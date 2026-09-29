#!/usr/bin/env python3
"""
ASEMON-PG — Collecteur

Tourne sur la VM surveillée (VM-Cible). À chaque cycle :
  1. Lit les métriques OS locales (CPU, iowait, mémoire, disque, réseau,
     espace disque libre) via psutil.
  2. Lit les vues pg_stat_* de l'instance PostgreSQL locale (surveillée)
     via l'utilisateur asemon_collect (rôle pg_monitor) : activité,
     verrous, I/O, top requêtes, tables (seq/index scans, bloat),
     index inutilisés, checkpoints, WAL, âge des transactions,
     connexions vs max_connections.
  3. Écrit les résultats dans le repository distant (VM-Monitoring)
     via l'utilisateur collector_writer.

Configuration attendue dans config.py (voir config.py.example).

Nécessite le schéma étendu (sql/04-schema-extension.sql) en plus du
schéma de base (sql/01-schema-asemon.sql).
"""

import time
import logging
import psutil
import psycopg
from config import TARGET_DSN, REPO_DSN, INTERVAL

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)
log = logging.getLogger("asemon-collector")

# Compteurs précédents pour calculer les deltas réseau/disque
_prev_disk = None
_prev_net = None


def collect_os_metrics():
    """Retourne un dict de métriques OS instantanées (deltas depuis le cycle précédent)."""
    global _prev_disk, _prev_net

    cpu_percent = psutil.cpu_percent(interval=1)
    mem_percent = psutil.virtual_memory().percent

    # iowait : uniquement disponible sous Linux (absent sur macOS/Windows).
    # psutil retourne alors un namedtuple sans l'attribut 'iowait'.
    cpu_times = psutil.cpu_times_percent(interval=None)
    cpu_iowait_percent = getattr(cpu_times, "iowait", None)

    disk_io = psutil.disk_io_counters()
    net = psutil.net_io_counters()
    disk_usage = psutil.disk_usage("/")

    disk_read = disk_io.read_bytes
    disk_write = disk_io.write_bytes
    net_sent = net.bytes_sent
    net_recv = net.bytes_recv

    if _prev_disk is not None:
        disk_read_delta = disk_read - _prev_disk[0]
        disk_write_delta = disk_write - _prev_disk[1]
    else:
        disk_read_delta = 0
        disk_write_delta = 0

    if _prev_net is not None:
        net_sent_delta = net_sent - _prev_net[0]
        net_recv_delta = net_recv - _prev_net[1]
    else:
        net_sent_delta = 0
        net_recv_delta = 0

    _prev_disk = (disk_read, disk_write)
    _prev_net = (net_sent, net_recv)

    return {
        "cpu_percent": cpu_percent,
        "mem_percent": mem_percent,
        "disk_read_bytes": disk_read_delta,
        "disk_write_bytes": disk_write_delta,
        "net_sent_bytes": net_sent_delta,
        "net_recv_bytes": net_recv_delta,
        "disk_free_bytes": disk_usage.free,
        "disk_total_bytes": disk_usage.total,
        "cpu_iowait_percent": cpu_iowait_percent,
    }


def collect_activity(target_conn):
    """pg_stat_activity : sessions, requêtes en cours, attentes."""
    query = """
        SELECT pid, usename, datname, application_name,
               client_addr::text, state,
               wait_event_type, wait_event,
               query, query_start, xact_start, backend_start
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def collect_locks(target_conn):
    """pg_locks + reconstruction des blocages via pg_blocking_pids()."""
    query = """
        SELECT l.pid,
               bp.blocking_pid,
               l.locktype,
               COALESCE(c.relname, l.relation::text) AS relation,
               l.mode,
               l.granted,
               a.query
        FROM pg_locks l
        LEFT JOIN pg_class c ON c.oid = l.relation
        LEFT JOIN pg_stat_activity a ON a.pid = l.pid
        LEFT JOIN LATERAL (
            SELECT unnest(pg_blocking_pids(l.pid)) AS blocking_pid
        ) bp ON true
        WHERE l.pid <> pg_backend_pid()
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def collect_io(target_conn):
    """pg_stat_database : I/O, cache hit ratio (calculé côté Grafana), fichiers
    temporaires et deadlocks cumulés par base."""
    query = """
        SELECT datname, blks_read, blks_hit, tup_returned, tup_fetched,
               tup_inserted, tup_updated, tup_deleted,
               temp_files, temp_bytes, deadlocks
        FROM pg_stat_database
        WHERE datname IS NOT NULL
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def collect_statements(target_conn):
    """Top requêtes / procédures depuis pg_stat_statements (requêtes lentes)."""
    query = """
        SELECT queryid, query, calls, total_exec_time, mean_exec_time,
               rows, shared_blks_hit, shared_blks_read
        FROM pg_stat_statements
        ORDER BY total_exec_time DESC
        LIMIT 100
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def collect_tables(target_conn):
    """pg_stat_user_tables : seq scans vs index scans, tuples morts, autovacuum.

    Un seq_scan élevé sur une grosse table (n_live_tup important) signale
    souvent un index manquant. n_dead_tup/last_autovacuum permettent de
    surveiller le bloat.
    """
    query = """
        SELECT schemaname, relname, seq_scan, seq_tup_read,
               idx_scan, idx_tup_fetch, n_live_tup, n_dead_tup,
               last_autovacuum, last_autoanalyze
        FROM pg_stat_user_tables
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def collect_indexes(target_conn):
    """pg_stat_user_indexes : détection des index jamais utilisés (idx_scan = 0),
    qui coûtent en écriture sans bénéfice en lecture."""
    query = """
        SELECT s.schemaname, s.relname, s.indexrelname,
               s.idx_scan, s.idx_tup_read, s.idx_tup_fetch,
               pg_relation_size(s.indexrelid) AS index_size_bytes
        FROM pg_stat_user_indexes s
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def collect_checkpoints(target_conn):
    """Statistiques de checkpoints.

    PostgreSQL 17 a déplacé ces compteurs de pg_stat_bgwriter vers la
    nouvelle vue pg_stat_checkpointer. On tente d'abord cette dernière,
    avec repli sur pg_stat_bgwriter pour rester compatible < 17.

    num_requested élevé par rapport à num_timed indique que max_wal_size
    est probablement trop bas (checkpoints déclenchés par le volume de
    WAL plutôt que par le planning).
    """
    query_pg17 = """
        SELECT num_timed, num_requested,
               restartpoints_timed, restartpoints_req,
               write_time, sync_time, buffers_written
        FROM pg_stat_checkpointer
    """
    query_legacy = """
        SELECT checkpoints_timed AS num_timed, checkpoints_req AS num_requested,
               0 AS restartpoints_timed, 0 AS restartpoints_req,
               checkpoint_write_time AS write_time, checkpoint_sync_time AS sync_time,
               buffers_checkpoint AS buffers_written
        FROM pg_stat_bgwriter
    """
    with target_conn.cursor() as cur:
        try:
            cur.execute(query_pg17)
            return cur.fetchall()
        except psycopg.errors.UndefinedTable:
            target_conn.rollback()
            cur.execute(query_legacy)
            return cur.fetchall()


def collect_wal(target_conn):
    """pg_stat_wal : volume de WAL généré (PostgreSQL 14+)."""
    query = """
        SELECT wal_records, wal_fpi, wal_bytes,
               wal_buffers_full, wal_write, wal_sync
        FROM pg_stat_wal
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def collect_db_age(target_conn):
    """Âge des transactions par base, pour surveiller le risque de
    wraparound des identifiants de transaction (datfrozenxid)."""
    query = """
        SELECT datname, age(datfrozenxid) AS datfrozenxid_age
        FROM pg_database
        WHERE datallowconn
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchall()


def collect_connections(target_conn):
    """Vue d'ensemble des connexions courantes vs max_connections."""
    query = """
        SELECT
            count(*) AS total_connections,
            count(*) FILTER (WHERE state = 'active') AS active_connections,
            count(*) FILTER (WHERE state = 'idle') AS idle_connections,
            count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction_connections,
            (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max_connections
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid()
    """
    with target_conn.cursor() as cur:
        cur.execute(query)
        return cur.fetchone()


def write_snapshots(repo_conn, os_metrics, activity, locks, io, statements,
                     tables, indexes, checkpoints, wal, db_age, connections):
    with repo_conn.cursor() as cur:
        cur.execute("""
            INSERT INTO asemon.snap_os
            (cpu_percent, mem_percent, disk_read_bytes, disk_write_bytes,
             net_sent_bytes, net_recv_bytes, disk_free_bytes, disk_total_bytes,
             cpu_iowait_percent)
            VALUES (%(cpu_percent)s, %(mem_percent)s, %(disk_read_bytes)s,
                    %(disk_write_bytes)s, %(net_sent_bytes)s, %(net_recv_bytes)s,
                    %(disk_free_bytes)s, %(disk_total_bytes)s, %(cpu_iowait_percent)s)
        """, os_metrics)

        if activity:
            cur.executemany("""
                INSERT INTO asemon.snap_activity
                (pid, usename, datname, application_name, client_addr, state,
                 wait_event_type, wait_event, query, query_start, xact_start, backend_start)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """, activity)

        if locks:
            cur.executemany("""
                INSERT INTO asemon.snap_locks
                (pid, blocking_pid, locktype, relation, mode, granted, query)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, locks)

        if io:
            cur.executemany("""
                INSERT INTO asemon.snap_io
                (datname, blks_read, blks_hit, tup_returned, tup_fetched,
                 tup_inserted, tup_updated, tup_deleted, temp_files, temp_bytes, deadlocks)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """, io)

        if statements:
            cur.executemany("""
                INSERT INTO asemon.snap_statements
                (queryid, query, calls, total_exec_time, mean_exec_time,
                 rows, shared_blks_hit, shared_blks_read)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
            """, statements)

        if tables:
            cur.executemany("""
                INSERT INTO asemon.snap_tables
                (schemaname, relname, seq_scan, seq_tup_read, idx_scan, idx_tup_fetch,
                 n_live_tup, n_dead_tup, last_autovacuum, last_autoanalyze)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """, tables)

        if indexes:
            cur.executemany("""
                INSERT INTO asemon.snap_indexes
                (schemaname, relname, indexrelname, idx_scan, idx_tup_read,
                 idx_tup_fetch, index_size_bytes)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, indexes)

        if checkpoints:
            cur.executemany("""
                INSERT INTO asemon.snap_checkpoints
                (num_timed, num_requested, restartpoints_timed, restartpoints_req,
                 write_time, sync_time, buffers_written)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, checkpoints)

        if wal:
            cur.executemany("""
                INSERT INTO asemon.snap_wal
                (wal_records, wal_fpi, wal_bytes, wal_buffers_full, wal_write, wal_sync)
                VALUES (%s, %s, %s, %s, %s, %s)
            """, wal)

        if db_age:
            cur.executemany("""
                INSERT INTO asemon.snap_db_age (datname, datfrozenxid_age)
                VALUES (%s, %s)
            """, db_age)

        if connections:
            cur.execute("""
                INSERT INTO asemon.snap_connections
                (total_connections, active_connections, idle_connections,
                 idle_in_transaction_connections, max_connections)
                VALUES (%s, %s, %s, %s, %s)
            """, connections)

    repo_conn.commit()


def run_cycle(target_conn, repo_conn):
    os_metrics = collect_os_metrics()
    activity = collect_activity(target_conn)
    locks = collect_locks(target_conn)
    io = collect_io(target_conn)
    statements = collect_statements(target_conn)
    tables = collect_tables(target_conn)
    indexes = collect_indexes(target_conn)
    checkpoints = collect_checkpoints(target_conn)
    wal = collect_wal(target_conn)
    db_age = collect_db_age(target_conn)
    connections = collect_connections(target_conn)

    write_snapshots(repo_conn, os_metrics, activity, locks, io, statements,
                     tables, indexes, checkpoints, wal, db_age, connections)

    log.info(
        "Snapshot OK | CPU=%.1f%% MEM=%.1f%% | sessions=%d locks=%d statements=%d "
        "tables=%d indexes=%d",
        os_metrics["cpu_percent"], os_metrics["mem_percent"],
        len(activity), len(locks), len(statements), len(tables), len(indexes)
    )


def main():
    log.info("Démarrage du collecteur ASEMON-PG (intervalle=%ss)", INTERVAL)

    target_conn = psycopg.connect(TARGET_DSN, autocommit=True)
    repo_conn = psycopg.connect(REPO_DSN)

    try:
        while True:
            try:
                run_cycle(target_conn, repo_conn)
            except Exception:
                log.exception("Erreur pendant le cycle de collecte")
                # Reconnexion défensive en cas de coupure réseau/DB
                try:
                    target_conn = psycopg.connect(TARGET_DSN, autocommit=True)
                    repo_conn = psycopg.connect(REPO_DSN)
                except Exception:
                    log.exception("Échec de reconnexion, nouvelle tentative dans %ss", INTERVAL)

            time.sleep(INTERVAL)
    except KeyboardInterrupt:
        log.info("Arrêt demandé, fermeture des connexions.")
    finally:
        target_conn.close()
        repo_conn.close()


if __name__ == "__main__":
    main()
