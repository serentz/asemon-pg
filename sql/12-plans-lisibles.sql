-- ============================================================
-- monAp_pg v2.1 — Plans d'exécution et requêtes lisibles
-- À appliquer sur VM-Monitoring (base monitoring), rejouable.
--
--   sudo -u postgres psql -d monitoring < sql/12-plans-lisibles.sql
--
--  * event_plans.plan_text : plan converti au format EXPLAIN (arbre indenté)
--  * event_plans.plan_hash : empreinte de la forme du plan (même hash = même plan)
--  * asemon.query_text     : une ligne par requête, texte d'origine et texte indenté
-- ============================================================

ALTER TABLE asemon.event_plans ADD COLUMN IF NOT EXISTS plan_text TEXT;
ALTER TABLE asemon.event_plans ADD COLUMN IF NOT EXISTS plan_hash TEXT;

CREATE TABLE IF NOT EXISTS asemon.query_text (
    queryid         BIGINT PRIMARY KEY,
    query           TEXT NOT NULL,
    query_formatted TEXT,
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE asemon.query_text IS
  'Texte SQL normalisé par queryid (écrit par le collecteur), avec version indentée pour l''affichage. Non purgée (une ligne par requête distincte, taille négligeable).';

-- Le collecteur (VM-Cible) écrit les textes ; le script de rattrapage lit et met à jour les plans.
GRANT INSERT ON asemon.query_text TO collector_writer;
GRANT SELECT ON asemon.query_text TO grafana_ro;
GRANT SELECT (id, plan, duration_ms, plan_text) ON asemon.event_plans TO collector_writer;
GRANT UPDATE (plan_text, plan_hash) ON asemon.event_plans TO collector_writer;
