"""
ASEMON-PG — Mise en forme lisible du SQL et des plans d'exécution (v2.1)

Utilisé par :
  - log_parser.py   : plan_text / plan_hash à l'écriture de event_plans
  - collector.py    : query_formatted à l'écriture de asemon.query_text
  - backfill_plans.py : rattrapage des plans déjà stockés

Le plan JSON d'auto_explain est converti en texte au format de EXPLAIN
(arbre indenté, coûts, temps réels, filtres, tampons). Le JSON d'origine reste
stocké dans event_plans.plan : rien n'est perdu.
"""

import hashlib

try:
    import sqlparse
except ImportError:          # le texte brut est alors conservé (non indenté)
    sqlparse = None


def format_sql(text):
    """SQL indenté, mots-clés en majuscules. Texte d'origine si la mise en forme échoue."""
    if not text:
        return text
    if sqlparse is None:
        return text
    try:
        return sqlparse.format(text, reindent=True, keyword_case="upper",
                               indent_width=2, strip_comments=False)
    except Exception:
        return text


def _num(v):
    if isinstance(v, float) and not v.is_integer():
        return "%.2f" % v
    return "%d" % v


def _title(n):
    t = n.get("Node Type", "?")
    strategy = n.get("Strategy")
    if t == "Aggregate":
        t = {"Hashed": "HashAggregate", "Sorted": "GroupAggregate"}.get(strategy, "Aggregate")
        if n.get("Partial Mode") in ("Partial", "Finalize"):
            t = n["Partial Mode"] + " " + t
    jt = n.get("Join Type")
    if jt and jt != "Inner" and (t.endswith("Join") or t == "Nested Loop"):
        # "Hash Join" + Left -> "Hash Left Join" ; "Nested Loop" + Left -> "Nested Loop Left Join"
        t = (t[:-4].rstrip() if t.endswith("Join") else t) + " " + jt + " Join"
    if n.get("Scan Direction") == "Backward":
        t += " Backward"
    if n.get("Index Name"):
        t += " using " + n["Index Name"]
    rel = n.get("Relation Name") or n.get("CTE Name") or n.get("Function Name")
    if rel:
        if n.get("Schema") and n.get("Relation Name"):
            rel = n["Schema"] + "." + rel
        t += " on " + rel
        alias = n.get("Alias")
        if alias and alias != n.get("Relation Name"):
            t += " " + alias
    elif n.get("Alias") and t == "Subquery Scan":
        t += " on " + n["Alias"]
    if n.get("Subplan Name"):
        t += "  [" + n["Subplan Name"] + "]"
    return t


def _costs(n):
    s = ""
    if "Startup Cost" in n:
        s += "  (cost=%.2f..%.2f rows=%d width=%d)" % (
            n["Startup Cost"], n["Total Cost"], n.get("Plan Rows", 0), n.get("Plan Width", 0))
    if "Actual Total Time" in n:
        s += " (actual time=%.3f..%.3f rows=%s loops=%d)" % (
            n["Actual Startup Time"], n["Actual Total Time"],
            _num(n.get("Actual Rows", 0)), n.get("Actual Loops", 1))
    return s


_DETAIL_KEYS = ["Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond", "Join Filter",
                "Filter", "Order By", "Sort Key", "Group Key", "One-Time Filter"]
_REMOVED = {"Filter": "Rows Removed by Filter",
            "Join Filter": "Rows Removed by Join Filter",
            "Index Cond": "Rows Removed by Index Recheck"}


def _buffers(n):
    parts = []
    for label, prefix in (("shared", "Shared"), ("local", "Local")):
        bits = []
        for k, name in (("Hit", "hit"), ("Read", "read"), ("Dirtied", "dirtied"), ("Written", "written")):
            v = n.get("%s %s Blocks" % (prefix, k))
            if v:
                bits.append("%s=%d" % (name, v))
        if bits:
            parts.append(label + " " + " ".join(bits))
    tb = []
    if n.get("Temp Read Blocks"):
        tb.append("read=%d" % n["Temp Read Blocks"])
    if n.get("Temp Written Blocks"):
        tb.append("written=%d" % n["Temp Written Blocks"])
    if tb:
        parts.append("temp " + " ".join(tb))
    return "Buffers: " + ", ".join(parts) if parts else None


def _details(n):
    out = []
    for k in _DETAIL_KEYS:
        v = n.get(k)
        if v is None:
            continue
        out.append("%s: %s" % (k, ", ".join(v) if isinstance(v, list) else v))
        r = n.get(_REMOVED.get(k, ""))
        if r:
            out.append("%s: %s" % (_REMOVED[k], r))
    if n.get("Sort Method"):
        space = n.get("Sort Space Used")
        out.append("Sort Method: %s  %s: %skB" % (
            n["Sort Method"], n.get("Sort Space Type", "Memory"), space if space is not None else "?"))
    if n.get("Heap Fetches") is not None:
        out.append("Heap Fetches: %d" % n["Heap Fetches"])
    if n.get("Hash Batches") and n["Hash Batches"] > 1:
        out.append("Batches: %d  Memory Usage: %skB" % (n["Hash Batches"], n.get("Peak Memory Usage", "?")))
    b = _buffers(n)
    if b:
        out.append(b)
    return out


def _render(n, level, lines):
    if level == 0:
        head, det = "", "  "
    else:
        arrow = " " * (2 + 6 * (level - 1))
        head, det = arrow + "->  ", arrow + "      "
    lines.append(head + _title(n) + _costs(n))
    for d in _details(n):
        lines.append(det + d)
    for c in n.get("Plans", []):
        _render(c, level + 1, lines)


def plan_to_text(plan, duration_ms=None):
    """Texte EXPLAIN lisible. `plan` : objet JSON d'auto_explain ({"Query Text":…, "Plan":{…}})."""
    root = plan.get("Plan") if isinstance(plan, dict) else None
    if not root:
        return None
    lines = []
    if duration_ms is not None:
        lines.append("Durée : %.1f ms" % duration_ms)
    _render(root, 0, lines)
    return "\n".join(lines)


def _shape(n):
    key = "%s|%s|%s|%s|%s" % (n.get("Node Type"), n.get("Relation Name"), n.get("Index Name"),
                              n.get("Join Type"), n.get("Strategy"))
    return key + "(" + ",".join(_shape(c) for c in n.get("Plans", [])) + ")"


def plan_hash(plan):
    """Empreinte de la FORME du plan (types de nœuds, tables, index), sans coûts ni temps.
    Deux exécutions avec le même plan donnent la même empreinte ; un changement de plan la modifie."""
    root = plan.get("Plan") if isinstance(plan, dict) else None
    if not root:
        return None
    return hashlib.md5(_shape(root).encode()).hexdigest()[:8]
