-- ============================================================
-- ASEMON-PG — Rollup horaire (page macro de l'IHM)
-- (voir docs/08-rollup-horaire.md et docs/06-roadmap-ihm.md)
--
-- Une ligne par heure UTC dans asemon.snap_hourly_summary, calculée
-- par asemon.rollup_hourly() à partir des snapshots bruts, pour que
-- la page macro n'agrège jamais les snapshots à la volée.
--
-- À exécuter sur VM-Monitoring, base `monitoring` (idempotent) :
--   sudo -u postgres psql -d monitoring < 06-rollup-horaire.sql
-- La fonction est ensuite appelée toutes les 5 minutes par le timer
-- systemd/asemon-rollup.timer.
-- ============================================================

CREATE TABLE IF NOT EXISTS asemon.snap_hourly_summary (
    id BIGSERIAL PRIMARY KEY,
    hour_bucket TIMESTAMPTZ NOT NULL,   -- début de l'heure, en UTC
    avg_cpu_percent NUMERIC,            -- moyenne de snap_os.cpu_percent
    avg_mem_percent NUMERIC,            -- moyenne de snap_os.mem_percent
    avg_active_sessions NUMERIC,        -- moyenne de snap_connections.active_connections
    max_active_sessions INT,            -- maximum de snap_connections.active_connections
    total_deadlocks INT,                -- nombre de lignes event_deadlocks dans l'heure
    total_slow_queries INT,             -- nombre de plans event_plans (seuil auto_explain) dans l'heure
    cache_hit_ratio NUMERIC,            -- en %, calculé sur les deltas de blks_hit / blks_read
    UNIQUE (hour_bucket)
);

CREATE INDEX IF NOT EXISTS idx_snap_hourly_summary_bucket ON asemon.snap_hourly_summary (hour_bucket);

-- ------------------------------------------------------------
-- asemon.rollup_hourly(p_hours) : (re)calcule les p_hours dernières
-- heures, heure courante incluse (défaut : 7), et renvoie le nombre
-- de lignes écrites.
--
--  * Idempotente : upsert sur hour_bucket. Rejouer la fonction, ou
--    l'appeler après l'arrivée de données en retard, corrige les lignes.
--  * L'heure courante est partielle : elle est recalculée à chaque appel.
--  * Une heure sans aucun snapshot (collecteur arrêté) ne produit pas
--    de ligne, plutôt qu'une ligne de zéros trompeuse.
--  * cache_hit_ratio : somme des deltas entre snapshots successifs, par
--    base. Un delta négatif (redémarrage de PostgreSQL, pg_stat_reset)
--    est ignoré. L'écart entre deux snapshots est rattaché à l'heure du
--    snapshot le plus récent.
--  * Rattrapage historique : SELECT asemon.rollup_hourly(24 * 30);
-- ------------------------------------------------------------
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
        SELECT g AS h
        FROM generate_series(v_from, date_trunc('hour', now(), 'UTC'), interval '1 hour') AS g
    ),
    os AS (
        SELECT date_trunc('hour', collected_at, 'UTC') AS h,
               avg(cpu_percent) AS cpu, avg(mem_percent) AS mem
        FROM asemon.snap_os
        WHERE collected_at >= v_from
        GROUP BY 1
    ),
    con AS (
        SELECT date_trunc('hour', collected_at, 'UTC') AS h,
               avg(active_connections) AS avg_active, max(active_connections) AS max_active
        FROM asemon.snap_connections
        WHERE collected_at >= v_from
        GROUP BY 1
    ),
    io_delta AS (
        -- une heure de marge en amont, pour que le premier snapshot de la
        -- fenêtre ait un précédent auquel être comparé
        SELECT collected_at,
               blks_hit  - lag(blks_hit)  OVER w AS d_hit,
               blks_read - lag(blks_read) OVER w AS d_read
        FROM asemon.snap_io
        WHERE collected_at >= v_from - interval '1 hour'
        WINDOW w AS (PARTITION BY datname ORDER BY collected_at)
    ),
    io AS (
        SELECT date_trunc('hour', collected_at, 'UTC') AS h,
               sum(d_hit) AS hit, sum(d_read) AS rd
        FROM io_delta
        WHERE collected_at >= v_from AND d_hit >= 0 AND d_read >= 0
        GROUP BY 1
    ),
    dl AS (
        SELECT date_trunc('hour', occurred_at, 'UTC') AS h, count(*) AS n
        FROM asemon.event_deadlocks
        WHERE occurred_at >= v_from
        GROUP BY 1
    ),
    sl AS (
        SELECT date_trunc('hour', occurred_at, 'UTC') AS h, count(*) AS n
        FROM asemon.event_plans
        WHERE occurred_at >= v_from
        GROUP BY 1
    )
    INSERT INTO asemon.snap_hourly_summary
        (hour_bucket, avg_cpu_percent, avg_mem_percent, avg_active_sessions,
         max_active_sessions, total_deadlocks, total_slow_queries, cache_hit_ratio)
    SELECT hrs.h,
           round(os.cpu, 2),
           round(os.mem, 2),
           round(con.avg_active, 2),
           con.max_active,
           COALESCE(dl.n, 0),
           COALESCE(sl.n, 0),
           CASE WHEN io.hit + io.rd > 0 THEN round(100.0 * io.hit / (io.hit + io.rd), 2) END
    FROM hrs
    LEFT JOIN os  ON os.h  = hrs.h
    LEFT JOIN con ON con.h = hrs.h
    LEFT JOIN io  ON io.h  = hrs.h
    LEFT JOIN dl  ON dl.h  = hrs.h
    LEFT JOIN sl  ON sl.h  = hrs.h
    WHERE os.h IS NOT NULL OR con.h IS NOT NULL OR io.h IS NOT NULL
    ON CONFLICT (hour_bucket) DO UPDATE SET
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

-- La fonction écrit dans la table : seul son propriétaire (postgres, via le
-- timer) l'appelle. Les autres rôles n'ont ni besoin ni droit de le faire.
REVOKE ALL ON FUNCTION asemon.rollup_hourly(INT) FROM PUBLIC;

GRANT SELECT ON asemon.snap_hourly_summary TO grafana_ro;

-- Vérification après déploiement :
--   SELECT asemon.rollup_hourly();
--   SELECT * FROM asemon.snap_hourly_summary ORDER BY hour_bucket DESC LIMIT 7;
