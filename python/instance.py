"""
monAp_pg Release 4a — Enregistrement de l'instance supervisée.

Chaque agent (collecteur, échantillonneur, parseur de logs) appelle register_instance() au démarrage :
il retrouve l'instance_id de INSTANCE_NAME dans asemon.instances, ou la crée à la première fois.
Toutes les lignes que l'agent écrit portent ensuite cet identifiant.

Paramètres de config.py (voir config.py.example) :
    INSTANCE_NAME  nom affiché de l'instance, unique dans le repository ("VM-Cible" par défaut)
    INSTANCE_HOST  adresse affichée (facultatif ; sinon l'hôte de TARGET_DSN)
"""

import logging
import time

import config as _cfg
from psycopg.conninfo import conninfo_to_dict

log = logging.getLogger("asemon-instance")

INSTANCE_NAME = getattr(_cfg, "INSTANCE_NAME", "VM-Cible")


def _target_info(target_conn):
    """Hôte, port et version de l'instance surveillée (informatif)."""
    host = getattr(_cfg, "INSTANCE_HOST", None)
    port = None
    try:
        info = conninfo_to_dict(_cfg.TARGET_DSN)
        host = host or info.get("host") or "localhost"
        port = int(info["port"]) if info.get("port") else 5432
    except Exception:
        host = host or "localhost"
    version = None
    if target_conn is not None:
        try:
            with target_conn.cursor() as cur:
                cur.execute("SHOW server_version")
                version = cur.fetchone()[0]
        except Exception:
            version = None
    return host, port, version


def register_instance(repo_conn, target_conn=None, name=None):
    """Renvoie l'instance_id de `name` (INSTANCE_NAME par défaut), après l'avoir créée si besoin.

    Lève une exception si le repository n'a pas le schéma de la Release 4a (sql/14-multi-instance.sql).
    """
    name = name or INSTANCE_NAME
    host, port, version = _target_info(target_conn)
    try:
        with repo_conn.cursor() as cur:
            cur.execute("SELECT instance_id FROM asemon.instances WHERE name = %s", (name,))
            row = cur.fetchone()
            if row is None:
                cur.execute("""
                    INSERT INTO asemon.instances (name, host, port, pg_version)
                    VALUES (%s, %s, %s, %s)
                    ON CONFLICT (name) DO NOTHING
                """, (name, host, port, version))
                cur.execute("SELECT instance_id FROM asemon.instances WHERE name = %s", (name,))
                row = cur.fetchone()
            else:
                cur.execute("UPDATE asemon.instances SET host = COALESCE(%s, host), port = COALESCE(%s, port), "
                            "pg_version = COALESCE(%s, pg_version) WHERE instance_id = %s",
                            (host, port, version, row[0]))
        repo_conn.commit()
    except Exception:
        repo_conn.rollback()
        raise
    log.info("Instance supervisée : %s (instance_id=%s)", name, row[0])
    return row[0]


def register_with_retry(connect_repo, target_conn=None, wait_s=10):
    """Variante des services de longue durée : réessaie tant que le repository est inaccessible."""
    while True:
        try:
            conn = connect_repo()
            try:
                return register_instance(conn, target_conn)
            finally:
                conn.close()
        except Exception:
            log.exception("Enregistrement de l'instance impossible (sql/14 appliqué ? repository joignable ?), "
                          "nouvel essai dans %ss", wait_s)
            time.sleep(wait_s)
