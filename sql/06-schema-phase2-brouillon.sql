-- ============================================================
-- ASEMON-PG — Tables des phases 2 et suivantes (BROUILLON)
-- (voir docs/06-roadmap-ihm.md)
--
-- STATUT : NON DÉPLOYÉ, à relire et adapter avant toute exécution.
-- Extrait de l'ancienne version de 05-schema-sessions.sql lors du
-- découpage de la Phase 1. Dépend de 05-schema-sessions.sql
-- (session_key = session_id natif de PostgreSQL, voir ce fichier).
--
-- À exécuter (une fois validé) sur VM-Monitoring, base `monitoring` :
--   sudo -u postgres psql -d monitoring -f 06-schema-phase2-brouillon.sql
-- ============================================================

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
GRANT INSERT ON asemon.snap_query_exec, asemon.snap_hourly_summary TO collector_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA asemon TO collector_writer;

GRANT SELECT ON asemon.snap_query_exec, asemon.snap_hourly_summary TO grafana_ro;
