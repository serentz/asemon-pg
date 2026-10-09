#!/usr/bin/env bash
# ASEMON-PG : fonctions communes aux scripts d'installation. À inclure avec `source`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;34m[asemon]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "À lancer avec sudo (ou en root)."; }

# Charge scripts/asemon.env (ou le fichier donné par ASEMON_ENV) et applique les défauts.
load_env() {
    local f="${ASEMON_ENV:-$SCRIPT_DIR/asemon.env}"
    [ -f "$f" ] || die "Fichier de paramètres absent : $f (copier scripts/asemon.env.example en scripts/asemon.env et l'adapter)."
    # shellcheck disable=SC1090
    . "$f"
    PG_VERSION="${PG_VERSION:-17}"
    SUBNET="${SUBNET:-192.168.1.0/24}"
    SERVICE_USER="${SERVICE_USER:-admin01}"
    INSTALL_DIR="${INSTALL_DIR:-/opt/asemon}"
    INTERVAL="${INTERVAL:-15}"
    SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-2}"
    GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
    TARGET_ALLOW_SUBNET="${TARGET_ALLOW_SUBNET:-}"
    PGCONF_DIR="/etc/postgresql/$PG_VERSION/main"
    PG_SERVICE="postgresql@${PG_VERSION}-main"
    # Commande psql (surchargeable pour les tests : PSQL_CMD="... psql -h /socket -p 5433")
    PSQL_CMD="${PSQL_CMD:-runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1}"
}

# require_vars NOM... : échoue si une variable est vide.
require_vars() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || die "Paramètre $v manquant dans asemon.env."
    done
}

# check_password NOM : refuse les mots de passe qui casseraient les chaînes de connexion.
check_password() {
    local name="$1" val="${!1:-}"
    [[ "$val" =~ ^[A-Za-z0-9._@%+=-]{8,}$ ]] || die "$name : 8 caractères minimum, lettres/chiffres/._@%+=- uniquement."
    case "$val" in CHANGEME*) warn "$name porte encore la valeur d'exemple (CHANGEME...) : à remplacer hors POC." ;; esac
}

# psql_sql BASE : exécute le SQL lu sur l'entrée standard (variables psql possibles via -v).
psql_sql() { local db="$1"; shift; $PSQL_CMD -d "$db" "$@"; }

# psql_file BASE FICHIER : exécute un fichier SQL par redirection. Nécessaire : l'utilisateur
# postgres ne peut pas lire /home/<user>, donc c'est le shell du script qui ouvre le fichier.
psql_file() { local db="$1" f="$2"; log "SQL $(basename "$f") -> $db"; $PSQL_CMD -d "$db" < "$f"; }

# psql_value BASE REQUETE : renvoie la première valeur (sans en-tête).
psql_value() { local db="$1" q="$2"; $PSQL_CMD -d "$db" -At -c "$q"; }

# set_role_password ROLE VARIABLE : ALTER USER sans exposer le mot de passe dans la liste des processus.
set_role_password() {
    local role="$1" pw="${!2}"
    printf "ALTER USER %s WITH PASSWORD :'pw';\n" "$role" | $PSQL_CMD -d postgres -v "pw=$pw"
}

# install_file SOURCE CIBLE [MODE] : copie si le contenu diffère ; positionne CHANGED=1 dans ce cas.
CHANGED=0
install_file() {
    local src="$1" dst="$2" mode="${3:-0644}"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
    install -m "$mode" "$src" "$dst"
    CHANGED=1
    log "installé : $dst"
}

# --- Dépôts et paquets ---------------------------------------------------------------
apt_update_once() {
    if [ -z "${_APT_UPDATED:-}" ]; then DEBIAN_FRONTEND=noninteractive apt-get update -qq; _APT_UPDATED=1; fi
}
apt_install() { apt_update_once; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null; }

setup_pgdg() {
    [ -f /etc/apt/sources.list.d/pgdg.list ] && { ok "dépôt PGDG déjà présent"; return; }
    log "Ajout du dépôt PostgreSQL (PGDG)"
    apt_install curl ca-certificates gnupg lsb-release
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
    local codename
    codename="$(lsb_release -cs)"
    # Si PGDG ne publie pas encore le nom de code de cette Ubuntu, repli sur noble (compatible).
    if ! curl -fsI "https://apt.postgresql.org/pub/repos/apt/dists/${codename}-pgdg/Release" >/dev/null 2>&1; then
        warn "PGDG n'a pas de dépôt pour '$codename' : repli sur 'noble'."
        codename=noble
    fi
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
    _APT_UPDATED=""
}

install_postgres() {
    setup_pgdg
    log "Installation de postgresql-$PG_VERSION"
    apt_install "postgresql-$PG_VERSION" "$@"
    systemctl enable --now "$PG_SERVICE" >/dev/null 2>&1 || true
    ok "PostgreSQL $PG_VERSION installé"
}

# Vérifie que conf.d est bien lu par postgresql.conf (cas par défaut des paquets Debian/Ubuntu).
ensure_conf_d() {
    mkdir -p "$PGCONF_DIR/conf.d"
    if ! grep -Eq "^\s*include_dir\s*=\s*'conf\.d'" "$PGCONF_DIR/postgresql.conf"; then
        echo "include_dir = 'conf.d'" >> "$PGCONF_DIR/postgresql.conf"
        log "include_dir 'conf.d' ajouté à postgresql.conf"
    fi
}

# write_pg_conf FICHIER_SOURCE : installe conf.d/asemon.conf ; positionne CHANGED=1 si modifié.
write_pg_conf() { install_file "$1" "$PGCONF_DIR/conf.d/asemon.conf" 0644; }

# set_hba_block MARQUEUR LIGNE... : bloc géré dans pg_hba.conf, remplacé à chaque exécution.
set_hba_block() {
    local marker="$1"; shift
    local f="$PGCONF_DIR/pg_hba.conf" tmp
    tmp="$(mktemp)"
    # retire l'ancien bloc
    sed "/^# BEGIN ASEMON-PG $marker\$/,/^# END ASEMON-PG $marker\$/d" "$f" > "$tmp"
    {
        cat "$tmp"
        echo "# BEGIN ASEMON-PG $marker"
        printf '%s\n' "$@"
        echo "# END ASEMON-PG $marker"
    } > "$tmp.new"
    if ! cmp -s "$tmp.new" "$f"; then
        cat "$tmp.new" > "$f"
        CHANGED=1
        log "pg_hba.conf : bloc '$marker' mis à jour"
    fi
    rm -f "$tmp" "$tmp.new"
}

restart_postgres() {
    log "Redémarrage de PostgreSQL (les connexions sont coupées quelques secondes)"
    systemctl restart "$PG_SERVICE"
    local i
    for i in $(seq 1 30); do
        $PSQL_CMD -d postgres -c 'SELECT 1' >/dev/null 2>&1 && { ok "PostgreSQL en ligne"; return; }
        sleep 1
    done
    die "PostgreSQL ne répond pas après redémarrage : journalctl -xeu $PG_SERVICE"
}

# Refuse de continuer si postgresql.auto.conf redéfinit un paramètre géré ici (il l'emporterait).
check_auto_conf() {
    local auto="/var/lib/postgresql/$PG_VERSION/main/postgresql.auto.conf" p
    [ -f "$auto" ] || return 0
    for p in "$@"; do
        if grep -Eq "^\s*$p\s*=" "$auto"; then
            die "$p est défini dans postgresql.auto.conf (ALTER SYSTEM) et l'emporterait sur conf.d/asemon.conf. Le retirer : ALTER SYSTEM RESET $p; puis relancer."
        fi
    done
}

# Active et démarre des unités systemd copiées depuis le dépôt.
install_units() {
    local u
    for u in "$@"; do install_file "$REPO_DIR/systemd/$u" "/etc/systemd/system/$u" 0644; done
    systemctl daemon-reload
}
