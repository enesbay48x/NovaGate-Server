# NovaGate - Server Deployment and Admin Panel

This document covers the parts an operator needs: how the server is deployed,
how the Admin Panel is reached, how the first superadmin is created, and which
environment variables must be set.

---

## 1. Production service

| Item | Value |
| --- | --- |
| Host | `https://novagate-server-1.onrender.com` |
| Health check | `GET /health` -> `{"status":"ok"}` |
| Admin Panel | `GET /admin` (same origin) |
| Auth | `POST /auth/login` -> Bearer JWT |

The Admin Panel is served by the same FastAPI process, so it needs no separate
hosting and no CORS exception.

---

## 2. Admin Panel: how it finds the API

The panel deliberately contains **no hard-coded URL**. `resolveApiBase()` in
`admin/admin.js` resolves the base in this order:

1. `?api=` query parameter - e.g. `admin/index.html?api=http://localhost:8000`
2. `window.__NOVAGATE_API__` - set by a deployment config if you front the
   panel separately
3. `window.location.origin` - the normal case

Because there is no localhost string in the build, the same file is correct in
both local development and production.

---

## 3. Roles and permissions

Authority is resolved **on the server** from the `accounts.role` column. The
role in a request body, a JWT payload field, or a local file is never trusted.

| Role | Rank | Summary of powers |
| --- | --- | --- |
| `player` | 0 | Normal gameplay only. No Admin Panel access. |
| `modifier` -> `moderator` | 1 | Player lookup, online status, kick, teleport, chat moderation. |
| `admin` | 2 | Everything a moderator can do, **plus** economy, inventory, equipment, stats, ship, NPC, map, quest and gate management, and the audit log. |
| `superadmin` | 3 | Everything above, **plus** role assignment, clan/squad moderation, auction and event control, server controls and settings. |

Two rules make escalation impossible regardless of what a client sends:

* **You may only assign a role at or below your own.** A moderator cannot make
  an admin; an admin cannot make a superadmin.
* **You can never change your own role.** So an admin cannot promote
  themselves even to a role they already outrank.

The full matrix lives in `server/admin_core.py` as a table, and is readable at
runtime from `GET /admin/permissions`.

---

## 4. Creating the first superadmin (production)

The credentials are **never committed**. They are read from the environment:

| Variable | Purpose |
| --- | --- |
| `ADMIN_USERNAME` | Username of the bootstrapped staff account |
| `ADMIN_PASSWORD` | Its password (bcrypt hashed on first boot) |
| `ADMIN_ROLE` | Role to grant. Defaults to `superadmin`. |
| `SECRET_KEY` | JWT signing key. Must be set in production. |

On boot, `main._bootstrap_admin` creates the account if it is missing and
otherwise only *repairs the role* - it never overwrites an existing password,
inventory or economy. So you can rotate the password in the panel and restart
without losing it.

### Setting them in Render

1. Open the service -> **Environment**.
2. Add `SECRET_KEY` (generate with
   `python -c "import secrets;print(secrets.token_urlsafe(48))"`).
3. Add `ADMIN_USERNAME` and `ADMIN_PASSWORD`.
4. Optionally set `ADMIN_ROLE=superadmin`.
5. Save and redeploy.

### First login

```
POST /auth/login
{"username": "<ADMIN_USERNAME>", "password": "<ADMIN_PASSWORD>"}
```

Open `/admin`, sign in with the same credentials, and the panel will show the
role the **server** reports for that account.

---

## 5. Audit log

Every admin mutation writes one row to `admin_audit_log` containing: timestamp,
admin username, admin role, action, target type, target, old value, new value,
reason, result and remote address.

**The log is append-only.** Two SQLite triggers abort any `UPDATE` or `DELETE`
on the table:

```sql
CREATE TRIGGER admin_audit_no_update BEFORE UPDATE ON admin_audit_log
BEGIN SELECT RAISE(ABORT, 'admin_audit_log is append-only'); END;
```

So the trail cannot be rewritten by anyone, including a superadmin. There is
also no HTTP endpoint that mutates it.

---

## 6. Background schedulers

Two sweeps run on a 5-second loop, started at boot and stopped cleanly at
shutdown:

* **Auction settlement** - settles `open` auctions whose `ends_at` has passed,
  refunds out-bid bidders, and pays the winner. Settlement is a conditional
  `UPDATE ... WHERE state = 'open'`, so two concurrent passes produce exactly
  one payout.
* **Event lifecycle** - advances each event to the state its
  `starts_at`/`ends_at` window implies.

Both are **rebuildable from the database**: the first pass runs *before* the
loop starts, so anything that expired while the process was down is handled at
boot rather than after a full interval. This is what makes a Render restart
safe.

---

## 7. Running locally

```bash
cd server
python -m uvicorn main:app --reload
```

With no `ADMIN_*` variables set, no staff account is created. To create one
locally, put this in `server/.env` (which is git-ignored):

```
SECRET_KEY=dev-only-not-a-real-secret
ADMIN_USERNAME=localadmin
ADMIN_PASSWORD=localadmin123
ADMIN_ROLE=superadmin
```

Then open <http://localhost:8000/admin>.

---

## 8. Pre-commit checks

```bash
cd server
python _check_syntax.py      # every .py parses
python _check_boot.py        # the app imports and all routes register
python _check_secrets.py     # no secret is about to be committed
python -m pytest tests -q    # full server suite
```

`_check_secrets.py` scans the working tree - including files Git has not staged
yet - for `.env` files, literal `SECRET_KEY`/`password` assignments, database
URLs with inline passwords, private key blocks and common token formats.

---

## 9. Verifying a deployment

A successful `git push` says nothing about what is being served. A service that
failed to build keeps answering `/health` from the PREVIOUS build, so the only
reliable evidence is the deployed OpenAPI document.

```bash
cd server

# Blocks until the new build is actually serving. Exits 1 on timeout.
python _wait_for_deploy.py https://novagate-server-1.onrender.com

# Full player-facing acceptance against the live host.
python _verify_production.py https://novagate-server-1.onrender.com

# Staff-only acceptance. Credentials come from the environment so they never
# appear in the command line, in shell history, or in a file.
set ADMIN_USERNAME=...
set ADMIN_PASSWORD=...
python _verify_admin_ops.py https://novagate-server-1.onrender.com
```

`_verify_admin_ops.py` performs every economy operation against a throwaway
account it registers itself, so no real player's balances are read or written.

### Database migration

`init_db()` runs the full Phase 1-7 schema on every boot and every statement is
`CREATE ... IF NOT EXISTS` or a guarded additive column, so it is idempotent and
cannot destroy a row. To rehearse it against a copy of a live database:

```bash
cd server
python _db_migrate.py --db path/to/game.db            # dry run on a COPY
python _db_migrate.py --db path/to/game.db --backup-only
python _db_migrate.py --db path/to/game.db --apply    # backup, then apply
python _db_migrate_selftest.py                        # proves it on a fixture
```

`--apply` refuses to run unless the rehearsal on the copy converged, and writes
a timestamped backup (plus its WAL sidecars) before the first write.

To confirm the schema is present on a running server without staff credentials,
`_verify_production.py` probes one route per table group. A missing table raises
500 from SQLite, so any non-500 answer is positive evidence the table exists.
