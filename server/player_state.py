"""Server-authoritative player state (Phase 2).

XP / honor / level / HP / shield / kills / deaths live HERE. Before Phase 2 the
login payload answered `level: 1, exp: 0` from thin air while the client kept
its own level in `_save.json`, so the client decided its own level and anything
gated on level (maps, items) was client-controlled.

Every function takes an open aiosqlite connection owned by the caller, so a
whole progression change (XP -> level-up -> journal -> quest) can run inside ONE
transaction and commit atomically or not at all.
"""

from __future__ import annotations

import json
import time
from typing import Optional

import aiosqlite

import game_data
from item_catalog import normalize_inventory, normalize_item_id


def _now() -> int:
    return int(time.time())


DEFAULT_STATS = {
    "xp": 0, "honor": 0, "level": 1,
    "hp": 100.0, "max_hp": 100.0,
    "shield": 100.0, "max_shield": 100.0,
    "npc_kills": 0, "player_kills": 0, "deaths": 0, "missions_done": 0,
}

# `hp`/`shield` here are the 100-point session values the world server has
# always broadcast in world_update. Equipment HP is a SEPARATE, larger pool
# tracked per loadout, so a generator never silently changes the number the
# existing world_update clients already read.
SESSION_MAX_HP = 100.0
SESSION_MAX_SHIELD = 100.0


async def ensure_stats(db: aiosqlite.Connection, player_id: str) -> dict:
    """Fetch stats, creating a default row on first sight.

    An account that predates Phase 2 is seeded with exactly what the login
    payload used to hardcode (level 1, 0 XP/honor), so nobody loses progress
    and nobody gains any.
    """
    await db.execute(
        "INSERT OR IGNORE INTO player_stats (player_id, updated_at) VALUES (?, ?)",
        (player_id, _now()),
    )
    cursor = await db.execute(
        "SELECT xp, honor, level, hp, max_hp, shield, max_shield, "
        "npc_kills, player_kills, deaths, missions_done "
        "FROM player_stats WHERE player_id = ?",
        (player_id,),
    )
    row = await cursor.fetchone()
    if row is None:
        return dict(DEFAULT_STATS)
    return {
        "xp": int(row[0]), "honor": int(row[1]), "level": int(row[2]),
        "hp": float(row[3]), "max_hp": float(row[4]),
        "shield": float(row[5]), "max_shield": float(row[6]),
        "npc_kills": int(row[7]), "player_kills": int(row[8]),
        "deaths": int(row[9]), "missions_done": int(row[10]),
    }


async def get_stats(db: aiosqlite.Connection, player_id: str) -> dict:
    return await ensure_stats(db, player_id)


def stats_payload(stats: dict) -> dict:
    """The shape the client receives; keys match existing GlobalState names."""
    level = int(stats.get("level", 1))
    return {
        "xp": int(stats.get("xp", 0)),
        "honor": int(stats.get("honor", 0)),
        "level": level,
        "hp": float(stats.get("hp", 100.0)),
        "max_hp": float(stats.get("max_hp", 100.0)),
        "shield": float(stats.get("shield", 100.0)),
        "max_shield": float(stats.get("max_shield", 100.0)),
        "npc_kills": int(stats.get("npc_kills", 0)),
        "player_kills": int(stats.get("player_kills", 0)),
        "deaths": int(stats.get("deaths", 0)),
        "missions_done": int(stats.get("missions_done", 0)),
        "xp_to_next": game_data.xp_for_level(level + 1) - int(stats.get("xp", 0)),
    }


async def set_level_and_xp(db, player_id: str, xp: int) -> tuple[int, int]:
    """Recompute the level from cumulative XP and persist both.

    The level is ALWAYS derived from XP, never accepted as an input, so a client
    cannot jump levels by posting a number.
    """
    xp = max(int(xp), 0)
    level = game_data.level_for_xp(xp)
    await db.execute(
        "UPDATE player_stats SET xp = ?, level = ?, updated_at = ? "
        "WHERE player_id = ?",
        (xp, level, _now(), player_id),
    )
    return level, xp


async def add_xp(db, player_id: str, amount: int) -> tuple:
    """Add XP, level up if the threshold is crossed.

    Returns (leveled_up, old_level, new_level, new_xp).
    """
    stats = await ensure_stats(db, player_id)
    old_level = int(stats["level"])
    new_level, new_xp = await set_level_and_xp(
        db, player_id, int(stats["xp"]) + max(int(amount), 0)
    )
    return new_level > old_level, old_level, new_level, new_xp


async def add_honor(db, player_id: str, amount: int) -> int:
    """Add honor; may be negative (the faction-change penalty). Floors at 0."""
    stats = await ensure_stats(db, player_id)
    value = max(int(stats["honor"]) + int(amount), 0)
    await db.execute(
        "UPDATE player_stats SET honor = ?, updated_at = ? WHERE player_id = ?",
        (value, _now(), player_id),
    )
    return value


async def add_kill(db, player_id: str, kind: str) -> dict:
    """Increment a kill counter. `kind` is 'npc' or 'player'."""
    stats = await ensure_stats(db, player_id)
    column = "npc_kills" if kind == "npc" else "player_kills"
    value = int(stats[column]) + 1
    await db.execute(
        f"UPDATE player_stats SET {column} = ?, updated_at = ? "
        f"WHERE player_id = ?",
        (value, _now(), player_id),
    )
    stats[column] = value
    return stats


async def add_death(db, player_id: str) -> int:
    stats = await ensure_stats(db, player_id)
    value = int(stats["deaths"]) + 1
    await db.execute(
        "UPDATE player_stats SET deaths = ?, updated_at = ? WHERE player_id = ?",
        (value, _now(), player_id),
    )
    return value

# ---------------------------------------------------------------------------
# HP / shield
# ---------------------------------------------------------------------------
async def set_vitals(
    db, player_id: str, hp: float, shield: float,
    max_hp: Optional[float] = None, max_shield: Optional[float] = None,
) -> dict:
    """Persist HP/shield, clamped to the maxima. Negative input floors at 0."""
    stats = await ensure_stats(db, player_id)
    cap_hp = float(max_hp if max_hp is not None else stats["max_hp"])
    cap_shield = float(max_shield if max_shield is not None else stats["max_shield"])
    hp = max(min(float(hp), cap_hp), 0.0)
    shield = max(min(float(shield), cap_shield), 0.0)
    await db.execute(
        "UPDATE player_stats SET hp = ?, shield = ?, max_hp = ?, max_shield = ?, "
        "updated_at = ? WHERE player_id = ?",
        (hp, shield, cap_hp, cap_shield, _now(), player_id),
    )
    stats.update({"hp": hp, "shield": shield,
                  "max_hp": cap_hp, "max_shield": cap_shield})
    return stats


async def full_restore(db, player_id: str, max_hp: float, max_shield: float) -> dict:
    """Respawn: HP and shield back to their caps."""
    return await set_vitals(db, player_id, max_hp, max_shield, max_hp, max_shield)


# ---------------------------------------------------------------------------
# Inventory helpers
# ---------------------------------------------------------------------------
async def owns_item(db, player_id: str, item_id: str, needed: int = 1) -> bool:
    """Does the player actually own `needed` of `item_id`?"""
    canonical = normalize_item_id(item_id)
    cursor = await db.execute(
        "SELECT quantity FROM inventory WHERE player_id = ? AND item_id = ?",
        (player_id, canonical),
    )
    row = await cursor.fetchone()
    return bool(row) and int(row[0]) >= int(needed)


async def get_inventory(db, player_id: str) -> dict:
    cursor = await db.execute(
        "SELECT item_id, quantity FROM inventory WHERE player_id = ?", (player_id,)
    )
    return normalize_inventory({r[0]: r[1] for r in await cursor.fetchall()})


async def consume_item(db, player_id: str, item_id: str, needed: int = 1) -> bool:
    """Remove `needed` of an item. Returns False (changing nothing) if short."""
    canonical = normalize_item_id(item_id)
    if not await owns_item(db, player_id, canonical, needed):
        return False
    await db.execute(
        "UPDATE inventory SET quantity = quantity - ? "
        "WHERE player_id = ? AND item_id = ?",
        (int(needed), player_id, canonical),
    )
    return True

# ---------------------------------------------------------------------------
# Loadouts (Config 1 / Config 2)
# ---------------------------------------------------------------------------
SLOT_KEYS = ("lasers", "generators", "extras", "drone_slots")


def _empty_loadout() -> dict:
    return {key: [] for key in SLOT_KEYS}


async def get_loadout(db, player_id: str, ship_id: str, config_index: int) -> dict:
    """One configuration, guaranteed to have every slot key."""
    cursor = await db.execute(
        "SELECT lasers, generators, extras, drone_slots, selected "
        "FROM loadouts WHERE player_id = ? AND ship_id = ? AND config_index = ?",
        (player_id, ship_id, int(config_index)),
    )
    row = await cursor.fetchone()
    if row is None:
        empty = _empty_loadout()
        empty.update({"config_index": int(config_index), "ship_id": ship_id,
                      "selected": False})
        return empty
    out = _empty_loadout()
    for i, key in enumerate(SLOT_KEYS):
        try:
            out[key] = json.loads(row[i]) or []
        except (TypeError, ValueError):
            out[key] = []
    out["config_index"] = int(config_index)
    out["ship_id"] = ship_id
    out["selected"] = bool(row[4])
    return out


async def get_all_loadouts(db, player_id: str, ship_id: str) -> dict:
    return {
        "1": await get_loadout(db, player_id, ship_id, 1),
        "2": await get_loadout(db, player_id, ship_id, 2),
    }


async def save_loadout(db, player_id: str, ship_id: str, config_index: int,
                       loadout: dict) -> dict:
    """Upsert one configuration."""
    values = []
    for key in SLOT_KEYS:
        raw = loadout.get(key, [])
        if not isinstance(raw, list):
            raw = []
        values.append(json.dumps([normalize_item_id(i) for i in raw]))
    selected = 1 if loadout.get("selected") else 0
    await db.execute(
        "INSERT INTO loadouts (player_id, ship_id, config_index, lasers, "
        "generators, extras, drone_slots, selected, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(player_id, ship_id, config_index) DO UPDATE SET "
        "lasers = excluded.lasers, generators = excluded.generators, "
        "extras = excluded.extras, drone_slots = excluded.drone_slots, "
        "selected = excluded.selected, updated_at = excluded.updated_at",
        (player_id, ship_id, int(config_index), *values, selected, _now()),
    )
    return await get_loadout(db, player_id, ship_id, config_index)


async def select_config(db, player_id: str, ship_id: str, config_index: int) -> dict:
    """Mark exactly one of the two configurations as active."""
    await db.execute(
        "UPDATE loadouts SET selected = 0 "
        "WHERE player_id = ? AND ship_id = ? AND config_index != ?",
        (player_id, ship_id, int(config_index)),
    )
    await db.execute(
        "INSERT INTO loadouts (player_id, ship_id, config_index, selected, "
        "updated_at) VALUES (?, ?, ?, 1, ?) "
        "ON CONFLICT(player_id, ship_id, config_index) DO UPDATE SET "
        "selected = 1, updated_at = excluded.updated_at",
        (player_id, ship_id, int(config_index), _now()),
    )
    return await get_loadout(db, player_id, ship_id, config_index)


async def get_selected_config(db, player_id: str, ship_id: str) -> dict:
    for index in (1, 2):
        loadout = await get_loadout(db, player_id, ship_id, index)
        if loadout.get("selected"):
            return loadout
    return await get_loadout(db, player_id, ship_id, 1)
# __APPEND__


