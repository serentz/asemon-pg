# Releases 3 et 4 : multi-instance, seuils, réplication

> Document de conception, rédigé le 2026-10-09 à partir de la demande suivante. **Rien n'est réalisé.** Il fixe ce qu'on construit, comment, et ce qui reste à trancher avant de coder.
>
> Rappel : la Release 1 est le dashboard unique `asemon-dashboard.json`, la Release 2 (tag `v2.0`) couvre les phases 0 à 4 (`06-roadmap-ihm.md`).

## 1. La demande

**Release 3**
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

**Release 4**
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

## 3. Conception proposée, Release 3

### 3.1 Identifier les instances

- Nouvelle table `asemon.instances` : `instance_id` (entier), `name` (par exemple `VM-Cible`), `host`, `port`, `pg_version`, `role` (`primary`, `replica`), `enabled`, `created_at`.
- **Une colonne `instance_id` sur toutes les tables** de données : `snap_*`, `event_*`, `snap_samples`, `snap_kcache`, `snap_sessions`, `snap_hourly_summary`. Les lignes existantes prennent `instance_id = 1` (la VM-Cible du POC).
- **`session_key` et `query_id` ne sont uniques qu'à l'intérieur d'une instance** (le `session_id` natif est une date et un pid, deux serveurs peuvent produire la même valeur). Toutes les jointures, index et liens de dashboard passent donc par le couple (`instance_id`, `session_key`). C'est la partie la plus délicate de la release : elle touche les 6 dashboards, `kcache_attr()`, `rollup_hourly()` et `purge_old_data()`.

### 3.2 Collecte : un agent par machine supervisée

Le collecteur lit des **fichiers et des mesures locales** (journaux PostgreSQL, `/proc` via `psutil`, espace disque). Un collecteur central distant ne pourrait pas les lire. On garde donc **le modèle actuel : un jeu de trois services (collecteur, échantillonneur, parseur) sur chaque machine supervisée**, qui écrivent dans le repository commun.

- Nouveau paramètre `INSTANCE_NAME` dans `config.py` ; l'agent s'enregistre dans `asemon.instances` au premier démarrage et reçoit son `instance_id`.
- **VM-Monitoring devient aussi une instance supervisée** : on y installe les trois services, qui écrivent dans la base locale. Ses propres sessions (collecteurs, Grafana) restent exclues des dashboards comme aujourd'hui (`is_internal`), à étendre au rôle `grafana_ro`.
- `scripts/install-target.sh` reçoit `INSTANCE_NAME` ; `install-monitoring.sh` appelle la même installation d'agent en local.

### 3.3 Volume : à traiter dans cette release

`snap_statements` pèse déjà environ **6 Go pour 30 jours et une instance** (`10-retention.md`, section « Volume mesuré »). Avec N instances, c'est N fois plus. **Ne n'écrire que les requêtes dont les compteurs ont changé** devient nécessaire. Les panneaux « état courant » du dashboard d'origine, qui lisent le dernier snapshot complet, sont à adapter dans la même release.

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

### 3.6 Modifier les seuils « sur une page »

Les dashboards Grafana sont **en lecture seule** (le rôle `grafana_ro` ne peut pas écrire) et un tableau Grafana n'est pas éditable. Trois voies (§6) : une **petite page web dédiée**, un **plugin de formulaire Grafana**, ou la modification en SQL documentée. Dans tous les cas, l'écriture passe par un rôle limité à la table `kpi_thresholds`.

### 3.7 Découpage proposé

| Étape | Contenu |
|---|---|
| 3a | `instances`, `instance_id` partout, agent paramétré par `INSTANCE_NAME`, migration des données existantes, `snap_statements` allégé |
| 3b | Dashboards existants filtrés par instance (variable, liens, requêtes) ; supervision de VM-Monitoring |
| 3c | `kpi_thresholds`, `kpi_values`, `v_instance_status`, page de modification |
| 3d | Niveau zéro (parc) et page instance (3 heures) |

3a et 3b ne changent rien à ce que l'utilisateur voit, sauf le sélecteur d'instance : on les valide d'abord sur les deux VM.

---

## 4. Conception proposée, Release 4 : réplication

**Prérequis** : une **réplique**. Il faut créer une troisième VM (`VM-Replica`), en réplication physique (streaming) depuis VM-Cible, avec un slot de réplication. Elle sert aussi de troisième instance pour tester le niveau zéro.

Mesures :
- **Sur le primaire** (`pg_stat_replication`) : `write_lag`, `flush_lag`, `replay_lag` (durées) et retard en octets (`sent_lsn`, `replay_lsn`), état, mode synchrone ; `pg_replication_slots` (slot actif, WAL retenu en octets : un slot inactif remplit le disque).
- **Sur la réplique** : `pg_last_xact_replay_timestamp()` (retard de rejeu), `pg_stat_wal_receiver`, `pg_stat_database_conflicts`.

Stockage : table `asemon.snap_replication` (par instance, par réplique). Les latences deviennent des **KPI normalisés** de `kpi_values` (`repl_replay_lag_s`, `repl_lag_bytes`, `repl_slot_retained_bytes`) avec seuils dans `kpi_thresholds` : ils apparaissent dans le niveau zéro comme tout autre KPI, sans mécanisme nouveau. Un dashboard « Réplication » (latence dans le temps, WAL retenu, état) complète la page instance.

Point d'attention : une réplique est en lecture seule ; l'agent y lit les vues statistiques et écrit dans le repository, jamais dans la réplique. Le parseur de logs et `pg_stat_kcache` y fonctionnent normalement. Un retard de réplication n'est mesurable que lorsqu'il y a de l'activité d'écriture sur le primaire (sur un primaire inactif, `replay_lag` retombe à zéro).

---

## 5. Impacts transverses

- **Installation scriptée** : `INSTANCE_NAME`, enregistrement de l'instance, installation d'agent sur VM-Monitoring ; nouveau rôle d'écriture des seuils ; VM-Replica (Release 4).
- **Rétention** : `purge_old_data()` à écrire par instance ; durées globales au départ.
- **Documentation** : une fiche par étape (comme `07` à `14`), mise à jour de `00-architecture.md`.
- **Tests** : deux instances au minimum (VM-Cible et VM-Monitoring) ; trois avec la réplique. Les VM du POC actuel sont voués à être détruits : **il faudra des VM neuves**, ce qui fera aussi office d'essai des scripts d'installation (`15-installation-scriptee.md` §7).

---

## 6. Points à trancher

| # | Question | Ma proposition |
|---|---|---|
| 1 | Où modifie-t-on les seuils ? | Petite page web dédiée (Python, sur VM-Monitoring), liée depuis Grafana ; à défaut le plugin de formulaire Grafana |
| 2 | « Valeur de blocage maximale » : quelle mesure ? | Durée maximale pendant laquelle une session a attendu un verrou dans l'heure (échantillons de 2 s), avec en complément le nombre maximal de sessions bloquées en même temps |
| 3 | « Maximum de transactions actives » : quelle mesure ? | Nombre maximal de sessions ayant une transaction ouverte au même instant (en cours d'exécution ou `idle in transaction`) |
| 4 | Valeurs par défaut des seuils | À fixer ensemble (par exemple CPU 80 % / 95 %, disque libre 20 % / 10 %) ; modifiables ensuite |
| 5 | VM disponibles pour la suite | Deux VM neuves pour la Release 3, une troisième pour la Release 4 |
