"""Phase 6-7 routes: clan, squad, chat, settings, auction, events, cargo.

Server authority notes:

* Chat is PERSISTED before it is broadcast, and the broadcast is a thin relay
  of the stored row. There is no client-only chat path any more.
* Auction settlement runs inside one transaction and is guarded by the
  auction's own `state`, so a bid arriving after settlement cannot pay twice.
* Cargo capacity is enforced server-side; `items` is a JSON id->quantity map
  using the canonical item ids.
"""

from __future__ import annotations

import json
import time
import uuid
from typing import Optional

import aiosqlite
from fastapi import Depends, HTTPException
from pydantic import BaseModel, Field

import game_data
import journal
import player_state
from item_catalog import normalize_inventory, normalize_item_id
from routes_p45 import _grant_currency, _grant_item, _now


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CLAN_NAME_MIN = 3
CLAN_NAME_MAX = 24
CLAN_TAG_MAX = 6
CLAN_MAX_MEMBERS = 50

CHAT_MAX_LENGTH = 240
# A simple per-player rate limit, matching the project's existing limiter style.
CHAT_MIN_INTERVAL_SECONDS = 1.0

# The channels the project's chat UI already exposes, plus the two social ones
# Phase 6 adds. A channel outside this set is rejected, so a client cannot
# invent an unbounded channel namespace.
CHAT_CHANNELS = (
    "global_tr", "global_en", "clan", "squad", "system",
)


def _clean_channel(raw: object) -> str:
    """Normalise a channel name, returning "" when it is not a known channel."""
    text = str(raw or "").strip().lower()
    return text if text in CHAT_CHANNELS else ""

AUCTION_MIN_SECONDS = 30
AUCTION_MAX_SECONDS = 7 * 24 * 3600
AUCTION_FEE_PERCENT = 5

CARGO_DEFAULT_CAPACITY = 100


# ---------------------------------------------------------------------------
# Request models
# ---------------------------------------------------------------------------
class ClanCreateRequest(BaseModel):
    name: str
    tag: str = ""


class ClanApplyRequest(BaseModel):
    clan_id: int
    message: str = ""


class ClanReviewRequest(BaseModel):
    application_id: int
    approve: bool


class DiplomacyRequest(BaseModel):
    other_clan_id: int
    relation: str


class SquadCreateRequest(BaseModel):
    pass_empty: bool = True


class ChatSendRequest(BaseModel):
    channel: str
    body: str


class SettingsUpdateRequest(BaseModel):
    nickname: Optional[str] = None
    chat_channel: Optional[str] = None
    hud_visible: Optional[bool] = None
    show_damage: Optional[bool] = None


class AuctionCreateRequest(BaseModel):
    item_id: str
    quantity: int = 1
    currency: str = "BTC"
    start_price: int = 1
    buyout_price: int = 0
    duration_seconds: int = 3600


class AuctionBidRequest(BaseModel):
    auction_id: int
    amount: int


class CargoUpdateRequest(BaseModel):
    item_id: str
    quantity: int


class CargoDepositRequest(BaseModel):
    item_id: str
    quantity: int


class EventJoinRequest(BaseModel):
    event_id: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
async def _clan_of(db, player_id: str) -> Optional[dict]:
    cursor = await db.execute(
        "SELECT c.clan_id, c.name, c.tag, c.owner_player_id, m.role "
        "FROM clan_members m JOIN clans c ON c.clan_id = m.clan_id "
        "WHERE m.player_id = ?",
        (player_id,),
    )
    row = await cursor.fetchone()
    if row is None:
        return None
    return {"clan_id": int(row[0]), "name": row[1], "tag": row[2],
            "owner_player_id": row[3], "role": row[4]}


async def _squad_of(db, player_id: str) -> Optional[dict]:
    cursor = await db.execute(
        "SELECT s.squad_id, s.leader_player_id FROM squad_members m "
        "JOIN squads s ON s.squad_id = m.squad_id WHERE m.player_id = ?",
        (player_id,),
    )
    row = await cursor.fetchone()
    if row is None:
        return None
    return {"squad_id": int(row[0]), "leader_player_id": row[1]}


async def _cargo(db, player_id: str) -> dict:
    await db.execute(
        "INSERT OR IGNORE INTO cargo (player_id, capacity, items, updated_at) "
        "VALUES (?, ?, '{}', ?)",
        (player_id, CARGO_DEFAULT_CAPACITY, _now()),
    )
    cursor = await db.execute(
        "SELECT capacity, items FROM cargo WHERE player_id = ?", (player_id,)
    )
    row = await cursor.fetchone()
    try:
        items = json.loads(row[1]) if row and row[1] else {}
    except (TypeError, ValueError):
        items = {}
    if not isinstance(items, dict):
        items = {}
    return {"capacity": int(row[0]) if row else CARGO_DEFAULT_CAPACITY,
            "items": normalize_inventory(items),
            "used": sum(int(v) for v in items.values())}


async def _escrow(db, player_id: str, currency: str, amount: int,
                  reason: str) -> bool:
    """Move `amount` of `currency` out of a balance. False when short.

    The read and the write happen in the caller's transaction, so an auction
    bid and its escrow commit together or not at all.
    """
    column = {"BTC": "btc", "PLT": "plt", "GOLD": "gold"}.get(
        str(currency).upper())
    if column is None:
        return False
    cursor = await db.execute(
        f"SELECT {column} FROM economy WHERE player_id = ?", (player_id,)
    )
    row = await cursor.fetchone()
    balance = int(row[0]) if row else 0
    if balance < int(amount):
        return False
    await db.execute(
        f"UPDATE economy SET {column} = {column} - ?, updated_at = ? "
        f"WHERE player_id = ?",
        (int(amount), _now(), player_id),
    )
    await db.execute(
        "INSERT INTO transactions (player_id, currency, amount, reason, "
        "timestamp) VALUES (?, ?, ?, ?, ?)",
        (player_id, str(currency).upper(), -int(amount), reason, _now()),
    )
    return True

def register_routes(app, get_current_account, db_path_provider) -> None:

    def _db() -> str:
        return db_path_provider()

    # -----------------------------------------------------------------------
    # Clan
    # -----------------------------------------------------------------------
    @app.post("/clans")
    async def post_clan(req: ClanCreateRequest,
                        account: dict = Depends(get_current_account)):
        name = " ".join(str(req.name).strip().split())
        tag = str(req.tag).strip().upper()[:CLAN_TAG_MAX]
        if not CLAN_NAME_MIN <= len(name) <= CLAN_NAME_MAX:
            raise HTTPException(status_code=400, detail="Invalid clan name")
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            if await _clan_of(db, player_id) is not None:
                raise HTTPException(status_code=409,
                                    detail="Already in a clan")
            cursor = await db.execute(
                "SELECT clan_id FROM clans WHERE name = ? OR tag = ?",
                (name, tag),
            )
            if await cursor.fetchone() is not None:
                raise HTTPException(status_code=409,
                                    detail="Clan name or tag taken")
            cur = await db.execute(
                "INSERT INTO clans (name, tag, owner_player_id, created_at) "
                "VALUES (?, ?, ?, ?)",
                (name, tag, player_id, _now()),
            )
            clan_id = cur.lastrowid
            await db.execute(
                "INSERT INTO clan_members (clan_id, player_id, role, joined_at) "
                "VALUES (?, ?, 'owner', ?)",
                (clan_id, player_id, _now()),
            )
            await journal.record_event(
                db, player_id, journal.EVENT_CLAN,
                f"Klan olusturuldu: {name}", journal.SEVERITY_GOOD,
                {"clan_id": clan_id, "name": name},
            )
            await db.commit()
        return {"ok": True, "clan_id": clan_id, "name": name, "tag": tag}

    @app.get("/clans/mine")
    async def get_my_clan(account: dict = Depends(get_current_account)):
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            clan = await _clan_of(db, player_id)
            if clan is None:
                return {"clan": None}
            cursor = await db.execute(
                "SELECT player_id, role, rank, joined_at FROM clan_members "
                "WHERE clan_id = ? ORDER BY joined_at",
                (clan["clan_id"],),
            )
            members = [{"player_id": r[0], "role": r[1], "rank": int(r[2]),
                        "joined_at": int(r[3])} for r in await cursor.fetchall()]
            cursor = await db.execute(
                "SELECT other_clan_id, relation FROM clan_diplomacy "
                "WHERE clan_id = ?",
                (clan["clan_id"],),
            )
            diplomacy = [{"other_clan_id": int(r[0]), "relation": r[1]}
                         for r in await cursor.fetchall()]
        return {"clan": clan, "members": members, "diplomacy": diplomacy}

    @app.post("/clans/apply")
    async def post_apply(req: ClanApplyRequest,
                         account: dict = Depends(get_current_account)):
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            if await _clan_of(db, player_id) is not None:
                raise HTTPException(status_code=409, detail="Already in a clan")
            cursor = await db.execute(
                "SELECT COUNT(*) FROM clan_members WHERE clan_id = ?",
                (req.clan_id,),
            )
            if (await cursor.fetchone())[0] >= CLAN_MAX_MEMBERS:
                raise HTTPException(status_code=409, detail="Clan is full")
            await db.execute(
                "INSERT INTO clan_applications (clan_id, player_id, message, "
                "state, created_at) VALUES (?, ?, ?, 'pending', ?) "
                "ON CONFLICT(clan_id, player_id) DO UPDATE SET "
                "state = 'pending', message = excluded.message",
                (req.clan_id, player_id, str(req.message)[:200], _now()),
            )
            await db.commit()
        return {"ok": True, "clan_id": req.clan_id, "state": "pending"}

    @app.get("/clans/applications")
    async def get_applications(account: dict = Depends(get_current_account)):
        """Pending applications for the caller's own clan."""
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            clan = await _clan_of(db, player_id)
            if clan is None:
                raise HTTPException(status_code=404, detail="Not in a clan")
            if clan["role"] not in ("owner", "officer"):
                raise HTTPException(status_code=403,
                                    detail="Officer rank required")
            cursor = await db.execute(
                "SELECT id, player_id, message, state, created_at "
                "FROM clan_applications WHERE clan_id = ? AND state = 'pending' "
                "ORDER BY created_at",
                (clan["clan_id"],),
            )
            rows = [{"application_id": int(r[0]), "player_id": r[1],
                     "message": r[2], "state": r[3], "created_at": int(r[4])}
                    for r in await cursor.fetchall()]
        return {"applications": rows, "count": len(rows)}

    @app.post("/clans/applications/review")
    async def post_review(req: ClanReviewRequest,
                          account: dict = Depends(get_current_account)):
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            clan = await _clan_of(db, player_id)
            if clan is None or clan["role"] not in ("owner", "officer"):
                raise HTTPException(status_code=403,
                                    detail="Officer rank required")
            cursor = await db.execute(
                "SELECT id, clan_id, player_id, state FROM clan_applications "
                "WHERE id = ?",
                (req.application_id,),
            )
            row = await cursor.fetchone()
            if row is None or int(row[1]) != int(clan["clan_id"]):
                raise HTTPException(status_code=404, detail="Unknown application")
            if row[3] != "pending":
                raise HTTPException(status_code=409, detail="Already reviewed")
            if req.approve:
                cursor = await db.execute(
                    "SELECT COUNT(*) FROM clan_members WHERE clan_id = ?",
                    (clan["clan_id"],),
                )
                if (await cursor.fetchone())[0] >= CLAN_MAX_MEMBERS:
                    raise HTTPException(status_code=409, detail="Clan is full")
                await db.execute(
                    "INSERT OR IGNORE INTO clan_members (clan_id, player_id, "
                    "role, joined_at) VALUES (?, ?, 'member', ?)",
                    (clan["clan_id"], row[2], _now()),
                )
            await db.execute(
                "UPDATE clan_applications SET state = ? WHERE id = ?",
                ("approved" if req.approve else "rejected",
                 req.application_id),
            )
            await journal.record_event(
                db, row[2], journal.EVENT_CLAN,
                "Klan basvurusu "
                + ("onaylandi" if req.approve else "reddedildi"),
                journal.SEVERITY_INFO, {"clan_id": int(clan["clan_id"])},
            )
            await db.commit()
        return {"ok": True, "application_id": req.application_id,
                "approved": req.approve}

    @app.post("/clans/leave")
    async def post_leave(account: dict = Depends(get_current_account)):
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            clan = await _clan_of(db, player_id)
            if clan is None:
                raise HTTPException(status_code=404, detail="Not in a clan")
            await db.execute(
                "DELETE FROM clan_members WHERE clan_id = ? AND player_id = ?",
                (clan["clan_id"], player_id),
            )
            if clan["owner_player_id"] == player_id:
                # An empty clan is removed; an owner leaving promotes the
                # longest-standing member rather than orphaning the roster.
                cursor = await db.execute(
                    "SELECT player_id FROM clan_members WHERE clan_id = ? "
                    "ORDER BY joined_at LIMIT 1",
                    (clan["clan_id"],),
                )
                nxt = await cursor.fetchone()
                if nxt is None:
                    await db.execute("DELETE FROM clans WHERE clan_id = ?",
                                     (clan["clan_id"],))
                else:
                    await db.execute(
                        "UPDATE clan_members SET role = 'owner' "
                        "WHERE clan_id = ? AND player_id = ?",
                        (clan["clan_id"], nxt[0]),
                    )
                    await db.execute(
                        "UPDATE clans SET owner_player_id = ? WHERE clan_id = ?",
                        (nxt[0], clan["clan_id"]),
                    )
            await db.commit()
        return {"ok": True, "left": clan["name"]}

    @app.post("/clans/diplomacy")
    async def post_diplomacy(req: DiplomacyRequest,
                              account: dict = Depends(get_current_account)):
        relation = str(req.relation).strip().lower()
        if relation not in ("ally", "enemy", "neutral"):
            raise HTTPException(status_code=400, detail="Invalid relation")
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            clan = await _clan_of(db, player_id)
            if clan is None:
                raise HTTPException(status_code=404, detail="Not in a clan")
            if clan["role"] not in ("owner", "officer"):
                raise HTTPException(status_code=403,
                                    detail="Officer rank required")
            if int(req.other_clan_id) == int(clan["clan_id"]):
                raise HTTPException(status_code=400,
                                    detail="Cannot target your own clan")
            cursor = await db.execute(
                "SELECT clan_id FROM clans WHERE clan_id = ?",
                (req.other_clan_id,),
            )
            if await cursor.fetchone() is None:
                raise HTTPException(status_code=404, detail="Unknown clan")
            # Stored on BOTH rows so a lookup is symmetric.
            for a, b in ((clan["clan_id"], req.other_clan_id),
                         (req.other_clan_id, clan["clan_id"])):
                await db.execute(
                    "INSERT INTO clan_diplomacy (clan_id, other_clan_id, "
                    "relation, updated_at) VALUES (?, ?, ?, ?) "
                    "ON CONFLICT(clan_id, other_clan_id) DO UPDATE SET "
                    "relation = excluded.relation, "
                    "updated_at = excluded.updated_at",
                    (a, b, relation, _now()),
                )
            await db.commit()
        return {"ok": True, "other_clan_id": req.other_clan_id,
                "relation": relation}

    # -----------------------------------------------------------------------
    # Squad
    # -----------------------------------------------------------------------
    @app.post("/squads")
    async def post_squad(account: dict = Depends(get_current_account)):
        """Create a squad. A player is in at most one squad."""
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            existing = await _squad_of(db, player_id)
            if existing is not None:
                return {"ok": True, "squad_id": existing["squad_id"],
                        "already": True}
            cur = await db.execute(
                "INSERT INTO squads (leader_player_id, created_at) "
                "VALUES (?, ?)",
                (player_id, _now()),
            )
            squad_id = cur.lastrowid
            await db.execute(
                "INSERT INTO squad_members (squad_id, player_id, joined_at) "
                "VALUES (?, ?, ?)",
                (squad_id, player_id, _now()),
            )
            await db.commit()
        return {"ok": True, "squad_id": squad_id, "leader": True}

    @app.get("/squads/mine")
    async def get_my_squad(account: dict = Depends(get_current_account)):
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            squad = await _squad_of(db, player_id)
            if squad is None:
                return {"squad": None, "members": []}
            cursor = await db.execute(
                "SELECT player_id, joined_at FROM squad_members "
                "WHERE squad_id = ? ORDER BY joined_at",
                (squad["squad_id"],),
            )
            members = [{"player_id": r[0], "joined_at": int(r[1])}
                       for r in await cursor.fetchall()]
        return {"squad": squad, "members": members}

    @app.post("/squads/join")
    async def post_squad_join(squad_id: int,
                              account: dict = Depends(get_current_account)):
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            if await _squad_of(db, player_id) is not None:
                raise HTTPException(status_code=409, detail="Already in a squad")
            cursor = await db.execute(
                "SELECT squad_id FROM squads WHERE squad_id = ?", (squad_id,)
            )
            if await cursor.fetchone() is None:
                raise HTTPException(status_code=404, detail="Unknown squad")
            await db.execute(
                "INSERT INTO squad_members (squad_id, player_id, joined_at) "
                "VALUES (?, ?, ?)",
                (squad_id, player_id, _now()),
            )
            await db.commit()
        return {"ok": True, "squad_id": squad_id}

    @app.post("/squads/leave")
    async def post_squad_leave(account: dict = Depends(get_current_account)):
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            squad = await _squad_of(db, player_id)
            if squad is None:
                raise HTTPException(status_code=404, detail="Not in a squad")
            await db.execute(
                "DELETE FROM squad_members WHERE squad_id = ? AND player_id = ?",
                (squad["squad_id"], player_id),
            )
            if squad["leader_player_id"] == player_id:
                cursor = await db.execute(
                    "SELECT player_id FROM squad_members WHERE squad_id = ? "
                    "ORDER BY joined_at LIMIT 1",
                    (squad["squad_id"],),
                )
                nxt = await cursor.fetchone()
                if nxt is None:
                    await db.execute("DELETE FROM squads WHERE squad_id = ?",
                                     (squad["squad_id"],))
                else:
                    await db.execute(
                        "UPDATE squads SET leader_player_id = ? "
                        "WHERE squad_id = ?",
                        (nxt[0], squad["squad_id"]),
                    )
            await db.commit()
        return {"ok": True, "left": squad["squad_id"]}

    @app.post("/squads/kick")
    async def post_squad_kick(player_id: str,
                              account: dict = Depends(get_current_account)):
        """Kick a member. Only the squad leader may do this."""
        caller = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            squad = await _squad_of(db, caller)
            if squad is None:
                raise HTTPException(status_code=404, detail="Not in a squad")
            if squad["leader_player_id"] != caller:
                raise HTTPException(status_code=403, detail="Leader only")
            cursor = await db.execute(
                "SELECT COUNT(*) FROM squad_members "
                "WHERE squad_id = ? AND player_id = ?",
                (squad["squad_id"], player_id),
            )
            if (await cursor.fetchone())[0] == 0:
                raise HTTPException(status_code=404, detail="Not your member")
            await db.execute(
                "DELETE FROM squad_members WHERE squad_id = ? AND player_id = ?",
                (squad["squad_id"], player_id),
            )
            await db.commit()
        return {"ok": True, "kicked": player_id}

    # -----------------------------------------------------------------------
    # Chat (server-persisted)
    # -----------------------------------------------------------------------
    @app.get("/chat/{channel}")
    async def get_chat(channel: str, limit: int = 50,
                       account: dict = Depends(get_current_account)):
        """Recent messages on a channel, oldest first."""
        limit = max(1, min(int(limit), 200))
        clean = _clean_channel(channel)
        if not clean:
            raise HTTPException(status_code=400, detail="Unknown channel")
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT id, channel, sender_player_id, sender_name, clan_id, "
                "squad_id, body, created_at FROM chat_messages "
                "WHERE channel = ? ORDER BY id DESC LIMIT ?",
                (clean, limit),
            )
            rows = [{"id": int(r[0]), "channel": r[1], "sender": r[2],
                     "sender_name": r[3], "clan_id": int(r[4]),
                     "squad_id": int(r[5]), "body": r[6],
                     "created_at": int(r[7])}
                    for r in await cursor.fetchall()]
        rows.reverse()
        return {"channel": clean, "messages": rows, "count": len(rows)}

    @app.post("/chat")
    async def post_chat(req: ChatSendRequest,
                        account: dict = Depends(get_current_account)):
        """Send a message.

        The row is written BEFORE anything is broadcast, so the persisted log
        and what players saw can never diverge. Length and rate are validated
        server-side.
        """
        player_id = account["player_id"]
        body = str(req.body).strip()
        if not body or len(body) > CHAT_MAX_LENGTH:
            raise HTTPException(status_code=400, detail="Invalid message")
        channel = _clean_channel(req.channel)
        if not channel:
            raise HTTPException(status_code=400, detail="Unknown channel")

        async with aiosqlite.connect(_db()) as db:
            # Per-player rate limit, derived from the last stored message.
            cursor = await db.execute(
                "SELECT created_at FROM chat_messages "
                "WHERE sender_player_id = ? ORDER BY id DESC LIMIT 1",
                (player_id,),
            )
            last = await cursor.fetchone()
            if last and (_now() - int(last[0])) < CHAT_MIN_INTERVAL_SECONDS:
                raise HTTPException(status_code=429, detail="Too fast")
            clan = await _clan_of(db, player_id)
            squad = await _squad_of(db, player_id)
            cur = await db.execute(
                "INSERT INTO chat_messages (channel, sender_player_id, "
                "sender_name, clan_id, squad_id, body, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (channel, player_id, account["username"],
                 int(clan["clan_id"]) if clan else 0,
                 int(squad["squad_id"]) if squad else 0,
                 body, _now()),
            )
            message_id = cur.lastrowid
            await db.commit()
        return {"ok": True, "id": message_id, "channel": channel,
                "body": body, "sender": player_id}

    # -----------------------------------------------------------------------
    # Settings (gameplay-affecting only)
    # -----------------------------------------------------------------------
    @app.get("/settings")
    async def get_settings(account: dict = Depends(get_current_account)):
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT nickname, chat_channel, hud_visible, show_damage "
                "FROM player_settings WHERE player_id = ?",
                (account["player_id"],),
            )
            row = await cursor.fetchone()
        if row is None:
            return {"nickname": account["username"],
                    "chat_channel": CHAT_CHANNELS[0], "hud_visible": True,
                    "show_damage": True}
        return {"nickname": row[0] or account["username"],
                "chat_channel": row[1], "hud_visible": bool(row[2]),
                "show_damage": bool(row[3])}

    @app.put("/settings")
    async def put_settings(req: SettingsUpdateRequest,
                           account: dict = Depends(get_current_account)):
        """Persist the server-owned settings.

        Graphics/UI preferences deliberately stay in the client: they are
        per-device, not per-account, and syncing them would be wrong.
        """
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            current = {"nickname": account["username"],
                       "chat_channel": CHAT_CHANNELS[0],
                       "hud_visible": True, "show_damage": True}
            cursor = await db.execute(
                "SELECT nickname, chat_channel, hud_visible, show_damage "
                "FROM player_settings WHERE player_id = ?",
                (player_id,),
            )
            row = await cursor.fetchone()
            if row is not None:
                current = {"nickname": row[0] or account["username"],
                           "chat_channel": row[1],
                           "hud_visible": bool(row[2]),
                           "show_damage": bool(row[3])}
            if req.nickname is not None:
                nickname = "".join(
                    ch for ch in str(req.nickname).strip() if ch.isprintable()
                )
                if not 2 <= len(nickname) <= 24:
                    raise HTTPException(status_code=400,
                                        detail="Invalid nickname")
                current["nickname"] = nickname
            if req.chat_channel is not None:
                if str(req.chat_channel) not in CHAT_CHANNELS:
                    raise HTTPException(status_code=400,
                                        detail="Unknown channel")
                current["chat_channel"] = str(req.chat_channel)
            if req.hud_visible is not None:
                current["hud_visible"] = bool(req.hud_visible)
            if req.show_damage is not None:
                current["show_damage"] = bool(req.show_damage)
            await db.execute(
                "INSERT INTO player_settings (player_id, nickname, "
                "chat_channel, hud_visible, show_damage, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(player_id) DO UPDATE SET "
                "nickname = excluded.nickname, "
                "chat_channel = excluded.chat_channel, "
                "hud_visible = excluded.hud_visible, "
                "show_damage = excluded.show_damage, "
                "updated_at = excluded.updated_at",
                (player_id, current["nickname"], current["chat_channel"],
                 1 if current["hud_visible"] else 0,
                 1 if current["show_damage"] else 0, _now()),
            )
            await db.commit()
        return {"ok": True, "settings": current}

    # -----------------------------------------------------------------------
    # Cargo
    # -----------------------------------------------------------------------
    @app.get("/cargo")
    async def get_cargo(account: dict = Depends(get_current_account)):
        async with aiosqlite.connect(_db()) as db:
            return await _cargo(db, account["player_id"])

    @app.post("/cargo/deposit")
    async def post_cargo_deposit(req: CargoDepositRequest,
                                 account: dict = Depends(get_current_account)):
        """Move items from the inventory into cargo, respecting capacity."""
        player_id = account["player_id"]
        item_id = normalize_item_id(req.item_id)
        quantity = max(1, int(req.quantity))
        async with aiosqlite.connect(_db()) as db:
            cargo = await _cargo(db, player_id)
            if cargo["used"] + quantity > cargo["capacity"]:
                raise HTTPException(
                    status_code=409,
                    detail={"reason": "cargo_full",
                            "capacity": cargo["capacity"],
                            "used": cargo["used"]})
            if not await player_state.consume_item(db, player_id, item_id,
                                                    quantity):
                raise HTTPException(status_code=400,
                                    detail={"reason": "not_owned",
                                            "item_id": item_id})
            items = dict(cargo["items"])
            items[item_id] = int(items.get(item_id, 0)) + quantity
            await db.execute(
                "UPDATE cargo SET items = ?, updated_at = ? WHERE player_id = ?",
                (json.dumps(items), _now(), player_id),
            )
            await db.commit()
        return {"ok": True,
                "cargo": {"capacity": cargo["capacity"], "items": items,
                          "used": sum(int(v) for v in items.values())}}

    @app.post("/cargo/withdraw")
    async def post_cargo_withdraw(req: CargoDepositRequest,
                                  account: dict = Depends(get_current_account)):
        """Move items from cargo back into the inventory."""
        player_id = account["player_id"]
        item_id = normalize_item_id(req.item_id)
        quantity = max(1, int(req.quantity))
        async with aiosqlite.connect(_db()) as db:
            cargo = await _cargo(db, player_id)
            held = int(cargo["items"].get(item_id, 0))
            if held < quantity:
                raise HTTPException(status_code=400,
                                    detail={"reason": "not_stored",
                                            "item_id": item_id,
                                            "stored": held})
            items = dict(cargo["items"])
            items[item_id] = held - quantity
            if items[item_id] <= 0:
                items.pop(item_id, None)
            await db.execute(
                "UPDATE cargo SET items = ?, updated_at = ? WHERE player_id = ?",
                (json.dumps(items), _now(), player_id),
            )
            await _grant_item(db, player_id, item_id, quantity)
            await db.commit()
        return {"ok": True,
                "cargo": {"capacity": cargo["capacity"], "items": items,
                          "used": sum(int(v) for v in items.values())}}

    # -----------------------------------------------------------------------
    # Auction
    # -----------------------------------------------------------------------
    @app.get("/auctions")
    async def get_auctions(state: str = "open",
                           account: dict = Depends(get_current_account)):
        columns = ("SELECT auction_id, seller_player_id, item_id, quantity, "
                   "currency, start_price, buyout_price, current_price, "
                   "highest_bidder, state, created_at, ends_at FROM auctions ")
        async with aiosqlite.connect(_db()) as db:
            if state and state != "all":
                cursor = await db.execute(
                    columns + "WHERE state = ? ORDER BY ends_at LIMIT 100",
                    (state,))
            else:
                cursor = await db.execute(
                    columns + "ORDER BY ends_at LIMIT 100")
            rows = await cursor.fetchall()
        return {"auctions": [
            {"auction_id": int(r[0]), "seller": r[1], "item_id": r[2],
             "quantity": int(r[3]), "currency": r[4],
             "start_price": int(r[5]), "buyout_price": int(r[6]),
             "current_price": int(r[7]), "highest_bidder": r[8],
             "state": r[9], "created_at": int(r[10]), "ends_at": int(r[11])}
            for r in rows], "count": len(rows)}

    @app.post("/auctions")
    async def post_auction(req: AuctionCreateRequest,
                           account: dict = Depends(get_current_account)):
        """List an item.

        The item moves from the seller's inventory into escrow immediately, so
        it cannot also be sold (or used) while the auction is running.
        """
        player_id = account["player_id"]
        item_id = normalize_item_id(req.item_id)
        quantity = max(1, int(req.quantity))
        currency = str(req.currency).strip().upper()
        if currency not in ("BTC", "PLT", "GOLD"):
            raise HTTPException(status_code=400, detail="Invalid currency")
        start_price = max(1, int(req.start_price))
        buyout = max(0, int(req.buyout_price))
        if buyout and buyout < start_price:
            raise HTTPException(status_code=400,
                                detail="Buyout below start price")
        duration = max(AUCTION_MIN_SECONDS,
                       min(int(req.duration_seconds), AUCTION_MAX_SECONDS))

        async with aiosqlite.connect(_db()) as db:
            if not await player_state.owns_item(db, player_id, item_id, quantity):
                raise HTTPException(status_code=400,
                                    detail={"reason": "not_owned",
                                            "item_id": item_id})
            await player_state.consume_item(db, player_id, item_id, quantity)
            now = _now()
            cur = await db.execute(
                "INSERT INTO auctions (seller_player_id, item_id, quantity, "
                "currency, start_price, buyout_price, current_price, "
                "highest_bidder, state, created_at, ends_at) "
                "VALUES (?, ?, ?, ?, ?, ?, 0, '', 'open', ?, ?)",
                (player_id, item_id, quantity, currency, start_price, buyout,
                 now, now + duration),
            )
            auction_id = cur.lastrowid
            await journal.record_event(
                db, player_id, journal.EVENT_SYSTEM,
                f"Auctions ilan acildi: {item_id}", journal.SEVERITY_INFO,
                {"auction_id": auction_id, "item_id": item_id,
                 "start_price": start_price, "currency": currency},
            )
            await db.commit()
        return {"ok": True, "auction_id": auction_id, "item_id": item_id,
                "quantity": quantity, "currency": currency,
                "start_price": start_price, "ends_at": now + duration}

    @app.post("/auctions/bid")
    async def post_bid(req: AuctionBidRequest,
                       account: dict = Depends(get_current_account)):
        """Place a bid.

        The bid and the ESCROW are written in the same transaction, so a bidder
        cannot win with money they already spent elsewhere. The auction's own
        `state` guards the write, so a bid arriving after settlement is refused
        rather than paid.
        """
        player_id = account["player_id"]
        amount = max(1, int(req.amount))
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT seller_player_id, item_id, quantity, currency, "
                "start_price, buyout_price, current_price, highest_bidder, "
                "state, ends_at FROM auctions WHERE auction_id = ?",
                (req.auction_id,),
            )
            row = await cursor.fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Unknown auction")
            if row[8] != "open":
                raise HTTPException(status_code=409,
                                    detail="Auction is not open")
            if int(row[9]) <= _now():
                raise HTTPException(status_code=409, detail="Auction ended")
            if row[0] == player_id:
                raise HTTPException(status_code=400,
                                    detail="Cannot bid on your own auction")
            minimum = max(int(row[4]), int(row[6]) + 1)
            if amount < minimum:
                raise HTTPException(status_code=400,
                                    detail={"reason": "bid_too_low",
                                            "minimum": minimum})
            currency = str(row[3])
            if not await _escrow(db, player_id, currency, amount,
                                 "auction_bid"):
                raise HTTPException(status_code=400,
                                    detail={"reason": "insufficient",
                                            "currency": currency})
            await db.execute(
                "UPDATE auctions SET current_price = ?, highest_bidder = ? "
                "WHERE auction_id = ? AND state = 'open'",
                (amount, player_id, req.auction_id),
            )
            await db.execute(
                "INSERT INTO auction_bids (auction_id, bidder_player_id, "
                "amount, created_at) VALUES (?, ?, ?, ?)",
                (req.auction_id, player_id, amount, _now()),
            )
            await journal.record_event(
                db, player_id, journal.EVENT_SYSTEM,
                f"Auctions teklif verildi: {amount} {currency}",
                journal.SEVERITY_INFO,
                {"auction_id": req.auction_id, "amount": amount,
                 "currency": currency},
            )
            await db.commit()
        return {"ok": True, "auction_id": req.auction_id, "amount": amount,
                "currency": currency, "highest_bidder": player_id}

    @app.post("/auctions/{auction_id}/settle")
    async def post_settle(auction_id: int,
                          account: dict = Depends(get_current_account)):
        """Settle a finished auction.

        Idempotent: the `state` transition is conditional, so a second caller
        sees "already settled" instead of paying the winner twice.
        """
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT seller_player_id, item_id, quantity, currency, "
                "current_price, highest_bidder, state, ends_at "
                "FROM auctions WHERE auction_id = ?",
                (auction_id,),
            )
            row = await cursor.fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Unknown auction")
            if row[6] != "open":
                return {"ok": True, "auction_id": auction_id, "state": row[6],
                        "already": True}
            if int(row[7]) > _now():
                raise HTTPException(status_code=409,
                                    detail="Auction still running")
            # An UPDATE returns no result rows, so the affected-row count comes
            # from `rowcount` - fetchone() here would be None.
            cursor = await db.execute(
                "UPDATE auctions SET state = 'settled' "
                "WHERE auction_id = ? AND state = 'open'",
                (auction_id,),
            )
            if cursor.rowcount == 0:
                return {"ok": True, "auction_id": auction_id,
                        "state": "settled", "already": True}

            item_id, quantity = row[1], int(row[2])
            price, winner, currency = int(row[4]), row[5], str(row[3])
            if not winner:
                # No bids: the item returns to the seller.
                await _grant_item(db, row[0], item_id, quantity)
                await db.commit()
                return {"ok": True, "auction_id": auction_id,
                        "state": "settled", "winner": "", "returned": True}

            # The bidder's escrow is already spent; pay the seller minus the fee.
            fee = price * AUCTION_FEE_PERCENT // 100
            await _grant_currency(
                db, row[0],
                btc=price - fee if currency == "BTC" else 0,
                plt=price - fee if currency == "PLT" else 0,
                gold=price - fee if currency == "GOLD" else 0,
                reason="auction_sale",
            )
            await _grant_item(db, winner, item_id, quantity)
            for party in (winner, row[0]):
                await journal.record_event(
                    db, party, journal.EVENT_SYSTEM,
                    f"Auctions kapandi: {item_id}", journal.SEVERITY_INFO,
                    {"auction_id": auction_id, "price": price,
                     "winner": winner, "seller": row[0]},
                )
            await db.commit()
        return {"ok": True, "auction_id": auction_id, "state": "settled",
                "winner": winner, "price": price}

    # -----------------------------------------------------------------------
    # Server events
    # -----------------------------------------------------------------------
    @app.get("/events")
    async def get_events(account: dict = Depends(get_current_account)):
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT event_id, name, map_id, state, starts_at, ends_at, "
                "reward_btc, reward_plt, reward_xp, reward_honor "
                "FROM server_events ORDER BY starts_at"
            )
            events = [{"event_id": r[0], "name": r[1], "map_id": r[2],
                       "state": r[3], "starts_at": int(r[4]),
                       "ends_at": int(r[5]), "reward_btc": int(r[6]),
                       "reward_plt": int(r[7]), "reward_xp": int(r[8]),
                       "reward_honor": int(r[9])}
                      for r in await cursor.fetchall()]
            cursor = await db.execute(
                "SELECT event_id, score, joined_at, rewarded "
                "FROM event_participants WHERE player_id = ?",
                (account["player_id"],),
            )
            mine = [{"event_id": r[0], "score": int(r[1]),
                     "joined_at": int(r[2]), "rewarded": bool(r[3])}
                    for r in await cursor.fetchall()]
        return {"events": events, "participations": mine, "count": len(events)}

    @app.post("/events/join")
    async def post_event_join(req: EventJoinRequest,
                              account: dict = Depends(get_current_account)):
        """Join a running event. The window is enforced server-side."""
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT state, starts_at, ends_at FROM server_events "
                "WHERE event_id = ?",
                (req.event_id,),
            )
            row = await cursor.fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Unknown event")
            now = _now()
            if row[0] != "active" or now < int(row[1]) or now > int(row[2]):
                raise HTTPException(status_code=409,
                                    detail={"reason": "not_running",
                                            "state": row[0]})
            await db.execute(
                "INSERT OR IGNORE INTO event_participants (event_id, player_id, "
                "score, joined_at, rewarded) VALUES (?, ?, 0, ?, 0)",
                (req.event_id, player_id, now),
            )
            await db.commit()
        return {"ok": True, "event_id": req.event_id, "joined": True}

    @app.post("/events/{event_id}/reward")
    async def post_event_reward(event_id: str,
                                account: dict = Depends(get_current_account)):
        """Claim an event reward.

        `rewarded` is flipped conditionally, so a repeat claim finds it already
        set and pays nothing.
        """
        player_id = account["player_id"]
        async with aiosqlite.connect(_db()) as db:
            cursor = await db.execute(
                "SELECT reward_btc, reward_plt, reward_xp, reward_honor "
                "FROM server_events WHERE event_id = ?",
                (event_id,),
            )
            row = await cursor.fetchone()
            if row is None:
                raise HTTPException(status_code=404, detail="Unknown event")
            cursor = await db.execute(
                "UPDATE event_participants SET rewarded = 1 "
                "WHERE event_id = ? AND player_id = ? AND rewarded = 0",
                (event_id, player_id),
            )
            # An UPDATE returns no rows; the count comes from `rowcount`.
            if cursor.rowcount == 0:
                raise HTTPException(status_code=409,
                                    detail="Already rewarded")
            btc, plt = int(row[0]), int(row[1])
            xp, honor = int(row[2]), int(row[3])
            if btc or plt:
                await _grant_currency(db, player_id, btc=btc, plt=plt,
                                     reason="event_reward")
            if xp:
                await player_state.add_xp(db, player_id, xp)
            if honor:
                await player_state.add_honor(db, player_id, honor)
            await journal.record_event(
                db, player_id, journal.EVENT_REWARD,
                f"Etkinlik odulu: {event_id}", journal.SEVERITY_GOOD,
                {"event_id": event_id, "btc": btc, "plt": plt, "xp": xp,
                 "honor": honor},
            )
            await db.commit()
        return {"ok": True, "event_id": event_id, "reward": {
            "btc": btc, "plt": plt, "xp": xp, "honor": honor}}











