# VM-Cible — Fiche technique

## Rôle

Cette VM héberge l'**instance PostgreSQL surveillée** (l'équivalent de l'ASE monitoré par ASEMON) ainsi que, à terme, le **collecteur** (script Python) et le **parseur de logs** qui envoient les métriques vers le repository de `VM-Monitoring`.

## Caractéristiques

| Paramètre | Valeur |
|---|---|
| Hyperviseur | Hyper-V (Windows 11 Pro) |
| OS | Ubuntu Server 26.04.1 LTS "Resolute Raccoon" |
| Hostname | `vmcible` |
| Utilisateur admin | `admin01` |
| RAM | 6144 Mo (fixe — mémoire dynamique **désactivée**) |
| Disque | 20-40 Go (recommandé) |
| Réseau | Commutateur virtuel `Monitoring-Switch` (type Externe), même switch que VM-Monitoring |
| IP (exemple POC) | `192.168.1.30` |
| PostgreSQL | 17.11 (dépôt PGDG) |

> Les adresses IP sont distribuées par DHCP sur le réseau local via le switch externe. Adaptez-les à votre environnement. Vérifier au redémarrage que l'IP n'a pas changé (bail DHCP) ; en cas de réinstallation de la VM, l'IP peut être réattribuée différemment.

---

## 1. Création de la VM dans Hyper-V

Suivre exactement la même procédure que pour `VM-Monitoring` (voir document `01-VM-Monitoring.md`, section 1), avec les différences suivantes :

- Nom de la VM : `VM-Cible`
- Hostname Ubuntu : `vmcible`
- Même commutateur virtuel `Monitoring-Switch` (indispensable pour que les deux VM communiquent)
- RAM : 6144 Mo fixe (mémoire dynamique désactivée dès la création, voir §1.5 du document VM-Monitoring)
- Cocher **"Install OpenSSH server"** pendant l'installation, ou l'installer après coup :
```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

### Vérification de connectivité entre les deux VM

Depuis VM-Cible :
```bash
ping -c 3 <IP_VM_MONITORING>
```
Depuis VM-Monitoring :
```bash
ping -c 3 <IP_VM_CIBLE>
```

### Mise à jour du système

```bash
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y
```

---

## 2. Installation de PostgreSQL 17 (dépôt PGDG)

```bash
sudo apt update
sudo apt install -y curl ca-certificates gnupg lsb-release

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
  sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | \
  sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update
sudo apt install -y postgresql-17 postgresql-contrib-17
```

Vérification :
```bash
sudo systemctl status postgresql@17-main
psql --version
```

---

## 3. Configuration monitoring (équivalent MDA)

Fichier à éditer :
```bash
sudo nano /etc/postgresql/17/main/postgresql.conf
```

### 3.1 Réseau

```
listen_addresses = '*'
```

### 3.2 Extensions et traçage (équivalent activation MDA)

```
shared_preload_libraries = 'pg_stat_statements,auto_explain'
track_activities = on
track_counts = on
track_io_timing = on
track_functions = all
pg_stat_statements.track = all
pg_stat_statements.max = 10000
```

### 3.3 Logs (deadlocks, verrous, requêtes lentes) au format JSON

```
logging_collector = on
log_destination = 'stderr,jsonlog'
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_lock_waits = on
deadlock_timeout = 1s
log_min_duration_statement = 500
log_checkpoints = on
log_autovacuum_min_duration = 0
```

### 3.4 auto_explain (capture des plans d'exécution)

```
auto_explain.log_min_duration = 500
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_timing = on
auto_explain.log_format = json
auto_explain.log_nested_statements = on
```

> `shared_preload_libraries` nécessite un **redémarrage complet** du service (pas un simple `reload`).

> **À compléter pour la suite du projet** (ajoutés par les phases 1 et 3, voir `07-sessions-phase1.md` et `14-kcache-phase3.md`) : `log_connections = on`, `log_disconnections = on`, `lc_messages = 'C'`, **`log_timezone = 'UTC'`** (le parseur lit les horodatages en UTC ; avec un fuseau local les lignes de log portent `CEST` et sont mal datées), et `pg_stat_kcache` dans `shared_preload_libraries`. `docs/15-installation-scriptee.md` regroupe tous ces réglages dans un seul fichier `conf.d/asemon.conf`.

### 3.5 `pg_hba.conf`

```bash
sudo nano /etc/postgresql/17/main/pg_hba.conf
```
```
# Accès collecteur / repository / administration
host    all             all             192.168.1.0/24          scram-sha-256
```

### 3.6 Redémarrage et validation

```bash
sudo systemctl restart postgresql@17-main
sudo systemctl status postgresql@17-main

sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
sudo -u postgres psql -c "SHOW shared_preload_libraries;"
```

Résultat attendu :
```
    shared_preload_libraries
---------------------------------
 pg_stat_statements,auto_explain
```

---

## 4. Utilisateur de collecte

Créé avec le rôle prédéfini `pg_monitor` (lecture des vues `pg_stat_*`, `pg_stat_activity`, `pg_stat_statements`, etc., sans droits d'administration) :

```bash
sudo -u postgres psql -c "CREATE USER asemon_collect WITH PASSWORD 'UnMotDePasseSolide';"
sudo -u postgres psql -c "GRANT pg_monitor TO asemon_collect;"
```

### Test de connexion TCP (depuis VM-Cible ou VM-Monitoring)

```bash
psql -h <IP_VM_CIBLE> -U asemon_collect -d postgres -c "SELECT current_user;"
```

Résultat attendu :
```
  current_user
----------------
 asemon_collect
```

### Test de remontée de données

```bash
sudo -u postgres psql -c "SELECT 1;"
sudo -u postgres psql -c "SELECT query, calls FROM pg_stat_statements ORDER BY calls DESC LIMIT 5;"
```

---

## 5. Génération de charge pour les tests (optionnel, recommandé)

```bash
sudo apt install -y postgresql-contrib   # fournit pgbench, déjà présent avec postgresql-contrib-17
sudo -u postgres createdb bench
sudo -u postgres pgbench -i -s 10 bench
sudo -u postgres pgbench -c 10 -j 2 -T 60 bench
```
Permet de vérifier que `pg_stat_statements`, `auto_explain` et les logs remontent effectivement de l'activité exploitable par le futur collecteur.

---

## 6. Points de vigilance rencontrés durant le POC

- **Kernel panic ("System is deadlocked on memory")** : lié à la mémoire dynamique Hyper-V. Corrigé en désactivant cette option et en fixant la RAM à 6 Go (voir document VM-Monitoring, §1.5). À faire **avant** l'installation de PostgreSQL pour éviter tout crash pendant `apt upgrade`.
- **IP changée après réinstallation** : en cas de réinstallation de la VM, l'IP attribuée par DHCP peut différer de la précédente. Toujours revérifier avec `ip a` et remettre à jour la configuration `pg_hba.conf` / les scripts du collecteur si nécessaire.
- **Service SSH absent** : si la case "Install OpenSSH server" n'est pas cochée pendant l'installeur, `systemctl status ssh` renvoie `Unit ssh.service could not be found`. Installer le paquet manuellement (§1).

---

## 7. Checklist de validation

- [ ] VM démarre avec RAM fixe, pas de kernel panic
- [ ] `ssh admin01@<IP>` fonctionne depuis l'hôte Windows
- [ ] `ping` bidirectionnel OK avec VM-Monitoring
- [ ] `sudo systemctl status postgresql@17-main` → `active (running)`
- [ ] `SHOW shared_preload_libraries` → `pg_stat_statements,auto_explain`
- [ ] Connexion TCP testée : `psql -h <IP> -U asemon_collect -d postgres`
- [ ] `pg_stat_statements` remonte des requêtes après un test de charge
- [ ] Logs JSON présents dans `/var/lib/postgresql/17/main/log/` (ou `log_directory` configuré)

---

## 8. Prochaines étapes (hors périmètre de cette fiche)

- Développement du collecteur Python (`psycopg` + `psutil`) en service `systemd`, écrivant vers le repository de `VM-Monitoring`.
- Parseur de logs JSON pour extraction des deadlocks (tables, users, requêtes impliquées) et des plans `auto_explain`.
- Modèle de données du schéma `asemon` (snapshots, événements, partitionnement, rétention).
