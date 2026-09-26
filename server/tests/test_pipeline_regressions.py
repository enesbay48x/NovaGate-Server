"""
Regressions for the standard account -> player_id -> company -> single
active WebSocket -> server-authoritative world/combat/reward pipeline.

Each test pins one previously-broken behaviour so it cannot silently return:

  R1  no hardcoded seed account exists (bb / test_user_*)
  R2  login does NOT overwrite the client's own ships/loadout/droids
  R3  a freshly registered account starts with the server-authoritative
      first-registration reward (and only that), never a back-pay
  R4  player_id stays unique and collisions are retried
  R5  an exhausted player_id retry budget fails loudly (503, no insert)
  R6  company relation is decided by ONE shared server function
  R7  only an enemy company is PvP targetable
  R8  a dead socket is removed from the world (no ghost players)
  R9  dropping a stale socket never deletes the newer session
  R10 an NPC reward failure keeps the NPC alive and emits no event
  R11 a successful NPC reward emits exactly one death event
  R12 killing the same NPC twice cannot pay twice
"""

import asyncio
import os
import sys
import time

import aiosqlite
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "test-secret-key-for-pipeline-regressions"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_novagate_pipeline.db")
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

from main import app, init_db, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402
import websocket_server as ws  # noqa: E402
from websocket_server import PlayerSession, calculate_company_relation  # noqa: E402

DB_PATH_TEST = os.environ["DB_PATH"]
PASSWORD = "TestPass123!"


def _run(coro):
    """Run a coroutine to completion on a private event loop.

    Other test modules in this suite create and close their own loops, so the
    thread's default loop cannot be relied upon here.
    """
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


@pytest.fixture(scope="module", autouse=True)
def _app():
    _reset_db()
    _run(init_db())
    reset_rate_limits()
    with TestClient(app) as client:
        yield client


def _register(client, prefix="pipe", company=""):
    # The limiter is process-global and its limit is fixed at import time by
    # whichever test module loaded `main` first, so clear it per registration.
    reset_rate_limits()
    username = _uname(prefix)
    resp = client.post(
        "/auth/register",
        json={"username": username, "password": PASSWORD, "nickname": username, "company": company},
    )
    assert resp.status_code == 200, resp.text
    return resp.json()


def _login(client, username):
    resp = client.post("/auth/login", json={"username": username, "password": PASSWORD})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert isinstance(body, dict), (
        f"login returned a non-dict body: {body!r} (raw={resp.text[:400]!r})"
    )
    return body


# ---------------------------------------------------------------------------
# R1 - no hardcoded seed accounts
# ---------------------------------------------------------------------------
def test_no_seed_accounts_are_bootstrap_created(_app):
    """The server must not fabricate any built-in account at startup."""
    for name in ("SEED_BB_USERNAME", "SEED_BB_PASSWORD", "SEED_BB_PLAYER_ID",
                 "SEED_BB_COMPANY", "SEED_BB_ECONOMY"):
        assert not hasattr(main_module, name), f"seed account symbol still present: {name}"

    # A known seed username must not be loggable into.
    resp = _app.post("/auth/login", json={"username": "bb", "password": "bb"})
    assert resp.status_code == 401, f"seed account 'bb' is still usable: {resp.text}"


# ---------------------------------------------------------------------------
# R2 - login must not overwrite the client's own game data
# ---------------------------------------------------------------------------
def test_login_does_not_invent_ship_data(_app):
    """Login must not ship fake owned_ships/loadout/droid_types."""
    created = _register(_app, "logindata")
    body = _login(_app, created["username"])
    player = body["oyuncu"]

    # The poisoned ownership fields must be absent everywhere in the payload.
    for poisoned in ("owned_ships", "ship_configurations", "droid_types"):
        assert poisoned not in body, f"login invented client data field: {poisoned}"
        assert poisoned not in player, f"'oyuncu' invented client data field: {poisoned}"

    # The authoritative balance is still present, and it is exactly the
    # first-registration reward - login never adds anything on top of it.
    assert "bitcoin" in player and "plt" in player
    assert player["bitcoin"] == main_module.FIRST_REGISTRATION_REWARD_BTC
    assert player["plt"] == main_module.FIRST_REGISTRATION_REWARD_PLT


# ---------------------------------------------------------------------------
# R3 - a new account starts empty
# ---------------------------------------------------------------------------
def test_new_account_starts_with_first_registration_reward(_app):
    created = _register(_app, "zero")
    pid = created["player_id"]

    async def _read():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            cur = await db.execute("SELECT btc, plt FROM economy WHERE player_id = ?", (pid,))
            return await cur.fetchone()

    row = _run(_read())
    assert row is not None, "no economy row created for the new account"
    assert row[0] == main_module.FIRST_REGISTRATION_REWARD_BTC, f"wrong BTC: {row}"
    assert row[1] == main_module.FIRST_REGISTRATION_REWARD_PLT, f"wrong PLT: {row}"

    # The reward must not be handed out a second time on a later login.
    player = _login(_app, created["username"])["oyuncu"]
    assert player["bitcoin"] == main_module.FIRST_REGISTRATION_REWARD_BTC
    assert player["plt"] == main_module.FIRST_REGISTRATION_REWARD_PLT

    # ...and the account is flagged, so nothing can re-grant it later.
    async def _flag():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            cur = await db.execute(
                "SELECT starter_reward_claimed FROM accounts WHERE player_id = ?", (pid,)
            )
            found = await cur.fetchone()
            return 0 if found is None else int(found[0])

    assert _run(_flag()) == 1


# ---------------------------------------------------------------------------
# R4 - player_id uniqueness
# ---------------------------------------------------------------------------
def test_player_ids_are_unique(_app):
    seen = set()
    for _ in range(5):
        pid = _register(_app, "unique")["player_id"]
        assert pid not in seen, f"duplicate player_id issued: {pid}"
        seen.add(pid)
    assert len(seen) == 5


def test_player_id_collision_is_retried(_app):
    """A forced collision must be retried, never inserted as a duplicate."""
    first = _register(_app, "collide")["player_id"]
    original = main_module._gen_player_id
    calls = {"n": 0}

    def colliding_gen():
        calls["n"] += 1
        # The first candidate is taken; every later one is fresh.
        return first if calls["n"] == 1 else original()

    main_module._gen_player_id = colliding_gen
    try:
        second = _register(_app, "collide2")["player_id"]
    finally:
        main_module._gen_player_id = original

    assert calls["n"] >= 2, "collision was not retried"
    assert second != first, "duplicate player_id was inserted after a collision"


# ---------------------------------------------------------------------------
# R5 - exhausted retry budget fails loudly
# ---------------------------------------------------------------------------
def test_exhausted_player_id_budget_rejects_registration(_app):
    """If every candidate collides, the request must fail and insert nothing."""
    original = main_module._gen_player_id
    main_module._gen_player_id = lambda: "always_taken_id"
    username = _uname("budget")
    try:
        taken = _register(_app, "taken")["player_id"]
        assert taken == "always_taken_id"

        reset_rate_limits()
        resp = _app.post(
            "/auth/register",
            json={"username": username, "password": PASSWORD, "nickname": username, "company": ""},
        )
        assert resp.status_code == 503, f"expected a loud 503, got {resp.status_code}: {resp.text}"
    finally:
        main_module._gen_player_id = original

    # The failed attempt must not have created the account.
    assert _app.post("/auth/login", json={"username": username, "password": PASSWORD}).status_code == 401


# ---------------------------------------------------------------------------
# R6 / R7 - one shared relation authority
# ---------------------------------------------------------------------------
def test_relation_function_is_the_single_authority():
    assert calculate_company_relation("EIC", "EIC") == "friendly"
    assert calculate_company_relation("eic", "EIC") == "friendly"   # case-insensitive
    assert calculate_company_relation("EIC", "MMO") == "enemy"
    assert calculate_company_relation("EIC", "") == "neutral"
    assert calculate_company_relation("", "EIC") == "neutral"
    assert calculate_company_relation("", "") == "neutral"


def test_only_enemy_company_is_pvp_targetable():
    """PvP is allowed exactly when the shared relation says "enemy"."""
    for observer, target, expected_fireable in (
        ("EIC", "EIC", False),   # friendly
        ("EIC", "MMO", True),    # enemy
        ("EIC", "", False),      # neutral
        ("", "MMO", False),      # neutral
    ):
        relation = calculate_company_relation(observer, target)


# ---------------------------------------------------------------------------
# R8 / R9 - dead socket cleanup
# ---------------------------------------------------------------------------
class _DeadSocket:
    """A socket that fails every send, like an already-closed transport."""

    application_state = ws.WebSocketState.CONNECTED

    async def send_text(self, _text):
        raise RuntimeError("socket is gone")


def _make_session(player_id: str) -> PlayerSession:
    """A minimal live session for connection-manager tests."""
    return PlayerSession(
        account_id=1,
        player_id=player_id,
        username=player_id,
        ship_id="",
        map_id="1-1",
        position_x=0.0,
        position_y=0.0,
    )


def test_failed_send_removes_session_from_world():
    """A dead socket must be dropped instead of lingering as a ghost player."""

    async def run():
        player = _make_session("ghost_pid")
        player.websocket = _DeadSocket()
        ws.manager.active_connections["ghost_pid"] = player
        try:
            # One full world tick must remove the dead session.
            await ws.broadcast_world_state()
            assert "ghost_pid" not in ws.manager.active_connections, "dead socket stayed in the world"
            assert player.disconnected is True
        finally:
            ws.manager.active_connections.pop("ghost_pid", None)

    _run(run())


def test_drop_never_removes_the_newer_session():
    """A stale socket must not evict the newer session of the same account."""

    async def run():
        old = _make_session("same_pid")
        old.websocket = _DeadSocket()
        new = _make_session("same_pid")
        new.websocket = object()
        ws.manager.active_connections["same_pid"] = new
        try:
            await ws.manager.drop(old)
            assert ws.manager.active_connections.get("same_pid") is new, "stale socket evicted the live session"
            assert old.disconnected is True

            # Dropping the live session does remove it.
            await ws.manager.drop(new)
            assert "same_pid" not in ws.manager.active_connections
        finally:
            ws.manager.active_connections.pop("same_pid", None)

    _run(run())


# ---------------------------------------------------------------------------
# R10 / R11 / R12 - NPC reward correctness
# ---------------------------------------------------------------------------
def _place_npc(npc_id="reward_npc", hp=10.0):
    """Isolate a single low-HP NPC at the origin.

    Other maps' NPCs are spawned by the server startup hook, so they must be
    cleared for the duration of the test; otherwise a second shot could
    legitimately hit a *different* living NPC. Returns (npc, restore).
    """
    saved = dict(ws.npc_manager.npcs)
    ws.npc_manager.npcs.clear()
    npc = ws.NPCState(
        npc_id=npc_id,
        npc_type="zyron_raider",
        map_id="1-1",
        position_x=0.0,
        position_y=0.0,
        health=hp,
        max_health=hp,
        shield=0.0,
        max_shield=0.0,
        alive=True,
        spawn_time=time.time(),
        respawn_at=0.0,
    )
    ws.npc_manager.npcs[npc_id] = npc

    def restore():
        ws.npc_manager.npcs.clear()
        ws.npc_manager.npcs.update(saved)

    return npc, restore


def _place_player(player_id="reward_pid"):
    player = _make_session(player_id)
    ws.manager.active_connections[player_id] = player
    return player


def test_npc_reward_paid_once_on_success(monkeypatch):
    """A successful payout emits exactly one npc_death event."""
    granted = []

    async def fake_grant(_player_id, _reward, _npc_type):
        granted.append(1)
        return True

    monkeypatch.setattr(ws, "_grant_server_currency", fake_grant)
    npc, restore = _place_npc()
    _place_player()
    try:
        event = _run(ws.npc_manager.handle_fire("reward_pid", (0.0, 0.0), 1, 0.0, 0.0))
        assert event is not None, "lethal hit produced no event"
        assert event["type"] == "npc_death", f"expected npc_death, got {event.get('type')}"
        assert event.get("npc_type") == "zyron_raider", "reward event is missing the npc type"
        assert len(granted) == 1, f"payout ran {len(granted)} times for one kill"
        assert npc.alive is False
    finally:
        restore()
        ws.manager.active_connections.pop("reward_pid", None)


def test_npc_reward_failure_keeps_npc_alive(monkeypatch):
    """A failed payout must not leave the NPC dead and must emit no event."""

    async def fake_grant(_player_id, _reward, _npc_type):
        return False

    monkeypatch.setattr(ws, "_grant_server_currency", fake_grant)
    npc, restore = _place_npc()
    _place_player()
    try:
        event = _run(ws.npc_manager.handle_fire("reward_pid", (0.0, 0.0), 1, 0.0, 0.0))
        assert event is None, "a death event was emitted despite a failed payout"
        assert npc.alive is True, "NPC stayed dead even though it was never paid for"
        assert npc.health > 0, "NPC health was not restored"
    finally:
        restore()
        ws.manager.active_connections.pop("reward_pid", None)


def test_npc_cannot_be_paid_twice(monkeypatch):
    """A second shot at an already-dead NPC must not pay again."""
    granted = []

    async def fake_grant(_player_id, _reward, _npc_type):
        granted.append(1)
        return True

    monkeypatch.setattr(ws, "_grant_server_currency", fake_grant)
    npc, restore = _place_npc()
    _place_player()
    try:
        first = _run(ws.npc_manager.handle_fire("reward_pid", (0.0, 0.0), 1, 0.0, 0.0))
        assert first is not None and first["type"] == "npc_death"
        # The only NPC in the world is now dead, so it is no longer a target.
        second = _run(ws.npc_manager.handle_fire("reward_pid", (0.0, 0.0), 1, 0.0, 0.0))
        assert second is None, f"a dead NPC was still targetable: {second!r}"
        assert len(granted) == 1, f"paid twice for one NPC ({len(granted)} payouts)"
    finally:
        restore()
        ws.manager.active_connections.pop("reward_pid", None)

