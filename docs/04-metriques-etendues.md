# VM-Cible / VM-Monitoring — Extension des métriques collectées

> Fait suite à `03-VM-Cible-parseur-systemd.md` (collecteur + parseur de logs en services systemd). Ce document couvre l'ajout de métriques manquantes par rapport à une checklist de référence PostgreSQL (requêtes, mémoire/I/O, connexions/verrous, maintenance, réplication/système), suite à un audit de couverture du schéma `asemon`.

## Contexte : audit de couverture

Un audit a comparé ce qui était collecté (schéma `asemon` initial) à une checklist standard de métriques PostgreSQL. Résultat :

| Catégorie | Élément | Avant | Après |
|---|---|---|---|
| Requêtes | Requêtes lentes (`pg_stat_statements`) | ✅ | ✅ |
| Requêtes | Seq scans vs index scans | ❌ | ✅ |
| Requêtes | Fichiers temporaires | ✅ | ✅ |
| Mémoire/I/O | Cache hit ratio | ✅ (calcul Grafana) | ✅ (calcul Grafana) |
| Mémoire/I/O | Checkpoints | ❌ | ✅ |
| Connexions/verrous | Connexions vs `max_connections` | ⚠️ partiel | ✅ |
| Connexions/verrous | `idle in transaction` | ✅ | ✅ |
| Connexions/verrous | Attentes, verrous, deadlocks | ✅ | ✅ |
| Maintenance | Tuples morts / bloat | ❌ | ✅ |
| Maintenance | Âge des transactions (wraparound) | ❌ | ✅ |
| Maintenance | Index inutilisés | ❌ | ✅ |
| Réplication/système | Lag de réplication | ❌ | ❌ (pas de réplica dans ce POC) |
| Réplication/système | Volume de WAL | ❌ | ✅ |
| Réplication/système | CPU, RAM | ✅ | ✅ |
| Réplication/système | iowait, latence disque, espace disque libre | ❌ | ⚠️ iowait et espace disque ajoutés ; latence disque non retenue (nécessiterait un outil externe type `iostat`) |

Fichiers correspondants dans le dépôt :
- `sql/04-schema-extension.sql`
- `python/collector.py` (remplace la version précédente)

---

## 1. Extension du schéma

À exécuter sur **VM-Monitoring**, dans la base `monitoring` :

```bash
sudo -u postgres psql -d monitoring -f sql/04-schema-extension.sql
```

Le script est idempotent (`CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`) — il peut être rejoué sans casser l'existant.

### Nouvelles tables

| Table | Source PostgreSQL | Contenu |
|---|---|---|
| `asemon.snap_tables` | `pg_stat_user_tables` | `seq_scan`, `idx_scan`, `n_live_tup`, `n_dead_tup`, `last_autovacuum` — détecte les index manquants (seq_scan élevé sur grosse table) et le bloat |
| `asemon.snap_indexes` | `pg_stat_user_indexes` | `idx_scan` par index, taille — détecte les index jamais utilisés (`idx_scan = 0`), qui coûtent en écriture sans bénéfice |
| `asemon.snap_checkpoints` | `pg_stat_checkpointer` (PG17+) ou `pg_stat_bgwriter` (repli) | `num_timed` vs `num_requested` — trop de checkpoints demandés signale `max_wal_size` trop bas |
| `asemon.snap_wal` | `pg_stat_wal` | Volume de WAL généré (`wal_bytes`, `wal_records`) |
| `asemon.snap_db_age` | `age(datfrozenxid)` sur `pg_database` | Âge des transactions par base — surveille le risque de wraparound |
| `asemon.snap_connections` | Agrégat de `pg_stat_activity` + `pg_settings` | Connexions actives/idle/`idle in transaction` vs `max_connections` |

### Colonnes ajoutées à `asemon.snap_os`

| Colonne | Contenu |
|---|---|
| `disk_free_bytes`, `disk_total_bytes` | Espace disque libre/total sur `/` (`psutil.disk_usage`) |
| `cpu_iowait_percent` | Pourcentage de temps CPU en attente d'I/O (Linux uniquement) |

### Droits

Le script accorde automatiquement `INSERT` sur les nouvelles tables à `collector_writer` et `SELECT` à `grafana_ro`, en cohérence avec `sql/02-roles-and-grants.sql`.

---

## 2. Mise à jour de `collector.py`

Le fichier `python/collector.py` remplace intégralement la version précédente (même structure : `collect_*()` puis `write_snapshots()`). Nouvelles fonctions de collecte ajoutées :

- `collect_tables()` — `pg_stat_user_tables`
- `collect_indexes()` — `pg_stat_user_indexes` avec `pg_relation_size()` pour la taille
- `collect_checkpoints()` — tente `pg_stat_checkpointer` (PostgreSQL 17+), et se rabat automatiquement sur `pg_stat_bgwriter` si la vue n'existe pas (`psycopg.errors.UndefinedTable`), pour rester compatible avec une cible en version antérieure
- `collect_wal()` — `pg_stat_wal`
- `collect_db_age()` — âge des transactions par base
- `collect_connections()` — connexions agrégées vs `max_connections`

`collect_os_metrics()` a été étendu pour ajouter :
- `disk_free_bytes` / `disk_total_bytes` via `psutil.disk_usage("/")`
- `cpu_iowait_percent` via `psutil.cpu_times_percent(interval=None)` — l'attribut `iowait` n'existe que sous Linux ; le code utilise `getattr(..., "iowait", None)` pour ne pas planter sur un autre OS.

> **Non implémenté volontairement** : le **lag de réplication** (`pg_stat_replication`) n'a pas été ajouté car ce POC ne comporte pas de réplica. La requête resterait à zéro ligne en permanence. À ajouter dès qu'un serveur secondaire (streaming replication) est mis en place — structure prête à dupliquer sur le modèle de `collect_wal()`.
>
> La **latence disque** précise (temps de réponse moyen par I/O) n'a pas non plus été retenue : elle nécessiterait un outil de collecte système supplémentaire (`iostat`, ou lecture de `/proc/diskstats` avec calcul de delta) hors du périmètre de `psutil`. Piste pour une itération ultérieure si le besoin se confirme.

---

## 3. Déploiement

### Sur VM-Monitoring (une fois)

```bash
sudo -u postgres psql -d monitoring -f sql/04-schema-extension.sql
sudo -u postgres psql -d monitoring -c "\dt asemon.*"
```
Vérifier que les 6 nouvelles tables apparaissent, en plus des 7 existantes (13 au total).

### Sur VM-Cible

Remplacer `/opt/asemon/app/collector.py` par la nouvelle version, puis redémarrer le service :

```bash
sudo cp python/collector.py /opt/asemon/app/collector.py
sudo systemctl restart asemon-collector.service
sudo systemctl status asemon-collector.service
sudo journalctl -u asemon-collector -f
```

Les logs "Snapshot OK" incluent désormais aussi les compteurs `tables=` et `indexes=` :
```
[INFO] Snapshot OK | CPU=0.0% MEM=11.4% | sessions=5 locks=0 statements=38 tables=3 indexes=2
```

### Vérification côté repository

```bash
sudo -u postgres psql -d monitoring -c "SELECT count(*) FROM asemon.snap_tables;"
sudo -u postgres psql -d monitoring -c "SELECT count(*) FROM asemon.snap_indexes;"
sudo -u postgres psql -d monitoring -c "SELECT count(*) FROM asemon.snap_checkpoints;"
sudo -u postgres psql -d monitoring -c "SELECT count(*) FROM asemon.snap_wal;"
sudo -u postgres psql -d monitoring -c "SELECT count(*) FROM asemon.snap_db_age;"
sudo -u postgres psql -d monitoring -c "SELECT * FROM asemon.snap_connections ORDER BY collected_at DESC LIMIT 1;"
sudo -u postgres psql -d monitoring -c "SELECT disk_free_bytes, disk_total_bytes, cpu_iowait_percent FROM asemon.snap_os ORDER BY collected_at DESC LIMIT 1;"
```

---

## 4. Points de vigilance à anticiper

- **`pg_stat_checkpointer` n'existe qu'à partir de PostgreSQL 17.** Le code gère le repli automatiquement, mais si l'instance surveillée est en version antérieure, les colonnes `restartpoints_timed`/`restartpoints_req` resteront à 0 (elles n'existent pas dans `pg_stat_bgwriter`).
- **`cpu_iowait_percent` peut être `NULL`** sur un OS non-Linux (macOS, Windows) — la colonne est nullable pour cette raison, à garder en tête pour les dashboards Grafana (gérer le cas `NULL`).
- **Volumétrie accrue** : avec un intervalle de collecte de 15s, les tables `snap_tables` et `snap_indexes` grossissent proportionnellement au nombre de tables/index de la base surveillée. Sur une base avec beaucoup d'objets, envisager d'augmenter l'intervalle de collecte pour ces deux tables spécifiquement, ou de mettre en place plus tôt la politique de partitionnement/rétention déjà identifiée comme prochaine étape.

---

## 5. Checklist de validation

- [ ] `sql/04-schema-extension.sql` exécuté sur VM-Monitoring sans erreur
- [ ] 13 tables au total dans le schéma `asemon` (`\dt asemon.*`)
- [ ] `collector.py` mis à jour sur VM-Cible, service redémarré
- [ ] Logs `asemon-collector` affichent `tables=` et `indexes=` sans erreur
- [ ] Les 6 nouvelles tables contiennent des données côté repository
- [ ] `snap_os` contient des valeurs non nulles pour `disk_free_bytes`/`disk_total_bytes`, et une valeur (ou `NULL` si non-Linux, documenté) pour `cpu_iowait_percent`

---

## 6. Prochaines étapes (hors périmètre de cette fiche)

- Ajout du lag de réplication (`pg_stat_replication`) si un réplica est mis en place
- Latence disque précise (`iostat` ou `/proc/diskstats`) si le besoin se confirme
- Dashboards Grafana couvrant l'ensemble des métriques désormais collectées
- Partitionnement et rétention sur les tables `asemon.snap_*` à fort volume (`snap_tables`, `snap_indexes`, `snap_activity`)
