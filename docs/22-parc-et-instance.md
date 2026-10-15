# Release 4d : page Parc (niveau zéro) et page Instance

> **Statut : codée et testée en local le 2026-10-15 (requêtes exécutées sur PostgreSQL 16 avec des données simulées). À valider dans Grafana.** Ces deux pages utilisent les seuils de la Release 4c ([21](21-seuils.md)). Aucun changement de schéma ni d'agent : seuls des dashboards sont ajoutés.

## 1. La page Parc (`asemon-fleet.json`, « monAp_pg — Parc »)

C'est le **niveau zéro** : une vue de toutes les instances supervisées.

| Panneau | Contenu |
|---|---|
| 3 tuiles | nombre d'instances **en alarme** (rouge dès 1), **en avertissement** (orange), **sans mesure récente** (jaune) |
| Tableau « Instances » | **une ligne par instance** : indicateur le plus problématique, sa valeur, ses seuils (avertissement / alarme), son état coloré, l'heure de la mesure. Triées : alarmes d'abord. Clic sur le nom : page de l'instance (ou Macro) |
| Graphe « Gravité » | pour chaque instance, l'évolution de **cet** indicateur rapportée à son seuil d'alarme : **100 % = alarme**, ligne orange à 70 %. Un point toutes les 5 minutes |

**Quel indicateur est « le plus problématique » ?** Celui d'état le plus grave (alarme, puis avertissement, puis ok) ; à état égal, celui dont la valeur est la plus proche de son seuil d'alarme (voir [21](21-seuils.md) §1). Une instance dont tous les indicateurs sont `ok` affiche donc celui qui s'approche le plus de son alarme.

## 2. La page Instance (`asemon-instance.json`, « monAp_pg — Instance »)

Liste **Instance** en haut (comme sur les autres pages) ; on y arrive depuis le Parc ou depuis le bouton « Instance ».

| Panneau | Contenu |
|---|---|
| « État actuel » | les indicateurs de l'instance avec leurs seuils et leur couleur |
| « Les 3 dernières heures » | **une ligne par heure UTC** (la dernière est partielle) |

Colonnes de la ligne horaire :

| Colonne | Calcul |
|---|---|
| CPU pic (%) et Heure du pic | maximum de `snap_os.cpu_percent` dans l'heure, et l'instant où il a été relevé. CPU **de la machine**, pas de PostgreSQL |
| Attente de verrou max (s) | plus longue attente d'**une même exécution** sur un verrou (échantillons de 2 s de `snap_samples`) |
| Sessions bloquées max | nombre maximal de sessions en attente d'un verrou **au même instant** |
| Deadlocks | nombre dans l'heure (`event_deadlocks`) |
| Transactions ouvertes max | maximum de sessions ayant une transaction ouverte **au même instant**, `idle in transaction` comprises |
| Disque libre min (%) | espace libre minimal de `/` dans l'heure |
| Transaction la plus longue (s) | plus grand âge d'une transaction ouverte (précision 15 s, intervalle de collecte) |

Sans activité (aucun verrou, aucune transaction), ces colonnes valent **0**. Une cellule vide (`-`) signifie qu'aucune mesure n'existe pour cette heure (agent arrêté). Les sessions de monAp_pg lui-même (`asemon-*`) sont exclues.

## 3. Navigation

Tous les dashboards portent la même barre de boutons : **Parc, Instance, Macro, Intermédiaire, Micro, Capacity, Seuils**. L'instance choisie est conservée d'une page à l'autre.

```
Parc ──(clic sur une instance)──> Instance ──> Macro → Intermédiaire → Micro → Détail session / requête
  └─ Seuils (consulter et modifier)
```

## 4. Mettre à jour le POC (VM-Monitoring, dans Grafana)

Aucune commande sur les VM. Dans Grafana : **Dashboards → New → Import → Upload dashboard JSON file**, datasource **ASEMON Monitoring**, **Overwrite** si Grafana le propose. Fichiers de `grafana/` (récupérés par `git pull` sur ton PC, branche `main`) :

1. `asemon-fleet.json` (nouveau) ;
2. `asemon-instance.json` (nouveau) ;
3. `asemon-macro.json`, `asemon-intermediate.json`, `asemon-micro.json`, `asemon-capacity.json` : nouvelle barre de boutons ;
4. **Pas** `asemon-thresholds.json` : ton formulaire est déjà relié à ta datasource. Seule la barre de boutons manque sur cette page ; pour l'avoir, réimporte-le puis refais l'étape « relier le formulaire à la datasource » ([21](21-seuils.md) §7).

## 5. Vérifier

- **Parc** : deux lignes (VM-Cible, VM-Monitoring), états colorés, une courbe de gravité par instance. Avec le pgbench sur VM-Cible, son indicateur le plus problématique peut être le CPU ou une attente de verrou.
- **Instance**, instance VM-Cible : trois lignes horaires, CPU et transactions non nuls pendant le pgbench ; instance VM-Monitoring : valeurs proches de 0.
- Un seuil abaissé sur la page Seuils (par exemple CPU de VM-Monitoring à 0,1 / 0,2) fait passer l'instance en alarme sur le Parc au calcul suivant (5 minutes au plus). Remettre ensuite : `SELECT asemon.reset_threshold(2, 'cpu_pct');`.

## 6. Adresse affichée de l'instance

Le Parc affiche l'hôte enregistré par chaque agent ; les deux instances indiquent `localhost` par défaut. Pour afficher l'adresse réelle, ajouter dans `/opt/asemon/app/config.py` de chaque VM (voir `INSTANCE_HOST`, [19](19-multi-instance.md)) :

```python
INSTANCE_HOST = "192.168.1.30"   # 192.168.1.28 sur VM-Monitoring
```
puis `sudo systemctl restart asemon-collector asemon-sampler asemon-logparser`. Facultatif.

## 7. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| Parc vide | aucune instance enregistrée, ou `sql/17` non appliqué | `SELECT * FROM asemon.v_instance_status;` ; [21](21-seuils.md) §4 |
| Tout « Pas de mesure » | `compute_kpi_values()` n'est plus appelée | `journalctl -u asemon-rollup -n 5` |
| Courbe de gravité vide | moins de 5 minutes d'historique, ou instance sans valeur | attendre un cycle du rollup |
| Les boutons Parc / Instance manquent | dashboard non réimporté | étape 3 de §4 |
| Clic sur le nom de l'instance sans effet | menu de liens : le clic ouvre une liste de 2 choix (instance ou Macro) | choisir « Page de l'instance » |
