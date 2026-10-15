-- ============================================================
-- monAp_pg Release 3 — Capacity planning : tables de taille
-- À appliquer sur VM-Monitoring (base monitoring), rejouable :
--
--   sudo -u postgres psql -d monitoring < sql/13-capacity.sql
--
-- Une collecte par heure (collector.py, VM-Cible) écrit :
--   asemon.snap_db_size     une ligne par base et par collecte
--   asemon.snap_table_size  une ligne par table et par collecte
-- Toutes les lignes d'une même collecte portent le même collected_at.
--
-- Rétention : python/retention.py (VM-Monitoring) garde tous les points
-- pendant capacity_full_days, puis le DERNIER point de chaque jour UTC,
-- et supprime au-delà de capacity_max_days.
--
-- PARAMÈTRES (asemon.settings) :
--   capacity_full_days  jours conservés à raison d'un point par heure   défaut 7
--   capacity_max_days   durée maximale de conservation (1 point/jour)   défaut 1095 (3 ans)
-- ============================================================

CREATE TABLE IF NOT EXISTS asemon.snap_db_size (
    id           BIGSERIAL PRIMARY KEY,
    collected_at TIMESTAMPTZ NOT NULL,
    datname      TEXT        NOT NULL,
    size_bytes   BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS asemon.snap_table_size (
    id            BIGSERIAL PRIMARY KEY,
    collected_at  TIMESTAMPTZ NOT NULL,
    datname       TEXT        NOT NULL,
    schemaname    TEXT        NOT NULL,
    relname       TEXT        NOT NULL,
    row_estimate  BIGINT      NOT NULL,   -- estimation (n_live_tup, à défaut reltuples), pas un count(*)
    table_bytes   BIGINT      NOT NULL,   -- table seule (heap)
    index_bytes   BIGINT      NOT NULL,   -- tous les index de la table
    toast_bytes   BIGINT      NOT NULL,   -- table TOAST associée
    total_bytes   BIGINT      NOT NULL,   -- pg_total_relation_size : table + index + TOAST
    index_count   INT         NOT NULL    -- nombre d'index de la table
);

-- Séries par objet (graphe, régression, réduction) et dernière collecte (tableau des plus grosses tables).
CREATE INDEX IF NOT EXISTS idx_snap_db_size_db_time
    ON asemon.snap_db_size (datname, collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_db_size_time
    ON asemon.snap_db_size (collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_table_size_obj_time
    ON asemon.snap_table_size (datname, schemaname, relname, collected_at);
CREATE INDEX IF NOT EXISTS idx_snap_table_size_time
    ON asemon.snap_table_size (collected_at);

COMMENT ON TABLE asemon.snap_db_size IS
  'Taille de chaque base, un point par heure (réduit à un point par jour après capacity_full_days par retention.py).';
COMMENT ON TABLE asemon.snap_table_size IS
  'Taille et nombre de lignes (estimé) de chaque table, un point par heure (réduit comme snap_db_size).';

INSERT INTO asemon.settings (key, value, description) VALUES
    ('capacity_full_days', '7',
     'Jours pendant lesquels snap_db_size et snap_table_size gardent un point par heure ; au-delà, un point par jour (le dernier du jour UTC).'),
    ('capacity_max_days', '1095',
     'Durée maximale de conservation de snap_db_size et snap_table_size (jours). 0 = illimité.')
ON CONFLICT (key) DO NOTHING;

-- Droits : le collecteur écrit, et relit seulement la date du dernier point (pour ne pas
-- écrire deux fois la même heure après un redémarrage). retention.py tourne sous postgres.
GRANT INSERT ON asemon.snap_db_size, asemon.snap_table_size TO collector_writer;
GRANT SELECT (collected_at) ON asemon.snap_db_size, asemon.snap_table_size TO collector_writer;
GRANT USAGE, SELECT ON SEQUENCE asemon.snap_db_size_id_seq, asemon.snap_table_size_id_seq TO collector_writer;
GRANT SELECT ON asemon.snap_db_size, asemon.snap_table_size TO grafana_ro;
