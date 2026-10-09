#!/usr/bin/env python3
"""
ASEMON-PG — Parseur de logs

Suit en continu le fichier de log JSON de l'instance PostgreSQL locale
et alimente le repository distant avec :
  - les deadlocks détaillés (asemon.event_deadlocks)
  - les plans d'exécution capturés par auto_explain (asemon.event_plans)
  - le cycle de vie des sessions : connexions / déconnexions
    (asemon.snap_sessions, Phase 1 de la roadmap IHM)

Détection des deadlocks basée sur le code SQLSTATE 40P01 (standard
PostgreSQL, indépendant de la langue configurée sur le serveur) plutôt
que sur le texte du message, qui varie selon lc_messages
(ex. "deadlock detected" en anglais vs "interblocage (deadlock) détecté"
en français).

EXCEPTION — connexions / déconnexions : ces messages sont de simples
LOG (SQLSTATE 00000), sans code qui les distingue. Ils sont donc
reconnus par le début de leur texte ("connection authorized:",
"disconnection:"), ce qui IMPOSE lc_messages = 'C' sur le serveur
surveillé. Avec une autre langue, aucune session n'est enregistrée
(sans erreur : même piège silencieux que pour les deadlocks).

Chaque événement est rattaché à sa session par session_key, qui est le
champ "session_id" du jsonlog (ex. "6ac8acf0.9bd" = epoch de début du
backend en hexa + "." + pid en hexa).
"""

import ipaddress
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

# Sessions. Le session_id du jsonlog vaut "<epoch hexa>.<pid hexa>".
SESSION_ID_RE = re.compile(r"^([0-9a-f]+)\.([0-9a-f]+)$")
# Dans "connection authorized: user=u database=d application_name=a[ SSL enabled (...)]",
# application_name n'est PAS un champ du JSON à ce stade de la connexion : on le lit
# dans le message. Un éventuel suffixe " SSL enabled (...)" est écarté.
CONN_APP_RE = re.compile(r" application_name=(.*?)(?: SSL enabled \(.*)?$")


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


def session_key_of(entry):
    """session_id du jsonlog si au format attendu, sinon None."""
    session_id = entry.get("session_id")
    return session_id if SESSION_ID_RE.match(session_id or "") else None


def session_start_from_key(session_key):
    """Début du backend (UTC, précision seconde) lu dans la clé de session."""
    m = SESSION_ID_RE.match(session_key or "")
    if not m:
        return None
    return datetime.fromtimestamp(int(m.group(1), 16), tz=timezone.utc)


def parse_client_addr(remote_host):
    """Adresse IP du client, ou None (socket Unix "[local]", nom d'hôte, vide)."""
    try:
        return str(ipaddress.ip_address(remote_host))
    except ValueError:
        return None


def parse_session_event(entry):
    """Connexion / déconnexion d'une session cliente, ou None pour toute autre ligne.

    Repose sur le texte du message : suppose lc_messages = 'C' (voir docstring).
    """
    message = entry.get("message", "")
    if message.startswith("connection authorized:"):
        kind = "connect"
    elif message.startswith("disconnection:"):
        kind = "disconnect"
    else:
        return None

    session_key = session_key_of(entry)
    if not session_key:
        return None

    if kind == "connect":
        m = CONN_APP_RE.search(message)
        application_name = m.group(1) if m else None
    else:
        application_name = entry.get("application_name")

    return {
        "kind": kind,
        "session_key": session_key,
        "pid": entry.get("pid"),
        "usename": entry.get("user") or None,
        "datname": entry.get("dbname") or None,
        "application_name": application_name or None,
        "client_addr": parse_client_addr(entry.get("remote_host")),
        "connected_at": session_start_from_key(session_key),
        "event_at": parse_timestamp(entry.get("timestamp")),
    }


def parse_deadlock(entry):
    detail = entry.get("detail", "")
    procs = DEADLOCK_PROC_RE.findall(detail)
    queries = [q.strip().rstrip(".") for _, q in procs]
    tables = sorted(set(t for q in queries for t in extract_tables(q)))
    return {
        "occurred_at": entry.get("timestamp"),
        "session_key": session_key_of(entry),
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
        "session_key": session_key_of(entry),
        "duration_ms": duration_ms,
        "query": entry.get("statement") or "",
        "plan": json.dumps(plan),
    }


def parse_timestamp(ts_str):
    try:
        return datetime.strptime(ts_str, "%Y-%m-%d %H:%M:%S.%f %Z").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return datetime.now(timezone.utc)


SQL_DEADLOCK = """
    INSERT INTO asemon.event_deadlocks
    (occurred_at, process_id, involved_tables, involved_users, queries, raw_log, session_key)
    VALUES (%s, %s, %s, %s, %s, %s, %s)
"""

SQL_PLAN = """
    INSERT INTO asemon.event_plans (occurred_at, duration_ms, query, plan, session_key)
    VALUES (%s, %s, %s, %s, %s)
"""

# Connexion : on n'écrase jamais une ligne existante.
SQL_SESSION_CONNECT = """
    INSERT INTO asemon.snap_sessions
    (session_key, pid, usename, application_name, client_addr, datname, connected_at)
    VALUES (%(session_key)s, %(pid)s, %(usename)s, %(application_name)s,
            %(client_addr)s, %(datname)s, %(connected_at)s)
    ON CONFLICT (session_key) DO NOTHING
"""

# Déconnexion : crée la ligne complète si la connexion n'a pas été vue (parseur
# démarré en cours de session), sinon se contente de poser disconnected_at.
SQL_SESSION_DISCONNECT = """
    INSERT INTO asemon.snap_sessions
    (session_key, pid, usename, application_name, client_addr, datname,
     connected_at, disconnected_at)
    VALUES (%(session_key)s, %(pid)s, %(usename)s, %(application_name)s,
            %(client_addr)s, %(datname)s, %(connected_at)s, %(event_at)s)
    ON CONFLICT (session_key) DO UPDATE SET disconnected_at = %(event_at)s
"""
# NB : on réutilise le paramètre plutôt que EXCLUDED.disconnected_at, car lire
# EXCLUDED exige le droit SELECT sur la colonne, que collector_writer n'a pas
# (seul SELECT (session_key) lui est accordé, voir sql/05-schema-sessions.sql).


def write_deadlock(repo_conn, d):
    with repo_conn.cursor() as cur:
        cur.execute(SQL_DEADLOCK, (parse_timestamp(d["occurred_at"]), d["process_id"],
                                   d["involved_tables"], d["involved_users"], d["queries"],
                                   d["raw_log"], d["session_key"]))
    repo_conn.commit()
    log.info("Deadlock enregistré | pid=%s tables=%s", d["process_id"], d["involved_tables"])


def write_plan(repo_conn, p):
    with repo_conn.cursor() as cur:
        cur.execute(SQL_PLAN, (parse_timestamp(p["occurred_at"]), p["duration_ms"],
                               p["query"], p["plan"], p["session_key"]))
    repo_conn.commit()
    log.info("Plan enregistré | duration=%.1fms", p["duration_ms"])


def write_session(repo_conn, s):
    sql = SQL_SESSION_CONNECT if s["kind"] == "connect" else SQL_SESSION_DISCONNECT
    with repo_conn.cursor() as cur:
        cur.execute(sql, s)
    repo_conn.commit()
    log.info("Session %s | key=%s user=%s app=%s",
             "connectée" if s["kind"] == "connect" else "déconnectée",
             s["session_key"], s["usename"], s["application_name"])


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
            else:
                s = parse_session_event(entry)
                if s:
                    write_session(repo_conn, s)
        except Exception:
            log.exception("Erreur lors du traitement d'une ligne de log")
            try:
                repo_conn = psycopg.connect(REPO_DSN)
            except Exception:
                log.exception("Échec de reconnexion au repository")


if __name__ == "__main__":
    main()
