# Phase 1 — Cycle de vie des sessions (`snap_sessions`)

> Première étape de la roadmap IHM (`06-roadmap-ihm.md`). Le parseur de logs enregistre désormais chaque connexion et déconnexion avec ses horodatages exacts, et une **clé de session** commune relie les sessions, les snapshots d'activité, les deadlocks et les plans `auto_explain`.
>
> **Statut : code et schéma écrits et testés en local, pas encore déployés sur les VM.**

Fichiers concernés :
- `sql/05-schema-sessions.sql` — table `snap_sessions`, colonne `session_key`, droits
- `sql/06-schema-phase2-brouillon.sql` — tables des phases suivantes (non déployées)
- `python/log_parser.py` — événements de connexion/déconnexion, `session_key` sur deadlocks et plans
- `python/collector.py` — `session_key` dans `snap_activity`

---

## 1. Prérequis côté VM-Cible (déjà appliqués au POC)

```bash
sudo -u postgres psql -d postgres <<'EOF'
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_disconnections = on;
ALTER SYSTEM SET lc_messages = 'C';
SELECT pg_reload_conf();
EOF
```

Un reload suffit. Les paramètres ne touchent que les **nouvelles** connexions.

### Pourquoi `lc_messages = 'C'` est obligatoire

Les messages de connexion/déconnexion sont de simples `LOG` (SQLSTATE `00000`) : contrairement aux deadlocks (`40P01`), aucun code ne les distingue. Le parseur les reconnaît donc par le **début du texte** (`connection authorized:` / `disconnection:`), qui est traduit selon `lc_messages`. Avec un serveur en français, aucune session ne serait enregistrée, **sans aucune erreur** (même piège silencieux que celui des deadlocks, voir `03-VM-Cible-parseur-systemd.md` §3).

Contrepartie : les messages d'erreur renvoyés aux clients passent aussi en anglais.

---

## 2. Format des lignes de log (observé sur la VM-Cible, PostgreSQL 17)

Connexion :
```json
{"timestamp":"2026-10-09 08:59:28.571 UTC","user":"postgres","dbname":"postgres","pid":2493,"remote_host":"[local]","session_id":"6ac8acf0.9bd","session_start":"2026-10-09 08:59:28 UTC","error_severity":"LOG","message":"connection authorized: user=postgres database=postgres application_name=test_phase1","backend_type":"client backend"}
```

Déconnexion :
```json
{"timestamp":"2026-10-09 08:59:30.574 UTC","user":"postgres","dbname":"postgres","pid":2493,"remote_host":"[local]","session_id":"6ac8acf0.9bd","session_start":"2026-10-09 08:59:28 UTC","error_severity":"LOG","message":"disconnection: session time: 0:00:02.003 user=postgres database=postgres host=[local]","application_name":"test_phase1","backend_type":"client backend"}
```

Deux particularités qui dictent le code :
- À la **connexion**, `application_name` n'est pas un champ du JSON : il faut le lire dans le message. À la **déconnexion**, c'est l'inverse (champ JSON présent).
- `remote_host` vaut `[local]` pour une connexion par socket Unix : `client_addr` reste alors `NULL`.

`log_timezone` est `Etc/UTC` sur la VM-Cible, ce que `parse_timestamp()` suppose (suffixe `UTC`).

---

## 3. La clé de session (`session_key`)

`session_key` = le champ `session_id` natif de PostgreSQL : **`<epoch de début du backend en hexa>.<pid en hexa>`**, par exemple `6ac8acf0.9bd` (`0x6ac8acf0` = 2026-10-09 08:59:28 UTC, `0x9bd` = pid 2493).

Il est présent dans **chaque** ligne du jsonlog, donc :
- les sessions, les deadlocks et les plans `auto_explain` le reçoivent sans calcul ;
- côté `pg_stat_activity`, le collecteur le reconstruit à l'identique :
  ```sql
  to_hex(floor(extract(epoch FROM backend_start))::bigint) || '.' || to_hex(pid)
  ```

> Cette définition **remplace** la formule `pid || '-' || extract(epoch from backend_start)` proposée initialement : le jsonlog ne fournit l'epoch qu'à la seconde, alors que `extract(epoch ...)` garde les fractions, les deux côtés n'auraient jamais produit la même clé.

---

## 4. Déploiement — dans cet ordre

**Le schéma d'abord**, car les nouvelles versions du parseur et du collecteur écrivent dans les colonnes `session_key` : sans elles, les `INSERT` échouent (y compris ceux des deadlocks et des plans, qui fonctionnent aujourd'hui).

### 4.1 VM-Monitoring — schéma

Copier `05-schema-sessions.sql` sur la VM (par exemple depuis PowerShell : `scp .\sql\05-schema-sessions.sql admin01@192.168.1.28:~/`), puis :

```bash
sudo -u postgres psql -d monitoring -f ~/05-schema-sessions.sql
```

Le script est idempotent. Vérification (4 lignes attendues) :

```bash
sudo -u postgres psql -d monitoring -c "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema='asemon' AND column_name='session_key' ORDER BY 1;"
```

### 4.2 VM-Cible — parseur et collecteur

Copier `python/log_parser.py` et `python/collector.py` sur la VM, puis :

```bash
sudo cp log_parser.py collector.py /opt/asemon/app/
sudo chmod -R a+rX /opt/asemon
sudo systemctl restart asemon-logparser.service asemon-collector.service
sudo systemctl status asemon-logparser.service asemon-collector.service
```

---

## 5. Vérification

Ouvrir une session de test de 20 secondes (VM-Cible) :
```bash
sudo -u postgres psql "dbname=postgres application_name=test_phase1b" -c "SELECT pg_sleep(20);"
```

Sur VM-Monitoring, après la fin du `pg_sleep` :
```bash
sudo -u postgres psql -d monitoring -c "SELECT session_key, usename, application_name, client_addr, connected_at, disconnected_at FROM asemon.snap_sessions ORDER BY connected_at DESC LIMIT 5;"
```
La ligne `test_phase1b` doit avoir `connected_at` **et** `disconnected_at`, environ 20 s d'écart. Dans `journalctl -u asemon-logparser -f` : `Session connectée` puis `Session déconnectée`.

Jointure avec l'activité (le collecteur doit voir la session pendant le `pg_sleep`, relancer-le au besoin) :
```bash
sudo -u postgres psql -d monitoring -c "SELECT a.pid, a.application_name, a.session_key, s.connected_at FROM asemon.snap_activity a LEFT JOIN asemon.snap_sessions s USING (session_key) WHERE a.collected_at > now() - interval '2 minutes' ORDER BY a.collected_at DESC LIMIT 10;"
```

Deadlock rattaché à sa session : rejouer le test de `03-VM-Cible-parseur-systemd.md` §5, puis
```bash
sudo -u postgres psql -d monitoring -c "SELECT occurred_at, session_key, involved_tables FROM asemon.event_deadlocks ORDER BY occurred_at DESC LIMIT 3;"
```

---

## 6. Limites connues

- **Sessions manquées** : le parseur démarre en fin de fichier. Les connexions survenues pendant un arrêt du parseur ne sont pas enregistrées. Une déconnexion dont la connexion n'a pas été vue crée quand même la ligne complète (début déduit du `session_id`).
- **Sessions ouvertes avant l'activation des logs** : elles n'ont pas de ligne de connexion ; `snap_activity` les voit (avec `session_key`) mais `snap_sessions` ne les connaît qu'à leur déconnexion.
- **Historique** : les lignes déjà présentes dans `snap_activity`, `event_plans` et `event_deadlocks` gardent `session_key` à `NULL`. Un rattrapage optionnel pour `snap_activity` est fourni (commenté) à la fin de la partie 2 de `05-schema-sessions.sql`.
- **Connexions de réplication** (`replication connection authorized:`) : ignorées pour l'instant.
- **Précision** : `connected_at` est à la seconde (limite du `session_id`), `disconnected_at` à la milliseconde.
- **Droits** : `collector_writer` n'a que `INSERT`, `UPDATE` sur 4 colonnes et `SELECT (session_key)` sur `snap_sessions`. L'`upsert` du parseur est écrit en conséquence : il n'utilise pas `EXCLUDED.disconnected_at` (qui exigerait le droit de lecture sur la colonne). Vérifié avec le rôle réel sur PostgreSQL 16.

---

## 7. Checklist de validation

- [ ] `lc_messages = 'C'`, `log_connections = on`, `log_disconnections = on` sur VM-Cible
- [ ] `05-schema-sessions.sql` exécuté sur VM-Monitoring, 4 colonnes `session_key` présentes
- [ ] `log_parser.py` et `collector.py` mis à jour dans `/opt/asemon/app`, deux services `active`
- [ ] Session de test visible dans `snap_sessions` avec connexion **et** déconnexion
- [ ] `snap_activity.session_key` renseigné sur les nouveaux snapshots, jointure avec `snap_sessions` non vide
- [ ] Un deadlock de test porte un `session_key`
- [ ] Dashboard Grafana existant inchangé (aucun panneau cassé)
