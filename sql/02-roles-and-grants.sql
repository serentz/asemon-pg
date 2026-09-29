-- ============================================================
-- ASEMON-PG — Rôles et droits du repository
-- À exécuter sur VM-Monitoring, dans la base `monitoring`
-- Usage : sudo -u postgres psql -d monitoring -f 02-roles-and-grants.sql
--
-- ATTENTION : remplacer les mots de passe avant exécution en environnement réel.
-- ============================================================

-- Rôle utilisé par le collecteur (tourne sur VM-Cible) pour écrire les snapshots
CREATE USER collector_writer WITH PASSWORD 'CHANGEME_collector';

-- Rôle utilisé par Grafana en lecture seule
CREATE USER grafana_ro WITH PASSWORD 'CHANGEME_grafana';

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
