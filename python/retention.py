#!/usr/bin/env python3
"""
ASEMON-PG Release 3 — Point d'entrée unique de la rétention (VM-Monitoring)

Lancé chaque jour par asemon-retention.timer (sous l'utilisateur postgres, connexion
locale), à la place de l'ancien asemon-purge.timer. Il enchaîne :

  1. asemon.purge_old_data()   rétention existante : snap_*, snap_kcache, événements, sessions
                               (snapshot_retention_days, event_retention_days, session_retention_days)
  2. suppression des points de capacity planning plus vieux que capacity_max_days (défaut 1095 j)
  3. réduction à UN point par jour (le dernier du jour UTC) des points de snap_db_size et
     snap_table_size plus vieux que capacity_full_days (défaut 7 j)

La maintenance des partitions de snap_samples (maintain_samples()) reste sur son timer horaire.

Utilisation :
  retention.py              applique la rétention
  retention.py --dry-run    affiche ce qui serait supprimé, ne modifie rien
                            (la purge de purge_old_data() n'est pas simulée)
  retention.py --dsn "dbname=monitoring host=/var/run/postgresql"     (connexion alternative)

Paramètres : table asemon.settings (capacity_full_days, capacity_max_days, voir sql/13-capacity.sql).
Code de sortie : 0 si tout est bon, 1 en cas d'erreur.
"""

import argparse
import logging
import sys

import psycopg

log = logging.getLogger("asemon-retention")

# table -> colonnes qui identifient un objet (une série de points)
CAPACITY_TABLES = {
    "snap_db_size": "datname",
    "snap_table_size": "datname, schemaname, relname",
}


def setting(cur, key, default):
    cur.execute("SELECT asemon.setting_int(%s, %s)", (key, default))
    return cur.fetchone()[0]


def purge_old_data(conn, dry_run):
    if dry_run:
        log.info("purge_old_data : non simulée en --dry-run (voir docs/10-retention.md)")
        return
    with conn.cursor() as cur:
        cur.execute("SELECT asemon.purge_old_data()")
        log.info("purge_old_data : %s", cur.fetchone()[0])
    conn.commit()


def drop_too_old(conn, table, max_days, dry_run):
    """Supprime les points plus vieux que capacity_max_days (0 ou moins = illimité)."""
    if max_days <= 0:
        return 0
    with conn.cursor() as cur:
        if dry_run:
            cur.execute(f"SELECT count(*) FROM asemon.{table} "
                        "WHERE collected_at < now() - make_interval(days => %s)", (max_days,))
            n = cur.fetchone()[0]
        else:
            cur.execute(f"DELETE FROM asemon.{table} "
                        "WHERE collected_at < now() - make_interval(days => %s)", (max_days,))
            n = cur.rowcount
    conn.commit()
    return n


def reduce_to_daily(conn, table, keys, full_days, max_days, dry_run):
    """Au-delà de full_days, ne garde que le dernier point de chaque jour UTC et de chaque objet."""
    if full_days <= 0:
        return 0
    ranked = f"""
        SELECT id, row_number() OVER (
                   PARTITION BY {keys}, (collected_at AT TIME ZONE 'UTC')::date
                   ORDER BY collected_at DESC, id DESC) AS rn
        FROM asemon.{table}
        WHERE collected_at < now() - make_interval(days => %s)
          AND (%s <= 0 OR collected_at >= now() - make_interval(days => %s))
    """
    # Les points hors durée maximale sont ignorés ici : ils sont supprimés par drop_too_old()
    # (le compte de --dry-run reste ainsi identique à celui de l'exécution réelle).
    params = (full_days, max_days, max_days)
    with conn.cursor() as cur:
        if dry_run:
            cur.execute(f"WITH ranked AS ({ranked}) SELECT count(*) FROM ranked WHERE rn > 1", params)
            n = cur.fetchone()[0]
        else:
            cur.execute(f"WITH ranked AS ({ranked}) "
                        f"DELETE FROM asemon.{table} t USING ranked r WHERE t.id = r.id AND r.rn > 1",
                        params)
            n = cur.rowcount
    conn.commit()
    return n


def main():
    ap = argparse.ArgumentParser(description="Rétention ASEMON-PG (point d'entrée unique)")
    ap.add_argument("--dry-run", action="store_true", help="affiche sans rien modifier")
    ap.add_argument("--dsn", default="dbname=monitoring", help="connexion au repository (défaut : socket local)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    prefix = "[simulation] " if args.dry_run else ""

    try:
        with psycopg.connect(args.dsn, application_name="asemon-retention") as conn:
            purge_old_data(conn, args.dry_run)
            with conn.cursor() as cur:
                full_days = setting(cur, "capacity_full_days", 7)
                max_days = setting(cur, "capacity_max_days", 1095)
            conn.commit()
            for table, keys in CAPACITY_TABLES.items():
                too_old = drop_too_old(conn, table, max_days, args.dry_run)
                reduced = reduce_to_daily(conn, table, keys, full_days, max_days, args.dry_run)
                log.info("%s%s : %d ligne(s) hors durée (> %d j), %d ligne(s) réduite(s) à 1 point/jour (> %d j)",
                         prefix, table, too_old, max_days, reduced, full_days)
    except Exception:
        log.exception("Rétention en échec")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
