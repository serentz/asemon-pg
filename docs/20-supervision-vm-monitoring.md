# Release 4b : superviser VM-Monitoring comme deuxième instance

> **Statut : rédigé le 2026-10-15, à valider sur la VM.** Objectif : VM-Monitoring (le serveur qui héberge le repository et Grafana) est elle-même surveillée par monAp_pg, sous le nom **`VM-Monitoring`**. Les dashboards choisissent l'instance avec la liste **Instance** (4b, première partie). Procédure **manuelle** (le script `install-target.sh` n'est testé qu'en fin de projet, sur des VM neuves).

## 1. Ce qui change

| Élément | Détail |
|---|---|
| Agents sur VM-Monitoring | `collector`, `sampler` et `log_parser` tournent **sur VM-Monitoring**, se connectent à PostgreSQL en local et écrivent dans le repository en local, sous `INSTANCE_NAME = "VM-Monitoring"` |
| Redémarrage de PostgreSQL | **obligatoire** (`shared_preload_libraries` : `pg_stat_statements`, `auto_explain`, `pg_stat_kcache`). Grafana et les agents de VM-Cible sont interrompus quelques secondes ; les agents réessaient seuls |
| Bruit | les connexions de monAp_pg et de Grafana sont visibles dans leur propre supervision. Trois protections : `SAMPLE_EXCLUDE_USERS` (le sampler ignore `collector_writer` et `grafana_ro`), `sql/16-internal-users.sql` (ces logins comptent comme « internes » dans `kcache_attr`), filtres des dashboards |

Paramètre ajouté (`config.py`, facultatif, liste vide par défaut) :

| Paramètre | Rôle |
|---|---|
| `SAMPLE_EXCLUDE_USERS` | logins que `sampler.py` ne relève pas. Sur VM-Monitoring : `["collector_writer", "grafana_ro"]` |

## 2. Étapes (sur VM-Monitoring, utilisateur `admin01`)

**1. Mettre à jour le code et le schéma**

```bash
cd ~/asemon-pg && git checkout -- . && git pull
sudo -u postgres psql -d monitoring < sql/16-internal-users.sql
```
Attendu : `CREATE FUNCTION` puis `GRANT`.

**2. Installer l'extension et vérifier la configuration actuelle**

```bash
sudo apt install -y postgresql-17-pg-stat-kcache
sudo -u postgres psql -Atc "SHOW data_directory;" -c "SHOW shared_preload_libraries;" -c "SHOW lc_messages;" -c "SHOW log_timezone;" -c "SHOW log_destination;"
grep -n "include_dir" /etc/postgresql/17/main/postgresql.conf
sudo cat /var/lib/postgresql/17/main/postgresql.auto.conf
```
Noter le `data_directory` (utilisé pour `PG_DATA_DIR`). Si `postgresql.auto.conf` contient déjà `shared_preload_libraries`, **ce réglage l'emporte sur `conf.d`** : le supprimer (`ALTER SYSTEM RESET shared_preload_libraries;`) avant l'étape suivante. Si le paquet n'existe pas pour votre version, adapter `17`.

**3. Réglages PostgreSQL** (même contenu que VM-Cible, fichier `conf.d/asemon.conf`)

```bash
grep -q "^include_dir = 'conf.d'" /etc/postgresql/17/main/postgresql.conf || echo "include_dir = 'conf.d'" | sudo tee -a /etc/postgresql/17/main/postgresql.conf
sudo mkdir -p /etc/postgresql/17/main/conf.d
sudo tee /etc/postgresql/17/main/conf.d/asemon.conf >/dev/null <<'CONF'
# Géré à la main (docs/20) : supervision de VM-Monitoring par monAp_pg
shared_preload_libraries = 'pg_stat_statements,auto_explain,pg_stat_kcache'
track_activities = on
track_counts = on
track_io_timing = on
track_functions = all
pg_stat_statements.track = all
pg_stat_statements.max = 10000
logging_collector = on
log_destination = 'stderr,jsonlog'
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_lock_waits = on
deadlock_timeout = 1s
log_min_duration_statement = 500
log_checkpoints = on
log_autovacuum_min_duration = 0
log_connections = on
log_disconnections = on
lc_messages = 'C'
log_timezone = 'UTC'
auto_explain.log_min_duration = 100
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_timing = on
auto_explain.log_format = json
auto_explain.log_nested_statements = on
CONF
sudo systemctl restart postgresql
sudo -u postgres psql -Atc "SHOW shared_preload_libraries;" -c "SHOW lc_messages;" -c "SHOW log_timezone;"
```
Attendu : `pg_stat_statements,auto_explain,pg_stat_kcache`, `C`, `UTC`. Si une ligne est contredite, c'est qu'un autre fichier (`postgresql.conf`, `postgresql.auto.conf`) fixe la même option plus tard : `sudo -u postgres psql -c "SELECT name, setting, sourcefile, sourceline FROM pg_settings WHERE name IN ('shared_preload_libraries','lc_messages','log_timezone');"`.

**4. Rôle de collecte et extensions**

```bash
sed "s/CHANGEME_asemon_collect/MOT_DE_PASSE_A_CHOISIR/" sql/03-target-user.sql | sudo -u postgres psql -d postgres
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_kcache CASCADE;"
```
Attendu : `GRANT ROLE`, `CREATE EXTENSION`. Ne pas oublier de remplacer `MOT_DE_PASSE_A_CHOISIR`. Le rôle se connecte à `localhost` : la ligne par défaut de `pg_hba.conf` (`host all all 127.0.0.1/32 scram-sha-256`) suffit.

**5. Application**

```bash
ls /opt/asemon/app /opt/asemon/venv/bin/python3
```
Si `/opt/asemon` n'existe pas : `sudo mkdir -p /opt/asemon/app && sudo python3 -m venv /opt/asemon/venv && sudo /opt/asemon/venv/bin/pip install -r python/requirements.txt`. Puis :

```bash
sudo groupadd --system asemon 2>/dev/null; sudo usermod -aG asemon admin01; sudo usermod -aG asemon postgres
for f in collector.py sampler.py log_parser.py plan_format.py backfill_plans.py instance.py retention.py; do
  sudo install -m 0644 python/$f /opt/asemon/app/$f
done
sudo chmod 0755 /opt/asemon /opt/asemon/app
```
Si un `config.py` existe déjà dans `/opt/asemon/app` (utilisé par la rétention), le sauvegarder : `sudo cp /opt/asemon/app/config.py /opt/asemon/app/config.py.avant-4b`. Écrire le nouveau :

```bash
sudo tee /opt/asemon/app/config.py >/dev/null <<'CFG'
TARGET_DSN = "host=localhost dbname=postgres user=asemon_collect password=MOT_DE_PASSE_ASEMON_COLLECT"
REPO_DSN = "host=localhost dbname=monitoring user=collector_writer password=MOT_DE_PASSE_COLLECTOR_WRITER"
INTERVAL = 15
SAMPLE_INTERVAL = 2
PG_DATA_DIR = "/var/lib/postgresql/17/main"
PLAN_MAX_PER_QUERY_HOUR = 5
INSTANCE_NAME = "VM-Monitoring"
SAMPLE_EXCLUDE_USERS = ["collector_writer", "grafana_ro"]
CFG
sudo chown root:asemon /opt/asemon/app/config.py && sudo chmod 0640 /opt/asemon/app/config.py
```
(remplacer les deux mots de passe ; `collector_writer` : celui de `config.py` sur VM-Cible, ou `sudo -u postgres psql -c "ALTER USER collector_writer PASSWORD '…'"` puis le reporter sur les deux VM).

**6. Services**

```bash
for u in asemon-collector asemon-sampler asemon-logparser; do sudo cp systemd/$u.service /etc/systemd/system/; done
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-collector asemon-sampler asemon-logparser
sleep 20
systemctl is-active asemon-collector asemon-sampler asemon-logparser
```
Attendu : trois `active`. Journal : `journalctl -u asemon-collector -n 20 --no-pager` doit montrer l'enregistrement de l'instance (« instance … VM-Monitoring »).

## 3. Vérifier

```bash
sudo -u postgres psql -d monitoring -c "SELECT instance_id, name, host, pg_version, enabled FROM asemon.instances ORDER BY 1;"
sudo -u postgres psql -d monitoring -c "SELECT instance_id, count(*), max(collected_at) FROM asemon.snap_activity GROUP BY 1 ORDER BY 1;"
sudo -u postgres psql -d monitoring -c "SELECT instance_id, usename, count(*) FROM asemon.snap_samples WHERE sampled_at > now() - interval '5 minutes' GROUP BY 1,2 ORDER BY 1,3 DESC;"
```
Attendu : deux instances (`VM-Cible` = 1, `VM-Monitoring` = 2) ; des lignes récentes pour chacune ; aucun `collector_writer` ni `grafana_ro` dans les échantillons de l'instance 2.

Dans Grafana : réimporter les 6 dashboards (Dashboards → New → Import, **Overwrite**), choisir **VM-Monitoring** dans la liste Instance. Les pages Macro, Intermédiaire et Micro affichent la charge de VM-Monitoring ; VM-Cible reste inchangée.

## 4. Retour en arrière

```bash
sudo systemctl disable --now asemon-collector asemon-sampler asemon-logparser
```
Les données de l'instance 2 restent dans le repository (purgées par la rétention) ; la liste Instance continue de la proposer tant qu'elle y est. Le `conf.d/asemon.conf` peut rester (le redémarrage n'est pas à refaire).

## 5. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| `pg_stat_kcache` : `could not access file` au redémarrage | paquet absent ou mauvaise version | `apt install postgresql-<version>-pg-stat-kcache` ; vérifier avec `ls /usr/lib/postgresql/*/lib/pg_stat_kcache.so` |
| PostgreSQL ne redémarre pas | erreur dans `conf.d/asemon.conf` | `sudo journalctl -u postgresql -n 30` ; retirer la ligne fautive |
| `SHOW shared_preload_libraries` inchangé | `postgresql.auto.conf` l'emporte | `ALTER SYSTEM RESET shared_preload_libraries;` puis redémarrer |
| Le journal du parseur ne trouve pas de fichier | `PG_DATA_DIR` faux ou groupe `asemon` pas pris en compte | `SHOW data_directory`, `sudo systemctl restart asemon-logparser` |
| `password authentication failed` | mot de passe de `config.py` différent de celui du rôle | `ALTER USER … PASSWORD` puis corriger `config.py` |
| La liste Instance ne propose que `VM-Cible` | agent de VM-Monitoring pas démarré | `journalctl -u asemon-collector -n 30` |
