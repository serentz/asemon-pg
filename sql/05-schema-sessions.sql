-- ============================================================
-- ASEMON-PG — Phase 1 : cycle de vie des sessions
-- (voir docs/06-roadmap-ihm.md et docs/07-sessions-phase1.md)
--
-- STATUT : prêt à déployer après relecture (jamais exécuté en
-- production). Les tables des phases suivantes (snap_query_exec,
-- snap_hourly_summary) sont dans 06-schema-phase2-brouillon.sql.
--
-- ORDRE DE DÉPLOIEMENT : ce script AVANT de mettre à jour
-- log_parser.py et collector.py sur VM-Cible, car les nouvelles
-- versions écrivent dans les colonnes session_key créées ici.
--
-- À exécuter sur VM-Monitoring, base `monitoring` :
--   sudo -u postgres psql -d monitoring -f 05-schema-sessions.sql
-- (idempotent : peut être rejoué sans effet de bord)
-- ============================================================

-- ------------------------------------------------------------
-- Clé de session : session_key = session_id natif de PostgreSQL,
-- au format '<epoch de début du backend en hexa>.<pid en hexa>'
-- (ex. '6ac8acf0.9bd').
--
-- Pourquoi ce format plutôt que pid || '-' || epoch(backend_start) :
--   * il figure tel quel dans CHAQUE ligne du jsonlog (champ
--     "session_id"), donc le parseur n'a rien à calculer et les
--     deadlocks / plans auto_explain sont rattachés à leur session ;
--   * côté pg_stat_activity, il se reconstruit à l'identique avec
--       to_hex(floor(extract(epoch FROM backend_start))::bigint)
--         || '.' || to_hex(pid)
--     (PostgreSQL tronque lui-même le début du backend à la seconde).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asemon.snap_sessions (
    id BIGSERIAL PRIMARY KEY,
    session_key TEXT NOT NULL,          -- session_id natif, voir ci-dessus
    pid INT,
    usename TEXT,
    application_name TEXT,
    client_addr INET,                   -- NULL pour une connexion locale (socket Unix)
    datname TEXT,
    connected_at TIMESTAMPTZ,           -- précision à la seconde (issue du session_id)
    disconnected_at TIMESTAMPTZ,        -- NULL tant que la session est ouverte
    total_cpu_ms NUMERIC,               -- agrégé a posteriori (Phase 3, pg_stat_kcache)
    total_io_bytes BIGINT,              -- agrégé a posteriori
    query_count INT,                    -- nombre de requêtes exécutées sur la session
    UNIQUE (session_key)
);

CREATE INDEX IF NOT EXISTS idx_snap_sessions_connected_at ON asemon.snap_sessions (connected_at);
CREATE INDEX IF NOT EXISTS idx_snap_sessions_usename ON asemon.snap_sessions (usename);
CREATE INDEX IF NOT EXISTS idx_snap_sessions_application_name ON asemon.snap_sessions (application_name);

-- ------------------------------------------------------------
-- session_key ajoutée aux tables existantes, pour permettre les
-- jointures macro → session → deadlock / plan / activité.
-- Les lignes déjà présentes gardent NULL (voir le rattrapage
-- optionnel plus bas pour snap_activity).
-- ------------------------------------------------------------
ALTER TABLE asemon.snap_activity   ADD COLUMN IF NOT EXISTS session_key TEXT;
ALTER TABLE asemon.event_plans     ADD COLUMN IF NOT EXISTS session_key TEXT;
ALTER TABLE asemon.event_deadlocks ADD COLUMN IF NOT EXISTS session_key TEXT;

CREATE INDEX IF NOT EXISTS idx_snap_activity_session_key   ON asemon.snap_activity (session_key);
CREATE INDEX IF NOT EXISTS idx_event_plans_session_key     ON asemon.event_plans (session_key);
CREATE INDEX IF NOT EXISTS idx_event_deadlocks_session_key ON asemon.event_deadlocks (session_key);

-- Rattrapage optionnel de l'historique de snap_activity (à lancer
-- à la main, peut être long si la table est volumineuse) :
--
-- UPDATE asemon.snap_activity
--    SET session_key = to_hex(floor(extract(epoch FROM backend_start))::bigint)
--                      || '.' || to_hex(pid)
--  WHERE session_key IS NULL AND backend_start IS NOT NULL;

-- ------------------------------------------------------------
-- Droits (cohérents avec sql/02-roles-and-grants.sql)
--
-- collector_writer reste un rôle quasi « écriture seule » :
--   * INSERT (déjà couvert par les privilèges par défaut de 02,
--     rappelé ici pour être explicite) ;
--   * UPDATE limité aux colonnes qui évoluent après coup ;
--   * SELECT limité à la seule colonne session_key : l'upsert
--     INSERT ... ON CONFLICT (session_key) en a besoin pour
--     détecter le conflit.
-- ------------------------------------------------------------
GRANT INSERT ON asemon.snap_sessions TO collector_writer;
GRANT SELECT (session_key) ON asemon.snap_sessions TO collector_writer;
GRANT UPDATE (disconnected_at, total_cpu_ms, total_io_bytes, query_count)
    ON asemon.snap_sessions TO collector_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA asemon TO collector_writer;

GRANT SELECT ON asemon.snap_sessions TO grafana_ro;

-- ------------------------------------------------------------
-- Vérification après déploiement (doit renvoyer 4 lignes, une par
-- table, avec la colonne session_key) :
--
-- SELECT table_name, column_name FROM information_schema.columns
--  WHERE table_schema = 'asemon' AND column_name = 'session_key'
--  ORDER BY table_name;
-- ------------------------------------------------------------
