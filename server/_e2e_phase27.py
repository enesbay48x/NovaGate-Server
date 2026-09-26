"""Phases 2-7 - REAL Godot client E2E harness.

Starts a real NovaGate server on a scratch database, then runs the REAL Godot
4.7.2 client driver (scripts/p2_p7_e2e_driver.gd, scenes/p2_p7_e2e.tscn)
against it and asserts on the machine-readable P2_P7_E2E_RESULT line.

The driver uses the project's own scripts (account_manager.gd, GlobalState.gd)
- nothing is mocked. Two checks exist precisely to prove the SERVER overrode a
tampered client-side number, which is the whole point of the phase.

Usage:  python _e2e_phase27.py
Exit 0 = all Godot-side checks passed.
"""
import os
import re
import shutil
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

PORT = 8137
BASE = f"http://127.0.0.1:{PORT}"
SECRET = "phase27-e2e-secret-key-0123456789abcdefghij"
DRIVER = "res://scenes/p2_p7_e2e.tscn"
RESULT_PREFIX = "P2_P7_E2E_RESULT "


def find_godot() -> str:
    for p in GODOT:
        if os.path.isfile(p):
            return p
    raise SystemExit("Godot 4.7.2 not found")


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
    db_path = os.path.join(HERE, "test_novagate_p27_e2e.db")
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

def run_godot_driver(log_path: str, timeout: float = 300.0) -> int:
    godot = find_godot()
    # A per-run user:// dir so a previous run's players.json / _save.json can
    # never make this run look successful.
    user_dir = tempfile.mkdtemp(prefix="p27e2e_user_")
    env = dict(os.environ)
    env["GODOT_USER_DATA_DIR"] = user_dir
    env["NOVAGATE_SERVER_URL"] = BASE
    cmd = [godot, "--headless", "--path", PROJECT, DRIVER]
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        try:
            proc = subprocess.run(
                cmd, cwd=PROJECT, env=env, stdout=log,
                stderr=subprocess.STDOUT, timeout=timeout,
            )
            rc = proc.returncode
        except subprocess.TimeoutExpired:
            rc = -999
    shutil.rmtree(user_dir, ignore_errors=True)
    return rc


def parse_result(log_path: str):
    """Read the P27_OK / P27_FAIL lines and the result summary.

    The summary line carries the counts; the per-check lines are kept so a
    failure names itself instead of only shrinking a number.
    """
    with open(log_path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    checks = []
    for line in text.splitlines():
        if line.startswith("P27_OK   "):
            checks.append({"name": line[len("P27_OK   "):].strip(), "ok": True})
        elif line.startswith("P27_FAIL "):
            rest = line[len("P27_FAIL "):]
            checks.append({
                "name": rest.split("  ", 1)[0].strip(), "ok": False})
    for line in text.splitlines():
        if line.startswith(RESULT_PREFIX):
            match = re.search(r"passed=(\d+)\s+failed=(\d+)\s+total=(\d+)",
                              line[len(RESULT_PREFIX):])
            if not match:
                return None
            return {
                "passed": int(match.group(1)),
                "failed": int(match.group(2)),
                "total": int(match.group(3)),
                "checks": checks,
            }
    return None


def main() -> int:
    server_log = os.path.join(HERE, "_e2e27_server.log")
    godot_log = os.path.join(HERE, "_e2e27_godot.log")

    proc, db_path, log = start_server(server_log)
    try:
        if not wait_health():
            print("FAIL: server did not become healthy")
            with open(server_log, encoding="utf-8", errors="replace") as fh:
                print(fh.read()[-3000:])
            return 1
        print("server healthy on", BASE)

        rc = run_godot_driver(godot_log)
        result = parse_result(godot_log)

        with open(godot_log, encoding="utf-8", errors="replace") as fh:
            print("\n--- godot output (tail) ---")
            print("\n".join(fh.read().splitlines()[-70:]))

        if result is None:
            print("\nFAIL: no P2_P7_E2E_RESULT line (rc=%s)" % rc)
            return 1

        print("\n--- Phase 2-7 real-client E2E checks ---")
        for c in result["checks"]:
            print(("  PASS  " if c["ok"] else "  FAIL  ") + c["name"])
        print("\npassed=%s failed=%s total=%s"
              % (result["passed"], result["failed"], result["total"]))
        if result["failed"]:
            print("failed checks: %s" % [c["name"] for c in result["checks"]
                                         if not c["ok"]])
            return 1
        if rc not in (0, None):
            print("FAIL: driver exit code %s" % rc)
            return 1
        print("\nPHASE2_7_REAL_GODOT_E2E=PASS")
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

