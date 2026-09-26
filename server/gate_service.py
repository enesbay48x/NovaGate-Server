"""Galaxy Gate progression service (Phase 5 completion).

A gate is a server-authoritative set of parts a player contributes. The rules
that matter for a persistent, abuse-resistant gate all live here rather than
being spread across a route handler:

* PARTS ARE INVENTORY ITEMS. Contributing one decrements `inventory` inside the
  same transaction that advances the gate, so a part can never be duplicated by
  a double submit or conjured from nothing.
* PROGRESS IS IN THE DATABASE, NOT THE SESSION. A player who disconnects
  mid-gate, or whose ship dies mid-gate, comes back to exactly the progress
  they had. `reconnect_state()` is what the login path reads.
* COMPLETION PAYS ONCE. The `state` transition is a conditional UPDATE, so a
  repeated completion request pays nothing the second time.
* DEATH IS A FAILURE, NOT A PAYOUT. Dying forfeits the ACTIVE attempt's
  progress; a completed gate is never rolled back by a death because it has
  already paid out and is not re-enterable.
"""

from __future__ import annotations

import json
import time
from typing import Optional

import aiosqlite

import game_data
import journal

GATE_STATE_LOCKED = "locked"
GATE_STATE_ACTIVE = "active"
GATE_STATE_COMPLETED = "completed"
GATE_STATE_FAILED = "failed"

# How long a completed gate's effect lasts, in seconds. Mirrors
# game_data.GATE_REWARD_DURATION_SECONDS; the row stores an absolute expiry so
# a restart neither extends nor shortens an in-flight effect.
GATE_REWARD_DURATION_SECONDS = game_data.GATE_REWARD_DURATION_SECONDS

# The completion bonus. A flat amount per gate, defined here on the server -
# the client neither sends nor influences it.
GATE_COMPLETION_REWARD = {"btc": 500, "plt": 250}


def _now() -> int:
    return int(time.time())


def gate_definitions() -> list:
    return [{"gate_id": gid,
             "parts": {pid: {"required": req, "min_level": lvl}
                       for pid, (req, lvl) in parts.items()}}
            for gid, parts in game_data.GATE_PART_DEFINITIONS.items()]


def gate_definition(gate_id: str) -> Optional[dict]:
    return game_data.GATE_PART_DEFINITIONS.get(gate_id)


async def read_gate(db, player_id: str, gate_id: str) -> dict:
    """The stored progress row for one gate, with a default when absent."""
    cursor = await db.execute(
        "SELECT parts, state, completed_at, updated_at FROM player_gates "
        "WHERE player_id = ? AND gate_id = ?",
        (player_id, gate_id),
    )
    row = await cursor.fetchone()
    if row is None:
        return {"parts": {}, "state": GATE_STATE_LOCKED, "completed_at": 0,
                "updated_at": 0}
    try:
        parts = json.loads(row[0]) or {}
    except (TypeError, ValueError):
        parts = {}
    return {"parts": parts, "state": str(row[1]),
            "completed_at": int(row[2]), "updated_at": int(row[3])}


def _is_complete(parts: dict, definition: dict) -> bool:
    return all(int(parts.get(pid, 0)) >= int(req)
               for pid, (req, _lvl) in definition.items())


async def reconnect_state(db, player_id: str) -> list:
    """Every gate's live state for a returning player.

    Read on login so a reconnect restores the same progress the player left
    with. The client only renders this; it cannot submit it back.
    """
    out = []
    for gate_id in game_data.GATE_PART_DEFINITIONS:
        state = await read_gate(db, player_id, gate_id)
        completed = state["state"] == GATE_STATE_COMPLETED
        out.append({
            "gate_id": gate_id,
            "state": state["state"],
            "parts": state["parts"],
            "completed": completed,
            "completed_at": state["completed_at"],
            "reward_active": bool(
                completed
                and state["completed_at"] + GATE_REWARD_DURATION_SECONDS > _now()
            ),
        })
    return out


async def contribute_part(
    db, player_id: str, gate_id: str, part_id: str, quantity: int
) -> tuple:
    """Contribute a part. Returns (ok, detail).

    Ownership check, inventory decrement, gate advance, completion and the
    completion reward are ONE transaction, so a crash can never leave a player
    having paid a part for no progress.
    """
    from routes_p45 import _grant_currency
    import player_state

    definition = gate_definition(gate_id)
    if definition is None:
        return False, {"reason": "unknown_gate"}
    if part_id not in definition:
        return False, {"reason": "part_not_in_gate", "part_id": part_id}
    required, min_level = definition[part_id]
    quantity = max(1, min(int(quantity), 50))

    stats = await player_state.get_stats(db, player_id)
    if int(stats["level"]) < int(min_level):
        return False, {"reason": "level_too_low",
                       "required": int(min_level),
                       "level": int(stats["level"])}

    state = await read_gate(db, player_id, gate_id)
    if state["state"] == GATE_STATE_COMPLETED:
        return False, {"reason": "gate_already_completed", "gate_id": gate_id}

    if not await player_state.owns_item(db, player_id, part_id, quantity):
        return False, {"reason": "not_owned", "part_id": part_id}
    await player_state.consume_item(db, player_id, part_id, quantity)

    parts = dict(state["parts"])
    parts[part_id] = int(parts.get(part_id, 0)) + quantity
    complete = _is_complete(parts, definition)
    new_state = GATE_STATE_COMPLETED if complete else GATE_STATE_ACTIVE
    completed_at = _now() if complete else 0

    # The transition is conditional on the gate not already being completed, so
    # two concurrent completions cannot both decide they finished it.
    cursor = await db.execute(
        "INSERT INTO player_gates (player_id, gate_id, parts, state, "
        "completed_at, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(player_id, gate_id) DO UPDATE SET parts = excluded.parts, "
        "state = excluded.state, completed_at = excluded.completed_at, "
        "updated_at = excluded.updated_at "
        "WHERE player_gates.state != 'completed'",
        (player_id, gate_id, json.dumps(parts), new_state, completed_at,
         _now()),
    )
    won = complete and cursor.rowcount > 0

    if won:
        await _grant_currency(db, player_id,
                              btc=int(GATE_COMPLETION_REWARD.get("btc", 0)),
                              plt=int(GATE_COMPLETION_REWARD.get("plt", 0)),
                              reason="gate_completion")
        await journal.record_event(
            db, player_id, journal.EVENT_GATE,
            f"Gate tamamlandi: {gate_id}", journal.SEVERITY_GOOD,
            {"gate_id": gate_id, "reward": GATE_COMPLETION_REWARD},
        )
    else:
        await journal.record_event(
            db, player_id, journal.EVENT_GATE,
            f"Gate parcasi eklendi: {part_id}", journal.SEVERITY_INFO,
            {"gate_id": gate_id, "part_id": part_id, "quantity": quantity},
        )
    await db.commit()
    return True, {"gate_id": gate_id, "parts": parts, "state": new_state,
                  "completed": bool(won)}


async def on_player_death(db, player_id: str) -> list:
    """Death handling: forfeit an unfinished attempt.

    A completed gate is left alone - it already paid out and is not
    re-enterable. Only an in-progress gate resets, and its consumed parts are
    NOT refunded: the parts went into the gate, which is what made the death
    cost something.
    """
    affected = []
    for gate_id in game_data.GATE_PART_DEFINITIONS:
        state = await read_gate(db, player_id, gate_id)
        if state["state"] != GATE_STATE_ACTIVE:
            continue
        await db.execute(
            "UPDATE player_gates SET state = ?, parts = '{}', updated_at = ? "
            "WHERE player_id = ? AND gate_id = ? AND state = 'active'",
            (GATE_STATE_FAILED, _now(), player_id, gate_id),
        )
        affected.append(gate_id)
    if affected:
        await journal.record_event(
            db, player_id, journal.EVENT_GATE,
            "Gate ilerlemesi kayboldu (olum)", journal.SEVERITY_BAD,
            {"gate_ids": affected},
        )
        await db.commit()
    return affected


async def reset_gate(db, player_id: str, gate_id: str) -> dict:
    """Clear a gate back to locked (admin action)."""
    await db.execute(
        "DELETE FROM player_gates WHERE player_id = ? AND gate_id = ?",
        (player_id, gate_id),
    )
    await db.commit()
    return {"gate_id": gate_id, "state": GATE_STATE_LOCKED, "parts": {}}

