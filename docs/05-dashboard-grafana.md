# VM-Monitoring — Dashboard Grafana

> Fait suite à `04-metriques-etendues.md` (collecteur étendu avec toutes les catégories de métriques). Ce document couvre l'import du dashboard Grafana `ASEMON-PG`, qui visualise l'ensemble des données collectées dans le schéma `asemon`.

## Prérequis

- Grafana installé et connecté au repository (`01-VM-Monitoring-repository-grafana.md`)
- Datasource PostgreSQL configuré (`grafana_ro` sur la base `monitoring`)
- Schéma étendu appliqué (`04-metriques-etendues.md`) — le dashboard référence les tables `snap_tables`, `snap_indexes`, `snap_checkpoints`, `snap_wal`, `snap_db_age`, `snap_connections` en plus des 7 tables de base

Fichier correspondant dans le dépôt : `grafana/asemon-dashboard.json`

---

## 1. Contenu du dashboard

Le dashboard `ASEMON-PG` est organisé en 5 sections (lignes pliables) :

| Section | Panneaux |
|---|---|
| **Système** | CPU/mémoire/iowait, réseau (delta), espace disque libre, cache hit ratio, fichiers temporaires |
| **Connexions, verrous et deadlocks** | Connexions vs `max_connections`, deadlocks cumulés, verrous actuels (table), deadlocks détaillés (table : tables/users/requêtes) |
| **Requêtes et plans d'exécution** | Top requêtes `pg_stat_statements` (table), derniers plans `auto_explain` capturés (table) |
| **Maintenance** | Seq scans vs index scans / tuples morts (table), index inutilisés (table), âge des transactions par base (table, seuils de couleur pour le risque de wraparound) |
| **Checkpoints et WAL** | Checkpoints planifiés vs demandés, volume de WAL généré |

Chaque panneau de type graphique temporel respecte la période sélectionnée en haut du dashboard (`$__timeFilter`). Les panneaux de type tableau montrant un "état courant" (verrous, seq scans, index inutilisés, âge des transactions) affichent toujours le **dernier snapshot** disponible, indépendamment de la période choisie — c'est voulu : ce sont des photos de l'état actuel, pas des séries temporelles.

---

## 2. Import du dashboard

1. Dans Grafana, menu de gauche → **Dashboards** → **New** → **Import**
2. **Upload dashboard JSON file** → sélectionner `grafana/asemon-dashboard.json`
3. À l'écran suivant, mapper la variable **"Datasource ASEMON"** sur le datasource PostgreSQL existant (celui pointant vers la base `monitoring`)
4. **Import**

Le dashboard s'ouvre directement, rafraîchissement automatique toutes les 30 secondes, fenêtre par défaut sur les 6 dernières heures.

---

## 3. Piège rencontré : droits `grafana_ro` jamais réellement testés

À l'ouverture du dashboard, **tous les panneaux** affichaient une erreur :
```
db query error: ERREUR: droit refusé pour le schéma asemon (SQLSTATE 42501)
```

**Cause** : le test "Save & test" effectué lors de la configuration du datasource (voir `01-VM-Monitoring-repository-grafana.md`) ne vérifie que la connexion réseau et l'authentification — **il n'exécute aucune requête sur le schéma**. Les droits `GRANT USAGE ON SCHEMA asemon TO grafana_ro` déclarés dans `sql/02-roles-and-grants.sql` n'avaient donc jamais été concrètement exercés jusqu'à la première vraie requête du dashboard, et se sont révélés ne pas avoir été appliqués — exactement le même symptôme que celui déjà rencontré avec `collector_writer` lors du déploiement du collecteur (voir `01-VM-Monitoring-repository-grafana.md`, section droits).

**Correction**, à exécuter sur VM-Monitoring :
```bash
sudo -u postgres psql -d monitoring <<'EOF'
GRANT USAGE ON SCHEMA asemon TO grafana_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA asemon TO grafana_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA asemon GRANT SELECT ON TABLES TO grafana_ro;
EOF
```

Vérification :
```bash
sudo -u postgres psql -d monitoring -c "\dp asemon.snap_os"
psql -h 192.168.1.28 -U grafana_ro -d monitoring -c "SELECT count(*) FROM asemon.snap_os;"
```

> **Enseignement pour la suite du projet** : un "Save & test" réussi sur un datasource Grafana ne garantit pas que le rôle utilisé peut réellement lire les tables cibles. Toujours valider les droits d'un rôle applicatif par une requête réelle sur au moins une table de chaque schéma concerné, pas seulement par un test de connexion.

---

## 4. Piège rencontré : panneaux "No data" à cause de la fenêtre temporelle

Après correction des droits, deux panneaux restaient vides en "Last 6 hours" :
- **"Deadlocks détaillés"**
- **"Derniers plans d'exécution capturés"**

**Cause** : ces panneaux filtrent sur `$__timeFilter(occurred_at)`. Les événements de test (deadlocks, plans `auto_explain`) avaient été générés plusieurs jours auparavant, donc hors de la fenêtre par défaut. Élargir la période à "Last 7 days" a confirmé que les données étaient bien présentes et correctement remontées — ce n'était pas un bug de requête.

**À distinguer** d'un troisième panneau resté vide pour une raison différente : **"Index inutilisés (idx_scan = 0)"** — celui-ci reste vide en continu car aucun index de la base de test n'a `idx_scan = 0` (les deux index de test ont `idx_scan = 16`). C'est le comportement attendu : absence de données = absence d'index inutilisés, pas une erreur.

> **Enseignement** : face à un panneau vide, distinguer trois causes possibles avant de chercher un bug : (1) la période sélectionnée n'inclut pas les données existantes, (2) le filtre de la requête exclut légitimement toutes les lignes actuelles (cas normal), (3) une vraie erreur de droits ou de syntaxe SQL (repérable par l'icône triangle rouge sur le panneau, contrairement aux deux premiers cas qui affichent juste "No data" sans erreur).

---

## 5. Checklist de validation

- [ ] Dashboard `ASEMON-PG` importé, datasource correctement mappé
- [ ] Droits `grafana_ro` corrigés (`GRANT USAGE ON SCHEMA` + `GRANT SELECT ON ALL TABLES`)
- [ ] Tous les panneaux "graphique temporel" affichent des données sur la période par défaut
- [ ] Tous les panneaux "tableau d'état courant" (verrous, seq scans, âge transactions) affichent le dernier snapshot
- [ ] "Deadlocks détaillés" et "Derniers plans d'exécution" confirmés fonctionnels en élargissant la période
- [ ] Dashboard sauvegardé (`Save`)

---

## 6. Prochaines étapes (hors périmètre de cette fiche)

- Alertes Grafana sur les seuils critiques (cache hit ratio < 99%, `idle in transaction` trop long, âge des transactions élevé, `num_requested` de checkpoints élevé)
- Partitionnement et rétention sur les tables `asemon.snap_*` à fort volume, identifiés dès `04-metriques-etendues.md`
- Ajout du lag de réplication si un réplica est mis en place
- Éventuellement : dashboard variabilisé par instance surveillée, si le POC est étendu à plusieurs VM cibles
