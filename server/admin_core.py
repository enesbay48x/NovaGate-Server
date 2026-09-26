"""Server-side role, permission and audit-log core for the Admin Panel.

Design rules
------------
1. AUTHORITY LIVES HERE, ON THE SERVER. Nothing in this module can be
   influenced by a client value. A `role` string is only ever read from the
   `accounts` row after the JWT has been verified, so a tampered client
   (`is_admin = true` in players.json, a forged payload field) grants nothing.

2. THE MATRIX IS A TABLE, NOT A NESTED IF-CHAIN. Adding a permission is one
   line; forgetting to guard a new endpoint is a visible gap in the table
   rather than an omission buried in a handler.

3. ROLES ARE ORDERED. `superadmin > admin > moderator > player` and a rank
   comparison is the ONLY way authority is compared. That makes the
   "an admin cannot promote themselves" rule a single rank check instead of a
   pile of special cases.

4. THE AUDIT LOG IS APPEND-ONLY. There is no UPDATE or DELETE path anywhere in
   the codebase, and a SQLite trigger below enforces that at the database
   level, so even a direct SQL mistake cannot rewrite history.
"""

from __future__ import annotations

import json
import time
from typing import Optional

import aiosqlite
from fastapi import HTTPException, Request, status

# ---------------------------------------------------------------------------
# Roles
# ---------------------------------------------------------------------------
ROLE_PLAYER = "player"
ROLE_MODERATOR = "moderator"
ROLE_ADMIN = "admin"
ROLE_SUPERADMIN = "superadmin"

# Ordered lowest -> highest. Index in this tuple IS the rank.
ROLE_ORDER = (ROLE_PLAYER, ROLE_MODERATOR, ROLE_ADMIN, ROLE_SUPERADMIN)
VALID_ROLES = frozenset(ROLE_ORDER)

# The roles that may use the Admin Panel at all.
STAFF_ROLES = frozenset({ROLE_MODERATOR, ROLE_ADMIN, ROLE_SUPERADMIN})


def role_rank(role: object) -> int:
    """Numeric rank of a role; -1 for anything unrecognised.

    An unknown role is deliberately the LOWEST possible rank, so a corrupted
    or missing value can never accidentally grant authority.
    """
    text = str(role or "").strip().lower()
    try:
        return ROLE_ORDER.index(text)
    except ValueError:
        return -1


def is_staff(role: object) -> bool:
    return str(role or "").strip().lower() in STAFF_ROLES


def at_least(role: object, required: str) -> bool:
    """True when `role` is the same as, or outranks, `required`."""
    mine = role_rank(role)
    needed = role_rank(required)
    return mine >= 0 and needed >= 0 and mine >= needed


# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------
# Every Admin Panel action maps to exactly one permission string. Handlers
# declare `Depends(require_permission("x.y"))` and never re-check by hand.
PERMISSIONS = (
    # --- moderator tier: look, moderate, move players --------------------
    "player.lookup", "player.online", "player.kick", "player.teleport",
    "chat.moderate",
    # --- admin tier: everything economic / progression -------------------
    "economy.manage", "inventory.manage", "equipment.manage",
    "stats.manage", "ship.manage", "npc.manage", "map.manage",
    "quest.manage", "gate.manage", "clan.view", "squad.view",
    "auction.view", "event.view", "server.dashboard", "audit.view",
    # --- superadmin tier: authority itself, and live operations ----------
    "role.manage", "clan.manage", "squad.manage", "auction.manage",
    "event.manage", "server.control", "settings.manage",
)

_MODERATOR_PERMS = frozenset({
    "player.lookup", "player.online", "player.kick", "player.teleport",
    "chat.moderate", "clan.view", "squad.view", "auction.view",
    "event.view", "server.dashboard",
})

ROLE_PERMISSIONS: dict[str, frozenset] = {
    ROLE_PLAYER: frozenset(),
    ROLE_MODERATOR: _MODERATOR_PERMS,
    # An admin is a moderator PLUS the whole economy/progression surface.
    ROLE_ADMIN: _MODERATOR_PERMS | frozenset({
        "economy.manage", "inventory.manage", "equipment.manage",
        "stats.manage", "ship.manage", "npc.manage", "map.manage",
        "quest.manage", "gate.manage", "audit.view",
    }),
    ROLE_SUPERADMIN: frozenset(PERMISSIONS),
}


def has_permission(role: object, permission: str) -> bool:
    text = str(role or "").strip().lower()
    return permission in ROLE_PERMISSIONS.get(text, frozenset())


def permissions_for(role: object) -> list:
    return sorted(ROLE_PERMISSIONS.get(
        str(role or "").strip().lower(), frozenset()))

# ---------------------------------------------------------------------------
# Database: audit log + mutes
# ---------------------------------------------------------------------------
AUDIT_SCHEMA = """
-- The audit trail. `old_value` / `new_value` are TEXT on purpose: an admin
-- operation may change an int, a JSON loadout or a map id, and the log must
-- record the before/after faithfully whatever the type was.
CREATE TABLE IF NOT EXISTS admin_audit_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       INTEGER NOT NULL,
    admin_account_id INTEGER,
    admin_username  TEXT NOT NULL,
    admin_role      TEXT NOT NULL DEFAULT '',
    action          TEXT NOT NULL,
    target_type     TEXT NOT NULL DEFAULT '',
    target          TEXT NOT NULL DEFAULT '',
    old_value       TEXT,
    new_value       TEXT,
    reason          TEXT NOT NULL DEFAULT '',
    result          TEXT NOT NULL DEFAULT 'success',
    remote_addr     TEXT NOT NULL DEFAULT '',
    session_id      TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_timestamp
    ON admin_audit_log(timestamp);
CREATE INDEX IF NOT EXISTS idx_admin_audit_action
    ON admin_audit_log(action);
CREATE INDEX IF NOT EXISTS idx_admin_audit_admin
    ON admin_audit_log(admin_username);

-- APPEND-ONLY ENFORCEMENT.
-- A trigger that RAISEs on UPDATE or DELETE means the log cannot be rewritten
-- even by a bug that issues the wrong SQL, and no application code path can
-- edit history - including a superadmin's own entries.
CREATE TRIGGER IF NOT EXISTS admin_audit_no_update
BEFORE UPDATE ON admin_audit_log
BEGIN
    SELECT RAISE(ABORT, 'admin_audit_log is append-only');
END;

CREATE TRIGGER IF NOT EXISTS admin_audit_no_delete
BEFORE DELETE ON admin_audit_log
BEGIN
    SELECT RAISE(ABORT, 'admin_audit_log is append-only');
END;

-- Moderation mutes, persisted server-side so a restart does not un-mute
-- anyone and a client cannot clear its own mute.
CREATE TABLE IF NOT EXISTS player_mutes (
    player_id       TEXT PRIMARY KEY,
    username        TEXT NOT NULL DEFAULT '',
    muted           INTEGER NOT NULL DEFAULT 1,
    reason          TEXT NOT NULL DEFAULT '',
    until_ts        INTEGER NOT NULL DEFAULT 0,
    muted_by        TEXT NOT NULL DEFAULT '',
    created_at      INTEGER NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL DEFAULT 0
);
"""


async def ensure_admin_schema(db: aiosqlite.Connection) -> None:
    """Create the audit log, its immutability triggers and the mute table.

    Idempotent: every statement is IF NOT EXISTS, so this is safe on every
    boot and never rewrites an existing row.
    """
    await db.executescript(AUDIT_SCHEMA)
    await db.commit()

# ---------------------------------------------------------------------------
# Audit log writer
# ---------------------------------------------------------------------------
def _now() -> int:
    return int(time.time())


def _encode_audit_value(value):
    """Render an audit before/after value as TEXT."""
    if value is None:
        return None
    if isinstance(value, (int, float, str, bool)):
        return str(value)
    try:
        return json.dumps(value, default=str)
    except (TypeError, ValueError):
        return str(value)


async def write_audit(
    db: aiosqlite.Connection,
    admin: dict,
    action: str,
    *,
    target_type: str = "player",
    target: str = "",
    old_value=None,
    new_value=None,
    reason: str = "",
    result: str = "success",
    request: Optional[Request] = None,
) -> None:
    """Append one audit row.

    Never raises: an audit failure must not roll back an operation that
    already succeeded, so it is printed loudly and swallowed.
    """
    remote_addr = ""
    session_id = ""
    if request is not None:
        try:
            remote_addr = (request.client.host if request.client else "") or ""
        except Exception:
            remote_addr = ""
        session_id = (request.headers.get("x-session-id")
                      or request.headers.get("x-request-id") or "")

    try:
        await db.execute(
            "INSERT INTO admin_audit_log (timestamp, admin_account_id, "
            "admin_username, admin_role, action, target_type, target, "
            "old_value, new_value, reason, result, remote_addr, session_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                _now(), admin.get("id"), str(admin.get("username", "")),
                str(admin.get("role", "")), str(action), str(target_type),
                str(target), _encode_audit_value(old_value),
                _encode_audit_value(new_value), str(reason or "")[:500],
                str(result), remote_addr[:64], str(session_id)[:64],
            ),
        )
        await db.commit()
    except Exception as exc:  # pragma: no cover - defensive
        print(f"[NOVAGATE] AUDIT WRITE FAILED action={action} "
              f"admin={admin.get('username')} err={exc}", flush=True)


# ---------------------------------------------------------------------------
# Mutes (chat moderation)
# ---------------------------------------------------------------------------
async def is_muted(db: aiosqlite.Connection, player_id: str) -> tuple:
    """(is_muted, reason) for a player. An expired mute reads as not muted."""
    cursor = await db.execute(
        "SELECT muted, reason, until_ts FROM player_mutes WHERE player_id = ?",
        (player_id,),
    )
    row = await cursor.fetchone()
    if row is None or not int(row[0]):
        return False, ""
    until = int(row[2])
    if until and until <= _now():
        return False, ""
    return True, str(row[1] or "")


async def set_mute(
    db: aiosqlite.Connection,
    player_id: str,
    username: str,
    muted: bool,
    reason: str,
    until_ts: int,
    muted_by: str,
) -> None:
    now = _now()
    await db.execute(
        "INSERT INTO player_mutes (player_id, username, muted, reason, "
        "until_ts, muted_by, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(player_id) DO UPDATE SET muted = excluded.muted, "
        "reason = excluded.reason, until_ts = excluded.until_ts, "
        "muted_by = excluded.muted_by, updated_at = excluded.updated_at",
        (player_id, username, 1 if muted else 0, reason, int(until_ts),
         muted_by, now, now),
    )
    await db.commit()
# __APPEND__


