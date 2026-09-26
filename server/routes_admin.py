"""Admin Panel HTTP surface.

Every handler follows the same three rules, which is what makes the panel
safe to expose to staff:

1. AUTHORITY IS RESOLVED FROM THE `accounts` ROW, NEVER FROM THE REQUEST BODY.
   `require_permission(...)` reads the role that `get_current_account` loaded
   from the database, so a client that sets `is_admin: true` in players.json,
   or a forged payload field, changes nothing.
2. EVERY MUTATION IS AUDITED. `admin_core.write_audit` records admin, role,
   action, target, old value, new value, reason, result and the remote
   address. The log is append-only (enforced by a database trigger), so
   history cannot be rewritten afterwards.
3. A LIVE SESSION IS PUSHED TOO. A change to an online player's economy,
   stats, map or loadout is not just written to the database: it is sent down
   that player's own WebSocket as `admin_state_update`, so the HUD and the
   inventory agree without waiting for a re-login.
"""

from __future__ import annotations

import time
from typing import Optional

import aiosqlite
from fastapi import Depends, HTTPException, Request, status
from pydantic import BaseModel, Field

import admin_core
import combat as combat_service
import game_data
import gate_service
import item_catalog
import journal
import player_state
import schedulers
from item_catalog import normalize_item_id
from routes_p45 import _grant_currency, _grant_item, _with_db

# Hard ceiling on any single admin currency or stat write. A typo in the panel
# must not be able to mint or destroy an economy.
MAX_ADMIN_DELTA = 1_000_000_000
MAX_ADMIN_QUANTITY = 1_000_000
MAX_CURRENCY_BALANCE = 9_000_000_000_000_000


def _now() -> int:
    return int(time.time())


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------
class CurrencyDelta(BaseModel):
    currency: str
    amount: int
    reason: str = ""


class ItemChange(BaseModel):
    item_id: str
    quantity: int
    reason: str = ""


class StatChange(BaseModel):
    xp: Optional[int] = None
    honor: Optional[int] = None
    level: Optional[int] = None
    hp: Optional[float] = None
    shield: Optional[float] = None
    reason: str = ""


class PlayerTeleport(BaseModel):
    map_id: str
    x: Optional[float] = None
    y: Optional[float] = None
    reason: str = ""


class LoadoutChange(BaseModel):
    ship_id: str = game_data.DEFAULT_SHIP
    config_index: int = Field(default=1, ge=1, le=2)
    lasers: Optional[list] = None
    generators: Optional[list] = None
    extras: Optional[list] = None
    selected: Optional[bool] = None
    reason: str = ""


class AmmoChange(BaseModel):
    ammo_id: str
    quantity: int
    reason: str = ""


class RoleChange(BaseModel):
    role: str
    reason: str = ""


class MuteChange(BaseModel):
    muted: bool
    reason: str = ""
    duration_seconds: int = 0


class QuestAdminAction(BaseModel):
    quest_id: str
    action: str            # complete | reset | progress
    amount: int = 0
    reason: str = ""


class GateAdminAction(BaseModel):
    gate_id: str
    action: str            # reset | complete
    reason: str = ""


class NpcPosition(BaseModel):
    x: float
    y: float


class BroadcastRequest(BaseModel):
    message: str = Field(min_length=1, max_length=500)
    reason: str = ""


class ServerFlag(BaseModel):
    enabled: bool
    reason: str = ""


class EventUpsert(BaseModel):
    event_id: str
    name: str
    map_id: str = ""
    starts_at: int = 0
    ends_at: int = 0
    reward_btc: int = 0
    reward_plt: int = 0
    reward_xp: int = 0
    reward_honor: int = 0
    reason: str = ""


class AuctionCancel(BaseModel):
    reason: str = ""


# ---------------------------------------------------------------------------
# Live push + lookup helpers
# ---------------------------------------------------------------------------
async def push_admin_state(player_id: str, payload: dict) -> bool:
    """Send an admin change to an online player's own socket.

    Only the affected player is messaged. A failure here never fails the
    operation: the database is already the source of truth and the client will
    reconcile on its next login, so a closed socket is not an error.
    """
    try:
        from websocket_server import manager as ws_manager
        session = ws_manager.active_connections.get(str(player_id))
        if session is None or getattr(session, "disconnected", True):
            return False
        websocket = getattr(session, "websocket", None)
        if websocket is None:
            return False
        import json as _json
        await websocket.send_text(_json.dumps({
            "type": "admin_state_update",
            "payload": payload,
        }))
        return True
    except Exception as exc:
        print(f"[NOVAGATE] admin push failed player={player_id} err={exc}",
              flush=True)
        return False


async def resolve_player(db, identifier: str) -> dict:
    """Look a player up by USERNAME or by PLAYER_ID.

    The Admin Panel shows a player_id in most tables, so accepting both is a
    usability win rather than a convenience that weakens any check.
    """
    text = str(identifier or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="Player identifier required")
    cursor = await db.execute(
        "SELECT id, username, player_id, company, role FROM accounts "
        "WHERE username = ? OR player_id = ?",
        (text, text),
    )
    row = await cursor.fetchone()
    if row is None:
        raise HTTPException(status_code=404,
                            detail=f"Player not found: {text}")
    return {"id": int(row[0]), "username": str(row[1]),
            "player_id": str(row[2]), "company": str(row[3] or ""),
            "role": str(row[4] or "player")}


async def player_snapshot(db, player: dict) -> dict:
    """The full server-side view of one player, for the panel and for pushes."""
    player_id = player["player_id"]
    stats = await player_state.get_stats(db, player_id)
    econ = await (await db.execute(
        "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
        (player_id,))).fetchone()
    world = await (await db.execute(
        "SELECT map_id, position_x, position_y FROM player_world_state "
        "WHERE player_id = ?", (player_id,))).fetchone()
    ship = await (await db.execute(
        "SELECT ship_id FROM sessions WHERE player_id = ? AND active = 1 "
        "ORDER BY last_seen DESC LIMIT 1", (player_id,))).fetchone()
    drones = await combat_service.get_drones(db, player_id)
    inventory = await player_state.get_inventory(db, player_id)
    ammo = await combat_service.get_ammo(db, player_id)
    ship_id = str(ship[0]) if ship else game_data.DEFAULT_SHIP
    loadouts = await player_state.get_all_loadouts(db, player_id, ship_id)
    damage = await combat_service.equipped_damage(db, player_id, ship_id)

    from websocket_server import manager as ws_manager
    session = ws_manager.active_connections.get(player_id)
    online = bool(session is not None
                  and not getattr(session, "disconnected", True))

    return {
        "username": player["username"],
        "player_id": player_id,
        "company": player["company"],
        "role": player["role"],
        "online": online,
        "ship_id": ship_id,
        "map_id": str(world[0]) if world else "",
        "position_x": float(world[1]) if world else 0.0,
        "position_y": float(world[2]) if world else 0.0,
        "hp": float(stats["hp"]), "max_hp": float(stats["max_hp"]),
        "shield": float(stats["shield"]),
        "max_shield": float(stats["max_shield"]),
        "level": int(stats["level"]), "xp": int(stats["xp"]),
        "honor": int(stats["honor"]),
        "npc_kills": int(stats["npc_kills"]),
        "player_kills": int(stats["player_kills"]),
        "deaths": int(stats["deaths"]),
        "btc": int(econ[0]) if econ else 0,
        "plt": int(econ[1]) if econ else 0,
        "gold": int(econ[2]) if econ else 0,
        "inventory": inventory,
        "ammo": ammo,
        "drones": drones,
        "loadouts": loadouts,
        "damage": damage,
        "gates": await gate_service.reconnect_state(db, player_id),
        "stats": player_state.stats_payload(stats),
    }


def _clamp(value: int, low: int, high: int, label: str) -> int:
    """Bound an admin-supplied number, refusing rather than silently clamping.

    Silently clamping would make a panel typo look like it worked; refusing
    makes the mistake visible in the audit log.
    """
    value = int(value)
    if value < low or value > high:
        raise HTTPException(
            status_code=400,
            detail={"reason": "out_of_range", "field": label,
                    "min": low, "max": high, "value": value},
        )
    return value


# ---------------------------------------------------------------------------
# Runtime server flags
# ---------------------------------------------------------------------------
# Deliberately in memory: a restart clears maintenance, and failing toward
# "the game is playable" is the safe direction for an operational flag.
MAINTENANCE: dict = {"enabled": False, "by": ""}


def maintenance_enabled() -> bool:
    return bool(MAINTENANCE.get("enabled", False))


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------
def register_routes(app, get_current_account, db_path_provider) -> None:
    """Attach the Admin Panel surface to `app`."""

    def _db() -> str:
        return db_path_provider()

    def require_permission(permission: str):
        """Build a dependency that enforces ONE permission from the matrix.

        The role comes from `get_current_account`, which reads the `accounts`
        row, so authority is always server-side. A dependency rather than an
        in-handler check means a new endpoint cannot forget to guard itself.
        """
        async def dependency(request: Request) -> dict:
            account = await get_current_account(request)
            role = str(account.get("role", "player"))
            if not admin_core.has_permission(role, permission):
                raise HTTPException(
                    status_code=status.HTTP_403_FORBIDDEN,
                    detail={"reason": "permission_denied",
                            "required": permission, "role": role},
                )
            # The panel builds its menu from these, so attach them once here.
            account["permissions"] = admin_core.permissions_for(role)
            account["rank"] = admin_core.role_rank(role)
            return account
        dependency.__name__ = f"need_{permission.replace('.', '_')}"
        return dependency

    # =======================================================================
    # Dashboard / server status
    # =======================================================================
    @app.get("/admin/session")
    async def admin_session(account: dict = Depends(require_permission(
            "server.dashboard"))):
        """Who am I, and what may I do?

        The panel calls this on load to build its menu, so a staff member never
        sees a tab whose actions would 403.
        """
        return {
            "username": account["username"],
            "role": account.get("role", "player"),
            "rank": account.get("rank", 0),
            "permissions": account.get("permissions", []),
            "all_permissions": list(admin_core.PERMISSIONS),
            "roles": list(admin_core.ROLE_ORDER),
        }

    @app.get("/admin/dashboard")
    async def admin_dashboard(account: dict = Depends(require_permission(
            "server.dashboard"))):
        """The dashboard cards, all from live server state."""
        from websocket_server import manager as ws_manager, npc_manager
        async with aiosqlite.connect(_db()) as db:
            accounts = int((await (await db.execute(
                "SELECT COUNT(*) FROM accounts")).fetchone())[0])
            sums = (await (await db.execute(
                "SELECT COALESCE(SUM(btc), 0), COALESCE(SUM(plt), 0), "
                "COALESCE(SUM(gold), 0) FROM economy")).fetchone())

        online = [p for p in ws_manager.active_connections.values()
                  if not getattr(p, "disconnected", True)]
        npc_alive = sum(1 for n in npc_manager.npcs.values() if n.alive)
        maps_active = {getattr(p, "map_id", "") for p in online}

        return {
            "online_players": len(online),
            "total_accounts": accounts,
            "btc_economy": int(sums[0]),
            "plt_economy": int(sums[1]),
            "gold_economy": int(sums[2]),
            "npc_total": len(npc_manager.npcs),
            "npc_alive": npc_alive,
            "active_maps": len([m for m in maps_active if m]),
            "websocket_connections": len(ws_manager.active_connections),
            "scheduler": {
                "running": schedulers.hub.running,
                "sweeps": schedulers.hub.sweep_count,
                "last_error": schedulers.hub.last_error,
            },
            "maintenance": maintenance_enabled(),
            "errors": 1 if schedulers.hub.last_error else 0,
        }

    @app.post("/admin/server/maintenance")
    async def post_maintenance(req: ServerFlag, request: Request,
                                account: dict = Depends(require_permission(
                                    "server.control"))):
        """Toggle maintenance mode.

        A flag in memory that a game-request gate reads, so a restart clears
        it - which is the safe direction to fail.
        """
        old = maintenance_enabled()
        MAINTENANCE["enabled"] = bool(req.enabled)
        MAINTENANCE["by"] = account["username"]
        async with aiosqlite.connect(_db()) as db:
            await admin_core.write_audit(
                db, account, "server.maintenance", target_type="server",
                target="global", old_value=old, new_value=bool(req.enabled),
                reason=req.reason, request=request)
        return {"ok": True, "maintenance": maintenance_enabled()}

    @app.post("/admin/server/broadcast")
    async def post_broadcast(req: BroadcastRequest, request: Request,
                             account: dict = Depends(require_permission(
                                 "server.control"))):
        """Send a message to every connected client."""
        import json as _json
        from websocket_server import manager as ws_manager
        frame = _json.dumps({"type": "server_broadcast",
                             "payload": {"message": req.message}})
        sent = 0
        for session in list(ws_manager.active_connections.values()):
            if getattr(session, "disconnected", True):
                continue
            websocket = getattr(session, "websocket", None)
            if websocket is None:
                continue
            try:
                await websocket.send_text(frame)
                sent += 1
            except Exception:
                continue
        async with aiosqlite.connect(_db()) as db:
            await admin_core.write_audit(
                db, account, "server.broadcast", target_type="server",
                target="all", new_value=req.message, reason=req.reason,
                request=request)
        return {"ok": True, "delivered": sent}

    @app.post("/admin/server/kick-all")
    async def post_kick_all(req: BroadcastRequest, request: Request,
                            account: dict = Depends(require_permission(
                                "server.control"))):
        """Disconnect every player. A moderation action, not a restart."""
        from websocket_server import manager as ws_manager
        kicked = 0
        for player_id in list(ws_manager.active_connections.keys()):
            if await ws_manager.kick(player_id, "admin_kick_all"):
                kicked += 1
        async with aiosqlite.connect(_db()) as db:
            await admin_core.write_audit(
                db, account, "server.kick_all", target_type="server",
                target="all", new_value=kicked, reason=req.reason,
                request=request)
        return {"ok": True, "kicked": kicked}

    # =======================================================================
    # Players
    # =======================================================================
    @app.get("/admin/players")
    async def admin_players(
            search: str = "", limit: int = 100, offset: int = 0,
            account: dict = Depends(require_permission("player.lookup"))):
        """The player table, searchable by username or player_id."""
        from websocket_server import manager as ws_manager
        limit = _clamp(limit, 1, 500, "limit")
        offset = max(0, int(offset))
        term = "%" + search.strip() + "%"
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT a.username, a.player_id, a.company, a.role, "
                "e.btc, e.plt, e.gold, s.level, s.xp, s.honor, s.hp, "
                "s.shield, s.npc_kills, s.player_kills, s.deaths, "
                "w.map_id, ses.last_seen "
                "FROM accounts a "
                "LEFT JOIN economy e ON e.player_id = a.player_id "
                "LEFT JOIN player_stats s ON s.player_id = a.player_id "
                "LEFT JOIN player_world_state w ON w.player_id = a.player_id "
                "LEFT JOIN sessions ses ON ses.player_id = a.player_id "
                "AND ses.active = 1 "
                "WHERE (? = '%%' OR a.username LIKE ? OR a.player_id LIKE ?) "
                "ORDER BY a.username LIMIT ? OFFSET ?",
                (term, term, term, limit, offset),
            )
            rows = await cursor.fetchall()

        out = []
        for r in rows:
            session = ws_manager.active_connections.get(str(r[1]))
            out.append({
                "username": r[0], "player_id": r[1], "company": r[2] or "",
                "role": r[3] or "player",
                "btc": int(r[4] or 0), "plt": int(r[5] or 0),
                "gold": int(r[6] or 0),
                "level": int(r[7] or 1), "xp": int(r[8] or 0),
                "honor": int(r[9] or 0), "hp": float(r[10] or 0.0),
                "shield": float(r[11] or 0.0),
                "npc_kills": int(r[12] or 0), "player_kills": int(r[13] or 0),
                "deaths": int(r[14] or 0), "map_id": r[15] or "",
                "last_login": int(r[16] or 0),
                "online": bool(session is not None
                               and not getattr(session, "disconnected", True)),
            })
        return {"players": out, "count": len(out), "search": search}

    @app.get("/admin/player/{identifier}")
    async def admin_player_detail(identifier: str,
                                  account: dict = Depends(require_permission(
                                      "player.lookup"))):
        """Everything the panel shows on one player's detail page."""
        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            snapshot = await player_snapshot(db, player)
            muted, mute_reason = await admin_core.is_muted(
                db, player["player_id"])
            # `sessions` stores `active`, not `is_admin` - the role lives on
            # `accounts` and is already resolved above. `sessions.id` is a
            # TEXT session uuid, so it is returned as-is rather than cast.
            rows = await (await db.execute(
                "SELECT id, active, last_seen FROM sessions "
                "WHERE player_id = ? ORDER BY last_seen DESC LIMIT 5",
                (player["player_id"],))).fetchall()
            sessions = [{"id": str(r[0]), "active": bool(r[1]),
                         "last_seen": int(r[2])} for r in rows]
        snapshot["muted"] = muted
        snapshot["mute_reason"] = mute_reason
        snapshot["sessions"] = sessions
        return snapshot

    # =======================================================================
    # Economy
    # =======================================================================
    @app.post("/admin/player/{identifier}/currency")
    async def admin_currency(identifier: str, req: CurrencyDelta,
                             request: Request,
                             account: dict = Depends(require_permission(
                                 "economy.manage"))):
        """Add or subtract BTC / PLT / GOLD.

        The delta is bounded, the resulting balance is bounded, and the
        before/after pair goes to the audit log. An online player is pushed the
        new balance immediately.
        """
        column = {"BTC": "btc", "PLT": "plt", "GOLD": "gold"}.get(
            str(req.currency).strip().upper())
        if column is None:
            raise HTTPException(status_code=400,
                                detail="currency must be BTC, PLT or GOLD")
        amount = _clamp(req.amount, -MAX_ADMIN_DELTA, MAX_ADMIN_DELTA, "amount")

        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            row = await (await db.execute(
                f"SELECT {column} FROM economy WHERE player_id = ?",
                (player["player_id"],))).fetchone()
            old = int(row[0]) if row else 0
            new = old + amount
            # f-string above is fed ONLY by the fixed dict lookup above, never
            # by request data, so the column name cannot be injected.
            if new < 0:
                raise HTTPException(
                    status_code=400,
                    detail={"reason": "insufficient", "field": column,
                            "current": old, "requested": amount})
            if new > MAX_CURRENCY_BALANCE:
                raise HTTPException(
                    status_code=400,
                    detail={"reason": "balance_overflow", "field": column,
                            "max": MAX_CURRENCY_BALANCE, "requested": new})
            await db.execute(
                "INSERT OR IGNORE INTO economy (player_id, btc, plt, gold, "
                "updated_at) VALUES (?, 0, 0, 0, ?)",
                (player["player_id"], _now()))
            await db.execute(
                f"UPDATE economy SET {column} = ?, updated_at = ? "
                f"WHERE player_id = ?",
                (new, _now(), player["player_id"]))
            await db.execute(
                "INSERT INTO transactions (player_id, currency, amount, "
                "reason, timestamp) VALUES (?, ?, ?, ?, ?)",
                (player["player_id"], column.upper(), amount,
                 req.reason or "admin", _now()))
            await journal.record_event(
                db, player["player_id"], journal.EVENT_REWARD,
                f"Admin {column.upper()} degisikligi: {amount:+d}",
                journal.SEVERITY_IMPORTANT,
                {"admin": account["username"], "old": old, "new": new,
                 "reason": req.reason})
            await admin_core.write_audit(
                db, account, f"economy.{column.lower()}",
                target=player["username"], old_value=old, new_value=new,
                reason=req.reason, request=request)
            await db.commit()

        await push_admin_state(player["player_id"],
                              {"economy": {column: new}})
        return {"ok": True, "player_id": player["player_id"],
                "currency": column.upper(), "old": old, "new": new}

    # =======================================================================
    # Inventory
    # =======================================================================
    @app.get("/admin/catalog")
    async def admin_catalog(account: dict = Depends(require_permission(
            "inventory.manage"))):
        """The canonical item catalog the panel's item picker is built from.

        Served from item_catalog rather than hard-coded in the panel, so the
        panel can never offer an id the server would reject.
        """
        return {"items": item_catalog.catalog_seeds()}

    @app.post("/admin/player/{identifier}/item")
    async def admin_item(identifier: str, req: ItemChange, request: Request,
                         account: dict = Depends(require_permission(
                             "inventory.manage"))):
        """Add or remove an inventory item.

        The id is normalised through the same `normalize_item_id` the gameplay
        path uses, so `Kalkan 1` and `kalkan1` are one item and an unknown id
        is rejected rather than silently stored.
        """
        canonical = normalize_item_id(req.item_id)
        if not item_catalog.is_known_item(canonical):
            raise HTTPException(status_code=400,
                                detail={"reason": "unknown_item",
                                        "item_id": req.item_id})
        quantity = _clamp(req.quantity, -MAX_ADMIN_QUANTITY,
                          MAX_ADMIN_QUANTITY, "quantity")

        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            old = await player_state.get_inventory(db, player["player_id"])
            if quantity > 0:
                await _grant_item(db, player["player_id"], canonical, quantity)
            else:
                wanted = -quantity if quantity < 0 else 1
                if not await player_state.owns_item(db, player["player_id"],
                                                    canonical, needed=wanted):
                    raise HTTPException(
                        status_code=400,
                        detail={"reason": "not_owned", "item_id": canonical})
                if quantity < 0:
                    await player_state.consume_item(
                        db, player["player_id"], canonical, needed=wanted)
            new = await player_state.get_inventory(db, player["player_id"])
            await admin_core.write_audit(
                db, account, "inventory.item", target=player["username"],
                old_value={canonical: old.get(canonical, 0)},
                new_value={canonical: new.get(canonical, 0)},
                reason=req.reason, request=request)
            await db.commit()

        await push_admin_state(player["player_id"], {"inventory": new})
        return {"ok": True, "item_id": canonical,
                "old": old.get(canonical, 0), "new": new.get(canonical, 0),
                "inventory": new}

    # =======================================================================
    # Stats / vitals
    # =======================================================================
    @app.post("/admin/player/{identifier}/stats")
    async def admin_stats(identifier: str, req: StatChange, request: Request,
                          account: dict = Depends(require_permission(
                              "stats.manage"))):
        """Set XP, honor, level, HP and/or shield.

        Level and XP are two views of the same progression, so a level change
        recomputes XP from the level table rather than leaving an inconsistent
        pair behind. HP and shield are clamped to the player's own maxima.
        """
        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            before = await player_state.get_stats(db, player["player_id"])
            old = {"xp": int(before["xp"]), "honor": int(before["honor"]),
                   "level": int(before["level"]), "hp": float(before["hp"]),
                   "shield": float(before["shield"])}

            if req.level is not None:
                level = _clamp(req.level, 1, game_data.MAX_LEVEL, "level")
                await player_state.set_level_and_xp(
                    db, player["player_id"], game_data.xp_for_level(level))
            if req.xp is not None:
                await player_state.set_level_and_xp(
                    db, player["player_id"],
                    _clamp(req.xp, 0, 1_000_000_000, "xp"))
            if req.honor is not None:
                current = int(before["honor"])
                target = current + _clamp(req.honor, -MAX_ADMIN_DELTA,
                                          MAX_ADMIN_DELTA, "honor")
                await player_state.add_honor(
                    db, player["player_id"], target - current)

            if req.hp is not None or req.shield is not None:
                after = await player_state.get_stats(db, player["player_id"])
                hp = float(req.hp if req.hp is not None else after["hp"])
                shield = float(req.shield if req.shield is not None
                               else after["shield"])
                await player_state.set_vitals(
                    db, player["player_id"],
                    min(max(0.0, hp), float(after["max_hp"])),
                    min(max(0.0, shield), float(after["max_shield"])),
                    max_hp=float(after["max_hp"]),
                    max_shield=float(after["max_shield"]))

            now = await player_state.get_stats(db, player["player_id"])
            new = {"xp": int(now["xp"]), "honor": int(now["honor"]),
                   "level": int(now["level"]), "hp": float(now["hp"]),
                   "shield": float(now["shield"])}
            await journal.record_event(
                db, player["player_id"], journal.EVENT_SYSTEM,
                "Admin istatistik degisikligi", journal.SEVERITY_IMPORTANT,
                {"admin": account["username"], "old": old, "new": new,
                 "reason": req.reason})
            await admin_core.write_audit(
                db, account, "player.stats", target=player["username"],
                old_value=old, new_value=new, reason=req.reason,
                request=request)
            await db.commit()

        await push_admin_state(player["player_id"], {"stats": new})
        return {"ok": True, "old": old, "new": new}

    # =======================================================================
    # Equipment / ship / ammo
    # =======================================================================
    @app.post("/admin/player/{identifier}/loadout")
    async def admin_loadout(identifier: str, req: LoadoutChange,
                            request: Request,
                            account: dict = Depends(require_permission(
                                "equipment.manage"))):
        """Overwrite a config's slots, and optionally select it.

        Every item is validated against the catalog AND the player's own
        inventory through `combat.can_equip` - the same gate the in-game hangar
        uses. An admin cannot fit a laser the player does not own.
        """
        ship_id = str(req.ship_id)
        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            old = await player_state.get_loadout(
                db, player["player_id"], ship_id, int(req.config_index))
            new = dict(old)
            for field in ("lasers", "generators", "extras"):
                supplied = getattr(req, field)
                if supplied is None:
                    continue
                cleaned = []
                for raw in supplied:
                    if not str(raw).strip():
                        continue
                    canonical = normalize_item_id(raw)
                    allowed, reason = await combat_service.can_equip(
                        db, player["player_id"], canonical)
                    if not allowed:
                        raise HTTPException(
                            status_code=400,
                            detail={"reason": reason, "item_id": canonical})
                    cleaned.append(canonical)
                new[field] = cleaned
            await player_state.save_loadout(
                db, player["player_id"], ship_id, int(req.config_index), new)
            if req.selected:
                await player_state.select_config(
                    db, player["player_id"], ship_id, int(req.config_index))
            await journal.record_event(
                db, player["player_id"], journal.EVENT_EQUIPMENT,
                f"Admin ekipman degisikligi: {ship_id} config "
                f"{req.config_index}", journal.SEVERITY_IMPORTANT,
                {"admin": account["username"], "old": old, "new": new})
            await admin_core.write_audit(
                db, account, "equipment.loadout",
                target=player["username"], old_value=old, new_value=new,
                reason=req.reason, request=request)
            await db.commit()

        await push_admin_state(player["player_id"],
                              {"loadout": new, "ship_id": ship_id})
        return {"ok": True, "ship_id": ship_id,
                "config_index": int(req.config_index),
                "old": old, "new": new}

    @app.post("/admin/player/{identifier}/ammo")
    async def admin_ammo(identifier: str, req: AmmoChange, request: Request,
                         account: dict = Depends(require_permission(
                             "equipment.manage"))):
        """Add or remove an ammo reserve.

        A negative delta requires the rounds to be present, so this can never
        leave a phantom negative balance.
        """
        ammo_id = str(req.ammo_id).strip()
        amount = _clamp(req.quantity, -MAX_ADMIN_QUANTITY, MAX_ADMIN_QUANTITY,
                        "quantity")
        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            old = await combat_service.get_ammo(db, player["player_id"])
            old_count = int(old.get(ammo_id, 0))
            if amount < 0 and old_count + amount < 0:
                raise HTTPException(
                    status_code=400,
                    detail={"reason": "insufficient_ammo",
                            "ammo_id": ammo_id, "current": old_count})
            if amount >= 0:
                await combat_service.add_ammo(db, player["player_id"],
                                              ammo_id, amount)
            else:
                await combat_service.consume_ammo(
                    db, player["player_id"], ammo_id, amount=-amount)
            new = await combat_service.get_ammo(db, player["player_id"])
            await journal.record_event(
                db, player["player_id"], journal.EVENT_AMMO,
                f"Admin ammo degisikligi: {ammo_id} {amount:+d}",
                journal.SEVERITY_IMPORTANT, {"admin": account["username"]})
            await admin_core.write_audit(
                db, account, "equipment.ammo", target=player["username"],
                old_value={ammo_id: old_count},
                new_value={ammo_id: int(new.get(ammo_id, 0))},
                reason=req.reason, request=request)
            await db.commit()

        await push_admin_state(player["player_id"], {"ammo": new})
        return {"ok": True, "ammo_id": ammo_id, "old": old_count,
                "new": int(new.get(ammo_id, 0)), "ammo": new}

    @app.post("/admin/player/{identifier}/ship")
    async def admin_ship(identifier: str, req: LoadoutChange, request: Request,
                         account: dict = Depends(require_permission(
                             "ship.manage"))):
        """Change the player's active ship.

        Written to `sessions` AND the live socket, because the world loop reads
        the session row while the HUD reads the socket - updating only one of
        them is what previously made a ship change look half-applied.
        """
        ship_id = str(req.ship_id)
        if ship_id not in game_data.SHIP_STATS:
            raise HTTPException(status_code=400,
                                detail={"reason": "unknown_ship",
                                        "ship_id": ship_id})
        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            old = await (await db.execute(
                "SELECT ship_id FROM sessions WHERE player_id = ? "
                "AND active = 1 ORDER BY last_seen DESC LIMIT 1",
                (player["player_id"],))).fetchone()
            old_ship = str(old[0]) if old else game_data.DEFAULT_SHIP
            await db.execute(
                "UPDATE sessions SET ship_id = ? WHERE player_id = ? "
                "AND active = 1",
                (ship_id, player["player_id"]))
            await admin_core.write_audit(
                db, account, "player.ship", target=player["username"],
                old_value=old_ship, new_value=ship_id, reason=req.reason,
                request=request)
            await db.commit()

        try:
            from websocket_server import manager as ws_manager
            if hasattr(ws_manager, "set_ship"):
                await ws_manager.set_ship(player["player_id"], ship_id)
        except Exception as exc:
            print("[NOVAGATE] ship push failed: %s" % exc, flush=True)
        await push_admin_state(player["player_id"], {"ship_id": ship_id})
        return {"ok": True, "old": old_ship, "new": ship_id}

    # =======================================================================
    # Player control
    # =======================================================================
    @app.post("/admin/player/{identifier}/teleport")
    async def admin_teleport(identifier: str, req: PlayerTeleport,
                             request: Request,
                             account: dict = Depends(require_permission(
                                 "player.teleport"))):
        """Move a player to a map.

        The map is validated against `game_data` and the portal rules, so an
        admin cannot drop a player into a map id that does not exist. The
        position is persisted in `player_world_state` AND pushed, so the move
        survives a reconnect.
        """
        map_id = str(req.map_id).strip()
        if not game_data.is_known_map(map_id):
            raise HTTPException(status_code=400,
                                detail={"reason": "unknown_map",
                                        "map_id": map_id})
        x = float(req.x if req.x is not None else 0.0)
        y = float(req.y if req.y is not None else 0.0)

        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            old = await (await db.execute(
                "SELECT map_id, position_x, position_y "
                "FROM player_world_state WHERE player_id = ?",
                (player["player_id"],))).fetchone()
            old_map = str(old[0]) if old else ""
            await db.execute(
                "INSERT INTO player_world_state (player_id, map_id, "
                "position_x, position_y, updated_at) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(player_id) DO UPDATE SET map_id = excluded.map_id, "
                "position_x = excluded.position_x, "
                "position_y = excluded.position_y, "
                "updated_at = excluded.updated_at",
                (player["player_id"], map_id, x, y, _now()))
            await admin_core.write_audit(
                db, account, "player.teleport", target=player["username"],
                old_value=old_map,
                new_value={"map_id": map_id, "x": x, "y": y},
                reason=req.reason, request=request)
            await db.commit()

        try:
            from websocket_server import manager as ws_manager
            if hasattr(ws_manager, "teleport"):
                await ws_manager.teleport(player["player_id"], map_id, x, y)
        except Exception as exc:
            print("[NOVAGATE] teleport push failed: %s" % exc, flush=True)
        await push_admin_state(player["player_id"],
                              {"map_id": map_id, "x": x, "y": y,
                               "teleported": True})
        return {"ok": True, "old": old_map, "new": map_id, "x": x, "y": y}

    @app.post("/admin/player/{identifier}/kick")
    async def admin_kick(identifier: str, request: Request,
                         account: dict = Depends(require_permission(
                             "player.kick"))):
        """Disconnect a player. Moderation, not a server restart."""
        from websocket_server import manager as ws_manager
        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            was_online = player["player_id"] in ws_manager.active_connections
            await admin_core.write_audit(
                db, account, "player.kick", target=player["username"],
                new_value=not was_online, reason="moderation",
                request=request)
            await db.commit()
        ok = await ws_manager.kick(player["player_id"], "admin_kick")
        return {"ok": bool(ok), "player_id": player["player_id"],
                "was_online": was_online}

    @app.get("/admin/online")
    async def admin_online(account: dict = Depends(require_permission(
            "player.online"))):
        """Who is connected right now."""
        from websocket_server import manager as ws_manager
        out = []
        for player_id, session in ws_manager.active_connections.items():
            if getattr(session, "disconnected", True):
                continue
            out.append({
                "player_id": player_id,
                "username": getattr(session, "username", ""),
                "map_id": getattr(session, "map_id", ""),
                "x": float(getattr(session, "x", 0.0) or 0.0),
                "y": float(getattr(session, "y", 0.0) or 0.0),
                "company": getattr(session, "company", ""),
            })
        return {"online": out, "count": len(out)}

    # =======================================================================
    # Chat moderation
    # =======================================================================
    @app.get("/admin/chat/recent")
    async def admin_chat(limit: int = 100,
                         account: dict = Depends(require_permission(
                             "chat.moderate"))):
        """Recent public chat, newest first."""
        from websocket_server import manager as ws_manager
        limit = _clamp(limit, 1, 500, "limit")
        history = list(getattr(ws_manager, "chat_history", []) or [])
        recent = history[-limit:][::-1]
        return {"messages": recent, "count": len(recent),
                "online": len(ws_manager.active_connections)}

    @app.post("/admin/player/{identifier}/mute")
    async def admin_mute(identifier: str, req: MuteChange, request: Request,
                         account: dict = Depends(require_permission(
                             "chat.moderate"))):
        """Mute or unmute a player.

        The mute is a database row, so it survives a restart and the client
        cannot clear it by editing a local file. The WebSocket chat handler
        reads it on every message.
        """
        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            was, _reason = await admin_core.is_muted(db, player["player_id"])
            until = (_now() + int(req.duration_seconds)
                     if req.muted and req.duration_seconds > 0 else 0)
            await admin_core.set_mute(db, player["player_id"],
                                      player["username"], bool(req.muted),
                                      req.reason, until, account["username"])
            await admin_core.write_audit(
                db, account, "chat.mute", target=player["username"],
                old_value=was, new_value=bool(req.muted), reason=req.reason,
                request=request)
            await db.commit()
        await push_admin_state(player["player_id"],
                              {"muted": bool(req.muted)})
        return {"ok": True, "muted": bool(req.muted), "until": until,
                "player_id": player["player_id"]}

    @app.get("/admin/mutes")
    async def admin_mutes(account: dict = Depends(require_permission(
            "chat.moderate"))):
        async with aiosqlite.connect(_db()) as db:
            rows = await (await db.execute(
                "SELECT player_id, username, muted, reason, until_ts, "
                "muted_by, created_at FROM player_mutes WHERE muted = 1 "
                "ORDER BY created_at DESC")).fetchall()
        return {"mutes": [
            {"player_id": r[0], "username": r[1], "reason": r[3],
             "until": int(r[4]), "muted_by": r[5],
             "created_at": int(r[6])} for r in rows]}

    # =======================================================================
    # NPC / map
    # =======================================================================
    @app.get("/admin/npcs")
    async def admin_npcs(account: dict = Depends(require_permission(
            "npc.manage"))):
        """The live NPC table.

        NPC economy values are NOT exposed for editing. The spawn controls
        below deliberately cannot change HP, damage or rewards, so the
        gameplay balance cannot be altered from the panel by accident.
        """
        from websocket_server import npc_manager
        return {"npcs": npc_manager.admin_list()}

    @app.post("/admin/npcs/spawn")
    async def admin_npc_spawn(request: Request,
                              account: dict = Depends(require_permission(
                                  "npc.manage"))):
        """Spawn an NPC from the server's own NPC table.

        The type comes from the request but the HP, damage and rewards all come
        from the server's NPC definition, so spawning cannot introduce an NPC
        with invented balance values.
        """
        from websocket_server import npc_manager
        body = await request.json()
        npc_type = str((body or {}).get("npc_type", "")).strip()
        map_id = str((body or {}).get("map_id", game_data.DEFAULT_MAP)).strip()
        if not npc_type:
            raise HTTPException(status_code=400,
                                detail={"reason": "npc_type_required"})
        if not game_data.is_known_map(map_id):
            raise HTTPException(status_code=400,
                                detail={"reason": "unknown_map",
                                        "map_id": map_id})
        try:
            x = float((body or {}).get("x", 0.0))
            y = float((body or {}).get("y", 0.0))
        except (TypeError, ValueError):
            raise HTTPException(status_code=400,
                                detail={"reason": "invalid_position"})
        npc = npc_manager.spawn_npc(npc_type, map_id, x, y)
        if npc is None:
            raise HTTPException(status_code=400,
                                detail={"reason": "unknown_npc_type",
                                        "npc_type": npc_type})
        async with aiosqlite.connect(_db()) as db:
            await admin_core.write_audit(
                db, account, "npc.spawn", target_type="npc",
                target=getattr(npc, "npc_id", npc_type),
                new_value={"npc_type": npc_type, "map_id": map_id,
                           "x": x, "y": y},
                reason=(body or {}).get("reason", ""), request=request)
        return {"ok": True, "npc_id": getattr(npc, "npc_id", ""),
                "npc_type": npc_type, "map_id": map_id, "x": x, "y": y}

    @app.post("/admin/npcs/{npc_id}/position")
    async def admin_npc_position(npc_id: str, req: NpcPosition,
                                 request: Request,
                                 account: dict = Depends(require_permission(
                                     "npc.manage"))):
        """Move an NPC. Position only - never its stats."""
        from websocket_server import npc_manager
        if npc_id not in npc_manager.npcs:
            raise HTTPException(status_code=404, detail="NPC not found")
        npc = npc_manager.npcs[npc_id]
        old = (float(npc.x), float(npc.y))
        npc.x, npc.y = float(req.x), float(req.y)
        async with aiosqlite.connect(_db()) as db:
            await admin_core.write_audit(
                db, account, "npc.position", target_type="npc", target=npc_id,
                old_value={"x": old[0], "y": old[1]},
                new_value={"x": npc.x, "y": npc.y}, request=request)
        return {"ok": True, "npc_id": npc_id, "x": npc.x, "y": npc.y,
                "old": {"x": old[0], "y": old[1]}}

    @app.post("/admin/npcs/{npc_id}/respawn")
    async def admin_npc_respawn(npc_id: str, request: Request,
                                account: dict = Depends(require_permission(
                                    "npc.manage"))):
        """Respawn a dead NPC at full health.

        `respawn()` restores the NPC's own configured HP, so this cannot be
        used to buff an NPC above its balance value.
        """
        from websocket_server import npc_manager
        if npc_id not in npc_manager.npcs:
            raise HTTPException(status_code=404, detail="NPC not found")
        ok = npc_manager.npcs[npc_id].respawn()
        async with aiosqlite.connect(_db()) as db:
            await admin_core.write_audit(
                db, account, "npc.respawn", target_type="npc", target=npc_id,
                new_value=bool(ok), request=request)
        return {"ok": bool(ok), "npc_id": npc_id}

    @app.delete("/admin/npcs/{npc_id}")
    async def admin_npc_remove(npc_id: str, request: Request,
                               account: dict = Depends(require_permission(
                                   "npc.manage"))):
        from websocket_server import npc_manager
        if not await npc_manager.admin_remove(npc_id):
            raise HTTPException(status_code=404, detail="NPC not found")
        async with aiosqlite.connect(_db()) as db:
            await admin_core.write_audit(
                db, account, "npc.remove", target_type="npc", target=npc_id,
                new_value="removed", request=request)
        return {"ok": True, "npc_id": npc_id}

    @app.get("/admin/maps")
    async def admin_maps(account: dict = Depends(require_permission(
            "map.manage"))):
        """Map population, NPC counts and portal definitions."""
        from websocket_server import manager as ws_manager, npc_manager
        population: dict = {}
        for session in ws_manager.active_connections.values():
            if getattr(session, "disconnected", True):
                continue
            key = getattr(session, "map_id", "")
            population[key] = population.get(key, 0) + 1
        npc_counts: dict = {}
        for npc in npc_manager.npcs.values():
            key = getattr(npc, "map_id", "")
            npc_counts[key] = npc_counts.get(key, 0) + 1

        out = []
        for map_id, info in game_data.MAPS.items():
            out.append({
                "map_id": map_id,
                "name": info.get("name", map_id),
                "min_level": int(info.get("min_level", 1)),
                "company": info.get("company", ""),
                "players": population.get(map_id, 0),
                "npcs": npc_counts.get(map_id, 0),
                "portals": game_data.portals_from(map_id),
            })
        return {"maps": out, "total": len(out),
                "portals": [p for m in out for p in m["portals"]]}

    # =======================================================================
    # Quests / gates
    # =======================================================================
    @app.get("/admin/quests")
    async def admin_quests(account: dict = Depends(require_permission(
            "quest.manage"))):
        """Quest definitions plus the progress of the players who have any."""
        from routes_p45 import QUEST_DEFINITIONS
        async with aiosqlite.connect(_db()) as db:
            players = []
            active = await (await db.execute(
                "SELECT DISTINCT player_id FROM quest_progress "
                "WHERE state = 'active' LIMIT 50")).fetchall()
            for r in active:
                rows = await (await db.execute(
                    "SELECT quest_id, state, progress, target "
                    "FROM quest_progress WHERE player_id = ?",
                    (r[0],))).fetchall()
                players.append({
                    "player_id": r[0],
                    "quests": [{"quest_id": q, "state": s,
                                "progress": int(p), "target": int(t)}
                               for q, s, p, t in rows],
                })
        return {"definitions": [{"quest_id": q, **info}
                                for q, info in QUEST_DEFINITIONS.items()],
                "players": players}

    @app.post("/admin/player/{identifier}/quest")
    async def admin_quest_action(identifier: str, req: QuestAdminAction,
                                 request: Request,
                                 account: dict = Depends(require_permission(
                                     "quest.manage"))):
        """Complete, reset or top up a quest for one player.

        `complete` inserts into `quest_rewards`, whose PRIMARY KEY keeps the
        reward single-claim even if an admin forces completion twice.
        """
        from routes_p45 import QUEST_DEFINITIONS, _grant_currency
        definition = QUEST_DEFINITIONS.get(req.quest_id)
        if definition is None:
            raise HTTPException(status_code=404, detail="Unknown quest")
        action = str(req.action).strip().lower()
        if action not in ("complete", "reset", "progress"):
            raise HTTPException(status_code=400,
                                detail={"reason": "unknown_action",
                                        "action": req.action})
        new_value = {}

        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            old = await (await db.execute(
                "SELECT state, progress FROM quest_progress "
                "WHERE player_id = ? AND quest_id = ?",
                (player["player_id"], req.quest_id))).fetchone()
            old_value = ({"state": old[0], "progress": int(old[1])}
                         if old else {})

            if action == "reset":
                await db.execute(
                    "DELETE FROM quest_progress WHERE player_id = ? "
                    "AND quest_id = ?", (player["player_id"], req.quest_id))
                await db.execute(
                    "DELETE FROM quest_rewards WHERE player_id = ? "
                    "AND quest_id = ?", (player["player_id"], req.quest_id))
                new_value = {"state": "locked", "progress": 0}
            elif action == "progress":
                amount = _clamp(req.amount, 0, 1_000_000, "amount")
                await db.execute(
                    "INSERT INTO quest_progress (player_id, quest_id, state, "
                    "progress, target, updated_at) "
                    "VALUES (?, ?, 'active', ?, ?, ?) "
                    "ON CONFLICT(player_id, quest_id) DO UPDATE SET progress = "
                    "MIN(quest_progress.target, "
                    "quest_progress.progress + ?), "
                    "updated_at = excluded.updated_at",
                    (player["player_id"], req.quest_id, amount,
                     int(definition["target"]), _now(), amount))
                row = await (await db.execute(
                    "SELECT state, progress FROM quest_progress "
                    "WHERE player_id = ? AND quest_id = ?",
                    (player["player_id"], req.quest_id))).fetchone()
                new_value = {"state": row[0], "progress": int(row[1])}
            else:
                await db.execute(
                    "INSERT INTO quest_progress (player_id, quest_id, state, "
                    "progress, target, completed_at, updated_at) "
                    "VALUES (?, ?, 'completed', ?, ?, ?, ?) "
                    "ON CONFLICT(player_id, quest_id) DO UPDATE SET "
                    "state = 'completed', progress = quest_progress.target, "
                    "completed_at = excluded.completed_at",
                    (player["player_id"], req.quest_id,
                     int(definition["target"]), int(definition["target"]),
                     _now(), _now()))
                reward = definition.get("reward", {})
                try:
                    await db.execute(
                        "INSERT INTO quest_rewards (player_id, quest_id, btc, "
                        "plt, xp, honor, granted_at) "
                        "VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (player["player_id"], req.quest_id,
                         int(reward.get("btc", 0)), int(reward.get("plt", 0)),
                         int(reward.get("xp", 0)), int(reward.get("honor", 0)),
                         _now()))
                    await _grant_currency(
                        db, player["player_id"],
                        btc=int(reward.get("btc", 0)),
                        plt=int(reward.get("plt", 0)), reason="admin_quest")
                except aiosqlite.IntegrityError:
                    # The unique key did its job: the reward was already paid.
                    pass
                new_value = {"state": "completed", "reward": reward}
            await admin_core.write_audit(
                db, account, "quest." + action,
                target=player["username"] + "/" + req.quest_id,
                old_value=old_value, new_value=new_value, reason=req.reason,
                request=request)
            await db.commit()
        return {"ok": True, "action": action, "quest_id": req.quest_id}

    # =======================================================================
    # Galaxy Gates
    # =======================================================================
    @app.get("/admin/gates")
    async def admin_gates(account: dict = Depends(require_permission(
            "gate.manage"))):
        """Gate definitions and per-player progress."""
        import json as _json
        async with aiosqlite.connect(_db()) as db:
            rows = await (await db.execute(
                "SELECT player_id, gate_id, parts, state, completed_at "
                "FROM player_gates ORDER BY updated_at DESC LIMIT 200")).fetchall()
        out = []
        for r in rows:
            try:
                parts = _json.loads(r[2]) or {}
            except (TypeError, ValueError):
                parts = {}
            out.append({"player_id": r[0], "gate_id": r[1], "parts": parts,
                        "state": r[3], "completed_at": int(r[4])})
        return {"definitions": gate_service.gate_definitions(), "progress": out,
                "reward": gate_service.GATE_COMPLETION_REWARD}

    @app.post("/admin/player/{identifier}/gate")
    async def admin_gate_action(identifier: str, req: GateAdminAction,
                                request: Request,
                                account: dict = Depends(require_permission(
                                    "gate.manage"))):
        """Reset or force-complete a gate.

        Force-complete uses the same conditional transition as normal
        completion, so it still cannot pay twice, and it deliberately does NOT
        grant the completion reward: an admin forcing a gate open is repairing
        state, not handing out currency.
        """
        import json as _json
        if req.gate_id not in game_data.GATE_PART_DEFINITIONS:
            raise HTTPException(status_code=404, detail="Unknown gate")
        action = str(req.action).strip().lower()
        if action not in ("reset", "complete"):
            raise HTTPException(status_code=400,
                                detail={"reason": "unknown_action",
                                        "action": req.action})

        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            old = await gate_service.read_gate(db, player["player_id"],
                                               req.gate_id)
            if action == "reset":
                result = await gate_service.reset_gate(
                    db, player["player_id"], req.gate_id)
            else:
                cursor = await db.execute(
                    "INSERT INTO player_gates (player_id, gate_id, parts, "
                    "state, completed_at, updated_at) "
                    "VALUES (?, ?, ?, 'completed', ?, ?) "
                    "ON CONFLICT(player_id, gate_id) DO UPDATE SET "
                    "state = 'completed', completed_at = excluded.completed_at "
                    "WHERE player_gates.state != 'completed'",
                    (player["player_id"], req.gate_id,
                     _json.dumps(old["parts"]), _now(), _now()))
                await db.commit()
                result = {"gate_id": req.gate_id, "state": "completed",
                          "changed": cursor.rowcount > 0}
            await admin_core.write_audit(
                db, account, "gate." + action,
                target=player["username"] + "/" + req.gate_id,
                old_value=old, new_value=result, reason=req.reason,
                request=request)
            await db.commit()
        await push_admin_state(player["player_id"], {"gate": result})
        return {"ok": True, "action": action, **result}

    # =======================================================================
    # Clan / squad
    # =======================================================================
    @app.get("/admin/clans")
    async def admin_clans(account: dict = Depends(require_permission(
            "clan.view"))):
        async with aiosqlite.connect(_db()) as db:
            clans = await (await db.execute(
                "SELECT clan_id, name, leader_player_id, created_at "
                "FROM clans ORDER BY created_at DESC LIMIT 200")).fetchall()
            members = await (await db.execute(
                "SELECT clan_id, player_id, role FROM clan_members "
                "LIMIT 1000")).fetchall()
            applications = await (await db.execute(
                "SELECT application_id, clan_id, player_id, created_at "
                "FROM clan_applications ORDER BY created_at DESC "
                "LIMIT 200")).fetchall()
        by_clan: dict = {}
        for c_id, p_id, role in members:
            by_clan.setdefault(c_id, []).append({"player_id": p_id,
                                                 "role": role})
        return {
            "clans": [{"clan_id": c[0], "name": c[1], "leader": c[2],
                       "created_at": int(c[3]),
                       "members": by_clan.get(c[0], []),
                       "member_count": len(by_clan.get(c[0], []))}
                      for c in clans],
            "applications": [{"id": int(a[0]), "clan_id": a[1],
                              "player_id": a[2], "created_at": int(a[3])}
                             for a in applications],
        }

    @app.post("/admin/clans/{clan_id}/remove-member")
    async def admin_clan_remove_member(clan_id: str, request: Request,
                                       player_id: str = "",
                                       account: dict = Depends(
                                           require_permission("clan.manage"))):
        """Remove one member. Superadmin-only via the `clan.manage` grant."""
        async with aiosqlite.connect(_db()) as db:
            row = await (await db.execute(
                "SELECT clan_id FROM clan_members WHERE clan_id = ? "
                "AND player_id = ?", (clan_id, player_id))).fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Member not found")
            await db.execute(
                "DELETE FROM clan_members WHERE clan_id = ? AND player_id = ?",
                (clan_id, player_id))
            await admin_core.write_audit(
                db, account, "clan.remove_member", target_type="clan",
                target=clan_id, new_value=player_id, request=request)
            await db.commit()
        return {"ok": True, "clan_id": clan_id, "player_id": player_id}

    @app.post("/admin/clans/{clan_id}/disband")
    async def admin_clan_disband(clan_id: str, req: BroadcastRequest,
                                 request: Request,
                                 account: dict = Depends(require_permission(
                                     "clan.manage"))):
        async with aiosqlite.connect(_db()) as db:
            row = await (await db.execute(
                "SELECT name FROM clans WHERE clan_id = ?", (clan_id,))).fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Clan not found")
            await db.execute("DELETE FROM clan_members WHERE clan_id = ?",
                             (clan_id,))
            await db.execute("DELETE FROM clans WHERE clan_id = ?", (clan_id,))
            await admin_core.write_audit(
                db, account, "clan.disband", target_type="clan", target=clan_id,
                old_value=row[0], reason=req.reason, request=request)
            await db.commit()
        return {"ok": True, "clan_id": clan_id}

    @app.get("/admin/squads")
    async def admin_squads(account: dict = Depends(require_permission(
            "squad.view"))):
        async with aiosqlite.connect(_db()) as db:
            squads = await (await db.execute(
                "SELECT squad_id, name, leader_player_id, created_at "
                "FROM squads ORDER BY created_at DESC LIMIT 200")).fetchall()
            members = await (await db.execute(
                "SELECT squad_id, player_id, role FROM squad_members "
                "LIMIT 1000")).fetchall()
        by_squad: dict = {}
        for s_id, p_id, role in members:
            by_squad.setdefault(s_id, []).append({"player_id": p_id,
                                                  "role": role})
        return {"squads": [{"squad_id": s[0], "name": s[1], "leader": s[2],
                            "created_at": int(s[3]),
                            "members": by_squad.get(s[0], [])}
                           for s in squads]}

    @app.post("/admin/squads/{squad_id}/dissolve")
    async def admin_squad_dissolve(squad_id: str, req: BroadcastRequest,
                                   request: Request,
                                   account: dict = Depends(require_permission(
                                       "squad.manage"))):
        async with aiosqlite.connect(_db()) as db:
            row = await (await db.execute(
                "SELECT name FROM squads WHERE squad_id = ?",
                (squad_id,))).fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Squad not found")
            await db.execute("DELETE FROM squad_members WHERE squad_id = ?",
                             (squad_id,))
            await db.execute("DELETE FROM squads WHERE squad_id = ?", (squad_id,))
            await admin_core.write_audit(
                db, account, "squad.dissolve", target_type="squad",
                target=squad_id, old_value=row[0], reason=req.reason,
                request=request)
            await db.commit()
        return {"ok": True, "squad_id": squad_id}

    # =======================================================================
    # Auctions
    # =======================================================================
    @app.get("/admin/auctions")
    async def admin_auctions(state: str = "",
                             account: dict = Depends(require_permission(
                                 "auction.view"))):
        """Auctions by state: open, settled, cancelled or all."""
        limit = 200
        async with aiosqlite.connect(_db()) as db:
            if state:
                rows = await (await db.execute(
                    "SELECT auction_id, seller_player_id, item_id, quantity, "
                    "currency, current_price, highest_bidder, state, "
                    "created_at, ends_at FROM auctions WHERE state = ? "
                    "ORDER BY ends_at DESC LIMIT ?", (state, limit))).fetchall()
            else:
                rows = await (await db.execute(
                    "SELECT auction_id, seller_player_id, item_id, quantity, "
                    "currency, current_price, highest_bidder, state, "
                    "created_at, ends_at FROM auctions "
                    "ORDER BY ends_at DESC LIMIT ?", (limit,))).fetchall()
        return {"auctions": [
            {"auction_id": int(r[0]), "seller": r[1], "item_id": r[2],
             "quantity": int(r[3]), "currency": r[4],
             "price": int(r[5]), "highest_bidder": r[6] or "",
             "state": r[7], "created_at": int(r[8]), "ends_at": int(r[9]),
             "expired": bool(r[7] == "open" and int(r[9]) <= _now())}
            for r in rows]}

    @app.post("/admin/auctions/{auction_id}/settle")
    async def admin_auction_settle(auction_id: int, request: Request,
                                    account: dict = Depends(require_permission(
                                        "auction.manage"))):
        """Force-settle one auction.

        Calls the same `schedulers.settle_one_auction` the background sweep
        uses, so a forced settlement and an automatic one are indistinguishable
        - including the single-winner guard that stops a double payout.
        """
        async with aiosqlite.connect(_db()) as db:
            row = await (await db.execute(
                "SELECT state FROM auctions WHERE auction_id = ?",
                (auction_id,))).fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Auction not found")
            if row[0] != "open":
                raise HTTPException(
                    status_code=409,
                    detail={"reason": "not_open", "state": row[0]})
            settled = await schedulers.settle_one_auction(db, auction_id)
            await admin_core.write_audit(
                db, account, "auction.settle", target_type="auction",
                target=auction_id, new_value=bool(settled), request=request)
        return {"ok": bool(settled), "auction_id": auction_id}

    @app.post("/admin/auctions/{auction_id}/cancel")
    async def admin_auction_cancel(auction_id: int, req: AuctionCancel,
                                   request: Request,
                                   account: dict = Depends(require_permission(
                                       "auction.manage"))):
        """Cancel an auction and return the escrowed item to the seller.

        Refunds any bidder the same way settlement does, so cancellation is
        not a way to confiscate escrowed funds.
        """
        async with aiosqlite.connect(_db()) as db:
            row = await (await db.execute(
                "SELECT seller_player_id, item_id, quantity, currency, "
                "highest_bidder, state FROM auctions WHERE auction_id = ?",
                (auction_id,))).fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Auction not found")
            if row[5] != "open":
                raise HTTPException(
                    status_code=409,
                    detail={"reason": "not_open", "state": row[5]})
            cursor = await db.execute(
                "UPDATE auctions SET state = 'cancelled' WHERE auction_id = ? "
                "AND state = 'open'", (auction_id,))
            if cursor.rowcount == 0:
                raise HTTPException(status_code=409, detail="Already settled")
            await schedulers._refund_outbid(db, auction_id,
                                            str(row[4]), str(row[3]))
            await _grant_item(db, str(row[0]), str(row[1]), int(row[2]))
            await admin_core.write_audit(
                db, account, "auction.cancel", target_type="auction",
                target=auction_id, old_value="open", new_value="cancelled",
                reason=req.reason, request=request)
            await db.commit()
        return {"ok": True, "auction_id": auction_id}

    # =======================================================================
    # Server events
    # =======================================================================
    @app.get("/admin/events")
    async def admin_events(account: dict = Depends(require_permission(
            "event.view"))):
        """Every event with its state DERIVED from its window, not cached."""
        async with aiosqlite.connect(_db()) as db:
            rows = await (await db.execute(
                "SELECT event_id, name, map_id, starts_at, ends_at, state, "
                "reward_btc, reward_plt, reward_xp, reward_honor "
                "FROM server_events ORDER BY starts_at DESC LIMIT 200")).fetchall()
        now = _now()
        out = []
        for r in rows:
            derived = schedulers.derived_event_state((r[0], r[3], r[4], r[5]),
                                                     now)
            out.append({
                "event_id": r[0], "name": r[1], "map_id": r[2],
                "starts_at": int(r[3]), "ends_at": int(r[4]),
                "stored_state": r[5], "state": derived,
                "reward": {"btc": int(r[6]), "plt": int(r[7]),
                           "xp": int(r[8]), "honor": int(r[9])},
            })
        return {"events": out}

    @app.post("/admin/events")
    async def admin_event_upsert(req: EventUpsert, request: Request,
                                 account: dict = Depends(require_permission(
                                     "event.manage"))):
        """Create or edit an event.

        The stored state is recomputed from the window on every read, so
        writing `scheduled` here cannot pin an event to a wrong state: the
        scheduler and the panel's own view can never disagree.
        """
        if not req.event_id.strip() or not req.name.strip():
            raise HTTPException(status_code=400,
                                detail={"reason": "event_id_and_name_required"})
        async with aiosqlite.connect(_db()) as db:
            old = await (await db.execute(
                "SELECT name, map_id, starts_at, ends_at, state, reward_btc, "
                "reward_plt, reward_xp, reward_honor FROM server_events "
                "WHERE event_id = ?", (req.event_id,))).fetchone()
            # `server_events` has no created_at/updated_at columns; the
            # lifecycle is expressed entirely through starts_at / ends_at and
            # the derived state, so nothing here writes a timestamp.
            await db.execute(
                "INSERT INTO server_events (event_id, name, map_id, state, "
                "starts_at, ends_at, reward_btc, reward_plt, reward_xp, "
                "reward_honor) VALUES (?, ?, ?, 'scheduled', ?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(event_id) DO UPDATE SET name = excluded.name, "
                "map_id = excluded.map_id, starts_at = excluded.starts_at, "
                "ends_at = excluded.ends_at, reward_btc = excluded.reward_btc, "
                "reward_plt = excluded.reward_plt, reward_xp = excluded.reward_xp, "
                "reward_honor = excluded.reward_honor",
                (req.event_id, req.name, req.map_id, int(req.starts_at),
                 int(req.ends_at), int(req.reward_btc), int(req.reward_plt),
                 int(req.reward_xp), int(req.reward_honor)))
            await admin_core.write_audit(
                db, account, "event.upsert", target_type="event",
                target=req.event_id, old_value=old,
                new_value=req.model_dump(), reason=req.reason,
                request=request)
            await db.commit()
        return {"ok": True, "event_id": req.event_id, "created": old is None}

    @app.post("/admin/events/{event_id}/state")
    async def admin_event_state(event_id: str, req: ServerFlag, request: Request,
                                account: dict = Depends(require_permission(
                                    "event.manage"))):
        """Start or stop an event.

        `enabled = True` opens the window now (so the event is active);
        `enabled = False` closes it. Cancellation is not a separate flag here:
        a cancelled event is one whose stored state is 'cancelled', and
        `derived_event_state` keeps it that way, so it never re-opens itself.
        """
        now = _now()
        async with aiosqlite.connect(_db()) as db:
            row = await (await db.execute(
                "SELECT starts_at, ends_at, state FROM server_events "
                "WHERE event_id = ?", (event_id,))).fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Event not found")
            if req.enabled:
                starts, ends, state = min(int(row[0]) or now, now), 0, "active"
            else:
                starts, ends = int(row[0]), max(int(row[1]) or now, now)
                state = "finished"
            await db.execute(
                "UPDATE server_events SET starts_at = ?, ends_at = ?, "
                "state = ? WHERE event_id = ?",
                (starts, ends, state, event_id))
            await admin_core.write_audit(
                db, account, "event.state", target_type="event", target=event_id,
                old_value={"starts_at": int(row[0]), "ends_at": int(row[1]),
                           "state": row[2]},
                new_value={"starts_at": starts, "ends_at": ends,
                           "state": state},
                reason=req.reason, request=request)
            await db.commit()
        return {"ok": True, "event_id": event_id, "state": state}

    # =======================================================================
    # Roles and staff
    # =======================================================================
    @app.get("/admin/admins")
    async def admin_list_staff(account: dict = Depends(require_permission(
            "role.manage"))):
        """Everyone with staff, plus the role matrix for the picker."""
        async with aiosqlite.connect(_db()) as db:
            rows = await (await db.execute(
                "SELECT username, player_id, role, company, last_login "
                "FROM accounts WHERE role != 'player' "
                "ORDER BY role, username")).fetchall()
        return {
            "staff": [{"username": r[0], "player_id": r[1], "role": r[2],
                       "company": r[3] or "", "last_login": int(r[4] or 0)}
                      for r in rows],
            "roles": [{"role": r, "rank": admin_core.role_rank(r),
                       "permissions": admin_core.permissions_for(r)}
                      for r in admin_core.ROLE_ORDER],
        }

    @app.put("/admin/player/{identifier}/role")
    async def admin_set_role(identifier: str, req: RoleChange, request: Request,
                             account: dict = Depends(require_permission(
                                 "role.manage"))):
        """Assign or change a role.

        Two guards make escalation impossible:
          1. THE ACTOR MUST OUTRANK THE ROLE BEING ASSIGNED. A moderator
             cannot make anybody an admin, and an admin cannot make anybody a
             superadmin. Only a superadmin can grant superadmin.
          2. THE ACTOR CANNOT CHANGE THEIR OWN ROLE, so an admin can never
             promote themselves - even to a role they already outrank.
        """
        role = str(req.role).strip().lower()
        if role not in admin_core.VALID_ROLES:
            raise HTTPException(
                status_code=400,
                detail={"reason": "invalid_role", "role": req.role,
                        "allowed": sorted(admin_core.VALID_ROLES)})
        actor_role = str(account.get("role", "player"))
        actor_rank = admin_core.role_rank(actor_role)
        target_rank = admin_core.role_rank(role)
        if actor_rank < target_rank:
            raise HTTPException(
                status_code=403,
                detail={"reason": "cannot_assign_role", "actor": actor_role,
                        "requested": role,
                        "rule": "you may only assign roles at or below your own"})

        async with aiosqlite.connect(_db()) as db:
            player = await resolve_player(db, identifier)
            if int(player["id"]) == int(account["id"]):
                raise HTTPException(
                    status_code=403,
                    detail={"reason": "cannot_change_own_role",
                            "rule": "role escalation requires another "
                                    "superadmin"})
            await db.execute("UPDATE accounts SET role = ? WHERE id = ?",
                             (role, player["id"]))
            await journal.record_event(
                db, player["player_id"], journal.EVENT_SYSTEM,
                f"Rol degistirildi: {player['role']} -> {role}",
                journal.SEVERITY_IMPORTANT,
                {"admin": account["username"], "reason": req.reason})
            await admin_core.write_audit(
                db, account, "role.change", target=player["username"],
                old_value=player["role"], new_value=role, reason=req.reason,
                request=request)
            await db.commit()

        # Live permission refresh: an online moderator sees the new panel
        # without needing to log out and back in.
        await push_admin_state(
            player["player_id"],
            {"role": role, "permissions": admin_core.permissions_for(role)})
        return {"ok": True, "username": player["username"], "role": role,
                "old": player["role"]}

    # =======================================================================
    # Audit log (read-only, append-only)
    # =======================================================================
    @app.get("/admin/audit")
    async def admin_audit(limit: int = 100, action: str = "", admin: str = "",
                          account: dict = Depends(require_permission(
                              "audit.view"))):
        """Read the audit trail.

        There is deliberately NO update or delete endpoint: triggers on the
        table abort both operations, so this trail cannot be rewritten by
        anyone, including a superadmin.
        """
        limit = _clamp(limit, 1, 1000, "limit")
        clauses, params = [], []
        if action:
            clauses.append("action LIKE ?")
            params.append(action + "%")
        if admin:
            clauses.append("admin_username = ?")
            params.append(admin)
        where = (" WHERE " + " AND ".join(clauses)) if clauses else ""
        async with aiosqlite.connect(_db()) as db:
            rows = await (await db.execute(
                "SELECT id, timestamp, admin_username, admin_role, action, "
                "target_type, target, old_value, new_value, reason, result, "
                "remote_addr FROM admin_audit_log" + where +
                " ORDER BY id DESC LIMIT ?",
                params + [limit])).fetchall()
        return {"entries": [
            {"id": int(r[0]), "timestamp": int(r[1]), "admin": r[2],
             "role": r[3], "action": r[4], "target_type": r[5],
             "target": r[6], "old_value": r[7], "new_value": r[8],
             "reason": r[9], "result": r[10], "remote_addr": r[11]}
            for r in rows], "count": len(rows)}

    @app.get("/admin/permissions")
    async def admin_permissions(account: dict = Depends(require_permission(
            "server.dashboard"))):
        """The whole matrix, so the panel can render read-only explanations."""
        return {
            "matrix": [{"role": role, "rank": admin_core.role_rank(role),
                        "permissions": sorted(perms)}
                       for role, perms in admin_core.ROLE_PERMISSIONS.items()],
            "all": list(admin_core.PERMISSIONS),
        }
# __APPEND__

