# VM-Monitoring — Repository PostgreSQL + Grafana

> Fait suite à `01-VM-Monitoring.md` (installation de la VM et de PostgreSQL). Ce document couvre : la création du repository, des rôles applicatifs, l'installation de Grafana et son raccordement.

## Prérequis

- VM-Monitoring opérationnelle, PostgreSQL 17 installé (voir document précédent)
- IP de la VM (exemple POC : `192.168.1.28`)

Fichiers SQL correspondants dans le dépôt : `sql/01-schema-asemon.sql`, `sql/02-roles-and-grants.sql`.

---

## 1. Configuration réseau de l'instance repository

**Point de vigilance rencontré lors du POC** : ne pas oublier cette étape avant de tester la connexion réseau depuis une autre VM — sans elle, PostgreSQL n'écoute que sur `localhost` même si `pg_hba.conf` autorise le sous-réseau.

```bash
sudo nano /etc/postgresql/17/main/postgresql.conf
```
Vérifier/décommenter :
```
listen_addresses = '*'
```

```bash
sudo nano /etc/postgresql/17/main/pg_hba.conf
```
Ajouter à la fin (adapter le sous-réseau) :
```
host    all             all             192.168.1.0/24          scram-sha-256
```

> **Piège rencontré** : ne pas coller cette ligne `pg_hba.conf` dans `postgresql.conf` par erreur — c'est une syntaxe invalide dans ce fichier et le service refuse de redémarrer (`Error: invalid line NNN`). En cas d'erreur au reload : `sudo journalctl -xeu postgresql@17-main --no-pager | tail -40` pour identifier la ligne fautive.

`listen_addresses` nécessite un **redémarrage complet** (pas un simple reload) :
```bash
sudo systemctl restart postgresql@17-main
sudo systemctl status postgresql@17-main
```

Vérification :
```bash
sudo -u postgres psql -c "SHOW listen_addresses;"
sudo ss -tlnp | grep 5432
```
Attendu : `*` et `0.0.0.0:5432` (ou équivalent).

---

## 2. Base repository, schéma et tables

```bash
sudo -u postgres psql -c "CREATE DATABASE monitoring;"
sudo -u postgres psql -d monitoring -f sql/01-schema-asemon.sql
```

Le script crée le schéma `asemon` et les tables suivantes :

| Table | Contenu |
|---|---|
| `asemon.snap_activity` | Snapshots de sessions (équivalent monProcessActivity) |
| `asemon.snap_locks` | Snapshots de verrous et blocages |
| `asemon.snap_io` | I/O cumulés par base (pg_stat_database) |
| `asemon.snap_os` | Métriques OS (CPU, mémoire, disque, réseau) |
| `asemon.snap_statements` | Top SQL / procédures (pg_stat_statements) |
| `asemon.event_deadlocks` | Deadlocks détaillés (alimenté par le futur parseur de logs) |
| `asemon.event_plans` | Plans d'exécution capturés (auto_explain, futur parseur de logs) |

Vérification :
```bash
sudo -u postgres psql -d monitoring -c "\dt asemon.*"
```

---

## 3. Rôles applicatifs

```bash
sudo -u postgres psql -d monitoring -f sql/02-roles-and-grants.sql
```

Adapter au préalable les mots de passe placeholder (`CHANGEME_collector`, `CHANGEME_grafana`) dans le script.

| Rôle | Usage | Droits |
|---|---|---|
| `collector_writer` | Utilisé par le collecteur (tourne sur VM-Cible) | `INSERT` sur toutes les tables du schéma `asemon` |
| `grafana_ro` | Utilisé par Grafana | `SELECT` sur toutes les tables du schéma `asemon` |

> **Piège rencontré** : un `GRANT INSERT ON ALL TABLES ...` exécuté avant que les tables existent, ou sans `GRANT USAGE ON SCHEMA`, ne suffit pas. Si un test d'insertion renvoie `ERREUR: droit refusé pour le schéma asemon`, relancer explicitement :
> ```sql
> GRANT USAGE ON SCHEMA asemon TO collector_writer;
> GRANT INSERT ON ALL TABLES IN SCHEMA asemon TO collector_writer;
> GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA asemon TO collector_writer;
> ```

### Test de validation (depuis n'importe quelle machine du réseau)

```bash
psql -h 192.168.1.28 -U collector_writer -d monitoring -c \
  "INSERT INTO asemon.snap_os (cpu_percent, mem_percent) VALUES (12.5, 34.2);"

sudo -u postgres psql -d monitoring -c "SELECT * FROM asemon.snap_os;"
```

---

## 4. Installation de Grafana

```bash
sudo apt install -y apt-transport-https software-properties-common wget

sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/grafana.gpg

echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | \
  sudo tee /etc/apt/sources.list.d/grafana.list

sudo apt update
sudo apt install -y grafana

sudo systemctl enable --now grafana-server
sudo systemctl status grafana-server
```

Accès web depuis le poste hôte :
```
http://192.168.1.28:3000
```
Identifiants par défaut : `admin` / `admin` (changement de mot de passe imposé à la première connexion).

---

## 5. Datasource PostgreSQL dans Grafana

**Connections → Data sources → Add data source → PostgreSQL**

| Champ | Valeur |
|---|---|
| Host URL | `localhost:5432` |
| Database name | `monitoring` |
| Username | `grafana_ro` |
| Password | (mot de passe défini en §3) |
| TLS/SSL Mode | `disable` (POC local — à durcir en environnement réel) |
| Version | 17 (ou Autodetect) |

Cliquer **Save & test** → message attendu : `✔ Database Connection OK`.

> **Piège rencontré** : `Validation error, invalid URL` si le champ **Host URL** contient autre chose que `host:port` strictement (ex. `http://localhost:5432`, ou un `/nom_de_base` accolé). Retaper le champ à la main plutôt que copier-coller.

---

## 6. Checklist de validation

- [ ] `listen_addresses = '*'` actif et confirmé par `SHOW listen_addresses`
- [ ] Port 5432 en écoute sur toutes les interfaces (`ss -tlnp`)
- [ ] Base `monitoring` et schéma `asemon` créés, 7 tables présentes
- [ ] `collector_writer` peut insérer depuis le réseau (test `psql -h ...`)
- [ ] `grafana_ro` peut lire (validé via "Save & test" dans Grafana)
- [ ] Grafana accessible sur `http://<IP>:3000`, mot de passe admin changé
