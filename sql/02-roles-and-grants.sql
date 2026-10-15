-- ============================================================
-- monAp_pg — Rôles et droits du repository
-- À exécuter sur VM-Monitoring, dans la base `monitoring`
-- Usage : sudo -u postgres psql -d monitoring -f 02-roles-and-grants.sql
--
-- ATTENTION : remplacer les mots de passe avant exécution en environnement réel.
-- Le script est rejouable : un rôle déjà présent est conservé tel quel (son mot
-- de passe n'est PAS modifié). Pour changer un mot de passe :
--   ALTER USER collector_writer WITH PASSWORD '...';
-- ============================================================

DO $$
BEGIN
    -- Rôle utilisé par le collecteur (tourne sur VM-Cible) pour écrire les snapshots
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'collector_writer') THEN
        CREATE USER collector_writer WITH PASSWORD 'CHANGEME_collector';
    END IF;
    -- Rôle utilisé par Grafana en lecture seule
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
        CREATE USER grafana_ro WITH PASSWORD 'CHANGEME_grafana';
    END IF;
END
$$;

-- Droits sur le schéma
GRANT USAGE ON SCHEMA asemon TO collector_writer;
GRANT USAGE ON SCHEMA asemon TO grafana_ro;

-- Droits d'écriture pour le collecteur, sur les tables existantes...
GRANT INSERT ON ALL TABLES IN SCHEMA asemon TO collector_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA asemon TO collector_writer;

-- ...et sur les futures tables créées dans le schéma (migrations ultérieures)
ALTER DEFAULT PRIVILEGES IN SCHEMA asemon GRANT INSERT ON TABLES TO collector_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA asemon GRANT USAGE, SELECT ON SEQUENCES TO collector_writer;

-- Droits de lecture pour Grafana, sur les tables existantes...
GRANT SELECT ON ALL TABLES IN SCHEMA asemon TO grafana_ro;

-- ...et sur les futures tables
ALTER DEFAULT PRIVILEGES IN SCHEMA asemon GRANT SELECT ON TABLES TO grafana_ro;

-- Release 4c : les agents n'écrivent jamais dans les seuils (la deuxième passe de ce script
-- leur donne INSERT sur toutes les tables, on le retire ici pour ces trois-là).
DO $$
BEGIN
    IF to_regclass('asemon.kpi_thresholds') IS NOT NULL THEN
        REVOKE INSERT ON asemon.kpi_catalog, asemon.kpi_thresholds, asemon.kpi_values FROM collector_writer;
    END IF;
END
$$;
