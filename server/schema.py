"""Complete server-authoritative schema for NovaGate (Phases 2-7).

Every table is created with CREATE TABLE IF NOT EXISTS, so running this against
an existing database only ADDS what is missing. Existing rows are never touched:
no DROP, no DELETE, no column rewrite. Additive columns that a later phase
introduces go through ADDITIVE_COLUMNS, which swallows the "duplicate column"
error and is therefore safe to run on every boot.

Design rules
------------
* Every player-owned table is keyed by `player_id` (accounts.player_id), which
  is what the rest of the server already uses.
* Economy stays where it already lives (`economy`, `inventory`); these tables
  hold *state*, not money.
* No column here encodes a gameplay VALUE the client also owns.
"""

from __future__ import annotations

import aiosqlite

# ---------------------------------------------------------------------------
# Phase 1 - the server-authoritative Seyir Defteri
# ---------------------------------------------------------------------------
# Lives here so schema.py is the single owner of every table in the database.
# main.py's own CREATE TABLE IF NOT EXISTS is redundant but harmless; keeping
# both means an old database and a fresh one converge on the same shape.
PHASE1_JOURNAL_TABLE = """
-- One row per player-visible event. The client only ever renders these rows;
-- it never authors them.
CREATE TABLE IF NOT EXISTS event_journal (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    player_id       TEXT NOT NULL,
    event_type      TEXT NOT NULL,
    severity        TEXT NOT NULL DEFAULT 'info',
    message         TEXT NOT NULL,
    details         TEXT,
    acknowledged    INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_event_journal_player
    ON event_journal(player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_event_journal_type
    ON event_journal(event_type);
"""

# ---------------------------------------------------------------------------
# Phase 2 - player / combat / equipment authority
# ---------------------------------------------------------------------------
PHASE2_TABLES = """
-- Server-authoritative progression + combat counters.
CREATE TABLE IF NOT EXISTS player_stats (
    player_id       TEXT PRIMARY KEY,
    xp              INTEGER NOT NULL DEFAULT 0,
    honor           INTEGER NOT NULL DEFAULT 0,
    level           INTEGER NOT NULL DEFAULT 1,
    hp              REAL    NOT NULL DEFAULT 100,
    max_hp          REAL    NOT NULL DEFAULT 100,
    shield          REAL    NOT NULL DEFAULT 100,
    max_shield      REAL    NOT NULL DEFAULT 100,
    npc_kills       INTEGER NOT NULL DEFAULT 0,
    player_kills    INTEGER NOT NULL DEFAULT 0,
    deaths          INTEGER NOT NULL DEFAULT 0,
    missions_done   INTEGER NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL DEFAULT 0
);

-- Config 1 / Config 2 per ship. Slot lists are JSON arrays of canonical ids.
CREATE TABLE IF NOT EXISTS loadouts (
    player_id       TEXT NOT NULL,
    ship_id         TEXT NOT NULL,
    config_index    INTEGER NOT NULL,
    lasers          TEXT NOT NULL DEFAULT '[]',
    generators      TEXT NOT NULL DEFAULT '[]',
    extras          TEXT NOT NULL DEFAULT '[]',
    drone_slots     TEXT NOT NULL DEFAULT '[]',
    selected        INTEGER NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, ship_id, config_index)
);

-- Account-scoped ammo stock, keyed by the canonical ammo ids.
CREATE TABLE IF NOT EXISTS player_ammo (
    player_id       TEXT NOT NULL,
    ammo_id         TEXT NOT NULL,
    quantity        INTEGER NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, ammo_id)
);

-- Owned drones: type, laser slots and equipped ids.
CREATE TABLE IF NOT EXISTS player_droids (
    player_id       TEXT NOT NULL,
    drone_index     INTEGER NOT NULL,
    drone_type      TEXT NOT NULL DEFAULT 'PLUS',
    laser_slots     INTEGER NOT NULL DEFAULT 2,
    equipped        TEXT NOT NULL DEFAULT '[]',
    updated_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, drone_index)
);

-- Per-item metadata the base `inventory` table has no column for.
CREATE TABLE IF NOT EXISTS player_inventory_ext (
    player_id       TEXT NOT NULL,
    item_id         TEXT NOT NULL,
    equipped        INTEGER NOT NULL DEFAULT 0,
    slot_index      INTEGER NOT NULL DEFAULT -1,
    level_req       INTEGER NOT NULL DEFAULT 1,
    updated_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, item_id)
);
"""

# ---------------------------------------------------------------------------
# Phase 3 - maps / faction / identity
# ---------------------------------------------------------------------------
PHASE3_TABLES = """
-- The authoritative map registry. `map_id` values are the EXISTING NovaGate map
-- names; this table records them, it does not rename them.
CREATE TABLE IF NOT EXISTS maps (
    map_id          TEXT PRIMARY KEY,
    display_name    TEXT NOT NULL,
    company         TEXT NOT NULL DEFAULT '',
    min_level       INTEGER NOT NULL DEFAULT 1,
    is_pvp          INTEGER NOT NULL DEFAULT 0,
    is_hub          INTEGER NOT NULL DEFAULT 0,
    width           REAL NOT NULL DEFAULT 14000,
    height          REAL NOT NULL DEFAULT 10000,
    sort_order      INTEGER NOT NULL DEFAULT 0
);

-- Portal graph. `portal_id` is what the client asks to travel through; the
-- server decides whether it is allowed.
CREATE TABLE IF NOT EXISTS map_connections (
    portal_id       TEXT PRIMARY KEY,
    from_map        TEXT NOT NULL,
    to_map          TEXT NOT NULL,
    from_rect_x     REAL NOT NULL DEFAULT 0,
    from_rect_y     REAL NOT NULL DEFAULT 0,
    from_rect_w     REAL NOT NULL DEFAULT 0,
    from_rect_h     REAL NOT NULL DEFAULT 0,
    min_level       INTEGER NOT NULL DEFAULT 1,
    companies       TEXT NOT NULL DEFAULT '',
    sort_order      INTEGER NOT NULL DEFAULT 0
);

-- Explicit level gates, separate from maps.min_level so a gate can be tuned
-- without touching the map row.
CREATE TABLE IF NOT EXISTS map_level_requirements (
    map_id          TEXT NOT NULL,
    min_level       INTEGER NOT NULL DEFAULT 1,
    company         TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (map_id, company)
);

-- Where a player stands right now; survives a disconnect.
CREATE TABLE IF NOT EXISTS player_world_state (
    player_id       TEXT PRIMARY KEY,
    map_id          TEXT NOT NULL DEFAULT '1-1',
    position_x      REAL NOT NULL DEFAULT 0,
    position_y      REAL NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL DEFAULT 0
);

-- Server-authoritative identity extras.
CREATE TABLE IF NOT EXISTS player_identity (
    player_id       TEXT PRIMARY KEY,
    nickname        TEXT NOT NULL DEFAULT '',
    a_rank          INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL DEFAULT 0
);

-- Faction (company) change bookkeeping: cost, cooldown, honor penalty.
CREATE TABLE IF NOT EXISTS faction_changes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    player_id       TEXT NOT NULL,
    from_company    TEXT NOT NULL DEFAULT '',
    to_company      TEXT NOT NULL,
    cost_plt        INTEGER NOT NULL DEFAULT 0,
    honor_lost      INTEGER NOT NULL DEFAULT 0,
    created_at      INTEGER NOT NULL
);
"""

# ---------------------------------------------------------------------------
# Phase 4 - loot / quests / portals
# ---------------------------------------------------------------------------
PHASE4_TABLES = """
-- Server-spawned world loot. Empty `claimed_by` means still on the ground.
CREATE TABLE IF NOT EXISTS world_loot (
    loot_id         TEXT PRIMARY KEY,
    map_id          TEXT NOT NULL,
    item_id         TEXT NOT NULL DEFAULT '',
    quantity        INTEGER NOT NULL DEFAULT 0,
    btc             INTEGER NOT NULL DEFAULT 0,
    plt             INTEGER NOT NULL DEFAULT 0,
    xp              INTEGER NOT NULL DEFAULT 0,
    honor           INTEGER NOT NULL DEFAULT 0,
    is_bonus_box    INTEGER NOT NULL DEFAULT 0,
    position_x      REAL NOT NULL DEFAULT 0,
    position_y      REAL NOT NULL DEFAULT 0,
    spawned_at      INTEGER NOT NULL DEFAULT 0,
    expires_at      INTEGER NOT NULL DEFAULT 0,
    claimed_by      TEXT NOT NULL DEFAULT '',
    claimed_at      INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_world_loot_map
    ON world_loot(map_id, claimed_by);

-- Server-side quest progress: locked/active/completed/claimed.
CREATE TABLE IF NOT EXISTS quest_progress (
    player_id       TEXT NOT NULL,
    quest_id        TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'active',
    progress        INTEGER NOT NULL DEFAULT 0,
    target          INTEGER NOT NULL DEFAULT 1,
    completed_at    INTEGER NOT NULL DEFAULT 0,
    claimed_at      INTEGER NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, quest_id)
);

-- Idempotency ledger for quest rewards: one row per (player, quest).
CREATE TABLE IF NOT EXISTS quest_rewards (
    player_id       TEXT NOT NULL,
    quest_id        TEXT NOT NULL,
    btc             INTEGER NOT NULL DEFAULT 0,
    plt             INTEGER NOT NULL DEFAULT 0,
    xp              INTEGER NOT NULL DEFAULT 0,
    honor           INTEGER NOT NULL DEFAULT 0,
    granted_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, quest_id)
);
"""

# ---------------------------------------------------------------------------
# Phase 5 - galaxy gates / drones / extras
# ---------------------------------------------------------------------------
PHASE5_TABLES = """
-- Per-player Galaxy Gate progress. Parts is a JSON id->quantity object so the
-- definition can grow without a migration per new part.
CREATE TABLE IF NOT EXISTS player_gates (
    player_id       TEXT NOT NULL,
    gate_id         TEXT NOT NULL,
    parts           TEXT NOT NULL DEFAULT '{}',
    state           TEXT NOT NULL DEFAULT 'locked',
    completed_at    INTEGER NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, gate_id)
);

-- Static definition of a gate and the parts it needs.
CREATE TABLE IF NOT EXISTS gate_parts (
    gate_id         TEXT NOT NULL,
    part_id         TEXT NOT NULL,
    required        INTEGER NOT NULL DEFAULT 1,
    min_level       INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (gate_id, part_id)
);

-- Active extras/boosters with their server-side expiry.
CREATE TABLE IF NOT EXISTS player_extras (
    player_id       TEXT NOT NULL,
    extra_id        TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'owned',
    activated_at    INTEGER NOT NULL DEFAULT 0,
    expires_at      INTEGER NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (player_id, extra_id)
);
"""

# ---------------------------------------------------------------------------
# Phase 6 - clan / squad / chat / settings
# ---------------------------------------------------------------------------
PHASE6_TABLES = """
CREATE TABLE IF NOT EXISTS clans (
    clan_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    tag             TEXT NOT NULL DEFAULT '',
    owner_player_id TEXT NOT NULL,
    created_at      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS clan_members (
    clan_id         INTEGER NOT NULL,
    player_id       TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'member',
    rank            INTEGER NOT NULL DEFAULT 0,
    joined_at       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (clan_id, player_id)
);

CREATE TABLE IF NOT EXISTS clan_applications (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    clan_id         INTEGER NOT NULL,
    player_id       TEXT NOT NULL,
    message         TEXT NOT NULL DEFAULT '',
    state           TEXT NOT NULL DEFAULT 'pending',
    created_at      INTEGER NOT NULL DEFAULT 0,
    UNIQUE (clan_id, player_id)
);

CREATE TABLE IF NOT EXISTS clan_diplomacy (
    clan_id         INTEGER NOT NULL,
    other_clan_id   INTEGER NOT NULL,
    relation        TEXT NOT NULL DEFAULT 'neutral',
    updated_at      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (clan_id, other_clan_id)
);

CREATE TABLE IF NOT EXISTS squads (
    squad_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    leader_player_id TEXT NOT NULL,
    created_at      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS squad_members (
    squad_id        INTEGER NOT NULL,
    player_id       TEXT NOT NULL,
    joined_at       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (squad_id, player_id)
);

CREATE TABLE IF NOT EXISTS chat_messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel         TEXT NOT NULL,
    sender_player_id TEXT NOT NULL,
    sender_name     TEXT NOT NULL DEFAULT '',
    clan_id         INTEGER NOT NULL DEFAULT 0,
    squad_id        INTEGER NOT NULL DEFAULT 0,
    body            TEXT NOT NULL,
    created_at      INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_chat_channel
    ON chat_messages(channel, id DESC);

-- Only GAMEPLAY-affecting settings live here. Graphics/UI preferences stay in
-- the client on purpose (they are per-device, not per-account).
CREATE TABLE IF NOT EXISTS player_settings (
    player_id       TEXT PRIMARY KEY,
    nickname        TEXT NOT NULL DEFAULT '',
    chat_channel    TEXT NOT NULL DEFAULT 'global_tr',
    hud_visible     INTEGER NOT NULL DEFAULT 1,
    show_damage     INTEGER NOT NULL DEFAULT 1,
    updated_at      INTEGER NOT NULL DEFAULT 0
);
"""

# ---------------------------------------------------------------------------
# Phase 7 - auction / events / cargo
# ---------------------------------------------------------------------------
PHASE7_TABLES = """
CREATE TABLE IF NOT EXISTS auctions (
    auction_id      INTEGER PRIMARY KEY AUTOINCREMENT,
    seller_player_id TEXT NOT NULL,
    item_id         TEXT NOT NULL,
    quantity        INTEGER NOT NULL DEFAULT 1,
    currency        TEXT NOT NULL DEFAULT 'BTC',
    start_price     INTEGER NOT NULL DEFAULT 0,
    buyout_price    INTEGER NOT NULL DEFAULT 0,
    current_price   INTEGER NOT NULL DEFAULT 0,
    highest_bidder  TEXT NOT NULL DEFAULT '',
    state           TEXT NOT NULL DEFAULT 'open',
    created_at      INTEGER NOT NULL DEFAULT 0,
    ends_at         INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_auctions_state ON auctions(state, ends_at);

CREATE TABLE IF NOT EXISTS auction_bids (
    bid_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    auction_id      INTEGER NOT NULL,
    bidder_player_id TEXT NOT NULL,
    amount          INTEGER NOT NULL,
    created_at      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_auction_bids
    ON auction_bids(auction_id, amount DESC);

CREATE TABLE IF NOT EXISTS server_events (
    event_id        TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    map_id          TEXT NOT NULL DEFAULT '',
    state           TEXT NOT NULL DEFAULT 'scheduled',
    starts_at       INTEGER NOT NULL DEFAULT 0,
    ends_at         INTEGER NOT NULL DEFAULT 0,
    reward_btc      INTEGER NOT NULL DEFAULT 0,
    reward_plt      INTEGER NOT NULL DEFAULT 0,
    reward_xp       INTEGER NOT NULL DEFAULT 0,
    reward_honor    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS event_participants (
    event_id        TEXT NOT NULL,
    player_id       TEXT NOT NULL,
    score           INTEGER NOT NULL DEFAULT 0,
    joined_at       INTEGER NOT NULL DEFAULT 0,
    rewarded        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (event_id, player_id)
);

-- Persistent server storage; `capacity` mirrors the ship slot cap.
CREATE TABLE IF NOT EXISTS cargo (
    player_id       TEXT PRIMARY KEY,
    capacity        INTEGER NOT NULL DEFAULT 100,
    items           TEXT NOT NULL DEFAULT '{}',
    updated_at      INTEGER NOT NULL DEFAULT 0
);
"""

ALL_TABLES = (
    PHASE1_JOURNAL_TABLE
    + PHASE2_TABLES
    + PHASE3_TABLES
    + PHASE4_TABLES
    + PHASE5_TABLES
    + PHASE6_TABLES
    + PHASE7_TABLES
)

# ---------------------------------------------------------------------------
# Additive column migrations (idempotent by construction)
# ---------------------------------------------------------------------------
ADDITIVE_COLUMNS: list[tuple[str, str, str]] = [
    # (table, column, definition)
    ("event_journal", "acknowledged", "INTEGER NOT NULL DEFAULT 0"),
    ("accounts", "starter_reward_claimed", "INTEGER NOT NULL DEFAULT 0"),
    ("player_stats", "missions_done", "INTEGER NOT NULL DEFAULT 0"),
    ("player_gates", "completed_at", "INTEGER NOT NULL DEFAULT 0"),
    ("loadouts", "selected", "INTEGER NOT NULL DEFAULT 0"),
    ("world_loot", "claimed_by", "TEXT NOT NULL DEFAULT ''"),
    ("world_loot", "claimed_at", "INTEGER NOT NULL DEFAULT 0"),
    ("cargo", "capacity", "INTEGER NOT NULL DEFAULT 100"),
]


async def apply_schema(db: aiosqlite.Connection) -> None:
    """Create every missing table/index and add every missing column.

    Safe to call on every startup and on every test DB:
      * CREATE TABLE IF NOT EXISTS never touches an existing table
      * a duplicate-column ALTER raises, and is caught
    """
    await db.executescript(ALL_TABLES)
    for table, column, definition in ADDITIVE_COLUMNS:
        try:
            await db.execute(
                f"ALTER TABLE {table} ADD COLUMN {column} {definition}"
            )
        except aiosqlite.OperationalError:
            # "duplicate column name" (already migrated) or "no such table"
            # for a table that legitimately does not exist yet.
            pass
    await db.commit()



