# VM-Monitoring — Fiche technique

## Rôle

Cette VM héberge :
- Le **repository PostgreSQL** : base qui stocke l'historique des snapshots de monitoring (activité, verrous, I/O, requêtes, deadlocks, plans d'exécution) collectés sur la VM surveillée (`VM-Cible`).
- **Grafana** : dashboards de visualisation branchés sur ce repository.

Elle ne surveille pas sa propre instance PostgreSQL : elle sert uniquement de réceptacle et de couche de restitution.

## Caractéristiques

| Paramètre | Valeur |
|---|---|
| Hyperviseur | Hyper-V (Windows 11 Pro) |
| OS | Ubuntu Server 26.04.1 LTS "Resolute Raccoon" |
| Hostname | `vmmonitoring` |
| Utilisateur admin | `admin01` |
| RAM | 6144 Mo (fixe — mémoire dynamique **désactivée**) |
| Disque | 40 Go (recommandé) |
| Réseau | Commutateur virtuel `Monitoring-Switch` (type Externe) |
| IP (exemple POC) | `192.168.1.28` |
| PostgreSQL | 17.11 (dépôt PGDG) |
| Grafana | dernière version stable (dépôt officiel) |

> Les adresses IP sont distribuées par DHCP sur le réseau local via le switch externe. Adaptez-les à votre environnement.

---

## 1. Création de la VM dans Hyper-V

### 1.1 Prérequis
- Windows 11 Pro/Enterprise/Education (Hyper-V indisponible sur Home)
- Hyper-V activé :
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```
Redémarrer la machine hôte après activation.

### 1.2 Commutateur virtuel

Gestionnaire Hyper-V → **Gestionnaire de commutateur virtuel** → Nouveau commutateur :
- Nom : `Monitoring-Switch`
- Type de connexion : **Réseau externe**, lié à la carte réseau physique de l'hôte
- Cocher **"Autoriser le système d'exploitation de gestion à partager cette carte réseau"**

Ou en PowerShell (variante réseau interne, si pas d'accès Internet requis pour les VM) :
```powershell
New-VMSwitch -Name "Monitoring-Switch" -SwitchType Internal
```

### 1.3 Télécharger l'ISO Ubuntu

Depuis https://ubuntu.com/download/server, récupérer `ubuntu-26.04.1-live-server-amd64.iso` et le placer dans `C:\ISO\`.

### 1.4 Créer la VM (Quick Create)

1. Gestionnaire Hyper-V → **Création rapide...**
2. Cliquer sur **"Source d'installation locale"** (la galerie intégrée de Microsoft ne propose souvent que d'anciennes versions d'Ubuntu, non à jour)
3. Parcourir jusqu'à `C:\ISO\ubuntu-26.04.1-live-server-amd64.iso`
4. Nom de la VM : `VM-Monitoring`
5. Déplier **"Autres options"** :
   - Réseau : `Monitoring-Switch`
   - RAM : 6144 Mo
6. Créer, puis **Se connecter** → **Démarrer**

### 1.5 Désactiver la mémoire dynamique (important)

Avant tout usage intensif : la mémoire dynamique de Hyper-V peut provoquer un **kernel panic ("System is deadlocked on memory")** sous charge. Fixer la RAM :

1. Éteindre la VM (`sudo shutdown now` en SSH, ou bouton Arrêter dans Hyper-V)
2. Gestionnaire Hyper-V → clic droit sur `VM-Monitoring` → **Paramètres → Mémoire**
3. **Décocher "Activer la mémoire dynamique"**
4. Fixer à 6144 Mo
5. Redémarrer la VM

### 1.6 Installation Ubuntu Server

Suivre l'installeur Subiquity :
- Langue / clavier : French
- Réseau : DHCP par défaut
- Nom du serveur : `vmmonitoring`
- Utilisateur : `admin01` + mot de passe
- **Cocher "Install OpenSSH server"** à l'étape correspondante (sinon, l'installer manuellement après coup, voir §1.7)
- Laisser l'installation se terminer, retirer le support, redémarrer

Relever l'IP affichée à l'écran de connexion (`ip a` ou directement visible sur l'écran MOTD après login).

### 1.7 SSH (si non installé pendant le setup)

```bash
sudo apt update
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
sudo systemctl status ssh
```

Vérifier le pare-feu local le cas échéant :
```bash
sudo ufw status
sudo ufw allow 22/tcp   # si ufw actif
```

Depuis l'hôte Windows (PowerShell) :
```powershell
ssh admin01@<IP_VM_MONITORING>
```
> Le presse-papiers (Ctrl+C / Ctrl+V) ne fonctionne pas de façon fiable dans la fenêtre "Connexion à un ordinateur virtuel" de Hyper-V pour une VM Ubuntu Server (pas d'interface graphique, session améliorée non disponible). Travailler en SSH depuis un terminal Windows résout le problème.

### 1.8 Mise à jour du système

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

> Note : le dépôt PGDG a fourni un build pour le nom de code `resolute` (Ubuntu 26.04) sans nécessiter de contournement lors du POC. Si ce n'était pas le cas sur votre environnement, remplacer `$(lsb_release -cs)` par `noble` dans la ligne `pgdg.list` (compatibilité binaire ascendante).

---

## 3. Configuration réseau

### 3.1 `postgresql.conf`

```bash
sudo nano /etc/postgresql/17/main/postgresql.conf
```
```
listen_addresses = '*'
```

### 3.2 `pg_hba.conf`

```bash
sudo nano /etc/postgresql/17/main/pg_hba.conf
```
Ajouter à la fin (adapter le sous-réseau) :
```
# Accès Grafana / réseau local
host    all             all             192.168.1.0/24          scram-sha-256
```

### 3.3 Mot de passe superuser et redémarrage

```bash
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'VotreMotDePasseSolide';"
sudo systemctl restart postgresql@17-main
```

---

## 4. Base repository et rôles

> **Procédure à ne pas cumuler avec `01-VM-Monitoring-repository-grafana.md` §2-3** : les deux créent la base et les rôles. Cette fiche donne le principe ; la procédure suivie par le POC est celle des scripts `sql/01` et `sql/02` (rejouables), et `docs/15-installation-scriptee.md` enchaîne tout automatiquement.

```bash
sudo -u postgres psql <<'EOF'
CREATE DATABASE monitoring;
\c monitoring
CREATE SCHEMA asemon;

-- Rôle utilisé par le collecteur (VM-Cible) pour écrire les snapshots
CREATE USER collector_writer WITH PASSWORD 'MotDePasseCollecteur';
GRANT USAGE, CREATE ON SCHEMA asemon TO collector_writer;

-- Rôle utilisé par Grafana en lecture seule
CREATE USER grafana_ro WITH PASSWORD 'MotDePasseGrafana';
GRANT USAGE ON SCHEMA asemon TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA asemon GRANT SELECT ON TABLES TO grafana_ro;
EOF
```

> Le schéma des tables de snapshots/événements (`asemon.*`) est à créer selon le modèle de données du projet (voir dépôt principal / migrations SQL).

---

## 5. Installation de Grafana

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

Grafana écoute par défaut sur le port **3000**. Accès depuis le navigateur de l'hôte Windows :
```
http://<IP_VM_MONITORING>:3000
```
Identifiants par défaut : `admin` / `admin` (changement de mot de passe demandé à la première connexion).

### 5.1 Ajouter le datasource PostgreSQL

Dans Grafana : **Connections → Data sources → Add data source → PostgreSQL**
- Host : `localhost:5432`
- Database : `monitoring`
- User : `grafana_ro`
- Password : (celui défini en §4)
- TLS/SSL mode : `disable` (POC local — à sécuriser en environnement réel)

---

## 6. Points de vigilance rencontrés durant le POC

- **Kernel panic mémoire** : provoqué par la mémoire dynamique Hyper-V sous pression. Corrigé en fixant la RAM (§1.5). À appliquer **avant** toute charge (installation de paquets, PostgreSQL, Grafana).
- **`apt upgrade` qui tue des processus (OOM killer)** : symptôme du même problème de RAM insuffisante/dynamique. Avec RAM fixe à 6 Go, plus de souci observé.
- **Copier-coller Hyper-V** : non fonctionnel en console Ubuntu Server. Utiliser SSH depuis un terminal Windows.
- **Service SSH absent** ("Unit ssh.service could not be found") si la case n'a pas été cochée à l'installation : installer `openssh-server` manuellement (§1.7).

---

## 7. Checklist de validation

- [ ] VM démarre avec RAM fixe, pas de kernel panic
- [ ] `ssh admin01@<IP>` fonctionne depuis l'hôte Windows
- [ ] `sudo systemctl status postgresql@17-main` → `active (running)`
- [ ] Connexion TCP testée : `psql -h <IP> -U grafana_ro -d monitoring`
- [ ] Grafana accessible sur `http://<IP>:3000`
- [ ] Datasource PostgreSQL opérationnel dans Grafana
