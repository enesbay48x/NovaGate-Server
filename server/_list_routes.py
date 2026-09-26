"""Print the live route list from a deployed NovaGate server.

Answers the question "did my deploy actually land?" without guessing: the
OpenAPI document lists every registered path, so a missing `/admin/...` means
the running build predates the change.

Usage:  python _list_routes.py [base_url]
"""
import json
import os
import sys
import urllib.request

DEFAULT_BASE = "https://novagate-server-1.onrender.com"


def main() -> int:
    base = (sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BASE).rstrip("/")
    url = base + "/openapi.json"
    with urllib.request.urlopen(url, timeout=45) as response:
        document = json.loads(response.read().decode("utf-8", "replace"))
    paths = sorted(document.get("paths", {}))
    admin = [p for p in paths if p.startswith("/admin")]

    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "_routes_out.txt")
    with open(out, "w", encoding="utf-8", errors="replace") as fh:
        fh.write("total_paths=%d\n" % len(paths))
        fh.write("admin_paths=%d\n" % len(admin))
        for path in admin:
            fh.write("  ADMIN %s\n" % path)
        fh.write("--- all ---\n")
        for path in paths:
            fh.write("  %s\n" % path)
    print("wrote %s (total=%d admin=%d)" % (out, len(paths), len(admin)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
