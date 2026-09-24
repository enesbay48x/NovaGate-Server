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
)
from websocket_server import manager as ws_manager, npc_manager

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


@app.get("/health")
async def health():
    return {"status": "ok"}


async def require_admin(request: Request):
    account = await get_current_account(request)
    if not account.get("is_admin") or account.get("role") != "admin":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin role required")
    return account


async def _admin_log(db, admin: dict, action: str, target: str, details: str, result: str = "success"):
    await db.execute(
        "INSERT INTO admin_log (timestamp, admin_account_id, admin_username, target_username, action, amount, reason, result) "
        "VALUES (?, ?, ?, ?, ?, NULL, ?, ?)",
        (_unix_now(), admin["id"], admin["username"], target, action, details, result),
    )


@app.get("/admin/status")
async def admin_status(admin: dict = Depends(require_admin)):
    return {"status": "ok", "server_version": "1.0.0", "online_players": len(ws_manager.active_connections), "active_npcs": len(npc_manager.npcs)}


@app.get("/admin/players")
async def admin_players(admin: dict = Depends(require_admin)):
    async with aiosqlite.connect(DB_PATH) as db:
        rows = await (await db.execute("SELECT a.id, a.username, a.player_id, a.company, a.role, e.btc, e.plt, e.gold FROM accounts a LEFT JOIN economy e ON e.player_id = a.player_id ORDER BY a.username")).fetchall()
    online_ids = set(ws_manager.active_connections.keys())
    return {"players": [{"account_id": row[0], "username": row[1], "player_id": row[2], "company": row[3] or "", "role": row[4], "online": row[2] in online_ids, "btc": row[5] or 0, "plt": row[6] or 0, "gold": row[7] or 0} for row in rows]}


@app.get("/admin/player/{username}")
async def admin_player(username: str, admin: dict = Depends(require_admin)):
    async with aiosqlite.connect(DB_PATH) as db:
        row = await (await db.execute("SELECT a.id, a.username, a.player_id, a.company, a.role, e.btc, e.plt, e.gold FROM accounts a LEFT JOIN economy e ON e.player_id = a.player_id WHERE a.username = ?", (username,))).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Player not found")
    session = ws_manager.active_connections.get(row[2])
    return {"account_id": row[0], "username": row[1], "player_id": row[2], "company": row[3] or "", "role": row[4], "btc": row[5] or 0, "plt": row[6] or 0, "gold": row[7] or 0, "online": session is not None, "map_id": session.map_id if session else "1-1", "position": [session.position_x, session.position_y] if session else [0.0, 0.0]}



    return {"status": "ok"}


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


class AdminCurrencyRequest(BaseModel):
    currency: str
    amount: int


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
                created_at      INTEGER NOT NULL
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
            """
        )
        await db.commit()

    # Seed item catalog if empty
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute("SELECT COUNT(*) FROM item_catalog")
        row = await cursor.fetchone()
        count = row[0]
        if count == 0:
            catalog_items = [
                # Lasers
                ("lf1", "LF1", "Lazer", 40000, "BTC", "laser"),
                ("lf2", "LF2", "Lazer", 80000, "BTC", "laser"),
                ("lf3", "LF3", "Lazer", 20000, "PLT", "laser"),
                # Shields/Generators
                ("kalkan1", "Kalkan 1", "Kalkan", 125000, "BTC", "generator"),
                ("kalkan2", "Kalkan 2", "Kalkan", 15000, "PLT", "generator"),
                ("hiz1", "Hız 1", "Hiz", 125000, "BTC", "generator"),
                ("hiz2", "Hız 2", "Hiz", 10000, "PLT", "generator"),
                # Extras/Boosters
                ("ema", "EMA", "Extra", 150000, "PLT", "extra"),
                ("enc", "ENC", "Extra", 95000, "PLT", "extra"),
                ("nukleer", "Nukleer", "Extra", 90000, "PLT", "extra"),
                ("uc_saniye", "3 Saniye", "Extra", 120000, "PLT", "extra"),
                # Log disks
                ("log_disk_1", "1 Log Disk", "Extra", 300, "PLT", "log_disk"),
                ("log_disk_50", "50 Log Disk", "Extra", 15000, "PLT", "log_disk"),
                ("log_disk_100", "100 Log Disk", "Extra", 30000, "PLT", "log_disk"),
                ("log_disk_1000", "1000 Log Disk", "Extra", 300000, "PLT", "log_disk"),
                # Ammo packages - X1
                ("ammo_x1_1000", "1000 X1", "Cephane", 4500, "BTC", "ammo"),
                ("ammo_x1_10000", "10000 X1", "Cephane", 45000, "BTC", "ammo"),
                ("ammo_x1_100000", "100000 X1", "Cephane", 450000, "BTC", "ammo"),
                # Ammo packages - X2
                ("ammo_x2_500", "500 X2", "Cephane", 22500, "BTC", "ammo"),
                ("ammo_x2_1000", "1000 X2", "Cephane", 450000, "BTC", "ammo"),
                ("ammo_x2_10000", "10000 X2", "Cephane", 4500000, "BTC", "ammo"),
                ("ammo_x2_10000", "10000 X2", "Cephane", 4500000, "BTC", "ammo"),
                ("ammo_x2_100000", "100000 X2", "Cephane", 45000000, "BTC", "ammo"),
                # Ammo packages - X3
                ("ammo_x3_100", "100 X3", "Cephane", 90, "PLT", "ammo"),
                ("ammo_x3_1000", "1000 X3", "Cephane", 900, "PLT", "ammo"),
                ("ammo_x3_10000", "10000 X3", "Cephane", 9000, "PLT", "ammo"),
                ("ammo_x3_100000", "100000 X3", "Cephane", 90000, "PLT", "ammo"),
                # Ammo packages - X4
                ("ammo_x4_1000", "1000 X4", "Cephane", 2700, "PLT", "ammo"),
                ("ammo_x4_10000", "10000 X4", "Cephane", 27000, "PLT", "ammo"),
                ("ammo_x4_100000", "100000 X4", "Cephane", 270000, "PLT", "ammo"),
                # Ammo packages - SAB
                ("ammo_sab_1000", "1000 SAB", "Cephane", 500, "PLT", "ammo"),
                ("ammo_sab_10000", "10000 SAB", "Cephane", 5000, "PLT", "ammo"),
                ("ammo_sab_100000", "100000 SAB", "Cephane", 50000, "PLT", "ammo"),
                # Ammo packages - RSB
                ("ammo_rsb_100", "100 RSB", "Cephane", 450, "PLT", "ammo"),
                ("ammo_rsb_1000", "1000 RSB", "Cephane", 4500, "PLT", "ammo"),
                ("ammo_rsb_10000", "10000 RSB", "Cephane", 45000, "PLT", "ammo"),
                ("ammo_rsb_100000", "100000 RSB", "Cephane", 450000, "PLT", "ammo"),
                # Ammo packages - R1
                ("ammo_r1_50", "50 R1", "Cephane", 2250, "BTC", "ammo"),
                ("ammo_r1_500", "500 R1", "Cephane", 22500, "BTC", "ammo"),
                ("ammo_r1_5000", "5000 R1", "Cephane", 225000, "BTC", "ammo"),
                # Ammo packages - R2
                ("ammo_r2_50", "50 R2", "Cephane", 22500, "BTC", "ammo"),
                ("ammo_r2_500", "500 R2", "Cephane", 225000, "BTC", "ammo"),
                ("ammo_r2_5000", "5000 R2", "Cephane", 2250000, "BTC", "ammo"),
                # Ammo packages - R3
                ("ammo_r3_50", "50 R3", "Cephane", 225, "PLT", "ammo"),
                ("ammo_r3_500", "500 R3", "Cephane", 2250, "PLT", "ammo"),
                ("ammo_r3_5000", "5000 R3", "Cephane", 22500, "PLT", "ammo"),
                # Droids
                ("droid_plus_1", "PLUS Droid", "Droid", 100000, "BTC", "droid_plus"),
                ("droid_zeus_1", "ZEUS Droid", "Droid", 12000, "PLT", "droid_zeus"),
            ]
            await db.executemany(
                "INSERT OR IGNORE INTO item_catalog (item_id, name, category, price, currency, item_type) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                catalog_items
            )
            await db.commit()


@app.on_event("startup")
async def startup():
    await init_db()
    from websocket_server import register_websocket_routes, on_startup
    register_websocket_routes(app, SECRET_KEY, DB_PATH)
    await on_startup(app, SECRET_KEY, DB_PATH)


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
        await db.execute("UPDATE accounts SET company = ? WHERE id = ?", (company, account["id"]))
        await db.commit()
    return {"success": True, "company": company}


# ---------------------------------------------------------------------------
@app.post("/admin/player/{username}/currency")
async def admin_currency(username: str, req: AdminCurrencyRequest, admin: dict = Depends(require_admin)):
    currency = req.currency.strip().upper()
    if currency not in {"BTC", "PLT", "GOLD"}:
        raise HTTPException(status_code=400, detail="Invalid currency")
    async with aiosqlite.connect(DB_PATH) as db:
        row = await (await db.execute("SELECT player_id FROM accounts WHERE username = ?", (username,))).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Player not found")
        column = currency.lower()
        await db.execute(f"UPDATE economy SET {column} = MAX(0, COALESCE({column}, 0) + ?), updated_at = ? WHERE player_id = ?", (req.amount, _unix_now(), row[0]))
        await _admin_log(db, admin, "currency_update", username, f"{currency}:{req.amount}")
        await db.commit()
    return {"success": True, "username": username, "currency": currency, "amount": req.amount}


@app.post("/admin/player/{username}/teleport")
async def admin_teleport(username: str, req: AdminTeleportRequest, admin: dict = Depends(require_admin)):
    async with aiosqlite.connect(DB_PATH) as db:
        row = await (await db.execute("SELECT player_id FROM accounts WHERE username = ?", (username,))).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Player not found")
    session = ws_manager.active_connections.get(row[0])
    if session:
        session.map_id, session.position_x, session.position_y = req.map_id, req.x, req.y
        await npc_manager.spawn_map_npcs(req.map_id)
    async with aiosqlite.connect(DB_PATH) as db:
        await _admin_log(db, admin, "teleport", username, f"{req.map_id}:{req.x},{req.y}")
        await db.commit()
    return {"success": True, "online": session is not None, "map_id": req.map_id, "position": [req.x, req.y]}


@app.get("/admin/npcs")
async def admin_npcs(admin: dict = Depends(require_admin)):
    return {"npcs": npc_manager.admin_list()}


@app.post("/admin/npcs/spawn")
async def admin_spawn_npc(req: AdminNpcSpawnRequest, admin: dict = Depends(require_admin)):
    try:
        npc = await npc_manager.admin_spawn(req.npc_type, req.map_id, req.x, req.y)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    async with aiosqlite.connect(DB_PATH) as db:
        await _admin_log(db, admin, "npc_spawn", "", f"{req.npc_type}:{req.map_id}:{req.x},{req.y}")
        await db.commit()
    return {"success": True, "npc": npc}


@app.delete("/admin/npcs/{npc_id}")
async def admin_remove_npc(npc_id: str, admin: dict = Depends(require_admin)):
    if not await npc_manager.admin_remove(npc_id):
        raise HTTPException(status_code=404, detail="NPC not found")
    async with aiosqlite.connect(DB_PATH) as db:
        await _admin_log(db, admin, "npc_remove", "", npc_id)
        await db.commit()
    return {"success": True, "npc_id": npc_id}


@app.get("/admin/log")
async def admin_log(limit: int = 100, admin: dict = Depends(require_admin)):
    async with aiosqlite.connect(DB_PATH) as db:
        rows = await (await db.execute("SELECT timestamp, admin_username, target_username, action, reason, result FROM admin_log ORDER BY id DESC LIMIT ?", (max(1, min(limit, 500)),))).fetchall()
    return {"log": [dict(zip(("timestamp", "admin_username", "target_username", "action", "details", "result"), row)) for row in rows]}



# Auth endpoints
# ---------------------------------------------------------------------------
@app.post("/auth/register")
@limiter.limit(RATE_LIMIT_REGISTER)
async def register(request: Request, req: RegisterRequest):
    password_hash = _hash_password(req.password)
    player_id = _gen_player_id()
    now = _unix_now()

    try:
        async with aiosqlite.connect(DB_PATH) as db:
            cursor = await db.execute(
                "INSERT INTO accounts (username, password_hash, player_id, nickname, company, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (req.username, password_hash, player_id, req.nickname or req.username, req.company, now),
            )
            await db.commit()
            account_id = cursor.lastrowid
    except aiosqlite.IntegrityError:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Username already exists")

    return {
        "success": True,
        "message": "Account created",
        "account_id": account_id,
        "player_id": player_id,
        "username": req.username,
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

    server_inventory: dict = {str(r[0]): int(r[1]) for r in inv_rows}
    active_ship = str(ship_row[0]) if ship_row and ship_row[0] else SHIP_ID_DEFAULT

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
        "oyuncu": {
            "id": player_id,
            "username": username,
            "company": company,
            "level": 1,
            "exp": 0,
            "honor": 0,
            "bitcoin": int(econ_row[0]) if econ_row else 0,
            "plt": int(econ_row[1]) if econ_row else 0,
            "gold": int(econ_row[2]) if econ_row else 0,
            "inventory": server_inventory,
            "owned_ships": [active_ship, "Ship10"],
            "active_ship_id": active_ship,
            "ship_configurations": {},
            "selected_config": 1,
            "droid_types": [],
            "is_admin": is_admin,
            "map": "",
        },
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
    access_token = _create_access_token(db_account_id, db_player_id, account_row[0], is_admin)
    new_refresh_token, new_refresh_jti, new_expires_at = _create_refresh_token(
        db_account_id, db_player_id, account_row[0]
    )

    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE sessions SET refresh_token = ?, refresh_jti = ?, expires_at = ? WHERE id = ?",
            (new_refresh_token, new_refresh_jti, new_expires_at, session_id),
        )
        await db.commit()

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

    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute(
            "UPDATE sessions SET active = 0 WHERE account_id = ? AND active = 1",
            (account_id,),
        )
        await db.commit()

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
        inventory = {row[0]: row[1] for row in rows}
        return {"inventory": inventory, "player_id": account["player_id"]}


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
                "inventory": {r[0]: r[1] for r in inv_rows},
            }

        # 1. Validate item against server catalog
        cursor = await db.execute(
            "SELECT item_id, price, currency, item_type FROM item_catalog WHERE item_id = ?",
            (req.item_id,),
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

        return {
            "success": True,
            "message": f"{server_item_id} purchased",
            "btc": new_btc,
            "plt": new_plt,
            "gold": gold,
            "inventory": {r[0]: r[1] for r in inv_rows},
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
            "inventory": {r[0]: r[1] for r in inv_rows},
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
