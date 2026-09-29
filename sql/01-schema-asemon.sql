-- ============================================================
-- ASEMON-PG — Schéma du repository de monitoring
-- À exécuter sur VM-Monitoring, dans la base `monitoring`
-- Usage : sudo -u postgres psql -d monitoring -f 01-schema-asemon.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS asemon;

-- Snapshots d'activité / sessions (équivalent monProcessActivity)
CREATE TABLE IF NOT EXISTS asemon.snap_activity (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    pid INT,
    usename TEXT,
    datname TEXT,
    application_name TEXT,
    client_addr TEXT,
    state TEXT,
    wait_event_type TEXT,
    wait_event TEXT,
    query TEXT,
    query_start TIMESTAMPTZ,
    xact_start TIMESTAMPTZ,
    backend_start TIMESTAMPTZ
);

-- Snapshots de verrous et blocages (équivalent monLocks)
CREATE TABLE IF NOT EXISTS asemon.snap_locks (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    pid INT,
    blocking_pid INT,
    locktype TEXT,
    relation TEXT,
    mode TEXT,
    granted BOOLEAN,
    query TEXT
);

-- Snapshots I/O par base (pg_stat_database)
CREATE TABLE IF NOT EXISTS asemon.snap_io (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    datname TEXT,
    blks_read BIGINT,
    blks_hit BIGINT,
    tup_returned BIGINT,
    tup_fetched BIGINT,
    tup_inserted BIGINT,
    tup_updated BIGINT,
    tup_deleted BIGINT,
    temp_files BIGINT,
    temp_bytes BIGINT,
    deadlocks BIGINT
);

-- Métriques OS (CPU, disque, réseau) — hors périmètre PostgreSQL
CREATE TABLE IF NOT EXISTS asemon.snap_os (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    cpu_percent NUMERIC,
    mem_percent NUMERIC,
    disk_read_bytes BIGINT,
    disk_write_bytes BIGINT,
    net_sent_bytes BIGINT,
    net_recv_bytes BIGINT
);

-- Top SQL / procédures (pg_stat_statements)
CREATE TABLE IF NOT EXISTS asemon.snap_statements (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    queryid BIGINT,
    query TEXT,
    calls BIGINT,
    total_exec_time DOUBLE PRECISION,
    mean_exec_time DOUBLE PRECISION,
    rows BIGINT,
    shared_blks_hit BIGINT,
    shared_blks_read BIGINT
);

-- Événements deadlocks (alimenté par le futur parseur de logs)
CREATE TABLE IF NOT EXISTS asemon.event_deadlocks (
    id BIGSERIAL PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL,
    process_id INT,
    involved_tables TEXT[],
    involved_users TEXT[],
    queries TEXT[],
    raw_log TEXT
);

-- Plans d'exécution capturés par auto_explain (alimenté par le futur parseur de logs)
CREATE TABLE IF NOT EXISTS asemon.event_plans (
    id BIGSERIAL PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL,
    duration_ms DOUBLE PRECISION,
    query TEXT,
    plan JSONB
);

-- Index sur les colonnes de temps, utilisés par tous les dashboards Grafana
CREATE INDEX IF NOT EXISTS idx_snap_activity_time ON asemon.snap_activity (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_locks_time ON asemon.snap_locks (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_io_time ON asemon.snap_io (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_os_time ON asemon.snap_os (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_statements_time ON asemon.snap_statements (collected_at);
CREATE INDEX IF NOT EXISTS idx_event_deadlocks_time ON asemon.event_deadlocks (occurred_at);
CREATE INDEX IF NOT EXISTS idx_event_plans_time ON asemon.event_plans (occurred_at);
