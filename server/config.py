import os
from dotenv import load_dotenv

load_dotenv()

def _get_env(key: str, default: str = "") -> str:
    return os.environ.get(key, default)

SECRET_KEY: str = _get_env("SECRET_KEY", "")
ACCESS_TOKEN_EXPIRE_SECONDS: int = int(_get_env("ACCESS_TOKEN_EXPIRE_SECONDS", "900"))
REFRESH_TOKEN_EXPIRE_SECONDS: int = int(_get_env("REFRESH_TOKEN_EXPIRE_SECONDS", "604800"))
DB_PATH: str = _get_env(
    "DB_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "novagate.db"),
)
RATE_LIMIT_LOGIN: str = _get_env("RATE_LIMIT_LOGIN", "5/minute")
RATE_LIMIT_REGISTER: str = _get_env("RATE_LIMIT_REGISTER", "3/minute")

# Server network config
SERVER_HOST: str = _get_env("SERVER_HOST", "0.0.0.0")
SERVER_PORT: int = int(_get_env("SERVER_PORT", _get_env("PORT", "8000")))

# WebSocket world settings
WORLD_TICK_HZ: int = int(_get_env("WORLD_TICK_HZ", "20"))
HEARTBEAT_INTERVAL_SECONDS: int = int(_get_env("HEARTBEAT_INTERVAL_SECONDS", "10"))
HEARTBEAT_TIMEOUT_SECONDS: int = int(_get_env("HEARTBEAT_TIMEOUT_SECONDS", "30"))
MAP_WIDTH: float = float(_get_env("MAP_WIDTH", "14000"))
MAP_HEIGHT: float = float(_get_env("MAP_HEIGHT", "10000"))
MAX_SPEED: float = float(_get_env("MAX_SPEED", "600.0"))
TICK_RATE: float = float(_get_env("TICK_RATE", "0.05"))

# Admin config
# The credentials are NEVER committed: they come from the environment only
# (Render dashboard / local .env), and the source has no default value.
ADMIN_USERNAME: str = _get_env("ADMIN_USERNAME", "")
ADMIN_PASSWORD: str = _get_env("ADMIN_PASSWORD", "")
# Which role the bootstrapped account receives. Defaults to superadmin because
# this is the documented production bootstrap path; anything not in the known
# role set falls back to "admin" in main._bootstrap_admin rather than silently
# creating an account with no panel access.
ADMIN_ROLE: str = _get_env("ADMIN_ROLE", "superadmin")

# ---------------------------------------------------------------------------
# First-registration reward (server-authoritative)
# ---------------------------------------------------------------------------
# The reward ALREADY EXISTED in the project, but only client-side in
# scripts/account_manager.gd (STARTER_REWARD_BITCOIN / _PLATINUM / _ITEMS).
# Because /auth/register created the economy row with 0/0/0 and
# account_manager.sync_server_player_to_local() overwrites the local balances
# from the server on every login, that client grant was always wiped.
# The amounts below therefore reuse the project's existing values (10000 BTC /
# 10000 PLT / LF1 + Kalkan I + Hız I) instead of inventing new ones.
# They are only ever applied inside POST /auth/register, so existing accounts
# are never back-paid.
FIRST_REGISTRATION_REWARD_BTC: int = int(_get_env("FIRST_REGISTRATION_REWARD_BTC", "10000"))
FIRST_REGISTRATION_REWARD_PLT: int = int(_get_env("FIRST_REGISTRATION_REWARD_PLT", "10000"))
# "item_id:quantity,item_id:quantity" using the SERVER item_catalog ids.
FIRST_REGISTRATION_REWARD_ITEMS: str = _get_env(
    "FIRST_REGISTRATION_REWARD_ITEMS", "lf1:1,kalkan1:1,hiz1:1"
)

# Online-only mode: when true, clients cannot play without a server session.
ONLINE_ONLY: bool = str(_get_env("ONLINE_ONLY", "true")).lower() in ("1", "true", "yes", "on")

# Server version
SERVER_VERSION: str = _get_env("SERVER_VERSION", "1.0.0")

if not SECRET_KEY:
    raise RuntimeError("SECRET_KEY environment variable is required")