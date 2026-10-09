# VM-Cible — Parseur de logs, déploiement /opt/asemon et services systemd

> Fait suite à `02-VM-Cible-collecteur-python.md` (collecteur Python testé manuellement). Ce document couvre : le parseur de logs (deadlocks + plans `auto_explain`), le déplacement de l'application vers un emplacement accessible par plusieurs utilisateurs système, et le passage des deux composants en services systemd permanents.

## Prérequis

- Collecteur Python fonctionnel (voir document précédent)
- Repository PostgreSQL opérationnel sur VM-Monitoring, tables `event_deadlocks` et `event_plans` créées (`sql/01-schema-asemon.sql`)

Fichiers correspondants dans le dépôt :
- `python/log_parser.py`
- `python/config.py.example` (mis à jour avec `PG_DATA_DIR`)
- `systemd/asemon-collector.service`
- `systemd/asemon-logparser.service`

---

## 1. Pourquoi un composant séparé pour les logs

Les vues `pg_stat_*` ne donnent pas tout :
- **Deadlocks** : seul un compteur cumulé existe (`pg_stat_database.deadlocks`). Le détail — tables, utilisateurs, requêtes impliqués — n'existe que dans les **logs** du serveur.
- **Plans d'exécution** : `pg_stat_statements` ne stocke pas les plans. Il faut l'extension `auto_explain` (déjà activée, voir document précédent) et lire ses sorties dans les logs.

D'où un second composant, `log_parser.py`, qui **suit en continu** (façon `tail -f`) le fichier de log JSON actif et alimente `asemon.event_deadlocks` / `asemon.event_plans`.

---

## 2. Déplacement de l'application vers `/opt/asemon`

**Piège rencontré** : le parseur doit lire les fichiers de log de PostgreSQL, dont le répertoire (`/var/lib/postgresql/17/main/`) est `drwx------`, appartenant à `postgres:postgres`. Deux approches possibles :
- Donner l'accès en lecture à l'utilisateur `admin01` (ajout au groupe `postgres`, `chmod g+r` sur les fichiers) → **rejetée** : les permissions sautent à chaque rotation quotidienne des logs, peu maintenable.
- Exécuter le parseur **en tant qu'utilisateur `postgres`** → solution retenue, robuste.

Cette seconde approche pose une contrainte : `postgres` doit pouvoir accéder aux fichiers du script. Or `/home/admin01` est en `drwxr-x---` (accès refusé aux autres utilisateurs, y compris `postgres`). D'où le déplacement de toute l'application vers `/opt/asemon`, lisible par tous :

```bash
sudo mkdir -p /opt/asemon
sudo cp -r ~/asemon-collector-app /opt/asemon/app
sudo cp -r ~/asemon-collector /opt/asemon/venv
sudo chown -R root:root /opt/asemon
sudo chmod -R a+rX /opt/asemon
```

Arborescence finale :
```
/opt/asemon/
├── app/
│   ├── collector.py
│   ├── log_parser.py
│   └── config.py        (créé à partir de config.py.example, non versionné)
└── venv/                 (environnement virtuel Python : psycopg, psutil)
```

> À partir de cette étape, **tous les chemins** (services systemd inclus) référencent `/opt/asemon/...`, plus `/home/admin01/...`.

---

## 3. Script `log_parser.py`

Résumé du fonctionnement (voir `python/log_parser.py` pour le code complet) :

1. Détermine le fichier de log JSON actif via `current_logfiles` (dans `PGDATA`).
2. Le "suit" en continu (équivalent `tail -f`), gère la rotation quotidienne des fichiers.
3. Pour chaque ligne JSON :
   - Si `state_code == "40P01"` (deadlock) → extrait les processus, tables et requêtes impliqués, écrit dans `asemon.event_deadlocks`.
   - Si le message commence par `duration:` et contient `plan:` (sortie `auto_explain`) → extrait la durée et le plan JSON, écrit dans `asemon.event_plans`.

### Piège rencontré : détection du deadlock dépendante de la langue

La première version du parseur testait :
```python
if message.startswith("deadlock detected"):
```
Ce texte n'apparaît que si le serveur PostgreSQL est configuré en anglais (`lc_messages`). Sur une instance en français, le message est `"interblocage (deadlock) détecté"` — la condition ne se déclenchait donc jamais, silencieusement (pas d'erreur, juste aucune capture).

**Correction** : s'appuyer sur le code **SQLSTATE**, standard et indépendant de la langue :
```python
if entry.get("state_code") == "40P01":
```
`40P01` est le code SQLSTATE PostgreSQL pour `deadlock_detected`, quel que soit `lc_messages`. La regex d'extraction des processus (`DEADLOCK_PROC_RE`) a aussi été adaptée pour reconnaître à la fois `Process 123:` (anglais) et `Processus 123 :` (français).

> **Enseignement pour la suite du projet** : toute détection basée sur le texte des messages PostgreSQL (logs, erreurs) doit utiliser les codes SQLSTATE plutôt que les chaînes de caractères, sauf si `lc_messages = 'C'` est explicitement forcé sur le serveur.

---

## 4. Configuration

Ajouter à `config.py` (voir `python/config.py.example`) :
```python
PG_DATA_DIR = "/var/lib/postgresql/17/main"
```

---

## 5. Test manuel du parseur

```bash
sudo -u postgres /opt/asemon/venv/bin/python3 /opt/asemon/app/log_parser.py
```

Sortie attendue :
```
2026-09-25 12:05:57,659 [INFO] Suivi du fichier de log : /var/lib/postgresql/17/main/log/postgresql-2026-09-25.json
```

### Provoquer un deadlock de test

Créer deux tables de test :
```bash
sudo -u postgres psql -d postgres <<'EOF'
DROP TABLE IF EXISTS test_a, test_b;
CREATE TABLE test_a (id INT PRIMARY KEY, val TEXT);
CREATE TABLE test_b (id INT PRIMARY KEY, val TEXT);
INSERT INTO test_a VALUES (1, 'x');
INSERT INTO test_b VALUES (1, 'x');
EOF
```

Ouvrir **deux sessions `psql` séparées** (deux terminaux SSH distincts) :

**Session A :**
```sql
BEGIN;
UPDATE test_a SET val = 'y' WHERE id = 1;
```
(laisser la transaction ouverte)

**Session B :**
```sql
BEGIN;
UPDATE test_b SET val = 'y' WHERE id = 1;
UPDATE test_a SET val = 'z' WHERE id = 1;   -- se bloque, en attente de A
```

**Retour Session A :**
```sql
UPDATE test_b SET val = 'z' WHERE id = 1;   -- déclenche le deadlock
```

PostgreSQL détecte le cycle après `deadlock_timeout` (1s configuré) et annule l'une des deux transactions. Le terminal du parseur doit afficher :
```
[INFO] Deadlock enregistré | pid=6492 tables=['test_a', 'test_b']
```

### Vérification côté repository (sur VM-Monitoring)

```bash
sudo -u postgres psql -d monitoring -c \
  "SELECT id, occurred_at, process_id, involved_tables, queries FROM asemon.event_deadlocks ORDER BY occurred_at DESC LIMIT 3;"
sudo -u postgres psql -d monitoring -c "SELECT count(*) FROM asemon.event_plans;"
```

---

## 6. Services systemd

### 6.1 Collecteur (`asemon-collector.service`)

Fichier : `systemd/asemon-collector.service` (à copier vers `/etc/systemd/system/`).

```bash
sudo cp systemd/asemon-collector.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-collector.service
sudo systemctl status asemon-collector.service
```

Tourne sous l'utilisateur `admin01` (pas besoin d'accès aux fichiers de logs PostgreSQL, seulement à sa propre connexion réseau).

### 6.2 Parseur de logs (`asemon-logparser.service`)

Fichier : `systemd/asemon-logparser.service`.

```bash
sudo cp systemd/asemon-logparser.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-logparser.service
sudo systemctl status asemon-logparser.service
```

Tourne sous l'utilisateur **`postgres`** (nécessaire pour accéder au répertoire de logs, voir §2).

### 6.3 Vérification des deux services

```bash
sudo systemctl status asemon-collector.service
sudo systemctl status asemon-logparser.service
sudo journalctl -u asemon-collector -f
sudo journalctl -u asemon-logparser -f
```

### 6.4 Test de résilience (recommandé)

```bash
sudo systemctl kill -s SIGKILL asemon-collector.service
sleep 6
sudo systemctl status asemon-collector.service   # doit être reparti (Restart=always)
```

### 6.5 Persistance au reboot

```bash
sudo systemctl is-enabled asemon-collector.service
sudo systemctl is-enabled asemon-logparser.service
```
Doit répondre `enabled` pour les deux.

---

## 7. Points de vigilance rencontrés durant le POC

- **`/home/admin01` inaccessible à `postgres`** (`drwxr-x---`) : bloque toute exécution `sudo -u postgres` d'un script situé dans le home d'un autre utilisateur. Résolu par le déplacement vers `/opt/asemon`, lisible par tous (`chmod -R a+rX`).
- **`current_logfiles` illisible malgré l'appartenance au groupe `postgres`** : le répertoire parent `PGDATA` est `drwx------`, donc même un membre du groupe `postgres` ne peut pas *traverser* le dossier pour atteindre le fichier. Contourné en exécutant directement le script sous l'utilisateur `postgres` plutôt que d'ouvrir les permissions du répertoire de données (ce qui aurait affaibli la sécurité de l'instance).
- **Détection de deadlock dépendante de la langue du serveur** (voir §3) — piège silencieux, sans erreur ni log d'échec, juste une absence totale de capture.
- **Confusion entre deux sessions `psql` de test** : lors des essais manuels de deadlock, bien identifier quel terminal est "Session A" et lequel est "Session B", et exécuter les commandes dans le bon ordre (A ouvre `test_a`, B ouvre `test_b` puis tente `test_a`, puis retour à A qui tente `test_b` pour fermer le cycle). Un ordre inversé ou mélangé ne produit aucun deadlock, juste des mises à jour séquentielles normales.

---

## 8. Checklist de validation

- [ ] `/opt/asemon` créé, lisible par tous, contient `app/` (avec `config.py`) et `venv/`
- [ ] `log_parser.py` testé manuellement, capture un deadlock de test et un plan `auto_explain`
- [ ] Détection basée sur `state_code == "40P01"` (pas sur le texte du message)
- [ ] `asemon-collector.service` actif, `enabled`, logs "Snapshot OK" réguliers
- [ ] `asemon-logparser.service` actif, `enabled`, tourne sous l'utilisateur `postgres`
- [ ] Test de résilience (`SIGKILL`) validé sur au moins un des deux services
- [ ] Données visibles côté repository : `asemon.event_deadlocks` et `asemon.event_plans` non vides

---

## 9. Prochaines étapes (hors périmètre de cette fiche)

- Construction des premiers **dashboards Grafana** : vue globale CPU/IO/réseau, verrous et chaînes de blocage, deadlocks détaillés, top SQL avec lien vers les plans d'exécution
- Contention spécifique PostgreSQL : `idle in transaction` longues, retard d'autovacuum, bloat, checkpoints, fichiers temporaires
- ~~Politique de rétention sur les tables `asemon.snap_*`~~ : traitée, voir `10-retention.md` (purge quotidienne, durées réglables). Pas de partitionnement pour ces tables, la purge par `DELETE` suffit à ce volume.
