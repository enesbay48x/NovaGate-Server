"""
Phase 1 - server-authoritative event journal + Seyir Defteri.

The logbook used to live only in the client's players.json, so it was lost on a
fresh install, editable client-side, and the server - the only component that
knows what happened - could not write to it.

  J1  register writes the first journal entry
  J2  login writes an entry
  J3  logout writes an entry
  J4  company change writes an entry
  J5  market buy writes an entry
  J6  /journal returns newest-first
  J7  /journal requires auth
  J8  /journal is scoped to the calling player
  J9  /journal filters by event_type
  J10 /journal limit is clamped
  J11 an entry is trimmed to the cap (no unbounded growth)
  J12 /journal/ack marks entries read without deleting them
  J13 details survive a round-trip through the DB
  J14 an unknown event_type falls back to `system` instead of raising
  J15 an oversized details blob is clipped, not rejected
  J16 journal_sync is pushed to a fresh WebSocket connection
  J17 journal_event is pushed live on a real map change
  J18 an NPC kill is journalled and stored
  J19 the journal never leaks another player's rows
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

os.environ["SECRET_KEY"] = "phase1-journal-secret-key-0123456789abcdef"
os.environ["DB_PATH"] = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "test_novagate_p1_journal.db"
)
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

import journal  # noqa: E402
from main import app, init_db, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402
import websocket_server as ws  # noqa: E402
from websocket_server import PlayerSession  # noqa: E402

DB_PATH_TEST = os.environ["DB_PATH"]
PASSWORD = "TestPass123!"


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _reset_db():
    main_module.DB_PATH = DB_PATH_TEST
    ws.manager.configure(ws.manager.secret_key, DB_PATH_TEST)
    if os.path.exists(DB_PATH_TEST):
        try:
            os.remove(DB_PATH_TEST)
        except OSError:
            pass


def _uname(prefix="p1j"):
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


def _journal_rows(player_id: str) -> list:
    async def read():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            cur = await db.execute(
                "SELECT event_type, severity, message, details "
                "FROM event_journal WHERE player_id = ? ORDER BY id",
                (player_id,),
            )
            return await cur.fetchall()
    return _run(read())

# ---------------------------------------------------------------------------
# J1-J5  the server writes the events
# ---------------------------------------------------------------------------
def test_register_writes_first_entry(_app):
    username, reg = _register(_app)
    rows = _journal_rows(reg["player_id"])
    assert len(rows) == 1, rows
    assert rows[0][0] == journal.EVENT_REGISTER
    details = json.loads(rows[0][3])
    assert details["username"] == username
    assert details["starter_reward"]["btc"] == 10000


def test_login_writes_an_entry(_app):
    username, reg = _register(_app)
    assert len(_journal_rows(reg["player_id"])) == 1
    _login(_app, username)
    types = [r[0] for r in _journal_rows(reg["player_id"])]
    assert journal.EVENT_LOGIN in types, types


def test_logout_writes_an_entry(_app):
    username, reg = _register(_app)
    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    resp = _app.post("/auth/logout", headers=headers)
    assert resp.status_code == 200, resp.text
    types = [r[0] for r in _journal_rows(reg["player_id"])]
    assert journal.EVENT_LOGOUT in types, types


def test_company_change_writes_an_entry(_app):
    username, reg = _register(_app)
    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    resp = _app.put("/account/company", headers=headers,
                    json={"company": "EIC"})
    assert resp.status_code == 200, resp.text
    rows = _journal_rows(reg["player_id"])
    change = [r for r in rows if r[0] == journal.EVENT_COMPANY_CHANGE]
    assert len(change) == 1, rows
    details = json.loads(change[0][3])
    assert details["to"] == "EIC"
    assert details["from"] == ""


def test_market_buy_writes_an_entry(_app):
    from main import grant_currency

    username, reg = _register(_app)
    body = _login(_app, username)
    token = body["access_token"]
    _run(grant_currency(reg["player_id"], plt=50000, reason="test_topup"))

    resp = _app.post("/market/buy",
                     headers={"Authorization": f"Bearer {token}"},
                     json={"item_id": "ammo_sab_1000", "currency": "PLT"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["success"] is True

    rows = _journal_rows(reg["player_id"])
    buys = [r for r in rows if r[0] == journal.EVENT_MARKET_BUY]
    assert len(buys) == 1, rows
    details = json.loads(buys[0][3])
    assert details["item_id"] == "ammo_sab_1000"
    assert details["currency"] == "PLT"


# ---------------------------------------------------------------------------
# J6-J10  /journal endpoint
# ---------------------------------------------------------------------------
def test_journal_returns_newest_first(_app):
    username, reg = _register(_app)
    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    resp = _app.get("/journal", headers=headers)
    assert resp.status_code == 200, resp.text
    events = resp.json()["events"]
    assert len(events) >= 2, events
    stamps = [e["timestamp"] for e in events]
    assert stamps == sorted(stamps, reverse=True), stamps


def test_journal_requires_auth(_app):
    assert _app.get("/journal").status_code == 401


def test_journal_is_scoped_to_the_calling_player(_app):
    user_a, reg_a = _register(_app)
    body_a = _login(_app, user_a)
    _app.put("/account/company",
             headers={"Authorization": f"Bearer {body_a['access_token']}"},
             json={"company": "MMO"})

    user_b, reg_b = _register(_app)
    body_b = _login(_app, user_b)

    resp = _app.get("/journal",
                    headers={"Authorization": f"Bearer {body_b['access_token']}"})
    assert resp.status_code == 200
    # B never changed company, so B must not see A's entry.
    types = {e["event_type"] for e in resp.json()["events"]}
    assert journal.EVENT_COMPANY_CHANGE not in types, types

    # A does see it.
    resp_a = _app.get("/journal",
                      headers={"Authorization": f"Bearer {body_a['access_token']}"})
    types_a = {e["event_type"] for e in resp_a.json()["events"]}
    assert journal.EVENT_COMPANY_CHANGE in types_a, types_a


def test_journal_filters_by_event_type(_app):
    username, reg = _register(_app)
    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    resp = _app.get("/journal", headers=headers,
                    params={"event_type": journal.EVENT_LOGIN})
    assert resp.status_code == 200
    events = resp.json()["events"]
    assert events, "expected at least one login event"
    for e in events:
        assert e["event_type"] == journal.EVENT_LOGIN


def test_journal_ignores_an_unknown_event_type_filter(_app):
    username, _ = _register(_app)
    body = _login(_app, username)
    resp = _app.get("/journal",
                    headers={"Authorization": f"Bearer {body['access_token']}"},
                    params={"event_type": "not_a_real_type"})
    assert resp.status_code == 200
    # Falls back to the unfiltered list rather than erroring.
    assert resp.json()["events"]


def test_journal_limit_is_clamped(_app):
    username, _ = _register(_app)
    body = _login(_app, username)
    resp = _app.get("/journal",
                    headers={"Authorization": f"Bearer {body['access_token']}"},
                    params={"limit": 999999})
    assert resp.status_code == 200
    data = resp.json()
    assert data["limit"] == journal.DEFAULT_JOURNAL_LIMIT
    assert len(data["events"]) <= journal.DEFAULT_JOURNAL_LIMIT

# ---------------------------------------------------------------------------
# J11-J15  module-level behaviour
# ---------------------------------------------------------------------------
def test_entries_are_trimmed_to_the_cap():
    """A chatty player must not grow the table without bound."""
    async def scenario():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            pid = "trim_player"
            await db.execute("DELETE FROM event_journal WHERE player_id = ?",
                             (pid,))
            for i in range(12):
                await journal.record_event(
                    db, pid, journal.EVENT_SYSTEM, f"entry {i}", limit=5
                )
            return await journal.count_events(db, pid)

    assert _run(scenario()) == 5


def test_ack_marks_read_without_deleting(_app):
    username, _ = _register(_app)
    body = _login(_app, username)
    headers = {"Authorization": f"Bearer {body['access_token']}"}

    before = _app.get("/journal", headers=headers).json()
    assert before["events"]
    ids = [e["id"] for e in before["events"]]

    resp = _app.post("/journal/ack", headers=headers, json={"ids": ids[:1]})
    assert resp.status_code == 200, resp.text
    assert resp.json()["ok"] is True

    after = _app.get("/journal", headers=headers).json()
    assert len(after["events"]) == len(before["events"]), "ack must not delete"

    async def read():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            cur = await db.execute(
                "SELECT acknowledged FROM event_journal "
                "WHERE player_id = ? AND id = ?",
                (body["player_id"], ids[0]),
            )
            return await cur.fetchone()

    row = _run(read())
    assert row and int(row[0]) == 1


def test_ack_all_is_accepted(_app):
    username, _ = _register(_app)
    body = _login(_app, username)
    resp = _app.post("/journal/ack",
                     headers={"Authorization": f"Bearer {body['access_token']}"},
                     json={})
    assert resp.status_code == 200, resp.text
    assert resp.json()["ok"] is True


def test_details_survive_a_db_round_trip():
    async def scenario():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            pid = "details_player"
            await db.execute("DELETE FROM event_journal WHERE player_id = ?",
                             (pid,))
            await journal.record_event(
                db, pid, journal.EVENT_NPC_KILL, "zyron_raider imha edildi",
                journal.SEVERITY_GOOD,
                {"npc_type": "zyron_raider",
                 "reward": {"bitcoin": 824.0, "xp": 412.0, "honor": 2.0}},
            )
            return await journal.list_events(db, pid)

    events = _run(scenario())
    assert len(events) == 1
    ev = events[0]
    assert ev["type"] == "journal_event"
    assert ev["event_type"] == journal.EVENT_NPC_KILL
    assert ev["severity"] == journal.SEVERITY_GOOD
    assert ev["details"]["npc_type"] == "zyron_raider"
    # Floats must survive, not be stringified.
    assert ev["details"]["reward"]["bitcoin"] == 824.0


def test_unknown_event_type_falls_back_to_system():
    ev = journal.make_event("totally_made_up", "hello")
    assert ev["event_type"] == journal.EVENT_SYSTEM
    # An unknown severity falls back to info rather than raising.
    ev2 = journal.make_event(journal.EVENT_REWARD, "x", "loud")
    assert ev2["severity"] == journal.SEVERITY_INFO


def test_oversized_details_are_clipped_not_rejected():
    ev = journal.make_event(
        journal.EVENT_SYSTEM, "big", details={"blob": "x" * 50000}
    )
    # The event is still produced, and `details` stays VALID JSON (a truncated
    # blob would be un-parseable on the way back out).
    assert ev["type"] == "journal_event"
    assert ev["details"].get("truncated") is True
    assert ev["details"]["original_bytes"] > journal.MAX_DETAILS_CHARS
    # The message itself is never lost.
    assert ev["message"] == "big"
    json.dumps(ev["details"])  # must not raise


def test_record_event_requires_a_player_id():
    async def scenario():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            with pytest.raises(ValueError):
                await journal.record_event(db, "", journal.EVENT_SYSTEM, "x")

    _run(scenario())

# ---------------------------------------------------------------------------
# J16-J19  live WebSocket delivery
# ---------------------------------------------------------------------------
def _ws_url(token: str) -> str:
    return f"/ws/game?token={token}"


def _recv(ws) -> dict:
    return json.loads(ws.receive_text())


def _expect(ws, expected: str, limit: int = 80) -> dict:
    for _ in range(limit):
        msg = _recv(ws)
        if msg.get("type") == expected:
            return msg
    raise AssertionError(f"{expected} not received within {limit} frames")


def test_journal_sync_is_pushed_on_connect(_app):
    username, reg = _register(_app, company="EIC")
    body = _login(_app, username)

    with _app.websocket_connect(_ws_url(body["access_token"])) as sock:
        _expect(sock, "welcome")
        sync = _expect(sock, "journal_sync")
        events = sync.get("events", [])
        assert events, "journal_sync arrived with no events"
        # The register + login entries must both be replayed.
        types = {e["event_type"] for e in events}
        assert journal.EVENT_REGISTER in types, types
        assert journal.EVENT_LOGIN in types, types
        # Newest-first, matching /journal.
        stamps = [e["timestamp"] for e in events]
        assert stamps == sorted(stamps, reverse=True), stamps


def _collect_until(ws, expected: str, limit: int = 60) -> list:
    """Read messages up to and including `expected`; return all of them.

    Required when two frames are emitted back-to-back (the journal_event is
    pushed BEFORE map_changed), because `_expect` would silently discard the
    first one.
    """
    seen = []
    for _ in range(limit):
        msg = _recv(ws)
        seen.append(msg)
        if msg.get("type") == expected:
            return seen
    raise AssertionError(f"{expected} not received within {limit} frames")


def test_map_change_pushes_journal_event_live(_app):
    username, reg = _register(_app, company="EIC")
    body = _login(_app, username)

    with _app.websocket_connect(_ws_url(body["access_token"])) as sock:
        _expect(sock, "welcome")
        _expect(sock, "journal_sync")

        sock.send_text(json.dumps({"type": "move", "map_id": "2-1"}))
        frames = _collect_until(sock, "map_changed")

        events = [m for m in frames if m.get("type") == "journal_event"]
        assert events, f"no journal_event among {[m.get('type') for m in frames]}"
        enter = [e for e in events
                 if e.get("event_type") == journal.EVENT_MAP_ENTER]
        assert enter, [e.get("event_type") for e in events]
        assert enter[0]["details"]["map_id"] == "2-1"
        assert enter[0]["message"], "journal_event must carry a message"

    # ...and it is persisted, not just pushed.
    types = [r[0] for r in _journal_rows(reg["player_id"])]
    assert journal.EVENT_MAP_ENTER in types, types


def test_npc_kill_is_journalled(_app, monkeypatch):
    """The kill entry is written only after the payout succeeded."""
    username, reg = _register(_app, company="EIC")
    body = _login(_app, username)

    granted = []

    async def fake_grant(_pid, _reward, _npc_type):
        granted.append(1)
        return True

    monkeypatch.setattr(ws, "_grant_server_currency", fake_grant)

    with _app.websocket_connect(_ws_url(body["access_token"])) as sock:
        _expect(sock, "welcome")
        _expect(sock, "journal_sync")

        # The NPC manager is process-global; start from a known-empty world.
        ws.npc_manager.npcs.clear()
        _run(ws.npc_manager.spawn_map_npcs("1-1"))
        # get_npcs_on_map is synchronous.
        npcs = ws.npc_manager.get_npcs_on_map("1-1")
        assert npcs, "no NPCs spawned on 1-1"
        target = npcs[0]
        target.health = 1.0
        target.shield = 0.0
        target.max_health = 1.0
        target.max_shield = 0.0
        target.position_x = 0.0
        target.position_y = 0.0

        sock.send_text(json.dumps({
            "type": "fire", "weapon": 1, "target_x": 0.0, "target_y": 0.0,
        }))

        # Drain until the journal_event for the kill arrives.
        seen_kill = None
        for _ in range(120):
            msg = _recv(sock)
            if msg.get("type") == "journal_event" and \
                    msg.get("event_type") == journal.EVENT_NPC_KILL:
                seen_kill = msg
                break
        assert seen_kill is not None, "no journal_event for the NPC kill"
        assert seen_kill["details"]["npc_type"] == target.npc_type
        assert len(granted) == 1, "payout must happen exactly once"

    types = [r[0] for r in _journal_rows(reg["player_id"])]
    assert journal.EVENT_NPC_KILL in types, types


def test_failed_payout_does_not_journal_the_kill(_app, monkeypatch):
    """A kill that was not paid for must not appear in the Seyir Defteri."""
    username, reg = _register(_app, company="EIC")
    body = _login(_app, username)

    async def fake_grant(_pid, _reward, _npc_type):
        return False

    monkeypatch.setattr(ws, "_grant_server_currency", fake_grant)

    # The NPC manager is process-global, so start from a known-empty world.
    ws.npc_manager.npcs.clear()
    _run(ws.npc_manager.spawn_map_npcs("1-1"))
    npcs = ws.npc_manager.get_npcs_on_map("1-1")
    assert npcs
    target = npcs[0]
    target.health = 1.0
    target.shield = 0.0
    target.max_health = 1.0
    target.max_shield = 0.0
    target.position_x = 0.0
    target.position_y = 0.0

    _run(ws.npc_manager.handle_fire(reg["player_id"], (0.0, 0.0), 1, 0.0, 0.0))

    types = [r[0] for r in _journal_rows(reg["player_id"])]
    assert journal.EVENT_NPC_KILL not in types, types
    # The NPC must also still be alive (the kill was rolled back).
    assert target.alive is True, "an unpaid kill must not stay dead"


def test_journal_never_leaks_across_ws_connections(_app):
    user_a, reg_a = _register(_app, company="EIC")
    body_a = _login(_app, user_a)
    user_b, reg_b = _register(_app, company="MMO")
    body_b = _login(_app, user_b)

    with _app.websocket_connect(_ws_url(body_b["access_token"])) as sock_b:
        _expect(sock_b, "welcome")
        sync_b = _expect(sock_b, "journal_sync")
        player_ids = {e.get("player_id") for e in sync_b["events"]}
        # Events carry no foreign player data; the connection itself scopes it.
        assert reg_a["player_id"] not in player_ids

    with _app.websocket_connect(_ws_url(body_a["access_token"])) as sock_a:
        _expect(sock_a, "welcome")
        sync_a = _expect(sock_a, "journal_sync")
        assert len(sync_a["events"]) <= len(sync_b["events"])



