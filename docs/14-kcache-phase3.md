# Phase 3 : CPU et I/O disque réels par requête (`pg_stat_kcache`)

> Jusqu'ici, les coûts affichés (pages 2 et 3) étaient du **temps actif échantillonné** : une approximation. `pg_stat_kcache` mesure, pour chaque requête, le **temps CPU réellement consommé** et les **octets réellement lus et écrits sur le disque**, à partir des compteurs du noyau (`getrusage`). Le collecteur lit ces compteurs à chaque cycle et stocke les écarts.
>
> **Statut : extension installée et validée sur VM-Cible (2026-10-09). Collecte déployée et validée sur les VM (2026-10-09) : totaux exacts conservés par l'attribution (CPU 11 787 ms contre 11 786 ms ; écritures 161 Mo contre 162 Mo). Dashboards pages 2 et 3 et détails mis à jour et validés (§8).**

Fichiers :
- `python/collector.py` : lecture de `pg_stat_kcache()`, calcul des écarts, écriture dans `snap_kcache` (VM-Cible)
- `sql/11-schema-kcache.sql` : table `asemon.snap_kcache` et fonction `asemon.kcache_attr()` (VM-Monitoring)
- `sql/09-retention.sql` : la purge couvre maintenant `snap_kcache` (à rejouer, idempotent)

---

## 1. Ce qui est mesuré, et ce qui ne l'est pas

`pg_stat_kcache` compte, par **(requête, utilisateur, base)** :

| Mesure | Unité | Détail |
|---|---|---|
| Temps CPU utilisateur | secondes | exécution (et planification si `track_planning` est actif) |
| Temps CPU système | secondes | idem |
| Octets lus | octets | **lectures physiques** demandées au système de fichiers : une page servie par le cache du système n'est pas comptée |
| Octets écrits | octets | écritures faites par le processus de la requête |

Ce que cela **ne** donne **pas** :
- **L'I/O réseau** : aucune extension standard ne la mesure par requête. Les camemberts et colonnes « I/O réseau » de la roadmap (`06-roadmap-ihm.md`) restent donc sans objet.
- **Les écritures différées** : une page modifiée est le plus souvent écrite plus tard par le *bgwriter* ou le *checkpointer*, qui ne sont pas rattachés à une requête. Les écritures mesurées sont **inférieures** aux écritures réelles ; ne pas les lire comme un volume d'écriture total.
- **Le journal WAL** : voir `snap_wal` pour le volume global.
- **Le CPU des processus parallèles** (workers lancés par une requête parallèle) : à notre connaissance, il n'est pas inclus dans le compteur de la requête.
- **Une requête très courte** : la mesure CPU a la granularité du noyau ; une requête de quelques microsecondes peut afficher 0.

### Exact ou réparti ?

| Axe | Qualité |
|---|---|
| Par **requête** et par **login** | **mesure exacte** : `pg_stat_kcache` donne directement `queryid` et utilisateur |
| Par **session** et par **programme** (`application_name`) | **répartition approchée** : `pg_stat_kcache` ne connaît pas la session. Le coût d'une requête mesuré entre deux cycles est réparti entre les sessions qui l'exécutaient d'après les échantillons de `snap_samples`, au prorata de leur temps actif. Un coût sans aucun échantillon correspondant (requête trop courte pour être vue) reste attribué au login et à la requête, avec la session « non attribuée ». **Le total est toujours conservé.** |

C'est la fonction `asemon.kcache_attr(début, fin)` qui fait cette répartition au moment de la lecture, sur la période demandée.

---

## 2. Installation de l'extension (VM-Cible) : fait le 2026-10-09

Procédure telle qu'elle doit être suivie, avec la correction d'un piège rencontré (§2.2) :

```bash
sudo apt install -y postgresql-17-pg-stat-kcache
sudo -u postgres psql -c "SHOW shared_preload_libraries;"      # reprendre la valeur actuelle
sudo -u postgres psql -c "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements', 'auto_explain', 'pg_stat_kcache';"
sudo systemctl restart postgresql
sudo -u postgres psql -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_kcache CASCADE;"
```

`pg_stat_statements` doit rester dans la liste : `pg_stat_kcache` en dépend. `compute_query_id` doit valoir `on` ou `auto` (c'est `auto` ici, qui s'active tout seul avec `pg_stat_statements`).

### 2.1 Redémarrage

Il coupe les connexions quelques secondes. Le collecteur, l'échantillonneur et le parseur de logs se reconnectent seuls.

### 2.2 Piège : `ALTER SYSTEM` et les listes

> Pour `shared_preload_libraries`, **chaque bibliothèque est une valeur distincte**, avec ses propres guillemets : `'a', 'b', 'c'`. Écrit `'a,b,c'`, PostgreSQL enregistre **un seul nom** `"a,b,c"` dans `postgresql.auto.conf` et le serveur **refuse de démarrer** (`could not access file "a,b,c"`).

C'est ce qui est arrivé lors de l'installation : le serveur est resté arrêté environ 7 minutes. Réparation, serveur arrêté :

```bash
sudo cp /var/lib/postgresql/17/main/postgresql.auto.conf ~/postgresql.auto.conf.bak
sudo sed -i "s|^shared_preload_libraries = .*|shared_preload_libraries = 'pg_stat_statements,auto_explain,pg_stat_kcache'|" /var/lib/postgresql/17/main/postgresql.auto.conf
sudo systemctl start postgresql@17-main
```

(Dans ce fichier, la forme `'a,b,c'` entre guillemets simples est valide ; c'est la commande `ALTER SYSTEM` qui demande la forme `'a', 'b', 'c'`.)

### 2.3 Marche arrière

```bash
sudo -u postgres psql -c "ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements', 'auto_explain';"
sudo systemctl restart postgresql
```

Le collecteur détecte l'absence de `pg_stat_kcache()` : il écrit un avertissement dans le journal et continue sans l'extension (nouvel essai toutes les 10 minutes). Rien d'autre n'est à défaire.

---

## 3. Déploiement du code

PowerShell, dans ton clone :

```powershell
cd I:\POC_ASEMON\asemon-pg
git fetch origin
git switch phase3-kcache
scp sql\09-retention.sql sql\11-schema-kcache.sql admin01@192.168.1.28:~/
scp python\collector.py admin01@192.168.1.30:~/
```

**VM-Monitoring, d'abord** (la table doit exister avant que le collecteur écrive dedans) :

```bash
sudo -u postgres psql -d monitoring < ~/11-schema-kcache.sql
sudo -u postgres psql -d monitoring < ~/09-retention.sql        # rejeu : la purge couvre snap_kcache
sudo -u postgres psql -d monitoring -c "\d asemon.snap_kcache" | head -14
```

**VM-Cible ensuite** :

```bash
sudo cp ~/collector.py /opt/asemon/app/collector.py
sudo chown admin01: /opt/asemon/app/collector.py
sudo systemctl restart asemon-collector
sleep 40
sudo journalctl -u asemon-collector -n 4 --no-pager | grep -v truncated
```

---

## 4. Vérification

Le premier cycle après le redémarrage du collecteur **amorce** les compteurs (aucun écart écrit) ; les suivants écrivent les écarts. Générer de la charge sur VM-Cible :

```bash
sudo -u postgres pgbench -c 4 -T 60 bench     # base créée pour les tests précédents ; sinon : sudo -u postgres createdb bench && sudo -u postgres pgbench -i -s 10 bench
```

Puis sur **VM-Monitoring** :

```bash
sudo -u postgres psql -d monitoring -c "SELECT count(*), min(sampled_at), max(sampled_at) FROM asemon.snap_kcache;"
sudo -u postgres psql -d monitoring -c "SELECT usename, queryid, round(sum(cpu_user_ms + cpu_system_ms)) AS cpu_ms, pg_size_pretty(sum(reads_bytes)::bigint) AS lus, pg_size_pretty(sum(writes_bytes)::bigint) AS ecrits FROM asemon.snap_kcache WHERE sampled_at > now() - interval '10 minutes' GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 8;"
sudo -u postgres psql -d monitoring -c "SELECT usename, application_name, round(sum(cpu_ms)) AS cpu_ms FROM asemon.kcache_attr(now() - interval '10 minutes', now()) WHERE NOT is_internal GROUP BY 1, 2 ORDER BY 3 DESC;"
```

Attendu :
- le journal du collecteur affiche `kcache=N` à la fin de la ligne « Snapshot OK » (0 au premier cycle, puis N > 0 pendant la charge) ;
- `snap_kcache` contient des lignes ; les requêtes `pgbench` (`UPDATE pgbench_accounts`, `commit`...) sont en tête pour le CPU ;
- la 3e requête répartit le CPU par login et par programme (`pgbench`), avec éventuellement une ligne « non attribué » (application_name vide) pour les requêtes trop courtes pour être échantillonnées.

Comparaison utile : le CPU total mesuré sur la période doit être du même ordre que la charge CPU de la VM pendant la même minute (pas égal : le CPU de la VM comprend aussi le noyau, le WAL, les autres processus).

---

## 5. Paramètres

| Paramètre | Où | Défaut | Rôle |
|---|---|---|---|
| `snapshot_retention_days` | `asemon.settings` (VM-Monitoring) | 30 | rétention de `snap_kcache`, avec les autres snapshots (`10-retention.md`) |
| `KCACHE_RETRY_S` | `python/collector.py` | 600 | délai avant un nouvel essai si l'extension est absente |
| `pg_stat_kcache.track` | PostgreSQL (VM-Cible) | `top` | `top` : requêtes de premier niveau, comme `snap_samples` ; `all` compterait aussi les requêtes imbriquées (doublons avec leur requête parente) ; ne pas changer sans raison |
| `pg_stat_kcache.track_planning` | PostgreSQL (VM-Cible) | `off` | ajoute le temps de planification (déjà additionné au collecteur s'il est activé) |

Intervalle de lecture : c'est celui du collecteur (`INTERVAL`, 15 s dans `config.py`). Un intervalle plus court affine la répartition par session, au prix de plus de lignes.

---

## 6. Volume

Une ligne par requête **ayant consommé quelque chose** pendant le cycle (pas une ligne par requête connue) : de quelques lignes (base au repos) à quelques dizaines (charge). Environ 100 octets par ligne : de l'ordre de 5 à 20 Mo par jour sous charge continue, nettement moins au repos, purgés après 30 jours. À mesurer après une journée :

```sql
SELECT pg_size_pretty(pg_total_relation_size('asemon.snap_kcache')), count(*) FROM asemon.snap_kcache;
```

---

## 7. Limites connues

- **Redémarrage ou reset de `pg_stat_kcache`** : le cumul repart de zéro ; le collecteur le détecte (compteur qui diminue) et prend la valeur courante. Un redémarrage du **collecteur** perd l'écart du cycle en cours (l'état est en mémoire).
- **Période sans collecteur** : aucun écart n'est écrit ; les compteurs continuent de croître et sont rattrapés au cycle suivant, mais **attribués à ce cycle**, d'où un pic possible juste après une panne.
- **Requête évincée** de la table de `pg_stat_statements` (`pg_stat_statements.max` = 10000) : ses compteurs disparaissent ; s'ils reviennent, ils repartent de zéro, ce qui est géré comme un reset.
- **Répartition par session** : fiable en moyenne sur une période de quelques minutes ou plus ; pour un cycle isolé, c'est une estimation.
- **Interne exclu** : le login `asemon_collect` et les programmes `asemon-*` sont marqués `is_internal` et exclus des tableaux (comme dans les pages 2 et 3).

---

## 8. Dashboards (mis à jour)

Aucune modification de la base : il suffit de **réimporter les 4 JSON** (même uid, « Overwrite ») : `asemon-intermediate.json`, `asemon-micro.json`, `asemon-session.json`, `asemon-query.json`.

| Page | Ajout |
|---|---|
| Page 2 (intermédiaire) | Rangée « Coûts mesurés » : 4 camemberts : CPU par login (exact), CPU par programme (réparti), I/O disque par login (exact), I/O disque par programme (réparti). Part « (non attribué) » = requêtes trop courtes pour l'échantillonnage. |
| Page 3, top sessions | Colonnes « CPU mesuré », « Lu », « Écrit » (réparties) |
| Page 3, top requêtes | Mêmes colonnes (exactes). Les requêtes invisibles à l'échantillonnage y apparaissent, avec un temps actif à 0. |
| Page 3, « Trier par » | Nouvelles valeurs : CPU mesuré, Lectures disque, Écritures disque |
| Détail session / requête | Tuiles « CPU mesuré », « Lu sur disque », « Écrit sur disque » (sur la période du dashboard) |

Rappels : les lectures disque restent à 0 tant que les données tiennent dans le cache de l'OS ; ASEMON-PG lui-même est exclu (login `asemon_collect`, programmes `asemon-*`).

---

## 9. Checklist de validation

- [x] `postgresql-17-pg-stat-kcache` installé, `shared_preload_libraries` correct, extension créée, serveur en ligne
- [x] `11-schema-kcache.sql` et `09-retention.sql` exécutés sur VM-Monitoring, sans erreur
- [x] `collector.py` déployé, `kcache=N` visible dans le journal
- [x] Test `pgbench` : `snap_kcache` rempli, requêtes `pgbench` en tête du CPU
- [x] `kcache_attr()` répartit le CPU par login et par programme
- [ ] Volume relevé après une journée
- [x] Dashboards réimportés et validés
