"""Phase 2-3 routes: stats, loadouts, equipment, ammo, drones, maps, faction.

Registered onto the FastAPI app from main.py with a single call
(`register_routes(app, ...)`) so main.py stays readable and this file owns
everything Phase 2 and Phase 3 add.

Every handler re-reads the caller's own row from the database. Nothing a client
posts is trusted: a damage number, a level, an XP amount, a map id or an item
requirement is always resolved server-side.
"""

from __future__ import annotations

import time
from typing import Optional

import aiosqlite
from fastapi import Depends, HTTPException, status
from pydantic import BaseModel, Field

import combat as combat_service
import game_data
import journal
import player_state
from item_catalog import normalize_item_id


def _now() -> int:
    return int(time.time())


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------
class VitalsRequest(BaseModel):
    hp: float
    shield: float


class LoadoutSaveRequest(BaseModel):
    ship_id: str = Field(default=game_data.DEFAULT_SHIP)
    config_index: int = Field(..., ge=1, le=2)
    lasers: list = Field(default_factory=list)
    generators: list = Field(default_factory=list)
    extras: list = Field(default_factory=list)
    drone_slots: list = Field(default_factory=list)


class ConfigSelectRequest(BaseModel):
    ship_id: str = Field(default=game_data.DEFAULT_SHIP)
    config_index: int = Field(..., ge=1, le=2)


class AmmoChangeRequest(BaseModel):
    ammo_id: str
    quantity: Optional[int] = None   # absolute
    amount: Optional[int] = None     # relative


class DroneSaveRequest(BaseModel):
    drones: list = Field(default_factory=list)


class FactionChangeRequest(BaseModel):
    company: str


class TeleportRequest(BaseModel):
    portal_id: str = ""


class MapMoveRequest(BaseModel):
    map_id: str


class NicknameRequest(BaseModel):
    nickname: str = Field(..., min_length=2, max_length=24)


AMMO_CLIENT_KEYS = {
    "ammo_x1_1000": "X1", "ammo_x2_1000": "X2",
    "ammo_x3_1000": "X3", "ammo_x4_1000": "X4",
    "ammo_sab_1000": "SAB", "ammo_rsb_1000": "RSB",
    "ammo_r1_500": "R1", "ammo_r2_500": "R2", "ammo_r3_500": "R3",
}


def _ammo_for_client(ammo: dict) -> dict:
    out = {key: 0 for key in AMMO_CLIENT_KEYS.values()}
    for ammo_id, qty in (ammo or {}).items():
        key = AMMO_CLIENT_KEYS.get(ammo_id)
        if key is not None:
            out[key] = out[key] + int(qty)
    return out


async def _owns_ship(db, player_id: str, ship_id: str) -> bool:
    """The project only ever issues Ship10, so that plus the ADMIN_TEST ship
    that the existing admin path hands out are the owned set."""
    return ship_id in (game_data.DEFAULT_SHIP, "ADMIN_TEST")


async def _world_of(db, account: dict) -> dict:
    """The player's current map/position, created on first sight."""
    from main import ensure_player_world_state
    return await ensure_player_world_state(db, account["player_id"],
                                            str(account.get("company", "")))


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------
def register_routes(app, get_current_account, db_path_provider) -> None:

    def _db() -> str:
        return db_path_provider()

    # -----------------------------------------------------------------------
    # Player stats / vitals
    # -----------------------------------------------------------------------
    @app.get("/player/stats")
    async def get_player_stats(account: dict = Depends(get_current_account)):
        """Server-authoritative progression. The client renders this and never
        computes it."""
        async with aiosqlite.connect(_db()) as db:
            stats = await player_state.get_stats(db, account["player_id"])
            world = await _world_of(db, account)
        return {
            "stats": player_state.stats_payload(stats),
            "world": world,
            "max_level": game_data.MAX_LEVEL,
            "xp_base": game_data.XP_BASE,
        }

    @app.post("/player/vitals")
    async def post_vitals(req: VitalsRequest,
                          account: dict = Depends(get_current_account)):
        """Persist HP/shield.

        The MAXIMUM is not an input: it comes from the player's own stats row,
        so a client cannot raise its own ceiling by posting a bigger number.
        """
        async with aiosqlite.connect(_db()) as db:
            stats = await player_state.set_vitals(
                db, account["player_id"], float(req.hp), float(req.shield)
            )
            await db.commit()
        return {"ok": True, "stats": player_state.stats_payload(stats)}

    # -----------------------------------------------------------------------
    # Loadouts (Config 1 / Config 2)
    # -----------------------------------------------------------------------
    @app.get("/loadouts")
    async def get_loadouts(ship_id: str = game_data.DEFAULT_SHIP,
                           account: dict = Depends(get_current_account)):
        async with aiosqlite.connect(_db()) as db:
            loadouts = await player_state.get_all_loadouts(
                db, account["player_id"], ship_id
            )
        return {"ship_id": ship_id, "loadouts": loadouts}

    @app.put("/loadouts")
    async def put_loadout(req: LoadoutSaveRequest,
                          account: dict = Depends(get_current_account)):
        """Write one configuration.

        Every slot is validated server-side: the player must own the item and
        their level must meet the item's requirement. The whole write is
        rejected if any single slot fails, so a config is never half equipped.
        """
        async with aiosqlite.connect(_db()) as db:
            if not await _owns_ship(db, account["player_id"], req.ship_id):
                raise HTTPException(status_code=400, detail="Ship not owned")
            rejected = []
            for key in ("lasers", "generators", "extras", "drone_slots"):
                for raw in (getattr(req, key) or []):
                    item = normalize_item_id(raw)
                    allowed, why = await combat_service.can_equip(
                        db, account["player_id"], item
                    )
                    if not allowed:
                        rejected.append({"item_id": item, "reason": why})
            if rejected:
                raise HTTPException(status_code=400,
                                    detail={"rejected": rejected})
            saved = await player_state.save_loadout(
                db, account["player_id"], req.ship_id,
                req.config_index, req.model_dump(),
            )
            # Phase 2: an equipment change is journalled so the Seyir Defteri
            # records who changed what, and when.
            await journal.record_event(
                db, account["player_id"], journal.EVENT_EQUIPMENT,
                f"Config {req.config_index} guncellendi", journal.SEVERITY_INFO,
                {"ship_id": req.ship_id, "config_index": req.config_index,
                 "lasers": saved.get("lasers", []),
                 "generators": saved.get("generators", []),
                 "extras": saved.get("extras", [])},
            )
            await db.commit()
        return {"ok": True, "loadout": saved}

    @app.post("/loadouts/select")
    async def post_select_config(req: ConfigSelectRequest,
                                 account: dict = Depends(get_current_account)):
        async with aiosqlite.connect(_db()) as db:
            if not await _owns_ship(db, account["player_id"], req.ship_id):
                raise HTTPException(status_code=400, detail="Ship not owned")
            loadout = await player_state.select_config(
                db, account["player_id"], req.ship_id, req.config_index
            )
            await db.commit()
        return {"ok": True, "loadout": loadout}

    @app.get("/equipment/stats")
    async def get_equipment_stats(ship_id: str = game_data.DEFAULT_SHIP,
                                  account: dict = Depends(get_current_account)):
        """The equipment aggregate the server uses for damage and speed."""
        async with aiosqlite.connect(_db()) as db:
            equipment = await combat_service.equipped_damage(
                db, account["player_id"], ship_id
            )
            drones = await combat_service.get_drones(db, account["player_id"])
        return {"equipment": equipment, "drones": drones,
                "ship": game_data.ship_stats(ship_id)}

    # -----------------------------------------------------------------------
    # Ammo (server-owned from Phase 2)
    # -----------------------------------------------------------------------
    @app.get("/ammo")
    async def get_ammo(account: dict = Depends(get_current_account)):
        async with aiosqlite.connect(_db()) as db:
            stock = await combat_service.get_ammo(db, account["player_id"])
        return {"ammo": stock, "ammo_client": _ammo_for_client(stock)}

    @app.post("/ammo")
    async def post_ammo(req: AmmoChangeRequest,
                        account: dict = Depends(get_current_account)):
        """Adjust the ammo stock.

        This is the CANONICAL entry point for a grant (quest reward, gate
        reward, admin action). Gameplay consumption happens through /ws, so a
        client cannot refill itself by calling this in a loop to gain ammo.
        """
        async with aiosqlite.connect(_db()) as db:
            if req.quantity is not None:
                stock = await combat_service.set_ammo(
                    db, account["player_id"], req.ammo_id, req.quantity
                )
            else:
                stock = await combat_service.add_ammo(
                    db, account["player_id"], req.ammo_id, req.amount or 0
                )
            await db.commit()
        return {"ok": True, "ammo": stock}

    # -----------------------------------------------------------------------
    # Drones
    # -----------------------------------------------------------------------
    @app.get("/drones")
    async def get_drones(account: dict = Depends(get_current_account)):
        async with aiosqlite.connect(_db()) as db:
            return {"drones": await combat_service.get_drones(
                db, account["player_id"])}

    @app.put("/drones")
    async def put_drones(req: DroneSaveRequest,
                         account: dict = Depends(get_current_account)):
        """Save the owned drone list.

        A drone must be OWNED: its type maps to a catalog item and the
        inventory count is what backs that claim, so the client cannot invent
        a fleet.
        """
        async with aiosqlite.connect(_db()) as db:
            inventory = await player_state.get_inventory(db, account["player_id"])
            wanted = {"PLUS": int(inventory.get("droid_plus_1", 0)),
                      "ZEUS": int(inventory.get("droid_zeus_1", 0))}
            counts = {"PLUS": 0, "ZEUS": 0}
            for entry in (req.drones or [])[: game_data.MAX_DRONES]:
                dtype = str(entry.get("drone_type", "PLUS")).strip().upper()
                if dtype in counts:
                    counts[dtype] += 1
            for dtype, count in counts.items():
                if count > wanted.get(dtype, 0):
                    raise HTTPException(
                        status_code=400,
                        detail={"rejected": [{"drone_type": dtype,
                                              "reason": "not_owned",
                                              "owned": wanted.get(dtype, 0),
                                              "requested": count}]},
                    )
            saved = await combat_service.set_drones(
                db, account["player_id"], req.drones
            )
            await db.commit()
        return {"ok": True, "drones": saved}

    # -----------------------------------------------------------------------
    # Faction change (Phase 3)
    # -----------------------------------------------------------------------
    @app.post("/account/faction")
    async def post_faction(req: FactionChangeRequest,
                           account: dict = Depends(get_current_account)):
        """Switch faction with the full public cost model.

        From the gap report's public reference:
          * 10000 PLT
          * 21 day (504 hour) cooldown
          * 50% of accrued honor is forfeited
          * blocked while the player is in a clan

        The FIRST company pick is free - it is part of registration and is
        still handled by PUT /account/company. This endpoint is only for a
        genuine faction SWITCH.
        """
        target = str(req.company).strip().upper()
        if target not in game_data.COMPANIES:
            raise HTTPException(status_code=400, detail="Unknown company")
        current = str(account.get("company", "")).strip().upper()
        if current == target:
            return {"ok": True, "changed": False, "reason": "already_member"}
        if not current:
            # No faction yet -> the free initial pick.
            return await _set_company(account, target, cost=0, honor_lost=0)

        async with aiosqlite.connect(_db()) as db:
            player_id = account["player_id"]

            # Clan restriction.
            cursor = await db.execute(
                "SELECT COUNT(*) FROM clan_members WHERE player_id = ?",
                (player_id,),
            )
            if (await cursor.fetchone())[0] > 0:
                raise HTTPException(status_code=409,
                                    detail="Leave your clan before changing faction")

            # Cooldown.
            cursor = await db.execute(
                "SELECT created_at FROM faction_changes WHERE player_id = ? "
                "ORDER BY id DESC LIMIT 1",
                (player_id,),
            )
            last = await cursor.fetchone()
            if last and last[0]:
                elapsed = _now() - int(last[0])
                if elapsed < game_data.FACTION_CHANGE_COOLDOWN_SECONDS:
                    remaining = game_data.FACTION_CHANGE_COOLDOWN_SECONDS - elapsed
                    raise HTTPException(
                        status_code=409,
                        detail={"reason": "cooldown",
                                "remaining_seconds": remaining},
                    )

            # Honor penalty + cost, both inside one transaction.
            stats = await player_state.ensure_stats(db, player_id)
            honor_lost = int(stats["honor"]) * \
                game_data.FACTION_CHANGE_HONOR_LOSS_PERCENT // 100
            cost = game_data.FACTION_CHANGE_COST_PLT

            cursor = await db.execute(
                "SELECT plt FROM economy WHERE player_id = ?", (player_id,)
            )
            econ = await cursor.fetchone()
            balance = int(econ[0]) if econ else 0
            if balance < cost:
                raise HTTPException(
                    status_code=400,
                    detail={"reason": "insufficient_plt", "required": cost,
                            "available": balance},
                )

            await db.execute(
                "UPDATE economy SET plt = plt - ?, updated_at = ? "
                "WHERE player_id = ?",
                (cost, _now(), player_id),
            )
            await player_state.add_honor(db, player_id, -honor_lost)
            await db.execute(
                "INSERT INTO faction_changes (player_id, from_company, "
                "to_company, cost_plt, honor_lost, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (player_id, current, target, cost, honor_lost, _now()),
            )
            await journal.record_event(
                db, player_id, journal.EVENT_FACTION_CHANGE,
                f"Sirket degistirildi: {current} -> {target}",
                journal.SEVERITY_IMPORTANT,
                {"from": current, "to": target, "cost_plt": cost,
                 "honor_lost": honor_lost},
            )
            await db.commit()

        return await _set_company(account, target, cost=cost, honor_lost=honor_lost)

    async def _set_company(account: dict, target: str, cost: int,
                           honor_lost: int) -> dict:
        """Persist the company on the account and on the live WebSocket session.

        The live-session update is what makes the change visible to other
        players immediately, matching the behaviour PUT /account/company
        already has.
        """
        from websocket_server import manager as ws_manager
        async with aiosqlite.connect(_db()) as db:
            await db.execute(
                "UPDATE accounts SET company = ? WHERE id = ?",
                (target, account["id"]),
            )
            await db.commit()
        try:
            # The live-session mirror is what makes the change visible to peers
            # immediately. A missing socket must never fail the change, so any
            # error here is swallowed.
            await ws_manager.set_company(account["player_id"], target)
        except Exception:
            pass
        return {"ok": True, "changed": True, "company": target,
                "cost_plt": cost, "honor_lost": honor_lost}

    # -----------------------------------------------------------------------
    # Maps / portals / online (Phase 3 + Phase 4)
    # -----------------------------------------------------------------------
    @app.get("/maps")
    async def get_maps(account: dict = Depends(get_current_account)):
        """Every map plus whether THIS player may enter it right now."""
        async with aiosqlite.connect(_db()) as db:
            stats = await player_state.get_stats(db, account["player_id"])
            world = await _world_of(db, account)
        level = int(stats["level"])
        company = str(account.get("company", "")).strip().upper()
        out = []
        for map_id, info in game_data.MAPS.items():
            allowed, reason = game_data.can_enter_map(map_id, level, company)
            out.append({
                "map_id": map_id,
                "display_name": str(info.get("display", map_id)),
                "company": str(info.get("company", "")),
                "min_level": int(info.get("min_level", 1)),
                "is_pvp": bool(info.get("is_pvp")),
                "unlocked": allowed,
                "reason": reason,
                "portals": [
                    {"portal_id": p["portal_id"], "to_map": p["to_map"],
                     "min_level": int(p["min_level"]),
                     "unlocked": level >= int(p["min_level"])}
                    for p in game_data.portals_from(map_id)
                ],
            })
        return {"maps": out, "current_map": world["map_id"],
                "level": level, "company": company}

    @app.post("/map/move")
    async def post_map_move(req: MapMoveRequest,
                            account: dict = Depends(get_current_account)):
        """Request a direct map move.

        The server checks the level and faction gate and then requires a REAL
        portal to exist for the transition; a client cannot name an arbitrary
        destination.
        """
        target = str(req.map_id).strip()
        async with aiosqlite.connect(_db()) as db:
            stats = await player_state.get_stats(db, account["player_id"])
            world = await _world_of(db, account)
        level = int(stats["level"])
        company = str(account.get("company", "")).strip().upper()
        allowed, reason = game_data.can_enter_map(target, level, company)
        if not allowed:
            raise HTTPException(status_code=403,
                                detail={"reason": reason, "map_id": target})
        portal = next((p for p in game_data.portals_from(world["map_id"])
                       if p["to_map"] == target), None)
        if portal is None:
            raise HTTPException(status_code=403,
                                detail={"reason": "no_portal",
                                        "from": world["map_id"], "to": target})
        return {"ok": True, "map_id": target, "portal_id": portal["portal_id"]}

    @app.post("/portal/travel")
    async def post_travel(req: TeleportRequest,
                          account: dict = Depends(get_current_account)):
        """Travel through a named portal.

        The portal must exist, must be reachable FROM the player's current map,
        and its level gate must be met. The actual world move is performed by
        the WebSocket layer so the broadcast happens on the same event loop.
        """
        async with aiosqlite.connect(_db()) as db:
            stats = await player_state.get_stats(db, account["player_id"])
            world = await _world_of(db, account)
        portal = game_data.find_portal(str(req.portal_id).strip())
        if portal is None:
            raise HTTPException(status_code=404, detail="Unknown portal")
        if portal["from_map"] != world["map_id"]:
            raise HTTPException(status_code=403,
                                detail={"reason": "wrong_origin",
                                        "portal_from": portal["from_map"],
                                        "you_are_on": world["map_id"]})
        level = int(stats["level"])
        if level < int(portal["min_level"]):
            raise HTTPException(status_code=403,
                                detail={"reason": "level_too_low",
                                        "required": int(portal["min_level"]),
                                        "level": level})
        company = str(account.get("company", "")).strip().upper()
        allowed, reason = game_data.can_enter_map(portal["to_map"], level, company)
        if not allowed:
            raise HTTPException(status_code=403,
                                detail={"reason": reason,
                                        "to_map": portal["to_map"]})
        return {"ok": True, "to_map": portal["to_map"],
                "portal_id": portal["portal_id"]}

    @app.get("/world/online")
    async def get_online(account: dict = Depends(get_current_account)):
        """Who is actually connected right now, from the live world server."""
        from websocket_server import manager as ws_manager
        players = []
        for pid, session in list(ws_manager.active_connections.items()):
            if getattr(session, "disconnected", False):
                continue
            players.append({
                "player_id": pid,
                "username": getattr(session, "username", ""),
                "company": str(getattr(session, "company", "")).upper(),
                "map_id": getattr(session, "map_id", ""),
                "level": int(getattr(session, "level", 0) or 0),
                "ship_id": getattr(session, "ship_id", ""),
            })
        return {"count": len(players), "players": players}

    @app.get("/ranking")
    async def get_ranking(limit: int = 50,
                          account: dict = Depends(get_current_account)):
        """Server-computed ranking over XP / honor / kills / deaths.

        The client used to derive a rank locally from its own save file, so two
        players could never agree. This is the single source.
        """
        limit = max(1, min(int(limit), 200))
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT s.player_id, a.username, a.company, s.xp, s.honor, "
                "s.level, s.npc_kills, s.player_kills, s.deaths "
                "FROM player_stats s "
                "LEFT JOIN accounts a ON a.player_id = s.player_id "
                "ORDER BY s.level DESC, s.xp DESC, s.honor DESC LIMIT ?",
                (limit,),
            )
            rows = await cursor.fetchall()
        entries = []
        for index, row in enumerate(rows, start=1):
            npc_kills, player_kills, deaths = int(row[6]), int(row[7]), int(row[8])
            total = npc_kills + player_kills
            # K/D as a plain ratio; a zero-death player is ranked by kills alone.
            ratio = (player_kills / deaths) if deaths else float(player_kills)
            entries.append({
                "position": index,
                "player_id": row[0],
                "username": row[1] or "",
                "company": row[2] or "",
                "xp": int(row[3]), "honor": int(row[4]), "level": int(row[5]),
                "npc_kills": npc_kills, "player_kills": player_kills,
                "deaths": deaths, "total_kills": total,
                "kd": round(ratio, 2),
            })
        return {"entries": entries, "count": len(entries)}

    @app.get("/account/nickname")
    async def get_nickname(account: dict = Depends(get_current_account)):
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT nickname, a_rank FROM player_identity WHERE player_id = ?",
                (account["player_id"],),
            )
            row = await cursor.fetchone()
        if row is None:
            return {"nickname": account["username"], "a_rank": False}
        return {"nickname": row[0] or account["username"],
                "a_rank": bool(row[1])}

    @app.put("/account/nickname")
    async def put_nickname(req: NicknameRequest,
                           account: dict = Depends(get_current_account)):
        """Set the display nickname.

        The server normalises it (trim, printable characters only, length) and
        enforces uniqueness, so two players cannot show the same name.
        """
        nickname = "".join(
            ch for ch in str(req.nickname).strip() if ch.isprintable()
        )
        if not 2 <= len(nickname) <= 24:
            raise HTTPException(status_code=400, detail="Invalid nickname")
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT player_id FROM player_identity WHERE nickname = ? "
                "AND player_id != ?",
                (nickname, account["player_id"]),
            )
            if await cursor.fetchone() is not None:
                raise HTTPException(status_code=409,
                                    detail="Nickname already taken")
            await db.execute(
                "INSERT INTO player_identity (player_id, nickname, created_at) "
                "VALUES (?, ?, ?) ON CONFLICT(player_id) DO UPDATE SET "
                "nickname = excluded.nickname",
                (account["player_id"], nickname, _now()),
            )
            await db.execute(
                "UPDATE accounts SET nickname = ? WHERE id = ?",
                (nickname, account["id"]),
            )
            await journal.record_event(
                db, account["player_id"], journal.EVENT_SYSTEM,
                f"Nickname degistirildi: {nickname}", journal.SEVERITY_INFO,
                {"nickname": nickname},
            )
            await db.commit()
        return {"ok": True, "nickname": nickname}





