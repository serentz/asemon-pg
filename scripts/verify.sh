#!/usr/bin/env bash
# ASEMON-PG : contrôles après installation.
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
    for t in asemon-rollup asemon-samples-maintenance asemon-purge; do
        check "timer $t.timer actif" systemctl is-active --quiet "$t.timer"
    done
    check "grafana_ro lit asemon.snap_os" $PSQL_CMD -d monitoring -c "SET ROLE grafana_ro; SELECT 1 FROM asemon.snap_os LIMIT 1"
    check "Grafana répond" curl -fs http://localhost:3000/api/health
    log "Données reçues de VM-Cible (vides tant que install-target.sh n'a pas tourné depuis une minute) :"
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
