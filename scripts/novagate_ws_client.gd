extends Node

# NovaGate WebSocket client for online world session.
# Connects to /ws after HTTP login, manages connection states,
# sends movement input, and receives server-authoritative world updates.

signal connected
signal disconnected
signal world_update(data)
signal remote_player_update(player_id, position, state)
signal remote_player_left(player_id)
signal welcome_received(tick_hz, tick_interval)
signal npc_hit(npc_id, weapon, damage, npc_health, npc_shield)
signal npc_death(npc_id, reward)
signal npc_state_update(npcs)
signal session_kicked(reason)
signal map_changed(map_id)
signal player_combat_event(event)
# Phase 1: server-authoritative Seyir Defteri.
#   journal_event           -> one newly persisted event was pushed live
#   journal_history_synced  -> the initial bulk history arrived (count)
signal journal_event(event)
signal journal_history_synced(count)

const WS_CONNECTING = 0
const WS_CONNECTED = 1
const WS_DISCONNECTED = 2
const WS_RECONNECTING = 3

const RECONNECT_DELAY_SECONDS = 3.0
const HEARTBEAT_INTERVAL_SECONDS = 10.0
const RECONNECT_MAX_DELAY = 30.0

var server_url: String = ""
var ws: WebSocketPeer = null
var state: int = WS_DISCONNECTED

var access_token: String = ""
var player_id: String = ""
var username: String = ""

var reconnect_timer: float = 0.0
var reconnect_delay: float = RECONNECT_DELAY_SECONDS
var heartbeat_timer: float = 0.0
var tick_hz: int = 20
var tick_interval: float = 0.05

var remote_players: Dictionary = {}  # player_id -> {position, username, company, ship_id, hp, shield}
var pending_input: Vector2 = Vector2.ZERO
var last_sent_input: Vector2 = Vector2(9999.0, 9999.0)

# The ship's effective movement speed, reported to the server so both sides
# integrate the SAME movement model. MAX_SPEED on the server remains the
# hard anti-cheat ceiling.
var movement_speed: float = 0.0

# Latest server-authoritative position for THIS player (world_update.self).
var server_position: Vector2 = Vector2.ZERO
var has_server_position: bool = false

# Set when the server force-closes this account's session (logged in
# elsewhere / logged out). Prevents the automatic reconnect loop.
var kicked_by_server: bool = false
var company: String = ""

# Every inbound frame type this socket has observed, in order. Used by the
# Phase 1 E2E driver to assert which server frames actually arrived; bounded so
# a long session cannot grow it without limit.
var _seen_frame_types: Array = []

# Every distinct frame type ever received. Unlike _seen_frame_types this is NOT
# a ring buffer: the handshake frames (welcome / journal_sync) arrive first and
# would otherwise be evicted by the 20 Hz world_update + ping traffic within a
# couple of seconds, making a late assertion on them impossible.
var _received_frame_types: Dictionary = {}

@onready var account_manager = get_node("/root/AccountManager") if has_node("/root/AccountManager") else null


func _ready() -> void:
	set_process(true)
	_cleanup_websocket()


func _process(delta: float) -> void:
	match state:
		WS_CONNECTING:
			_update_connecting()
		WS_CONNECTED:
			_update_connected(delta)
		WS_DISCONNECTED:
			pass
		WS_RECONNECTING:
			_update_reconnecting(delta)


func connect_to_server(url: String, token: String, p_id: String, uname: String) -> void:
	"""Initiate WebSocket connection to the NovaGate world server.

	Args:
		url: WebSocket URL (e.g., ws://host:port)
		token: JWT access token from HTTP login
		p_id: Player ID
		uname: Username
	"""
	server_url = url
	access_token = token
	player_id = p_id
	username = uname
	kicked_by_server = false
	remote_players.clear()

	_cleanup_websocket()
	ws = WebSocketPeer.new()
	state = WS_CONNECTING

	var err = ws.connect_to_url("%s?token=%s" % [server_url, access_token.uri_encode()])
	if err != OK:
		state = WS_DISCONNECTED
		push_error("WebSocket connection failed: %s" % err)


func disconnect_from_server() -> void:
	if ws:
		ws.close()
	_cleanup_websocket()
	state = WS_DISCONNECTED


func _cleanup_websocket() -> void:
	if ws:
		ws = null


func _update_connecting() -> void:
	ws.poll()

	# A kick can be queued in the very same poll that opens or closes the
	# handshake, so the queue is drained here too. Otherwise the frame is
	# lost when the state check below fires first.
	while ws.get_available_packet_count() > 0:
		var pkt = ws.get_packet()
		_handle_message(pkt.get_string_from_utf8())

	if kicked_by_server:
		state = WS_DISCONNECTED
		disconnected.emit()
		return

	var pol = ws.get_ready_state()
	if pol == WebSocketPeer.STATE_OPEN:
		state = WS_CONNECTED
		heartbeat_timer = 0.0
		connected.emit()
	elif pol == WebSocketPeer.STATE_CLOSING or pol == WebSocketPeer.STATE_CLOSED:
		state = WS_DISCONNECTED
		disconnected.emit()


func _update_connected(delta: float) -> void:
	if not ws:
		state = WS_DISCONNECTED
		disconnected.emit()
		return

	ws.poll()

	# Drain the inbound queue BEFORE looking at the ready state.
	#
	# The server sends `session_kicked` and closes the socket in the same
	# breath. When the close is inspected first, the still-queued kick frame
	# is discarded, `kicked_by_server` stays false and the client silently
	# reconnects with a token the server already invalidated. Draining first
	# guarantees the kick is always processed.
	while ws.get_available_packet_count() > 0:
		var pkt = ws.get_packet()
		_handle_message(pkt.get_string_from_utf8())

	# A kick received in this very drain wins over the generic close path:
	# go straight to DISCONNECTED so no reconnect is ever attempted.
	if kicked_by_server:
		state = WS_DISCONNECTED
		disconnected.emit()
		return

	var pol = ws.get_ready_state()
	if pol == WebSocketPeer.STATE_CLOSING or pol == WebSocketPeer.STATE_CLOSED:
		state = WS_RECONNECTING
		reconnect_timer = 0.0
		disconnected.emit()
		return

	# Send pending input (including the zero input when stopping, once)
	if pending_input != last_sent_input:
		_send_input(pending_input)
		last_sent_input = pending_input
	pending_input = Vector2.ZERO

	# Heartbeat
	heartbeat_timer += delta
	if heartbeat_timer >= HEARTBEAT_INTERVAL_SECONDS:
		heartbeat_timer = 0.0
		ws.send_text(JSON.stringify({"type": "heartbeat"}))

	# Send ping (client-initiated)
	ws.send_text(JSON.stringify({"type": "ping"}))
	heartbeat_timer = 0.0


func _update_reconnecting(delta: float) -> void:
	# Server kicked this session (logged in elsewhere / logged out):
	# gameplay must stop and the client must NOT auto-reconnect.
	if kicked_by_server:
		state = WS_DISCONNECTED
		return
	reconnect_timer += delta
	if reconnect_timer >= reconnect_delay:
		reconnect_timer = 0.0
		state = WS_CONNECTING
		if ws:
			_cleanup_websocket()

		if access_token.is_empty():
			state = WS_DISCONNECTED
			return

		ws = WebSocketPeer.new()
		var err = ws.connect_to_url("%s?token=%s" % [server_url, access_token.uri_encode()])
		if err != OK:
			state = WS_RECONNECTING
			reconnect_timer = 0.0
			if reconnect_delay < RECONNECT_MAX_DELAY:
				reconnect_delay = minf(reconnect_delay * 1.5, RECONNECT_MAX_DELAY)
		else:
			state = WS_CONNECTING


func send_movement_input(input_x: float, input_y: float, speed: float = -1.0) -> void:
	"""Queue movement input to be sent to server.

	Client only sends input direction; server computes authoritative position.
	`speed` is the ship's own effective movement speed (PlayerShip.max_speed
	plus equipment/skill bonuses) so the server integrates the IDENTICAL model
	instead of a mismatched global constant. Negative means "unchanged"; the
	server keeps MAX_SPEED as the hard anti-cheat ceiling either way.
	"""
	if speed >= 0.0:
		movement_speed = speed
	if state != WS_CONNECTED:
		pending_input = Vector2(input_x, input_y)
		return

	pending_input = Vector2(input_x, input_y)


func send_combat_fire(weapon_slot: int, target_x: float, target_y: float, target_pid: String = "") -> void:
	"""Send combat fire request to server. Server validates and calculates damage.

	When `target_pid` is set the shot is a PvP attempt; the server re-checks
	self/company/map/range rules before any damage is applied.
	"""
	if state != WS_CONNECTED or not ws:
		return

	var msg = {
		"type": "fire",
		"weapon": weapon_slot,
		"target_x": target_x,
		"target_y": target_y,
	}
	if not target_pid.is_empty():
		msg["target_player_id"] = target_pid
	ws.send_text(JSON.stringify(msg))


func send_map_change(map_id: String) -> void:
	"""Notify the server that the client entered another map.

	map_id is validated server-side; the server keeps the authoritative
	map assignment used for map isolation.
	"""
	if state != WS_CONNECTED or not ws:
		return
	ws.send_text(JSON.stringify({"type": "move", "map_id": map_id}))


func get_server_player_state() -> Dictionary:
	"""Return the server-authoritative state for this player's connection."""
	return {
		"player_id": player_id,
		# Authoritative position from the latest world_update.self, so the
		# client can reconcile its local ship with the server's world.
		"position": server_position,
		"has_position": has_server_position,
	}


func _send_input(direction: Vector2) -> void:
	if not ws:
		return

	var msg = {
		"type": "input",
		"input_x": direction.x,
		"input_y": direction.y,
	}
	# Reported so the server moves this ship at the same speed the client
	# model uses. Omitted when unknown, which keeps the server-side
	# MAX_SPEED default.
	if movement_speed > 0.0:
		msg["speed"] = movement_speed
	ws.send_text(JSON.stringify(msg))


func _handle_message(text: String) -> void:
	var json_result = JSON.parse_string(text)
	if json_result == null:
		return
	var msg: Dictionary = json_result as Dictionary
	if msg.is_empty():
		return

	# Recorded for every frame so a test (or a debug overlay) can see exactly
	# which server frames this socket observed, in order.
	_note_frame_type(str(msg.get("type", "")))

	match msg.get("type", ""):
		"welcome":
			tick_hz = int(msg.get("tick_hz", 20))
			tick_interval = float(msg.get("tick_interval", 0.05))
			player_id = str(msg.get("player_id", player_id))
			username = str(msg.get("username", username))
			company = str(msg.get("company", company)).strip_edges().to_upper()
			welcome_received.emit(tick_hz, tick_interval)

		"session_kicked":
			# Another login for this account took over (or logout happened).
			# Stop gameplay and go back to the login screen; never reconnect.
			kicked_by_server = true
			var kick_reason := str(msg.get("reason", "account_logged_in_elsewhere"))
			session_kicked.emit(kick_reason)
			if ws:
				ws.close()

		"map_changed":
			map_changed.emit(str(msg.get("map_id", "")))

		"journal_event":
			# Phase 1: the server owns the Seyir Defteri. The frame is already
			# persisted server-side; the client only renders it. Dedupe by the
			# server-assigned id inside apply_server_journal_event() so a replay
			# from GET /journal can never produce a duplicate row.
			_apply_journal_event(msg)
			journal_event.emit(msg)

		"journal_sync":
			# Bulk history replay sent right after `welcome` so the logbook is
			# correct before the first world_update is rendered.
			var events = msg.get("events", []) as Array
			if not events.is_empty():
				GlobalState.apply_server_journal_list(events)
				journal_history_synced.emit(events.size())

		"player_hit", "player_death":
			player_combat_event.emit(msg)

		"world_update":
			_process_self_state(msg)
			world_update.emit(msg)
			_process_remote_players(msg)
			_process_npc_state(msg)

		"ping":
			ws.send_text(JSON.stringify({"type": "pong"}))

		"pong":
			# Server received our heartbeat
			pass

		"heartbeat_ack":
			pass

		"npc_hit":
			npc_hit.emit(
				msg.get("npc_id", ""),
				int(msg.get("weapon", 1)),
				float(msg.get("damage", 0)),
				float(msg.get("npc_health", 0)),
				float(msg.get("npc_shield", 0))
			)

		"npc_death":
			var reward: Dictionary = msg.get("reward", {}) as Dictionary
			var npc_id := str(msg.get("npc_id", ""))
			var npc_type := str(msg.get("npc_type", ""))
			if npc_type.is_empty():
				var cached_npc: Dictionary = remote_npcs.get(npc_id, {}) as Dictionary
				npc_type = str(cached_npc.get("npc_type", ""))
			reward = reward.duplicate(true)
			reward["attacker_id"] = str(msg.get("attacker_id", ""))
			reward["npc_type"] = npc_type
			npc_death.emit(npc_id, reward)



# --- 8b. helper: every frame type this socket has seen, in order ------
func get_seen_frame_types() -> Array:
	return _seen_frame_types.duplicate()


func has_received_frame(type_name: String) -> bool:
	return _received_frame_types.has(type_name)


func get_received_frame_types() -> Array:
	return _received_frame_types.keys()


func _note_frame_type(type_name: String) -> void:
	if type_name.is_empty():
		return
	_received_frame_types[type_name] = true
	# Bounded: a long session would otherwise grow this without limit.
	if _seen_frame_types.size() >= 64:
		_seen_frame_types.pop_front()
	_seen_frame_types.append(type_name)


func _apply_journal_event(payload: Dictionary) -> void:
	# Route into GlobalState, which owns dedupe + the 300-entry cap. Guarded
	# because the WS client can be constructed before the autoload is ready in
	# editor/--script contexts.
	var gs = get_node_or_null("/root/GlobalState")
	if gs != null and gs.has_method("apply_server_journal_event"):
		gs.call("apply_server_journal_event", payload)


func _process_self_state(update: Dictionary) -> void:
	# The server echoes the receiver's OWN authoritative position in
	# world_update.self (`players` only carries peers). This is what keeps
	# the client's view of its ship and the server's authoritative position on
	# the same movement model.
	var self_state = update.get("self", null)
	if not (self_state is Dictionary):
		return
	var entry: Dictionary = self_state
	server_position = Vector2(float(entry.get("x", 0.0)), float(entry.get("y", 0.0)))
	has_server_position = true


func _process_remote_players(update: Dictionary) -> void:
	var players = update.get("players", []) as Array
	var seen_ids: Dictionary = {}

	for p in players:
		if p is Dictionary:
			var pid = str(p.get("player_id", ""))
			if pid.is_empty() or pid == player_id:
				# Never spawn our own player as a remote ship.
				continue
			seen_ids[pid] = true
			var pos = Vector2(float(p.get("x", 0)), float(p.get("y", 0)))
			var entry = remote_players.get(pid)
			if entry == null:
				entry = {
					"player_id": pid,
					"username": str(p.get("username", "")),
					"company": str(p.get("company", "")).to_upper(),
					"relation": str(p.get("relation", "enemy")).to_lower(),
					"ship_id": str(p.get("ship_id", "")),
					"map_id": str(p.get("map_id", "")),
					"position": pos,
					"hp": float(p.get("hp", 100)),
					"shield": float(p.get("shield", 100)),
					"max_hp": float(p.get("max_hp", 100)),
					"max_shield": float(p.get("max_shield", 100)),
				}
				remote_players[pid] = entry
				remote_player_update.emit(pid, pos, entry)
			else:
				entry["position"] = pos
				entry["username"] = str(p.get("username", entry["username"]))
				entry["company"] = str(p.get("company", entry["company"])).to_upper()
				entry["relation"] = str(p.get("relation", entry["relation"])).to_lower()
				entry["ship_id"] = str(p.get("ship_id", entry["ship_id"]))
				entry["map_id"] = str(p.get("map_id", entry["map_id"]))
				entry["hp"] = float(p.get("hp", entry["hp"]))
				entry["shield"] = float(p.get("shield", entry["shield"]))
				entry["max_hp"] = float(p.get("max_hp", entry["max_hp"]))
				entry["max_shield"] = float(p.get("max_shield", entry["max_shield"]))
				remote_player_update.emit(pid, pos, entry)

	# Players missing from this update left our interest area/map/disconnected.
	var stale: Array = []
	for pid in remote_players.keys():
		if not seen_ids.has(pid):
			stale.append(pid)
	for pid in stale:
		remote_players.erase(pid)
		remote_player_left.emit(pid)


var remote_npcs: Dictionary = {}  # npc_id -> npc state dict


func _process_npc_state(update: Dictionary) -> void:
	var npcs = update.get("npcs", []) as Array
	var seen_ids: Dictionary = {}
	for n in npcs:
		if n is Dictionary:
			var nid = str(n.get("npc_id", ""))
			seen_ids[nid] = true
			remote_npcs[nid] = n
	# Remove NPCs no longer in update
	var to_remove = remote_npcs.keys().filter(func(k): return not seen_ids.has(k))
	for k in to_remove:
		remote_npcs.erase(k)
	npc_state_update.emit(remote_npcs)


func is_ws_connected() -> bool:
	return state == WS_CONNECTED


func get_connection_state_name() -> String:
	match state:
		WS_CONNECTING:
			return "CONNECTING"
		WS_CONNECTED:
			return "CONNECTED"
		WS_DISCONNECTED:
			return "DISCONNECTED"
		WS_RECONNECTING:
			return "RECONNECTING"
	return "UNKNOWN"
