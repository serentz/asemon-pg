-- ============================================================
-- ASEMON-PG — Rétention des tables de snapshots, d'événements et de sessions
-- (voir docs/10-retention.md)
--
-- asemon.purge_old_data() supprime les lignes plus anciennes que la durée
-- de rétention, par groupe de tables. Appelée une fois par jour par
-- systemd/asemon-purge.timer.
--
-- À exécuter sur VM-Monitoring, base `monitoring` (idempotent) :
--   sudo -u postgres psql -d monitoring < 09-retention.sql
-- Dépend de 08-schema-samples.sql (table asemon.settings, asemon.setting_int).
-- snap_samples a sa propre rétention (sample_retention_days) et n'est pas
-- concernée. snap_hourly_summary n'est jamais purgée (une ligne par heure).
--
-- PARAMÈTRES (table asemon.settings) :
--   snapshot_retention_days  snapshots bruts (snap_*, snap_kcache) défaut 30
--   event_retention_days     événements (deadlocks, plans)        défaut 90
--   session_retention_days   snap_sessions (sessions terminées)   défaut 90
--   Une valeur <= 0 désactive la purge du groupe (conservation illimitée).
--   Une valeur positive est ramenée à 2 jours minimum.
-- ============================================================

INSERT INTO asemon.settings (key, value, description) VALUES
    ('snapshot_retention_days', '30',
     'Jours conservés pour les snapshots bruts (snap_activity, snap_locks, snap_io, snap_os, snap_statements, snap_tables, snap_indexes, snap_checkpoints, snap_wal, snap_db_age, snap_connections). 0 = illimité.'),
    ('event_retention_days', '90',
     'Jours conservés pour les événements (event_deadlocks, event_plans). 0 = illimité.'),
    ('session_retention_days', '90',
     'Jours conservés pour snap_sessions (sessions terminées, ou ouvertes sans activité depuis ce délai). 0 = illimité.')
ON CONFLICT (key) DO NOTHING;

-- Les tables d'événements portent le lien vers snap_sessions : les purger
-- avant (90 j) ou en même temps que les sessions évite des références orphelines
-- utiles, mais aucune contrainte ne les lie (liens logiques par session_key).

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
    -- Snapshots bruts
    IF v_snap > 0 THEN
        v_cut := now() - make_interval(days => GREATEST(v_snap, 2));
        FOREACH t IN ARRAY ARRAY['snap_activity','snap_locks','snap_io','snap_os','snap_statements',
                                 'snap_tables','snap_indexes','snap_checkpoints','snap_wal',
                                 'snap_db_age','snap_connections'] LOOP
            EXECUTE format('DELETE FROM asemon.%I WHERE collected_at < %L', t, v_cut);
            GET DIAGNOSTICS n = ROW_COUNT;
            v_out := v_out || format('%s=%s ', t, n);
        END LOOP;
        -- snap_kcache (Phase 3) : horodatée par sampled_at, absente tant que
        -- 11-schema-kcache.sql n'est pas déployé.
        IF to_regclass('asemon.snap_kcache') IS NOT NULL THEN
            DELETE FROM asemon.snap_kcache WHERE sampled_at < v_cut;
            GET DIAGNOSTICS n = ROW_COUNT;
            v_out := v_out || format('snap_kcache=%s ', n);
        END IF;
    ELSE
        v_out := v_out || 'snapshots=illimité ';
    END IF;

    -- Événements
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

    -- Sessions : terminées avant la limite, ou jamais clôturées (déconnexion
    -- non vue) et sans aucun relevé d'activité depuis la limite.
    IF v_sess > 0 THEN
        v_cut := now() - make_interval(days => GREATEST(v_sess, 2));
        DELETE FROM asemon.snap_sessions s
        WHERE s.disconnected_at < v_cut
           OR (s.disconnected_at IS NULL
               AND s.connected_at < v_cut
               AND NOT EXISTS (SELECT 1 FROM asemon.snap_activity a
                               WHERE a.session_key = s.session_key AND a.collected_at >= v_cut));
        GET DIAGNOSTICS n = ROW_COUNT;
        v_out := v_out || format('snap_sessions=%s ', n);
    ELSE
        v_out := v_out || 'sessions=illimité ';
    END IF;

    RETURN trim(v_out);
END;
$$;

-- Écrit (DELETE) : seul le propriétaire (postgres, via le timer) l'appelle.
REVOKE ALL ON FUNCTION asemon.purge_old_data() FROM PUBLIC;

-- Vérification après déploiement (la première exécution peut ne rien supprimer) :
--   SELECT asemon.purge_old_data();
--   SELECT key, value FROM asemon.settings ORDER BY key;
