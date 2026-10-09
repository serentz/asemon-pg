-- ============================================================
-- ASEMON-PG — Phase 3 : CPU et I/O disque réels par requête (pg_stat_kcache)
-- (voir docs/14-kcache-phase3.md)
--
-- Le collecteur lit pg_stat_kcache() à chaque cycle, calcule l'écart avec le
-- cycle précédent et écrit une ligne par requête qui a consommé quelque chose
-- dans asemon.snap_kcache. La fonction asemon.kcache_attr() répartit ensuite
-- ces coûts sur les sessions et programmes d'après les échantillons de
-- snap_samples (Phase 2).
--
-- À exécuter sur VM-Monitoring, base `monitoring` (idempotent) :
--   sudo -u postgres psql -d monitoring < 11-schema-kcache.sql
-- Dépend de 08-schema-samples.sql (snap_samples).
-- ============================================================

CREATE TABLE IF NOT EXISTS asemon.snap_kcache (
    id BIGSERIAL PRIMARY KEY,
    sampled_at TIMESTAMPTZ NOT NULL,   -- instant du relevé, horloge de l'instance surveillée
    period_ms INT NOT NULL,            -- durée couverte : depuis le relevé précédent
    queryid BIGINT,                    -- même valeur que pg_stat_statements.queryid
    usename TEXT,
    datname TEXT,
    cpu_user_ms DOUBLE PRECISION NOT NULL,     -- temps CPU en mode utilisateur consommé pendant la période
    cpu_system_ms DOUBLE PRECISION NOT NULL,   -- temps CPU en mode noyau
    reads_bytes BIGINT NOT NULL,       -- octets lus sur le disque (hors cache du système)
    writes_bytes BIGINT NOT NULL       -- octets écrits (hors journal WAL)
);

CREATE INDEX IF NOT EXISTS idx_snap_kcache_time    ON asemon.snap_kcache (sampled_at);
CREATE INDEX IF NOT EXISTS idx_snap_kcache_queryid ON asemon.snap_kcache (queryid, sampled_at);

-- ------------------------------------------------------------
-- asemon.kcache_attr(p_from, p_to) : coûts mesurés, répartis sur les sessions.
--
-- pg_stat_kcache mesure par (requête, utilisateur, base), pas par session. Pour
-- chaque ligne de snap_kcache, le coût est réparti entre les échantillons
-- (snap_samples) de la même requête, du même utilisateur et de la même base
-- pris pendant la période couverte, au prorata de leur durée. Un coût sans
-- aucun échantillon correspondant (requête trop courte pour être vue) reste
-- attribué au login et à la requête, avec session_key et programme NULL
-- (« non attribué ») : le total est toujours conservé.
--
--  * Par requête et par login : mesure exacte.
--  * Par session et par programme : répartition approchée.
--  * is_internal : coûts de ASEMON-PG lui-même (login asemon_collect, programmes
--    asemon-*), à exclure des tableaux de bord.
--
-- Les bornes sont des paramètres (et non une vue filtrée après coup) pour que
-- PostgreSQL ne calcule que la période demandée.
--   SELECT * FROM asemon.kcache_attr(now() - interval '1 hour', now());
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION asemon.kcache_attr(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE (
    sampled_at TIMESTAMPTZ, queryid BIGINT, usename TEXT, datname TEXT,
    session_key TEXT, application_name TEXT,
    cpu_ms DOUBLE PRECISION, reads_bytes DOUBLE PRECISION, writes_bytes DOUBLE PRECISION,
    is_internal BOOLEAN
)
LANGUAGE sql
STABLE
AS $$
    WITH k AS (
        SELECT * FROM asemon.snap_kcache
        WHERE snap_kcache.sampled_at >= p_from AND snap_kcache.sampled_at <= p_to
    ),
    -- une ligne par (relevé, session) : durée des échantillons de la session
    g AS (
        SELECT k.id, k.sampled_at, k.queryid, k.usename, k.datname,
               k.cpu_user_ms + k.cpu_system_ms AS cpu_ms,
               k.reads_bytes, k.writes_bytes,
               s.session_key, s.application_name,
               sum(s.interval_ms) AS ms
        FROM k
        LEFT JOIN asemon.snap_samples s
               ON s.query_id = k.queryid
              AND s.usename = k.usename
              AND s.datname = k.datname
              AND s.sampled_at >  k.sampled_at - k.period_ms * interval '1 millisecond'
              AND s.sampled_at <= k.sampled_at
        GROUP BY k.id, k.sampled_at, k.queryid, k.usename, k.datname, k.cpu_user_ms,
                 k.cpu_system_ms, k.reads_bytes, k.writes_bytes, s.session_key, s.application_name
    ),
    j AS (
        SELECT g.*, sum(g.ms) OVER (PARTITION BY g.id) AS tot_ms FROM g
    )
    SELECT j.sampled_at, j.queryid, j.usename, j.datname,
           j.session_key, j.application_name,
           j.cpu_ms * w.weight, j.reads_bytes * w.weight, j.writes_bytes * w.weight,
           (j.usename = 'asemon_collect' OR COALESCE(j.application_name, '') LIKE 'asemon-%')
    FROM j
    CROSS JOIN LATERAL (SELECT CASE WHEN j.tot_ms IS NULL OR j.tot_ms = 0 THEN 1.0
                                    ELSE j.ms::float8 / j.tot_ms END AS weight) w
$$;

-- ------------------------------------------------------------
-- Droits (cohérents avec sql/02-roles-and-grants.sql)
-- ------------------------------------------------------------
GRANT INSERT ON asemon.snap_kcache TO collector_writer;
GRANT USAGE, SELECT ON SEQUENCE asemon.snap_kcache_id_seq TO collector_writer;
GRANT SELECT ON asemon.snap_kcache TO grafana_ro;
GRANT EXECUTE ON FUNCTION asemon.kcache_attr(TIMESTAMPTZ, TIMESTAMPTZ) TO grafana_ro;

-- Vérification après déploiement :
--   SELECT count(*), min(sampled_at), max(sampled_at) FROM asemon.snap_kcache;
--   SELECT usename, round(sum(cpu_ms)) AS cpu_ms, sum(reads_bytes) AS lus
--     FROM asemon.kcache_attr(now() - interval '1 hour', now()) WHERE NOT is_internal GROUP BY 1;
