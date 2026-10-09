# Page micro : top sessions, top requêtes et détails (page 3 de l'IHM)

> Troisième page de l'IHM cible (`06-roadmap-ihm.md` §2) : les 10 sessions et les 10 requêtes qui ont le plus travaillé, avec un clic vers le détail de la session (toutes ses exécutions) ou de la requête (texte, sessions qui l'ont exécutée, plans). La boucle est fermée : session → requête → sessions, et retour.
>
> **Statut : écrit, requêtes SQL testées en local (PostgreSQL 16), mise en page et déploiement pas encore faits.**

Fichiers :
- `grafana/asemon-micro.json` (uid `asemon-micro`), `grafana/asemon-session.json` (uid `asemon-session`), `grafana/asemon-query.json` (uid `asemon-query`)
- `grafana/asemon-macro.json` et `grafana/asemon-intermediate.json` : liens de navigation mis à jour (Macro, Intermédiaire, Micro)
- `sql/10-plans-query-id.sql` : colonne `event_plans.query_id` et index (VM-Monitoring)
- `python/log_parser.py` : enregistre le `query_id` de chaque plan (VM-Cible)

Dépend de `snap_samples` (doc `09`), `snap_sessions` (doc `07`) et `snap_statements`.

---

## 1. Contenu

### Page micro
- **Top 10 sessions** : login, programme, base, temps actif, dont CPU, dont I/O, dont verrous, nombre de requêtes distinctes. Clic sur `session_key` : détail de la session.
- **Top 10 requêtes** : `query_id`, texte SQL, mêmes colonnes de coût, nombre de sessions. Clic sur `query_id` : détail de la requête.
- **Variable « Trier par »** (en haut) : Temps actif, CPU, I/O ou Verrous. Elle change le classement des deux tableaux (c'est la requête qui est triée, pas seulement l'affichage : on obtient bien le top 10 du critère choisi).

### Détail d'une session
Identité (login, programme, base, adresse, connexion, déconnexion), six compteurs (temps actif, CPU, I/O, verrous, exécutions, requêtes distinctes), graphique de charge par type d'attente, **une ligne par exécution relevée** (début, fin approximative, coûts, requête), plans et deadlocks de la session.

### Détail d'une requête
Texte SQL, temps actif sur la période et sa répartition, appels et temps moyen (pg_stat_statements), graphique de charge, évolution du temps moyen, **sessions qui l'ont exécutée** (clic : retour au détail de session), plans capturés.

### Navigation
Les deux pages de détail s'ouvrent depuis les tableaux de la page micro, en conservant la période. Elles sont pilotées par les variables `session_key` et `query_id` (champs texte en haut) : on peut aussi les coller à la main.

---

## 2. À lire avant d'interpréter

- **Coûts = temps actif échantillonné** (toutes les 2 s), pas du CPU ni des octets mesurés. « CPU » = session active sans événement d'attente ; « I/O » = attente de type `IO` ; « verrous » = `Lock` et `LWLock`. Il n'y a **pas de colonnes « I/O réseau » ni « I/O disque »** en octets : elles viendront avec `pg_stat_kcache` (Phase 3), les tableaux changeront alors de source.
- **Sessions `asemon-*` exclues** (collecteur, échantillonneur) du top 10.
- **Texte des requêtes** : pris dans `snap_statements` (top des requêtes de pg_stat_statements relevé par le collecteur). Une requête qui n'y a jamais figuré s'affiche « (texte non capturé) » ; son `query_id` reste utilisable.
- **Exécutions** : une exécution = couple `(query_id, query_start)` vu par l'échantillonneur. La fin est le dernier échantillon plus un intervalle. Une exécution plus courte que 2 s peut ne jamais être vue.
- **Plans** : liés aux requêtes par `query_id`. **Les plans enregistrés avant ce déploiement n'ont pas de `query_id`** : ils restent visibles dans le détail de leur session, pas dans celui de la requête.
- **`query_id` est traité comme du texte** dans Grafana : ce sont des entiers 64 bits signés, que le navigateur arrondirait s'il les prenait pour des nombres.
- **Durée de vie** : les échantillons sont conservés 14 jours (`sample_retention_days`, doc `09`) ; au-delà, le détail d'une vieille session n'a plus de coûts, mais son identité (`snap_sessions`, 90 jours) reste.

---

## 3. Déploiement

Dans l'ordre : base de données, parseur, puis Grafana.

### 3.1 PowerShell, depuis ton clone

```powershell
cd I:\POC_ASEMON\asemon-pg
git fetch origin
git switch grafana-micro
scp sql\10-plans-query-id.sql admin01@192.168.1.28:~/
scp python\log_parser.py admin01@192.168.1.30:~/
```

### 3.2 VM-Monitoring (192.168.1.28)

```bash
sudo -u postgres psql -d monitoring < ~/10-plans-query-id.sql
sudo -u postgres psql -d monitoring -c "\d asemon.event_plans" | grep -i query_id
```

Attendu : la colonne `query_id | bigint` et les index sont créés, sans erreur.

### 3.3 VM-Cible (192.168.1.30)

```bash
sudo cp ~/log_parser.py /opt/asemon/app/log_parser.py
sudo chown admin01: /opt/asemon/app/log_parser.py
sudo systemctl restart asemon-logparser
sleep 3
sudo systemctl status asemon-logparser --no-pager | head -4
```

Puis provoquer un plan (dans `sudo -u postgres psql -d postgres`) :

```sql
SELECT pg_sleep(10);
```

### 3.4 Vérification du lien plan / requête (VM-Monitoring)

```bash
sudo -u postgres psql -d monitoring -c "SELECT p.occurred_at, p.query_id, left(p.query, 30) AS query, (SELECT count(*) FROM asemon.snap_samples s WHERE s.query_id = p.query_id) AS echantillons FROM asemon.event_plans p ORDER BY p.id DESC LIMIT 3;"
```

Attendu : la dernière ligne a un `query_id` non nul, et `echantillons` > 0 (les mêmes requêtes vues par l'échantillonneur). Si `query_id` est vide, vérifier que `compute_query_id` est actif sur la cible : `SHOW compute_query_id;` (doit valoir `on` ou `auto`).

### 3.5 Grafana

Importer, un par un (**Dashboards**, **New**, **Import**, choisir le datasource `DS_MONITORING` à chaque fois) :
1. `grafana\asemon-micro.json`
2. `grafana\asemon-session.json`
3. `grafana\asemon-query.json`
4. Réimporter `grafana\asemon-macro.json` et `grafana\asemon-intermediate.json` (même uid, accepter d'écraser) pour avoir le lien « Micro ».

---

## 4. Vérification

Lancer une session identifiable pendant une minute (sur VM-Cible) :

```bash
PGAPPNAME=demo-micro sudo -u postgres psql -d postgres -c "SELECT pg_sleep(60);"
```

Puis dans Grafana, page **Micro** (30 s plus tard) :
- la session `demo-micro` apparaît dans le top 10 sessions, avec environ 60 s de temps actif ;
- le tableau des requêtes contient `SELECT pg_sleep($1)` ou le texte équivalent ;
- changer « Trier par » modifie l'ordre ;
- clic sur la `session_key` : le détail liste l'exécution de `pg_sleep` (début, fin approximative, ~60 s) ;
- clic sur le `query_id` : le détail affiche le texte, les sessions (dont `demo-micro`) et le plan du `pg_sleep(10)` de tout à l'heure ;
- depuis le détail de requête, clic sur une `session_key` : retour au détail de session.

---

## 5. Limites connues

- **Un seul niveau de tri à la fois** (variable « Trier par »), pas de tri multi-colonnes natif.
- **Le top 10 est calculé sur la période choisie** (6 h par défaut) : agrandir la période pour retrouver une session plus ancienne.
- **Liens** : ils fonctionnent par `uid` de dashboard. Si un dashboard est réimporté sous un autre uid, les liens cassent.
- **Pas de coût I/O en octets** (voir §2).
- **Détail de requête sans texte** si la requête n'a jamais figuré dans le top du collecteur ; une alternative serait de stocker le texte à l'échantillonnage (volume), non retenue.

---

## 6. Checklist de validation

- [ ] `10-plans-query-id.sql` exécuté sur VM-Monitoring, colonne `query_id` présente
- [ ] `log_parser.py` déployé, service `asemon-logparser` actif
- [ ] Un plan récent a un `query_id` non nul, relié à des échantillons
- [ ] Trois dashboards importés, aucune erreur de panneau
- [ ] Test `demo-micro` : visible dans le top 10 sessions et requêtes
- [ ] Navigation session ↔ requête dans les deux sens
- [ ] « Trier par » modifie le classement
- [ ] Liens « Micro » présents sur Macro et Intermédiaire
