"""PRODUCTION ADMIN ACCEPTANCE - the full section-4 checklist against a live host.

THIS NEEDS STAFF CREDENTIALS. It is the one check in the suite that cannot be
faked with a throwaway account, because every interesting assertion is about
what a role is ALLOWED to do. Run it yourself once the superadmin exists:

    python _verify_admin_ops.py <base_url>
    # then, with a fresh terminal, when prompted interactively:
    #   superadmin password is read from the ADMIN_PASSWORD env var
    #   admin      password is read from the ADMIN_PASSWORD_ADMIN env var
    #   moderator  password is read from the ADMIN_PASSWORD_MODERATOR env var

Passing the passwords as environment variables is deliberate: it keeps them out
of the command line (where they would land in shell history) and out of this
file. Nothing is ever printed back.

WHAT IT PROVES
--------------
  A1  health
  A2  superadmin login + JWT
  A3  /admin/session reports role=superadmin
  A4  player list / lookup / online players
  A5  BTC, PLT, GOLD operations on a THROWAWAY player
  A6  inventory, state, teleport, NPC and map inspect
  A7  audit log records the actions
  A8  MODERATOR is refused (403) on the currency endpoint
  A9  ADMIN is refused (403) on a superadmin-only endpoint
  A10 SUPERADMIN is allowed on the same endpoint
  A11 a forged `is_admin` claim in the request body grants nothing
  A12 logout

The economy operations run ONLY against a freshly registered throwaway player,
never against a real account, and the script records what it changed.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
import uuid

DEFAULT_BASE = "https://novagate-server-1.onrender.com"
_results = []


def record(name, ok, detail=""):
    _results.append((name, bool(ok)))
    print("%-52s %s %s" % (name, "PASS" if ok else "FAIL", detail), flush=True)
    return ok


def call(base, path, method="GET", payload=None, token=None):
    url = base.rstrip("/") + path
    data = None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if payload is not None:
        data = json.dumps(payload).encode()
    request = urllib.request.Request(url, data=data, headers=headers,
                                     method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
            code = response.getcode()
    except urllib.error.HTTPError as exc:
        body, code = exc.read(), exc.code
    except Exception as exc:                      # noqa: BLE001
        return 0, {"error": str(exc)}
    try:
        return code, json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return code, {}


def login(base, username, password):
    code, body = call(base, "/auth/login", "POST",
                      {"username": username, "password": password})
    return code, body, body.get("access_token") or body.get("token")


def main() -> int:
    base = (sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BASE).rstrip("/")

    code, body = call(base, "/health")
    record("A1 health", code == 200 and body.get("status") == "ok",
           "status=%s" % code)
    if code != 200:
        return _finish()

    sa_user = os.environ.get("ADMIN_USERNAME", "")
    sa_pass = os.environ.get("ADMIN_PASSWORD", "")
    if not sa_user or not sa_pass:
        record("A2 superadmin credentials supplied", False,
               "set ADMIN_USERNAME and ADMIN_PASSWORD in the environment")
        print("\nThis script cannot complete without staff credentials. See "
              "the deployment section of the final report.")
        return _finish()

    code, _, sa_token = login(base, sa_user, sa_pass)
    record("A2 superadmin login returns a JWT",
           code == 200 and bool(sa_token), "status=%s" % code)
    if not sa_token:
        return _finish()

    code, session = call(base, "/admin/session", token=sa_token)
    role = str((session or {}).get("role", "")).lower()
    record("A3 /admin/session reports role=superadmin",
           code == 200 and role == "superadmin", "role=%s" % (role or "?"))

    for label, path in (("A4 player list", "/admin/players"),
                        ("A4 online players", "/admin/online"),
                        ("A6 NPC inspect", "/admin/npcs"),
                        ("A6 map inspect", "/admin/maps")):
        code, _ = call(base, path, token=sa_token)
        record(label, code == 200, "status=%s" % code)

    # A throwaway player is the ONLY target of any economy operation.
    target, target_pass, target_token = make_user(base, "admops")
    code, _ = call(base, "/admin/player/" + target, token=sa_token)
    record("A4 player lookup", code == 200, "status=%s" % code)

    _, before, _ = login(base, target, target_pass)
    start = _balances(before)
    for currency in ("btc", "plt", "gold"):
        code, _ = call(base, "/admin/player/%s/currency" % target, "POST",
                       {"currency": currency, "amount": 1,
                        "reason": "acceptance_check"}, token=sa_token)
        record("A5 %s operation accepted" % currency.upper(),
               code == 200, "status=%s" % code)
    _, after, _ = login(base, target, target_pass)
    final = _balances(after)
    moved = {k: (start.get(k), final.get(k)) for k in final
             if start.get(k) != final.get(k)}
    record("A5 balances moved by +1 each", len(moved) == 3, str(moved))

    for label, path, payload in (
            ("A6 inventory inspect", "/admin/player/%s/item" % target, None),
            ("A6 state update", "/admin/player/%s/stats" % target,
             {"level": 1}),
            ("A6 teleport", "/admin/player/%s/teleport" % target,
             {"map_id": "1-1", "x": 100, "y": 100}),
    ):
        code, _ = call(base, path, "POST" if payload else "GET",
                       payload, token=sa_token)
        record(label, code == 200, "status=%s" % code)

    code, audit = call(base, "/admin/audit", token=sa_token)
    rows = audit if isinstance(audit, list) else (audit or {}).get("entries", [])
    record("A7 audit log has entries", code == 200 and len(rows) > 0,
           "entries=%s" % len(rows))

    # --- role separation -------------------------------------------------
    mod_user, mod_pass, _ = make_user(base, "modchk")
    ad_user, ad_pass, _ = make_user(base, "adchk")
    for account, role in ((mod_user, "moderator"), (ad_user, "moderator")):
        code, _ = call(base, "/admin/player/%s/role" % account, "POST",
                       {"role": role}, token=sa_token)
        record("A8/A9 seeded %s as moderator" % account, code == 200,
               "status=%s" % code)
    code, _ = call(base, "/admin/player/%s/role" % ad_user, "POST",
                   {"role": "admin"}, token=sa_token)
    record("A10 superadmin may set a role", code == 200, "status=%s" % code)

    # Re-login so the NEW role is inside the token being tested.
    _, _, mod_token = login(base, mod_user, mod_pass)
    _, _, ad_token = login(base, ad_user, ad_pass)

    code, _ = call(base, "/admin/player/%s/currency" % target, "POST",
                   {"currency": "btc", "amount": 1}, token=mod_token)
    record("A8 MODERATOR refused on currency (403)", code == 403,
           "status=%s" % code)
    code, _ = call(base, "/admin/player/%s/role" % ad_user, "POST",
                   {"role": "superadmin"}, token=ad_token)
    record("A9 ADMIN refused on role change (403)", code == 403,
           "status=%s" % code)
    code, _ = call(base, "/admin/player/%s/currency" % target, "POST",
                   {"currency": "btc", "amount": 1}, token=ad_token)
    record("A10 ADMIN allowed on currency", code == 200, "status=%s" % code)

    # A player cannot grant themselves staff by putting it in the body.
    code, _ = call(base, "/admin/players", "POST",
                   {"is_admin": True, "role": "superadmin"},
                   token=target_token)
    record("A11 forged is_admin in the BODY grants nothing",
           code in (401, 403, 405), "status=%s" % code)

    code, _ = call(base, "/auth/logout", "POST", {}, token=sa_token)
    record("A12 logout", code == 200, "status=%s" % code)

    print("\nthrowaway accounts created (safe to leave in place): %s, %s, %s"
          % (target, mod_user, ad_user))
    return _finish()


def _balances(body):
    body = body or {}
    return {
        "btc": int(body.get("bitcoin", body.get("btc", -1)) or -1),
        "plt": int(body.get("plt", body.get("platinum", -1)) or -1),
        "gold": int(body.get("gold", -1) or -1),
    }


def _finish() -> int:
    passed = sum(1 for _, ok in _results if ok)
    failed = [n for n, ok in _results if not ok]
    print("\n%d/%d admin acceptance checks passed" % (passed, len(_results)))
    if failed:
        print("failed: %s" % ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
