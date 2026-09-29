#!/usr/bin/env python3
"""
ASEMON-PG — Parseur de logs

Suit en continu le fichier de log JSON de l'instance PostgreSQL locale
et alimente le repository distant avec :
  - les deadlocks détaillés (asemon.event_deadlocks)
  - les plans d'exécution capturés par auto_explain (asemon.event_plans)

Détection des deadlocks basée sur le code SQLSTATE 40P01 (standard
PostgreSQL, indépendant de la langue configurée sur le serveur) plutôt
que sur le texte du message, qui varie selon lc_messages
(ex. "deadlock detected" en anglais vs "interblocage (deadlock) détecté"
en français).
"""

import json
import os
import re
import time
import logging
from datetime import datetime, timezone

import psycopg
from config import REPO_DSN, PG_DATA_DIR

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("asemon-log-parser")

CURRENT_LOGFILES = os.path.join(PG_DATA_DIR, "current_logfiles")
POLL_INTERVAL = 5

# Extraction des lignes "Processus <pid> : <requête>" dans le détail du
# deadlock. Le texte est produit par PostgreSQL dans la langue du serveur
# (lc_messages) — le format observé en français est "Processus 123 : ..."
# et en anglais "Process 123: ...". Le "s?" couvre les deux variantes.
DEADLOCK_PROC_RE = re.compile(r"Processus?\s+(\d+)\s*:\s*(.+?)(?=\n(?:Processus?)\s+\d+\s*:|\Z)", re.DOTALL)
TABLE_RE = re.compile(r'\b(?:FROM|UPDATE|INTO|JOIN)\s+"?([A-Za-z_][A-Za-z0-9_\.]*)"?', re.IGNORECASE)
PLAN_RE = re.compile(r"duration:\s*([\d.]+)\s*ms\s*plan:\s*(\{.*\})", re.DOTALL)


def get_current_jsonlog_path():
    try:
        with open(CURRENT_LOGFILES) as f:
            for line in f:
                if line.startswith("jsonlog "):
                    rel_path = line.strip().split(" ", 1)[1]
                    return os.path.join(PG_DATA_DIR, rel_path)
    except FileNotFoundError:
        pass
    return None


def extract_tables(text):
    return sorted(set(TABLE_RE.findall(text or "")))


def parse_deadlock(entry):
    detail = entry.get("detail", "")
    procs = DEADLOCK_PROC_RE.findall(detail)
    queries = [q.strip().rstrip(".") for _, q in procs]
    tables = sorted(set(t for q in queries for t in extract_tables(q)))
    return {
        "occurred_at": entry.get("timestamp"),
        "process_id": entry.get("pid"),
        "involved_tables": tables,
        "involved_users": [entry.get("user")] if entry.get("user") else [],
        "queries": queries,
        "raw_log": json.dumps(entry, ensure_ascii=False),
    }


def parse_plan(entry):
    message = entry.get("message", "")
    m = PLAN_RE.search(message)
    if not m:
        return None
    duration_ms = float(m.group(1))
    try:
        plan = json.loads(m.group(2))
    except json.JSONDecodeError:
        return None
    return {
        "occurred_at": entry.get("timestamp"),
        "duration_ms": duration_ms,
        "query": entry.get("statement") or "",
        "plan": json.dumps(plan),
    }


def parse_timestamp(ts_str):
    try:
        return datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S.%f %Z").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return datetime.now(timezone.utc)


def write_deadlock(repo_conn, d):
    with repo_conn.cursor() as cur:
        cur.execute("""
            INSERT INTO asemon.event_deadlocks
            (occurred_at, process_id, involved_tables, involved_users, queries, raw_log)
            VALUES (%s, %s, %s, %s, %s, %s)
        """, (parse_timestamp(d["occurred_at"]), d["process_id"],
              d["involved_tables"], d["involved_users"], d["queries"], d["raw_log"]))
    repo_conn.commit()
    log.info("Deadlock enregistré | pid=%s tables=%s", d["process_id"], d["involved_tables"])


def write_plan(repo_conn, p):
    with repo_conn.cursor() as cur:
        cur.execute("""
            INSERT INTO asemon.event_plans (occurred_at, duration_ms, query, plan)
            VALUES (%s, %s, %s, %s)
        """, (parse_timestamp(p["occurred_at"]), p["duration_ms"], p["query"], p["plan"]))
    repo_conn.commit()
    log.info("Plan enregistré | duration=%.1fms", p["duration_ms"])


def follow(filepath):
    f = open(filepath, "r")
    f.seek(0, os.SEEK_END)
    inode = os.fstat(f.fileno()).st_ino

    while True:
        line = f.readline()
        if line:
            yield line
            continue

        current_path = get_current_jsonlog_path()
        if current_path and current_path != filepath:
            log.info("Rotation de log détectée, bascule vers %s", current_path)
            f.close()
            filepath = current_path
            f = open(filepath, "r")
            inode = os.fstat(f.fileno()).st_ino
            continue

        try:
            if os.stat(filepath).st_ino != inode:
                f.close()
                f = open(filepath, "r")
                inode = os.fstat(f.fileno()).st_ino
                continue
        except FileNotFoundError:
            pass

        time.sleep(POLL_INTERVAL)


def main():
    logpath = get_current_jsonlog_path()
    if not logpath:
        log.error("Impossible de déterminer le fichier de log actif. Arrêt.")
        return

    log.info("Suivi du fichier de log : %s", logpath)
    repo_conn = psycopg.connect(REPO_DSN)

    for line in follow(logpath):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue

        message = entry.get("message", "")
        try:
            if entry.get("state_code") == "40P01":
                write_deadlock(repo_conn, parse_deadlock(entry))
            elif message.startswith("duration:") and "plan:" in message:
                p = parse_plan(entry)
                if p:
                    write_plan(repo_conn, p)
        except Exception:
            log.exception("Erreur lors du traitement d'une ligne de log")
            try:
                repo_conn = psycopg.connect(REPO_DSN)
            except Exception:
                log.exception("Échec de reconnexion au repository")


if __name__ == "__main__":
    main()
