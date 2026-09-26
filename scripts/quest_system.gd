extends Node

# Persistent, account-scoped quest state. Gameplay scripts publish small events;
# this autoload owns progression, rewards and UI notifications.
signal quests_changed
signal quest_completed(quest_id: String)
signal reward_claimed(quest_id: String)

const QUEST_DATA_PATH := "res://data/quests.json"
const SAVE_DIRECTORY := "user://novagate_quests"

# LF3 dagilim tablosu: gorev sisteminin tamaminda toplam 3 LF3.
# Level 1 (LV01_Q01) = LF3 x2, Level 2 (LV02_Q01) = LF3 x1. Level 3-21: LF3 YOK.
const LF3_REWARDS_BY_QUEST := {
	"LV01_Q01": 2,
	"LV02_Q01": 1,
}

# Ayni anda en fazla kac gorev aktif olabilir.
const MAX_ACTIVE_QUESTS := 5

var definitions: Dictionary = {}
var state: Dictionary = {"version": 3, "active": [], "progress": {}, "completed": [], "claimed": []}
var active_username := ""
# survival_time gorevleri icin saniye birikimi (her frame event uretmemek icin).
var _survival_accum: float = 0.0

func _ready() -> void:
	_load_definitions()

func activate_profile(username: String) -> void:
	var normalized := username.strip_edges()
	if normalized.is_empty() or normalized != GlobalState.username.strip_edges():
		return
	if normalized == active_username and not state.is_empty():
		return
	active_username = normalized
	state = {"version": 2, "active": [], "progress": {}, "completed": [], "claimed": []}
	var path := _save_path()
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			file.close()
			if parsed is Dictionary:
				for key in ["active", "completed", "claimed"]:
					if parsed.get(key) is Array:
						state[key] = parsed[key].duplicate()
				if parsed.get("progress") is Dictionary:
					state["progress"] = parsed["progress"].duplicate(true)
				if parsed.get("pending_reward") is Dictionary:
					state["pending_reward"] = parsed["pending_reward"]
				# Legacy quests had no acceptance flag: preserve only recorded progress.
				if not parsed.has("active"):
					for id in state["progress"]:
						if int(state["progress"][id]) > 0 and not is_completed(id):
							state["active"].append(id)
	# Eski q01..q21 test ID'lerini final LVxx_Q01 ID'lerine tasi (sadece quest state).
	_migrate_legacy_quest_ids()
	for id in state["claimed"]:
		if not state["completed"].has(id):
			state["completed"].append(id)
	if state.has("pending_reward"):
		_commit_pending_reward()
	for id in state["completed"].duplicate():
		state["active"].erase(id)
		# COMPLETED durumu odul bekleyen olarak korunur; odul yalnizca claim_reward ile verilir.
	for id in get_active_quests():
		if get_progress(id) >= get_target(id):
			_complete_quest(id)
	_save()
	quests_changed.emit()

func _ensure_profile_active() -> void:
	# Login akisi disindan (main_menu vb.) gelindiginde profil otomatik etkinlesir.
	if active_username.is_empty() or active_username != GlobalState.username.strip_edges():
		activate_profile(GlobalState.username)

func _migrate_legacy_quest_ids() -> void:
	# Eski test ID'leri (q01..q21) final sistem ID'lerine (LVxx_Q01) tasinir.
	# SADECE quest state: BTC/PLT/XP/inventory/equipment/ship verisine dokunulmaz.
	var renamed := false
	for index in range(1, 22):
		var legacy := "q%02d" % index
		var final_id := "LV%02d_Q01" % index
		for list_key in ["active", "completed", "claimed"]:
			if (state.get(list_key, []) as Array).has(legacy):
				state[list_key].erase(legacy)
				if not (state[list_key] as Array).has(final_id):
					state[list_key].append(final_id)
				renamed = true
		var progress: Dictionary = state.get("progress", {})
		if progress.has(legacy):
			if not progress.has(final_id):
				progress[final_id] = 0
			progress.erase(legacy)
			renamed = true
	if renamed:
		_save()

func _process(delta: float) -> void:
	# survival_time gorevleri: saniyede bir event (her frame event uretmez).
	var scene := get_tree().current_scene
	if scene == null or not ("current_map_name" in scene):
		_survival_accum = 0.0
		return
	if GlobalState.username.is_empty() or state.has("pending_reward"):
		return
	var has_survival := false
	for id_value in get_active_quests():
		var quest: Dictionary = definitions.get(str(id_value), {})
		if str((quest.get("objective", {}) as Dictionary).get("type", "")) == "survival_time":
			has_survival = true
			break
	if not has_survival:
		_survival_accum = 0.0
		return
	_survival_accum += delta
	if _survival_accum >= 1.0:
		_survival_accum -= 1.0
		record_event("survival_time", {"amount": 1})


func record_event(event_type: String, payload: Dictionary = {}) -> void:
	_ensure_profile_active()
	if active_username.is_empty() or definitions.is_empty() or active_username != GlobalState.username or state.has("pending_reward"):
		return
	var changed := false
	for quest_id_value in get_active_quests():
		var quest_id := str(quest_id_value)
		var quest: Dictionary = definitions.get(quest_id, {})
		var objective: Dictionary = quest.get("objective", {})
		if str(objective.get("type", "")) != event_type or not _matches_objective(objective, payload):
			continue
		var progress: Dictionary = state.get("progress", {})
		var target := maxi(1, int(objective.get("count", 1)))
		var new_value := mini(target, int(progress.get(quest_id, 0)) + maxi(1, int(payload.get("amount", 1))))
		if new_value == int(progress.get(quest_id, 0)):
			continue
		progress[quest_id] = new_value
		state["progress"] = progress
		changed = true
		if new_value >= target:
			_complete_quest(quest_id)
		else:
			GlobalState.add_logbook_entry("QUEST", "%s: %d/%d" % [quest_id, new_value, target], quest_id)
	if changed:
		_save()
		quests_changed.emit()

# COMPLETED gorevden odul alma: yalnizca UI [ODULU AL] ile, mevcut crash-safe
# reward sistemi (pending_reward journal) uzerinden verilir. Tekrar verilemez.
func claim_reward(quest_id: String) -> bool:
	_ensure_profile_active()
	if not definitions.has(quest_id) or not is_completed(quest_id) or is_claimed(quest_id):
		return false
	if state.has("pending_reward"):
		return false
	return _grant_reward(quest_id)

func accept_quest(quest_id: String) -> bool:
	_ensure_profile_active()
	if not get_available_quests().has(quest_id) or state.has("pending_reward"):
		return false
	# Mevcut aktif gorev limiti: 5 aktif gorevden fazlasi alinamaz.
	if get_active_quests().size() >= MAX_ACTIVE_QUESTS:
		return false
	state["active"].append(quest_id)
	state["progress"][quest_id] = 0
	if not _save():
		state["active"].erase(quest_id)
		state["progress"].erase(quest_id)
		return false
	# Completion objectives describe persistent facts (q21 depends on q20).
	var objective: Dictionary = definitions[quest_id].get("objective", {})
	if objective.get("type", "") == "quest_completed" and is_completed(str(objective.get("quest_id", ""))):
		state["progress"][quest_id] = get_target(quest_id)
		_complete_quest(quest_id)
	quests_changed.emit()
	return true

func get_available_quests() -> Array:
	_ensure_profile_active()
	var result: Array = []
	if active_username.is_empty() or active_username != GlobalState.username:
		return result
	for id in definitions:
		if get_quest_status(str(id)) == "AVAILABLE":
			result.append(id)
	result.sort_custom(func(a, b): return int(definitions[a].get("level", 1)) < int(definitions[b].get("level", 1)))
	return result

func get_active_quests() -> Array:
	_ensure_profile_active()
	var result: Array = []
	if active_username.is_empty() or active_username != GlobalState.username:
		return result
	for id in state.get("active", []):
		if definitions.has(id) and not is_completed(id) and not is_claimed(id):
			result.append(id)
	return result

func get_completed_quests() -> Array:
	return state.get("completed", [])

func get_claimed_quests() -> Array:
	return state.get("claimed", [])

func get_locked_quests() -> Array:
	# LOCKED: seviye/prerequisite saglanmiyor.
	var result: Array = []
	if active_username.is_empty() or active_username != GlobalState.username:
		return result
	for id in definitions:
		if get_quest_status(str(id)) == "LOCKED":
			result.append(id)
	result.sort_custom(func(a, b): return int(definitions[a].get("level", 1)) < int(definitions[b].get("level", 1)))
	return result

func at_active_limit() -> bool:
	return get_active_quests().size() >= MAX_ACTIVE_QUESTS

func is_locked(quest_id: String) -> bool:
	return definitions.has(quest_id) and get_quest_status(quest_id) == "LOCKED"

func get_quest_status(quest_id: String) -> String:
	if is_claimed(quest_id):
		return "CLAIMED"
	if is_completed(quest_id):
		return "COMPLETED"
	if (state.get("active", []) as Array).has(quest_id):
		return "ACTIVE"
	if definitions.has(quest_id) and _prerequisites_met(definitions[quest_id]):
		return "AVAILABLE"
	return "LOCKED"

func get_quest(quest_id: String) -> Dictionary:
	return definitions.get(quest_id, {})

func get_progress(quest_id: String) -> int:
	return int((state.get("progress", {}) as Dictionary).get(quest_id, 0))

func get_target(quest_id: String) -> int:
	var quest: Dictionary = definitions.get(quest_id, {})
	return maxi(1, int((quest.get("objective", {}) as Dictionary).get("count", 1)))

func is_completed(quest_id: String) -> bool:
	return (state.get("completed", []) as Array).has(quest_id)

func is_claimed(quest_id: String) -> bool:
	return (state.get("claimed", []) as Array).has(quest_id)

func _load_definitions() -> void:
	definitions.clear()
	if not FileAccess.file_exists(QUEST_DATA_PATH):
		push_warning("Quest data missing: " + QUEST_DATA_PATH)
		return
	var file := FileAccess.open(QUEST_DATA_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Array:
		push_warning("Quest data must be a JSON array.")
		return
	for item in parsed:
		if item is Dictionary and not str(item.get("id", "")).is_empty():
			definitions[str(item["id"])] = item

func _matches_objective(objective: Dictionary, payload: Dictionary) -> bool:
	for key in ["npc_type", "map", "currency", "item", "slot_type", "quest_id", "box_type"]:
		if objective.has(key) and str(objective[key]) != str(payload.get(key, "")):
			return false
	# npc_any_of: birden fazla NPC turunden olumleri tek gorevde biriktirir.
	if objective.has("npc_any_of"):
		var allowed: Array = objective["npc_any_of"]
		if not (allowed as Array).has(str(payload.get("npc_type", ""))):
			return false
	if objective.has("boss") and bool(objective["boss"]) != bool(payload.get("boss", false)):
		return false
	return true

func _prerequisites_met(quest: Dictionary) -> bool:
	var prerequisite := str(quest.get("prerequisite", ""))
	return GlobalState.level >= int(quest.get("level", 1)) and (prerequisite.is_empty() or is_completed(prerequisite))

func _complete_quest(quest_id: String) -> void:
	if not get_active_quests().has(quest_id) or get_progress(quest_id) < get_target(quest_id):
		return
	if state.has("pending_reward"):
		return
	# Hedef tamamlandi: odul otomatik verilmez. COMPLETED bekler, odul yalnizca
	# claim_reward() (UI [ODULU AL]) ile verilir -> CLAIMED.
	state["completed"].append(quest_id)
	state["active"].erase(quest_id)
	quest_completed.emit(quest_id)
	GlobalState.add_logbook_entry("QUEST", "%s tamamlandı." % quest_id, quest_id)
	# NPC olayından anında tamamlanan görev mevcut crash-safe ödül yolunu kullanır.
	_grant_reward(quest_id)
	quests_changed.emit()
	record_event("quest_completed", {"quest_id": quest_id})

func _grant_reward(quest_id: String) -> bool:
	if is_claimed(quest_id) or state.has("pending_reward") or active_username != GlobalState.username:
		return false
	var quest_level := int(definitions[quest_id].get("level", 1))
	var rewards: Dictionary = (definitions[quest_id].get("rewards", {}) as Dictionary).duplicate(true)
	# KESIN LF3 KURALI: LF3 sadece level 1-2 gorevlerinden kazanilabilir.
	# Level 3-21 hicbir gorev LF3 vermez. Toplam gorev LF3 = 3.
	rewards = _enforce_lf3_rule(quest_id, quest_level, rewards)
	var balances := {
		"bitcoin": GlobalState.bitcoin + int(rewards.get("btc", 0)),
		"platinum": GlobalState.platinum + int(rewards.get("plt", 0)),
		"xp": GlobalState.xp + int(rewards.get("xp", 0)),
		"honor": GlobalState.honor + int(rewards.get("honor", 0))
	}
	var ammo: Dictionary = GlobalState.ammo_inventory.duplicate(true)
	for key in rewards.get("ammo", {}):
		ammo[key] = int(ammo.get(key, 0)) + int(rewards["ammo"][key])
	var inventory: Dictionary = GlobalState.inventory.duplicate(true)
	for key in rewards.get("items", {}):
		inventory[key] = int(inventory.get(key, 0)) + int(rewards["items"][key])
	# Write-ahead journal: recovery assigns final values, NEVER adds the delta again.
	# Log Disk: envanter item'i DEGIL; mevcut GlobalState.log_disks sayacina islenir.
	var log_disks := maxi(int(GlobalState.log_disks) + int(rewards.get("log_disk", 0)), 0)
	state["pending_reward"] = {"id": quest_id, "balances": balances, "ammo": ammo, "inventory": inventory, "items": rewards.get("items", {}), "log_disks": log_disks}
	if not _save():
		return false
	return _commit_pending_reward()

func _commit_pending_reward() -> bool:
	if active_username != GlobalState.username:
		return false
	var pending: Dictionary = state["pending_reward"]
	# Guvenlik: bekleyen odulde level 3+ icin LF3 kalmissa temizle.
	pending = _sanitize_pending_lf3(pending)
	for key in pending["balances"]:
		GlobalState.set(key, int(pending["balances"][key]))
	GlobalState.uridium = GlobalState.platinum
	GlobalState.check_level_up()
	GlobalState.ammo_inventory = pending["ammo"].duplicate(true)
	GlobalState.inventory = pending["inventory"].duplicate(true)
	# Log Disk odulu: mevcut sayac ile aynalanir (1 Log Disk = 1 Skill Point DEGIL,
	# mevcut Yetenek Agaci / Pilot Puani sistemine dokunulmaz).
	GlobalState.log_disks = maxi(int(pending.get("log_disks", GlobalState.log_disks)), int(GlobalState.log_disks))
	if not GlobalState.save_game() or not GlobalState.save_ammo_inventory():
		return false
	if not pending.get("items", {}).is_empty():
		# Equipment UI reads players.json; preserve unrelated account fields.
		var manager = load("res://scripts/account_manager.gd").new()
		var players: Array = manager.load_players()
		manager.server_http.free()
		manager.free()
		for player in players:
			if player is Dictionary and str(player.get("username", "")) == active_username:
				player["inventory"] = GlobalState.inventory.duplicate(true)
		if not _write_json("user://players.json", players):
			return false
	var id := str(pending["id"])
	if not state["claimed"].has(id):
		state["claimed"].append(id)
	state.erase("pending_reward")
	if not _save():
		state["pending_reward"] = pending
		return false
	reward_claimed.emit(id)
	var effective_rewards: Dictionary = (definitions.get(id, {}).get("rewards", {}) as Dictionary).duplicate(true) if definitions.get(id, {}).get("rewards", {}) is Dictionary else {}
	effective_rewards = _enforce_lf3_rule(id, int(definitions.get(id, {}).get("level", 1)), effective_rewards)
	for item in effective_rewards.get("items", {}):
		record_event("item_acquired", {"item": item, "amount": int((effective_rewards["items"] as Dictionary)[item])})
	return true

func _save_path() -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIRECTORY))
	return SAVE_DIRECTORY.path_join(active_username.to_lower().sha256_text() + ".json")


func _enforce_lf3_rule(quest_id: String, quest_level: int, rewards: Dictionary) -> Dictionary:
	var items: Dictionary = (rewards.get("items", {}) as Dictionary).duplicate(true) if rewards.get("items", {}) is Dictionary else {}
	if items.has("LF3"):
		items.erase("LF3")
	if quest_level <= 2 and LF3_REWARDS_BY_QUEST.has(quest_id):
		items["LF3"] = int(LF3_REWARDS_BY_QUEST[quest_id])
	if items.is_empty():
		rewards.erase("items")
	else:
		rewards["items"] = items
	return rewards


func _sanitize_pending_lf3(pending: Dictionary) -> Dictionary:
	var quest_id := str(pending.get("id", ""))
	var quest_level := int(definitions.get(quest_id, {}).get("level", 1))
	var items: Dictionary = (pending.get("items", {}) as Dictionary).duplicate(true) if pending.get("items", {}) is Dictionary else {}
	if items.has("LF3"):
		items.erase("LF3")
	if quest_level <= 2 and LF3_REWARDS_BY_QUEST.has(quest_id):
		items["LF3"] = int(LF3_REWARDS_BY_QUEST[quest_id])
	pending["items"] = items
	var inventory: Dictionary = (pending.get("inventory", {}) as Dictionary).duplicate(true) if pending.get("inventory", {}) is Dictionary else {}
	if inventory.has("LF3"):
		inventory.erase("LF3")
	if quest_level <= 2 and LF3_REWARDS_BY_QUEST.has(quest_id):
		inventory["LF3"] = int(GlobalState.inventory.get("LF3", 0)) + int(LF3_REWARDS_BY_QUEST[quest_id])
	pending["inventory"] = inventory
	state["pending_reward"] = pending
	_save()
	return pending

func _save() -> bool:
	if active_username.is_empty():
		return false
	return _write_json(_save_path(), state)

func _write_json(path: String, data: Variant) -> bool:
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		push_error("Quest save failed: " + path)
		return false
	file.store_string(JSON.stringify(data))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return false
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"), ProjectSettings.globalize_path(path)) == OK
