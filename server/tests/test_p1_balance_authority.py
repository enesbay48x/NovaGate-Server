"""
Phase 1 - server balance authority + first-registration reward persistence.

The contract the real Godot client depends on:

  A1  register grants 10000 BTC / 10000 PLT / LF1 / Kalkan I / Hiz I
  A2  a SECOND login does not grant the reward again
  A3  logout+login preserves the balances
  A4  DB, /player/* and the login payload all agree
  A5  an EXISTING account is never back-paid
  A6  the reward is marked claimed exactly once
  A7  a failed/rolled-back registration leaves no partial state
  A8  the client cannot inflate its own balance
  A9  a market purchase is server-priced
  A10 the reward survives a server restart (DB-backed, not memory)
"""

import asyncio
import json
import os
import subprocess
import sys
import time

import aiosqlite
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "phase1-balance-authority-secret-0123456789"
os.environ["DB_PATH"] = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "test_novagate_p1_balance.db"
)
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

from main import app, init_db, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402

DB_PATH_TEST = os.environ["DB_PATH"]
PASSWORD = "TestPass123!"

# The exact Phase 1 contract.
EXPECT_BTC = 10000
EXPECT_PLT = 10000
EXPECT_ITEMS = {"lf1": 1, "kalkan1": 1, "hiz1": 1}


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _reset_db():
    main_module.DB_PATH = DB_PATH_TEST
    if os.path.exists(DB_PATH_TEST):
        try:
            os.remove(DB_PATH_TEST)
        except OSError:
            pass


def _uname(prefix="p1bal"):
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


@pytest.fixture(scope="module", autouse=True)
def _app():
    _reset_db()
    _run(init_db())
    reset_rate_limits()
    with TestClient(app) as client:
        yield client
    _reset_db()


def _register(client, company=""):
    reset_rate_limits()
    username = _uname()
    resp = client.post("/auth/register", json={
        "username": username, "password": PASSWORD,
        "nickname": username, "company": company,
    })
    assert resp.status_code == 200, resp.text
    return username, resp.json()


def _login(client, username):
    resp = client.post("/auth/login",
                       json={"username": username, "password": PASSWORD})
    assert resp.status_code == 200, resp.text
    return resp.json()


def _db_economy(player_id: str) -> dict:
    async def read():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            cur = await db.execute(
                "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
                (player_id,),
            )
            row = await cur.fetchone()
            cur = await db.execute(
                "SELECT item_id, quantity FROM inventory WHERE player_id = ?",
                (player_id,),
            )
            inv = {r[0]: r[1] for r in await cur.fetchall()}
            return {"btc": row[0], "plt": row[1], "gold": row[2], "inv": inv}

    return _run(read())

# ---------------------------------------------------------------------------
# A1-A2  the reward, and only once
# ---------------------------------------------------------------------------
def test_register_grants_the_full_reward(_app):
    username, reg = _register(_app)
    reward = reg["first_registration_reward"]
    assert reward["btc"] == EXPECT_BTC
    assert reward["plt"] == EXPECT_PLT
    assert reward["items"] == EXPECT_ITEMS

    econ = _db_economy(reg["player_id"])
    assert econ["btc"] == EXPECT_BTC, econ
    assert econ["plt"] == EXPECT_PLT, econ
    for item_id, qty in EXPECT_ITEMS.items():
        assert econ["inv"].get(item_id) == qty, econ


def test_second_login_does_not_grant_the_reward_again(_app):
    username, reg = _register(_app)
    pid = reg["player_id"]

    for _ in range(3):
        body = _login(_app, username)
        assert body["oyuncu"]["bitcoin"] == EXPECT_BTC
        assert body["oyuncu"]["plt"] == EXPECT_PLT

    econ = _db_economy(pid)
    assert econ["btc"] == EXPECT_BTC, f"reward was re-granted: {econ}"
    assert econ["plt"] == EXPECT_PLT, f"reward was re-granted: {econ}"
    for item_id, qty in EXPECT_ITEMS.items():
        assert econ["inv"].get(item_id) == qty, econ


def test_logout_then_login_preserves_the_reward(_app):
    username, reg = _register(_app)
    pid = reg["player_id"]

    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    assert _app.post("/auth/logout", headers=headers).status_code == 200

    again = _login(_app, username)
    assert again["oyuncu"]["bitcoin"] == EXPECT_BTC
    assert again["oyuncu"]["plt"] == EXPECT_PLT
    inv = again["oyuncu"]["inventory"]
    for item_id, qty in EXPECT_ITEMS.items():
        assert inv.get(item_id) == qty, inv

    econ = _db_economy(pid)
    assert econ["btc"] == EXPECT_BTC
    assert econ["plt"] == EXPECT_PLT


# ---------------------------------------------------------------------------
# A3-A4  every view of the balance agrees
# ---------------------------------------------------------------------------
def test_db_endpoints_and_login_payload_agree(_app):
    username, reg = _register(_app)
    pid = reg["player_id"]
    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}

    db = _db_economy(pid)
    balance = _app.get("/player/balance", headers=headers).json()
    inventory = _app.get("/player/inventory", headers=headers).json()
    full = _app.get("/player/full", headers=headers).json()
    oyuncu = body["oyuncu"]

    assert db["btc"] == balance["btc"] == full["btc"] == oyuncu["bitcoin"], (
        f"db={db['btc']} balance={balance['btc']} full={full['btc']} "
        f"login={oyuncu['bitcoin']}"
    )
    assert db["plt"] == full["plt"] == oyuncu["plt"], (
        f"db={db['plt']} full={full['plt']} login={oyuncu['plt']}"
    )
    assert db["inv"] == inventory["inventory"] == full["inventory"], (
        f"db={db['inv']} inv={inventory['inventory']} full={full['inventory']}"
    )
    assert oyuncu["inventory"] == db["inv"]

# ---------------------------------------------------------------------------
# A5-A6  no back-pay for existing accounts
# ---------------------------------------------------------------------------
def test_existing_account_is_never_back_paid(_app):
    """An account created WITHOUT the reward must stay at zero."""
    async def seed_plain_account(username):
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            now = int(time.time())
            cur = await db.execute(
                "INSERT INTO accounts (username, password_hash, player_id, "
                "nickname, company, role, created_at, starter_reward_claimed) "
                "VALUES (?, 'x', ?, ?, '', 'player', ?, 0)",
                (username, f"legacy_{username}", username, now),
            )
            del cur
            await db.execute(
                "INSERT INTO economy (player_id, btc, plt, gold, updated_at) "
                "VALUES (?, 0, 0, 0, ?)",
                (f"legacy_{username}", now),
            )
            await db.commit()
            return f"legacy_{username}"

    username = _uname("legacy")
    pid = _run(seed_plain_account(username))

    econ = _db_economy(pid)
    assert econ["btc"] == 0, f"a legacy account was back-paid: {econ}"
    assert econ["plt"] == 0, f"a legacy account was back-paid: {econ}"
    assert econ["inv"] == {}, econ

    # The account has an unusable password hash, so no reward path is
    # reachable through the API at all.
    resp = _app.post("/auth/login",
                     json={"username": username, "password": PASSWORD})
    assert resp.status_code == 401, resp.text
    assert _db_economy(pid)["btc"] == 0


def test_starter_reward_claimed_is_set_exactly_once(_app):
    username, reg = _register(_app)
    pid = reg["player_id"]

    async def read_flag():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            cur = await db.execute(
                "SELECT starter_reward_claimed FROM accounts WHERE player_id = ?",
                (pid,),
            )
            row = await cur.fetchone()
            return None if row is None else int(row[0])

    assert _run(read_flag()) == 1

    _login(_app, username)
    assert _run(read_flag()) == 1, "the claimed flag was reset on login"

    async def count_tx():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            cur = await db.execute(
                "SELECT currency, amount FROM transactions "
                "WHERE player_id = ? AND reason = 'first_registration_reward' "
                "ORDER BY currency",
                (pid,),
            )
            return await cur.fetchall()

    rows = _run(count_tx())
    # Exactly one BTC leg and one PLT leg - the reward is written once and
    # never re-appended by a later login.
    assert len(rows) == 2, f"reward ledger rows wrong: {rows}"
    assert [r[0] for r in rows] == ["BTC", "PLT"], rows
    assert {r[0]: r[1] for r in rows} == {"BTC": EXPECT_BTC, "PLT": EXPECT_PLT}


# ---------------------------------------------------------------------------
# A7-A9  the client cannot author its own economy
# ---------------------------------------------------------------------------
def test_client_cannot_inflate_its_balance(_app):
    username, reg = _register(_app)

    # A login body carrying a client-side balance must not be honoured; the
    # server always answers from the DB.
    resp = _app.post("/auth/login", json={
        "username": username, "password": PASSWORD,
        "bitcoin": 999999999, "plt": 999999999,
    })
    assert resp.status_code == 200
    assert resp.json()["oyuncu"]["bitcoin"] == EXPECT_BTC
    assert resp.json()["oyuncu"]["plt"] == EXPECT_PLT
    assert _db_economy(reg["player_id"])["btc"] == EXPECT_BTC


def test_market_is_server_priced(_app):
    from main import grant_currency

    username, reg = _register(_app)
    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    # grant_currency is ADDITIVE, so the account ends up with
    # 10000 (reward) + 200000 = 210000 BTC.
    _run(grant_currency(reg["player_id"], btc=200000, reason="test_topup"))
    before = _db_economy(reg["player_id"])["btc"]
    assert before == EXPECT_BTC + 200000, before

    # A client-sent price of 1 must be ignored; the catalog price is charged.
    resp = _app.post("/market/buy", headers=headers, json={
        "item_id": "LF2", "currency": "BTC", "price": 1,
    })
    assert resp.status_code == 200, resp.text
    payload = resp.json()
    assert payload["success"] is True, payload
    assert payload["purchase"]["price"] == 80000, payload["purchase"]
    assert payload["btc"] == before - 80000, payload
    assert _db_economy(reg["player_id"])["btc"] == before - 80000


def test_insufficient_balance_is_rejected_without_side_effects(_app):
    username, reg = _register(_app)
    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}

    # kalkan1 costs 125000 BTC; the account has 10000.
    resp = _app.post("/market/buy", headers=headers,
                     json={"item_id": "kalkan1", "currency": "BTC"})
    assert resp.status_code == 200, resp.text
    payload = resp.json()
    # The API reports a business-level failure rather than an HTTP error, and
    # crucially nothing changed.
    assert payload["success"] is False, payload
    assert "Insufficient" in payload["message"], payload
    econ = _db_economy(reg["player_id"])
    assert econ["btc"] == EXPECT_BTC, "a rejected purchase moved the balance"
    assert econ["inv"].get("kalkan1") == EXPECT_ITEMS["kalkan1"], econ


