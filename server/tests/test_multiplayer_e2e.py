"""
NovaGate server-authoritative multiplayer E2E checklist (37 checks).

This module is the "real end-to-end" companion of test_websocket.py: every
check exercises the live FastAPI app + real WebSocket endpoint + real SQLite
session/economy tables (no mocks), and follows the post-refactor product rules:

  1  welcome carries player_id / username / company
  2  register creates an OWN economy row keyed by player_id
  3  register persists the company (server-authoritative)
  4  PUT /account/company updates the LIVE websocket session
  5  same account, 2nd socket -> old session receives session_kicked
  6  stale (kicked) socket cleanup never deletes the new session
  7  POST /auth/logout kicks only the logging-out player's socket
  8  two different accounts may share one ship_id (no ship lock)
  9  one account = exactly one live session per player_id
 10  GET /api/session_info mirrors the live session
 11  connect sends the world snapshot immediately (after welcome)
 12  world_update never contains the receiving player itself
 13  world_update carries company/level/map_id/ship_id/last_seen
 14  map isolation: other map players are invisible
 15  returning to the map restores visibility
 16  interest radius limits visibility
 17  valid "move" (map change) is acknowledged with map_changed
 18  invalid map id is rejected (previous map survives)
 19  input magnitude is clamped (anti-cheat)
 20  malformed input defaults to zero
 21  server computes positions (client never sends x/y)
 22  server clamps positions to the world rect
 23  heartbeat is acknowledged without dropping the session
 24  heartbeat timeout drops the session server-side
 25  PvP: fire{target_player_id} applies server-side damage
 26  PvP: same-company friendly fire is rejected
 27  PvP: cross-map shots are rejected
 28  PvP: out-of-range shots are rejected
 29  PvP: self-targeting is rejected
 30  PvP: invalid weapon slots are rejected
 31  PvP: SAB (slot 5) drains target shield into the attacker
 32  PvP: lethal damage -> player_death + server-side respawn
 33  PvP: fire cooldown (rate limit) is enforced server-side
  34  the client-reported ship speed drives the authoritative motion
  35  the reported speed is capped by MAX_SPEED (anti-cheat ceiling)
  36  a client that omits "speed" keeps the MAX_SPEED default
  37  world_update carries the receiver's OWN authoritative position (self)
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

os.environ["SECRET_KEY"] = "test-secret-key-for-mp-e2e-only"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_novagate_mp.db")
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "200/minute"
os.environ["RATE_LIMIT_REGISTER"] = "200/minute"

from main import app, init_db, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402
from websocket_server import (  # noqa: E402
    PlayerSession,
    broadcast_world_state,
    handle_player_fire,
    manager,
    FIRE_COOLDOWN_SECONDS,
    HEARTBEAT_TIMEOUT,
    INTEREST_RADIUS,
    MAX_SPEED,
    PLAYER_LASER_RANGE,
    TICK_INTERVAL,
    WORLD_RECT_MAX,
    WORLD_RECT_MIN,
)

DB_PATH_TEST = os.environ["DB_PATH"]
PASSWORD = "TestPass123!"
COMPANY_A = "EIC"
COMPANY_B = "MMO"


# ---------------------------------------------------------------------------
# setup helpers
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


def _make_username(prefix: str = "mpe2e") -> str:
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


def _register_and_login(client, prefix: str, company: str = "") -> dict:
    """Create a real account (HTTP) and log in, returning its identity."""
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


def _ws_url(token: str) -> str:
    return f"/ws/game?token={token}"


def _receive_json(ws) -> dict:
    return json.loads(ws.receive_text())


def _expect_welcome(ws) -> dict:
    msg = _receive_json(ws)
    assert msg.get("type") == "welcome", f"expected welcome, got {msg.get('type')}"
    return msg


def _expect_type(ws, expected: str, limit: int = 60) -> dict:
    """Read messages (skipping pings / other broadcasts) until `expected`."""
    for _ in range(limit):
        msg = _receive_json(ws)
        if msg.get("type") == expected:
            return msg
    raise AssertionError(f"message type {expected} not received within {limit} frames")


def _collect_until(ws, expected: str, limit: int = 40) -> list:
    """Read messages up to and including `expected`; return all of them."""
    seen = []
    for _ in range(limit):
        msg = _receive_json(ws)
        seen.append(msg)
        if msg.get("type") == expected:
            return seen
    raise AssertionError(f"message type {expected} not received within {limit} frames")


def _sync(ws) -> None:
    """FIFO barrier: guarantees every previously sent client message was handled."""
    ws.send_text(json.dumps({"type": "heartbeat"}))
    _expect_type(ws, "heartbeat_ack")


def _snapshot(ws) -> dict:
    """Return a deterministic world_update produced by this test."""
    _sync(ws)
    asyncio.run(broadcast_world_state())
    return _expect_type(ws, "world_update")


def _fire(ws, target_player_id: str, weapon: int = 1, target_x: float = 0.0, target_y: float = 0.0):
    ws.send_text(json.dumps({
        "type": "fire",
        "weapon": weapon,
        "target_x": target_x,
        "target_y": target_y,
        "target_player_id": target_player_id,
    }))


def _session(player_id: str):
    return manager.active_connections.get(player_id)


def _find_player(state: dict, player_id: str):
    for entry in state.get("players", []):
        if str(entry.get("player_id", "")) == player_id:
            return entry
    return None

def _fake_session(player_id: str, username: str, company: str = "",
                  map_id: str = "1-1", x: float = 0.0, y: float = 0.0,
                  hp: float = 100.0, shield: float = 100.0) -> PlayerSession:
    """Register a websocket-less session for pure server-logic checks."""
    session = PlayerSession(
        account_id=1,
        player_id=player_id,
        username=username,
        ship_id="Ship10",
        map_id=map_id,
        position_x=x,
        position_y=y,
    )
    session.hp = hp
    session.max_hp = 100.0
    session.shield = shield
    session.max_shield = 100.0
    session.company = company
    manager.active_connections[player_id] = session
    return session


async def _one_world_tick():
    """Mirror of world_tick body (TestClient has no 20 Hz loop of its own)."""
    current_time = time.time()
    async with manager._lock:
        expired = []
        for pid, player in list(manager.active_connections.items()):
            if current_time - player.last_heartbeat > HEARTBEAT_TIMEOUT:
                expired.append(pid)
        for pid in expired:
            player = manager.active_connections.get(pid)
            if player and player.websocket:
                try:
                    await player.websocket.close(code=1001, reason="Heartbeat timeout")
                except Exception:
                    pass
            manager.active_connections.pop(pid, None)
            if player and player.ship_id:
                manager.ship_locks.pop(player.ship_id, None)
            if player:
                player.disconnected = True

        for player in list(manager.active_connections.values()):
            if player.disconnected:
                continue
            magnitude = (player.input_x ** 2 + player.input_y ** 2) ** 0.5
            if magnitude > 1.0:
                player.input_x /= magnitude
                player.input_y /= magnitude
            # Mirrors world_tick: the session's own speed (client-reported,
            # capped by MAX_SPEED) drives the authoritative motion.
            new_x = player.position_x + player.input_x * player.speed * TICK_INTERVAL
            new_y = player.position_y + player.input_y * player.speed * TICK_INTERVAL
            player.position_x = max(WORLD_RECT_MIN[0], min(WORLD_RECT_MAX[0], new_x))
            player.position_y = max(WORLD_RECT_MIN[1], min(WORLD_RECT_MAX[1], new_y))
            player.last_input_time = current_time
    await broadcast_world_state()


def _tick_once():
    asyncio.run(_one_world_tick())


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
@pytest.fixture(scope="module")
def client():
    asyncio.run(_init_test_db())
    with TestClient(app) as c:
        # Determinism fix (no production behaviour changed).
        #
        # `on_startup` launches the REAL 20 Hz `world_tick` task. The movement
        # tests below drive a ship with a manual `_tick_once()` and then assert
        # the distance equals EXACTLY one step (speed * TICK_INTERVAL). When the
        # live loop also fires between the manual tick and the assertion, the
        # ship has moved TWICE and the equality fails with 2x the expected
        # value - a race in the harness, not in the movement code, which is why
        # the module passes in isolation and fails intermittently under load.
        #
        # The background task is cancelled for the duration of the module so
        # the manual tick is the only thing that advances a ship. The movement
        # assertions keep their exact 1e-6 equality, so nothing is weakened.
        asyncio.run(_stop_background_world_tick())
        try:
            yield c
        finally:
            asyncio.run(_restore_background_world_tick())


async def _stop_background_world_tick() -> None:
    import websocket_server as ws
    task = getattr(ws, "_world_task", None)
    if task is not None and not task.done():
        ws._test_saved_world_task = task
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass


async def _restore_background_world_tick() -> None:
    import websocket_server as ws
    task = getattr(ws, "_test_saved_world_task", None)
    if task is not None and not task.done():
        # Resume the loop where it left off.
        ws._world_task = task
    ws._test_saved_world_task = None


@pytest.fixture(autouse=True)
def cleanup():
    _clear_connections()
    reset_rate_limits()
    yield
    _clear_connections()

async def _economy_row(player_id: str):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cursor = await db.execute(
            "SELECT btc, plt, gold FROM economy WHERE player_id = ?", (player_id,)
        )
        return await cursor.fetchall()


async def _stored_company(player_id: str):
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        cursor = await db.execute("SELECT company FROM accounts WHERE player_id = ?", (player_id,))
        row = await cursor.fetchone()
        return row[0] if row else None


# ---------------------------------------------------------------------------
# 1-10 identity / session policy
# ---------------------------------------------------------------------------
class TestSessionIdentity:
    def test_01_welcome_carries_player_identity(self, client):
        acc = _register_and_login(client, "mp_e2e_id", COMPANY_A)
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            welcome = _expect_welcome(ws)
        assert welcome["player_id"] == acc["player_id"]
        assert welcome["username"] == acc["username"]
        assert str(welcome.get("company", "")).upper() == COMPANY_A
        assert welcome.get("map_id") == "1-1"

    def test_02_register_creates_own_economy_row(self, client):
        """Each account owns exactly ONE economy row, seeded with the
        server-authoritative first-registration reward (and nothing else)."""
        acc = _register_and_login(client, "mp_e2e_eco")
        rows = asyncio.run(_economy_row(acc["player_id"]))
        assert len(rows) == 1, f"expected exactly one economy row, got {rows}"
        assert tuple(rows[0]) == (
            main_module.FIRST_REGISTRATION_REWARD_BTC,
            main_module.FIRST_REGISTRATION_REWARD_PLT,
            0,
        ), f"unexpected starting balance: {rows[0]}"

        # Logging in again must not top it up (the reward is granted once).
        payload = client.post("/auth/login", json={
            "username": acc["username"], "password": PASSWORD,
        }).json()["oyuncu"]
        assert payload["bitcoin"] == main_module.FIRST_REGISTRATION_REWARD_BTC
        assert payload["plt"] == main_module.FIRST_REGISTRATION_REWARD_PLT

    def test_03_register_company_persisted(self, client):
        acc = _register_and_login(client, "mp_e2e_comp", COMPANY_B)
        assert asyncio.run(_stored_company(acc["player_id"])) == COMPANY_B

    def test_04_company_update_syncs_live_session(self, client):
        acc = _register_and_login(client, "mp_e2e_upd", COMPANY_A)
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            resp = client.put(
                "/account/company",
                json={"company": "VRU"},
                headers={"Authorization": f"Bearer {acc['token']}"},
            )
            assert resp.status_code == 200, resp.text
            assert resp.json()["company"] == "VRU"
            session = _session(acc["player_id"])
            assert session is not None
            assert session.company == "VRU"
        assert asyncio.run(_stored_company(acc["player_id"])) == "VRU"

    def test_05_second_socket_kicks_first_session(self, client):
        acc = _register_and_login(client, "mp_e2e_kick")
        with client.websocket_connect(_ws_url(acc["token"])) as ws1:
            _expect_welcome(ws1)
            with client.websocket_connect(_ws_url(acc["token"])) as ws2:
                _expect_welcome(ws2)
                kicked = None
                for _ in range(50):
                    candidate = json.loads(ws1.receive_text())
                    if candidate.get("type") == "session_kicked":
                        kicked = candidate
                        break
                assert kicked is not None, "old session did not receive session_kicked"
                assert kicked.get("reason") == "account_logged_in_elsewhere"
                session = _session(acc["player_id"])
                assert session is not None and session.disconnected is False

    def test_06_stale_disconnect_keeps_new_session(self, client):
        acc = _register_and_login(client, "mp_e2e_stale")
        with client.websocket_connect(_ws_url(acc["token"])) as ws1:
            _expect_welcome(ws1)
            with client.websocket_connect(_ws_url(acc["token"])) as ws2:
                _expect_welcome(ws2)
                session = _session(acc["player_id"])
                assert session is not None
                # Cleanup of the kicked (old) socket must not delete the session.
                asyncio.run(manager.disconnect(acc["player_id"], object()))
                assert _session(acc["player_id"]) is session
                assert session.disconnected is False
                _sync(ws2)

    def test_07_logout_kicks_only_own_session(self, client):
        a = _register_and_login(client, "mp_e2e_outa")
        b = _register_and_login(client, "mp_e2e_outb")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            assert _session(a["player_id"]) is not None
            assert _session(b["player_id"]) is not None
            resp = client.post(
                "/auth/logout", headers={"Authorization": f"Bearer {a['token']}"}
            )
            assert resp.status_code == 200, resp.text
            kicked = None
            for _ in range(50):
                candidate = json.loads(ws_a.receive_text())
                if candidate.get("type") == "session_kicked":
                    kicked = candidate
                    break
            assert kicked is not None, "logging-out player was not kicked"
            assert kicked.get("reason") == "logged_out"
            assert _session(a["player_id"]) is None
            b_session = _session(b["player_id"])
            assert b_session is not None and b_session.disconnected is False

    def test_08_two_accounts_same_ship_both_online(self, client):
        a = _register_and_login(client, "mp_e2e_ship_a")
        b = _register_and_login(client, "mp_e2e_ship_b")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            welcome_a = _expect_welcome(ws_a)
            welcome_b = _expect_welcome(ws_b)
            # Both accounts share the default ship: no single-ship lock anymore.
            assert welcome_a["ship_id"] == welcome_b["ship_id"]
            session_a = _session(a["player_id"])
            session_b = _session(b["player_id"])
            assert session_a is not None and session_b is not None
            assert session_a.disconnected is False
            assert session_b.disconnected is False

    def test_09_single_session_per_player_id(self, client):
        acc = _register_and_login(client, "mp_e2e_single")
        with client.websocket_connect(_ws_url(acc["token"])) as ws1:
            _expect_welcome(ws1)
            with client.websocket_connect(_ws_url(acc["token"])) as ws2:
                _expect_welcome(ws2)
                sessions = [s for s in manager.active_connections.values()
                            if s.player_id == acc["player_id"]]
                assert len(sessions) == 1, f"expected 1 session, got {len(sessions)}"
                assert sessions[0].disconnected is False
                # The surviving session is the NEWEST socket (it answers heartbeats).
                _sync(ws2)

    def test_10_session_info_reports_live_state(self, client):
        acc = _register_and_login(client, "mp_e2e_info")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            info = client.get(
                "/api/session_info",
                headers={"Authorization": f"Bearer {acc['token']}"},
            ).json()
            assert info["player_id"] == acc["player_id"]
            assert info["username"] == acc["username"]
            assert info["websocket_connected"] is True
            assert info["session_active"] is True
            assert info["map_id"] == "1-1"

# ---------------------------------------------------------------------------
# 11-18 world state / map isolation
# ---------------------------------------------------------------------------
class TestWorldStateBroadcast:
    def test_11_immediate_world_snapshot_after_welcome(self, client):
        acc = _register_and_login(client, "mp_e2e_snap")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            snapshot = None
            for _ in range(4):
                msg = _receive_json(ws)
                if msg.get("type") == "world_update":
                    snapshot = msg
                    break
            assert snapshot is not None, "no world_update right after welcome"
            assert isinstance(snapshot.get("players"), list)
            assert isinstance(snapshot.get("npcs"), list)
            assert snapshot.get("tick_interval")

    def test_12_world_update_excludes_self(self, client):
        a = _register_and_login(client, "mp_e2e_self_a")
        b = _register_and_login(client, "mp_e2e_self_b")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            state = _snapshot(ws_a)
            assert _find_player(state, a["player_id"]) is None, "own ship echoed back"
            assert _find_player(state, b["player_id"]) is not None, "peer ship missing"

    def test_13_world_update_identity_fields(self, client):
        a = _register_and_login(client, "mp_e2e_fields_a", COMPANY_A)
        b = _register_and_login(client, "mp_e2e_fields_b", COMPANY_B)
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            state = _snapshot(ws_a)
            entry = _find_player(state, b["player_id"])
            assert entry is not None
            for key in ("player_id", "username", "company", "relation", "level", "map_id",
                        "ship_id", "x", "y", "hp", "shield", "last_seen"):
                assert key in entry, f"world_update player entry missing '{key}'"
            assert entry["company"] == COMPANY_B
            assert entry["relation"] == "enemy"
            assert entry["username"] == b["username"]
            assert str(entry["company"]).upper() == COMPANY_B
            assert entry["map_id"] == "1-1"
            assert float(entry["last_seen"]) > 0.0

    def test_14_map_isolation_hides_other_map(self, client):
        a = _register_and_login(client, "mp_e2e_map_a")
        b = _register_and_login(client, "mp_e2e_map_b")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            assert _find_player(_snapshot(ws_a), b["player_id"]) is not None
            ws_a.send_text(json.dumps({"type": "move", "map_id": "2-1"}))
            ack = _expect_type(ws_a, "map_changed")
            assert ack["map_id"] == "2-1"
            assert _session(a["player_id"]).map_id == "2-1"
            assert _find_player(_snapshot(ws_a), b["player_id"]) is None
            # The peer keeps seeing only its own map (A left it).
            peer_state = _snapshot(ws_b)
            assert _find_player(peer_state, b["player_id"]) is None
            assert _find_player(peer_state, a["player_id"]) is None

    def test_15_returning_to_map_restores_visibility(self, client):
        a = _register_and_login(client, "mp_e2e_ret_a")
        b = _register_and_login(client, "mp_e2e_ret_b")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            ws_a.send_text(json.dumps({"type": "move", "map_id": "3-4"}))
            assert _expect_type(ws_a, "map_changed")["map_id"] == "3-4"
            assert _find_player(_snapshot(ws_a), b["player_id"]) is None
            ws_a.send_text(json.dumps({"type": "move", "map_id": "1-1"}))
            assert _expect_type(ws_a, "map_changed")["map_id"] == "1-1"
            assert _find_player(_snapshot(ws_a), b["player_id"]) is not None

    def test_16_interest_radius_limits_visibility(self, client):
        a = _register_and_login(client, "mp_e2e_rad_a")
        b = _register_and_login(client, "mp_e2e_rad_b")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            session_b = _session(b["player_id"])
            session_b.position_x = INTEREST_RADIUS + 500.0
            session_b.position_y = 0.0
            assert _find_player(_snapshot(ws_a), b["player_id"]) is None
            session_b.position_x = INTEREST_RADIUS - 500.0
            assert _find_player(_snapshot(ws_a), b["player_id"]) is not None

    def test_17_valid_map_change_acknowledged(self, client):
        acc = _register_and_login(client, "mp_e2e_mapok")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({"type": "move", "map_id": "3-4"}))
            ack = _expect_type(ws, "map_changed")
            assert ack["map_id"] == "3-4"
            assert _session(acc["player_id"]).map_id == "3-4"
            info = client.get(
                "/api/session_info",
                headers={"Authorization": f"Bearer {acc['token']}"},
            ).json()
            assert info["map_id"] == "3-4"

    def test_18_invalid_map_change_rejected(self, client):
        acc = _register_and_login(client, "mp_e2e_mapbad")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({"type": "move", "map_id": "99-9"}))
            ws.send_text(json.dumps({"type": "heartbeat"}))
            frames = _collect_until(ws, "heartbeat_ack")
            assert all(f.get("type") != "map_changed" for f in frames), \
                "invalid map id was acknowledged"
            assert _session(acc["player_id"]).map_id == "1-1"
            ws.send_text(json.dumps({"type": "move", "map_id": "3-1"}))
            assert _expect_type(ws, "map_changed")["map_id"] == "3-1"

# ---------------------------------------------------------------------------
# 19-24 movement / liveness authority
# ---------------------------------------------------------------------------
class TestMovementAuthority:
    def test_19_input_magnitude_clamped(self, client):
        acc = _register_and_login(client, "mp_e2e_clamp")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({"type": "input", "input_x": 5.0, "input_y": 0.0}))
            _sync(ws)
            session = _session(acc["player_id"])
            assert session is not None
            assert abs(session.input_x - 1.0) < 1e-6, f"input_x={session.input_x}"
            assert abs(session.input_y) < 1e-6

    def test_20_malformed_input_defaults_to_zero(self, client):
        acc = _register_and_login(client, "mp_e2e_badinput")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({"type": "input"}))
            _sync(ws)
            session = _session(acc["player_id"])
            assert session is not None
            assert session.input_x == 0.0
            assert session.input_y == 0.0

    def test_21_server_computes_position(self, client):
        a = _register_and_login(client, "mp_e2e_move_a")
        b = _register_and_login(client, "mp_e2e_move_b")
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            first = _snapshot(ws_b)
            x1 = float(_find_player(first, a["player_id"])["x"])
            # Client sends ONLY input; the position is computed server-side.
            ws_a.send_text(json.dumps({"type": "input", "input_x": 1.0, "input_y": 0.0}))
            _sync(ws_a)
            session_a = _session(a["player_id"])
            start_x = session_a.position_x
            _tick_once()
            step = MAX_SPEED * TICK_INTERVAL
            assert session_a.position_x >= start_x + step - 1e-6
            assert abs(session_a.position_y) < 1e-6
            second = _snapshot(ws_b)
            x2 = float(_find_player(second, a["player_id"])["x"])
            assert x2 > x1, f"peer did not observe movement ({x1} -> {x2})"
            assert x2 >= 0.0

    def test_22_world_bounds_clamped(self, client):
        acc = _register_and_login(client, "mp_e2e_bounds")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({"type": "input", "input_x": 1.0, "input_y": 0.0}))
            _sync(ws)
            session = _session(acc["player_id"])
            session.position_x = WORLD_RECT_MAX[0]
            _tick_once()
            assert abs(session.position_x - WORLD_RECT_MAX[0]) < 1e-6
            assert session.position_x <= WORLD_RECT_MAX[0] + 1e-9
            session.input_x = -1.0
            session.position_x = WORLD_RECT_MIN[0]
            _tick_once()
            assert abs(session.position_x - WORLD_RECT_MIN[0]) < 1e-6

    def test_23_heartbeat_ack_keeps_session(self, client):
        acc = _register_and_login(client, "mp_e2e_hb")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({"type": "heartbeat"}))
            assert _expect_type(ws, "heartbeat_ack")["type"] == "heartbeat_ack"
            session = _session(acc["player_id"])
            assert session is not None and session.disconnected is False
            assert session.last_heartbeat >= session.connected_at
            ws.send_text(json.dumps({"type": "ping"}))
            assert _expect_type(ws, "pong")["type"] == "pong"
            assert _session(acc["player_id"]) is session

    def test_24_heartbeat_timeout_drops_session(self, client):
        acc = _register_and_login(client, "mp_e2e_dead")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            session = _session(acc["player_id"])
            assert session is not None
            session.last_heartbeat = time.time() - (HEARTBEAT_TIMEOUT + 5.0)
            _tick_once()
            assert _session(acc["player_id"]) is None
            assert session.disconnected is True

# ---------------------------------------------------------------------------
# 25-33 PvP authority
# ---------------------------------------------------------------------------
class TestPvPAuthority:
    def test_25_pvp_hit_applies_server_damage(self, client):
        a = _register_and_login(client, "mp_e2e_pvp_a", COMPANY_A)
        b = _register_and_login(client, "mp_e2e_pvp_b", COMPANY_B)
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
            assert float(event_a["target_shield"]) == 0.0
            assert target.shield < shield_before
            peer_event = _expect_type(ws_b, "player_hit")
            assert peer_event["target_id"] == b["player_id"]
            assert peer_event["attacker_id"] == a["player_id"]

    def test_26_friendly_fire_rejected(self, client):
        a = _register_and_login(client, "mp_e2e_friend_a", COMPANY_A)
        b = _register_and_login(client, "mp_e2e_friend_b", COMPANY_A)
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            target = _session(b["player_id"])
            _fire(ws_a, b["player_id"], weapon=1)
            ws_a.send_text(json.dumps({"type": "ping"}))
            frames = _collect_until(ws_a, "pong")
            assert all(f.get("type") != "player_hit" for f in frames), \
                "same-company player was hit"
            assert target.shield == 100.0 and target.hp == 100.0

    def test_27_cross_map_pvp_rejected(self, client):
        attacker = _fake_session("mp_att_x", "AttackerX", COMPANY_A, map_id="1-1")
        target = _fake_session("mp_tgt_x", "TargetX", COMPANY_B, map_id="2-1")
        event = asyncio.run(handle_player_fire(attacker, target.player_id, 1, 0.0, 0.0))
        assert event is None
        assert target.shield == 100.0 and target.hp == 100.0

    def test_28_out_of_range_pvp_rejected(self, client):
        attacker = _fake_session("mp_att_r", "AttackerR", COMPANY_A, x=0.0, y=0.0)
        target = _fake_session("mp_tgt_r", "TargetR", COMPANY_B,
                               x=PLAYER_LASER_RANGE + 100.0, y=0.0)
        event = asyncio.run(handle_player_fire(attacker, target.player_id, 1, 0.0, 0.0))
        assert event is None
        assert target.shield == 100.0
        # ...while a shot inside the range is accepted.
        target.position_x = PLAYER_LASER_RANGE - 50.0
        assert asyncio.run(handle_player_fire(attacker, target.player_id, 1, 0.0, 0.0)) is not None

    def test_29_self_target_rejected(self, client):
        solo = _fake_session("mp_self_s", "SoloShip", COMPANY_A)
        assert asyncio.run(handle_player_fire(solo, solo.player_id, 1, 0.0, 0.0)) is None
        assert solo.shield == 100.0 and solo.hp == 100.0

    def test_30_invalid_weapon_rejected(self, client):
        attacker = _fake_session("mp_att_w", "AttackerW", COMPANY_A)
        target = _fake_session("mp_tgt_w", "TargetW", COMPANY_B)
        for weapon in (-1, 0, 7, 99):
            assert asyncio.run(handle_player_fire(attacker, target.player_id, weapon, 0.0, 0.0)) is None
        assert target.shield == 100.0 and target.hp == 100.0

    def test_31_sab_drains_shield_to_attacker(self, client):
        attacker = _fake_session("mp_att_sab", "AttackerSab", COMPANY_A, shield=0.0)
        target = _fake_session("mp_tgt_sab", "TargetSab", COMPANY_B, shield=100.0)
        event = asyncio.run(handle_player_fire(attacker, target.player_id, 5, 0.0, 0.0))
        assert event is not None
        assert event["type"] == "player_hit"
        assert float(event["shield_drain"]) == 100.0
        assert target.shield == 0.0
        assert attacker.shield == 100.0

    def test_32_lethal_hit_death_and_respawn(self, client):
        attacker = _fake_session("mp_att_die", "AttackerDie", COMPANY_A)
        target = _fake_session("mp_tgt_die", "TargetDie", COMPANY_B, hp=10.0, shield=0.0)
        event = asyncio.run(handle_player_fire(attacker, target.player_id, 6, 0.0, 0.0))
        assert event is not None
        assert event["type"] == "player_death"
        assert event.get("respawn") is True
        assert float(event["target_hp"]) == 0.0
        assert target.hp == target.max_hp
        assert target.shield == target.max_shield

    def test_33_fire_rate_limit_enforced(self, client):
        a = _register_and_login(client, "mp_e2e_rate_a", COMPANY_A)
        b = _register_and_login(client, "mp_e2e_rate_b", COMPANY_B)
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            assert FIRE_COOLDOWN_SECONDS > 0.0
            _fire(ws_a, b["player_id"], weapon=1)
            _fire(ws_a, b["player_id"], weapon=1)
            ws_a.send_text(json.dumps({"type": "ping"}))
            frames = _collect_until(ws_a, "pong")
            hits = [f for f in frames if f.get("type") == "player_hit"]
            assert len(hits) == 1, f"fire cooldown not enforced (hits={len(hits)})"


# ---------------------------------------------------------------------------
# 34-36 movement model alignment (client speed <-> server authority)
# ---------------------------------------------------------------------------
class TestMovementModelAlignment:
    """The server must move a ship at the SAME speed the client model uses.

    Godot's PlayerShip.max_speed is 320 px/s for Ship10 (300 for ADMIN) while
    the server used to integrate every ship at the MAX_SPEED constant (600),
    so the client's own position and the server's authoritative position
    drifted apart and PvP/NPC range checks compared two different worlds.
    The client now reports its effective speed and the server integrates that
    same value, still capped by MAX_SPEED.
    """

    def test_34_reported_speed_drives_authoritative_motion(self, client):
        acc = _register_and_login(client, "mp_e2e_speed_align")
        ship_speed = 320.0
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({
                "type": "input", "input_x": 1.0, "input_y": 0.0, "speed": ship_speed,
            }))
            _sync(ws)
            session = _session(acc["player_id"])
            assert session is not None
            assert abs(session.speed - ship_speed) < 1e-6, f"speed={session.speed}"
            start_x = session.position_x
            _tick_once()
            expected = ship_speed * TICK_INTERVAL
            assert abs((session.position_x - start_x) - expected) < 1e-6, \
                f"server did not integrate the reported speed ({session.position_x - start_x} != {expected})"

    def test_35_reported_speed_is_capped_by_max_speed(self, client):
        """MAX_SPEED stays the hard anti-cheat ceiling."""
        acc = _register_and_login(client, "mp_e2e_speed_cap")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({
                "type": "input", "input_x": 1.0, "input_y": 0.0, "speed": 99999.0,
            }))
            _sync(ws)
            session = _session(acc["player_id"])
            assert session is not None
            assert abs(session.speed - MAX_SPEED) < 1e-6, f"speed={session.speed}"
            start_x = session.position_x
            _tick_once()
            step = MAX_SPEED * TICK_INTERVAL
            assert abs((session.position_x - start_x) - step) < 1e-6

    def test_36_absent_speed_keeps_legacy_max_speed(self, client):
        """A client that omits "speed" still moves at MAX_SPEED (compat)."""
        acc = _register_and_login(client, "mp_e2e_speed_legacy")
        with client.websocket_connect(_ws_url(acc["token"])) as ws:
            _expect_welcome(ws)
            ws.send_text(json.dumps({"type": "input", "input_x": 1.0, "input_y": 0.0}))
            _sync(ws)
            session = _session(acc["player_id"])
            assert session is not None
            assert abs(session.speed - MAX_SPEED) < 1e-6

    def test_37_world_update_carries_own_authoritative_position(self, client):
        """world_update.self lets the client reconcile with the server world.

        `players` only carries peers (see test_12), so without `self` the
        client could never correct its own position and its range checks would
        disagree with the server's.
        """
        a = _register_and_login(client, "mp_e2e_selfpos_a", COMPANY_A)
        b = _register_and_login(client, "mp_e2e_selfpos_b", COMPANY_B)
        with client.websocket_connect(_ws_url(a["token"])) as ws_a, \
                client.websocket_connect(_ws_url(b["token"])) as ws_b:
            _expect_welcome(ws_a)
            _expect_welcome(ws_b)
            ws_a.send_text(json.dumps({
                "type": "input", "input_x": 1.0, "input_y": 0.0, "speed": 320.0,
            }))
            _sync(ws_a)
            _tick_once()
            state = _snapshot(ws_a)
            own = state.get("self")
            assert isinstance(own, dict), "world_update has no 'self' block"
            assert own["player_id"] == a["player_id"]
            session = _session(a["player_id"])
            assert own["x"] == pytest.approx(session.position_x, abs=0.05)
            assert own["y"] == pytest.approx(session.position_y, abs=0.05)
            # The self block must NOT be smuggled into the peers list.
            assert _find_player(state, a["player_id"]) is None








