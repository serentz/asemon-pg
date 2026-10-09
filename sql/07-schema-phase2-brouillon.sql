-- ============================================================
-- ASEMON-PG — Tables de la Phase 2 (BROUILLON)
-- (voir docs/06-roadmap-ihm.md)
--
-- STATUT : NON DÉPLOYÉ, à relire et adapter avant toute exécution.
-- Extrait de l'ancienne version de 05-schema-sessions.sql lors du
-- découpage de la Phase 1. Dépend de 05-schema-sessions.sql
-- (session_key = session_id natif de PostgreSQL, voir ce fichier).
-- L'échantillonnage resserré (relevé des sessions actives, rétention) est
-- réalisé par snap_samples : voir 08-schema-samples.sql et
-- docs/09-echantillonnage-phase2.md. Seule snap_query_exec reste à trancher
-- (dérivable des échantillons : une exécution = (session_key, query_start)).
-- Le rollup horaire (snap_hourly_summary) n'est plus ici : il est
-- déployable, voir 06-rollup-horaire.sql et docs/08-rollup-horaire.md.
--
-- À exécuter (une fois validé) sur VM-Monitoring, base `monitoring` :
--   sudo -u postgres psql -d monitoring < 07-schema-phase2-brouillon.sql
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
-- Droits (cohérents avec sql/02-roles-and-grants.sql)
-- ------------------------------------------------------------
GRANT INSERT ON asemon.snap_query_exec TO collector_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA asemon TO collector_writer;

GRANT SELECT ON asemon.snap_query_exec TO grafana_ro;
