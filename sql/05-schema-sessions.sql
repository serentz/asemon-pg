-- ============================================================
-- ASEMON-PG — Proposition de schéma pour la réconciliation
-- session / requête (voir docs/06-roadmap-ihm.md)
--
-- STATUT : NON DÉPLOYÉ. Ce script est une proposition de travail
-- pour la Phase 1 / Phase 2 de la roadmap IHM, à relire et adapter
-- avant toute exécution sur VM-Monitoring. Il n'est référencé par
-- aucun code (collector.py / log_parser.py) pour l'instant.
--
-- À exécuter (une fois validé) sur VM-Monitoring, base `monitoring` :
--   sudo -u postgres psql -d monitoring -f 05-schema-sessions.sql
-- ============================================================

-- ------------------------------------------------------------
-- Phase 1 : cycle de vie des sessions, alimenté par le parsing
-- des logs de connexion/déconnexion (log_connections/log_disconnections
-- à activer côté PostgreSQL sur VM-Cible, puis extension de
-- log_parser.py pour peupler cette table).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asemon.snap_sessions (
    id BIGSERIAL PRIMARY KEY,
    session_key TEXT NOT NULL,          -- pid || '-' || epoch(backend_start), stable sur la durée de vie du backend
    pid INT,
    usename TEXT,
    application_name TEXT,
    client_addr INET,
    datname TEXT,
    connected_at TIMESTAMPTZ,
    disconnected_at TIMESTAMPTZ,        -- NULL tant que la session est active
    total_cpu_ms NUMERIC,               -- agrégé a posteriori (Phase 3, pg_stat_kcache)
    total_io_bytes BIGINT,              -- agrégé a posteriori
    query_count INT,                    -- nombre de requêtes exécutées sur la session
    UNIQUE (session_key)
);

CREATE INDEX IF NOT EXISTS idx_snap_sessions_connected_at ON asemon.snap_sessions (connected_at);
CREATE INDEX IF NOT EXISTS idx_snap_sessions_usename ON asemon.snap_sessions (usename);
CREATE INDEX IF NOT EXISTS idx_snap_sessions_application_name ON asemon.snap_sessions (application_name);

-- ------------------------------------------------------------
-- Phase 2 : une ligne par exécution de requête détectée par
-- échantillonnage resserré de pg_stat_activity (1-5s), reliée à
-- la session et au queryid (pg_stat_statements).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asemon.snap_query_exec (
    id BIGSERIAL PRIMARY KEY,
    session_key TEXT NOT NULL,          -- FK logique vers snap_sessions.session_key
    query_id TEXT,                      -- query_id de pg_stat_activity / queryid de pg_stat_statements
    query_text TEXT,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,               -- déduit de la disparition de la requête au sampling suivant
    duration_ms NUMERIC,
    wait_event_type TEXT,
    wait_event TEXT,
    estimated_cpu_ms NUMERIC,           -- NULL tant que pg_stat_kcache n'est pas en place (Phase 3)
    estimated_io_bytes BIGINT
);

CREATE INDEX IF NOT EXISTS idx_snap_query_exec_session ON asemon.snap_query_exec (session_key);
CREATE INDEX IF NOT EXISTS idx_snap_query_exec_queryid ON asemon.snap_query_exec (query_id);
CREATE INDEX IF NOT EXISTS idx_snap_query_exec_started_at ON asemon.snap_query_exec (started_at);

-- ------------------------------------------------------------
-- session_key ajoutée aux tables existantes, pour permettre les
-- jointures macro → session → requête / deadlock / plan.
-- (ALTER TABLE idempotent — ADD COLUMN IF NOT EXISTS)
-- ------------------------------------------------------------
ALTER TABLE asemon.snap_activity   ADD COLUMN IF NOT EXISTS session_key TEXT;
ALTER TABLE asemon.event_plans     ADD COLUMN IF NOT EXISTS session_key TEXT;
ALTER TABLE asemon.event_deadlocks ADD COLUMN IF NOT EXISTS session_key TEXT;

CREATE INDEX IF NOT EXISTS idx_snap_activity_session_key   ON asemon.snap_activity (session_key);
CREATE INDEX IF NOT EXISTS idx_event_plans_session_key     ON asemon.event_plans (session_key);
CREATE INDEX IF NOT EXISTS idx_event_deadlocks_session_key ON asemon.event_deadlocks (session_key);

-- ------------------------------------------------------------
-- Rollup horaire pour la page macro (évite de ré-agréger les
-- snapshots bruts à chaque ouverture de dashboard).
-- À peupler par un job planifié (timer systemd ou vue matérialisée
-- rafraîchie périodiquement), pas calculé à la volée.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asemon.snap_hourly_summary (
    id BIGSERIAL PRIMARY KEY,
    hour_bucket TIMESTAMPTZ NOT NULL,   -- date_trunc('hour', collected_at)
    avg_cpu_percent NUMERIC,
    avg_mem_percent NUMERIC,
    avg_active_sessions NUMERIC,
    max_active_sessions INT,
    total_deadlocks INT,
    total_slow_queries INT,
    cache_hit_ratio NUMERIC,
    UNIQUE (hour_bucket)
);

CREATE INDEX IF NOT EXISTS idx_snap_hourly_summary_bucket ON asemon.snap_hourly_summary (hour_bucket);

-- ------------------------------------------------------------
-- Droits (cohérents avec sql/02-roles-and-grants.sql)
-- ------------------------------------------------------------
GRANT INSERT ON asemon.snap_sessions, asemon.snap_query_exec, asemon.snap_hourly_summary
    TO collector_writer;
GRANT UPDATE (disconnected_at, total_cpu_ms, total_io_bytes, query_count) ON asemon.snap_sessions
    TO collector_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA asemon TO collector_writer;

GRANT SELECT ON asemon.snap_sessions, asemon.snap_query_exec, asemon.snap_hourly_summary
    TO grafana_ro;
