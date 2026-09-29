-- ============================================================
-- ASEMON-PG — Extension du schéma (maintenance, checkpoints, WAL, système)
-- À exécuter sur VM-Monitoring, dans la base `monitoring`
-- Usage : sudo -u postgres psql -d monitoring -f 04-schema-extension.sql
-- ============================================================

-- Seq scans / index scans / tuples morts par table (pg_stat_user_tables)
CREATE TABLE IF NOT EXISTS asemon.snap_tables (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    schemaname TEXT,
    relname TEXT,
    seq_scan BIGINT,
    seq_tup_read BIGINT,
    idx_scan BIGINT,
    idx_tup_fetch BIGINT,
    n_live_tup BIGINT,
    n_dead_tup BIGINT,
    last_autovacuum TIMESTAMPTZ,
    last_autoanalyze TIMESTAMPTZ
);

-- Index inutilisés / usage des index (pg_stat_user_indexes)
CREATE TABLE IF NOT EXISTS asemon.snap_indexes (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    schemaname TEXT,
    relname TEXT,
    indexrelname TEXT,
    idx_scan BIGINT,
    idx_tup_read BIGINT,
    idx_tup_fetch BIGINT,
    index_size_bytes BIGINT
);

-- Checkpoints (pg_stat_checkpointer, PostgreSQL 17+)
CREATE TABLE IF NOT EXISTS asemon.snap_checkpoints (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    num_timed BIGINT,
    num_requested BIGINT,
    restartpoints_timed BIGINT,
    restartpoints_req BIGINT,
    write_time DOUBLE PRECISION,
    sync_time DOUBLE PRECISION,
    buffers_written BIGINT
);

-- Volume de WAL généré (pg_stat_wal)
CREATE TABLE IF NOT EXISTS asemon.snap_wal (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    wal_records BIGINT,
    wal_fpi BIGINT,
    wal_bytes NUMERIC,
    wal_buffers_full BIGINT,
    wal_write BIGINT,
    wal_sync BIGINT
);

-- Âge des transactions par base (risque de wraparound)
CREATE TABLE IF NOT EXISTS asemon.snap_db_age (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    datname TEXT,
    datfrozenxid_age BIGINT
);

-- Vue d'ensemble des connexions (courant vs max_connections)
CREATE TABLE IF NOT EXISTS asemon.snap_connections (
    id BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    total_connections INT,
    active_connections INT,
    idle_connections INT,
    idle_in_transaction_connections INT,
    max_connections INT
);

-- Extension de snap_os : espace disque libre et iowait, en plus des
-- colonnes existantes (cpu_percent, mem_percent, disk_*_bytes, net_*_bytes)
ALTER TABLE asemon.snap_os ADD COLUMN IF NOT EXISTS disk_free_bytes BIGINT;
ALTER TABLE asemon.snap_os ADD COLUMN IF NOT EXISTS disk_total_bytes BIGINT;
ALTER TABLE asemon.snap_os ADD COLUMN IF NOT EXISTS cpu_iowait_percent NUMERIC;

-- Index sur les colonnes de temps
CREATE INDEX IF NOT EXISTS idx_snap_tables_time ON asemon.snap_tables (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_indexes_time ON asemon.snap_indexes (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_checkpoints_time ON asemon.snap_checkpoints (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_wal_time ON asemon.snap_wal (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_db_age_time ON asemon.snap_db_age (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_connections_time ON asemon.snap_connections (collected_at);

-- Droits d'écriture pour le collecteur sur les nouvelles tables
GRANT INSERT ON asemon.snap_tables, asemon.snap_indexes, asemon.snap_checkpoints,
                 asemon.snap_wal, asemon.snap_db_age, asemon.snap_connections
    TO collector_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA asemon TO collector_writer;

-- Droits de lecture pour Grafana
GRANT SELECT ON asemon.snap_tables, asemon.snap_indexes, asemon.snap_checkpoints,
                 asemon.snap_wal, asemon.snap_db_age, asemon.snap_connections
    TO grafana_ro;
