# Dashboard Grafana « ASEMON-PG — Intermédiaire » (page 2 de l'IHM)

> Deuxième page de l'IHM cible (`06-roadmap-ihm.md` §2) : qui consomme la base (camemberts par login et par programme), à quoi les sessions passent leur temps (CPU ou attentes), puis les graphiques déjà présents dans le dashboard `ASEMON-PG`, regroupés. Nouveau dashboard : `ASEMON-PG` n'est pas modifié.
>
> **Statut : importé dans Grafana et validé (2026-10-09) : camemberts, graphique empilé, graphiques système et liens de navigation corrects.**

Fichiers : `grafana/asemon-intermediate.json` (uid `asemon-intermediate`) et `grafana/asemon-macro.json` (mis à jour : liens de navigation, version 2). Dépend de `snap_samples` (`09-echantillonnage-phase2.md`).

---

## 1. Contenu

**Répartition de la charge active** (période choisie en haut, 6 h par défaut)

| Panneau | Contenu |
|---|---|
| Temps actif par login | secondes actives cumulées par `usename` |
| Temps actif par programme | secondes actives cumulées par `application_name` |
| CPU contre attentes | part du temps actif sans attente (CPU) ou par type d'attente (`IO`, `Lock`, `LWLock`, `Client`...) |
| Charge active par type d'attente | sessions actives moyennes par minute, empilées par type (graphique de type ASH) |

**Graphiques existants**, repris à l'identique de `ASEMON-PG` : CPU / mémoire / iowait, réseau, espace disque libre, cache hit ratio, fichiers temporaires, connexions vs `max_connections`, checkpoints, volume de WAL.

**Navigation** : les deux dashboards ont en haut les liens « Macro » et « Intermédiaire », qui conservent la période choisie.

### À lire avant d'interpréter les camemberts

- **Ce n'est pas un coût CPU ou I/O exact.** C'est du **temps actif échantillonné** : chaque ligne de `snap_samples` représente `interval_ms` millisecondes d'activité d'une session (2 s par défaut). « CPU » veut dire « active sans événement d'attente », pas un temps CPU mesuré. Le coût réel par session viendra de `pg_stat_kcache` (Phase 3) : les camemberts changeront alors de source, pas de forme.
- **Les sessions de ASEMON-PG sont exclues** (`application_name` commençant par `asemon-`), sinon le collecteur apparaîtrait comme un gros consommateur.
- **Les requêtes plus courtes que l'intervalle** peuvent échapper à l'échantillonnage : sur une période longue, la répartition reste juste statistiquement, pas à la requête près.
- **Pas de données avant le 9 octobre 2026** (mise en service de `asemon-sampler`) : sur une période plus ancienne, les camemberts sont vides.
- Un login ou un programme vide apparaît comme « (inconnu) » ou « (sans nom) ».

---

## 2. Import

Depuis ton clone (`git switch grafana-intermediaire`), dans Grafana :

1. **Dashboards** → **New** → **Import** → **Upload dashboard JSON file** → `grafana/asemon-intermediate.json`
2. Choisir ton datasource PostgreSQL dans le champ `DS_MONITORING` (obligatoire), puis **Import**
3. Réimporter aussi `grafana/asemon-macro.json` (même `uid`, Grafana propose d'écraser) pour obtenir les liens de navigation

Aucune VM à toucher, aucun changement de schéma.

---

## 3. Vérification

- Les 3 camemberts affichent des parts avec une légende (valeur en secondes et pourcentage).
- Lancer `SELECT pg_sleep(60);` dans une session `psql` de la VM-Cible : le login `postgres`, le programme `psql` et le type `Timeout` (attente `PgSleep`) augmentent dans les 30 s qui suivent.
- Le graphique empilé montre des barres par minute avec une légende (moyenne et maximum par type).
- Les graphiques système affichent les mêmes courbes que dans `ASEMON-PG` sur la même période.
- Les liens « Macro » / « Intermédiaire » fonctionnent dans les deux sens.

---

## 4. Limites connues

- **Pas de camembert « I/O réseau » ni « I/O disque »** comme dans la roadmap : aucune source avant Phase 3. Le type d'attente `IO` (lectures de fichiers, écritures de WAL) donne une indication, sans volume en octets.
- **Pas de filtre par base** : à ajouter si besoin (une variable Grafana sur `datname`).
- **Panneaux dupliqués** : les graphiques système existent dans `ASEMON-PG` et ici ; une correction doit être faite aux deux endroits.

---

## 5. Checklist de validation

- [x] `asemon-intermediate.json` importé, datasource choisi, aucune erreur de panneau
- [x] Trois camemberts avec légende, graphique empilé affiché
- [x] Test `pg_sleep(60)` visible dans les camemberts
- [x] Graphiques système cohérents avec `ASEMON-PG`
- [x] `asemon-macro.json` réimporté, liens de navigation fonctionnels dans les deux sens
