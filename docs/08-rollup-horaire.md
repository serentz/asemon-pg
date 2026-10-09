# Rollup horaire (`snap_hourly_summary`)

> Prépare la **page macro** de l'IHM (`06-roadmap-ihm.md` §2) : le résumé « une ligne par heure sur les 6 dernières heures ». Une fonction SQL agrège les snapshots bruts toutes les 5 minutes, de sorte que Grafana lise une table de quelques lignes au lieu de ré-agréger des dizaines de milliers de snapshots à chaque ouverture de page.
>
> **Statut : écrit et testé en local (PostgreSQL 16, données synthétiques), pas encore déployé sur VM-Monitoring.**

Fichiers concernés :
- `sql/06-rollup-horaire.sql` : table `asemon.snap_hourly_summary` et fonction `asemon.rollup_hourly()`
- `systemd/asemon-rollup.service` et `systemd/asemon-rollup.timer` : exécution toutes les 5 minutes

---

## 1. Colonnes et définitions

Une ligne par **heure pleine UTC** (`hour_bucket`).

| Colonne | Définition | Source |
|---|---|---|
| `avg_cpu_percent` | moyenne sur l'heure | `snap_os.cpu_percent` |
| `avg_mem_percent` | moyenne sur l'heure | `snap_os.mem_percent` |
| `avg_active_sessions` | moyenne des sessions `active` | `snap_connections.active_connections` |
| `max_active_sessions` | maximum des sessions `active` | `snap_connections.active_connections` |
| `total_deadlocks` | nombre de deadlocks enregistrés dans l'heure | `event_deadlocks` (parseur de logs) |
| `total_slow_queries` | nombre de plans capturés dans l'heure, c'est-à-dire de requêtes au-dessus du seuil `auto_explain.log_min_duration` | `event_plans` (parseur de logs) |
| `cache_hit_ratio` | en **%** : `100 × Σ Δblks_hit / (Σ Δblks_hit + Σ Δblks_read)` | `snap_io` |

Précisions :
- **Cache hit ratio** : calculé sur les écarts entre snapshots successifs de chaque base, puis sommés. Un écart négatif (redémarrage de PostgreSQL, `pg_stat_reset`) est ignoré. Ce n'est donc pas le ratio cumulé depuis le démarrage, qui masquerait les variations. L'écart entre deux snapshots est rattaché à l'heure du plus récent.
- **Deadlocks et requêtes lentes** : comptés à partir des événements du parseur de logs. Si le parseur est arrêté, ces deux compteurs sous-estiment. Le compteur cumulé `pg_stat_database.deadlocks` (panneau « Deadlocks cumulés ») reste la référence de contrôle.
- **Heure courante** : partielle, recalculée à chaque exécution.
- **Heure sans aucun snapshot** (collecteur arrêté) : pas de ligne, plutôt qu'une ligne de zéros trompeuse. Un trou dans la table signale donc un trou dans la collecte.
- **Fuseau** : les heures sont tronquées en UTC quel que soit le fuseau de la session (testé avec `Asia/Kolkata`, +5:30).

---

## 2. Déploiement (VM-Monitoring)

Copier les trois fichiers sur la VM (depuis PowerShell, dans ton clone) :

```powershell
cd I:\POC_ASEMON\asemon-pg
git pull
scp sql\06-rollup-horaire.sql systemd\asemon-rollup.service systemd\asemon-rollup.timer admin01@192.168.1.28:~/
```

Puis sur la VM-Monitoring :

```bash
# 1. Table et fonction (la redirection < est nécessaire : postgres ne peut pas lire /home/admin01)
sudo -u postgres psql -d monitoring < ~/06-rollup-horaire.sql

# 2. Premier calcul, et rattrapage de l'historique existant (ici 30 jours, à adapter)
sudo -u postgres psql -d monitoring -c "SELECT asemon.rollup_hourly(24 * 30);"

# 3. Timer
sudo cp ~/asemon-rollup.service ~/asemon-rollup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-rollup.timer
```

---

## 3. Vérification

```bash
sudo systemctl list-timers asemon-rollup.timer --no-pager
sudo systemctl start asemon-rollup.service && sudo journalctl -u asemon-rollup -n 3 --no-pager | grep -v truncated
sudo -u postgres psql -d monitoring -c "SELECT hour_bucket, avg_cpu_percent, avg_active_sessions, max_active_sessions, total_deadlocks, total_slow_queries, cache_hit_ratio FROM asemon.snap_hourly_summary ORDER BY hour_bucket DESC LIMIT 7;"
```

Attendu :
- le timer est listé avec un prochain déclenchement dans moins de 5 minutes ;
- le journal affiche un seul nombre (les lignes écrites), sans erreur ;
- la table contient une ligne par heure où le collecteur a tourné, et `total_deadlocks` / `total_slow_queries` correspondent à tes tests du jour.

Requête type pour la page macro (« une ligne par heure sur les 6 dernières heures », heure courante partielle comprise) :

```sql
SELECT hour_bucket AS time, avg_cpu_percent, avg_mem_percent, avg_active_sessions,
       max_active_sessions, total_deadlocks, total_slow_queries, cache_hit_ratio
FROM asemon.snap_hourly_summary
ORDER BY hour_bucket DESC
LIMIT 6;
```

---

## 4. Limites connues

- **Pas de rétention** : la table grossit d'une ligne par heure, soit environ 8 800 lignes par an. Négligeable ; la rétention des tables de snapshots bruts reste à traiter séparément (voir `03-VM-Cible-parseur-systemd.md` §9).
- **Droits** : seul `postgres` (via le timer) peut appeler `rollup_hourly()`. `grafana_ro` lit la table, `collector_writer` ne l'écrit pas.
- **Delta de compteurs sur redémarrage** : l'intervalle qui contient un redémarrage de PostgreSQL est ignoré pour le cache hit ratio, pas estimé.
- **Seuil des « requêtes lentes »** : il dépend d'`auto_explain.log_min_duration` côté VM-Cible, pas d'un réglage de ce rollup. Changer ce seuil change la signification de la colonne pour les heures suivantes.

---

## 5. Checklist de validation

- [ ] `06-rollup-horaire.sql` exécuté sur VM-Monitoring, sans erreur
- [ ] `rollup_hourly(24 * 30)` exécuté, table non vide
- [ ] `asemon-rollup.timer` actif (`enabled`), prochain déclenchement visible
- [ ] Une exécution manuelle du service écrit une ligne propre dans le journal
- [ ] Valeurs de la dernière heure cohérentes avec le dashboard Grafana (CPU, cache hit ratio, deadlocks)
- [ ] Dashboard Grafana existant inchangé
