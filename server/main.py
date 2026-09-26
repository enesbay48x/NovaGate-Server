import asyncio
import os
import secrets
import time
import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

import bcrypt
import jwt
import aiosqlite
from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from slowapi import Limiter
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from starlette.responses import JSONResponse

from config import (
    ACCESS_TOKEN_EXPIRE_SECONDS,
    REFRESH_TOKEN_EXPIRE_SECONDS,
    RATE_LIMIT_LOGIN,
    RATE_LIMIT_REGISTER,
    SECRET_KEY,
    DB_PATH,
    ADMIN_USERNAME,
    ADMIN_PASSWORD,
    ADMIN_ROLE,
    FIRST_REGISTRATION_REWARD_BTC,
    FIRST_REGISTRATION_REWARD_PLT,
    FIRST_REGISTRATION_REWARD_ITEMS,
)
from websocket_server import manager as ws_manager, npc_manager
from item_catalog import (
    catalog_seeds,
    display_name,
    normalize_inventory,
    normalize_item_id,
)
import journal
import schema as db_schema
import player_state
import combat as combat_service
import game_data
import admin_core
import gate_service
import schedulers
import routes_admin

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
JWT_ALGORITHM = "HS256"
PASSWORD_MIN_LENGTH = 6
PASSWORD_MAX_LENGTH = 128
USERNAME_MIN_LENGTH = 3
USERNAME_MAX_LENGTH = 30
SHIP_ID_DEFAULT = "Ship10"
SESSION_EXPIRE_SECONDS = 86400  # 24h

# Reason string written into the `transactions` table for the first-registration
# reward. Kept as a constant so audits/tests can assert on it.
FIRST_REGISTRATION_REWARD_REASON = "first_registration_reward"


def _parse_first_registration_reward_items(raw: str) -> list:
    """Parse "item_id:quantity,item_id:quantity" into [(item_id, quantity)].

    Malformed entries are skipped instead of raising: a bad env value must
    never make registration fail (the currency part is the important part).
    """
    result = []
    for chunk in (raw or "").split(","):
        chunk = chunk.strip()
        if not chunk or ":" not in chunk:
            continue
        item_id, _, qty_text = chunk.partition(":")
        item_id = item_id.strip()
        try:
            qty = int(qty_text.strip())
        except ValueError:
            continue
        if item_id and qty > 0:
            # Phase 1: fold the configured id onto the canonical id so an
            # operator writing "Kalkan 1" in the env still grants `kalkan1`.
            result.append((normalize_item_id(item_id), qty))
    return result

# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------
app = FastAPI(title="NovaGate Auth Server", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

limiter = Limiter(key_func=get_remote_address, default_limits=[])
app.state.limiter = limiter


def reset_rate_limits():
    """Reset the in-memory rate limiter storage. Intended for testing."""
    try:
        if hasattr(limiter, "_storage"):
            limiter._storage.reset()
    except Exception:
        pass


async def seed_world_data(db) -> None:
    """Insert the static map/portal/level-gate rows defined in game_data.

    Uses INSERT OR IGNORE throughout, so it is safe on every boot and can
    never overwrite a row an operator has tuned by hand. A player's own state
    (loadouts, stats, ...) is NOT seeded here - that happens lazily per player.
    """
    for map_id, info in game_data.MAPS.items():
        await db.execute(
            "INSERT OR IGNORE INTO maps (map_id, display_name, company, "
            "min_level, is_pvp, is_hub, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                map_id,
                str(info.get("display", map_id)),
                str(info.get("company", "")),
                int(info.get("min_level", 1)),
                1 if info.get("is_pvp") else 0,
                1 if info.get("is_hub") else 0,
                int(info.get("order", 0)),
            ),
        )
        # A per-company gate row is written for the owning faction, and an
        # empty-company row for everyone else, so a lookup is always total.
        owner = str(info.get("company", ""))
        await db.execute(
            "INSERT OR IGNORE INTO map_level_requirements "
            "(map_id, min_level, company) VALUES (?, ?, ?)",
            (map_id, int(info.get("min_level", 1)), owner),
        )
        if not owner:
            for company in game_data.COMPANIES:
                await db.execute(
                    "INSERT OR IGNORE INTO map_level_requirements "
                    "(map_id, min_level, company) VALUES (?, ?, ?)",
                    (map_id, int(info.get("min_level", 1)), company),
                )

    for order, portal in enumerate(game_data.PORTALS):
        await db.execute(
            "INSERT OR IGNORE INTO map_connections (portal_id, from_map, "
            "to_map, from_rect_x, from_rect_y, from_rect_w, from_rect_h, "
            "min_level, companies, sort_order) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                portal["portal_id"], portal["from_map"], portal["to_map"],
                portal["x"], portal["y"], portal["w"], portal["h"],
                int(portal["min_level"]), str(portal.get("companies", "")),
                order,
            ),
        )

    # Galaxy Gate part definitions (Phase 5). The gate id and the required
    # parts are server data; only the player's progress in them is per-account.
    for gate_id, parts in game_data.GATE_PART_DEFINITIONS.items():
        for part_id, (required, min_level) in parts.items():
            await db.execute(
                "INSERT OR IGNORE INTO gate_parts (gate_id, part_id, required, "
                "min_level) VALUES (?, ?, ?, ?)",
                (gate_id, part_id, int(required), int(min_level)),
            )

    await db.commit()


async def ensure_player_world_state(db, player_id: str, company: str = "") -> dict:
    """Create the player's world row on first sight and return it.

    The spawn map is the company's start map, so a brand-new account lands
    where the client expects. `company` is only used the FIRST time, so
    returning players are never teleported by a company change.
    """
    spawn = game_data.COMPANY_START_MAP.get(
        company.strip().upper(), game_data.DEFAULT_MAP
    )
    await db.execute(
        "INSERT OR IGNORE INTO player_world_state (player_id, map_id, "
        "position_x, position_y, updated_at) VALUES (?, ?, 0, 0, ?)",
        (player_id, spawn, _unix_now()),
    )
    cursor = await db.execute(
        "SELECT map_id, position_x, position_y FROM player_world_state "
        "WHERE player_id = ?",
        (player_id,),
    )
    row = await cursor.fetchone()
    if row is None:
        return {"map_id": spawn, "position_x": 0.0, "position_y": 0.0}
    return {"map_id": str(row[0]),
            "position_x": float(row[1]), "position_y": float(row[2])}


async def save_player_world_state(db, player_id: str, map_id: str,
                                  x: float, y: float) -> None:
    await db.execute(
        "UPDATE player_world_state SET map_id = ?, position_x = ?, "
        "position_y = ?, updated_at = ? WHERE player_id = ?",
        (map_id, float(x), float(y), _unix_now(), player_id),
    )


async def _build_player_state_payload(db, player_id: str, ship_id: str = "",
                                      company: str = "") -> dict:
    """The single server-authoritative view of a player.

    Built once per login / world sync and reused by every endpoint, so the
    login payload, /player/full and the world snapshot can never disagree.

    `company` only affects the FIRST spawn: a returning player keeps the map the
    server last had them on.
    """
    stats = await player_state.get_stats(db, player_id)
    ship = ship_id or game_data.DEFAULT_SHIP
    world = await ensure_player_world_state(db, player_id, company)
    equipment = await combat_service.equipped_damage(db, player_id, ship)
    ammo = await combat_service.get_ammo(db, player_id)
    loadouts = await _stored_loadouts_for_client(db, player_id, ship)
    selected = 1
    if loadouts:
        for key, value in loadouts.items():
            raw = await player_state.get_loadout(db, player_id, ship, int(key))
            if raw.get("selected"):
                selected = int(key)
    return {
        "stats": player_state.stats_payload(stats),
        "world": world,
        "ship_id": ship,
        "equipment": equipment,
        "ammo": ammo,
        "loadouts": loadouts,
        "ship_configurations": loadouts,
        "selected_config": selected,
    }


# ---------------------------------------------------------------------------
# Client-facing shape helpers
# ---------------------------------------------------------------------------
# The client already reads `ship_configurations` as
# {ship_id: {"1": {...}, "2": {...}}} where each config has
# lasers / generators / extras / drones. The server stores the same four slot
# lists (drones live in player_droids, so the config's drone list is echoed
# through) - this reshapes the DB rows into exactly that structure.
async def _stored_loadouts_for_client(db, player_id: str, ship_id: str) -> dict:
    """The player's stored Config 1 / Config 2, or {} when there are none.

    R2 in test_pipeline_regressions guards a real hazard: sending an EMPTY
    loadout made the client overwrite a returning player's own equipment on
    every login. Phase 2 makes the server authoritative over loadouts, but
    that protection still holds, so the key is omitted entirely until the
    player has actually used the loadout endpoints. Only then does the server
    speak for their configuration.
    """
    cursor = await db.execute(
        "SELECT COUNT(*) FROM loadouts WHERE player_id = ? AND ship_id = ?",
        (player_id, ship_id),
    )
    if (await cursor.fetchone())[0] == 0:
        return {}
    return _configurations_for_client(
        await player_state.get_all_loadouts(db, player_id, ship_id)
    )


def _configurations_for_client(loadouts: dict) -> dict:
    return {
        "1": _config_for_client(loadouts.get("1", {})),
        "2": _config_for_client(loadouts.get("2", {})),
    }


def _config_for_client(loadout: dict) -> dict:
    return {
        "lasers": list(loadout.get("lasers", [])),
        "generators": list(loadout.get("generators", [])),
        "extras": list(loadout.get("extras", [])),
        "drones": list(loadout.get("drone_slots", [])),
    }


# The client's GlobalState.ammo_inventory is keyed by the short names it
# already uses ("X1", "SAB", "RSB", "R1"...). Server ids are canonical package
# ids, so they are mapped back here for display/consumption and the client
# still never decides the count.
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


@app.get("/health")
async def health():
    return {"status": "ok"}


async def require_admin(request: Request):
    """Legacy 2-role guard, kept so the original admin endpoints keep working.

    It now accepts any STAFF role (moderator, admin, superadmin) rather than
    only the literal "admin", which is what makes the 4-tier matrix usable.
    New endpoints use `routes_admin`'s `require_permission(...)` instead,
    because a whole permission set is more precise than a role string.
    """
    account = await get_current_account(request)
    if not admin_core.is_staff(account.get("role")):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN,
                            detail="Staff role required")
    return account
# --------------------------------------------------------------------------
# LEGACY ADMIN ROUTES REMOVED
# --------------------------------------------------------------------------
# These handlers used to live here, guarded only by `require_admin` (which
# admits ANY staff role). Because they were registered BEFORE
# `routes_admin.register_routes(...)`, they shadowed the permission-gated
# versions of the same paths: /admin/npcs answered 200 for a moderator,
# and /admin/player/{id}/role used the old 2-role rules instead of the
# rank model.
#
# `routes_admin` now owns every one of these paths, each behind a specific
# permission, with a richer response and an audit-log write.
#
# `require_admin` and `_admin_log` are intentionally KEPT: the guard is the
# staff-tier check other code imports, and the helper writes to the legacy
# `admin_log` table that still exists in existing databases.




async def _admin_log(db, admin: dict, action: str, target: str, details: str, result: str = "success"):
    await db.execute(
        "INSERT INTO admin_log (timestamp, admin_account_id, admin_username, target_username, action, amount, reason, result) "
        "VALUES (?, ?, ?, ?, ?, NULL, ?, ?)",
        (_unix_now(), admin["id"], admin["username"], target, action, details, result),
    )


@app.exception_handler(RateLimitExceeded)
async def rate_limit_handler(request: Request, exc: RateLimitExceeded):
    return JSONResponse(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        content={"success": False, "message": "Rate limit exceeded. Try again later."},
    )


app.add_exception_handler(RateLimitExceeded, rate_limit_handler)


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
class RegisterRequest(BaseModel):
    username: str = Field(..., min_length=USERNAME_MIN_LENGTH, max_length=USERNAME_MAX_LENGTH)
    password: str = Field(..., min_length=PASSWORD_MIN_LENGTH, max_length=PASSWORD_MAX_LENGTH)
    nickname: str = Field("", max_length=40)
    company: str = Field("", max_length=10)


class LoginRequest(BaseModel):
    username: str
    password: str


class RefreshRequest(BaseModel):
    refresh_token: str

class CompanyUpdateRequest(BaseModel):
    company: str


class JournalAckRequest(BaseModel):
    """Acknowledge journal entries. An empty `ids` acknowledges everything."""
    ids: list[int] = Field(default_factory=list)


class AdminCurrencyRequest(BaseModel):
    currency: str
    amount: int


class AdminRoleRequest(BaseModel):
    role: str


class AdminTeleportRequest(BaseModel):
    map_id: str
    x: float
    y: float


class AdminNpcSpawnRequest(BaseModel):
    npc_type: str
    map_id: str
    x: float = 0.0
    y: float = 0.0




# ---------------------------------------------------------------------------
# Database initialization
# ---------------------------------------------------------------------------
async def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executescript(
            """
            CREATE TABLE IF NOT EXISTS accounts (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                username        TEXT UNIQUE NOT NULL,
                password_hash   TEXT NOT NULL,
                player_id       TEXT UNIQUE NOT NULL,
                nickname        TEXT,
                company         TEXT,
                role            TEXT DEFAULT 'player',
                created_at      INTEGER NOT NULL,
                starter_reward_claimed INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS sessions (
                id              TEXT PRIMARY KEY,
                account_id      INTEGER NOT NULL,
                player_id       TEXT NOT NULL,
                refresh_token   TEXT UNIQUE NOT NULL,
                refresh_jti     TEXT NOT NULL,
                created_at      INTEGER NOT NULL,
                last_seen       INTEGER NOT NULL,
                expires_at      INTEGER NOT NULL,
                active          INTEGER NOT NULL DEFAULT 1,
                ship_id         TEXT,
                FOREIGN KEY (account_id) REFERENCES accounts(id)
            );

            CREATE INDEX IF NOT EXISTS idx_sessions_refresh_token ON sessions(refresh_token);
            CREATE INDEX IF NOT EXISTS idx_sessions_expires_at ON sessions(expires_at);

            CREATE TABLE IF NOT EXISTS economy (
                player_id       TEXT PRIMARY KEY,
                btc             INTEGER NOT NULL DEFAULT 0,
                plt             INTEGER NOT NULL DEFAULT 0,
                gold            INTEGER NOT NULL DEFAULT 0,
                updated_at      INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS inventory (
                player_id       TEXT NOT NULL,
                item_id         TEXT NOT NULL,
                quantity        INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (player_id, item_id)
            );

            CREATE TABLE IF NOT EXISTS transactions (
                id              TEXT PRIMARY KEY,
                player_id       TEXT NOT NULL,
                currency        TEXT NOT NULL,
                amount          INTEGER NOT NULL,
                reason          TEXT NOT NULL,
                reference_id    TEXT,
                timestamp       INTEGER NOT NULL,
                FOREIGN KEY (player_id) REFERENCES accounts(player_id)
            );

            CREATE INDEX IF NOT EXISTS idx_transactions_player ON transactions(player_id);
            CREATE INDEX IF NOT EXISTS idx_transactions_timestamp ON transactions(timestamp);

            CREATE TABLE IF NOT EXISTS item_catalog (
                item_id         TEXT PRIMARY KEY,
                name            TEXT NOT NULL,
                category        TEXT NOT NULL,
                price           INTEGER NOT NULL,
                currency        TEXT NOT NULL,
                item_type       TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS admin_log (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp       INTEGER NOT NULL,
                admin_account_id INTEGER NOT NULL,
                admin_username  TEXT NOT NULL,
                target_account_id INTEGER,
                target_username  TEXT,
                action          TEXT NOT NULL,
                amount          TEXT,
                reason          TEXT,
                result          TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_admin_log_timestamp ON admin_log(timestamp);
            CREATE INDEX IF NOT EXISTS idx_admin_log_admin_username ON admin_log(admin_username);
            CREATE INDEX IF NOT EXISTS idx_admin_log_target_username ON admin_log(target_username);

            -- Phase 1: server-authoritative Seyir Defteri (event journal).
            -- One row per player-visible event. The client only ever renders
            -- these rows; it never authors them.
            CREATE TABLE IF NOT EXISTS event_journal (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                player_id       TEXT NOT NULL,
                event_type      TEXT NOT NULL,
                severity        TEXT NOT NULL DEFAULT 'info',
                message         TEXT NOT NULL,
                details         TEXT,
                acknowledged    INTEGER NOT NULL DEFAULT 0,
                created_at      INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_event_journal_player
                ON event_journal(player_id, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_event_journal_type
                ON event_journal(event_type);
            """
        )
        await db.commit()

        # Additive migration: databases created by an earlier Phase 1 build
        # have event_journal without `acknowledged`. Adding a column with a
        # NOT NULL DEFAULT is safe on an existing table (every existing row
        # reads back 0 = "unread") and is a no-op once applied.
        try:
            await db.execute(
                "ALTER TABLE event_journal "
                "ADD COLUMN acknowledged INTEGER NOT NULL DEFAULT 0"
            )
            await db.commit()
        except aiosqlite.OperationalError:
            # "duplicate column name" -> already migrated.
            pass

        # Additive migration for databases created before the first-registration
        # reward existed. `CREATE TABLE IF NOT EXISTS` above is a no-op for those,
        # so the column is added here. Existing rows keep the DEFAULT 0, which
        # means "never granted" - they are NOT back-paid, because the reward is
        # only ever written inside POST /auth/register for a brand new account.
        try:
            await db.execute(
                "ALTER TABLE accounts ADD COLUMN starter_reward_claimed INTEGER NOT NULL DEFAULT 0"
            )
            await db.commit()
        except aiosqlite.OperationalError:
            # "duplicate column name" -> already migrated.
            pass

    # Phases 2-7: every remaining table + additive column, then the static
    # world rows (maps, portals, level gates, gate part definitions).
    #
    # A NEW connection is opened rather than reusing the one above, because
    # that `async with` has already closed. Both steps are idempotent:
    # `apply_schema` only creates what is missing, and `seed_world_data` uses
    # INSERT OR IGNORE, so an existing database is never rewritten.
    async with aiosqlite.connect(DB_PATH) as db:
        await db_schema.apply_schema(db)
        await seed_world_data(db)

    # Phase 1: the catalog is now owned by item_catalog.py so that the reward
    # grant, the market and the client all agree on one canonical id per item.
    #
    # This ALWAYS runs (not only on an empty table) with INSERT OR IGNORE, so an
    # existing database gains the newly added ids (PBMB/WSH/EMP/INVIS/FREP/ACPR)
    # without its rows being rewritten. Because it is INSERT OR IGNORE, a price
    # that an operator already tuned by hand is preserved - this seed can only
    # ever add a missing row, never modify an existing one.
    async with aiosqlite.connect(DB_PATH) as db:
        await db.executemany(
            "INSERT OR IGNORE INTO item_catalog "
            "(item_id, name, category, price, currency, item_type) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            catalog_seeds(),
        )
        await db.commit()


# ---------------------------------------------------------------------------
# Database bootstrap
# ---------------------------------------------------------------------------
# There are NO hardcoded/seeded player accounts.
#
# Every player is created through the single standard pipeline
# (POST /auth/register -> POST /auth/login -> /ws/game), and every player_id is
# generated by the server. No username is ever special-cased, and no account
# exists that did not come through that public pipeline.
#
# The only bootstrap left is the optional admin account, which is driven purely
# by the ADMIN_USERNAME / ADMIN_PASSWORD environment variables.
# ---------------------------------------------------------------------------


async def _bootstrap_admin(db) -> None:
    """Create/repair the staff account from the ADMIN_* environment variables.

    - If the named account does not exist, create it (bcrypt hashed; the
      plaintext password is NEVER stored and never lives in the source).
    - If it exists, only ensure the configured role. Economy, inventory and
      password are left untouched, so a real operator keeps their password.

    The role comes from `ADMIN_ROLE` and is validated against the known role
    set; an unrecognised value falls back to "admin" rather than creating an
    account that can do nothing.
    """
    username = (ADMIN_USERNAME or "").strip()
    password = ADMIN_PASSWORD or ""
    if not username or not password:
        return

    role = str(ADMIN_ROLE or "").strip().lower()
    if role not in admin_core.VALID_ROLES:
        role = admin_core.ROLE_ADMIN

    existing = await (
        await db.execute("SELECT id, role FROM accounts WHERE username = ?", (username,))
    ).fetchone()
    if existing is None:
        now = _unix_now()
        player_id = _gen_player_id()
        await db.execute(
            "INSERT INTO accounts (username, password_hash, player_id, nickname, company, role, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (username, _hash_password(password), player_id, username, "", role, now),
        )
        await db.execute(
            "INSERT OR IGNORE INTO economy (player_id, btc, plt, gold, updated_at) "
            "VALUES (?, 0, 0, 0, ?)",
            (player_id, now),
        )
        await db.commit()
        return

    if existing[1] != role:
        await db.execute(
            "UPDATE accounts SET role = ? WHERE id = ?", (role, existing[0])
        )
        await db.commit()


async def _run_seed_bootstrap() -> None:
    """Run the environment-driven admin bootstrap once after schema init.

    No player accounts are created here: every player comes from
    POST /auth/register (the single standard account pipeline).
    """
    async with aiosqlite.connect(DB_PATH) as db:
        # The audit trail and its immutability triggers must exist BEFORE any
        # admin code path can run, otherwise the first admin action on a fresh
        # production database would have nowhere to record itself.
        await admin_core.ensure_admin_schema(db)
        await _bootstrap_admin(db)


@app.on_event("startup")
async def startup():
    await init_db()
    await _run_seed_bootstrap()
    from websocket_server import on_startup
    await on_startup(app, SECRET_KEY, DB_PATH)
    # Start the background sweeps. `SchedulerHub.start` performs one immediate
    # pass first, so auctions and events that expired while the process was
    # down are handled at boot rather than after a full interval.
    await schedulers.hub.start(DB_PATH)


@app.on_event("shutdown")
async def shutdown():
    # Cancel the scheduler cleanly so a redeploy does not leave a pending
    # sweep task writing to a database that is being closed.
    await schedulers.hub.stop()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _unix_now() -> int:
    return int(time.time())


def _hash_password(password: str) -> str:
    salt = bcrypt.gensalt(rounds=12)
    return bcrypt.hashpw(password.encode("utf-8"), salt).decode("utf-8")


def _verify_password(password: str, password_hash: str) -> bool:
    if not password_hash:
        return False
    try:
        return bcrypt.checkpw(password.encode("utf-8"), password_hash.encode("utf-8"))
    except (ValueError, TypeError):
        return False


def _gen_player_id() -> str:
    return str(uuid.uuid4()).replace("-", "")[:12]


def _gen_token_id() -> str:
    return secrets.token_urlsafe(32)


def _create_access_token(account_id: int, player_id: str, username: str, is_admin: bool, session_jti: str = "") -> str:
    expire = datetime.now(timezone.utc) + timedelta(seconds=ACCESS_TOKEN_EXPIRE_SECONDS)
    payload = {
        "sub": str(account_id),
        "player_id": player_id,
        "username": username,
        "is_admin": is_admin,
        "type": "access",
        "exp": expire,
        "iat": datetime.now(timezone.utc),
        "jti": _gen_token_id(),
        "session_jti": session_jti,
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALGORITHM)


def _create_refresh_token(account_id: int, player_id: str, username: str) -> tuple[str, str, int]:
    """Returns (refresh_token, refresh_jti, expires_at_unix)."""
    expires_at = _unix_now() + REFRESH_TOKEN_EXPIRE_SECONDS
    payload = {
        "sub": str(account_id),
        "player_id": player_id,
        "username": username,
        "type": "refresh",
        "exp": datetime.now(timezone.utc) + timedelta(seconds=REFRESH_TOKEN_EXPIRE_SECONDS),
        "iat": datetime.now(timezone.utc),
        "jti": _gen_token_id(),
    }
    jti = payload["jti"]
    token = jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALGORITHM)
    return token, jti, expires_at


def _decode_token(token: str) -> dict:
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[JWT_ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    if payload.get("type") != "access":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token type")
    return payload


async def get_current_account(request: Request) -> dict:
    auth_header: Optional[str] = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing or invalid Authorization header")
    token = auth_header[7:]
    payload = _decode_token(token)
    account_id = int(payload["sub"])
    session_jti = payload.get("session_jti", "")

    async with aiosqlite.connect(DB_PATH) as db:
        # If session_jti is present, verify the session is still active.
        # This ensures that logout, double-login, and session expiry
        # invalidate the access token immediately.
        if session_jti:
            cursor = await db.execute(
                "SELECT active, expires_at FROM sessions WHERE refresh_jti = ? ORDER BY created_at DESC LIMIT 1",
                (session_jti,),
            )
            row = await cursor.fetchone()
            if not row or not row[0]:
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session inactive")
            now = _unix_now()
            if now > row[1]:
                raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session expired")

        cursor = await db.execute(
            "SELECT id, username, player_id, company, role FROM accounts WHERE id = ?",
            (account_id,),
        )
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Account not found")
        return {
            "id": row[0],
            "username": row[1],
            "player_id": row[2],
            "company": row[3],
            "role": row[4],
            "is_admin": row[4] == "admin",
        }


@app.put("/account/company")
async def update_company(request: CompanyUpdateRequest, account: dict = Depends(get_current_account)):
    company = request.company.strip().upper()
    if company not in {"EIC", "MMO", "VRU"}:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid company")
    async with aiosqlite.connect(DB_PATH) as db:
        previous = await (
            await db.execute(
                "SELECT company FROM accounts WHERE id = ?", (account["id"],)
            )
        ).fetchone()
        await db.execute("UPDATE accounts SET company = ? WHERE id = ?", (company, account["id"]))
        # Phase 1: a company switch is a permanent, expensive decision, so it
        # belongs in the permanent Seyir Defteri.
        await journal.log_company_change(
            db, str(account.get("player_id") or ""),
            (previous[0] if previous else "") or "", company,
        )
        await db.commit()
    # The database row stays authoritative, but an OPEN WebSocket session keeps
    # its own copy of the company. Writing only the row left the live session on
    # the old value, so peers kept seeing company "" / relation "neutral" and
    # server-authoritative PvP stayed off until the player reconnected.
    await ws_manager.set_company(str(account.get("player_id") or ""), company)
    return {"success": True, "company": company}


# ---------------------------------------------------------------------------
# The 4-tier role set. Sourced from admin_core so the router and main.py can
# never disagree about what a valid role is.
# ---------------------------------------------------------------------------
VALID_ROLES = set(admin_core.VALID_ROLES)


# Auth endpoints
# ---------------------------------------------------------------------------
@app.post("/auth/register")
@limiter.limit(RATE_LIMIT_REGISTER)
async def register(request: Request, req: RegisterRequest):
    password_hash = _hash_password(req.password)
    now = _unix_now()

    reward_btc = max(0, int(FIRST_REGISTRATION_REWARD_BTC))
    reward_plt = max(0, int(FIRST_REGISTRATION_REWARD_PLT))
    reward_items = _parse_first_registration_reward_items(FIRST_REGISTRATION_REWARD_ITEMS)

    async with aiosqlite.connect(DB_PATH) as db:
        # player_id must be unique per account. Generate until a free id is
        # found; after the retry budget is exhausted fail loudly instead of
        # silently inserting a duplicated player_id.
        player_id = ""
        for _ in range(5):
            candidate = _gen_player_id()
            clash = await (
                await db.execute(
                    "SELECT 1 FROM accounts WHERE player_id = ?", (candidate,)
                )
            ).fetchone()
            if clash is None:
                player_id = candidate
                break
        if not player_id:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Could not allocate a unique player_id, please retry",
            )

        # ------------------------------------------------------------------
        # İLK KAYIT ÖDÜLÜ (server-authoritative, exactly once)
        # ------------------------------------------------------------------
        # The account row, its economy row, the reward items and the reward
        # transaction logs are written inside ONE explicit transaction, so a
        # failure can never leave a half-credited account behind.
        #
        # The reward block below is the ONLY place the grant is ever written,
        # and it is reached only from a successful INSERT of a brand new
        # `accounts` row. Therefore:
        #   * login can never re-grant it (nothing here runs on /auth/login),
        #   * registering an existing username is rejected with 409 before any
        #     economy row is created,
        #   * existing accounts are untouched - no back-pay, no migration of
        #     balances.
        await db.execute("BEGIN IMMEDIATE TRANSACTION")
        try:
            cursor = await db.execute(
                "INSERT INTO accounts (username, password_hash, player_id, nickname, company, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (req.username, password_hash, player_id, req.nickname or req.username, req.company, now),
            )
            account_id = cursor.lastrowid

            # Every account gets its OWN economy/inventory state keyed by its
            # unique player_id. Nothing is copied from any other account; the
            # starting balance IS the first-registration reward.
            await db.execute(
                "INSERT OR IGNORE INTO economy (player_id, btc, plt, gold, updated_at) VALUES (?, ?, ?, 0, ?)",
                (player_id, reward_btc, reward_plt, now),
            )

            if reward_btc:
                await db.execute(
                    "INSERT INTO transactions (id, player_id, currency, amount, reason, reference_id, timestamp) "
                    "VALUES (?, ?, 'BTC', ?, ?, NULL, ?)",
                    (_gen_token_id(), player_id, reward_btc, FIRST_REGISTRATION_REWARD_REASON, now),
                )
            if reward_plt:
                await db.execute(
                    "INSERT INTO transactions (id, player_id, currency, amount, reason, reference_id, timestamp) "
                    "VALUES (?, ?, 'PLT', ?, ?, NULL, ?)",
                    (_gen_token_id(), player_id, reward_plt, FIRST_REGISTRATION_REWARD_REASON, now),
                )

            for item_id, quantity in reward_items:
                row = await (
                    await db.execute(
                        "SELECT quantity FROM inventory WHERE player_id = ? AND item_id = ?",
                        (player_id, item_id),
                    )
                ).fetchone()
                if row:
                    await db.execute(
                        "UPDATE inventory SET quantity = ? WHERE player_id = ? AND item_id = ?",
                        (int(row[0]) + quantity, player_id, item_id),
                    )
                else:
                    await db.execute(
                        "INSERT INTO inventory (player_id, item_id, quantity) VALUES (?, ?, ?)",
                        (player_id, item_id, quantity),
                    )

            # Marks the reward as taken for this account.
            await db.execute(
                "UPDATE accounts SET starter_reward_claimed = 1 WHERE id = ?",
                (account_id,),
            )

            # Phase 1: the first journal entry is written in the SAME
            # transaction, so a rolled-back registration also leaves no
            # orphaned "welcome aboard" entry behind.
            await journal.record_event(
                db, player_id, journal.EVENT_REGISTER,
                f"{req.username} icin yeni hesap olusturuldu",
                journal.SEVERITY_GOOD,
                {
                    "username": req.username,
                    "starter_reward": {
                        "btc": reward_btc,
                        "plt": reward_plt,
                        "items": {i: q for i, q in reward_items},
                    },
                },
            )

            await db.commit()
        except aiosqlite.IntegrityError:
            await db.rollback()
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Username already exists")
        except HTTPException:
            await db.rollback()
            raise
        except Exception:
            await db.rollback()
            if os.environ.get("NOVAGATE_DEBUG_REGISTER"):
                import traceback
                traceback.print_exc()
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="First-registration reward transaction failed and was rolled back",
            )

    return {
        "success": True,
        "message": "Account created",
        "account_id": account_id,
        "player_id": player_id,
        "username": req.username,
        # Echoed so the client / tests can assert the grant really happened.
        "first_registration_reward": {
            "btc": reward_btc,
            "plt": reward_plt,
            "items": {item_id: quantity for item_id, quantity in reward_items},
        },
    }


@app.post("/auth/login")
@limiter.limit(RATE_LIMIT_LOGIN)
async def login(request: Request, req: LoginRequest):
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT id, username, password_hash, player_id, company, role FROM accounts WHERE username = ?",
            (req.username,),
        )
        row = await cursor.fetchone()

    if not row or not _verify_password(req.password, row[2]):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid username or password")

    account_id = row[0]
    username = row[1]
    player_id = row[3]
    company = row[4] or ""
    is_admin = row[5] == "admin"

    # Invalidate any previous active session for this account (single session policy)
    refresh_token, refresh_jti, expires_at = _create_refresh_token(account_id, player_id, username)
    session_id = _gen_token_id()
    now = _unix_now()

    async with aiosqlite.connect(DB_PATH) as db:
        # Invalidate all previous sessions for this account
        await db.execute(
            "UPDATE sessions SET active = 0 WHERE account_id = ? AND active = 1",
            (account_id,),
        )
        await db.execute(
            "INSERT INTO sessions (id, account_id, player_id, refresh_token, refresh_jti, "
            "created_at, last_seen, expires_at, active, ship_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)",
            (session_id, account_id, player_id, refresh_token, refresh_jti, now, now, expires_at, SHIP_ID_DEFAULT),
        )
        await db.commit()

    access_token = _create_access_token(account_id, player_id, username, is_admin, refresh_jti)

    # --- Server-authoritative full player payload ---------------------------
    # The client (PC + Android) mirrors this into its local players.json via
    # account_manager.sync_server_player_to_local(). Without the "oyuncu" key
    # the client has no ship / inventory / equipment / BTC / PLT / Gold /
    # progression to load, so Android falls back to a fresh empty account and
    # prompts for re-registration on every launch.
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
            (player_id,),
        )
        econ_row = await cursor.fetchone()
        cursor = await db.execute(
            "SELECT item_id, quantity FROM inventory WHERE player_id = ?",
            (player_id,),
        )
        inv_rows = await cursor.fetchall()
        cursor = await db.execute(
            "SELECT ship_id FROM sessions WHERE player_id = ? AND active = 1 "
            "ORDER BY last_seen DESC LIMIT 1",
            (player_id,),
        )
        ship_row = await cursor.fetchone()

        # Phase 1: the login payload is the client's ONLY view of the economy.
        # Normalizing here guarantees the client never receives two spellings of
        # the same physical item, and drops any zero-quantity row.
        server_inventory: dict = normalize_inventory(
            {str(r[0]): int(r[1]) for r in inv_rows}
        )

        # Phase 1: login is a journal event. Written after the session row so a
        # failed login never leaves an entry.
        await journal.log_login(db, player_id, username)

        # Phase 2: the server owns level / xp / honor / hp / shield / kills /
        # deaths, plus the world position, the loadouts, the equipment
        # aggregate and the ammo stock. Built here so the login payload, the
        # world snapshot and /player/full can never disagree.
        active_ship = str(ship_row[0]) if ship_row and ship_row[0] else SHIP_ID_DEFAULT
        await player_state.ensure_stats(db, player_id)
        await combat_service.ensure_starter_ammo(db, player_id)
        authoritative = await _build_player_state_payload(
            db, player_id, active_ship, company
        )
        # The first-login spawn follows the company; a returning player keeps
        # the map the server last had them on. _build_player_state_payload
        # already created the row, so this second call is a no-op lookup.
        await ensure_player_world_state(db, player_id, company)
        await db.commit()

    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_SECONDS,
        "player_id": player_id,
        "username": username,
        "company": company,
        "is_admin": is_admin,
        # "oyuncu" is the single source of truth the Godot client syncs from.
        # Every field sync_server_player_to_local() reads MUST be present here
        # so PC and Android resolve to the identical account / player / ship /
        # inventory / equipment / BTC / PLT / Gold / progression.
        #
        # Ownership fields the server does NOT track (owned_ships,
        # droid_types) are intentionally OMITTED rather than sent as empty
        # defaults. Sending empty defaults made the client overwrite a real
        # player's ships/loadout with "Ship10 only" on every login, which
        # silently destroyed progression. `ship_configurations` follows the
        # same rule: it appears only once the server has a stored loadout.
        "oyuncu": {
            "id": player_id,
            "username": username,
            "company": company,
            # Phases 2-3: real progression, not the old hardcoded 1/0/0.
            "level": authoritative["stats"]["level"],
            "exp": authoritative["stats"]["xp"],
            "honor": authoritative["stats"]["honor"],
            "hp": authoritative["stats"]["hp"],
            "max_hp": authoritative["stats"]["max_hp"],
            "shield": authoritative["stats"]["shield"],
            "max_shield": authoritative["stats"]["max_shield"],
            "npc_kills": authoritative["stats"]["npc_kills"],
            "player_kills": authoritative["stats"]["player_kills"],
            "deaths": authoritative["stats"]["deaths"],
            "bitcoin": int(econ_row[0]) if econ_row else 0,
            "plt": int(econ_row[1]) if econ_row else 0,
            "gold": int(econ_row[2]) if econ_row else 0,
            "inventory": server_inventory,
            "active_ship_id": active_ship,
            "is_admin": is_admin,
            "map": authoritative["world"]["map_id"],
            # Ammo is server-owned from Phase 2; the client mirrors it.
            "ammo_inventory": _ammo_for_client(authoritative["ammo"]),
            "equipment_stats": authoritative["equipment"],
        },
        # Config 1 / Config 2 + the active selection. Present ONLY when the
        # server holds a stored loadout (see _stored_loadouts_for_client).
        **({"ship_configurations": authoritative["ship_configurations"],
            "selected_config": authoritative["selected_config"]}
           if authoritative["ship_configurations"] else {}),
    }


@app.post("/auth/refresh")
@limiter.limit("10/minute")
async def refresh(request: Request, req: RefreshRequest):
    try:
        payload = jwt.decode(req.refresh_token, SECRET_KEY, algorithms=[JWT_ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")

    if payload.get("type") != "refresh":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token type")

    account_id = int(payload["sub"])
    player_id = payload["player_id"]
    username = payload["username"]
    refresh_jti = payload.get("jti")

    now = _unix_now()

    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT id, account_id, player_id, active, expires_at FROM sessions "
            "WHERE refresh_jti = ? AND active = 1",
            (refresh_jti,),
        )
        row = await cursor.fetchone()

        if not row:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session not found or inactive")

        session_id = row[0]
        db_account_id = row[1]
        db_player_id = row[2]
        db_active = row[3]
        db_expires_at = row[4]

        if db_account_id != account_id or db_player_id != player_id:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token/account mismatch")

        if now > db_expires_at:
            await db.execute("UPDATE sessions SET active = 0 WHERE id = ?", (session_id,))
            await db.commit()
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session expired")

        if not db_active:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session inactive")

        # Update last_seen
        new_expires_at = now + REFRESH_TOKEN_EXPIRE_SECONDS
        await db.execute(
            "UPDATE sessions SET last_seen = ?, expires_at = ? WHERE id = ?",
            (now, new_expires_at, session_id),
        )
        await db.commit()

        cursor = await db.execute(
            "SELECT username, company, role FROM accounts WHERE id = ?",
            (db_account_id,),
        )
        account_row = await cursor.fetchone()

    is_admin = account_row[2] == "admin"
    new_refresh_token, new_refresh_jti, new_expires_at = _create_refresh_token(
        db_account_id, db_player_id, account_row[0]
    )

    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE sessions SET refresh_token = ?, refresh_jti = ?, expires_at = ? WHERE id = ?",
            (new_refresh_token, new_refresh_jti, new_expires_at, session_id),
        )
        await db.commit()

    # The access token MUST be bound to the session that was just rotated.
    # Without session_jti the refreshed token skipped session validation on
    # every request AND made ConnectionManager.connect() skip the company
    # lookup, which dropped the live session back to company "" and disabled
    # PvP relation. The rotated jti is the value now stored in
    # sessions.refresh_jti, so it is the one that validates.
    access_token = _create_access_token(
        db_account_id, db_player_id, account_row[0], is_admin, new_refresh_jti
    )

    return {
        "access_token": access_token,
        "refresh_token": new_refresh_token,
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_SECONDS,
        "player_id": db_player_id,
        "username": account_row[0],
        "company": account_row[1] or "",
        "is_admin": is_admin,
    }


@app.post("/auth/logout")
@limiter.limit("20/minute")
async def logout(request: Request):
    auth_header: Optional[str] = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")

    access_token = auth_header[7:]
    try:
        payload = jwt.decode(access_token, SECRET_KEY, algorithms=[JWT_ALGORITHM])
        if payload.get("type") != "access":
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token type")
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

    account_id = int(payload["sub"])
    player_id = str(payload.get("player_id", ""))

    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE sessions SET active = 0 WHERE account_id = ? AND active = 1",
            (account_id,),
        )
        # Phase 1: journalled before the session is killed, so a player who
        # logs out and back in can see when they were last seen.
        if player_id:
            await journal.log_logout(db, player_id, str(payload.get("username", "")))
        await db.commit()

    # Close the live WebSocket session of THIS player only. Other players'
    # sessions are untouched.
    if player_id:
        try:
            await ws_manager.kick(player_id, reason="logged_out")
        except Exception:
            pass

    return {"success": True, "message": "Logged out"}


@app.get("/auth/verify")
async def verify(account: dict = Depends(get_current_account)):
    return {
        "valid": True,
        "account_id": account["id"],
        "player_id": account["player_id"],
        "username": account["username"],
        "company": account["company"],
        "is_admin": account["is_admin"],
    }


@app.get("/auth/session")
async def session_info(account: dict = Depends(get_current_account)):
    return {
        "account_id": account["id"],
        "player_id": account["player_id"],
        "username": account["username"],
        "company": account["company"],
        "is_admin": account["is_admin"],
    }


# ---------------------------------------------------------------------------
# Economy endpoints (server-authoritative)
# ---------------------------------------------------------------------------
def _get_economy(account: dict) -> dict:
    """Get or create economy record for a player."""
    return {"player_id": account["player_id"]}


@app.get("/player/balance")
async def get_balance(account: dict = Depends(get_current_account)):
    """Return server-authoritative currency balances for the authenticated player."""
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
            (account["player_id"],),
        )
        row = await cursor.fetchone()
        if not row:
            return {"btc": 0, "plt": 0, "gold": 0}
        return {"btc": row[0], "plt": row[1], "gold": row[2]}


@app.get("/player/inventory")
async def get_inventory(account: dict = Depends(get_current_account)):
    """Return server-authoritative inventory for the authenticated player."""
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT item_id, quantity FROM inventory WHERE player_id = ?",
            (account["player_id"],),
        )
        rows = await cursor.fetchall()
        # Phase 1: ids come back canonical, so the client can key its inventory
        # directly on them and never has to guess a display spelling.
        inventory = normalize_inventory({row[0]: row[1] for row in rows})
        return {"inventory": inventory, "player_id": account["player_id"]}


# ---------------------------------------------------------------------------
# Journal endpoints (Phase 1 - the real "Seyir Defteri")
# ---------------------------------------------------------------------------
@app.get("/journal")
async def get_journal(
    limit: int = journal.DEFAULT_JOURNAL_LIMIT,
    offset: int = 0,
    event_type: str = "",
    account: dict = Depends(get_current_account),
):
    """Newest-first journal entries for the authenticated player.

    The client renders this list; it can neither author nor reorder it. An
    `event_type` filter is accepted so the UI can show a single category tab.
    """
    async with aiosqlite.connect(DB_PATH) as db:
        if event_type and event_type in journal.VALID_EVENT_TYPES:
            cursor = await db.execute(
                "SELECT id, event_type, severity, message, details, created_at "
                "FROM event_journal WHERE player_id = ? AND event_type = ? "
                "ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
                (
                    account["player_id"], event_type,
                    max(1, min(limit, journal.DEFAULT_JOURNAL_LIMIT)),
                    max(0, offset),
                ),
            )
        else:
            cursor = await db.execute(
                "SELECT id, event_type, severity, message, details, created_at "
                "FROM event_journal WHERE player_id = ? "
                "ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
                (
                    account["player_id"],
                    max(1, min(limit, journal.DEFAULT_JOURNAL_LIMIT)),
                    max(0, offset),
                ),
            )
        rows = await cursor.fetchall()
        events = [journal.row_to_event(r) for r in rows]
        total = await journal.count_events(db, account["player_id"])
    return {
        "events": events,
        "total": total,
        "limit": max(1, min(limit, journal.DEFAULT_JOURNAL_LIMIT)),
        "offset": max(0, offset),
    }


@app.post("/journal/ack")
async def ack_journal(account: dict = Depends(get_current_account),
                      req: JournalAckRequest = JournalAckRequest()):
    """Acknowledge (read) journal entries.

    Reading is purely cosmetic - the entries stay in the table. This exists so
    the client can mark what it has already shown and a future "unread" badge
    has a server-owned source of truth.
    """
    async with aiosqlite.connect(DB_PATH) as db:
        if req.ids:
            marks = ",".join("?" for _ in req.ids)
            await db.execute(
                f"UPDATE event_journal SET acknowledged = 1 "
                f"WHERE player_id = ? AND id IN ({marks})",
                (account["player_id"], *req.ids),
            )
        else:
            await db.execute(
                "UPDATE event_journal SET acknowledged = 1 WHERE player_id = ?",
                (account["player_id"],),
            )
        await db.commit()
    return {"ok": True, "acknowledged": len(req.ids) if req.ids else None}



@app.get("/market/catalog")
async def get_market_catalog():
    """Return the server-side item catalog with validated prices.
    
    Client must not send prices; server is the single source of truth.
    """
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT item_id, name, category, price, currency, item_type FROM item_catalog"
        )
        rows = await cursor.fetchall()
        items = []
        for row in rows:
            items.append({
                "item_id": row[0],
                "name": row[1],
                "category": row[2],
                "price": row[3],
                "currency": row[4],
                "type": row[5],
            })
        return {"items": items}


class MarketBuyRequest(BaseModel):
    item_id: str = Field(..., min_length=1)
    currency: str = Field("")
    price: float = Field(0)
    transaction_id: str = Field("", max_length=128)


@app.post("/market/buy")
async def market_buy(request: Request, req: MarketBuyRequest, account: dict = Depends(get_current_account)):
    """Server-authoritative market purchase.
    
    Flow:
    1. Validate item_id against server catalog (server price, not client)
    2. Validate currency matches catalog
    3. Check server-side balance
    4. Atomic transaction: decrease balance + add item to inventory
    5. Record transaction
    6. Return new balance + inventory
    
    Client-sent price is IGNORED. Server uses catalog price.
    Idempotency: transaction_id prevents duplicate processing.
    """
    now = _unix_now()
    tx_id = str(req.transaction_id).strip() if req.transaction_id else _gen_token_id()

    async with aiosqlite.connect(DB_PATH) as db:
        # Idempotency: check if this transaction_id was already processed
        cursor = await db.execute(
            "SELECT 1 FROM transactions WHERE reference_id = ? LIMIT 1",
            (tx_id,),
        )
        existing = await cursor.fetchone()
        if existing:
            # Already processed - return current state without double-charging
            cursor = await db.execute(
                "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
                (account["player_id"],),
            )
            bal_row = await cursor.fetchone()
            cursor = await db.execute(
                "SELECT item_id, quantity FROM inventory WHERE player_id = ?",
                (account["player_id"],),
            )
            inv_rows = await cursor.fetchall()
            return {
                "success": True,
                "message": "Transaction already processed (idempotent replay)",
                "btc": bal_row[0] if bal_row else 0,
                "plt": bal_row[1] if bal_row else 0,
                "gold": bal_row[2] if bal_row else 0,
                "inventory": normalize_inventory({r[0]: r[1] for r in inv_rows}),
            }

        # 1. Validate item against server catalog.
        # Phase 1: the client id is folded onto the canonical id first, so
        # "Kalkan 1" from the market UI resolves to the `kalkan1` row instead
        # of being rejected as an unknown item.
        requested_item_id = normalize_item_id(req.item_id)
        cursor = await db.execute(
            "SELECT item_id, price, currency, item_type FROM item_catalog WHERE item_id = ?",
            (requested_item_id,),
        )
        catalog_row = await cursor.fetchone()
        if not catalog_row:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Item not found in catalog: {req.item_id}"
            )

        server_item_id = catalog_row[0]
        server_price = catalog_row[1]
        server_currency = catalog_row[2]
        server_item_type = catalog_row[3]

        # 2. Validate currency matches catalog (ignore client's price)
        # Client may send empty currency (server determines from catalog) or
        # a non-empty currency that must match
        if req.currency and req.currency != server_currency:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Currency mismatch: expected {server_currency}, got {req.currency}"
            )

        # 3. Get server-side balance
        cursor = await db.execute(
            "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
            (account["player_id"],),
        )
        bal_row = await cursor.fetchone()
        if not bal_row:
            await db.execute(
                "INSERT INTO economy (player_id, btc, plt, gold, updated_at) VALUES (?, 0, 0, 0, ?)",
                (account["player_id"], now),
            )
            btc, plt, gold = 0, 0, 0
        else:
            btc, plt, gold = bal_row[0], bal_row[1], bal_row[2]

        if server_currency == "BTC":
            if btc < server_price:
                return {
                    "success": False,
                    "message": f"Insufficient BTC. Required: {server_price}, Available: {btc}",
                    "btc": btc,
                    "plt": plt,
                    "gold": gold,
                }
            new_btc = btc - server_price
            new_plt = plt
        elif server_currency == "PLT":
            if plt < server_price:
                return {
                    "success": False,
                    "message": f"Insufficient PLT. Required: {server_price}, Available: {plt}",
                    "btc": btc,
                    "plt": plt,
                    "gold": gold,
                }
            new_btc = btc
            new_plt = plt - server_price
        else:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Unknown currency: {server_currency}"
            )

        # 4. Atomic: decrease balance + add item to inventory + record transaction
        try:
            cursor = await db.execute("BEGIN IMMEDIATE TRANSACTION")
            
            await db.execute(
                "UPDATE economy SET btc = ?, plt = ?, gold = ?, updated_at = ? WHERE player_id = ?",
                (new_btc, new_plt, gold, now, account["player_id"]),
            )

            # Add item to inventory (increment if exists)
            cursor = await db.execute(
                "SELECT quantity FROM inventory WHERE player_id = ? AND item_id = ?",
                (account["player_id"], server_item_id),
            )
            inv_row = await cursor.fetchone()
            if inv_row:
                new_qty = inv_row[0] + 1
                await db.execute(
                    "UPDATE inventory SET quantity = ? WHERE player_id = ? AND item_id = ?",
                    (new_qty, account["player_id"], server_item_id),
                )
            else:
                await db.execute(
                    "INSERT INTO inventory (player_id, item_id, quantity) VALUES (?, ?, 1)",
                    (account["player_id"], server_item_id),
                )

            # Record transaction
            await db.execute(
                "INSERT INTO transactions (id, player_id, currency, amount, reason, reference_id, timestamp) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    _gen_token_id(),
                    account["player_id"],
                    server_currency,
                    -server_price,
                    f"market_buy:{server_item_id}",
                    tx_id,
                    now,
                ),
            )

            await journal.log_market(
                db, account["player_id"], True, server_item_id,
                1, server_currency,
            )

            await db.commit()
        except Exception:
            await db.rollback()
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail="Transaction failed and was rolled back"
            )

        # 5. Return new state
        cursor = await db.execute(
            "SELECT item_id, quantity FROM inventory WHERE player_id = ?",
            (account["player_id"],),
        )
        inv_rows = await cursor.fetchall()
        # Phase 1: the response mirrors /player/inventory - canonical ids only.
        server_inventory = normalize_inventory({r[0]: r[1] for r in inv_rows})

        return {
            "success": True,
            "message": f"{server_item_id} purchased",
            "btc": new_btc,
            "plt": new_plt,
            "gold": gold,
            "inventory": server_inventory,
            "purchase": {
                "item_id": server_item_id,
                "price": server_price,
                "currency": server_currency,
                "transaction_id": tx_id,
            },
        }


@app.get("/player/full")
async def get_full_player(account: dict = Depends(get_current_account)):
    """Return full player state: balance + inventory (server-authoritative)."""
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
            (account["player_id"],),
        )
        row = await cursor.fetchone()
        cursor = await db.execute(
            "SELECT item_id, quantity FROM inventory WHERE player_id = ?",
            (account["player_id"],),
        )
        inv_rows = await cursor.fetchall()
        return {
            "player_id": account["player_id"],
            "username": account["username"],
            "btc": row[0] if row else 0,
            "plt": row[1] if row else 0,
            "gold": row[2] if row else 0,
            "inventory": normalize_inventory({r[0]: r[1] for r in inv_rows}),
        }


# ---------------------------------------------------------------------------
# Server-side economy helpers (used by NPC combat rewards, etc.)
# ---------------------------------------------------------------------------
async def grant_currency(player_id: str, btc: int = 0, plt: int = 0, gold: int = 0,
                         reason: str = "") -> dict:
    """Atomically grant currency to a player. Server-authoritative."""
    now = _unix_now()
    async with aiosqlite.connect(DB_PATH) as db:
        try:
            await db.execute("BEGIN IMMEDIATE TRANSACTION")

            cursor = await db.execute(
                "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
                (player_id,),
            )
            row = await cursor.fetchone()
            if row:
                new_btc = row[0] + btc
                new_plt = row[1] + plt
                new_gold = row[2] + gold
                await db.execute(
                    "UPDATE economy SET btc = ?, plt = ?, gold = ?, updated_at = ? WHERE player_id = ?",
                    (new_btc, new_plt, new_gold, now, player_id),
                )
            else:
                new_btc = btc
                new_plt = plt
                new_gold = gold
                await db.execute(
                    "INSERT INTO economy (player_id, btc, plt, gold, updated_at) VALUES (?, ?, ?, ?, ?)",
                    (player_id, new_btc, new_plt, new_gold, now),
                )

            if btc != 0:
                await db.execute(
                    "INSERT INTO transactions (id, player_id, currency, amount, reason, reference_id, timestamp) "
                    "VALUES (?, ?, 'BTC', ?, ?, NULL, ?)",
                    (_gen_token_id(), player_id, btc, reason, now),
                )
            if plt != 0:
                await db.execute(
                    "INSERT INTO transactions (id, player_id, currency, amount, reason, reference_id, timestamp) "
                    "VALUES (?, ?, 'PLT', ?, ?, NULL, ?)",
                    (_gen_token_id(), player_id, plt, reason, now),
                )

            await db.commit()
            return {"btc": new_btc, "plt": new_plt, "gold": new_gold}
        except Exception:
            await db.rollback()
            return {"btc": 0, "plt": 0, "gold": 0}


async def grant_item(player_id: str, item_id: str, quantity: int = 1,
                     reason: str = "") -> dict:
    """Grant an item to a player's server inventory."""
    now = _unix_now()
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute(
            "SELECT quantity FROM inventory WHERE player_id = ? AND item_id = ?",
            (player_id, item_id),
        )
        row = await cursor.fetchone()
        if row:
            new_qty = row[0] + quantity
            await db.execute(
                "UPDATE inventory SET quantity = ? WHERE player_id = ? AND item_id = ?",
                (new_qty, player_id, item_id),
            )
        else:
            await db.execute(
                "INSERT INTO inventory (player_id, item_id, quantity) VALUES (?, ?, ?)",
                (player_id, item_id, quantity),
            )
        await db.commit()
        return {"item_id": item_id, "quantity": new_qty if row else quantity}


# Register WebSocket routes at module level so they appear in the app
from websocket_server import register_websocket_routes as _register_ws  # noqa: E402

_register_ws(app, SECRET_KEY, DB_PATH)


# ---------------------------------------------------------------------------
# Phase 2-7 route registration
# ---------------------------------------------------------------------------
# One call per router group, placed at the very end of the module so
# `get_current_account` is already defined. The routers receive the auth
# dependency and a DB-path *provider* rather than importing main, which keeps
# the dependency direction one-way (main -> routers) and stops a router from
# reading main.DB_PATH at import time - tests repoint it per module.
def _current_db_path() -> str:
    return DB_PATH


def _register_phase_routes() -> None:
    import routes_p23
    import routes_p45
    import routes_p67
    routes_p23.register_routes(app, get_current_account, _current_db_path)
    routes_p45.register_routes(app, get_current_account, _current_db_path)
    routes_p67.register_routes(app, get_current_account, _current_db_path)
    # The Admin Panel surface. Same auth dependency and same DB-path provider,
    # so it also reads whatever DB the tests repoint.
    routes_admin.register_routes(app, get_current_account, _current_db_path)


_register_phase_routes()


# ---------------------------------------------------------------------------
# Admin Panel static assets
# ---------------------------------------------------------------------------
# Registered AFTER the admin API routes on purpose. FastAPI matches routes in
# registration order, so a `/admin/{asset_name}` route registered earlier would
# shadow `/admin/session`, `/admin/dashboard` and every other real endpoint.
@app.get("/admin")
async def admin_panel():
    """Serve the Admin Panel shell.

    The panel resolves its own API base at runtime, so this same build works
    locally and in production with no environment URL hard-coded into it.
    """
    from fastapi.responses import FileResponse
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "admin", "index.html")
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Admin panel not built")
    return FileResponse(path)


@app.get("/admin/{asset_name}")
async def admin_panel_asset(asset_name: str):
    """Serve one panel asset (admin.css / admin.js).

    Validated against an allow-list rather than joined blindly, so this cannot
    be turned into an arbitrary file read.
    """
    from fastapi.responses import FileResponse
    allowed = {"admin.css", "admin.js"}
    if asset_name not in allowed:
        raise HTTPException(status_code=404, detail="Unknown asset")
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "admin", asset_name)
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail="Asset not found")
    return FileResponse(path)

