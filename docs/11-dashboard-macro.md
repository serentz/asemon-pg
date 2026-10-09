# Dashboard Grafana « ASEMON-PG — Macro » (page 1 de l'IHM)

> Première page de l'IHM cible (`06-roadmap-ihm.md` §2) : huit tuiles d'indicateurs avec sparkline, et un résumé « une ligne par heure » sur les 6 dernières heures. C'est un **nouveau dashboard**, importé à côté de `ASEMON-PG` qui n'est pas modifié.
>
> **Statut : importé dans Grafana et validé (2026-10-09) : 8 tuiles et tableau horaire corrects.**

Fichier : `grafana/asemon-macro.json` (uid `asemon-macro`, rafraîchissement 30 s, période par défaut 6 h).

Dépend de : `snap_connections`, `snap_os`, `snap_hourly_summary` (`08-rollup-horaire.md`) et `snap_samples` (`09-echantillonnage-phase2.md`), déjà déployés.

---

## 1. Contenu

| Tuile | Source | Valeur affichée | Seuils de couleur |
|---|---|---|---|
| Sessions actives | `snap_connections.active_connections` | dernier cycle (variation en % sur la période) | aucun |
| Connexions / max_connections | `snap_connections` | % du maximum, dernier cycle | orange > 70 %, rouge > 85 % |
| CPU hôte | `snap_os.cpu_percent` | dernier cycle | aucun |
| Mémoire hôte | `snap_os.mem_percent` | dernier cycle | aucun |
| Cache hit ratio | `snap_hourly_summary` | dernière heure | rouge < 95 %, orange < 99 %, vert ≥ 99 % |
| Deadlocks | `snap_hourly_summary.total_deadlocks` | **total** sur la période | rouge dès 1 |
| Requêtes lentes | `snap_hourly_summary.total_slow_queries` | **total** sur la période | orange dès 1, rouge dès 10 |
| Charge active moyenne | `snap_samples` | sessions actives moyennes par minute, dernière minute | aucun |

Dessous, le tableau « Une ligne par heure » : les 6 dernières lignes de `snap_hourly_summary`, indépendantes de la période choisie en haut. Les colonnes Deadlocks, Requêtes lentes et Cache hit % sont colorées avec les mêmes seuils.

Précisions :
- La sparkline de chaque tuile suit la **période** sélectionnée en haut (6 h par défaut). Les tuiles Cache hit ratio, Deadlocks et Requêtes lentes ont un point par **heure pleine UTC** ; les autres un point par cycle du collecteur (15 s).
- Les totaux Deadlocks et Requêtes lentes comptent des heures entières : la première heure peut commencer avant le début de la période (léger surcomptage possible).
- Les heures du tableau sont des heures pleines UTC, **affichées dans le fuseau du navigateur** (heure de Paris chez toi).
- « Charge active moyenne » vient de l'échantillonnage : il n'y a pas de point pour une minute sans session active, et le tableau de bord n'affiche rien tant que `asemon-sampler` n'a pas écrit.
- La variation en % sous la valeur (Sessions actives, CPU, Mémoire) dépend de la version de Grafana : si elle n'apparaît pas, ce n'est qu'un détail d'affichage, la valeur et la sparkline restent.

---

## 2. Import

Copier `grafana/asemon-macro.json` sur ton PC (il est dans ton clone), puis dans Grafana :

1. **Dashboards** → **New** → **Import** → **Upload dashboard JSON file** → `grafana/asemon-macro.json`
2. Mapper « Datasource ASEMON » sur le datasource PostgreSQL existant (base `monitoring`)
3. **Import**

Pour mettre à jour plus tard : refaire l'import avec le même fichier (même `uid`), Grafana propose de l'écraser.

Aucun changement de schéma, aucune VM à toucher : `grafana_ro` lit déjà toutes les tables utilisées.

---

## 3. Vérification

- Les 8 tuiles affichent une valeur (sinon : message « No data » sur la tuile concernée, à me signaler avec son nom).
- Le tableau (colonnes « Sessions moy. » et « Sessions max ») contient 6 lignes (ou moins si le collecteur n'a pas tourné 6 heures).
- Comparaison avec le dashboard `ASEMON-PG` : mêmes valeurs de CPU, mémoire et connexions sur la même période.
- La tuile « Deadlocks » correspond à tes tests du jour (un deadlock provoqué sur la période = 1 ou plus).
- Un `pg_sleep(60)` lancé sur la cible fait monter « Charge active moyenne » à environ 1 pendant la minute concernée.

---

## 4. Limites connues

- **Pas de variation absolue (« +436 »)** comme dans la tuile de référence `images/references/kpi-tile-sparkline.png` : Grafana n'affiche nativement qu'une variation en %. Une tuile entièrement personnalisée demanderait un panneau HTML ou un plugin ; à discuter si nécessaire.
- **Navigation** : liens vers la page intermédiaire ajoutés (`12-dashboard-intermediaire.md`) ; le lien vers la page micro viendra avec elle.
- **« Requêtes lentes en cours »** (roadmap) n'est pas une tuile : un snapshot toutes les 15 s les manquerait. La tuile « Requêtes lentes » compte les plans capturés par `auto_explain`.

---

## 5. Checklist de validation

- [x] Dashboard importé, datasource mappé, aucune erreur de panneau
- [x] 8 tuiles avec valeur et sparkline
- [x] Tableau horaire : 6 lignes cohérentes avec `snap_hourly_summary`
- [x] Valeurs cohérentes avec le dashboard `ASEMON-PG`
- [x] Dashboard `ASEMON-PG` existant inchangé
