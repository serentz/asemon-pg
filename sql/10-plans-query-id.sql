-- ============================================================
-- ASEMON-PG — Lien plans / requêtes et index pour la page micro de l'IHM
-- (voir docs/13-dashboard-micro.md)
--
--  * event_plans.query_id : query_id de la requête qui a produit le plan
--    (même valeur que pg_stat_statements.queryid, pg_stat_activity.query_id
--    et snap_samples.query_id). Renseigné par log_parser.py ; NULL pour les
--    plans enregistrés avant ce changement, ou si compute_query_id est off.
--  * Index pour retrouver vite les requêtes d'une session ou les sessions
--    d'une requête, et le texte d'une requête dans snap_statements.
--
-- À exécuter sur VM-Monitoring, base `monitoring` (idempotent) :
--   sudo -u postgres psql -d monitoring < 10-plans-query-id.sql
-- Les droits existants (INSERT pour collector_writer, SELECT pour grafana_ro)
-- sont au niveau de la table : ils couvrent la nouvelle colonne.
-- ============================================================

ALTER TABLE asemon.event_plans ADD COLUMN IF NOT EXISTS query_id BIGINT;

CREATE INDEX IF NOT EXISTS idx_event_plans_queryid ON asemon.event_plans (query_id);
CREATE INDEX IF NOT EXISTS idx_snap_statements_queryid ON asemon.snap_statements (queryid, collected_at DESC);

-- Sur une table partitionnée, cet index est créé sur chaque partition.
CREATE INDEX IF NOT EXISTS idx_snap_samples_queryid ON asemon.snap_samples (query_id);

-- Vérification :
--   \d asemon.event_plans
--   SELECT occurred_at, query_id, left(query, 40) FROM asemon.event_plans ORDER BY id DESC LIMIT 5;
