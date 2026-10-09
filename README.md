# ASEMON-PG

Preuve de concept de **supervision de PostgreSQL**, inspirée d'ASEMON (supervision Sybase ASE) : une vue qui descend de l'instance entière jusqu'à la session, puis jusqu'à la requête SQL, avec ses coûts réels (CPU, disque) et son plan d'exécution.

- Une VM **surveillée** (`VM-Cible`, PostgreSQL 17) envoie ses mesures à une VM **de supervision** (`VM-Monitoring`) qui les stocke dans un dépôt PostgreSQL et les affiche dans **Grafana**.
- Aucune solution externe : PostgreSQL, Python, systemd et Grafana.

> Les adresses (`192.168.1.28`, `192.168.1.30`), l'utilisateur `admin01` et les chemins (`/opt/asemon`) sont ceux du POC : à adapter.

## Ce que le POC permet

| Question | Où |
|---|---|
| Comment va l'instance ? (sessions, connexions, cache, deadlocks, charge machine) | Dashboard **Macro** et résumé par heure |
| Qui consomme ? (par login, par programme ; CPU réel, disque, attentes) | Dashboard **Intermédiaire** |
| Quelles sont les sessions et les requêtes les plus coûteuses ? | Dashboard **Micro** (top 10, tri au choix) |
| Que fait cette session ? Qui exécute cette requête ? Quel plan ? | Dashboards **Détail session** et **Détail requête** |
| Que s'est-il passé pendant un incident ? (deadlocks, plans lents, sessions disparues) | Tables `event_*` et `snap_sessions`, rétention de 90 jours |

## Architecture en une image

```
 VM-Cible (PostgreSQL 17 surveillé)              VM-Monitoring
┌──────────────────────────────────┐          ┌─────────────────────────────┐
│ collector   (15 s)  ─────────────┼─ INSERT ─▶ base « monitoring »         │
│ sampler     (2 s)   ─────────────┼─ INSERT ─▶   schéma asemon              │
│ log_parser  (logs)  ─────────────┼─ INSERT ─▶   (snap_*, event_*)          │
│                                  │          │        ▲ lecture seule      │
│ pg_stat_statements, auto_explain │          │        │                    │
│ pg_stat_kcache                   │          │     Grafana :3000           │
└──────────────────────────────────┘          │  timers : rollup, purge,    │
                                              │  maintenance des partitions │
                                              └─────────────────────────────┘
```

Schémas détaillés (flux, tables, clés, navigation des dashboards) : **[docs/00-architecture.md](docs/00-architecture.md)**.

## État d'avancement

| Phase | Contenu | État |
|---|---|---|
| 0 | Collecte toutes les 15 s, dashboard d'origine | Fait |
| 1 | Sessions exactes (connexion, déconnexion) via les logs ; `session_key` partout ; rollup horaire | Fait, validé |
| 2 | Échantillonnage des sessions actives toutes les 2 s ; rétention des données | Fait, validé |
| 3 | CPU et disque réels par requête (`pg_stat_kcache`) | Fait, validé (I/O réseau non mesurable) |
| 4 | Dashboards Grafana : macro, intermédiaire, micro, détails session et requête | Fait, validé |

Suites possibles : alertes Grafana, mesure du volume réel après plusieurs jours, ajustement des durées de rétention. Réflexion et historique des choix : [docs/06-roadmap-ihm.md](docs/06-roadmap-ihm.md).

## Contenu du dépôt

| Dossier | Contenu |
|---|---|
| `python/` | `collector.py` (snapshots toutes les 15 s, dont `pg_stat_kcache`), `sampler.py` (sessions actives toutes les 2 s), `log_parser.py` (connexions, deadlocks, plans), `config.py.example` |
| `sql/` | Schéma du dépôt, rôles et droits, fonctions (rollup, purge, partitions, répartition `kcache_attr`). Numérotés dans l'ordre d'application |
| `systemd/` | Services (`collector`, `sampler`, `logparser`) et timers (`rollup`, `purge`, `samples-maintenance`) |
| `grafana/` | 6 dashboards en JSON, importables |
| `scripts/` | Installation scriptée (`install-monitoring.sh`, `install-target.sh`, `grafana-provision.sh`, `verify.sh`) |
| `docs/` | Fiches d'installation et de fonctionnement, une par étape |
| `images/` | Captures et références visuelles |

`python/config.py` contient des mots de passe : il n'est **jamais** versionné (`.gitignore`). Partir de `config.py.example`.

## Installation : l'ordre à suivre

| Étape | Où | Document |
|---|---|---|
| 1. Créer VM-Monitoring, PostgreSQL 17, Grafana | VM-Monitoring | [01-VM-Monitoring](docs/01-VM-Monitoring.md), [01-…-repository-grafana](docs/01-VM-Monitoring-repository-grafana.md) |
| 2. Créer VM-Cible, PostgreSQL 17, extensions, logs JSON | VM-Cible | [02-VM-Cible](docs/02-VM-Cible.md) |
| 3. Collecteur Python | VM-Cible | [02-VM-Cible-collecteur-python](docs/02-VM-Cible-collecteur-python.md) |
| 4. Parseur de logs, déploiement dans `/opt/asemon`, services systemd | VM-Cible | [03-VM-Cible-parseur-systemd](docs/03-VM-Cible-parseur-systemd.md) |
| 5. Métriques étendues (tables, index, WAL, checkpoints…) | les deux | [04-metriques-etendues](docs/04-metriques-etendues.md) |
| 6. Dashboard d'origine | Grafana | [05-dashboard-grafana](docs/05-dashboard-grafana.md) |
| 7. Sessions exactes (`log_connections`, `lc_messages = 'C'`) | les deux | [07-sessions-phase1](docs/07-sessions-phase1.md) |
| 8. Rollup horaire | VM-Monitoring | [08-rollup-horaire](docs/08-rollup-horaire.md) |
| 9. Échantillonnage 2 s | les deux | [09-echantillonnage-phase2](docs/09-echantillonnage-phase2.md) |
| 10. Rétention | VM-Monitoring | [10-retention](docs/10-retention.md) |
| 11. `pg_stat_kcache` : extension, schéma, collecte | les deux | [14-kcache-phase3](docs/14-kcache-phase3.md) |
| 12. Dashboards macro, intermédiaire, micro | Grafana | [11](docs/11-dashboard-macro.md), [12](docs/12-dashboard-intermediaire.md), [13](docs/13-dashboard-micro.md) |
| Tout en un | les deux | [15-installation-scriptee](docs/15-installation-scriptee.md) |

**Chemin court : installation scriptée** (VM déjà créées, Ubuntu installé) : deux scripts enchaînent toutes les étapes ci-dessus, voir [docs/15-installation-scriptee.md](docs/15-installation-scriptee.md).

```bash
cp scripts/asemon.env.example scripts/asemon.env && nano scripts/asemon.env   # IP, mots de passe
sudo ./scripts/install-monitoring.sh      # d'abord, sur VM-Monitoring
sudo ./scripts/install-target.sh          # ensuite, sur VM-Cible
sudo ./scripts/verify.sh monitoring|target
```

Ordre des scripts SQL (VM-Monitoring) : `01, 02, 04, 05, 06, 08, 09, 10, 11` ; `03` sur VM-Cible ; `07` est un brouillon, **ne pas l'appliquer**. Les scripts sont rejouables. Toujours VM-Monitoring avant VM-Cible : le schéma doit exister avant que le collecteur écrive dedans.

## Réglages courants

| Je veux… | Où | Document |
|---|---|---|
| Changer l'intervalle de collecte (15 s) ou d'échantillonnage (2 s) | `/opt/asemon/app/config.py` (`INTERVAL`, `SAMPLE_INTERVAL`) puis `systemctl restart` | `09`, `14` |
| Changer la durée de conservation | `asemon.settings` (VM-Monitoring) : `sample_retention_days` 14, `snapshot_retention_days` 30, `event_retention_days` 90, `session_retention_days` 90 | `10`, `09` |
| Forcer une purge ou un rollup | `SELECT asemon.purge_old_data();` / `SELECT asemon.rollup_hourly();` | `10`, `08` |
| Voir la taille des échantillons | `SELECT * FROM asemon.v_samples_partitions;` | `09` |
| Désactiver `pg_stat_kcache` | retirer l'extension de `shared_preload_libraries` (procédure et piège dans le doc) | `14` §2 |

## Pièges déjà rencontrés

- **`lc_messages = 'C'` obligatoire** sur VM-Cible : en français, les connexions et deadlocks ne sont plus reconnus, sans aucune erreur (`07`, `03`).
- **`ALTER SYSTEM SET shared_preload_libraries`** avec plusieurs extensions : écrire `'a', 'b', 'c'` (chaque nom entre apostrophes, séparés par des virgules). Écrire `'a,b,c'` enregistre un seul nom et **le serveur ne démarre plus** (`14` §2.2).
- **`query_id`** dépasse la précision des nombres JavaScript : toujours le traiter comme du texte dans Grafana (`13`).
- **Lectures disque à 0** avec `pg_stat_kcache` : normal quand les données tiennent dans le cache du système (`14`).
- **« Part non attribuée »** dans les camemberts par programme : requêtes plus courtes que l'intervalle d'échantillonnage. Le total reste exact (`00-architecture`, §4).
- **Journal tronqué** (`journal ... is truncated, ignoring file`) : message inoffensif, filtrer avec `grep -v truncated`.

## Vocabulaire

| Terme | Sens |
|---|---|
| Snapshot | Photo périodique (15 s) de vues statistiques ; table `snap_*` |
| Échantillon | Relevé des sessions actives toutes les 2 s ; table `snap_samples` |
| `session_key` | `session_id` natif de PostgreSQL : même valeur dans les logs et dans `pg_stat_activity` |
| `query_id` | Identifiant d'une requête normalisée (le même dans toutes les sources) |
| Temps actif | Durée pendant laquelle une session exécutait quelque chose, d'après les échantillons |
| CPU mesuré | CPU réellement consommé (`pg_stat_kcache`), exact par requête et par login |
| Non attribué | Coût mesuré qu'aucun échantillon ne permet de rattacher à une session |
