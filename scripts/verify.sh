#!/usr/bin/env bash
# monAp_pg : contrôles après installation.
#   sudo ./scripts/verify.sh monitoring     (sur VM-Monitoring)
#   sudo ./scripts/verify.sh target         (sur VM-Cible)
# Code de sortie : 0 si tout est bon, 1 sinon.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_root
load_env

FAIL=0
check() { # check "libellé" commande...
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else warn "ÉCHEC : $label"; FAIL=1; fi
}
active() { systemctl is-active --quiet "$1"; }
has_rows() { [ "$(psql_value monitoring "SELECT count(*) FROM $1 WHERE ${2:-true}")" -gt 0 ]; }
param() { [ "$(psql_value postgres "SHOW $1")" = "$2" ]; }

case "${1:-}" in
monitoring)
    check "PostgreSQL actif" active "$PG_SERVICE"
    check "Grafana actif" active grafana-server
    check "PostgreSQL écoute sur le réseau" bash -c "[ \"\$($PSQL_CMD -d postgres -At -c 'SHOW listen_addresses')\" = '*' ]"
    check "base monitoring : 18 tables ou plus dans le schéma asemon" bash -c "[ \"\$($PSQL_CMD -d monitoring -At -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='asemon' AND table_type='BASE TABLE'\")\" -ge 18 ]"
    check "fonctions asemon.* présentes" bash -c "[ \"\$($PSQL_CMD -d monitoring -At -c \"SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='asemon' AND proname IN ('rollup_hourly','maintain_samples','purge_old_data','kcache_attr','setting_int')\")\" -eq 5 ]"
    for t in asemon-rollup asemon-samples-maintenance asemon-retention; do
        check "timer $t.timer actif" systemctl is-active --quiet "$t.timer"
    done
    check "retention.py --dry-run s'exécute" runuser -u postgres -- "$INSTALL_DIR/venv/bin/python3" "$INSTALL_DIR/app/retention.py" --dry-run
    check "grafana_ro lit asemon.snap_db_size (R3)" $PSQL_CMD -d monitoring -c "SET ROLE grafana_ro; SELECT 1 FROM asemon.snap_db_size LIMIT 1"
    check "grafana_ro lit asemon.snap_os" $PSQL_CMD -d monitoring -c "SET ROLE grafana_ro; SELECT 1 FROM asemon.snap_os LIMIT 1"
    check "Grafana répond" curl -fs http://localhost:3000/api/health
    log "Données reçues de VM-Cible (vides tant que install-target.sh n'a pas tourné depuis une minute) :"
    check "multi-instance (R4a) : asemon.instances lisible par grafana_ro" $PSQL_CMD -d monitoring -c "SET ROLE grafana_ro; SELECT 1 FROM asemon.instances LIMIT 1"
    check "multi-instance (R4a) : instance_id sur toutes les tables de données (sans valeur par défaut)" bash -c "[ \"\$($PSQL_CMD -d monitoring -At -c \"SELECT count(*) FROM information_schema.columns WHERE table_schema='asemon' AND column_name='instance_id' AND column_default IS NOT NULL AND table_name <> 'instances' AND table_name NOT LIKE 'snap_samples\\_%'\")\" -eq 0 ]"
    check "multi-instance (R4a) : au moins une instance enregistrée par un agent" bash -c "[ \"\$($PSQL_CMD -d monitoring -At -c 'SELECT count(*) FROM asemon.instances')\" -ge 1 ]"
    check "seuils (R4c) : 6 indicateurs et leurs seuils par défaut" bash -c "[ \"\$($PSQL_CMD -d monitoring -At -c 'SELECT count(*) FROM asemon.kpi_thresholds WHERE instance_id IS NULL')\" -ge 6 ]"
    check "seuils (R4c) : compute_kpi_values() s'exécute" $PSQL_CMD -d monitoring -c "SELECT asemon.compute_kpi_values()"
    check "seuils (R4c) : grafana_ro lit v_instance_status" $PSQL_CMD -d monitoring -c "SET ROLE grafana_ro; SELECT 1 FROM asemon.v_instance_status LIMIT 1"
    check "seuils (R4c) : grafana_thresholds n'écrit pas directement dans les seuils" bash -c "! $PSQL_CMD -d monitoring -c \"SET ROLE grafana_thresholds; UPDATE asemon.kpi_thresholds SET warn_value = warn_value\" 2>/dev/null"
    check "table asemon.query_text (v2.1)" bash -c "[ \"\$($PSQL_CMD -d monitoring -At -c \"SELECT count(*) FROM information_schema.columns WHERE table_schema='asemon' AND ((table_name='query_text' AND column_name='query_formatted') OR (table_name='event_plans' AND column_name IN ('plan_text','plan_hash')))\")\" -eq 3 ]"
    for t in snap_os snap_activity snap_statements snap_samples snap_kcache snap_sessions; do
        printf '   %-16s %s lignes\n' "$t" "$(psql_value monitoring "SELECT count(*) FROM asemon.$t")"
    done
    ;;
target)
    check "PostgreSQL actif" active "$PG_SERVICE"
    check "shared_preload_libraries contient pg_stat_kcache" bash -c "$PSQL_CMD -d postgres -At -c 'SHOW shared_preload_libraries' | grep -q pg_stat_kcache"
    check "lc_messages = C" param lc_messages C
    check "log_timezone = UTC" param log_timezone UTC
    check "log_connections = on" param log_connections on
    check "extension pg_stat_kcache" bash -c "[ \"\$($PSQL_CMD -d postgres -At -c \"SELECT count(*) FROM pg_extension WHERE extname IN ('pg_stat_statements','pg_stat_kcache')\")\" -eq 2 ]"
    for s in asemon-collector asemon-sampler asemon-logparser; do check "service $s actif" active "$s"; done
    check "collecteur : un cycle 'Snapshot OK' récent" bash -c "journalctl -u asemon-collector --since '-2 min' --no-pager 2>/dev/null | grep -q 'Snapshot OK'"
    check "collecteur : kcache actif (pas d'avertissement pg_stat_kcache)" bash -c "! journalctl -u asemon-collector --since '-2 min' --no-pager 2>/dev/null | grep -qi 'WARNING.*kcache'"
    ;;
*)
    die "Usage : verify.sh monitoring|target"
    ;;
esac
[ "$FAIL" -eq 0 ] && ok "Tous les contrôles sont bons" || die "Au moins un contrôle a échoué (voir ci-dessus)"
