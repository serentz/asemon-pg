-- ============================================================
-- monAp_pg Release 4a : plusieurs instances supervisées (étape 1/2 : ajout, sans rupture)
--
-- Ce fichier est REJOUABLE et ne casse rien : les agents (collecteur, échantillonneur,
-- parseur de logs) de l'ancienne version continuent d'écrire (instance_id vaut 1 par
-- défaut). Il faut l'exécuter en autocommit (psql -d monitoring < sql/14-multi-instance.sql),
-- pas dans une transaction : CREATE INDEX CONCURRENTLY l'interdit.
--
-- Ordre de mise à jour :
--   1. ce fichier (VM-Monitoring)
--   2. nouveaux agents (VM-Cible, puis les autres machines supervisées)
--   3. sql/15-instance-id-cutover.sql, une fois TOUS les agents à jour
--
-- Ce que fait ce fichier :
--   * crée asemon.instances ; si des données existent déjà, elles deviennent l'instance 1
--     (nom « VM-Cible », modifiable : UPDATE asemon.instances SET name = '...' WHERE instance_id = 1)
--   * ajoute instance_id (NOT NULL DEFAULT 1) à toutes les tables de données : ajout instantané,
--     sans réécriture des tables
--   * remplace chaque index sur le temps par un index qui commence par instance_id
--     (CREATE INDEX CONCURRENTLY : n'empêche pas la collecte), puis supprime l'ancien
--   * rend rollup_hourly() et kcache_attr() multi-instances
-- ============================================================

-- 0. Nettoyage d'un éventuel index invalide laissé par une exécution interrompue
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT c.relname
             FROM pg_index i
             JOIN pg_class c ON c.oid = i.indexrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'asemon' AND NOT i.indisvalid AND c.relname LIKE 'ix\_%'
    LOOP
        EXECUTE format('DROP INDEX asemon.%I', r.relname);
    END LOOP;
END
$$;

-- 1. Les instances supervisées
CREATE TABLE IF NOT EXISTS asemon.instances (
    instance_id SERIAL PRIMARY KEY,
    name        TEXT        NOT NULL UNIQUE,      -- nom affiché (INSTANCE_NAME dans config.py)
    host        TEXT,                             -- adresse de l'instance (informatif)
    port        INT,
    pg_version  TEXT,
    role        TEXT        NOT NULL DEFAULT 'primary' CHECK (role IN ('primary', 'replica')),
    enabled     BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE asemon.instances IS
  'Instances PostgreSQL supervisées. Chaque agent s''enregistre au démarrage (nom = INSTANCE_NAME) et reçoit son instance_id. Toutes les tables de données portent cet identifiant : session_key et queryid ne sont uniques qu''à l''intérieur d''une instance.';

-- Les données existantes appartiennent à l'instance 1 (la VM-Cible du POC)
INSERT INTO asemon.instances (instance_id, name)
SELECT 1, 'VM-Cible'
WHERE NOT EXISTS (SELECT 1 FROM asemon.instances)
  AND EXISTS (SELECT 1 FROM asemon.snap_os LIMIT 1)
ON CONFLICT DO NOTHING;
SELECT setval(pg_get_serial_sequence('asemon.instances', 'instance_id'),
              GREATEST((SELECT COALESCE(max(instance_id), 0) FROM asemon.instances), 1),
              (SELECT count(*) > 0 FROM asemon.instances));

-- 2. Colonne instance_id sur toutes les tables de données (pas de clé étrangère : elle ralentirait
--    inutilement les écritures ; la cohérence est assurée par l'enregistrement des agents)
ALTER TABLE asemon.snap_activity      ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_locks         ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_io            ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_os            ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_statements    ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_tables        ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_indexes       ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_checkpoints   ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_wal           ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_db_age        ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_connections   ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_sessions      ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_hourly_summary ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_samples       ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_kcache        ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_db_size       ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.snap_table_size    ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.event_deadlocks    ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.event_plans        ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;
ALTER TABLE asemon.query_text         ADD COLUMN IF NOT EXISTS instance_id INT NOT NULL DEFAULT 1;

-- 3. Index : tous commencent par instance_id (les requêtes des dashboards filtrent d'abord
--    sur l'instance, puis sur la période). Création CONCURRENTLY, puis suppression de l'ancien.
--    Les noms ix_* distinguent les nouveaux index des anciens idx_*.

-- Snapshots à horodatage collected_at
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_activity_time    ON asemon.snap_activity    (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_locks_time       ON asemon.snap_locks       (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_io_time          ON asemon.snap_io          (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_os_time          ON asemon.snap_os          (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_statements_time  ON asemon.snap_statements  (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_tables_time      ON asemon.snap_tables      (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_indexes_time     ON asemon.snap_indexes     (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_checkpoints_time ON asemon.snap_checkpoints (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_wal_time         ON asemon.snap_wal         (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_db_age_time      ON asemon.snap_db_age      (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_connections_time ON asemon.snap_connections (instance_id, collected_at);

-- Liens session / requête
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_activity_session ON asemon.snap_activity    (instance_id, session_key);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_statements_query ON asemon.snap_statements  (instance_id, queryid, collected_at DESC);

-- Événements
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_event_deadlocks_time    ON asemon.event_deadlocks (instance_id, occurred_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_event_deadlocks_session ON asemon.event_deadlocks (instance_id, session_key);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_event_plans_time        ON asemon.event_plans     (instance_id, occurred_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_event_plans_session     ON asemon.event_plans     (instance_id, session_key);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_event_plans_query       ON asemon.event_plans     (instance_id, query_id);

-- Sessions (unicité par instance ; l'ancienne unicité sur session_key seule est retirée par sql/15)
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_sessions_key   ON asemon.snap_sessions (instance_id, session_key);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_sessions_connected    ON asemon.snap_sessions (instance_id, connected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_sessions_usename      ON asemon.snap_sessions (instance_id, usename);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_sessions_application  ON asemon.snap_sessions (instance_id, application_name);

-- Résumé horaire et texte des requêtes (unicité par instance)
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_hourly_summary_key ON asemon.snap_hourly_summary (instance_id, hour_bucket);
CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS ix_query_text_key          ON asemon.query_text (instance_id, queryid);

-- CPU / I/O par requête
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_kcache_time  ON asemon.snap_kcache (instance_id, sampled_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_kcache_query ON asemon.snap_kcache (instance_id, queryid, sampled_at);

-- Capacity planning
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_db_size_db_time ON asemon.snap_db_size (instance_id, datname, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_db_size_time    ON asemon.snap_db_size (instance_id, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_table_size_obj_time
    ON asemon.snap_table_size (instance_id, datname, schemaname, relname, collected_at);
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_snap_table_size_time ON asemon.snap_table_size (instance_id, collected_at);

-- Échantillons (table partitionnée : CONCURRENTLY n'existe pas pour les tables partitionnées ;
-- chaque partition est petite, le verrou est bref)
CREATE INDEX IF NOT EXISTS ix_snap_samples_time    ON asemon.snap_samples (instance_id, sampled_at);
CREATE INDEX IF NOT EXISTS ix_snap_samples_session ON asemon.snap_samples (instance_id, session_key);
CREATE INDEX IF NOT EXISTS ix_snap_samples_query   ON asemon.snap_samples (instance_id, query_id);

-- Suppression des anciens index (remplacés ci-dessus)
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_activity_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_locks_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_io_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_os_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_statements_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_tables_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_indexes_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_checkpoints_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_wal_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_db_age_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_connections_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_activity_session_key;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_statements_queryid;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_event_deadlocks_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_event_deadlocks_session_key;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_event_plans_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_event_plans_session_key;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_event_plans_queryid;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_sessions_connected_at;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_sessions_usename;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_sessions_application_name;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_hourly_summary_bucket;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_kcache_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_kcache_queryid;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_db_size_db_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_db_size_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_table_size_obj_time;
DROP INDEX CONCURRENTLY IF EXISTS asemon.idx_snap_table_size_time;
DROP INDEX IF EXISTS asemon.idx_snap_samples_time;
DROP INDEX IF EXISTS asemon.idx_snap_samples_session;
DROP INDEX IF EXISTS asemon.idx_snap_samples_queryid;

-- 4. Droits : les agents enregistrent leur instance et lisent leur propre état
GRANT SELECT, INSERT ON asemon.instances TO collector_writer;
GRANT UPDATE (host, port, pg_version) ON asemon.instances TO collector_writer;
GRANT USAGE, SELECT ON SEQUENCE asemon.instances_instance_id_seq TO collector_writer;
GRANT SELECT ON asemon.instances TO grafana_ro;
GRANT SELECT (instance_id) ON asemon.snap_sessions, asemon.snap_db_size, asemon.snap_table_size,
                              asemon.query_text TO collector_writer;
GRANT SELECT (instance_id) ON asemon.event_plans TO collector_writer;

-- 5. Résumé horaire par instance
CREATE OR REPLACE FUNCTION asemon.rollup_hourly(p_hours INT DEFAULT 7)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_from TIMESTAMPTZ := date_trunc('hour', now(), 'UTC') - make_interval(hours => GREATEST(p_hours, 1) - 1);
    v_rows INT;
BEGIN
    WITH
    hrs AS (
        SELECT i.instance_id, g AS h
        FROM asemon.instances i
        CROSS JOIN generate_series(v_from, date_trunc('hour', now(), 'UTC'), interval '1 hour') AS g
        WHERE i.enabled
    ),
    os AS (
        SELECT instance_id, date_trunc('hour', collected_at, 'UTC') AS h,
               avg(cpu_percent) AS cpu, avg(mem_percent) AS mem
        FROM asemon.snap_os
        WHERE collected_at >= v_from
        GROUP BY 1, 2
    ),
    con AS (
        SELECT instance_id, date_trunc('hour', collected_at, 'UTC') AS h,
               avg(active_connections) AS avg_active, max(active_connections) AS max_active
        FROM asemon.snap_connections
        WHERE collected_at >= v_from
        GROUP BY 1, 2
    ),
    io_delta AS (
        SELECT instance_id, collected_at,
               blks_hit  - lag(blks_hit)  OVER w AS d_hit,
               blks_read - lag(blks_read) OVER w AS d_read
        FROM asemon.snap_io
        WHERE collected_at >= v_from - interval '1 hour'
        WINDOW w AS (PARTITION BY instance_id, datname ORDER BY collected_at)
    ),
    io AS (
        SELECT instance_id, date_trunc('hour', collected_at, 'UTC') AS h,
               sum(d_hit) AS hit, sum(d_read) AS rd
        FROM io_delta
        WHERE collected_at >= v_from AND d_hit >= 0 AND d_read >= 0
        GROUP BY 1, 2
    ),
    dl AS (
        SELECT instance_id, date_trunc('hour', occurred_at, 'UTC') AS h, count(*) AS n
        FROM asemon.event_deadlocks
        WHERE occurred_at >= v_from
        GROUP BY 1, 2
    ),
    sl AS (
        SELECT instance_id, date_trunc('hour', occurred_at, 'UTC') AS h, count(*) AS n
        FROM asemon.event_plans
        WHERE occurred_at >= v_from
        GROUP BY 1, 2
    )
    INSERT INTO asemon.snap_hourly_summary
        (instance_id, hour_bucket, avg_cpu_percent, avg_mem_percent, avg_active_sessions,
         max_active_sessions, total_deadlocks, total_slow_queries, cache_hit_ratio)
    SELECT hrs.instance_id, hrs.h,
           round(os.cpu, 2),
           round(os.mem, 2),
           round(con.avg_active, 2),
           con.max_active,
           COALESCE(dl.n, 0),
           COALESCE(sl.n, 0),
           CASE WHEN io.hit + io.rd > 0 THEN round(100.0 * io.hit / (io.hit + io.rd), 2) END
    FROM hrs
    LEFT JOIN os  ON os.instance_id  = hrs.instance_id AND os.h  = hrs.h
    LEFT JOIN con ON con.instance_id = hrs.instance_id AND con.h = hrs.h
    LEFT JOIN io  ON io.instance_id  = hrs.instance_id AND io.h  = hrs.h
    LEFT JOIN dl  ON dl.instance_id  = hrs.instance_id AND dl.h  = hrs.h
    LEFT JOIN sl  ON sl.instance_id  = hrs.instance_id AND sl.h  = hrs.h
    WHERE os.h IS NOT NULL OR con.h IS NOT NULL OR io.h IS NOT NULL
    ON CONFLICT (instance_id, hour_bucket) DO UPDATE SET
        avg_cpu_percent     = EXCLUDED.avg_cpu_percent,
        avg_mem_percent     = EXCLUDED.avg_mem_percent,
        avg_active_sessions = EXCLUDED.avg_active_sessions,
        max_active_sessions = EXCLUDED.max_active_sessions,
        total_deadlocks     = EXCLUDED.total_deadlocks,
        total_slow_queries  = EXCLUDED.total_slow_queries,
        cache_hit_ratio     = EXCLUDED.cache_hit_ratio;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;
REVOKE ALL ON FUNCTION asemon.rollup_hourly(INT) FROM PUBLIC;

-- 6. Purge : la correspondance session / activité tient compte de l'instance
CREATE OR REPLACE FUNCTION asemon.purge_old_data()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_snap  INT := asemon.setting_int('snapshot_retention_days', 30);
    v_event INT := asemon.setting_int('event_retention_days', 90);
    v_sess  INT := asemon.setting_int('session_retention_days', 90);
    v_cut   TIMESTAMPTZ;
    t       TEXT;
    n       BIGINT;
    v_out   TEXT := '';
BEGIN
    IF v_snap > 0 THEN
        v_cut := now() - make_interval(days => GREATEST(v_snap, 2));
        FOREACH t IN ARRAY ARRAY['snap_activity','snap_locks','snap_io','snap_os','snap_statements',
                                 'snap_tables','snap_indexes','snap_checkpoints','snap_wal',
                                 'snap_db_age','snap_connections'] LOOP
            EXECUTE format('DELETE FROM asemon.%I WHERE collected_at < %L', t, v_cut);
            GET DIAGNOSTICS n = ROW_COUNT;
            v_out := v_out || format('%s=%s ', t, n);
        END LOOP;
        IF to_regclass('asemon.snap_kcache') IS NOT NULL THEN
            DELETE FROM asemon.snap_kcache WHERE sampled_at < v_cut;
            GET DIAGNOSTICS n = ROW_COUNT;
            v_out := v_out || format('snap_kcache=%s ', n);
        END IF;
    ELSE
        v_out := v_out || 'snapshots=illimité ';
    END IF;
    IF v_event > 0 THEN
        v_cut := now() - make_interval(days => GREATEST(v_event, 2));
        FOREACH t IN ARRAY ARRAY['event_deadlocks','event_plans'] LOOP
            EXECUTE format('DELETE FROM asemon.%I WHERE occurred_at < %L', t, v_cut);
            GET DIAGNOSTICS n = ROW_COUNT;
            v_out := v_out || format('%s=%s ', t, n);
        END LOOP;
    ELSE
        v_out := v_out || 'événements=illimité ';
    END IF;
    IF v_sess > 0 THEN
        v_cut := now() - make_interval(days => GREATEST(v_sess, 2));
        DELETE FROM asemon.snap_sessions s
        WHERE s.disconnected_at < v_cut
           OR (s.disconnected_at IS NULL
               AND s.connected_at < v_cut
               AND NOT EXISTS (SELECT 1 FROM asemon.snap_activity a
                               WHERE a.instance_id = s.instance_id
                                 AND a.session_key = s.session_key AND a.collected_at >= v_cut));
        GET DIAGNOSTICS n = ROW_COUNT;
        v_out := v_out || format('snap_sessions=%s ', n);
    ELSE
        v_out := v_out || 'sessions=illimité ';
    END IF;
    RETURN trim(v_out);
END;
$$;
REVOKE ALL ON FUNCTION asemon.purge_old_data() FROM PUBLIC;

-- 7. Répartition du CPU et de l'I/O mesurés : p_instance NULL = toutes les instances.
--    Les appels à deux arguments (dashboards actuels) restent valides.
DROP FUNCTION IF EXISTS asemon.kcache_attr(TIMESTAMPTZ, TIMESTAMPTZ);
CREATE OR REPLACE FUNCTION asemon.kcache_attr(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_instance INT DEFAULT NULL)
RETURNS TABLE (
    sampled_at TIMESTAMPTZ, queryid BIGINT, usename TEXT, datname TEXT,
    session_key TEXT, application_name TEXT,
    cpu_ms DOUBLE PRECISION, reads_bytes DOUBLE PRECISION, writes_bytes DOUBLE PRECISION,
    is_internal BOOLEAN, instance_id INT
)
LANGUAGE sql
STABLE
AS $$
    WITH k AS (
        SELECT * FROM asemon.snap_kcache
        WHERE snap_kcache.sampled_at >= p_from AND snap_kcache.sampled_at <= p_to
          AND (p_instance IS NULL OR snap_kcache.instance_id = p_instance)
    ),
    g AS (
        SELECT k.id, k.instance_id, k.sampled_at, k.queryid, k.usename, k.datname,
               k.cpu_user_ms + k.cpu_system_ms AS cpu_ms,
               k.reads_bytes, k.writes_bytes,
               s.session_key, s.application_name,
               sum(s.interval_ms) AS ms
        FROM k
        LEFT JOIN asemon.snap_samples s
               ON s.instance_id = k.instance_id
              AND s.query_id = k.queryid
              AND s.usename = k.usename
              AND s.datname = k.datname
              AND s.sampled_at >  k.sampled_at - k.period_ms * interval '1 millisecond'
              AND s.sampled_at <= k.sampled_at
        GROUP BY k.id, k.instance_id, k.sampled_at, k.queryid, k.usename, k.datname, k.cpu_user_ms,
                 k.cpu_system_ms, k.reads_bytes, k.writes_bytes, s.session_key, s.application_name
    ),
    j AS (
        SELECT g.*, sum(g.ms) OVER (PARTITION BY g.id) AS tot_ms FROM g
    )
    SELECT j.sampled_at, j.queryid, j.usename, j.datname,
           j.session_key, j.application_name,
           j.cpu_ms * w.weight, j.reads_bytes * w.weight, j.writes_bytes * w.weight,
           (j.usename = 'asemon_collect' OR COALESCE(j.application_name, '') LIKE 'asemon-%'),
           j.instance_id
    FROM j
    CROSS JOIN LATERAL (SELECT CASE WHEN j.tot_ms IS NULL OR j.tot_ms = 0 THEN 1.0
                                    ELSE j.ms::float8 / j.tot_ms END AS weight) w
$$;
GRANT EXECUTE ON FUNCTION asemon.kcache_attr(TIMESTAMPTZ, TIMESTAMPTZ, INT) TO grafana_ro;
