#!/usr/bin/env python3
"""
ASEMON-PG — Échantillonneur de sessions actives (Phase 2)

Tourne sur la VM surveillée (VM-Cible), à côté du collecteur. Toutes les
SAMPLE_INTERVAL secondes (défaut 2), relève les sessions ACTIVES de
pg_stat_activity et écrit une ligne par session dans asemon.snap_samples
(repository, VM-Monitoring). Voir docs/09-echantillonnage-phase2.md.

  * Seules les sessions state='active' des backends clients sont relevées
    (pas les sessions idle, ni l'échantillonneur lui-même).
  * Pas de texte de requête : query_id (jointure avec snap_statements).
  * Si le repository est injoignable, les échantillons sont gardés en mémoire
    (plafonnés) et réécrits avec leur horodatage d'origine au retour.

Configuration (config.py, voir config.py.example) :
  TARGET_DSN, REPO_DSN       comme le collecteur
  SAMPLE_INTERVAL            secondes entre deux échantillons (optionnel, 2 par défaut,
                             borné à 0.5 - 60)
"""

import logging
import signal
import threading
import time

import psycopg

import config
from config import TARGET_DSN, REPO_DSN

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger("asemon-sampler")

APP_NAME = "asemon-sampler"

DEFAULT_INTERVAL = 2.0
MIN_INTERVAL = 0.5
MAX_INTERVAL = 60.0

BUFFER_MAX_ROWS = 5000        # au-delà, on abandonne les plus anciens
BUFFER_MAX_AGE_S = 600        # un échantillon plus vieux que 10 min est abandonné
SUMMARY_EVERY_S = 60          # une ligne de bilan par minute
ERROR_LOG_EVERY_S = 60        # erreurs répétitives : une ligne par minute

SQL_SAMPLE = """
    SELECT now(),
           pid,
           -- session_key = session_id natif, cf. sql/05-schema-sessions.sql
           to_hex(floor(extract(epoch FROM backend_start))::bigint) || '.' || to_hex(pid),
           usename, datname, application_name,
           wait_event_type, wait_event, query_id, query_start
    FROM pg_stat_activity
    WHERE state = 'active'
      AND backend_type = 'client backend'
      AND pid <> pg_backend_pid()
"""

SQL_INSERT = """
    INSERT INTO asemon.snap_samples
        (sampled_at, interval_ms, pid, session_key, usename, datname,
         application_name, wait_event_type, wait_event, query_id, query_start)
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
"""

_stop = threading.Event()


def read_interval():
    """Lit SAMPLE_INTERVAL dans config.py ; valeur invalide ou hors bornes = avertissement."""
    raw = getattr(config, "SAMPLE_INTERVAL", DEFAULT_INTERVAL)
    try:
        value = float(raw)
    except (TypeError, ValueError):
        log.warning("SAMPLE_INTERVAL=%r invalide, valeur par défaut %ss utilisée", raw, DEFAULT_INTERVAL)
        return DEFAULT_INTERVAL
    if value != value:  # NaN
        log.warning("SAMPLE_INTERVAL=NaN invalide, valeur par défaut %ss utilisée", DEFAULT_INTERVAL)
        return DEFAULT_INTERVAL
    clamped = min(max(value, MIN_INTERVAL), MAX_INTERVAL)
    if clamped != value:
        log.warning("SAMPLE_INTERVAL=%s hors de [%s, %s], ramené à %ss",
                    value, MIN_INTERVAL, MAX_INTERVAL, clamped)
    return clamped


def connect_target():
    return psycopg.connect(TARGET_DSN, autocommit=True, application_name=APP_NAME)


def connect_repo():
    return psycopg.connect(REPO_DSN, application_name=APP_NAME)


def safe_close(conn):
    try:
        if conn is not None:
            conn.close()
    except Exception:
        pass


class Throttle:
    """Limite la fréquence d'une même catégorie de message d'erreur."""

    def __init__(self, every):
        self.every = every
        self.last = {}

    def ok(self, key):
        now = time.monotonic()
        if now - self.last.get(key, -1e18) >= self.every:
            self.last[key] = now
            return True
        return False


def main():
    interval = read_interval()
    interval_ms = int(round(interval * 1000))
    log.info("Démarrage de l'échantillonneur ASEMON-PG (intervalle=%ss)", interval)

    def on_signal(signum, _frame):
        log.info("Signal %s reçu, arrêt demandé.", signum)
        _stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    target_conn = None
    repo_conn = None
    buffer = []                 # [(monotonic_ts, row_tuple)]
    throttle = Throttle(ERROR_LOG_EVERY_S)
    n_sampled = n_written = n_dropped = 0
    last_summary = time.monotonic()
    next_tick = time.monotonic()

    def flush():
        """Écrit le buffer dans le repository ; garde tout en cas d'échec."""
        nonlocal repo_conn, buffer, n_written
        if not buffer:
            return
        try:
            if repo_conn is None or repo_conn.closed:
                repo_conn = connect_repo()
            with repo_conn.cursor() as cur:
                cur.executemany(SQL_INSERT, [row for _, row in buffer])
            repo_conn.commit()
            n_written += len(buffer)
            buffer = []
        except Exception as exc:
            if throttle.ok("repo"):
                log.error("Écriture dans le repository impossible (%d échantillons en attente) : %s",
                          len(buffer), exc)
            try:
                if repo_conn is not None and not repo_conn.closed:
                    repo_conn.rollback()
            except Exception:
                pass
            safe_close(repo_conn)
            repo_conn = None

    try:
        while not _stop.is_set():
            # --- relevé sur l'instance surveillée ---
            try:
                if target_conn is None or target_conn.closed:
                    target_conn = connect_target()
                with target_conn.cursor() as cur:
                    cur.execute(SQL_SAMPLE)
                    rows = cur.fetchall()
                ts = time.monotonic()
                for r in rows:
                    buffer.append((ts, (r[0], interval_ms) + tuple(r[1:])))
                n_sampled += len(rows)
            except Exception as exc:
                if throttle.ok("target"):
                    log.error("Lecture de pg_stat_activity impossible : %s", exc)
                safe_close(target_conn)
                target_conn = None

            # --- plafonnement du buffer ---
            if buffer:
                limit = time.monotonic() - BUFFER_MAX_AGE_S
                kept = [b for b in buffer if b[0] >= limit][-BUFFER_MAX_ROWS:]
                if len(kept) != len(buffer):
                    n_dropped += len(buffer) - len(kept)
                    if throttle.ok("drop"):
                        log.warning("Buffer plein ou trop ancien : %d échantillons abandonnés", n_dropped)
                    buffer = kept

            # --- écriture dans le repository ---
            flush()

            # --- bilan périodique ---
            if time.monotonic() - last_summary >= SUMMARY_EVERY_S:
                log.info("Bilan : %d échantillons relevés, %d écrits, %d abandonnés, %d en attente",
                         n_sampled, n_written, n_dropped, len(buffer))
                n_sampled = n_written = n_dropped = 0
                last_summary = time.monotonic()

            # --- attente jusqu'au prochain tick (sans dérive) ---
            next_tick += interval
            delay = next_tick - time.monotonic()
            if delay < 0:
                next_tick = time.monotonic()   # en retard : on ne rattrape pas
                delay = 0
            _stop.wait(delay)
    finally:
        flush()     # dernier envoi avant de quitter
        safe_close(target_conn)
        safe_close(repo_conn)
        log.info("Échantillonneur arrêté.")


if __name__ == "__main__":
    main()
