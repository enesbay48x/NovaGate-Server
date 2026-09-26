extends Node

# ==========================================================================
# NOVAGATE GALAXY GATE YONETICISI (autoload: GalaxyGateManager)
# --------------------------------------------------------------------------
# Sorumluluklar:
#  * Oyuncu bazli gate state (player_id -> gate state) tutmak (BOLUM 27).
#  * Kapali parca (gate part) kazanma ve multiplier (BOLUM 4 / BOLUM 5).
#  * Gate BUILD / ACTIVATE ve X1 portali gorunurlugu (BOLUM 2 / BOLUM 14).
#  * Kat / dalga ilerlemesi ve gate tamamlama odulu (BOLUM 10 / BOLUM 11).
#  * Kalici save/load (BOLUM 16 / BOLUM 22).
#
# Save dosyasi GlobalState cephane kaydiyla ayni desendedir:
#   user://<username>_gates.json
# Bu dosya players.json ve GlobalState kaydindan BAGIMSIZDIR; mevcut
# inventory save akisi degistirilmez (BOLUM 31).
# ==========================================================================

const GateData := preload("res://scripts/galaxy_gate_data.gd")

const SAVE_VERSION: int = 1

# Oyuncu bazli state: <player_id> -> {"gates": {...}, "selected_gate": "alpha"}
var _players: Dictionary = {}
var _active_player_id: String = ""
var _loaded: bool = false

# Ileride multiplayer icin: bu instance'in hangi gate instance'inda oldugu.
var active_run: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _save_path() -> String:
	var username: String = str(GlobalState.username).strip_edges()
	if username.is_empty():
		return ""
	return "user://" + username + "_gates.json"


func _current_player_id() -> String:
	var live_id: String = str(GlobalState.player_id).strip_edges()
	if not live_id.is_empty():
		return live_id
	var username: String = str(GlobalState.username).strip_edges()
	if username.is_empty():
		return ""
	return username


func _write_json(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return false
	return DirAccess.rename_absolute(path + ".tmp", path) == OK


func load_states(force: bool = false) -> void:
	if _loaded and not force:
		return
	_players = {}
	_active_player_id = _current_player_id()
	var path := _save_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		_loaded = true
		_ensure_player_entry()
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary:
		var stored_players = (parsed as Dictionary).get("players", {})
		if stored_players is Dictionary:
			for key in (stored_players as Dictionary).keys():
				var record = (stored_players as Dictionary)[key]
				if record is Dictionary:
					_players[str(key)] = (record as Dictionary).duplicate(true)
		var stored_active := str((parsed as Dictionary).get("active_player_id", ""))
		if not stored_active.is_empty():
			_active_player_id = stored_active
	_loaded = true
	_ensure_player_entry()


func save_states() -> bool:
	var path := _save_path()
	if path.is_empty():
		return false
	var payload := {
		"version": SAVE_VERSION,
		"active_player_id": _active_player_id,
		"players": _players
	}
	return _write_json(path, payload)


func _ensure_player_entry() -> Dictionary:
	if _active_player_id.is_empty():
		_active_player_id = _current_player_id()
	if _active_player_id.is_empty():
		return {"gates": {}, "selected_gate": ""}
	if not _players.has(_active_player_id):
		_players[_active_player_id] = {"gates": {}, "selected_gate": ""}
	var entry = _players[_active_player_id]
	if not (entry is Dictionary):
		entry = {"gates": {}, "selected_gate": ""}
		_players[_active_player_id] = entry
	if not ((entry as Dictionary).get("gates", {}) is Dictionary):
		(entry as Dictionary)["gates"] = {}
	return entry


func selected_gate_id() -> String:
	load_states()
	var entry: Dictionary = _ensure_player_entry()
	var selected := str(entry.get("selected_gate", ""))
	if not GateData.has_gate(selected):
		selected = GateData.GATE_IDS[0] if not GateData.GATE_IDS.is_empty() else ""
		entry["selected_gate"] = selected
	return selected


func set_selected_gate_id(gate_id: String) -> void:
	load_states()
	if not GateData.has_gate(gate_id):
		return
	_ensure_player_entry()["selected_gate"] = str(gate_id).strip_edges().to_lower()
	save_states()
# --------------------------------------------------------------------------
# STATE ERISIMI
# --------------------------------------------------------------------------

func state_for(gate_id: String) -> Dictionary:
	# Oyuncunun bu gate icin canli state'i. Yoksa tanimdan uretilir.
	load_states()
	if not GateData.has_gate(gate_id):
		return {}
	var key: String = str(gate_id).strip_edges().to_lower()
	var entry: Dictionary = _ensure_player_entry()
	var gates: Dictionary = entry["gates"]
	if not gates.has(key) or not (gates[key] is Dictionary):
		gates[key] = GateData.default_state(key)
	var state: Dictionary = gates[key]
	_normalize_state(key, state)
	return state


func _normalize_state(gate_id: String, state: Dictionary) -> void:
	# Bozuk/elle degistirilmis kayitlara karsi savunma (BOLUM 31).
	var required: int = GateData.required_parts(gate_id)
	state["gate_id"] = gate_id
	if not (state.get("owned_parts", []) is Array):
		state["owned_parts"] = []
	var owned: Array = []
	for value in state["owned_parts"]:
		var index: int = int(value)
		if index >= 1 and index <= required and not owned.has(index):
			owned.append(index)
	state["owned_parts"] = owned
	state["current_parts"] = clampi(int(state.get("current_parts", 0)), 0, required)
	if owned.size() > state["current_parts"]:
		state["current_parts"] = owned.size()
	if not (state.get("duplicate_counts", {}) is Dictionary):
		state["duplicate_counts"] = {}
	var floors = state.get("completed_floors", [])
	state["completed_floors"] = floors if floors is Array else []
	state["completed_waves"] = maxi(0, int(state.get("completed_waves", 0)))
	state["current_floor"] = clampi(int(state.get("current_floor", 1)), 1, GateData.max_floor(gate_id))
	state["current_wave"] = clampi(int(state.get("current_wave", 1)), 1, GateData.WAVES_PER_FLOOR)
	state["spawned_wave"] = clampi(int(state.get("spawned_wave", 0)), 0, GateData.WAVES_PER_FLOOR)
	state["active"] = bool(state.get("active", false))
	state["completed"] = bool(state.get("completed", false))
	state["completion_reward_claimed"] = bool(state.get("completion_reward_claimed", false))
	state["in_run"] = bool(state.get("in_run", false))
	if state["completed"]:
		# Tamamlanan gate tekrar aktif olamaz (completion odulu iki kez verilmez).
		state["active"] = false
	if not state["active"] and not state["completed"]:
		state["in_run"] = false


func parts_count(gate_id: String) -> int:
	var state: Dictionary = state_for(gate_id)
	if state.is_empty():
		return 0
	return int(state.get("current_parts", 0))

# --------------------------------------------------------------------------
# KAPI PARCASI KAZANMA / MATERIALIZER (BOLUM 4 / BOLUM 5)
# --------------------------------------------------------------------------

# Sahip olunmayan parcalara verilen secim agirligi. Boylece eksik parcalar
# onceliklidir; ayni parca tekrar geldiginde multiplier devreye girer.
const UNOWNED_PART_PRIORITY_WEIGHT: int = 3
const OWNED_PART_WEIGHT: int = 1

# Materializer'da parca cikmadiginda kullanilan (bos olmayan) odul havuzu.
# Mevcut ekonomi/cephane API'leri kullanilir; yeni para birimi uydurulmaz.
const FALLBACK_AMMO_REWARDS := [
	{"ammo": "X1", "amount_min": 50, "amount_max": 300},
	{"ammo": "X2", "amount_min": 20, "amount_max": 120},
	{"ammo": "R1", "amount_min": 5, "amount_max": 30}
]
const FALLBACK_BTC_MIN: int = 5000
const FALLBACK_BTC_MAX: int = 45000
const FALLBACK_PLT_MIN: int = 30
const FALLBACK_PLT_MAX: int = 400


func _roll_part_chance() -> bool:
	return (randi() % 100) < GateData.GATE_PART_CHANCE_PERCENT


func _pick_part_index(gate_id: String) -> int:
	var required: int = GateData.required_parts(gate_id)
	if required <= 0:
		return 0
	var owned: Array = state_for(gate_id).get("owned_parts", [])
	var weights: Array[int] = []
	var total: int = 0
	for index in range(1, required + 1):
		var weight: int = OWNED_PART_WEIGHT if owned.has(index) else UNOWNED_PART_PRIORITY_WEIGHT
		weights.append(weight)
		total += weight
	if total <= 0:
		return 1
	var pick: int = randi() % total
	for i in range(weights.size()):
		pick -= weights[i]
		if pick < 0:
			return i + 1
	return 1


func _fallback_reward_text() -> Dictionary:
	var roll: int = randi() % 100
	if roll < 40:
		var ammo_entry: Dictionary = FALLBACK_AMMO_REWARDS[randi() % FALLBACK_AMMO_REWARDS.size()]
		var ammo_name: String = str(ammo_entry.get("ammo", "X1"))
		var amount: int = randi_range(int(ammo_entry.get("amount_min", 10)), int(ammo_entry.get("amount_max", 50)))
		GlobalState.add_ammo(ammo_name, amount)
		GlobalState.save_game()
		return {"reward": "ammo", "text": "+%d %s" % [amount, ammo_name]}
	if roll < 70:
		var btc: int = randi_range(FALLBACK_BTC_MIN, FALLBACK_BTC_MAX)
		GlobalState.sync_economy_delta(btc, 0, 0, 0)
		return {"reward": "btc", "text": "+%d BTC" % btc}
	var plt: int = randi_range(FALLBACK_PLT_MIN, FALLBACK_PLT_MAX)
	GlobalState.sync_economy_delta(0, plt, 0, 0)
	return {"reward": "plt", "text": "+%d PLT" % plt}


func award_gate_part(gate_id: String) -> Dictionary:
	# Parca dagitimi. Gate tamamlandiysa veya parca tavani dolduysa gereksiz
	# parca uretilmez; uygun odul verilir.
	if not GateData.has_gate(gate_id):
		return {"granted": false, "text": "", "message": "Bilinmeyen gate."}
	var key: String = str(gate_id).strip_edges().to_lower()
	var state: Dictionary = state_for(key)
	if bool(state.get("completed", false)) or parts_complete(key):
		var fallback: Dictionary = _fallback_reward_text()
		save_states()
		return {
			"granted": false,
			"gate_id": key,
			"converted": true,
			"text": str(fallback.get("text", "")),
			"message": "%s tamamlandi; parcalar odul cevrildi." % GateData.display_name(key)
		}
	var required: int = GateData.required_parts(key)
	var part_index: int = _pick_part_index(key)
	var owned: Array = state["owned_parts"]
	var multiplier: int = 1
	var duplicate: bool = owned.has(part_index)
	if duplicate:
		var dup_counts: Dictionary = state["duplicate_counts"]
		var dup_count: int = int(dup_counts.get(str(part_index), 0)) + 1
		dup_counts[str(part_index)] = dup_count
		multiplier = GateData.duplicate_multiplier(dup_count)
	else:
		owned.append(part_index)
		owned.sort()
	# Parca sayisi negatif olamaz ve gereken sayiyi asmaz (BOLUM 31).
	state["current_parts"] = clampi(int(state.get("current_parts", 0)) + multiplier, 0, required)
	save_states()
	var text: String = "%s PART %d" % [GateData.display_name(key), part_index]
	if multiplier > 1:
		text += "  x%d" % multiplier
	return {
		"granted": true,
		"gate_id": key,
		"part_index": part_index,
		"multiplier": multiplier,
		"duplicate": duplicate,
		"total_parts": int(state["current_parts"]),
		"required_parts": required,
		"text": text,
		"message": text
	}


func try_award_gate_part_from_source() -> Dictionary:
	# Mevcut odul kaynagi (X1 bonus kutulari) icin %13 parca kontrolu.
	if not _roll_part_chance():
		return {"granted": false}
	var gate_id: String = selected_gate_id()
	if gate_id.is_empty():
		return {"granted": false}
	return award_gate_part(gate_id)


# --------------------------------------------------------------------------
# GATE BUILD / ACTIVATE + X1 PORTALI (BOLUM 2 / BOLUM 14)
# --------------------------------------------------------------------------

func activate_gate(gate_id: String) -> Dictionary:
	if not GateData.has_gate(gate_id):
		return {"ok": false, "message": "Bilinmeyen gate."}
	var key: String = str(gate_id).strip_edges().to_lower()
	var state: Dictionary = state_for(key)
	if bool(state.get("completed", false)):
		return {"ok": false, "message": "%s zaten tamamlandi." % GateData.display_name(key)}
	if bool(state.get("active", false)):
		return {"ok": false, "message": "%s zaten aktif." % GateData.display_name(key)}
	var required: int = GateData.required_parts(key)
	if int(state.get("current_parts", 0)) < required:
		return {
			"ok": false,
			"message": "Yetersiz parca. %d / %d" % [int(state.get("current_parts", 0)), required]
		}
	# Parcalar dusurulur (BOLUM 14).
	state["owned_parts"] = []
	state["duplicate_counts"] = {}
	state["current_parts"] = 0
	state["active"] = true
	state["completed"] = false
	state["current_floor"] = 1
	state["current_wave"] = 1
	state["spawned_wave"] = 0
	state["completed_floors"] = []
	state["completed_waves"] = 0
	state["instance_id"] = "%s_%s_%d" % [key, _current_player_id(), int(Time.get_unix_time_from_system())]
	state["in_run"] = false
	save_states()
	return {"ok": true, "gate_id": key, "message": "%s AKTIF. X1 portali acildi." % GateData.display_name(key)}


func deactivate_gate(gate_id: String) -> Dictionary:
	if not GateData.has_gate(gate_id):
		return {"ok": false, "message": "Bilinmeyen gate."}
	var key: String = str(gate_id).strip_edges().to_lower()
	var state: Dictionary = state_for(key)
	if bool(state.get("completed", false)):
		return {"ok": false, "message": "Tamamlanan gate tekrar kapatilamaz."}
	state["active"] = false
	state["in_run"] = false
	save_states()
	return {"ok": true, "gate_id": key, "message": "%s deaktif." % GateData.display_name(key)}


func active_gate_for_company(company: String) -> String:
	# Oyuncunun sirketinin X1 haritasinda gorunecek AKTIF gate.
	for gate_id in GateData.gate_ids():
		if not is_active(gate_id):
			continue
		var def: Dictionary = GateData.definition(gate_id)
		var restriction: String = str(def.get("company_restriction", "")).strip_edges().to_upper()
		if restriction.is_empty() or restriction == GateData.resolve_company(company):
			return gate_id
	return ""


func company_home_map(company: String) -> String:
	return GateData.home_map_for_company(company)


func gate_portal_position(company: String) -> Vector2:
	return GateData.gate_position_for_company(company)


# --------------------------------------------------------------------------
# KAT / DALGA ILERLEMESI (BOLUM 7 / BOLUM 9 / BOLUM 10)
# --------------------------------------------------------------------------

func start_run(gate_id: String) -> Dictionary:
	# X1 portalindan gate'e giris. Kat 1 / dalga 1'den baslar.
	if not GateData.has_gate(gate_id):
		return {"ok": false, "message": "Bilinmeyen gate."}
	var key: String = str(gate_id).strip_edges().to_lower()
	if not is_active(key):
		return {"ok": false, "message": "%s aktif degil." % GateData.display_name(key)}
	var state: Dictionary = state_for(key)
	if not bool(state.get("in_run", false)):
		state["in_run"] = true
		# Onceden kalma yarim ilerleme varsa korunur (BOLUM 26).
		state["current_floor"] = clampi(int(state.get("current_floor", 1)), 1, GateData.max_floor(key))
		state["current_wave"] = clampi(int(state.get("current_wave", 1)), 1, GateData.WAVES_PER_FLOOR)
		state["spawned_wave"] = 0
	if str(state.get("instance_id", "")).is_empty():
		state["instance_id"] = "%s_%s_%d" % [key, _current_player_id(), int(Time.get_unix_time_from_system())]
	save_states()
	active_run = run_snapshot(key)
	return {"ok": true, "gate_id": key, "run": active_run}


func run_snapshot(gate_id: String) -> Dictionary:
	# player_id -> gate_instance mantigi (BOLUM 27). Sahne bu veriyi okur.
	var key: String = str(gate_id).strip_edges().to_lower()
	var state: Dictionary = state_for(key)
	if state.is_empty():
		return {}
	return {
		"player_id": _current_player_id(),
		"gate_id": key,
		"instance_id": str(state.get("instance_id", "")),
		"map_id": GateData.gate_map_id(key, int(state.get("current_floor", 1))),
		"floor": int(state.get("current_floor", 1)),
		"wave": int(state.get("current_wave", 1)),
		"max_floor": GateData.max_floor(key),
		"waves_per_floor": GateData.WAVES_PER_FLOOR,
		"active": bool(state.get("active", false)),
		"completed": bool(state.get("completed", false))
	}


func resume_run() -> Dictionary:
	# Sahne yuklendiginde cagrilir: kayitli ilerleme restore edilir.
	load_states()
	var gate_id: String = ""
	for candidate in GateData.gate_ids():
		var state: Dictionary = state_for(candidate)
		if bool(state.get("in_run", false)) and not bool(state.get("completed", false)):
			gate_id = candidate
			break
	if gate_id.is_empty():
		active_run = {}
		return {}
	active_run = run_snapshot(gate_id)
	return active_run


func current_run_gate_id() -> String:
	return str(active_run.get("gate_id", ""))


func wave_can_spawn() -> bool:
	# Ayni dalga iki kere spawn edilemez (BOLUM 31).
	var gate_id: String = current_run_gate_id()
	if gate_id.is_empty():
		return false
	var state: Dictionary = state_for(gate_id)
	var wave: int = clampi(int(state.get("current_wave", 1)), 1, GateData.WAVES_PER_FLOOR)
	if bool(state.get("completed", false)) or not bool(state.get("active", false)):
		return false
	return int(state.get("spawned_wave", 0)) != wave


func mark_wave_spawned() -> void:
	var gate_id: String = current_run_gate_id()
	if gate_id.is_empty():
		return
	var state: Dictionary = state_for(gate_id)
	state["spawned_wave"] = clampi(int(state.get("current_wave", 1)), 1, GateData.WAVES_PER_FLOOR)
	save_states()


func current_wave_definition() -> Dictionary:
	var gate_id: String = current_run_gate_id()
	if gate_id.is_empty():
		return {}
	return current_wave_definition_for(gate_id)


func current_wave_definition_for(gate_id: String) -> Dictionary:
	var key: String = str(gate_id).strip_edges().to_lower()
	if not GateData.has_gate(key):
		return {}
	var state: Dictionary = state_for(key)
	return GateData.wave_definition(
		key,
		int(state.get("current_floor", 1)),
		int(state.get("current_wave", 1))
	)


func complete_wave() -> Dictionary:
	# Dalga temizlendi. Dalga 5 bittiyse kat tamamlanir.
	var gate_id: String = current_run_gate_id()
	if gate_id.is_empty():
		return {"ok": false}
	var state: Dictionary = state_for(gate_id)
	var wave: int = clampi(int(state.get("current_wave", 1)), 1, GateData.WAVES_PER_FLOOR)
	var floor_number: int = clampi(int(state.get("current_floor", 1)), 1, GateData.max_floor(gate_id))
	state["completed_waves"] = maxi(int(state.get("completed_waves", 0)), 0) + 1
	if wave < GateData.WAVES_PER_FLOOR:
		state["current_wave"] = wave + 1
		save_states()
		active_run = run_snapshot(gate_id)
		return {
			"ok": true,
			"gate_id": gate_id,
			"floor_completed": false,
			"gate_completed": false,
			"next_wave": wave + 1,
			"message": "WAVE %d TAMAMLANDI" % wave
		}
	# Kat tamamlandi.
	var floors: Array = state.get("completed_floors", [])
	if not floors.has(floor_number):
		floors.append(floor_number)
	state["completed_floors"] = floors
	if floor_number >= GateData.max_floor(gate_id):
		var finish: Dictionary = complete_gate(gate_id)
		return {
			"ok": true,
			"gate_id": gate_id,
			"floor_completed": true,
			"gate_completed": true,
			"message": "%s TAMAMLANDI" % GateData.display_name(gate_id),
			"rewards_text": str(finish.get("rewards_text", ""))
		}
	state["current_floor"] = floor_number + 1
	state["current_wave"] = 1
	state["spawned_wave"] = 0
	save_states()
	active_run = run_snapshot(gate_id)
	return {
		"ok": true,
		"gate_id": gate_id,
		"floor_completed": true,
		"gate_completed": false,
		"next_floor": floor_number + 1,
		"message": "FLOOR %d TAMAMLANDI" % floor_number
	}


func complete_gate(gate_id: String) -> Dictionary:
	var key: String = str(gate_id).strip_edges().to_lower()
	var state: Dictionary = state_for(key)
	if state.is_empty():
		return {"ok": false, "message": "Bilinmeyen gate."}
	if bool(state.get("completed", false)):
		return {"ok": false, "message": "Gate zaten tamamlandi."}
	var rewards_text: String = ""
	if not bool(state.get("completion_reward_claimed", false)):
		rewards_text = grant_completion_rewards(key)
		state["completion_reward_claimed"] = true
	state["completed"] = true
	state["active"] = false
	state["in_run"] = false
	state["current_parts"] = 0
	state["owned_parts"] = []
	state["duplicate_counts"] = {}
	save_states()
	active_run = {}
	return {"ok": true, "gate_id": key, "rewards_text": rewards_text}


func grant_completion_rewards(gate_id: String) -> String:
	# Tamamlama odulu mevcut NovaGate odul/ekonomi sistemi uzerinden verilir.
	var rewards: Dictionary = GateData.completion_rewards(gate_id)
	if rewards.is_empty():
		return ""
	var btc: int = maxi(0, int(rewards.get("BTC", 0)))
	var plt: int = maxi(0, int(rewards.get("PLT", 0)))
	var xp: int = maxi(0, int(rewards.get("XP", 0)))
	var honor: int = maxi(0, int(rewards.get("HONOR", 0)))
	GlobalState.sync_economy_delta(btc, plt, xp, honor)
	var parts: Array[String] = []
	if btc > 0:
		parts.append("+%d BTC" % btc)
	if plt > 0:
		parts.append("+%d PLT" % plt)
	if xp > 0:
		parts.append("+%d XP" % xp)
	if honor > 0:
		parts.append("+%d HONOR" % honor)
	var ammo = rewards.get("ammo", {})
	if ammo is Dictionary:
		for ammo_name in (ammo as Dictionary).keys():
			var amount: int = maxi(0, int((ammo as Dictionary)[ammo_name]))
			if amount <= 0:
				continue
			GlobalState.add_ammo(str(ammo_name), amount)
			parts.append("+%d %s" % [amount, str(ammo_name)])
	var items = rewards.get("items", {})
	if items is Dictionary and not (items as Dictionary).is_empty():
		_grant_items(items as Dictionary)
		for item_name in (items as Dictionary).keys():
			parts.append("+%d %s" % [int((items as Dictionary)[item_name]), str(item_name)])
	GlobalState.save_game()
	return "  ".join(parts)


func _grant_items(items: Dictionary) -> void:
	# Ekipman odulu players.json envanterine ve canli GlobalState envanterine
	# birlikte yazilir; boylece Hangar odulu aninda gorur.
	for item_name in items.keys():
		var amount: int = maxi(0, int(items[item_name]))
		if amount <= 0:
			continue
		var key: String = str(item_name)
		GlobalState.inventory[key] = int(GlobalState.inventory.get(key, 0)) + amount
	var account_manager = load("res://scripts/account_manager.gd").new()
	if account_manager != null and account_manager.has_method("add_inventory_items"):
		account_manager.call("add_inventory_items", items)
	if account_manager != null:
		account_manager.free()


func leave_gate() -> void:
	# "X1'E DON" / ESC: ilerleme SILINMEZ, yalnizca run kapatilir (BOLUM 26).
	var gate_id: String = current_run_gate_id()
	if not gate_id.is_empty():
		var state: Dictionary = state_for(gate_id)
		state["in_run"] = false
		state["spawned_wave"] = 0
	active_run = {}
	save_states()


func abandon_run(gate_id: String) -> void:
	# Oyuncu gate'i tamamen birakmak isterse (baslangica donus).
	var key: String = str(gate_id).strip_edges().to_lower()
	if not GateData.has_gate(key):
		return
	var state: Dictionary = state_for(key)
	state["in_run"] = false
	state["current_floor"] = 1
	state["current_wave"] = 1
	state["spawned_wave"] = 0
	state["completed_floors"] = []
	state["completed_waves"] = 0
	save_states()
	active_run = {}


func reset_for_player() -> void:
	# Farkli bir hesaba gecildiginde bellek state'i tazelenir.
	var live_id: String = _current_player_id()
	if _loaded and _active_player_id == live_id:
		return
	_players = {}
	_loaded = false
	active_run = {}
	load_states()


func active_run_snapshot() -> Dictionary:
	# GalaxyGateArena sahnesi icin aktif kosu anlik gorunumu (player_id dahil).
	return active_run.duplicate(true) if active_run is Dictionary else {}


func wave_can_spawn_for(gate_id: String) -> bool:
	# Belirli bir gate icin ayni dalganin iki kez spawn edilmesini engelle.
	var key: String = str(gate_id).strip_edges().to_lower()
	if not GateData.has_gate(key):
		return false
	var state: Dictionary = state_for(key)
	var wave: int = clampi(int(state.get("current_wave", 1)), 1, GateData.WAVES_PER_FLOOR)
	if bool(state.get("completed", false)) or not bool(state.get("active", false)):
		return false
	return int(state.get("spawned_wave", 0)) != wave


func mark_wave_spawned_for(gate_id: String) -> void:
	# Belirli bir gate icin mevcut dalgayi spawn edildi olarak isaretle.
	var key: String = str(gate_id).strip_edges().to_lower()
	if not GateData.has_gate(key):
		return
	var state: Dictionary = state_for(key)
	state["spawned_wave"] = clampi(int(state.get("current_wave", 1)), 1, GateData.WAVES_PER_FLOOR)
	save_states()


func portal_visible_on_map(map_name: String, company: String) -> bool:
	# X1 portali yalnizca gate AKTIF oldugunda gorunur (BOLUM 2 / BOLUM 14).
	if GateData.is_gate_map(map_name):
		return false
	if map_name != GateData.home_map_for_company(company):
		return false
	return not active_gate_for_company(company).is_empty()


# --------------------------------------------------------------------------
# EXTRA ENERGY
# --------------------------------------------------------------------------
const EXTRA_ENERGY_KEY: String = "extra_energy"


func extra_energy() -> int:
	# Hesap bazli Extra Energy. Mevcut gate save dosyasinda saklanir; yeni bir
	# kayit dosyasi ACILMAZ.
	load_states()
	return maxi(int(_ensure_player_entry().get(EXTRA_ENERGY_KEY, 0)), 0)


func add_extra_energy(amount: int) -> void:
	if int(amount) == 0:
		return
	var entry: Dictionary = _ensure_player_entry()
	entry[EXTRA_ENERGY_KEY] = maxi(0, int(entry.get(EXTRA_ENERGY_KEY, 0)) + int(amount))
	save_states()


func spin_cost_plt(spins: int) -> int:
	# 1 kullanim = 100 PLT; panel adimlari bu maliyetin katlaridir.
	return maxi(int(spins), 1) * GateData.MATERIALIZER_PLT_COST


func materialize(gate_id: String, spins: int = 1) -> Dictionary:
	# Oyuncunun sectigi gate icin N spin. Bos sonuc YOKTUR; her spin
	# %67 muhimmat, %13 kapi parcasi, %12 Xenomit, %4 Nano Hull,
	# %3 tamir kuponu, %1 log disk uretir.
	if not GateData.has_gate(gate_id):
		return {"ok": false, "message": "Bilinmeyen gate."}
	var key: String = str(gate_id).strip_edges().to_lower()
	if is_completed(key):
		return {"ok": false, "message": "%s zaten tamamlandi." % GateData.display_name(key)}
	var spin_count: int = clampi(int(spins), 1, 100)
	# Extra Energy varsa ONCE o kullanilir; kalan spinler PLT ile odenir.
	var ee_used: int = mini(extra_energy(), spin_count)
	var plt_spins: int = spin_count - ee_used
	var cost: int = plt_spins * GateData.MATERIALIZER_PLT_COST
	if cost > 0 and not GlobalState.spend_plt(cost):
		return {
			"ok": false,
			"required_plt": cost,
			"message": "Yetersiz PLT. Gereken: %d" % cost
		}
	if ee_used > 0:
		add_extra_energy(-ee_used)
	var results: Array[String] = []
	var parts_gained: int = 0
	for _index in range(spin_count):
		var reward: Dictionary = _roll_materializer_reward(key)
		results.append(str(reward.get("text", "")))
		parts_gained += int(reward.get("parts", 0))
	save_states()
	GlobalState.save_game()
	var text: String = "\n".join(results)
	return {
		"ok": true,
		"kind": "spin",
		"gate_id": key,
		"spins": spin_count,
		"ee_used": ee_used,
		"plt_cost": cost,
		"parts_gained": parts_gained,
		"results": results,
		"text": text,
		"message": text
	}


func _roll_materializer_reward(gate_id: String) -> Dictionary:
	# Tek spin odulu. Olasilik toplami tam %100'dur.
	var roll: int = randi() % 100
	if roll < GateData.REWARD_AMMO_PERCENT:
		return _grant_ammo_reward()
	var part_limit: int = GateData.REWARD_AMMO_PERCENT + GateData.GATE_PART_CHANCE_PERCENT
	if roll < part_limit:
		var part_result: Dictionary = award_gate_part(gate_id)
		if bool(part_result.get("granted", false)):
			var multiplier: int = maxi(int(part_result.get("multiplier", 1)), 1)
			var text: String = "+ %s Gate Part" % GateData.display_name(gate_id)
			if multiplier > 1:
				text += " x%d" % multiplier
			return {"reward": "part", "parts": 1, "text": text}
		# Parcalar dolduysa mevcut donusturme davranisi korunur.
		return {
			"reward": "part_converted",
			"parts": 0,
			"text": str(part_result.get("text", ""))
		}
	var xenomit_limit: int = part_limit + GateData.REWARD_XENOMIT_PERCENT
	if roll < xenomit_limit:
		var amount: int = randi_range(GateData.XENOMIT_AMOUNT_MIN, GateData.XENOMIT_AMOUNT_MAX)
		_add_inventory_item(GateData.ITEM_XENOMIT, amount)
		return {"reward": "xenomit", "text": "+%d Xenomit" % amount}
	var nano_limit: int = xenomit_limit + GateData.REWARD_NANO_HULL_PERCENT
	if roll < nano_limit:
		_add_inventory_item(GateData.ITEM_NANO_HULL, 1)
		return {"reward": "nano_hull", "text": "+1 Nano Hull"}
	var repair_limit: int = nano_limit + GateData.REWARD_REPAIR_COUPON_PERCENT
	if roll < repair_limit:
		_add_inventory_item(GateData.ITEM_REPAIR_COUPON, 1)
		return {"reward": "repair_coupon", "text": "+1 Tamir Kuponu"}
	GlobalState.log_disks = maxi(0, int(GlobalState.log_disks) + 1)
	return {"reward": "log_disk", "text": "+1 Log Disk"}


func _grant_ammo_reward() -> Dictionary:
	var pool: Array = GateData.AMMO_REWARD_POOL
	if pool.is_empty():
		return {"reward": "ammo", "text": ""}
	var pick = pool[randi() % pool.size()]
	if not (pick is Dictionary):
		return {"reward": "ammo", "text": ""}
	var ammo_name: String = str((pick as Dictionary).get("ammo", "X1"))
	var amount: int = randi_range(
		int((pick as Dictionary).get("amount_min", 10)),
		int((pick as Dictionary).get("amount_max", 50))
	)
	GlobalState.add_ammo(ammo_name, amount)
	return {"reward": "ammo", "text": "+%d %s" % [amount, ammo_name]}


func _add_inventory_item(item_name: String, amount: int) -> void:
	# Odul mevcut GlobalState envanterine yazilir; GlobalState.save_game() ile
	# kalici hale gelir ve diger sistemler ayni veriyi gorur.
	if int(amount) <= 0:
		return
	GlobalState.inventory[item_name] = maxi(0, int(GlobalState.inventory.get(item_name, 0))) + int(amount)

func parts_required(gate_id: String) -> int:
	return GateData.required_parts(gate_id)


func is_active(gate_id: String) -> bool:
	var state: Dictionary = state_for(gate_id)
	return bool(state.get("active", false)) and not bool(state.get("completed", false))


func is_completed(gate_id: String) -> bool:
	var state: Dictionary = state_for(gate_id)
	return bool(state.get("completed", false))


func parts_complete(gate_id: String) -> bool:
	var required: int = GateData.required_parts(gate_id)
	if required <= 0:
		return false
	return parts_count(gate_id) >= required


func can_activate(gate_id: String) -> bool:
	if not GateData.has_gate(gate_id):
		return false
	if is_completed(gate_id):
		return false
	if is_active(gate_id):
		return false
	return parts_complete(gate_id)


func status_text(gate_id: String) -> String:
	if is_completed(gate_id):
		return "COMPLETED"
	if is_active(gate_id):
		return "ACTIVE"
	if parts_complete(gate_id):
		return "READY"
	return "PARTS"
