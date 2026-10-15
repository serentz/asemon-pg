# Release 3 : captures des dashboards monAp_pg

Captures prises sur les VM du POC le 2026-10-15 (Grafana, thème sombre, période « Last 6 hours »), après le renommage en monAp_pg. Charge : `pgbench` (`bench`, 2 clients, 50 transactions par seconde) lancée le 2026-10-14 à 16:50 UTC. Les captures de la Release 2 sont dans `images/Release_2/`.

| Capture | Dashboard | Ce qu'on y voit |
|---|---|---|
| `01-macro.png` | Macro | Tuiles d'indicateurs avec tendance, résumé par heure |
| `02-intermediaire-repartition.png` | Intermédiaire | Répartition du temps actif (login, programme, CPU contre attentes), coûts mesurés `pg_stat_kcache`, charge par type d'attente |
| `03-intermediaire-attentes-systeme.png` | Intermédiaire | CPU / mémoire / iowait, réseau, espace disque, cache hit ratio, fichiers temporaires, connexions |
| `04-intermediaire-connexions-wal.png` | Intermédiaire | Connexions vs `max_connections`, checkpoints, volume de WAL |
| `05-micro-top10.png` | Micro | Top 10 sessions et requêtes, variable « Trier par » |
| `06-detail-session.png` | Détail session | Identité, temps actif, coûts mesurés, charge par type d'attente |
| `07-detail-session-executions.png` | Détail session | Une ligne par exécution relevée, plans et deadlocks de la session |
| `08-detail-requete.png` | Détail requête | Texte SQL (boîte de 10 lignes), temps actif, appels, coûts mesurés, courbes |
| `09-detail-requete-sessions-plans.png` | Détail requête | Sessions, plan d'exécution lisible (boîte de 15 lignes), tableau des plans |
| `10-capacity.png` | Capacity planning | Taille de la base, tuiles de projection, 10 plus grosses tables |

Lecture des captures :
- Les heures affichées sont en heure de Paris (UTC+2) ; la base stocke l'UTC.
- Sur `10-capacity.png`, les projections affichent « historique insuffisant » : la période de 6 heures couvre moins de 48 h de points. Avec la période par défaut de 30 jours, elles apparaissent à partir de 48 h d'historique.
- Les captures proviennent de VM avec la base surveillée `bench` ; le thème, la période et les données sont ceux du POC.
