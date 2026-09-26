"""
NovaGate WebSocket World Server

Implements:
- WebSocket endpoint with JWT/session authentication
- 20 Hz authoritative world loop
- Server-authoritative player movement (client sends input, server computes position)
- Remote player position broadcasting with interest management
- Heartbeat / ping-pong with disconnect on timeout
- Single-ship lock (no ghost players)
"""

import asyncio
import json
import os
import random
import time
from dataclasses import dataclass, field
from typing import Optional

import aiosqlite
import jwt
from fastapi import HTTPException, Request, status, WebSocket
from pydantic import BaseModel
from starlette.websockets import WebSocketState

import journal


# ---------------------------------------------------------------------------
# Constants (duplicated from config to avoid circular import)
# ---------------------------------------------------------------------------
JWT_ALGORITHM = "HS256"
SHIP_ID_DEFAULT = "Ship10"
WORLD_TICK_HZ = 20
INTEREST_RADIUS = 3000.0
MAP_WIDTH = 14000.0
MAP_HEIGHT = 10000.0
MAX_SPEED = 600.0
HEARTBEAT_INTERVAL = 10
HEARTBEAT_TIMEOUT = 30

TICK_INTERVAL = 1.0 / WORLD_TICK_HZ
WORLD_RECT_MIN = (-MAP_WIDTH / 2.0, -MAP_HEIGHT / 2.0)
WORLD_RECT_MAX = (MAP_WIDTH / 2.0, MAP_HEIGHT / 2.0)

# Fallback used when `configure()` is called without a path. Matches the
# default in config.py so the journal writes to the same file as the auth API.
_DEFAULT_DB_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "data", "novagate.db"
)


def _unix_now() -> int:
    return int(time.time())


def _decode_token(token: str, secret_key: str) -> dict:
    try:
        payload = jwt.decode(token, secret_key, algorithms=[JWT_ALGORITHM])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token expired")
    except jwt.InvalidTokenError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")
    if payload.get("type") != "access":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token type")
    return payload


# ---------------------------------------------------------------------------
# Player state (server-authoritative)
# ---------------------------------------------------------------------------
@dataclass
class PlayerSession:
    account_id: int
    player_id: str
    username: str
    ship_id: str
    map_id: str
    position_x: float
    position_y: float
    input_x: float = 0.0
    input_y: float = 0.0
    speed: float = MAX_SPEED
    hp: float = 100.0
    max_hp: float = 100.0
    shield: float = 100.0
    max_shield: float = 100.0
    last_input_time: float = 0.0
    last_fire_time: float = 0.0
    last_heartbeat: float = field(default_factory=time.time)
    last_seen: float = field(default_factory=time.time)
    company: str = ""
    level: int = 1
    connected_at: float = field(default_factory=time.time)
    websocket: WebSocket = None
    disconnected: bool = False
    # Phase 1: background task replaying the journal on connect. Held on the
    # session (rather than fired and forgotten) so the event loop keeps a
    # strong reference and the task cannot be garbage collected mid-await.
    journal_sync_task: Optional[asyncio.Task] = None

    @property
    def position(self) -> tuple[float, float]:
        return (self.position_x, self.position_y)


# ---------------------------------------------------------------------------
# Connection manager - tracks all connected WebSocket players
# ---------------------------------------------------------------------------
class ConnectionManager:
    def __init__(self):
        self.active_connections: dict[str, PlayerSession] = {}
        self.ship_locks: dict[str, str] = {}
        self._lock = asyncio.Lock()
        self.secret_key: str = ""
        self.db_path: str = "novagate.db"

    def configure(self, secret_key: str, db_path: str):
        self.secret_key = secret_key
        # An empty db_path must never be stored: every journal write resolves
        # through it, and an empty string would silently create/skip a file.
        self.db_path = db_path or _DEFAULT_DB_PATH

    async def _kick_locked(self, player: "PlayerSession", reason: str) -> None:
        """Kick an existing session (caller must hold self._lock).

        Sends `session_kicked` to the old WebSocket, closes it and marks the
        session as disconnected so the world loop stops broadcasting to it.
        """
        player.disconnected = True
        if player.ship_id and self.ship_locks.get(player.ship_id) == player.player_id:
            self.ship_locks.pop(player.ship_id, None)
        if self.active_connections.get(player.player_id) is player:
            self.active_connections.pop(player.player_id, None)
        if player.websocket is None:
            return
        try:
            if player.websocket.application_state == WebSocketState.CONNECTED:
                await player.websocket.send_text(json.dumps({
                    "type": "session_kicked",
                    "reason": reason,
                }))
        except Exception:
            pass
        try:
            await player.websocket.close(code=1000, reason=reason)
        except Exception:
            pass
        print(f"[NOVAGATE] session_kicked player_id={player.player_id} reason={reason}", flush=True)

    async def kick(self, player_id: str, reason: str = "account_logged_in_elsewhere") -> bool:
        """Kick the active WebSocket session of a player (if any)."""
        async with self._lock:
            player = self.active_connections.get(player_id)
            if player is None:
                return False
            await self._kick_locked(player, reason)
            return True

    async def set_company(self, player_id: str, company: str) -> bool:
        """Mirror a persisted company change onto the LIVE session.

        The database row stays authoritative; this keeps the already-open
        WebSocket session (and therefore every world_update peer entry, the
        server-decided relation and the PvP gate) in sync with it, so a player
        does not have to reconnect to become PvP-eligible.

        Returns True when a connected session was updated.
        """
        normalized = str(company or "").strip().upper()
        async with self._lock:
            player = self.active_connections.get(player_id)
            if player is None or player.disconnected:
                return False
            player.company = normalized
            return True

    async def connect(self, websocket: WebSocket, token: str) -> Optional[PlayerSession]:
        """Authenticate the WebSocket connection via JWT access token."""
        if not token:
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason="Missing token")
            return None

        try:
            payload = _decode_token(token, self.secret_key)
        except HTTPException:
            await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason="Invalid token")
            return None

        account_id = int(payload["sub"])
        player_id = payload["player_id"]
        username = payload["username"]
        session_jti = payload.get("session_jti", "")
        company = ""
        ship_id = SHIP_ID_DEFAULT

        async with self._lock:
            async with aiosqlite.connect(self.db_path) as db:
                # Verify session is still active
                if session_jti:
                    cursor = await db.execute(
                        "SELECT active, ship_id, expires_at FROM sessions WHERE refresh_jti = ? AND active = 1",
                        (session_jti,),
                    )
                    row = await cursor.fetchone()
                    if not row or not row[0]:
                        await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason="Session inactive")
                        return None
                    if _unix_now() > row[2]:
                        await websocket.close(code=status.WS_1008_POLICY_VIOLATION, reason="Session expired")
                        return None
                    ship_id = row[1] or SHIP_ID_DEFAULT

                # Server-authoritative company comes from the DB, never from
                # client-provided state.
                #
                # This read must happen for EVERY authenticated connection, not
                # only inside the `if session_jti` branch. A token issued by
                # /auth/refresh carries no session_jti, and that used to skip
                # this read entirely: the session silently started with
                # company "" so every peer saw relation "neutral" and
                # server-authoritative PvP stayed disabled until reconnect.
                cursor = await db.execute(
                    "SELECT company FROM accounts WHERE id = ?",
                    (account_id,),
                )
                account_row = await cursor.fetchone()
                if account_row and account_row[0]:
                    company = str(account_row[0]).strip().upper()

            # ONE ACCOUNT = ONE ACTIVE SESSION.
            # If this player_id already has a live WebSocket (PC session, then
            # mobile login, etc.) the old session is kicked and closed first.
            existing_player = self.active_connections.get(player_id)
            if existing_player is not None and existing_player.websocket is not websocket:
                await self._kick_locked(existing_player, "account_logged_in_elsewhere")

            await websocket.accept()

            player = PlayerSession(
                account_id=account_id,
                player_id=player_id,
                username=username,
                ship_id=ship_id,
                map_id="1-1",
                position_x=0.0,
                position_y=0.0,
                websocket=websocket,
                company=company,
            )
            self.active_connections[player_id] = player
            self.ship_locks[ship_id] = player_id
            # Ensure NPCs are spawned for the player's map
            try:
                await npc_manager.spawn_map_npcs(player.map_id)
            except Exception as e:
                print(f"[DEBUG] spawn_map_npcs error: {e}", flush=True)
            print(f"[DEBUG] connect OK: player_id={player_id} ship={ship_id} company={company} total={len(self.active_connections)}", flush=True)
            return player

    async def disconnect(self, player_id: str, websocket: Optional[WebSocket] = None) -> None:
        """Remove a player session.

        When `websocket` is provided, only the session owned by that exact
        WebSocket is removed. This prevents a kicked (old) connection's cleanup
        from deleting the session of the newer, active connection.
        """
        async with self._lock:
            player = self.active_connections.get(player_id)
            if player is None:
                return
            if websocket is not None and player.websocket is not websocket:
                # Stale connection: its replacement is already registered.
                return
            self.active_connections.pop(player_id, None)
            if player.ship_id and self.ship_locks.get(player.ship_id) == player_id:
                self.ship_locks.pop(player.ship_id, None)
            player.disconnected = True

    async def drop(self, player: "PlayerSession") -> None:
        """Remove a session whose socket has already failed.

        Only removes the session if the stored entry is still this exact
        object, so a stale socket can never delete the newer replacement
        session of the same account.
        """
        async with self._lock:
            if self.active_connections.get(player.player_id) is player:
                self.active_connections.pop(player.player_id, None)
            if player.ship_id and self.ship_locks.get(player.ship_id) == player.player_id:
                self.ship_locks.pop(player.ship_id, None)
            player.disconnected = True

    async def get_nearby_players(self, player_id: str) -> list[PlayerSession]:
        """Return players in the same map within INTEREST_RADIUS."""
        player = self.active_connections.get(player_id)
        if not player:
            return []
        result = []
        for other in self.active_connections.values():
            if other.player_id == player_id:
                continue
            if other.map_id != player.map_id:
                continue
            dx = other.position_x - player.position_x
            dy = other.position_y - player.position_y
            if (dx * dx + dy * dy) <= (INTEREST_RADIUS * INTEREST_RADIUS):
                result.append(other)
        return result


manager = ConnectionManager()


# ---------------------------------------------------------------------------
# World tick loop (20 Hz)
# ---------------------------------------------------------------------------
_world_task: Optional[asyncio.Task] = None
_ping_task: Optional[asyncio.Task] = None


async def world_tick():
    """Run the authoritative world loop at 20 Hz."""
    while True:
        current_time = time.time()

        async with manager._lock:
            to_disconnect = []
            for pid, player in list(manager.active_connections.items()):
                elapsed = current_time - player.last_heartbeat
                if elapsed > HEARTBEAT_TIMEOUT:
                    to_disconnect.append(pid)

            for pid in to_disconnect:
                player = manager.active_connections.get(pid)
                if player and player.websocket:
                    try:
                        await player.websocket.close(code=status.WS_1001_GOING_AWAY, reason="Heartbeat timeout")
                    except Exception:
                        pass
                manager.active_connections.pop(pid, None)
                if player and player.ship_id:
                    manager.ship_locks.pop(player.ship_id, None)
                if player:
                    player.disconnected = True

            for player in list(manager.active_connections.values()):
                if player.disconnected:
                    continue

                # Movement delta
                # Uses the session's own speed (aligned with the client's ship
                # model, still capped by MAX_SPEED) instead of the raw global
                # constant, so client and server integrate the same motion.
                dx = player.input_x * player.speed * TICK_INTERVAL
                dy = player.input_y * player.speed * TICK_INTERVAL
                new_x = player.position_x + dx
                new_y = player.position_y + dy

                # Map boundary check
                new_x = max(WORLD_RECT_MIN[0], min(WORLD_RECT_MAX[0], new_x))
                new_y = max(WORLD_RECT_MIN[1], min(WORLD_RECT_MAX[1], new_y))

                # Anti-cheat: clamp input magnitude
                input_mag = (player.input_x * player.input_x + player.input_y * player.input_y) ** 0.5
                if input_mag > 1.0:
                    player.input_x = player.input_x / input_mag if input_mag > 0 else 0.0
                    player.input_y = player.input_y / input_mag if input_mag > 0 else 0.0

                player.position_x = new_x
                player.position_y = new_y
                player.last_input_time = current_time

        await broadcast_world_state()
        await asyncio.sleep(TICK_INTERVAL)


async def broadcast_world_state():
    """Broadcast each player's state to nearby players (interest management)."""
    async with manager._lock:
        players = list(manager.active_connections.values())

    for player in players:
        if player.disconnected:
            continue
        if player.websocket is None:
            continue
        if player.websocket.application_state != WebSocketState.CONNECTED:
            continue

        nearby = await manager.get_nearby_players(player.player_id)

        state_msg = {
            "type": "world_update",
            "tick_interval": TICK_INTERVAL,
            # The receiver's OWN authoritative state. `players` below only
            # carries peers (see get_nearby_players), so without this the
            # client could never reconcile its local ship with the server
            # position and range checks would compare two different worlds.
            "self": {
                "player_id": player.player_id,
                "x": round(player.position_x, 2),
                "y": round(player.position_y, 2),
                "map_id": player.map_id,
                "speed": round(player.speed, 2),
            },
            "players": [],
            "npcs": [],
        }
        for other in nearby:
            state_msg["players"].append({
                "player_id": other.player_id,
                "username": other.username,
                "company": other.company,
                # Server-decided relation: the client must not recompute it.
                "relation": calculate_company_relation(player.company, other.company),
                "level": other.level,
                "map_id": other.map_id,
                "ship_id": other.ship_id,
                "x": round(other.position_x, 2),
                "y": round(other.position_y, 2),
                "hp": round(other.hp, 1),
                "max_hp": round(other.max_hp, 1),
                "shield": round(other.shield, 1),
                "max_shield": round(other.max_shield, 1),
                "input_x": round(other.input_x, 4),
                "input_y": round(other.input_y, 4),
                # Presence metadata: lets the client detect stale/ghost entities.
                "last_seen": round(other.last_seen, 3),
            })
            other.last_seen = time.time()

        # Add NPC state for NPCs on the same map
        for npc in npc_manager.get_npcs_on_map(player.map_id):
            # Only send NPCs near the player (within interest range)
            dist = ((npc.position_x - player.position_x) ** 2 +
                    (npc.position_y - player.position_y) ** 2) ** 0.5
            if dist <= INTEREST_RADIUS:
                state_msg["npcs"].append(npc_manager.to_dict(npc))

        try:
            await player.websocket.send_text(json.dumps(state_msg))
        except Exception:
            # Dead socket: remove the session from the world immediately so it
            # cannot linger as a ghost player.
            await manager.drop(player)


async def send_journal_event(player: "PlayerSession", event: dict) -> bool:
    """Push one `journal_event` frame to a single player's socket.

    Phase 1: the Seyir Defteri is server-authored. This is only the transport;
    the event must already be persisted by `journal.record_event`, so a failed
    send can never create a history the server does not know about.

    Returns False when the socket is gone, in which case the caller should drop
    the session - the entry is still stored and will be replayed on next login.
    """
    if player is None or player.websocket is None:
        return False
    if player.websocket.application_state != WebSocketState.CONNECTED:
        return False
    try:
        await player.websocket.send_text(json.dumps(event))
        return True
    except Exception:
        await manager.drop(player)
        return False


async def record_and_push_journal(
    player: "PlayerSession",
    event_type: str,
    message: str,
    severity: str = "info",
    details: Optional[dict] = None,
) -> Optional[dict]:
    """Persist a journal entry and push it to the player's live socket.

    The single call site gameplay code should use. Persistence happens first and
    a DB failure is swallowed (the entry is lost, the action is NOT rolled back)
    so a journal problem can never break combat or movement.
    """
    if player is None or not player.player_id:
        return None
    db_path = manager.db_path
    if not db_path:
        return None
    try:
        async with aiosqlite.connect(db_path) as db:
            event = await journal.record_event(
                db, player.player_id, event_type, message, severity, details
            )
            await db.commit()
    except Exception:
        return None
    await send_journal_event(player, event)
    return event


async def _send_journal_history(websocket: WebSocket, player: "PlayerSession") -> None:
    """Push the persisted journal to a freshly connected player.

    Sent as one `journal_sync` frame right after the `welcome` handshake, so a
    reconnecting client rebuilds the same logbook it had before it dropped. A DB
    failure here must never break the connection, so it is swallowed.
    """
    if websocket is None or websocket.application_state != WebSocketState.CONNECTED:
        return
    db_path = manager.db_path
    if not db_path or not player.player_id:
        return
    try:
        async with aiosqlite.connect(db_path) as db:
            events = await journal.list_events(db, player.player_id)
    except Exception:
        return
    if not events:
        return
    try:
        await websocket.send_text(json.dumps({
            "type": "journal_sync",
            "events": events,
        }))
    except Exception:
        pass


async def start_world_loop():
    """Start the world tick loop."""
    global _world_task
    if _world_task is None or _world_task.done():
        _world_task = asyncio.create_task(world_tick())


async def _send_server_pings():
    """Send periodic ping messages to all connected WebSocket players."""
    while True:
        current_time = time.time()
        async with manager._lock:
            players = list(manager.active_connections.values())

        for player in players:
            if player.disconnected:
                continue
            if player.websocket and player.websocket.application_state == WebSocketState.CONNECTED:
                try:
                    await player.websocket.send_text(json.dumps({"type": "ping", "server_time": current_time}))
                except Exception:
                    await manager.drop(player)

        await asyncio.sleep(HEARTBEAT_INTERVAL)


# ---------------------------------------------------------------------------
# Route registration
# ---------------------------------------------------------------------------
def register_websocket_routes(app, secret_key: str = "", db_path: str = ""):
    """Register WebSocket and HTTP routes on the FastAPI app."""
    manager.configure(secret_key, db_path)

    @app.websocket("/ws/game")
    async def websocket_endpoint(websocket: WebSocket):
        token = websocket.query_params.get("token")
        player = await manager.connect(websocket, token)
        if player is None:
            return

        # Send welcome message immediately (doesn't depend on world loop)
        try:
            await websocket.send_text(json.dumps({
                "type": "welcome",
                "tick_interval": TICK_INTERVAL,
                "tick_hz": WORLD_TICK_HZ,
                "x": player.position_x,
                "y": player.position_y,
                "ship_id": player.ship_id,
                "map_id": player.map_id,
                "player_id": player.player_id,
                "username": player.username,
                "company": player.company,
            }))
        except Exception:
            pass

        # Phase 1: replay the persisted Seyir Defteri so the client starts with
        # the server's history instead of an empty (or stale local) logbook.
        #
        # Sent as a background task, NOT awaited inline. The journal replay is a
        # disk read, and awaiting it here would delay the start of the receive
        # loop - a client that sends its first `input` frame immediately would
        # have that frame sit unprocessed for the duration of the query. The
        # task is stored on the session so it cannot be garbage collected.
        player.journal_sync_task = asyncio.create_task(
            _send_journal_history(websocket, player)
        )

        # Send the initial world snapshot immediately. The world loop will
        # continue broadcasting subsequent updates after this handshake.
        await broadcast_world_state()

        try:
            while True:
                try:
                    data = await websocket.receive_text()
                except Exception:
                    await manager.disconnect(player.player_id, websocket)
                    break

                player.last_seen = time.time()

                try:
                    msg = json.loads(data)
                except json.JSONDecodeError:
                    continue

                msg_type = msg.get("type", "")

                if msg_type == "ping":
                    player.last_heartbeat = time.time()
                    await websocket.send_text(json.dumps({"type": "pong"}))

                elif msg_type == "pong":
                    player.last_heartbeat = time.time()

                elif msg_type == "input":
                    input_x = float(msg.get("input_x", 0.0))
                    input_y = float(msg.get("input_y", 0.0))
                    mag = (input_x * input_x + input_y * input_y) ** 0.5
                    if mag > 1.0:
                        input_x = input_x / mag
                        input_y = input_y / mag
                    player.input_x = input_x
                    player.input_y = input_y
                    # Movement model alignment: the client reports the speed its
                    # own ship model actually moves at (PlayerShip.max_speed plus
                    # equipment/skill bonuses). The server integrates that SAME
                    # value so both sides follow one movement model.
                    # MAX_SPEED stays the hard anti-cheat ceiling: a client can
                    # never move faster than it, and omitting "speed" keeps the
                    # previous MAX_SPEED default.
                    if "speed" in msg:
                        try:
                            requested_speed = float(msg.get("speed", MAX_SPEED))
                        except (TypeError, ValueError):
                            requested_speed = MAX_SPEED
                        if requested_speed != requested_speed:  # NaN guard
                            requested_speed = MAX_SPEED
                        player.speed = max(0.0, min(MAX_SPEED, requested_speed))
                    player.last_input_time = time.time()

                elif msg_type == "fire":
                    # Combat input: client sends fire request
                    # Server validates and processes
                    now = time.time()
                    if now - player.last_fire_time < FIRE_COOLDOWN_SECONDS:
                        continue  # Rate limit
                    player.last_fire_time = now

                    weapon = int(msg.get("weapon", 1))
                    target_x = float(msg.get("target_x", 0.0))
                    target_y = float(msg.get("target_y", 0.0))
                    target_player_id = str(msg.get("target_player_id", "") or "")

                    combat_event = None
                    if target_player_id:
                        # PvP: server-authoritative player-vs-player path.
                        combat_event = await handle_player_fire(
                            player, target_player_id, weapon, target_x, target_y
                        )
                    else:
                        combat_event = await npc_manager.handle_fire(
                            player.player_id,
                            (player.position_x, player.position_y),
                            weapon,
                            target_x,
                            target_y,
                        )
                    if combat_event:
                        # Broadcast to nearby players
                        event_with_player = dict(combat_event)
                        event_with_player["player_id"] = player.player_id
                        recipients = await manager.get_nearby_players(player.player_id)
                        if player.player_id not in {recipient.player_id for recipient in recipients}:
                            recipients.append(player)
                        if "target_id" in event_with_player:
                            target_session = manager.active_connections.get(str(event_with_player["target_id"]))
                            if target_session is not None and target_session not in recipients:
                                recipients.append(target_session)
                        for other in recipients:
                            if other.websocket and other.websocket.application_state == WebSocketState.CONNECTED:
                                try:
                                    await other.websocket.send_text(json.dumps(event_with_player))
                                except Exception:
                                    await manager.drop(other)

                elif msg_type == "move":
                    # Server-authoritative map change: only known maps accepted.
                    new_map = str(msg.get("map_id", "")).strip()
                    if _is_valid_map_id(new_map):
                        previous_map = player.map_id
                        if new_map != player.map_id:
                            player.map_id = new_map
                            await npc_manager.spawn_map_npcs(new_map)
                            # Phase 1: a real map transition is a journal event.
                            # Journalled AFTER the authoritative state changed, so
                            # the entry can only ever describe a map the player
                            # really reached.
                            await record_and_push_journal(
                                player, journal.EVENT_MAP_ENTER,
                                f"Harita {new_map} girildi",
                                journal.SEVERITY_INFO,
                                {"map_id": new_map, "from_map": previous_map},
                            )
                        try:
                            await websocket.send_text(json.dumps({
                                "type": "map_changed",
                                "map_id": player.map_id,
                            }))
                        except Exception:
                            player.disconnected = True

                elif msg_type == "heartbeat":
                    player.last_heartbeat = time.time()
                    await websocket.send_text(json.dumps({"type": "heartbeat_ack"}))

        except Exception:
            pass
        finally:
            await manager.disconnect(player.player_id, websocket)

    @app.get("/api/session_info")
    async def api_session_info(request: Request):
        auth_header: Optional[str] = request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")

        token = auth_header[7:]
        try:
            payload = _decode_token(token, secret_key)
        except HTTPException:
            raise

        account_id = int(payload["sub"])
        player_id = payload["player_id"]
        username = payload["username"]
        session_jti = payload.get("session_jti", "")

        is_active = False
        ship_id = SHIP_ID_DEFAULT
        expires_at = _unix_now() + 3600

        if session_jti:
            # Always read sessions from the SAME database the live session
            # manager authenticates against (single source of truth; avoids a
            # stale import-time path binding).
            async with aiosqlite.connect(manager.db_path) as db:
                cursor = await db.execute(
                    "SELECT active, ship_id, expires_at FROM sessions WHERE refresh_jti = ?",
                    (session_jti,),
                )
                row = await cursor.fetchone()
                if row:
                    is_active = row[0] == 1
                    ship_id = row[1] or SHIP_ID_DEFAULT
                    expires_at = row[2]
                else:
                    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Session not found")

        ws_player = manager.active_connections.get(player_id)
        connected = ws_player is not None and not ws_player.disconnected

        return {
            "authenticated": True,
            "session_active": is_active,
            "websocket_connected": connected,
            "account_id": account_id,
            "player_id": player_id,
            "username": username,
            "ship_id": ship_id,
            "map_id": ws_player.map_id if connected else "1-1",
            "position": list(ws_player.position) if connected else [0.0, 0.0],
            "hp": ws_player.hp if connected else 100.0,
            "shield": ws_player.shield if connected else 100.0,
            "last_heartbeat": ws_player.last_heartbeat if connected else 0.0,
            "connected_at": ws_player.connected_at if connected else 0.0,
            "expires_at": expires_at,
            "tick_hz": WORLD_TICK_HZ,
            "tick_interval": TICK_INTERVAL,
        }

    class _SessionInfoResponse(BaseModel):
        pass


# ---------------------------------------------------------------------------
# NPC Server State (authoritative)
# ---------------------------------------------------------------------------
NPC_STATS = {
    "zyron_raider": {"health": 800.0, "shield": 560.0, "speed": 90.0,
                     "damage": 50.0,
                     "reward_xp": 412, "reward_bitcoin": 824, "reward_platinum": 3, "reward_honor": 2,
                     "attack_range": 210.0, "aggro_range": 1500.0, "passive": True},
    "nexar_fighter": {"health": 3000.0, "shield": 2100.0, "speed": 100.0,
                      "damage": 100.0,
                      "reward_xp": 824, "reward_bitcoin": 1280, "reward_platinum": 8, "reward_honor": 4,
                      "attack_range": 210.0, "aggro_range": 1100.0, "passive": False},
    "nexar_destroyer": {"health": 7000.0, "shield": 4900.0, "speed": 390.0,
                        "damage": 250.0,
                        "reward_xp": 1863, "reward_bitcoin": 2600, "reward_platinum": 14, "reward_honor": 6,
                        "attack_range": 210.0, "aggro_range": 1250.0, "passive": False},
    "nexar_warlord": {"health": 16000.0, "shield": 11200.0, "speed": 125.0,
                      "damage": 500.0,
                      "reward_xp": 3526, "reward_bitcoin": 8670, "reward_platinum": 24, "reward_honor": 8,
                      "attack_range": 210.0, "aggro_range": 1400.0, "passive": False},
    "void_reaper": {"health": 100000.0, "shield": 70000.0, "speed": 175.0,
                    "damage_min": 1000, "damage_max": 1400,
                    "reward_xp": 18376, "reward_bitcoin": 72000, "reward_platinum": 96, "reward_honor": 34,
                    "attack_range": 210.0, "aggro_range": 1550.0, "passive": False},
    "void_predator": {"health": 48000.0, "shield": 33600.0, "speed": 290.0,
                      "damage_min": 900, "damage_max": 1100,
                      "reward_xp": 6542, "reward_bitcoin": 15200, "reward_platinum": 48, "reward_honor": 24,
                      "attack_range": 210.0, "aggro_range": 1650.0, "passive": False},
    "abyss_guardian": {"health": 192000.0, "shield": 134400.0, "speed": 200.0,
                       "damage_min": 1800, "damage_max": 2200,
                       "reward_xp": 23400, "reward_bitcoin": 130000, "reward_platinum": 125, "reward_honor": 96,
                       "attack_range": 210.0, "aggro_range": 1500.0, "passive": True},
    "void_ravager": {"health": 384000.0, "shield": 268800.0, "speed": 220.0,
                     "damage_min": 3000, "damage_max": 4000,
                     "reward_xp": 40248, "reward_bitcoin": 315792, "reward_platinum": 231, "reward_honor": 211,
                     "attack_range": 210.0, "aggro_range": 1500.0, "passive": True},
    "void_guardian": {"health": 45000.0, "shield": 31500.0, "speed": 390.0,
                      "damage_min": 2000, "damage_max": 2200,
                      "reward_xp": 0, "reward_bitcoin": 0, "reward_platinum": 0, "reward_honor": 0,
                      "attack_range": 210.0, "aggro_range": 2000.0, "passive": False},
    "titan_nemesis": {"health": 1900000.0, "shield": 1800000.0, "speed": 25.0,
                      "damage": 18000.0,
                      "reward_xp": 0, "reward_bitcoin": 0, "reward_platinum": 0, "reward_honor": 0,
                      "attack_range": 210.0, "aggro_range": 1500.0, "passive": False},
    "cubikon": {"health": 2500000.0, "shield": 0.0, "speed": 30.0,
                "damage_min": 0, "damage_max": 0,
                "reward_xp": 250000, "reward_bitcoin": 1000000, "reward_platinum": 800, "reward_honor": 2500,
                "attack_range": 420.0, "aggro_range": 0.0, "passive": True},
}

# Spawn table - matches scripts/main.gd npc_table format:
# [type_name, normal_count, boss_count, hp_fallback, move_speed, optional_uber_bool]
NPC_SPAWN_TABLE = {
    "1-1": [["zyron_raider", 30, 10, 4500.0, 90.0]],
    "2-1": [["zyron_raider", 30, 10, 4500.0, 90.0]],
    "3-1": [["zyron_raider", 30, 10, 4500.0, 90.0]],

    "1-2": [["zyron_raider", 20, 6, 4500.0, 90.0], ["nexar_fighter", 20, 6, 8000.0, 100.0]],
    "2-2": [["zyron_raider", 20, 6, 4500.0, 90.0], ["nexar_fighter", 20, 6, 8000.0, 100.0]],
    "3-2": [["zyron_raider", 20, 6, 4500.0, 90.0], ["nexar_fighter", 20, 6, 8000.0, 100.0]],

    "1-3": [
        ["nexar_fighter", 20, 6, 8000.0, 100.0],
        ["nexar_destroyer", 20, 6, 7000.0, 390.0],
        ["nexar_warlord", 20, 6, 16000.0, 125.0],
        ["void_reaper", 10, 3, 110000.0, 175.0],
    ],
    "2-3": [
        ["nexar_fighter", 20, 6, 8000.0, 100.0],
        ["nexar_destroyer", 20, 6, 7000.0, 390.0],
        ["nexar_warlord", 20, 6, 16000.0, 125.0],
        ["void_reaper", 10, 3, 110000.0, 175.0],
    ],
    "3-3": [
        ["nexar_fighter", 20, 6, 8000.0, 100.0],
        ["nexar_destroyer", 20, 6, 7000.0, 390.0],
        ["nexar_warlord", 20, 6, 16000.0, 125.0],
        ["void_reaper", 10, 3, 110000.0, 175.0],
    ],

    "1-4": [["void_predator", 30, 10, 48000.0, 290.0], ["abyss_guardian", 15, 5, 75000.0, 260.0]],
    "2-4": [["void_predator", 30, 10, 48000.0, 290.0], ["abyss_guardian", 15, 5, 75000.0, 260.0]],
    "3-4": [["void_predator", 30, 10, 48000.0, 290.0], ["abyss_guardian", 15, 5, 75000.0, 260.0]],

    "1-5": [
        ["void_predator", 30, 10, 48000.0, 290.0],
        ["void_ravager", 15, 5, 120000.0, 300.0],
        ["cubikon", 1, 0, 2500000.0, 30.0],
    ],
    "2-5": [
        ["void_predator", 30, 10, 48000.0, 290.0],
        ["void_ravager", 15, 5, 120000.0, 300.0],
        ["cubikon", 1, 0, 2500000.0, 30.0],
    ],
    "3-5": [
        ["void_predator", 30, 10, 48000.0, 290.0],
        ["void_ravager", 15, 5, 120000.0, 300.0],
        ["cubikon", 1, 0, 2500000.0, 30.0],
    ],

    # 4-5: Uber map - all variants are uber (x3 stats)
    "4-5": [
        ["zyron_raider", 12, 0, 4500.0, 90.0, True],
        ["nexar_fighter", 12, 0, 8000.0, 100.0, True],
        ["nexar_destroyer", 10, 0, 7000.0, 390.0, True],
        ["nexar_warlord", 10, 0, 16000.0, 125.0, True],
        ["void_reaper", 8, 0, 110000.0, 175.0, True],
        ["void_predator", 8, 0, 48000.0, 290.0, True],
        ["abyss_guardian", 8, 0, 75000.0, 260.0, True],
        ["void_ravager", 6, 0, 120000.0, 300.0, True],
        ["void_guardian", 8, 0, 45000.0, 390.0, True],
        ["titan_nemesis", 2, 0, 1900000.0, 25.0, True],
    ],

    # BOSS map - handled separately
    "BOSS": [
        ["titan_nemesis", 3, 0, 1900000.0, 25.0],
        ["void_guardian", 27, 0, 45000.0, 390.0],
    ],
}

# Boss multiplier (same as client)
BOSS_MULTIPLIER = 2.0
UBER_MULTIPLIER = 3.0

# Laser weapon damage multipliers (from weapon_system.gd LASERS dict)
LASER_MULTIPLIERS = [1.0, 2.0, 3.0, 4.0, 3.0, 6.0]  # X1, X2, X3, X4, SAB, RSB
AMMO_KEYS = ["X1", "X2", "X3", "X4", "SAB", "RSB"]
PLAYER_LASER_RANGE = 550.0
PLAYER_LASER_PROJECTILE_SPEED = 1850.0
PLAYER_LASER_MIN_TRAVEL_TIME = 0.10
PLAYER_LASER_MAX_TRAVEL_TIME = 0.32
SAB_SHIELD_FACTOR = 2.0

# Combat cooldown settings
FIRE_COOLDOWN_SECONDS = 0.3  # Minimum time between shots from same player
MAX_LASER_DAMAGE = 100000.0  # Anti-cheat cap on damage


# ---------------------------------------------------------------------------
# Phase 2/4 - progression applied on an NPC death
# ---------------------------------------------------------------------------
async def apply_npc_kill_progression(db_path: str, player_id: str,
                                    reward: dict, map_id: str) -> None:
    """Apply XP, honor, the kill counter and quest progress after an NPC dies.

    Called from the NPC manager only AFTER `_grant_server_currency` has
    confirmed the BTC/PLT payout, so the whole chain is "kill -> reward -> XP ->
    honor -> stats -> journal -> quest".

    The XP and honor amounts are read from the SERVER's own reward dict; nothing
    here trusts a client value. Failures are swallowed deliberately: a
    progression write must never undo a reward the player already received.
    """
    try:
        import player_state
        from routes_p45 import _advance_quest

        async with aiosqlite.connect(db_path) as db:
            await player_state.add_kill(db, player_id, "npc")
            leveled, old_level, new_level, _ = await player_state.add_xp(
                db, player_id, int(reward.get("xp", 0) or 0)
            )
            if int(reward.get("honor", 0) or 0):
                await player_state.add_honor(
                    db, player_id, int(reward["honor"])
                )
            if leveled:
                await journal.record_event(
                    db, player_id, journal.EVENT_LEVEL_UP,
                    f"Seviye atlandi: {new_level}", journal.SEVERITY_GOOD,
                    {"from": old_level, "to": new_level,
                     "trigger": "npc_kill"},
                )
            await _advance_quest(db, player_id, "npc_kill",
                                 extra={"map_id": map_id})
            await db.commit()
    except Exception as exc:  # pragma: no cover - defensive
        print(f"[NOVAGATE] npc progression skipped player={player_id} "
              f"err={exc}", flush=True)


# Server-authoritative map whitelist (map isolation: players only ever share
# a map_id that this server recognizes).
VALID_MAP_IDS: set[str] = (
    {f"{region}-{n}" for region in (1, 2, 3) for n in range(1, 7)}
    | {"PVP", "BOSS", "4-5"}
)


def _is_valid_map_id(map_id: str) -> bool:
    return str(map_id).strip().upper() in {m.upper() for m in VALID_MAP_IDS}


def calculate_company_relation(observer_company: str, target_company: str) -> str:
    """Single server-side authority for company/team relation.

    Used by BOTH the world snapshot (what the client is told) and the PvP
    validation (who may be shot), so the two can never disagree.
    """
    observer = str(observer_company or "").strip().upper()
    target = str(target_company or "").strip().upper()
    if not observer or not target:
        # No company selected on one side: nobody is a valid PvP target.
        return "neutral"
    return "friendly" if observer == target else "enemy"


async def handle_player_fire(attacker: "PlayerSession", target_player_id: str,
                             weapon: int, target_x: float, target_y: float) -> Optional[dict]:
    """Server-authoritative player-vs-player fire.

    Validation order (all checks server-side, client cannot bypass):
      1. attacker/target session state
      2. not the same player
      3. same map (map isolation)
      4. company relation (same company = friendly, cannot be targeted)
      5. weapon slot + range (PLAYER_LASER_RANGE)
      6. damage via the shared weapon damage formula (existing values only)

    Returns a combat event dict, or None when the shot is rejected.
    """
    if attacker.disconnected:
        return None
    target = manager.active_connections.get(target_player_id)
    if target is None or target.disconnected:
        return None

    # 1) Same player can never be a target.
    if target.player_id == attacker.player_id:
        return None

    # 2) Map isolation: no cross-map PvP.
    if target.map_id != attacker.map_id:
        return None

    # 3) Company relation: same company = friendly, no company = neutral.
    #    Both are rejected server-side. Only a real enemy company is targetable.
    if calculate_company_relation(attacker.company, target.company) != "enemy":
        return None

    # 4) Range check in server space.
    distance = ((target.position_x - attacker.position_x) ** 2 +
                (target.position_y - attacker.position_y) ** 2) ** 0.5
    if distance > PLAYER_LASER_RANGE:
        return None

    if weapon < 1 or weapon > len(LASER_MULTIPLIERS):
        return None

    damage = _calculate_laser_damage(weapon, attacker, None, distance)
    if damage > MAX_LASER_DAMAGE:
        damage = MAX_LASER_DAMAGE

    event = {
        "type": "player_hit",
        "attacker_id": attacker.player_id,
        "attacker_username": attacker.username,
        "attacker_company": attacker.company,
        "target_id": target.player_id,
        "target_username": target.username,
        "target_company": target.company,
        "weapon": weapon,
        "damage": round(damage, 1),
        "distance": round(distance, 1),
    }

    if weapon == 5:
        # SAB: drains target shield and transfers it to the attacker.
        drained = min(target.shield, damage)
        target.shield -= drained
        attacker.shield = min(attacker.max_shield, attacker.shield + drained)
        event["shield_drain"] = round(drained, 1)
    else:
        # Regular laser: shield first, then HP (existing pipeline).
        remaining = damage
        if target.shield > 0:
            absorbed = min(target.shield, remaining)
            target.shield -= absorbed
            remaining -= absorbed
        if remaining > 0:
            target.hp -= remaining

    event["target_shield"] = round(target.shield, 1)
    event["target_hp"] = round(target.hp, 1)

    if target.hp <= 0:
        # Death + respawn are server decisions; the killed player is restored
        # to full state so the session keeps living.
        event["type"] = "player_death"
        event["target_hp"] = 0.0
        target.hp = target.max_hp
        target.shield = target.max_shield
        event["respawn"] = True

        # Phase 1: PvP is journalled server-side. The killer and the victim each
        # get their own entry - the client cannot author either one, which is
        # what makes "kim kimi öldürdü" in the Seyir Defteri trustworthy.
        # `record_and_push_journal` swallows its own failures, so a journal
        # problem can never break the combat pipeline.
        await record_and_push_journal(
            attacker, journal.EVENT_PLAYER_KILL,
            f"{target.username} vuruldu", journal.SEVERITY_GOOD,
            {"victim": target.username, "target_id": target.player_id,
             "weapon": weapon},
        )
        await record_and_push_journal(
            target, journal.EVENT_DEATH,
            f"{attacker.username} tarafindan oldun", journal.SEVERITY_BAD,
            {"killer": attacker.username, "killer_id": attacker.player_id,
             "weapon": weapon},
        )

    return event


@dataclass
class NPCState:
    npc_id: str
    npc_type: str
    map_id: str
    position_x: float
    position_y: float
    health: float
    max_health: float
    shield: float
    max_shield: float
    alive: bool
    spawn_time: float
    respawn_at: float
    is_boss: bool = False
    is_uber: bool = False
    first_attacker_player_id: str = ""
    target_player_id: str = ""


class NPCManager:
    """Server-authoritative NPC state manager."""

    def __init__(self):
        self.npcs: dict[str, NPCState] = {}
        self._lock = asyncio.Lock()
        self._id_counter = 0

    def _gen_npc_id(self) -> str:
        self._id_counter += 1
        return f"npc_{int(time.time())}_{self._id_counter}"

    async def spawn_map_npcs(self, map_id: str) -> None:
        """Spawn NPCs for a map based on NPC_SPAWN_TABLE.

        Table format: [type_name, normal_count, boss_count, hp_fallback, move_speed, optional_uber_bool]
        - normal_count spawns regular NPCs
        - boss_count spawns boss-variant NPCs (x2 health/shield/damage/rewards)
        - make_uber flag: all spawns become uber-variant (x3 health/shield/damage/rewards)
        """
        if map_id not in NPC_SPAWN_TABLE:
            return

        # Check if already spawned (avoid duplicate spawns)
        existing = self.get_npcs_on_map(map_id)
        if existing:
            return

        rng = random.Random(hash(f"{map_id}_{id(self)}") % 2147483647)
        is_boss_map = map_id == "BOSS"

        for spawn_def in NPC_SPAWN_TABLE[map_id]:
            npc_type = str(spawn_def[0])
            normal_count = int(spawn_def[1])
            boss_count = int(spawn_def[2])
            # hp_fallback and move_speed are in the table but npc_stats override them
            make_uber = len(spawn_def) > 5 and bool(spawn_def[5])

            if npc_type not in NPC_STATS:
                continue

            stats = NPC_STATS[npc_type]
            base_hp = stats["health"]
            base_shield = stats["shield"]

            spawn_range = (-7000.0, 7000.0) if is_boss_map else (-5600.0, 5600.0)
            spawn_y_range = (-7000.0, 7000.0) if is_boss_map else (-3800.0, 3800.0)

            # Spawn normal variants
            for i in range(normal_count):
                hp = base_hp
                shield = base_shield
                if make_uber:
                    hp *= UBER_MULTIPLIER
                    shield *= UBER_MULTIPLIER

                x = rng.uniform(spawn_range[0], spawn_range[1])
                y = rng.uniform(spawn_y_range[0], spawn_y_range[1])
                npc_id = self._gen_npc_id()
                self.npcs[npc_id] = NPCState(
                    npc_id=npc_id,
                    npc_type=npc_type,
                    map_id=map_id,
                    position_x=x,
                    position_y=y,
                    health=hp,
                    max_health=hp,
                    shield=shield,
                    max_shield=shield,
                    alive=True,
                    spawn_time=time.time(),
                    respawn_at=0.0,
                    is_boss=False,
                    is_uber=make_uber,
                )

            # Spawn boss variants (x2 health/shield)
            for i in range(boss_count):
                hp = base_hp * BOSS_MULTIPLIER
                shield = base_shield * BOSS_MULTIPLIER
                if make_uber:
                    hp *= UBER_MULTIPLIER
                    shield *= UBER_MULTIPLIER

                x = rng.uniform(spawn_range[0], spawn_range[1])
                y = rng.uniform(spawn_y_range[0], spawn_y_range[1])
                npc_id = self._gen_npc_id()
                self.npcs[npc_id] = NPCState(
                    npc_id=npc_id,
                    npc_type=npc_type,
                    map_id=map_id,
                    position_x=x,
                    position_y=y,
                    health=hp,
                    max_health=hp,
                    shield=shield,
                    max_shield=shield,
                    alive=True,
                    spawn_time=time.time(),
                    respawn_at=0.0,
                    is_boss=True,
                    is_uber=make_uber,
                )

    def get_npc(self, npc_id: str) -> Optional[NPCState]:
        return self.npcs.get(npc_id)

    async def admin_spawn(self, npc_type: str, map_id: str, x: float, y: float) -> dict:
        if npc_type not in NPC_STATS:
            raise ValueError("Unknown NPC type")
        async with self._lock:
            stats = NPC_STATS[npc_type]
            npc_id = self._gen_npc_id()
            npc = NPCState(
                npc_id=npc_id,
                npc_type=npc_type,
                map_id=map_id,
                position_x=float(x),
                position_y=float(y),
                health=stats["health"],
                max_health=stats["health"],
                shield=stats["shield"],
                max_shield=stats["shield"],
                alive=True,
                spawn_time=time.time(),
                respawn_at=0.0,
            )
            self.npcs[npc_id] = npc
            return self.to_dict(npc)

    async def admin_remove(self, npc_id: str) -> bool:
        async with self._lock:
            return self.npcs.pop(npc_id, None) is not None

    def admin_list(self) -> list[dict]:
        return [self.to_dict(npc) for npc in self.npcs.values()]

    def get_npcs_on_map(self, map_id: str) -> list[NPCState]:
        return [n for n in self.npcs.values() if n.map_id == map_id]

    async def handle_fire(self, player_id: str, player_position: tuple[float, float],
                          weapon: int, target_x: float, target_y: float) -> Optional[dict]:
        """Process combat fire from client. Returns combat event or None if rejected."""
        player = manager.active_connections.get(player_id)
        if not player or player.disconnected:
            return None

        # Validate weapon (1-6 maps to ammo slot)
        if weapon < 1 or weapon > 6:
            return None

        # Find NPCs near the target position within range
        async with self._lock:
            npcs = [n for n in self.npcs.values()
                    if n.map_id == player.map_id and n.alive]

            if not npcs:
                return None

            # Find the closest NPC to the target position within range
            closest_npc = None
            closest_dist = float("inf")
            for npc in npcs:
                dist = ((npc.position_x - target_x) ** 2 + (npc.position_y - target_y) ** 2) ** 0.5
                if dist < closest_dist and dist <= PLAYER_LASER_RANGE:
                    closest_dist = dist
                    closest_npc = npc

            if not closest_npc:
                return None

            # Range validation (server computes distance)
            player_pos = (player.position_x, player.position_y)
            dist_to_target = ((closest_npc.position_x - player_pos[0]) ** 2 +
                             (closest_npc.position_y - player_pos[1]) ** 2) ** 0.5
            if dist_to_target > PLAYER_LASER_RANGE:
                return None

            # Calculate damage server-side (not trusting client)
            damage = _calculate_laser_damage(weapon, player, closest_npc, dist_to_target)
            if damage <= 0:
                return None

            # Anti-cheat: cap damage
            if damage > MAX_LASER_DAMAGE:
                damage = MAX_LASER_DAMAGE

            # Apply damage
            event = _apply_npc_damage(closest_npc, damage, weapon, player_id, player)

            # If the NPC died, persist reward to server economy FIRST.
            # If the payout fails the kill is rolled back on the NPC so the
            # world state and the economy can never disagree, and no reward
            # event is emitted to any client.
            if event.get("type") == "npc_death" and event.get("reward"):
                reward = event["reward"]
                granted = await _grant_server_currency(player_id, reward, closest_npc.npc_type)
                if not granted:
                    _revive_npc_after_failed_reward(closest_npc)
                    return None
                event["npc_type"] = closest_npc.npc_type

                # Phase 1: the kill is journalled only AFTER the payout
                # succeeded, so the Seyir Defteri can never advertise a reward
                # the economy table does not contain.
                await record_and_push_journal(
                    player, journal.EVENT_NPC_KILL,
                    f"{closest_npc.npc_type} imha edildi",
                    journal.SEVERITY_GOOD,
                    {
                        "npc_type": closest_npc.npc_type,
                        "npc_id": closest_npc.npc_id,
                        "map_id": closest_npc.map_id,
                        "reward": reward,
                    },
                )

                # Phase 2/4: XP, honor, the kill counter, the level-up journal
                # entry and any active quest all follow from this one death.
                # The BTC/PLT above are untouched, and the XP/honor amounts come
                # from the SERVER reward table, never from the client.
                # manager.db_path is the same path _grant_server_currency just
                # wrote the payout to, so both halves land in one database.
                await apply_npc_kill_progression(
                    manager.db_path, player_id, reward, closest_npc.map_id,
                )

            return event

    def to_dict(self, npc: NPCState) -> dict:
        return {
            "npc_id": npc.npc_id,
            "npc_type": npc.npc_type,
            "x": round(npc.position_x, 2),
            "y": round(npc.position_y, 2),
            "health": round(npc.health, 1),
            "max_health": round(npc.max_health, 1),
            "shield": round(npc.shield, 1),
            "max_shield": round(npc.max_shield, 1),
            "alive": npc.alive,
            "is_boss": npc.is_boss,
            "is_uber": npc.is_uber,
            "target_player_id": npc.target_player_id,
        }


npc_manager = NPCManager()


def _calculate_laser_damage(weapon_slot: int, player: PlayerSession,
                            npc: NPCState, distance: float) -> float:
    """Calculate damage based on weapon, distance, and NPC type. Server-authoritative.

    Weapon slot is 1-6 (X1=1, X2=2, X3=3, X4=4, SAB=5, RSB=6).
    Damage uses the player's equipment damage * ammo multiplier with falloff.
    """
    # Base damage from player's ship equipment
    # In the Godot client, get_laser_damage() returns base laser damage.
    # For the server, we use a reasonable base damage per ship type.
    # The actual value is validated client-side but computed server-side.
    base_damage = 100.0  # Default base damage; would come from player equipment in production

    # Ammo multiplier (from weapon_system.gd LASERS dict)
    ammo_index = weapon_slot - 1  # 0-5
    if ammo_index < 0 or ammo_index >= len(LASER_MULTIPLIERS):
        return 0.0
    multiplier = LASER_MULTIPLIERS[ammo_index]

    # Damage falloff: reduce damage at longer range (20% at max range)
    falloff = 1.0 - (distance / PLAYER_LASER_RANGE) * 0.2
    falloff = max(0.8, falloff)

    damage = base_damage * multiplier * falloff

    # SAB special: drains shield, doesn't deal HP damage directly
    if ammo_index == 4:  # SAB
        damage = base_damage * SAB_SHIELD_FACTOR * falloff

    return damage


def _apply_npc_damage(npc: NPCState, damage: float, weapon_slot: int,
                      attacker_id: str, attacker: PlayerSession) -> dict:
    """Apply damage to NPC, return combat event."""
    event = {
        "type": "npc_hit",
        "npc_id": npc.npc_id,
        "attacker_id": attacker_id,
        "weapon": weapon_slot,
        "damage": round(damage, 1),
        "target_id": npc.npc_id,
    }

    ammo_index = weapon_slot - 1

    if ammo_index == 4:  # SAB - shield drain
        if npc.shield > 0:
            absorbed = min(npc.shield, damage)
            npc.shield -= absorbed
            # Give SAB shield back to player
            if attacker and not attacker.disconnected:
                attacker.shield = min(attacker.max_shield, attacker.shield + absorbed)
            event["shield_drain"] = round(absorbed, 1)
            event["npc_shield"] = round(npc.shield, 1)
    else:
        # Regular laser damage: shield first, then HP
        remaining = damage
        if npc.shield > 0:
            absorbed = min(npc.shield, remaining)
            npc.shield -= absorbed
            remaining -= absorbed

        if remaining > 0:
            npc.health -= remaining
            event["npc_health"] = round(npc.health, 1)

        event["npc_shield"] = round(npc.shield, 1)

    # Check death
    if npc.health <= 0 and npc.alive:
        npc.alive = False
        npc.respawn_at = time.time() + random.uniform(4.0, 8.0)
        event["type"] = "npc_death"
        event["reward"] = _calculate_npc_reward(npc, attacker_id)
        event["npc_health"] = 0.0

    return event


def _calculate_npc_reward(npc: NPCState, attacker_id: str) -> dict:
    """Calculate reward for killing an NPC. Server-authoritative."""
    if npc.npc_type not in NPC_STATS:
        return {"xp": 0, "bitcoin": 0, "platinum": 0, "honor": 0}

    stats = NPC_STATS[npc.npc_type]
    reward_mult = UBER_MULTIPLIER if npc.is_uber else (BOSS_MULTIPLIER if npc.is_boss else 1.0)

    return {
        "xp": int(stats["reward_xp"] * reward_mult),
        "bitcoin": int(stats["reward_bitcoin"] * reward_mult),
        "platinum": int(stats["reward_platinum"] * reward_mult),
        "honor": int(stats["reward_honor"] * reward_mult),
        "killed_by": attacker_id,
    }


import aiosqlite as _aiosqlite


def _revive_npc_after_failed_reward(npc: NPCState) -> None:
    """Roll an NPC death back when the server-side reward payout failed.

    Keeps the authoritative world state and the economy consistent: the player
    is never told "you killed it" unless the reward was really persisted.
    """
    npc.alive = True
    npc.respawn_at = 0.0
    npc.health = npc.max_health
    npc.shield = npc.max_shield


async def _grant_server_currency(player_id: str, reward: dict, npc_type: str) -> bool:
    """Persist an NPC kill reward to the server economy table.

    Returns True only when the whole payout (economy update + transaction
    log) committed successfully. A failure is logged and reported as False
    instead of being silently swallowed, so callers can refuse to hand the
    reward to the client.
    """
    btc = int(reward.get("bitcoin", 0) or 0)
    plt = int(reward.get("platinum", 0) or 0)
    now = time.time()

    try:
        async with _aiosqlite.connect(manager.db_path) as db:
            await db.execute("BEGIN IMMEDIATE TRANSACTION")
            cursor = await db.execute(
                "SELECT btc, plt, gold FROM economy WHERE player_id = ?",
                (player_id,),
            )
            row = await cursor.fetchone()
            if row:
                new_btc = row[0] + btc
                new_plt = row[1] + plt
                await db.execute(
                    "UPDATE economy SET btc = ?, plt = ?, gold = ?, updated_at = ? WHERE player_id = ?",
                    (new_btc, new_plt, row[2], int(now), player_id),
                )
            else:
                await db.execute(
                    "INSERT INTO economy (player_id, btc, plt, gold, updated_at) VALUES (?, ?, ?, 0, ?)",
                    (player_id, btc, plt, int(now)),
                )

            # Reference id must be unique per kill, otherwise a second kill in
            # the same second would hit the transactions PRIMARY KEY and roll
            # back the entire payout.
            reward_ref = f"npc:{npc_type}:{int(now * 1000)}:{player_id}"
            if btc != 0:
                await db.execute(
                    "INSERT INTO transactions (id, player_id, currency, amount, reason, reference_id, timestamp) "
                    "VALUES (?, ?, 'BTC', ?, ?, NULL, ?)",
                    (f"tx_{reward_ref}_btc", player_id, btc, f"npc_kill:{npc_type}", int(now)),
                )
            if plt != 0:
                await db.execute(
                    "INSERT INTO transactions (id, player_id, currency, amount, reason, reference_id, timestamp) "
                    "VALUES (?, ?, 'PLT', ?, ?, NULL, ?)",
                    (f"tx_{reward_ref}_plt", player_id, plt, f"npc_kill:{npc_type}", int(now)),
                )

            await db.commit()
        return True
    except Exception as exc:  # noqa: BLE001 - payout must never be silent
        print(
            f"[NOVAGATE] npc reward FAILED player_id={player_id} npc={npc_type} error={exc}",
            flush=True,
        )
        return False


# ---------------------------------------------------------------------------
# Startup integration
# ---------------------------------------------------------------------------
async def on_startup(app, secret_key: str, db_path: str):
    """Called from main.py startup to initialize WebSocket world."""
    manager.configure(secret_key, db_path)
    global _world_task, _ping_task
    await start_world_loop()
    if _ping_task is None or _ping_task.done():
        _ping_task = asyncio.create_task(_send_server_pings())
    print(f"[NOVAGATE] World tick started", flush=True)
