# Release 4c : seuils d'alarme et d'avertissement

> **Statut : validée sur VM-Monitoring le 2026-10-15** (calcul des états, page Seuils, formulaire de modification, droits du rôle limité). Le formulaire dépend de la version du plugin (6.3.5) ; les seuils restent modifiables en SQL (étape 6) quoi qu'il arrive. Le niveau zéro et la page d'une instance (4d) utilisent ces seuils.

## 1. Principe

Six indicateurs sont calculés **toutes les 5 minutes** pour chaque instance, puis comparés à deux seuils : **avertissement** (orange) et **alarme** (rouge). Un seuil peut être **propre à une instance** ; sinon c'est le **défaut** qui s'applique.

| Clé | Indicateur | Sens | Avert. | Alarme | Calcul (5 dernières minutes) |
|---|---|---|---|---|---|
| `cpu_pct` | CPU de la machine | haut = mauvais | 80 % | 95 % | pic de `snap_os.cpu_percent` (CPU **de la machine**, pas de PostgreSQL) |
| `disk_free_pct` | Espace disque libre | **bas** = mauvais | 20 % | 10 % | dernière mesure, disque de `/` |
| `lock_wait_s` | Attente de verrou la plus longue | haut | 30 s | 120 s | plus longue attente d'une même exécution sur un verrou (échantillons de 2 s) |
| `longest_xact_s` | Transaction la plus longue | haut | 300 s | 1 800 s | plus grand âge d'une transaction ouverte (précision : intervalle de collecte, 15 s) |
| `deadlocks` | Deadlocks | haut | 1 | 5 | nombre sur la **dernière heure** |
| `active_xacts` | Transactions ouvertes en même temps | haut | 20 | 50 | maximum d'un relevé, `idle in transaction` compris. **Désactivé** : pas de valeur validée |

Sans activité (aucun verrou, aucune transaction), les indicateurs d'événements valent **0**. Sans mesure récente (agent arrêté), l'état est **« pas de mesure »**, ni vert ni rouge.

**L'indicateur le plus problématique d'une instance** (vue `v_instance_status`) est le premier dans cet ordre : alarme, puis avertissement, puis ok ; à état égal, la plus grande **gravité** = valeur rapportée au seuil d'alarme (97 % de CPU pour une alarme à 95 % → 1,02 ; verrou de 140 s pour 120 s → 1,17).

## 2. Ce qui est ajouté

| Élément | Rôle |
|---|---|
| `sql/17-thresholds.sql` | tables `kpi_catalog` (les indicateurs, fixes), `kpi_thresholds` (seuils), `kpi_values` (valeurs) ; fonction `compute_kpi_values()` ; vues `v_kpi_status` et `v_instance_status` ; fonctions `set_threshold()` et `reset_threshold()` ; rôle `grafana_thresholds` |
| `systemd/asemon-rollup.service` | appelle aussi `compute_kpi_values()` (le timer tourne déjà toutes les 5 minutes) |
| `grafana/asemon-thresholds.json` | page **Seuils** : état actuel, seuils en vigueur, mode d'emploi |
| Liens « Seuils » | ajoutés à Macro, Intermédiaire, Micro, Capacity |
| Scripts | `GRAFANA_THRESHOLDS_PASSWORD` dans `asemon.env`, plugin `volkovlabs-form-panel`, datasource « ASEMON Seuils » (installation scriptée, non testée) |

**Écart par rapport à la conception initiale** (`16-roadmap-releases.md` §3.4, §3.6) : le sens (`high` / `low`) est dans `kpi_catalog` et non dans `kpi_thresholds` (on ne peut donc pas l'inverser par erreur), et le rôle de Grafana **n'écrit pas dans la table** : il appelle seulement `set_threshold()` et `reset_threshold()`, qui vérifient l'instance, l'indicateur et l'ordre des seuils. Les agents (`collector_writer`) n'ont aucun droit d'écriture sur ces tables.

## 3. Paramètres

| Où | Paramètre | Rôle |
|---|---|---|
| `asemon.env` | `GRAFANA_THRESHOLDS_PASSWORD` | mot de passe du rôle `grafana_thresholds` (vide : page en lecture seule) |
| `kpi_thresholds` | `warn_value`, `crit_value`, `enabled` | seuils ; `instance_id` vide = défaut |
| `settings` | `snapshot_retention_days` | durée de conservation de `kpi_values`, comme les snapshots (30 jours) |

## 4. Mettre à jour le POC (VM-Monitoring uniquement)

**1. Code et schéma**

```bash
cd ~/asemon-pg && git checkout -- . && git fetch && git checkout r4c-seuils && git pull
sudo -u postgres psql -d monitoring < sql/02-roles-and-grants.sql
sudo -u postgres psql -d monitoring < sql/17-thresholds.sql
```
Attendu : pas d'erreur ; la dernière ligne est `REVOKE`. (On rejoue `02` pour que les agents n'aient pas de droit d'écriture sur les nouvelles tables ; il est rejouable.)

**2. Calcul toutes les 5 minutes**

```bash
sudo cp systemd/asemon-rollup.service /etc/systemd/system/ && sudo systemctl daemon-reload
sudo systemctl start asemon-rollup.service
sudo journalctl -u asemon-rollup -n 4 --no-pager
```
Attendu : deux nombres dans le journal (lignes du résumé horaire, valeurs de seuils calculées : environ 12 pour deux instances).

**3. Rôle de modification** (remplacer `MOT_DE_PASSE_SEUILS`)

```bash
sudo -u postgres psql -c "ALTER USER grafana_thresholds LOGIN PASSWORD 'MOT_DE_PASSE_SEUILS';"
```
Attendu : `ALTER ROLE`.

**4. Plugin Grafana**

```bash
sudo grafana cli plugins install volkovlabs-form-panel
sudo systemctl restart grafana-server
```
Attendu : `✔ Installed volkovlabs-form-panel`. En cas d'échec (accès à grafana.com), dis-le : seul le formulaire est concerné, les seuils restent modifiables en SQL.

**5. Datasource « ASEMON Seuils »** (Grafana → Connections → Data sources → Add new data source → PostgreSQL). Attention : le navigateur peut pré-remplir *Username* et *Password* avec tes identifiants Grafana : les retaper, et mettre le *TLS/SSL Mode* sur `disable` (la valeur par défaut `require` échoue)

| Champ | Valeur |
|---|---|
| Name | `ASEMON Seuils` |
| Host URL | `localhost:5432` |
| Database | `monitoring` |
| User / Password | `grafana_thresholds` / le mot de passe de l'étape 3 |
| TLS/SSL Mode | `disable` |
| PostgreSQL Version | celle de VM-Monitoring (17) |

Grafana peut conserver un nom par défaut (`grafana-postgresql-datasource-1`) malgré le champ *Name* : sans conséquence.

**Save & test** : « Database Connection OK ».

**6. Dashboards** : importer `grafana/asemon-thresholds.json` (Import, datasource **ASEMON Monitoring**), relier le formulaire à la datasource (étape 7), et réimporter Macro, Intermédiaire, Micro, Capacity avec **Overwrite** (nouveau bouton « Seuils »).

## 5. Vérifier

```bash
sudo -u postgres psql -d monitoring -c "SELECT instance_name, label, round(value::numeric,1) AS valeur, warn_value AS avert, crit_value AS alarme, state FROM asemon.v_kpi_status ORDER BY 1, sort_order;"
sudo -u postgres psql -d monitoring -c "SELECT instance_name, worst_label, value, state FROM asemon.v_instance_status;"
```
Attendu : pour chaque instance, les 5 indicateurs actifs avec un état (`ok`, ou `warning` / `critical` si une valeur dépasse). Dans Grafana, la page **Seuils** affiche les mêmes lignes, colorées.

## 6. Modifier un seuil en SQL (sûr, toujours disponible)

```bash
sudo -u postgres psql -d monitoring
```
```sql
-- défaut de toutes les instances (premier argument NULL)
SELECT asemon.set_threshold(NULL, 'cpu_pct', 75, 90);
-- seuil propre à l'instance 2 (VM-Monitoring)
SELECT asemon.set_threshold(2, 'longest_xact_s', 600, 3600);
-- activer active_xacts (avertissement 20, alarme 50), pour toutes les instances
SELECT asemon.set_threshold(NULL, 'active_xacts', 20, 50, true);
-- l'instance 2 retrouve le défaut
SELECT asemon.reset_threshold(2, 'longest_xact_s');
```
Les refus sont explicites : alarme inférieure à l'avertissement (ou l'inverse pour `disk_free_pct`), indicateur ou instance inconnus. L'état est recalculé au prochain passage (5 minutes au plus).

## 7. Le formulaire « Modifier un seuil »

Il fait partie de `grafana/asemon-thresholds.json` (plugin **Business Forms** 6.3.5, validé sur Grafana 13.2.2 le 2026-10-15). Cinq champs : instance (`0` = défaut de toutes), indicateur, avertissement, alarme, actif. **Submit** ouvre une fenêtre de confirmation, puis appelle `asemon.set_threshold(…)` avec le rôle `grafana_thresholds`.

**Après l'import du dashboard** (étape 6), une seule action manuelle : relier le formulaire à la datasource « ASEMON Seuils ».
1. Page **Seuils** → **Edit** ; menu du panneau « Modifier un seuil » (trois points) → **Edit**.
2. Section **Update Request**, liste **Data Source** : choisir la datasource **ASEMON Seuils**. Grafana peut l'afficher sous un nom par défaut (`grafana-postgresql-datasource-1`) : c'est la deuxième de la liste, celle créée à l'étape 5.
3. **Save**, puis **Exit edit**.

(L'installation scriptée crée cette datasource avec l'identifiant `asemon-seuils` : le formulaire est alors déjà relié.)

**Essai** : instance `2`, indicateur **CPU**, avertissement `5`, alarme `8`, actif **Oui**, **Submit**, **Confirm**. Message vert « Values updated successfully » ; la ligne VM-Monitoring / CPU de « Seuils en vigueur » affiche 5 et 8, origine « propre à l'instance », et passe en alarme au calcul suivant (5 minutes au plus). Contrôle en SQL :

```bash
sudo -u postgres psql -d monitoring -c "SELECT instance_id, kpi, warn_value, crit_value, enabled, updated_by FROM asemon.kpi_thresholds WHERE instance_id IS NOT NULL;"
```
Attendu : `2 | cpu_pct | 5 | 8 | t | grafana_thresholds`. Retour au défaut : `SELECT asemon.reset_threshold(2, 'cpu_pct');` (le formulaire sait créer ou modifier un seuil, pas supprimer une surcharge).

**Réglages du plugin** (utiles pour le refaire à la main) :

| Section | Réglage |
|---|---|
| Form Elements | `instance` (Number input), `kpi` (Select with custom options, options de type **String** : `cpu_pct`, `disk_free_pct`, `lock_wait_s`, `longest_xact_s`, `deadlocks`, `active_xacts`), `warn` et `crit` (Number input), `enabled` (Select with custom options, options **String** `true` / `false`). Les **Id** doivent être exactement ceux-ci |
| Update Request → Update Action | **Data Source** : datasource « ASEMON Seuils » |
| Update Request Payload | **Custom** : `const payload = {}; context.panel.elements.forEach((e) => { payload[e.id] = e.value; }); return payload;` (le code d'exemple ignore les valeurs vides ou à zéro, ce qui supprimerait l'instance `0`) |
| Query Editor | onglet **Code**, format **Table** : `SELECT asemon.set_threshold(NULLIF(${payload.instance}::int, 0), '${payload.kpi}', ${payload.warn}::float8, ${payload.crit}::float8, '${payload.enabled}'::boolean)` |
| Update Confirmation Window | **Enabled** |

**Pièges rencontrés** : une option de Select a par défaut le type **Number** (il faut **String**) ; « Add Element » crée un élément, et non une option d'un champ existant ; le bouton **Submit** est inactif tant qu'aucune valeur n'a changé.

**Droits** : dans Grafana open source, toute personne qui peut modifier un dashboard peut interroger la datasource « ASEMON Seuils ». Le risque est borné (le rôle ne peut appeler que les deux fonctions) ; ne donner le droit d'édition qu'aux administrateurs.

## 8. Retour en arrière

```bash
sudo -u postgres psql -d monitoring -c "DROP TABLE asemon.kpi_values, asemon.kpi_thresholds, asemon.kpi_catalog CASCADE; DROP FUNCTION asemon.compute_kpi_values(), asemon.set_threshold(INT,TEXT,DOUBLE PRECISION,DOUBLE PRECISION,BOOLEAN,TEXT), asemon.reset_threshold(INT,TEXT);"
git checkout main -- systemd/asemon-rollup.service && sudo cp systemd/asemon-rollup.service /etc/systemd/system/ && sudo systemctl daemon-reload
```
(Les vues sont supprimées avec `CASCADE`. Le reste du schéma n'est pas touché.)

## 9. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| « Pas de mesure » partout | `compute_kpi_values()` jamais appelée ou agent arrêté | `journalctl -u asemon-rollup -n 5` ; service à jour (étape 2) |
| `function asemon.compute_kpi_values() does not exist` dans le journal du rollup | `sql/17` pas appliqué | étape 1 |
| `permission denied for table kpi_thresholds` en écrivant | écriture directe : voulu | utiliser `set_threshold()` |
| Le formulaire ne change rien | datasource ou code d'envoi | tester d'abord `SELECT asemon.set_threshold(...)` avec le mot de passe de `grafana_thresholds` : `psql "host=localhost dbname=monitoring user=grafana_thresholds"` |
| Un seuil modifié ne change pas la couleur | recalcul toutes les 5 minutes | attendre, ou `sudo systemctl start asemon-rollup.service` |
| `password authentication failed` (datasource Seuils) | étape 3 non faite ou mot de passe différent | `ALTER USER grafana_thresholds LOGIN PASSWORD '…'` |
