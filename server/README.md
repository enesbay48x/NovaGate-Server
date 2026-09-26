NovaGate Auth Server (Phase 1: Auth + Session)

Dependencies:
  pip install -r requirements.txt

Local run:
  python run_server.py

Render run:
  uvicorn main:app --app-dir server --host 0.0.0.0 --port $PORT

Environment variables:
  SECRET_KEY         - JWT signing secret (required)
  PORT               - Render-provided service port
  DB_PATH            - persistent mounted SQLite path, e.g. /var/data/novagate.db
  ACCESS_TOKEN_EXPIRE_SECONDS - default 900 (15 min)
  REFRESH_TOKEN_EXPIRE_SECONDS - default 604800 (7 days)
  RATE_LIMIT_LOGIN    - default 5 per minute
  RATE_LIMIT_REGISTER - default 3 per minute
  ADMIN_USERNAME      - optional admin account username
  ADMIN_PASSWORD      - optional admin account password

Health:
  GET /health

Admin API:
  /admin/* routes require a valid JWT belonging to an accounts.role='admin' account.
  Do not use a normal player token; normal tokens receive HTTP 403.

