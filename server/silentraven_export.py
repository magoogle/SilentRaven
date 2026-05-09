"""
silentraven_export.py — Side-output for the SilentRaven plugin.

Mirrors the alfred unique-item.json pattern.  Reads BountyMetaCache +
Whisper Cache rows from the master catalog, classifies each into a
SilentRaven slot id + legendary flag, and writes
/data/silentraven/caches.lua atomically (.tmp + os.replace).

Schema written:
    return {
        [<sno>] = { slot=<id>, legendary=<bool>, name='<display>' },
        ...
    }

Slot ids match SilentRaven core/rewards.lua KNOWN_SLOTS.  When that
list grows, update _classify_slot below in lockstep.

Legendary detection has two paths:
  * BountyMetaCache type: magic_type stays 0 even at Greater tier, so
    the only reliable signal is the name prefix ("Greater ", "Ancestral ").
  * Whisper Cache type: magic_type DOES carry rarity (>=3 == legendary),
    so we trust that for Material Collection of * etc.
The two paths are unioned -- any positive signal flips the bool.
"""

import os
import logging
from datetime import datetime, timezone

logger = logging.getLogger("looter.silentraven_export")

DATA_DIR = os.environ.get("LOOTER_ROOT", "/data")


def _classify_slot(name: str) -> str:
    """Map a cache display name to a SilentRaven slot id.  Returns
    'other' for anything we don't recognize -- unknown caches still
    end up in the file so SilentRaven can let the user weight them."""
    n = (name or "").lower()
    # Order matters: 'leg guard' must beat 'leg' alone, etc.
    if "helm" in n:                                          return "helms"
    if "chestplate" in n or "torso" in n or "chest" in n:    return "chest"
    if "leg guard" in n or "pants" in n or " legs" in n or n.endswith("legs"):
        return "legs"
    if "gauntlet" in n or "glove" in n:                      return "gloves"
    if "boot" in n or "feet" in n:                           return "boots"
    if "amulet" in n or "neck" in n or "talisman" in n:      return "amulets"
    if "ring" in n:                                          return "rings"
    if "one-handed" in n or "1-handed" in n or "1h " in n or "1hweapon" in n:
        return "weapons_1h"
    if "two-handed" in n or "2-handed" in n or "2h " in n or "2hweapon" in n:
        return "weapons_2h"
    if "gold" in n:                                          return "gold"
    if "chaos" in n:                                         return "chaos"
    return "other"


def _classify_legendary(name: str, magic_type: int) -> bool:
    """Decide whether a cache is legendary-tier.  See module docstring."""
    n = (name or "").lower()
    # Name-prefix path -- works for BountyMetaCache armor/jewelry
    # whose magic_type stays 0 even at Greater tier.
    if n.startswith("greater "):                return True
    if n.startswith("ancestral "):              return True
    if "greater collection" in n:               return True
    if "ancestral collection" in n:             return True
    if "material collection" in n:              return True
    if "upgraded" in n:                         return True
    # DB rarity path -- catches Whisper Cache Material*/Gem Fragments
    # etc. which DO carry magic_type=3.
    try:
        if int(magic_type or 0) >= 3:           return True
    except (TypeError, ValueError):
        pass
    return False


def _lua_str(s: str) -> str:
    """Quote a string for embedding in Lua single-quoted form."""
    if s is None:
        return "''"
    out = (
        s.replace("\\", "\\\\")
         .replace("'",  "\\'")
         .replace("\n", "\\n")
         .replace("\r", "\\r")
    )
    return f"'{out}'"


def generate_silentraven_caches(log_fn=None) -> int:
    """Dump every BountyMetaCache + Whisper Cache row to
    /data/silentraven/caches.lua.  Excludes placeholder items
    ((PH)/[PH]) and excluded rows.  Returns the number of entries
    written.  Opens its own DB connection so it stays safe to call
    after pipeline's main `with get_conn()` block has closed."""
    # Imported here to avoid circular imports at module load time.
    from db import get_conn

    log = log_fn or logger.info
    with get_conn() as conn:
        rows = conn.execute(
            """SELECT sno_id, name, item_type, magic_type
                 FROM catalog
                WHERE group_key = 'cache'
                  AND item_type IN ('BountyMetaCache', 'Whisper Cache')
                  AND name IS NOT NULL
                  AND name != ''
                  AND name NOT LIKE '(PH)%'
                  AND name NOT LIKE '[PH]%'
                  AND COALESCE("excluded", 0) = 0
                ORDER BY sno_id"""
        ).fetchall()

    entries = []
    for r in rows:
        entries.append({
            "sno":       int(r["sno_id"]),
            "name":      r["name"],
            "slot":      _classify_slot(r["name"]),
            "legendary": _classify_legendary(r["name"], r["magic_type"]),
            "item_type": r["item_type"],
            "magic_type": int(r["magic_type"] or 0),
        })

    # Format Lua file
    now = datetime.now(timezone.utc).isoformat()
    lines = [
        "-- Auto-generated by LooteerV3 pipeline (silentraven_export.py)",
        f"-- Generated: {now}",
        f"-- Total entries: {len(entries)}",
        "-- Schema: [sno] = { slot, legendary, name, item_type, magic_type }",
        "--",
        "-- SilentRaven uses this for SNO-keyed lookup at claim time; the",
        "-- slot id picks which priority slider applies, the legendary",
        "-- bool feeds the legendary-bonus scoring.  See SilentRaven's",
        "-- core/rewards.lua for the consumer side.",
        "",
        "return {",
    ]
    for e in entries:
        lines.append(
            "    [{sno}] = {{ slot={slot}, legendary={leg}, name={name}, "
            "item_type={itype}, magic_type={mt} }},".format(
                sno=e["sno"],
                slot=_lua_str(e["slot"]),
                leg="true" if e["legendary"] else "false",
                name=_lua_str(e["name"]),
                itype=_lua_str(e["item_type"]),
                mt=e["magic_type"],
            )
        )
    lines.append("}")
    lines.append("")
    body = "\n".join(lines)

    out_dir  = os.path.join(DATA_DIR, "silentraven")
    out_path = os.path.join(out_dir, "caches.lua")
    os.makedirs(out_dir, exist_ok=True)
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, out_path)

    # Quick stats for the pipeline log -- helpful when validating.
    n_legendary = sum(1 for e in entries if e["legendary"])
    n_other     = sum(1 for e in entries if e["slot"] == "other")
    log(
        f"silentraven caches.lua: {len(entries)} entries "
        f"({n_legendary} legendary, {n_other} unclassified slot) "
        f"-> {out_path}"
    )
    return len(entries)
