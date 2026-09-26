extends Node

const SETTINGS_PATH := "user://settings.json"

# Ayar degisikliginde canli duzeltme yapmak isteyen sistemler bu sinyali
# dinler (orn. main.gd grafik/isim gorunurlugu). Deger yazimi bittikten
# SONRA yayilir.
signal settings_changed

var settings: Dictionary = {}

func _ready() -> void:
	load_settings()
	apply_settings()

func _default_settings() -> Dictionary:
	return {
		"account": {
			"nickname": "",
			"auto_login": false,
			"logout_on_close": false
		},
		"gameplay": {
			"auto_fire": false,
			"auto_aim": true,
			"show_enemy_names": true,
			"show_npc_names": true,
			"show_player_names": true,
			"show_coordinates": true,
			"show_minimap": true,
			"minimap_scale": 1.0,
			"show_hp_bars": true,
			"show_shield_bars": true,
			"damage_numbers": true,
			"show_damage": true,
			"battle_notifications": true,
			"quest_notifications": true,
			"loot_notifications": true,
			"effects": true
		},
		"graphics": {
			"display_mode": "windowed",
			"resolution": "1280x720",
			"fullscreen": false,
			"vsync": true,
			"fps_limit": 60,
			"quality": "high",
			"map_scale": 1.0,
			"background_quality": "medium",
			"effects_quality": "high",
			"ship_effects": true,
			"npc_effects": true,
			"explosion_effects": true,
			"laser_effects": true,
			"damage_effects": true,
			"ui_scale": 1.0
		},
		"audio": {
			"master_volume": 1.0,
			"music_volume": 0.9,
			"effects_volume": 0.9,
			"weapon_volume": 0.9,
			"npc_volume": 0.8,
			"ui_volume": 0.8,
			"music_on": true,
			"sfx_on": true
		},
		"controls": {
			"pc": {
				"move_forward": KEY_W,
				"move_back": KEY_S,
				"move_left": KEY_A,
				"move_right": KEY_D,
				"fire": KEY_SPACE,
				"target": KEY_TAB,
				"laser": KEY_Q,
				"rocket": KEY_E,
				"extra": KEY_R,
				"config": KEY_C,
				"gate": KEY_G,
				"minimap": KEY_M,
				"menu": KEY_ESCAPE,
				"market": KEY_B,
				"equipment": KEY_I,
				"quests": KEY_J,
				"next_ammo": KEY_1
			},
			"mobile": {
				"joystick_size": 1.0,
				"joystick_opacity": 0.8,
				"button_size": 1.0,
				"button_opacity": 0.8,
				"hud_scale": 1.0,
				"aim_sensitivity": 1.0,
				"joystick_sensitivity": 1.0,
				"auto_fire": false,
				"auto_aim": true
			}
		},
		"ui": {
			"hud_scale": 1.0,
			"hud_opacity": 1.0,
			"show_hud": true,
			"default_layout": true,
			"compact_mode": false
		},
		"language": "tr",
		"accessibility": {
			"high_contrast": false,
			"colorblind_mode": false,
			"reduce_motion": false,
			"large_text": false
		}
	}

func _merge_dict(base: Dictionary, incoming: Dictionary) -> void:
	for key in incoming.keys():
		var value = incoming[key]
		if base.has(key) and base[key] is Dictionary and value is Dictionary:
			_merge_dict(base[key], value)
		else:
			base[key] = value

func load_settings() -> Dictionary:
	settings = _default_settings()
	if not FileAccess.file_exists(SETTINGS_PATH):
		return settings
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if file == null:
		return settings
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		_merge_dict(settings, parsed)
	return settings

func save_settings() -> bool:
	var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(settings))
	file.close()
	return true

func reset_to_defaults() -> Dictionary:
	settings = _default_settings()
	apply_settings()
	save_settings()
	return settings

func get_setting(section: String, key: String, default_value = null):
	if settings.has(section):
		if key == "" or key == null:
			return settings[section]
		if settings[section] is Dictionary and settings[section].has(key):
			return settings[section][key]
		if section == "controls" and settings[section] is Dictionary and settings[section].has("mobile") and settings[section]["mobile"] is Dictionary and settings[section]["mobile"].has(key):
			return settings[section]["mobile"][key]
		if section == "controls" and settings[section] is Dictionary and settings[section].has("pc") and settings[section]["pc"] is Dictionary and settings[section]["pc"].has(key):
			return settings[section]["pc"][key]
	return default_value

func set_setting(section: String, key: String, value) -> void:
	if key == "" or key == null:
		settings[section] = value
		save_settings()
		apply_settings()
		return
	if section == "language":
		settings["language"] = value
		save_settings()
		apply_settings()
		return
	if section == "controls":
		if not settings.has("controls") or not (settings["controls"] is Dictionary):
			settings["controls"] = {"pc": {}, "mobile": {}}
		if key in ["joystick_size", "joystick_opacity", "button_size", "button_opacity", "hud_scale", "aim_sensitivity", "joystick_sensitivity", "auto_fire", "auto_aim"]:
			var mobile_settings: Dictionary = Dictionary(settings["controls"].get("mobile", {}))
			mobile_settings[key] = value
			settings["controls"]["mobile"] = mobile_settings
		else:
			var pc_settings: Dictionary = Dictionary(settings["controls"].get("pc", {}))
			pc_settings[key] = value
			settings["controls"]["pc"] = pc_settings
		save_settings()
		apply_settings()
		return
	if not settings.has(section) or not (settings[section] is Dictionary):
		settings[section] = {}
	settings[section][key] = value
	save_settings()
	apply_settings()

func apply_settings() -> void:
	var graphics: Dictionary = settings.get("graphics", {})
	var audio: Dictionary = settings.get("audio", {})
	var ui: Dictionary = settings.get("ui", {})
	var controls: Dictionary = settings.get("controls", {})
	var pc_controls: Dictionary = controls.get("pc", {}) if controls.get("pc", {}) is Dictionary else {}
	var display_mode := str(graphics.get("display_mode", "windowed")).to_lower()
	var fullscreen := bool(graphics.get("fullscreen", false))
	var resolution_text := str(graphics.get("resolution", "1280x720"))
	var split := resolution_text.split("x")
	var width := 1280
	var height := 720
	if split.size() >= 2:
		width = max(800, int(split[0]))
		height = max(600, int(split[1]))
	if fullscreen or display_mode == "fullscreen":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(width, height))
	
	if graphics.has("vsync"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(graphics.get("vsync", true)) else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = maxi(30, int(graphics.get("fps_limit", 60)))
	
	for bus_index in range(AudioServer.bus_count):
		var bus_name := AudioServer.get_bus_name(bus_index).to_lower()
		if bus_name.contains("master"):
			AudioServer.set_bus_volume_db(bus_index, linear_to_db(float(audio.get("master_volume", 1.0))))
		elif bus_name.contains("music"):
			AudioServer.set_bus_volume_db(bus_index, linear_to_db(float(audio.get("music_volume", 0.9))))
		elif bus_name.contains("sfx") or bus_name.contains("effect"):
			AudioServer.set_bus_volume_db(bus_index, linear_to_db(float(audio.get("effects_volume", 0.9))))
		elif bus_name.contains("ui"):
			AudioServer.set_bus_volume_db(bus_index, linear_to_db(float(audio.get("ui_volume", 0.8))))

	if has_node("/root/GlobalState"):
		var gs = get_node("/root/GlobalState")
		if gs.has_method("load_game"):
			pass
	_apply_pc_keybinds(pc_controls)
	if has_node("/root/GlobalState"):
		var gs = get_node("/root/GlobalState")
		if gs.has_method("save_game"):
			gs.save_game()

func _apply_pc_keybinds(pc_controls: Dictionary) -> void:
	var action_to_default := {
		"move_forward": KEY_W,
		"move_back": KEY_S,
		"move_left": KEY_A,
		"move_right": KEY_D,
		"fire": KEY_SPACE,
		"target": KEY_TAB,
		"laser": KEY_Q,
		"rocket": KEY_E,
		"extra": KEY_R,
		"config": KEY_C,
		"gate": KEY_G,
		"minimap": KEY_M,
		"menu": KEY_ESCAPE,
		"market": KEY_B,
		"equipment": KEY_I,
		"quests": KEY_J,
		"next_ammo": KEY_1
	}
	for action_name in action_to_default.keys():
		var keycode: int = int(pc_controls.get(action_name, action_to_default[action_name]))
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
		var existing_events: Array = InputMap.action_get_events(action_name)
		for event in existing_events:
			if event is InputEventKey:
				InputMap.action_erase_event(action_name, event)
		var event := InputEventKey.new()
		event.keycode = keycode
		InputMap.action_add_event(action_name, event)

func get_mobile_settings() -> Dictionary:
	var controls: Dictionary = settings.get("controls", {})
	if controls.has("mobile") and controls["mobile"] is Dictionary:
		return controls["mobile"]
	return _default_settings()["controls"]["mobile"]

func get_language_options() -> Array:
	# NovaGate dilleri: Turkce / English (BOLUM 20).
	return LANGUAGE_CODES.duplicate()

# ==========================================================================
# NOVAGATE LANGUAGE (BOLUM 20)
# --------------------------------------------------------------------------
# Kucuk, settings.json icinde KALICI dil cekirdegi. Ikinci bir localization
# sistemi YAZILMADI; mevcut SettingsManager autoload'unun uzerine eklendi.
# Secilen dil user://settings.json icinde saklanir (save/load otomatik).
# ==========================================================================
const LANGUAGE_CODES: Array[String] = ["tr", "en"]

func get_language() -> String:
	var code := str(get_setting("language", "", "tr")).to_lower()
	return code if LANGUAGE_CODES.has(code) else "tr"


func set_language(code: String) -> void:
	var clean := str(code).strip_edges().to_lower()
	if not LANGUAGE_CODES.has(clean):
		return
	set_setting("language", "", clean)
	# set_setting() zaten save_settings + apply_settings + settings_changed yapar.


func translate(key: String) -> String:
	# Dil tablosu kod tarafindan gelir (ikinci bir localization sistemi yazilmadi);
	# yalnizca secilen dil kodu settings.json icinde KALICI olarak saklanir.
	var sections: Dictionary = _default_language_sections()
	var table_value = sections.get(get_language(), {})
	if not (table_value is Dictionary):
		return key
	return str((table_value as Dictionary).get(key, key))


func nickname_cooldown_info() -> Dictionary:
	# Account/nickname UI'i icin kalan sure bilgisi (gun + saat).
	var am = load("res://scripts/account_manager.gd").new()
	var info: Dictionary = {"cooldown_active": false, "days": 0, "hours": 0, "message": translate("NICK_READY")}
	var username := str(am.call("get_current_player")).strip_edges()
	if username.is_empty():
		am.free()
		info["message"] = translate("ACC_NO_ACCOUNT")
		return info
	var players = am.call("load_players")
	am.free()
	if not (players is Array):
		info["message"] = translate("ACC_NO_ACCOUNT")
		return info
	for player_value in players:
		if not (player_value is Dictionary):
			continue
		var player: Dictionary = player_value
		if str(player.get("username", "")) != username:
			continue
		var last_change: int = int(player.get("nickname_last_change", 0))
		if last_change <= 0:
			return info
		var now: int = int(Time.get_unix_time_from_system())
		var remaining_seconds: int = maxi(0, last_change + int(NICKNAME_COOLDOWN_SECONDS) - now)
		if remaining_seconds <= 0:
			return info
		info["cooldown_active"] = true
		info["days"] = int(remaining_seconds / 86400)
		info["hours"] = int((remaining_seconds % 86400) / 3600.0)
		info["message"] = translate("NICK_COOLDOWN") % [info["days"], info["hours"]]
		return info
	info["message"] = translate("ACC_NO_ACCOUNT")
	return info

const NICKNAME_COOLDOWN_SECONDS := 7 * 24 * 3600

# --------------------------------------------------------------------------
# NOVAGATE LANGUAGE TABLE (tr/en). Uzun tablo; guncellemesi kolay olsun diye
# tek Dictionary'ye ayrildi. Eksik anahtar fallback olarak anahtarin kendisini
# dondurur; boylece yeni UI metinleri sorunlu davranmaz.
# --------------------------------------------------------------------------
func _default_language_sections() -> Dictionary:
	# Kullaniciya gosterilen metinler icin tek kaynak (tr/en).
	# Gate veri/id isimleri (alpha/beta/gamma, map id'leri) burada YOKTUR.
	return {
		"tr": {
			"SETTINGS": "AYARLAR",
			"GENERAL": "GENEL",
			"CONTROLS": "KONTROLLER",
			"GRAPHICS": "GRAFİK",
			"AUDIO": "SES",
			"LANGUAGE": "DİL",
			"ACCOUNT": "HESAP",
			"GAME": "OYUN",
			"ACCOUNT_USERNAME": "Kullanıcı Adı",
			"ACCOUNT_NICKNAME": "Takma Ad",
			"ACCOUNT_PASSWORD": "Şifre",
			"ACCOUNT_PLAYER_ID": "Player ID",
			"ACCOUNT_COMPANY": "Şirket",
			"ACCOUNT_LEVEL": "Seviye",
			"ACC_NO_ACCOUNT": "Hesap bilgisi bulunamadı.",
			"CHANGE_NICKNAME": "NICKNAME DEĞİŞTİR",
			"NICK_READY": "Nickname değiştirebilirsin.",
			"NICK_COOLDOWN": "Nickname değiştirmek için %d gün %d saat beklemelisin.",
			"NICK_CHANGED": "Nickname değiştirildi: %s",
			"NICK_EMPTY": "Nickname boş olamaz.",
			"NICK_TOO_SHORT": "Nickname en az 3 karakter olmalı.",
			"NICK_TOO_LONG": "Nickname en fazla 20 karakter olabilir.",
			"NICK_SAME": "Bu nickname mevcut nickname ile aynı.",
			"NICK_INVALID_CHARS": "Nickname geçersiz karakterler içeriyor.",
			"NICK_TAKEN": "Bu nickname başka bir oyuncuda kullanılıyor.",
			"CHANGE_PASSWORD": "ŞİFRE DEĞİŞTİR",
			"CURRENT_PASSWORD": "Mevcut Şifre",
			"NEW_PASSWORD": "Yeni Şifre",
			"CONFIRM_NEW_PASSWORD": "Yeni Şifre (Tekrar)",
			"PASSWORD_CHANGED": "Şifre değiştirildi.",
			"PASSWORD_WRONG": "Mevcut şifre hatalı.",
			"PASSWORD_TOO_SHORT": "Yeni şifre en az 6 karakter olmalı.",
			"PASSWORD_MISMATCH": "Yeni şifreler birbiriyle uyuşmuyor.",
			"PASSWORD_SAME": "Yeni şifre eski şifreyle aynı olamaz.",
			"PASSWORD_EMPTY": "Şifre boş bırakılamaz.",
			"LANGUAGE_TR": "Türkçe",
			"LANGUAGE_EN": "English",
			"GATE_MENU": "GALAXY GATES",
			"GATE_TITLE": "GALAXY GATES",
			"GATE_PARTS": "PARÇA",
			"GATE_SELECT": "SEÇ",
			"GATE_MATERIALIZE": "MATERIALIZER",
			"GATE_ACTIVATE": "AKTİF ET",
			"GATE_ENTER": "GATE'E GİR",
			"GATE_COMPLETED": "TAMAMLANDI",
			"GATE_ACTIVE": "AKTİF",
			"GATE_READY": "HAZIR",
			"GATE_PARTS_STATUS": "PARÇA",
			"GATE_NOT_ACTIVE": "Gate aktif değil.",
			"GATE_FOOTER": "Materializer: 1 spin = %d PLT. Parça şansı %%%d. X1 bonus kutularından da parça düşebilir.",
			"GATE_INFO": "Seçili materializer gate: %s   |   PLT: %d   |   BTC: %d",
			"MENÜ": "MENÜ",
			"AYARLAR": "AYARLAR",
			"GALAXY GATES": "GALAXY GATES",
			"EKİPMAn": "EKİPMAN",
			"YETENEK AĞACI": "YETENEK AĞACI",
			"MARKET": "MARKET",
			"GÖREVLER": "GÖREVLER",
			"KLAn": "KLAN",
			"İSTATİSTİKLER": "İSTATİSTİKLER",
			"HARİTA": "HARİTA",
			"OYUNA DÖn": "OYUNA DÖN"
		},
		"en": {
			"SETTINGS": "SETTINGS",
			"GENERAL": "GENERAL",
			"CONTROLS": "CONTROLS",
			"GRAPHICS": "GRAPHICS",
			"AUDIO": "AUDIO",
			"LANGUAGE": "LANGUAGE",
			"ACCOUNT": "ACCOUNT",
			"GAME": "GAME",
			"ACCOUNT_USERNAME": "Username",
			"ACCOUNT_NICKNAME": "Nickname",
			"ACCOUNT_PASSWORD": "Password",
			"ACCOUNT_PLAYER_ID": "Player ID",
			"ACCOUNT_COMPANY": "Company",
			"ACCOUNT_LEVEL": "Level",
			"ACC_NO_ACCOUNT": "No account information found.",
			"CHANGE_NICKNAME": "CHANGE NICKNAME",
			"NICK_READY": "You can change your nickname.",
			"NICK_COOLDOWN": "You must wait %d days %d hours before changing your nickname.",
			"NICK_CHANGED": "Nickname changed: %s",
			"NICK_EMPTY": "Nickname cannot be empty.",
			"NICK_TOO_SHORT": "Nickname must be at least 3 characters.",
			"NICK_TOO_LONG": "Nickname must be at most 20 characters.",
			"NICK_SAME": "This nickname is the same as the current one.",
			"NICK_INVALID_CHARS": "Nickname contains invalid characters.",
			"NICK_TAKEN": "This nickname is already used by another player.",
			"CHANGE_PASSWORD": "CHANGE PASSWORD",
			"CURRENT_PASSWORD": "Current Password",
			"NEW_PASSWORD": "New Password",
			"CONFIRM_NEW_PASSWORD": "Confirm New Password",
			"PASSWORD_CHANGED": "Password changed.",
			"PASSWORD_WRONG": "Current password is incorrect.",
			"PASSWORD_TOO_SHORT": "New password must be at least 6 characters.",
			"PASSWORD_MISMATCH": "New passwords do not match.",
			"PASSWORD_SAME": "New password must differ from the old one.",
			"PASSWORD_EMPTY": "Password cannot be empty.",
			"LANGUAGE_TR": "Türkçe",
			"LANGUAGE_EN": "English",
			"GATE_MENU": "GALAXY GATES",
			"GATE_TITLE": "GALAXY GATES",
			"GATE_PARTS": "PARTS",
			"GATE_SELECT": "SELECT",
			"GATE_MATERIALIZE": "MATERIALIZE",
			"GATE_ACTIVATE": "ACTIVATE",
			"GATE_ENTER": "ENTER GATE",
			"GATE_COMPLETED": "COMPLETED",
			"GATE_ACTIVE": "ACTIVE",
			"GATE_READY": "READY",
			"GATE_PARTS_STATUS": "PARTS",
			"GATE_NOT_ACTIVE": "Gate is not active.",
			"GATE_FOOTER": "Materializer: 1 spin = %d PLT. Gate part chance %d%%. Bonus boxes in X1 can also drop parts.",
			"GATE_INFO": "Selected materializer gate: %s   |   PLT: %d   |   BTC: %d",
			"MENÜ": "MENU",
			"AYARLAR": "SETTINGS",
			"GALAXY GATES": "GALAXY GATES",
			"EKİPMAn": "EQUIPMENT",
			"YETENEK AĞACI": "SKILL TREE",
			"MARKET": "MARKET",
			"GÖREVLER": "QUESTS",
			"KLAn": "CLAN",
			"İSTATİSTİKLER": "STATISTICS",
			"HARİTA": "MAP",
			"OYUNA DÖn": "RETURN TO GAME"
		}
	}
