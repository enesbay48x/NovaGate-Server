"""Parse-check every NovaGate server module and report syntax errors.

Exits non-zero when any file fails to parse, so it can gate a commit-free
verification step.
"""
import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def targets() -> list:
    out = []
    for rel in ("server/main.py", "server/journal.py", "server/item_catalog.py",
                "server/config.py", "server/websocket_server.py",
                "server/schema.py", "server/game_data.py",
                "server/player_state.py", "server/combat.py",
                "server/routes_p23.py", "server/routes_p45.py",
                "server/routes_p67.py"):
        out.append(os.path.join(ROOT, rel))
    tests_dir = os.path.join(HERE, "tests")
    if os.path.isdir(tests_dir):
        for name in sorted(os.listdir(tests_dir)):
            if name.startswith("test_") and name.endswith(".py"):
                out.append(os.path.join(tests_dir, name))
    return out


def main() -> int:
    failures = 0
    for path in targets():
        rel = os.path.relpath(path, ROOT)
        try:
            with open(path, encoding="utf-8") as fh:
                ast.parse(fh.read(), filename=path)
        except SyntaxError as exc:
            failures += 1
            print(f"FAIL {rel}:{exc.lineno} {exc.msg}")
        except OSError as exc:
            failures += 1
            print(f"FAIL {rel}: {exc}")
        else:
            print(f"OK   {rel}")
    print(f"\nchecked={len(targets())} failures={failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
