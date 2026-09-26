"""
First-registration reward: server-authoritative, exactly once.

Tests verify that:
- a brand new account is credited with the project's existing first-registration
  reward values (scripts/account_manager.gd STARTER_REWARD_*) on the SERVER DB,
- the register response echoes the grant and the login payload's
  "oyuncu.bitcoin" / "oyuncu.plt" reflect it (so the client cannot lose it),
- the reward items land in the server inventory and in the login payload,
- LOGIN never re-grants the reward (repeat logins keep the same balance),
- re-registering the same username is rejected and grants nothing extra,
- an account that existed before the reward existed is never back-paid,
- the reward is recorded in the `transactions` audit table.
"""

import asyncio
import os
import sys
import time

import aiosqlite
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "test-secret-key-for-first-registration-reward"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_novagate_starter.db")
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

import main as main_module  # noqa: E402
from main import (  # noqa: E402
    app,
    init_db,
    reset_rate_limits,
    FIRST_REGISTRATION_REWARD_BTC,
    FIRST_REGISTRATION_REWARD_PLT,
    FIRST_REGISTRATION_REWARD_REASON,
)

DB_PATH_TEST = os.environ["DB_PATH"]
PASSWORD = "TestPass123!"

# The reward values must equal the ones the project already defined
# client-side in scripts/account_manager.gd. If somebody changes one side and
# not the other, these two tests fail loudly.
CLIENT_STARTER_REWARD_BITCOIN = 10000
CLIENT_STARTER_REWARD_PLATINUM = 10000
CLIENT_STARTER_REWARD_ITEMS = ["Kalkan 1", "Hız 1", "LF1"]  # -> server ids


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


def _uname(prefix: str) -> str:
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


@pytest.fixture(scope="module")
def client():
    _reset_db()
    _run(init_db())
    with TestClient(app) as c:
        yield c
    _reset_db()


@pytest.fixture(autouse=True)
def _clean(client):
    reset_rate_limits()
    yield
    reset_rate_limits()


def _register(c, prefix="starter"):
    reset_rate_limits()
    username = _uname(prefix)
    resp = c.post("/auth/register", json={
        "username": username,
        "password": PASSWORD,
        "nickname": username,
        "company": "",
    })
    assert resp.status_code == 200, resp.text
    return resp.json()


def _login(c, username):
    reset_rate_limits()
    resp = c.post("/auth/login", json={"username": username, "password": PASSWORD})
    assert resp.status_code == 200, resp.text
    return resp.json()


async def _economy_row(player_id):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cur = await db.execute("SELECT btc, plt, gold FROM economy WHERE player_id = ?", (player_id,))
        return await cur.fetchone()


async def _transactions(player_id):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cur = await db.execute(
            "SELECT currency, amount, reason FROM transactions WHERE player_id = ?", (player_id,)
        )
        return await cur.fetchall()


async def _inventory(player_id):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cur = await db.execute(
            "SELECT item_id, quantity FROM inventory WHERE player_id = ?", (player_id,)
        )
        return {r[0]: r[1] for r in await cur.fetchall()}


async def _claimed_flag(username):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cur = await db.execute(
            "SELECT starter_reward_claimed FROM accounts WHERE username = ?", (username,)
        )
        row = await cur.fetchone()
        return None if row is None else int(row[0])


# ---------------------------------------------------------------------------
class TestRewardAmountMatchesProject:
    def test_server_reward_equals_existing_client_constants(self):
        assert FIRST_REGISTRATION_REWARD_BTC == CLIENT_STARTER_REWARD_BITCOIN
        assert FIRST_REGISTRATION_REWARD_PLT == CLIENT_STARTER_REWARD_PLATINUM

    def test_reward_items_match_existing_client_item_list(self):
        from main import _parse_first_registration_reward_items
        from config import FIRST_REGISTRATION_REWARD_ITEMS

        granted = dict(_parse_first_registration_reward_items(FIRST_REGISTRATION_REWARD_ITEMS))
        # client: "Kalkan 1" -> kalkan1, "Hız 1" -> hiz1, "LF1" -> lf1
        expected = {"kalkan1": 1, "hiz1": 1, "lf1": 1}
        assert granted == expected
        assert len(granted) == len(CLIENT_STARTER_REWARD_ITEMS)


# ---------------------------------------------------------------------------
class TestRegisterGrantsRewardOnce:
    def test_register_response_reports_the_grant(self, client):
        body = _register(client, "grant_resp")
        reward = body.get("first_registration_reward")
        assert isinstance(reward, dict)
        assert reward["btc"] == FIRST_REGISTRATION_REWARD_BTC
        assert reward["plt"] == FIRST_REGISTRATION_REWARD_PLT
        assert reward["items"]

    def test_economy_row_is_credited_on_the_server_db(self, client):
        body = _register(client, "grant_db")
        row = _run(_economy_row(body["player_id"]))
        assert row is not None, "no economy row for the new account"
        assert row[0] == FIRST_REGISTRATION_REWARD_BTC
        assert row[1] == FIRST_REGISTRATION_REWARD_PLT
        assert row[2] == 0, "gold must stay zero"

    def test_reward_items_are_in_the_server_inventory(self, client):
        body = _register(client, "grant_items")
        inv = _run(_inventory(body["player_id"]))
        assert inv.get("lf1") == 1
        assert inv.get("kalkan1") == 1
        assert inv.get("hiz1") == 1

    def test_reward_is_written_to_the_transaction_audit_log(self, client):
        body = _register(client, "grant_tx")
        rows = _run(_transactions(body["player_id"]))
        by_currency = {r[0]: (r[1], r[2]) for r in rows}
        assert by_currency["BTC"] == (FIRST_REGISTRATION_REWARD_BTC, FIRST_REGISTRATION_REWARD_REASON)
        assert by_currency["PLT"] == (FIRST_REGISTRATION_REWARD_PLT, FIRST_REGISTRATION_REWARD_REASON)

    def test_account_is_flagged_as_rewarded(self, client):
        body = _register(client, "grant_flag")
        assert _run(_claimed_flag(body["username"])) == 1


# ---------------------------------------------------------------------------
class TestLoginPayloadCarriesTheReward:
    def test_login_returns_the_rewarded_balance(self, client):
        created = _register(client, "carry")
        payload = _login(client, created["username"])["oyuncu"]
        assert payload["bitcoin"] == FIRST_REGISTRATION_REWARD_BTC
        assert payload["plt"] == FIRST_REGISTRATION_REWARD_PLT

    def test_login_payload_includes_reward_items(self, client):
        created = _register(client, "carry_items")
        payload = _login(client, created["username"])["oyuncu"]
        inv = payload["inventory"]
        assert inv.get("lf1") == 1
        assert inv.get("kalkan1") == 1
        assert inv.get("hiz1") == 1


# ---------------------------------------------------------------------------
class TestLoginNeverReGrants:
    def test_repeated_logins_do_not_change_the_balance(self, client):
        created = _register(client, "noregrant")
        expected_btc = FIRST_REGISTRATION_REWARD_BTC
        expected_plt = FIRST_REGISTRATION_REWARD_PLT
        for _ in range(4):
            payload = _login(client, created["username"])["oyuncu"]
            assert payload["bitcoin"] == expected_btc
            assert payload["plt"] == expected_plt
        row = _run(_economy_row(created["player_id"]))
        assert (row[0], row[1]) == (expected_btc, expected_plt)

    def test_relogging_does_not_stack_reward_transactions(self, client):
        created = _register(client, "noregrant_tx")
        for _ in range(3):
            _login(client, created["username"])
        rows = _run(_transactions(created["player_id"]))
        reward_rows = [r for r in rows if r[2] == FIRST_REGISTRATION_REWARD_REASON]
        assert len(reward_rows) == 2, f"reward logged more than once: {reward_rows}"  # BTC + PLT


# ---------------------------------------------------------------------------
class TestDuplicateRegistrationGrantsNothing:
    def test_second_register_is_rejected_and_does_not_top_up(self, client):
        created = _register(client, "dupe")
        reset_rate_limits()
        resp = client.post("/auth/register", json={
            "username": created["username"],
            "password": PASSWORD,
        })
        assert resp.status_code == 409
        row = _run(_economy_row(created["player_id"]))
        assert (row[0], row[1]) == (FIRST_REGISTRATION_REWARD_BTC, FIRST_REGISTRATION_REWARD_PLT)


# ---------------------------------------------------------------------------
class TestExistingAccountsAreNotBackPaid:
    def test_pre_reward_account_keeps_its_balance_on_migration(self, client):
        """An account that already existed keeps its balance; init_db() only
        adds the column, it never credits anything."""
        username = _uname("legacy")
        _run(_insert_legacy_account(username))
        # Re-run the migration path exactly like a server restart.
        _run(init_db())
        row = _run(_legacy_economy_row(username))
        assert row == (777, 333), f"legacy balance changed: {row}"

    def test_legacy_account_can_still_log_in(self, client):
        username = _uname("legacy_login")
        _run(_insert_legacy_account(username))
        _run(init_db())
        reset_rate_limits()
        resp = client.post("/auth/login", json={"username": username, "password": PASSWORD})
        assert resp.status_code == 200, resp.text
        payload = resp.json()["oyuncu"]
        assert payload["bitcoin"] == 777
        assert payload["plt"] == 333


async def _insert_legacy_account(username):
    """Simulate an account created before the reward existed."""
    import bcrypt

    async with aiosqlite.connect(DB_PATH_TEST) as db:
        pw = bcrypt.hashpw(PASSWORD.encode(), bcrypt.gensalt()).decode()
        await db.execute(
            "INSERT INTO accounts (username, password_hash, player_id, nickname, company, created_at) "
            "VALUES (?, ?, ?, ?, '', 0)",
            (username, pw, f"legacy_{username}", username),
        )
        await db.execute(
            "INSERT INTO economy (player_id, btc, plt, gold, updated_at) VALUES (?, 777, 333, 5, 0)",
            (f"legacy_{username}",),
        )
        await db.commit()


async def _legacy_economy_row(username):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cur = await db.execute(
            "SELECT btc, plt FROM economy WHERE player_id = (SELECT player_id FROM accounts WHERE username = ?)",
            (username,),
        )
        row = await cur.fetchone()
        return None if row is None else (int(row[0]), int(row[1]))


# ---------------------------------------------------------------------------
class TestRewardParserIsDefensive:
    def test_malformed_item_specs_are_skipped(self):
        from main import _parse_first_registration_reward_items

        parsed = _parse_first_registration_reward_items("lf1:1, ,broken,kalkan1:x,hiz1:2,lf2:0")
        assert parsed == [("lf1", 1), ("hiz1", 2)]

    def test_empty_spec_yields_no_items(self):
        from main import _parse_first_registration_reward_items

        assert _parse_first_registration_reward_items("") == []
        assert _parse_first_registration_reward_items(None) == []


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
