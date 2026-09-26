"""Prove the migration is safe on a database that looks like PRODUCTION.

A production database is not empty: it has years of players, balances and
inventory. This builds a fixture that models exactly that - the Phase 1 tables
ONLY (accounts, economy, inventory, transactions, sessions) with realistic rows
and no Phase 2-7 tables - then runs the migration against it and proves:

  1. Every required Phase 1-7 table is created.
  2. NOT ONE player value is lost or altered (BTC/PLT/GOLD/inventory).
  3. Running the migration a SECOND time changes nothing (idempotent).
  4. A backup is written before the real file is touched.

This is the check that would catch a destructive migration BEFORE it runs
against a live economy.

Usage:  python _db_migrate_selftest.py
"""
from __future__ import annotations

import glob
import os
import sqlite3
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import _db_migrate  # noqa: E402

WORKING = os.path.join(HERE, "_selftest_prod.db")
PLAYER_COUNT = 25

# Exactly the Phase 1 schema, with no Phase 2-7 tables. This is what a
# long-lived production database looks like before the new code deploys.
PHASE1_ONLY_SCHEMA = """
CREATE TABLE accounts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    username        TEXT UNIQUE NOT NULL,
    password_hash   TEXT NOT NULL,
    player_id       TEXT UNIQUE NOT NULL,
    nickname        TEXT,
    company         TEXT,
    role            TEXT DEFAULT 'player',
    created_at      INTEGER NOT NULL,
    starter_reward_claimed INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE sessions (
    id              TEXT PRIMARY KEY,
    account_id      INTEGER NOT NULL,
    player_id       TEXT NOT NULL,
    refresh_token   TEXT UNIQUE NOT NULL,
    refresh_jti     TEXT NOT NULL,
    created_at      INTEGER NOT NULL,
    last_seen       INTEGER NOT NULL,
    expires_at      INTEGER NOT NULL,
    active          INTEGER NOT NULL DEFAULT 1,
    ship_id         TEXT
);
CREATE TABLE economy (
    player_id       TEXT PRIMARY KEY,
    btc             INTEGER NOT NULL DEFAULT 0,
    plt             INTEGER NOT NULL DEFAULT 0,
    gold            INTEGER NOT NULL DEFAULT 0,
    updated_at      INTEGER NOT NULL
);
CREATE TABLE inventory (
    player_id       TEXT NOT NULL,
    item_id         TEXT NOT NULL,
    quantity        INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (player_id, item_id)
);
CREATE TABLE transactions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    player_id       TEXT NOT NULL,
    currency        TEXT NOT NULL,
    amount          INTEGER NOT NULL,
    reason          TEXT NOT NULL,
    timestamp       INTEGER NOT NULL
);
"""

failures = []


def check(name, ok, detail=""):
    print("%-48s %s %s" % (name, "PASS" if ok else "FAIL", detail))
    if not ok:
        failures.append(name)
    return ok


def _wipe():
    for path in glob.glob(WORKING + "*"):
        if os.path.isfile(path):
            os.remove(path)


def build_fixture() -> None:
    """Create a Phase 1-only database with realistic player data."""
    _wipe()
    now = int(time.time())
    connection = sqlite3.connect(WORKING)
    connection.executescript(PHASE1_ONLY_SCHEMA)
    for index in range(PLAYER_COUNT):
        username = "veteran_%02d" % index
        player_id = "vet%06d" % index
        items = {"lf1": 1 + index % 3, "kalkan1": 1, "hiz1": 1}
        connection.execute(
            "INSERT INTO accounts (username, password_hash, player_id, "
            "nickname, company, role, created_at, starter_reward_claimed) "
            "VALUES (?, 'x', ?, ?, ?, 'player', ?, 1)",
            (username, player_id, username,
             ["EIC", "MMO", "VRU"][index % 3], now - index * 86400))
        connection.execute(
            "INSERT INTO economy (player_id, btc, plt, gold, updated_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (player_id, 10000 + index * 137, 10000 + index * 91,
             index * 5, now))
        for item_id, quantity in items.items():
            connection.execute(
                "INSERT INTO inventory (player_id, item_id, quantity) "
                "VALUES (?, ?, ?)", (player_id, item_id, quantity))
        connection.execute(
            "INSERT INTO transactions (player_id, currency, amount, reason, "
            "timestamp) VALUES (?, 'BTC', ?, 'market_buy', ?)",
            (player_id, -40000, now - index * 3600))
        connection.execute(
            "INSERT INTO sessions (id, account_id, player_id, refresh_token, "
            "refresh_jti, created_at, last_seen, expires_at, active, ship_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 'Ship10')",
            ("sess%03d" % index, index + 1, player_id, "rt%03d" % index,
             "jti%03d" % index, now, now, now + 86400))
    connection.commit()
    connection.close()


def snapshot(db_path: str) -> dict:
    """Read every gameplay value we promise not to change."""
    connection = sqlite3.connect(db_path)
    try:
        out = {}
        for row in connection.execute(
                "SELECT player_id, btc, plt, gold FROM economy"):
            out[row[0]] = {"btc": row[1], "plt": row[2], "gold": row[3]}
        for row in connection.execute(
                "SELECT player_id, item_id, quantity FROM inventory"):
            entry = out.setdefault(row[0], {"btc": 0, "plt": 0, "gold": 0})
            entry.setdefault("inventory", {})[row[1]] = row[2]
        return out
    finally:
        connection.close()


def migrate(*args) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, os.path.join(HERE, "_db_migrate.py"),
         "--db", WORKING] + list(args),
        capture_output=True, text=True, timeout=300)


def main() -> int:
    print("=== building a Phase 1-only 'production' fixture ===")
    build_fixture()
    before = _db_migrate.read_state(WORKING)
    check("fixture has no Phase 2-7 tables",
          not [t for t in _db_migrate.REQUIRED_TABLES if t in before["tables"]],
          "%d tables total" % len(before["tables"]))
    check("fixture has %d veteran players" % PLAYER_COUNT,
          before["counts"].get("accounts") == PLAYER_COUNT)
    baseline = snapshot(WORKING)

    print("\n=== DRY RUN (must not modify the file) ===")
    result = migrate()
    check("dry run exit 0", result.returncode == 0, "rc=%d" % result.returncode)
    check("dry run reported OK", "DRY RUN OK" in result.stdout)
    check("dry run left player data untouched",
          snapshot(WORKING) == baseline)

    print("\n=== APPLY (backup first) ===")
    result = migrate("--apply")
    check("apply exit 0", result.returncode == 0, "rc=%d" % result.returncode)
    check("apply reported a backup", "backup written:" in result.stdout)

    after = _db_migrate.read_state(WORKING)
    missing = [t for t in _db_migrate.REQUIRED_TABLES
               if t not in after["tables"]]
    check("all %d required tables created" % len(_db_migrate.REQUIRED_TABLES),
          not missing, "missing=%s" % (missing or "none"))
    admin_missing = [t for t in _db_migrate.ADMIN_TABLES
                     if t not in after["tables"]]
    check("admin tables created", not admin_missing,
          "missing=%s" % (admin_missing or "none"))
    check("every BTC/PLT/GOLD/inventory value preserved",
          snapshot(WORKING) == baseline)
    check("accounts preserved",
          after["counts"].get("accounts") == PLAYER_COUNT)
    check("transaction history preserved",
          after["counts"].get("transactions") == PLAYER_COUNT)
    check("sessions preserved",
          after["counts"].get("sessions") == PLAYER_COUNT)

    print("\n=== IDEMPOTENCY (a second apply changes nothing) ===")
    counts_before = dict(after["counts"])
    result = migrate("--apply")
    check("second apply exit 0", result.returncode == 0)
    counts_after = _db_migrate.read_state(WORKING)["counts"]
    changed = {t: (counts_before.get(t), counts_after.get(t))
               for t in set(counts_before) | set(counts_after)
               if counts_before.get(t) != counts_after.get(t)}
    check("no row counts changed on re-run", not changed, str(changed))
    check("player data still identical", snapshot(WORKING) == baseline)

    print("\n=== BACKUP ARTIFACTS ===")
    backups = glob.glob(WORKING + ".backup-*")
    check("at least one backup written", bool(backups),
          "%d found" % len(backups))

    print("\n" + "=" * 62)
    if failures:
        print("MIGRATION SELFTEST FAILED: %s" % ", ".join(failures))
        return 1
    print("MIGRATION SELFTEST PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
