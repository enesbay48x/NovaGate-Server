"""
Phases 4-7: loot, bonus boxes, quests, Galaxy Gates, extras, clan, squad, chat,
settings, auction, events, cargo.

  L1  a loot node is spawned by the server and listed for the map
  L2  claiming a node pays exactly once (a second claim is refused)
  L3  a node cannot be claimed from another map
  L4  an expired node cannot be claimed
  L5  claiming a box grants XP/honor and records the kill
  Q1  quest accept -> progress -> complete -> claim
  Q2  a quest reward can only be claimed once (DB-level guard)
  Q3  a client cannot claim a quest it has not completed
  G1  a gate part is consumed from the inventory
  G2  a gate completes when every part is in
  G3  a part the player does not own is refused
  G4  a level-gated gate part is refused
  E1  an extra can only be activated when owned
  C1  a clan can be created / applied / approved
  C2  a member application cannot be reviewed twice
  C3  leaving a clan promotes the next member
  C4  diplomacy is stored symmetrically
  Q1' squad create / join / leave / leader-only kick
  CH1 chat is persisted and rate limited
  CH2 an unknown channel is refused
  S1  settings round-trip
  A1  an auction escrows the item
  A2  a bid escrows the funds
  A3  settling pays the winner once and refunds the loser
  A4  settling twice pays nothing extra
  A5  a bid under the minimum is refused
  EV1 event join + reward, claimed once
  CA1 cargo deposit/withdraw respect capacity
  CA2 cargo is server-persistent
"""

import asyncio
import os
import sys
import time

import aiosqlite
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "phase4567-authority-secret-0123456789abcde"
os.environ["DB_PATH"] = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "test_novagate_p4567.db"
)
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

import game_data  # noqa: E402
import player_state  # noqa: E402
import routes_p45 as r45  # noqa: E402
import routes_p67 as r67  # noqa: E402
from main import app, init_db, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402

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
    for suffix in ("", "-wal", "-shm"):
        path = DB_PATH_TEST + suffix
        if os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass


def _uname(prefix="p47"):
    return f"{prefix}_{int(time.time() * 1000000) % 100000000}"


@pytest.fixture(scope="module", autouse=True)
def _app():
    _reset_db()
    _run(init_db())
    reset_rate_limits()
    with TestClient(app) as client:
        yield client
    _reset_db()


def _new_player(client, company="EIC", name=None):
    reset_rate_limits()
    username = name or _uname()
    resp = client.post("/auth/register", json={
        "username": username, "password": PASSWORD,
        "nickname": username, "company": company,
    })
    assert resp.status_code == 200, resp.text
    body = client.post("/auth/login",
                       json={"username": username, "password": PASSWORD}).json()
    return {
        "username": username,
        "player_id": resp.json()["player_id"],
        "headers": {"Authorization": f"Bearer {body['access_token']}"},
    }


def _db(fn):
    async def runner():
        async with aiosqlite.connect(DB_PATH_TEST) as db:
            result = await fn(db)
            await db.commit()
            return result
    return _run(runner())


def _grant_item(player_id, item_id, quantity=1):
    return _db(lambda db: r45._grant_item(db, player_id, item_id, quantity))


def _grant_currency(player_id, **kwargs):
    return _db(lambda db: r45._grant_currency(db, player_id, **kwargs))


def _set_map(player_id, map_id):
    async def apply(db):
        await main_module.save_player_world_state(db, player_id, map_id, 0.0, 0.0)
    return _db(apply)


def _read(query, args=()):
    async def apply(db):
        cur = await db.execute(query, args)
        return await cur.fetchall()
    return _db(apply)


def _echo(client, player):
    """Read the player's economy back through a fresh login."""
    body = client.post("/auth/login",
                       json={"username": player["username"],
                             "password": PASSWORD}).json()
    player["headers"] = {"Authorization": f"Bearer {body['access_token']}"}
    return body["oyuncu"]

# ---------------------------------------------------------------------------
# L1-L5  world loot / bonus boxes
# ---------------------------------------------------------------------------
def _spawn_box(client, player, map_id="1-1"):
    resp = client.post("/loot/spawn", headers=player["headers"], json={
        "map_id": map_id, "is_bonus_box": True,
    })
    assert resp.status_code == 200, resp.text
    return resp.json()["loot"]


async def _expire(db, loot_id):
    await db.execute("UPDATE world_loot SET expires_at = 1 WHERE loot_id = ?",
                     (loot_id,))


def test_loot_is_listed_but_its_payout_is_hidden(_app):
    player = _new_player(_app)
    node = _spawn_box(_app, player)
    listed = _app.get("/loot/1-1", headers=player["headers"]).json()
    ids = [entry["loot_id"] for entry in listed["loot"]]
    assert node["loot_id"] in ids, listed
    entry = next(e for e in listed["loot"] if e["loot_id"] == node["loot_id"])
    # The listing never leaks the amounts; only the claim reveals them.
    assert "btc" not in entry and "plt" not in entry, entry
    assert entry["is_bonus_box"] is True


def test_claiming_a_node_pays_exactly_once(_app):
    player = _new_player(_app)
    node = _spawn_box(_app, player)
    before = _echo(_app, player)

    first = _app.post("/loot/claim", headers=player["headers"],
                      json={"loot_id": node["loot_id"]})
    assert first.status_code == 200, first.text
    paid = first.json()
    assert paid["btc"] > 0 and paid["plt"] > 0, paid

    after = _echo(_app, player)
    assert after["bitcoin"] == before["bitcoin"] + paid["btc"]
    assert after["plt"] == before["plt"] + paid["plt"]
    assert after["exp"] > before["exp"]
    assert after["honor"] > before["honor"]
    # A bonus box is loot, not an NPC kill, so the kill counter is untouched.
    assert after["npc_kills"] == before["npc_kills"]

    # A second claim is refused and pays nothing.
    second = _app.post("/loot/claim", headers=player["headers"],
                       json={"loot_id": node["loot_id"]})
    assert second.status_code == 409, second.text
    again = _echo(_app, player)
    assert again["bitcoin"] == after["bitcoin"]
    assert again["plt"] == after["plt"]


def test_a_node_cannot_be_claimed_from_another_map(_app):
    player = _new_player(_app)
    node = _spawn_box(_app, player, map_id="1-1")
    _set_map(player["player_id"], "1-2")
    resp = _app.post("/loot/claim", headers=player["headers"],
                     json={"loot_id": node["loot_id"]})
    assert resp.status_code == 403, resp.text
    assert resp.json()["detail"]["reason"] == "wrong_map"
    # Still claimable from its own map.
    _set_map(player["player_id"], "1-1")
    assert _app.post("/loot/claim", headers=player["headers"],
                     json={"loot_id": node["loot_id"]}).status_code == 200


def test_an_expired_node_cannot_be_claimed(_app):
    player = _new_player(_app)
    node = _spawn_box(_app, player)
    _db(lambda db: _expire(db, node["loot_id"]))
    resp = _app.post("/loot/claim", headers=player["headers"],
                     json={"loot_id": node["loot_id"]})
    assert resp.status_code == 410, resp.text


def test_an_invented_loot_id_is_404(_app):
    player = _new_player(_app)
    resp = _app.post("/loot/claim", headers=player["headers"],
                     json={"loot_id": "loot_does_not_exist"})
    assert resp.status_code == 404, resp.text


def test_loot_on_an_unknown_map_is_refused(_app):
    player = _new_player(_app)
    assert _app.get("/loot/nowhere",
                    headers=player["headers"]).status_code == 404
    resp = _app.post("/loot/spawn", headers=player["headers"],
                     json={"map_id": "nowhere", "is_bonus_box": True})
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Q1-Q3  quests
# ---------------------------------------------------------------------------
def _quest_state(client, player, quest_id):
    listing = client.get("/quests", headers=player["headers"]).json()
    return next(q for q in listing["quests"] if q["quest_id"] == quest_id)


def test_quest_lifecycle(_app):
    player = _new_player(_app)
    quest_id = "LV01_Q01"
    target = r45.QUEST_DEFINITIONS[quest_id]["target"]

    assert _app.post("/quests/accept", headers=player["headers"],
                     params={"quest_id": quest_id}).status_code == 200
    assert _quest_state(_app, player, quest_id)["state"] == "active"
    assert _quest_state(_app, player, quest_id)["target"] == target

    # The quest advances through real gameplay, so the progress endpoint
    # refuses a world-event quest outright.
    resp = _app.post("/quests/progress", headers=player["headers"],
                     json={"quest_id": quest_id, "amount": 99})
    assert resp.status_code == 403, resp.text

    for _ in range(target):
        _db(lambda db: r45._advance_quest(db, player["player_id"], "npc_kill"))
    assert _quest_state(_app, player, quest_id)["state"] == "completed"

    claim = _app.post("/quests/claim", headers=player["headers"],
                      params={"quest_id": quest_id})
    assert claim.status_code == 200, claim.text
    assert claim.json()["reward"] == r45.QUEST_DEFINITIONS[quest_id]["reward"]
    assert _quest_state(_app, player, quest_id)["state"] == "claimed"


def test_a_quest_reward_cannot_be_claimed_twice(_app):
    player = _new_player(_app)
    quest_id = "LV03_Q01"          # target 1, event loot_claim
    _app.post("/quests/accept", headers=player["headers"],
              params={"quest_id": quest_id})
    _db(lambda db: r45._advance_quest(db, player["player_id"], "loot_claim"))
    before = _echo(_app, player)

    first = _app.post("/quests/claim", headers=player["headers"],
                      params={"quest_id": quest_id})
    assert first.status_code == 200, first.text
    after_first = _echo(_app, player)
    reward = r45.QUEST_DEFINITIONS[quest_id]["reward"]
    assert after_first["plt"] == before["plt"] + reward["plt"]

    second = _app.post("/quests/claim", headers=player["headers"],
                       params={"quest_id": quest_id})
    assert second.status_code == 409, second.text
    assert _echo(_app, player)["plt"] == after_first["plt"], "reward paid twice"


def test_an_incomplete_quest_cannot_be_claimed(_app):
    player = _new_player(_app)
    _app.post("/quests/accept", headers=player["headers"],
              params={"quest_id": "LV01_Q01"})
    resp = _app.post("/quests/claim", headers=player["headers"],
                     params={"quest_id": "LV01_Q01"})
    assert resp.status_code == 409, resp.text
    assert "not completed" in str(resp.json()["detail"]).lower()


def test_an_unknown_quest_is_404(_app):
    player = _new_player(_app)
    assert _app.post("/quests/accept", headers=player["headers"],
                     params={"quest_id": "NOPE"}).status_code == 404
    assert _app.post("/quests/claim", headers=player["headers"],
                     params={"quest_id": "NOPE"}).status_code == 404


# ---------------------------------------------------------------------------
# G1-G4  Galaxy Gates
# ---------------------------------------------------------------------------
def test_gate_part_is_consumed_from_the_inventory(_app):
    player = _new_player(_app)
    # gate_alpha needs kalkan1 + hiz1 + lf1; the starter reward grants all three.
    before = _echo(_app, player)
    assert before["inventory"].get("kalkan1") == 1

    resp = _app.post("/gates/contribute", headers=player["headers"], json={
        "gate_id": "gate_alpha", "part_id": "kalkan1", "quantity": 1,
    })
    assert resp.status_code == 200, resp.text
    assert resp.json()["parts"]["kalkan1"] == 1

    after = _echo(_app, player)
    assert after["inventory"].get("kalkan1", 0) == 0, "the part was not consumed"


def test_a_gate_completes_when_every_part_is_in(_app):
    player = _new_player(_app)
    _grant_item(player["player_id"], "kalkan1", 1)
    _grant_item(player["player_id"], "hiz1", 1)
    _grant_item(player["player_id"], "lf1", 1)

    for part in ("kalkan1", "hiz1", "lf1"):
        resp = _app.post("/gates/contribute", headers=player["headers"],
                         json={"gate_id": "gate_alpha", "part_id": part,
                               "quantity": 1})
        assert resp.status_code == 200, resp.text
    assert resp.json()["completed"] is True
    assert resp.json()["state"] == "completed"

    # A completed gate accepts nothing further.
    _grant_item(player["player_id"], "lf1", 1)
    resp = _app.post("/gates/contribute", headers=player["headers"], json={
        "gate_id": "gate_alpha", "part_id": "lf1", "quantity": 1,
    })
    assert resp.status_code == 409, resp.text


def test_an_unowned_part_is_refused(_app):
    player = _new_player(_app)
    resp = _app.post("/gates/contribute", headers=player["headers"], json={
        "gate_id": "gate_beta", "part_id": "kalkan2", "quantity": 1,
    })
    assert resp.status_code in (400, 403), resp.text
    detail = resp.json()["detail"]
    assert detail["reason"] in ("not_owned", "level_too_low"), detail


def test_an_unknown_gate_or_part_is_refused(_app):
    player = _new_player(_app)
    assert _app.post("/gates/contribute", headers=player["headers"],
                     json={"gate_id": "nope", "part_id": "lf1"}
                     ).status_code == 404
    assert _app.post("/gates/contribute", headers=player["headers"],
                     json={"gate_id": "gate_alpha", "part_id": "kalkan2"}
                     ).status_code == 400


# ---------------------------------------------------------------------------
# E1  extras
# ---------------------------------------------------------------------------
def test_an_extra_needs_ownership(_app):
    player = _new_player(_app)
    resp = _app.post("/extras/activate", headers=player["headers"],
                     json={"extra_id": "enc"})
    assert resp.status_code == 400, resp.text
    assert resp.json()["detail"]["reason"] == "not_owned"

    _grant_item(player["player_id"], "enc", 1)
    resp = _app.post("/extras/activate", headers=player["headers"],
                     json={"extra_id": "enc"})
    assert resp.status_code == 200, resp.text
    # The expiry is server-written, not client-supplied.
    assert resp.json()["expires_at"] > int(time.time())
    listed = _app.get("/extras", headers=player["headers"]).json()
    assert listed["extras"]["enc"]["state"] == "active"


# ---------------------------------------------------------------------------
# C1-C4  clan
# ---------------------------------------------------------------------------
# A clan name AND a tag must both be unique, and the tag is only CLAN_TAG_MAX
# (6) characters, so a timestamp-derived tag can collide when two calls land in
# the same microsecond. A module counter makes both provably unique.
_CLAN_SEQ = [0]


def _make_clan(client, player, prefix):
    _CLAN_SEQ[0] += 1
    seq = _CLAN_SEQ[0]
    resp = client.post("/clans", headers=player["headers"], json={
        "name": f"{prefix}{seq}",
        "tag": f"{prefix[:3].upper()}{seq:03d}"[:6],
    })
    assert resp.status_code == 200, resp.text
    return resp.json()["clan_id"]


def test_clan_lifecycle(_app):
    owner = _new_player(_app)
    name = "Clan" + _uname("c")[:5]
    created = _app.post("/clans", headers=owner["headers"],
                        json={"name": name, "tag": _uname("T")[:4].upper()})
    assert created.status_code == 200, created.text
    clan_id = created.json()["clan_id"]

    mine = _app.get("/clans/mine", headers=owner["headers"]).json()
    assert mine["clan"]["clan_id"] == clan_id
    assert mine["clan"]["role"] == "owner"

    # A second clan with the same name is refused.
    other = _new_player(_app)
    again = _app.post("/clans", headers=other["headers"],
                      json={"name": name, "tag": "ZZZZ"})
    assert again.status_code == 409, again.text

    applicant = _new_player(_app)
    applied = _app.post("/clans/apply", headers=applicant["headers"],
                        json={"clan_id": clan_id, "message": "please"})
    assert applied.status_code == 200, applied.text

    listing = _app.get("/clans/applications", headers=owner["headers"]).json()
    assert listing["count"] == 1
    app_id = listing["applications"][0]["application_id"]

    reviewed = _app.post("/clans/applications/review",
                         headers=owner["headers"],
                         json={"application_id": app_id, "approve": True})
    assert reviewed.status_code == 200, reviewed.text

    roster = _app.get("/clans/mine", headers=owner["headers"]).json()
    assert {m["player_id"] for m in roster["members"]} == {
        owner["player_id"], applicant["player_id"]}, roster

    # Reviewing the same application twice is refused.
    twice = _app.post("/clans/applications/review", headers=owner["headers"],
                      json={"application_id": app_id, "approve": True})
    assert twice.status_code == 409, twice.text


def test_a_non_member_cannot_review_applications(_app):
    owner = _new_player(_app)
    clan_id = _make_clan(_app, owner, "Rank")
    applicant = _new_player(_app)
    _app.post("/clans/apply", headers=applicant["headers"],
              json={"clan_id": clan_id})
    resp = _app.get("/clans/applications", headers=applicant["headers"])
    assert resp.status_code == 404, resp.text


def test_leaving_a_clan_promotes_the_next_member(_app):
    owner = _new_player(_app)
    clan_id = _make_clan(_app, owner, "Promo")
    second = _new_player(_app)
    _app.post("/clans/apply", headers=second["headers"],
              json={"clan_id": clan_id})
    listing = _app.get("/clans/applications", headers=owner["headers"]).json()
    _app.post("/clans/applications/review", headers=owner["headers"],
              json={"application_id": listing["applications"][0]["application_id"],
                    "approve": True})

    assert _app.post("/clans/leave", headers=owner["headers"]).status_code == 200
    # The owner leaving promotes the remaining member rather than orphaning.
    remaining = _app.get("/clans/mine", headers=second["headers"]).json()
    assert remaining["clan"]["role"] == "owner", remaining
    assert remaining["clan"]["owner_player_id"] == second["player_id"]


def test_diplomacy_is_stored_symmetrically(_app):
    a = _new_player(_app)
    b = _new_player(_app)
    clan_a = _make_clan(_app, a, "DipA")
    clan_b = _make_clan(_app, b, "DipB")

    resp = _app.post("/clans/diplomacy", headers=a["headers"],
                     json={"other_clan_id": clan_b, "relation": "ally"})
    assert resp.status_code == 200, resp.text

    from_a = _app.get("/clans/mine", headers=a["headers"]).json()
    from_b = _app.get("/clans/mine", headers=b["headers"]).json()
    assert from_a["diplomacy"] == [{"other_clan_id": clan_b, "relation": "ally"}]
    assert from_b["diplomacy"] == [{"other_clan_id": clan_a, "relation": "ally"}]

    bad = _app.post("/clans/diplomacy", headers=a["headers"],
                    json={"other_clan_id": clan_b, "relation": "besties"})
    assert bad.status_code == 400


# ---------------------------------------------------------------------------
# SQ1  squads
# ---------------------------------------------------------------------------
def test_squad_lifecycle(_app):
    leader = _new_player(_app)
    created = _app.post("/squads", headers=leader["headers"])
    assert created.status_code == 200, created.text
    squad_id = created.json()["squad_id"]

    member = _new_player(_app)
    assert _app.post("/squads/join", headers=member["headers"],
                     params={"squad_id": squad_id}).status_code == 200
    roster = _app.get("/squads/mine", headers=leader["headers"]).json()
    assert {m["player_id"] for m in roster["members"]} == {
        leader["player_id"], member["player_id"]}

    # A non-leader cannot kick.
    assert _app.post("/squads/kick", headers=member["headers"],
                     params={"player_id": leader["player_id"]}
                     ).status_code == 403
    # The leader can.
    assert _app.post("/squads/kick", headers=leader["headers"],
                     params={"player_id": member["player_id"]}
                     ).status_code == 200

    # One squad per player.
    assert _app.post("/squads",
                     headers=leader["headers"]).json().get("already") is True


def test_leaving_a_squad_promotes_a_new_leader(_app):
    leader = _new_player(_app)
    squad_id = _app.post("/squads",
                         headers=leader["headers"]).json()["squad_id"]
    member = _new_player(_app)
    _app.post("/squads/join", headers=member["headers"],
              params={"squad_id": squad_id})
    _app.post("/squads/leave", headers=leader["headers"])
    after = _app.get("/squads/mine", headers=member["headers"]).json()
    assert after["squad"]["leader_player_id"] == member["player_id"], after


# ---------------------------------------------------------------------------
# CH1-CH2  chat
# ---------------------------------------------------------------------------
def test_chat_is_persisted_and_rate_limited(_app):
    player = _new_player(_app)
    first = _app.post("/chat", headers=player["headers"],
                      json={"channel": "global_tr", "body": "merhaba"})
    assert first.status_code == 200, first.text
    assert first.json()["id"] > 0

    # The rate limiter is server-side and per player.
    too_fast = _app.post("/chat", headers=player["headers"],
                         json={"channel": "global_tr", "body": "spam"})
    assert too_fast.status_code == 429, too_fast.text

    history = _app.get("/chat/global_tr",
                       headers=player["headers"]).json()
    assert history["count"] >= 1
    assert history["messages"][-1]["body"] == "merhaba"
    assert history["messages"][-1]["sender"] == player["player_id"]


def test_chat_validates_channel_length_and_body(_app):
    player = _new_player(_app)
    assert _app.post("/chat", headers=player["headers"],
                     json={"channel": "made_up", "body": "hi"}
                     ).status_code == 400
    assert _app.post("/chat", headers=player["headers"],
                     json={"channel": "global_tr", "body": "  "}
                     ).status_code == 400
    assert _app.post("/chat", headers=player["headers"],
                     json={"channel": "global_tr", "body": "x" * 500}
                     ).status_code == 400
    assert _app.get("/chat/made_up",
                    headers=player["headers"]).status_code == 400


# ---------------------------------------------------------------------------
# S1  settings
# ---------------------------------------------------------------------------
def test_settings_round_trip(_app):
    player = _new_player(_app)
    before = _app.get("/settings", headers=player["headers"]).json()
    assert before["chat_channel"] == r67.CHAT_CHANNELS[0]

    resp = _app.put("/settings", headers=player["headers"],
                    json={"nickname": "  Pilot  ", "chat_channel": "global_en",
                          "show_damage": False})
    assert resp.status_code == 200, resp.text
    after = _app.get("/settings", headers=player["headers"]).json()
    assert after["nickname"] == "Pilot"
    assert after["chat_channel"] == "global_en"
    assert after["show_damage"] is False

    # An unknown channel is refused.
    bad = _app.put("/settings", headers=player["headers"],
                  json={"chat_channel": "nope"})
    assert bad.status_code == 400



# ---------------------------------------------------------------------------
# A1-A5  auction
# ---------------------------------------------------------------------------
async def _end_auction(db, auction_id):
    await db.execute("UPDATE auctions SET ends_at = 1 WHERE auction_id = ?",
                     (auction_id,))


def _list(client, headers, item_id="kalkan1", **kwargs):
    body = {"item_id": item_id, "currency": "PLT", "start_price": 500}
    body.update(kwargs)
    resp = client.post("/auctions", headers=headers, json=body)
    assert resp.status_code == 200, resp.text
    return resp.json()["auction_id"]


def test_auction_escrows_the_item(_app):
    seller = _new_player(_app)
    before = _echo(_app, seller)
    assert before["inventory"].get("kalkan1") == 1

    auction_id = _list(_app, seller["headers"], duration_seconds=3600)
    # The item left the inventory, so it cannot be sold or used twice.
    assert _echo(_app, seller)["inventory"].get("kalkan1", 0) == 0

    listed = _app.get("/auctions", headers=seller["headers"]).json()
    assert any(a["auction_id"] == auction_id for a in listed["auctions"])


def test_a_bid_escrows_the_funds_immediately(_app):
    seller = _new_player(_app)
    bidder = _new_player(_app)
    _grant_item(seller["player_id"], "kalkan1", 1)
    _grant_currency(bidder["player_id"], plt=10000)
    auction_id = _list(_app, seller["headers"], duration_seconds=3600)

    before = _echo(_app, bidder)
    resp = _app.post("/auctions/bid", headers=bidder["headers"],
                     json={"auction_id": auction_id, "amount": 1000})
    assert resp.status_code == 200, resp.text
    # Escrowed now, not at settlement time.
    assert _echo(_app, bidder)["plt"] == before["plt"] - 1000


def test_a_bid_below_the_minimum_is_refused(_app):
    seller = _new_player(_app)
    bidder = _new_player(_app)
    _grant_item(seller["player_id"], "kalkan1", 1)
    _grant_currency(bidder["player_id"], plt=10000)
    auction_id = _list(_app, seller["headers"])
    before = _echo(_app, bidder)

    resp = _app.post("/auctions/bid", headers=bidder["headers"],
                     json={"auction_id": auction_id, "amount": 100})
    assert resp.status_code == 400, resp.text
    assert resp.json()["detail"]["reason"] == "bid_too_low"
    assert _echo(_app, bidder)["plt"] == before["plt"], \
        "funds moved on a rejected bid"


def test_a_seller_cannot_bid_on_their_own_auction(_app):
    seller = _new_player(_app)
    _grant_item(seller["player_id"], "kalkan1", 1)
    _grant_currency(seller["player_id"], plt=10000)
    auction_id = _list(_app, seller["headers"])
    resp = _app.post("/auctions/bid", headers=seller["headers"],
                     json={"auction_id": auction_id, "amount": 1000})
    assert resp.status_code == 400, resp.text


def test_settlement_returns_an_unsold_item(_app):
    seller = _new_player(_app)
    before = _echo(_app, seller)
    auction_id = _list(_app, seller["headers"], duration_seconds=30)

    _db(lambda db: _end_auction(db, auction_id))
    settled = _app.post(f"/auctions/{auction_id}/settle",
                        headers=seller["headers"])
    assert settled.status_code == 200, settled.text
    assert settled.json()["returned"] is True
    # The escrowed item is back, so the inventory is exactly as it was.
    assert _echo(_app, seller)["inventory"].get("kalkan1") == \
        before["inventory"].get("kalkan1")

    # Settling again changes nothing.
    again = _app.post(f"/auctions/{auction_id}/settle",
                      headers=seller["headers"])
    assert again.json().get("already") is True


def test_settlement_pays_the_winner_exactly_once(_app):
    seller = _new_player(_app)
    bidder = _new_player(_app)
    _grant_item(seller["player_id"], "kalkan1", 1)
    _grant_currency(bidder["player_id"], plt=10000)
    auction_id = _list(_app, seller["headers"], duration_seconds=30)
    bidder_before = _echo(_app, bidder)
    assert _app.post("/auctions/bid", headers=bidder["headers"],
                     json={"auction_id": auction_id, "amount": 1000}
                     ).status_code == 200

    seller_before = _echo(_app, seller)
    _db(lambda db: _end_auction(db, auction_id))

    settled = _app.post(f"/auctions/{auction_id}/settle",
                        headers=seller["headers"])
    assert settled.status_code == 200, settled.text
    assert settled.json()["winner"] == bidder["player_id"]

    fee = 1000 * r67.AUCTION_FEE_PERCENT // 100
    after = _echo(_app, seller)
    assert after["plt"] == seller_before["plt"] + (1000 - fee)
    # The winner RECEIVES the item, so it is their baseline plus one.
    assert _echo(_app, bidder)["inventory"].get("kalkan1", 0) == \
        bidder_before["inventory"].get("kalkan1", 0) + 1

    _app.post(f"/auctions/{auction_id}/settle", headers=seller["headers"])
    assert _echo(_app, seller)["plt"] == after["plt"], "seller paid twice"


# ---------------------------------------------------------------------------
# EV1  server events
# ---------------------------------------------------------------------------
async def _activate_event(db, event_id):
    now = int(time.time())
    await db.execute(
        "INSERT OR REPLACE INTO server_events (event_id, name, map_id, state, "
        "starts_at, ends_at, reward_btc, reward_plt, reward_xp, reward_honor) "
        "VALUES (?, 'Raid', '1-1', 'active', ?, ?, 100, 200, 300, 50)",
        (event_id, now - 60, now + 3600),
    )


def test_event_join_and_reward_pays_once(_app):
    player = _new_player(_app)
    _db(lambda db: _activate_event(db, "ev_test_1"))

    before = _echo(_app, player)
    joined = _app.post("/events/join", headers=player["headers"],
                       json={"event_id": "ev_test_1"})
    assert joined.status_code == 200, joined.text

    reward = _app.post("/events/ev_test_1/reward", headers=player["headers"])
    assert reward.status_code == 200, reward.text
    after = _echo(_app, player)
    assert after["plt"] == before["plt"] + 200
    assert after["bitcoin"] == before["bitcoin"] + 100
    assert after["exp"] > before["exp"]

    twice = _app.post("/events/ev_test_1/reward", headers=player["headers"])
    assert twice.status_code == 409, twice.text
    assert _echo(_app, player)["plt"] == after["plt"], "reward paid twice"


def test_joining_a_stopped_event_is_refused(_app):
    player = _new_player(_app)

    async def seed(db):
        await db.execute(
            "INSERT OR REPLACE INTO server_events (event_id, name, map_id, "
            "state, starts_at, ends_at, reward_btc, reward_plt, reward_xp, "
            "reward_honor) VALUES ('ev_stopped', 'Old', '1-1', 'finished', "
            "1, 2, 0, 0, 0, 0)")
    _db(seed)
    resp = _app.post("/events/join", headers=player["headers"],
                     json={"event_id": "ev_stopped"})
    assert resp.status_code == 409, resp.text


# ---------------------------------------------------------------------------
# CA1-CA2  cargo
# ---------------------------------------------------------------------------
def test_cargo_deposit_and_withdraw_round_trip(_app):
    player = _new_player(_app)
    _grant_item(player["player_id"], "kalkan1", 2)
    before = _echo(_app, player)   # also refreshes the token
    owned = before["inventory"].get("kalkan1", 0)

    deposit = _app.post("/cargo/deposit", headers=player["headers"],
                        json={"item_id": "kalkan1", "quantity": 2})
    assert deposit.status_code == 200, deposit.text
    assert deposit.json()["cargo"]["items"]["kalkan1"] == 2
    # The inventory lost exactly what was deposited.
    assert _echo(_app, player)["inventory"].get("kalkan1", 0) == owned - 2

    withdraw = _app.post("/cargo/withdraw", headers=player["headers"],
                         json={"item_id": "kalkan1", "quantity": 1})
    assert withdraw.status_code == 200, withdraw.text
    assert withdraw.json()["cargo"]["items"]["kalkan1"] == 1
    assert _echo(_app, player)["inventory"].get("kalkan1", 0) == owned - 1


def test_cargo_refuses_more_than_capacity(_app):
    player = _new_player(_app)
    _grant_item(player["player_id"], "kalkan1", 1)
    before = _echo(_app, player)
    owned = before["inventory"].get("kalkan1", 0)

    async def shrink(db):
        # INSERT OR REPLACE rather than UPDATE: it works whether or not the row
        # exists yet, so the test does not depend on a prior /cargo read having
        # created it.
        await db.execute(
            "INSERT OR REPLACE INTO cargo (player_id, capacity, items, "
            "updated_at) VALUES (?, 0, '{}', 0)",
            (player["player_id"],),
        )
    _db(shrink)

    resp = _app.post("/cargo/deposit", headers=player["headers"],
                     json={"item_id": "kalkan1", "quantity": 1})
    assert resp.status_code == 409, resp.text
    assert resp.json()["detail"]["reason"] == "cargo_full"
    # The item was not consumed by the refused deposit.
    assert _echo(_app, player)["inventory"].get("kalkan1", 0) == owned


def test_cargo_withdraw_needs_the_item_stored(_app):
    player = _new_player(_app)
    _echo(_app, player)
    resp = _app.post("/cargo/withdraw", headers=player["headers"],
                     json={"item_id": "kalkan1", "quantity": 1})
    assert resp.status_code == 400, resp.text
    assert resp.json()["detail"]["reason"] == "not_stored"


def test_cargo_survives_a_relogin(_app):
    player = _new_player(_app)
    _grant_item(player["player_id"], "kalkan1", 1)
    _echo(_app, player)
    _app.post("/cargo/deposit", headers=player["headers"],
              json={"item_id": "kalkan1", "quantity": 1})

    # A fresh login reads the SERVER cargo, not a local file.
    _echo(_app, player)
    cargo = _app.get("/cargo", headers=player["headers"]).json()
    assert cargo["items"]["kalkan1"] == 1
    assert cargo["used"] == 1
    assert cargo["capacity"] == r67.CARGO_DEFAULT_CAPACITY
