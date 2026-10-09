-- ============================================================
-- ASEMON-PG — Utilisateur de collecte sur l'instance surveillée
-- À exécuter sur VM-Cible, base postgres (ou toute base par défaut)
-- Usage : sudo -u postgres psql -f 03-target-user.sql
--
-- ATTENTION : remplacer le mot de passe avant exécution en environnement réel.
-- ============================================================

-- Rejouable : un rôle déjà présent est conservé (mot de passe inchangé).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'asemon_collect') THEN
        CREATE USER asemon_collect WITH PASSWORD 'CHANGEME_asemon_collect';
    END IF;
END
$$;

-- pg_monitor : rôle prédéfini PostgreSQL donnant un accès en lecture
-- à toutes les vues pg_stat_*, pg_stat_activity, pg_stat_statements, etc.
-- sans droits d'administration.
GRANT pg_monitor TO asemon_collect;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
