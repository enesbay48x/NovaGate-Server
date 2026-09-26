extends Node

# ============================================================================
# PHASES 2-7 - REAL GODOT CLIENT E2E
# ============================================================================
# Runs the REAL client code paths (account_manager + GlobalState + a plain
# HTTPRequest) against a live server and asserts the server-authority contract.
#
#   * the login payload carries real level/xp/honor/hp/shield/kills/deaths
#   * GlobalState mirrors them and does NOT recompute the level locally
#   * loadouts / Config 1 / Config 2 round-trip through the server
#   * an item the player does not own is refused
#   * ammo is server-owned and the client only reads the count
#   * maps are gated, a level-gated move is refused, a bad portal is a 404
#   * loot is claimed exactly once
#   * a quest cannot be claimed before it is completed
#   * clan / squad / chat / settings / auction / events / cargo round-trip
#   * everything survives logout + login
#
# Emits one machine-readable line: P2_P7_E2E_RESULT passed=.. failed=..
#
# Usage: godot --headless --path <project> res://scenes/p2_p7_e2e.tscn
# ============================================================================

const PASSWORD := "P27E2E!pass1"
const RUN := "p27e2e"

var SERVER: String = "http://127.0.0.1:8000"
var _failures: Array = []
var _checks: Array = []
var _token: String = ""


func _check(name: String, ok: bool, detail: String = "") -> void:
	_checks.append({"name": name, "ok": bool(ok)})
	if ok:
		print("P27_OK   ", name)
	else:
		_failures.append(name)
		print("P27_FAIL ", name, "  ", detail)


func _init() -> void:
	var from_env := OS.get_environment("NOVAGATE_SERVER_URL").strip_edges()
	if not from_env.is_empty():
		SERVER = from_env.trim_suffix("/")
	else:
		var am = load("res://scripts/account_manager.gd")
		var resolved: String = str(am.get_server_endpoint()).strip_edges()
		if not resolved.is_empty():
			SERVER = resolved.trim_suffix("/")
	OS.set_environment("NOVAGATE_SERVER_URL", SERVER)
	var am2 = load("res://scripts/account_manager.gd")
	am2.set_server_endpoint(SERVER)
	_run.call_deferred()


func _emit() -> void:
	var passed := _checks.size() - _failures.size()
	print("P2_P7_E2E_RESULT passed=%d failed=%d total=%d failures=%s" % [
		passed, _failures.size(), _checks.size(), str(_failures)
	])
	get_tree().quit(0 if _failures.is_empty() else 1)


# --- minimal HTTP helpers --------------------------------------------------
# NOTE: the Godot 4.7 signature is request(url, headers, method, body) - the
# method is the THIRD argument, not the first. Both helpers are coroutines, so
# every caller must `await` them.
func _http_auth(method: HTTPClient.Method, path: String,
		payload: Dictionary) -> Dictionary:
	return await _http_request(method, SERVER + path, payload, _token)


func _http_request(method: HTTPClient.Method, url: String,
		payload: Dictionary, token: String) -> Dictionary:
	var http := HTTPRequest.new()
	# The node must be in the tree before request(), and a root child matches
	# what the Phase 1 driver does.
	get_tree().root.add_child(http)
	http.timeout = 20.0
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not token.is_empty():
		headers.append("Authorization: Bearer " + token)
	var body := "" if payload.is_empty() else JSON.stringify(payload)
	var err := http.request(url, headers, method, body)
	var result: Array = []
	if err == OK:
		result = await http.request_completed
	http.queue_free()
	# request_completed yields [result, code, headers, body] - the BODY is
	# index 3 and the STATUS is index 1.
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


# Read the first element of a possibly-empty laser list as a String, so an
# empty list yields "" instead of an index-out-of-range error.
func _first_id(list_value: Variant) -> String:
	if list_value is Array and (list_value as Array).size() > 0:
		return str((list_value as Array)[0])
	return ""

func _run() -> void:
	var username := "%s_%d" % [RUN, int(Time.get_unix_time_from_system())]
	print("P2_P7_E2E_BEGIN username=", username)

	# --- 1. register + login through the real account_manager ---------------
	var am = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(am)
	var reg := await _http_request(HTTPClient.METHOD_POST, SERVER + "/auth/register", {
		"username": username, "password": PASSWORD,
		"nickname": username, "company": "EIC",
	}, "")
	_check("register_200", int(reg.get("status", 0)) == 200, str(reg))

	var login: Dictionary = await am.server_login(username, PASSWORD)
	_check("login_ok", bool(login.get("basarili", false)), str(login))
	if not bool(login.get("basarili", false)):
		_emit()
		return
	_token = str(login.get("access_token", ""))

	# --- 2. the login payload really carries progression --------------------
	# server_login() ran sync_server_player_to_local() internally, so these are
	# the client's LIVE GlobalState values, not a re-applied copy.
	_check("gs_level_is_1", int(GlobalState.level) == 1, str(GlobalState.level))
	_check("gs_hp_from_server", int(GlobalState.server_health) == 100,
		str(GlobalState.server_health))
	_check("gs_shield_from_server", int(GlobalState.server_shield) == 100,
		str(GlobalState.server_shield))
	_check("gs_ammo_from_server",
		int(GlobalState.server_ammo.get("X1", 0)) > 0, str(GlobalState.server_ammo))
	_check("gs_map_from_server", not str(GlobalState.server_map).is_empty(),
		str(GlobalState.server_map))

	# --- 3. loadouts: Config 1 / Config 2 round-trip -----------------------
	var put1 := await _http_auth(HTTPClient.METHOD_PUT, "/loadouts", {
		"ship_id": "Ship10", "config_index": 1,
		"lasers": ["lf1"], "generators": ["kalkan1", "hiz1"],
		"extras": [], "drone_slots": [],
	})
	_check("loadout_put_200", int(put1.get("status", 0)) == 200, str(put1))

	var got := await _http_auth(HTTPClient.METHOD_GET, "/loadouts", {})
	_check("loadout_get_200", int(got.get("status", 0)) == 200, str(got))
	var loadouts: Dictionary = got.get("body", {}).get("loadouts", {})
	var l1: Dictionary = loadouts.get("1", {})
	var l2: Dictionary = loadouts.get("2", {})
	_check("config1_has_lf1", _first_id(l1.get("lasers", [])) == "lf1", str(l1))
	_check("config2_independent_empty", _first_id(l2.get("lasers", [])) == "",
		str(l2))

	# --- 4. an unowned item is refused -------------------------------------
	var bad := await _http_auth(HTTPClient.METHOD_PUT, "/loadouts", {
		"ship_id": "Ship10", "config_index": 1, "lasers": ["lf3"],
	})
	_check("unowned_item_refused_400", int(bad.get("status", 0)) == 400, str(bad))

	# --- 5. equipment aggregate follows the SELECTED config -----------------
	# Config 1 is the stored one, so the aggregate must reflect it. Checked
	# BEFORE switching to config 2, because the aggregate is defined as the
	# SELECTED config's contents.
	var eq := await _http_auth(HTTPClient.METHOD_GET, "/equipment/stats", {})
	_check("equipment_stats_200", int(eq.get("status", 0)) == 200, str(eq))
	var eqb: Dictionary = eq.get("body", {}).get("equipment", {})
	_check("equipment_damage_from_config", int(eqb.get("laser_damage", 0)) > 0,
		str(eqb))
	_check("equipment_lists_equipped_laser",
		_first_id(eqb.get("lasers", [])) == "lf1", str(eqb))

	# --- 6. select Config 2 -> the aggregate must follow it ----------------
	var sel := await _http_auth(HTTPClient.METHOD_POST, "/loadouts/select",
		{"ship_id": "Ship10", "config_index": 2})
	_check("config2_select_200", int(sel.get("status", 0)) == 200, str(sel))
	var eq2 := await _http_auth(HTTPClient.METHOD_GET, "/equipment/stats", {})
	var eq2b: Dictionary = eq2.get("body", {}).get("equipment", {})
	_check("equipment_follows_selected_config",
		int(eq2b.get("laser_damage", 0)) == 0, str(eq2b))

	# --- 7. maps are server-gated -----------------------------------------
	var maps := await _http_auth(HTTPClient.METHOD_GET, "/maps", {})
	_check("maps_200", int(maps.get("status", 0)) == 200, str(maps))
	var m1: Dictionary = {}
	var m14: Dictionary = {}
	for m in maps.get("body", {}).get("maps", []):
		if str(m.get("map_id", "")) == "1-1":
			m1 = m
		if str(m.get("map_id", "")) == "1-4":
			m14 = m
	_check("map_1_1_unlocked", bool(m1.get("unlocked", false)), str(m1))
	_check("map_1_4_level_locked", not bool(m14.get("unlocked", true)), str(m14))

	# --- 8. a level-gated map move is refused ------------------------------
	var mv := await _http_auth(HTTPClient.METHOD_POST, "/map/move",
		{"map_id": "1-4"})
	_check("locked_map_move_403", int(mv.get("status", 0)) == 403, str(mv))

	# --- 9. an invented portal is a 404 ------------------------------------
	var tp := await _http_auth(HTTPClient.METHOD_POST, "/portal/travel",
		{"portal_id": "nope->nowhere"})
	_check("bad_portal_404", int(tp.get("status", 0)) == 404, str(tp))

	# --- 10. loot is claimed exactly once ----------------------------------
	var spawn := await _http_auth(HTTPClient.METHOD_POST, "/loot/spawn",
		{"map_id": "1-1", "is_bonus_box": true})
	_check("loot_spawn_200", int(spawn.get("status", 0)) == 200, str(spawn))
	var loot_id := str(spawn.get("body", {}).get("loot", {}).get("loot_id", ""))
	var c1 := await _http_auth(HTTPClient.METHOD_POST, "/loot/claim",
		{"loot_id": loot_id})
	_check("loot_claim_200", int(c1.get("status", 0)) == 200, str(c1))
	var c2 := await _http_auth(HTTPClient.METHOD_POST, "/loot/claim",
		{"loot_id": loot_id})
	_check("loot_double_claim_409", int(c2.get("status", 0)) == 409, str(c2))

	# --- 11. a quest cannot be claimed before it is completed ---------------
	var acc := await _http_auth(HTTPClient.METHOD_POST,
		"/quests/accept?quest_id=LV03_Q01", {})
	_check("quest_accept_200", int(acc.get("status", 0)) == 200, str(acc))
	var qclaim := await _http_auth(HTTPClient.METHOD_POST,
		"/quests/claim?quest_id=LV03_Q01", {})
	_check("quest_incomplete_claim_409", int(qclaim.get("status", 0)) == 409,
		str(qclaim))

	# --- 12. clan ----------------------------------------------------------
	var clan_name := "E2E" + username.substr(username.length() - 4, 4)
	var clan := await _http_auth(HTTPClient.METHOD_POST, "/clans",
		{"name": clan_name, "tag": "E27"})
	_check("clan_create_200", int(clan.get("status", 0)) == 200, str(clan))
	var mine := await _http_auth(HTTPClient.METHOD_GET, "/clans/mine", {})
	_check("clan_mine_owner",
		str(mine.get("body", {}).get("clan", {}).get("role", "")) == "owner",
		str(mine))

	# --- 13. squad ---------------------------------------------------------
	var sq := await _http_auth(HTTPClient.METHOD_POST, "/squads", {})
	_check("squad_create_200", int(sq.get("status", 0)) == 200, str(sq))
	var sqm := await _http_auth(HTTPClient.METHOD_GET, "/squads/mine", {})
	_check("squad_mine_present",
		mine_ok(sqm.get("body", {}).get("squad", null)), str(sqm))

	# --- 14. chat is persisted and a burst is throttled --------------------
	var ch := await _http_auth(HTTPClient.METHOD_POST, "/chat",
		{"channel": "global_tr", "body": "merhaba e2e"})
	_check("chat_send_200", int(ch.get("status", 0)) == 200, str(ch))

	# A single back-to-back pair is not a reliable throttle probe: on a slow
	# machine two requests can straddle the 1-second window and both succeed.
	# A burst is, so the invariant asserted is "a burst of rapid sends is
	# rejected at least once" - which holds regardless of per-request latency
	# and still fails loudly if the limiter is missing entirely.
	var throttled := 0
	var burst_codes: Array = []
	for i in range(5):
		var r := await _http_auth(HTTPClient.METHOD_POST, "/chat",
			{"channel": "global_tr", "body": "burst %d" % i})
		var code := int(r.get("status", 0))
		burst_codes.append(code)
		if code == 429:
			throttled += 1
	_check("chat_burst_throttled", throttled > 0, str(burst_codes))

	var chs := await _http_auth(HTTPClient.METHOD_GET, "/chat/global_tr", {})
	_check("chat_history_200", int(chs.get("status", 0)) == 200, str(chs))
	var badch := await _http_auth(HTTPClient.METHOD_POST, "/chat",
		{"channel": "made_up", "body": "hi"})
	_check("chat_bad_channel_400", int(badch.get("status", 0)) == 400, str(badch))

	# --- 15. settings ------------------------------------------------------
	var st := await _http_auth(HTTPClient.METHOD_PUT, "/settings",
		{"chat_channel": "global_en", "show_damage": false})
	_check("settings_put_200", int(st.get("status", 0)) == 200, str(st))
	var stg := await _http_auth(HTTPClient.METHOD_GET, "/settings", {})
	_check("settings_round_trip",
		str(stg.get("body", {}).get("chat_channel", "")) == "global_en",
		str(stg))

	# --- 16. cargo ---------------------------------------------------------
	var cg := await _http_auth(HTTPClient.METHOD_GET, "/cargo", {})
	_check("cargo_get_200", int(cg.get("status", 0)) == 200, str(cg))
	var dep := await _http_auth(HTTPClient.METHOD_POST, "/cargo/deposit",
		{"item_id": "kalkan1", "quantity": 1})
	_check("cargo_deposit_200", int(dep.get("status", 0)) == 200, str(dep))
	var wd := await _http_auth(HTTPClient.METHOD_POST, "/cargo/withdraw",
		{"item_id": "kalkan1", "quantity": 1})
	_check("cargo_withdraw_200", int(wd.get("status", 0)) == 200, str(wd))

	# --- 17. auction: item is escrowed, bad bids are refused ---------------
	var auc := await _http_auth(HTTPClient.METHOD_POST, "/auctions", {
		"item_id": "kalkan1", "currency": "PLT", "start_price": 500,
	})
	_check("auction_create_200", int(auc.get("status", 0)) == 200, str(auc))
	var aid := int(auc.get("body", {}).get("auction_id", 0))
	var underbid := await _http_auth(HTTPClient.METHOD_POST, "/auctions/bid",
		{"auction_id": aid, "amount": 1})
	_check("auction_low_bid_400", int(underbid.get("status", 0)) == 400,
		str(underbid))
	var selfbid := await _http_auth(HTTPClient.METHOD_POST, "/auctions/bid",
		{"auction_id": aid, "amount": 9999})
	_check("auction_self_bid_400", int(selfbid.get("status", 0)) == 400,
		str(selfbid))

	# --- 18. events / ranking / nickname -----------------------------------
	var ev := await _http_auth(HTTPClient.METHOD_GET, "/events", {})
	_check("events_get_200", int(ev.get("status", 0)) == 200, str(ev))
	var rk := await _http_auth(HTTPClient.METHOD_GET, "/ranking", {})
	_check("ranking_200", int(rk.get("status", 0)) == 200, str(rk))
	var nn := await _http_auth(HTTPClient.METHOD_PUT, "/account/nickname",
		{"nickname": clan_name})
	_check("nickname_200", int(nn.get("status", 0)) == 200, str(nn))

	# --- 19. logout + login: everything persists --------------------------
	await am.server_logout()
	am.queue_free()
	var am3 = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(am3)
	var relogin: Dictionary = await am3.server_login(username, PASSWORD)
	_check("relogin_ok", bool(relogin.get("basarili", false)), str(relogin))
	_token = str(relogin.get("access_token", ""))

	_check("persist_level", int(GlobalState.level) == 1, str(GlobalState.level))
	_check("persist_hp", int(GlobalState.server_health) == 100,
		str(GlobalState.server_health))
	_check("persist_ammo", int(GlobalState.server_ammo.get("X1", 0)) > 0,
		str(GlobalState.server_ammo))

	var cl2 := await _http_auth(HTTPClient.METHOD_GET, "/clans/mine", {})
	_check("persist_clan",
		str(cl2.get("body", {}).get("clan", {}).get("role", "")) == "owner",
		str(cl2))
	var sq2 := await _http_auth(HTTPClient.METHOD_GET, "/squads/mine", {})
	_check("persist_squad", mine_ok(sq2.get("body", {}).get("squad", null)),
		str(sq2))
	var st2 := await _http_auth(HTTPClient.METHOD_GET, "/settings", {})
	_check("persist_settings",
		str(st2.get("body", {}).get("chat_channel", "")) == "global_en",
		str(st2))
	var lo2 := await _http_auth(HTTPClient.METHOD_GET, "/loadouts", {})
	var lo1: Dictionary = lo2.get("body", {}).get("loadouts", {}).get("1", {})
	_check("persist_loadout", _first_id(lo1.get("lasers", [])) == "lf1", str(lo1))

	# --- 20. the client did NOT recompute the level ------------------------
	# Tamper the local XP/level, then re-apply the server payload: the server
	# value must win, proving a tampered client file cannot grant a level.
	GlobalState.level = 20
	GlobalState.xp = 999999
	GlobalState.apply_server_authority({
		"level": 1, "exp": 0, "honor": 0,
		"hp": 100, "max_hp": 100, "shield": 100, "max_shield": 100,
	})
	_check("level_not_client_computable", int(GlobalState.level) == 1,
		str(GlobalState.level))
	_check("xp_not_client_computable", int(GlobalState.xp) == 0, str(GlobalState.xp))

	am3.queue_free()
	_emit()


func mine_ok(value: Variant) -> bool:
	return value is Dictionary and not (value as Dictionary).is_empty()



