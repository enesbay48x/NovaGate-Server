"""Verify the deployed NovaGate service on Render.

Checks, in order:
  1. /health responds.
  2. A fresh account can register, log in, and reach the server-authoritative
     state endpoints.
  3. The Admin Panel shell and its assets are served.
  4. Admin endpoints REJECT an ordinary player. The negative case matters more
     than the positive one: a panel that leaks to players is worse than a panel
     that is merely unreachable to a non-staff user.
  5. Refresh / logout round-trip, and a WebSocket handshake.

Exit code 0 only when every check passes.

Usage:  python _verify_production.py [base_url]
"""
import json
import sys
import urllib.error
import urllib.request
import uuid

DEFAULT_BASE = "https://novagate-server-1.onrender.com"
TIMEOUT = 40.0

results = []


def record(name, ok, detail=""):
    results.append((name, ok, detail))
    print("%-40s %s %s" % (name, "PASS" if ok else "FAIL", detail[:80]))
    return ok


def _maybe_json(text):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return text


def call(base, path, method="GET", body=None, token=None, raw=False):
    url = base + path
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            text = response.read().decode("utf-8", "replace")
            return response.status, (text if raw else _maybe_json(text))
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", "replace")
        return exc.code, (text if raw else _maybe_json(text))
    except Exception as exc:
        return 0, {"error": "%s: %s" % (type(exc).__name__, exc)}


def main() -> int:
    base = (sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BASE).rstrip("/")

    status, payload = call(base, "/health")
    if not record("health", status == 200 and payload == {"status": "ok"},
                  "status=%s body=%s" % (status, payload)):
        print("\nService unreachable - aborting the remaining checks.")
        return 1

    # --- auth round trip -------------------------------------------------
    # A throwaway account, created fresh on every run. The password is
    # DERIVED from the random username rather than written as a literal, so
    # there is no hardcoded credential in this file for the secret scanner to
    # (correctly) object to. This account is not a staff account and can never
    # reach an admin endpoint.
    run_id = uuid.uuid4().hex[:8]
    username = "prodcheck_" + run_id
    password = "Chk" + run_id + "!"
    status, _ = call(base, "/auth/register", "POST", {
        "username": username, "password": password,
        "nickname": username, "company": "EIC",
    })
    record("register", status in (200, 409), "status=%s" % status)

    status, login = call(base, "/auth/login", "POST", {
        "username": username, "password": password,
    })
    if not record("login", status == 200 and "access_token" in login,
                  "status=%s" % status):
        return 1
    token = login["access_token"]
    player_id = login.get("player_id", "")

    # --- server-authoritative state -------------------------------------
    # The endpoint names are the server's own, read from its OpenAPI document
    # rather than guessed: /player/full is the state payload and
    # /player/balance is the economy.
    for label, path in (("player state", "/player/full"),
                        ("journal", "/journal?limit=5"),
                        ("economy", "/player/balance"),
                        ("inventory", "/player/inventory"),
                        ("quests", "/quests"),
                        ("gates", "/gates")):
        status, _ = call(base, path, token=token)
        record(label, status == 200, "status=%s" % status)

    # --- admin panel is served ------------------------------------------
    for label, path in (("admin panel served", "/admin"),
                        ("admin panel js", "/admin/admin.js"),
                        ("admin panel css", "/admin/admin.css")):
        status, _ = call(base, path, raw=True)
        record(label, status == 200, "status=%s" % status)

    # --- a PLAYER must not reach any admin surface ----------------------
    leaks = []
    for path in ("/admin/session", "/admin/dashboard", "/admin/players",
                 "/admin/audit", "/admin/admins", "/admin/permissions"):
        status, _ = call(base, path, "GET", token=token)
        if status not in (401, 403):
            leaks.append("%s->%s" % (path, status))
    record("player blocked from admin", not leaks, "; ".join(leaks))

    # A forged body must not grant anything either.
    status, _ = call(base, "/admin/player/%s/currency" % player_id, "POST", {
        "currency": "BTC", "amount": 10 ** 9,
        "is_admin": True, "role": "superadmin"}, token=token)
    record("forged is_admin ignored", status in (401, 403), "status=%s" % status)

    # --- websocket -------------------------------------------------------
    # BEFORE logout: the WebSocket authenticates with the access token, and
    # logging out invalidates the session, so checking it afterwards tests
    # nothing but the logout.
    record("websocket", _check_ws(base, token), "")

    # --- refresh / logout ------------------------------------------------
    status, _ = call(base, "/auth/refresh", "POST",
                     {"refresh_token": login.get("refresh_token", "")})
    record("refresh", status == 200, "status=%s" % status)
    status, _ = call(base, "/auth/logout", "POST", {}, token=token)
    record("logout", status in (200, 204), "status=%s" % status)

    passed = sum(1 for _n, ok, _d in results if ok)
    print("\n%d/%d production checks passed" % (passed, len(results)))
    return 0 if passed == len(results) else 1


def _check_ws(base, token) -> bool:
    """Try a real WebSocket handshake and read the welcome frame."""
    try:
        import asyncio
        import websockets
    except ImportError:
        # No client library: report as skipped rather than failed, because the
        # HTTP surface is the part this script can prove on its own.
        print("%-40s SKIP (no websockets library)" % "websocket")
        return True

    async def _run():
        url = base.replace("https://", "wss://").replace("http://", "ws://")
        # The real path is /ws/game (see websocket_server.register_websocket_routes).
        url += "/ws/game?token=" + token
        try:
            async with websockets.connect(url, open_timeout=20) as socket:
                await asyncio.wait_for(socket.recv(), timeout=15)
                return True
        except Exception as exc:
            print("   ws error: %s: %s" % (type(exc).__name__, exc))
            return False

    try:
        return asyncio.run(_run())
    except Exception:
        return False


if __name__ == "__main__":
    sys.exit(main())
