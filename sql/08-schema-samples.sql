-- ============================================================
-- ASEMON-PG — Phase 2 : échantillonnage des sessions actives
-- (voir docs/09-echantillonnage-phase2.md et docs/06-roadmap-ihm.md)
--
-- Un échantillonneur (python/sampler.py, sur VM-Cible) relève toutes les
-- SAMPLE_INTERVAL secondes les sessions ACTIVES de pg_stat_activity et les
-- écrit dans asemon.snap_samples, à la manière de l'Active Session History
-- d'Oracle. La table est partitionnée par jour (UTC) : la rétention se fait
-- en supprimant des partitions entières, sans DELETE ni VACUUM.
--
-- À exécuter sur VM-Monitoring, base `monitoring` (idempotent) :
--   sudo -u postgres psql -d monitoring < 08-schema-samples.sql
-- Dépend de 05-schema-sessions.sql (session_key).
--
-- PARAMÈTRES MODIFIABLES (table asemon.settings, voir plus bas) :
--   sample_retention_days   nombre de jours d'échantillons conservés (14)
--   sample_partitions_ahead nombre de jours de partitions créées d'avance (3)
-- L'intervalle d'échantillonnage, lui, se règle côté VM-Cible dans config.py
-- (SAMPLE_INTERVAL), voir docs/09-echantillonnage-phase2.md.
-- ============================================================

-- ------------------------------------------------------------
-- Paramètres, modifiables par un simple UPDATE (pas de redémarrage) :
--   UPDATE asemon.settings SET value = '30' WHERE key = 'sample_retention_days';
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asemon.settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    description TEXT
);

INSERT INTO asemon.settings (key, value, description) VALUES
    ('sample_retention_days', '14',
     'Jours calendaires (UTC, jour en cours inclus) d''échantillons conservés dans snap_samples. Les partitions plus anciennes sont supprimées par asemon.maintain_samples().'),
    ('sample_partitions_ahead', '3',
     'Nombre de jours de partitions de snap_samples créées à l''avance (marge si la maintenance horaire est en panne).')
ON CONFLICT (key) DO NOTHING;

-- Lecture d'un paramètre entier ; valeur par défaut si absent ou invalide
-- (une faute de frappe dans settings ne doit pas bloquer la maintenance).
CREATE OR REPLACE FUNCTION asemon.setting_int(p_key TEXT, p_default INT)
RETURNS INT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v TEXT;
BEGIN
    SELECT value INTO v FROM asemon.settings WHERE key = p_key;
    IF v IS NULL THEN
        RETURN p_default;
    END IF;
    BEGIN
        RETURN v::INT;
    EXCEPTION WHEN invalid_text_representation THEN
        RAISE WARNING 'asemon.settings: % = "%" n''est pas un entier, valeur par défaut % utilisée', p_key, v, p_default;
        RETURN p_default;
    END;
END;
$$;

-- ------------------------------------------------------------
-- Échantillons de sessions actives.
--
-- Une ligne = une session active au moment de l'échantillon. Pas de ligne
-- quand rien n'est actif : le temps actif d'un groupe de lignes est donc
-- SUM(interval_ms) / 1000 secondes, et la charge moyenne sur une fenêtre de
-- W secondes vaut SUM(interval_ms) / 1000 / W (« Average Active Sessions »).
-- interval_ms est stocké sur chaque ligne : changer SAMPLE_INTERVAL ne fausse
-- donc pas l'historique.
--
-- Lecture des attentes (convention ASH) : wait_event IS NULL = la session
-- tourne sur CPU ; sinon elle attend (wait_event_type : IO, Lock, LWLock...).
-- C'est une approximation de la répartition CPU / I/O, sans extension.
--
-- Pas de texte de requête (volume) : jointure avec snap_statements sur
-- query_id pour le retrouver ; query_start identifie l'exécution dans la session.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS asemon.snap_samples (
    sampled_at TIMESTAMPTZ NOT NULL,    -- horloge de l'instance surveillée (now())
    interval_ms INT NOT NULL,           -- intervalle d'échantillonnage en vigueur
    pid INT NOT NULL,
    session_key TEXT,                   -- lien vers snap_sessions.session_key
    usename TEXT,
    datname TEXT,
    application_name TEXT,
    wait_event_type TEXT,
    wait_event TEXT,
    query_id BIGINT,                    -- NULL si compute_query_id est désactivé
    query_start TIMESTAMPTZ
) PARTITION BY RANGE (sampled_at);

-- Sur une table partitionnée, ces index sont créés automatiquement sur
-- chaque partition (existante ou future).
CREATE INDEX IF NOT EXISTS idx_snap_samples_time    ON asemon.snap_samples (sampled_at);
CREATE INDEX IF NOT EXISTS idx_snap_samples_session ON asemon.snap_samples (session_key);

-- ------------------------------------------------------------
-- asemon.maintain_samples() : crée les partitions de la veille, du jour et
-- des sample_partitions_ahead jours suivants, et supprime celles qui sortent
-- de la fenêtre de sample_retention_days jours. Idempotente, appelée toutes
-- les heures par systemd/asemon-samples-maintenance.timer.
-- Renvoie un résumé lisible (une ligne dans le journal).
--
-- ATTENTION : réduire sample_retention_days SUPPRIME les partitions plus
-- anciennes au prochain passage (au plus une heure plus tard) ; c'est
-- irréversible. Voir asemon.v_samples_partitions pour savoir ce qui existe.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION asemon.maintain_samples()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_retention INT := GREATEST(asemon.setting_int('sample_retention_days', 14), 1);
    v_ahead     INT := GREATEST(asemon.setting_int('sample_partitions_ahead', 3), 1);
    v_today     DATE := (now() AT TIME ZONE 'UTC')::DATE;
    v_day       DATE;
    v_name      TEXT;
    v_created   INT := 0;
    v_dropped   INT := 0;
    r           RECORD;
BEGIN
    FOR i IN -1 .. v_ahead LOOP
        v_day  := v_today + i;
        v_name := 'snap_samples_' || to_char(v_day, 'YYYYMMDD');
        IF to_regclass(format('asemon.%I', v_name)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE asemon.%I PARTITION OF asemon.snap_samples FOR VALUES FROM (%L) TO (%L)',
                v_name, v_day::TEXT || ' 00:00:00+00', (v_day + 1)::TEXT || ' 00:00:00+00');
            v_created := v_created + 1;
        END IF;
    END LOOP;

    FOR r IN
        SELECT c.relname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'asemon.snap_samples'::regclass
          AND c.relname ~ '^snap_samples_[0-9]{8}$'
    LOOP
        v_day := to_date(right(r.relname, 8), 'YYYYMMDD');
        IF v_day <= v_today - v_retention THEN
            EXECUTE format('DROP TABLE asemon.%I', r.relname);
            v_dropped := v_dropped + 1;
        END IF;
    END LOOP;

    RETURN format('partitions créées=%s supprimées=%s (rétention=%s j, avance=%s j)',
                  v_created, v_dropped, v_retention, v_ahead);
END;
$$;

-- ------------------------------------------------------------
-- Suivi du volume : une ligne par partition (jour, lignes estimées, taille).
--   SELECT * FROM asemon.v_samples_partitions;
-- rows_estimate vient des statistiques (approximatif, quelques minutes de retard).
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW asemon.v_samples_partitions AS
SELECT to_date(right(c.relname, 8), 'YYYYMMDD') AS day,
       c.relname::TEXT                          AS partition,
       COALESCE(s.n_live_tup, 0)                AS rows_estimate,
       pg_total_relation_size(c.oid)            AS bytes,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE i.inhparent = 'asemon.snap_samples'::regclass
ORDER BY 1;

-- ------------------------------------------------------------
-- Droits. Seul postgres (timer de maintenance) crée et supprime des
-- partitions. L'échantillonneur écrit via collector_writer, par la table
-- parente (les droits de la parente suffisent, y compris pour les partitions
-- futures). Grafana lit par la parente.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION asemon.maintain_samples() FROM PUBLIC;

GRANT INSERT ON asemon.snap_samples TO collector_writer;
GRANT SELECT ON asemon.snap_samples, asemon.v_samples_partitions, asemon.settings TO grafana_ro;

-- Première création des partitions (sinon l'échantillonneur n'aurait nulle
-- part où écrire avant le premier passage du timer).
SELECT asemon.maintain_samples();

-- Vérification après déploiement :
--   SELECT * FROM asemon.v_samples_partitions;      -- 5 partitions (veille, jour, +3)
--   SELECT * FROM asemon.settings;                  -- les deux paramètres
