"""
Market purchase -> inventory delivery (the "money left, item never arrived" bug).

ROOT CAUSE pinned here: the server answers /market/buy with `"success"`, but
market.gd gated every purchase on `result.get("basarili", false)`. Because the
server never sends "basarili", a SUCCESSFUL purchase was read by the client as
a FAILURE, so it returned before save_game() and before the equipment refresh:
BTC/PLT were debited (server side) while the item never appeared on screen.

  M1  a purchase debits the server balance AND delivers the inventory row
  M2  the item is stored under the CANONICAL id, never the display name
  M3  the response carries the server's authoritative inventory + balance
  M4  the response is normalized onto the keys the client actually reads
      ("basarili" / "mesaj"), which is the whole bug
  M5  a server REJECTION is not treated as "unreachable" (no free local item)
  M6  only a genuinely unreachable server sets the offline-fallback flag
  M7  market prices/currency are never taken from the client
  M8  duplicate transaction_id is idempotent (no double charge/item)
  M9  the item survives logout -> login
  M10 exactly one market_buy journal row per successful purchase
  M11 an unknown item id is refused and costs nothing
  M12 a failed purchase writes no journal row and no inventory row
"""

import asyncio
import os
import sqlite3
import sys
import time

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "market-delivery-regression-secret-0123456789"
os.environ["DB_PATH"] = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "test_novagate_market_delivery.db"
)
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

import journal  # noqa: E402,F401  (imported so main's deps are initialised first)
import main as main_module  # noqa: E402
import websocket_server as ws  # noqa: E402
from item_catalog import CATALOG_BY_ID, normalize_item_id  # noqa: E402
from main import app, init_db, reset_rate_limits  # noqa: E402

DB_PATH_TEST = os.environ["DB_PATH"]


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _reset_db():
    """Point the app at THIS module's database.

    config.py reads DB_PATH once at import time, so every test module in the
    suite shares whichever database the first-imported module selected. Each
    module therefore re-points main.DB_PATH (and the WebSocket session store)
    at its own file. Without this the app would write to a neighbouring
    module's database and every direct SQL assertion would fail with
    "no such table".
    """
    main_module.DB_PATH = DB_PATH_TEST
    ws.manager.configure(ws.manager.secret_key, DB_PATH_TEST)
    for suffix in ("", "-wal", "-shm"):
        stale = DB_PATH_TEST + suffix
        if os.path.exists(stale):
            try:
                os.remove(stale)
            except OSError:
                pass


@pytest.fixture(scope="module", autouse=True)
def _app():
    _reset_db()
    _run(init_db())
    reset_rate_limits()
    yield
    _reset_db()


def _register(client, tag):
    """Create an account and return (username, player_id, access_token).

    /auth/register deliberately returns no token, so the token comes from a
    follow-up login. The limiter is a process-wide singleton shared by every
    test module, so it is reset here the way the other modules do.
    """
    reset_rate_limits()
    user = f"mkt_{tag}_{int(time.time() * 1000000) % 100_000_000}"
    r = client.post("/auth/register", json={
        "username": user, "password": "pw-market-123",
        "nickname": "Mkt", "company": "nova",
    })
    assert r.status_code == 200, r.text
    pid = r.json()["player_id"]

    login = client.post("/auth/login", json={
        "username": user, "password": "pw-market-123"})
    assert login.status_code == 200, login.text
    return user, pid, login.json()["access_token"]


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _fund(player_id, btc=5_000_000, plt=5_000_000):
    from main import grant_currency
    _run(grant_currency(player_id, btc=btc, plt=plt, reason="test_funding"))


def _inv(player_id):
    conn = sqlite3.connect(DB_PATH_TEST)
    try:
        rows = conn.execute(
            "SELECT item_id, quantity FROM inventory WHERE player_id = ?",
            (player_id,)).fetchall()
    finally:
        conn.close()
    return {r[0]: r[1] for r in rows}


def _journal(player_id, event="market_buy"):
    conn = sqlite3.connect(DB_PATH_TEST)
    try:
        rows = conn.execute(
            "SELECT event_type, message FROM event_journal "
            "WHERE player_id = ? AND event_type = ? ORDER BY id",
            (player_id, event)).fetchall()
    finally:
        conn.close()
    return rows


def _buy(client, headers, item_id, tx=None):
    return client.post("/market/buy", headers=headers, json={
        "item_id": item_id,
        "currency": "",
        "price": 0,
        "transaction_id": tx or f"tx_{item_id}_{time.time_ns()}",
    })


# The four items the bug report names explicitly.
BUY_ITEMS = ["LF1", "LF3", "Kalkan 1", "Hız 1"]

@pytest.mark.parametrize("label", BUY_ITEMS)
def test_m1_debits_and_delivers(label):
    """M1+M2: balance drops AND the canonical inventory row grows by one."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m1")
        _fund(pid)
        h = _auth(tok)

        before = c.get("/player/full", headers=h).json()
        inv_before = _inv(pid).get(normalize_item_id(label), 0)

        r = _buy(c, h, label)
        assert r.status_code == 200, r.text

        canonical = normalize_item_id(label)
        assert _inv(pid).get(canonical, 0) == inv_before + 1, (
            f"{label}: inventory row not delivered")

        after = c.get("/player/full", headers=h).json()
        assert (after["btc"], after["plt"]) != (before["btc"], before["plt"]), \
            f"{label}: currency was not debited"

        # M2: stored under the canonical id, never the display spelling.
        stored = _inv(pid)
        assert all(" " not in k for k in stored), stored


def test_m3_response_carries_authoritative_state():
    """M3: the response returns the server's own balance + inventory."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m3")
        _fund(pid)
        h = _auth(tok)

        data = _buy(c, h, "LF1").json()
        live = c.get("/player/full", headers=h).json()

        assert data["inventory"] == live["inventory"], (
            "response inventory disagrees with the server")
        assert data["btc"] == live["btc"]
        assert data["plt"] == live["plt"]
        assert data["purchase"]["item_id"] == "lf1"
        assert data["purchase"]["price"] == CATALOG_BY_ID["lf1"][2]


def test_m4_client_keys_are_normalized():
    """M4: THE BUG. The response must satisfy the gate market.gd reads."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m4")
        _fund(pid)
        data = _buy(c, _auth(tok), "Kalkan 1").json()

        # market.gd: if not bool(result.get("basarili", false)): <bail>
        assert data.get("basarili") is True, (
            "server response has no 'basarili'; market.gd bails out and the "
            "purchased item is never applied or shown")
        # market.gd: result.get("mesaj", ...) for the success text.
        assert str(data.get("mesaj", "")).strip() != ""


def test_m5_rejection_is_not_unreachable():
    """M5: a server refusal must NOT open the local-economy fallback."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m5")
        _fund(pid)
        # An unknown id is refused with 400, and the refusal carries no
        # inventory, so the client cannot treat it as a delivered item.
        r = _buy(c, _auth(tok), "bilinmeyen_esya_999")
        assert r.status_code == 400, r.text
        assert "inventory" not in r.json()


def test_m6_only_unreachable_sets_the_fallback_flag():
    """M6: the flag is a transport fact, never a business outcome."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m6")
        _fund(pid)
        data = _buy(c, _auth(tok), "LF2").json()
        # A successful HTTP 200 must never claim the server was unreachable.
        assert data.get("server_erisilemez") is False


def test_m7_client_price_and_currency_are_ignored():
    """M7: the catalog decides the price; a forged cheap price does nothing."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m7")
        _fund(pid)
        h = _auth(tok)

        before = c.get("/player/full", headers=h).json()
        r = c.post("/market/buy", headers=h, json={
            "item_id": "lf1", "currency": "BTC", "price": 1,
            "transaction_id": f"tx_forge_{time.time_ns()}",
        })
        assert r.status_code == 200, r.text
        after = c.get("/player/full", headers=h).json()

        real = CATALOG_BY_ID["lf1"][2]
        assert before["btc"] - after["btc"] == real, (
            "server used the client's price instead of the catalog price")

        # A wrong currency is refused outright.
        bad = c.post("/market/buy", headers=h, json={
            "item_id": "lf1", "currency": "PLT", "price": 0,
            "transaction_id": f"tx_cur_{time.time_ns()}",
        })
        assert bad.status_code == 400


def test_m8_duplicate_transaction_is_idempotent():
    """M8: the same transaction_id must not charge or deliver twice.

    The first-registration reward already grants 1 lf1, so the baseline is
    captured rather than assumed to be 0.
    """
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m8")
        _fund(pid)
        h = _auth(tok)
        tx = f"tx_dup_{time.time_ns()}"
        baseline = _inv(pid).get("lf1", 0)

        first = _buy(c, h, "LF1", tx=tx).json()
        after_first = _inv(pid).get("lf1", 0)
        assert after_first == baseline + 1, "the first purchase did not deliver"

        second = _buy(c, h, "LF1", tx=tx).json()

        assert first["btc"] == second["btc"], "replay changed the balance"
        assert first["inventory"] == second["inventory"], \
            "replay delivered a second item"
        assert _inv(pid).get("lf1", 0) == after_first, \
            "replay delivered the item twice"
        assert len(_journal(pid)) == 1, "replay wrote a second journal row"


@pytest.mark.parametrize("label", BUY_ITEMS)
def test_m9_survives_logout_login(label):
    """M9: logout -> login must still show the purchased item."""
    with TestClient(app) as c:
        user, pid, tok = _register(c, "m9")
        _fund(pid)
        _buy(c, _auth(tok), label)

        c.post("/auth/logout", headers=_auth(tok))
        again = c.post("/auth/login", json={
            "username": user, "password": "pw-market-123"})
        assert again.status_code == 200
        h2 = _auth(again.json()["access_token"])

        canonical = normalize_item_id(label)
        live = c.get("/player/full", headers=h2).json()
        assert live["inventory"].get(canonical, 0) >= 1, \
            f"{label}: lost after reconnect"
        # The inventory the client syncs from must carry it too.
        inv = c.get("/player/inventory", headers=h2).json()["inventory"]
        assert inv.get(canonical, 0) >= 1


@pytest.mark.parametrize("label", BUY_ITEMS)
def test_m10_journal_records_the_purchase(label):
    """M10: exactly one market_buy row, naming the item."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m10")
        _fund(pid)
        _buy(c, _auth(tok), label)

        rows = _journal(pid)
        assert len(rows) == 1, rows
        assert normalize_item_id(label) in rows[0][1], rows[0][1]


def test_m11_unknown_item_is_refused_and_free():
    """M11: an unknown id costs nothing and delivers nothing."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m11")
        _fund(pid)
        h = _auth(tok)
        before = c.get("/player/full", headers=h).json()

        r = _buy(c, h, "bilinmeyen_esya_999")
        assert r.status_code == 400

        after = c.get("/player/full", headers=h).json()
        assert (after["btc"], after["plt"]) == (before["btc"], before["plt"])


def test_m12_failure_writes_no_journal_and_no_item():
    """M12: a refused purchase is not recorded as a success."""
    with TestClient(app) as c:
        _user, pid, tok = _register(c, "m12")
        # Fund nothing beyond the starter reward: LF1 costs 40000 BTC.
        h = _auth(tok)
        before_inv = _inv(pid)

        r = _buy(c, h, "LF1")
        assert r.status_code == 200
        assert r.json()["success"] is False
        assert r.json()["basarili"] is False

        assert _journal(pid) == [], "failed purchase wrote a market_buy row"
        assert _inv(pid) == before_inv, "failed purchase changed the inventory"

