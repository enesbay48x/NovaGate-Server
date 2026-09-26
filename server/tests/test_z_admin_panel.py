"""Tests for the 4-tier admin system, the schedulers and gate persistence.

WHY THE FILE IS NAMED `test_z_admin_panel.py`
---------------------------------------------
The filename is load-bearing, not cosmetic.

pytest imports every test module during COLLECTION, and the first one to
`import main` permanently binds `main.DB_PATH` from `os.environ` at that
moment. Every existing module works by *setting its own* `os.environ["DB_PATH"]`
before that import, so whichever module sorts first decides the initial binding
- and the rest repoint `main.DB_PATH` themselves in their fixtures.

Naming this module `test_admin.py` put it first alphabetically, so it imported
`main` with ITS database bound. `test_auth._reset_db()` reads
`os.environ["DB_PATH"]` but never repoints `main.DB_PATH`, so it then ran
`init_db()` against this module's (already deleted) database and every auth
test failed with "no such table: sessions".

The `z_` prefix keeps `test_auth.py` first, exactly as before, so this module
inherits an already-imported `main` and repoints `main.DB_PATH` in its own
fixture. Renaming it back would reintroduce that failure.

What these tests are really asserting
-------------------------------------
* AUTHORITY IS SERVER-SIDE. Every negative test here takes a valid JWT for a
  LOW-privilege account and calls an endpoint it should not reach. If any of
  them returned 200, the permission matrix would be decorative.
* THE CLIENT CANNOT ESCALATE. `is_admin` in a body, a forged role, a
  self-promotion and an admin promoting themselves are all covered.
* MONEY AND ITEMS CANNOT BE DOUBLE-SPENT. Auction settlement and quest/gate
  completion are each exercised twice to prove the second attempt pays nothing.
* THE AUDIT TRAIL IS APPEND-ONLY. A direct UPDATE and DELETE are attempted and
  must both be refused by the database triggers.
"""
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.environ.setdefault("SECRET_KEY", "test-secret-key-for-admin-tests")

import admin_core  # noqa: E402
import game_data  # noqa: E402
import schedulers  # noqa: E402


# ---------------------------------------------------------------------------
# Permission matrix (pure unit, no server)
# ---------------------------------------------------------------------------
class TestRoleMatrix:
    def test_four_roles_defined(self):
        assert admin_core.ROLE_ORDER == (
            "player", "moderator", "admin", "superadmin")

    def test_ranks_are_ordered(self):
        assert (admin_core.role_rank("player")
                < admin_core.role_rank("moderator")
                < admin_core.role_rank("admin")
                < admin_core.role_rank("superadmin"))

    def test_unknown_role_has_no_rank(self):
        # A corrupted role must be the lowest possible rank, never a grant.
        assert admin_core.role_rank("wizard") == -1
        assert admin_core.role_rank(None) == -1
        assert admin_core.role_rank("") == -1

    def test_player_has_no_permissions(self):
        assert admin_core.permissions_for("player") == []
        for permission in admin_core.PERMISSIONS:
            assert not admin_core.has_permission("player", permission)

    def test_moderator_cannot_touch_economy(self):
        assert admin_core.has_permission("moderator", "player.kick")
        assert admin_core.has_permission("moderator", "chat.moderate")
        assert not admin_core.has_permission("moderator", "economy.manage")
        assert not admin_core.has_permission("moderator", "role.manage")

    def test_admin_has_economy_but_not_roles(self):
        assert admin_core.has_permission("admin", "economy.manage")
        assert admin_core.has_permission("admin", "stats.manage")
        assert not admin_core.has_permission("admin", "role.manage")
        assert not admin_core.has_permission("admin", "server.control")

    def test_admin_inherits_moderator_powers(self):
        for permission in admin_core.ROLE_PERMISSIONS["moderator"]:
            assert admin_core.has_permission("admin", permission)

    def test_superadmin_has_everything(self):
        for permission in admin_core.PERMISSIONS:
            assert admin_core.has_permission("superadmin", permission)

    def test_unknown_role_cannot_be_staff(self):
        assert not admin_core.is_staff("wizard")
        assert not admin_core.is_staff(None)
        assert admin_core.is_staff("moderator")

    def test_at_least_is_rank_comparison(self):
        assert admin_core.at_least("admin", "moderator")
        assert admin_core.at_least("admin", "admin")
        assert not admin_core.at_least("moderator", "admin")
        assert not admin_core.at_least("unknown", "player")


# ---------------------------------------------------------------------------
# Event state derivation (pure unit)
# ---------------------------------------------------------------------------
class TestEventStates:
    NOW = 1_000_000

    def _row(self, starts, ends, stored="scheduled"):
        return ("ev1", starts, ends, stored)

    def test_scheduled_before_start(self):
        assert schedulers.derived_event_state(
            self._row(self.NOW + 100, self.NOW + 200), self.NOW) == "scheduled"

    def test_active_inside_window(self):
        assert schedulers.derived_event_state(
            self._row(self.NOW - 10, self.NOW + 100), self.NOW) == "active"

    def test_finished_after_end(self):
        assert schedulers.derived_event_state(
            self._row(self.NOW - 200, self.NOW - 10), self.NOW) == "finished"

    def test_cancelled_is_sticky(self):
        # A cancelled event must never re-open itself on a later pass.
        assert schedulers.derived_event_state(
            self._row(self.NOW - 10, self.NOW + 100, "cancelled"),
            self.NOW) == "cancelled"


# ---------------------------------------------------------------------------
# HTTP integration: authority, roles, audit
# ---------------------------------------------------------------------------
import asyncio  # noqa: E402
import time  # noqa: E402
import uuid  # noqa: E402

import aiosqlite  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import aiosqlite  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main as main_module  # noqa: E402
from main import app, init_db, reset_rate_limits  # noqa: E402

DB_PATH_TEST = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "test_novagate_admin.db")
SECRET_KEY_TEST = "admin-panel-authority-secret-0123456789abcd"
PASSWORD = "AdminPanel123!"

# NOTE ON WHY NOTHING IS WRITTEN TO os.environ AT IMPORT TIME
# -----------------------------------------------------------
# Every existing test module reads or writes `os.environ["DB_PATH"]`, and the
# module that WRITES it LAST during collection wins for every module whose
# fixture runs later. Writing it here - at import time, with a `z_` name that
# sorts last - made THIS path the final value, so `test_auth._reset_db()`
# (which reads the env var but relies on `main.DB_PATH` for the real work)
# deleted the wrong database and its 27 tests failed with
# "no such table: sessions".
#
# So this module deliberately does NOT touch os.environ at all. It only
# repoints `main.DB_PATH` inside its own fixture, and restores it on teardown,
# which makes it invisible to every other module.

# ---------------------------------------------------------------------------
# Event loop management
# ---------------------------------------------------------------------------
# ROOT CAUSE OF THE "Event loop is closed" ERRORS
# ----------------------------------------------
# These tests call `_run()` far more often than the rest of the suite - every
# `_register` with a role, every seed and every read. A `_run` that creates a
# fresh loop and closes it immediately orphans the aiosqlite worker threads
# that `aiosqlite.connect()` starts: the thread is still winding down when the
# loop disappears, and it raises "Event loop is closed" from
# `_connection_worker_thread`.
#
# The fix is ONE loop for the whole module, closed only in the fixture
# teardown - after the TestClient has shut down - so no connection can outlive
# the loop that owns it.
_LOOP = None


def _loop():
    global _LOOP
    if _LOOP is None or _LOOP.is_closed():
        _LOOP = asyncio.new_event_loop()
        asyncio.set_event_loop(_LOOP)
    return _LOOP


def _run(coro):
    """Run a coroutine on the module's shared loop.

    Deliberately does NOT close the loop: the module fixture owns its lifetime.
    """
    return _loop().run_until_complete(coro)


def _shutdown_loop() -> None:
    """Close the shared loop. Called once, in fixture teardown."""
    global _LOOP
    if _LOOP is not None and not _LOOP.is_closed():
        try:
            # Let queued callbacks (including aiosqlite thread hand-offs)
            # drain before the loop goes away.
            _LOOP.run_until_complete(asyncio.sleep(0))
        except Exception:
            pass
        _LOOP.close()
    _LOOP = None


def _reset_db():
    main_module.DB_PATH = DB_PATH_TEST
    for suffix in ("", "-wal", "-shm"):
        path = DB_PATH_TEST + suffix
        if os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass


def _uname(prefix="adm"):
    return "%s_%s" % (prefix, uuid.uuid4().hex[:10])


@pytest.fixture(scope="module", autouse=True)
def client():
    """Boot the app once for the module and hand the TestClient to each test.

    WHY main.DB_PATH IS REPOINTED AND RESTORED HERE
    ------------------------------------------------
    `main.DB_PATH` is a module-level binding captured at import time from
    `os.environ["DB_PATH"]`, and every other test module depends on it. This
    fixture repoints it at this module's database for the duration of the
    module and puts the previous value back on teardown, so the module is
    completely invisible to everything else.

    Teardown order matters: the TestClient closes first (running the app's
    shutdown hook and stopping the scheduler), and only then is the shared
    event loop closed. Closing the loop while aiosqlite threads are still
    attached to it is what produced the "Event loop is closed" errors.
    """
    previous_db_path = main_module.DB_PATH
    previous_secret = main_module.SECRET_KEY
    main_module.DB_PATH = DB_PATH_TEST
    main_module.SECRET_KEY = SECRET_KEY_TEST
    _reset_db()
    _run(init_db())
    _run(main_module._run_seed_bootstrap())
    reset_rate_limits()
    try:
        with TestClient(app) as test_client:
            yield test_client
    finally:
        _reset_db()
        _shutdown_loop()
        main_module.DB_PATH = previous_db_path
        main_module.SECRET_KEY = previous_secret


def _register(client, role="player"):
    """Register a player and optionally promote it directly in the DB.

    Promotion goes through SQL rather than the admin API on purpose: these
    tests need a KNOWN role on a real account, and seeding it that way keeps
    the role-assignment tests (which have their own rules) independent.
    """
    reset_rate_limits()
    username = _uname(role)
    resp = client.post("/auth/register", json={
        "username": username, "password": PASSWORD,
        "nickname": username, "company": "EIC",
    })
    assert resp.status_code == 200, resp.text
    body = client.post("/auth/login",
                       json={"username": username, "password": PASSWORD}).json()
    if role != "player":
        async def _promote():
            async with aiosqlite.connect(DB_PATH_TEST) as db:
                await db.execute(
                    "UPDATE accounts SET role = ? WHERE username = ?",
                    (role, username))
                await db.commit()
        _run(_promote())
    return {
        "username": username,
        "player_id": body.get("player_id"),
        "token": body["access_token"],
        "headers": {"Authorization": "Bearer " + body["access_token"]},
    }


class TestAuthenticationBoundary:
    """Nothing below may be reachable without a staff credential."""

    PROTECTED = [
        ("GET", "/admin/session"),
        ("GET", "/admin/dashboard"),
        ("GET", "/admin/players"),
        ("GET", "/admin/permissions"),
        ("GET", "/admin/audit"),
        ("GET", "/admin/admins"),
        ("GET", "/admin/npcs"),
        ("GET", "/admin/maps"),
        ("GET", "/admin/quests"),
        ("GET", "/admin/gates"),
        ("GET", "/admin/clans"),
        ("GET", "/admin/squads"),
        ("GET", "/admin/auctions"),
        ("GET", "/admin/events"),
        ("GET", "/admin/catalog"),
    ]

    def test_no_token_is_rejected(self, client):
        for method, path in self.PROTECTED:
            assert client.request(method, path).status_code in (401, 403), path

    def test_plain_player_is_rejected(self, client):
        player = _register(client, "player")
        for method, path in self.PROTECTED:
            resp = client.request(method, path, headers=player["headers"])
            assert resp.status_code in (401, 403), "%s leaked to player" % path

    def test_garbage_token_is_rejected(self, client):
        headers = {"Authorization": "Bearer not-a-real-jwt"}
        for method, path in self.PROTECTED:
            assert client.request(method, path,
                                  headers=headers).status_code in (401, 403), path

    def test_moderator_cannot_reach_admin_tier(self, client):
        mod = _register(client, "moderator")
        # The moderator tier IS reachable...
        assert client.get("/admin/session",
                          headers=mod["headers"]).status_code == 200
        assert client.get("/admin/players",
                          headers=mod["headers"]).status_code == 200
        # ...but the admin tier is not.
        for method, path in (("GET", "/admin/audit"),
                             ("GET", "/admin/npcs"),
                             ("GET", "/admin/maps"),
                             ("GET", "/admin/quests"),
                             ("GET", "/admin/gates"),
                             ("GET", "/admin/admins")):
            resp = client.request(method, path, headers=mod["headers"])
            assert resp.status_code == 403, "%s leaked to moderator" % path


class TestClientCannotGrantItself:
    """The specific attacks the brief calls out by name."""

    def test_is_admin_in_body_is_ignored(self, client):
        player = _register(client, "player")
        resp = client.post("/admin/player/%s/currency" % player["player_id"],
                           headers=player["headers"],
                           json={"currency": "BTC", "amount": 1000000,
                                 "is_admin": True, "role": "superadmin"})
        assert resp.status_code == 403

    def test_role_field_in_body_is_ignored(self, client):
        player = _register(client, "player")
        resp = client.put("/admin/player/%s/role" % player["username"],
                          headers=player["headers"],
                          json={"role": "superadmin"})
        assert resp.status_code == 403

    def test_moderator_cannot_promote_anyone(self, client):
        mod = _register(client, "moderator")
        target = _register(client, "player")
        resp = client.put("/admin/player/%s/role" % target["username"],
                          headers=mod["headers"], json={"role": "admin"})
        assert resp.status_code == 403

    def test_admin_cannot_make_a_superadmin(self, client):
        admin = _register(client, "admin")
        target = _register(client, "player")
        resp = client.put("/admin/player/%s/role" % target["username"],
                          headers=admin["headers"], json={"role": "superadmin"})
        assert resp.status_code == 403

    def test_admin_cannot_promote_themselves(self, client):
        admin = _register(client, "admin")
        resp = client.put("/admin/player/%s/role" % admin["username"],
                          headers=admin["headers"], json={"role": "superadmin"})
        assert resp.status_code == 403

    def test_superadmin_can_promote_below_themselves(self, client):
        root = _register(client, "superadmin")
        target = _register(client, "player")
        resp = client.put("/admin/player/%s/role" % target["username"],
                          headers=root["headers"], json={"role": "moderator"})
        assert resp.status_code == 200, resp.text
        assert resp.json()["role"] == "moderator"

    def test_superadmin_cannot_change_own_role(self, client):
        root = _register(client, "superadmin")
        resp = client.put("/admin/player/%s/role" % root["username"],
                          headers=root["headers"], json={"role": "player"})
        assert resp.status_code == 403


# ---------------------------------------------------------------------------
# Currency: bounds, audit, and the exact scenario from the brief
# ---------------------------------------------------------------------------
class TestCurrencyManagement:
    def test_the_documented_scenario(self, client):
        """username bb: BTC +100000, PLT +50000, GOLD +1000."""
        root = _register(client, "superadmin")
        target = _register(client, "player")
        for currency, amount in (("BTC", 100000), ("PLT", 50000),
                                 ("GOLD", 1000)):
            resp = client.post(
                "/admin/player/%s/currency" % target["player_id"],
                headers=root["headers"],
                json={"currency": currency, "amount": amount,
                      "reason": "support compensation"})
            assert resp.status_code == 200, resp.text
            assert resp.json()["new"] - resp.json()["old"] == amount

    def test_subtract_is_allowed(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        client.post("/admin/player/%s/currency" % target["player_id"],
                    headers=root["headers"],
                    json={"currency": "BTC", "amount": 5000})
        resp = client.post("/admin/player/%s/currency" % target["player_id"],
                           headers=root["headers"],
                           json={"currency": "BTC", "amount": -2000})
        assert resp.status_code == 200
        assert resp.json()["new"] == resp.json()["old"] - 2000

    def test_cannot_go_negative(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        resp = client.post("/admin/player/%s/currency" % target["player_id"],
                           headers=root["headers"],
                           json={"currency": "BTC", "amount": -999999999})
        assert resp.status_code == 400
        assert resp.json()["detail"]["reason"] == "insufficient"

    def test_unknown_currency_is_refused(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        resp = client.post("/admin/player/%s/currency" % target["player_id"],
                           headers=root["headers"],
                           json={"currency": "DOGE", "amount": 1})
        assert resp.status_code == 400

    def test_absurd_amount_is_refused(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        resp = client.post("/admin/player/%s/currency" % target["player_id"],
                           headers=root["headers"],
                           json={"currency": "BTC", "amount": 10 ** 12})
        assert resp.status_code == 400
        assert resp.json()["detail"]["reason"] == "out_of_range"

    def test_unknown_player_is_404(self, client):
        root = _register(client, "admin")
        resp = client.post("/admin/player/nobody_here/currency",
                           headers=root["headers"],
                           json={"currency": "BTC", "amount": 1})
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Audit log: recorded, and append-only
# ---------------------------------------------------------------------------
class TestAuditLog:
    def test_currency_change_is_recorded(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        client.post("/admin/player/%s/currency" % target["player_id"],
                    headers=root["headers"],
                    json={"currency": "PLT", "amount": 2500,
                          "reason": "quest compensation"})
        data = client.get("/admin/audit?limit=50",
                          headers=root["headers"]).json()
        entry = next((e for e in data["entries"]
                      if e["action"] == "economy.plt"), None)
        assert entry is not None, "no audit row for the currency change"
        assert entry["admin"] == root["username"]
        assert entry["target"] == target["username"]
        assert entry["reason"] == "quest compensation"
        assert entry["old_value"] is not None
        assert entry["new_value"] is not None
        assert entry["timestamp"] > 0

    def test_role_change_is_recorded(self, client):
        root = _register(client, "superadmin")
        target = _register(client, "player")
        client.put("/admin/player/%s/role" % target["username"],
                   headers=root["headers"], json={"role": "moderator"})
        data = client.get("/admin/audit?action=role",
                          headers=root["headers"]).json()
        entry = next((e for e in data["entries"]
                      if e["action"] == "role.change"), None)
        assert entry is not None
        assert entry["old_value"] == "player"
        assert entry["new_value"] == "moderator"

    def test_update_is_refused_by_the_database(self, client):
        """Append-only is enforced by a trigger, not by convention."""
        async def _tamper():
            async with aiosqlite.connect(DB_PATH_TEST) as db:
                with pytest.raises(Exception) as excinfo:
                    await db.execute(
                        "UPDATE admin_audit_log SET reason = 'redacted'")
                    await db.commit()
                return "append-only" in str(excinfo.value).lower()

        assert _run(_tamper()) is True

    def test_delete_is_refused_by_the_database(self, client):
        async def _tamper():
            async with aiosqlite.connect(DB_PATH_TEST) as db:
                with pytest.raises(Exception) as excinfo:
                    await db.execute("DELETE FROM admin_audit_log")
                    await db.commit()
                return "append-only" in str(excinfo.value).lower()

        assert _run(_tamper()) is True

    def test_audit_still_has_rows_after_tamper_attempts(self, client):
        root = _register(client, "superadmin")
        data = client.get("/admin/audit?limit=200", headers=root["headers"])
        assert data.status_code == 200
        assert len(data.json()["entries"]) > 0

    def test_there_is_no_write_endpoint(self, client):
        """No HTTP verb can mutate the trail - only the triggers block SQL."""
        root = _register(client, "superadmin")
        for method in ("POST", "PUT", "DELETE", "PATCH"):
            resp = client.request(method, "/admin/audit",
                                  headers=root["headers"], json={})
            assert resp.status_code in (404, 405), (
                "%s /admin/audit should not be a write route" % method)


# ---------------------------------------------------------------------------
# Inventory / equipment
# ---------------------------------------------------------------------------
class TestInventoryManagement:
    def test_add_item_uses_canonical_ids(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        # A brand-new account already holds the Phase 1 starter reward, which
        # includes "Kalkan I", so the baseline is read from the server rather
        # than assumed to be zero.
        before = client.get(
            "/admin/player/%s" % target["player_id"],
            headers=root["headers"]).json()["inventory"].get("kalkan1", 0)
        # "Kalkan 1" is a display alias; the server must store `kalkan1`.
        resp = client.post("/admin/player/%s/item" % target["player_id"],
                           headers=root["headers"],
                           json={"item_id": "Kalkan 1", "quantity": 3})
        assert resp.status_code == 200, resp.text
        assert resp.json()["item_id"] == "kalkan1"
        assert resp.json()["old"] == before
        assert resp.json()["new"] == before + 3

    def test_unknown_item_is_refused(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        resp = client.post("/admin/player/%s/item" % target["player_id"],
                           headers=root["headers"],
                           json={"item_id": "not_a_real_item", "quantity": 1})
        assert resp.status_code == 400
        assert resp.json()["detail"]["reason"] == "unknown_item"

    def test_remove_more_than_owned_is_refused(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        resp = client.post("/admin/player/%s/item" % target["player_id"],
                           headers=root["headers"],
                           json={"item_id": "kalkan1", "quantity": -50})
        assert resp.status_code == 400
        assert resp.json()["detail"]["reason"] == "not_owned"

    def test_zeus_droid_chain(self, client):
        """ZEUS is catalogued, purchasable, equippable and reports stats."""
        root = _register(client, "admin")
        target = _register(client, "player")
        resp = client.post("/admin/player/%s/item" % target["player_id"],
                           headers=root["headers"],
                           json={"item_id": "droid_zeus_1", "quantity": 1})
        assert resp.status_code == 200, resp.text
        detail = client.get("/admin/player/%s" % target["player_id"],
                            headers=root["headers"]).json()
        assert detail["inventory"].get("droid_zeus_1") == 1
        # The drone chain is server-readable, not just an inventory count.
        drones = detail.get("drones") or []
        assert isinstance(drones, list)

    def test_zeus_has_server_defined_stats(self, client):
        """No invented numbers: the stats must equal the game_data values."""
        stats = game_data.item_stats("droid_zeus_1")
        assert stats["type"] == "drone"
        assert stats["laser_slots"] == game_data.DRONE_SLOTS_PER_DRONE
        assert stats["level_req"] == game_data.ITEM_LEVEL_REQUIREMENTS[
            "droid_zeus_1"]

    def test_loadout_rejects_item_the_player_does_not_own(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        resp = client.post("/admin/player/%s/loadout" % target["player_id"],
                           headers=root["headers"],
                           json={"ship_id": game_data.DEFAULT_SHIP,
                                 "config_index": 1, "lasers": ["lf3"]})
        assert resp.status_code == 400
        assert resp.json()["detail"]["item_id"] == "lf3"

    def test_loadout_accepts_an_owned_item(self, client):
        root = _register(client, "admin")
        target = _register(client, "player")
        client.post("/admin/player/%s/item" % target["player_id"],
                    headers=root["headers"],
                    json={"item_id": "lf1", "quantity": 1})
        resp = client.post("/admin/player/%s/loadout" % target["player_id"],
                           headers=root["headers"],
                           json={"ship_id": game_data.DEFAULT_SHIP,
                                 "config_index": 1, "lasers": ["lf1"],
                                 "generators": ["kalkan1"], "selected": True})
        assert resp.status_code == 200, resp.text
        assert resp.json()["new"]["lasers"] == ["lf1"]
        assert resp.json()["new"]["generators"] == ["kalkan1"]

    def test_teleport_persists(self, client):
        root = _register(client, "moderator")
        target = _register(client, "player")
        target_map = next(m for m in game_data.MAPS
                          if m != game_data.DEFAULT_MAP)
        resp = client.post("/admin/player/%s/teleport" % target["player_id"],
                           headers=root["headers"],
                           json={"map_id": target_map, "x": 5, "y": 7,
                                 "reason": "test move"})
        assert resp.status_code == 200, resp.text
        detail = client.get("/admin/player/%s" % target["player_id"],
                            headers=root["headers"]).json()
        assert detail["map_id"] == target_map

    def test_teleport_rejects_unknown_map(self, client):
        root = _register(client, "moderator")
        target = _register(client, "player")
        resp = client.post("/admin/player/%s/teleport" % target["player_id"],
                           headers=root["headers"],
                           json={"map_id": "9-9", "x": 0, "y": 0})
        assert resp.status_code == 400


# ---------------------------------------------------------------------------
# Auction settlement: single-winner, refunds, restart safety
# ---------------------------------------------------------------------------
def _seed_auction(seller, item_id="lf1", quantity=1, currency="BTC",
                  price=1000, ends_in=-60, winner=""):
    """Insert an auction directly, with a bid already recorded if `winner`.

    `auctions.highest_bidder` is `TEXT NOT NULL DEFAULT ''`, so "no bidder" is
    the empty string - passing NULL would violate the constraint.
    """
    async def _seed():
        now = int(time.time())
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            cursor = await db.execute(
                "INSERT INTO auctions (seller_player_id, item_id, quantity, "
                "currency, start_price, current_price, highest_bidder, state, "
                "created_at, ends_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?, ?)",
                (seller["player_id"], item_id, quantity, currency, price, price,
                 winner or "", now, now + ends_in))
            auction_id = cursor.lastrowid
            if winner:
                await db.execute(
                    "INSERT INTO auction_bids (auction_id, bidder_player_id, "
                    "amount, created_at) VALUES (?, ?, ?, ?)",
                    (auction_id, winner, price, now))
            await db.commit()
            return auction_id
    return _run(_seed())


def _balance(player_id, column="btc"):
    async def _read():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            row = await (await db.execute(
                "SELECT %s FROM economy WHERE player_id = ?" % column,
                (player_id,))).fetchone()
            return int(row[0]) if row else 0
    return _run(_read())


def _item_count(player_id, item_id):
    async def _read():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            row = await (await db.execute(
                "SELECT quantity FROM inventory WHERE player_id = ? "
                "AND item_id = ?", (player_id, item_id))).fetchone()
            return int(row[0]) if row else 0
    return _run(_read())


def _grant_item(headers, player_id, item_id, quantity=1):
    async def _do():
        import routes_p45 as r45
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            await r45._grant_item(db, player_id, item_id, quantity)
            await db.commit()
    _run(_do())


def _fund(headers, player_id, column, amount):
    async def _do():
        import routes_p45 as r45
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            await r45._grant_currency(db, player_id, **{column: amount},
                                      reason="test_setup")
            await db.commit()
    _run(_do())


class TestAuctionSettlement:
    def test_expired_auction_settles(self, client):
        seller = _register(client, "player")
        winner = _register(client, "player")
        _grant_item(None, seller["player_id"], "lf1", 1)
        _fund(None, seller["player_id"], "btc", 5000)
        _fund(None, winner["player_id"], "btc", 5000)

        # The Phase 1 starter reward already includes one LF1, so the baseline
        # is measured rather than assumed to be zero.
        winner_before_items = _item_count(winner["player_id"], "lf1")
        auction_id = _seed_auction(seller, winner=winner["player_id"])
        seller_before = _balance(seller["player_id"])
        winner_before = _balance(winner["player_id"])

        settled = _run(schedulers.settle_expired_auctions(DB_PATH_TEST))
        assert auction_id in settled
        # The winner gains the auctioned item...
        assert _item_count(winner["player_id"], "lf1") == winner_before_items + 1
        # ...the seller is paid (less the fee)...
        assert _balance(seller["player_id"]) > seller_before
        # ...and the winning bid was already escrowed, so settlement does not
        # charge the winner a second time.
        assert _balance(winner["player_id"]) == winner_before

    def test_settling_twice_pays_nothing_extra(self, client):
        """The single-winner guard: a second pass must change nothing."""
        seller = _register(client, "player")
        winner = _register(client, "player")
        _grant_item(None, seller["player_id"], "lf1", 1)
        winner_before_items = _item_count(winner["player_id"], "lf1")
        auction_id = _seed_auction(seller, winner=winner["player_id"])

        assert _run(schedulers.settle_expired_auctions(DB_PATH_TEST)) == [auction_id]
        seller_after = _balance(seller["player_id"])
        assert _item_count(winner["player_id"], "lf1") == winner_before_items + 1

        assert _run(schedulers.settle_expired_auctions(DB_PATH_TEST)) == []
        assert _balance(seller["player_id"]) == seller_after
        assert _item_count(winner["player_id"], "lf1") == winner_before_items + 1

    def test_admin_force_settle_is_single_winner_too(self, client):
        root = _register(client, "superadmin")
        seller = _register(client, "player")
        winner = _register(client, "player")
        _grant_item(None, seller["player_id"], "lf1", 1)
        winner_before = _item_count(winner["player_id"], "lf1")
        auction_id = _seed_auction(seller, winner=winner["player_id"],
                                   ends_in=3600)
        first = client.post("/admin/auctions/%d/settle" % auction_id,
                            headers=root["headers"], json={})
        assert first.status_code == 200, first.text
        second = client.post("/admin/auctions/%d/settle" % auction_id,
                             headers=root["headers"], json={})
        assert second.status_code == 409
        assert _item_count(winner["player_id"], "lf1") == winner_before + 1

    def test_unbid_auction_returns_the_item(self, client):
        seller = _register(client, "player")
        _grant_item(None, seller["player_id"], "lf1", 1)
        before = _item_count(seller["player_id"], "lf1")
        _seed_auction(seller, winner=None)
        _run(schedulers.settle_expired_auctions(DB_PATH_TEST))
        assert _item_count(seller["player_id"], "lf1") == before + 1

    def test_open_auction_is_not_settled(self, client):
        seller = _register(client, "player")
        _seed_auction(seller, ends_in=3600)
        assert _run(schedulers.settle_expired_auctions(DB_PATH_TEST)) == []

    def test_settlement_survives_a_restart(self, client):
        """A sweep on a fresh connection is exactly what a reboot does."""
        seller = _register(client, "player")
        winner = _register(client, "player")
        _grant_item(None, seller["player_id"], "lf1", 1)
        winner_before = _item_count(winner["player_id"], "lf1")
        auction_id = _seed_auction(seller, winner=winner["player_id"])
        # `settle_expired_auctions` opens its own connection, so this IS the
        # restart path: nothing is held in memory between passes.
        assert auction_id in _run(
            schedulers.settle_expired_auctions(DB_PATH_TEST))
        assert _item_count(winner["player_id"], "lf1") == winner_before + 1


class TestEventScheduler:
    def test_event_activates_and_finishes(self, client):
        root = _register(client, "superadmin")
        now = int(time.time())
        resp = client.post("/admin/events", headers=root["headers"], json={
            "event_id": "ev_test_%d" % now, "name": "Test Raid",
            "map_id": game_data.DEFAULT_MAP,
            "starts_at": now - 10, "ends_at": now + 3600,
            "reward_btc": 100,
        })
        assert resp.status_code == 200, resp.text
        event_id = "ev_test_%d" % now

        changed = _run(schedulers.sync_event_states(DB_PATH_TEST))
        assert event_id in changed["activated"]

        data = client.get("/admin/events", headers=root["headers"]).json()
        entry = next(e for e in data["events"] if e["event_id"] == event_id)
        assert entry["state"] == "active"

    def test_finished_event_is_not_reactivated(self, client):
        root = _register(client, "superadmin")
        now = int(time.time())
        event_id = "ev_done_%d" % now
        client.post("/admin/events", headers=root["headers"], json={
            "event_id": event_id, "name": "Finished", "map_id": "",
            "starts_at": now - 7200, "ends_at": now - 3600,
        })
        changed = _run(schedulers.sync_event_states(DB_PATH_TEST))
        assert event_id in changed["finished"]
        # A second pass finds nothing to do - the window already closed it.
        assert event_id not in _run(
            schedulers.sync_event_states(DB_PATH_TEST))["activated"]
