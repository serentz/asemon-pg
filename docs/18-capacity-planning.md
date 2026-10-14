# Release 3 : capacity planning, collecte et rétention (étape 3a)

> **Statut : 3a (collecte, rétention) validée sur les VM et fusionnée dans `main` ; 3b (dashboard `asemon-capacity`) codée le 2026-10-14, SQL testé en local sur PostgreSQL 16 avec un historique synthétique, à valider sur Grafana.** Conception : `16-roadmap-releases.md`, §B.

## 1. Ce qui change

| Sujet | Avant | Release 3a |
|---|---|---|
| Taille des bases et des tables | suivie seulement par `snap_tables` (activité, pas de taille) | **un point par heure** : `snap_db_size` et `snap_table_size` |
| Rétention | `asemon-purge.timer` appelle `purge_old_data()` | **`retention.py`** : point d'entrée unique, `asemon-retention.timer` remplace `asemon-purge.timer` |
| Python sur VM-Monitoring | aucun | un petit environnement `/opt/asemon/venv` (psycopg) |

## 2. La collecte horaire (VM-Cible)

Le collecteur écrit **au premier cycle de chaque heure UTC** (et au démarrage si l'heure en cours n'a pas de point) :
- `snap_db_size` : une ligne par base (hors modèles `template*`), taille par `pg_database_size`.
- `snap_table_size` : une ligne par table utilisateur de chaque base : lignes **estimées** (`n_live_tup`, à défaut `reltuples`), taille de la table, des index, du TOAST, taille totale, **nombre d'index**.

Détails :
- Une connexion brève par base, une fois par heure : `pg_stat_user_tables` ne décrit que la base courante.
- Les lignes sont des **estimations**, pas des `count(*)` : suffisant pour une tendance. Juste après la création ou une grosse insertion, l'estimation peut être décalée jusqu'au prochain passage d'autovacuum ou d'analyze.
- Les tables de moins de `CAPACITY_MIN_BYTES` (64 ko par défaut, taille totale) ne sont pas suivies.
- Les partitions apparaissent comme des tables séparées.
- Toutes les lignes d'une collecte ont le même `collected_at` : le tableau « plus grosses tables » prendra la dernière collecte.
- Un échec (base inaccessible, schéma absent) est journalisé sans arrêter la collecte ; nouvel essai après 10 minutes (`CAPACITY_RETRY_S`).
- Au redémarrage, le collecteur relit la dernière heure écrite : pas de doublon.

## 3. Paramètres

| Paramètre | Où | Défaut | Effet |
|---|---|---|---|
| `CAPACITY_MIN_BYTES` | `/opt/asemon/app/config.py` (VM-Cible), optionnel | 65536 | taille totale minimale d'une table suivie ; redémarrer `asemon-collector` |
| `capacity_full_days` | `asemon.settings` (VM-Monitoring) | 7 | jours gardés à un point par heure ; au-delà, un point par jour. 0 = pas de réduction |
| `capacity_max_days` | `asemon.settings` | 1095 | durée maximale (3 ans). 0 = illimité |

```sql
UPDATE asemon.settings SET value = '14' WHERE key = 'capacity_full_days';
```
Effet au prochain passage de `retention.py`. Réduire une durée supprime définitivement des points.

## 4. `retention.py` (VM-Monitoring)

Lancé chaque jour à 03:17 UTC par `asemon-retention.timer`, sous l'utilisateur `postgres`. Il enchaîne :
1. `asemon.purge_old_data()` : la rétention existante (doc `10`) ;
2. suppression des points de capacity planning de plus de `capacity_max_days` ;
3. réduction à **un point par jour** (le **dernier du jour UTC**, par base et par table) des points de plus de `capacity_full_days`.

`maintain_samples()` (partitions de `snap_samples`) reste sur son timer horaire.

```bash
cd /
sudo -u postgres /opt/asemon/venv/bin/python3 /opt/asemon/app/retention.py --dry-run   # n'écrit rien
sudo -u postgres /opt/asemon/venv/bin/python3 /opt/asemon/app/retention.py             # applique
sudo systemctl start asemon-retention.service && sudo journalctl -u asemon-retention -n 5 --no-pager | grep -v truncated
```

Sortie type : `snap_db_size : 0 ligne(s) hors durée (> 1095 j), 0 ligne(s) réduite(s) à 1 point/jour (> 7 j)`. La purge de `purge_old_data()` n'est pas simulée par `--dry-run`.

Résultat du test local : un historique synthétique de 1 200 jours (2 bases et 2 tables, un point par heure, 57 602 lignes dans chaque table) est réduit à 2 514 lignes ; le contenu est identique à celui calculé indépendamment par une requête, un second passage ne supprime plus rien, et le compte de `--dry-run` égale celui de l'exécution.

## 5. Mettre à jour un POC existant

**Une fois par VM, dans l'ordre : VM-Monitoring d'abord.**

**VM-Monitoring**

```bash
cd ~/asemon-pg && git fetch && git checkout main && git pull
sudo -u postgres psql -d monitoring < sql/13-capacity.sql
sudo apt install -y python3-venv
sudo mkdir -p /opt/asemon/app && sudo python3 -m venv /opt/asemon/venv
sudo /opt/asemon/venv/bin/pip install "psycopg[binary]"
sudo cp python/retention.py /opt/asemon/app/ && sudo chmod a+rX /opt/asemon/app/retention.py
sudo cp systemd/asemon-retention.service systemd/asemon-retention.timer /etc/systemd/system/
sudo systemctl daemon-reload
cd / && sudo -u postgres /opt/asemon/venv/bin/python3 /opt/asemon/app/retention.py --dry-run
```
Le `--dry-run` doit se terminer sans erreur. Puis remplacer l'ancien timer :
```bash
sudo systemctl disable --now asemon-purge.timer
sudo rm -f /etc/systemd/system/asemon-purge.timer /etc/systemd/system/asemon-purge.service
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-retention.timer
sudo systemctl list-timers asemon-retention.timer --no-pager
```

**VM-Cible**

```bash
cd ~/asemon-pg && git fetch && git checkout main && git pull
sudo cp python/collector.py /opt/asemon/app/ && sudo chmod a+rX /opt/asemon/app/collector.py
sudo systemctl restart asemon-collector
```
`config.py` n'a pas besoin de changer (`CAPACITY_MIN_BYTES` est optionnel).

## 5 bis. Le dashboard `asemon-capacity` (3b)

URL : `/d/asemon-capacity`, lien **Capacity** dans la barre de navigation de tous les dashboards.

| Zone | Contenu |
|---|---|
| Variable **Base** | une base, ou `(toute l'instance)` (somme des bases) |
| Graphe | taille de la base sur la période (30 jours par défaut), un point par heure |
| 4 tuiles | **Taille actuelle**, **Dans 1 mois**, **Dans 6 mois**, **Dans 1 an** |
| Tableau (10 lignes, défilant) | les plus grosses tables : base, table, nombre d'**index**, lignes (estimation), taille totale, **taille dans 6 mois** |

**Extrapolation** : régression linéaire (`regr_slope`) sur les points de la période affichée ; taille future = taille actuelle + pente × durée (30, 182 ou 365 jours), jamais négative. Elle suppose un périmètre constant (pas de nouvelle table, pas de purge massive). Si les points de la période couvrent moins de **48 heures**, la tuile et la colonne affichent « historique insuffisant ». Pour que la projection ignore un événement ancien (gros chargement), raccourcir la période.

**Mise à jour d'un POC existant** (une fois, sur la machine qui fait tourner Grafana) : `git pull` sur `main`, puis dans Grafana > Dashboards > New > **Import**, charger `grafana/asemon-capacity.json` (choisir la source *ASEMON Monitoring*), puis ré-importer les 5 autres fichiers `grafana/asemon-*.json` avec remplacement pour qu'ils reçoivent le lien Capacity. Avec le script : `sudo bash ./scripts/grafana-provision.sh` fait tout.

## 6. Vérifier

Dans les 15 secondes qui suivent le redémarrage du collecteur (VM-Cible) :
```bash
sudo journalctl -u asemon-collector --since '-2 min' --no-pager | grep -E "Capacity|capacity" | grep -v truncated
```
Attendu : `Capacity OK | AAAA-MM-JJ HH:MM UTC | bases=N tables=M`.

Sur VM-Monitoring :
```sql
SELECT collected_at, datname, pg_size_pretty(size_bytes) FROM asemon.snap_db_size ORDER BY collected_at DESC, datname LIMIT 10;
SELECT datname, schemaname, relname, row_estimate, pg_size_pretty(total_bytes) AS taille, index_count
FROM asemon.snap_table_size WHERE collected_at = (SELECT max(collected_at) FROM asemon.snap_table_size)
ORDER BY total_bytes DESC LIMIT 10;
```
Une heure plus tard, une deuxième collecte apparaît (`SELECT count(DISTINCT collected_at) FROM asemon.snap_db_size;`).

## 7. Volume

Mesuré en local : environ **250 octets par ligne** de `snap_table_size`, index compris. Pour 1 000 tables : 24 000 lignes par jour, soit **6 Mo par jour** ; 7 jours à l'heure : environ 42 Mo ; au-delà, 1 000 lignes par jour (0,25 Mo par jour), soit environ 270 Mo pour les 3 ans. `snap_db_size` est négligeable. L'historique commence au déploiement : les tailles passées ne sont pas connues.

## 8. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| Journal : « Capacity planning : collecte horaire en échec … schéma sql/13 appliqué ? » | `sql/13` non appliqué, ou droits | appliquer `sql/13-capacity.sql` (donne les droits à `collector_writer`) |
| Journal : « tables de la base X ignorées » | `pg_hba.conf` de VM-Cible refuse `asemon_collect` sur cette base | autoriser le rôle sur toutes les bases en local |
| Aucune ligne `Capacity OK` | collecteur non redémarré avec le nouveau code | `sudo systemctl restart asemon-collector` |
| `retention.py` : `No module named psycopg` | venv absent ou sans psycopg | `sudo /opt/asemon/venv/bin/pip install "psycopg[binary]"` |
| `retention.py` : `permission denied` | lancé sous un autre utilisateur | `sudo -u postgres …` |
| Ancien `asemon-purge.timer` toujours actif | étape de remplacement oubliée | §5, deuxième bloc |
| Une table attendue est absente | sa taille totale est sous `CAPACITY_MIN_BYTES` | baisser la valeur dans `config.py`, redémarrer le collecteur |
