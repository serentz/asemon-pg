-- ============================================================
-- monAp_pg — Release 4c : seuils d'alarme et état des instances
-- À exécuter sur VM-Monitoring, base `monitoring` (rejouable) :
--   sudo -u postgres psql -d monitoring < sql/17-thresholds.sql
-- Dépend de sql/14 (instances, instance_id) et de sql/08 (setting_int).
--
-- Contenu :
--   kpi_catalog       les indicateurs (clé, libellé, unité, sens)         [fixe]
--   kpi_thresholds    seuils d'avertissement et d'alarme, par instance     [modifiable]
--   kpi_values        valeur de chaque indicateur toutes les 5 minutes
--   compute_kpi_values()  calcule kpi_values (appelée par asemon-rollup.timer)
--   v_kpi_status      état de chaque indicateur de chaque instance
--   v_instance_status l'indicateur le plus problématique de chaque instance
--   set_threshold() / reset_threshold()  seuls points d'écriture, pour Grafana
--   grafana_thresholds  rôle de la page de modification (EXECUTE sur ces 2 fonctions, rien d'autre)
-- ============================================================

-- 1. Les indicateurs. Le sens est fixe : 'high' = trop haut est mauvais, 'low' = trop bas est mauvais.
CREATE TABLE IF NOT EXISTS asemon.kpi_catalog (
    kpi        TEXT PRIMARY KEY,
    label      TEXT NOT NULL,
    unit       TEXT NOT NULL,
    direction  TEXT NOT NULL CHECK (direction IN ('high', 'low')),
    sort_order INT  NOT NULL DEFAULT 0
);
INSERT INTO asemon.kpi_catalog (kpi, label, unit, direction, sort_order) VALUES
    ('cpu_pct',        'CPU de la machine (pic)',                  '%', 'high', 1),
    ('disk_free_pct',  'Espace disque libre',                      '%', 'low',  2),
    ('lock_wait_s',    'Attente de verrou la plus longue',         's', 'high', 3),
    ('longest_xact_s', 'Transaction la plus longue',               's', 'high', 4),
    ('deadlocks',      'Deadlocks sur la dernière heure',          '',  'high', 5),
    ('active_xacts',   'Transactions ouvertes en même temps (max)', '',  'high', 6)
ON CONFLICT (kpi) DO UPDATE
    SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
        sort_order = EXCLUDED.sort_order;

-- 2. Les seuils. instance_id NULL = valeur par défaut de toutes les instances ;
--    une valeur = surcharge pour cette instance seulement.
CREATE TABLE IF NOT EXISTS asemon.kpi_thresholds (
    threshold_id SERIAL PRIMARY KEY,
    instance_id  INT REFERENCES asemon.instances (instance_id) ON DELETE CASCADE,
    kpi          TEXT NOT NULL REFERENCES asemon.kpi_catalog (kpi),
    warn_value   DOUBLE PRECISION NOT NULL,
    crit_value   DOUBLE PRECISION NOT NULL,
    enabled      BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by   TEXT NOT NULL DEFAULT session_user
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_kpi_thresholds
    ON asemon.kpi_thresholds ((COALESCE(instance_id, 0)), kpi);
COMMENT ON TABLE asemon.kpi_thresholds IS
  'Seuils par indicateur. instance_id NULL = défaut ; sinon surcharge de cette instance. Modifier par asemon.set_threshold().';

-- Cohérence : l'alarme est « plus grave » que l'avertissement, dans le sens de l'indicateur.
CREATE OR REPLACE FUNCTION asemon.kpi_thresholds_check()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_dir TEXT;
BEGIN
    SELECT direction INTO v_dir FROM asemon.kpi_catalog WHERE kpi = NEW.kpi;
    IF v_dir = 'high' AND NEW.crit_value < NEW.warn_value THEN
        RAISE EXCEPTION 'Seuil %: l''alarme (%) doit être supérieure ou égale à l''avertissement (%)',
            NEW.kpi, NEW.crit_value, NEW.warn_value;
    ELSIF v_dir = 'low' AND NEW.crit_value > NEW.warn_value THEN
        RAISE EXCEPTION 'Seuil %: l''alarme (%) doit être inférieure ou égale à l''avertissement (%)',
            NEW.kpi, NEW.crit_value, NEW.warn_value;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_kpi_thresholds_check ON asemon.kpi_thresholds;
CREATE TRIGGER trg_kpi_thresholds_check BEFORE INSERT OR UPDATE ON asemon.kpi_thresholds
    FOR EACH ROW EXECUTE FUNCTION asemon.kpi_thresholds_check();

-- Valeurs par défaut (validées le 2026-10-09) : avertissement / alarme.
-- active_xacts n'avait pas de valeur validée : désactivé tant qu'on ne l'a pas choisie.
INSERT INTO asemon.kpi_thresholds (instance_id, kpi, warn_value, crit_value, enabled) VALUES
    (NULL, 'cpu_pct',         80,   95,   TRUE),
    (NULL, 'disk_free_pct',   20,   10,   TRUE),
    (NULL, 'lock_wait_s',     30,   120,  TRUE),
    (NULL, 'longest_xact_s',  300,  1800, TRUE),
    (NULL, 'deadlocks',       1,    5,    TRUE),
    (NULL, 'active_xacts',    20,   50,   FALSE)
ON CONFLICT ((COALESCE(instance_id, 0)), kpi) DO NOTHING;

-- 3. Les valeurs, une par instance, indicateur et tranche de 5 minutes.
CREATE TABLE IF NOT EXISTS asemon.kpi_values (
    instance_id INT NOT NULL,
    kpi         TEXT NOT NULL,
    ts          TIMESTAMPTZ NOT NULL,
    value       DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (instance_id, kpi, ts)
);

-- 4. Calcul. Fenêtre : les 5 dernières minutes (1 heure pour les deadlocks). Un indicateur sans donnée
--    (agent arrêté) n'est pas écrit : la vue d'état le signale « inconnu ». Rejouable : la tranche en cours est mise à jour.
CREATE OR REPLACE FUNCTION asemon.compute_kpi_values()
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_ts   TIMESTAMPTZ := date_bin(interval '5 minutes', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_from TIMESTAMPTZ := now() - interval '5 minutes';
    v_n    INT;
    v_ret  INT := asemon.setting_int('snapshot_retention_days', 30);
BEGIN
    -- « vivante » : l'agent a écrit dans les 5 dernières minutes. Pour les indicateurs d'événements
    -- (verrous, transactions), l'absence de ligne signifie 0 ; sans agent vivant, on n'écrit rien.
    WITH alive AS (
        SELECT DISTINCT instance_id FROM asemon.snap_os WHERE collected_at >= v_from
    ),
    lw AS (
        SELECT instance_id, max(ms) / 1000.0 AS v
        FROM (
            SELECT instance_id, session_key, query_start, sum(interval_ms)::float8 AS ms
            FROM asemon.snap_samples
            WHERE sampled_at >= v_from AND wait_event_type = 'Lock'
              AND COALESCE(application_name, '') NOT LIKE 'asemon-%'
            GROUP BY instance_id, session_key, query_start
        ) w GROUP BY instance_id
    ),
    lx AS (
        SELECT instance_id, max(extract(epoch FROM collected_at - xact_start))::float8 AS v
        FROM asemon.snap_activity
        WHERE collected_at >= v_from AND xact_start IS NOT NULL
          AND COALESCE(application_name, '') NOT LIKE 'asemon-%'
        GROUP BY instance_id
    ),
    ax AS (
        SELECT instance_id, max(n)::float8 AS v
        FROM (
            SELECT instance_id, collected_at, count(*) AS n
            FROM asemon.snap_activity
            WHERE collected_at >= v_from AND xact_start IS NOT NULL
              AND COALESCE(application_name, '') NOT LIKE 'asemon-%'
            GROUP BY instance_id, collected_at
        ) a GROUP BY instance_id
    ),
    k AS (
        SELECT instance_id, 'cpu_pct' AS kpi, max(cpu_percent)::float8 AS value
        FROM asemon.snap_os WHERE collected_at >= v_from GROUP BY instance_id
        UNION ALL
        (SELECT DISTINCT ON (instance_id) instance_id, 'disk_free_pct',
                (100.0 * disk_free_bytes / NULLIF(disk_total_bytes, 0))::float8
         FROM asemon.snap_os
         WHERE collected_at >= now() - interval '15 minutes' AND disk_total_bytes > 0
         ORDER BY instance_id, collected_at DESC)
        UNION ALL
        SELECT a.instance_id, 'lock_wait_s', COALESCE(lw.v, 0)
        FROM alive a LEFT JOIN lw USING (instance_id)
        UNION ALL
        SELECT a.instance_id, 'longest_xact_s', COALESCE(lx.v, 0)
        FROM alive a LEFT JOIN lx USING (instance_id)
        UNION ALL
        SELECT a.instance_id, 'active_xacts', COALESCE(ax.v, 0)
        FROM alive a LEFT JOIN ax USING (instance_id)
        UNION ALL
        SELECT i.instance_id, 'deadlocks',
               (SELECT count(*) FROM asemon.event_deadlocks d
                WHERE d.instance_id = i.instance_id AND d.occurred_at >= now() - interval '1 hour')::float8
        FROM asemon.instances i WHERE i.enabled
    )
    INSERT INTO asemon.kpi_values (instance_id, kpi, ts, value)
    SELECT instance_id, kpi, v_ts, value FROM k WHERE value IS NOT NULL
    ON CONFLICT (instance_id, kpi, ts) DO UPDATE SET value = EXCLUDED.value;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    -- Rétention : même durée que les snapshots
    IF v_ret > 0 THEN
        DELETE FROM asemon.kpi_values WHERE ts < now() - make_interval(days => GREATEST(v_ret, 2));
    END IF;
    RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION asemon.compute_kpi_values() FROM PUBLIC;

-- 5. État. Seuil effectif = surcharge de l'instance, sinon défaut. Dernière valeur de moins de 15 minutes,
--    sinon « unknown ». Gravité = valeur rapportée au seuil d'alarme (>= 1 : alarme) ; sert à désigner
--    l'indicateur le plus problématique d'une instance.
CREATE OR REPLACE VIEW asemon.v_kpi_status AS
WITH eff AS (
    SELECT DISTINCT ON (i.instance_id, c.kpi)
           i.instance_id, i.name AS instance_name, c.kpi, c.label, c.unit, c.direction, c.sort_order,
           t.warn_value, t.crit_value, (t.instance_id IS NOT NULL) AS is_override
    FROM asemon.instances i
    CROSS JOIN asemon.kpi_catalog c
    JOIN asemon.kpi_thresholds t
      ON t.kpi = c.kpi AND t.enabled AND (t.instance_id = i.instance_id OR t.instance_id IS NULL)
    WHERE i.enabled
    ORDER BY i.instance_id, c.kpi, (t.instance_id IS NULL)
),
last_val AS (
    SELECT DISTINCT ON (instance_id, kpi) instance_id, kpi, ts, value
    FROM asemon.kpi_values
    WHERE ts >= now() - interval '15 minutes'
    ORDER BY instance_id, kpi, ts DESC
)
SELECT e.instance_id, e.instance_name, e.kpi, e.label, e.unit, e.direction, e.sort_order,
       v.value, v.ts AS value_ts, e.warn_value, e.crit_value, e.is_override,
       CASE
           WHEN v.value IS NULL THEN 'unknown'
           WHEN e.direction = 'high' AND v.value >= e.crit_value THEN 'critical'
           WHEN e.direction = 'low'  AND v.value <= e.crit_value THEN 'critical'
           WHEN e.direction = 'high' AND v.value >= e.warn_value THEN 'warning'
           WHEN e.direction = 'low'  AND v.value <= e.warn_value THEN 'warning'
           ELSE 'ok'
       END AS state,
       CASE
           WHEN v.value IS NULL THEN NULL
           WHEN e.direction = 'high' THEN v.value / NULLIF(e.crit_value, 0)
           ELSE e.crit_value / NULLIF(v.value, 0)
       END AS severity
FROM eff e
LEFT JOIN last_val v ON v.instance_id = e.instance_id AND v.kpi = e.kpi;

-- L'indicateur le plus problématique de chaque instance (critical > warning > ok > unknown,
-- puis gravité décroissante). Une instance sans indicateur évaluable apparaît en « unknown ».
CREATE OR REPLACE VIEW asemon.v_instance_status AS
SELECT DISTINCT ON (i.instance_id)
       i.instance_id, i.name AS instance_name, i.host, i.role,
       s.kpi AS worst_kpi, s.label AS worst_label, s.unit, s.value, s.warn_value, s.crit_value,
       COALESCE(s.state, 'unknown') AS state, s.severity, s.value_ts
FROM asemon.instances i
LEFT JOIN asemon.v_kpi_status s ON s.instance_id = i.instance_id
WHERE i.enabled
ORDER BY i.instance_id,
         CASE s.state WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 WHEN 'ok' THEN 2 ELSE 3 END,
         s.severity DESC NULLS LAST, s.sort_order;

-- 6. Écriture des seuils : les seuls points d'entrée. Les fonctions s'exécutent avec les droits de leur
--    propriétaire, et vérifient tout ; le rôle de Grafana n'a aucun droit direct sur les tables.
CREATE OR REPLACE FUNCTION asemon.set_threshold(
    p_instance INT, p_kpi TEXT, p_warn DOUBLE PRECISION, p_crit DOUBLE PRECISION,
    p_enabled BOOLEAN DEFAULT TRUE, p_by TEXT DEFAULT NULL)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = asemon, pg_temp
AS $$
BEGIN
    IF p_instance IS NOT NULL AND NOT EXISTS (SELECT 1 FROM asemon.instances WHERE instance_id = p_instance) THEN
        RAISE EXCEPTION 'Instance % inconnue', p_instance;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM asemon.kpi_catalog WHERE kpi = p_kpi) THEN
        RAISE EXCEPTION 'Indicateur % inconnu', p_kpi;
    END IF;
    IF p_warn IS NULL OR p_crit IS NULL THEN
        RAISE EXCEPTION 'Les seuils d''avertissement et d''alarme sont obligatoires';
    END IF;
    INSERT INTO asemon.kpi_thresholds (instance_id, kpi, warn_value, crit_value, enabled, updated_by)
    VALUES (p_instance, p_kpi, p_warn, p_crit, COALESCE(p_enabled, TRUE), COALESCE(NULLIF(p_by, ''), session_user))
    ON CONFLICT ((COALESCE(instance_id, 0)), kpi) DO UPDATE
        SET warn_value = EXCLUDED.warn_value, crit_value = EXCLUDED.crit_value,
            enabled = EXCLUDED.enabled, updated_by = EXCLUDED.updated_by;
    RETURN format('OK %s / %s : avertissement %s, alarme %s%s',
                  COALESCE((SELECT name FROM asemon.instances WHERE instance_id = p_instance), 'défaut'),
                  p_kpi, p_warn, p_crit, CASE WHEN COALESCE(p_enabled, TRUE) THEN '' ELSE ' (désactivé)' END);
END;
$$;

-- Supprime la surcharge d'une instance (elle retrouve le défaut). Le défaut lui-même ne se supprime pas.
CREATE OR REPLACE FUNCTION asemon.reset_threshold(p_instance INT, p_kpi TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = asemon, pg_temp
AS $$
DECLARE n INT;
BEGIN
    IF p_instance IS NULL THEN
        RAISE EXCEPTION 'Le seuil par défaut ne se supprime pas : le modifier avec set_threshold()';
    END IF;
    DELETE FROM asemon.kpi_thresholds WHERE instance_id = p_instance AND kpi = p_kpi;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN CASE WHEN n = 0 THEN 'aucune surcharge à supprimer' ELSE 'surcharge supprimée : le défaut s''applique' END;
END;
$$;

-- 7. Droits
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_thresholds') THEN
        CREATE ROLE grafana_thresholds NOLOGIN;  -- connexion ouverte par : ALTER USER grafana_thresholds LOGIN PASSWORD '…'
    END IF;
END
$$;
GRANT USAGE ON SCHEMA asemon TO grafana_thresholds;
REVOKE ALL ON FUNCTION asemon.set_threshold(INT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION asemon.reset_threshold(INT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION asemon.set_threshold(INT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION, BOOLEAN, TEXT) TO grafana_thresholds;
GRANT EXECUTE ON FUNCTION asemon.reset_threshold(INT, TEXT) TO grafana_thresholds;
-- Le formulaire a besoin de lire les seuils et les instances pour se remplir
GRANT SELECT ON asemon.kpi_catalog, asemon.kpi_thresholds, asemon.instances, asemon.v_kpi_status TO grafana_thresholds;
-- Lecture pour les dashboards
GRANT SELECT ON asemon.kpi_catalog, asemon.kpi_thresholds, asemon.kpi_values,
                asemon.v_kpi_status, asemon.v_instance_status TO grafana_ro;
-- Aucune écriture directe pour les agents
REVOKE INSERT ON asemon.kpi_catalog, asemon.kpi_thresholds, asemon.kpi_values FROM collector_writer;
