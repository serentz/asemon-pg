# Release 2 : captures des dashboards

Captures prises sur les VM du POC le 2026-10-09 (Grafana, thème sombre, période « Last 6 hours »). La Release 1 était le dashboard unique `grafana/asemon-dashboard.json` (captures dans `images/phase1/`).

| Capture | Dashboard | Ce qu'on y voit |
|---|---|---|
| `01-macro.png` | Macro | Tuiles d'indicateurs avec tendance, résumé par heure sur 6 heures |
| `02-intermediaire-repartition.png` | Intermédiaire | Répartition du temps actif (login, programme, CPU contre attentes) et, en dessous, les **coûts mesurés** `pg_stat_kcache` : CPU et I/O disque par login (exact) et par programme (réparti, avec la part « non attribué ») |
| `03-intermediaire-attentes-systeme.png` | Intermédiaire | Charge active par type d'attente, CPU / mémoire / iowait, réseau, espace disque, cache hit ratio, fichiers temporaires |
| `04-intermediaire-connexions-wal.png` | Intermédiaire | Connexions vs `max_connections`, checkpoints, volume de WAL |
| `05-micro-top10.png` | Micro | Top 10 sessions et top 10 requêtes, variable « Trier par » |
| `06-detail-session.png` | Détail session | Identité, temps actif (CPU, I/O, verrous), tuiles de coûts mesurés, charge par type d'attente |
| `07-detail-session-executions.png` | Détail session | Une ligne par exécution relevée, plans et deadlocks de la session |
| `08-detail-requete.png` | Détail requête | Texte SQL, temps actif, appels, temps moyen, coûts mesurés, courbes |
| `09-detail-requete-sessions-plans.png` | Détail requête | Sessions qui ont exécuté la requête, plans `auto_explain` |

Lecture des captures :
- Les heures affichées sont en heure de Paris (UTC+2) ; la base stocke l'UTC.
- Les coûts mesurés (CPU, lu, écrit) de `06` sont à zéro : cette session `pgbench` date de 14:01 UTC, avant l'activation de la collecte `pg_stat_kcache` (15:24 UTC). Ils sont à zéro aussi pour `08`, normalement : `pg_sleep` n'utilise pas de CPU.
- La grande part « (non attribué) » de `02` correspond aux requêtes plus courtes que l'intervalle d'échantillonnage de 2 s (voir `docs/00-architecture.md` §4).
