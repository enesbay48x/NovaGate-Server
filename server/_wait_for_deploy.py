"""Poll a deployed NovaGate server until it serves the CURRENT build.

WHY THIS EXISTS
---------------
The single most misleading state in a deploy is "the push succeeded". GitHub
having the commit says nothing about what Render is serving, and a Render
service that failed to build will happily keep answering /health from the
PREVIOUS build. Only the deployed OpenAPI document reveals which commit is
live.

So this watches for the specific evidence that the new build is serving:
  * the permission-gated admin routes exist
  * the legacy shadowing /admin/log route is GONE
It prints the route count and exits 0 the moment both hold, or exits 1 after
the timeout. It never reports success it did not observe.

Usage:
    python _wait_for_deploy.py [base_url] [timeout_seconds]
"""
from __future__ import annotations

import json
import sys
import time
import urllib.request

DEFAULT_BASE = "https://novagate-server-1.onrender.com"

# Routes that only exist in the new build. The currency route is the
# parameterised per-player one; there is no top-level `/admin/currency`,
# because every economy action is taken against a specific player.
REQUIRED_PREFIX = "/admin/players"
REQUIRED_EXACT = ["/admin/session", "/admin/dashboard", "/admin/audit",
                  "/admin/admins", "/admin/player/{identifier}/currency",
                  "/admin/player/{identifier}/teleport"]

# A legacy route that must NOT come back: it shadowed the permission-gated
# routes and bypassed the role check.
LEGACY = ["/admin/log"]


def fetch(base: str, path: str):
    url = base.rstrip("/") + path
    try:
        with urllib.request.urlopen(url, timeout=45) as response:
            return response.getcode(), response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except Exception as exc:                      # noqa: BLE001
        return 0, str(exc).encode()


def inspect(base: str) -> dict:
    status, body = fetch(base, "/openapi.json")
    state = {"openapi": status, "total": 0, "admin": 0,
             "missing": list(REQUIRED_EXACT), "legacy_present": False,
             "admin_present": False}
    if status != 200:
        return state
    try:
        paths = json.loads(body.decode("utf-8", "replace")).get("paths", {})
    except ValueError:
        return state
    state["total"] = len(paths)
    state["admin"] = len([p for p in paths if p.startswith("/admin")])
    state["admin_present"] = REQUIRED_PREFIX in paths
    state["missing"] = [p for p in REQUIRED_EXACT if p not in paths]
    state["legacy_present"] = any(p in paths for p in LEGACY)
    return state


def main() -> int:
    base = (sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BASE).rstrip("/")
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 1800
    deadline = time.time() + limit
    attempt = 0

    while True:
        attempt += 1
        state = inspect(base)
        ready = (state["admin_present"] and not state["missing"]
                 and not state["legacy_present"])
        print("[%3d] openapi=%s routes=%s admin=%s admin_present=%s "
              "missing=%s legacy_present=%s"
              % (attempt, state["openapi"], state["total"], state["admin"],
                 state["admin_present"], state["missing"] or "none",
                 state["legacy_present"]), flush=True)
        if ready:
            print("\nDEPLOYED: the new build is serving (%d routes, %d admin)"
                  % (state["total"], state["admin"]))
            return 0
        if time.time() >= deadline:
            print("\nNOT DEPLOYED after %d attempts / %ds. The service is still "
                  "serving the previous build." % (attempt, limit))
            print("A manual deploy is required in the Render dashboard.")
            return 1
        time.sleep(30)


if __name__ == "__main__":
    sys.exit(main())
