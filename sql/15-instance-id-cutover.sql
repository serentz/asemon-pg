-- ============================================================
-- monAp_pg Release 4a : plusieurs instances supervisées (étape 2/2 : bascule)
--
-- À exécuter UNE FOIS, quand TOUS les agents (collecteur, échantillonneur, parseur de logs)
-- ont été mis à jour et redémarrés (ils écrivent alors instance_id explicitement), et AVANT
-- d'ajouter une deuxième instance. Rejouable.
--
--   * supprime la valeur par défaut instance_id = 1 : un agent resté dans l'ancienne version
--     est refusé (NOT NULL) au lieu d'écrire sous la mauvaise instance
--   * remplace les unicités sur session_key seul, hour_bucket seul et queryid seul par les
--     unicités par instance (créées par sql/14)
-- ============================================================
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['snap_activity','snap_locks','snap_io','snap_os','snap_statements',
                             'snap_tables','snap_indexes','snap_checkpoints','snap_wal','snap_db_age',
                             'snap_connections','snap_sessions','snap_hourly_summary','snap_samples',
                             'snap_kcache','snap_db_size','snap_table_size','event_deadlocks',
                             'event_plans','query_text'] LOOP
        EXECUTE format('ALTER TABLE asemon.%I ALTER COLUMN instance_id DROP DEFAULT', t);
    END LOOP;
END
$$;

ALTER TABLE asemon.snap_sessions        DROP CONSTRAINT IF EXISTS snap_sessions_session_key_key;
ALTER TABLE asemon.snap_hourly_summary  DROP CONSTRAINT IF EXISTS snap_hourly_summary_hour_bucket_key;
ALTER TABLE asemon.query_text           DROP CONSTRAINT IF EXISTS query_text_pkey;
