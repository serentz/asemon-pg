# Création scriptée des deux VM sous Hyper-V

Le script `infra/hyperv/create_vms.ps1` remplace les sections 1.2 et 2 du [guide pas à pas](00-guide-pas-a-pas.md) : il crée le commutateur réseau et les deux VM, et **installe Ubuntu sans intervention** (autoinstall). Il est rejouable : `-Destroy` supprime les VM, on relance, on obtient les mêmes.

| VM Hyper-V | Serveur Ubuntu | Rôle | vCPU / RAM / disque |
|---|---|---|---|
| `VM-Monitoring` | `vmmonitoring` | Dépôt PostgreSQL + Grafana | 2 / 6 Go fixes / 40 Go |
| `VM-Cible` | `vmcible` | PostgreSQL 17 surveillé + collecteur, échantillonneur, lecteur de journaux | 2 / 6 Go fixes / 40 Go |

La mémoire dynamique est désactivée (elle provoque des plantages pendant les installations), le démarrage sécurisé est réglé pour Linux (modèle *Autorité de certification UEFI Microsoft*), l'utilisateur est `admin01` et le clavier français.

## Prérequis

- Windows 11 Pro, Enterprise ou Éducation avec Hyper-V (guide, section 1.1), 12 Go de RAM libres, 80 Go de disque.
- L'ISO `ubuntu-26.04.1-live-server-amd64.iso` (guide, section 1.3).
- Un mot de passe pour `admin01` : demandé par le script, jamais écrit dans git. Il est identique sur les deux VM, 8 caractères minimum parmi lettres, chiffres et `!@#%^*_+=.,:;/?-`.

## Lancer

PowerShell **en administrateur**, depuis le dossier du dépôt.

**Réseau externe (défaut, comme le guide)** : les VM prennent une adresse DHCP de ton réseau local, sur le commutateur `Monitoring-Switch`. S'il n'existe pas encore, indique la carte du PC à relier (`Get-NetAdapter -Physical`) :

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\infra\hyperv\create_vms.ps1 -UbuntuIso "C:\ISO\ubuntu-26.04.1-live-server-amd64.iso" -NetAdapterName "Ethernet"
```

Si le commutateur existe déjà (créé à la main selon la section 1.2), omets `-NetAdapterName`. La création d'un commutateur externe coupe la connexion du PC quelques secondes.

**Réseau interne** (sans toucher à ton réseau) : commutateur interne et NAT `192.168.70.0/24`, adresses fixes `192.168.70.28` (VM-Monitoring) et `192.168.70.30` (VM-Cible), les VM sont joignables depuis le PC :

```powershell
.\infra\hyperv\create_vms.ps1 -UbuntuIso "C:\ISO\ubuntu-26.04.1-live-server-amd64.iso" -Network Internal -SwitchName "Monitoring-Internal"
```

Le script :
1. prépare le commutateur ;
2. crée les VM et un petit disque de configuration (volume `CIDATA`) : nom, utilisateur, SSH, disque entier, clavier, réseau ;
3. démarre les VM, ouvre leurs consoles et attend (10 à 20 minutes) ;
4. quand les VM se sont éteintes seules, retire l'ISO et les disques de configuration (ils contiennent le mot de passe), redémarre les VM ;
5. attend l'adresse IP de chaque VM et que SSH réponde, puis affiche les commandes `ssh`.

Si une console demande `Continue with autoinstall?`, taper `yes` puis Entrée.

Notez `IP_MONITORING` et `IP_CIBLE`, puis continuez au guide, **section 3**. En réseau externe, fixez l'adresse de `VM-Monitoring` par une réservation DHCP dans le routeur (guide, section 2.4) : elle sera écrite dans la configuration de `VM-Cible`.

Options utiles : `-AdminUser`, `-SshPublicKeyFile` (par défaut `~\.ssh\id_ed25519.pub` ou `id_rsa.pub` s'ils existent), `-Keyboard`, `-VmRoot` (défaut `C:\HyperV\monAp_pg`), `-Subnet`, `-NoConsole`, `-Only VM-Cible`.

## Recommencer de zéro

```powershell
.\infra\hyperv\create_vms.ps1 -Destroy
```

Après confirmation (`OUI`), supprime les deux VM et leurs disques. Le commutateur est conservé.

## En cas de problème

| Symptôme | Piste |
|---|---|
| `Commutateur ... absent : preciser la carte physique` | Ajouter `-NetAdapterName "<nom>"` (liste affichée dans le message) |
| `Il faut le chemin complet d'un fichier .iso` | Donner le fichier, pas le dossier |
| `VM deja presentes` | `-Destroy` puis relancer |
| Console noire au démarrage | `Get-VMFirmware -VMName VM-Cible` doit montrer le modèle *MicrosoftUEFICertificateAuthority* |
| L'installateur pose des questions | La configuration n'a pas été lue : la VM doit avoir 2 disques (`Get-VMHardDiskDrive -VMName VM-Cible`) |
| Adresse IP `?` ou `SSH ne repond pas` en fin de script | Console de la VM : `ip -br a` ; en réseau externe, vérifier que le DHCP répond sur ce réseau |
| Le script s'arrête sur le délai | Regarder les consoles, relancer avec `-Destroy` puis sans |

Ce script n'a pas encore été exécuté sur une machine Hyper-V réelle : en cas d'écart avec ce document, corriger le script ou ouvrir une issue.
