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

# Nom sous lequel le collecteur apparaît dans pg_stat_activity et dans les logs
# de connexion (snap_sessions.application_name) : permet de le distinguer des
# sessions utilisateur (camemberts "par programme", Phase 3).
APP_NAME = "asemon-collector"

# Compteurs précédents pour calculer les deltas réseau/disque
_prev_disk = None
_prev_net = None

# pg_stat_kcache (CPU et I/O disque réels par requête, Phase 3) : compteurs
# cumulés du cycle précédent, par (queryid, userid, dbid). Voir
# docs/14-kcache-phase3.md. L'extension est facultative : si elle est absente,
# le collecteur continue sans elle et réessaie toutes les KCACHE_RETRY_S secondes.
KCACHE_RETRY_S = 600
_kcache_prev = {}          # (queryid, userid, dbid) -> (usename, datname, cpu_user_s, cpu_system_s, reads, writes)
_kcache_prev_at = None     # now() de la cible au dernier relevé validé
_kcache_disabled_until = 0.0


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
               query, query_start, xact_start, backend_start,
               -- session_key = session_id natif (celui du jsonlog), cf. sql/05-schema-sessions.sql
               to_hex(floor(extract(epoch FROM backend_start))::bigint) || '.' || to_hex(pid)
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


SQL_KCACHE = """
    SELECT now(), k.queryid, k.userid, k.dbid, r.rolname, d.datname,
           sum(k.plan_user_time + k.exec_user_time),
           sum(k.plan_system_time + k.exec_system_time),
           sum(k.plan_reads + k.exec_reads),
           sum(k.plan_writes + k.exec_writes)
    FROM pg_stat_kcache() k
    LEFT JOIN pg_roles r ON r.oid = k.userid
    LEFT JOIN pg_database d ON d.oid = k.dbid
    GROUP BY k.queryid, k.userid, k.dbid, r.rolname, d.datname
"""


def compute_kcache_deltas(prev, current):
    """Écarts entre deux relevés cumulés de pg_stat_kcache.

    prev, current : {(queryid, userid, dbid): (usename, datname, cpu_user_s,
    cpu_system_s, reads, writes)}. Retourne des tuples
    (queryid, usename, datname, cpu_user_ms, cpu_system_ms, reads, writes) pour
    les seules requêtes qui ont consommé quelque chose entre les deux relevés.

    Un compteur qui diminue (pg_stat_kcache_reset, redémarrage, entrée évincée
    puis recréée) signifie que le cumul est reparti de zéro : on prend alors la
    valeur courante. Une clé absente du relevé précédent compte en entier.
    Si prev est vide (premier relevé), il n'y a pas d'écart à calculer.
    """
    if not prev:
        return []
    rows = []
    for key, (usename, datname, user_s, sys_s, reads, writes) in current.items():
        old = prev.get(key)
        if old is None:
            d_user, d_sys, d_reads, d_writes = user_s, sys_s, reads, writes
        else:
            _, _, o_user, o_sys, o_reads, o_writes = old
            if user_s < o_user or sys_s < o_sys or reads < o_reads or writes < o_writes:
                d_user, d_sys, d_reads, d_writes = user_s, sys_s, reads, writes
            else:
                d_user, d_sys = user_s - o_user, sys_s - o_sys
                d_reads, d_writes = reads - o_reads, writes - o_writes
        if d_user > 0 or d_sys > 0 or d_reads > 0 or d_writes > 0:
            rows.append((key[0], usename, datname,
                         d_user * 1000.0, d_sys * 1000.0, int(d_reads), int(d_writes)))
    return rows


def collect_kcache(target_conn):
    """Écarts pg_stat_kcache depuis le cycle précédent.

    Retourne (lignes, état) ; l'état n'est adopté par commit_kcache() qu'après
    l'écriture réussie dans le repository, pour ne perdre aucun écart si cette
    écriture échoue. Retourne ([], None) si l'extension est absente.
    """
    global _kcache_disabled_until
    if time.monotonic() < _kcache_disabled_until:
        return [], None
    try:
        with target_conn.cursor() as cur:
            cur.execute(SQL_KCACHE)
            fetched = cur.fetchall()
    except (psycopg.errors.UndefinedFunction, psycopg.errors.UndefinedTable,
            psycopg.errors.FeatureNotSupported, psycopg.errors.ObjectNotInPrerequisiteState) as exc:
        log.warning("pg_stat_kcache indisponible (%s) : CPU et I/O réels non collectés, "
                    "nouvel essai dans %ss", str(exc).splitlines()[0], KCACHE_RETRY_S)
        _kcache_disabled_until = time.monotonic() + KCACHE_RETRY_S
        commit_kcache((None, {}))   # repartir d'un état vierge au retour de l'extension
        return [], None

    if not fetched:
        return [], (None, {})
    now = fetched[0][0]
    current = {(r[1], r[2], r[3]): (r[4], r[5], float(r[6] or 0), float(r[7] or 0),
                                    int(r[8] or 0), int(r[9] or 0)) for r in fetched}
    rows = []
    if _kcache_prev_at is not None:
        period_ms = int(round((now - _kcache_prev_at).total_seconds() * 1000))
        if period_ms > 0:
            rows = [(now, period_ms) + d for d in compute_kcache_deltas(_kcache_prev, current)]
    return rows, (now, current)


def commit_kcache(state):
    """Adopte l'état du cycle une fois ses écarts écrits dans le repository."""
    global _kcache_prev, _kcache_prev_at
    if state is not None:
        _kcache_prev_at, _kcache_prev = state


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
                     tables, indexes, checkpoints, wal, db_age, connections, kcache=()):
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
                 wait_event_type, wait_event, query, query_start, xact_start, backend_start,
                 session_key)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
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

        if kcache:
            cur.executemany("""
                INSERT INTO asemon.snap_kcache
                (sampled_at, period_ms, queryid, usename, datname,
                 cpu_user_ms, cpu_system_ms, reads_bytes, writes_bytes)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
            """, kcache)

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
    kcache, kcache_state = collect_kcache(target_conn)

    write_snapshots(repo_conn, os_metrics, activity, locks, io, statements,
                     tables, indexes, checkpoints, wal, db_age, connections, kcache)
    commit_kcache(kcache_state)

    log.info(
        "Snapshot OK | CPU=%.1f%% MEM=%.1f%% | sessions=%d locks=%d statements=%d "
        "tables=%d indexes=%d kcache=%d",
        os_metrics["cpu_percent"], os_metrics["mem_percent"],
        len(activity), len(locks), len(statements), len(tables), len(indexes), len(kcache)
    )


def main():
    log.info("Démarrage du collecteur ASEMON-PG (intervalle=%ss)", INTERVAL)

    target_conn = psycopg.connect(TARGET_DSN, autocommit=True, application_name=APP_NAME)
    repo_conn = psycopg.connect(REPO_DSN, application_name=APP_NAME)

    try:
        while True:
            try:
                run_cycle(target_conn, repo_conn)
            except Exception:
                log.exception("Erreur pendant le cycle de collecte")
                # Reconnexion défensive en cas de coupure réseau/DB
                try:
                    target_conn = psycopg.connect(TARGET_DSN, autocommit=True, application_name=APP_NAME)
                    repo_conn = psycopg.connect(REPO_DSN, application_name=APP_NAME)
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
