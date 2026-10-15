# Release 4 : captures des dashboards monAp_pg

Captures prises sur les VM du POC le 2026-10-15 (Grafana 13, thème sombre, période « Last 30 days »), après la validation de la Release 4d. Deux instances surveillées : **VM-Cible** (charge `pgbench`) et **VM-Monitoring**. Les captures de la Release 3 sont dans `images/Release_3/`.

| Capture | Dashboard | Ce qu'on y voit |
|---|---|---|
| `01-parc.png` | Parc (niveau zéro) | Trois tuiles (instances en alarme, en avertissement, sans mesure récente), une ligne par instance avec son indicateur le plus problématique, graphe de gravité |
| `02-instance.png` | Instance (VM-Cible) | État actuel des 6 indicateurs, une ligne par heure sur les 3 dernières heures |
| `03-macro.png` | Macro | Sélecteur **Instance** et nouvelle barre de navigation à 7 boutons |
| `04-intermediaire.png` | Intermédiaire | Répartition de la charge et coûts mesurés pour l'instance choisie |
| `05-micro.png` | Micro | Top 10 sessions et requêtes pour l'instance choisie, variable « Trier par » |
| `06-capacity.png` | Capacity planning | Taille de la base de l'instance choisie, projections, 10 plus grosses tables |
| `07-seuils.png` | Seuils | Seuils en vigueur par instance, explication, formulaire « Modifier un seuil » |

Lecture des captures :
- Les heures affichées sont en heure de Paris (UTC+2) ; la base stocke l'UTC.
- Sur `07-seuils.png`, la barre de navigation n'a que 5 boutons : cette page n'a pas été réimportée sur le POC pour garder le lien du formulaire vers la source « ASEMON Seuils ». Le fichier du dépôt (`grafana/asemon-thresholds.json`) a les 7 boutons.
- Sur `01-parc.png`, le graphe de gravité ne commence qu'à l'installation de la Release 4c, et la colonne Hôte affiche `localhost` tant que `INSTANCE_HOST` n'est pas réglé ([docs/22](../../docs/22-parc-et-instance.md)).
- Sur `06-capacity.png`, les projections affichent « historique insuffisant » avant 48 h d'historique.
