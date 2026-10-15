#!/usr/bin/env bash
# ============================================================
# monAp_pg : installation de VM-Monitoring (repository + Grafana)
#
#   sudo ./scripts/install-monitoring.sh              installation complète
#   sudo ./scripts/install-monitoring.sh --sql-only   applique seulement les scripts SQL
#                                                     (mise à jour du schéma, sans toucher au reste)
#
# Prérequis : Ubuntu installé, accès réseau (apt), scripts/asemon.env renseigné.
# La création de la VM et l'installation d'Ubuntu ne sont PAS couvertes.
# Le script est rejouable : chaque étape vérifie l'état avant d'agir.
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SQL_ONLY=0
[ "${1:-}" = "--sql-only" ] && SQL_ONLY=1

need_root
load_env
require_vars COLLECTOR_PASSWORD GRAFANA_RO_PASSWORD
check_password COLLECTOR_PASSWORD
check_password GRAFANA_RO_PASSWORD
[ -n "${GRAFANA_THRESHOLDS_PASSWORD:-}" ] && check_password GRAFANA_THRESHOLDS_PASSWORD

# Ordre d'application. 07 est un brouillon et n'est jamais appliqué.
SQL_FILES=(01-schema-asemon 02-roles-and-grants 04-schema-extension 05-schema-sessions
           06-rollup-horaire 08-schema-samples 09-retention 10-plans-query-id 11-schema-kcache 12-plans-lisibles 13-capacity
           14-multi-instance 15-instance-id-cutover 16-internal-users 17-thresholds)

apply_schema() {
    log "Schéma du repository"
    if [ "$(psql_value postgres "SELECT 1 FROM pg_database WHERE datname = 'monitoring'")" != "1" ]; then
        $PSQL_CMD -d postgres -c "CREATE DATABASE monitoring"
        log "base monitoring créée"
    fi
    local f
    for f in "${SQL_FILES[@]}"; do
        psql_file monitoring "$REPO_DIR/sql/$f.sql"
    done
    # Les mots de passe sont fixés ici (les scripts SQL ne gardent que des valeurs d'exemple).
    set_role_password collector_writer COLLECTOR_PASSWORD
    set_role_password grafana_ro GRAFANA_RO_PASSWORD
    if [ -n "${GRAFANA_THRESHOLDS_PASSWORD:-}" ]; then
        open_role_login grafana_thresholds GRAFANA_THRESHOLDS_PASSWORD
    else
        warn "GRAFANA_THRESHOLDS_PASSWORD vide : le rôle grafana_thresholds reste sans connexion (seuils en lecture seule dans Grafana)"
    fi
    # Deuxième passe des droits : couvre les tables créées par les scripts suivants.
    psql_file monitoring "$REPO_DIR/sql/02-roles-and-grants.sql"
    psql_value monitoring "SELECT asemon.maintain_samples()" >/dev/null
    ok "schéma appliqué ($(psql_value monitoring "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'asemon'") tables et vues)"
}

if [ "$SQL_ONLY" -eq 1 ]; then
    apply_schema
    exit 0
fi

# --- 1. PostgreSQL -------------------------------------------------------------------
install_postgres
ensure_conf_d
check_auto_conf listen_addresses

# --- 2. Réseau : écoute et accès du collecteur et de Grafana ---------------------------
CHANGED=0
tmp="$(mktemp)"
cat > "$tmp" <<CONF
# Géré par monAp_pg (scripts/install-monitoring.sh) : ne pas modifier à la main.
listen_addresses = '*'
CONF
write_pg_conf "$tmp"; rm -f "$tmp"
set_hba_block monitoring \
    "host    monitoring      collector_writer   $SUBNET   scram-sha-256" \
    "host    monitoring      grafana_ro         $SUBNET   scram-sha-256"
if [ "$CHANGED" -eq 1 ]; then restart_postgres; else ok "configuration réseau inchangée"; fi

if [ -n "$POSTGRES_PASSWORD" ]; then
    check_password POSTGRES_PASSWORD
    set_role_password postgres POSTGRES_PASSWORD
fi

# --- 3. Schéma ---------------------------------------------------------------------
apply_schema

# --- 4. Timers : rollup, maintenance des partitions, rétention ---------------------------
# retention.py (Release 3) est le point d'entrée unique de la rétention : il remplace
# l'ancien asemon-purge.timer. Il a besoin de Python et de psycopg sur VM-Monitoring.
log "Environnement Python de la rétention ($INSTALL_DIR)"
apt_install python3 python3-venv python3-pip
mkdir -p "$INSTALL_DIR/app"
if [ ! -x "$INSTALL_DIR/venv/bin/python3" ]; then
    python3 -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install -q "psycopg[binary]"
install -m 0644 -o root -g root "$REPO_DIR/python/retention.py" "$INSTALL_DIR/app/retention.py"
ok "retention.py installé"

log "Timers systemd"
install_units asemon-rollup.service asemon-rollup.timer \
              asemon-samples-maintenance.service asemon-samples-maintenance.timer
sed -e "s|/opt/asemon|$INSTALL_DIR|g" "$REPO_DIR/systemd/asemon-retention.service" > /etc/systemd/system/asemon-retention.service
install_file "$REPO_DIR/systemd/asemon-retention.timer" /etc/systemd/system/asemon-retention.timer 0644
if [ -f /etc/systemd/system/asemon-purge.timer ]; then
    log "Remplacement de l'ancien asemon-purge.timer par asemon-retention.timer"
    systemctl disable --now asemon-purge.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/asemon-purge.timer /etc/systemd/system/asemon-purge.service
fi
systemctl daemon-reload
systemctl enable --now asemon-rollup.timer asemon-samples-maintenance.timer asemon-retention.timer >/dev/null
ok "timers actifs"

# --- 5. Grafana --------------------------------------------------------------------
if ! command -v grafana-server >/dev/null 2>&1; then
    log "Installation de Grafana"
    apt_install apt-transport-https software-properties-common wget gnupg
    mkdir -p /etc/apt/keyrings
    wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg --yes
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
    _APT_UPDATED=""
    apt_install grafana
fi
# Panneau « Business Text » (v2.1) : affiche le SQL et les plans dans une boîte défilante
if [ ! -d /var/lib/grafana/plugins/marcusolsson-dynamictext-panel ]; then
    log "Installation du plugin Grafana marcusolsson-dynamictext-panel"
    if grafana cli plugins install marcusolsson-dynamictext-panel >/dev/null 2>&1; then
        chown -R grafana:grafana /var/lib/grafana/plugins 2>/dev/null || true
        systemctl restart grafana-server
        ok "plugin installé"
    else
        warn "Plugin non installé (accès à grafana.com ?). Les boîtes SQL et plan resteront vides : grafana cli plugins install marcusolsson-dynamictext-panel puis redémarrer Grafana."
    fi
fi
# Panneau « Business Forms » (Release 4c) : formulaire de modification des seuils
if [ ! -d /var/lib/grafana/plugins/volkovlabs-form-panel ]; then
    log "Installation du plugin Grafana volkovlabs-form-panel"
    if grafana cli plugins install volkovlabs-form-panel >/dev/null 2>&1; then
        chown -R grafana:grafana /var/lib/grafana/plugins 2>/dev/null || true
        systemctl restart grafana-server
        ok "plugin installé"
    else
        warn "Plugin non installé (accès à grafana.com ?). Les seuils restent modifiables en SQL (docs/21) : grafana cli plugins install volkovlabs-form-panel puis redémarrer Grafana."
    fi
fi
systemctl enable --now grafana-server >/dev/null 2>&1
ok "Grafana installé et démarré (port 3000)"

if [ -z "$GRAFANA_ADMIN_PASSWORD" ]; then
    warn "GRAFANA_ADMIN_PASSWORD vide : datasource et dashboards non configurés."
    warn "À faire à la main (voir docs/01-VM-Monitoring-repository-grafana.md §5 et docs/11 à 13), ou renseigner le mot de passe et relancer."
else
    check_password GRAFANA_ADMIN_PASSWORD
    "$SCRIPT_DIR/grafana-provision.sh"
fi

log "Terminé. Vérification : sudo ./scripts/verify.sh monitoring"
