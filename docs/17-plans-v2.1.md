# v2.1 : plans d'exécution et requêtes lisibles

> **Statut : codé et testé en local le 2026-10-11 (PostgreSQL 16, sans `psycopg` ni `sqlparse` ni Grafana). À valider sur les VM.** Ce qui n'a pas pu être testé ici : la mise en forme du SQL par `sqlparse` (texte brut conservé s'il est absent), l'installation du plugin Grafana et le rendu du panneau Business Text.

## 1. Ce qui change

| Sujet | Avant | v2.1 |
|---|---|---|
| Seuil `auto_explain.log_min_duration` | 500 ms | **100 ms** |
| Plans par requête | illimité | **5 par requête et par heure** (`PLAN_MAX_PER_QUERY_HOUR`) |
| Plan | JSON brut sur une ligne | JSON conservé **et** texte arborescent type `EXPLAIN` (`event_plans.plan_text`) |
| Forme du plan | — | `event_plans.plan_hash` : même valeur = même plan ; une valeur qui change = changement de plan |
| Texte SQL | une ligne dans un tableau | table `asemon.query_text` : texte indenté, mots-clés en majuscules |
| Page « Détail requête » | tableau étroit | **deux boîtes de 6 lignes avec ascenseur** (SQL, plan) ; un clic sur un plan du tableau l'affiche |

### Pourquoi si peu de plans (diagnostic du 2026-10-11)

- Les logs contiennent 16 plans (7 + 9) et la table `event_plans` 16 lignes : le parseur ne perd rien.
- Sur 118 requêtes suivies, 3 ont une durée moyenne ≥ 10 ms (et ≥ 500 ms), 5 ≥ 1 ms. Entre 1 ms et 500 ms il n'y a rien : la charge du POC n'a presque pas de requêtes lentes. Baisser le seuil ne suffit pas, d'où le script `scripts/charge-lente.sh`.
- Le coût de mesure d'`auto_explain` est déjà payé pour toutes les requêtes (`log_analyze`, `log_timing`) : baisser le seuil n'augmente que le volume des logs et de `event_plans`.

## 2. Paramètres

| Paramètre | Où | Défaut | Effet |
|---|---|---|---|
| `auto_explain.log_min_duration` | `conf.d/asemon.conf` (VM-Cible) | 100 (ms) | durée à partir de laquelle un plan est journalisé |
| `auto_explain.sample_rate` | idem | 1 | fraction des requêtes expliquées (à baisser si le volume gêne) |
| `PLAN_MAX_PER_QUERY_HOUR` | `/opt/asemon/app/config.py` | 5 (0 = illimité) | plafond de plans par requête et par heure ; compteur en mémoire, remis à zéro au redémarrage du parseur |

## 3. Mise à jour d'un POC existant

Dans l'ordre, après avoir fait `git pull` sur chaque VM (branche `v2.1-plans` pour l'essai).

**VM-Monitoring**
```bash
cd ~/asemon-pg && git pull
sudo -u postgres psql -d monitoring < sql/12-plans-lisibles.sql
sudo grafana cli plugins install marcusolsson-dynamictext-panel
sudo systemctl restart grafana-server
```
Puis réimporter `grafana/asemon-query.json` (Dashboards > New > Import, même uid : choisir « Overwrite »). Ou, avec le script, `sudo ./scripts/grafana-provision.sh`.

**VM-Cible**
```bash
cd ~/asemon-pg && git pull
sudo ./scripts/install-target.sh            # copie le code, installe sqlparse, passe auto_explain à 100 ms, redémarre
```
`install-target.sh` redémarre PostgreSQL (quelques secondes) parce qu'il réécrit `conf.d/asemon.conf`. Pour n'appliquer que le seuil sans redémarrage :
```bash
sudo sed -i 's/^auto_explain.log_min_duration = .*/auto_explain.log_min_duration = 100/' /etc/postgresql/17/main/conf.d/asemon.conf
sudo -u postgres psql -c "SELECT pg_reload_conf()"      # vaut pour les nouvelles connexions
```
Si `install-target.sh` signale que `sqlparse` manque : `sudo /opt/asemon/venv/bin/pip install sqlparse`, puis `sudo systemctl restart asemon-collector asemon-logparser`.

**Rattraper les plans déjà stockés** (VM-Cible, une fois) :
```bash
/opt/asemon/venv/bin/python /opt/asemon/app/backfill_plans.py --dry-run
/opt/asemon/venv/bin/python /opt/asemon/app/backfill_plans.py
```
Rejouable : ne traite que les lignes sans `plan_text`.

## 4. Vérifier

1. Générer des requêtes lentes (VM-Cible) : `sudo ./scripts/charge-lente.sh 120` (tri, jointure et filtre de 0,3 à 1 s sur 1 million de lignes, plus un `pg_sleep(0.3)`)
2. VM-Monitoring :
```sql
SELECT count(*), count(DISTINCT query_id), count(plan_text) FROM asemon.event_plans WHERE occurred_at > now() - interval '10 minutes';
SELECT queryid, left(query_formatted, 60) FROM asemon.query_text LIMIT 5;      -- texte indenté (plusieurs lignes)
```
3. Grafana > Détail requête (cliquer un `query_id` depuis le Micro) : la boîte SQL est indentée, la boîte Plan montre l'arbre ; cliquer sur le N° d'un autre plan le remplace.
4. `sudo ./scripts/verify.sh monitoring` : la ligne « table asemon.query_text (v2.1) » est verte.

## 5. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| Boîtes vides, message « Panel plugin not found » | plugin non installé | `grafana cli plugins install marcusolsson-dynamictext-panel`, redémarrer Grafana |
| Boîtes présentes mais texte sur une seule ligne ou HTML visible | version du plugin différente | éditer le panneau : mode de rendu « Data », « Pour chaque ligne » ; le contenu est `<pre …>{{sql}}</pre>` |
| SQL non indenté | `sqlparse` absent du venv de VM-Cible | `pip install sqlparse` dans `/opt/asemon/venv`, redémarrer `asemon-collector` ; les requêtes déjà dans `query_text` ne sont pas reformatées (`TRUNCATE asemon.query_text;` puis redémarrage du collecteur) |
| « Écriture de asemon.query_text impossible » dans le journal du collecteur | `sql/12` non appliqué sur VM-Monitoring | appliquer `sql/12-plans-lisibles.sql` |
| Plan « non mis en forme » | plan écrit avant la v2.1 | lancer `backfill_plans.py` |
| Toujours peu de plans | peu de requêtes ≥ 100 ms | lancer `charge-lente.sh`, ou baisser `auto_explain.log_min_duration` (volume des logs !) |

## 6. Écarts avec le plan initial (doc 16, §A)

- `query_text` n'est **pas purgée** : une ligne par requête distincte (volume négligeable). Si une requête sort du top 100 puis revient, son texte reste.
- Le compteur de plafond est en mémoire : un redémarrage du parseur autorise de nouveau jusqu'à 5 plans pour l'heure en cours.
- `plan_hash` identifie la **forme** (types de nœuds, tables, index, jointures), pas les coûts ni les temps.
