"""Server-authoritative event journal (Phase 1).

The "Seyir Defteri" (logbook) used to live only in the client's
`user://players.json` (`GlobalState.logbook`). That meant it was lost on a
fresh install, editable client-side (never authoritative), and unreachable by
the one component that actually knows *what happened* - the server.

This module is the single writer for `event_journal`. Events are persisted
first and only then pushed over the WebSocket as a `journal_event` frame, so a
disconnected player still sees the full history on the next login.

`event_type` is one of: login, logout, register, company_change, npc_kill,
player_kill, death, reward, market_buy, market_sell, map_enter, map_leave,
level_up, quest, gate, loot, chat, clan, system.

`severity` is one of `info`, `good`, `bad`, `important` and drives the client
colour only; it never changes gameplay.
"""

from __future__ import annotations

import json
import time
from typing import Any, Optional

import aiosqlite

# ---------------------------------------------------------------------------
# Event types
# ---------------------------------------------------------------------------
EVENT_LOGIN = "login"
EVENT_LOGOUT = "logout"
EVENT_REGISTER = "register"
EVENT_COMPANY_CHANGE = "company_change"
EVENT_NPC_KILL = "npc_kill"
EVENT_PLAYER_KILL = "player_kill"
EVENT_DEATH = "death"
EVENT_REWARD = "reward"
EVENT_MARKET_BUY = "market_buy"
EVENT_MARKET_SELL = "market_sell"
EVENT_MAP_ENTER = "map_enter"
EVENT_MAP_LEAVE = "map_leave"
EVENT_LEVEL_UP = "level_up"
EVENT_QUEST = "quest"
EVENT_GATE = "gate"
EVENT_LOOT = "loot"
EVENT_CHAT = "chat"
EVENT_CLAN = "clan"
EVENT_SYSTEM = "system"

# Phases 2-7 add their own event types so the Seyir Defteri can distinguish a
# faction switch from a free company pick, an equipment change from a combat
# one, and a portal transit from a plain map join. Existing types above keep
# their exact string values, so an already-synced client is unaffected.
EVENT_FACTION_CHANGE = "faction_change"
EVENT_PORTAL = "portal"
EVENT_EQUIPMENT = "equipment"
EVENT_AMMO = "ammo"
EVENT_AUCTION = "auction"
EVENT_EVENT = "world_event"
EVENT_CARGO = "cargo"
EVENT_DRONE = "drone"

VALID_EVENT_TYPES: frozenset[str] = frozenset(
    {
        EVENT_LOGIN, EVENT_LOGOUT, EVENT_REGISTER, EVENT_COMPANY_CHANGE,
        EVENT_NPC_KILL, EVENT_PLAYER_KILL, EVENT_DEATH, EVENT_REWARD,
        EVENT_MARKET_BUY, EVENT_MARKET_SELL, EVENT_MAP_ENTER, EVENT_MAP_LEAVE,
        EVENT_LEVEL_UP, EVENT_QUEST, EVENT_GATE, EVENT_LOOT, EVENT_CHAT,
        EVENT_CLAN, EVENT_SYSTEM,
        EVENT_FACTION_CHANGE, EVENT_PORTAL, EVENT_EQUIPMENT, EVENT_AMMO,
        EVENT_AUCTION, EVENT_EVENT, EVENT_CARGO, EVENT_DRONE,
    }
)

SEVERITY_INFO = "info"
SEVERITY_GOOD = "good"
SEVERITY_BAD = "bad"
SEVERITY_IMPORTANT = "important"

VALID_SEVERITIES: frozenset[str] = frozenset(
    {SEVERITY_INFO, SEVERITY_GOOD, SEVERITY_BAD, SEVERITY_IMPORTANT}
)

# The client keeps a bounded in-memory list; the server trims the stored
# history to the same depth so the two never disagree about "the logbook".
DEFAULT_JOURNAL_LIMIT = 300

# Cap on a single serialized payload so a rogue caller cannot write a 10 MB
# "details" blob into every player's journal.
MAX_DETAILS_CHARS = 2000


def _now() -> int:
    return int(time.time())


def _clip(text: str, limit: int = MAX_DETAILS_CHARS) -> str:
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "\u2026"


def _clean_text(value: Any, limit: int = 200) -> str:
    return _clip(str("" if value is None else value), limit)


def make_event(
    event_type: str,
    message: str,
    severity: str = SEVERITY_INFO,
    details: Optional[dict] = None,
) -> dict:
    """Build a normalized journal event.

    Unknown event types / severities fall back to `system` / `info` instead of
    raising: a journal entry must never be the reason a gameplay action fails.
    """
    etype = event_type if event_type in VALID_EVENT_TYPES else EVENT_SYSTEM
    sev = severity if severity in VALID_SEVERITIES else SEVERITY_INFO
    payload: dict = {
        "type": "journal_event",
        "event_type": etype,
        "severity": sev,
        "message": _clean_text(message),
        "timestamp": _now(),
    }
    if details:
        try:
            encoded = json.dumps(details, ensure_ascii=False, default=str)
        except (TypeError, ValueError):
            encoded = json.dumps({"repr": repr(details)})
        if len(encoded) > MAX_DETAILS_CHARS:
            # Truncating a serialized blob would split a string/escape and make
            # the row un-parseable on the way back out, so the payload is
            # replaced with a valid marker instead of being cut mid-token.
            encoded = json.dumps(
                {
                    "truncated": True,
                    "original_bytes": len(encoded),
                },
                ensure_ascii=False,
            )
        payload["details"] = json.loads(encoded)
    return payload

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------
async def record_event(
    db: aiosqlite.Connection,
    player_id: str,
    event_type: str,
    message: str,
    severity: str = SEVERITY_INFO,
    details: Optional[dict] = None,
    limit: int = DEFAULT_JOURNAL_LIMIT,
) -> dict:
    """Append one journal entry for `player_id` and return the stored event.

    `db` is an already-open aiosqlite connection owned by the caller, so this
    composes with the single-connection-per-request style in main.py and cannot
    deadlock against an open transaction.
    """
    if not player_id:
        raise ValueError("record_event requires a player_id")
    event = make_event(event_type, message, severity, details)
    # `lastrowid` lives on the CURSOR, not the aiosqlite Connection.
    cursor = await db.execute(
        "INSERT INTO event_journal "
        "(player_id, event_type, severity, message, details, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (
            player_id,
            event["event_type"],
            event["severity"],
            event["message"],
            json.dumps(event.get("details", {}), ensure_ascii=False),
            event["timestamp"],
        ),
    )
    # Trim the stored history to `limit` newest rows. The id cursor keeps the
    # newest even when several events share a second-granularity timestamp.
    await db.execute(
        "DELETE FROM event_journal WHERE player_id = ? AND id NOT IN ("
        "  SELECT id FROM event_journal WHERE player_id = ? "
        "  ORDER BY created_at DESC, id DESC LIMIT ?"
        ")",
        (player_id, player_id, max(int(limit), 1)),
    )
    event["id"] = cursor.lastrowid
    return event


async def list_events(
    db: aiosqlite.Connection,
    player_id: str,
    limit: int = DEFAULT_JOURNAL_LIMIT,
    offset: int = 0,
) -> list:
    """Newest-first journal rows for `player_id`, as client-ready dicts."""
    limit = max(1, min(int(limit), DEFAULT_JOURNAL_LIMIT))
    offset = max(0, int(offset))
    cursor = await db.execute(
        "SELECT id, event_type, severity, message, details, created_at "
        "FROM event_journal WHERE player_id = ? "
        "ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
        (player_id, limit, offset),
    )
    rows = await cursor.fetchall()
    return [row_to_event(r) for r in rows]


async def count_events(db: aiosqlite.Connection, player_id: str) -> int:
    cursor = await db.execute(
        "SELECT COUNT(*) FROM event_journal WHERE player_id = ?", (player_id,)
    )
    row = await cursor.fetchone()
    return int(row[0]) if row else 0


def row_to_event(row) -> dict:
    """DB row -> the same dict shape `make_event` produces."""
    (eid, etype, severity, message, details, created_at) = row
    event: dict = {
        "type": "journal_event",
        "id": eid,
        "event_type": etype,
        "severity": severity,
        "message": message,
        "timestamp": int(created_at),
    }
    if details:
        try:
            parsed = json.loads(details)
        except (TypeError, ValueError):
            parsed = {}
        if isinstance(parsed, dict) and parsed:
            event["details"] = parsed
    return event

# ---------------------------------------------------------------------------
# Convenience wrappers - one per Phase 1 event type
# ---------------------------------------------------------------------------
async def log_login(db, player_id: str, username: str) -> dict:
    return await record_event(
        db, player_id, EVENT_LOGIN, f"{username} sisteme baglandi",
        SEVERITY_INFO, {"username": username},
    )


async def log_logout(db, player_id: str, username: str) -> dict:
    return await record_event(
        db, player_id, EVENT_LOGOUT, f"{username} oturumu kapatti",
        SEVERITY_INFO, {"username": username},
    )


async def log_register(db, player_id: str, username: str, granted: dict) -> dict:
    return await record_event(
        db, player_id, EVENT_REGISTER,
        f"{username} icin yeni hesap olusturuldu", SEVERITY_GOOD,
        {"username": username, "starter_reward": granted},
    )


async def log_company_change(db, player_id: str, old: str, new: str) -> dict:
    return await record_event(
        db, player_id, EVENT_COMPANY_CHANGE,
        f"Sirket degistirildi: {old or 'Yok'} -> {new}",
        SEVERITY_IMPORTANT, {"from": old, "to": new},
    )


async def log_npc_kill(db, player_id: str, npc_type: str, reward: dict) -> dict:
    return await record_event(
        db, player_id, EVENT_NPC_KILL, f"{npc_type} imha edildi",
        SEVERITY_GOOD, {"npc_type": npc_type, "reward": reward},
    )


async def log_reward(db, player_id: str, message: str, details: dict) -> dict:
    return await record_event(
        db, player_id, EVENT_REWARD, message, SEVERITY_GOOD, details,
    )


async def log_market(db, player_id: str, bought: bool, item: str,
                     amount: int, currency: str) -> dict:
    verb = "satin alindi" if bought else "satildi"
    return await record_event(
        db, player_id, EVENT_MARKET_BUY if bought else EVENT_MARKET_SELL,
        f"{item} x{amount} {verb}",
        SEVERITY_INFO,
        {"item_id": item, "quantity": amount, "currency": currency},
    )


async def log_map(db, player_id: str, map_id: str, entered: bool) -> dict:
    return await record_event(
        db, player_id, EVENT_MAP_ENTER if entered else EVENT_MAP_LEAVE,
        f"Harita {map_id} {'girildi' if entered else 'ayrildi'}",
        SEVERITY_INFO, {"map_id": map_id},
    )


async def log_player_kill(db, player_id: str, victim: str) -> dict:
    return await record_event(
        db, player_id, EVENT_PLAYER_KILL, f"{victim} vuruldu",
        SEVERITY_GOOD, {"victim": victim},
    )


async def log_death(db, player_id: str, killer: str = "") -> dict:
    return await record_event(
        db, player_id, EVENT_DEATH,
        f"{killer + ' tarafindan ' if killer else ''}oldun",
        SEVERITY_BAD, {"killer": killer},
    )


