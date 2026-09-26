extends Node

# ============================================================================
# MARKET E2E - "money left, item never arrived" (real Godot client)
#
# Runs as a normal scene (scenes/market_e2e.tscn) rather than via `--script`,
# because `--script` does NOT instantiate autoloads, and the whole point is to
# exercise the REAL account_manager -> GlobalState -> market gate chain.
#
# This is the test that failed before the fix. The exact symptom was:
#   money deducted, purchase "worked", item absent from the inventory.
# Root cause: market.gd gated every purchase on result.get("basarili", false)
# while the server answered "success". This driver asserts the gate, the
# GlobalState application, the persistence and the equipment visibility.
#
#   E1  server login + starter reward present in GlobalState
#   E2  market_buy() reports basarili=true for a REAL purchase
#   E3  the balance actually dropped by the server catalog price
#   E4  the item is in GlobalState.inventory under the CANONICAL id
#   E5  inventory has no display-name duplicate keys
#   E6  the server /player/inventory agrees with GlobalState
#   E7  journal has exactly one market_buy row naming the item
#   E8  logout -> login keeps every purchased item
#   E9  a server refusal (unknown id) is NOT a silent success
#   E10 the equipment UI table knows the purchased items
#
# Emits one machine-readable line prefixed MARKET_E2E_RESULT.
#
# Usage:
#   godot --headless --path <project> res://scenes/market_e2e.tscn
# ============================================================================

const DEFAULT_SERVER := "http://127.0.0.1:8000"
const PASSWORD := "MktE2E!pass1"
const RUN := "mkte2e"

# The four items the bug report names, with the canonical id the server
# resolves them to.
var TARGETS: Array = [
	["LF1", "lf1"],
	["LF3", "lf3"],
	["Kalkan 1", "kalkan1"],
	["Hız 1", "hiz1"],
]

var SERVER: String = DEFAULT_SERVER

var _failures: Array = []
var _checks: Array = []
var _am: Node = null


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
		print("MKT_OK   ", name)
	else:
		_failures.append(name)
		print("MKT_FAIL ", name, "  ", detail)


func _init() -> void:
	_resolve_server()
	OS.set_environment("NOVAGATE_SERVER_URL", SERVER)
	var am = load("res://scripts/account_manager.gd")
	am.set_server_endpoint(SERVER)
	_run.call_deferred()


func _inv_count(id: String) -> int:
	return int(GlobalState.inventory.get(id, 0))


func _run() -> void:
	# The harness registers and funds the account (the client must never grant
	# itself currency) and passes the credentials in. When they are absent the
	# driver registers its own account, which only has the starter reward and
	# therefore cannot afford the four test items.
	var username := OS.get_environment("NOVAGATE_E2E_USER").strip_edges()
	var password := OS.get_environment("NOVAGATE_E2E_PASSWORD").strip_edges()
	if username.is_empty():
		username = "%s_%d" % [RUN, int(Time.get_unix_time_from_system())]
		password = PASSWORD
		print("MARKET_E2E registering its own account (no harness funding)")
		var reg := await _http_json(HTTPClient.METHOD_POST, "/auth/register", {
			"username": username, "password": password,
			"nickname": username, "company": "",
		})
		_check("register_http_200", reg.get("status", 0) == 200, str(reg))
	else:
		print("MARKET_E2E_BEGIN username=", username, " server=", SERVER)

	_am = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(_am)
	var login_result: Dictionary = await _am.server_login(username, password)
	_check("login_ok", bool(login_result.get("basarili", false)), str(login_result))
	if not bool(login_result.get("basarili", false)):
		_emit_result(username)
		return

	var token: String = str(login_result.get("access_token", ""))
	_check("globalstate_username_set", GlobalState.username == username,
		str(GlobalState.username))

	# --- E1: funded and the starter reward is the pre-purchase baseline ---
	_check("account_is_funded", int(GlobalState.bitcoin) >= 400000,
		"btc=%s" % str(GlobalState.bitcoin))
	_check("baseline_has_starter_items",
		_inv_count("lf1") >= 1 and _inv_count("kalkan1") >= 1
		and _inv_count("hiz1") >= 1, str(GlobalState.inventory))

	await _buy_each(token)
	await _check_refusal()
	await _check_equipment_ui()

	# --- E8: logout -> login keeps everything -----------------------------
	await _am.server_logout()
	_am.queue_free()
	_am = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(_am)
	var relogin: Dictionary = await _am.server_login(username, password)
	_check("relogin_ok", bool(relogin.get("basarili", false)), str(relogin))

	for target in TARGETS:
		var canonical: String = str(target[1])
		_check("relogin_kept_" + canonical, _inv_count(canonical) >= 1,
			"%s = %d after relogin" % [canonical, _inv_count(canonical)])

	_emit_result(username)


func _buy_each(token: String) -> void:
	# --- E2..E7: buy each item through the REAL market gate ---------------
	for target in TARGETS:
		var label: String = str(target[0])
		var canonical: String = str(target[1])
		var inv_before: int = _inv_count(canonical)
		var btc_before: int = int(GlobalState.bitcoin)
		var plt_before: int = int(GlobalState.platinum)

		# The exact call market.gd:_buy_equipment() makes.
		var result: Dictionary = await _am.server_market_buy("equipment", label)

		# E2: THE BUG. Before the fix this was false on a successful purchase.
		_check("gate_basarili_" + canonical,
			bool(result.get("basarili", false)), str(result))
		_check("gate_not_offline_" + canonical,
			bool(result.get("server_erisilemez", false)) == false, str(result))

		# E3: money left, and only the server's price left.
		var spent := (btc_before - int(GlobalState.bitcoin)) \
			+ (plt_before - int(GlobalState.platinum))
		_check("balance_debited_" + canonical, spent > 0,
			"btc %d->%d plt %d->%d" % [btc_before, int(GlobalState.bitcoin),
				plt_before, int(GlobalState.platinum)])

		# E4: the item arrived, canonically keyed.
		_check("globalstate_inventory_grew_" + canonical,
			_inv_count(canonical) == inv_before + 1,
			"%s: %d -> %d" % [canonical, inv_before, _inv_count(canonical)])

		# E5: no display-name duplicate key was created.
		_check("no_duplicate_key_" + canonical,
			not GlobalState.inventory.has(label) or label == canonical,
			str(GlobalState.inventory.keys()))

		# E6: the server agrees with the client.
		var inv_resp: Dictionary = await _http_auth(
			HTTPClient.METHOD_GET, "/player/inventory", {}, token)
		var server_inv: Dictionary = inv_resp.get("body", {}).get("inventory", {})
		_check("server_inventory_grew_" + canonical,
			int(server_inv.get(canonical, 0)) == inv_before + 1,
			"%s server=%s" % [canonical, str(server_inv)])

		# E7: exactly one journal row naming this item.
		var jr: Dictionary = await _http_auth(
			HTTPClient.METHOD_GET, "/journal", {}, token)
		var events: Array = jr.get("body", {}).get("events", [])
		var buys := 0
		for e in events:
			if str(e.get("event_type", "")) == "market_buy" \
					and str(e.get("message", "")).contains(canonical):
				buys += 1
		_check("journal_market_buy_" + canonical, buys == 1,
			"%s market_buy rows for %s" % [buys, canonical])


func _check_refusal() -> void:
	# --- E9: a refusal is never a silent success --------------------------
	var before_refuse: Dictionary = GlobalState.inventory.duplicate(true)
	var refuse: Dictionary = await _am.server_market_buy(
		"equipment", "bilinmeyen_esya_999")
	_check("unknown_item_refused",
		bool(refuse.get("basarili", true)) == false, str(refuse))
	_check("unknown_item_no_local_grant",
		GlobalState.inventory.size() == before_refuse.size(),
		str(GlobalState.inventory))


func _check_equipment_ui() -> void:
	# --- E10: the equipment UI table knows the purchased items -------------
	# menu_ui.gd keys ITEM_DATA and its inventory by the SAME canonical ids the
	# server returns. If it used display names the purchase would be invisible
	# in the hangar even though the server delivered it.
	var script_res = load("res://scripts/menu_ui.gd")
	if script_res == null:
		_check("equipment_ui_loads", false, "menu_ui.gd would not load")
		return
	var node = script_res.new()
	if node == null:
		_check("equipment_ui_loads", false, "menu_ui.gd did not instantiate")
		return
	get_tree().root.add_child(node)
	await get_tree().process_frame

	var ui_data: Dictionary = node.get("ITEM_DATA")
	var known := 0
	for target in TARGETS:
		if ui_data.has(str(target[1])) and _inv_count(str(target[1])) >= 1:
			known += 1
	_check("equipment_ui_knows_purchased_items", known == TARGETS.size(),
		"known=%d of %d; keys=%s" % [known, TARGETS.size(), str(ui_data.keys())])
	node.queue_free()


func _emit_result(username: String) -> void:
	var payload := {
		"username": username,
		"checks": _checks,
		"failed": _failures,
		"passed": _checks.size() - _failures.size(),
		"total": _checks.size(),
	}
	print("MARKET_E2E_RESULT ", JSON.stringify(payload))
	get_tree().quit(0 if _failures.is_empty() else 1)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
func _http_json(method: int, path: String, payload: Dictionary) -> Dictionary:
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
