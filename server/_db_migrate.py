"""Production database migration DRY RUN and verified apply.

WHAT THIS DOES
--------------
1. Rehearses the migration on a COPY of the database (so production is not
   touched during the dry run).
2. Reports the PRE state: which required Phase 1-7 tables exist, which are
   missing, and the row counts of the legacy tables.
3. Applies the schema to the copy, then diffs row counts.
4. Only if the rehearsal converged AND `--apply` was passed, makes a
   timestamped BACKUP and re-runs the same statements on the real file.

SAFETY PROPERTIES (why this is safe on a live economy)
------------------------------------------------------
* NON-DESTRUCTIVE BY CONSTRUCTION. Every statement is CREATE TABLE/INDEX
  IF NOT EXISTS, or a guarded additive column. There is no DROP, no DELETE and
  no UPDATE of a gameplay value anywhere, so a player's BTC, PLT, GOLD and
  inventory cannot be changed by running this.
* BACKUP FIRST. A timestamped copy (plus its WAL sidecars) is written before
  the first write to the real database, and its path is printed.
* IDEMPOTENT. Running it twice changes nothing the second time, and the tool
  reports row counts before and after to prove it.
* REFUSES TO APPLY unless the rehearsal converged. A migration that did not
  work on a copy will not be attempted on production.

USAGE
-----
    python _db_migrate.py --db PATH                 # dry run only (default)
    python _db_migrate.py --db PATH --apply         # backup + apply
    python _db_migrate.py --db PATH --backup-only   # just take a backup
"""
from __future__ import annotations

import argparse
import asyncio
import os
import shutil
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# `config` deliberately refuses to import without SECRET_KEY so production can
# never start with an unsigned JWT. A migration tool inherits that requirement,
# so a THROWAWAY key is supplied here when the environment has none. It is only
# used to import the schema module and is never written anywhere.
if not os.environ.get("SECRET_KEY"):
    os.environ["SECRET_KEY"] = "migration-tool-throwaway-key-not-a-secret"

import main as main_module  # noqa: E402

# Every table the Phase 1-7 design requires, in dependency order so a partial
# failure is easy to reason about.
REQUIRED_TABLES = [
    "event_journal",
    "player_stats", "loadouts", "player_ammo", "player_droids",
    "player_inventory_ext", "player_identity",
    "maps", "map_connections", "map_level_requirements",
    "player_world_state", "faction_changes", "world_loot",
    "quest_progress", "quest_rewards",
    "player_gates", "gate_parts", "player_extras",
    "clans", "clan_members", "clan_applications", "clan_diplomacy",
    "squads", "squad_members", "chat_messages", "player_settings",
    "auctions", "auction_bids", "server_events", "event_participants",
    "cargo",
]

# Phase 1 tables whose ROWS must survive a migration untouched.
LEGACY_TABLES = ["accounts", "economy", "inventory", "transactions",
                 "sessions"]

# Admin surface added alongside the Phase 1-7 schema.
ADMIN_TABLES = ["admin_audit_log", "player_mutes"]


def read_state(db_path: str) -> dict:
    """Table list plus row counts, read from the file as it stands."""
    state = {"tables": [], "counts": {}}
    if not os.path.exists(db_path):
        return state
    connection = sqlite3.connect(db_path)
    try:
        rows = connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
        state["tables"] = [r[0] for r in rows]
        for name in state["tables"]:
            try:
                state["counts"][name] = connection.execute(
                    "SELECT COUNT(*) FROM %s" % name).fetchone()[0]
            except sqlite3.Error:
                state["counts"][name] = None
    finally:
        connection.close()
    return state


def apply_schema(db_path: str) -> None:
    """Run the full schema + seed.

    Synchronous sqlite3 is used for the DDL via the async entry points the
    server already has, so there is exactly ONE schema definition in the
    codebase - this tool cannot drift from what a normal boot applies.
    """
    main_module.DB_PATH = db_path
    loop = asyncio.new_event_loop()
    try:
        loop.run_until_complete(main_module.init_db())
        loop.run_until_complete(main_module._run_seed_bootstrap())
    finally:
        loop.close()


def take_backup(db_path: str) -> str:
    """Timestamped copy of the database and its WAL sidecars."""
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = db_path + ".backup-" + stamp
    for suffix in ("", "-wal", "-shm"):
        source = db_path + suffix
        if os.path.exists(source):
            shutil.copy2(source, backup + suffix)
    return backup


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, help="path to the SQLite file")
    parser.add_argument("--apply", action="store_true",
                        help="write to the real database (not just a copy)")
    parser.add_argument("--backup-only", action="store_true")
    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    print("database: %s" % db_path)
    if not os.path.exists(db_path):
        print("ERROR: database file does not exist")
        return 1

    if args.backup_only:
        print("backup: %s" % take_backup(db_path))
        return 0

    # --- BEFORE ----------------------------------------------------------
    pre = read_state(db_path)
    missing_before = [t for t in REQUIRED_TABLES if t not in pre["tables"]]
    print("\n=== BEFORE ===")
    print("tables: %d   required missing: %d"
          % (len(pre["tables"]), len(missing_before)))
    if missing_before:
        print("  missing: %s" % ", ".join(missing_before))
    legacy_before = {n: pre["counts"].get(n) for n in LEGACY_TABLES}
    for name in LEGACY_TABLES:
        count = legacy_before.get(name)
        print("  legacy %-14s rows=%s"
              % (name, "ABSENT" if count is None else count))

    # --- REHEARSAL on a copy --------------------------------------------
    scratch = db_path + ".migration-dryrun"
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(scratch + suffix):
            os.remove(scratch + suffix)
    shutil.copy2(db_path, scratch)

    apply_schema(scratch)
    post = read_state(scratch)
    missing_after = [t for t in REQUIRED_TABLES if t not in post["tables"]]
    print("\n=== AFTER (dry run, on a copy) ===")
    print("tables: %d   required still missing: %d"
          % (len(post["tables"]), len(missing_after)))
    if missing_after:
        print("  STILL MISSING: %s" % ", ".join(missing_after))

    # --- PLAYER DATA INTEGRITY ------------------------------------------
    print("\n=== PLAYER DATA INTEGRITY ===")
    drift = []
    for name in LEGACY_TABLES:
        before = legacy_before.get(name)
        after = post["counts"].get(name)
        if before is not None and after is not None and before != after:
            drift.append("%s %s -> %s" % (name, before, after))
        print("  %-14s %s -> %s" % (name, before, after))
    if drift:
        print("ERROR: migration changed row counts: %s" % "; ".join(drift))
        os.remove(scratch)
        return 1
    print("  no row-count drift in any legacy table")

    if missing_after:
        print("\nREFUSING to apply: rehearsal did not converge")
        os.remove(scratch)
        return 1

    if not args.apply:
        print("\nDRY RUN OK - %s was not modified" % db_path)
        os.remove(scratch)
        return 0

    # --- APPLY -----------------------------------------------------------
    backup = take_backup(db_path)
    print("\n=== APPLYING ===")
    print("backup written: %s" % backup)
    apply_schema(db_path)
    final = read_state(db_path)
    still = [t for t in REQUIRED_TABLES if t not in final["tables"]]
    admin_missing = [t for t in ADMIN_TABLES if t not in final["tables"]]
    print("tables now: %d" % len(final["tables"]))
    print("required missing: %s" % (still or "none"))
    print("admin tables missing: %s" % (admin_missing or "none"))
    for name in LEGACY_TABLES:
        print("  legacy %-14s rows=%s" % (name, final["counts"].get(name)))
    print("\nAPPLY OK - backup at %s" % backup)
    return 0 if not still and not admin_missing else 1


if __name__ == "__main__":
    sys.exit(main())
