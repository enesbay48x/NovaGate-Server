"""Market purchase -> inventory delivery, REAL Godot client E2E.

Starts a real NovaGate server on a throwaway database, then runs the REAL
Godot 4.7.2 client driver (scripts/market_e2e_driver.gd) against it and
asserts on the machine-readable MARKET_E2E_RESULT line it prints.

The driver uses the project's own scripts (account_manager.gd, menu_ui.gd,
GlobalState.gd) - nothing is mocked. This is the end-to-end proof that a market
purchase now delivers the item to the client inventory, the equipment UI and
the save file, and survives a logout/login cycle.

Usage:  python _e2e_market.py
Exit 0 = all Godot-side checks passed.
"""
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)

GODOT = [
    r"C:\Users\Pc\.ziva\engines\godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe",
    r"C:\Users\Pc\Desktop\Godot_v4.7.2-stable_win64_console.exe",
    r"C:\Users\Pc\.ziva\engines\godot\4.7.2\Godot.exe",
]

PORT = 8131
BASE = f"http://127.0.0.1:{PORT}"
SECRET = "market-e2e-secret-key-0123456789abcdefghijkl"
DRIVER = "res://scenes/market_e2e.tscn"

# The starter reward is 10000 BTC / 10000 PLT, but LF1 costs 40000 BTC,
# LF3 20000 PLT, Kalkan I 125000 BTC and Hiz I 125000 BTC. A clean test
# account is therefore funded first, so every one of the four items the bug
# report names can actually be bought for real.
FUND_BTC = 5_000_000
FUND_PLT = 5_000_000

# A fresh random password per run, handed to the client through the
# environment. A hardcoded test credential would be a literal secret in the
# repository for no benefit: this account lives only in a throwaway database
# that is deleted before the next run.
PASSWORD = "Mkt" + secrets.token_urlsafe(12)


def _register_account() -> str:
    """Create the funded test account and return its username.

    Done here, in Python, because the Godot client has no legitimate way to
    grant itself currency - and it must not, that would be the cheat the
    server-side price check exists to prevent.
    """
    import sqlite3
    import urllib.request

    username = "mkte2e_%d" % int(time.time())
    body = json.dumps({
        "username": username, "password": PASSWORD,
        "nickname": username, "company": "",
    }).encode()
    req = urllib.request.Request(
        f"{BASE}/auth/register", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        if resp.status != 200:
            raise SystemExit("register failed: %s" % resp.status)
        payload = json.loads(resp.read().decode())
    player_id = payload["player_id"]

    # The server owns the schema, so the account row already exists; only the
    # balance needs topping up. This is a throwaway test database.
    db_path = os.path.join(HERE, "test_novagate_market_e2e.db")
    conn = sqlite3.connect(db_path, timeout=15)
    try:
        conn.execute(
            "UPDATE economy SET btc = ?, plt = ? WHERE player_id = ?",
            (FUND_BTC, FUND_PLT, player_id))
        conn.commit()
    finally:
        conn.close()
    return username


def find_godot() -> str:
    for p in GODOT:
        if os.path.isfile(p):
            return p
    raise SystemExit("Godot 4.7.2 not found")


def port_open(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(0.4)
        return s.connect_ex(("127.0.0.1", port)) == 0


def wait_health(timeout: float = 60.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"{BASE}/health", timeout=2) as r:
                if r.status == 200:
                    return True
        except Exception:
            time.sleep(0.5)
    return False


def start_server(log_path: str):
    db_path = os.path.join(HERE, "test_novagate_market_e2e.db")
    for stale in (db_path, db_path + "-wal", db_path + "-shm"):
        if os.path.exists(stale):
            os.remove(stale)
    env = dict(os.environ)
    env.update({
        "SECRET_KEY": SECRET,
        "DB_PATH": db_path,
        "SERVER_HOST": "127.0.0.1",
        "SERVER_PORT": str(PORT),
        "RATE_LIMIT_LOGIN": "500/minute",
        "RATE_LIMIT_REGISTER": "500/minute",
        "PYTHONUNBUFFERED": "1",
    })
    log = open(log_path, "w", encoding="utf-8", errors="replace")
    proc = subprocess.Popen(
        [sys.executable, "run_server.py"], cwd=HERE, env=env,
        stdout=log, stderr=subprocess.STDOUT,
    )
    return proc, db_path, log


def run_godot_driver(log_path: str, username: str, timeout: float = 240.0) -> int:
    godot = find_godot()
    # A per-run user:// dir, so a previous run's players.json / _save.json can
    # never make this run look successful.
    user_dir = tempfile.mkdtemp(prefix="mkte2e_user_")
    env = dict(os.environ)
    env["GODOT_USER_DATA_DIR"] = user_dir
    env["NOVAGATE_SERVER_URL"] = BASE
    env["NOVAGATE_E2E_USER"] = username
    env["NOVAGATE_E2E_PASSWORD"] = PASSWORD
    cmd = [godot, "--headless", "--path", PROJECT, DRIVER]
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        try:
            rc = subprocess.run(
                cmd, cwd=PROJECT, env=env, stdout=log,
                stderr=subprocess.STDOUT, timeout=timeout,
            ).returncode
        except subprocess.TimeoutExpired:
            rc = -999
    shutil.rmtree(user_dir, ignore_errors=True)
    return rc


def parse_result(log_path: str):
    with open(log_path, encoding="utf-8", errors="replace") as fh:
        for line in fh.read().splitlines():
            if line.startswith("MARKET_E2E_RESULT "):
                return json.loads(line[len("MARKET_E2E_RESULT "):])
    return None


def main() -> int:
    server_log = os.path.join(HERE, "_e2e_market_server.log")
    godot_log = os.path.join(HERE, "_e2e_market_godot.log")

    proc, db_path, log = start_server(server_log)
    try:
        if not wait_health():
            print("FAIL: server did not become healthy")
            with open(server_log, encoding="utf-8", errors="replace") as fh:
                print(fh.read()[-3000:])
            return 1
        print("server healthy on", BASE)

        username = _register_account()
        print("funded test account:", username)

        rc = run_godot_driver(godot_log, username)
        result = parse_result(godot_log)

        with open(godot_log, encoding="utf-8", errors="replace") as fh:
            godot_text = fh.read()
        print("\n--- godot output (tail) ---")
        print("\n".join(godot_text.splitlines()[-70:]))

        if result is None:
            print("\nFAIL: driver produced no MARKET_E2E_RESULT line (rc=%s)" % rc)
            return 1

        print("\n--- Market real-client E2E checks ---")
        for c in result["checks"]:
            print(("  PASS  " if c["ok"] else "  FAIL  ") + c["name"])
        print("\npassed=%s failed=%s total=%s"
              % (result["passed"], len(result["failed"]), result["total"]))
        if result["failed"]:
            print("failed checks: %s" % result["failed"])
            return 1
        if rc not in (0, None):
            print("FAIL: driver exit code %s" % rc)
            return 1
        print("\nMARKET_REAL_GODOT_E2E=PASS  user=%s" % result["username"])
        return 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        log.close()


if __name__ == "__main__":
    sys.exit(main())
