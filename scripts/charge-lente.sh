#!/usr/bin/env bash
# ASEMON-PG v2.1 — Charge de test avec des requêtes lentes (VM-Cible)
#
# Produit des requêtes de 100 ms à quelques secondes pour alimenter auto_explain
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
# alimente pgbench_history pour que la jointure ci-dessous ait des lignes
run pgbench -c 4 -T 20 bench >/dev/null

cat > "$TMP/tri.sql" <<'SQL'
SELECT aid, abalance FROM pgbench_accounts ORDER BY abalance DESC, filler LIMIT 10;
SQL
cat > "$TMP/jointure.sql" <<'SQL'
SELECT b.bid, count(*), sum(a.abalance)
FROM pgbench_accounts a JOIN pgbench_branches b ON b.bid = a.bid
JOIN pgbench_history h ON h.aid = a.aid
GROUP BY b.bid;
SQL
cat > "$TMP/filtre.sql" <<'SQL'
SELECT count(*) FROM pgbench_accounts WHERE filler LIKE '%00%' AND abalance <> 1;
SQL
cat > "$TMP/lent.sql" <<'SQL'
SELECT pg_sleep(0.3);
SQL

echo "Charge lente pendant ${DUREE} s (tri, jointure, filtre, pg_sleep) ..."
run pgbench -n -c 2 -T "$DUREE" -f "$TMP/tri.sql"@3 -f "$TMP/jointure.sql"@2 \
    -f "$TMP/filtre.sql"@3 -f "$TMP/lent.sql"@1 bench | tail -8
echo "Terminé. Plans capturés (VM-Monitoring) : SELECT count(*) FROM asemon.event_plans WHERE occurred_at > now() - interval '10 minutes';"
