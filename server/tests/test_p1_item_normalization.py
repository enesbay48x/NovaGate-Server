"""
Phase 1 - item ID normalization + expanded catalog.

Pins the behaviour that made the starter reward invisible: the client said
"Kalkan 1", the server granted "kalkan1", and the UI showed 0.

  N1  display names normalize onto the canonical id
  N2  case / whitespace / accent variants normalize identically
  N3  every canonical id round-trips
  N4  unknown ids are NOT silently mapped to a real item
  N5  an inventory with colliding spellings sums to one physical item
  N6  zero/negative quantities are dropped
  N7  the catalog has no duplicate ids
  N8  the protected pre-existing prices are unchanged
  N9  the market resolves a display name to the canonical catalog row
  N10 /player/inventory returns canonical ids
  N11 the login payload returns canonical ids
"""

import asyncio
import os
import sys
import time

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "phase1-item-normalization-secret-0123456789"
os.environ["DB_PATH"] = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "test_novagate_p1_items.db"
)
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

from item_catalog import (  # noqa: E402
    CATALOG_BY_ID, CATALOG_ROWS, canonical_ids, display_name, is_known_item,
    normalize_inventory, normalize_item_id,
)
from main import app, init_db, reset_rate_limits, grant_currency  # noqa: E402
import main as main_module  # noqa: E402

DB_PATH_TEST = os.environ["DB_PATH"]
PASSWORD = "TestPass123!"

# The prices the project shipped before Phase 1. Phase 1 must not move them.
PROTECTED_PRICES = {
    "lf1": (40000, "BTC"),
    "lf2": (80000, "BTC"),
    "lf3": (20000, "PLT"),
    "kalkan1": (125000, "BTC"),
    "kalkan2": (15000, "PLT"),
    "hiz1": (125000, "BTC"),
    "hiz2": (10000, "PLT"),
    "ema": (150000, "PLT"),
    "enc": (95000, "PLT"),
    "nukleer": (90000, "PLT"),
    "uc_saniye": (120000, "PLT"),
    "log_disk_1": (300, "PLT"),
    "log_disk_50": (15000, "PLT"),
    "log_disk_100": (30000, "PLT"),
    "log_disk_1000": (300000, "PLT"),
}


def _uname(prefix="p1item"):
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


def _reset_db():
    main_module.DB_PATH = DB_PATH_TEST
    if os.path.exists(DB_PATH_TEST):
        try:
            os.remove(DB_PATH_TEST)
        except OSError:
            pass


@pytest.fixture(scope="module", autouse=True)
def _app():
    _reset_db()
    asyncio.run(init_db())
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


def _run(coro):
    """Run a coroutine to completion on a private loop.

    Other modules in this suite create and close their own loops, so the thread
    default cannot be relied upon here.
    """
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


# Module-scoped "current account", so a test needing a top-up does not have to
# re-register (which would mint a different player_id).
_STATE: dict = {}


def _player_id(_client=None):
    return _STATE["player_id"]


def _token(_client=None):
    return _STATE["access_token"]


def _remember(body: dict) -> dict:
    _STATE["player_id"] = body["player_id"]
    _STATE["access_token"] = body["access_token"]
    return body


# ---------------------------------------------------------------------------
# N1-N4  pure normalization
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("raw,expected", [
    ("Kalkan 1", "kalkan1"), ("kalkan1", "kalkan1"), ("KALKAN1", "kalkan1"),
    ("Kalkan 2", "kalkan2"), ("kalkan_1", "kalkan1"), ("kalkan-2", "kalkan2"),
    ("Kalkan I", "kalkan1"), ("Kalkan II", "kalkan2"),
    ("Hız 1", "hiz1"), ("Hiz 1", "hiz1"), ("HIZ 1", "hiz1"),
    ("Hız 2", "hiz2"), ("hiz_1", "hiz1"), ("hiz_2", "hiz2"),
    ("LF1", "lf1"), ("lf1", "lf1"), ("LF 1", "lf1"), ("lf 3", "lf3"),
    ("PBMB", "pbmb"), ("WSH", "wsh"), ("EMP", "emp"), ("INVIS", "invis"),
    ("FREP", "frep"), ("ACPR", "acpr"),
    ("PLUS", "droid_plus_1"), ("ZEUS", "droid_zeus_1"),
    ("PLUS Droid", "droid_plus_1"), ("ZEUS Droid", "droid_zeus_1"),
    ("3 Saniye", "uc_saniye"), ("100 Log Disk", "log_disk_100"),
    ("  Kalkan 1  ", "kalkan1"), ("Kalkan\t1", "kalkan1"),
])
def test_display_name_normalizes_to_canonical(raw, expected):
    assert normalize_item_id(raw) == expected


def test_every_canonical_id_round_trips():
    for cid in CATALOG_BY_ID:
        assert normalize_item_id(cid) == cid, f"round-trip broke for {cid}"
        assert is_known_item(cid), f"{cid} should be a known item"


def test_unknown_item_is_not_mapped_to_a_real_one():
    for raw in ("Kalkan 3", "Hiz 9", "Nukleer X", "not_an_item", "lf9"):
        got = normalize_item_id(raw)
        assert got not in CATALOG_BY_ID, f"{raw!r} wrongly mapped to {got!r}"
        assert got != "", "unknown id must never normalize to empty"


def test_empty_and_none_normalize_to_empty():
    for raw in ("", "   ", None):
        assert normalize_item_id(raw) == ""


def test_display_name_is_never_empty():
    for cid in CATALOG_BY_ID:
        assert display_name(cid).strip() != ""


# ---------------------------------------------------------------------------
# N5-N6  inventory folding
# ---------------------------------------------------------------------------
def test_colliding_spellings_sum_to_one_physical_item():
    inv = normalize_inventory({
        "Kalkan 1": 1, "kalkan1": 2, "KALKAN1": 3,
        "Hız 1": 1, "Hiz 1": 2,
    })
    assert inv.get("kalkan1") == 6, inv
    assert inv.get("hiz1") == 3, inv
    # Non-canonical spellings must not survive as their own rows.
    assert "Kalkan 1" not in inv and "Hız 1" not in inv and "Hiz 1" not in inv


def test_zero_negative_and_invalid_quantities_are_dropped():
    inv = normalize_inventory({"X1": 0, "RSB": -5, "SAB": "abc", "": 3,
                               "Kalkan 1": 1})
    assert inv == {"kalkan1": 1}, inv


def test_non_dict_inventory_is_empty():
    for bad in (None, [], "x", 5):
        assert normalize_inventory(bad) == {}


def test_canonical_ids_dedupes_and_preserves_order():
    assert canonical_ids(["LF1", "lf1", "Kalkan 1", "", "Hiz 1"]) == [
        "lf1", "kalkan1", "hiz1",
    ]

# ---------------------------------------------------------------------------
# N7-N8  catalog integrity
# ---------------------------------------------------------------------------
def test_catalog_has_no_duplicate_ids():
    seen = set()
    for row in CATALOG_ROWS:
        assert row[0] not in seen, f"duplicate catalog row {row[0]}"
        seen.add(row[0])


def test_protected_prices_are_unchanged():
    for item_id, (price, currency) in PROTECTED_PRICES.items():
        assert item_id in CATALOG_BY_ID, f"{item_id} vanished from the catalog"
        _, _, got_price, got_currency, _ = CATALOG_BY_ID[item_id]
        assert got_price == price, (
            f"{item_id} price changed {price} -> {got_price}; Phase 1 must not "
            f"move a market price"
        )
        assert got_currency == currency, (
            f"{item_id} currency changed {currency} -> {got_currency}"
        )


def test_catalog_expanded_with_previously_missing_ids():
    # These exist in the client's _default_inventory but were never sellable.
    for item_id in ("pbmb", "wsh", "emp", "invis", "frep", "acpr"):
        assert item_id in CATALOG_BY_ID, f"{item_id} missing from the catalog"


# ---------------------------------------------------------------------------
# N9-N11  the running server agrees
# ---------------------------------------------------------------------------
def test_catalog_endpoint_contains_canonical_ids(_app):
    resp = _app.get("/market/catalog")
    assert resp.status_code == 200
    ids = {row["item_id"] for row in resp.json()["items"]}
    for expected in ("lf1", "kalkan1", "hiz1", "pbmb", "ammo_x1_1000"):
        assert expected in ids, f"{expected} missing from /market/catalog"


def test_market_accepts_a_display_name(_app):
    # "Kalkan 2" costs 15000 PLT - more than the 10000 PLT starter reward - so
    # the display-name resolution is proven on an affordable item. `ammo_sab_1000`
    # costs 500 PLT and its display name is "1000 SAB", which only resolves
    # through normalize_item_id (it is not an alias). Currency is topped up
    # through the server helper rather than by weakening the assertion.
    username, _ = _register(_app)
    _remember(_login(_app, username))
    _run(grant_currency(_player_id(), plt=50000, reason="test_topup"))
    headers = {"Authorization": f"Bearer {_token()}"}

    resp = _app.post("/market/buy", headers=headers,
                     json={"item_id": "1000 SAB", "currency": "PLT"})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["success"] is True, body
    assert body["purchase"]["item_id"] == "ammo_sab_1000"
    assert "ammo_sab_1000" in body["inventory"]
    assert "1000 SAB" not in body["inventory"]


def test_market_rejects_an_unknown_item(_app):
    username, _ = _register(_app)
    token = _login(_app, username)["access_token"]
    resp = _app.post("/market/buy",
                     headers={"Authorization": f"Bearer {token}"},
                     json={"item_id": "Kalkan 99", "currency": "PLT"})
    assert resp.status_code == 400, resp.text


def test_player_inventory_endpoint_is_canonical(_app):
    username, _ = _register(_app)
    token = _login(_app, username)["access_token"]
    resp = _app.get("/player/inventory",
                    headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    inv = resp.json()["inventory"]
    assert inv.get("lf1") == 1, inv
    assert inv.get("kalkan1") == 1, inv
    assert inv.get("hiz1") == 1, inv
    assert "Kalkan 1" not in inv and "Hız 1" not in inv


def test_login_payload_inventory_is_canonical(_app):
    username, _ = _register(_app)
    inv = _login(_app, username)["oyuncu"]["inventory"]
    assert inv.get("lf1") == 1
    assert inv.get("kalkan1") == 1
    assert inv.get("hiz1") == 1
    assert "Kalkan 1" not in inv and "Hız 1" not in inv


def test_reward_values_match_the_phase1_contract(_app):
    """10000 BTC / 10000 PLT / LF1 x1 / Kalkan I x1 / Hiz I x1."""
    _, reg = _register(_app)
    reward = reg["first_registration_reward"]
    assert reward["btc"] == 10000
    assert reward["plt"] == 10000
    assert reward["items"] == {"lf1": 1, "kalkan1": 1, "hiz1": 1}


