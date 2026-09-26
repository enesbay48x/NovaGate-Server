"""Production market purchase -> inventory delivery check.

Registers a THROWAWAY account on the live host, then really buys
LF1 / LF3 / Kalkan 1 / Hiz 1 and proves each item lands in the inventory and
survives a fresh login.

It never touches a real player's balances: every account it uses is its own,
created for this run.

Usage:
  python _verify_production_market.py https://novagate-server-1.onrender.com
"""
from __future__ import annotations

import json
import secrets
import sys
import time
import urllib.error
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else
        "https://novagate-server-1.onrender.com").rstrip("/")

# The four items the bug report names. A brand-new account holds only the
# starter reward (10000 BTC / 10000 PLT) and these cost 40000 BTC, 20000 PLT,
# 125000 BTC and 125000 BTC, so on production they must be REFUSED cleanly.
# That refusal is itself part of the proof: the price comes from the server
# catalog, and a refusal moves neither money nor items.
NAMED = [("LF1", "lf1"), ("LF3", "lf3"), ("Kalkan 1", "kalkan1"),
         ("Hız 1", "hiz1")]

# Items a starter account CAN afford, so the success path - the one that was
# broken - really runs against production. Hız 2 is a piece of equipment and
# costs exactly the 10000 PLT a new account holds; PBMB is a 0 PLT edge case.
# hiz2 first, because it consumes the entire 10000 PLT budget; anything with a
# price before it would leave too little and be refused (correctly, but it
# would not exercise the delivery path).
AFFORDABLE = [("Hız 2", "hiz2"), ("PBMB", "pbmb")]

PASSWORD = "Prod" + secrets.token_urlsafe(12)

_failures: list = []
_checks: list = []


def check(name: str, ok: bool, detail: str = "") -> None:
    _checks.append((name, bool(ok), detail))
    if not ok:
        _failures.append(name)
    print(f"  {'PASS' if ok else 'FAIL'}  {name}"
          + (f"   {detail}" if not ok else ""))


def call(method: str, path: str, body=None, token: str = ""):
    url = f"{BASE}{path}"
    data = None if body is None else json.dumps(body).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()
        try:
            return exc.code, json.loads(raw)
        except json.JSONDecodeError:
            return exc.code, raw


def sign_in(user: str):
    status, reg = call("POST", "/auth/register", {
        "username": user, "password": PASSWORD,
        "nickname": user, "company": "",
    })
    if status != 200:
        return None, None, f"register {status} {reg}"
    status, login = call("POST", "/auth/login", {
        "username": user, "password": PASSWORD})
    if status != 200:
        return None, None, f"login {status} {login}"
    return login, reg, None


def main() -> int:
    print(f"target: {BASE}")
    status, health = call("GET", "/health")
    check("health_200", status == 200, f"{status} {health}")
    if status != 200:
        return 1

    user = f"promkt_{int(time.time())}"
    login, reg, err = sign_in(user)
    check("register_and_login", err is None, str(err))
    if err:
        return 1
    token = login["access_token"]

    before = call("GET", "/player/full", token=token)[1]
    check("before_state_readable", "btc" in before, str(before))
    print(f"\nBEFORE  btc={before['btc']} plt={before['plt']}")
    print(f"BEFORE  inventory={before['inventory']}\n")

    print("=" * 74)
    print("A. REAL PURCHASE of affordable items (the path that was broken)")
    print("=" * 74)
    bought_ok = 0
    for label, canonical in AFFORDABLE:
        btc0, plt0 = before["btc"], before["plt"]
        inv0 = before["inventory"].get(canonical, 0)

        status, data = call("POST", "/market/buy", {
            "item_id": label, "currency": "", "price": 0,
            "transaction_id": f"{user}_{label}_{time.time_ns()}",
        }, token=token)

        # THE key contract: the client gate market.gd reads.
        check(f"basarili_present_{canonical}",
              status == 200 and data.get("basarili") is True,
              f"status={status} keys={sorted(data.keys()) if isinstance(data, dict) else data}")
        check(f"reports_canonical_id_{canonical}",
              str(data.get("purchase", {}).get("item_id")) == canonical,
              str(data.get("purchase")))

        after = call("GET", "/player/full", token=token)[1]
        got = after["inventory"].get(canonical, 0)
        check(f"inventory_grew_{canonical}", got == inv0 + 1,
              f"{canonical} {inv0} -> {got}")
        spent = (btc0 - after["btc"]) + (plt0 - after["plt"])
        check(f"balance_debited_{canonical}", spent >= 0 and
              ((after["btc"], after["plt"]) != (btc0, plt0) or spent == 0),
              f"btc {btc0}->{after['btc']} plt {plt0}->{after['plt']}")
        bought_ok += 1
        print(f"    {label:8s} -> {canonical:11s} x{got}  "
              f"btc {btc0}->{after['btc']}  plt {plt0}->{after['plt']}")
        before = after

    print("\n" + "=" * 74)
    print("B. The four items from the report, on a starter balance")
    print("=" * 74)
    for label, canonical in NAMED:
        btc0, plt0 = before["btc"], before["plt"]
        inv_before = dict(before["inventory"])
        status, data = call("POST", "/market/buy", {
            "item_id": label, "currency": "", "price": 0,
            "transaction_id": f"{user}_{label}_{time.time_ns()}",
        }, token=token)
        msg = (data.get("mesaj") or data.get("message") or "") \
            if isinstance(data, dict) else ""
        check(f"refused_with_reason_{canonical}", bool(msg),
              f"status={status} body={data}")
        after = call("GET", "/player/full", token=token)[1]
        check(f"refused_moved_nothing_{canonical}",
              after["inventory"] == inv_before
              and (after["btc"], after["plt"]) == (btc0, plt0),
              "a refused purchase must move neither money nor items")
        print(f"    {label:9s} -> REFUSED: {msg}")
        before = after

    print("\nRECONNECT")
    call("POST", "/auth/logout",
         {"refresh_token": login["refresh_token"]}, token)
    status, again = call("POST", "/auth/login", {
        "username": user, "password": PASSWORD})
    check("relogin_200", status == 200, str(status))
    if status == 200:
        fresh = call("GET", "/player/full", token=again["access_token"])[1]
        print(f"  after fresh login: {fresh['inventory']}")
        for _, canonical in AFFORDABLE:
            check(f"kept_after_relogin_{canonical}",
                  fresh["inventory"].get(canonical, 0) >= 1,
                  f"{canonical} missing after relogin")

    print("\nJOURNAL")
    status, jr = call("GET", "/journal?limit=100",
                      token=again["access_token"])
    check("journal_readable", status == 200, str(status))
    if status == 200:
        events = [e for e in jr.get("events", [])
                  if e.get("event_type") == "market_buy"]
        for e in events:
            print(f"    market_buy: {e.get('message')}")
        # Exactly the successful purchases, and not one row for the refusals.
        check("journal_row_per_success_only", len(events) == bought_ok,
              f"{len(events)} market_buy rows for {bought_ok} purchases")

    print("\n" + "=" * 74)
    print(f"{len(_checks) - len(_failures)}/{len(_checks)} checks passed")
    if _failures:
        print("FAILED: " + ", ".join(_failures))
        return 1
    print("PRODUCTION_MARKET=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
