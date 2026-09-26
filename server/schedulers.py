"""Background schedulers: auction settlement and server-event lifecycle.

Why a background task rather than a lazy sweep inside a request
-----------------------------------------------------------------
A lazy sweep only runs when a player happens to do something, so an auction
that expires at 03:00 settles whenever the first player logs in at 09:00 - and
never at all on a quiet server. A real settlement needs its own clock.

Restart safety
--------------
Both schedulers are REBUILDABLE FROM THE DATABASE, not from memory:

* `settle_expired_auctions` reads `state='open' AND ends_at <= now` on every
  pass, so anything missed while the process was down is picked up on the first
  tick after boot.
* `sync_event_states` derives each event's live state from its stored
  `starts_at` / `ends_at` rather than trusting a cached flag.

That is what makes a deploy (Render restarts regularly) safe.

Single-winner settlement
------------------------
Settlement is a CONDITIONAL UPDATE (`WHERE auction_id = ? AND state = 'open'`)
and every side effect happens only when that UPDATE affected a row. Two passes
racing, or a pass overlapping the admin force-settle endpoint, therefore produce
exactly one payment: the loser sees rowcount 0 and changes nothing.
"""

from __future__ import annotations

import asyncio
import time
from typing import Optional

import aiosqlite

import journal

# How often each loop runs. Both are deliberately slow: they are background
# maintenance, not gameplay, and a 5-second cadence is far finer than any
# auction duration or event boundary the game uses.
AUCTION_SWEEP_SECONDS = 5.0
EVENT_SYNC_SECONDS = 10.0


def _now() -> int:
    return int(time.time())


# ---------------------------------------------------------------------------
# Auction settlement
# ---------------------------------------------------------------------------
async def settle_expired_auctions(db_path: str, limit: int = 20) -> list:
    """Settle every open auction whose end time has passed.

    Returns the settled auction ids. Safe to call concurrently with itself and
    with the admin force-settle endpoint: the `state='open'` guard makes
    settlement a single-winner operation.
    """
    settled: list = []
    now = _now()
    async with aiosqlite.connect(db_path) as db:
        cursor = await db.execute(
            "SELECT auction_id FROM auctions WHERE state = 'open' "
            "AND ends_at <= ? ORDER BY ends_at LIMIT ?",
            (now, int(limit)),
        )
        candidates = [int(r[0]) for r in await cursor.fetchall()]
        for auction_id in candidates:
            if await settle_one_auction(db, auction_id) is not None:
                settled.append(auction_id)
    return settled


async def settle_one_auction(db: aiosqlite.Connection,
                             auction_id: int) -> Optional[int]:
    """Settle one auction. Returns the auction_id on success, None if skipped.

    This is the same code path the admin "force settle" endpoint calls, so
    there is exactly one settlement implementation to reason about.
    """
    from routes_p45 import _grant_currency, _grant_item
    from routes_p67 import AUCTION_FEE_PERCENT

    cursor = await db.execute(
        "SELECT seller_player_id, item_id, quantity, currency, current_price, "
        "highest_bidder, state, ends_at FROM auctions WHERE auction_id = ?",
        (auction_id,),
    )
    row = await cursor.fetchone()
    if row is None or row[6] != "open":
        return None

    # --- the single-winner transition ------------------------------------
    cursor = await db.execute(
        "UPDATE auctions SET state = 'settled' WHERE auction_id = ? "
        "AND state = 'open'",
        (auction_id,),
    )
    # An UPDATE returns no rows; the affected count is `rowcount`.
    if cursor.rowcount == 0:
        return None

    seller, item_id, quantity = str(row[0]), str(row[1]), int(row[2])
    currency, price, winner = str(row[3]), int(row[4]), str(row[5])

    if not winner or price <= 0:
        # Nothing was bid: the escrowed item returns to the seller.
        await _grant_item(db, seller, item_id, quantity)
        await db.commit()
        return auction_id

    # Refund a bidder who was out-bid BEFORE paying the winner, so the
    # escrowed funds are conserved.
    await _refund_outbid(db, auction_id, winner, currency)
    fee = price * int(AUCTION_FEE_PERCENT) // 100
    await _grant_currency(db, seller, currency=currency, amount=price - fee)
    await _grant_item(db, winner, item_id, quantity)
    for party in (winner, seller):
        await journal.record_event(
            db, party, journal.EVENT_AUCTION,
            f"Auctions kapandi: {item_id}", journal.SEVERITY_INFO,
            {"auction_id": auction_id, "price": price, "winner": winner,
             "seller": seller},
        )
    await db.commit()
    return auction_id


async def _refund_outbid(db, auction_id: int, winner: str,
                         currency: str) -> None:
    """Return the escrow of every bidder who did not win, once each."""
    from routes_p45 import _grant_currency
    cursor = await db.execute(
        "SELECT bidder_player_id, SUM(amount) FROM auction_bids "
        "WHERE auction_id = ? AND bidder_player_id != ? GROUP BY bidder_player_id",
        (auction_id, winner),
    )
    for bidder, total in await cursor.fetchall():
        await _grant_currency(db, str(bidder), currency=currency,
                              amount=int(total), reason="auction_refund")


# ---------------------------------------------------------------------------
# Server-event lifecycle
# ---------------------------------------------------------------------------
# An event's live state is DERIVED from its stored window rather than cached, so
# a restart cannot leave an event stuck "active" forever. `state` in the table
# is only ever an override for an admin-cancelled event.
EVENT_STATE_SCHEDULED = "scheduled"
EVENT_STATE_ACTIVE = "active"
EVENT_STATE_FINISHED = "finished"
EVENT_STATE_CANCELLED = "cancelled"


def derived_event_state(row, now: int) -> str:
    """The state an event should be in, given its window and any override."""
    stored = str(row[3] or EVENT_STATE_SCHEDULED)
    if stored == EVENT_STATE_CANCELLED:
        return EVENT_STATE_CANCELLED
    starts_at, ends_at = int(row[1]), int(row[2])
    if ends_at and now >= ends_at:
        return EVENT_STATE_FINISHED
    if starts_at and now >= starts_at:
        return EVENT_STATE_ACTIVE
    return EVENT_STATE_SCHEDULED


async def sync_event_states(db_path: str) -> dict:
    """Advance every event to the state its window implies.

    Restart-safe by construction: the next pass recomputes from `starts_at` /
    `ends_at`, so an event that ran while the process was down is closed on
    the first tick after boot rather than lingering.
    """
    now = _now()
    changed = {"activated": [], "finished": []}
    async with aiosqlite.connect(db_path) as db:
        cursor = await db.execute(
            "SELECT event_id, starts_at, ends_at, state FROM server_events")
        for row in await cursor.fetchall():
            target = derived_event_state(row, now)
            if target == str(row[3]):
                continue
            await db.execute(
                "UPDATE server_events SET state = ? WHERE event_id = ? "
                "AND state != ?",
                (target, str(row[0]), str(row[3])),
            )
            if target == EVENT_STATE_ACTIVE:
                changed["activated"].append(str(row[0]))
            elif target == EVENT_STATE_FINISHED:
                changed["finished"].append(str(row[0]))
        await db.commit()
    return changed


# ---------------------------------------------------------------------------
# Task loops
# ---------------------------------------------------------------------------
# One loop for both sweeps rather than two: they are both cheap, a single task
# is one less thing to start/stop cleanly, and a shared 5-second cadence is
# finer than either domain needs.
class SchedulerHub:
    """Owns the background maintenance task and its lifecycle.

    Exposed as a module-level singleton (`hub`) so main.py's startup can start
    it and a test can await a single sweep through `run_once()` without any
    background timing at all.
    """

    def __init__(self) -> None:
        self._task: Optional[asyncio.Task] = None
        self.db_path: str = ""
        self.tick_count: int = 0
        self.last_error: str = ""
        self.sweep_count: int = 0

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    async def start(self, db_path: str) -> None:
        self.db_path = db_path
        if self.running:
            return
        # Catch up on anything that expired while the process was down BEFORE
        # entering the loop, so a restart settles immediately rather than
        # waiting a full interval.
        await self.run_once()
        self._task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        task, self._task = self._task, None
        if task is None:
            return
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass

    async def run_once(self) -> dict:
        """One pass of both sweeps. Returns what changed.

        Exposed for tests: a deterministic, explicitly-awaited sweep beats
        sleeping and hoping a background loop has fired.
        """
        result = {"settled": [], "activated": [], "finished": []}
        if not self.db_path:
            return result
        self.tick_count += 1
        self.sweep_count += 1
        try:
            result["settled"] = await settle_expired_auctions(self.db_path)
            events = await sync_event_states(self.db_path)
            result["activated"] = events["activated"]
            result["finished"] = events["finished"]
            self.last_error = ""
        except Exception as exc:  # pragma: no cover - defensive
            # A failed sweep must never kill the loop: the next pass retries
            # from the database, so nothing is lost.
            self.last_error = f"{type(exc).__name__}: {exc}"
            print(f"[NOVAGATE] scheduler sweep failed: {self.last_error}",
                  flush=True)
        return result

    async def _loop(self) -> None:
        while True:
            await asyncio.sleep(AUCTION_SWEEP_SECONDS)
            try:
                await self.run_once()
            except Exception as exc:  # pragma: no cover - defensive
                self.last_error = f"{type(exc).__name__}: {exc}"
                print(f"[NOVAGATE] scheduler loop error: {self.last_error}",
                      flush=True)


hub = SchedulerHub()


