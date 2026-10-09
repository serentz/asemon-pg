#!/usr/bin/env bash
# ASEMON-PG : configure Grafana par son API (mot de passe admin, datasource, import des dashboards).
# Appelé par install-monitoring.sh ; peut aussi être relancé seul (rejouable) :
#   sudo ./scripts/grafana-provision.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
require_vars GRAFANA_ADMIN_PASSWORD GRAFANA_RO_PASSWORD
command -v python3 >/dev/null || die "python3 requis"

GF=http://localhost:3000
DS_NAME="ASEMON Monitoring"

# http MÉTHODE CHEMIN [FICHIER_JSON] : résultat dans HTTP_CODE et HTTP_BODY.
# À appeler SANS substitution de commande $(...) : elle perdrait ces variables.
http() {
    local method="$1" path="$2" body="${3:-}" out
    out="$(mktemp)"
    if [ -n "$body" ]; then
        HTTP_CODE="$(curl -s -o "$out" -w '%{http_code}' -u "admin:$GF_PW" -X "$method" \
            -H 'Content-Type: application/json' --data-binary "@$body" "$GF$path")"
    else
        HTTP_CODE="$(curl -s -o "$out" -w '%{http_code}' -u "admin:$GF_PW" -X "$method" "$GF$path")"
    fi
    HTTP_BODY="$(cat "$out")"; rm -f "$out"
}
json_get() { python3 -c "import sys,json; d=json.load(sys.stdin); print(d$1)" 2>/dev/null; }

log "Attente de l'API Grafana"
for _ in $(seq 1 60); do
    curl -fs "$GF/api/health" >/dev/null 2>&1 && break
    sleep 2
done
curl -fs "$GF/api/health" >/dev/null 2>&1 || die "Grafana ne répond pas sur $GF (journalctl -u grafana-server)"

# Mot de passe admin : celui voulu, sinon le défaut admin/admin qu'on remplace.
GF_PW="$GRAFANA_ADMIN_PASSWORD"
http GET /api/org
if [ "$HTTP_CODE" = "401" ]; then
    GF_PW=admin
    http GET /api/org
    [ "$HTTP_CODE" = "200" ] || die "Connexion à Grafana impossible : ni le mot de passe de asemon.env ni admin/admin ne fonctionne."
    pwfile="$(mktemp)"
    printf '{"oldPassword":"admin","newPassword":"%s","confirmNew":"%s"}' "$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_ADMIN_PASSWORD" > "$pwfile"
    http PUT /api/user/password "$pwfile"
    rm -f "$pwfile"
    [ "$HTTP_CODE" = "200" ] || die "Changement du mot de passe admin refusé (HTTP $HTTP_CODE)."
    GF_PW="$GRAFANA_ADMIN_PASSWORD"
    ok "mot de passe admin de Grafana défini"
fi

# Datasource : création, ou mise à jour si elle existe déjà.
dsfile="$(mktemp)"
python3 - "$dsfile" "$DS_NAME" "$GRAFANA_RO_PASSWORD" <<'PY'
import json, sys
path, name, pw = sys.argv[1:4]
json.dump({
    "name": name, "type": "postgres", "access": "proxy",
    "url": "localhost:5432", "user": "grafana_ro", "database": "monitoring", "isDefault": True,
    "jsonData": {"sslmode": "disable", "postgresVersion": 1700, "timescaledb": False},
    "secureJsonData": {"password": pw},
}, open(path, "w"))
PY
http GET "/api/datasources/name/${DS_NAME// /%20}"
if [ "$HTTP_CODE" = "200" ]; then
    DS_UID="$(printf '%s' "$HTTP_BODY" | json_get "['uid']")"
    http PUT "/api/datasources/uid/$DS_UID" "$dsfile"
    [ "$HTTP_CODE" = "200" ] || die "Mise à jour de la datasource refusée (HTTP $HTTP_CODE)."
    ok "datasource « $DS_NAME » mise à jour"
else
    http POST /api/datasources "$dsfile"
    [ "$HTTP_CODE" = "200" ] || die "Création de la datasource refusée (HTTP $HTTP_CODE) : $HTTP_BODY"
    DS_UID="$(printf '%s' "$HTTP_BODY" | json_get "['datasource']['uid']")"
    ok "datasource « $DS_NAME » créée"
fi
rm -f "$dsfile"
[ -n "${DS_UID:-}" ] || die "uid de la datasource introuvable"

# Test de la datasource (connexion réelle à la base monitoring).
http GET "/api/datasources/uid/$DS_UID/health"
[ "$HTTP_CODE" = "200" ] && ok "datasource : connexion à la base OK" || warn "test de connexion de la datasource : HTTP $HTTP_CODE (vérifier GRAFANA_RO_PASSWORD)"

# Dashboards : import avec remplacement (même uid = mise à jour).
for f in "$REPO_DIR"/grafana/asemon-*.json; do
    pf="$(mktemp)"
    python3 - "$f" "$pf" "$DS_UID" <<'PY'
import json, sys
src, dst, uid = sys.argv[1:4]
d = json.load(open(src))
d.pop("id", None)
json.dump({"dashboard": d, "overwrite": True, "folderId": 0,
           "inputs": [{"name": "DS_MONITORING", "type": "datasource", "pluginId": "postgres", "value": uid}]},
          open(dst, "w"))
PY
    http POST /api/dashboards/import "$pf"
    rm -f "$pf"
    if [ "$HTTP_CODE" = "200" ]; then ok "dashboard importé : $(basename "$f")"
    else warn "import de $(basename "$f") refusé (HTTP $HTTP_CODE) : $HTTP_BODY"; fi
done
