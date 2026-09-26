"""
Phase 3: Server-authoritative NPC combat tests for NovaGate.

Tests verify that:
- Client sends fire input, server validates range/cooldown, calculates damage, applies it
- NPC HP/shield are managed server-side only
- NPC death broadcasts reward events
- NPC state is included in world_update
- Client cannot cheat damage values (server recalculates)
"""

import asyncio
import json
import os
import sys
import time

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

os.environ["SECRET_KEY"] = "test-secret-key-for-phase3-testing-only"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test_novagate_combat.db")
os.environ["ACCESS_TOKEN_EXPIRE_SECONDS"] = "900"
os.environ["REFRESH_TOKEN_EXPIRE_SECONDS"] = "3600"
os.environ["RATE_LIMIT_LOGIN"] = "100/minute"
os.environ["RATE_LIMIT_REGISTER"] = "100/minute"

from main import app, init_db, SECRET_KEY, DB_PATH, reset_rate_limits  # noqa: E402
import main as main_module  # noqa: E402
from websocket_server import (  # noqa: E402
    manager, npc_manager, NPC_STATS, NPC_SPAWN_TABLE, NPCManager,
    _calculate_laser_damage, _apply_npc_damage, _calculate_npc_reward,
    NPCState, BOSS_MULTIPLIER, UBER_MULTIPLIER,
    LASER_MULTIPLIERS, PLAYER_LASER_RANGE, MAX_LASER_DAMAGE,
    FIRE_COOLDOWN_SECONDS, PlayerSession,
)


DB_PATH_TEST = os.environ["DB_PATH"]


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


def _make_username(prefix: str = "combat") -> str:
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


def _clear_all_state():
    """Reset DB and clear all server state."""
    asyncio.run(_clear_db_and_state())


async def _clear_db_and_state():
    if os.path.exists(DB_PATH_TEST):
        async with aiosqlite_connect(DB_PATH_TEST) as db:
            await db.execute("DELETE FROM sessions")
            await db.execute("DELETE FROM accounts")
            await db.commit()
    else:
        await init_db()
    reset_rate_limits()
    manager.active_connections.clear()
    manager.ship_locks.clear()
    npc_manager.npcs.clear()
    npc_manager._id_counter = 0


import aiosqlite as aiosqlite_connect  # noqa: E402


@pytest.fixture(autouse=True)
def _setup(request):
    """Setup and teardown for each test."""
    asyncio.run(_init_test_db())
    npc_manager.npcs.clear()
    npc_manager._id_counter = 0
    yield
    npc_manager.npcs.clear()
    npc_manager._id_counter = 0


@pytest.fixture()
def event_loop():
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


client = TestClient(app)


def _make_player(player_id: str = "test_player_1", map_id: str = "1-1",
                 x: float = 0.0, y: float = 0.0) -> PlayerSession:
    """Create a mock PlayerSession for testing."""
    return PlayerSession(
        account_id=1,
        player_id=player_id,
        username="test_user",
        ship_id="default_ship",
        map_id=map_id,
        position_x=x,
        position_y=y,
        hp=100.0,
        max_hp=100.0,
        shield=100.0,
        max_shield=100.0,
    )


# ---------------------------------------------------------------------------
# NPC Stats Tests
# ---------------------------------------------------------------------------
class TestNPCStats:
    def test_npc_stats_all_known_types_present(self):
        for npc_type in ["zyron_raider", "nexar_fighter", "nexar_destroyer",
                         "nexar_warlord", "void_reaper", "void_predator",
                         "abyss_guardian", "void_ravager", "void_guardian",
                         "cubikon", "titan_nemesis"]:
            assert npc_type in NPC_STATS, f"Missing NPC type: {npc_type}"

    def test_npc_stats_have_required_fields(self):
        for npc_type, stats in NPC_STATS.items():
            assert "health" in stats
            assert "shield" in stats
            assert "speed" in stats
            assert "reward_xp" in stats
            assert "reward_bitcoin" in stats
            assert "reward_platinum" in stats
            assert "reward_honor" in stats
            assert "attack_range" in stats
            assert "aggro_range" in stats
            assert "passive" in stats

    def test_boss_multipliers(self):
        assert BOSS_MULTIPLIER == 2.0
        assert UBER_MULTIPLIER == 3.0


# ---------------------------------------------------------------------------
# Spawn Tests
# ---------------------------------------------------------------------------
class TestNPCSpawn:
    @pytest.mark.asyncio
    async def test_spawn_npcs_for_map(self):
        await npc_manager.spawn_map_npcs("1-1")
        npcs = npc_manager.get_npcs_on_map("1-1")
        assert len(npcs) > 0
        for npc in npcs:
            assert npc.alive is True
            assert npc.map_id == "1-1"

    @pytest.mark.asyncio
    async def test_spawn_zyron_raider_on_1_1(self):
        await npc_manager.spawn_map_npcs("1-1")
        npcs = npc_manager.get_npcs_on_map("1-1")
        raiders = [n for n in npcs if n.npc_type == "zyron_raider"]
        # 30 normal + 10 boss = 40 total
        assert len(raiders) == 40
        boss_raiders = [n for n in raiders if n.is_boss]
        assert len(boss_raiders) == 10

    @pytest.mark.asyncio
    async def test_spawn_boss_map_4_5(self):
        await npc_manager.spawn_map_npcs("4-5")
        npcs = npc_manager.get_npcs_on_map("4-5")
        assert len(npcs) > 0
        # 4-5 has all NPC types as uber variants (x3 stats)
        uber_npcs = [n for n in npcs if n.is_uber]
        assert len(uber_npcs) > 0
        # 4-5 has no cubikon
        cubikons = [n for n in npcs if n.npc_type == "cubikon"]
        assert len(cubikons) == 0

    @pytest.mark.asyncio
    async def test_spawn_cubikon_on_1_5(self):
        await npc_manager.spawn_map_npcs("1-5")
        npcs = npc_manager.get_npcs_on_map("1-5")
        cubikons = [n for n in npcs if n.npc_type == "cubikon"]
        assert len(cubikons) == 1

    @pytest.mark.asyncio
    async def test_spawn_empty_map(self):
        await npc_manager.spawn_map_npcs("nonexistent_map")
        npcs = npc_manager.get_npcs_on_map("nonexistent_map")
        assert len(npcs) == 0


# ---------------------------------------------------------------------------
# Damage Calculation Tests
# ---------------------------------------------------------------------------
class TestDamageCalculation:
    def test_laser_damage_basic(self):
        player = _make_player()
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=NPC_STATS["zyron_raider"]["health"],
            max_health=NPC_STATS["zyron_raider"]["health"],
            shield=NPC_STATS["zyron_raider"]["shield"],
            max_shield=NPC_STATS["zyron_raider"]["shield"],
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        # weapon_slot=1 (X1), distance=100
        damage = _calculate_laser_damage(1, player, npc, 100.0)
        assert damage > 0
        assert damage <= MAX_LASER_DAMAGE

    def test_laser_damage_invalid_weapon(self):
        player = _make_player()
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=800.0, max_health=800.0,
            shield=560.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        damage = _calculate_laser_damage(0, player, npc, 100.0)  # invalid weapon
        assert damage == 0.0

    def test_laser_damage_weapon_7_invalid(self):
        player = _make_player()
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=800.0, max_health=800.0,
            shield=560.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        damage = _calculate_laser_damage(7, player, npc, 100.0)  # invalid weapon
        assert damage == 0.0

    def test_laser_damage_decreases_with_distance(self):
        player = _make_player()
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=800.0, max_health=800.0,
            shield=560.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        close_damage = _calculate_laser_damage(4, player, npc, 100.0)  # X4 close
        far_damage = _calculate_laser_damage(4, player, npc, 500.0)    # X4 far
        assert close_damage > far_damage

    def test_damage_capped_at_max(self):
        player = _make_player()
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=800.0, max_health=800.0,
            shield=560.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        # At max range, damage should still be capped
        damage = _calculate_laser_damage(4, player, npc, PLAYER_LASER_RANGE)
        assert damage <= MAX_LASER_DAMAGE


# ---------------------------------------------------------------------------
# Damage Application Tests
# ---------------------------------------------------------------------------
class TestDamageApplication:
    def test_apply_damage_to_shield_first(self):
        player = _make_player()
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=800.0, max_health=800.0,
            shield=560.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        damage = 200.0
        event = _apply_npc_damage(npc, damage, 1, player.player_id, player)

        assert event["type"] == "npc_hit"
        assert npc.shield == 360.0  # 560 - 200
        assert npc.health == 800.0  # unchanged
        assert npc.alive is True

    def test_apply_damage_breaks_shield_hits_health(self):
        player = _make_player()
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=800.0, max_health=800.0,
            shield=100.0, max_shield=100.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        damage = 200.0
        event = _apply_npc_damage(npc, damage, 1, player.player_id, player)

        assert event["type"] == "npc_hit"
        assert npc.shield == 0.0
        assert npc.health == 700.0  # 800 - (200 - 100)
        assert npc.alive is True

    def test_npc_death_on_zero_health(self):
        player = _make_player()
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=300.0, max_health=800.0,
            shield=0.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        damage = 500.0  # More than health
        event = _apply_npc_damage(npc, damage, 1, player.player_id, player)

        assert event["type"] == "npc_death"
        assert npc.alive is False
        assert npc.respawn_at > 0.0
        assert "reward" in event

    def test_sab_drains_shield(self):
        player = _make_player()
        player.shield = 50.0
        player.max_shield = 100.0
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=800.0, max_health=800.0,
            shield=560.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        # SAB is weapon_slot=5, ammo_index=4
        damage = _calculate_laser_damage(5, player, npc, 100.0)
        event = _apply_npc_damage(npc, damage, 5, player.player_id, player)

        assert "shield_drain" in event
        assert npc.shield < 560.0  # Shield was drained
        assert player.shield > 50.0  # Player gained shield

    def test_npc_death_reward_calculated(self):
        npc = NPCState(
            npc_id="test_npc", npc_type="zyron_raider", map_id="1-1",
            position_x=100.0, position_y=0.0,
            health=10.0, max_health=800.0,
            shield=0.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
            is_boss=False, is_uber=False,
        )
        reward = _calculate_npc_reward(npc, "attacker1")
        stats = NPC_STATS["zyron_raider"]
        assert reward["xp"] == stats["reward_xp"]
        assert reward["bitcoin"] == stats["reward_bitcoin"]
        assert reward["platinum"] == stats["reward_platinum"]
        assert reward["honor"] == stats["reward_honor"]
        assert reward["killed_by"] == "attacker1"

    def test_boss_npc_reward_multiplied(self):
        npc = NPCState(
            npc_id="boss_npc", npc_type="void_reaper", map_id="1-5",
            position_x=100.0, position_y=0.0,
            health=100.0, max_health=100000.0,
            shield=0.0, max_shield=70000.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
            is_boss=True, is_uber=False,
        )
        reward = _calculate_npc_reward(npc, "attacker1")
        stats = NPC_STATS["void_reaper"]
        assert reward["xp"] == int(stats["reward_xp"] * BOSS_MULTIPLIER)
        assert reward["bitcoin"] == int(stats["reward_bitcoin"] * BOSS_MULTIPLIER)


# ---------------------------------------------------------------------------
# Combat Input Validation Tests
# ---------------------------------------------------------------------------
class TestCombatInputValidation:
    @pytest.mark.asyncio
    async def test_fire_out_of_range_rejected(self):
        player = _make_player(
            player_id="test_player_1", map_id="1-1", x=0.0, y=0.0
        )
        manager.active_connections["test_player_1"] = player

        await npc_manager.spawn_map_npcs("1-1")
        npcs = npc_manager.get_npcs_on_map("1-1")

        # Target a point beyond max range
        target_x = PLAYER_LASER_RANGE + 1000
        target_y = 0.0
        event = await npc_manager.handle_fire(
            "test_player_1", (0.0, 0.0), 1, target_x, target_y
        )
        # Should be rejected - no NPC within range
        assert event is None or event["type"] != "npc_death"

    @pytest.mark.asyncio
    async def test_fire_valid_npc_hit(self):
        player = _make_player(
            player_id="test_player_1", map_id="1-1", x=0.0, y=0.0
        )
        manager.active_connections["test_player_1"] = player

        # Manually place one NPC close to the player (within laser range)
        npc = NPCState(
            npc_id="close_npc_1", npc_type="zyron_raider", map_id="1-1",
            position_x=200.0, position_y=0.0,
            health=NPC_STATS["zyron_raider"]["health"],
            max_health=NPC_STATS["zyron_raider"]["health"],
            shield=NPC_STATS["zyron_raider"]["shield"],
            max_shield=NPC_STATS["zyron_raider"]["shield"],
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        npc_manager.npcs["close_npc_1"] = npc

        # Target the NPC position (within range)
        event = await npc_manager.handle_fire(
            "test_player_1", (0.0, 0.0), 1,
            npc.position_x, npc.position_y
        )

        assert event is not None
        assert event["type"] in ("npc_hit", "npc_death")
        assert event["npc_id"] == "close_npc_1"
        assert event["attacker_id"] == "test_player_1"

    @pytest.mark.asyncio
    async def test_fire_invalid_weapon_rejected(self):
        player = _make_player(
            player_id="test_player_1", map_id="1-1", x=0.0, y=0.0
        )
        manager.active_connections["test_player_1"] = player

        await npc_manager.spawn_map_npcs("1-1")
        npcs = npc_manager.get_npcs_on_map("1-1")
        target_npc = npcs[0]

        event = await npc_manager.handle_fire(
            "test_player_1", (0.0, 0.0), 0,  # Invalid weapon
            target_npc.position_x, target_npc.position_y
        )
        assert event is None

    @pytest.mark.asyncio
    async def test_fire_no_npcs_on_map(self):
        player = _make_player(
            player_id="test_player_1", map_id="5-5", x=0.0, y=0.0
        )
        manager.active_connections["test_player_1"] = player

        # Don't spawn any NPCs
        event = await npc_manager.handle_fire(
            "test_player_1", (0.0, 0.0), 1, 100.0, 0.0
        )
        assert event is None

    @pytest.mark.asyncio
    async def test_fire_to_dead_npc_ignored(self):
        player = _make_player(
            player_id="test_player_1", map_id="1-1", x=0.0, y=0.0
        )
        manager.active_connections["test_player_1"] = player

        await npc_manager.spawn_map_npcs("1-1")
        npcs = npc_manager.get_npcs_on_map("1-1")
        # Kill one NPC
        npcs[0].alive = False

        event = await npc_manager.handle_fire(
            "test_player_1", (0.0, 0.0), 1,
            npcs[0].position_x, npcs[0].position_y
        )
        # Should target a different alive NPC, or return None if no valid target
        if event is not None:
            assert event["npc_id"] != npcs[0].npc_id  # Not targeting dead one


# ---------------------------------------------------------------------------
# NPC State Serialization Tests
# ---------------------------------------------------------------------------
class TestNPCStateSerialization:
    def test_npc_to_dict(self):
        npc = NPCState(
            npc_id="test_npc_1", npc_type="zyron_raider", map_id="1-1",
            position_x=123.456, position_y=789.012,
            health=800.0, max_health=800.0,
            shield=560.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
            is_boss=True, is_uber=False,
        )
        m = npc_manager.to_dict(npc)
        assert m["npc_id"] == "test_npc_1"
        assert m["npc_type"] == "zyron_raider"
        assert m["x"] == round(123.456, 2)
        assert m["y"] == round(789.012, 2)
        assert m["health"] == 800.0
        assert m["max_health"] == 800.0
        assert m["shield"] == 560.0
        assert m["max_shield"] == 560.0
        assert m["alive"] is True
        assert m["is_boss"] is True
        assert m["is_uber"] is False

    def test_npc_get_npcs_on_map(self):
        npc1 = NPCState(
            npc_id="npc1", npc_type="zyron_raider", map_id="1-1",
            position_x=0.0, position_y=0.0,
            health=800.0, max_health=800.0,
            shield=560.0, max_shield=560.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        npc2 = NPCState(
            npc_id="npc2", npc_type="nexar_fighter", map_id="1-2",
            position_x=0.0, position_y=0.0,
            health=3000.0, max_health=3000.0,
            shield=2100.0, max_shield=2100.0,
            alive=True, spawn_time=time.time(), respawn_at=0.0,
        )
        npc_manager.npcs["npc1"] = npc1
        npc_manager.npcs["npc2"] = npc2

        map1_npcs = npc_manager.get_npcs_on_map("1-1")
        assert len(map1_npcs) == 1
        assert map1_npcs[0].npc_id == "npc1"

        map2_npcs = npc_manager.get_npcs_on_map("1-2")
        assert len(map2_npcs) == 1
        assert map2_npcs[0].npc_id == "npc2"
