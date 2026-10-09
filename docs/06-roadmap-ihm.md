# ASEMON-PG — Réflexion IHM et roadmap (session / requête)

> Ce document est une **réflexion d'architecture et une feuille de route**, pas une fiche d'installation comme les précédentes. Il formalise la vision cible de l'interface (navigation du général vers la requête SQL, en passant par la session) et liste ce qui doit changer dans le collecteur et le schéma pour la rendre possible. Au départ, rien de ce qui est décrit ici n'était déployé. Les phases 1 à 4 sont maintenant réalisées (voir le tableau du §5) ; ce document est conservé comme **historique des choix**. Pour l'état actuel, voir `README.md` et `00-architecture.md`.

## 1. Principe directeur

L'interface s'organise selon deux axes orthogonaux :

- **Axe temporel** : de l'instant présent vers l'historique (dernières heures, puis plus loin).
- **Axe de granularité** : de l'instance globale vers la session, puis vers la requête SQL individuelle.

Le modèle métier sous-jacent est celui d'une **entité session**, avec un cycle de vie propre :

```
Connexion (login, programme, adresse cliente, heure de début)
   │
   ├── Requête SQL #1 (début, fin, coût CPU, I/O réseau, I/O disque, mémoire, plan)
   ├── Requête SQL #2 (...)
   └── ...
   │
Déconnexion (heure de fin)
```

À cela s'ajoutent les sessions internes du moteur (autovacuum, walwriter, checkpointer, background workers), qui doivent être visibles mais traitées séparément des sessions utilisateur dans les vues.

C'est le même paradigme que l'**Active Session History** d'Oracle (ASH/AWR) ou que les APM applicatifs (Datadog, New Relic) : toute donnée de coût est rattachée à une session, elle-même rattachable à une fenêtre de temps.

---

## 2. Proposition d'IHM (3 pages)

### Page 1 — Vue macro

- Bandeau de KPI/compteurs instantanés : sessions actives, connexions vs `max_connections`, cache hit ratio, deadlocks sur la période, requêtes lentes en cours, charge CPU/mémoire de l'hôte.
- **Gabarit de widget retenu pour chaque KPI** : une tuile compacte (fond sombre) avec le libellé en haut, la valeur courante en gros avec son delta (`+436`, `+9`, ...), et une sparkline de tendance en bas de tuile, dans la couleur d'accent du thème — voir `images/references/kpi-tile-sparkline.png` pour l'exemple de référence. Chaque tuile est autonome et peut être dupliquée pour n'importe quel KPI de la page (sessions actives, deadlocks, requêtes lentes, cache hit ratio, etc.).
- En dessous, **un résumé par heure sur les 6 dernières heures** (1 ligne = 1 heure), avec les mêmes KPI agrégés, pour repérer en un coup d'œil une période anormale avant de zoomer dessus.

### Page 2 — Vue intermédiaire

- Les graphiques déjà présents dans le dashboard actuel (CPU/mémoire/iowait, réseau, cache hit ratio, checkpoints, WAL, etc.).
- Nouveaux panneaux : **camemberts de répartition des coûts** (CPU, I/O réseau, I/O disque) par login et par nom de programme (`application_name`), sur la période sélectionnée.

### Page 3 — Vue micro

- **Top 10 sessions**, triable par coût CPU / I/O réseau / I/O disque.
  → clic sur une ligne → détail de la session : liste de toutes ses requêtes exécutées (heure de début/fin, coûts), sur sa durée de vie complète.
- **Top 10 requêtes SQL**, triable par coût CPU / I/O réseau / I/O disque.
  → clic sur une ligne → détail de la requête : texte SQL complet, coûts agrégés, plan d'exécution (`auto_explain`).
- Pour boucler le modèle plutôt que d'en faire un arbre à sens unique : depuis le détail d'une requête, un lien retour vers **la liste des sessions qui l'ont exécutée**.

---

## 3. Ce qui bloque aujourd'hui : deux réconciliations à construire

Le collecteur actuel (`python/collector.py`) fonctionne par **snapshots périodiques** de vues statistiques PostgreSQL. C'est suffisant pour des graphiques de tendance, mais **insuffisant pour reconstituer des entités "session" et "exécution de requête"** avec un vrai début/fin et un coût exact. Deux obstacles précis :

### 3.1 La session n'a pas de cycle de vie fiable

`pg_stat_activity` est un instantané : on voit les connexions vivantes au moment du snapshot, mais :
- si une connexion est trop courte, elle peut être manquée entre deux cycles de collecte ;
- l'heure de connexion exacte n'est pas garantie (on prend `backend_start`, disponible, mais la déconnexion n'est **jamais** visible dans ce flux — on ne peut que déduire "le pid a disparu entre deux snapshots").

**Solution retenue** : exploiter les logs serveur, comme cela a déjà été fait pour les deadlocks. Activer `log_connections` et `log_disconnections` dans `postgresql.conf`, et étendre `log_parser.py` pour alimenter une nouvelle table `asemon.snap_sessions` avec des horodatages exacts. Ces messages n'ont pas de SQLSTATE exploitable : le serveur doit être en `lc_messages = 'C'` (voir `07-sessions-phase1.md`).

### 3.2 PostgreSQL ne trace pas l'exécution individuelle d'une requête

- `pg_stat_statements` est **cumulatif** par requête normalisée (`queryid`), tous appelants confondus, depuis le dernier reset. Il expose `userid`/`dbid` (donc un camembert "coût par login" est déjà possible), mais **pas `application_name`** — donc le camembert "par programme" ne peut pas venir de cette vue.
- `pg_stat_statements.total_exec_time` est un **temps mur** (wall time), pas un temps CPU. PostgreSQL ne mesure pas nativement le CPU consommé par requête.
- `auto_explain` capture bien des exécutions individuelles (durée + plan), mais uniquement celles dépassant le seuil configuré (`log_min_duration`) — ce n'est pas une trace exhaustive.

**Deux stratégies possibles**, non exclusives :

| Approche | Principe | Avantage | Coût |
|---|---|---|---|
| **A. Échantillonnage haute fréquence** (type Active Session History) | Sampler `pg_stat_activity` toutes les 1 à 5 secondes (au lieu de 15s), en conservant `pid`, `usename`, `application_name`, `query_id`, `wait_event`, `state` | Attribution *approchée* du temps par login/programme/requête, par pondération temporelle — sans extension supplémentaire | Volume de données en forte hausse → nécessite rétention agressive et rollups |
| **B. Capture exacte par extension** | `pg_stat_kcache` (CPU réel par `queryid` via `getrusage()`) + `pg_wait_sampling` (histogramme d'attentes à haute fréquence) | Chiffres exacts, CPU et attentes réels | Extensions supplémentaires à installer et qualifier sur VM-Cible |

**Recommandation** : combiner les deux, en commençant par (A) qui ne demande aucune extension nouvelle, puis ajouter (B) pour fiabiliser le CPU par requête une fois le modèle de données en place.

---

## 4. Évolution de schéma proposée (à qualifier avant déploiement)

Il manque une **clé de session stable** traversant les tables, pour permettre les jointures nécessaires au drill-down (macro → session → requête). Proposition détaillée dans `sql/05-schema-sessions.sql` (non déployé, à relire et adapter avant exécution) :

- `asemon.snap_sessions` : une ligne par session, alimentée par le parsing des logs de connexion/déconnexion (`log_parser.py` étendu).
- `asemon.snap_query_exec` : une ligne par exécution de requête détectée par échantillonnage (approche A). **Finalement non créée** : une exécution se déduit de `snap_samples` (`session_key`, `query_start`), ce que montrent les dashboards de détail.
- Ajout de la colonne `session_key` dans `snap_activity`, `event_plans`, `event_deadlocks`, pour pouvoir reconstituer "quelles requêtes/plans/deadlocks appartiennent à quelle session". **Définition retenue** : le `session_id` natif de PostgreSQL (`<epoch hexa>.<pid hexa>`, ex. `6ac8acf0.9bd`), présent dans chaque ligne du jsonlog et reconstructible depuis `pg_stat_activity` — la formule initiale `pid || '-' || extract(epoch from backend_start)` ne pouvait pas être reproduite côté logs (secondes entières seulement). Voir `07-sessions-phase1.md`.
- Table de rollup `asemon.snap_hourly_summary`, pré-calculée (vue matérialisée ou job planifié), pour que la page 1 n'ait jamais à agréger les snapshots bruts à la volée.

---

## 5. Plan en phases

| Phase | Contenu | Prérequis | Statut |
|---|---|---|---|
| **Phase 0** | Existant : snapshots 15s, dashboard Grafana actuel | — | ✅ Fait |
| **Phase 1** | `snap_sessions` via logs de connexion/déconnexion ; `session_key` ajoutée aux tables existantes ; page macro avec rollup horaire | Activer `log_connections`/`log_disconnections` ; étendre `log_parser.py` | **En cours** — sessions : déployé et validé le 2026-10-09 (`07-sessions-phase1.md`). Rollup horaire `snap_hourly_summary` : déployé et validé (`08-rollup-horaire.md`) |
| **Phase 2** | Échantillonnage resserré des sessions actives (`snap_samples`, 2 s, rétention 14 j, voir `09-echantillonnage-phase2.md`) ; camemberts par login | Volume et rétention traités dans `09` ; reste à brancher les camemberts (Phase 4) | Échantillonneur déployé et validé (2026-10-09) |
| **Phase 3** | Camemberts par programme ; CPU réel par requête | Installer `pg_stat_kcache` (+ éventuellement `pg_wait_sampling`) sur VM-Cible | Extension installée et validée (2026-10-09) ; collecte déployée et validée (`14-kcache-phase3.md`) ; I/O réseau non mesurable, abandonnée ; dashboards adaptés et validés (`14-kcache-phase3.md` §8) |
| **Phase 4** | Pages 1/2/3 complètes dans Grafana (ou interface dédiée si Grafana atteint ses limites de navigation drill-down inter-pages) | Phases 1-3 | En cours : page 1 macro validée (`11-dashboard-macro.md`), page 2 validée (`12-dashboard-intermediaire.md`), page 3 validée (`13-dashboard-micro.md`) ; coûts réels (Phase 3) validés |

**Point de vigilance pour la Phase 4** : Grafana gère bien les tableaux de bord juxtaposés, mais le drill-down "clic sur une ligne → page de détail contextualisée" (session → ses requêtes, requête → ses sessions) est plus naturel avec des liens de variables de dashboard (`${__data.fields.session_key}` en lien vers un autre dashboard) qu'avec un vrai routage applicatif. À tester avant de considérer Grafana comme la cible finale de cette navigation ; une petite interface web dédiée reste une option de repli si les besoins de navigation deviennent trop riches pour ce mécanisme.

---

## 6. Ce qui n'est pas remis en cause

- Le socle actuel (collecteur, parseur, schéma `asemon`, services systemd, dashboard Grafana) reste la fondation : les phases ci-dessus l'étendent, elles ne le remplacent pas.
- Les métriques déjà couvertes (`04-metriques-etendues.md`) restent valables et alimenteront la page 2 telle quelle.
