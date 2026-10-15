-- ============================================================
-- monAp_pg — Release 4b : logins internes (bruit de monAp_pg et de Grafana)
-- Quand VM-Monitoring est supervisée, ses propres connexions (agents -> collector_writer,
-- Grafana -> grafana_ro) apparaissent dans pg_stat_activity. On les classe "internes"
-- comme asemon_collect, pour qu'elles ne polluent pas les attributions CPU / I/O.
-- Idempotent (CREATE OR REPLACE, même signature qu'en sql/14).
-- ============================================================
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
           (j.usename IN ('asemon_collect', 'grafana_ro', 'collector_writer') OR COALESCE(j.application_name, '') LIKE 'asemon-%'),
           j.instance_id
    FROM j
    CROSS JOIN LATERAL (SELECT CASE WHEN j.tot_ms IS NULL OR j.tot_ms = 0 THEN 1.0
                                    ELSE j.ms::float8 / j.tot_ms END AS weight) w
$$;
GRANT EXECUTE ON FUNCTION asemon.kcache_attr(TIMESTAMPTZ, TIMESTAMPTZ, INT) TO grafana_ro;
