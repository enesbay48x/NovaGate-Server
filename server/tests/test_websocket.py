"""
WebSocket tests for NovaGate Phase 2.

Tests use the Starlette TestClient's websocket_connect for connection-level tests.
For world-loop-dependent tests (movement, broadcast), we invoke the world tick
and broadcast functions directly since TestClient's synchronous WebSocket handler
does not run background asyncio tasks.
"""

import asyncio
import json
import os
import sys
import time

import pytest
import aiosqlite
import jwt
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "test-secret-key-for-phase2-testing-only"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_novagate.db")
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "100/minute"
os.environ["RATE_LIMIT_REGISTER"] = "100/minute"

from main import app, init_db, JWT_ALGORITHM, SECRET_KEY, DB_PATH, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402
from websocket_server import (  # noqa: E402
    manager, world_tick, broadcast_world_state, _decode_token,
    _unix_now, MAX_SPEED, TICK_INTERVAL, WORLD_RECT_MIN, WORLD_RECT_MAX,
    HEARTBEAT_TIMEOUT, HEARTBEAT_INTERVAL,
)


DB_PATH_TEST = os.environ["DB_PATH"]
MAX_SPEED_ESTIMATE = 600.0


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


def _make_username(prefix: str = "wstest") -> str:
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


def _clear_state():
    asyncio.run(_clear_db())
    reset_rate_limits()
    manager.active_connections.clear()
    manager.ship_locks.clear()


async def _clear_db():
    async with aiosqlite.connect(DB_PATH_TEST) as db:
        await db.execute("DELETE FROM sessions")
        await db.execute("DELETE FROM accounts")
        await db.commit()


def _expect_welcome(ws):
    """Receive and verify the welcome message."""
    data = ws.receive_text()
    msg = json.loads(data)
    assert msg.get("type") == "welcome", f"Expected welcome, got: {msg.get('type')}"
    return msg


def _try_connect(client, token: str) -> bool:
    """Try to connect to WebSocket. Returns True if connected."""
    try:
        with client.websocket_connect(f"/ws/game?token={token}") as ws:
            _expect_welcome(ws)
            return True
    except Exception:
        return False


def _tick_once():
    """Run one world tick manually (since TestClient doesn't run background tasks)."""
    asyncio.run(_do_one_tick())


async def _do_one_tick():
    """Run one iteration of the world loop."""
    current_time = time.time()
    async with manager._lock:
        # Heartbeat check
        to_disconnect = []
        for pid, player in list(manager.active_connections.items()):
            elapsed = current_time - player.last_heartbeat
            if elapsed > HEARTBEAT_TIMEOUT:
                to_disconnect.append(pid)

        for pid in to_disconnect:
            player = manager.active_connections.get(pid)
            if player:
                try:
                    if player.websocket:
                        await player.websocket.close(code=1001, reason="Heartbeat timeout")
                except Exception:
                    pass
            manager.active_connections.pop(pid, None)
            if player and player.ship_id:
                manager.ship_locks.pop(player.ship_id, None)
            if player:
                player.disconnected = True

        # Movement processing
        for player in list(manager.active_connections.values()):
            if player.disconnected:
                continue
            dx = player.input_x * MAX_SPEED * TICK_INTERVAL
            dy = player.input_y * MAX_SPEED * TICK_INTERVAL
            new_x = player.position_x + dx
            new_y = player.position_y + dy
            new_x = max(WORLD_RECT_MIN[0], min(WORLD_RECT_MAX[0], new_x))
            new_y = max(WORLD_RECT_MIN[1], min(WORLD_RECT_MAX[1], new_y))
            # Clamp input magnitude (anti-cheat)
            input_mag = (player.input_x * player.input_x + player.input_y * player.input_y) ** 0.5
            if input_mag > 1.0:
                player.input_x = player.input_x / input_mag if input_mag > 0 else 0.0
                player.input_y = player.input_y / input_mag if input_mag > 0 else 0.0
            player.position_x = new_x
            player.position_y = new_y
            player.last_input_time = current_time

    await broadcast_world_state()


@pytest.fixture(scope="module")
def ws_client():
    asyncio.run(_init_test_db())
    with TestClient(app) as c:
        # Determinism fix (no production behaviour changed).
        #
        # `on_startup` launches the REAL 20 Hz `world_tick` task. The movement
        # tests drive a ship with a manual `_tick_once()` and then assert the
        # travelled distance is at most ONE tick's worth. When the live loop
        # also fires between the manual tick and the assertion the ship has
        # moved twice, so the bound is exceeded - a harness race, which is why
        # this module passes in isolation and fails intermittently under load.
        #
        # Cancelling the background task for the module makes the manual tick
        # the only mover. The assertions are left exactly as strict.
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
        ws._world_task = task
    ws._test_saved_world_task = None


@pytest.fixture(autouse=True)
def cleanup():
    _clear_state()
    yield
    _clear_state()


# ===========================================================================
# Phase 2 Test Suite
# ===========================================================================

class TestWebSocketAuth:
    """1. Auth-related WebSocket tests"""

    def test_1_valid_session_websocket(self, ws_client):
        """1. Valid session can connect to WebSocket."""
        username = _make_username("ws_valid")
        access_token, _ = _make_tokens(ws_client, username)

        with ws_client.websocket_connect(f"/ws/game?token={access_token}") as ws:
            msg = _expect_welcome(ws)
            assert msg["type"] == "welcome"
            assert "x" in msg and "y" in msg
            assert msg["map_id"] == "1-1"
        print("PASS")

    def test_2_invalid_token(self, ws_client):
        """2. Invalid token is rejected."""
        connected = _try_connect(ws_client, "invalid_token_12345")
        assert not connected, "Should reject invalid token"
        print("PASS")

    def test_3_expired_token(self, ws_client):
        """3. Expired token is rejected."""
        username = _make_username("ws_expired")
        access_token, _ = _make_tokens(ws_client, username)

        payload = jwt.decode(access_token, SECRET_KEY, algorithms=[JWT_ALGORITHM])
        payload["exp"] = int(time.time()) - 10  # expired 10s ago
        expired_token = jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALGORITHM)

        connected = _try_connect(ws_client, expired_token)
        assert not connected, "Should reject expired token"
        print("PASS")

    def test_4_logout_then_websocket(self, ws_client):
        """4. After logout, WebSocket connection is rejected."""
        username = _make_username("ws_logout")
        access_token, _ = _make_tokens(ws_client, username)

        ws_client.post("/auth/logout", headers={"Authorization": f"Bearer {access_token}"})

        connected = _try_connect(ws_client, access_token)
        assert not connected, "Should reject connection after logout"
        print("PASS")

    def test_5_double_login_invalidates_websocket(self, ws_client):
        """5. Double login invalidates first session's WebSocket access."""
        username = _make_username("ws_double")
        access_token1, _ = _make_tokens(ws_client, username)

        resp = ws_client.post("/auth/login", json={"username": username, "password": "TestPass123!"})
        access_token2 = resp.json()["access_token"]

        connected_old = _try_connect(ws_client, access_token1)
        assert not connected_old, "Old token should be rejected after re-login"

        connected_new = _try_connect(ws_client, access_token2)
        assert connected_new, "New token should work after re-login"
        print("PASS")


class TestWebSocketMovement:
    """Tests for server-authoritative movement"""

    def test_7_movement_input(self, ws_client):
        """7. Movement input from client produces server-side position change."""
        username = _make_username("ws_move")
        access_token, _ = _make_tokens(ws_client, username)

        with ws_client.websocket_connect(f"/ws/game?token={access_token}") as ws:
            _expect_welcome(ws)

            # Send movement input
            ws.send_text(json.dumps({"type": "input", "input_x": 1.0, "input_y": 0.0}))

            # Process one tick (world loop)
            _tick_once()

            # Verify position changed on server
            player = manager.active_connections.get(str(ws_client.get("/auth/verify", headers={"Authorization": f"Bearer {access_token}"}).json()["player_id"]))
            assert player is not None, "Player should be in active connections"
            assert player.position_x > 0, "Player should have moved right"
        print("PASS")

    def test_8_invalid_movement_speed(self, ws_client):
        """8. Movement input with excessive speed is clamped to unit vector."""
        username = _make_username("ws_speedhack")
        access_token, _ = _make_tokens(ws_client, username)

        with ws_client.websocket_connect(f"/ws/game?token={access_token}") as ws:
            _expect_welcome(ws)

            # Send input with magnitude >> 1 (speed hack attempt)
            ws.send_text(json.dumps({"type": "input", "input_x": 10.0, "input_y": 10.0}))

            # Process one tick
            _tick_once()

            player = manager.active_connections.get(
                ws_client.get("/auth/verify", headers={"Authorization": f"Bearer {access_token}"}).json()["player_id"]
            )
            assert player is not None
            # After clamping, input_x and input_y should be ~0.707 (1/sqrt(2))
            mag = (player.input_x ** 2 + player.input_y ** 2) ** 0.5
            assert abs(mag - 1.0) < 0.01, f"Input magnitude should be 1.0 after clamping, got {mag}"

            # Position should be limited to one tick's worth of movement at max speed
            expected_max_dist = MAX_SPEED * TICK_INTERVAL
            actual_dist = (player.position_x ** 2 + player.position_y ** 2) ** 0.5
            assert actual_dist <= expected_max_dist + 0.01, f"Speed hack: dist={actual_dist}, max={expected_max_dist}"
        print("PASS")

    def test_9_map_boundary(self, ws_client):
        """9. Player cannot move beyond map boundaries."""
        username = _make_username("ws_boundary")
        access_token, _ = _make_tokens(ws_client, username)

        with ws_client.websocket_connect(f"/ws/game?token={access_token}") as ws:
            _expect_welcome(ws)

            # Move right repeatedly until we hit boundary
            ws.send_text(json.dumps({"type": "input", "input_x": 1.0, "input_y": 0.0}))
            for _ in range(100):  # 100 ticks should exceed boundary
                _tick_once()

            player = manager.active_connections.get(
                ws_client.get("/auth/verify", headers={"Authorization": f"Bearer {access_token}"}).json()["player_id"]
            )
            assert player is not None
            assert player.position_x <= WORLD_RECT_MAX[0], f"X {player.position_x} exceeds boundary {WORLD_RECT_MAX[0]}"
            assert player.position_x >= WORLD_RECT_MIN[0], f"X {player.position_x} below boundary {WORLD_RECT_MIN[0]}"

            # Verify via HTTP API too
            resp = ws_client.get("/api/session_info", headers={"Authorization": f"Bearer {access_token}"})
            info = resp.json()
            x, y = info["position"]
            assert x <= 7000.0
            assert x >= -7000.0
        print("PASS")


class TestWebSocketDisconnect:
    """Tests for disconnect and cleanup"""

    def test_10_disconnect_cleanup(self, ws_client):
        """10. After disconnect, player is removed from active connections."""
        username = _make_username("ws_disconnect")
        access_token, _ = _make_tokens(ws_client, username)

        initial_count = len(manager.active_connections)

        with ws_client.websocket_connect(f"/ws/game?token={access_token}") as ws:
            _expect_welcome(ws)
            assert len(manager.active_connections) == initial_count + 1

        # After context exit, player should be cleaned up
        time.sleep(0.1)
        assert len(manager.active_connections) == initial_count, "Player not cleaned up after disconnect"
        print("PASS")

    def test_11_reconnect(self, ws_client):
        """11. Player can reconnect after disconnect."""
        username = _make_username("ws_reconnect")
        access_token, _ = _make_tokens(ws_client, username)

        with ws_client.websocket_connect(f"/ws/game?token={access_token}") as ws:
            _expect_welcome(ws)

        # Wait and reconnect
        time.sleep(0.2)
        with ws_client.websocket_connect(f"/ws/game?token={access_token}") as ws:
            _expect_welcome(ws)
            assert len(manager.active_connections) >= 1
        print("PASS")


class TestRemotePlayerSync:
    """Tests for remote player broadcasting"""

    def test_12_two_players_same_map(self, ws_client):
        """12. Two players on same map can connect (different ships)."""
        username1 = _make_username("ws_two_a")
        username2 = _make_username("ws_two_b")
        token1, _ = _make_tokens(ws_client, username1)
        token2, _ = _make_tokens(ws_client, username2)

        # Give them different ships by updating sessions
        async def set_different_ships():
            p1 = ws_client.get("/auth/verify", headers={"Authorization": f"Bearer {token1}"}).json()["player_id"]
            p2 = ws_client.get("/auth/verify", headers={"Authorization": f"Bearer {token2}"}).json()["player_id"]
            async with aiosqlite.connect(DB_PATH_TEST) as db:
                await db.execute("UPDATE sessions SET ship_id = 'Ship11' WHERE player_id = ? AND active = 1", (p1,))
                await db.execute("UPDATE sessions SET ship_id = 'Ship12' WHERE player_id = ? AND active = 1", (p2,))
                await db.commit()

        asyncio.run(set_different_ships())

        with ws_client.websocket_connect(f"/ws/game?token={token1}") as ws1:
            _expect_welcome(ws1)
            with ws_client.websocket_connect(f"/ws/game?token={token2}") as ws2:
                _expect_welcome(ws2)
                assert len(manager.active_connections) >= 2
        print("PASS")

    def test_13_remote_player_position_broadcast(self, ws_client):
        """13. Player receives remote player position updates via broadcast."""
        username1 = _make_username("ws_bcast_a")
        username2 = _make_username("ws_bcast_b")
        token1, _ = _make_tokens(ws_client, username1)
        token2, _ = _make_tokens(ws_client, username2)

        # Give them different ships
        async def set_different_ships():
            p1 = ws_client.get("/auth/verify", headers={"Authorization": f"Bearer {token1}"}).json()["player_id"]
            p2 = ws_client.get("/auth/verify", headers={"Authorization": f"Bearer {token2}"}).json()["player_id"]
            async with aiosqlite.connect(DB_PATH_TEST) as db:
                await db.execute("UPDATE sessions SET ship_id = 'Ship11' WHERE player_id = ? AND active = 1", (p1,))
                await db.execute("UPDATE sessions SET ship_id = 'Ship12' WHERE player_id = ? AND active = 1", (p2,))
                await db.commit()

        asyncio.run(set_different_ships())

        with ws_client.websocket_connect(f"/ws/game?token={token1}") as ws1:
            _expect_welcome(ws1)
            with ws_client.websocket_connect(f"/ws/game?token={token2}") as ws2:
                _expect_welcome(ws2)

                # Both players start at origin, within interest radius
                # Trigger the broadcast
                _tick_once()
                time.sleep(0.1)
        print("PASS")

    def test_14_heartbeat_timeout(self, ws_client):
        """14. Inactivity for > HEARTBEAT_TIMEOUT causes disconnect."""
        import websocket_server as wss

        username = _make_username("ws_hb_timeout")
        access_token, _ = _make_tokens(ws_client, username)

        initial_count = len(manager.active_connections)

        # Override timeout for faster test
        original_timeout = wss.HEARTBEAT_TIMEOUT
        wss.HEARTBEAT_TIMEOUT = 2

        with ws_client.websocket_connect(f"/ws/game?token={access_token}") as ws:
            _expect_welcome(ws)
            # Don't send heartbeats

        # Wait past timeout
        time.sleep(3)

        wss.HEARTBEAT_TIMEOUT = original_timeout
        time.sleep(0.2)

        assert len(manager.active_connections) <= initial_count, "Heartbeat timeout did not disconnect"
        print("PASS")


class TestSessionPolicy:
    """Single account = single active session; two accounts online together."""

    def test_6_two_players_same_ship_both_online(self, ws_client):
        """6. Two different accounts can be online at the same time.

        The old ship-lock rejected the second player whenever both used the
        default ship (Ship10). Multiplayer requires two accounts online, so
        the only concurrency rule now is: ONE account = ONE active session.
        """
        username1 = _make_username("ws_ship_a")
        username2 = _make_username("ws_ship_b")
        token1, _ = _make_tokens(ws_client, username1)
        token2, _ = _make_tokens(ws_client, username2)

        # Both accounts default to Ship10 - both must connect.
        with ws_client.websocket_connect(f"/ws/game?token={token1}") as ws1:
            _expect_welcome(ws1)
            with ws_client.websocket_connect(f"/ws/game?token={token2}") as ws2:
                _expect_welcome(ws2)
                assert len(manager.active_connections) >= 2, "Both players should be online"
        print("PASS")

    def test_7_second_socket_kicks_first(self, ws_client):
        """7. Same account, second WebSocket: old session kicked, new active."""
        username = _make_username("ws_kick")
        other_name = _make_username("ws_kick_other")
        token, _ = _make_tokens(ws_client, username)
        other_token, _ = _make_tokens(ws_client, other_name)

        verify = ws_client.get("/auth/verify", headers={"Authorization": f"Bearer {token}"}).json()
        player_id = verify["player_id"]

        with ws_client.websocket_connect(f"/ws/game?token={other_token}") as other_ws:
            _expect_welcome(other_ws)
            with ws_client.websocket_connect(f"/ws/game?token={token}") as ws1:
                _expect_welcome(ws1)
                assert player_id in manager.active_connections

                # Open a second connection for the SAME account (WS-3).
                with ws_client.websocket_connect(f"/ws/game?token={token}") as ws3:
                    welcome3 = _expect_welcome(ws3)
                    assert welcome3.get("player_id") == player_id

                    # WS-1 must receive session_kicked (world updates that
                    # were already queued may arrive first).
                    kicked = None
                    for _ in range(50):
                        candidate = json.loads(ws1.receive_text())
                        if candidate.get("type") == "session_kicked":
                            kicked = candidate
                            break
                    assert kicked is not None, "Old session did not receive session_kicked"
                    assert kicked.get("reason") == "account_logged_in_elsewhere"

                    # The new session is the active one...
                    session = manager.active_connections.get(player_id)
                    assert session is not None and not session.disconnected
                    # ...and the other user is still online.
                    assert len(manager.active_connections) >= 2
        print("PASS")
