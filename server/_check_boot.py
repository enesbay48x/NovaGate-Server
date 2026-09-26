"""Boot the real FastAPI app on a scratch DB and list the registered routes.

Catches import-time and route-registration errors that a pure `ast.parse`
cannot see (a bad decorator, a name error in a default argument, a duplicate
operation id).
"""
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ["SECRET_KEY"] = "phase2-boot-secret-key-0123456789abcdef"
os.environ["DB_PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "test_novagate_p2_boot.db")
os.environ["RATE_LIMIT_LOGIN"] = "500/minute"
os.environ["RATE_LIMIT_REGISTER"] = "500/minute"

import asyncio  # noqa: E402

REQUIRED_ROUTES = [
    # Phase 2
    ("GET", "/player/stats"), ("POST", "/player/vitals"),
    ("GET", "/loadouts"), ("PUT", "/loadouts"), ("POST", "/loadouts/select"),
    ("GET", "/equipment/stats"), ("GET", "/ammo"), ("POST", "/ammo"),
    ("GET", "/drones"), ("PUT", "/drones"),
    # Phase 3
    ("POST", "/account/faction"), ("GET", "/maps"), ("POST", "/map/move"),
    ("POST", "/portal/travel"), ("GET", "/world/online"), ("GET", "/ranking"),
    ("GET", "/account/nickname"), ("PUT", "/account/nickname"),
    # Phase 4
    ("GET", "/loot/{map_id}"), ("POST", "/loot/spawn"), ("POST", "/loot/claim"),
    ("GET", "/quests"), ("POST", "/quests/accept"), ("POST", "/quests/claim"),
    # Phase 5
    ("GET", "/gates"), ("POST", "/gates/contribute"),
    ("GET", "/extras"), ("POST", "/extras/activate"),
    # Phase 6
    ("POST", "/clans"), ("GET", "/clans/mine"), ("POST", "/clans/apply"),
    ("GET", "/clans/applications"), ("POST", "/clans/applications/review"),
    ("POST", "/clans/leave"), ("POST", "/clans/diplomacy"),
    ("POST", "/squads"), ("GET", "/squads/mine"), ("POST", "/squads/join"),
    ("POST", "/squads/leave"), ("POST", "/squads/kick"),
    ("GET", "/chat/{channel}"), ("POST", "/chat"),
    ("GET", "/settings"), ("PUT", "/settings"),
    # Phase 7
    ("GET", "/auctions"), ("POST", "/auctions"), ("POST", "/auctions/bid"),
    ("GET", "/cargo"), ("POST", "/cargo/deposit"), ("POST", "/cargo/withdraw"),
    ("GET", "/events"), ("POST", "/events/join"),
    # Phase 1 must still be there
    ("GET", "/journal"), ("POST", "/journal/ack"),
]


def main() -> int:
    if os.path.exists(os.environ["DB_PATH"]):
        os.remove(os.environ["DB_PATH"])
    try:
        from main import app, init_db
    except Exception:
        traceback.print_exc()
        print("FAIL: importing main raised")
        return 1

    try:
        asyncio.run(init_db())
    except Exception:
        traceback.print_exc()
        print("FAIL: init_db raised")
        return 1

    present = set()
    for route in app.routes:
        path = getattr(route, "path", "")
        for method in getattr(route, "methods", []) or []:
            present.add((method, path))

    missing = [r for r in REQUIRED_ROUTES if r not in present]
    if missing:
        print("FAIL: missing routes")
        for method, path in missing:
            print("  -", method, path)
        return 1

    print(f"OK  app booted, {len(present)} method+path routes, "
          f"{len(REQUIRED_ROUTES)} required routes present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
