"""Phase 4-5 routes: world loot, bonus boxes, quests, Galaxy Gates, extras.

Server authority rules enforced here:

* Loot is SPAWNED by the server and CLAIMED by the server. The claim is a
  single conditional UPDATE, so two players racing for the same box produce
  exactly one winner and one reward.
* A quest reward is written through `quest_rewards`, whose PRIMARY KEY is
  (player_id, quest_id) - a second claim is rejected by the database, not by a
  hopeful in-code check.
* A Galaxy Gate part is an ordinary inventory item, so contributing one is an
  inventory decrement inside the same transaction that advances the gate.
"""

from __future__ import annotations

import json
import random
import time
import uuid
from typing import Optional

import aiosqlite
from fastapi import Depends, HTTPException
from pydantic import BaseModel, Field

import combat as combat_service
import game_data
import gate_service
import journal
import player_state
from item_catalog import normalize_item_id


def _now() -> int:
    return int(time.time())


# ---------------------------------------------------------------------------
# Loot tables
# ---------------------------------------------------------------------------
# Server-owned. The BTC/PLT magnitudes are deliberately small and are the ONLY
# new economy values Phase 4 introduces: they are separate from the NPC reward
# table in websocket_server, which is untouched.
BONUS_BOX_BTC = (50, 250)
BONUS_BOX_PLT = (25, 150)
BONUS_BOX_XP = (25, 120)
WORLD_LOOT_LIFETIME_SECONDS = 300
BONUS_BOX_LIFETIME_SECONDS = 180

# Items a bonus box can contain. These are catalog ids the server can already
# grant, so a box never invents an item.
BONUS_BOX_ITEMS = ("ammo_sab_1000", "ammo_rsb_100", "log_disk_1")

MAX_LOOT_PER_MAP = 40


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------
class LootClaimRequest(BaseModel):
    loot_id: str


class LootSpawnRequest(BaseModel):
    map_id: str
    loot_id: str = ""
    item_id: str = ""
    quantity: int = 1
    btc: int = 0
    plt: int = 0
    is_bonus_box: bool = False
    position_x: float = 0.0
    position_y: float = 0.0


class QuestProgressRequest(BaseModel):
    quest_id: str
    progress: Optional[int] = None
    amount: int = 0


class GateContributeRequest(BaseModel):
    gate_id: str
    part_id: str
    quantity: int = 1


class ExtraActivateRequest(BaseModel):
    extra_id: str


# ---------------------------------------------------------------------------
# Loot helpers
# ---------------------------------------------------------------------------
def _loot_row_to_dict(row) -> dict:
    return {
        "loot_id": row[0], "map_id": row[1], "item_id": row[2],
        "quantity": int(row[3]), "btc": int(row[4]), "plt": int(row[5]),
        "xp": int(row[6]), "honor": int(row[7]),
        "is_bonus_box": bool(row[8]),
        "position_x": float(row[9]), "position_y": float(row[10]),
        "spawned_at": int(row[11]), "expires_at": int(row[12]),
        "claimed_by": row[13],
    }


async def _roll_bonus_box(rng: random.Random) -> dict:
    """Server RNG for a bonus box. The client never rolls this."""
    return {
        "item_id": rng.choice(BONUS_BOX_ITEMS),
        "quantity": rng.randint(1, 2),
        "btc": rng.randint(*BONUS_BOX_BTC),
        "plt": rng.randint(*BONUS_BOX_PLT),
        "xp": rng.randint(*BONUS_BOX_XP),
        "honor": rng.randint(1, 5),
    }


async def spawn_loot(db, map_id: str, rng: Optional[random.Random] = None,
                    is_bonus_box: bool = False, x: float = 0.0,
                    y: float = 0.0) -> dict:
    """Insert one loot row. Server-owned spawn; the world layer calls this."""
    rng = rng or random
    loot_id = f"loot_{uuid.uuid4().hex[:16]}"
    if is_bonus_box:
        payload = await _roll_bonus_box(rng)
    else:
        payload = {"item_id": "", "quantity": 0, "btc": 0, "plt": 0,
                   "xp": 0, "honor": 0}
    lifetime = (BONUS_BOX_LIFETIME_SECONDS if is_bonus_box
                else WORLD_LOOT_LIFETIME_SECONDS)
    now = _now()
    await db.execute(
        "INSERT INTO world_loot (loot_id, map_id, item_id, quantity, btc, plt, "
        "xp, honor, is_bonus_box, position_x, position_y, spawned_at, "
        "expires_at, claimed_by, claimed_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', 0)",
        (loot_id, map_id, payload["item_id"], payload["quantity"],
         payload["btc"], payload["plt"], payload["xp"], payload["honor"],
         1 if is_bonus_box else 0, float(x), float(y), now, now + lifetime),
    )
    return {
        "loot_id": loot_id, "map_id": map_id,
        "is_bonus_box": is_bonus_box,
        "position_x": float(x), "position_y": float(y),
        "expires_at": now + lifetime,
    }

# ---------------------------------------------------------------------------
# Quest definitions (server-owned)
# ---------------------------------------------------------------------------
# objective types the world layer can emit, mapped to the quest event name.
#
# The three original quests are preserved EXACTLY as Phase 4 shipped them
# (same ids, targets, events, titles and rewards). The gate fields below are
# additive and every existing quest satisfies them, so adding prerequisites
# cannot lock out a quest that was playable before.
QUEST_DEFINITIONS: dict[str, dict] = {
    "LV01_Q01": {"target": 5, "event": "npc_kill", "title": "Sectoru temizle",
                 "reward": {"btc": 100, "plt": 50, "xp": 200, "honor": 5},
                 # Gate fields: absent keys mean "no requirement".
                 "min_level": 1, "requires": [], "chain": None},
    "LV02_Q01": {"target": 3, "event": "map_enter", "map": "1-2",
                 "title": "1-2 haritasina ulas",
                 "reward": {"btc": 200, "plt": 100, "xp": 400, "honor": 10},
                 "min_level": 2, "requires": ["LV01_Q01"],
                 "chain": "LV01_Q01"},
    "LV03_Q01": {"target": 1, "event": "loot_claim",
                 "title": "Bonus box bul",
                 "reward": {"btc": 300, "plt": 150, "xp": 600, "honor": 15},
                 "min_level": 1, "requires": [], "chain": None},
}

QUEST_STATES = ("locked", "active", "completed", "claimed")

# The set of events a quest can listen for. A quest that is NOT in this set is
# ambient (driven by POST /quests/progress) rather than world-event driven.
WORLD_EVENT_QUEST_EVENTS = ("npc_kill", "map_enter", "loot_claim")


def quest_definitions() -> list:
    return [{"quest_id": qid, **info}
            for qid, info in QUEST_DEFINITIONS.items()]


async def quest_availability(db, player_id: str, quest_id: str) -> tuple:
    """(is_unlockable, reason) for one quest, evaluated SERVER-side.

    A client can see that a quest is locked, but it cannot decide that it is
    unlockable: the level comes from `player_stats` and each prerequisite's
    state comes from `quest_progress`, both read here.
    """
    definition = QUEST_DEFINITIONS.get(quest_id)
    if definition is None:
        return False, "unknown_quest"
    stats = await player_state.get_stats(db, player_id)
    if int(stats["level"]) < int(definition.get("min_level", 1)):
        return False, "level_too_low"
    for required in definition.get("requires", []) or []:
        cursor = await db.execute(
            "SELECT state FROM quest_progress WHERE player_id = ? AND quest_id = ?",
            (player_id, required),
        )
        row = await cursor.fetchone()
        if row is None or str(row[0]) not in ("completed", "claimed"):
            return False, f"requires_{required}"
    return True, ""


# ---------------------------------------------------------------------------
# Shared helpers (used by this module and by the WebSocket world layer)
# ---------------------------------------------------------------------------
async def _with_db(db_path: str, fn, *args, **kwargs):
    """Open a connection, run `fn(db, ...)`, and return its result.

    The service functions (gate_service and friends) take the connection as
    their first argument so they can be reused by a background task or a test
    with a caller-owned transaction. This adapter is the only place that
    opens a connection for them.
    """
    async with aiosqlite.connect(db_path) as db:
        return await fn(db, *args, **kwargs)


async def _world_state(db, player_id: str) -> dict:
    from main import ensure_player_world_state
    return await ensure_player_world_state(db, player_id)


async def _grant_item(db, player_id: str, item_id: str, quantity: int) -> None:
    """Add items to the inventory, creating the row when needed."""
    canonical = normalize_item_id(item_id)
    await db.execute(
        "INSERT INTO inventory (player_id, item_id, quantity) VALUES (?, ?, ?) "
        "ON CONFLICT(player_id, item_id) DO UPDATE SET "
        "quantity = inventory.quantity + excluded.quantity",
        (player_id, canonical, int(quantity)),
    )


async def _grant_currency(db, player_id: str, btc: int = 0, plt: int = 0,
                           gold: int = 0, reason: str = "reward",
                           currency: str = "", amount: int = 0) -> None:
    """Add currency, creating the economy row when needed.

    Two call styles, because both read naturally at their call sites:
      * per-column:  _grant_currency(db, pid, btc=100, reason="loot")
      * by name:     _grant_currency(db, pid, currency="PLT", amount=100)

    The by-name form is what the auction scheduler uses: an auction stores
    its currency as a string column rather than as a separate argument, so
    the scheduler needs no per-currency branch at each call site.
    """
    if currency:
        column = {"BTC": "btc", "PLT": "plt", "GOLD": "gold"}.get(
            str(currency).strip().upper())
        if column is None:
            return
        if column == "btc":
            btc += int(amount)
        elif column == "plt":
            plt += int(amount)
        else:
            gold += int(amount)

    await db.execute(
        "INSERT OR IGNORE INTO economy (player_id, btc, plt, gold, updated_at) "
        "VALUES (?, 0, 0, 0, ?)",
        (player_id, _now()),
    )
    await db.execute(
        "UPDATE economy SET btc = btc + ?, plt = plt + ?, gold = gold + ?, "
        "updated_at = ? WHERE player_id = ?",
        (int(btc), int(plt), int(gold), _now(), player_id),
    )
    # Named currency_name so the loop cannot shadow the by-name parameter.
    for currency_name, value in (("BTC", btc), ("PLT", plt), ("GOLD", gold)):
        if value:
            await db.execute(
                "INSERT INTO transactions (player_id, currency, amount, reason, "
                "timestamp) VALUES (?, ?, ?, ?, ?)",
                (player_id, currency_name, int(value), reason, _now()),
            )


async def _advance_quest(db, player_id: str, event: str,
                         amount: int = 1, extra: Optional[dict] = None) -> list:
    """Push a gameplay event into every active quest that listens for it.

    Called from the world layer (NPC kill, map enter, loot claim, ...) so quest
    progress is a consequence of real gameplay, never a client assertion.
    Returns the quest ids that changed.
    """
    extra = extra or {}
    cursor = await db.execute(
        "SELECT player_id, quest_id, progress, target, state "
        "FROM quest_progress WHERE player_id = ? AND state = 'active'",
        (player_id,),
    )
    changed = []
    for pid, quest_id, progress, target, state in await cursor.fetchall():
        definition = QUEST_DEFINITIONS.get(quest_id)
        if not definition or definition.get("event") != event:
            continue
        if definition.get("map") and extra.get("map_id") != definition["map"]:
            continue
        new_progress = int(progress) + int(amount)
        if new_progress >= int(target):
            await db.execute(
                "UPDATE quest_progress SET state = 'completed', progress = ?, "
                "completed_at = ?, updated_at = ? "
                "WHERE player_id = ? AND quest_id = ?",
                (int(target), _now(), _now(), pid, quest_id),
            )
            await journal.record_event(
                db, pid, journal.EVENT_QUEST,
                f"Gorev tamamlandi: {quest_id}", journal.SEVERITY_GOOD,
                {"quest_id": quest_id, "progress": int(target)},
            )
        else:
            await db.execute(
                "UPDATE quest_progress SET progress = ?, updated_at = ? "
                "WHERE player_id = ? AND quest_id = ?",
                (new_progress, _now(), pid, quest_id),
            )
        changed.append(quest_id)
    return changed


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------
def register_routes(app, get_current_account, db_path_provider) -> None:
    """Attach every Phase 4-5 endpoint to `app`."""

    def _db() -> str:
        return db_path_provider()

    # -----------------------------------------------------------------------
    # World loot
    # -----------------------------------------------------------------------
    @app.get("/loot/{map_id}")
    async def get_loot(map_id: str, account: dict = Depends(get_current_account)):
        """Unclaimed, unexpired loot on a map. The client renders it and never
        creates it."""
        if not game_data.is_known_map(map_id):
            raise HTTPException(status_code=404, detail="Unknown map")
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT loot_id, map_id, item_id, is_bonus_box, position_x, "
                "position_y, expires_at FROM world_loot "
                "WHERE map_id = ? AND claimed_by = '' AND expires_at > ? "
                "ORDER BY spawned_at DESC LIMIT ?",
                (map_id, _now(), MAX_LOOT_PER_MAP),
            )
            rows = await cursor.fetchall()
        # A row must not advertise its payout to every client on the map, so
        # the amounts are revealed only to the player who claims it.
        return {"map_id": map_id, "loot": [
            {"loot_id": r[0], "map_id": r[1], "item_id": r[2],
             "is_bonus_box": bool(r[3]), "position_x": float(r[4]),
             "position_y": float(r[5]), "expires_at": int(r[6])}
            for r in rows]}

    @app.post("/loot/spawn")
    async def post_loot_spawn(req: LootSpawnRequest,
                              account: dict = Depends(get_current_account)):
        """Spawn a loot node. Used by the NPC-drop path and the world scheduler."""
        if not game_data.is_known_map(req.map_id):
            raise HTTPException(status_code=404, detail="Unknown map")
        async with aiosqlite.connect(_db()) as db:
            if req.loot_id:
                # Deterministic spawn (an NPC drop): the exact values the world
                # layer already computed are written verbatim.
                now = _now()
                await db.execute(
                    "INSERT OR REPLACE INTO world_loot (loot_id, map_id, "
                    "item_id, quantity, btc, plt, xp, honor, is_bonus_box, "
                    "position_x, position_y, spawned_at, expires_at, "
                    "claimed_by, claimed_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, 0, 0, 1, ?, ?, ?, ?, '', 0)",
                    (req.loot_id, req.map_id, normalize_item_id(req.item_id),
                     int(req.quantity), int(req.btc), int(req.plt),
                     float(req.position_x), float(req.position_y), now,
                     now + BONUS_BOX_LIFETIME_SECONDS),
                )
                node = {"loot_id": req.loot_id, "map_id": req.map_id,
                        "is_bonus_box": True,
                        "position_x": float(req.position_x),
                        "position_y": float(req.position_y)}
            else:
                node = await spawn_loot(
                    db, req.map_id, is_bonus_box=req.is_bonus_box,
                    x=float(req.position_x), y=float(req.position_y),
                )
            await db.commit()
        return {"ok": True, "loot": node}

    @app.post("/loot/claim")
    async def post_loot_claim(req: LootClaimRequest,
                              account: dict = Depends(get_current_account)):
        """Claim a loot node.

        The claim is ONE conditional UPDATE (`WHERE claimed_by = ''`), so a race
        has exactly one winner: the loser sees zero rows affected and is told
        the node is gone. Reward, XP, honor, inventory, quest progress and the
        journal all commit in the same transaction.
        """
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            world = await _world_state(db, player_id)
            cursor = await db.execute(
                "SELECT map_id, item_id, quantity, btc, plt, xp, honor, "
                "is_bonus_box, expires_at, claimed_by FROM world_loot "
                "WHERE loot_id = ?",
                (req.loot_id,),
            )
            row = await cursor.fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Unknown loot node")
            if row[9] != "":
                raise HTTPException(status_code=409, detail="Already claimed")
            if int(row[8]) <= _now():
                raise HTTPException(status_code=410, detail="Loot expired")
            if str(row[0]) != str(world["map_id"]):
                raise HTTPException(
                    status_code=403,
                    detail={"reason": "wrong_map",
                            "you_are_on": world["map_id"]})

            # The atomic claim: only the first writer sees claimed_by = ''.
            # `cursor.rowcount` is the affected-row count; an UPDATE returns no
            # result rows, so fetchone() here would be None, not the count.
            cursor = await db.execute(
                "UPDATE world_loot SET claimed_by = ?, claimed_at = ? "
                "WHERE loot_id = ? AND claimed_by = ''",
                (player_id, _now(), req.loot_id),
            )
            if cursor.rowcount == 0:
                raise HTTPException(status_code=409, detail="Already claimed")

            item_id, quantity = row[1], int(row[2])
            btc, plt = int(row[3]), int(row[4])
            xp, honor = int(row[5]), int(row[6])

            if item_id and quantity > 0:
                await _grant_item(db, player_id, item_id, quantity)
            if btc or plt:
                await _grant_currency(db, player_id, btc=btc, plt=plt,
                                     reason="loot")
            if xp:
                leveled, old_lvl, new_lvl, _ = await player_state.add_xp(
                    db, player_id, xp
                )
                if leveled:
                    await journal.record_event(
                        db, player_id, journal.EVENT_LEVEL_UP,
                        f"Seviye atlandi: {new_lvl}", journal.SEVERITY_GOOD,
                        {"from": old_lvl, "to": new_lvl},
                    )
            if honor:
                await player_state.add_honor(db, player_id, honor)

            await journal.record_event(
                db, player_id, journal.EVENT_LOOT,
                "Bonus box acildi" if bool(row[7]) else "Loot alindi",
                journal.SEVERITY_GOOD,
                {"loot_id": req.loot_id, "item_id": item_id,
                 "quantity": quantity, "btc": btc, "plt": plt,
                 "xp": xp, "honor": honor, "is_bonus_box": bool(row[7])},
            )
            await _advance_quest(db, player_id, "loot_claim")
            await db.commit()
        return {"ok": True, "loot_id": req.loot_id, "item_id": item_id,
                "quantity": quantity, "btc": btc, "plt": plt,
                "xp": xp, "honor": honor}

    # -----------------------------------------------------------------------
    # Quests
    # -----------------------------------------------------------------------
    @app.get("/quests")
    async def get_quests(account: dict = Depends(get_current_account)):
        """Server quest state plus the static definitions.

        `unlocked` is computed here, not by the client: a tampered client can
        change what it draws, but not what this endpoint reports or whether
        POST /quests/accept succeeds.
        """
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT quest_id, state, progress, target, completed_at, "
                "claimed_at FROM quest_progress WHERE player_id = ? "
                "ORDER BY quest_id",
                (player_id,),
            )
            rows = {r[0]: {"quest_id": r[0], "state": r[1],
                           "progress": int(r[2]), "target": int(r[3]),
                           "completed_at": int(r[4]), "claimed_at": int(r[5])}
                    for r in await cursor.fetchall()}
            out = []
            for definition in quest_definitions():
                qid = definition["quest_id"]
                entry = rows.get(qid, {"quest_id": qid, "state": "locked",
                                       "progress": 0,
                                       "target": definition["target"],
                                       "completed_at": 0, "claimed_at": 0})
                entry["title"] = definition["title"]
                entry["min_level"] = int(definition.get("min_level", 1))
                entry["requires"] = list(definition.get("requires", []) or [])
                unlocked, reason = await quest_availability(db, player_id, qid)
                entry["unlocked"] = unlocked
                entry["locked_reason"] = reason
                # A locked quest never shows as "active" to the client.
                if not unlocked and entry["state"] == "active":
                    entry["state"] = "locked"
                out.append(entry)
        return {"quests": out, "definitions": quest_definitions()}

    @app.post("/quests/accept")
    async def post_quest_accept(quest_id: str,
                                account: dict = Depends(get_current_account)):
        """Accept a quest. The target and the gates are all server-side."""
        definition = QUEST_DEFINITIONS.get(quest_id)
        if definition is None:
            raise HTTPException(status_code=404, detail="Unknown quest")
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT state FROM quest_progress WHERE player_id = ? "
                "AND quest_id = ?",
                (player_id, quest_id),
            )
            row = await cursor.fetchone()
            if row and row[0] in ("active", "completed", "claimed"):
                return {"ok": True, "state": row[0], "already": True}
            # Server-side gate: level and prerequisites, both from the database.
            unlocked, reason = await quest_availability(db, player_id, quest_id)
            if not unlocked:
                raise HTTPException(status_code=403,
                                    detail={"reason": reason,
                                            "quest_id": quest_id})
            await db.execute(
                "INSERT INTO quest_progress (player_id, quest_id, state, "
                "progress, target, updated_at) "
                "VALUES (?, ?, 'active', 0, ?, ?) "
                "ON CONFLICT(player_id, quest_id) DO UPDATE SET "
                "state = 'active', updated_at = excluded.updated_at",
                (player_id, quest_id, int(definition["target"]), _now()),
            )
            await db.commit()
        return {"ok": True, "state": "active", "quest_id": quest_id}

    @app.post("/quests/progress")
    async def post_quest_progress(req: QuestProgressRequest,
                                  account: dict = Depends(get_current_account)):
        """Nudge a quest forward.

        Reserved for ambient objectives (survival time, for example) that no
        discrete world event can hook. Combat / map / loot objectives are
        advanced by the world layer through `_advance_quest`, so posting one
        here is refused: a client cannot make a quest complete by asking.
        """
        definition = QUEST_DEFINITIONS.get(req.quest_id)
        if definition is None:
            raise HTTPException(status_code=404, detail="Unknown quest")
        if definition.get("event") in ("npc_kill", "map_enter", "loot_claim"):
            raise HTTPException(status_code=403,
                                detail="Quest is world-event driven")
        amount = int(req.amount) or (int(req.progress) if req.progress else 0)
        async with aiosqlite.connect(_db()) as db:
            changed = await _advance_quest(db, account["player_id"],
                                          definition["event"], amount)
            await db.commit()
        return {"ok": True, "changed": changed}

    @app.post("/quests/claim")
    async def post_quest_claim(quest_id: str,
                               account: dict = Depends(get_current_account)):
        """Claim a completed quest.

        The idempotency ledger `quest_rewards` has PRIMARY KEY (player_id,
        quest_id), so a second claim is rejected by the DATABASE, not by a
        hopeful in-code check. Reward, XP, honor and the journal all commit in
        the same transaction.
        """
        definition = QUEST_DEFINITIONS.get(quest_id)
        if definition is None:
            raise HTTPException(status_code=404, detail="Unknown quest")
        player_id = account["player_id"]
        reward = definition.get("reward", {})

        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT state, target, progress FROM quest_progress "
                "WHERE player_id = ? AND quest_id = ?",
                (player_id, quest_id),
            )
            row = await cursor.fetchone()
            if row is None or row[0] not in ("completed", "claimed"):
                raise HTTPException(status_code=409,
                                    detail="Quest not completed")
            if int(row[2]) < int(row[1]):
                raise HTTPException(status_code=409, detail="Quest incomplete")

            # The ledger insert IS the duplicate guard.
            try:
                await db.execute(
                    "INSERT INTO quest_rewards (player_id, quest_id, btc, plt, "
                    "xp, honor, granted_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (player_id, quest_id, int(reward.get("btc", 0)),
                     int(reward.get("plt", 0)), int(reward.get("xp", 0)),
                     int(reward.get("honor", 0)), _now()),
                )
            except aiosqlite.IntegrityError:
                raise HTTPException(status_code=409,
                                    detail="Reward already claimed")

            if reward.get("btc") or reward.get("plt"):
                await _grant_currency(
                    db, player_id, btc=int(reward.get("btc", 0)),
                    plt=int(reward.get("plt", 0)), reason="quest_reward",
                )
            if reward.get("xp"):
                leveled, old_lvl, new_lvl, _ = await player_state.add_xp(
                    db, player_id, int(reward["xp"])
                )
                if leveled:
                    await journal.record_event(
                        db, player_id, journal.EVENT_LEVEL_UP,
                        f"Seviye atlandi: {new_lvl}", journal.SEVERITY_GOOD,
                        {"from": old_lvl, "to": new_lvl},
                    )
            if reward.get("honor"):
                await player_state.add_honor(db, player_id,
                                             int(reward["honor"]))
            await db.execute(
                "UPDATE quest_progress SET state = 'claimed', claimed_at = ?, "
                "updated_at = ? WHERE player_id = ? AND quest_id = ?",
                (_now(), _now(), player_id, quest_id),
            )
            await journal.record_event(
                db, player_id, journal.EVENT_QUEST,
                f"Gorev odulu alindi: {quest_id}", journal.SEVERITY_GOOD,
                {"quest_id": quest_id, "reward": reward},
            )
            await db.commit()
        return {"ok": True, "quest_id": quest_id, "reward": reward}


    # -----------------------------------------------------------------------
    # Galaxy Gates (Phase 5)
    # -----------------------------------------------------------------------
    @app.get("/gates")
    async def get_gates(account: dict = Depends(get_current_account)):
        """Live gate state, read from the database so a reconnect resumes."""
        async with aiosqlite.connect(_db()) as db:
            live = await gate_service.reconnect_state(db, account["player_id"])
        required = {d["gate_id"]: d["parts"]
                    for d in gate_service.gate_definitions()}
        for entry in live:
            entry["required"] = required.get(entry["gate_id"], {})
        return {"gates": live,
                "reward": gate_service.GATE_COMPLETION_REWARD,
                "reward_duration": gate_service.GATE_REWARD_DURATION_SECONDS}

    @app.post("/gates/contribute")
    async def post_gate_contribute(req: GateContributeRequest,
                                   account: dict = Depends(get_current_account)):
        """Contribute a gate part.

        All of the rules - ownership, level, the inventory decrement, the
        advance, completion and the completion reward - live in gate_service
        and run in ONE transaction, so a part can neither be duplicated by a
        double submit nor conjured out of nothing, and a completed gate pays
        exactly once.
        """
        ok, detail = await _with_db(
            _db(), gate_service.contribute_part,
            account["player_id"], req.gate_id, req.part_id, req.quantity,
        )
        if not ok:
            reason = detail.get("reason", "gate_error")
            if reason in ("unknown_gate", "part_not_in_gate"):
                code = 404 if reason == "unknown_gate" else 400
            elif reason in ("gate_already_completed",):
                code = 409
            elif reason == "level_too_low":
                code = 403
            else:
                code = 400
            raise HTTPException(status_code=code, detail=detail)
        return {"ok": True, **detail}

    # -----------------------------------------------------------------------
    # Extras (Phase 5)
    # -----------------------------------------------------------------------
    @app.get("/extras")
    async def get_extras(account: dict = Depends(get_current_account)):
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            inventory = await player_state.get_inventory(db, player_id)
            cursor = await db.execute(
                "SELECT extra_id, state, activated_at, expires_at "
                "FROM player_extras WHERE player_id = ?",
                (player_id,),
            )
            rows = {r[0]: {"extra_id": r[0], "state": r[1],
                           "activated_at": int(r[2]), "expires_at": int(r[3])}
                    for r in await cursor.fetchall()}
        return {"extras": rows,
                "owned": {k: v for k, v in inventory.items()
                          if game_data.item_stats(k).get("type") == "extra"}}

    @app.post("/extras/activate")
    async def post_activate(req: ExtraActivateRequest,
                            account: dict = Depends(get_current_account)):
        """Activate an owned extra for its server-side duration.

        Ownership is checked against the inventory and the expiry is written
        by the server, so a client cannot activate something it does not own
        or set its own timer.
        """
        player_id = account["player_id"]
        extra_id = normalize_item_id(req.extra_id)
        async with aiosqlite.connect(_db()) as db:
            if not await player_state.owns_item(db, player_id, extra_id, 1):
                raise HTTPException(status_code=400,
                                    detail={"reason": "not_owned",
                                            "extra_id": extra_id})
            duration = game_data.EXTRA_DURATION_SECONDS
            now = _now()
            await db.execute(
                "INSERT INTO player_extras (player_id, extra_id, state, "
                "activated_at, expires_at, updated_at) "
                "VALUES (?, ?, 'active', ?, ?, ?) "
                "ON CONFLICT(player_id, extra_id) DO UPDATE SET "
                "state = 'active', activated_at = excluded.activated_at, "
                "expires_at = excluded.expires_at, "
                "updated_at = excluded.updated_at",
                (player_id, extra_id, now, now + duration, now),
            )
            await journal.record_event(
                db, player_id, journal.EVENT_SYSTEM,
                f"Extra aktif: {extra_id}", journal.SEVERITY_INFO,
                {"extra_id": extra_id, "expires_at": now + duration},
            )
            await db.commit()
        return {"ok": True, "extra_id": extra_id,
                "expires_at": now + duration}





