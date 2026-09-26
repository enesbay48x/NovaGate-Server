extends Node

# ============================================================================
# PHASE 1 - REAL GODOT CLIENT E2E
# ============================================================================
# Runs as a normal scene (scenes/p1_e2e.tscn) rather than via `--script`,
# because `--script` mode does NOT instantiate autoloads, and the whole point
# of this test is to exercise the REAL GlobalState / account_manager / WS
# client code paths.
#
# Drives the actual client flow against a live server:
#   Login.tscn -> register -> server register -> login -> company select
#   -> WebSocket -> main
#
# Then asserts the Phase 1 contract on the real GlobalState values:
#   10000 BTC / 10000 PLT / LF1 x1 / Kalkan I x1 / Hiz I x1
#   preserved across logout+login, never granted twice
#   server / DB / GlobalState agree
#
# Emits one machine-readable line prefixed P1_E2E_RESULT.
#
# Usage:
#   godot --headless --path <project> res://scenes/p1_e2e.tscn
# ============================================================================

const DEFAULT_SERVER := "http://127.0.0.1:8000"
const PASSWORD := "P1E2E!pass1"
const RUN := "p1e2e"

# The harness sets NOVAGATE_SERVER_URL (and the matching env var Godot exposes
# to the process) so the same driver can run against any port. Falls back to
# the project's own default endpoint.
var SERVER: String = DEFAULT_SERVER

var _failures: Array = []
var _checks: Array = []


func _resolve_server() -> void:
	var from_env := OS.get_environment("NOVAGATE_SERVER_URL").strip_edges()
	if not from_env.is_empty():
		SERVER = from_env.trim_suffix("/")
		return
	var am = load("res://scripts/account_manager.gd")
	var resolved: String = str(am.get_server_endpoint()).strip_edges()
	if not resolved.is_empty():
		SERVER = resolved.trim_suffix("/")


func _check(name: String, ok: bool, detail: String = "") -> void:
	_checks.append({"name": name, "ok": bool(ok)})
	if ok:
		print("P1_OK   ", name)
	else:
		_failures.append(name)
		print("P1_FAIL ", name, "  ", detail)


func _init() -> void:
	# Point the client at the server under test for the whole run.
	_resolve_server()
	OS.set_environment("NOVAGATE_SERVER_URL", SERVER)
	var am = load("res://scripts/account_manager.gd")
	am.set_server_endpoint(SERVER)
	# Deferred so the autoloads are guaranteed to be in the tree first.
	_run.call_deferred()


func _run() -> void:
	var username := "%s_%d" % [RUN, int(Time.get_unix_time_from_system())]
	print("P1_E2E_BEGIN username=", username)

	# --- 1. register -------------------------------------------------------
	var reg := await _http_json(HTTPClient.METHOD_POST, "/auth/register", {
		"username": username, "password": PASSWORD,
		"nickname": username, "company": "",
	})
	_check("register_http_200", reg.get("status", 0) == 200, str(reg))
	var reward: Dictionary = reg.get("body", {}).get("first_registration_reward", {})
	_check("register_reward_btc_10000", reward.get("btc", 0) == 10000, str(reward))
	_check("register_reward_plt_10000", reward.get("plt", 0) == 10000, str(reward))
	var ritems: Dictionary = reward.get("items", {})
	_check("register_reward_items_canonical",
		ritems.get("lf1", 0) == 1 and ritems.get("kalkan1", 0) == 1
		and ritems.get("hiz1", 0) == 1, str(ritems))

	# --- 2. login through the real account_manager ------------------------
	var account_manager = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(account_manager)
	var login_result: Dictionary = await account_manager.server_login(username, PASSWORD)
	_check("server_login_ok", bool(login_result.get("basarili", false)),
		str(login_result))
	if not bool(login_result.get("basarili", false)):
		_emit_result(username)
		return

	# --- 3. the client mirrors the server payload into GlobalState ---------
	# server_login() already called sync_server_player_to_local() internally,
	# so GlobalState is the client's real view of the server economy. Assert
	# on THAT rather than re-applying the payload by hand.
	_check("globalstate_username_set", GlobalState.username == username,
		GlobalState.username)
	_check("globalstate_btc_10000", GlobalState.bitcoin == 10000,
		str(GlobalState.bitcoin))
	_check("globalstate_plt_10000", GlobalState.platinum == 10000,
		str(GlobalState.platinum))
	_check("globalstate_uridium_10000", GlobalState.uridium == 10000,
		str(GlobalState.uridium))
	_check("globalstate_lf1_1", int(GlobalState.inventory.get("lf1", 0)) == 1,
		str(GlobalState.inventory))
	_check("globalstate_kalkan1_1", int(GlobalState.inventory.get("kalkan1", 0)) == 1,
		str(GlobalState.inventory))
	_check("globalstate_hiz1_1", int(GlobalState.inventory.get("hiz1", 0)) == 1,
		str(GlobalState.inventory))
	_check("globalstate_inventory_has_no_display_spelling",
		not GlobalState.inventory.has("Kalkan 1")
		and not GlobalState.inventory.has("Hız 1")
		and not GlobalState.inventory.has("LF1"), str(GlobalState.inventory.keys()))

	# --- 4. company select (the real endpoint) ----------------------------
	var company_result: Dictionary = await account_manager.server_update_company("EIC")
	_check("company_update_ok", bool(company_result.get("basarili", false)),
		str(company_result))
	GlobalState.company = "EIC"
	GlobalState.save_game()

	# --- 5. real WebSocket handshake ---------------------------------------
	var ws_url: String = account_manager.get_ws_endpoint()
	var ws = load("res://scripts/novagate_ws_client.gd").new()
	get_tree().root.add_child(ws)
	var token: String = str(login_result.get("access_token", ""))
	var pid: String = str(login_result.get("player_id", ""))
	ws.call("connect_to_server", ws_url, token, pid, username)
	var ws_ok: bool = await _wait_for(ws, "is_ws_connected", 10.0)
	_check("websocket_connected", ws_ok, "ws never connected to " + ws_url)

	await _wait_frames(ws, 2.0)
	# has_received_frame() is not a ring buffer, so the handshake frames are
	# still observable even though 20 Hz world_update traffic has since
	# overflowed the ordered log.
	_check("ws_welcome_received", ws.call("has_received_frame", "welcome"),
		"received: " + str(ws.call("get_received_frame_types")))
	_check("ws_journal_sync_received",
		ws.call("has_received_frame", "journal_sync"),
		"received: " + str(ws.call("get_received_frame_types")))
	_check("ws_world_update_received",
		ws.call("has_received_frame", "world_update"),
		"received: " + str(ws.call("get_received_frame_types")))

	# --- 6. the real Seyir Defteri was populated from the server ----------
	_check("globalstate_logbook_non_empty", GlobalState.logbook.size() > 0,
		"logbook empty after journal_sync")
	var server_backed := 0
	for entry in GlobalState.logbook:
		if entry is Dictionary and int(entry.get("server_id", 0)) != 0:
			server_backed += 1
	_check("globalstate_logbook_has_server_entries", server_backed > 0,
		"no server-backed entries in the logbook")

	# --- 7. logout / login preserves the reward, never re-grants ----------
	ws.call("disconnect_from_server")
	await account_manager.server_logout()
	account_manager.queue_free()

	var am2 = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(am2)
	var relogin: Dictionary = await am2.server_login(username, PASSWORD)
	_check("relogin_ok", bool(relogin.get("basarili", false)), str(relogin))
	# GlobalState is re-populated by the relogin's own sync, which is exactly
	# the "Logout/Login sonrasında korunmalı" requirement.
	_check("relogin_btc_still_10000", GlobalState.bitcoin == 10000,
		str(GlobalState.bitcoin))
	_check("relogin_plt_still_10000", GlobalState.platinum == 10000,
		str(GlobalState.platinum))
	_check("relogin_items_still_1",
		int(GlobalState.inventory.get("lf1", 0)) == 1
		and int(GlobalState.inventory.get("kalkan1", 0)) == 1
		and int(GlobalState.inventory.get("hiz1", 0)) == 1,
		str(GlobalState.inventory))

	# --- 8. /journal is server-authoritative ------------------------------
	var token2: String = str(relogin.get("access_token", ""))
	var jr := await _http_auth(HTTPClient.METHOD_GET, "/journal", {}, token2)
	_check("journal_http_200", jr.get("status", 0) == 200, str(jr))
	var events: Array = jr.get("body", {}).get("events", [])
	_check("journal_has_events", events.size() > 0, str(events.size()))
	var types: Array = []
	for e in events:
		types.append(str(e.get("event_type", "")))
	_check("journal_has_register_event", types.has("register"), str(types))
	_check("journal_has_login_event", types.has("login"), str(types))

	am2.queue_free()
	ws.queue_free()
	_emit_result(username)


func _ws_frame_types(ws: Node) -> Array:
	if ws == null or not ws.has_method("get_seen_frame_types"):
		return []
	return ws.call("get_seen_frame_types")


func _emit_result(username: String) -> void:
	var payload := {
		"username": username,
		"checks": _checks,
		"failed": _failures,
		"passed": _checks.size() - _failures.size(),
		"total": _checks.size(),
	}
	print("P1_E2E_RESULT ", JSON.stringify(payload))
	get_tree().quit(0 if _failures.is_empty() else 1)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
func _wait_for(node: Node, method: String, timeout: float) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < int(timeout * 1000.0):
		if bool(node.call(method)):
			return true
		await get_tree().process_frame
	return bool(node.call(method))


func _wait_frames(node: Node, seconds: float) -> void:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < int(seconds * 1000.0):
		await get_tree().process_frame


func _http_json(method: int, path: String, payload: Dictionary) -> Dictionary:
	# The Content-Type header is mandatory: without it FastAPI treats the body
	# as form data and the Pydantic model rejects it with a 422.
	return await _http_request(method, SERVER + path, payload,
		["Content-Type: application/json"])


func _http_auth(method: int, path: String, payload: Dictionary,
		token: String) -> Dictionary:
	return await _http_request(method, SERVER + path, payload,
		["Content-Type: application/json", "Authorization: Bearer " + token])


func _http_request(method: int, url: String, payload: Dictionary,
		headers: Array) -> Dictionary:
	var http := HTTPRequest.new()
	get_tree().root.add_child(http)
	http.timeout = 20.0
	var body := "" if payload.is_empty() else JSON.stringify(payload)
	var err := http.request(url, headers, method, body)
	var result: Array = []
	if err == OK:
		result = await http.request_completed
	http.queue_free()
	if result.size() < 4:
		return {"status": 0, "body": {}, "error": "no response"}
	var code := int(result[1])
	var raw: Variant = result[3]
	# Typed explicitly: a ternary over two different types cannot be inferred.
	var text: String = ""
	if raw is PackedByteArray:
		text = (raw as PackedByteArray).get_string_from_utf8()
	else:
		text = str(raw)
	var parsed: Variant = JSON.parse_string(text)
	return {
		"status": code,
		"body": parsed if parsed is Dictionary else {},
	}

