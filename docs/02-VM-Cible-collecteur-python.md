# VM-Cible — Collecteur Python

> Fait suite à `02-VM-Cible.md` (installation de la VM et de PostgreSQL surveillé). Ce document couvre : la création de l'utilisateur de collecte, l'environnement Python, et l'écriture/test du script collecteur.

## Prérequis

- VM-Cible opérationnelle, PostgreSQL 17 installé, extensions `pg_stat_statements`/`auto_explain` actives (voir document précédent)
- VM-Monitoring opérationnelle avec le repository prêt (voir `01-VM-Monitoring-repository-grafana.md`)
- Connectivité réseau validée entre les deux VM

Fichiers correspondants dans le dépôt :
- `sql/03-target-user.sql`
- `python/collector.py`
- `python/config.py.example`
- `python/requirements.txt`

---

## 1. Utilisateur de collecte côté instance surveillée

```bash
sudo -u postgres psql -f sql/03-target-user.sql
```

Adapter au préalable le mot de passe placeholder (`CHANGEME_asemon_collect`) dans le script. Il crée l'utilisateur `asemon_collect` avec le rôle prédéfini `pg_monitor` (lecture de toutes les vues `pg_stat_*`, sans droits d'administration) et s'assure que `pg_stat_statements` est activé.

### Test de validation

```bash
psql -h localhost -U asemon_collect -d postgres -c "SELECT current_user;"
```

> **Piège rencontré** : `FATAL: authentification par mot de passe échouée`. Vérifier que le mot de passe utilisé dans `config.py` (étape 3) correspond exactement à celui défini ici. En cas de doute, le réinitialiser :
> ```bash
> sudo -u postgres psql -c "ALTER USER asemon_collect WITH PASSWORD 'NouveauMotDePasse';"
> ```

---

## 2. Environnement Python

```bash
sudo apt update
sudo apt install -y python3-pip python3-venv

python3 -m venv ~/asemon-collector
source ~/asemon-collector/bin/activate

pip install -r python/requirements.txt
```

`requirements.txt` :
```
psycopg[binary]
psutil
```

---

## 3. Configuration du collecteur

```bash
mkdir -p ~/asemon-collector-app
cp python/collector.py ~/asemon-collector-app/
cp python/config.py.example ~/asemon-collector-app/config.py
nano ~/asemon-collector-app/config.py
```

Adapter les trois valeurs :
```python
# Instance surveillée (locale à VM-Cible)
TARGET_DSN = "host=localhost dbname=postgres user=asemon_collect password=..."

# Repository (VM-Monitoring)
REPO_DSN = "host=192.168.1.28 dbname=monitoring user=collector_writer password=..."

# Intervalle de collecte (secondes)
INTERVAL = 15
```

> **Important** : `config.py` contient des mots de passe en clair — ne pas le committer dans Git. Ajouter au `.gitignore` du dépôt :
> ```
> config.py
> ```
> Seul `config.py.example` (avec des valeurs `CHANGEME_*`) doit être versionné.

---

## 4. Ce que fait `collector.py`

Le script tourne en boucle, à intervalle fixe (`INTERVAL`) :

1. **Métriques OS** (`psutil`) : CPU, mémoire, delta lecture/écriture disque, delta envoi/réception réseau.
2. **Activité PostgreSQL** (`pg_stat_activity`) : sessions, requêtes en cours, types d'attente.
3. **Verrous** (`pg_locks` + `pg_blocking_pids()`) : chaînes de blocage reconstruites.
4. **I/O par base** (`pg_stat_database`) : lectures/écritures, deadlocks cumulés, fichiers temporaires.
5. **Top requêtes** (`pg_stat_statements`) : 100 requêtes les plus coûteuses en temps cumulé.

Chaque cycle écrit ces données dans les tables `asemon.snap_*` du repository (connexion réseau vers VM-Monitoring), avec reconnexion automatique en cas de coupure.

---

## 5. Test manuel

```bash
source ~/asemon-collector/bin/activate
cd ~/asemon-collector-app
python3 collector.py
```

Logs attendus, un cycle toutes les `INTERVAL` secondes :
```
2026-09-25 09:28:23,326 [INFO] Snapshot OK | CPU=0.0% MEM=10.9% | sessions=5 locks=0 statements=37
```

Laisser tourner quelques cycles, puis `Ctrl+C` pour arrêter.

### Vérification côté repository (sur VM-Monitoring)

```bash
sudo -u postgres psql -d monitoring -c \
  "SELECT collected_at, cpu_percent, mem_percent FROM asemon.snap_os ORDER BY collected_at DESC LIMIT 5;"
sudo -u postgres psql -d monitoring -c "SELECT count(*) FROM asemon.snap_activity;"
sudo -u postgres psql -d monitoring -c "SELECT count(*) FROM asemon.snap_statements;"
```

---

## 6. Points de vigilance rencontrés durant le POC

- **Dossier de travail inexistant** : `nano ~/asemon-collector-app/collector.py` échoue avec `No such file or directory` si `mkdir -p ~/asemon-collector-app` n'a pas été exécuté au préalable.
- **Mot de passe incohérent entre `config.py` et PostgreSQL** : provoque `psycopg.OperationalError: FATAL: authentification par mot de passe échouée`. Toujours valider le mot de passe avec un `psql -h ... -U ...` manuel avant de lancer le script.
- **Écarts de configuration réseau côté repository** : si le test échoue avec `Connection refused`, le problème est presque toujours côté VM-Monitoring (`listen_addresses`), pas côté collecteur — voir `01-VM-Monitoring-repository-grafana.md`.

---

## 7. Checklist de validation

- [ ] `asemon_collect` créé, rôle `pg_monitor` accordé, connexion locale testée
- [ ] Environnement virtuel Python créé, `psycopg`/`psutil` installés
- [ ] `config.py` renseigné avec les bons DSN (non commité dans Git)
- [ ] `python3 collector.py` tourne sans erreur, logs "Snapshot OK" réguliers
- [ ] Données visibles côté repository (`snap_os`, `snap_activity`, `snap_statements`)

---

## 8. Prochaines étapes (hors périmètre de cette fiche)

- Passage du collecteur en **service systemd** (démarrage automatique, redémarrage en cas de crash, survie au reboot)
- **Parseur de logs** JSON pour `event_deadlocks` (tables/users/requêtes impliqués) et `event_plans` (plans `auto_explain`)
- Premiers **dashboards Grafana** (vue globale CPU/IO, verrous, deadlocks, top SQL)
