#!/usr/bin/env python3
"""
ASEMON-PG v2.1 — Rattrapage des plans déjà stockés

Remplit plan_text et plan_hash pour les lignes de asemon.event_plans écrites
avant la v2.1. Rejouable : ne traite que les lignes où plan_text est vide.

  /opt/asemon/venv/bin/python /opt/asemon/app/backfill_plans.py [--dry-run]

Utilise REPO_DSN de config.py (rôle collector_writer, droits donnés par sql/12).
"""

import sys

import psycopg
from config import REPO_DSN
from plan_format import plan_to_text, plan_hash


def main():
    dry = "--dry-run" in sys.argv
    done = skipped = 0
    with psycopg.connect(REPO_DSN, application_name="asemon-backfill-plans") as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id, plan, duration_ms FROM asemon.event_plans "
                        "WHERE plan_text IS NULL ORDER BY id")
            rows = cur.fetchall()
        for pid, plan, dur in rows:
            text = plan_to_text(plan, dur)
            if text is None:
                skipped += 1
                continue
            if not dry:
                with conn.cursor() as cur:
                    cur.execute("UPDATE asemon.event_plans SET plan_text = %s, plan_hash = %s WHERE id = %s",
                                (text, plan_hash(plan), pid))
            done += 1
        if not dry:
            conn.commit()
    print("%s : %d plan(s) mis en forme, %d ignoré(s) (JSON sans nœud « Plan »)"
          % ("Simulation" if dry else "Terminé", done, skipped))


if __name__ == "__main__":
    main()
