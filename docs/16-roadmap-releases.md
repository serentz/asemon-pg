# Releases suivantes : plans, capacity planning, multi-instance, seuils, réplication

> Document de conception. **Rien n'est réalisé.** Il fixe ce qu'on construit, comment, et ce qui reste à trancher avant de coder.
>
> Rappel : la Release 1 est le dashboard unique `asemon-dashboard.json`, la Release 2 (tag `v2.0`) couvre les phases 0 à 4 (`06-roadmap-ihm.md`).

## 0. Ordre des releases (révisé le 2026-10-11)

| Release | Contenu | Section |
|---|---|---|
| **v2.1** | Plans d'exécution : pourquoi si peu de plans sont capturés ; SQL et plans lisibles (encadré de 6 lignes, indenté, avec ascenseur) | §A |
| **Release 3** (nouvelle) | **Capacity planning** : taille et nombre de lignes des tables, taille des bases, extrapolation ; `retention.py` | §B |
| **Release 4** (ancienne 3) | Multi-instance, niveau zéro, seuils, page instance | §1 à §3 |
| **Release 5** (ancienne 4) | Réplication et latence | §4 |

---

## A. v2.1 : plans d'exécution

> **Réalisation : voir [17-plans-v2.1.md](17-plans-v2.1.md)** (codé le 2026-10-11, à valider sur les VM).

### A.1 La demande

- Comprendre **pourquoi on capture si peu de plans**.
- Rendre lisibles le **texte SQL** et le **plan d'exécution** : dans la page requête, chacun dans un **encadré de 6 lignes maximum, indenté, avec un ascenseur** sur le côté si le contenu dépasse.

### A.2 Diagnostic : pourquoi si peu de plans

Cause la plus probable, à confirmer sur les VM (§A.3) : **`auto_explain.log_min_duration = 500`** (docs `02-VM-Cible.md` §3.4 et `install-target.sh`). `auto_explain` ne journalise un plan que si la requête dure **500 ms ou plus**. Or la charge du POC (`pgbench`) exécute des requêtes de quelques millisecondes : aucune n'atteint le seuil. Les seuls plans visibles dans les captures de la Release 2 sont ceux de `SELECT pg_sleep(...)` lancés à la main. Le KPI « Requêtes lentes » de la page macro est le nombre de plans capturés : il compte donc les requêtes de plus de 500 ms, pas toutes les requêtes lentes au sens de l'application.

Le parseur de logs (`log_parser.py`) n'est a priori **pas en cause** : il enregistre tout message `duration: … plan: {…}` qu'il lit. La vérification du §A.3 (nombre de plans dans les logs contre lignes de `event_plans`) le confirmera.

Un point à connaître : avec `auto_explain.log_analyze = on` et `log_timing = on`, PostgreSQL **mesure déjà chaque requête** (le surcoût est payé que le plan soit journalisé ou non). **Baisser le seuil n'ajoute donc pas de surcoût de mesure** ; cela augmente seulement le volume de journaux, d'écritures du parseur et de lignes dans `event_plans`.

### A.2 bis Résultats des vérifications (2026-10-11)

| Mesure | Résultat | Lecture |
|---|---|---|
| `auto_explain.log_min_duration`, `sample_rate` | 500 ms, 1 | seuil confirmé, aucune réduction par échantillonnage |
| Plans dans `event_plans` | 7 le 2026-09-25 (de 9,1 s à 120 s), 9 le 2026-10-09 (de 2 s à 60 s) | **16 plans en tout, tous de plus de 2 s** : ce sont les `pg_sleep` de test |
| `pg_stat_statements` : durée moyenne ≥ 500 ms / ≥ 100 ms / total | 5 / 6 / 122 | **la charge du POC n'a presque aucune requête lente** : passer le seuil à 100 ms n'ajouterait qu'**une** requête |

**Conclusion** : le seuil de 500 ms est bien la porte d'entrée, mais il n'est pas seul en cause : les requêtes de `pgbench` durent quelques millisecondes en moyenne. Pour capturer plus de plans, il faut **soit un seuil nettement plus bas** (quelques dizaines de millisecondes, à choisir d'après la distribution des durées, §A.3 bis), **soit une charge qui contient de vraies requêtes lentes**. Le comptage des lignes `plan:` des journaux n'a pas pu être fait (le caractère générique du nom de fichier est développé par un shell sans droit de lecture) ; commande corrigée au §A.3 bis.

### A.3 Vérifications à faire (VM-Cible puis VM-Monitoring)

```bash
# VM-Cible : seuil actif, et nombre de plans réellement écrits dans les journaux
sudo -u postgres psql -At -c "SHOW auto_explain.log_min_duration; SHOW auto_explain.sample_rate;"
sudo grep -c "plan:" /var/lib/postgresql/17/main/log/postgresql-*.json
# VM-Cible : combien de requêtes dépassent le seuil en moyenne (pg_stat_statements)
sudo -u postgres psql -c "SELECT count(*) FILTER (WHERE mean_exec_time >= 500) AS lentes_500ms, count(*) FILTER (WHERE mean_exec_time >= 100) AS lentes_100ms, count(*) AS total FROM pg_stat_statements;"
# VM-Monitoring : plans stockés
sudo -u postgres psql -d monitoring -c "SELECT date_trunc('day', occurred_at) AS jour, count(*), round(min(duration_ms)) AS min_ms, round(max(duration_ms)) AS max_ms FROM asemon.event_plans GROUP BY 1 ORDER BY 1;"
```

Lecture : si le nombre de lignes `plan:` des journaux est **égal** au nombre de lignes de `event_plans` et si `min_ms` est au-dessus de 500, c'est bien le seuil.

### A.3 bis Compléments à relever

```bash
# VM-Cible : lignes plan: dans les journaux (le caractère générique doit être développé par root)
sudo sh -c 'grep -c "plan:" /var/lib/postgresql/17/main/log/postgresql-*.json'
# VM-Cible : distribution des durées, pour choisir le seuil
sudo -u postgres psql -c "SELECT count(*) FILTER (WHERE max_exec_time >= 500) AS max_500, count(*) FILTER (WHERE max_exec_time >= 100) AS max_100, count(*) FILTER (WHERE max_exec_time >= 50) AS max_50, count(*) FILTER (WHERE max_exec_time >= 10) AS max_10, count(*) FILTER (WHERE mean_exec_time >= 10) AS moy_10, count(*) FILTER (WHERE mean_exec_time >= 1) AS moy_1 FROM pg_stat_statements;"
```

### A.4 Corrections proposées

| Levier | Proposition | Remarque |
|---|---|---|
| `auto_explain.log_min_duration` | **à choisir d'après la distribution des durées** (§A.3 bis) : de l'ordre de 20 à 100 ms ; 500 ms ne capture que les requêtes très lentes | réglage dans `conf.d/asemon.conf` ; un `reload` suffit, pour les nouvelles connexions |
| `auto_explain.sample_rate` | 1 (défaut) ; à baisser (par exemple 0,2) si le volume devient trop grand | n'explique que la fraction demandée des requêtes |
| Limite par requête | **au plus 5 plans par requête (`query_id`) et par heure** (`PLAN_MAX_PER_QUERY_HOUR` dans `config.py`) | évite qu'une requête rapide mais très fréquente remplisse la table ; les plans conservés sont les premiers de l'heure |
| Empreinte du plan (`plan_hash`) | colonne ajoutée à `event_plans` : hachage de la structure du plan sans les mesures | permet de voir qu'un plan **change** pour une même requête (étape ultérieure) |

Le seuil exact se règle après essai : on regarde le nombre de plans par heure sous charge (`pgbench`) et on ajuste. Pour tester la lisibilité des plans, on ajoute à la charge de test une requête volontairement lente (jointure sans index sur les tables `pgbench_*`).

### A.5 Lisibilité du SQL et des plans

**Mise en forme à l'enregistrement**, pas à l'affichage (Grafana ne sait pas indenter du SQL ni du JSON dans un tableau) :
- **SQL** : le collecteur formate une seule fois chaque nouvelle requête (`sqlparse`, bibliothèque Python pure ajoutée à `requirements.txt`) et la range dans une petite table `asemon.query_text` (`queryid`, `query`, `query_formatted`).
- **Plan** : le parseur produit, en plus du JSON, un **texte arborescent** comme celui de `EXPLAIN` (`Hash Join (cost=… rows=…) (actual time=… rows=… loops=…)`, puis les enfants indentés avec `->`), dans une nouvelle colonne `event_plans.plan_text`. Les plans déjà stockés sont convertis par un script unique.

**Affichage** : un panneau **Business Text** (plugin Grafana, identifiant `marcusolsson-dynamictext-panel`, à valider à l'installation, comme le plugin de formulaire de la Release 4) affiche le texte dans un bloc `<pre>` de hauteur limitée à 6 lignes avec ascenseur vertical. Le plugin s'installe avec `grafana cli plugins install` : à ajouter à `install-monitoring.sh`.

Sur la page requête :
1. **Texte SQL** : un encadré de 6 lignes, indenté, ascenseur.
2. **Plans capturés** : un tableau (quand, durée, session) ; **un clic sélectionne un plan**, qui s'affiche dans un encadré de 6 lignes identique, sous le tableau.

Repli si le plugin ne convient pas : un tableau Grafana standard avec retour à la ligne, mais l'indentation des espaces n'y est pas garantie.

---

## B. Release 3 : capacity planning

### B.1 La demande

Une nouvelle page **Capacity planning** pour suivre l'évolution du nombre de lignes et de la taille des tables, et de l'espace utilisé par les bases.

- **Collecte** : le collecteur écrit **un point par heure** pour chaque table (taille et nombre de lignes).
- **Rétention** : sur VM-Monitoring, un script **`retention.py`** gère la rétention dans la base `monitoring`. Pour les tables de points de taille : **1 point par heure sur la dernière semaine, 1 point par jour au-delà, 3 ans au maximum**.
- **Page**, deux parties :
  1. le **graphe de l'évolution de la taille de la base**, et dessous une ligne : **taille actuelle**, **extrapolation à 1 mois, 6 mois et 1 an** ;
  2. un **tableau de 10 lignes avec ascenseur** : les 10 tables les plus grosses (nom de la table, nombre d'index, nombre de lignes, taille), et une dernière colonne : **extrapolation de la taille à 6 mois « à périmètre constant »**.

### B.2 Collecte : un point par heure

Nouvelles tables (VM-Monitoring) :

| Table | Une ligne par | Colonnes principales |
|---|---|---|
| `asemon.snap_db_size` | base et heure | `collected_at`, `datname`, `size_bytes` (`pg_database_size`) |
| `asemon.snap_table_size` | table et heure | `collected_at`, `datname`, `schemaname`, `relname`, `row_estimate`, `table_bytes` (heap), `index_bytes`, `toast_bytes`, `total_bytes`, `index_count` (nombre d'index de la table) |

- **Une fois par heure** : le collecteur garde en mémoire l'heure UTC du dernier point écrit et écrit au premier cycle d'une nouvelle heure. Au redémarrage, il lit la dernière heure écrite dans le repository (pas de doublon).
- **Nombre de lignes = estimation** (`n_live_tup`, à défaut `reltuples`) : un `count(*)` exact sur toutes les tables, chaque heure, serait trop coûteux. L'estimation suit les passages d'autovacuum et d'analyze ; elle est précise à quelques pour cent près, ce qui suffit pour une tendance.
- **Toutes les bases** : aujourd'hui le collecteur ne se connecte qu'à la base `postgres`. Pour les tailles, il ouvre **brièvement une connexion par base** (hors modèles `template*`), une fois par heure. `asemon_collect` a le droit de connexion par défaut ; les fonctions de taille ne demandent pas de droit sur les tables.
- **Tables suivies** : celles des schémas utilisateur, au-dessus d'un seuil de taille (`CAPACITY_MIN_BYTES`, 64 ko par défaut dans `config.py`), pour borner le volume : 1 000 tables donnent 24 000 lignes par jour avant réduction.
- **Historique** : il commence au déploiement (les tailles passées ne sont pas connues). Les extrapolations sont peu fiables avant quelques jours de données ; la page l'indique (« historique insuffisant » sous 48 heures).

### B.3 `retention.py` (VM-Monitoring)

Un script Python, lancé chaque jour par un timer systemd (`asemon-retention.timer`), qui applique la rétention de la base `monitoring`.

- **Réduction des points de capacity planning** : pour `snap_db_size` et `snap_table_size`, les points de **plus de 7 jours** sont réduits à **un par jour et par objet (le dernier point du jour UTC)** ; ceux de **plus de 1 095 jours (3 ans)** sont supprimés. Les durées sont des paramètres de `asemon.settings` (`capacity_full_days` = 7, `capacity_max_days` = 1095).
- **Rejouable et mesurable** : option `--dry-run` (affiche ce qui serait supprimé sans rien modifier), une ligne de bilan par table dans le journal.
- **Droits** : le script tourne sous l'utilisateur `postgres` (authentification locale), comme les autres timers. Il demande un environnement Python sur VM-Monitoring (aujourd'hui seule VM-Cible en a un) : `install-monitoring.sh` le crée.
- **Périmètre (à confirmer, §6)** : proposition : `retention.py` devient **le point d'entrée unique de la rétention** : il appelle `asemon.purge_old_data()` (rétention actuelle des `snap_*`, événements et sessions) puis applique la réduction ci-dessus ; `asemon-retention.timer` remplace `asemon-purge.timer`. La maintenance des partitions de `snap_samples` (`maintain_samples()`, toutes les heures) reste sur son timer.

### B.4 La page « Capacity planning »

Un dashboard `asemon-capacity`, avec une variable **base** (une base, ou la somme de l'instance), des liens de navigation comme les autres pages.

**Partie 1 : la base**
- Un graphe de l'évolution de la taille.
- Dessous, une ligne de 4 tuiles : **taille actuelle**, **dans 1 mois**, **dans 6 mois**, **dans 1 an**.
- **Méthode d'extrapolation** : régression linéaire (moindres carrés) sur la période du dashboard (30 jours par défaut) : `taille actuelle + pente × durée`. Calculée en SQL (`regr_slope`). Une croissance qui s'accélère est sous-estimée ; une tuile affiche « historique insuffisant » sous 48 heures de points.

**Partie 2 : les tables**
- Un tableau avec ascenseur, 10 lignes triées par taille décroissante.
- Colonnes : **table**, **nombre d'index** (il explique en partie la taille de la table), **lignes**, **taille** (totale : table + index + TOAST), **taille dans 6 mois**.
- **« À périmètre constant »** : la projection suppose que rien ne change dans l'usage (pas de nouvelle table, pas d'archivage ni de purge ajoutés) : même régression linéaire, appliquée à chaque table sur la période du dashboard.

### B.5 Découpage proposé

> **3a validée sur les VM et fusionnée (2026-10-14). 3b (dashboard) codée le 2026-10-14, à valider sur Grafana : voir [18-capacity-planning.md](18-capacity-planning.md).**

| Étape | Contenu |
|---|---|
| 3a | Tables `snap_db_size` et `snap_table_size`, collecte horaire, droits, `retention.py` et son timer, mise à jour de `install-*.sh` |
| 3b | Dashboard `asemon-capacity` et extrapolations |
| Tests | en local sur PostgreSQL 16 avec un historique synthétique (régression, réduction à 1 point par jour, 3 ans) ; puis sur les VM actuelles |

---

## 1. Release 4 : la demande

**Release 4**
- Ajouter un **niveau zéro, multi-instance** : une ligne ou un graphe par instance, avec le KPI ou le graphe **le plus problématique**.
- Des **seuils d'alarme et d'avertissement** par instance et par KPI, **modifiables sur une page**, **stockés dans une table**.
- Une **page instance** avec une ligne **par heure, pour les 3 dernières heures**, qui contient :
  - le pic de CPU : pourcentage et heure ;
  - la valeur de blocage maximale (verrous) ;
  - le nombre de deadlocks ;
  - le nombre maximal de transactions actives ;
  - l'espace disque disponible ;
  - la durée de la transaction la plus longue.
- Instances à superviser : `VM-Cible` et `VM-Monitoring`.

**Release 5**
- Surveillance de la **réplication**, avec la **latence**.

---

## 2. Navigation cible

```
Niveau 0 : Parc          une ligne par instance, KPI le plus problématique, couleur d'état
   └─ Instance           3 dernières heures, une ligne par heure (les 6 indicateurs ci-dessus)
        └─ Macro → Intermédiaire → Micro → Détail session / Détail requête     (Release 2, filtrés sur l'instance)
Page seuils              consultation et modification des seuils
```

Les dashboards de la Release 2 deviennent **filtrés par instance** : une variable `instance` sur chacun, transmise par tous les liens.

---

## 3. Conception proposée, Release 4

### 3.1 Identifier les instances

- Nouvelle table `asemon.instances` : `instance_id` (entier), `name` (par exemple `VM-Cible`), `host`, `port`, `pg_version`, `role` (`primary`, `replica`), `enabled`, `created_at`.
- **Une colonne `instance_id` sur toutes les tables** de données : `snap_*`, `event_*`, `snap_samples`, `snap_kcache`, `snap_sessions`, `snap_hourly_summary`. Les lignes existantes prennent `instance_id = 1` (la VM-Cible du POC).
- **`session_key` et `query_id` ne sont uniques qu'à l'intérieur d'une instance** (le `session_id` natif est une date et un pid, deux serveurs peuvent produire la même valeur). Toutes les jointures, index et liens de dashboard passent donc par le couple (`instance_id`, `session_key`). C'est la partie la plus délicate de la release : elle touche les 6 dashboards, `kcache_attr()`, `rollup_hourly()` et `purge_old_data()`.

### 3.2 Collecte : un agent par machine supervisée

Le collecteur lit des **fichiers et des mesures locales** (journaux PostgreSQL, `/proc` via `psutil`, espace disque). Un collecteur central distant ne pourrait pas les lire. On garde donc **le modèle actuel : un jeu de trois services (collecteur, échantillonneur, parseur) sur chaque machine supervisée**, qui écrivent dans le repository commun.

- Nouveau paramètre `INSTANCE_NAME` dans `config.py` ; l'agent s'enregistre dans `asemon.instances` au premier démarrage et reçoit son `instance_id`.
- **VM-Monitoring devient aussi une instance supervisée** : on y installe les trois services, qui écrivent dans la base locale. Ses propres sessions (collecteurs, Grafana) restent exclues des dashboards comme aujourd'hui (`is_internal`), à étendre au rôle `grafana_ro`.
- `scripts/install-target.sh` reçoit `INSTANCE_NAME` ; `install-monitoring.sh` appelle la même installation d'agent en local.

### 3.3 Volume et index (point d'attention : performances)

Une grosse `snap_statements` est normale pour ce type de table (environ 6 Go pour 30 jours et une instance, `10-retention.md`) : **la taille n'est pas un problème en soi, on ne change pas la collecte** (décision du 2026-10-09). Ce qui compte, c'est la **performance** :

- Avec plusieurs instances, **chaque index doit commencer par `instance_id`** (par exemple `(instance_id, collected_at)` à la place de `(collected_at)`), puisque toutes les requêtes des dashboards filtrent d'abord sur l'instance puis sur la période. Un index sur le temps seul obligerait à parcourir les lignes de toutes les instances.
- Chaque index ajouté **ralentit les écritures** : le collecteur insère 100 lignes par cycle dans `snap_statements`, par instance. On garde le strict nécessaire, on mesure avant et après avec `EXPLAIN (ANALYZE, BUFFERS)` sur les requêtes des dashboards, et on ne conserve que les index réellement utilisés (`pg_stat_user_indexes`, `idx_scan`).
- Les requêtes « dernier snapshot par requête » (texte SQL, appels, temps moyen) sont les plus coûteuses sur cette table : à vérifier en priorité, avec un index `(instance_id, queryid, collected_at DESC)`.
- La création des index sur des tables déjà grosses se fait hors des heures de collecte (`CREATE INDEX CONCURRENTLY`), et le script de migration doit être rejouable.
- La rétention (`purge_old_data()`) supprime par `DELETE` sur ces tables : le coût d'une purge croît avec le volume ; à mesurer, et à passer en partitionnement par jour (comme `snap_samples`) si elle devient trop longue.

### 3.4 Seuils

Table `asemon.kpi_thresholds` :

| Colonne | Rôle |
|---|---|
| `instance_id` | `NULL` = seuil par défaut pour toutes les instances ; une valeur = surcharge pour cette instance |
| `kpi` | clé du KPI (`cpu_pct`, `disk_free_pct`, `lock_wait_s`, `deadlocks`, `active_xacts`, `longest_xact_s`, plus tard `repl_lag_s`) |
| `warn_value`, `crit_value` | seuils d'avertissement et d'alarme |
| `direction` | `high` (trop haut est mauvais) ou `low` (trop bas est mauvais, comme l'espace disque) |
| `enabled`, `updated_at`, `updated_by` | activation et traçabilité |

Évaluation : une vue `asemon.v_instance_status` compare la dernière valeur de chaque KPI aux seuils effectifs (surcharge d'instance, sinon défaut) et en déduit un **état** (`ok`, `warning`, `critical`) et un **degré de gravité** (valeur rapportée au seuil). **Le KPI le plus problématique d'une instance est celui de plus grand degré de gravité.** Le niveau zéro l'affiche avec sa valeur, son seuil et un graphe de son évolution.

Pour que ce graphe fonctionne quel que soit le KPI, le rollup alimente en plus une table normalisée `asemon.kpi_values` (`instance_id`, `ts`, `kpi`, `value`), calculée toutes les 5 minutes avec le résumé horaire.

### 3.5 Les indicateurs de la page instance

Tous sont calculables à partir de ce qui est déjà collecté ; une ligne par heure UTC, les 3 dernières (l'heure courante est partielle) :

| Indicateur demandé | Source existante | Précision à valider |
|---|---|---|
| Pic de CPU, % et heure | `snap_os.cpu_percent` (max, et `collected_at` de ce max) | CPU de **la machine**, pas de PostgreSQL |
| Valeur de blocage maximale | `snap_samples` (attentes `Lock`, 2 s) ou `snap_locks` | voir questions (§6) |
| Nombre de deadlocks | `event_deadlocks` | |
| Maximum de transactions actives | `snap_activity` (`xact_start` non nul) ou `snap_connections` | voir questions (§6) |
| Espace disque disponible | `snap_os.disk_free_bytes` (minimum de l'heure) | disque de `/` seulement |
| Durée de la transaction la plus longue | `snap_activity` : `collected_at - xact_start` (maximum) | précision de 15 s |

`snap_hourly_summary` reçoit ces colonnes, calculées par instance.

### 3.6 Modifier les seuils « sur une page » (décision : plugin de formulaire Grafana)

Les dashboards Grafana sont en lecture seule et un tableau Grafana n'est pas éditable. **Choix retenu : le plugin de formulaire Grafana** (panneau « Business Forms » de Volkov Labs), pour que tout reste dans Grafana.

- Installation sur VM-Monitoring : `sudo grafana cli plugins install volkovlabs-form-panel`, puis redémarrage de Grafana (accès Internet nécessaire ; à intégrer dans `install-monitoring.sh`). À valider à l'installation : nom exact du plugin et compatibilité avec la version de Grafana installée.
- Une **seconde datasource** PostgreSQL, `ASEMON Seuils`, utilise un rôle `grafana_thresholds` qui n'a que `SELECT`, `INSERT` et `UPDATE` sur `asemon.kpi_thresholds` (rien d'autre). Les dashboards de lecture continuent d'utiliser `grafana_ro`.
- La page « Seuils » affiche un tableau des seuils effectifs par instance et un formulaire (instance, KPI, avertissement, alarme, activé) dont la validation écrit dans la table.
- **Limite à connaître** : dans Grafana open source, les permissions par datasource n'existent pas ; toute personne pouvant éditer un dashboard peut interroger cette datasource. Le rôle SQL limité à une seule table borne le risque. À restreindre en ne donnant le droit d'édition de la page qu'aux administrateurs.

### 3.7 Découpage proposé

> **Numérotation** : les étapes ci-dessous (3a à 3d) sont celles de la **Release 4**. **4a** (schéma, index, agents) codée le 2026-10-15, à valider sur les VM : voir [19-multi-instance.md](19-multi-instance.md). La vérification des **index utilisés** (`idx_scan`) se fait après quelques jours d'usage.

| Étape | Contenu |
|---|---|
| 3a | `instances`, `instance_id` partout, **index revus** (§3.3), agent paramétré par `INSTANCE_NAME`, migration des données existantes |
| 3b | Dashboards existants filtrés par instance (variable, liens, requêtes) ; supervision de VM-Monitoring |
| 3c | `kpi_thresholds`, `kpi_values`, `v_instance_status`, page de modification |
| 3d | Niveau zéro (parc) et page instance (3 heures) |

3a et 3b ne changent rien à ce que l'utilisateur voit, sauf le sélecteur d'instance : on les valide d'abord sur les deux VM.

---

## 4. Conception proposée, Release 5 : réplication

**Prérequis** : une **réplique**. Il faut créer une troisième VM (`VM-Replica`), en réplication physique (streaming) depuis VM-Cible, avec un slot de réplication. Elle sert aussi de troisième instance pour tester le niveau zéro.

Mesures :
- **Sur le primaire** (`pg_stat_replication`) : `write_lag`, `flush_lag`, `replay_lag` (durées) et retard en octets (`sent_lsn`, `replay_lsn`), état, mode synchrone ; `pg_replication_slots` (slot actif, WAL retenu en octets : un slot inactif remplit le disque).
- **Sur la réplique** : `pg_last_xact_replay_timestamp()` (retard de rejeu), `pg_stat_wal_receiver`, `pg_stat_database_conflicts`.

Stockage : table `asemon.snap_replication` (par instance, par réplique). Les latences deviennent des **KPI normalisés** de `kpi_values` (`repl_replay_lag_s`, `repl_lag_bytes`, `repl_slot_retained_bytes`) avec seuils dans `kpi_thresholds` : ils apparaissent dans le niveau zéro comme tout autre KPI, sans mécanisme nouveau. Un dashboard « Réplication » (latence dans le temps, WAL retenu, état) complète la page instance.

Point d'attention : une réplique est en lecture seule ; l'agent y lit les vues statistiques et écrit dans le repository, jamais dans la réplique. Le parseur de logs et `pg_stat_kcache` y fonctionnent normalement. Un retard de réplication n'est mesurable que lorsqu'il y a de l'activité d'écriture sur le primaire (sur un primaire inactif, `replay_lag` retombe à zéro).

---

## 5. Impacts transverses

- **Installation scriptée** : `INSTANCE_NAME`, enregistrement de l'instance, installation d'agent sur VM-Monitoring ; nouveau rôle d'écriture des seuils ; VM-Replica (Release 5).
- **Rétention** : `purge_old_data()` à écrire par instance ; durées globales au départ.
- **Documentation** : une fiche par étape (comme `07` à `14`), mise à jour de `00-architecture.md`.
- **Tests** : deux instances au minimum (VM-Cible et VM-Monitoring, **les VM actuelles, conservées jusqu'à la fin du projet**) ; trois avec la réplique (Release 5, VM à créer). Les scripts d'installation (`15-installation-scriptee.md` §7) seront essayés sur des VM neuves à la fin.

---

## 6. Décisions et points restants

| # | Question | Décision |
|---|---|---|
| 1 | Où modifie-t-on les seuils ? | **Plugin de formulaire Grafana** (§3.6) |
| 2 | « Valeur de blocage maximale » | **Durée maximale d'attente d'une session sur un verrou dans l'heure** (échantillons de 2 s), avec le nombre maximal de sessions bloquées en même temps en complément |
| 3 | « Maximum de transactions actives » | **Nombre maximal de sessions ayant une transaction ouverte au même instant**, y compris `idle in transaction` |
| 4 | Valeurs par défaut des seuils | **Validées** : CPU 80 % / 95 %, disque libre 20 % / 10 %, blocage 30 s / 120 s, transaction la plus longue 300 s / 1 800 s, deadlocks 1 / 5 par heure (avertissement / alarme) ; modifiables ensuite dans la page |
| 5 | VM disponibles pour la suite | **Release 4 : les deux VM actuelles** (VM-Cible, VM-Monitoring), toujours en service. **Release 5 : une troisième VM à créer** (réplique) |
| 6 | Taille de `snap_statements` | Normale, **pas de changement de collecte** ; vigilance sur les index (§3.3) |

### Points ajoutés le 2026-10-11

| # | Question | Proposition (à confirmer) |
|---|---|---|
| 7 | Les corrections de plans (§A) forment-elles une version **v2.1** avant la Release 3 ? | **Oui** : v2.1, puis Release 3 (capacity planning) |
| 8 | Seuil `auto_explain` | **Décidé le 2026-10-11 : 100 ms** (la distribution n'a rien entre 1 ms et 500 ms : le seuil n'est pas le facteur limitant) ; au plus 5 plans par requête et par heure ; requêtes lentes ajoutées à la charge de test (`scripts/charge-lente.sh`) |
| 9 | Périmètre de `retention.py` | **Oui, point d'entrée unique de la rétention** : appelle `purge_old_data()` puis réduit les points de capacité ; remplace `asemon-purge.timer` ; `maintain_samples()` reste sur son timer horaire |
| 10 | Point conservé par jour après réduction | Le **dernier** point du jour UTC |
| 11 | Colonne « index » du tableau des 10 plus grosses tables | **Le nombre d'index seulement** (il explique en partie la taille de la table) |
| 12 | « Taille de la table » | **Taille totale** : table + index + TOAST (cohérent avec le choix du nombre d'index) |
| 13 | Extrapolation | Régression linéaire sur la période du dashboard (30 jours par défaut) |

