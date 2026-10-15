# Release 4a : plusieurs instances supervisées

> **Statut : codée et testée en local le 2026-10-15 (PostgreSQL 16, copie d'une base de test, deux instances simulées par un mini-remplaçant de `psycopg`). À valider sur les VM.** Cette étape change le **schéma** et les **agents** ; les dashboards ne changent pas encore (étape 4b). Conception : `16-roadmap-releases.md`, §3.1 à §3.3.

## 1. Ce qui change

Jusqu'ici le repository ne connaissait qu'une instance surveillée. La Release 4 en supervise plusieurs (VM-Cible, puis VM-Monitoring, puis une réplique en Release 5). Chaque ligne du repository porte donc maintenant un **`instance_id`**.

| Élément | Changement |
|---|---|
| Table `asemon.instances` | une ligne par instance : `instance_id`, `name`, `host`, `port`, `pg_version`, `role`, `enabled` |
| 20 tables de données | colonne `instance_id` (`snap_*`, `event_*`, `snap_samples`, `snap_kcache`, `snap_sessions`, `snap_hourly_summary`, `query_text`, `snap_db_size`, `snap_table_size`). Les lignes existantes reçoivent `instance_id = 1` (« VM-Cible ») |
| Index | chaque index sur le temps **commence par `instance_id`** ; les anciens sont supprimés |
| Unicités | `session_key`, `hour_bucket` et `queryid` sont uniques **par instance** (deux serveurs peuvent produire le même `session_key`) |
| `rollup_hourly()` | une ligne par instance et par heure |
| `kcache_attr(de, à, instance)` | 3e paramètre facultatif (`NULL` = toutes les instances) ; les dashboards actuels l'appellent avec deux paramètres et continuent de marcher |
| Agents | `instance.py` (nouveau) : au démarrage, chaque agent s'enregistre sous `INSTANCE_NAME` et écrit sous son `instance_id` |
| `retention.py` | la réduction à un point par jour se fait par instance |

La collecte ne change pas (même contenu, mêmes intervalles).

## 2. Paramètres

| Paramètre | Où | Défaut | Rôle |
|---|---|---|---|
| `INSTANCE_NAME` | `config.py` (VM supervisée), `asemon.env` | `VM-Cible` | nom de **cette machine** dans les dashboards ; unique dans le repository ; lettres, chiffres, `.` `_` `-` |
| `INSTANCE_HOST` | `config.py` | hôte de `TARGET_DSN` | adresse affichée (facultatif) |

Un `config.py` existant n'a **pas besoin** de changer : sans `INSTANCE_NAME`, l'agent prend `VM-Cible`, qui est l'instance 1.

## 3. Pourquoi deux fichiers SQL

- **`sql/14-multi-instance.sql`** (étape 1) n'enlève rien : les anciens agents continuent de fonctionner, car `instance_id` vaut 1 par défaut. Il est rejouable et s'exécute en autocommit (les index sont créés `CONCURRENTLY`, sans bloquer la collecte).
- **`sql/15-instance-id-cutover.sql`** (étape 2) supprime la valeur par défaut et les anciennes unicités. À lancer **quand tous les agents sont à jour**, et avant d'ajouter une deuxième instance : un agent resté dans l'ancienne version est alors refusé au lieu d'écrire sous la mauvaise instance.

## 4. Mettre à jour un POC existant

**Dans cet ordre.** Remplacer `r4a-multi-instance` par `main` après la fusion.

**1. VM-Monitoring : schéma et rétention**

```bash
cd ~/asemon-pg && git fetch && git checkout r4a-multi-instance && git pull
sudo -u postgres psql -d monitoring < sql/14-multi-instance.sql 2>&1 | grep -E "ERROR|ERREUR" ; echo "fin (rien au-dessus = aucune erreur)"
sudo cp python/retention.py /opt/asemon/app/ && sudo chmod a+rX /opt/asemon/app/retention.py
```
Compter quelques secondes à quelques minutes selon le volume. Contrôle :
```bash
sudo -u postgres psql -d monitoring -c "SELECT * FROM asemon.instances;"
sudo -u postgres psql -d monitoring -c "SELECT count(*) AS tables_avec_instance_id FROM information_schema.columns WHERE table_schema='asemon' AND column_name='instance_id' AND table_name NOT LIKE 'snap_samples\_%';"
sudo -u postgres psql -d monitoring -c "SELECT count(*) AS index_invalides FROM pg_index WHERE NOT indisvalid;"
```
Attendu : une ligne `1 | VM-Cible`, 20 tables avec `instance_id` et 0 index invalide. Les dashboards continuent de fonctionner pendant et après cette étape.

**2. VM-Cible : agents**

```bash
cd ~/asemon-pg && git fetch && git checkout r4a-multi-instance && git pull
sudo cp python/collector.py python/sampler.py python/log_parser.py python/instance.py /opt/asemon/app/
sudo chmod a+rX /opt/asemon/app/*.py
sudo systemctl restart asemon-collector asemon-sampler asemon-logparser
sleep 20
sudo journalctl -u asemon-collector --since '-1 min' --no-pager | grep -E "Instance supervisée|Snapshot OK|ERROR" | tail -3
sudo journalctl -u asemon-sampler -u asemon-logparser --since '-1 min' --no-pager | grep -E "Instance supervisée|ERROR" | tail -4
```
Attendu : `Instance supervisée : VM-Cible (instance_id=1)` pour chacun des trois services, puis `Snapshot OK`, et aucune ligne `ERROR`.

**3. VM-Monitoring : bascule**, après avoir vu les trois services écrire (étape 2) :

```bash
sudo -u postgres psql -d monitoring < sql/15-instance-id-cutover.sql
sudo -u postgres psql -d monitoring -c "SELECT instance_id, count(*) FROM asemon.snap_os WHERE collected_at > now() - interval '5 minutes' GROUP BY 1;"
```
Attendu : une seule ligne, `1 | N` avec N qui augmente d'une minute à l'autre.

Pour revenir en arrière avant l'étape 3 : remettre l'ancienne version des fichiers Python et redémarrer les services ; le schéma de l'étape 1 est compatible avec l'ancien code.

## 5. Vérifier

```bash
sudo -u postgres psql -d monitoring -c "SELECT asemon.rollup_hourly(3);"
sudo -u postgres psql -d monitoring -c "SELECT instance_id, hour_bucket, avg_cpu_percent FROM asemon.snap_hourly_summary ORDER BY hour_bucket DESC LIMIT 3;"
sudo -u postgres psql -d monitoring -c "SELECT instance_id, count(*), max(sampled_at) FROM asemon.snap_samples GROUP BY 1;"
```
Dans Grafana, **rien ne doit avoir changé** : Macro, Intermédiaire, Micro, Détails, Capacity affichent les mêmes valeurs.

## 6. Index et performances

Tous les index commencent par `instance_id` : les requêtes des dashboards filtrent d'abord sur l'instance puis sur la période. Les anciens index sur le temps seul sont supprimés (chaque index ajouté ralentit les écritures). Pour voir quels index servent :

```sql
SELECT relname, indexrelname, idx_scan FROM pg_stat_user_indexes
WHERE schemaname = 'asemon' ORDER BY idx_scan;
```
À regarder après quelques jours d'usage : un index à `idx_scan = 0` n'est pas utilisé et peut être supprimé. `snap_samples` est partitionnée : ses index sont créés sans `CONCURRENTLY` (non disponible sur une table partitionnée), un verrou bref sur des partitions petites.

## 7. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| `Enregistrement de l'instance impossible` dans le journal d'un agent | `sql/14` pas appliqué, ou repository injoignable | appliquer `sql/14` ; l'agent réessaie toutes les 10 s |
| `null value in column "instance_id"` | `sql/15` appliqué alors qu'un agent est resté à l'ancienne version | mettre l'agent à jour (étape 2) et le redémarrer |
| `duplicate key … snap_sessions_session_key_key` avec deux instances | `sql/15` pas encore appliqué | l'appliquer (étape 3) |
| `index_invalides` > 0 | un `CREATE INDEX CONCURRENTLY` a été interrompu | rejouer `sql/14` : il supprime les index invalides puis les recrée |
