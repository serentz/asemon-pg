<#
.SYNOPSIS
  Cree les 2 VM Hyper-V de monAp_pg (VM-Monitoring et VM-Cible), Ubuntu installe automatiquement.

.DESCRIPTION
  - VM-Monitoring (hostname vmmonitoring) : depot PostgreSQL + Grafana ;
  - VM-Cible (hostname vmcible) : PostgreSQL 17 surveille + collecteur, echantillonneur, lecteur de journaux ;
  - 2 vCPU, 6 Go de RAM fixe (memoire dynamique desactivee : voir docs/00-guide-pas-a-pas.md), disque 40 Go ;
  - chaque VM recoit un petit disque "graine" (CIDATA) avec sa configuration : nom, utilisateur, SSH,
    disque entier, clavier ;
  - le script attend la fin des installations (les VM s'eteignent seules), retire l'ISO et les disques
    graines, redemarre les VM, attend leur adresse IP et que SSH reponde.

  Deux modes reseau (-Network) :
    External (defaut) : commutateur externe 'Monitoring-Switch' (celui du guide), adresses DHCP du reseau local.
                        Le commutateur est cree s'il n'existe pas : il faut alors -NetAdapterName.
    Internal          : commutateur interne + NAT 192.168.70.0/24, adresses fixes (.28 et .30), sans DHCP.

  Rejouable : -Destroy supprime les VM (et leurs disques) pour recommencer de zero ; -Only limite a une VM.

.EXAMPLE
  .\create_vms.ps1 -UbuntuIso "C:\ISO\ubuntu-26.04.1-live-server-amd64.iso"

.EXAMPLE
  .\create_vms.ps1 -UbuntuIso "C:\ISO\ubuntu-26.04.1-live-server-amd64.iso" -NetAdapterName "Ethernet"   # 1er lancement : cree le commutateur externe

.EXAMPLE
  .\create_vms.ps1 -Destroy        # supprime les 2 VM et leurs disques

  PowerShell ouvert en administrateur. Fonctionnalite Windows "Hyper-V" requise.
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$UbuntuIso,
    [ValidateSet('External', 'Internal')]
    [string]$Network    = 'External',
    [string]$VmRoot     = 'C:\HyperV\monAp_pg',
    [string]$SwitchName = 'Monitoring-Switch',
    [string]$NetAdapterName,                  # carte physique, seulement pour creer un commutateur externe
    [string]$Subnet     = '192.168.70',       # mode Internal : trois premiers octets, masque /24
    [string]$AdminUser  = 'admin01',          # utilisateur cree sur les 2 VM
    [securestring]$AdminPassword,             # sinon demande a la saisie
    [string]$SshPublicKeyFile,                # defaut : ~\.ssh\id_ed25519.pub ou id_rsa.pub s'ils existent
    [string]$Keyboard   = 'fr',
    [int]$InstallTimeoutMin = 60,
    [string[]]$Only,                          # ne traiter que ces VM, ex. -Only VM-Cible
    [switch]$Destroy,                         # supprime les VM du POC (et rien d'autre)
    [switch]$NoConsole                        # n'ouvre pas les consoles
)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot

# Nom Hyper-V, nom du serveur, vCPU, RAM (Go), disque (Go), derniere partie de l'IP (mode Internal)
$vms = @(
    @{ Name = 'VM-Monitoring'; Hostname = 'vmmonitoring'; Cpu = 2; MemGB = 6; DiskGB = 40; Ip = 28 },
    @{ Name = 'VM-Cible';      Hostname = 'vmcible';      Cpu = 2; MemGB = 6; DiskGB = 40; Ip = 30 }
)

$allVms = $vms      # la liste complete sert au fichier /etc/hosts (mode Internal)
if ($Only) {
    $unknown = $Only | Where-Object { $allVms.Name -notcontains $_ }
    if ($unknown) { throw "-Only : VM inconnue(s) $($unknown -join ', '). Valeurs possibles : $($allVms.Name -join ', ')" }
    $vms = @($allVms | Where-Object { $Only -contains $_.Name })
}

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    throw "Module Hyper-V absent. Activer la fonctionnalite Windows Hyper-V (Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All), redemarrer, relancer."
}

# --- Mode -Destroy ---------------------------------------------------------------
if ($Destroy) {
    Write-Warning "Va supprimer les VM $($vms.Name -join ', ') et leurs disques dans $VmRoot."
    if ((Read-Host "Taper OUI pour confirmer") -ne 'OUI') { Write-Host "Annule."; return }
    foreach ($v in $vms) {
        $vm = Get-VM -Name $v.Name -ErrorAction SilentlyContinue
        if ($vm) {
            if ($vm.State -ne 'Off') { Stop-VM -Name $v.Name -TurnOff -Force }
            Remove-VM -Name $v.Name -Force
            Write-Host "[-] VM $($v.Name) supprimee"
        }
        $dir = Join-Path $VmRoot $v.Name
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
    Write-Host "Reseau '$SwitchName' conserve. Relancer le script sans -Destroy pour recreer les VM."
    return
}

# --- Controles -------------------------------------------------------------------
if (-not $UbuntuIso -or -not (Test-Path -LiteralPath $UbuntuIso -PathType Leaf)) {
    throw "-UbuntuIso : il faut le chemin complet d'un fichier .iso existant (pas d'un dossier)."
}
$existing = $vms | Where-Object { Get-VM -Name $_.Name -ErrorAction SilentlyContinue }
if ($existing) {
    throw "VM deja presentes : $($existing.Name -join ', '). Relancer avec -Destroy pour tout supprimer et recommencer."
}

# Mot de passe
if (-not $AdminPassword) {
    $s1 = Read-Host "Mot de passe de '$AdminUser' sur les 2 VM (8 caracteres min.)" -AsSecureString
    $s2 = Read-Host "Confirmer le mot de passe" -AsSecureString
    $plain1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1))
    $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2))
    if ($plain1 -ne $plain2) { throw "Les deux mots de passe different." }
    $Password = $plain1
} else {
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword))
}
# Caracteres autorises : evitent tout probleme de guillemets dans YAML et kickstart
if ($Password -notmatch '^[A-Za-z0-9!@#%^*_+=.,:;/?-]{8,}$') {
    throw "Mot de passe : 8 caracteres minimum, parmi lettres, chiffres et !@#%^*_+=.,:;/?- (pas d'espace, guillemet, \ ni `$)."
}
if ($AdminUser -notmatch '^[a-z][a-z0-9_-]{0,30}$') { throw "-AdminUser : minuscules, chiffres, - et _ (commence par une lettre)." }

# Cle SSH publique (facultative)
if (-not $SshPublicKeyFile) {
    foreach ($c in @('id_ed25519.pub', 'id_rsa.pub')) {
        $f = Join-Path $HOME ".ssh\$c"
        if (Test-Path -LiteralPath $f) { $SshPublicKeyFile = $f; break }
    }
}
$sshKey = $null
if ($SshPublicKeyFile -and (Test-Path -LiteralPath $SshPublicKeyFile)) {
    $sshKey = (Get-Content -LiteralPath $SshPublicKeyFile -TotalCount 1).Trim()
    if ($sshKey -notmatch '^(ssh-[a-z0-9]+|ecdsa-[a-z0-9-]+) [A-Za-z0-9+/=]+( .*)?$' -or $sshKey -match '["''\\]') {
        throw "Cle publique illisible dans $SshPublicKeyFile"
    }
    Write-Host "[i] Cle SSH publique ajoutee : $SshPublicKeyFile"
} else {
    Write-Host "[i] Pas de cle SSH publique : connexion par mot de passe uniquement."
}

# --- Reseau ----------------------------------------------------------------------------------------
if ($Network -eq 'Internal') {
    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        Write-Host "[+] Commutateur interne '$SwitchName'"
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    }
    $alias = "vEthernet ($SwitchName)"
    if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress "$Subnet.1" -ErrorAction SilentlyContinue)) {
        Write-Host "[+] Adresse $Subnet.1/24 sur $alias (passerelle des VM)"
        New-NetIPAddress -InterfaceAlias $alias -IPAddress "$Subnet.1" -PrefixLength 24 | Out-Null
    }
    $nat = Get-NetNat -ErrorAction SilentlyContinue
    if (-not ($nat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq "$Subnet.0/24" })) {
        Write-Host "[+] NAT $Subnet.0/24 (acces Internet des VM)"
        New-NetNat -Name $SwitchName -InternalIPInterfaceAddressPrefix "$Subnet.0/24" | Out-Null
    }
} else {
    $sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($sw) {
        Write-Host "[i] Commutateur '$SwitchName' existant utilise (type $($sw.SwitchType))."
    } else {
        if (-not $NetAdapterName) {
            $nics = (Get-NetAdapter -Physical | Where-Object Status -eq 'Up').Name -join ', '
            throw "Commutateur '$SwitchName' absent : preciser la carte physique a relier avec -NetAdapterName (cartes actives : $nics)."
        }
        Write-Host "[+] Commutateur externe '$SwitchName' sur la carte '$NetAdapterName' (la connexion du PC peut s'interrompre quelques secondes)"
        New-VMSwitch -Name $SwitchName -NetAdapterName $NetAdapterName -AllowManagementOS $true | Out-Null
    }
}

# --- Disque graine (volume FAT32 avec la configuration d'installation) ---------------
$utf8 = New-Object System.Text.UTF8Encoding($false)
function New-SeedDisk {
    param([string]$Path, [string]$Label, [hashtable]$Files)
    New-VHD -Path $Path -SizeBytes 128MB -Dynamic | Out-Null
    $number = (Mount-VHD -Path $Path -Passthru | Get-Disk).Number
    try {
        Initialize-Disk -Number $number -PartitionStyle MBR
        $part = New-Partition -DiskNumber $number -UseMaximumSize -AssignDriveLetter
        $vol = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $Label -Force -Confirm:$false
        $root = "$($vol.DriveLetter):\"
        foreach ($name in $Files.Keys) {
            [IO.File]::WriteAllText((Join-Path $root $name), ($Files[$name] -replace "`r`n", "`n"), $utf8)
        }
    } finally {
        Dismount-VHD -Path $Path
    }
}

function Expand-Template {
    param([string]$TemplateFile, [hashtable]$Values)
    $t = Get-Content -LiteralPath (Join-Path $Here "templates\$TemplateFile") -Raw
    foreach ($k in $Values.Keys) { $t = $t.Replace("{{$k}}", [string]$Values[$k]) }
    return $t
}

if ($Network -eq 'Internal') {
    $hostsPlain = ($allVms | Sort-Object { $_.Ip } | ForEach-Object { "{0}.{1}  {2}" -f $Subnet, $_.Ip, $_.Hostname }) -join "`n"
} else {
    $hostsPlain = "# monAp_pg : adresses par DHCP, pas de fixe a declarer"
}
$hostsYaml = ($hostsPlain -split "`n" | ForEach-Object { "          $_" }) -join "`n"

# --- Creation des VM --------------------------------------------------------------------
foreach ($v in $vms) {
    $name = $v.Name
    $dir  = Join-Path $VmRoot $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $addr = if ($Network -eq 'Internal') { "$Subnet.$($v.Ip)" } else { 'DHCP' }
    Write-Host "[+] VM $name ($($v.Hostname), $($v.Cpu) vCPU, $($v.MemGB) Go fixes, disque $($v.DiskGB) Go, $addr)"

    New-VM -Name $name -Generation 2 -Path $VmRoot `
        -MemoryStartupBytes ([uint64]$v.MemGB * 1GB) `
        -NewVHDPath (Join-Path $dir "$name.vhdx") -NewVHDSizeBytes ([uint64]$v.DiskGB * 1GB) `
        -SwitchName $SwitchName | Out-Null
    Set-VMProcessor -VMName $name -Count $v.Cpu
    Set-VMMemory -VMName $name -DynamicMemoryEnabled $false
    Set-VM -Name $name -AutomaticCheckpointsEnabled $false

    # Configuration d'installation
    $iso = $UbuntuIso
    $networkYaml = if ($Network -eq 'Internal') {
@"
  network:
    version: 2
    ethernets:
      eth0:
        dhcp4: false
        addresses: [$Subnet.$($v.Ip)/24]
        routes:
          - to: default
            via: $Subnet.1
        nameservers:
          addresses: [8.8.8.8, 1.1.1.1]
"@
    } else {
@"
  network:
    version: 2
    ethernets:
      eth0:
        dhcp4: true
"@
    }
    $values = @{
        NAME = $v.Hostname; NETWORK = $networkYaml; USER = $AdminUser
        PASSWORD = $Password; KEYBOARD = $Keyboard
    }
    $seed = Join-Path $dir "seed-$name.vhdx"
    # ssh_authorized_keys ne doit jamais etre une liste vide : la ligne est omise sans cle
    $values.SSHKEYS = if ($sshKey) { "ssh_authorized_keys: [""$sshKey""]" } else { "" }
    $values.HOSTS   = $hostsYaml
    New-SeedDisk -Path $seed -Label 'CIDATA' -Files @{
        'user-data' = (Expand-Template 'ubuntu-user-data.tpl' $values)
        'meta-data' = "instance-id: $($v.Hostname)-install`nlocal-hostname: $($v.Hostname)`n"
    }
    Add-VMHardDiskDrive -VMName $name -Path $seed -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1

    # ISO, Secure Boot Linux, ordre de demarrage : disque systeme puis DVD
    # (disque vide au premier demarrage -> l'ISO ; apres installation -> le disque, sans toucher a l'ISO)
    $dvd = Add-VMDvdDrive -VMName $name -Path $iso -Passthru
    $os  = Get-VMHardDiskDrive -VMName $name | Where-Object { $_.Path -like "*\$name.vhdx" }
    Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' `
        -BootOrder $os, $dvd
}

# --- Installation automatique -------------------------------------------------------------
Start-VM -Name $vms.Name
if (-not $NoConsole) { foreach ($v in $vms) { Start-Process vmconnect.exe -ArgumentList 'localhost', $v.Name } }

Write-Host ""
Write-Host "Installation en cours dans les VM (10 a 20 minutes, en parallele)."
Write-Host "Si une console demande 'Continue with autoinstall?', taper  yes  puis Entree."
Write-Host "Les VM s'eteignent toutes seules a la fin : ne rien faire d'autre."

$pending  = [System.Collections.ArrayList]@($vms.Name)
$deadline = (Get-Date).AddMinutes($InstallTimeoutMin)
while ($pending.Count -gt 0) {
    if ((Get-Date) -gt $deadline) {
        throw "Delai de $InstallTimeoutMin min depasse, VM encore en cours : $($pending -join ', '). Verifier leurs consoles."
    }
    Start-Sleep -Seconds 20
    foreach ($n in @($pending)) {
        if ((Get-VM -Name $n).State -eq 'Off') {
            Write-Host "[ok] $n : installation terminee"
            $pending.Remove($n)
        }
    }
}

# --- Nettoyage : ISO et disques graines (ils contiennent le mot de passe) --------------------
foreach ($v in $vms) {
    $n = $v.Name
    Get-VMDvdDrive -VMName $n | Set-VMDvdDrive -Path $null
    Get-VMHardDiskDrive -VMName $n | Where-Object { $_.Path -like "*seed-$n.vhdx" } | Remove-VMHardDiskDrive
    Remove-Item -LiteralPath (Join-Path (Join-Path $VmRoot $n) "seed-$n.vhdx") -Force -ErrorAction SilentlyContinue
}

# --- Premier demarrage, adresse IP et attente de SSH -------------------------------------------------
Start-VM -Name $vms.Name
Write-Host "[i] VM redemarrees, attente de l'adresse IP et de SSH..."
function Test-Port($ip, $port) {
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync($ip, $port).Wait(1500) } catch { return $false } finally { $c.Close() }
}
function Get-VmIPv4($vmName) {
    $ips = (Get-VMNetworkAdapter -VMName $vmName).IPAddresses | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' }
    return ($ips | Select-Object -First 1)
}
$deadline = (Get-Date).AddMinutes(10)
$addrOf = @{}
$up = @{}
while ($up.Count -lt $vms.Count -and (Get-Date) -lt $deadline) {
    foreach ($v in $vms) {
        if ($up.ContainsKey($v.Name)) { continue }
        $ip = if ($Network -eq 'Internal') { "$Subnet.$($v.Ip)" } else { Get-VmIPv4 $v.Name }
        if ($ip) {
            $addrOf[$v.Name] = $ip
            if (Test-Port $ip 22) { $up[$v.Name] = $true }
        }
    }
    if ($up.Count -lt $vms.Count) { Start-Sleep -Seconds 10 }
}

Write-Host ""
foreach ($v in $vms) {
    $ip = if ($addrOf.ContainsKey($v.Name)) { $addrOf[$v.Name] } else { '?' }
    $state = if ($up.ContainsKey($v.Name)) { 'SSH ok' } else { 'SSH ne repond pas (voir la console)' }
    Write-Host ("  {0,-14} ssh {1}@{2,-15} {3}" -f $v.Name, $AdminUser, $ip, $state)
}
Write-Host ""
Write-Host "Notez IP_MONITORING (VM-Monitoring) et IP_CIBLE (VM-Cible)."
if ($Network -eq 'External') {
    Write-Host "Reseau externe : l'adresse de VM-Monitoring doit rester fixe (reservation DHCP dans le routeur, guide section 2.4)."
}
Write-Host "Etape suivante : docs/00-guide-pas-a-pas.md section 3 (SSH, mise a jour, installation)."
