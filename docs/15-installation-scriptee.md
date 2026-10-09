# Installation scriptée (VM-Monitoring et VM-Cible)

> Les docs `01` à `14` décrivent chaque étape à la main, dans l'ordre où le POC s'est construit. Ce document décrit le **chemin court** : deux scripts qui enchaînent toutes ces étapes sur des VM neuves.
>
> **Statut : écrit le 2026-10-09, à valider sur des VM neuves.** Ce qui a été testé en local (PostgreSQL 16) : les scripts SQL appliqués deux fois de suite, les droits des rôles, la configuration PostgreSQL, la génération de `config.py`. Ce qui n'a **pas** pu être testé (pas de VM ni d'accès à `apt` ici) : l'installation des paquets, les unités systemd et l'appel à l'API Grafana. Au premier essai, garder le terminal ouvert et coller la sortie en cas d'erreur.

**Hors périmètre, volontairement** : la création des VM (Hyper-V : commutateur, RAM fixe, ISO) et l'installation d'Ubuntu. Voir `01-VM-Monitoring.md` §1 et `02-VM-Cible.md` §1.

---

## 1. Avant de lancer

Sur chaque VM, une fois Ubuntu installé :
- SSH fonctionnel, un compte avec `sudo` (`admin01` au POC) ;
- accès à Internet (`apt`, PyPI, dépôts PostgreSQL et Grafana) ;
- **RAM fixe** (pas de mémoire dynamique Hyper-V : kernel panic pendant les installations) ;
- IP stable pour VM-Monitoring (réservation DHCP ou IP fixe), car elle est écrite dans `config.py` de VM-Cible ;
- les deux VM se joignent (`ping`).

### Récupérer le dépôt sur la VM

Au choix, sur chaque VM :

```bash
sudo apt install -y git && git clone https://github.com/serentz/asemon-pg.git     # si le dépôt est accessible
```

ou depuis PowerShell, en copiant le dossier :

```powershell
scp -r I:\POC_ASEMON\asemon-pg admin01@192.168.1.28:~/
scp -r I:\POC_ASEMON\asemon-pg admin01@192.168.1.30:~/
```

### Le fichier de paramètres

```bash
cd ~/asemon-pg
cp scripts/asemon.env.example scripts/asemon.env
nano scripts/asemon.env
```

Les valeurs essentielles : `MONITORING_IP`, `SUBNET`, les trois mots de passe, `SERVICE_USER`. Chaque paramètre est commenté dans le fichier. Il peut être **le même sur les deux VM** (copier-le). Il n'est jamais versionné (`.gitignore`).

Mots de passe : 8 caractères minimum, lettres, chiffres et `. _ @ % + = -` seulement (ils sont recopiés dans des chaînes de connexion).

---

## 2. Installation

**Toujours VM-Monitoring en premier** : le repository doit exister avant que VM-Cible n'y écrive.

### 2.1 VM-Monitoring

```bash
cd ~/asemon-pg
sudo ./scripts/install-monitoring.sh
```

Le script :
1. installe PostgreSQL (dépôt PGDG) ;
2. écrit `conf.d/asemon.conf` (`listen_addresses = '*'`) et un bloc dans `pg_hba.conf` limité aux rôles `collector_writer` et `grafana_ro` depuis `SUBNET`, puis redémarre PostgreSQL si nécessaire ;
3. crée la base `monitoring` et applique, dans l'ordre, `sql/01`, `02`, `04`, `05`, `06`, `08`, `09`, `10`, `11` (le `07` est un brouillon : jamais appliqué) ;
4. fixe les mots de passe des rôles, repasse les droits ;
5. installe et active les trois timers (rollup 5 min, partitions 1 h, purge quotidienne) ;
6. installe Grafana ; **si `GRAFANA_ADMIN_PASSWORD` est renseigné**, définit le mot de passe admin, crée la datasource et importe les 6 dashboards (`scripts/grafana-provision.sh`, rejouable seul).

Vérification :

```bash
sudo ./scripts/verify.sh monitoring
```

### 2.2 VM-Cible

```bash
cd ~/asemon-pg
sudo ./scripts/install-target.sh
```

Le script :
1. installe PostgreSQL, `pg_stat_kcache`, Python ;
2. écrit **un seul** fichier de réglages, `conf.d/asemon.conf` : extensions, journaux JSON, `auto_explain`, `log_connections`, `lc_messages = 'C'`, `log_timezone = 'UTC'` ; **redémarre PostgreSQL** (coupure de quelques secondes) ;
3. crée le rôle `asemon_collect` et les extensions `pg_stat_statements` et `pg_stat_kcache` ;
4. installe l'application dans `/opt/asemon` (code, `config.py` généré, environnement Python) ;
5. installe et démarre `asemon-collector`, `asemon-sampler` et `asemon-logparser`.

Vérification, **une minute après** la fin du script :

```bash
sudo ./scripts/verify.sh target
sudo ./scripts/verify.sh monitoring      # sur VM-Monitoring : les compteurs de lignes doivent monter
```

Générer un peu de charge pour voir de l'activité : `sudo -u postgres createdb bench && sudo -u postgres pgbench -i -s 10 bench && sudo -u postgres pgbench -c 4 -T 60 bench` (sur VM-Cible), puis ouvrir Grafana : `http://<IP_VM_MONITORING>:3000`.

---

## 3. Rejouer, mettre à jour

- **Rejouer un script** est sans danger : chaque étape vérifie l'état avant d'agir. `config.py` est conservé s'il existe (`sudo FORCE_CONFIG=1 ./scripts/install-target.sh` pour le régénérer).
- **Mettre à jour le schéma seulement** (après un `git pull` qui apporte un nouveau `sql/NN-*.sql`) : `sudo ./scripts/install-monitoring.sh --sql-only`. Le fichier doit d'abord être ajouté à la liste `SQL_FILES` du script.
- **Mettre à jour le code Python** : `git pull`, puis relancer `install-target.sh` (copie les fichiers et redémarre les services).
- **Changer un réglage PostgreSQL de VM-Cible** : modifier le bloc dans `install-target.sh` et relancer. Ne pas utiliser `ALTER SYSTEM` pour les paramètres gérés : `postgresql.auto.conf` l'emporterait sur `conf.d`, et le script s'arrête avec un message si cela arrive.

---

## 4. Ce que le script change par rapport aux étapes à la main

| Sujet | À la main (docs 01 à 14) | Script |
|---|---|---|
| Réglages PostgreSQL de VM-Cible | modifiés dans `postgresql.conf`, puis `ALTER SYSTEM` (docs 02, 07, 14) | un fichier `conf.d/asemon.conf`, jamais de `ALTER SYSTEM` (évite le piège `shared_preload_libraries`) |
| `log_timezone = 'UTC'` | non documenté (valeur par défaut des VM du POC) | fixé explicitement : sans lui, un serveur en heure locale écrit `CEST` et le parseur perd les horodatages |
| `pg_hba.conf` | une ligne pour tout le sous-réseau, tous rôles et bases | lignes limitées aux rôles et bases utiles ; aucune ouverture réseau sur VM-Cible par défaut |
| `config.py` | `chmod -R a+rX /opt/asemon` : mots de passe lisibles par tous | `config.py` en `0640`, groupe `asemon` (compte de service et `postgres`) |
| Venv et application | créés dans le home, puis déplacés dans `/opt/asemon` | directement dans `/opt/asemon` |
| Rôles SQL | `CREATE USER` avec mot de passe d'exemple à modifier dans le fichier | `sql/02` et `sql/03` rejouables ; les mots de passe viennent de `asemon.env` |
| Datasource et dashboards Grafana | à la main dans l'interface | par l'API (optionnel) |

---

## 5. Écarts relevés dans les docs d'installation (relecture du 2026-10-09)

| # | Écart | Traitement |
|---|---|---|
| 1 | Deux procédures concurrentes pour créer la base et les rôles du repository : `01-VM-Monitoring.md` §4 (en ligne, avec ses mots de passe) et `01-VM-Monitoring-repository-grafana.md` (fichiers `sql/`). Suivre les deux de suite échoue (`role already exists`). | `sql/02` et `sql/03` rendus rejouables ; note ajoutée dans la fiche `01`. |
| 2 | Aucun document ne donne **l'ordre complet des scripts SQL** (`01, 02, 04, 05, 06, 08, 09, 10, 11` ; `07` à ne pas appliquer). | Ordre fixé dans `install-monitoring.sh` et dans ce document. |
| 3 | `log_timezone` jamais cité comme prérequis alors que le parseur suppose l'UTC. | Ajouté à `conf.d/asemon.conf` ; note dans `02-VM-Cible.md` et `07-sessions-phase1.md`. |
| 4 | Les réglages de VM-Cible sont répartis sur trois docs (02, 07, 14), dont deux par `ALTER SYSTEM`. | Regroupés dans `conf.d/asemon.conf`. |
| 5 | `config.py` rendu lisible par tous (`chmod -R a+rX`), mots de passe compris. | Groupe `asemon`, mode `0640`. |
| 6 | `User=admin01` écrit en dur dans `asemon-collector.service` et `asemon-sampler.service`. | Remplacé à l'installation par `SERVICE_USER`. |
| 7 | Les mots de passe sont à modifier dans les fichiers SQL avant exécution (`CHANGEME_*`) : facile à oublier. | Fixés par le script depuis `asemon.env`. |
| 8 | Grafana : datasource et import des dashboards uniquement à la main. | `grafana-provision.sh`. |
| 9 | L'IP de VM-Monitoring est écrite dans `config.py` (`REPO_DSN`) : si le DHCP la change, la collecte s'arrête sans bruit. | Prérequis « IP stable » ci-dessus ; en cas de changement, éditer `REPO_DSN` et redémarrer les trois services. |
| 10 | Les docs 02 et 03 décrivent un venv dans le home, déplacé ensuite vers `/opt/asemon`. Étapes intermédiaires inutiles sur une VM neuve. | Le script installe directement dans `/opt/asemon`. |
| 11 | `postgresql-contrib-17` cité dans les docs ; ce paquet n'est plus nécessaire (les contributions et `pgbench` sont dans `postgresql-17` chez PGDG). | Le script n'installe que `postgresql-17`. À confirmer au premier essai. |

---

## 6. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| `install-target.sh` : « postgresql.auto.conf redéfinit … » | un `ALTER SYSTEM` antérieur | `ALTER SYSTEM RESET <paramètre>;` puis relancer |
| PostgreSQL ne redémarre pas après le script de VM-Cible | `pg_stat_kcache` absent (paquet non installé) | `journalctl -xeu postgresql@17-main` ; installer `postgresql-17-pg-stat-kcache` |
| Collecteur : `connection refused` / timeout vers le repository | `SUBNET` ou `MONITORING_IP` faux, `pg_hba` | contrôler `scripts/asemon.env`, relancer `install-monitoring.sh` puis `install-target.sh` |
| `verify.sh` : « kcache actif » en échec | extension absente ou serveur non redémarré | `SHOW shared_preload_libraries;` sur VM-Cible |
| `grafana-provision.sh` : HTTP 401 | mot de passe admin différent de celui de `asemon.env` | le saisir dans `asemon.env` ou le réinitialiser : `sudo grafana cli admin reset-admin-password <mdp>` |
| Dashboards importés mais vides | datasource en échec | Grafana > Connections > Data sources > « ASEMON Monitoring » > Save & test |

---

## 7. Checklist de validation (premier essai sur VM neuves)

- [ ] `install-monitoring.sh` terminé sans erreur, `verify.sh monitoring` tout vert
- [ ] `install-target.sh` terminé sans erreur, `verify.sh target` tout vert
- [ ] Après une minute : `snap_os`, `snap_activity`, `snap_samples` se remplissent
- [ ] Après un `pgbench` : `snap_kcache` rempli, dashboards avec des données
- [ ] Rejeu des deux scripts : aucune erreur, pas de redémarrage inutile de PostgreSQL
- [ ] Datasource et 6 dashboards présents dans Grafana
