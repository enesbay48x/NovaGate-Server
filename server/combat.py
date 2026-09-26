"""Equipment-aware combat resolution and server-side ammo (Phase 2).

What changed in Phase 2
-----------------------
The world server used to compute laser damage from the WEAPON SLOT INDEX alone
(`LASER_MULTIPLIERS[weapon]`), and the client owned ammo in a local
`user://<name>_ammo.json`. Both are now server decisions:

* the damage of a shot is the sum of the LASERS ACTUALLY EQUIPPED in the
  player's selected config, plus the lasers in their drones;
* firing consumes ammo from `player_ammo`, and a shot with no ammo is refused
  server-side.

The protected numbers are untouched. `LASER_MULTIPLIERS`, `PLAYER_LASER_RANGE`,
`MAX_LASER_DAMAGE` and `FIRE_COOLDOWN_SECONDS` still live in
`websocket_server.py` and are still the base layer. What is added on top is the
EQUIPMENT term, which was previously computed client-side and ignored.
"""

from __future__ import annotations

import json
from typing import Optional

import aiosqlite

import game_data
import player_state
from item_catalog import normalize_item_id

# ---------------------------------------------------------------------------
# Ammo
# ---------------------------------------------------------------------------
# Which ammo package each laser consumes. Values are the canonical ids from
# item_catalog, so an ammo package is a real catalog row and can be bought and
# stored like any other item.
LASER_TO_AMMO = {
    "lf1": "ammo_x1_1000",
    "lf2": "ammo_x2_1000",
    "lf3": "ammo_x3_1000",
}

ROCKET_TO_AMMO = {
    "r1": "ammo_r1_50",
    "r2": "ammo_r2_50",
    "r3": "ammo_r3_50",
}

# The starter account receives these through the client-side starter reward
# (scripts/account_manager.gd STARTER_REWARD_AMMO), mirrored server-side so the
# two agree without inventing a new grant.
STARTER_AMMO = {"ammo_x1_1000": 1000, "ammo_r1_50": 100}


async def get_ammo(db, player_id: str) -> dict:
    """The player's whole ammo stock as a canonical id -> quantity map."""
    cursor = await db.execute(
        "SELECT ammo_id, quantity FROM player_ammo WHERE player_id = ?",
        (player_id,),
    )
    return {normalize_item_id(r[0]): int(r[1]) for r in await cursor.fetchall()}


async def set_ammo(db, player_id: str, ammo_id: str, quantity: int) -> int:
    """Absolute set. Used by a purchase or a server-side grant."""
    canonical = normalize_item_id(ammo_id)
    quantity = max(int(quantity), 0)
    await db.execute(
        "INSERT INTO player_ammo (player_id, ammo_id, quantity, updated_at) "
        "VALUES (?, ?, ?, ?) "
        "ON CONFLICT(player_id, ammo_id) DO UPDATE SET "
        "quantity = excluded.quantity, updated_at = excluded.updated_at",
        (player_id, canonical, quantity, _unix()),
    )
    return quantity


async def add_ammo(db, player_id: str, ammo_id: str, amount: int) -> int:
    """Relative grant. Negative is clamped at 0 rather than going negative."""
    canonical = normalize_item_id(ammo_id)
    await db.execute(
        "INSERT INTO player_ammo (player_id, ammo_id, quantity, updated_at) "
        "VALUES (?, ?, ?, ?) "
        "ON CONFLICT(player_id, ammo_id) DO UPDATE SET "
        "quantity = MAX(0, player_ammo.quantity + excluded.quantity), "
        "updated_at = excluded.updated_at",
        (player_id, canonical, max(int(amount), 0), _unix()),
    )
    stock = await get_ammo(db, player_id)
    return stock.get(canonical, 0)


def _unix() -> int:
    import time
    return int(time.time())


async def ensure_starter_ammo(db, player_id: str) -> dict:
    """Seed the starter ammo once, mirroring the client's starter reward.

    Idempotent by construction: it only writes when the player has NO row at
    all, so a returning player keeps whatever they have.
    """
    cursor = await db.execute(
        "SELECT COUNT(*) FROM player_ammo WHERE player_id = ?", (player_id,)
    )
    if (await cursor.fetchone())[0] > 0:
        return await get_ammo(db, player_id)
    for ammo_id, qty in STARTER_AMMO.items():
        await set_ammo(db, player_id, ammo_id, qty)
    return await get_ammo(db, player_id)


async def consume_ammo(db, player_id: str, ammo_id: str, amount: int = 1) -> bool:
    """Take `amount` rounds. Returns False and changes nothing if short."""
    canonical = normalize_item_id(ammo_id)
    stock = await get_ammo(db, player_id)
    if stock.get(canonical, 0) < int(amount):
        return False
    await db.execute(
        "UPDATE player_ammo SET quantity = quantity - ?, updated_at = ? "
        "WHERE player_id = ? AND ammo_id = ?",
        (int(amount), _unix(), player_id, canonical),
    )
    return True


async def has_ammo_for_laser(db, player_id: str, laser_id: str) -> bool:
    ammo_id = LASER_TO_AMMO.get(normalize_item_id(laser_id))
    if ammo_id is None:
        return True  # a laser with no mapped ammo package is unlimited
    stock = await get_ammo(db, player_id)
    return stock.get(ammo_id, 0) > 0

# ---------------------------------------------------------------------------
# Drones (Phase 5 storage, consumed by Phase 2 damage)
# ---------------------------------------------------------------------------
async def get_drones(db, player_id: str) -> list:
    cursor = await db.execute(
        "SELECT drone_index, drone_type, laser_slots, equipped "
        "FROM player_droids WHERE player_id = ? ORDER BY drone_index",
        (player_id,),
    )
    out = []
    for row in await cursor.fetchall():
        try:
            equipped = json.loads(row[3]) or []
        except (TypeError, ValueError):
            equipped = []
        out.append({
            "drone_index": int(row[0]),
            "drone_type": str(row[1]),
            "laser_slots": int(row[2]),
            "equipped": [normalize_item_id(i) for i in equipped],
        })
    return out


async def set_drones(db, player_id: str, drones: list) -> list:
    """Replace the owned drone list. Capped at game_data.MAX_DRONES."""
    await db.execute("DELETE FROM player_droids WHERE player_id = ?", (player_id,))
    kept = 0
    for entry in (drones or [])[: game_data.MAX_DRONES]:
        drone_type = str(entry.get("drone_type", "PLUS")).strip().upper()
        if drone_type not in game_data.DRONE_TYPES:
            drone_type = "PLUS"
        slots = max(1, min(int(entry.get("laser_slots",
                                         game_data.DRONE_SLOTS_PER_DRONE)),
                           game_data.DRONE_SLOTS_PER_DRONE))
        equipped = entry.get("equipped", [])
        if not isinstance(equipped, list):
            equipped = []
        equipped = [normalize_item_id(i) for i in equipped][:slots]
        await db.execute(
            "INSERT INTO player_droids (player_id, drone_index, drone_type, "
            "laser_slots, equipped, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(player_id, drone_index) DO UPDATE SET "
            "drone_type = excluded.drone_type, laser_slots = excluded.laser_slots, "
            "equipped = excluded.equipped, updated_at = excluded.updated_at",
            (player_id, kept, drone_type, slots, json.dumps(equipped), _unix()),
        )
        kept += 1
    return await get_drones(db, player_id)

# ---------------------------------------------------------------------------
# Equipment-aware damage
# ---------------------------------------------------------------------------
async def equipped_lasers(db, player_id: str, ship_id: str) -> list:
    """Lasers in the SELECTED config, plus the lasers inside owned drones."""
    loadout = await player_state.get_selected_config(db, player_id, ship_id)
    lasers = [normalize_item_id(i) for i in loadout.get("lasers", [])]
    for drone in await get_drones(db, player_id):
        lasers.extend(drone.get("equipped", []))
    return lasers


async def equipped_damage(db, player_id: str, ship_id: str) -> dict:
    """Aggregate equipment stats: laser damage, shield, speed bonus.

    This is the number the server applies on top of the protected weapon-slot
    multiplier, instead of trusting a client-supplied damage value.
    """
    loadout = await player_state.get_selected_config(db, player_id, ship_id)
    lasers = [normalize_item_id(i) for i in loadout.get("lasers", [])]
    for drone in await get_drones(db, player_id):
        lasers.extend(drone.get("equipped", []))
    damage = 0
    for laser in lasers:
        damage += int(game_data.item_stats(laser).get("damage", 0))

    shield = 0
    speed = 0
    for generator in loadout.get("generators", []):
        stats = game_data.item_stats(generator)
        shield += int(stats.get("shield", 0))
        speed += int(stats.get("speed", 0))

    return {
        "lasers": lasers,
        "laser_count": len(lasers),
        "laser_damage": damage,
        "shield": shield,
        "speed_bonus": speed,
    }


async def resolve_shot(db, player_id: str, ship_id: str,
                       weapon: int) -> tuple:
    """Validate a laser shot against the SERVER's equipment + ammo state.

    Returns (allowed, reason, info). A player with no equipped laser can still
    fire - the base slot multiplier applies exactly as before, which keeps every
    existing client that never equipped anything working. The gate is ammo, and
    ammo is now server-owned.
    """
    info = await equipped_damage(db, player_id, ship_id)
    stock = await get_ammo(db, player_id)

    needed = None
    if info["lasers"]:
        needed = LASER_TO_AMMO.get(info["lasers"][0])
    if needed is None:
        needed = LASER_TO_AMMO.get(f"lf{max(1, min(int(weapon), 3))}")
    if needed is None:
        return True, "", info
    if stock.get(needed, 0) <= 0:
        return False, "no_ammo", info

    info["ammo_id"] = needed
    return True, "", info


async def fire_laser(db, player_id: str, ship_id: str, weapon: int) -> tuple:
    """Validate AND consume one round. The consumption is server-side only."""
    allowed, reason, info = await resolve_shot(db, player_id, ship_id, weapon)
    if not allowed:
        return False, reason, info
    ammo_id = info.get("ammo_id")
    if ammo_id and not await consume_ammo(db, player_id, ammo_id, 1):
        return False, "no_ammo", info
    return True, "", info


# ---------------------------------------------------------------------------
# Item level gating
# ---------------------------------------------------------------------------
async def can_equip(db, player_id: str, item_id: str) -> tuple:
    """May this player put `item_id` into a config slot?

    Two server checks: they must own the item, and their level must meet the
    item's requirement.
    """
    canonical = normalize_item_id(item_id)
    stats = await player_state.ensure_stats(db, player_id)
    if int(stats["level"]) < game_data.item_level_req(canonical):
        return False, "level_too_low"
    if not await player_state.owns_item(db, player_id, canonical, 1):
        return False, "not_owned"
    return True, ""


