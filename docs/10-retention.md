# Rétention des snapshots, événements et sessions

> Jusqu'ici, seules `snap_samples` (voir `09-echantillonnage-phase2.md`) et `snap_hourly_summary` (une ligne par heure) avaient une limite de croissance. Les autres tables grossissaient sans fin. Une fonction SQL, appelée une fois par jour, supprime maintenant les lignes plus anciennes que des durées réglables.
>
> **Statut : écrit et testé en local (PostgreSQL 16, données synthétiques), pas encore déployé sur VM-Monitoring.**

Fichiers concernés :
- `sql/09-retention.sql` : paramètres dans `asemon.settings` et fonction `asemon.purge_old_data()` (VM-Monitoring)
- `systemd/asemon-purge.service` et `systemd/asemon-purge.timer` : exécution quotidienne à 03:17 UTC

---

## 1. Ce qui est purgé, et pour combien de temps

| Groupe | Tables | Paramètre (`asemon.settings`) | Défaut |
|---|---|---|---|
| Snapshots bruts | `snap_activity`, `snap_locks`, `snap_io`, `snap_os`, `snap_statements`, `snap_tables`, `snap_indexes`, `snap_checkpoints`, `snap_wal`, `snap_db_age`, `snap_connections` | `snapshot_retention_days` | 30 jours |
| Événements | `event_deadlocks`, `event_plans` | `event_retention_days` | 90 jours |
| Sessions | `snap_sessions` | `session_retention_days` | 90 jours |
| Échantillons | `snap_samples` | `sample_retention_days` (doc `09`) | 14 jours |
| Résumé horaire | `snap_hourly_summary` | aucun : jamais purgée | illimité |

Pourquoi ces valeurs : les snapshots bruts sont les plus volumineux et servent aux graphiques récents (30 jours suffisent) ; les deadlocks et les plans lents sont rares, petits et utiles pour comprendre un incident passé (90 jours) ; le résumé horaire pèse environ 8 800 lignes par an et alimente la page macro sans limite.

Règles de la purge :
- **Snapshots et événements** : suppression des lignes dont `collected_at` (ou `occurred_at`) est antérieur à `maintenant − durée`.
- **Sessions** : une session est supprimée si elle s'est terminée avant la limite, **ou** si elle n'a jamais été vue se déconnecter (déconnexion manquée par le parseur) et qu'aucun relevé de `snap_activity` ne la mentionne depuis la limite. Une session ouverte depuis des mois **mais encore active** est donc conservée.
- Les liens entre tables sont logiques (`session_key`), sans contrainte : supprimer une session ne bloque rien, mais ses anciennes lignes d'événements (90 jours aussi par défaut) ne pointent plus vers une session si tu mets `session_retention_days` en dessous de `event_retention_days`.

---

## 2. Modifier les durées

Sur **VM-Monitoring** :

```bash
# Voir les réglages actuels
sudo -u postgres psql -d monitoring -c "SELECT key, value FROM asemon.settings ORDER BY key;"

# Exemple : garder 60 jours de snapshots bruts
sudo -u postgres psql -d monitoring -c "UPDATE asemon.settings SET value = '60' WHERE key = 'snapshot_retention_days';"
```

La valeur est lue à **chaque exécution** de la purge : pas de redémarrage. Le changement s'applique au prochain passage (au plus 24 h), ou tout de suite avec `SELECT asemon.purge_old_data();`.

| Valeur | Effet |
|---|---|
| un entier ≥ 2 | durée en jours |
| `1` | ramenée à 2 jours (garde-fou) |
| `0` ou négatif | **pas de purge** pour ce groupe (conservation illimitée) |
| texte non numérique | ignoré avec un `WARNING`, valeur par défaut utilisée |

**Attention : réduire une durée supprime définitivement les données plus anciennes au prochain passage, sans retour arrière.** Augmenter une durée ne restaure rien, elle ne fait que conserver plus longtemps ce qui reste.

Changer l'heure du passage : éditer `OnCalendar=` dans `/etc/systemd/system/asemon-purge.timer`, puis `sudo systemctl daemon-reload && sudo systemctl restart asemon-purge.timer`.

Désactiver complètement la purge : `sudo systemctl disable --now asemon-purge.timer`.

---

## 3. Déploiement

Depuis PowerShell, dans ton clone :

```powershell
cd I:\POC_ASEMON\asemon-pg
git fetch origin
git switch retention-snapshots
scp sql\09-retention.sql systemd\asemon-purge.service systemd\asemon-purge.timer admin01@192.168.1.28:~/
```

Sur **VM-Monitoring**, **d'abord regarder ce qui serait supprimé** (rien n'est modifié) :

```bash
sudo -u postgres psql -d monitoring -c "
SELECT 'snap_activity' AS table, count(*) FILTER (WHERE collected_at < now() - interval '30 days') AS a_supprimer, count(*) AS total FROM asemon.snap_activity
UNION ALL SELECT 'event_plans', count(*) FILTER (WHERE occurred_at < now() - interval '90 days'), count(*) FROM asemon.event_plans
UNION ALL SELECT 'snap_sessions', count(*) FILTER (WHERE COALESCE(disconnected_at, connected_at) < now() - interval '90 days'), count(*) FROM asemon.snap_sessions;"
```

Puis installer :

```bash
# 1. Paramètres et fonction (la redirection < est nécessaire : postgres ne peut pas lire /home/admin01)
sudo -u postgres psql -d monitoring < ~/09-retention.sql

# 2. Premier passage manuel
sudo -u postgres psql -d monitoring -c "SELECT asemon.purge_old_data();"

# 3. Timer
sudo cp ~/asemon-purge.service ~/asemon-purge.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-purge.timer
```

---

## 4. Vérification

```bash
sudo systemctl list-timers asemon-purge.timer --no-pager
sudo systemctl start asemon-purge.service && sudo journalctl -u asemon-purge -n 3 --no-pager | grep -v truncated
```

Attendu :
- le timer est listé avec un prochain passage à 03:17 UTC ;
- le journal affiche une ligne `snap_activity=0 snap_locks=0 ... snap_sessions=0` (le collecteur ne tourne que depuis le 25 septembre : avec 30 jours de rétention, rien n'est encore à supprimer, ce qui est normal) ;
- le dashboard Grafana existant est inchangé.

Pour constater une vraie suppression sans attendre un mois, mets temporairement `snapshot_retention_days` à `2`, lance `SELECT asemon.purge_old_data();`, vérifie que les lignes de plus de 2 jours ont disparu, puis remets `30`. **Ces lignes seront perdues définitivement** : ne le fais que si tu n'en as pas besoin.

---

## 5. Limites connues

- **Espace disque** : un `DELETE` laisse des lignes mortes que l'autovacuum réutilise ; la taille des fichiers ne diminue pas, elle se stabilise. C'est suffisant pour limiter la croissance. Récupérer l'espace après une grosse purge demanderait un `VACUUM FULL` (verrou exclusif, à faire hors collecte).
- **Une seule transaction** : la fonction supprime tout dans un passage. Au rythme actuel (quelques milliers de lignes par jour), c'est instantané. Un rattrapage sur plusieurs millions de lignes serait plus long et gonflerait le journal WAL.
- **`snap_statements`** : conservée 30 jours comme les autres snapshots ; la jointure avec `snap_samples` (14 jours) reste donc toujours possible.
- **Rollup horaire** : il ne recalcule que les 7 dernières heures ; la purge des snapshots bruts n'altère pas les lignes déjà écrites dans `snap_hourly_summary`.

---

## 6. Checklist de validation

- [ ] Requête « à supprimer » exécutée, résultat cohérent (0 à ce stade)
- [ ] `09-retention.sql` exécuté sur VM-Monitoring, sans erreur
- [ ] `purge_old_data()` renvoie une ligne de compteurs sans erreur
- [ ] `asemon-purge.timer` actif, prochain passage à 03:17 UTC
- [ ] Exécution manuelle du service : une ligne propre dans le journal
- [ ] Dashboard Grafana existant inchangé
