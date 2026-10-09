# Échantillonnage des sessions actives (Phase 2)

> Un échantillonneur relève toutes les 2 secondes les sessions **actives** de PostgreSQL et les stocke dans `asemon.snap_samples`, à la manière de l'Active Session History d'Oracle. C'est la matière première des camemberts « coût par login / par programme » et du drill-down de la page micro (`06-roadmap-ihm.md`).
>
> **Statut : déployé sur VM-Monitoring et VM-Cible (2026-10-09) et validé (échantillons, intervalle, lien avec `snap_sessions`). Reste à relever le volume réel après quelques heures.**

Fichiers concernés :
- `sql/08-schema-samples.sql` : table `asemon.snap_samples` (partitionnée par jour), table de paramètres `asemon.settings`, fonction de maintenance `asemon.maintain_samples()`, vue `asemon.v_samples_partitions` (VM-Monitoring)
- `python/sampler.py` : l'échantillonneur (VM-Cible)
- `systemd/asemon-sampler.service` (VM-Cible), `systemd/asemon-samples-maintenance.service` et `.timer` (VM-Monitoring)
- `python/config.py.example` : nouveau paramètre `SAMPLE_INTERVAL`

---

## 1. Ce qui est enregistré

Une ligne = **une session active à un instant donné**. Aucune ligne si rien n'est actif.

| Colonne | Contenu |
|---|---|
| `sampled_at` | horloge de l'instance surveillée (`now()`) |
| `interval_ms` | intervalle d'échantillonnage en vigueur au moment du relevé |
| `pid`, `session_key` | session (lien avec `snap_sessions.session_key`) |
| `usename`, `datname`, `application_name` | qui, quelle base, quel programme |
| `wait_event_type`, `wait_event` | `NULL` = la session tourne sur CPU ; sinon elle attend (`IO`, `Lock`, `LWLock`...) |
| `query_id`, `query_start` | requête (jointure avec `snap_statements` sur `query_id`) et début de son exécution |

Choix de conception :
- **Sessions actives uniquement** (`state = 'active'`, backends clients, hors échantillonneur lui-même). Les sessions `idle` ou `idle in transaction` ne sont pas relevées : c'est ce qui garde le volume proportionnel à la charge réelle.
- **Pas de texte de requête** : il coûterait cher en volume. On retrouve le texte via `query_id`. `query_id` est `NULL` si `compute_query_id` est désactivé sur l'instance.
- **`interval_ms` sur chaque ligne** : changer l'intervalle plus tard ne fausse pas l'historique.

### Comment lire les données

Chaque ligne représente `interval_ms` millisecondes de temps actif. Donc :
- temps actif d'un groupe de lignes (secondes) = `SUM(interval_ms) / 1000`
- charge moyenne sur une fenêtre de W secondes (« Average Active Sessions ») = `SUM(interval_ms) / 1000 / W`
- répartition CPU / attente : lignes avec `wait_event IS NULL` = CPU, les autres = attente (par type). **C'est une approximation** : un échantillon n'est pas une mesure de temps CPU. La mesure réelle viendra de `pg_stat_kcache` (Phase 3).

```sql
-- Coût actif par login sur la dernière heure (base des camemberts)
SELECT usename, round(SUM(interval_ms) / 1000.0) AS secondes_actives
FROM asemon.snap_samples
WHERE sampled_at > now() - interval '1 hour'
GROUP BY usename ORDER BY 2 DESC;

-- Charge moyenne par minute, CPU contre attentes
SELECT date_trunc('minute', sampled_at) AS time,
       SUM(interval_ms) FILTER (WHERE wait_event IS NULL) / 60000.0 AS cpu,
       SUM(interval_ms) FILTER (WHERE wait_event_type = 'IO') / 60000.0 AS io,
       SUM(interval_ms) FILTER (WHERE wait_event IS NOT NULL AND wait_event_type <> 'IO') / 60000.0 AS autres_attentes
FROM asemon.snap_samples
WHERE sampled_at > now() - interval '1 hour'
GROUP BY 1 ORDER BY 1;
```

Une requête plus courte que l'intervalle peut passer entre deux relevés : c'est la nature de l'échantillonnage. Sur de nombreux relevés, la répartition reste juste statistiquement ; pour une requête isolée, utiliser `snap_statements` et les plans (`event_plans`).

---

## 2. Paramètres modifiables (à lire avant de changer quoi que ce soit)

| Paramètre | Valeur par défaut | Où | Comment le changer | Prise d'effet |
|---|---|---|---|---|
| Intervalle d'échantillonnage | 2 s (borné à 0,5 - 60) | **VM-Cible**, `/opt/asemon/app/config.py`, ligne `SAMPLE_INTERVAL` | éditer la ligne, puis `sudo systemctl restart asemon-sampler` | au redémarrage du service |
| Rétention | 14 jours | **VM-Monitoring**, table `asemon.settings`, clé `sample_retention_days` | `UPDATE` (voir §2.2) | au prochain passage de la maintenance (au plus 1 h), ou tout de suite avec `SELECT asemon.maintain_samples();` |
| Partitions créées d'avance | 3 jours | **VM-Monitoring**, `asemon.settings`, clé `sample_partitions_ahead` | `UPDATE` (voir §2.3) | idem |
| Périodicité de la maintenance | toutes les heures (à `hh:07`) | **VM-Monitoring**, `/etc/systemd/system/asemon-samples-maintenance.timer` | éditer `OnCalendar=`, puis `sudo systemctl daemon-reload && sudo systemctl restart asemon-samples-maintenance.timer` | immédiat |
| Sessions relevées (filtre) | actives, backends clients | `python/sampler.py`, requête `SQL_SAMPLE` | voir §2.5 | au redéploiement |

### 2.1 Changer l'intervalle d'échantillonnage

Sur **VM-Cible** :

```bash
sudo nano /opt/asemon/app/config.py        # SAMPLE_INTERVAL = 5     (secondes, décimales acceptées : 0.5)
sudo systemctl restart asemon-sampler
sudo journalctl -u asemon-sampler -n 5 --no-pager | grep -v truncated   # "intervalle=5.0s"
```

- Si `SAMPLE_INTERVAL` est absent de `config.py`, la valeur par défaut (2 s) s'applique.
- Une valeur invalide (texte, vide) ou hors de 0,5 - 60 s ne bloque pas le service : il démarre avec la valeur par défaut ou la borne la plus proche, et **écrit un avertissement dans le journal**. Vérifier la ligne « intervalle=... » après tout changement.
- **Effet sur le volume** : il est inversement proportionnel à l'intervalle. Passer de 2 s à 1 s double le volume, passer à 5 s le divise par 2,5 (voir §3).
- **Effet sur la précision** : plus l'intervalle est grand, plus les requêtes courtes sont sous-représentées. En dessous de 1 s, le coût du relevé lui-même (une requête sur `pg_stat_activity` par tick) n'est plus négligeable.

### 2.2 Changer la rétention

Sur **VM-Monitoring** :

```bash
sudo -u postgres psql -d monitoring -c "UPDATE asemon.settings SET value = '30' WHERE key = 'sample_retention_days';"
sudo -u postgres psql -d monitoring -c "SELECT asemon.maintain_samples();"    # optionnel : appliquer tout de suite
sudo -u postgres psql -d monitoring -c "SELECT * FROM asemon.v_samples_partitions;"
```

- Le comptage se fait en **jours calendaires UTC, jour en cours inclus** : avec 14, on garde le jour en cours et les 13 précédents.
- **Augmenter** la rétention ne restaure rien : seuls les jours à venir s'accumulent plus longtemps.
- **Réduire** la rétention **supprime définitivement** les partitions plus anciennes au prochain passage de la maintenance (au plus une heure plus tard). Pas de retour arrière : vérifier la vue `v_samples_partitions` avant. La valeur minimale appliquée est 1 (le jour en cours).
- Une valeur qui n'est pas un entier est ignorée avec un avertissement (`WARNING` dans le journal de la maintenance) et la valeur par défaut (14) s'applique.

### 2.3 Changer les partitions créées d'avance

```bash
sudo -u postgres psql -d monitoring -c "UPDATE asemon.settings SET value = '7' WHERE key = 'sample_partitions_ahead';"
```

Le timer crée les partitions chaque heure, 3 jours d'avance suffisent largement. Ce réglage ne sert que de marge si la maintenance est en panne (voir §5) : si les partitions manquent, l'échantillonneur ne peut plus écrire.

### 2.4 Voir les réglages actuels

```bash
sudo -u postgres psql -d monitoring -c "SELECT key, value, description FROM asemon.settings;"
```

### 2.5 Changer ce qui est relevé

C'est du code, pas un réglage. Dans `python/sampler.py`, la clause `WHERE` de `SQL_SAMPLE` décide des sessions relevées. Exemple : relever aussi les `idle in transaction` en remplaçant `state = 'active'` par `state IN ('active', 'idle in transaction')`. Attention : une session `idle in transaction` n'est pas du temps de travail, elle fausserait l'interprétation « temps actif » ; ajouter plutôt une colonne `state` à la table (`ALTER TABLE asemon.snap_samples ADD COLUMN state TEXT;`, puis adapter `SQL_SAMPLE` et `SQL_INSERT`). Après modification, copier `sampler.py` sur VM-Cible et redémarrer le service.

### 2.6 Arrêter ou désactiver l'échantillonnage

```bash
sudo systemctl disable --now asemon-sampler      # VM-Cible : plus de nouveaux relevés
```

Les données déjà enregistrées restent jusqu'à la fin de la rétention. Le collecteur et le parseur de logs ne sont pas touchés. `sudo systemctl enable --now asemon-sampler` pour reprendre.

---

## 3. Volume attendu

Environ **165 octets par ligne**, index inclus (mesuré en local sur 100 000 lignes synthétiques : 16 Mo), et une ligne par session active et par relevé. Pour un intervalle de 2 s : 43 200 relevés par jour. La valeur réelle dépend de la longueur des noms de login, de base et de programme, à confirmer avec `v_samples_partitions` (ci-dessous).

| Sessions actives en moyenne | Par jour à 2 s | 14 jours à 2 s | Par jour à 1 s | Par jour à 5 s |
|---|---|---|---|---|
| 1 | 7 Mo | 100 Mo | 14 Mo | 3 Mo |
| 10 | 71 Mo | 1 Go | 143 Mo | 29 Mo |
| 50 | 356 Mo | 5 Go | 713 Mo | 143 Mo |

Ordre de grandeur pour décider : `Mo/jour ≈ 7 × sessions actives moyennes × (2 / intervalle en s)`. Le disque de VM-Monitoring a 50 Go libres au moment de la mesure.

**Première mesure réelle (2026-10-09)** : 614 lignes pour 168 ko, soit environ 270 octets par ligne, index compris. C'est plus que l'estimation de 165 octets, mais l'échantillon est trop petit pour conclure (une partition vide occupe déjà 32 ko). À reprendre sur plusieurs jours de charge avant de dimensionner le disque ; prendre 270 octets par ligne comme hypothèse prudente.

Mesure réelle une fois en place :

```sql
SELECT * FROM asemon.v_samples_partitions;                       -- taille par jour
SELECT pg_size_pretty(SUM(bytes)) FROM asemon.v_samples_partitions;
```

`rows_estimate` vient des statistiques de PostgreSQL (retard de quelques minutes) ; `bytes` est exact.

La rétention est assurée en supprimant des partitions entières : pas de `DELETE`, pas de `VACUUM`, pas de gonflement de table.

---

## 4. Déploiement

Depuis PowerShell, dans ton clone :

```powershell
cd I:\POC_ASEMON\asemon-pg
git fetch origin
git switch phase2-echantillonnage
scp sql\08-schema-samples.sql systemd\asemon-samples-maintenance.service systemd\asemon-samples-maintenance.timer admin01@192.168.1.28:~/
scp python\sampler.py python\config.py.example systemd\asemon-sampler.service admin01@192.168.1.30:~/
```

### 4.1 VM-Monitoring (192.168.1.28), d'abord

```bash
# 1. Table, paramètres, fonction (la redirection < est nécessaire : postgres ne peut pas lire /home/admin01)
sudo -u postgres psql -d monitoring < ~/08-schema-samples.sql

# 2. Timer de maintenance
sudo cp ~/asemon-samples-maintenance.service ~/asemon-samples-maintenance.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-samples-maintenance.timer
```

### 4.2 VM-Cible (192.168.1.30)

```bash
# 1. Code (l'ancien config.py n'est pas touché)
sudo cp ~/sampler.py /opt/asemon/app/sampler.py
sudo chown admin01: /opt/asemon/app/sampler.py

# 2. Optionnel : fixer l'intervalle (2 s par défaut s'il est absent)
echo 'SAMPLE_INTERVAL = 2' | sudo tee -a /opt/asemon/app/config.py

# 3. Service
sudo cp ~/asemon-sampler.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now asemon-sampler
```

Le fichier `config.py.example` copié ne sert que de référence. Les droits `INSERT` sur `snap_samples` sont donnés à `collector_writer` par le script SQL : aucun nouvel utilisateur n'est nécessaire.

---

## 5. Vérification

Sur **VM-Cible** :

```bash
sudo systemctl status asemon-sampler --no-pager | head -5
sudo journalctl -u asemon-sampler -n 5 --no-pager | grep -v truncated    # "intervalle=2.0s", puis un bilan par minute
```

Générer de l'activité, puis sur **VM-Monitoring** :

```bash
# Dans une session psql sur la cible :  SELECT pg_sleep(20);   (pendant que l'échantillonneur tourne)
sudo -u postgres psql -d monitoring -c "SELECT * FROM asemon.v_samples_partitions;"
sudo -u postgres psql -d monitoring -c "SELECT usename, application_name, wait_event_type, wait_event, count(*), min(interval_ms) FROM asemon.snap_samples WHERE sampled_at > now() - interval '5 minutes' GROUP BY 1,2,3,4 ORDER BY 5 DESC;"
sudo systemctl list-timers asemon-samples-maintenance.timer --no-pager
sudo journalctl -u asemon-samples-maintenance -n 3 --no-pager | grep -v truncated
```

Attendu :
- 5 partitions (la veille, le jour, +3 jours) ;
- le `pg_sleep(20)` donne une dizaine de lignes avec `wait_event = PgSleep`, `interval_ms = 2000` ; l'échantillonneur et le collecteur n'apparaissent pas comme sessions échantillonnées de façon significative (le collecteur peut apparaître brièvement quand il lit ses vues) ;
- le journal de maintenance affiche « partitions créées=0 supprimées=0 ... » ;
- `session_key` est présent et se retrouve dans `snap_sessions`.

Comportement en cas de panne (à connaître) :
- **Repository injoignable** ou **partition manquante** : l'échantillonneur garde les relevés en mémoire (au plus 5 000 lignes et 10 minutes), les réécrit avec leur horodatage d'origine au retour, et écrit une erreur par minute dans le journal. Au-delà, les plus anciens sont abandonnés, avec un avertissement.
- **Maintenance en panne** : les 3 jours d'avance laissent 3 jours pour réagir. Pour recréer les partitions à la main : `SELECT asemon.maintain_samples();`.
- **Arrêt du service** (`systemctl stop`) : dernier envoi des relevés en attente avant la sortie.

---

## 6. Limites connues

- **Rétention des autres tables** : traitée à part, voir `10-retention.md` (les durées se règlent dans la même table `asemon.settings`).
- **Approximation CPU / I/O** : voir §1. Mesure fine en Phase 3 (`pg_stat_kcache`).
- **Un échantillon est un instant, pas une durée** : l'erreur statistique diminue avec le nombre de relevés. Sur 5 minutes d'activité à 2 s, on a 150 relevés par session active.
- **Horloge** : `sampled_at` vient de l'instance surveillée, `now()` est donc cohérent avec `snap_activity`. Les partitions sont découpées en UTC.
- **Jour de partition manquant** : une ligne dont le jour n'a pas de partition est refusée (c'est ce qui déclenche la mise en mémoire tampon décrite plus haut).

---

## 7. Checklist de validation

- [ ] `08-schema-samples.sql` exécuté sur VM-Monitoring, sans erreur, 5 partitions créées
- [ ] `asemon-samples-maintenance.timer` actif, prochain déclenchement visible
- [ ] `asemon-sampler` actif sur VM-Cible, journal « intervalle=2.0s »
- [ ] `pg_sleep(20)` retrouvé dans `snap_samples` (`PgSleep`, `interval_ms = 2000`)
- [ ] `session_key` des échantillons retrouvé dans `snap_sessions`
- [ ] Changement d'intervalle testé (par exemple 5 s), journal « intervalle=5.0s », puis remis à 2
- [ ] Volume après quelques heures relevé via `v_samples_partitions`
- [ ] Dashboard Grafana existant inchangé
