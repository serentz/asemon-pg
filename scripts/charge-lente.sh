#!/usr/bin/env bash
# monAp_pg v2.1 — Charge de test avec des requêtes lentes (VM-Cible)
#
# Produit des requêtes d'environ 0,3 à 1 s (tri, jointure, filtre sur 1 million de lignes avec -s 10) pour alimenter auto_explain
# (seuil 100 ms), donc la table event_plans et la page « Détail requête ».
# Utilise la base « bench » et pgbench (voir docs/15-installation-scriptee.md).
#
#   sudo ./scripts/charge-lente.sh [durée en secondes, 120 par défaut] [facteur d'échelle, 10 par défaut]
set -euo pipefail

DUREE="${1:-120}"
SCALE="${2:-10}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
chmod 755 "$TMP"

run() { (cd /tmp && sudo -u postgres "$@"); }

if ! run psql -Atc "SELECT 1 FROM pg_database WHERE datname='bench'" | grep -q 1; then
    run createdb bench
    run pgbench -i -s "$SCALE" bench >/dev/null
fi

cat > "$TMP/tri.sql" <<'SQL'
SELECT aid FROM pgbench_accounts ORDER BY md5(aid::text) LIMIT 10;
SQL
cat > "$TMP/jointure.sql" <<'SQL'
SELECT a.bid, count(*), avg(length(a.filler || b.filler))
FROM pgbench_accounts a JOIN pgbench_accounts b ON b.aid = a.aid + 1
GROUP BY a.bid;
SQL
cat > "$TMP/filtre.sql" <<'SQL'
SELECT count(*) FROM pgbench_accounts WHERE md5(aid::text) LIKE '%ab%';
SQL
cat > "$TMP/lent.sql" <<'SQL'
SELECT pg_sleep(0.3);
SQL

echo "Charge lente pendant ${DUREE} s (tri, jointure, filtre, pg_sleep) ..."
run pgbench -n -c 2 -T "$DUREE" -f "$TMP/tri.sql"@3 -f "$TMP/jointure.sql"@2 \
    -f "$TMP/filtre.sql"@3 -f "$TMP/lent.sql"@1 bench | tail -8
echo "Terminé. Plans capturés (VM-Monitoring) : SELECT count(*) FROM asemon.event_plans WHERE occurred_at > now() - interval '10 minutes';"
