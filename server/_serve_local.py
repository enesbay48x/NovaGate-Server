"""Run the NovaGate server locally for E2E testing.

A THROWAWAY test key is supplied when the environment has none, because
`config` refuses to import without SECRET_KEY - which is correct for
production and inconvenient for a local test run. The database is pointed at a
throwaway file so a local E2E can never touch a real one.

Usage:  python _serve_local.py [port]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099

if not os.environ.get("SECRET_KEY"):
    os.environ["SECRET_KEY"] = "local-e2e-throwaway-key-not-a-secret"
# A dedicated database, so a local run is isolated from anything real.
if not os.environ.get("DB_PATH"):
    os.environ["DB_PATH"] = os.path.join(HERE, "data", "local_e2e.db")
os.environ.setdefault("RATE_LIMIT_LOGIN", "1000/minute")
os.environ.setdefault("RATE_LIMIT_REGISTER", "1000/minute")
# The background scheduler is left ON here on purpose: a local E2E should
# exercise the same startup path production does, not a reduced one.

import uvicorn  # noqa: E402

if __name__ == "__main__":
    uvicorn.run("main:app", host="127.0.0.1", port=PORT, log_level="warning")
