"""
Phases 2-3: server-authoritative stats, loadouts, equipment, ammo, faction,
maps, portals, ranking, nickname.

  S1  login payload carries REAL level/xp/honor (not the old hardcoded 1/0/0)
  S2  XP is applied server-side and the level is DERIVED from it
  S3  a client cannot post a level directly
  S4  vitals are clamped to the server's own maxima
  S5  loadouts round-trip through Config 1 / Config 2
  S6  an item the player does not own cannot be equipped
  S7  an item above the player's level cannot be equipped
  S8  only one config is selected at a time
  S9  equipment damage aggregates the equipped lasers
  S10 ammo is server-owned and consumed by firing
  S11 a player cannot equip a drone they do not own
  S12 faction change costs 10000 PLT
  S13 faction change forfeits 50% of honor
  S14 faction change has a 21 day cooldown
  S15 faction change is blocked while in a clan
  S16 the first company pick is free
  S17 maps are gated by level and faction
  S18 a map move requires a real portal
  S19 portal travel is server-authorised
  S20 ranking is computed server-side
  S21 nickname is normalised and unique
  S22 XP curve and map names are unchanged
"""

import asyncio
import os
import sys
import time

import aiosqlite
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "phase23-authority-secret-key-0123456789abcd"
os.environ["DB_PATH"] = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "test_novagate_p23.db"
)
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

import combat as combat_service  # noqa: E402
import game_data  # noqa: E402
import player_state  # noqa: E402
from main import app, init_db, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402

DB_PATH_TEST = os.environ["DB_PATH"]
PASSWORD = "TestPass123!"
EXPECT_BTC = 10000
EXPECT_PLT = 10000


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


def _uname(prefix="p23"):
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


@pytest.fixture(scope="module", autouse=True)
def _app():
    _reset_db()
    _run(init_db())
    reset_rate_limits()
    with TestClient(app) as client:
        yield client
    _reset_db()


def _new_player(client, company="EIC"):
    reset_rate_limits()
    username = _uname()
    resp = client.post("/auth/register", json={
        "username": username, "password": PASSWORD,
        "nickname": username, "company": company,
    })
    assert resp.status_code == 200, resp.text
    body = resp.json()
    login = client.post("/auth/login",
                        json={"username": username, "password": PASSWORD})
    assert login.status_code == 200, login.text
    data = login.json()
    return {
        "username": username,
        "player_id": body["player_id"],
        "token": data["access_token"],
        "headers": {"Authorization": f"Bearer {data['access_token']}"},
    }


def _db_write(fn):
    """Run a coroutine against a fresh connection to the test DB.

    The COMMIT is explicit: aiosqlite's connection context manager closes the
    connection but does not commit, so a helper that forgets it would silently
    discard the write and every assertion would read the pre-write value.
    """
    async def runner():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            result = await fn(db)
            await db.commit()
            return result
    return _run(runner())


def _grant_xp(player_id, amount):
    async def apply(db):
        await player_state.ensure_stats(db, player_id)
        return await player_state.add_xp(db, player_id, amount)
    return _db_write(apply)


def _grant_item(player_id, item_id, quantity=1):
    async def apply(db):
        from routes_p45 import _grant_item as grant
        return await grant(db, player_id, item_id, quantity)
    return _db_write(apply)


def _grant_plt(player_id, amount):
    async def apply(db):
        from routes_p45 import _grant_currency
        return await _grant_currency(db, player_id, plt=amount, reason="test")
    return _db_write(apply)


def _grant_btc(player_id, amount):
    async def apply(db):
        from routes_p45 import _grant_currency
        return await _grant_currency(db, player_id, btc=amount, reason="test")
    return _db_write(apply)


def _set_honor(player_id, amount):
    async def apply(db):
        await player_state.ensure_stats(db, player_id)
        return await player_state.add_honor(db, player_id, amount)
    return _db_write(apply)

# ---------------------------------------------------------------------------
# S1-S4  stats / XP / level / vitals
# ---------------------------------------------------------------------------
def _login_payload(client, player):
    """Re-login and refresh the player's token.

    The server keeps ONE active session per account, so logging in again
    invalidates the previous token. Any test that re-logs-in MUST take the
    refreshed token back, or every later call 401s with "Session inactive".
    """
    resp = client.post("/auth/login",
                       json={"username": player["username"],
                             "password": PASSWORD})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    player["token"] = body["access_token"]
    player["headers"] = {"Authorization": f"Bearer {body['access_token']}"}
    return body["oyuncu"]


def test_login_carries_real_progression(_app):
    player = _new_player(_app)
    oyuncu = _login_payload(_app, player)
    assert oyuncu["level"] == 1
    # The client-facing key is `exp` (the client's existing GlobalState name);
    # the server's canonical column is `xp`.
    assert oyuncu["exp"] == 0
    assert oyuncu["honor"] == 0
    for field in ("hp", "shield", "npc_kills", "player_kills", "deaths",
                  "ammo_inventory", "equipment_stats"):
        assert field in oyuncu, field


def test_stats_endpoint_matches_the_login_payload(_app):
    player = _new_player(_app)
    payload = _login_payload(_app, player)
    resp = _app.get("/player/stats", headers=player["headers"])
    assert resp.status_code == 200, resp.text
    stats = resp.json()["stats"]
    assert stats["level"] == payload["level"]
    assert stats["xp"] == payload["exp"]
    assert stats["honor"] == payload["honor"]
    assert stats["hp"] == payload["hp"]
    assert stats["deaths"] == payload["deaths"]


def test_xp_is_applied_and_level_is_derived(_app):
    player = _new_player(_app)
    _grant_xp(player["player_id"], game_data.xp_for_level(2))
    payload = _login_payload(_app, player)
    assert payload["level"] == 2, payload
    assert payload["exp"] == game_data.xp_for_level(2)


def test_level_is_never_accepted_from_the_client(_app):
    player = _new_player(_app)
    # There is deliberately no endpoint that takes a level. Prove that posting
    # one alongside a real call changes nothing.
    resp = _app.post("/player/vitals", headers=player["headers"],
                     json={"hp": 50, "shield": 50, "level": 99})
    assert resp.status_code == 200
    assert resp.json()["stats"]["level"] == 1, "a posted level was honoured"
    assert _login_payload(_app, player)["level"] == 1


def test_vitals_are_clamped_to_the_server_maxima(_app):
    player = _new_player(_app)
    resp = _app.post("/player/vitals", headers=player["headers"],
                     json={"hp": 9999, "shield": 9999})
    assert resp.status_code == 200
    stats = resp.json()["stats"]
    assert stats["hp"] == stats["max_hp"] == 100.0
    assert stats["shield"] == stats["max_shield"] == 100.0

    # A client cannot raise its own ceiling either.
    resp = _app.post("/player/vitals", headers=player["headers"],
                     json={"hp": 50, "shield": 50, "max_hp": 9999})
    assert resp.json()["stats"]["max_hp"] == 100.0

    # Negative input floors at zero rather than going negative.
    resp = _app.post("/player/vitals", headers=player["headers"],
                     json={"hp": -50, "shield": -1})
    assert resp.json()["stats"]["hp"] == 0.0
    assert resp.json()["stats"]["shield"] == 0.0

# ---------------------------------------------------------------------------
# S5-S8  loadouts / equipment gating
# ---------------------------------------------------------------------------
def test_loadout_round_trips(_app):
    player = _new_player(_app)
    # LF1 + Kalkan1 + Hiz1 all come from the starter reward.
    resp = _app.put("/loadouts", headers=player["headers"], json={
        "ship_id": "Ship10", "config_index": 1,
        "lasers": ["lf1"], "generators": ["kalkan1", "hiz1"],
        "extras": [], "drone_slots": [],
    })
    assert resp.status_code == 200, resp.text
    assert resp.json()["loadout"]["lasers"] == ["lf1"]

    got = _app.get("/loadouts", headers=player["headers"]).json()
    assert got["loadouts"]["1"]["lasers"] == ["lf1"]
    assert set(got["loadouts"]["1"]["generators"]) == {"kalkan1", "hiz1"}
    # Config 2 stays independent and empty.
    assert got["loadouts"]["2"]["lasers"] == []


def test_cannot_equip_an_unowned_item(_app):
    player = _new_player(_app)
    # PBMB has no level requirement, so OWNERSHIP is unambiguously the gate
    # here. (lf2 would report level_too_low first, which is correct but tests a
    # different rule - see the next test.)
    resp = _app.put("/loadouts", headers=player["headers"], json={
        "ship_id": "Ship10", "config_index": 1, "extras": ["pbmb"],
    })
    assert resp.status_code == 400, resp.text
    rejected = resp.json()["detail"]["rejected"]
    assert any(r["item_id"] == "pbmb" and r["reason"] == "not_owned"
               for r in rejected), rejected


def test_cannot_equip_above_the_player_level(_app):
    player = _new_player(_app)
    # LF3 requires level 10. Give the item so the LEVEL gate - not ownership -
    # is what blocks it.
    _grant_item(player["player_id"], "lf3", 1)
    resp = _app.put("/loadouts", headers=player["headers"], json={
        "ship_id": "Ship10", "config_index": 1, "lasers": ["lf3"],
    })
    assert resp.status_code == 400, resp.text
    assert resp.json()["detail"]["rejected"][0]["reason"] == "level_too_low"

    # After levelling up the very same request succeeds.
    _grant_xp(player["player_id"], game_data.xp_for_level(10))
    resp = _app.put("/loadouts", headers=player["headers"], json={
        "ship_id": "Ship10", "config_index": 1, "lasers": ["lf3"],
    })
    assert resp.status_code == 200, resp.text


def test_a_rejected_slot_rolls_the_whole_config_back(_app):
    player = _new_player(_app)
    resp = _app.put("/loadouts", headers=player["headers"], json={
        "ship_id": "Ship10", "config_index": 1,
        "lasers": ["lf1"],           # owned
        "generators": ["kalkan2"],   # NOT owned
    })
    assert resp.status_code == 400
    got = _app.get("/loadouts", headers=player["headers"]).json()
    assert got["loadouts"]["1"]["lasers"] == [], "a partial config was written"


def test_only_one_config_is_selected(_app):
    player = _new_player(_app)
    for index in (1, 2):
        _app.put("/loadouts", headers=player["headers"], json={
            "ship_id": "Ship10", "config_index": index, "lasers": ["lf1"],
        })
        _app.post("/loadouts/select", headers=player["headers"],
                  json={"ship_id": "Ship10", "config_index": index})
        got = _app.get("/loadouts", headers=player["headers"]).json()
        selected = [k for k, v in got["loadouts"].items() if v.get("selected")]
        assert selected == [str(index)], got["loadouts"]


# ---------------------------------------------------------------------------
# S9-S11  equipment aggregate / ammo / drones
# ---------------------------------------------------------------------------
def test_equipment_damage_aggregates_equipped_lasers(_app):
    player = _new_player(_app)
    before = _app.get("/equipment/stats", headers=player["headers"]).json()
    assert before["equipment"]["laser_damage"] == 0

    _app.put("/loadouts", headers=player["headers"], json={
        "ship_id": "Ship10", "config_index": 1, "lasers": ["lf1"],
        "generators": ["kalkan1", "hiz1"],
    })
    equipment = _app.get("/equipment/stats",
                         headers=player["headers"]).json()["equipment"]
    assert equipment["laser_damage"] == 90, equipment
    assert equipment["shield"] == 5000, equipment
    assert equipment["speed_bonus"] == 7, equipment


def test_ammo_is_server_owned_and_consumed(_app):
    player = _new_player(_app)
    stock = _app.get("/ammo", headers=player["headers"]).json()
    # The starter grant mirrors the client's STARTER_REWARD_AMMO.
    assert stock["ammo"]["ammo_x1_1000"] == 1000, stock
    assert stock["ammo_client"]["X1"] == 1000, stock

    async def fire():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            allowed, reason, _ = await combat_service.fire_laser(
                db, player["player_id"], "Ship10", 1)
            after = await combat_service.get_ammo(db, player["player_id"])
            return allowed, reason, after
    allowed, reason, after = _run(fire())
    assert allowed, reason
    assert after["ammo_x1_1000"] == 999, after

    # With the stock emptied the server refuses the shot.
    _app.post("/ammo", headers=player["headers"],
              json={"ammo_id": "ammo_x1_1000", "quantity": 0})
    async def fire_empty():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            return await combat_service.fire_laser(
                db, player["player_id"], "Ship10", 1)
    allowed, reason, _ = _run(fire_empty())
    assert not allowed and reason == "no_ammo", (allowed, reason)


def test_drones_require_ownership(_app):
    player = _new_player(_app)
    resp = _app.put("/drones", headers=player["headers"], json={
        "drones": [{"drone_type": "PLUS"}],
    })
    assert resp.status_code == 400, resp.text
    assert resp.json()["detail"]["rejected"][0]["reason"] == "not_owned"

    _grant_item(player["player_id"], "droid_plus_1", 1)
    resp = _app.put("/drones", headers=player["headers"], json={
        "drones": [{"drone_type": "PLUS"}],
    })
    assert resp.status_code == 200, resp.text
    assert len(resp.json()["drones"]) == 1


# ---------------------------------------------------------------------------
# S12-S16  faction change
# ---------------------------------------------------------------------------
def _faction_switch(client, player, target="MMO"):
    return client.post("/account/faction", headers=player["headers"],
                       json={"company": target})


def test_first_company_pick_is_free(_app):
    reset_rate_limits()
    username = _uname()
    resp = _app.post("/auth/register", json={
        "username": username, "password": PASSWORD,
        "nickname": username, "company": "",
    })
    assert resp.status_code == 200
    body = _app.post("/auth/login",
                    json={"username": username,
                          "password": PASSWORD}).json()
    headers = {"Authorization": f"Bearer {body['access_token']}"}
    result = _faction_switch(_app, {"headers": headers})
    assert result.status_code == 200, result.text
    assert result.json()["cost_plt"] == 0, result.json()
    assert result.json()["honor_lost"] == 0, result.json()


def test_faction_change_costs_10000_plt(_app):
    player = _new_player(_app, company="EIC")
    before = _login_payload(_app, player)
    result = _faction_switch(_app, player, "MMO")
    assert result.status_code == 200, result.text
    assert result.json()["company"] == "MMO"
    assert result.json()["cost_plt"] == game_data.FACTION_CHANGE_COST_PLT
    after = _login_payload(_app, player)
    assert after["plt"] == before["plt"] - 10000, (before, after)


def test_faction_change_forfeits_half_the_honor(_app):
    player = _new_player(_app, company="EIC")
    _set_honor(player["player_id"], 200)
    result = _faction_switch(_app, player, "MMO")
    assert result.status_code == 200, result.text
    assert result.json()["honor_lost"] == 100
    assert _login_payload(_app, player)["honor"] == 100


def test_faction_change_is_blocked_without_enough_plt(_app):
    player = _new_player(_app, company="EIC")

    async def drain():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            await db.execute(
                "UPDATE economy SET plt = 0, updated_at = 0 WHERE player_id = ?",
                (player["player_id"],))
            await db.commit()
    _run(drain())
    resp = _faction_switch(_app, player, "MMO")
    assert resp.status_code == 400, resp.text
    assert resp.json()["detail"]["reason"] == "insufficient_plt"


def test_faction_change_has_a_21_day_cooldown(_app):
    player = _new_player(_app, company="EIC")
    _grant_plt(player["player_id"], 100000)
    assert _faction_switch(_app, player, "MMO").status_code == 200
    resp = _faction_switch(_app, player, "VRU")
    assert resp.status_code == 409, resp.text
    detail = resp.json()["detail"]
    assert detail["reason"] == "cooldown"
    assert detail["remaining_seconds"] > 20 * 24 * 3600


def test_faction_change_cooldown_expires(_app):
    player = _new_player(_app, company="EIC")
    _grant_plt(player["player_id"], 100000)
    assert _faction_switch(_app, player, "MMO").status_code == 200

    # Age the record past the cooldown, exactly as 21 days of uptime would.
    async def age():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            await db.execute(
                "UPDATE faction_changes SET created_at = ? WHERE player_id = ?",
                (int(time.time()) - game_data.FACTION_CHANGE_COOLDOWN_SECONDS - 60,
                 player["player_id"]))
            await db.commit()
    _run(age())
    assert _faction_switch(_app, player, "VRU").status_code == 200


def test_faction_change_blocked_while_in_a_clan(_app):
    player = _new_player(_app, company="EIC")
    _grant_plt(player["player_id"], 100000)
    created = _app.post("/clans", headers=player["headers"],
                        json={"name": "Blocked" + _uname("c")[:6],
                              "tag": "BLK"})
    assert created.status_code == 200, created.text
    resp = _faction_switch(_app, player, "MMO")
    assert resp.status_code == 409, resp.text
    assert "clan" in str(resp.json()["detail"]).lower()


# ---------------------------------------------------------------------------
# S17-S19  maps / portals
# ---------------------------------------------------------------------------
def test_maps_are_gated_by_level_and_faction(_app):
    player = _new_player(_app, company="EIC")
    resp = _app.get("/maps", headers=player["headers"])
    assert resp.status_code == 200, resp.text
    maps = {m["map_id"]: m for m in resp.json()["maps"]}

    assert maps["1-1"]["unlocked"] is True
    assert maps["1-4"]["unlocked"] is False
    assert maps["1-4"]["reason"] == "level_too_low"
    # Another faction's sector is closed to this player.
    assert maps["2-1"]["unlocked"] is False
    assert maps["2-1"]["reason"] == "wrong_company"
    # Portals are reported so the client can render them.
    assert maps["1-1"]["portals"], maps["1-1"]


def test_map_move_requires_a_real_portal(_app):
    player = _new_player(_app, company="EIC")
    # 1-1 -> 1-2 exists, and 1-2 needs level 2.
    resp = _app.post("/map/move", headers=player["headers"],
                     json={"map_id": "1-2"})
    assert resp.status_code == 403, resp.text
    assert resp.json()["detail"]["reason"] == "level_too_low"

    # Level up and the very same move is allowed, proving the portal exists.
    _grant_xp(player["player_id"], game_data.xp_for_level(3))
    resp = _app.post("/map/move", headers=player["headers"],
                     json={"map_id": "1-2"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["map_id"] == "1-2"

    # A destination the player has no portal to is refused. Standing on 1-3,
    # "1-2" is level-legal and same-faction, but 1-3 only links back to its
    # hub - so the failure is the missing portal, which is the rule under test.
    async def stand_on_13():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            await main_module.save_player_world_state(
                db, player["player_id"], "1-3", 0.0, 0.0)
            await db.commit()
    _run(stand_on_13())
    resp = _app.post("/map/move", headers=player["headers"],
                     json={"map_id": "1-2"})
    assert resp.status_code == 403, resp.text
    assert resp.json()["detail"]["reason"] == "no_portal", resp.text

    # A level-gated map is refused even where a portal exists.
    resp = _app.post("/map/move", headers=player["headers"],
                     json={"map_id": "1-4"})
    assert resp.status_code == 403
    assert resp.json()["detail"]["reason"] == "level_too_low"

    # An invented map name is refused.
    resp = _app.post("/map/move", headers=player["headers"],
                     json={"map_id": "not_a_map"})
    assert resp.status_code == 403
    assert resp.json()["detail"]["reason"] == "unknown_map"


def test_portal_travel_is_server_authorised(_app):
    player = _new_player(_app, company="EIC")
    # 1-2 is level 2, so level up before travelling there.
    _grant_xp(player["player_id"], game_data.xp_for_level(3))
    portal = game_data.find_portal("1-1->1-2")
    assert portal is not None

    resp = _app.post("/portal/travel", headers=player["headers"],
                     json={"portal_id": portal["portal_id"]})
    assert resp.status_code == 200, resp.text
    assert resp.json()["to_map"] == "1-2"

    # A portal the player is not standing on is refused.
    far = game_data.find_portal("2-1->2-2")
    resp = _app.post("/portal/travel", headers=player["headers"],
                     json={"portal_id": far["portal_id"]})
    assert resp.status_code == 403, resp.text
    assert resp.json()["detail"]["reason"] == "wrong_origin"

    # An invented portal id is a 404, not a silent success.
    resp = _app.post("/portal/travel", headers=player["headers"],
                     json={"portal_id": "1-1->nowhere"})
    assert resp.status_code == 404


def test_portal_travel_respects_the_level_gate(_app):
    player = _new_player(_app, company="EIC")
    # PVP needs level 10; this player is level 1.
    gated = next(p for p in game_data.portals_from("1-1")
                 if p["to_map"] == "PVP")
    resp = _app.post("/portal/travel", headers=player["headers"],
                     json={"portal_id": gated["portal_id"]})
    assert resp.status_code == 403, resp.text
    assert resp.json()["detail"]["reason"] == "level_too_low"


# ---------------------------------------------------------------------------
# S20-S22  ranking / nickname / protected values / world state
# ---------------------------------------------------------------------------
def test_ranking_is_server_computed(_app):
    player = _new_player(_app, company="EIC")
    _grant_xp(player["player_id"], game_data.xp_for_level(5))

    async def record():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            await player_state.ensure_stats(db, player["player_id"])
            await player_state.add_kill(db, player["player_id"], "npc")
            await player_state.add_death(db, player["player_id"])
            await db.commit()
    _run(record())

    resp = _app.get("/ranking", headers=player["headers"])
    assert resp.status_code == 200, resp.text
    entries = {e["player_id"]: e for e in resp.json()["entries"]}
    assert player["player_id"] in entries, resp.json()
    entry = entries[player["player_id"]]
    assert entry["level"] == 5, entry
    assert entry["npc_kills"] == 1
    assert entry["deaths"] == 1


def test_nickname_is_normalised_and_unique(_app):
    first = _new_player(_app, company="EIC")
    resp = _app.put("/account/nickname", headers=first["headers"],
                    json={"nickname": "  NovaCmdr  "})
    assert resp.status_code == 200, resp.text
    assert resp.json()["nickname"] == "NovaCmdr"

    second = _new_player(_app, company="EIC")
    resp = _app.put("/account/nickname", headers=second["headers"],
                    json={"nickname": "NovaCmdr"})
    assert resp.status_code == 409, resp.text

    resp = _app.put("/account/nickname", headers=second["headers"],
                    json={"nickname": "x"})
    # Pydantic rejects a 1-character nickname before the handler runs.
    assert resp.status_code in (400, 422)

    got = _app.get("/account/nickname", headers=first["headers"]).json()
    assert got["nickname"] == "NovaCmdr"


def test_protected_values_are_unchanged(_app):
    """Phase 2/3 must not re-tune the existing economy or progression."""
    assert game_data.XP_BASE == 10337
    assert game_data.FACTION_CHANGE_COST_PLT == 10000
    assert game_data.FACTION_CHANGE_COOLDOWN_SECONDS == 21 * 24 * 3600
    assert game_data.FACTION_CHANGE_HONOR_LOSS_PERCENT == 50
    for map_id in ("1-1", "2-1", "3-1", "PVP", "BOSS", "4-5", "1-6", "3-6"):
        assert game_data.is_known_map(map_id), map_id
    assert EXPECT_BTC == 10000 and EXPECT_PLT == 10000


def test_world_state_is_created_and_persisted(_app):
    player = _new_player(_app, company="MMO")
    resp = _app.get("/player/stats", headers=player["headers"])
    assert resp.status_code == 200
    # The spawn follows the company.
    assert resp.json()["world"]["map_id"] == "2-1", resp.json()["world"]

    async def move():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            await main_module.save_player_world_state(
                db, player["player_id"], "3-1", 12.0, 34.0)
            await db.commit()
    _run(move())
    again = _app.get("/player/stats", headers=player["headers"]).json()
    assert again["world"]["map_id"] == "3-1"
    assert again["world"]["position_x"] == 12.0


def test_online_players_reflects_live_sessions(_app):
    player = _new_player(_app, company="EIC")
    resp = _app.get("/world/online", headers=player["headers"])
    assert resp.status_code == 200, resp.text
    # No socket in this test, so the list is empty but well formed.
    assert isinstance(resp.json()["players"], list)
    assert isinstance(resp.json()["count"], int)


