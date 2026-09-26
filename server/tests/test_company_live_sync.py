"""
NovaGate company / live-sync / PvP-relation regression tests.

These checks lock down the two production defects found after deploy 8b4cf3b
(6/8 smoke PASS):

  BUG 1 - LIVE COMPANY SYNC
      `PUT /account/company` only wrote the `accounts` row, so a player that was
      ALREADY connected kept company "" in its live PlayerSession. Peers then
      observed company "" / relation "neutral" in world_update.

  BUG 2 - COMPANY LOST ON A REFRESHED TOKEN  (independent of bug 1)
      `/auth/refresh` minted an access token with NO `session_jti`, and
      `ConnectionManager.connect()` only read the company from the DB inside its
      `if session_jti` branch. A client that refreshed its token (the Godot
      client does exactly this) therefore reconnected with company "" even
      though the DB row was correct -> relation "neutral" -> PvP permanently
      disabled for that session.

Guarantees asserted here (nothing is loosened):
  * the DB row and the live session always carry the same company
  * peers observe the new company / relation WITHOUT any reconnect
  * a refreshed access token still yields the real company and a working PvP
  * only a real ENEMY company is targetable (neutral / friendly stay rejected)
  * relation computation and the PvP gate stay server-side and unchanged
"""

import asyncio
import json
import os
import sys
import time

import aiosqlite
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "test-secret-key-for-company-live-sync-only"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_novagate_company.db")
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "200/minute"
os.environ["RATE_LIMIT_REGISTER"] = "200/minute"

from main import app, init_db, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402
from websocket_server import (  # noqa: E402
    manager,
    broadcast_world_state,
    calculate_company_relation,
)

DB_PATH_TEST = os.environ["DB_PATH"]
PASSWORD = "TestPass123!"
COMPANY_A = "EIC"
COMPANY_B = "MMO"
COMPANY_C = "VRU"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _reset_db():
    main_module.DB_PATH = DB_PATH_TEST
    if os.path.exists(DB_PATH_TEST):
        try:
            os.remove(DB_PATH_TEST)
        except OSError:
            pass


async def _init_test_db():
    _reset_db()
    await init_db()


def _clear_connections():
    manager.active_connections.clear()
    manager.ship_locks.clear()


def _make_username(prefix: str = "compsync") -> str:
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


def _register_and_login(client, prefix: str, company: str = "") -> dict:
    """Real account through the public pipeline (register -> login -> verify)."""
    username = _make_username(prefix)
    client.post("/auth/register", json={
        "username": username,
        "password": PASSWORD,
        "nickname": username,
        "company": company,
    })
    data = client.post("/auth/login", json={
        "username": username,
        "password": PASSWORD,
    }).json()
    verify = client.get(
        "/auth/verify",
        headers={"Authorization": f"Bearer {data['access_token']}"},
    ).json()
    return {
        "username": username,
        "token": data["access_token"],
        "refresh_token": data["refresh_token"],
        "player_id": verify["player_id"],
        "company": data.get("company", ""),
    }


def _refresh(client, acc: dict) -> dict:
    """Exchange the refresh token for a NEW access token (client behaviour)."""
    resp = client.post("/auth/refresh", json={"refresh_token": acc["refresh_token"]})
    assert resp.status_code == 200, resp.text
    data = resp.json()
    acc["token"] = data["access_token"]
    acc["refresh_token"] = data["refresh_token"]
    return acc


def _put_company(client, acc: dict, company: str):
    return client.put(
        "/account/company",
        json={"company": company},
        headers={"Authorization": f"Bearer {acc['token']}"},
    )


def _ws_url(token: str) -> str:
    return f"/ws/game?token={token}"


def _expect_welcome(ws) -> dict:
    msg = json.loads(ws.receive_text())
    assert msg.get("type") == "welcome", f"expected welcome, got {msg.get('type')}"
    return msg


def _expect_type(ws, expected: str, limit: int = 60) -> dict:
    for _ in range(limit):
        msg = json.loads(ws.receive_text())
        if msg.get("type") == expected:
            return msg
    raise AssertionError(f"message type {expected} not received within {limit} frames")


def _sync(ws) -> None:
    """FIFO barrier so every previously sent client message was handled."""
    ws.send_text(json.dumps({"type": "heartbeat"}))
    _expect_type(ws, "heartbeat_ack")


def _snapshot(ws) -> dict:
    """Deterministic world_update produced by this test."""
    _sync(ws)
    asyncio.run(broadcast_world_state())
    return _expect_type(ws, "world_update")


def _fire(ws, target_player_id: str, weapon: int = 1):
    ws.send_text(json.dumps({
        "type": "fire",
        "weapon": weapon,
        "target_x": 0.0,
        "target_y": 0.0,
        "target_player_id": target_player_id,
    }))


def _drain_until_pong(ws, limit: int = 50) -> list:
    ws.send_text(json.dumps({"type": "ping"}))
    frames = []
    for _ in range(limit):
        frame = json.loads(ws.receive_text())
        frames.append(frame)
        if frame.get("type") == "pong":
            break
    return frames


def _session(player_id: str):
    return manager.active_connections.get(player_id)


def _peer(state: dict, player_id: str):
    for entry in state.get("players", []):
        if str(entry.get("player_id", "")) == player_id:
            return entry
    return None


async def _stored_company(player_id: str):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cursor = await db.execute("SELECT company FROM accounts WHERE player_id = ?", (player_id,))
        row = await cursor.fetchone()
        return row[0] if row else None


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def client():
    asyncio.run(_init_test_db())
    with TestClient(app) as c:
        yield c


@pytest.fixture(autouse=True)
def cleanup():
    _clear_connections()
    reset_rate_limits()
    yield
    _clear_connections()


# ---------------------------------------------------------------------------
# BUG 1 - company persistence + live session sync
# ---------------------------------------------------------------------------
class TestCompanyLiveSync:
    def test_01_register_persists_company(self, client):
        acc = _register_and_login(client, "compsync_reg", COMPANY_B)
        assert asyncio.run(_stored_company(acc["player_id"])) == COMPANY_B

    def test_02_put_company_persists_and_syncs_live_session(self, client):
        acc = _register_and_login(client, "compsync_put")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            assert _session(acc["player_id"]).company == ""

            resp = _put_company(client, acc, COMPANY_A)
            assert resp.status_code == 200, resp.text
            assert resp.json()["company"] == COMPANY_A

            session = _session(acc["player_id"])
            assert session is not None, "session vanished after company update"
            # DB and live session must agree.
            assert session.company == COMPANY_A
        assert asyncio.run(_stored_company(acc["player_id"])) == COMPANY_A

    def test_03_peer_sees_new_company_without_reconnect(self, client):
        """THE production failure: PUT returned 200 but peers still saw ''."""
        a = _register_and_login(client, "compsync_va")
        b = _register_and_login(client, "compsync_vb")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)

            # Before: no company anywhere.
            assert _peer(_snapshot(ws_b), a["player_id"])["company"] == ""

            assert _put_company(client, a, COMPANY_A).status_code == 200
            assert _put_company(client, b, COMPANY_B).status_code == 200

            # No reconnect happened - only a new world snapshot.
            seen = _peer(_snapshot(ws_b), a["player_id"])
            assert seen is not None
            assert seen["company"] == COMPANY_A
            assert seen["relation"] == "enemy"

    def test_04_invalid_company_rejected_and_live_state_untouched(self, client):
        acc = _register_and_login(client, "compsync_bad", COMPANY_A)
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            resp = _put_company(client, acc, "XXX")
            assert resp.status_code == 400
            assert _session(acc["player_id"]).company == COMPANY_A
        assert asyncio.run(_stored_company(acc["player_id"])) == COMPANY_A

    def test_05_set_company_helper_semantics(self, client):
        """set_company is the single live-sync entry point used by the route."""
        assert asyncio.run(manager.set_company("no_such_player", COMPANY_A)) is False

        acc = _register_and_login(client, "compsync_helper")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            assert asyncio.run(manager.set_company(acc["player_id"], "eic")) is True
            # Normalization must match the DB form written by the route.
            assert _session(acc["player_id"]).company == COMPANY_A
            _sync(ws)

        # Session is gone -> a later update must not resurrect it.
        assert asyncio.run(manager.set_company(acc["player_id"], COMPANY_C)) is False

    def test_06_existing_account_reconnect_still_loads_company(self, client):
        """Existing-account login must not be broken by the live sync."""
        acc = _register_and_login(client, "compsync_recon", COMPANY_C)
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            welcome = _expect_welcome(ws)
            assert welcome["company"] == COMPANY_C
            assert _session(acc["player_id"]).company == COMPANY_C


# ---------------------------------------------------------------------------
# BUG 2 - a REFRESHED access token must not lose the company
# ---------------------------------------------------------------------------
class TestRefreshedTokenKeepsCompany:
    def test_07_refreshed_token_welcome_carries_company(self, client):
        acc = _register_and_login(client, "compsync_ref", COMPANY_A)
        _refresh(client, acc)
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            welcome = _expect_welcome(ws)
            assert welcome["company"] == COMPANY_A, (
                "refreshed access token lost the company -> PvP would be neutral"
            )
            assert _session(acc["player_id"]).company == COMPANY_A

    def test_08_refreshed_token_peer_relation_is_enemy(self, client):
        a = _register_and_login(client, "compsync_ra", COMPANY_A)
        b = _register_and_login(client, "compsync_rb", COMPANY_B)
        _refresh(client, a)
        _refresh(client, b)
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)

            a_sees_b = _peer(_snapshot(ws_a), b["player_id"])
            b_sees_a = _peer(_snapshot(ws_b), a["player_id"])
            assert a_sees_b["company"] == COMPANY_B and a_sees_b["relation"] == "enemy"
            assert b_sees_a["company"] == COMPANY_A and b_sees_a["relation"] == "enemy"

    def test_09_refreshed_token_pvp_damage_is_applied(self, client):
        a = _register_and_login(client, "compsync_pa", COMPANY_A)
        b = _register_and_login(client, "compsync_pb", COMPANY_B)
        _refresh(client, a)
        _refresh(client, b)
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            target = _session(b["player_id"])
            shield_before = target.shield

            _fire(ws_a, b["player_id"], weapon=1)

            event_a = _expect_type(ws_a, "player_hit")
            assert event_a["attacker_id"] == a["player_id"]
            assert event_a["target_id"] == b["player_id"]
            assert float(event_a["damage"]) > 0.0
            assert float(event_a["target_shield"]) < shield_before
            assert target.shield < shield_before

            event_b = _expect_type(ws_b, "player_hit")
            assert event_b["target_id"] == b["player_id"]
            assert event_b["attacker_id"] == a["player_id"]

    def test_10_refreshed_access_token_is_still_session_bound(self, client):
        """A refreshed token must not become an unvalidatable token."""
        acc = _register_and_login(client, "compsync_bind", COMPANY_A)
        _refresh(client, acc)
        ok = client.get("/auth/verify", headers={"Authorization": f"Bearer {acc['token']}"})
        assert ok.status_code == 200, ok.text
        assert ok.json()["company"] == COMPANY_A

        assert client.post(
            "/auth/logout", headers={"Authorization": f"Bearer {acc['token']}"}
        ).status_code == 200
        after = client.get("/auth/verify", headers={"Authorization": f"Bearer {acc['token']}"})
        assert after.status_code == 401, "refreshed token survived logout"


# ---------------------------------------------------------------------------
# company relation - enemy-only PvP stays intact
# ---------------------------------------------------------------------------
class TestCompanyRelationAndPvpGate:
    def test_11_relation_is_the_single_server_authority(self):
        assert calculate_company_relation("EIC", "EIC") == "friendly"
        assert calculate_company_relation("eic", "EIC") == "friendly"
        assert calculate_company_relation("EIC", "MMO") == "enemy"
        assert calculate_company_relation("EIC", "VRU") == "enemy"
        # No company is NEVER an enemy - this must not be relaxed.
        assert calculate_company_relation("EIC", "") == "neutral"
        assert calculate_company_relation("", "EIC") == "neutral"
        assert calculate_company_relation("", "") == "neutral"

    def test_12_relation_enemy_both_directions_after_live_sync(self, client):
        a = _register_and_login(client, "compsync_ea")
        b = _register_and_login(client, "compsync_eb")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            assert _put_company(client, a, COMPANY_A).status_code == 200
            assert _put_company(client, b, COMPANY_B).status_code == 200

            a_sees_b = _peer(_snapshot(ws_a), b["player_id"])
            b_sees_a = _peer(_snapshot(ws_b), a["player_id"])
            assert a_sees_b["relation"] == "enemy"
            assert b_sees_a["relation"] == "enemy"
            assert a_sees_b["company"] == COMPANY_B
            assert b_sees_a["company"] == COMPANY_A

    def test_13_pvp_damage_after_live_company_sync(self, client):
        """Full production scenario: PUT company, then a real server hit."""
        a = _register_and_login(client, "compsync_lsa")
        b = _register_and_login(client, "compsync_lsb")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            assert _put_company(client, a, COMPANY_A).status_code == 200
            assert _put_company(client, b, COMPANY_B).status_code == 200

            target = _session(b["player_id"])
            shield_before = target.shield
            hp_before = target.hp
            assert shield_before == 100.0 and hp_before == 100.0

            _fire(ws_a, b["player_id"], weapon=1)

            event_a = _expect_type(ws_a, "player_hit")
            assert event_a["attacker_company"] == COMPANY_A
            assert event_a["target_company"] == COMPANY_B
            assert float(event_a["damage"]) > 0.0

            assert target.shield < shield_before
            assert target.shield + target.hp < shield_before + hp_before

            event_b = _expect_type(ws_b, "player_hit")
            assert event_b["target_id"] == b["player_id"]

    def test_14_live_sync_to_same_company_still_rejected(self, client):
        """Live sync must not let the PvP gate through friendly fire."""
        a = _register_and_login(client, "compsync_fa")
        b = _register_and_login(client, "compsync_fb")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            assert _put_company(client, a, COMPANY_A).status_code == 200
            assert _put_company(client, b, COMPANY_A).status_code == 200

            target = _session(b["player_id"])
            assert _peer(_snapshot(ws_a), b["player_id"])["relation"] == "friendly"

            _fire(ws_a, b["player_id"], weapon=1)
            frames = _drain_until_pong(ws_a)
            assert all(f.get("type") != "player_hit" for f in frames), \
                "same-company player was hit after live sync"
            assert target.shield == 100.0 and target.hp == 100.0

    def test_15_companyless_player_stays_neutral_and_untargetable(self, client):
        a = _register_and_login(client, "compsync_na", COMPANY_A)
        b = _register_and_login(client, "compsync_nb")  # never picks a company
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            assert _peer(_snapshot(ws_a), b["player_id"])["relation"] == "neutral"

            target = _session(b["player_id"])
            _fire(ws_a, b["player_id"], weapon=1)
            frames = _drain_until_pong(ws_a)
            assert all(f.get("type") != "player_hit" for f in frames), \
                "company-less player was hit"
            assert target.shield == 100.0 and target.hp == 100.0
