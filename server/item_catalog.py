"""NovaGate server-authoritative item identity + catalog (Phase 1).

The Godot client, the market screen and the local `players.json` cache have
historically used *display* names for items ("Kalkan 1", "Hiz 1", "LF1") while
the server catalog uses *canonical* ids ("kalkan1", "hiz1", "lf1"). Mixing the
two produced a starter reward that granted `kalkan1` but a UI that looked up
`Kalkan 1` and showed 0, market buys that rejected valid client ids, and two
rows for one physical item once a case/space difference crept in.

This module is the single place that decides "what is the id of this item".
Registration reward, market, inventory and journal all funnel through
`normalize_item_id`, so a mapping fix is a one-line change.

Protected values: CATALOG_ROWS reproduces the project's original
`item_catalog` seed price-for-price. Phase 1 only ADDS rows for ids the
catalog never carried; it never moves a price.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Iterable

# ---------------------------------------------------------------------------
# Canonical ids (item_catalog.item_id) -> display name shipped to clients.
# ---------------------------------------------------------------------------
CANONICAL_ITEMS: dict[str, str] = {
    # Lasers
    "lf1": "LF1", "lf2": "LF2", "lf3": "LF3",
    # Shields / Generators
    "kalkan1": "Kalkan 1", "kalkan2": "Kalkan 2",
    "hiz1": "Hiz 1", "hiz2": "Hiz 2",
    # Extras / Boosters
    "ema": "EMA", "enc": "ENC", "nukleer": "Nukleer", "uc_saniye": "3 Saniye",
    "pbmb": "PBMB", "wsh": "WSH", "emp": "EMP", "invis": "INVIS",
    "frep": "FREP", "acpr": "ACPR",
    # Log disks
    "log_disk_1": "1 Log Disk", "log_disk_50": "50 Log Disk",
    "log_disk_100": "100 Log Disk", "log_disk_1000": "1000 Log Disk",
    # Ammo packages
    "ammo_x1_1000": "1000 X1", "ammo_x1_10000": "10000 X1",
    "ammo_x1_100000": "100000 X1",
    "ammo_x2_500": "500 X2", "ammo_x2_1000": "1000 X2",
    "ammo_x2_10000": "10000 X2", "ammo_x2_100000": "100000 X2",
    "ammo_x3_100": "100 X3", "ammo_x3_1000": "1000 X3",
    "ammo_x3_10000": "10000 X3", "ammo_x3_100000": "100000 X3",
    "ammo_x4_1000": "1000 X4", "ammo_x4_10000": "10000 X4",
    "ammo_x4_100000": "100000 X4",
    "ammo_sab_1000": "1000 SAB", "ammo_sab_10000": "10000 SAB",
    "ammo_sab_100000": "100000 SAB",
    "ammo_rsb_100": "100 RSB", "ammo_rsb_1000": "1000 RSB",
    "ammo_rsb_10000": "10000 RSB", "ammo_rsb_100000": "100000 RSB",
    "ammo_r1_50": "50 R1", "ammo_r1_500": "500 R1", "ammo_r1_5000": "5000 R1",
    "ammo_r2_50": "50 R2", "ammo_r2_500": "500 R2", "ammo_r2_5000": "5000 R2",
    "ammo_r3_50": "50 R3", "ammo_r3_500": "500 R3", "ammo_r3_5000": "5000 R3",
    # Droids
    "droid_plus_1": "PLUS Droid", "droid_zeus_1": "ZEUS Droid",
}

# ---------------------------------------------------------------------------
# Alias table: every spelling the client is known to send -> canonical id.
# Keys here are raw; they get folded by _fold() before lookup.
# ---------------------------------------------------------------------------
_ALIAS_SEED: dict[str, str] = {
    # Display names straight out of players.json / market UI.
    "kalkan 1": "kalkan1", "kalkan 2": "kalkan2",
    "kalkan i": "kalkan1", "kalkan ii": "kalkan2",
    "kalkan_1": "kalkan1", "kalkan_2": "kalkan2",
    "hiz 1": "hiz1", "hiz 2": "hiz2",
    "hiz i": "hiz1", "hiz ii": "hiz2",
    "hiz_1": "hiz1", "hiz_2": "hiz2",
    "lf 1": "lf1", "lf 2": "lf2", "lf 3": "lf3",
    # Ammo shorthands used by GlobalState.ammo_inventory.
    "x1": "ammo_x1_1000", "x2": "ammo_x2_1000",
    "x3": "ammo_x3_1000", "x4": "ammo_x4_1000",
    "sab": "ammo_sab_1000", "rsb": "ammo_rsb_1000",
    "r1": "ammo_r1_500", "r2": "ammo_r2_500", "r3": "ammo_r3_500",
    # Droids.
    "plus": "droid_plus_1", "zeus": "droid_zeus_1",
    "plus droid": "droid_plus_1", "zeus droid": "droid_zeus_1",
}

_WS_RE = re.compile(r"\s+")


def _fold(value: object) -> str:
    """Lowercase + strip accents + collapse whitespace, for alias lookup.

    Turkish dotted/dotless i and the accented glyphs in the display names must
    all fold onto the same key, otherwise "Hiz 1" and "Hız 1" would be two
    different items.
    """
    text = "" if value is None else str(value)
    text = text.strip().lower()
    if not text:
        return ""
    decomposed = unicodedata.normalize("NFKD", text)
    # Drop the combining marks NFKD leaves behind, then re-map the dotless-i.
    folded = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    folded = folded.replace("ı", "i")
    return _WS_RE.sub(" ", folded).strip()


# Pre-computed alias table: folded key -> canonical id.
_ALIASES: dict[str, str] = {_fold(k): v for k, v in _ALIAS_SEED.items()}
_ALIASES.update({cid: cid for cid in CANONICAL_ITEMS})


def normalize_item_id(item_id: object) -> str:
    """Map any accepted spelling of an item onto its canonical id.

    Unknown items return their folded form (never ""), so a bad id fails loudly
    at the catalog lookup instead of silently becoming an empty key.
    """
    folded = _fold(item_id)
    if not folded:
        return ""
    known = _ALIASES.get(folded)
    if known:
        return known
    # Display names are already folded above only if they were in the alias
    # seed; the rest are resolved here.
    for canonical, display in CANONICAL_ITEMS.items():
        if _fold(display) == folded:
            return canonical
    # Compact form, so "kalkan-1" / "kalkan_1" / "kalkan1" all agree.
    compact = folded.replace(" ", "").replace("-", "").replace("_", "")
    if compact:
        known = _ALIASES.get(compact)
        if known:
            return known
    return folded


def display_name(item_id: object) -> str:
    """Human-readable name for a canonical id (falls back to the id itself)."""
    canonical = normalize_item_id(item_id)
    return CANONICAL_ITEMS.get(canonical, canonical)


def is_known_item(item_id: object) -> bool:
    return normalize_item_id(item_id) in CANONICAL_ITEMS

def normalize_inventory(raw: object) -> dict[str, int]:
    """Normalize a client-supplied inventory dict onto canonical ids.

    Keys are folded through `normalize_item_id` and colliding spellings are
    summed, so a player who somehow ends up with both "Kalkan 1" and "kalkan1"
    rows is counted once per physical item instead of twice.
    """
    if not isinstance(raw, dict):
        return {}
    result: dict[str, int] = {}
    for key, value in raw.items():
        canonical = normalize_item_id(key)
        if not canonical:
            continue
        try:
            qty = int(value)
        except (TypeError, ValueError):
            continue
        if qty <= 0:
            continue
        result[canonical] = result.get(canonical, 0) + qty
    return result


def canonical_ids(items: Iterable[str]) -> list[str]:
    seen: list[str] = []
    for item in items:
        canonical = normalize_item_id(item)
        if canonical and canonical not in seen:
            seen.append(canonical)
    return seen


# ---------------------------------------------------------------------------
# Catalog seeding
# ---------------------------------------------------------------------------
# (item_id, name, category, price, currency, item_type)
#
# Every price/currency pair for a pre-existing item is copied verbatim from the
# project's original `item_catalog` seed in main.py. Phase 1 must not move a
# single price. Rows carrying price 0 are ids the catalog never had
# (PBMB/WSH/EMP/INVIS/FREP/ACPR exist in the client's _default_inventory but
# were never sellable): they are seeded so the server recognises and can grant
# them, while a 0 price keeps them unpurchasable until one is chosen on purpose.
_CATALOG_LASERS = [
    ("lf1", "LF1", "Lazer", 40000, "BTC", "laser"),
    ("lf2", "LF2", "Lazer", 80000, "BTC", "laser"),
    ("lf3", "LF3", "Lazer", 20000, "PLT", "laser"),
]

_CATALOG_GENERATORS = [
    ("kalkan1", "Kalkan 1", "Kalkan", 125000, "BTC", "generator"),
    ("kalkan2", "Kalkan 2", "Kalkan", 15000, "PLT", "generator"),
    ("hiz1", "Hız 1", "Hiz", 125000, "BTC", "generator"),
    ("hiz2", "Hız 2", "Hiz", 10000, "PLT", "generator"),
]

_CATALOG_EXTRAS = [
    ("ema", "EMA", "Extra", 150000, "PLT", "extra"),
    ("enc", "ENC", "Extra", 95000, "PLT", "extra"),
    ("nukleer", "Nukleer", "Extra", 90000, "PLT", "extra"),
    ("uc_saniye", "3 Saniye", "Extra", 120000, "PLT", "extra"),
    ("pbmb", "PBMB", "Extra", 0, "PLT", "extra"),
    ("wsh", "WSH", "Extra", 0, "PLT", "extra"),
    ("emp", "EMP", "Extra", 0, "PLT", "extra"),
    ("invis", "INVIS", "Extra", 0, "PLT", "extra"),
    ("frep", "FREP", "Extra", 0, "PLT", "extra"),
    ("acpr", "ACPR", "Extra", 0, "PLT", "extra"),
    ("log_disk_1", "1 Log Disk", "Extra", 300, "PLT", "log_disk"),
    ("log_disk_50", "50 Log Disk", "Extra", 15000, "PLT", "log_disk"),
    ("log_disk_100", "100 Log Disk", "Extra", 30000, "PLT", "log_disk"),
    ("log_disk_1000", "1000 Log Disk", "Extra", 300000, "PLT", "log_disk"),
]

_CATALOG_AMMO = [
    ("ammo_x1_1000", "1000 X1", "Cephane", 4500, "BTC", "ammo"),
    ("ammo_x1_10000", "10000 X1", "Cephane", 45000, "BTC", "ammo"),
    ("ammo_x1_100000", "100000 X1", "Cephane", 450000, "BTC", "ammo"),
    ("ammo_x2_500", "500 X2", "Cephane", 22500, "BTC", "ammo"),
    ("ammo_x2_1000", "1000 X2", "Cephane", 450000, "BTC", "ammo"),
    ("ammo_x2_10000", "10000 X2", "Cephane", 4500000, "BTC", "ammo"),
    ("ammo_x2_100000", "100000 X2", "Cephane", 45000000, "BTC", "ammo"),
    ("ammo_x3_100", "100 X3", "Cephane", 90, "PLT", "ammo"),
    ("ammo_x3_1000", "1000 X3", "Cephane", 900, "PLT", "ammo"),
    ("ammo_x3_10000", "10000 X3", "Cephane", 9000, "PLT", "ammo"),
    ("ammo_x3_100000", "100000 X3", "Cephane", 90000, "PLT", "ammo"),
    ("ammo_x4_1000", "1000 X4", "Cephane", 2700, "PLT", "ammo"),
    ("ammo_x4_10000", "10000 X4", "Cephane", 27000, "PLT", "ammo"),
    ("ammo_x4_100000", "100000 X4", "Cephane", 270000, "PLT", "ammo"),
    ("ammo_sab_1000", "1000 SAB", "Cephane", 500, "PLT", "ammo"),
    ("ammo_sab_10000", "10000 SAB", "Cephane", 5000, "PLT", "ammo"),
    ("ammo_sab_100000", "100000 SAB", "Cephane", 50000, "PLT", "ammo"),
    ("ammo_rsb_100", "100 RSB", "Cephane", 450, "PLT", "ammo"),
    ("ammo_rsb_1000", "1000 RSB", "Cephane", 4500, "PLT", "ammo"),
    ("ammo_rsb_10000", "10000 RSB", "Cephane", 45000, "PLT", "ammo"),
    ("ammo_rsb_100000", "100000 RSB", "Cephane", 450000, "PLT", "ammo"),
    ("ammo_r1_50", "50 R1", "Cephane", 2250, "BTC", "ammo"),
    ("ammo_r1_500", "500 R1", "Cephane", 22500, "BTC", "ammo"),
    ("ammo_r1_5000", "5000 R1", "Cephane", 225000, "BTC", "ammo"),
    ("ammo_r2_50", "50 R2", "Cephane", 22500, "BTC", "ammo"),
    ("ammo_r2_500", "500 R2", "Cephane", 225000, "BTC", "ammo"),
    ("ammo_r2_5000", "5000 R2", "Cephane", 2250000, "BTC", "ammo"),
    ("ammo_r3_50", "50 R3", "Cephane", 225, "PLT", "ammo"),
    ("ammo_r3_500", "500 R3", "Cephane", 2250, "PLT", "ammo"),
    ("ammo_r3_5000", "5000 R3", "Cephane", 22500, "PLT", "ammo"),
]

_CATALOG_DROIDS = [
    ("droid_plus_1", "PLUS Droid", "Droid", 100000, "BTC", "droid_plus"),
    ("droid_zeus_1", "ZEUS Droid", "Droid", 12000, "PLT", "droid_zeus"),
]

CATALOG_ROWS: list[tuple[str, str, str, int, str, str]] = [
    *_CATALOG_LASERS,
    *_CATALOG_GENERATORS,
    *_CATALOG_EXTRAS,
    *_CATALOG_AMMO,
    *_CATALOG_DROIDS,
]

CATALOG_BY_ID: dict[str, tuple[str, str, int, str, str]] = {
    row[0]: (row[1], row[2], row[3], row[4], row[5]) for row in CATALOG_ROWS
}


def catalog_seeds() -> list[tuple[str, str, str, int, str, str]]:
    """Rows the server inserts into `item_catalog` (INSERT OR IGNORE)."""
    return list(CATALOG_ROWS)


