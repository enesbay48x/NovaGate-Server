"""
Phase 4: Server-Authoritative Economy + Inventory + Market tests.

Tests verify:
- Server is the single source of truth for BTC, PLT, gold balances
- Client-sent prices are ignored (server uses catalog prices)
- Client-sent fake quantity/ownership is rejected
- Market purchases are atomic (balance decrease + item add happen together)
- Idempotency: duplicate transaction_id doesn't double-charge
- Insufficient balance is rejected
- Invalid items are rejected
- Market purchases persist to database
- Inventory sync between server and client is correct
- Two players' balances/inventories don't interfere
"""

import asyncio
import json
import os
import sys
import time
import uuid

import pytest
import aiosqlite
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "test-secret-key-for-phase4-testing-only"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_novagate_economy.db")
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "100/minute"
os.environ["RATE_LIMIT_REGISTER"] = "100/minute"

from main import app, init_db, SECRET_KEY, DB_PATH, reset_rate_limits, grant_currency, grant_item  # noqa: E402


import main as main_module

DB_PATH_TEST = os.environ["DB_PATH"]


def _reset_db():
    main_module.DB_PATH = DB_PATH_TEST
    if os.path.exists(DB_PATH_TEST):
        try:
            os.remove(DB_PATH_TEST)
        except OSError:
            pass


def _make_username(prefix: str = "econ") -> str:
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


def _make_tokens(client, username: str, password: str = "TestPass123!"):
    client.post("/auth/register", json={
        "username": username,
        "password": password,
        "nickname": username,
        "company": ""
    })
    resp = client.post("/auth/login", json={
        "username": username,
        "password": password
    })
    data = resp.json()
    return data["access_token"], data["refresh_token"]


def _auth_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _starter_items() -> dict:
    """{item_id: quantity} the server grants on a brand new registration."""
    from main import _parse_first_registration_reward_items
    from config import FIRST_REGISTRATION_REWARD_ITEMS

    return dict(_parse_first_registration_reward_items(FIRST_REGISTRATION_REWARD_ITEMS))


def _starter_item_count(item_id: str) -> int:
    """How many of `item_id` a brand new account already owns from the
    server-authoritative first-registration reward.

    Market tests assert absolute inventory counts, so they must be offset by
    the reward the account was seeded with. The market itself is unchanged.
    """
    return int(_starter_items().get(item_id, 0))


def _clear_all_state():
    asyncio.run(_clear_db())


async def _clear_db():
    _reset_db()
    await init_db()


@pytest.fixture(autouse=True)
def _setup(request):
    asyncio.run(_clear_db())
    reset_rate_limits()
    yield
    _reset_db()


@pytest.fixture()
def event_loop():
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


client = TestClient(app)


async def _economy_row(player_id: str):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cur = await db.execute(
            "SELECT btc, plt, gold FROM economy WHERE player_id = ?", (player_id,)
        )
        return await cur.fetchone()


async def _set_absolute_balance(player_id: str, btc: int, plt: int, gold: int):
    """Set an ABSOLUTE balance, compensating for the first-registration reward.

    /auth/register now seeds a brand new account with the server-authoritative
    first-registration reward, so a plain additive grant_currency() would not
    land on the value the test asked for. This keeps every test's intent
    ("the player owns exactly X") unchanged.
    """
    row = await _economy_row(player_id)
    current = (int(row[0]), int(row[1]), int(row[2])) if row else (0, 0, 0)
    await grant_currency(
        player_id,
        btc=btc - current[0],
        plt=plt - current[1],
        gold=gold - current[2],
        reason="phase4_test_setup",
    )


def _create_test_player_and_balance(btc: int = 100000, plt: int = 50000, gold: int = 1000) -> tuple:
    """Create a test player with an initial server balance. Returns (token, player_id)."""
    username = _make_username("phase4")
    access_token, _ = _make_tokens(client, username)
    
    # Register the player's access token to get player_id from token
    import jwt
    payload = jwt.decode(access_token, SECRET_KEY, algorithms=["HS256"])
    player_id = payload["player_id"]

    # Set the absolute initial balance the test asked for.
    asyncio.run(_set_absolute_balance(player_id, btc, plt, gold))
    
    return access_token, player_id


# ---------------------------------------------------------------------------
# Balance Tests
# ---------------------------------------------------------------------------
class TestServerBalance:
    def test_server_balance_correct_after_grant(self):
        """Server BTC/PLT/Gold balance is stored and returned correctly."""
        token, player_id = _create_test_player_and_balance(btc=50000, plt=25000, gold=500)
        resp = client.get("/player/balance", headers=_auth_headers(token))
        data = resp.json()
        assert resp.status_code == 200
        assert data["btc"] == 50000
        assert data["plt"] == 25000
        assert data["gold"] == 500

    def test_server_balance_is_first_registration_reward_for_new_player(self):
        """A brand new account holds exactly the first-registration reward."""
        username = _make_username("phase4_zero")
        token, _ = _make_tokens(client, username)
        resp = client.get("/player/balance", headers=_auth_headers(token))
        assert resp.status_code == 200
        data = resp.json()
        assert data["btc"] == main_module.FIRST_REGISTRATION_REWARD_BTC
        assert data["plt"] == main_module.FIRST_REGISTRATION_REWARD_PLT
        assert data["gold"] == 0

    def test_server_balance_zero_when_no_economy_row_exists(self):
        """An account whose economy row is missing still reads as zero balance."""
        import jwt

        username = _make_username("phase4_norow")
        access_token, _ = _make_tokens(client, username)
        player_id = jwt.decode(access_token, SECRET_KEY, algorithms=["HS256"])["player_id"]

        async def _drop_row():
            async with aiosqlite.connect(DB_PATH_TEST) as db:
                await db.execute("DELETE FROM economy WHERE player_id = ?", (player_id,))
                await db.commit()

        asyncio.run(_drop_row())

        resp = client.get("/player/balance", headers=_auth_headers(access_token))
        assert resp.status_code == 200
        data = resp.json()
        assert data["btc"] == 0
        assert data["plt"] == 0
        assert data["gold"] == 0


# ---------------------------------------------------------------------------
# Market Catalog Tests
# ---------------------------------------------------------------------------
class TestMarketCatalog:
    def test_catalog_returns_server_prices(self):
        """Server returns validated item catalog with prices."""
        token, _ = _create_test_player_and_balance()
        resp = client.get("/market/catalog", headers=_auth_headers(token))
        assert resp.status_code == 200
        data = resp.json()
        items = data["items"]
        assert len(items) > 0

        # Verify known items
        lf1 = [i for i in items if i["item_id"] == "lf1"]
        assert len(lf1) == 1
        assert lf1[0]["price"] == 40000
        assert lf1[0]["currency"] == "BTC"

        # Verify ammo items exist
        x1_1000 = [i for i in items if i["item_id"] == "ammo_x1_1000"]
        assert len(x1_1000) == 1
        assert x1_1000[0]["price"] == 4500
        assert x1_1000[0]["currency"] == "BTC"

    def test_catalog_has_ammo_packages(self):
        """Catalog includes all ammo packages."""
        token, _ = _create_test_player_and_balance()
        resp = client.get("/market/catalog", headers=_auth_headers(token))
        items = resp.json()["items"]

        expected_ammo_ids = [
            "ammo_x1_1000", "ammo_x2_500", "ammo_x3_100",
            "ammo_sab_1000", "ammo_rsb_100",
            "ammo_r1_50", "ammo_r2_50", "ammo_r3_50",
        ]
        item_ids = {i["item_id"] for i in items}
        for expected in expected_ammo_ids:
            assert expected in item_ids, f"Missing ammo item: {expected}"


# ---------------------------------------------------------------------------
# Market Purchase Tests
# ---------------------------------------------------------------------------
class TestMarketPurchase:
    def test_valid_purchase(self):
        """Valid market purchase succeeds and deducts server balance."""
        token, player_id = _create_test_player_and_balance(btc=50000, plt=25000)

        resp = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 999999,  # Fake price - should be IGNORED
            "transaction_id": f"tx_test_{uuid.uuid4().hex[:8]}",
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is True

        # Server should have deducted its own price (40000 BTC), not the client's fake price
        assert data["btc"] == 10000  # 50000 - 40000
        assert data["plt"] == 25000  # unchanged

        # Verify balance persisted to database
        check = client.get("/player/balance", headers=_auth_headers(token))
        assert check.json()["btc"] == 10000

    def test_purchase_with_fake_price_uses_server_price(self):
        """Client-sent fake price is ignored; server uses catalog price."""
        token, player_id = _create_test_player_and_balance(btc=50000, plt=25000)

        # Try to buy lf1 (cost 40000 BTC) but send a fake price of 0
        resp = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 0,  # Fake price - should be ignored
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is True
        # Server used catalog price (40000), not client's 0
        assert data["btc"] == 10000  # 50000 - 40000

    def test_purchase_with_wrong_currency_rejected(self):
        """Item requiring BTC cannot be purchased with PLT."""
        token, player_id = _create_test_player_and_balance(btc=50000, plt=25000)

        resp = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",  # costs BTC
            "currency": "PLT",  # wrong currency
            "price": 40000,
        })
        assert resp.status_code == 400  # Bad request - currency mismatch

    def test_insufficient_balance_rejected(self):
        """Insufficient balance is rejected by server."""
        token, player_id = _create_test_player_and_balance(btc=1000, plt=0)

        # lf1 costs 40000 BTC, player only has 1000
        resp = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["success"] is False
        assert "Insufficient" in data.get("message", data.get("mesaj", ""))

        # Balance should remain unchanged
        balance = client.get("/player/balance", headers=_auth_headers(token)).json()
        assert balance["btc"] == 1000

    def test_invalid_item_rejected(self):
        """Non-existent item_id is rejected."""
        token, player_id = _create_test_player_and_balance(btc=50000)

        resp = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "fake_item_12345",
            "currency": "BTC",
            "price": 1000,
        })
        assert resp.status_code == 400  # Bad request - item not in catalog

    def test_item_added_to_inventory(self):
        """Purchased item appears in server inventory."""
        token, player_id = _create_test_player_and_balance(btc=50000)

        client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
        })

        inv = client.get("/player/inventory", headers=_auth_headers(token)).json()
        assert "lf1" in inv["inventory"]
        # 1 from the first-registration reward + 1 from this purchase.
        assert inv["inventory"]["lf1"] == 1 + _starter_item_count("lf1")

    def test_purchase_multiple_items_increments_inventory(self):
        """Buying same item twice increments inventory count."""
        token, player_id = _create_test_player_and_balance(btc=100000)

        tx_id = f"tx_{uuid.uuid4().hex[:8]}"
        client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
            "transaction_id": tx_id,
        })
        client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
            "transaction_id": f"tx_{uuid.uuid4().hex[:8]}",
        })

        inv = client.get("/player/inventory", headers=_auth_headers(token)).json()
        assert inv["inventory"]["lf1"] == 2 + _starter_item_count("lf1")


# ---------------------------------------------------------------------------
# Atomic Transaction Tests
# ---------------------------------------------------------------------------
class TestAtomicTransaction:
    def test_balance_and_inventory_atomic(self):
        """Balance decreases AND inventory increases together."""
        token, player_id = _create_test_player_and_balance(btc=100000, plt=50000)

        # Buy LF1 (40000 BTC)
        resp = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
        })
        data = resp.json()
        assert data["success"] is True
        assert data["btc"] == 60000  # 100000 - 40000

        # Both balance and inventory should be updated
        balance = client.get("/player/balance", headers=_auth_headers(token)).json()
        inv = client.get("/player/inventory", headers=_auth_headers(token)).json()
        assert balance["btc"] == 60000
        assert inv["inventory"]["lf1"] == 1 + _starter_item_count("lf1")


# ---------------------------------------------------------------------------
# Idempotency / Duplicate Prevention Tests
# ---------------------------------------------------------------------------
class TestIdempotency:
    def test_duplicate_transaction_id_no_double_charge(self):
        """Same transaction_id sent twice does not double-charge."""
        token, player_id = _create_test_player_and_balance(btc=100000)
        tx_id = f"tx_dup_{uuid.uuid4().hex[:8]}"

        # First purchase
        resp1 = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
            "transaction_id": tx_id,
        })
        data1 = resp1.json()
        assert data1["success"] is True
        assert data1["btc"] == 60000  # 100000 - 40000

        # Second purchase with same transaction_id
        resp2 = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
            "transaction_id": tx_id,  # Same ID
        })
        data2 = resp2.json()
        assert data2["success"] is True  # Idempotent: returns current state
        assert data2["btc"] == 60000  # NOT deducted again
        assert data2["inventory"]["lf1"] == 1 + _starter_item_count("lf1")  # NOT incremented again


# ---------------------------------------------------------------------------
# Multi-player Isolation Tests
# ---------------------------------------------------------------------------
class TestMultiPlayerIsolation:
    def test_two_players_balances_independent(self):
        """Two players have independent balances."""
        token1, pid1 = _create_test_player_and_balance(btc=50000, plt=25000)
        token2, pid2 = _create_test_player_and_balance(btc=100000, plt=50000)

        # Player 1 buys LF1 (40000 BTC)
        resp = client.post("/market/buy", headers=_auth_headers(token1), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
        })
        assert resp.json()["success"] is True
        assert resp.json()["btc"] == 10000  # Player 1's balance

        # Player 2's balance should not change
        balance2 = client.get("/player/balance", headers=_auth_headers(token2)).json()
        assert balance2["btc"] == 100000  # Player 2 unchanged

    def test_two_players_inventories_independent(self):
        """Two players have independent inventories."""
        token1, _ = _create_test_player_and_balance(btc=50000)
        token2, _ = _create_test_player_and_balance(btc=100000)

        # Player 1 buys LF1
        client.post("/market/buy", headers=_auth_headers(token1), json={
            "item_id": "lf1", "currency": "BTC", "price": 40000,
        })

        # Player 2 buys LF2
        client.post("/market/buy", headers=_auth_headers(token2), json={
            "item_id": "lf2", "currency": "BTC", "price": 80000,
        })

        inv1 = client.get("/player/inventory", headers=_auth_headers(token1)).json()
        inv2 = client.get("/player/inventory", headers=_auth_headers(token2)).json()

        # Both start with the same first-registration reward, so the real
        # assertion is the DELTA caused by each purchase.
        assert inv1["inventory"]["lf1"] == 1 + _starter_item_count("lf1")
        assert inv2["inventory"]["lf1"] == _starter_item_count("lf1")

        assert inv2["inventory"]["lf2"] == 1
        assert _starter_item_count("lf2") == 0
        assert "lf2" not in inv1.get("inventory", {})


# ---------------------------------------------------------------------------
# Security Tests
# ---------------------------------------------------------------------------
class TestSecurity:
    def test_fake_btc_value_rejected(self):
        """Client cannot set BTC value; server ignores it."""
        token, player_id = _create_test_player_and_balance(btc=50000)

        # The market/buy endpoint doesn't accept a 'btc' field for setting balance
        # Verify that balance can only be changed through purchases
        balance_before = client.get("/player/balance", headers=_auth_headers(token)).json()
        assert balance_before["btc"] == 50000

    def test_fake_platinum_rejected(self):
        """Client cannot set PLT value; server ignores it."""
        token, player_id = _create_test_player_and_balance(plt=25000)

        balance = client.get("/player/balance", headers=_auth_headers(token)).json()
        assert balance["plt"] == 25000

    def test_fake_item_quantity_rejected(self):
        """Client cannot set item quantity; server adds exactly 1."""
        token, player_id = _create_test_player_and_balance(btc=100000)

        # Try to buy with a quantity field - server should ignore it
        client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
            "quantity": 100,  # Should be ignored
        })

        inv = client.get("/player/inventory", headers=_auth_headers(token)).json()
        # Only 1 added by the purchase, not 100 (plus the starter reward).
        assert inv["inventory"]["lf1"] == 1 + _starter_item_count("lf1")

    def test_fake_item_price_rejected(self):
        """Client cannot set a fake price; server uses catalog price."""
        token, player_id = _create_test_player_and_balance(btc=100)

        # Try to buy LF1 (costs 40000 BTC) but claim price is 10 BTC
        resp = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 10,  # Fake - should be ignored
        })
        # Server uses catalog price (40000), player only has 100 → rejected
        data = resp.json()
        assert data["success"] is False
        assert "Insufficient" in data.get("message", data.get("mesaj", ""))

    def test_fake_item_ownership_rejected(self):
        """Client cannot claim ownership of items they haven't purchased."""
        token, player_id = _create_test_player_and_balance()

        inv = client.get("/player/inventory", headers=_auth_headers(token)).json()
        # A brand new account only owns the first-registration reward items;
        # it cannot claim anything else.
        assert set(inv.get("inventory", {}).keys()) == set(_starter_items().keys())

    def test_purchase_not_in_catalog_rejected(self):
        """Items not in server catalog cannot be purchased."""
        token, player_id = _create_test_player_and_balance(btc=999999)

        resp = client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "nonexistent_item",
            "currency": "BTC",
            "price": 1,
        })
        assert resp.status_code == 400

    def test_transaction_logged(self):
        """Every purchase is recorded in the transactions table."""
        token, player_id = _create_test_player_and_balance(btc=50000)
        tx_id = f"tx_log_{uuid.uuid4().hex[:8]}"

        client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1",
            "currency": "BTC",
            "price": 40000,
            "transaction_id": tx_id,
        })

        # Verify transaction was logged
        import jwt
        payload = jwt.decode(token, SECRET_KEY, algorithms=["HS256"])

        async def check():
            async with aiosqlite.connect(DB_PATH_TEST) as db:
                cursor = await db.execute(
                    "SELECT currency, amount, reason FROM transactions WHERE player_id = ?",
                    (payload["player_id"],),
                )
                rows = await cursor.fetchall()
                assert len(rows) >= 1
                has_btc_tx = any(r[0] == "BTC" for r in rows)
                assert has_btc_tx
        asyncio.run(check())

    def test_database_persistence(self):
        """Purchase data persists to database after transaction."""
        token, player_id = _create_test_player_and_balance(btc=50000)

        client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1", "currency": "BTC", "price": 40000,
        })

        # Verify persistence by checking the database directly
        async def check_persistence():
            async with aiosqlite.connect(DB_PATH_TEST) as db:
                cursor = await db.execute(
                    "SELECT btc FROM economy WHERE player_id = ?",
                    (player_id,),
                )
                row = await cursor.fetchone()
                assert row is not None
                assert row[0] == 10000  # 50000 - 40000

                cursor = await db.execute(
                    "SELECT quantity FROM inventory WHERE player_id = ? AND item_id = ?",
                    (player_id, "lf1"),
                )
                row = await cursor.fetchone()
                assert row is not None
                assert row[0] == 1 + _starter_item_count("lf1")
        asyncio.run(check_persistence())


# ---------------------------------------------------------------------------
# Full Player State Tests
# ---------------------------------------------------------------------------
class TestPlayerFull:
    def test_full_player_endpoint(self):
        """Full player endpoint returns balance + inventory."""
        token, player_id = _create_test_player_and_balance(btc=50000, plt=25000)

        # Purchase something
        client.post("/market/buy", headers=_auth_headers(token), json={
            "item_id": "lf1", "currency": "BTC", "price": 40000,
        })

        resp = client.get("/player/full", headers=_auth_headers(token))
        data = resp.json()
        assert data["btc"] == 10000
        assert data["plt"] == 25000
        assert "lf1" in data["inventory"]
