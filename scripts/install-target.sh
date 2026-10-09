#!/usr/bin/env bash
# ============================================================
# ASEMON-PG : installation de VM-Cible (instance surveillée + collecte)
#
#   sudo ./scripts/install-target.sh
#
# À lancer APRÈS install-monitoring.sh (le repository doit exister).
# Prérequis : Ubuntu installé, accès réseau (apt), scripts/asemon.env renseigné.
# La création de la VM et l'installation d'Ubuntu ne sont PAS couvertes.
# Le script est rejouable. Il REDÉMARRE PostgreSQL si sa configuration change
# (coupure de quelques secondes).
# ============================================================
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need_root
load_env
require_vars MONITORING_IP COLLECTOR_PASSWORD ASEMON_COLLECT_PASSWORD SERVICE_USER
check_password COLLECTOR_PASSWORD
check_password ASEMON_COLLECT_PASSWORD
id "$SERVICE_USER" >/dev/null 2>&1 || die "L'utilisateur Linux '$SERVICE_USER' (SERVICE_USER) n'existe pas."
[[ "$SAMPLE_INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "SAMPLE_INTERVAL invalide : $SAMPLE_INTERVAL"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || die "INTERVAL invalide : $INTERVAL"

# --- 1. Paquets -----------------------------------------------------------------------
install_postgres "postgresql-$PG_VERSION-pg-stat-kcache"
apt_install python3 python3-venv python3-pip

# --- 2. Configuration de l'instance ----------------------------------------------------
# Un seul fichier, conf.d/asemon.conf, regroupe tout ce qu'ASEMON-PG exige. Il remplace les
# modifications à la main de postgresql.conf décrites dans docs/02, 07 et 14.
ensure_conf_d
check_auto_conf shared_preload_libraries lc_messages log_timezone log_connections log_disconnections

listen_line="# listen_addresses : valeur par défaut (local uniquement)"
[ -n "$TARGET_ALLOW_SUBNET" ] && listen_line="listen_addresses = '*'"

CHANGED=0
tmp="$(mktemp)"
cat > "$tmp" <<CONF
# Géré par ASEMON-PG (scripts/install-target.sh) : ne pas modifier à la main.
$listen_line

# Extensions : pg_stat_kcache dépend de pg_stat_statements (ordre sans importance, présence obligatoire)
shared_preload_libraries = 'pg_stat_statements,auto_explain,pg_stat_kcache'
track_activities = on
track_counts = on
track_io_timing = on
track_functions = all
pg_stat_statements.track = all
pg_stat_statements.max = 10000

# Journaux JSON lus par asemon-logparser (deadlocks, plans, connexions)
logging_collector = on
log_destination = 'stderr,jsonlog'
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_lock_waits = on
deadlock_timeout = 1s
log_min_duration_statement = 500
log_checkpoints = on
log_autovacuum_min_duration = 0
log_connections = on
log_disconnections = on
# OBLIGATOIRE : le parseur reconnaît les messages par leur texte anglais (docs/07 §1)
lc_messages = 'C'
# OBLIGATOIRE : le parseur lit les horodatages en UTC (suffixe 'UTC')
log_timezone = 'UTC'

# Plans d'exécution lents (auto_explain)
auto_explain.log_min_duration = 500
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_timing = on
auto_explain.log_format = json
auto_explain.log_nested_statements = on
CONF
write_pg_conf "$tmp"; rm -f "$tmp"
if [ -n "$TARGET_ALLOW_SUBNET" ]; then
    set_hba_block target "host    all             asemon_collect  $TARGET_ALLOW_SUBNET   scram-sha-256"
else
    set_hba_block target "# (aucun accès réseau ouvert : TARGET_ALLOW_SUBNET est vide)"
fi
if [ "$CHANGED" -eq 1 ]; then restart_postgres; else ok "configuration de l'instance inchangée"; fi

# --- 3. Rôle de collecte et extensions -----------------------------------------------------
log "Rôle asemon_collect et extensions"
psql_file postgres "$REPO_DIR/sql/03-target-user.sql"
set_role_password asemon_collect ASEMON_COLLECT_PASSWORD
printf 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;\nCREATE EXTENSION IF NOT EXISTS pg_stat_kcache CASCADE;\n' | psql_sql postgres
ok "rôle et extensions en place"

# --- 4. Application dans $INSTALL_DIR -----------------------------------------------------
log "Application dans $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/app"
getent group asemon >/dev/null || groupadd --system asemon
# config.py contient des mots de passe : lisible seulement par le groupe asemon
# (utilisateur du service + postgres, qui fait tourner le parseur de logs).
usermod -aG asemon "$SERVICE_USER"
usermod -aG asemon postgres
for f in collector.py sampler.py log_parser.py; do
    install -m 0644 -o root -g root "$REPO_DIR/python/$f" "$INSTALL_DIR/app/$f"
done
if [ -f "$INSTALL_DIR/app/config.py" ] && [ "${FORCE_CONFIG:-0}" != "1" ]; then
    ok "config.py existant conservé (FORCE_CONFIG=1 pour le régénérer)"
else
    cfg="$(mktemp)"
    sed -e "s|^TARGET_DSN = .*|TARGET_DSN = \"host=localhost dbname=postgres user=asemon_collect password=$ASEMON_COLLECT_PASSWORD\"|" \
        -e "s|^REPO_DSN = .*|REPO_DSN = \"host=$MONITORING_IP dbname=monitoring user=collector_writer password=$COLLECTOR_PASSWORD\"|" \
        -e "s|^INTERVAL = .*|INTERVAL = $INTERVAL|" \
        -e "s|^SAMPLE_INTERVAL = .*|SAMPLE_INTERVAL = $SAMPLE_INTERVAL|" \
        -e "s|^PG_DATA_DIR = .*|PG_DATA_DIR = \"/var/lib/postgresql/$PG_VERSION/main\"|" \
        "$REPO_DIR/python/config.py.example" > "$cfg"
    install -m 0640 -o root -g asemon "$cfg" "$INSTALL_DIR/app/config.py"
    rm -f "$cfg"
    ok "config.py généré"
fi
chmod 0755 "$INSTALL_DIR" "$INSTALL_DIR/app"

if [ ! -x "$INSTALL_DIR/venv/bin/python3" ]; then
    log "Environnement Python"
    python3 -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install -q -r "$REPO_DIR/python/requirements.txt"
ok "dépendances Python installées"

# --- 5. Services ---------------------------------------------------------------------
log "Services systemd"
for u in asemon-collector.service asemon-sampler.service; do
    sed -e "s|^User=.*|User=$SERVICE_USER|" -e "s|/opt/asemon|$INSTALL_DIR|g" "$REPO_DIR/systemd/$u" > "/etc/systemd/system/$u"
done
sed -e "s|/opt/asemon|$INSTALL_DIR|g" "$REPO_DIR/systemd/asemon-logparser.service" > /etc/systemd/system/asemon-logparser.service
systemctl daemon-reload

# Le repository doit répondre, sinon les services bouclent en erreur (ils réessaient toutes les 5 s).
if ! "$INSTALL_DIR/venv/bin/python3" - "$MONITORING_IP" "$COLLECTOR_PASSWORD" <<'PY' 2>/dev/null
import sys, psycopg
psycopg.connect(f"host={sys.argv[1]} dbname=monitoring user=collector_writer password={sys.argv[2]}", connect_timeout=5).close()
PY
then
    warn "Connexion au repository ($MONITORING_IP) impossible : les services démarrent mais n'écriront rien tant que VM-Monitoring ne répond pas."
    warn "Vérifier : install-monitoring.sh exécuté ? SUBNET dans asemon.env ? IP de VM-Monitoring ?"
fi

systemctl enable asemon-collector asemon-sampler asemon-logparser >/dev/null 2>&1
systemctl restart asemon-collector asemon-sampler asemon-logparser
ok "services collector, sampler et logparser (re)démarrés"

log "Terminé. Vérification (après une minute) : sudo ./scripts/verify.sh target"
