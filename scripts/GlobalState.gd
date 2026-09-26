extends Node
signal logbook_changed
# Global sinif onbellegine bagimli kalmamak icin veri/servis katmani preload edilir
# (--script modunda global sinif adlari cozulemeyebiliyor).
const RankData = preload("res://scripts/rank_data.gd")
const RankService = preload("res://scripts/rank_service.gd")

var server_session_active: bool = false

var username := ""
var nickname: String = ""
var player_id := ""
var logbook: Array = []
# Seyir Defteri kapasitesi. Eski 50 kayıt "çok sayıda kayıt tutulsun"
# beklentisini karşılamıyordu; 300 kayıt hem geçmişi korur hem de
# players.json içindeki logbook dizisini makul bir boyutta tutar.
const LOGBOOK_MAX_ENTRIES: int = 300
# Aynı olay (aynı kategori + aynı mesaj + aynı değer) bu süre içinde tekrar
# gelirse ikinci kez yazılmaz. Örn. görev tamamlandı sinyali hem QuestSystem
# hem main.gd tarafından loglanıyordu; merkezi koruma ikisini tekilleştirir.
const LOGBOOK_DEDUPE_WINDOW_MSEC: int = 1500
var _logbook_last_signature: String = ""
var _logbook_last_msec: int = 0
var recent_npc_death_ids: Dictionary = {}
var ship_name := ""
var company := ""
var start_map := "1-1"

var level := 1
var is_admin: bool = false
var server_laser_slots: int = 30
var server_generator_slots: int = 15
var server_extra_slots: int = 8
var server_laser_damage_multiplier: float = 1.0
var xp := 0
var honor := 0
var log_disks: int = 0
var skill_points: int = 0

# ---------------------------------------------------------------------------
# PHASES 2-7 - server-authoritative state
# ---------------------------------------------------------------------------
# These mirror values the SERVER owns. The client reads them so the HUD can
# display them and so gameplay code has a value to consult, but it must never
# DECIDE them: the server recomputes level, HP, shield, ammo counts, loadouts
# and everything below from the database and pushes the result back. Each is a
# cache of the last server answer, not a source of truth.
#
# NOTE: several of these already existed further down this file
# (`server_map`, `server_shield`, `server_max_shield`, `server_health`,
# `server_max_health`, `player_hp`, `player_kills`, `npc_kills`,
# `player_deaths`) and are REUSED here rather than redeclared - Godot rejects a
# duplicate member name, and duplicating them would also split the save file
# and the HUD across two sources.
var server_max_hp_cache: float = 100.0

# Ammo stock keyed by the short names GlobalState already used ("X1", "SAB",
# "RSB", "R1"...). Server-owned from Phase 2; the client only displays it and
# asks the server to consume it.
var server_ammo: Dictionary = {}

# The aggregate the server derives from the selected config + drones.
var server_equipment_lasers: Array = []
var server_laser_damage: int = 0
var server_shield_bonus: int = 0
var server_speed_bonus: int = 0

# The map list with per-map unlock flags, so the client can grey out a locked
# sector without re-deriving the level gate itself.
var server_maps: Array = []

# Ranking + identity, both server-computed.
var server_rank_position: int = 0
var server_nickname: String = ""
var skill_levels: Dictionary = {
	"laser_power": 0,
	"npc_damage": 0,
	"critical_damage": 0,
	"shield_power": 0,
	"hp_power": 0,
	"motor_power": 0
}

# NovaGate skill etkileri. Tek merkezden değiştirilebilir.
# Her skill seviyesi temel statta +%2 sağlar.
const SKILL_STAT_PER_LEVEL: float = 0.02
# Kritik: seviye başına +%2 şans, kritik gerçekleşince seviye başına +%10 ek hasar.
const CRIT_CHANCE_PER_LEVEL: float = 0.02
const CRIT_DAMAGE_PER_LEVEL: float = 0.10

var bitcoin := 0
var uridium := 0
var platinum := 0
var gold := 0
var vip_expire_timestamp: int = 0
var premium_gold_last_updated: int = 0
# Kaydedilmis can/kalkan (resume icin; -1 = kayit yok).
var saved_hp: float = -1.0
var saved_shield: float = -1.0
# Ani kapanmalarda veri kaybini azaltmak icin dunya konumu periyodik
# kaydedilir (her frame degil; aralikli).
const WORLD_AUTOSAVE_INTERVAL_MSEC: int = 15000
var _world_autosave_last_msec: int = 0

# Droid sistemi
var plus_droids: int = 0
var zeus_droids: int = 0
var total_droids: int = 0
var droid_types: Array = []
var inventory: Dictionary = {}
var active_extras: Dictionary = {}
var owned_ships: Array = ["Ship10"]
var ship_configurations: Dictionary = {}
var selected_config: int = 1
var active_ship_id: String = "Ship10"

# Hesap bazlı cephane stoğu.
# Sunucu ekonomisiyle para düşümü yapılır; miktarlar kullanıcı adına özel
# ayrı cephane dosyasında tutulur ve Hangar/Roket/Lazer sistemi buradan okur.
var ammo_inventory: Dictionary = {
	"X1": 0,
	"X2": 0,
	"X3": 0,
	"X4": 0,
	"SAB": 0,
	"RSB": 0,
	"R1": 0,
	"R2": 0,
	"R3": 0
}

func _ammo_save_path() -> String:
	if username.is_empty():
		return ""
	return "user://" + username + "_ammo.json"


func _default_ammo_inventory() -> Dictionary:
	return {
		"X1": 0,
		"X2": 0,
		"X3": 0,
		"X4": 0,
		"SAB": 0,
		"RSB": 0,
		"R1": 0,
		"R2": 0,
		"R3": 0
	}


func load_ammo_inventory() -> void:
	ammo_inventory = _default_ammo_inventory()
	var path := _ammo_save_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return

	var parsed = JSON.parse_string(file.get_as_text())
	file.close()

	if not (parsed is Dictionary):
		return

	for key in ammo_inventory.keys():
		ammo_inventory[key] = maxi(int(parsed.get(key, 0)), 0)


func save_ammo_inventory() -> bool:
	var path := _ammo_save_path()
	if path.is_empty():
		return false
	return _write_local_save(path, ammo_inventory)

func _write_local_save(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		return false
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"), ProjectSettings.globalize_path(path)) == OK


func get_ammo_count(ammo_name: String) -> int:
	return maxi(int(ammo_inventory.get(ammo_name, 0)), 0)


func add_ammo(ammo_name: String, amount: int) -> void:
	if not ammo_inventory.has(ammo_name):
		return
	ammo_inventory[ammo_name] = maxi(0, get_ammo_count(ammo_name) + maxi(amount, 0))
	save_ammo_inventory()


func use_ammo_stock(ammo_name: String, amount: int = 1) -> bool:
	var wanted := maxi(amount, 1)
	var current := get_ammo_count(ammo_name)
	if current < wanted:
		return false
	ammo_inventory[ammo_name] = current - wanted
	save_ammo_inventory()
	return true


var rank_key: String = "private"
var rank_title: String = "Er"
var rank_points: float = 0.0
var global_rank_position: int = 0
var company_rank_position: int = 0
var rank_company_count: int = 0
var rank_global_count: int = 0
var rank_next_title: String = ""
var rank_next_points: float = -1.0
# 21 rutbelik merdiven icin yerel (offline) rutbe verisi.
# Sunucu siralama cevabi bos donerse bu alanlar RankService ile YEREL olarak
# hesaplanir; boylece ikinci bir rutbe sistemi olusturulmaz.
var rank_index: int = 21
# A rutbesi: merdivenin disindadir, SADECE hesap kaydindan (players.json)
# veya admin panelinden gelir. Yerel save dosyasi bu yetkiyi VEREMEZ.
var rank_a_active: bool = false
# Rutbe puani girdisi: hesabin olusturulma zamani (unix). Yoksa 0 = gun sayisi 0.
var created_at: int = 0
var player_kills: int = 0
var friendly_kills: int = 0
var player_deaths: int = 0
var missions_completed: int = 0
var clan_id: int = 0
var clan_name: String = ""
var clan_tag: String = ""
var clan_role: String = ""
var clan_permissions: Dictionary = {}


var npc_kills := 0
func update_save_path():
	if username != "":
		SAVE_PATH = "user://" + username + "_save.json"
var map_requirements = {
	"1-1": 1,
	"1-2": 2,
	"1-3": 3,

	"2-1": 1,
	"2-2": 2,
	"2-3": 3,

	"3-1": 1,
	"3-2": 2,
	"3-3": 3,

	"PVP": 10,

	"1-4": 11,
	"2-4": 11,
	"3-4": 11,

	"1-5": 13,
	"2-5": 13,
	"3-5": 13,

	"1-6": 15,
	"2-6": 15,
	"3-6": 15,

	"4-5": 20
}
const MAX_LEVEL := 24
const LEVEL_XP_BASE := 10337

func get_required_xp(level_number:int) -> int:
	if level_number <= 1:
		return 0
	
	var total := 0
	var need := LEVEL_XP_BASE
	
	for i in range(2, level_number + 1):
		total += need
		need *= 2
	
	return total


func check_level_up() -> void:
	# PHASE 2: the level is SERVER-AUTHORITATIVE.
	#
	# This used to recompute the level locally from `xp`, which meant the client
	# decided its own level and every level-gated system (map access, item
	# requirements) was client-controlled. The server now derives the level from
	# XP in `player_stats` and sends it in the login payload / world snapshot.
	#
	# The while-loop is kept ONLY as a fallback for a session with no server
	# (offline / pre-login), where there is no authority to ask. Once a server
	# session is active, `set_server_level()` is the only thing that writes
	# `level`, so a tampered client file cannot raise it.
	if server_session_active:
		return
	while level < MAX_LEVEL and xp >= get_required_xp(level + 1):
		level += 1
		print("SEVİYE ATLADI:", level)


# PHASE 2: accept the level the server computed, and report a level-up so the
# HUD can react. `previous` is the value the client had, so the caller can tell
# whether crossing happened without recomputing the curve.
func set_server_level(server_level: int, server_xp: int) -> bool:
	var previous := level
	level = clampi(int(server_level), 1, MAX_LEVEL)
	xp = maxi(int(server_xp), 0)
	var leveled := level > previous
	if leveled:
		print("SEVİYE ATLADI:", level, " (server)")
	return leveled


# PHASES 2-7: apply every server-authoritative block in one place.
#
# Called by account_manager.gd right after it mirrors the login payload into
# GlobalState. The split is deliberate: `stats` is the progression, `equipment`
# the combat aggregate, `ammo_inventory` the stock, `ship_configurations` the
# two configs, and `world` the confirmed map. Absent keys keep the current value
# so an older server response degrades gracefully instead of zeroing the HUD.
func apply_server_authority(oyuncu: Dictionary) -> void:
	if oyuncu.is_empty():
		return

	# --- progression -------------------------------------------------------
	if oyuncu.has("level") or oyuncu.has("exp"):
		set_server_level(
			int(oyuncu.get("level", level)),
			int(oyuncu.get("exp", xp))
		)
	if oyuncu.has("honor"):
		honor = int(oyuncu.get("honor", honor))

	# These are PRE-EXISTING members reused here, so the HUD and the save file
	# keep reading exactly one value for each.
	#   server_health     - server-confirmed HP (-1 means "not yet known")
	#   server_max_health - server-confirmed HP cap
	#   server_shield     - server-confirmed shield
	#   server_max_shield - server-confirmed shield cap
	if oyuncu.has("hp"):
		server_health = float(oyuncu.get("hp", server_health))
	if oyuncu.has("max_hp"):
		server_max_health = float(oyuncu.get("max_hp", server_max_health))
		server_max_hp_cache = server_max_health
	if oyuncu.has("shield"):
		server_shield = float(oyuncu.get("shield", server_shield))
	if oyuncu.has("max_shield"):
		server_max_shield = float(oyuncu.get("max_shield", server_max_shield))
	if oyuncu.has("npc_kills"):
		npc_kills = int(oyuncu.get("npc_kills", npc_kills))
	if oyuncu.has("player_kills"):
		player_kills = int(oyuncu.get("player_kills", player_kills))
	if oyuncu.has("deaths"):
		player_deaths = int(oyuncu.get("deaths", player_deaths))

	# --- ammo (server-owned count) ----------------------------------------
	var ammo_value = oyuncu.get("ammo_inventory", null)
	if ammo_value is Dictionary and not (ammo_value as Dictionary).is_empty():
		server_ammo = (ammo_value as Dictionary).duplicate(true)

	# --- equipment aggregate ----------------------------------------------
	var eq_value = oyuncu.get("equipment_stats", null)
	if eq_value is Dictionary:
		var eq := eq_value as Dictionary
		var lasers_value = eq.get("lasers", [])
		if lasers_value is Array:
			server_equipment_lasers = (lasers_value as Array).duplicate()
		server_laser_damage = int(eq.get("laser_damage", server_laser_damage))
		server_shield_bonus = int(eq.get("shield", server_shield_bonus))
		server_speed_bonus = int(eq.get("speed_bonus", server_speed_bonus))

	# --- world position ----------------------------------------------------
	if oyuncu.has("map"):
		var m := str(oyuncu.get("map", ""))
		if not m.is_empty():
			# server_map / start_map already exist and are what the world and HUD
			# read, so the confirmed server map is mirrored onto them rather than
			# duplicated.
			server_map = m
			start_map = m

	# --- position (PHASE 2-7 HUD) -----------------------------------------
	# The server snapshot carries the confirmed X/Y. Reading it here means the
	# HUD and the world agree on one set of numbers, and `server_has_position`
	# records whether the server has confirmed a position AT ALL - so a
	# snapshot without one renders as "unknown" rather than as 0,0.
	# The key names match the ones the login/world paths already accept.
	var position_sent := oyuncu.has("server_pos_x") or oyuncu.has("position_x")
	if position_sent:
		server_pos_x = float(oyuncu.get("server_pos_x",
				oyuncu.get("position_x", server_pos_x)))
		server_pos_y = float(oyuncu.get("server_pos_y",
				oyuncu.get("position_y", server_pos_y)))
		server_has_position = true

	# --- economy (PHASE 2-7 HUD) -----------------------------------------
	# `bitcoin` / `plt` / `gold` are the names the server already uses, so this
	# mirrors the values rather than introducing a second naming scheme. The
	# same fields are ALSO applied by account_manager on the login response;
	# both paths read the same server keys and write the same members, so
	# there is still exactly one source of truth.
	if oyuncu.has("bitcoin"):
		bitcoin = int(oyuncu.get("bitcoin", bitcoin))
	if oyuncu.has("plt"):
		platinum = int(oyuncu.get("plt", platinum))
		# `uridium` is a legacy alias the save file and UI still read.
		uridium = platinum
	if oyuncu.has("gold"):
		gold = int(oyuncu.get("gold", gold))

var SAVE_PATH = ""


func save_game() -> bool:
	update_save_path()
	# Oturum yoksa kayıt oluşturma.
	if username.is_empty():
		return false
	# Kaydetmeden once canli dunya durumunu yakala (harita + X/Y + HP/Kalkan).
	capture_live_player_state()
	# Log Disk / yetenek seviyeleri degistiyse turetilmis pilot puani esitlenir.
	_sync_skill_points()
	var data = {
		"username": username,
		"player_id": player_id,
		"ship_name": ship_name,
		"nickname": nickname,
		"company": company,
		"start_map": start_map,
		"server_pos_x": server_pos_x,
		"server_pos_y": server_pos_y,
		"position_x": server_pos_x,
		"position_y": server_pos_y,
		"hp": saved_hp,
		"shield": saved_shield,
		"active_ship": active_ship_id,
		"selected_config": selected_config,
		"ship_configurations": ship_configurations,

		"level": level,
		"xp": xp,
		"honor": honor,

		"bitcoin": bitcoin,
		"uridium": uridium,
		"platinum": platinum,
		"gold": gold,
	"vip_expire_timestamp": vip_expire_timestamp,
		"log_disks": log_disks,
		"skill_points": skill_points,
		"skill_levels": skill_levels,
		"plus_droids": plus_droids,
		"zeus_droids": zeus_droids,
		"total_droids": total_droids,
		"droid_types": droid_types,
		"inventory": inventory,
		"active_extras": active_extras,
		"owned_ships": owned_ships,

		"npc_kills": npc_kills,
		"logbook": logbook.duplicate(true),

		# Rutbe altyapisi: girdiler + son hesaplanan degerler.
		# a_rank buraya YAZILMAZ; yetki yalnizca hesap kaydindan gelir.
		"created_at": created_at,
		"player_kills": player_kills,
		"friendly_kills": friendly_kills,
		"player_deaths": player_deaths,
		"missions_completed": missions_completed,
		"rank_key": rank_key,
		"rank_title": rank_title,
		"rank_points": rank_points,
		"rank_index": rank_index
	}


	# Rutbe statlari hesap kaydina da islenir; boylece diger oyuncularin
	# siralamasi yerel kayittan dogru hesaplanabilir.
	_sync_rank_stats_to_account()
	var write_ok := _write_local_save(SAVE_PATH, data)
	if write_ok:
		_mirror_world_state_to_account()
	return write_ok


func load_game():
	update_save_path()

	if not FileAccess.file_exists(SAVE_PATH):
		return

	var file = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return

	var data = JSON.parse_string(file.get_as_text())
	file.close()
	if not (data is Dictionary):
		return

	username = str(data.get("username", username))
	nickname = str(data.get("nickname", nickname if not nickname.is_empty() else ""))
	player_id = str(data.get("player_id", player_id))
	ship_name = str(data.get("ship_name", ship_name))
	company = str(data.get("company", company))
	start_map = str(data.get("start_map", start_map))
	server_map = start_map
	# Kayitli harita konumu (resume icin). Yeni + eski anahtarlar desteklenir.
	server_pos_x = float(data.get("server_pos_x", data.get("position_x", server_pos_x)))
	server_pos_y = float(data.get("server_pos_y", data.get("position_y", server_pos_y)))
	server_has_position = data.has("server_pos_x") or data.has("position_x")
	saved_hp = float(data.get("hp", saved_hp))
	saved_shield = float(data.get("shield", saved_shield))
	active_ship_id = str(data.get("active_ship", active_ship_id))
	selected_config = int(data.get("selected_config", selected_config))
	var loaded_ship_configs = data.get("ship_configurations", {})
	if loaded_ship_configs is Dictionary:
		ship_configurations = (loaded_ship_configs as Dictionary).duplicate(true)
	level = int(data.get("level", level))
	xp = int(data.get("xp", xp))
	honor = int(data.get("honor", honor))
	bitcoin = int(data.get("bitcoin", bitcoin))
	uridium = int(data.get("uridium", uridium))
	platinum = int(data.get("platinum", platinum))
	gold = int(data.get("gold", gold))
	vip_expire_timestamp = int(data.get("vip_expire_timestamp", vip_expire_timestamp))
	log_disks = int(data.get("log_disks", log_disks))
	skill_points = int(data.get("skill_points", skill_points))
	var loaded_skills = data.get("skill_levels", {})
	if loaded_skills is Dictionary:
		for skill_id in skill_levels.keys():
			skill_levels[skill_id] = clampi(int((loaded_skills as Dictionary).get(skill_id, 0)), 0, 5)

	var loaded_inventory = data.get("inventory", {})
	inventory = loaded_inventory.duplicate(true) if loaded_inventory is Dictionary else {}
	active_extras = data.get("active_extras", {})

	var loaded_droids = data.get("droid_types", [])
	droid_types = loaded_droids.duplicate() if loaded_droids is Array else []
	while droid_types.size() > 8:
		droid_types.pop_back()
	plus_droids = droid_types.count("PLUS")
	zeus_droids = droid_types.count("ZEUS")
	total_droids = droid_types.size()

	var loaded_ships = data.get("owned_ships", ["Ship10"])
	owned_ships = loaded_ships.duplicate() if loaded_ships is Array else ["Ship10"]
	if not owned_ships.has("Ship10"):
		owned_ships.push_front("Ship10")

	npc_kills = int(data.get("npc_kills", npc_kills))
	var saved_logbook = data.get("logbook", [])
	logbook = saved_logbook.duplicate(true) if saved_logbook is Array else []
	while logbook.size() > LOGBOOK_MAX_ENTRIES:
		logbook.pop_back()
	_logbook_last_signature = ""
	_logbook_last_msec = 0
	recent_npc_death_ids.clear()

	# Rutbe girdileri ve son hesaplanan degerler geri yuklenir.
	created_at = int(data.get("created_at", created_at))
	player_kills = int(data.get("player_kills", player_kills))
	friendly_kills = int(data.get("friendly_kills", friendly_kills))
	player_deaths = int(data.get("player_deaths", player_deaths))
	missions_completed = int(data.get("missions_completed", missions_completed))
	rank_points = float(data.get("rank_points", rank_points))
	rank_index = clampi(int(data.get("rank_index", rank_index)), 1, RankData.RANK_COUNT)
	rank_key = str(data.get("rank_key", rank_key))
	rank_title = str(data.get("rank_title", rank_title))
	# a_rank burada OKUNMAZ: yetki hesap kaydindan (load_player_data) gelir.
	# Yerel save dosyasi kurcalansa bile A rutbesi verilmez.
	# Siralamayi yerel veriyle tazele (cevrimdisi modda tek kaynak).
	recompute_local_ranking()
	# Kayitli Log Disk ve yetenek seviyeleriyle turetilmis pilot puani esitlenir.
	_sync_skill_points()



# Periyodik dunya kaydi (ani kapanmalarda kayip azalir; her frame degil).
func _maybe_autosave_world(force: bool = false) -> void:
	if username.is_empty():
		return
	var now_msec: int = Time.get_ticks_msec()
	if not force and (now_msec - _world_autosave_last_msec) < WORLD_AUTOSAVE_INTERVAL_MSEC:
		return
	_world_autosave_last_msec = now_msec
	save_game()


# Canli oyuncu durumunu (HP/Kalkan + harita/konum) save verisine isle.
# NOT: players.json aynalama burada DEGIL, save_game basarili yazinca yapilir.
func capture_live_player_state() -> void:
	if get_tree() == null:
		return
	var ship = get_tree().get_first_node_in_group("player")
	if ship != null and "health" in ship and "shield" in ship:
		saved_hp = float(ship.get("health"))
		saved_shield = float(ship.get("shield"))
	# Ana sahneden guncel haritayi da yakala (login sonrasi resume icin kritik).
	var scene = get_tree().current_scene
	if scene != null and "current_map_name" in scene and ship != null and ship is Node2D:
		var map_name := str(scene.get("current_map_name"))
		if not map_name.is_empty():
			start_map = map_name
			server_map = map_name
			server_pos_x = (ship as Node2D).global_position.x
			server_pos_y = (ship as Node2D).global_position.y
			server_has_position = true


# Seyir Defteri economy satırları için binlik ayraçlı sayı: 824 -> "824",
# 20000 -> "20.000", -20000 -> "-20.000" (DarkOrbit tarzı gösterim).
static func format_amount(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "." + out
	return ("-" if value < 0 else "") + out


# Mevcut save sistemine aynalama: players.json kaydini guncelle.
# AYRI bir save sistemi DEGIL; ayni players.json dosyasini kullanir.
func add_logbook_entry(category: String, message: String, value: String = "") -> void:
	var trimmed := message.strip_edges()
	if trimmed.is_empty():
		return
	# Aynı olayın iki kez loglanmasını merkezi olarak engelle.
	var signature := "%s|%s|%s" % [category.to_upper(), trimmed, value]
	var now_msec := Time.get_ticks_msec()
	if signature == _logbook_last_signature \
			and (now_msec - _logbook_last_msec) < LOGBOOK_DEDUPE_WINDOW_MSEC:
		return
	_logbook_last_signature = signature
	_logbook_last_msec = now_msec
	var entry := {
		"timestamp": Time.get_datetime_string_from_system(false, true),
		"category": category.to_upper(),
		"message": trimmed,
		"value": value
	}
	logbook.push_front(entry)
	while logbook.size() > LOGBOOK_MAX_ENTRIES:
		logbook.pop_back()
	logbook_changed.emit()
	save_game()


# ==============================
# PHASE 1 - SERVER-AUTHORITATIVE SEYIR DEFTERI
# ==============================
# The server owns the journal (event_journal table). This function is the ONLY
# way a server-authored event reaches the logbook list the UI renders. It is
# deliberately separate from add_logbook_entry() above, which stays for purely
# cosmetic client-side notices.
#
# Shape returned by GET /journal and by the `journal_event` WebSocket frame:
#   {id, event_type, severity, message, timestamp, details?}
func apply_server_journal_event(payload: Dictionary) -> void:
	if payload.is_empty():
		return
	var message := str(payload.get("message", "")).strip_edges()
	if message.is_empty():
		return

	# The server id is the stable identity. Re-delivery (HTTP history replay
	# followed by a live push of the same entry) must not duplicate a row.
	var event_id := int(payload.get("id", 0))
	if event_id != 0:
		for existing in logbook:
			if existing is Dictionary and int(existing.get("server_id", 0)) == event_id:
				return

	var stamp := str(payload.get("timestamp", 0))
	var entry := {
		"timestamp": stamp,
		# Map the server's event_type onto the categories the UI already knows.
		# Unmapped types fall through to SYSTEM rather than vanishing.
		"category": journal_category(str(payload.get("event_type", ""))),
		"severity": str(payload.get("severity", "info")),
		"message": message,
		"value": "",
		"server_id": event_id,
		"event_type": str(payload.get("event_type", "")),
	}
	if payload.get("details", null) is Dictionary:
		entry["details"] = (payload["details"] as Dictionary).duplicate(true)

	logbook.push_front(entry)
	while logbook.size() > LOGBOOK_MAX_ENTRIES:
		logbook.pop_back()
	logbook_changed.emit()


func apply_server_journal_list(events: Array) -> void:
	# The server returns newest-first; the logbook is also newest-first, so the
	# list is rebuilt in order. A full replace (rather than an append) is what
	# makes a stale local entry disappear once the server is authoritative.
	logbook.clear()
	for i in range(events.size() - 1, -1, -1):
		var payload = events[i]
		if payload is Dictionary:
			apply_server_journal_event(payload)
	_logbook_last_signature = ""
	_logbook_last_msec = 0
	logbook_changed.emit()


func journal_category(event_type: String) -> String:
	match event_type:
		"register", "login", "logout":
			return "SYSTEM"
		"npc_kill", "player_kill", "death":
			return "COMBAT"
		"reward", "market_buy", "market_sell", "loot":
			return "ECONOMY"
		"map_enter", "map_leave":
			return "SYSTEM"
		"level_up":
			return "PROGRESS"
		"quest":
			return "QUEST"
		"gate":
			return "GATE"
		"company_change", "clan":
			return "COMPANY"
		"chat":
			return "CHAT"
		_:
			return "SYSTEM"


func _mirror_world_state_to_account() -> void:
	if username.is_empty():
		return
	var path := "user://players.json"
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Array):
		return
	var players: Array = parsed
	var changed := false
	for p in players:
		if not (p is Dictionary):
			continue
		if str((p as Dictionary).get("username", "")) != username:
			continue
		(p as Dictionary)["npc_kills"] = npc_kills
		(p as Dictionary)["logbook"] = logbook.duplicate(true)
		(p as Dictionary)["current_map"] = start_map
		(p as Dictionary)["map"] = start_map
		(p as Dictionary)["position_x"] = server_pos_x
		(p as Dictionary)["position_y"] = server_pos_y
		(p as Dictionary)["level"] = level
		(p as Dictionary)["xp"] = xp
		(p as Dictionary)["honor"] = honor
		(p as Dictionary)["bitcoin"] = bitcoin
		(p as Dictionary)["platinum"] = platinum
		(p as Dictionary)["uridium"] = uridium
		(p as Dictionary)["log_disks"] = log_disks
		(p as Dictionary)["skill_points"] = skill_points
		(p as Dictionary)["skill_levels"] = skill_levels.duplicate(true)
		(p as Dictionary)["inventory"] = inventory.duplicate(true)
		(p as Dictionary)["droid_types"] = droid_types.duplicate()
		(p as Dictionary)["plus_droids"] = plus_droids
		(p as Dictionary)["zeus_droids"] = zeus_droids
		(p as Dictionary)["total_droids"] = total_droids
		(p as Dictionary)["owned_ships"] = owned_ships.duplicate()
		(p as Dictionary)["ship_configurations"] = ship_configurations.duplicate(true)
		(p as Dictionary)["selected_config"] = selected_config
		(p as Dictionary)["active_ship"] = active_ship_id
		if saved_hp >= 0.0:
			(p as Dictionary)["hp"] = saved_hp
		if saved_shield >= 0.0:
			(p as Dictionary)["shield"] = saved_shield
		changed = true
		break
	if not changed:
		return
	var out := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if out == null:
		return
	out.store_string(JSON.stringify(players))
	out.flush()
	out.close()
	DirAccess.rename_absolute(path + ".tmp", path)

func reset_account_runtime() -> void:
	# Hesap değiştirirken önceki oyuncudan hiçbir canlı veri taşınmasın.
	server_session_active = false
	server_health = -1.0
	server_shield = -1.0
	server_max_health = -1.0
	server_max_shield = -1.0
	server_alive = true
	username = ""
	nickname = ""
	player_id = ""
	ship_name = ""
	company = ""
	start_map = ""
	level = 1
	xp = 0
	honor = 0
	bitcoin = 0
	uridium = 0
	platinum = 0
	log_disks = 0
	skill_points = 0
	for skill_id in skill_levels.keys():
		skill_levels[skill_id] = 0
	active_extras = {}
	plus_droids = 0
	zeus_droids = 0
	total_droids = 0
	droid_types = []
	inventory = {}
	owned_ships = ["Ship10"]
	ship_configurations = {}
	selected_config = 1
	active_ship_id = "Ship10"
	ammo_inventory = _default_ammo_inventory()
	npc_kills = 0
	logbook.clear()
	recent_npc_death_ids.clear()
	saved_hp = -1.0
	saved_shield = -1.0
	server_pos_x = 0.0
	server_pos_y = 0.0
	server_has_position = false
	_world_autosave_last_msec = 0
	# Rutbe verisi de hesap bazlidir: onceki oyuncunun siralamasi tasinmaz.
	rank_key = "private"
	rank_title = "Er"
	rank_points = 0.0
	rank_index = RankData.RANK_COUNT
	rank_a_active = false
	created_at = 0
	global_rank_position = 0
	company_rank_position = 0
	rank_company_count = 0
	rank_global_count = 0
	rank_next_title = ""
	rank_next_points = -1.0
	player_kills = 0
	friendly_kills = 0
	player_deaths = 0
	missions_completed = 0
	SAVE_PATH = ""

func company_start_map(company_code: String) -> String:
	match company_code.strip_edges().to_upper():
		"EIC":
			return "2-1"
		"VRU":
			return "3-1"
		_:
			return "1-1"


func load_player_data(data: Dictionary) -> void:
	# Offline yerel hesap verisini GlobalState'e yükle.
	reset_account_runtime()
	server_session_active = false

	username = str(data.get("username", "")).strip_edges()
	nickname = str(data.get("nickname", username))
	clan_tag = str(data.get("clan_tag", clan_tag))
	player_id = str(data.get("id", ""))
	ship_name = str(data.get("ship", "Başlangıç Gemisi"))

	company = str(data.get("company", "")).strip_edges().to_upper()

	server_map = str(data.get("current_map", data.get("map", ""))).strip_edges()
	server_pos_x = float(data.get("position_x", data.get("x", 0.0)))
	server_pos_y = float(data.get("position_y", data.get("y", 0.0)))
	server_has_position = (not server_map.is_empty()) and (data.has("position_x") or data.has("x"))
	saved_hp = float(data.get("hp", -1.0))
	saved_shield = float(data.get("shield", -1.0))
	server_health = -1.0
	server_shield = -1.0
	server_max_health = -1.0
	server_max_shield = -1.0
	server_alive = true
	server_session_active = false
	if company.is_empty():
		start_map = ""
	elif server_has_position:
		start_map = server_map
	else:
		start_map = company_start_map(company)

	is_admin = bool(data.get("is_admin", false))
	server_laser_slots = int(data.get("laser_slots", 60 if is_admin else 30))
	server_generator_slots = int(data.get("generator_slots", 30 if is_admin else 15))
	server_extra_slots = int(data.get("extra_slots", 16 if is_admin else 8))
	server_laser_damage_multiplier = float(data.get("laser_damage_multiplier", 2.0 if is_admin else 1.0))
	level = int(data.get("level", 1))
	# Rutbe altyapisi: hesap kaydi (players.json) yetkili kaynaktir.
	# created_at yoksa 0 kalir -> "kayittan beri gun" 0 / puan uydurulmaz.
	created_at = int(data.get("created_at", 0))
	player_kills = int(data.get("player_kills", 0))
	friendly_kills = int(data.get("friendly_kills", 0))
	player_deaths = int(data.get("deaths", data.get("player_deaths", 0)))
	missions_completed = int(data.get("missions_completed", 0))
	npc_kills = int(data.get("npc_kills", 0))
	rank_a_active = bool(data.get("a_rank", false))
	# Offline account fields, with legacy/server aliases retained.
	xp = int(data.get("xp", data.get("exp", 0)))
	# Server level eski/1 kalmışsa XP'den gerçek seviyeyi burada da hesapla.
	# Bu, kapı ve menü tarafında stale level kullanılmasını engeller.
	check_level_up()
	honor = int(data.get("honor", 0))
	bitcoin = int(data.get("bitcoin", 0))
	platinum = int(data.get("platinum", data.get("plt", 0)))
	log_disks = int(data.get("log_disks", 0))
	skill_points = int(data.get("skill_points", 0))
	var saved_skills = data.get("skill_levels", {})
	if saved_skills is Dictionary:
		for skill_id in skill_levels.keys():
			skill_levels[skill_id] = clampi(int((saved_skills as Dictionary).get(skill_id, 0)), 0, 5)
	uridium = platinum

	# Bu alanlar hesap bazlıdır; cevapta yoksa boş kabul edilir,
	# önceki hesabın değerleri ASLA kullanılmaz.
	var server_droids = data.get("droid_types", [])
	droid_types = server_droids.duplicate() if server_droids is Array else []
	while droid_types.size() > 8:
		droid_types.pop_back()
	plus_droids = droid_types.count("PLUS")
	zeus_droids = droid_types.count("ZEUS")
	total_droids = droid_types.size()

	var server_inventory = data.get("inventory", {})
	inventory = server_inventory.duplicate(true) if server_inventory is Dictionary else {}

	var server_ships = data.get("owned_ships", ["Ship10"])
	owned_ships = server_ships.duplicate() if server_ships is Array else ["Ship10"]
	if not owned_ships.has("Ship10"):
		owned_ships.push_front("Ship10")

	var server_configs=data.get("ship_configurations",{})
	ship_configurations=server_configs.duplicate(true) if server_configs is Dictionary else {}
	selected_config=clampi(int(data.get("selected_config",1)),1,2)
	active_ship_id=str(data.get("active_ship", data.get("active_ship_id","Ship10")))
	if not owned_ships.has(active_ship_id): active_ship_id="Ship10"

	update_save_path()
	# Restore the balances written by local gameplay/quest rewards at login.
	if FileAccess.file_exists(SAVE_PATH):
		var saved = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
		if saved is Dictionary:
			# Kayitli harita/konum/HP-kalkan/envarter mevcut kayit uzerinden geri yuklenir.
			if saved.has("start_map") and not str(saved["start_map"]).is_empty():
				start_map = str(saved["start_map"])
				server_map = start_map
			if saved.has("server_pos_x") or saved.has("position_x"):
				server_pos_x = float(saved.get("server_pos_x", saved.get("position_x", server_pos_x)))
			if saved.has("server_pos_y") or saved.has("position_y"):
				server_pos_y = float(saved.get("server_pos_y", saved.get("position_y", server_pos_y)))
			if saved.has("server_pos_x") or saved.has("position_x"):
				server_has_position = true
			if saved.has("hp"):
				saved_hp = float(saved.get("hp", saved_hp))
			if saved.has("shield"):
				saved_shield = float(saved.get("shield", saved_shield))
			if saved.has("nickname"):
				nickname = str(saved.get("nickname", nickname))
			if saved.has("skill_levels") and saved["skill_levels"] is Dictionary:
				for skill_id in skill_levels.keys():
					skill_levels[skill_id] = clampi(int((saved["skill_levels"] as Dictionary).get(skill_id, skill_levels[skill_id])), 0, 5)
			if saved.has("ship_configurations") and saved["ship_configurations"] is Dictionary:
				ship_configurations = (saved["ship_configurations"] as Dictionary).duplicate(true)
			if saved.has("selected_config"):
				selected_config = clampi(int(saved.get("selected_config", selected_config)), 1, 2)
			if saved.has("active_ship"):
				active_ship_id = str(saved.get("active_ship", active_ship_id))
				if not owned_ships.has(active_ship_id):
					active_ship_id = "Ship10"
			for key in ["bitcoin", "platinum", "xp", "honor", "level"]:
				if saved.has(key):
					set(key, int(saved[key]))
			uridium = platinum
			check_level_up()
	_load_local_timed_extras_only()
	load_ammo_inventory()
	# Hesaptan gelen Log Disk / yetenek verisiyle turetilmis puani esitle.
	_sync_skill_points()
	

	print("SERVER OYUNCU YÜKLENDİ")
	print("KULLANICI: ", username)
	print("PLAYER ID: ", player_id)
	print("ŞİRKET: ", company)
	print("HARİTA: ", start_map)
	print("PLT: ", platinum)
	print("DROID: ", droid_types.size(), " ENVANTER KALEMİ: ", inventory.size())

func refresh_server_player_by_username() -> bool:
	# Offline build: aktif oyuncu zaten yerel kaynaktan yüklenmiştir.
	return not username.is_empty()

func spend_plt(cost: int) -> bool:
	if cost <= 0:
		return true
	if int(platinum) < cost:
		print("PLT HARCAMA: yetersiz bakiye. Mevcut=", platinum, " gereken=", cost)
		return false
	platinum = maxi(0, int(platinum) - cost)
	uridium = platinum
	save_game()
	return true

func sync_economy_delta(bitcoin_delta: int, plt_delta: int, xp_delta: int, honor_delta: int) -> void:
	# Offline build: ekonomi doğrudan yerel kayda uygulanır.
	bitcoin = maxi(0, int(bitcoin) + int(bitcoin_delta))
	platinum = maxi(0, int(platinum) + int(plt_delta))
	uridium = platinum
	xp = maxi(0, int(xp) + int(xp_delta))
	honor = int(honor) + int(honor_delta)
	check_level_up()
	save_game()

func _apply_ranking_data(data: Dictionary) -> void:
	rank_key = str(data.get("rank_key", rank_key))
	rank_title = str(data.get("rank_title", rank_title))
	rank_points = float(data.get("rank_points", rank_points))
	global_rank_position = int(data.get("global_position", global_rank_position))
	company_rank_position = int(data.get("company_position", company_rank_position))
	rank_company_count = int(data.get("company_count", rank_company_count))
	rank_global_count = int(data.get("global_count", rank_global_count))
	rank_next_title = str(data.get("next_rank_title", rank_next_title))
	var next_value = data.get("next_rank_points", null)
	rank_next_points = -1.0 if next_value == null else float(next_value)
	npc_kills = int(data.get("npc_kills", npc_kills))
	player_kills = int(data.get("player_kills", player_kills))
	friendly_kills = int(data.get("friendly_kills", friendly_kills))
	player_deaths = int(data.get("deaths", player_deaths))
	missions_completed = int(data.get("missions_completed", missions_completed))
	if data.has("rank_index"):
		rank_index = clampi(int(data.get("rank_index", rank_index)), 1, RankData.RANK_COUNT)


func refresh_ranking() -> Dictionary:
	if username.is_empty():
		return {}
	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_GET,
		"/ranking/player/" + username.uri_encode()
	)
	if bool(result.get("basarili", false)):
		var ranking_value: Dictionary = result.get("ranking", {}) as Dictionary
		if ranking_value is Dictionary:
			_apply_ranking_data(ranking_value)
			return ranking_value
	# Sunucu cevabi yok (cevrimdisi derleme): siralama yerel veriyle hesaplanir.
	return recompute_local_ranking()


# --- Yerel (cevrimdisi) rutbe hesaplama ---
# Sunucu cevabi bos donerse ayni girdiler RankService ile hesaplanir.
# Boylece ayri bir rutbe sistemi yoktur; tek formel kaynak RankService'tir.

func a_rank_bonus_active() -> bool:
	# Runtime stat carpani icin tek yetkili kontrol.
	return rank_a_active


func account_days_registered() -> int:
	return RankService.days_registered_from_timestamp(created_at)


func display_rank_key() -> String:
	# Ekranda gosterilecek rutbe anahtari.
	# "A" rutbesi merdivenin disinda oldugu icin rank_key'i DEGISTIRMEZ
	# (siralama/kontenjan hesabi normal rutbeyle devam eder), sadece
	# badge ve etiket A rutbesini gosterir.
	if a_rank_bonus_active():
		return RankData.RANK_A_KEY
	return rank_key


func display_rank_title() -> String:
	if a_rank_bonus_active():
		return RankData.RANK_A_TITLE
	return rank_title


func local_rank_stats() -> Dictionary:
	return {
		"xp": xp,
		"honor": honor,
		"level": level,
		"player_kills": player_kills,
		"days_registered": account_days_registered(),
		"ship_id": ship_name,
		"npc_kills": npc_kills,
		"missions_completed": missions_completed,
		"friendly_kills": friendly_kills,
		"deaths": player_deaths
	}


func _account_manager() -> Node:
	return get_node_or_null("/root/AccountManager")


func rank_records_for_local_ranking() -> Array:
	# Yerel siralama girdisi: hesap kayitlari + AKTIF oyuncunun canli statlari.
	var records: Array = []
	var manager := _account_manager()
	if manager != null and manager.has_method("get_all_player_records"):
		var fetched = manager.get_all_player_records()
		if fetched is Array:
			records = (fetched as Array).duplicate()
	if username.is_empty():
		return records

	var self_record := local_rank_stats()
	self_record["username"] = username
	self_record["nickname"] = nickname if not nickname.is_empty() else username
	self_record["player_id"] = player_id
	self_record["company"] = company
	self_record["a_rank"] = rank_a_active
	self_record["rank_points"] = float(
		RankService.compute_rank_points(local_rank_stats()).get("points", 0.0)
	)

	# Aktif oyuncu listede her zaman vardir ve canli statlariyla temsil edilir
	# (hesap kaydi yalnizca son kaydetmede guncellenmis olabilir).
	for index in records.size():
		var record = records[index]
		if record is Dictionary and str(record.get("username", "")) == username:
			var merged: Dictionary = (record as Dictionary).duplicate()
			merged.merge(self_record, true)
			records[index] = merged
			return records
	records.append(self_record)
	return records


func _sync_rank_stats_to_account() -> void:
	var manager := _account_manager()
	if manager == null or not manager.has_method("sync_rank_stats"):
		return
	if username.is_empty():
		return
	manager.sync_rank_stats(username, local_rank_stats())


func recompute_local_ranking() -> Dictionary:
	if username.is_empty():
		return {}
	var stats := local_rank_stats()
	var computed: Dictionary = RankService.compute_rank_points(stats)
	var points := float(computed.get("points", 0.0))
	var earned_index := RankService.rank_index_for_points(points)

	var resolution: Dictionary = RankService.resolve_all(rank_records_for_local_ranking())
	var placement: Dictionary = resolution.get("players", {})
	var mine: Dictionary = placement.get(username, {})
	var placed_index := int(mine.get("rank_index", 0))

	rank_points = points
	rank_index = placed_index if placed_index > 0 else earned_index
	rank_key = str(mine.get("rank_key", RankService.rank_key_for_points(points)))
	rank_title = str(mine.get("rank_title", RankService.rank_title_for_points(points)))
	company_rank_position = int(mine.get("position", 0))
	global_rank_position = int(mine.get("global_position", 0))
	var population: Dictionary = resolution.get("company_population", {})
	rank_company_count = int(population.get(company, 0))
	rank_global_count = int(resolution.get("global_population", 0))
	var next_info: Dictionary = RankService.next_rank_info(rank_index)
	rank_next_title = str(next_info.get("title", ""))
	rank_next_points = float(next_info.get("points", -1.0))

	return {
		"basarili": true,
		"kaynak": "local",
		"exp": xp,
		"honor": honor,
		"level": level,
		"player_kills": player_kills,
		"npc_kills": npc_kills,
		"missions_completed": missions_completed,
		"friendly_kills": friendly_kills,
		"deaths": player_deaths,
		"days_registered": account_days_registered(),
		"rank_key": rank_key,
		"rank_title": rank_title,
		"rank_points": rank_points,
		"rank_index": rank_index,
		"rows": computed.get("rows", [])
	}


func get_rank_leaderboard(limit: int = 10, company_only: bool = true) -> Array:
	var path := "/ranking/leaderboard?limit=%d" % clampi(limit, 1, 100)
	if company_only and not company.is_empty():
		path += "&company=" + company.uri_encode()

	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_GET,
		path
	)
	var rows_value = result.get("rows", [])
	if bool(result.get("basarili", false)) and rows_value is Array and not (rows_value as Array).is_empty():
		return rows_value

	# Sunucu bos dondu (cevrimdisi): siralama yerel kayittan uretilir.
	return local_rank_leaderboard(limit, company_only)


func local_rank_leaderboard(limit: int = 10, company_only: bool = true) -> Array:
	# A rutbesi listede yalnizca admin'e gorunur; digerlerine gizlenir.
	var scope := company if company_only else ""
	return RankService.company_leaderboard(
		rank_records_for_local_ranking(),
		scope,
		limit,
		is_admin
	)


func sync_rank_stat(stat_name: String, amount: int = 1) -> void:
	var value := maxi(amount, 1)
	match stat_name:
		"npc_kills": npc_kills += value
		"player_kills": player_kills += value
		"deaths": player_deaths += value
		"friendly_kills": friendly_kills += value
		"missions_completed": missions_completed += value
	# Stat degistiginde rutbe puani/sirasi hemen tazelenir.
	recompute_local_ranking()
	save_game()

func _apply_clan_me(result: Dictionary) -> Dictionary:
	if not bool(result.get("basarili", false)):
		return {}
	if not bool(result.get("in_clan", false)):
		clan_id = 0
		clan_name = ""
		clan_tag = ""
		clan_role = ""
		clan_permissions = {}
		return result

	var data_value = result.get("data", {})
	if not (data_value is Dictionary):
		return {}
	var clan_value = data_value.get("clan", {})
	if clan_value is Dictionary:
		clan_id = int(clan_value.get("id", 0))
		clan_name = str(clan_value.get("name", ""))
		clan_tag = str(clan_value.get("tag", ""))
	clan_role = str(data_value.get("viewer_role", ""))
	var perms_value = data_value.get("permissions", {})
	clan_permissions = perms_value if perms_value is Dictionary else {}
	return data_value


func refresh_clan() -> Dictionary:
	if username.is_empty():
		return {}
	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_GET,
		"/clan/me/" + username.uri_encode()
	)
	return _apply_clan_me(result)


func search_clans(query: String = "") -> Array:
	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_GET,
		"/clan/search?q=" + query.uri_encode() + "&limit=30"
	)
	var rows_value = result.get("rows", [])
	return rows_value if rows_value is Array else []


func create_clan(clan_name_value: String, clan_tag_value: String, description_value: String = "") -> Dictionary:
	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_POST,
		"/clan/create",
		{
			"username": username,
			"name": clan_name_value,
			"tag": clan_tag_value,
			"description": description_value
		}
	)
	if bool(result.get("basarili", false)):
		await refresh_clan()
	return result


func apply_clan(target_clan_id: int, message_value: String = "") -> Dictionary:
	return await _http_json(
		HTTPClient.METHOD_POST,
		"/clan/apply",
		{"username": username, "clan_id": target_clan_id, "message": message_value}
	)


func decide_clan_application(application_id: int, accept: bool) -> Dictionary:
	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_POST,
		"/clan/application/decide",
		{"username": username, "application_id": application_id, "accept": accept}
	)
	if bool(result.get("basarili", false)):
		await refresh_clan()
	return result


func leave_clan() -> Dictionary:
	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_POST,
		"/clan/leave?username=" + username.uri_encode()
	)
	if bool(result.get("basarili", false)):
		await refresh_clan()
	return result


func set_clan_tax(rate: float) -> Dictionary:
	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_POST,
		"/clan/tax",
		{"username": username, "tax_rate": rate}
	)
	if bool(result.get("basarili", false)):
		await refresh_clan()
	return result


func send_clan_message(message_value: String) -> Dictionary:
	var result: Dictionary = await _http_json(
		HTTPClient.METHOD_POST,
		"/clan/message",
		{"username": username, "message": message_value}
	)
	if bool(result.get("basarili", false)):
		await refresh_clan()
	return result


func request_clan_diplomacy(target_clan_id: int, relation: String) -> Dictionary:
	return await _http_json(
		HTTPClient.METHOD_POST,
		"/clan/diplomacy/request",
		{"username": username, "target_clan_id": target_clan_id, "relation": relation}
	)



func _load_local_timed_extras_only() -> void:
	# PostgreSQL hesap verisini bozmaz. Yalnızca bu hesaba ait zamanlı booster cache'ini yükler.
	active_extras = {}
	if SAVE_PATH.is_empty() or not FileAccess.file_exists(SAVE_PATH):
		return
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return
	var local_username := str((parsed as Dictionary).get("username", ""))
	if local_username != username:
		return
	var loaded = (parsed as Dictionary).get("active_extras", {})
	active_extras = loaded.duplicate(true) if loaded is Dictionary else {}
	prune_expired_extras(false)


func prune_expired_extras(save_after: bool = true) -> void:
	var now := int(Time.get_unix_time_from_system())
	var changed := false
	for extra_name in active_extras.keys().duplicate():
		var info = active_extras.get(extra_name, {})
		if not (info is Dictionary) or int((info as Dictionary).get("expire", 0)) <= now:
			active_extras.erase(extra_name)
			changed = true
	if changed and save_after and not SAVE_PATH.is_empty():
		save_game()


func is_booster_active(extra_name: String) -> bool:
	var info = active_extras.get(extra_name, {})
	if not (info is Dictionary):
		return false
	if int((info as Dictionary).get("expire", 0)) <= int(Time.get_unix_time_from_system()):
		active_extras.erase(extra_name)
		return false
	return true


func get_booster_bonus(extra_name: String) -> float:
	if not is_booster_active(extra_name):
		return 0.0
	var info = active_extras.get(extra_name, {})
	return float((info as Dictionary).get("bonus", 0.20))


# --------------------------------------------------------------------------
# PILOT PUANI / LOG DISK DONUSUMU (NovaGate SABIT maliyet tablosu)
# --------------------------------------------------------------------------
# Log Disk dogrudan yetenek ACMAZ. Log Disk birikir; asagidaki sabit tabloya
# gore her esikte 1 PILOT PUANI kazanilir. Degerler NovaGate icin sabittir;
# formul ile uretilmez, aynen kullanilir (toplam 30 puan = 20.053 Log Disk).
const PILOT_POINT_LOG_DISK_COSTS: Array[int] = [
	122, 134, 147, 162, 178, 196, 215, 237, 261, 287,
	316, 348, 383, 421, 463, 509, 560, 616, 678, 746,
	821, 903, 993, 1092, 1201, 1321, 1453, 1598, 1758, 1934
]

# Ayni tablonun kumulatif toplamlari (Pilot Puani -> toplam Log Disk).
const PILOT_POINT_LOG_DISK_TOTALS: Array[int] = [
	122, 256, 403, 565, 743, 939, 1154, 1391, 1652, 1939,
	2255, 2603, 2986, 3407, 3870, 4379, 4939, 5555, 6233, 6979,
	7800, 8703, 9696, 10788, 11989, 13310, 14763, 16361, 18119, 20053
]


func max_pilot_points() -> int:
	return PILOT_POINT_LOG_DISK_COSTS.size()


func pilot_points_total_log_disks() -> int:
	if PILOT_POINT_LOG_DISK_TOTALS.is_empty():
		return 0
	return PILOT_POINT_LOG_DISK_TOTALS[PILOT_POINT_LOG_DISK_TOTALS.size() - 1]


func pilot_points_earned() -> int:
	# Toplam Log Disk'e karsilik gelen KAZANILMIS Pilot Puani (0..30).
	var total: int = maxi(int(log_disks), 0)
	var earned: int = 0
	for index in range(PILOT_POINT_LOG_DISK_TOTALS.size()):
		if total >= PILOT_POINT_LOG_DISK_TOTALS[index]:
			earned = index + 1
		else:
			break
	return earned


func pilot_points_spent() -> int:
	# Yetenek agacina harcanmis puan = mevcut seviyelerin toplami.
	var spent: int = 0
	for skill_id in skill_levels.keys():
		spent += clampi(int(skill_levels[skill_id]), 0, 5)
	return clampi(spent, 0, maxi(max_pilot_points(), 1))


func pilot_points_available() -> int:
	return maxi(pilot_points_earned() - pilot_points_spent(), 0)


func pilot_point_progress() -> Dictionary:
	# UI icin: sonraki puan numarasi, gereken Log Disk ve bant ici ilerleme.
	var total: int = maxi(int(log_disks), 0)
	var earned: int = pilot_points_earned()
	var next_cost: int = 0
	var next_number: int = 0
	var base: int = 0
	if earned > 0 and earned <= PILOT_POINT_LOG_DISK_TOTALS.size():
		base = PILOT_POINT_LOG_DISK_TOTALS[earned - 1]
	if earned < PILOT_POINT_LOG_DISK_COSTS.size():
		next_cost = PILOT_POINT_LOG_DISK_COSTS[earned]
		next_number = earned + 1
	var into_band: int = maxi(total - base, 0)
	if next_cost > 0:
		into_band = clampi(into_band, 0, next_cost)
	return {
		"total_log_disks": total,
		"earned": earned,
		"spent": pilot_points_spent(),
		"available": pilot_points_available(),
		"max_points": max_pilot_points(),
		"target_log_disks": pilot_points_total_log_disks(),
		"next_number": next_number,
		"next_cost": next_cost,
		"into_band": into_band
	}


func _sync_skill_points() -> void:
	# skill_points artik TURETILMIS degerdir: Log Disk'ten kazanilan puan eksi
	# yeteneklere harcanan puan. Kayit dosyasiyla uyumluluk icin saklanir.
	skill_points = clampi(pilot_points_available(), 0, 30)


func get_skill_level(skill_id: String) -> int:
	return clampi(int(skill_levels.get(skill_id, 0)), 0, 5)


func get_skill_stat_bonus(skill_id: String) -> float:
	return float(get_skill_level(skill_id)) * SKILL_STAT_PER_LEVEL


func get_critical_multiplier() -> float:
	var level_value := get_skill_level("critical_damage")
	if level_value <= 0:
		return 1.0
	var chance := clampf(float(level_value) * CRIT_CHANCE_PER_LEVEL, 0.0, 1.0)
	if randf() < chance:
		return 1.0 + float(level_value) * CRIT_DAMAGE_PER_LEVEL
	return 1.0


func _apply_skill_payload(data: Dictionary) -> void:
	if data.has("log_disks"):
		log_disks = int(data.get("log_disks", log_disks))
	# skill_points artik TURETILMIS degerdir: asagida _sync_skill_points() ile
	# Log Disk tablosundan ve yetenek seviyelerinden yeniden hesaplanir.

	var server_skills = data.get("skills", {})
	if server_skills is Dictionary:
		for skill_id in skill_levels.keys():
			skill_levels[skill_id] = clampi(int((server_skills as Dictionary).get(skill_id, 0)), 0, 5)
	elif server_skills is Array:
		for skill_id in skill_levels.keys():
			skill_levels[skill_id] = 0
		for row in server_skills:
			if row is Dictionary:
				var sid := str((row as Dictionary).get("skill_id", ""))
				if skill_levels.has(sid):
					skill_levels[sid] = clampi(int((row as Dictionary).get("level", 0)), 0, 5)

	_sync_skill_points()
	save_game()
	_refresh_player_persistent_bonuses()


func _refresh_player_persistent_bonuses() -> void:
	var player_node = get_tree().get_first_node_in_group("player")
	if player_node != null and player_node.has_method("refresh_persistent_bonuses"):
		player_node.call("refresh_persistent_bonuses")


func _refresh_skill_tree_after_login() -> void:
	await refresh_skill_tree_from_server()


func refresh_skill_tree_from_server() -> bool:
	if username.is_empty():
		return false
	var response: Dictionary = await _http_json(
		HTTPClient.METHOD_GET,
		"/skill/tree/" + username.uri_encode()
	)
	if response.is_empty() or not bool(response.get("basarili", false)):
		return false
	_apply_skill_payload(response)
	return true


func upgrade_skill_server(skill_id: String) -> Dictionary:
	if username.is_empty():
		return {"basarili": false, "mesaj": "Oyuncu oturumu yok."}
	var path := "/skill/upgrade?username=" + username.uri_encode()
	path += "&skill_id=" + skill_id.uri_encode()
	var response: Dictionary = await _http_json(HTTPClient.METHOD_POST, path)
	if bool(response.get("basarili", false)):
		_apply_skill_payload(response)
		return response

	# OFFLINE FALLBACK: sunucu yokken yetenek yükseltmesi yerelde uygulanır.
	# Kurallar: Log Disk DOGRUDAN harcanmaz. Log Disk birikimi PILOT PUANI
	# kazandirir (sabit tablo) ve her yetenek seviyesi 1 PILOT PUANI harcar.
	if not skill_levels.has(skill_id):
		return {"basarili": false, "mesaj": "Geçersiz yetenek."}

	var current_level := get_skill_level(skill_id)
	if current_level >= 5:
		return {"basarili": false, "mesaj": "Bu yetenek en yüksek seviyede."}
	if pilot_points_available() <= 0:
		var progress: Dictionary = pilot_point_progress()
		if int(progress.get("next_cost", 0)) <= 0:
			return {"basarili": false, "mesaj": "Tüm Pilot Puanları yeteneklere harcandı."}
		return {
			"basarili": false,
			"mesaj": "Yeterli Pilot Puanı yok. Sonraki puan için %d Log Disk gerekli (kazanılan: %d / %d)." % [
				int(progress.get("next_cost", 0)),
				int(pilot_points_earned()),
				max_pilot_points()
			]
		}

	# Log Disk DOKUNULMAZ; yalnizca kazanilmis pilot puani harcanir.
	skill_levels[skill_id] = current_level + 1
	_sync_skill_points()
	save_game()
	_refresh_player_persistent_bonuses()
	return {
		"basarili": true,
		"mesaj": "Yetenek yükseltildi (offline).",
		"log_disks": log_disks,
		"skill_points": skill_points,
		"skills": skill_levels.duplicate()
	}


func add_npc_reward(xp_reward, bitcoin_reward, platinum_reward, honor_reward):
	print("BURASI GLOBALSTATE")
	print("ADD NPC REWARD ÇALIŞTI")

	var real_xp := int(xp_reward)
	var real_honor := int(honor_reward)

	if is_booster_active("XP-B01"):
		real_xp = int(round(float(real_xp) * (1.0 + get_booster_bonus("XP-B01"))))
	if is_booster_active("HON-B01"):
		real_honor = int(round(float(real_honor) * (1.0 + get_booster_bonus("HON-B01"))))

	xp += real_xp
	bitcoin += int(bitcoin_reward)
	platinum += int(platinum_reward)
	honor += real_honor
	npc_kills += 1
	check_level_up()
	save_game()

	# Rütbe sayacı server-authoritative tutulur.
	sync_rank_stat("npc_kills", 1)

	# Booster uygulanmış GERÇEK XP/Şeref sunucuya kaydedilir.
	sync_economy_delta(
		int(bitcoin_reward),
		int(platinum_reward),
		real_xp,
		real_honor
	)

	print("ÖDÜL SON DURUM:")
	print("XP=", xp)
	print("BTC=", bitcoin)
	print("PLT=", platinum)
	print("ŞEREF=", honor)
func can_enter_map(map_name:String) -> bool:
	if is_admin:
		return true
	print("KAPI:", map_name, " OYUNCU LEVEL:", level)
	if level >= 15:
		return true
	
	if map_requirements.has(map_name):
		return level >= map_requirements[map_name]
	
	return false

# === NovaGate persistent online world v1 ===
var server_map: String = ""
var server_pos_x: float = 0.0
var server_pos_y: float = 0.0
var server_has_position: bool = false

# MMO Core V2 - sunucudan gelen gerçek savaş/oturum durumu.
var server_health: float = -1.0
var server_shield: float = -1.0
var server_max_health: float = -1.0
var server_max_shield: float = -1.0
var server_alive: bool = true

func _http_json(_method: int, _path: String, _payload: Dictionary = {}) -> Dictionary:
	# Offline build: ağ isteği yok.
	return {}

func cache_world_location(map_name: String, pos: Vector2) -> void:
	# Harita + koordinat birbirinden bağımsız tutulmaz.
	# Böylece X-3 koordinatının X-1 haritasına uygulanması engellenir.
	if map_name.is_empty():
		return
	start_map = map_name
	server_map = map_name
	server_pos_x = pos.x
	server_pos_y = pos.y
	server_has_position = true
	_maybe_autosave_world()


func sync_presence(
	_map_name: String, _pos: Vector2, _health_value: float = -1.0, _shield_value: float = -1.0,
	_max_health_value: float = -1.0, _max_shield_value: float = -1.0
) -> bool:
	return true

func notify_damage_state(_health_value: float, _shield_value: float, _map_name: String, _pos: Vector2) -> void:
	return

func notify_position_state(_map_name: String, _pos: Vector2) -> void:
	return

func request_safe_logout(map_name: String, pos: Vector2, _health_value: float, _shield_value: float) -> Dictionary:
	cache_world_location(map_name, pos)
	if _health_value >= 0.0:
		saved_hp = _health_value
	if _shield_value >= 0.0:
		saved_shield = _shield_value
	save_game()
	return {"basarili": true, "offline": true}

func get_player_world_state() -> Dictionary:
	return {}

func repair_server_player(
	_map_name: String, _pos: Vector2, _health_value: float, _shield_value: float,
	_max_health_value: float, _max_shield_value: float
) -> bool:
	return true

func claim_world_npc(_npc_id: String) -> Dictionary:
	return {"basarili": true, "first_attacker_username": username}

func sync_npc_death(_payload: Dictionary) -> void:
	return

func get_online_players(_map_name: String) -> Array:
	return []

func get_world_npcs(_map_name: String) -> Array:
	return []

func sync_world_npc(_payload: Dictionary) -> void:
	return

func sync_world_npcs_batch(_items: Array) -> bool:
	return true

func get_server_effects() -> Dictionary:
	return {}

func start_server_effect(key: String, cooldown_seconds: float, active_seconds: float = 0.0) -> Dictionary:
	# Offline build: efekt süreleri ilgili sistem tarafından yerelde yönetilir.
	return {"basarili": true, "offline": true, "key": key, "cooldown_seconds": cooldown_seconds, "active_seconds": active_seconds}
