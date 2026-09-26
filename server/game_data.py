"""Static game data the server owns (Phases 2-5).

Everything here is SERVER data. The client may render it, but it never decides
it. Two rules are absolute here:

* `XP_BASE` is the project's existing 10337 and the doubling curve is the one
  the client's GlobalState already uses, so a level means the same number on
  both sides. Nothing about the curve is re-tuned.
* Ship/laser/shield/generator NUMBERS are copied from the existing client
  tables (menu_ui.ITEM_DATA, hangar_equipment). Phase 2 makes the server
  *authoritative* about them; it does not rebalance them.

Map ids are the EXISTING NovaGate map names. They are recorded, never renamed.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Progression
# ---------------------------------------------------------------------------
# Mirrors GlobalState.LEVEL_XP_BASE / MAX_LEVEL exactly.
XP_BASE = 10337
MAX_LEVEL = 24
COMPANIES = ("EIC", "MMO", "VRU")


def xp_for_level(level: int) -> int:
    """Total XP required to reach `level` (0 for level 1).

    Same doubling recurrence the client already uses, so both sides agree on
    what "level N" means without any re-balancing.
    """
    if level <= 1:
        return 0
    total = 0
    need = XP_BASE
    for _ in range(2, level + 1):
        total += need
        need *= 2
    return total


def level_for_xp(xp: int) -> int:
    """The highest level whose cumulative XP requirement `xp` satisfies."""
    level = 1
    while level < MAX_LEVEL and xp >= xp_for_level(level + 1):
        level += 1
    return level


# ---------------------------------------------------------------------------
# Faction change (Phase 3)
# ---------------------------------------------------------------------------
# Values come from the gap report's public reference: switching a faction costs
# 10000 PLT, is locked for 21 days, and forfeits half the accrued honor.
FACTION_CHANGE_COST_PLT = 10000
FACTION_CHANGE_COOLDOWN_SECONDS = 21 * 24 * 60 * 60  # 504 hours
FACTION_CHANGE_HONOR_LOSS_PERCENT = 50

# ---------------------------------------------------------------------------
# Item level requirements (Phase 2)
# ---------------------------------------------------------------------------
# A player below `level_req` cannot equip the item. Every starter item is 1 so the
# first-session experience is unchanged; higher tiers are gated.
ITEM_LEVEL_REQUIREMENTS: dict[str, int] = {
    "lf1": 1, "kalkan1": 1, "hiz1": 1,
    "lf2": 5, "kalkan2": 5, "hiz2": 5,
    "lf3": 10, "droid_plus_1": 10,
    "droid_zeus_1": 15,
    "uc_saniye": 3, "nukleer": 3, "enc": 3, "ema": 3,
    "log_disk_50": 2, "log_disk_100": 5, "log_disk_1000": 10,
}


def item_level_req(item_id: str) -> int:
    from item_catalog import normalize_item_id
    return ITEM_LEVEL_REQUIREMENTS.get(normalize_item_id(item_id), 1)


# ---------------------------------------------------------------------------
# Ship + equipment stats (Phase 2)
# ---------------------------------------------------------------------------
# Copied from the existing client tables. `hp`/`speed` are the ship base values
# menu_ui already used for its CONFIGURATION panel; the laser/shield/speed
# numbers are menu_ui.ITEM_DATA's. No value is invented.
SHIP_STATS: dict[str, dict] = {
    "Ship10": {"hp": 8000, "speed": 320, "laser_slots": 30,
               "generator_slots": 16, "extra_slots": 8, "drone_slots": 2},
}
DEFAULT_SHIP = "Ship10"

ITEM_STATS: dict[str, dict] = {
    # lasers
    "lf1": {"type": "laser", "damage": 90, "level_req": 1},
    "lf2": {"type": "laser", "damage": 132, "level_req": 5},
    "lf3": {"type": "laser", "damage": 210, "level_req": 10},
    # generators
    "kalkan1": {"type": "generator", "shield": 5000, "level_req": 1},
    "kalkan2": {"type": "generator", "shield": 10000, "level_req": 5},
    "hiz1": {"type": "generator", "speed": 7, "level_req": 1},
    "hiz2": {"type": "generator", "speed": 10, "level_req": 5},
    # drones
    "droid_plus_1": {"type": "drone", "laser_slots": 2, "level_req": 10},
    "droid_zeus_1": {"type": "drone", "laser_slots": 2, "level_req": 15},
}

DRONE_TYPES = ("PLUS", "ZEUS")
DRONE_SLOTS_PER_DRONE = 2
MAX_DRONES = 8


def ship_stats(ship_id: str) -> dict:
    return SHIP_STATS.get(ship_id, SHIP_STATS[DEFAULT_SHIP])


def item_stats(item_id: str) -> dict:
    from item_catalog import normalize_item_id
    return ITEM_STATS.get(normalize_item_id(item_id), {"type": "extra"})


# ---------------------------------------------------------------------------
# Galaxy Gate definitions (Phase 5)
# ---------------------------------------------------------------------------
# gate_id -> {part_id: (required_quantity, min_level)}
# Parts use canonical item ids, so contributing a part is an ordinary
# inventory decrement and the gate can never invent an item.
GATE_PART_DEFINITIONS: dict[str, dict] = {
    "gate_alpha": {"kalkan1": (1, 1), "hiz1": (1, 1), "lf1": (1, 1)},
    "gate_beta": {"kalkan2": (1, 5), "hiz2": (1, 5), "lf2": (1, 5)},
    "gate_gamma": {"lf3": (2, 10), "droid_plus_1": (1, 10)},
}

# How long a completed gate's effect lasts, in seconds.
GATE_REWARD_DURATION_SECONDS = 300

# How long an activated extra stays active, in seconds.
EXTRA_DURATION_SECONDS = 300


def gate_definitions() -> list:
    return [{"gate_id": gid, "parts": parts}
            for gid, parts in GATE_PART_DEFINITIONS.items()]

# ---------------------------------------------------------------------------
# Map registry (Phase 3)
# ---------------------------------------------------------------------------
# The EXISTING NovaGate map ids, unchanged. `min_level` mirrors the
# `map_requirements` table the client already shipped in GlobalState, so gating
# the server on these values cannot change which maps a given player reaches.
# `company` is the owning faction; an empty string means shared.
MAPS: dict[str, dict] = {
    "1-1": {"display": "1-1", "company": "EIC", "min_level": 1, "order": 11},
    "1-2": {"display": "1-2", "company": "EIC", "min_level": 2, "order": 12},
    "1-3": {"display": "1-3", "company": "EIC", "min_level": 3, "order": 13},
    "1-4": {"display": "1-4", "company": "EIC", "min_level": 11, "order": 14},
    "1-5": {"display": "1-5", "company": "EIC", "min_level": 13, "order": 15},
    "1-6": {"display": "1-6", "company": "EIC", "min_level": 15, "order": 16},
    "2-1": {"display": "2-1", "company": "MMO", "min_level": 1, "order": 21},
    "2-2": {"display": "2-2", "company": "MMO", "min_level": 2, "order": 22},
    "2-3": {"display": "2-3", "company": "MMO", "min_level": 3, "order": 23},
    "2-4": {"display": "2-4", "company": "MMO", "min_level": 11, "order": 24},
    "2-5": {"display": "2-5", "company": "MMO", "min_level": 13, "order": 25},
    "2-6": {"display": "2-6", "company": "MMO", "min_level": 15, "order": 26},
    "3-1": {"display": "3-1", "company": "VRU", "min_level": 1, "order": 31},
    "3-2": {"display": "3-2", "company": "VRU", "min_level": 2, "order": 32},
    "3-3": {"display": "3-3", "company": "VRU", "min_level": 3, "order": 33},
    "3-4": {"display": "3-4", "company": "VRU", "min_level": 11, "order": 34},
    "3-5": {"display": "3-5", "company": "VRU", "min_level": 13, "order": 35},
    "3-6": {"display": "3-6", "company": "VRU", "min_level": 15, "order": 36},
    "PVP": {"display": "PVP", "company": "", "min_level": 10, "order": 90,
            "is_pvp": 1},
    "BOSS": {"display": "BOSS", "company": "", "min_level": 1, "order": 95},
    "4-5": {"display": "4-5", "company": "", "min_level": 20, "order": 45},
}

# Where a company starts. These are the maps the project already used as the
# per-company entry point.
COMPANY_START_MAP = {"EIC": "1-1", "MMO": "2-1", "VRU": "3-1"}

# Default map for a player with no company yet.
DEFAULT_MAP = "1-1"


def map_info(map_id: str) -> dict:
    return MAPS.get(map_id, MAPS[DEFAULT_MAP])


def is_known_map(map_id: str) -> bool:
    return map_id in MAPS


def map_min_level(map_id: str) -> int:
    return int(map_info(map_id).get("min_level", 1))


def map_company(map_id: str) -> str:
    return str(map_info(map_id).get("company", ""))


def can_enter_map(map_id: str, level: int, company: str) -> tuple[bool, str]:
    """Server-side map gate. Returns (allowed, reason)."""
    if not is_known_map(map_id):
        return False, "unknown_map"
    if level < map_min_level(map_id):
        return False, "level_too_low"
    owner = map_company(map_id)
    if owner and company and company != owner:
        return False, "wrong_company"
    return True, ""


# ---------------------------------------------------------------------------
# Portals (Phase 4)
# ---------------------------------------------------------------------------
# A portal is a rectangle on `from_map` that leads to `to_map`. Rectangles are
# centred on the origin of the source map, matching the world rect the world
# server already clamps to.
PORTAL_RADIUS = 400.0


def _portal(portal_id, from_map, to_map, min_level=1, companies=""):
    return {
        "portal_id": portal_id,
        "from_map": from_map,
        "to_map": to_map,
        "x": 0.0, "y": 0.0, "w": PORTAL_RADIUS, "h": PORTAL_RADIUS,
        "min_level": min_level, "companies": companies,
    }


# The hub of each faction links outward; the reverse portals exist so a player
# can always walk back. Every connection is declared server-side, so a client
# cannot invent a destination.
#
# Map ids are numeric prefixes ("1-1"), NOT faction names, so the faction prefix
# is derived from the hub id rather than from the company code.
PORTALS: list[dict] = []


def _prefix_of(map_id: str) -> str:
    return map_id.split("-", 1)[0] if "-" in map_id else map_id


for _hub in COMPANY_START_MAP.values():
    _pfx = _prefix_of(_hub)
    # Hub -> sectors 1..3
    for _n in (1, 2, 3):
        _dest = f"{_pfx}-{_n}"
        if _dest == _hub:
            continue
        PORTALS.append(_portal(f"{_hub}->{_dest}", _hub, _dest))
        PORTALS.append(_portal(f"{_dest}->{_hub}", _dest, _hub))
    # Sector chain 1 -> 4 -> 5 -> 6
    for _a, _b in ((1, 4), (4, 5), (5, 6)):
        _src, _dst = f"{_pfx}-{_a}", f"{_pfx}-{_b}"
        PORTALS.append(_portal(f"{_src}->{_dst}", _src, _dst))
        PORTALS.append(_portal(f"{_dst}->{_src}", _dst, _src))

# Shared areas: reachable from every faction hub.
for _hub in COMPANY_START_MAP.values():
    for _shared in ("PVP", "BOSS", "4-5"):
        PORTALS.append(_portal(f"{_hub}->{_shared}", _hub, _shared,
                               min_level=map_min_level(_shared)))
        PORTALS.append(_portal(f"{_shared}->{_hub}", _shared, _hub))

# A portal is only usable when the DESTINATION itself is also unlocked, so the
# effective requirement is the stricter of the two.
for _p in PORTALS:
    _p["min_level"] = max(_p["min_level"], map_min_level(_p["to_map"]))

PORTALS_BY_SOURCE: dict[str, list[dict]] = {}
for _p in PORTALS:
    PORTALS_BY_SOURCE.setdefault(_p["from_map"], []).append(_p)


def portals_from(map_id: str) -> list:
    return PORTALS_BY_SOURCE.get(map_id, [])


def find_portal(portal_id: str) -> dict | None:
    for p in PORTALS:
        if p["portal_id"] == portal_id:
            return p
    return None


def portal_at(map_id: str, x: float, y: float) -> dict | None:
    """The portal whose rectangle contains (x, y) on `map_id`, if any."""
    for p in PORTALS_BY_SOURCE.get(map_id, []):
        if (p["x"] <= x <= p["x"] + p["w"]) and (p["y"] <= y <= p["y"] + p["h"]):
            return p
    return None

