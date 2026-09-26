extends Control
@export var main_path: NodePath = NodePath("../..")
@export var player_path: NodePath = NodePath("../../PlayerShip")
@onready var main_node: node = get_node_or_null(main_path)
@onready var player: node = get_node_or_null(player_path)
var menu_button: Button

var overlay: ColorRect
var window_panel: Panel
var main_menu: Control
var hangar_screen: Control
var section_screen: Control
var section_title_label: Label
var section_body_label: Label
var section_content_panel: Panel
var market_host: Control
var market_instance: Control
var _menu_section_generation: int = 0
var _active_menu_section: String = ""
var center_host: Control
var inventory_grid: GridContainer
var stats_label: Label
var selection_label: Label
var config_one_button: Button

var config_two_button: Button

var ship_tab_button: Button

var drone_tab_button: Button

var config_indicator: Label
var selected_item: String = ""
var droid_sell_in_progress: bool = false
var selected_config: int = 1
var selected_tab: String = "ship"
# A rutbesi admin panelinde son islemin sonucu (yalnizca admin gorur).
var _a_rank_status_message: String = ""
# A rutbesi panelinde ayni anda listelenen oyuncu sayisi.
const A_RANK_ADMIN_ROWS := 6
const RankData = preload("res://scripts/rank_data.gd")
const RankService = preload("res://scripts/rank_service.gd")
const RankBadge = preload("res://scripts/rank_badge.gd")
const SHIP_LASER_SLOTS := 60
const SHIP_GENERATOR_SLOTS := 32
const NORMAL_LASER_SLOT_CAP := 30
const NORMAL_GENERATOR_SLOT_CAP := 16
const SHIP_EXTRA_SLOTS := 8
const DRONE_COUNT := 8
const ITEM_DATA: Dictionary = {
				"LF1": {"icon": "res://assets/equipment/pro/lf1.png", "type": "laser", "damage": 90, "title": "LF1"},
				"LF2": {"icon": "res://assets/equipment/pro/lf2.png", "type": "laser", "damage": 132, "title": "LF2"},
				"LF3": {"icon": "res://assets/equipment/pro/lf3.png", "type": "laser", "damage": 210, "title": "LF3"},
				"Kalkan 1": {"icon": "res://assets/equipment/pro/shield1.png", "type": "generator", "shield": 5000, "title": "Kalkan I"},
				"Kalkan 2": {"icon": "res://assets/equipment/pro/shield2.png", "type": "generator", "shield": 10000, "title": "Kalkan II"},
				"Hız 1": {"icon": "res://assets/equipment/pro/speed1.png", "type": "generator", "speed": 7, "title": "Hız I"},
				"Hız 2": {"icon": "res://assets/equipment/pro/speed2.png", "type": "generator", "speed": 10, "title": "Hız II"},
				"PBMB": {"icon": "res://assets/equipment/pro/ext1.png", "type": "extra", "title": "PBMB"},
				"WSH": {"icon": "res://assets/equipment/pro/ext2.png", "type": "extra", "title": "WSH"},
				"EMP": {"icon": "res://assets/equipment/pro/ext3.png", "type": "extra", "title": "EMP"},
				"INVIS": {"icon": "res://assets/equipment/pro/ext4.png", "type": "extra", "title": "INVIS"},
				"FREP": {"icon": "res://assets/equipment/pro/ext5.png", "type": "extra", "title": "FREP"},
				"ENC": {"icon": "res://assets/equipment/pro/ext6.png", "type": "extra", "title": "ENC"},
				"ACPR": {"icon": "res://assets/equipment/pro/ext7.png", "type": "extra", "title": "ACPR"},
				"DMG-B01": {"icon": "res://market/assets/boosters/DMG-B01.png", "type": "extra", "title": "DMG-B01"},
				"HP-B01": {"icon": "res://market/assets/boosters/HP-B01.png", "type": "extra", "title": "HP-B01"},
				"SHD-B01": {"icon": "res://market/assets/boosters/SHD-B01.png", "type": "extra", "title": "SHD-B01"},
				"XP-B01": {"icon": "res://market/assets/boosters/XP-B01.png", "type": "extra", "title": "XP-B01"},
				"HOn-B01": {"icon": "res://market/assets/boosters/HOn-B01.png", "type": "extra", "title": "HOn-B01"}
}
var inventory: Dictionary = {
				"LF1": 0,
				"LF2": 0,
				"LF3": 0,
				"Kalkan 1": 0,
				"Kalkan 2": 0,
				"Hız 1": 0,
				"Hız 2": 0,
				"PBMB": 0,
				"WSH": 0,
				"EMP": 0,
				"INVIS": 0,
				"FREP": 0,
				"ENC": 0,
				"ACPR": 0,
				"DMG-B01": 0,
				"HP-B01": 0,
				"SHD-B01": 0,
				"XP-B01": 0,
				"HOn-B01": 0
}
var owned_droid_types: Array = []
var owned_ships: Array = ["Ship10"]
var active_ship_id: String = "Ship10"
var ship_catalog: Dictionary = {}
var active_ship_data: Dictionary = {}
var active_ship_image: TextureRect = null
var configurations: Dictionary = {}
var ship_configurations: Dictionary = {}
var server_loadout_sync_queued: bool = false
var migrate_local_loadout_to_server: bool = false

func _ready() -> void:
				add_to_group("menu_ui")
				QuestSystem.quests_changed.connect(_refresh_available_quests, CONNECT_DEFERRED)
				process_mode = node.PROCESS_MODE_ALWAYS
				set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				mouse_filter = Control.MOUSE_FILTER_IGNORE
				_initialize_configurations()
				_build_menu_button()
				_build_overlay()
				call_deferred("refresh_info")
				# Oyun açılır açılmaz server loadout'unu canlı gemiye uygula.
				# Hangarın açılmasını bekleme.
				call_deferred("_refresh_stats")
				if player != null and player.has_method("set_active_config"):
								player.call("set_active_config", selected_config)
				_show_main_menu()nfunc _unhandled_input(event: InputEvent) -> void:
				if event is InputEventKey:
								var key_event := event as InputEventKey
								if key_event.pressed and not key_event.echo and key_event.keycode == KEY_ESCAPE and overlay != null and overlay.visible:
												_close_all()
												get_viewport().set_input_as_handled()
												retur

								if key_event.pressed and not key_event.echo and key_event.keycode == KEY_C:
												_set_config(2 if selected_config == 1 else 1)
												get_viewport().set_input_as_handled()nfunc _initialize_configurations() -> void:
	var account_manager = load("res://scripts/account_manager.gd").new()
	var username: String = account_manager.get_current_player()
	var saved_player = account_manager.get_player(username)
	_load_ship_catalog()
	_load_owned_items(saved_player)
	# SERVER OTURUMUNDA sahiplik yalnız PostgreSQL canlı verisinden okunur.
	if GlobalState.server_session_active:
		inventory = {
			"LF1": 0, "LF2": 0, "LF3": 0,
			"Kalkan 1": 0, "Kalkan 2": 0,
			"Hız 1": 0, "Hız 2": 0,
			"PBMB": 0, "WSH": 0, "EMP": 0, "INVIS": 0,
			"FREP": 0, "ENC": 0, "ACPR": 0,
			"DMG-B01": 0,
			"HP-B01": 0,
			"SHD-B01": 0,
			"XP-B01": 0,
			"HOn-B01": 0
		}
		for item_name in GlobalState.inventory.keys():
			inventory[str(item_name)] = maxi(int(GlobalState.inventory.get(item_name, 0)), 0)
		owned_droid_types = GlobalState.droid_types.duplicate()
		while owned_droid_types.size() > DRONE_COUNT:
			owned_droid_types.pop_back()
		owned_ships = GlobalState.owned_ships.duplicate()
		if not owned_ships.has("Ship10"):
			owned_ships.push_front("Ship10")
		if not owned_ships.has(active_ship_id):
			active_ship_id = "Ship10"
		active_ship_data = _get_ship_data(active_ship_id)
	# Her geminin ekipmanı birbirinden tamamen bağımsızdır.
	ship_configurations = {}
	if GlobalState.server_session_active and not GlobalState.ship_configurations.is_empty():
		for ship_key in GlobalState.ship_configurations.keys():
			var pair_value=GlobalState.ship_configurations[ship_key]
			if pair_value is Dictionary:
				var pair:Dictionary=pair_value
				ship_configurations[str(ship_key)]={
					1:_normalize_configuration(pair.get("1",pair.get(1,_new_configuration()))),
					2:_normalize_configuration(pair.get("2",pair.get(2,_new_configuration())))
				}
	else:
		if saved_player!=null and saved_player.has("ship_configurations") and saved_player["ship_configurations"] is Dictionary:
			for ship_key in saved_player["ship_configurations"].keys():
				var pair_value=saved_player["ship_configurations"][ship_key]
				if pair_value is Dictionary:
					var pair:Dictionary=pair_value
					ship_configurations[str(ship_key)]={
						1:_normalize_configuration(pair.get("1",pair.get(1,_new_configuration()))),
						2:_normalize_configuration(pair.get("2",pair.get(2,_new_configuration())))
					}
			if GlobalState.server_session_active and not ship_configurations.is_empty():
				migrate_local_loadout_to_server=true
	if ship_configurations.is_empty() and saved_player!=null and saved_player.has("configurations"):
		var legacy:Dictionary=saved_player["configurations"]
		ship_configurations[active_ship_id]={
			1:_normalize_configuration(legacy.get("1",legacy.get(1,_new_configuration()))),
			2:_normalize_configuration(legacy.get("2",legacy.get(2,_new_configuration())))
		}
		if GlobalState.server_session_active: migrate_local_loadout_to_server=true
	# Sahip olunan fakat daha önce hiç kullanılmamış her gemi BOŞ başlar.
	for ship_value in owned_ships:
		_ensure_ship_configuration(str(ship_value))
	_ensure_ship_configuration(active_ship_id)
	configurations = ship_configurations[active_ship_id]
	if GlobalState.server_session_active and not GlobalState.ship_configurations.is_empty():
		selected_config=GlobalState.selected_config
		if owned_ships.has(GlobalState.active_ship_id):
			active_ship_id=GlobalState.active_ship_id
			active_ship_data=_get_ship_data(active_ship_id)
			_ensure_ship_configuration(active_ship_id)
			configurations=ship_configurations[active_ship_id]
	else:
		selected_config = int(saved_player.get("selected_config", 1)) if saved_player != null else 1
		if selected_config != 1 and selected_config != 2:
			selected_config = 1
	if migrate_local_loadout_to_server:
		call_deferred("_queue_server_loadout_sync")

func _normalize_configuration(config_value) -> Dictionary:
	var config:Dictionary = config_value if config_value is Dictionary else _new_configuration()
	for key in ["lasers", "generators", "extras", "drones"]:
		if not config.has(key) or not (config[key] is Array):
			config[key] = []
	var lasers:Array = config["lasers"]
	var generators:Array = config["generators"]
	var extras:Array = config["extras"]
	var drones:Array = config["drones"]
	lasers.resize(SHIP_LASER_SLOTS)
	generators.resize(SHIP_GENERATOR_SLOTS)
	extras.resize(SHIP_EXTRA_SLOTS)
	drones.resize(DRONE_COUNT * DRONE_SLOTS_PER_DRONE)
	return confignfunc _load_owned_items(saved_player) -> void:
	inventory = {
		"LF1": 0,
		"LF2": 0,
		"LF3": 0,
		"Kalkan 1": 0,
		"Kalkan 2": 0,
		"Hız 1": 0,
		"Hız 2": 0,
		"PBMB": 0,
		"WSH": 0,
		"EMP": 0,
		"INVIS": 0,
		"FREP": 0,
		"ENC": 0,
		"ACPR": 0
	}
	owned_droid_types = []
	owned_ships = ["Ship10"]
	active_ship_id = "Ship10"
	active_ship_data = _get_ship_data("Ship10")
	if saved_player == null:
		retur

	var saved_inventory = saved_player.get("inventory", {})
	if saved_inventory is Dictionary:
		for item_name in inventory.keys():
			inventory[item_name] = maxi(int(saved_inventory.get(item_name, 0)), 0)
	var saved_droids = saved_player.get("droid_types", [])
	if saved_droids is Array:
		for droid_name in saved_droids:
			var normalized := str(droid_name).to_upper()
			if normalized == "PLUS" or normalized == "ZEUS":
				owned_droid_types.append(normalized)
	var saved_ships = saved_player.get("owned_ships", ["Ship10"])
	if saved_ships is Array:
		owned_ships = saved_ships.duplicate()
	if not owned_ships.has("Ship10"):
		owned_ships.push_front("Ship10")
	active_ship_id = str(saved_player.get("active_ship", "Ship10"))
	if not owned_ships.has(active_ship_id):
		active_ship_id = "Ship10"
	active_ship_data = _get_ship_data(active_ship_id)
	while owned_droid_types.size() > DRONE_COUNT:
		owned_droid_types.pop_back()nfunc _load_ship_catalog() -> void:
	ship_catalog.clear()
	var path := "res://market/data/ships.json"
	if not FileAccess.file_exists(path):
		retur

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		retur

	var parsed = JSOn.parse_string(f.get_as_text())
	if parsed is Array:
		for ship_value in parsed:
			if ship_value is Dictionary:
				var ship:Dictionary = ship_value
				ship_catalog[str(ship.get("id", ""))] = shipnfunc _get_ship_data(ship_id:String) -> Dictionary:
	if ship_catalog.is_empty():
		_load_ship_catalog()
	var value = ship_catalog.get(ship_id, {})
	return value if value is Dictionary else {}nfunc _ship_slot_limit(slot_type:String) -> int:
	if active_ship_data.is_empty():
		active_ship_data = _get_ship_data(active_ship_id)
	match slot_type:
		"laser":
			var base_laser := clampi(int(active_ship_data.get("laser_slots", 1)), 0, NORMAL_LASER_SLOT_CAP)
			return mini(base_laser * 2, SHIP_LASER_SLOTS) if GlobalState.is_admin else base_laser
		"generator":
			var base_generator := clampi(int(active_ship_data.get("generator_slots", 1)), 0, NORMAL_GENERATOR_SLOT_CAP)
			return mini(base_generator * 2, SHIP_GENERATOR_SLOTS) if GlobalState.is_admin else base_generator
		"extra":
			return clampi(int(active_ship_data.get("extra_slots", 0)), 0, SHIP_EXTRA_SLOTS)
	return 0nfunc reload_owned_items_from_save() -> void:
	_load_ship_catalog()
	var old_droid_count := owned_droid_types.size()
	var previous_active_ship := active_ship_id
	if previous_active_ship != "":
		ship_configurations[previous_active_ship] = configurations
	var account_manager = load("res://scripts/account_manager.gd").new()
	var username: String = account_manager.get_current_player()
	var saved_player = account_manager.get_player(username)
	_load_owned_items(saved_player)
	# Yeni satın alınan gemiler için boş loadout oluştur.
	for ship_value in owned_ships:
		_ensure_ship_configuration(str(ship_value))
	# Yeni alınan droid, eski/stale slot içeriğini miras almasın.
	_clear_new_droid_slots(old_droid_count, owned_droid_types.size())
	_ensure_ship_configuration(active_ship_id)
	configurations = ship_configurations[active_ship_id]
	_save_configurations()
	_refresh_all()

func _owned_droid_slot_indices() -> Array:
	var result: Array = []
	for droid_index in range(owned_droid_types.size()):
		var base_index := droid_index * DRONE_SLOTS_PER_DRONE
		result.append(base_index)
		if str(owned_droid_types[droid_index]) == "ZEUS":
			result.append(base_index + 1)
	return result

func _new_configuration() -> Dictionary:
				var lasers: Array = []
				lasers.resize(SHIP_LASER_SLOTS)
				var generators: Array = []
				generators.resize(SHIP_GENERATOR_SLOTS)
				var extras: Array = []
				extras.resize(SHIP_EXTRA_SLOTS)
				var drones: Array = []
				drones.resize(DRONE_COUNT * DRONE_SLOTS_PER_DRONE)
				return {
								"lasers": lasers,
								"generators": generators,
								"extras": extras,
								"drones": drones
				}nfunc _ensure_ship_configuration(ship_id: String) -> void:
	if ship_id == "":
		retur

	if ship_configurations.has(ship_id) and ship_configurations[ship_id] is Dictionary:
		var existing: Dictionary = ship_configurations[ship_id]
		ship_configurations[ship_id] = {
			1: _normalize_configuration(existing.get("1", existing.get(1, _new_configuration()))),
			2: _normalize_configuration(existing.get("2", existing.get(2, _new_configuration())))
		}
		retur

	ship_configurations[ship_id] = {
		1: _new_configuration(),
		2: _new_configuration()
	}nfunc _clear_new_droid_slots(old_count: int, new_count: int) -> void:
	if new_count <= old_count:
		retur

	for ship_id in ship_configurations.keys():
		var pair_value = ship_configurations[ship_id]
		if not (pair_value is Dictionary):
			continue
		var pair: Dictionary = pair_value
		for config_number in [1, 2]:
			var config_value = pair.get(config_number, pair.get(str(config_number), null))
			if not (config_value is Dictionary):
				continue
			var config: Dictionary = config_value
			var slots: Array = config.get("drones", [])
			for droid_index in range(old_count, new_count):
				var base_index := droid_index * DRONE_SLOTS_PER_DRONE
				if base_index < slots.size():
					slots[base_index] = null
				if base_index + 1 < slots.size():
					slots[base_index + 1] = nullnfunc _build_menu_button() -> void:
				menu_button = Button.new()
				menu_button.text = "MEnÜ"
				menu_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
				menu_button.offset_left = -230.0
				menu_button.offset_top = 172.0
				menu_button.offset_right = -20.0
				menu_button.offset_bottom = 216.0
				menu_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
				menu_button.add_theme_font_size_override("font_size", 18)
				menu_button.add_theme_stylebox_override("normal", _panel_style(Color(0.025, 0.075, 0.11, 0.96), Color(0.15, 0.8, 1.0, 0.95), 2))
				menu_button.add_theme_stylebox_override("hover", _panel_style(Color(0.04, 0.14, 0.20, 0.98), Color(0.35, 0.95, 1.0, 1.0), 2))
				menu_button.pressed.co
nect(_open_menu)
				add_child(menu_button)
				config_indicator = Label.new()
				config_indicator.set_anchors_preset(Control.PRESET_TOP_RIGHT)
				config_indicator.offset_left = -230.0
				config_indicator.offset_top = 220.0
				config_indicator.offset_right = -20.0
				config_indicator.offset_bottom = 250.0
				config_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				config_indicator.add_theme_font_size_override("font_size", 16)
				config_indicator.add_theme_color_override("font_color", Color(0.4, 0.95, 1.0))
				config_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
				add_child(config_indicator)
				_update_config_indicator()nfunc _build_overlay() -> void:
				overlay = ColorRect.new()
				overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				overlay.color = Color(0.0, 0.0, 0.0, 0.72)
				overlay.mouse_filter = Control.MOUSE_FILTER_STOP
				overlay.visible = false
				add_child(overlay)
				window_panel = Panel.new()
				window_panel.set_anchors_preset(Control.PRESET_CENTER)
				window_panel.offset_left = -600.0
				window_panel.offset_top = -330.0
				window_panel.offset_right = 600.0
				window_panel.offset_bottom = 330.0
				window_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.012, 0.025, 0.04, 0.995), Color(0.08, 0.72, 0.92, 1.0), 2))
				overlay.add_child(window_panel)
				var title := Label.new()
				title.text = "NOVA GATE"
				title.position = Vector2(20, 12)
				title.size = Vector2(1160, 40)
				title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				title.add_theme_font_size_override("font_size", 25)
				title.add_theme_color_override("font_color", Color(0.35, 0.92, 1.0))
				window_panel.add_child(title)
				var close_button := Button.new()
				close_button.text = "X"
				close_button.position = Vector2(1142, 12)
				close_button.size = Vector2(42, 38)
				close_button.pressed.co
nect(_close_all)
				window_panel.add_child(close_button)
				var host := Control.new()
				host.position = Vector2(16, 58)
				host.size = Vector2(1168, 586)
				window_panel.add_child(host)
				GlobalState.load_game()
				main_menu = _build_main_menu()
				host.add_child(main_menu)
				hangar_screen = _build_unified_hangar()
				host.add_child(hangar_screen)
				section_screen = _build_section_screen()
				host.add_child(section_screen)nfunc _build_main_menu() -> Control:
				var root := Control.new()
				root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				var heading := Label.new()
				heading.text = "NOVA GATE • KONTROL PANELİ"
				heading.position = Vector2(250, 5)
				heading.size = Vector2(668, 48)
				heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				heading.add_theme_font_size_override("font_size", 29)
				heading.add_theme_color_override("font_color", Color(0.45, 0.92, 1.0))
				root.add_child(heading)
				var items = ["YETENEK AĞACI","EKİPMAn","MARKET","GÖREVLER","KLAn","İSTATİSTİKLER","HARİTA","AYARLAR"]
				for i in range(items.size()):
								var b := _large_button(items[i])
								b.position = Vector2(20, 70 + i * 55)
								b.size = Vector2(220, 45)
								if items[i] == "EKİPMAn":
												b.pressed.co
nect(_show_hangar)
								else:
												b.pressed.co
nect(_show_section.bind(items[i]))
								root.add_child(b)
				var info := Label.new()
				info.name = "PilotInfo"
				var selected_company = GlobalState.company
				var player_id := str(GlobalState.player_id)
				info.text = "PİLOT BİLGİLERİNOyuncu ID: %snŞirket: %sNSeviye: %dNBitcoin: %dNPLT: %dNTecrübe: %dnŞeref: %d" % [
					player_id,
					selected_company,
					GlobalState.level,
					GlobalState.bitcoin,
					GlobalState.platinum,
					GlobalState.xp,
					GlobalState.honor
				]
				info.position = Vector2(280, 80)
				info.size = Vector2(350, 300)
				info.add_theme_font_size_override("font_size", 20)
				info.name = "PilotInfo"
				root.add_child(info)
				var log := Label.new()
				log.text = "SİSTEM GÜNLÜĞÜn[12:45] nova Gate'e hoş geldin.n[12:46] Günlük giriş bonusu alındı.n[12:50] Sistem hazır."
				log.position = Vector2(700, 80)
				log.size = Vector2(380, 300)
				log.add_theme_font_size_override("font_size", 18)
				root.add_child(log)
				var continue_button := _large_button("OYUNA DÖn")
				continue_button.position = Vector2(430, 470)
				continue_button.size = Vector2(300, 60)
				continue_button.pressed.co
nect(_close_all)
				root.add_child(continue_button)
				return rootnfunc _build_section_screen() -> Control:
				var root := Control.new()
				root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				var back := Button.new()
				back.text = "← MEnÜ"
				back.position = Vector2(8, 0)
				back.size = Vector2(112, 38)
				back.pressed.co
nect(_show_main_menu)
				root.add_child(back)
				section_title_label = Label.new()
				section_title_label.position = Vector2(150, 15)
				section_title_label.size = Vector2(868, 48)
				section_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				section_title_label.add_theme_font_size_override("font_size", 28)
				section_title_label.add_theme_color_override("font_color", Color(0.45, 0.92, 1.0))
				root.add_child(section_title_label)
				section_content_panel = Panel.new()
				section_content_panel.position = Vector2(130, 85)
				section_content_panel.size = Vector2(908, 430)
				section_content_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.018, 0.042, 0.065, 0.98), Color(0.07, 0.38, 0.52), 1))
				root.add_child(section_content_panel)
				section_body_label = Label.new()
				section_body_label.position = Vector2(35, 35)
				section_body_label.size = Vector2(838, 360)
				section_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				section_body_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
				section_body_label.add_theme_font_size_override("font_size", 20)
				section_body_label.add_theme_color_override("font_color", Color(0.82, 0.92, 1.0))
				section_content_panel.add_child(section_body_label)
				# Market artık ana oyun sahnesine ayrı overlay olarak EKLENMEZ.
				# Doğrudan menünün section_screen alanında çalışır.
				market_host = Control.new()
				market_host.position = Vector2(0, 58)
				market_host.size = Vector2(1168, 528)
				market_host.mouse_filter = Control.MOUSE_FILTER_STOP
				market_host.visible = false
				root.add_child(market_host)
				return rootnfunc _build_unified_hangar() -> Control:
				var root := Control.new()
				root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				var back := Button.new()
				back.text = "← MEnÜ"
				back.position = Vector2(8, 0)
				back.size = Vector2(112, 38)
				novaGateUITheme.apply_button(back)
				back.pressed.co
nect(_show_main_menu)
				root.add_child(back)
				var ships_tab_button := Button.new()
				ships_tab_button.text = "GEMİLER"
				ships_tab_button.position = Vector2(140, 0)
				ships_tab_button.size = Vector2(120, 38)
				novaGateUITheme.apply_button(ships_tab_button)
				ships_tab_button.pressed.co
nect(_set_tab.bind("ships"))
				root.add_child(ships_tab_button)
				var ammo_tab_button := Button.new()
				ammo_tab_button.text = "CEPHANE"
				ammo_tab_button.position = Vector2(270, 0)
				ammo_tab_button.size = Vector2(120, 38)
				novaGateUITheme.apply_button(ammo_tab_button)
				ammo_tab_button.pressed.co
nect(_set_tab.bind("ammo"))
				root.add_child(ammo_tab_button)
				# CONFIG 1 / CONFIG 2 — segmented control görünümü.
				config_one_button = Button.new()
				config_one_button.text = "CONFIG 1"
				config_one_button.position = Vector2(410, 0)
				config_one_button.size = Vector2(88, 38)
				novaGateUITheme.apply_button(config_one_button)
				config_one_button.pressed.co
nect(_set_config.bind(1))
				root.add_child(config_one_button)
				config_two_button = Button.new()
				config_two_button.text = "CONFIG 2"
				config_two_button.position = Vector2(500, 0)
				config_two_button.size = Vector2(88, 38)
				novaGateUITheme.apply_button(config_two_button)
				config_two_button.pressed.co
nect(_set_config.bind(2))
				root.add_child(config_two_button)
				ship_tab_button = Button.new()
				ship_tab_button.text = "UZAY GEMİSİ"
				ship_tab_button.position = Vector2(608, 0)
				ship_tab_button.size = Vector2(150, 38)
				novaGateUITheme.apply_button(ship_tab_button)
				ship_tab_button.pressed.co
nect(_set_tab.bind("ship"))
				root.add_child(ship_tab_button)
				drone_tab_button = Button.new()
				drone_tab_button.text = "DROİDLER"
				drone_tab_button.position = Vector2(766, 0)
				drone_tab_button.size = Vector2(140, 38)
				novaGateUITheme.apply_button(drone_tab_button)
				drone_tab_button.pressed.co
nect(_set_tab.bind("drones"))
				root.add_child(drone_tab_button)
				selection_label = Label.new()
				selection_label.text = "Envanterden bir ekipman seç. Sonra uygun yuvaya tıkla. Sağ tık: çıkar."
				selection_label.position = Vector2(920, 5)
				selection_label.size = Vector2(240, 30)
				selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				selection_label.add_theme_font_size_override("font_size", 12)
				selection_label.add_theme_color_override("font_color", novaGateUITheme.DIM)
				root.add_child(selection_label)
				var left_panel := Panel.new()
				left_panel.position = Vector2(8, 50)
				left_panel.size = Vector2(230, 520)
				left_panel.add_theme_stylebox_override("panel", novaGateUITheme.panel())
				root.add_child(left_panel)
				var ship_title := Label.new()
				ship_title.text = "AKTİF GEMİ"
				ship_title.position = Vector2(15, 12)
				ship_title.size = Vector2(200, 30)
				ship_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				novaGateUITheme.title_label(ship_title, 19)
				left_panel.add_child(ship_title)
				var ship_image := TextureRect.new()
				ship_image.position = Vector2(22, 56)
				ship_image.size = Vector2(186, 215)
				ship_image.texture = load("res://assets/ship.svg")
				ship_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				ship_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				left_panel.add_child(ship_image)
				active_ship_image = ship_image
				stats_label = Label.new()
				stats_label.position = Vector2(18, 300)
				stats_label.size = Vector2(195, 190)
				stats_label.add_theme_font_size_override("font_size", 14)
				stats_label.add_theme_color_override("font_color", Color(0.82, 0.92, 1.0))
				left_panel.add_child(stats_label)
				var center_panel := Panel.new()
				center_panel.position = Vector2(248, 50)
				center_panel.size = Vector2(606, 520)
				center_panel.add_theme_stylebox_override("panel", novaGateUITheme.panel())
				root.add_child(center_panel)
				var center_scroll := ScrollContainer.new()
				center_scroll.position = Vector2(8, 8)
				center_scroll.size = Vector2(590, 504)
				center_panel.add_child(center_scroll)
				center_host = VBoxContainer.new()
				center_host.custom_minimum_size = Vector2(565, 490)
				center_host.add_theme_constant_override("separation", 10)
				center_scroll.add_child(center_host)
				var inventory_panel := Panel.new()
				inventory_panel.position = Vector2(864, 50)
				inventory_panel.size = Vector2(296, 520)
				inventory_panel.add_theme_stylebox_override("panel", novaGateUITheme.panel())
				root.add_child(inventory_panel)
				var inventory_title := Label.new()
				inventory_title.text = "ENVANTER"
				inventory_title.position = Vector2(12, 10)
				inventory_title.size = Vector2(272, 34)
				inventory_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				novaGateUITheme.title_label(inventory_title, 20)
				inventory_panel.add_child(inventory_title)
				var inventory_scroll := ScrollContainer.new()
				inventory_scroll.position = Vector2(10, 50)
				inventory_scroll.size = Vector2(276, 455)
				inventory_panel.add_child(inventory_scroll)
				inventory_grid = GridContainer.new()
				inventory_grid.columns = 3
				inventory_grid.custom_minimum_size = Vector2(255, 440)
				inventory_grid.add_theme_constant_override("h_separation", 5)
				inventory_grid.add_theme_constant_override("v_separation", 5)
				inventory_scroll.add_child(inventory_grid)
				_refresh_all()
				return rootnfunc _refresh_all() -> void:
				refresh_info()
				_refresh_tabs()
				_refresh_center()
				_refresh_inventory()
				_refresh_stats()nfunc _refresh_tabs() -> void:
				if config_one_button == null:
								retur

				config_one_button.disabled = selected_config == 1
				config_two_button.disabled = selected_config == 2
				ship_tab_button.disabled = selected_tab == "ship"
				drone_tab_button.disabled = selected_tab == "drones"nfunc _refresh_center() -> void:
				if center_host == null:
								retur

				_clear_children(center_host)
				GlobalState.load_game()
				if selected_tab == "ship":
								_build_ship_slots(center_host)
				elif selected_tab == "ships":
								_build_owned_ships(center_host)
				elif selected_tab == "ammo":
								_build_ammo(center_host)
				elif selected_tab == "drones":
								_build_drone_slots(center_host)
				else:
								_build_ship_slots(center_host)nfunc _build_owned_ships(parent: VBoxContainer) -> void:
				parent.add_child(_section_title("SAHİP OLUNAn GEMİLER • AKTİF: %s" % active_ship_id))
				if owned_ships.is_empty():
								var empty := Label.new()
								empty.text = "Henüz sahip olunan gemi yok."
								parent.add_child(empty)
								retur

				for ship_id_value in owned_ships:
								var ship_id := str(ship_id_value)
								var data := _get_ship_data(ship_id)
								if data.is_empty():
												continue
								var panel := PanelContainer.new()
								panel.custom_minimum_size = Vector2(540, 150)
								panel.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.08, 0.96), Color(0.08, 0.38, 0.52), 1))
								var row := HBoxContainer.new()
								row.add_theme_constant_override("separation", 12)
								panel.add_child(row)
								var image := TextureRect.new()
								image.custom_minimum_size = Vector2(130, 125)
								var preview := str(data.get("preview", ""))
								if preview != "" and ResourceLoader.exists(preview):
												image.texture = load(preview)
								image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
								image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
								row.add_child(image)
								var text_box := VBoxContainer.new()
								text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
								row.add_child(text_box)
								var label := Label.new()
								var hp_value := int(data.get("hp", 0))
								var hp_text := _format_number(hp_value) if hp_value > 0 else "BELİRLENMEDİ"
								label.text = "%sn%sNCAn: %s • HIZ: %dNLAZER: %d • JENERATÖR: %d • EKSTRA: %d" % [
												str(data.get("name", ship_id)),
												ship_id,
												hp_text,
												int(data.get("speed", 0)),
												int(data.get("laser_slots", 0)),
												int(data.get("generator_slots", 0)),
												int(data.get("extra_slots", 0))
								]
								text_box.add_child(label)
								var use_button := Button.new()
								var is_active := active_ship_id == ship_id
								var can_activate := hp_value > 0
								use_button.text = "AKTİF GEMİ" if is_active else ("KULLAn" if can_activate else "CAn DEĞERİ EKSİK")
								use_button.disabled = is_active or not can_activate
								use_button.pressed.co
nect(_activate_owned_ship.bind(ship_id))
								text_box.add_child(use_button)
								var currency := str(data.get("currency", "FREE"))
								if ship_id != "Ship10" and currency == "BTC":
												var sell_button := Button.new()
												var refund := int(data.get("price", 0)) / 2
												sell_button.text = "SAT • %s BTC" % _format_number(refund)
												sell_button.pressed.co
nect(_sell_owned_ship.bind(ship_id, refund))
												text_box.add_child(sell_button)
								elif ship_id != "Ship10" and currency == "PLT":
												var sale_info := Label.new()
												sale_info.text = "PLT gemisi satış BTC değeri henüz belirlenmedi."
												sale_info.add_theme_color_override("font_color", Color(0.72, 0.82, 0.9))
												text_box.add_child(sale_info)
								parent.add_child(panel)nfunc _activate_owned_ship(ship_id:String) -> void:
				var account_manager = load("res://scripts/account_manager.gd").new()
				var result:Dictionary = account_manager.set_active_ship(ship_id)
				if not bool(result.get("ok", false)):
								selection_label.text = str(result.get("message", "Gemi değiştirilemedi."))
								retur

				# Eski geminin loadout'unu kendi anahtarında bırak.
				if active_ship_id != "":
					ship_configurations[active_ship_id] = configurations
				active_ship_id = ship_id
				active_ship_data = _get_ship_data(ship_id)
				if GlobalState.server_session_active:
					GlobalState.active_ship_id = ship_id
				# İlk kez alınan / açılan gemi her iki konfigürasyonda da BOŞ gelir.
				_ensure_ship_configuration(active_ship_id)
				configurations = ship_configurations[active_ship_id]
				_trim_equipment_to_ship_limits()
				_save_configurations()
				if player != null and player.has_method("reload_active_ship_from_save"):
								player.call("reload_active_ship_from_save")
				selection_label.text = str(result.get("message", "Aktif gemi değişti."))
				_refresh_all()nfunc _sell_owned_ship(ship_id:String, refund_btc:int) -> void:
				var account_manager = load("res://scripts/account_manager.gd").new()
				var result:Dictionary = account_manager.sell_ship(ship_id, refund_btc)
				if not bool(result.get("ok", false)):
								selection_label.text = str(result.get("message", "Gemi satılamadı."))
								retur

				GlobalState.bitcoin = int(result.get("bitcoin", GlobalState.bitcoin))
				GlobalState.save_game()
				reload_owned_items_from_save()
				if player != null and player.has_method("reload_active_ship_from_save"):
								player.call("reload_active_ship_from_save")
				selection_label.text = str(result.get("message", "Gemi satıldı."))nfunc _trim_equipment_to_ship_limits() -> void:
				var laser_limit := _ship_slot_limit("laser")
				var generator_limit := _ship_slot_limit("generator")
				var extra_limit := _ship_slot_limit("extra")
				for config_key in configurations.keys():
								var config:Dictionary = configurations[config_key]
								var lasers:Array = config["lasers"]
								var generators:Array = config["generators"]
								var extras:Array = config["extras"]
								for i in range(laser_limit, lasers.size()):
												lasers[i] = null
								for i in range(generator_limit, generators.size()):
												generators[i] = null
								for i in range(extra_limit, extras.size()):
												extras[i] = nullnfunc _build_ammo(parent: VBoxContainer) -> void:
				parent.add_child(_section_title("CEPHANE"))
				var ammo_list := [
								["X1", "X1 Lazer"],
								["X2", "X2 Lazer"],
								["X3", "X3 Lazer"],
								["X4", "X4 Lazer"],
								["SAB", "SAB"],
								["RSB", "RSB"],
								["R1", "R1 Roket"],
								["R2", "R2 Roket"],
								["R3", "R3 Roket"]
				]
				for ammo_data in ammo_list:
								var ammo_key := str(ammo_data[0])
								var ammo_title := str(ammo_data[1])
								var label := Label.new()
								label.text = "%s : %s" % [ammo_title, _format_number(GlobalState.get_ammo_count(ammo_key))]
								label.custom_minimum_size = Vector2(520, 35)
								parent.add_child(label)nfunc _build_ship_slots(parent: VBoxContainer) -> void:
				var laser_limit := _ship_slot_limit("laser")
				var generator_limit := _ship_slot_limit("generator")
				var extra_limit := _ship_slot_limit("extra")
				var config: Dictionary = configurations[selected_config]
				parent.add_child(_section_title("LAZER • %d YUVA" % laser_limit))
				var laser_grid := _new_slot_grid(10)
				parent.add_child(laser_grid)
				var lasers: Array = config["lasers"]
				for index in range(laser_limit):
								laser_grid.add_child(_equipment_slot("laser", index, lasers[index], "lasers"))
				parent.add_child(_section_title("JENERATÖR • %d YUVA" % generator_limit))
				var generator_grid := _new_slot_grid(10)
				parent.add_child(generator_grid)
				var generators: Array = config["generators"]
				for index in range(generator_limit):
								generator_grid.add_child(_equipment_slot("generator", index, generators[index], "generators"))
				parent.add_child(_section_title("EKSTRALAR • %d YUVA" % extra_limit))
				var extra_grid := _new_slot_grid(8)
				parent.add_child(extra_grid)
				var extras: Array = config["extras"]
				for index in range(extra_limit):
								extra_grid.add_child(_equipment_slot("extra", index, extras[index], "extras"))nfunc _build_drone_slots(parent: VBoxContainer) -> void:
				var owned_count := owned_droid_types.size()
				parent.add_child(_section_title("%d / 8 DROİD • PLUS 1 YUVA • ZEUS 2 YUVA" % owned_count))
				if owned_count <= 0:
								var empty_label := Label.new()
								empty_label.text = "Henüz droid satın alınmadı."
								empty_label.custom_minimum_size = Vector2(550, 70)
								empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
								empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
								empty_label.add_theme_color_override("font_color", Color(0.7, 0.82, 0.9))
								parent.add_child(empty_label)
								retur

				var grid := GridContainer.new()
				grid.columns = 2
				grid.add_theme_constant_override("h_separation", 10)
				grid.add_theme_constant_override("v_separation", 10)
				parent.add_child(grid)
				var config: Dictionary = configurations[selected_config]
				var drone_slots: Array = config["drones"]
				for drone_index in range(owned_count):
								var droid_type := str(owned_droid_types[drone_index])
								var slot_count := 1 if droid_type == "PLUS" else 2
								var card := Panel.new()
								# Satış butonu ekipman yuvalarından ayrı, kartın en altında görünür.
								card.custom_minimum_size = Vector2(270, 155)
								card.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.08, 0.96), Color(0.1, 0.42, 0.58), 1))
								grid.add_child(card)
								var icon := TextureRect.new()
								icon.position = Vector2(10, 15)
								icon.size = Vector2(75, 75)
								icon.texture = load("res://assets/drone.svg")
								icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
								icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
								card.add_child(icon)
								var label := Label.new()
								label.text = "DROİD %d • %s • %d YUVA" % [drone_index + 1, droid_type, slot_count]
								label.position = Vector2(95, 10)
								label.size = Vector2(165, 30)
								label.add_theme_color_override("font_color", Color(0.45, 0.92, 1.0))
								card.add_child(label)
								var sell_button := Button.new()
								var same_type_count := owned_droid_types.count(droid_type)
								var refund_info := _get_droid_sell_refund(droid_type, same_type_count)
								sell_button.text = "SAT  •  %s %s" % [
												_format_number(int(refund_info.get("refund", 0))),
												str(refund_info.get("currency", ""))
								]
								# Ayrı ve net görünen gerçek SAT butonu.
								sell_button.position = Vector2(10, 112)
								sell_button.size = Vector2(250, 34)
								sell_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
								sell_button.add_theme_font_size_override("font_size", 15)
								sell_button.add_theme_color_override("font_color", Color(1.0, 0.92, 0.86))
								sell_button.add_theme_color_override("font_hover_color", Color.WHITE)
								sell_button.add_theme_stylebox_override(
												"normal",
												_panel_style(Color(0.20, 0.055, 0.04, 0.98), Color(0.92, 0.28, 0.18, 1.0), 2)
								)
								sell_button.add_theme_stylebox_override(
												"hover",
												_panel_style(Color(0.30, 0.075, 0.05, 1.0), Color(1.0, 0.45, 0.25, 1.0), 2)
								)
								sell_button.add_theme_stylebox_override(
												"pressed",
												_panel_style(Color(0.13, 0.035, 0.025, 1.0), Color(1.0, 0.65, 0.35, 1.0), 2)
								)
								sell_button.pressed.co
nect(_sell_droid.bind(drone_index))
								card.add_child(sell_button)
								for slot_offset in range(slot_count):
												var absolute_index := drone_index * DRONE_SLOTS_PER_DRONE + slot_offset
												var slot := _equipment_slot("drone", absolute_index, drone_slots[absolute_index], "drones")
												slot.position = Vector2(95 + slot_offset * 70, 48)
												card.add_child(slot)nfunc _get_droid_sell_refund(droid_type:String, same_type_count:int) -> Dictionary:
				var plus_prices := [100000, 200000, 400000, 800000, 1600000, 3200000, 6400000, 12800000]
				var zeus_prices := [12000, 20000, 35000, 60000, 100000, 170000, 300000, 500000]
				var prices:Array = plus_prices if droid_type == "PLUS" else zeus_prices
				var currency := "BTC" if droid_type == "PLUS" else "PLT"
				var price_index := clampi(maxi(same_type_count, 1) - 1, 0, prices.size() - 1)
				return {
								"refund": int(prices[price_index]) / 2,
								"currency": currency
				}nfunc _sell_droid(droid_index:int) -> void:
				if droid_sell_in_progress:
								retur

				droid_sell_in_progress = true
				# HTTPRequest kullanan AccountManager sahne ağacında olmalı.
				var account_manager = load("res://scripts/account_manager.gd").new()
				get_tree().root.add_child(account_manager)
				selection_label.text = "Droid satılıyor..."
				var result:Dictionary = await account_manager.sell_droid(droid_index)
				account_manager.queue_free()
				if not bool(result.get("ok", false)):
								selection_label.text = str(result.get("message", "Droid satılamadı."))
								droid_sell_in_progress = false
								retur

				# Satılan droidin iki olası ekipman yuvasını boşalt.
				for config_key in configurations.keys():
								var config:Dictionary = configurations[config_key]
								var slots:Array = config["drones"]
								var base_index := droid_index * DRONE_SLOTS_PER_DRONE
								if base_index < slots.size():
												slots[base_index] = null
								if base_index + 1 < slots.size():
												slots[base_index + 1] = null
				_save_configurations()
				reload_owned_items_from_save()
				var droid_root := get_tree().current_scene.find_child("Drones", true, false)
				if droid_root != null and droid_root.has_method("refresh_from_save"):
								droid_root.call_deferred("refresh_from_save")
				selection_label.text = str(result.get("message", "Droid satıldı."))
				droid_sell_in_progress = false
				_refresh_all()nfunc _refresh_inventory() -> void:
				if inventory_grid == null:
								retur

				_clear_children(inventory_grid)
				for item_name in ITEM_DATA.keys():
								if int(inventory.get(item_name, 0)) > 0:
												inventory_grid.add_child(_inventory_button(str(item_name)))nfunc _inventory_button(item_name: String) -> Button:
				var data: Dictionary = ITEM_DATA[item_name]
				var button := Button.new()
				button.custom_minimum_size = Vector2(80, 94)
				button.icon = load(str(data["icon"]))
				button.expand_icon = true
				button.text = "%snx%d" % [str(data["title"]), _available_count(item_name)]
				button.tooltip_text = _item_tooltip(item_name)
				button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
				button.disabled = _available_count(item_name) <= 0
				button.add_theme_font_size_override("font_size", 12)
				if selected_item == item_name:
								button.add_theme_stylebox_override("normal", _panel_style(Color(0.07, 0.18, 0.22, 1.0), Color(0.35, 0.95, 1.0), 2))
				else:
								button.add_theme_stylebox_override("normal", _panel_style(Color(0.025, 0.055, 0.08, 0.96), Color(0.08, 0.35, 0.48), 1))
				button.pressed.co
nect(_select_item.bind(item_name))
				return butto
nfunc _equipment_slot(accepted_type: String, index: int, item_value: Variant, array_key: String) -> Button:
				var button := Button.new()
				button.custom_minimum_size = Vector2(50, 50)
				button.tooltip_text = "Boş yuva"
				button.add_theme_stylebox_override("normal", _panel_style(Color(0.018, 0.035, 0.05, 0.98), _slot_color(accepted_type), 1))
				button.add_theme_stylebox_override("hover", _panel_style(Color(0.05, 0.13, 0.17, 1.0), Color(0.35, 0.95, 1.0), 2))
				if item_value != null and str(item_value) != "":
								var item_name := str(item_value)
								var data: Dictionary = ITEM_DATA[item_name]
								button.icon = load(str(data["icon"]))
								button.expand_icon = true
								button.tooltip_text = "%sNSağ tık: çıkar" % _item_tooltip(item_name)
				else:
								button.text = str(index + 1)
				button.pressed.co
nect(_equip_selected.bind(accepted_type, index, array_key))
				button.gui_input.co
nect(_slot_gui_input.bind(index, array_key))
				return butto
nfunc _equip_selected(accepted_type: String, index: int, array_key: String) -> void:
				var config: Dictionary = configurations[selected_config]
				var slots: Array = config[array_key]
				var current_item: Variant = slots[index]
				# Ekipman seçili değilse dolu yuvaya sol tıkla çıkar.
				if selected_item == "":
								if current_item != null and str(current_item) != "":
												_remove_item(index, array_key)
								retur

				var data: Dictionary = ITEM_DATA[selected_item]
				var item_type := str(data["type"])
				if accepted_type == "drone":
								if item_type != "laser" and item_type != "generator":
												selection_label.text = "Droid yuvasına sadece lazer veya jeneratör takılabilir."
												retur

				elif item_type != accepted_type:
								selection_label.text = "%s ekipmanı bu yuvaya takılamaz." % str(data["title"])
								retur

				if _available_count(selected_item) <= 0 and str(current_item) != selected_item:
								selection_label.text = "%s bu konfigürasyon için kalmadı." % str(data["title"])
								retur

				slots[index] = selected_item
				QuestSystem.record_event("equipment_equipped", {"slot_type": item_type, "item": selected_item, "amount": 1})
				_save_configurations()
				selection_label.text = "%s takıldı." % str(data["title"])
				selected_item = ""
				_refresh_all()nfunc _slot_gui_input(event: InputEvent, index: int, array_key: String) -> void:
				if event is InputEventMouseButton:
								var mouse_event := event as InputEventMouseButto

								if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTOn_RIGHT:
												_remove_item(index, array_key)nfunc _remove_item(index: int, array_key: String) -> void:
				var config: Dictionary = configurations[selected_config]
				var slots: Array = config[array_key]
				var item_value: Variant = slots[index]
				if item_value == null or str(item_value) == "":
								retur

				var item_name := str(item_value)
				slots[index] = null
				_save_configurations()
				selected_item = ""
				selection_label.text = "%s çıkarıldı." % str(ITEM_DATA[item_name]["title"])
				_refresh_all()nfunc _select_item(item_name: String) -> void:
				# Envanterde ekipmana sol tıklanınca ilk uygun boş yuvaya doğrudan takılır.
				# Böylece seçim yapıp ayrıca slota tıklamak gerekmez.
				selected_item = item_name
				if _auto_equip_selected(item_name):
								selection_label.text = "%s ilk uygun yuvaya takıldı." % str(ITEM_DATA[item_name]["title"])
								selected_item = ""
								_refresh_all()
				else:
								selection_label.text = "%s için boş ve uygun yuva yok." % str(ITEM_DATA[item_name]["title"])
								_refresh_inventory()nfunc _auto_equip_selected(item_name: String) -> bool:
				if _available_count(item_name) <= 0:
								return false
				var data: Dictionary = ITEM_DATA[item_name]
				var item_type := str(data["type"])
				var config: Dictionary = configurations[selected_config]
				var array_key := ""
				if selected_tab == "drones":
								if item_type != "laser" and item_type != "generator":
												return false
								array_key = "drones"
				elif item_type == "laser":
								array_key = "lasers"
				elif item_type == "generator":
								array_key = "generators"
				elif item_type == "extra":
								array_key = "extras"
				else:
								return false
				var slots: Array = config[array_key]
				var candidate_indices: Array = []
				if array_key == "drones":
								candidate_indices = _owned_droid_slot_indices()
				else:
								var limit := slots.size()
								if array_key == "lasers":
												limit = _ship_slot_limit("laser")
								elif array_key == "generators":
												limit = _ship_slot_limit("generator")
								elif array_key == "extras":
												limit = _ship_slot_limit("extra")
								for i in range(limit):
												candidate_indices.append(i)
				for index in candidate_indices:
								if index >= 0 and index < slots.size() and (slots[index] == null or str(slots[index]) == ""):
												slots[index] = item_name
												_save_configurations()
												return true
				return falsenfunc _set_config(config_number: int) -> void:
				selected_config = clampi(config_number, 1, 2)
				selected_item = ""
				if selection_label != null:
								selection_label.text = "Konfigürasyon %d aktif. C ile değiştir." % selected_config
				if player != null and player.has_method("set_active_config"):
								player.call("set_active_config", selected_config)
				_update_config_indicator()
				_refresh_all()nfunc _update_config_indicator() -> void:
				if config_indicator != null:
								config_indicator.text = "KONFİGÜRASYOn %d  •  C" % selected_confignfunc _count_item_in_active_config(item_name: String) -> int:
				var count := 0
				var config: Dictionary = configurations[selected_config]
				var limits := {
								"lasers": _ship_slot_limit("laser"),
								"generators": _ship_slot_limit("generator"),
								"extras": _ship_slot_limit("extra")
				}
				for key in ["lasers", "generators", "extras"]:
								var slots: Array = config[key]
								var limit:int = mini(int(limits[key]), slots.size())
								for i in range(limit):
												var value = slots[i]
												if value != null and str(value) == item_name:
																count += 1
				var drone_slots: Array = config["drones"]
				for index in _owned_droid_slot_indices():
								if index >= 0 and index < drone_slots.size():
												var value = drone_slots[index]
												if value != null and str(value) == item_name:
																count += 1
				return countnfunc _available_count(item_name: String) -> int:
				return maxi(int(inventory.get(item_name, 0)) - _count_item_in_active_config(item_name), 0)nfunc _set_tab(tab_name: String) -> void:
				selected_tab = tab_name
				selected_item = ""
				_refresh_all()nfunc _refresh_stats() -> void:
				if stats_label == null:
								retur

				var damage := 0
				var shield := 0
				var speed_bonus := 0
				var config: Dictionary = configurations[selected_config]
				var laser_limit := _ship_slot_limit("laser")
				var generator_limit := _ship_slot_limit("generator")
				var extra_limit := _ship_slot_limit("extra")
				var lasers:Array = config["lasers"]
				for i in range(mini(laser_limit, lasers.size())):
								var item_value = lasers[i]
								if item_value != null and str(item_value) != "":
												var data:Dictionary = ITEM_DATA[str(item_value)]
												damage += int(data.get("damage", 0))
				var generators:Array = config["generators"]
				for i in range(mini(generator_limit, generators.size())):
								var item_value = generators[i]
								if item_value != null and str(item_value) != "":
												var data:Dictionary = ITEM_DATA[str(item_value)]
												shield += int(data.get("shield", 0))
												speed_bonus += int(data.get("speed", 0))
				var drone_slots:Array = config["drones"]
				for index in _owned_droid_slot_indices():
								if index >= 0 and index < drone_slots.size():
												var item_value = drone_slots[index]
												if item_value != null and str(item_value) != "":
																var data:Dictionary = ITEM_DATA[str(item_value)]
																damage += int(data.get("damage", 0))
																shield += int(data.get("shield", 0))
																speed_bonus += int(data.get("speed", 0))
				if active_ship_data.is_empty():
								active_ship_data = _get_ship_data(active_ship_id)
				var base_hp := int(active_ship_data.get("hp", 8000))
				var base_speed_value := int(active_ship_data.get("speed", 320))
				var total_speed := base_speed_value + speed_bonus
				stats_label.text = "%sNKONFİGÜRASYOn: %dNCAn: %sNLAZER HASARI: %dNKALKAn: %dNHIZ: %dNDROİD: %d / 8NLAZER YUVASI: %dNJENERATÖR YUVASI: %dNEKSTRA YUVASI: %d" % [
								str(active_ship_data.get("name", active_ship_id)),
								selected_config,
								_format_number(base_hp),
								damage,
								shield,
								total_speed,
								owned_droid_types.size(),
								laser_limit,
								generator_limit,
								extra_limit
				]
				if active_ship_image != null:
								var preview := str(active_ship_data.get("preview", ""))
								active_ship_image.texture = load(preview) if preview != "" and ResourceLoader.exists(preview) else load("res://assets/ship.svg")
				if player != null and player.has_method("apply_equipment_stats"):
								player.call("apply_equipment_stats", damage, shield, speed_bonus)nfunc _section_title(text_value: String) -> Label:
				var label := Label.new()
				label.text = text_value
				label.custom_minimum_size = Vector2(550, 30)
				label.add_theme_font_size_override("font_size", 17)
				label.add_theme_color_override("font_color", Color(0.68, 0.9, 1.0))
				return labelnfunc _new_slot_grid(columns: int) -> GridContainer:
				var grid := GridContainer.new()
				grid.columns = columns
				grid.add_theme_constant_override("h_separation", 5)
				grid.add_theme_constant_override("v_separation", 5)
				return gridnfunc _slot_color(slot_type: String) -> Color:
				if slot_type == "laser":
								return Color(0.08, 0.55, 0.95)
				if slot_type == "generator":
								return Color(0.15, 0.8, 0.45)
				if slot_type == "extra":
								return Color(0.95, 0.55, 0.1)
				return Color(0.55, 0.35, 0.95)nfunc _item_tooltip(item_name: String) -> String:
				var data: Dictionary = ITEM_DATA[item_name]
				var text := str(data["title"])
				if data.has("damage"):
								text += "NHasar: %d" % int(data["damage"])
				if data.has("shield"):
								text += "NKalkan: +%d" % int(data["shield"])
				if data.has("speed"):
								text += "NHız: +%d" % int(data["speed"])
				return textnfunc _clear_children(node: node) -> void:
				for child in node.get_children():
								child.queue_free()nfunc _large_button(text_value: String) -> Button:
				var button := Button.new()
				button.text = text_value
				button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
				button.add_theme_font_size_override("font_size", 21)
				button.add_theme_stylebox_override("normal", _panel_style(Color(0.035, 0.08, 0.115, 0.98), Color(0.08, 0.48, 0.64, 0.95), 2))
				button.add_theme_stylebox_override("hover", _panel_style(Color(0.06, 0.16, 0.22, 1.0), Color(0.3, 0.95, 1.0), 2))
				return butto
nfunc _panel_style(fill: Color, border: Color, border_width: int) -> StyleBoxFlat:
				var style := StyleBoxFlat.new()
				style.bg_color = fill
				style.border_color = border
				style.set_border_width_all(border_width)
				style.corner_radius_top_left = 5
				style.corner_radius_top_right = 5
				style.corner_radius_bottom_left = 5
				style.corner_radius_bottom_right = 5
				style.content_margin_left = 7
				style.content_margin_right = 7
				style.content_margin_top = 5
				style.content_margin_bottom = 5
				return stylenfunc _show_main_menu() -> void:
				# PLT / Bitcoin / XP gibi canlı ekonomi değerlerini menü her
				# açıldığında yeniden çiz. Extra kullanımı GlobalState.platinum
				# değerini anında değiştirir; eski PilotInfo yazısı cache'de kalmasın.
				refresh_info()
				if market_host != null:
								market_host.visible = false
				if section_content_panel != null:
								section_content_panel.visible = true
				if main_menu != null:
								main_menu.visible = true
				if hangar_screen != null:
								hangar_screen.visible = false
				if section_screen != null:
								section_screen.visible = falsenfunc _show_hangar() -> void:
				main_menu.visible = false
				hangar_screen.visible = true
				if section_screen != null:
								section_screen.visible = false
				_refresh_all()nfunc _rank_icon_texture(rank_id: String) -> Texture2D:
	# Badge bileseni tek kaynaktir (atlas + dikdortgen eslemesi).
	return RankBadge.texture_for(rank_id)nfunc _section_request_is_current(request_generation: int, expected_section: String) -> bool:
	return (
		request_generation == _menu_section_generatio

		and _active_menu_section == expected_sectio

		and section_screen != null
		and section_screen.visible
	)nfunc _rank_number(value) -> String:
	var n := int(value)
	var source := str(abs(n))
	var formatted := ""
	var count := 0
	for i in range(source.length() - 1, -1, -1):
		formatted = source[i] + formatted
		count += 1
		if count % 3 == 0 and i > 0:
			formatted = "." + formatted
	return ("-" if n < 0 else "") + formattednfunc _rank_add_text(parent: Control, text_value: String, pos: Vector2, size_value: Vector2, font_size: int = 15, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.name = "RankV1Text"
	label.set_meta("novagate_section_dynamic", true)
	label.text = text_value
	label.position = pos
	label.size = size_value
	label.horizontal_alignment = alig

	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.84, 0.93, 1.0))
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	parent.add_child(label)
	return labelnfunc _rank_add_icon(parent: Control, rank_id: String, pos: Vector2, size_value: Vector2) -> TextureRect:
	var icon := TextureRect.new()
	icon.name = "RankV1Icon"
	icon.set_meta("novagate_section_dynamic", true)
	icon.texture = _rank_icon_texture(rank_id)
	icon.position = pos
	icon.size = size_value
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(icon)
	return ico
nfunc _show_ranking_statistics(request_generation: int = -1) -> void:
	if request_generation < 0:
		request_generation = _menu_section_generatio

	if not _section_request_is_current(request_generation, "İSTATİSTİKLER"):
		retur

	section_body_label.visible = false
	# Admin icin A rutbesi yonetim bolumu de cizilir; panel o kadar uzar.
	_rank_apply_panel_height(GlobalState.is_admin)
	# Klan ekranından gelindiyse ClaNV1 node'larını da aynı anda kaldır.
	_clear_section_dynamic_now()
	var ranking: Dictionary = await GlobalState.refresh_ranking()
	if not _section_request_is_current(request_generation, "İSTATİSTİKLER"):
		retur

	if ranking.is_empty():
		section_body_label.visible = true
		section_body_label.position = Vector2(30, 30)
		section_body_label.text = "İSTATİSTİK / SIRALAMANRütbe bilgileri sunucudan alınamadı."
		retur

	var leaderboard: Array = await GlobalState.get_rank_leaderboard(10, true)
	if not _section_request_is_current(request_generation, "İSTATİSTİKLER"):
		retur

	# SOL PANEL: Şirket içindeki güncel ilk 10.
	_rank_add_text(section_content_panel, "ŞİRKET RÜTBE SIRALAMASI • İLK 10", Vector2(20, 14), Vector2(350, 34), 17)
	_rank_add_text(section_content_panel, "Rütbe     Pilot                         Puan", Vector2(20, 50), Vector2(350, 26), 13)
	var row_y := 80.0
	for i in range(10):
		if i >= leaderboard.size():
			_rank_add_text(section_content_panel, "%d.  ---" % (i + 1), Vector2(20, row_y), Vector2(350, 31), 14)
			row_y += 34.0
			continue
		var row = leaderboard[i]
		if not (row is Dictionary):
			continue
		var rank_id := str(row.get("rank_key", "private"))
		_rank_add_icon(section_content_panel, rank_id, Vector2(22, row_y + 5), Vector2(22, 22))
		_rank_add_text(section_content_panel, "%d." % (i + 1), Vector2(48, row_y), Vector2(30, 31), 14)
		_rank_add_text(section_content_panel, str(row.get("nickname", row.get("username", "Oyuncu"))), Vector2(78, row_y), Vector2(180, 31), 14)
		_rank_add_text(section_content_panel, _rank_number(round(float(row.get("rank_points", 0.0)))), Vector2(260, row_y), Vector2(100, 31), 14, HORIZONTAL_ALIGNMENT_RIGHT)
		row_y += 34.0
	# SAĞ PANEL: Gönderdiğin DarkOrbit örneğindeki hesap dökümü.
	var right_x := 390.0
	# "A" rutbesi ekranda A ikonu ve "A Rutbesi" etiketiyle gorunur;
	# siralama hesabi normal rutbeyle devam eder (display_* yalnizca gorunum).
	_rank_add_icon(section_content_panel, GlobalState.display_rank_key(), Vector2(right_x, 10), Vector2(38, 38))
	_rank_add_text(section_content_panel, "Bugünkü %s rütbenin hesaplaması böyle oldu:" % GlobalState.display_rank_title(), Vector2(right_x + 46, 10), Vector2(510, 32), 15)
	_rank_add_text(section_content_panel, "Kazanılan rütbe puanı:", Vector2(right_x, 54), Vector2(260, 34), 16)
	_rank_add_text(section_content_panel, _rank_number(round(GlobalState.rank_points)), Vector2(right_x + 270, 54), Vector2(170, 34), 18, HORIZONTAL_ALIGNMENT_CENTER)
	# Gemi turu degerleri tek kaynaktan (RankData.SHIP_RANK_VALUES) gelir.
	var ship_rank_value := maxi(RankData.ship_rank_value(GlobalState.ship_name), 1)
	var rows: Array = [
		["+", "Tecrübe Puanı", int(ranking.get("exp", GlobalState.xp)), "/ 100.000"],
		["+", "Şeref Puanları", int(ranking.get("honor", GlobalState.honor)), "/ 100"],
		["+", "Oyuncu İmha Puanları", int(ranking.get("player_kills", GlobalState.player_kills)), "x 3"],
		["+", "Seviyen", GlobalState.level, "x 100"],
		["+", "Kayıttan beri gün sayısı", int(ranking.get("days_registered", 0)), "x 6"],
		["+", "Geminin türü", ship_rank_value, "x 1.000"],
		["+", "NPC İmha Puanları", int(ranking.get("npc_kills", GlobalState.npc_kills)), "/ 2"],
		["+", "Tamamlanan görevler", int(ranking.get("missions_completed", GlobalState.missions_completed)), "x 100"],
		["-", "Dost oyuncu imha", int(ranking.get("friendly_kills", GlobalState.friendly_kills)), "x 100"],
		["-", "Ölümler", int(ranking.get("deaths", GlobalState.player_deaths)), "x 4"]
	]
	var ry := 98.0
	for detail in rows:
		var sign_text := str(detail[0])
		var sign_color := Color(0.35, 0.95, 1.0) if sign_text == "+" else Color(1.0, 0.35, 0.35)
		var sign := _rank_add_text(section_content_panel, sign_text, Vector2(right_x, ry), Vector2(25, 28), 15, HORIZONTAL_ALIGNMENT_CENTER)
		sign.add_theme_color_override("font_color", sign_color)
		_rank_add_text(section_content_panel, str(detail[1]), Vector2(right_x + 28, ry), Vector2(245, 28), 14)
		_rank_add_text(section_content_panel, _rank_number(detail[2]), Vector2(right_x + 277, ry), Vector2(125, 28), 14, HORIZONTAL_ALIGNMENT_RIGHT)
		_rank_add_text(section_content_panel, str(detail[3]), Vector2(right_x + 414, ry), Vector2(95, 28), 14)
		ry += 30.0
	_rank_add_text(section_content_panel, "Toplam rütbe puanı", Vector2(right_x, ry + 4), Vector2(265, 32), 15)
	_rank_add_text(section_content_panel, _rank_number(round(GlobalState.rank_points)), Vector2(right_x + 277, ry + 4), Vector2(125, 32), 16, HORIZONTAL_ALIGNMENT_RIGHT)
	_rank_add_text(section_content_panel, "Şirket sırası: %d / %d     Genel sıra: %d / %d" % [GlobalState.company_rank_position, GlobalState.rank_company_count, GlobalState.global_rank_position, GlobalState.rank_global_count], Vector2(right_x, ry + 42), Vector2(520, 30), 13)
	# A rutbesi yalnizca admin hesaplara verilebilir; panel de yalnizca
	# admin oturumunda cizilir. Yetki kontrolu ayrica hesap katmaninda
	# (AccountManager.set_player_a_rank) tekrar dogrulanir.
	if GlobalState.is_admin:
		_rank_add_a_rank_admin_block(request_generation)nfunc _rank_apply_panel_height(admin_view: bool) -> void:
	# Rutbe ekrani ayni anda iki panel + (admin ise) A rutbesi panelini gosterir.
	if section_content_panel == null:
		retur

	section_content_panel.size = Vector2(908, 620) if admin_view else Vector2(908, 430)nfunc _rank_add_a_rank_admin_block(request_generation: int) -> void:
	if not _section_request_is_current(request_generation, "İSTATİSTİKLER"):
		retur

	if not GlobalState.is_admin:
		retur

	var account_manager = load("res://scripts/account_manager.gd").new()
	var records: Array = account_manager.get_all_player_records()
	account_manager.queue_free()
	var top := 486.0
	_rank_add_text(section_content_panel, "A RÜTBESİ YÖNETİMİ • ADMİn", Vector2(20, top), Vector2(430, 30), 17)
	_rank_add_text(
		section_content_panel,
		"A rütbesi kontenjan ve sıralama dışıdır; savaş statlarına %sx çarpan uygular." % str(RankData.RANK_A_STAT_MULTIPLIER),
		Vector2(20, top + 28), Vector2(620, 24), 13
	)
	if not _a_rank_status_message.is_empty():
		var status := _rank_add_text(section_content_panel, _a_rank_status_message, Vector2(470, top), Vector2(420, 30), 13, HORIZONTAL_ALIGNMENT_RIGHT)
		status.add_theme_color_override("font_color", Color(0.45, 0.95, 0.65))
	_rank_add_text(section_content_panel, "Rütbe   Pilot                          Durum", Vector2(20, top + 54), Vector2(430, 24), 13)
	var sorted_records: Array = _rank_a_rank_sorted(records)
	var shown := 0
	var row_y := top + 82.0
	for record in sorted_records:
		if shown >= A_RANK_ADMIn_ROWS:
			break
		var username := str(record.get("username", ""))
		if username.is_empty():
			continue
		var active := bool(record.get("a_rank", false))
		_rank_add_icon(section_content_panel, _rank_a_rank_icon_key(record, active), Vector2(22, row_y + 3), Vector2(22, 22))
		_rank_add_text(section_content_panel, str(shown + 1) + ".", Vector2(48, row_y), Vector2(28, 28), 14)
		_rank_add_text(section_content_panel, username, Vector2(80, row_y), Vector2(190, 28), 14)
		# enable = tiklandiginda uygulanacak yeni durum.
		_rank_add_a_rank_button(section_content_panel, username, not active, Vector2(280, row_y))
		var state_text := "A AKTİF • 2x stat" if active else "normal rütbe"
		var state_label := _rank_add_text(section_content_panel, state_text, Vector2(430, row_y), Vector2(210, 28), 13)
		state_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4) if active else Color(0.7, 0.82, 0.9))
		row_y += 30.0
		shown += 1
	if shown == 0:
		_rank_add_text(section_content_panel, "Hesap kaydı bulunamadı.", Vector2(80, row_y), Vector2(400, 28), 13)
		retur

	if sorted_records.size() > shown:
		_rank_add_text(
			section_content_panel,
			"… ve %d oyuncu daha (yetki veritabanından yönetilir)" % (sorted_records.size() - shown),
			Vector2(80, row_y + 2), Vector2(500, 26), 12
		)nfunc _rank_a_rank_sorted(records: Array) -> Array:
	# A rutbeli oyuncular listenin basinda, kalanlar ada gore siralanir.
	var flagged: Array = []
	var normal: Array = []
	for record in records:
		if not (record is Dictionary):
			continue
		if bool(record.get("a_rank", false)):
			flagged.append(record)
		else:
			normal.append(record)
	var by_name := func(a, b) -> bool: return str(a.get("username", "")) < str(b.get("username", ""))
	flagged.sort_custom(by_name)
	normal.sort_custom(by_name)
	return flagged + normalnfunc _rank_a_rank_icon_key(record: Dictionary, active: bool) -> String:
	# A rutbesi kendi ikonunu kullanir; digerleri puanlarindan hesaplanan rutbeyi.
	if active:
		return RankData.RANK_A_KEY
	return RankService.rank_key_for_points(RankService.points_for_record(record))nfunc _rank_add_a_rank_button(parent: Control, username: String, enable: bool, pos: Vector2) -> Button:
	var button := Button.new()
	button.name = "RankV1AdmiNButton"
	button.set_meta("novagate_section_dynamic", true)
	button.text = "A VER" if enable else "A AL"
	button.position = pos
	button.size = Vector2(140, 28)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_stylebox_override("normal", _panel_style(Color(0.035, 0.08, 0.115, 0.98), Color(0.08, 0.48, 0.64, 0.95), 1))
	button.add_theme_stylebox_override("hover", _panel_style(Color(0.06, 0.16, 0.22, 1.0), Color(0.3, 0.95, 1.0), 1))
	# enable = tiklandiginda uygulanacak YENI durum.
	button.pressed.co
nect(_rank_on_toggle_a_rank.bind(username, enable))
	parent.add_child(button)
	return butto
nfunc _rank_on_toggle_a_rank(username: String, enable: bool) -> void:
	# Yetki kontrolu hesap katmaninda tekrar yapilir; burada sonuc gosterilir.
	var account_manager = load("res://scripts/account_manager.gd").new()
	var result: Dictionary = account_manager.set_player_a_rank(username, enable)
	account_manager.queue_free()
	if bool(result.get("ok", false)):
		_a_rank_status_message = "%s → %s" % [username, "A RÜTBESİ AÇIK (2x stat)" if enable else "A rütbesi kapatıldı"]
	else:
		_a_rank_status_message = "Hata: " + str(result.get("message", "bilinmeyen"))
	# Panel yeniden cizilir: rozet, kontenjan ve siralama ayni anda guncellenir.
	_clear_section_dynamic_now()
	_show_ranking_statistics()nfunc _clan_clear_dynamic() -> void:
	section_body_label.visible = false
	_clear_section_dynamic_now()nfunc _clan_label(text_value: String, pos: Vector2, size_value: Vector2, font_size: int = 14) -> Label:
	var l := Label.new()
	l.name = "ClaNV1Label"
	l.set_meta("novagate_section_dynamic", true)
	l.text = text_value
	l.position = pos
	l.size = size_value
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", Color(0.86, 0.94, 1.0))
	section_content_panel.add_child(l)
	return lnfunc _clan_button(text_value: String, pos: Vector2, size_value: Vector2, callback: Callable) -> Button:
	var b := Button.new()
	b.name = "ClaNV1Button"
	b.set_meta("novagate_section_dynamic", true)
	b.text = text_value
	b.position = pos
	b.size = size_value
	b.pressed.co
nect(callback)
	section_content_panel.add_child(b)
	return bnfunc _show_clan_system(request_generation: int = -1) -> void:
	if request_generation < 0:
		request_generation = _menu_section_generatio

	if not _section_request_is_current(request_generation, "KLAn"):
		retur

	_clan_clear_dynamic()
	_clan_label("KLAn", Vector2(20, 10), Vector2(250, 34), 20)
	var data: Dictionary = await GlobalState.refresh_clan()
	if not _section_request_is_current(request_generation, "KLAn"):
		retur

	if GlobalState.clan_id <= 0:
		_clan_label("Henüz bir klana kayıtlı değilsin.", Vector2(20, 55), Vector2(500, 30), 15)
		var name_edit := LineEdit.new()
		name_edit.name = "ClaNV1name"
		name_edit.set_meta("novagate_section_dynamic", true)
		name_edit.placeholder_text = "Klan adı"
		name_edit.position = Vector2(20, 100)
		name_edit.size = Vector2(260, 36)
		section_content_panel.add_child(name_edit)
		var tag_edit := LineEdit.new()
		tag_edit.name = "ClaNV1Tag"
		tag_edit.set_meta("novagate_section_dynamic", true)
		tag_edit.placeholder_text = "TAG (2-5)"
		tag_edit.position = Vector2(290, 100)
		tag_edit.size = Vector2(130, 36)
		section_content_panel.add_child(tag_edit)
		var desc_edit := LineEdit.new()
		desc_edit.name = "ClaNV1Desc"
		desc_edit.set_meta("novagate_section_dynamic", true)
		desc_edit.placeholder_text = "Klan açıklaması"
		desc_edit.position = Vector2(20, 145)
		desc_edit.size = Vector2(400, 36)
		section_content_panel.add_child(desc_edit)
		_clan_button("KLAn KUR", Vector2(430, 100), Vector2(150, 81), func():
			var result: Dictionary = await GlobalState.create_clan(name_edit.text, tag_edit.text, desc_edit.text)
			if not _section_request_is_current(request_generation, "KLAn"):
				retur

			_clan_label(str(result.get("mesaj", "")), Vector2(20, 190), Vector2(560, 30), 13)
			if bool(result.get("basarili", false)):
				_show_clan_system(request_generation)
		)
		_clan_label("KLAn ARA / BAŞVUR", Vector2(20, 235), Vector2(300, 30), 16)
		var search_rows: Array = await GlobalState.search_clans("")
		if not _section_request_is_current(request_generation, "KLAn"):
			retur

		var y := 275.0
		for row in search_rows.slice(0, 8):
			if not (row is Dictionary):
				continue
			var cid := int(row.get("id", 0))
			var text := "[%s] %s  • %d üye" % [
				str(row.get("tag", "")),
				str(row.get("name", "")),
				int(row.get("member_count", 0))
			]
			_clan_label(text, Vector2(20, y), Vector2(450, 30), 14)
			_clan_button("BAŞVUR", Vector2(480, y), Vector2(120, 30), func():
				var result: Dictionary = await GlobalState.apply_clan(cid, "novaGate klan başvurusu")
				if not _section_request_is_current(request_generation, "KLAn"):
					retur

				_clan_label(str(result.get("mesaj", "")), Vector2(620, y), Vector2(260, 30), 12)
			)
			y += 36.0
		retur

	var clan_value = data.get("clan", {})
	if not (clan_value is Dictionary):
		retur

	var members_value = data.get("members", [])
	var apps_value = data.get("applications", [])
	var diplomacy_value = data.get("diplomacy", [])
	var messages_value = data.get("messages", [])
	_clan_label("[%s] %s" % [GlobalState.clan_tag, GlobalState.clan_name], Vector2(20, 48), Vector2(420, 34), 19)
	_clan_label("Klan rütben: %s" % GlobalState.clan_role, Vector2(20, 82), Vector2(300, 28), 14)
	_clan_label("Lider: %s" % str(clan_value.get("leader_username", "")), Vector2(20, 110), Vector2(300, 28), 14)
	_clan_label("Üye: %d" % int(clan_value.get("member_count", 0)), Vector2(20, 138), Vector2(200, 28), 14)
	_clan_label("Kasa: %s BTC" % _rank_number(int(clan_value.get("treasury_bitcoin", 0))), Vector2(220, 110), Vector2(260, 28), 14)
	_clan_label("Vergi: %.1f%%" % float(clan_value.get("tax_rate", 0.0)), Vector2(220, 138), Vector2(200, 28), 14)
	_clan_label("ÜYELER", Vector2(20, 180), Vector2(240, 28), 16)
	var y := 210.0
	if members_value is Array:
		for member in members_value.slice(0, 10):
			if member is Dictionary:
				var nick := str(member.get("nickname", member.get("username", "")))
				var role := str(member.get("role_name", "Üye"))
				var online := "Çevrimiçi" if float(member.get("last_seen", 0.0)) > Time.get_unix_time_from_system() - 10.0 else "Çevrimdışı"
				_clan_label("%s  • %s  • %s" % [nick, role, online], Vector2(20, y), Vector2(520, 26), 13)
				y += 27.0
	_clan_label("BAŞVURULAR", Vector2(570, 48), Vector2(240, 28), 16)
	var ay := 80.0
	if apps_value is Array:
		for app in apps_value.slice(0, 5):
			if app is Dictionary:
				var aid := int(app.get("id", 0))
				_clan_label(str(app.get("username", "")), Vector2(570, ay), Vector2(190, 28), 13)
				if bool(GlobalState.clan_permissions.get("applications", false)):
					_clan_button("KABUL", Vector2(760, ay), Vector2(78, 28), func():
						await GlobalState.decide_clan_application(aid, true)
						if _section_request_is_current(request_generation, "KLAn"):
							_show_clan_system(request_generation)
					)
					_clan_button("RED", Vector2(842, ay), Vector2(65, 28), func():
						await GlobalState.decide_clan_application(aid, false)
						if _section_request_is_current(request_generation, "KLAn"):
							_show_clan_system(request_generation)
					)
				ay += 32.0
	_clan_label("DİPLOMASİ", Vector2(570, 260), Vector2(240, 28), 16)
	var dy := 292.0
	if diplomacy_value is Array:
		for rel in diplomacy_value.slice(0, 5):
			if rel is Dictionary:
				_clan_label("%s [%s] • %s • %s" % [
					str(rel.get("target_name", "")),
					str(rel.get("target_tag", "")),
					str(rel.get("relation", "")),
					str(rel.get("status", ""))
				], Vector2(570, dy), Vector2(360, 26), 12)
				dy += 27.0
	if bool(GlobalState.clan_permissions.get("tax", false)):
		var tax_edit := LineEdit.new()
		tax_edit.name = "ClaNV1Tax"
		tax_edit.set_meta("novagate_section_dynamic", true)
		tax_edit.placeholder_text = "Vergi 0-5"
		tax_edit.position = Vector2(570, 440)
		tax_edit.size = Vector2(110, 34)
		section_content_panel.add_child(tax_edit)
		_clan_button("VERGİYİ AYARLA", Vector2(690, 440), Vector2(160, 34), func():
			await GlobalState.set_clan_tax(clampf(float(tax_edit.text), 0.0, 5.0))
			if _section_request_is_current(request_generation, "KLAn"):
				_show_clan_system(request_generation)
		)
	_clan_label("KLAn MESAJI", Vector2(20, 500), Vector2(200, 28), 16)
	var message_edit := LineEdit.new()
	message_edit.name = "ClaNV1Message"
	message_edit.set_meta("novagate_section_dynamic", true)
	message_edit.placeholder_text = "Klan mesajı..."
	message_edit.position = Vector2(20, 530)
	message_edit.size = Vector2(460, 34)
	section_content_panel.add_child(message_edit)
	_clan_button("GÖNDER", Vector2(490, 530), Vector2(110, 34), func():
		await GlobalState.send_clan_message(message_edit.text)
		if _section_request_is_current(request_generation, "KLAn"):
			_show_clan_system(request_generation)
	)
	if GlobalState.clan_role != "Lider":
		_clan_button("KLANDAn AYRIL", Vector2(790, 530), Vector2(140, 34), func():
			await GlobalState.leave_clan()
			if _section_request_is_current(request_generation, "KLAn"):
				_show_clan_system(request_generation)
		)nfunc _clear_section_dynamic_now() -> void:
	if section_content_panel == null:
		retur

	# Eski yetenek ağacını temizle
	for child in section_content_panel.get_children():
		if child.name == "SkillTreeRoot":
			child.queue_free()
	# queue_free() bir sonraki frame'i beklediği için Klan ve Rütbe node'ları
	# diğer sayfaya geçildiğinde bir frame daha ekranda kalıp üst üste biniyordu.
	# Burada sadece bizim dinamik RankV1 / ClaNV1 node'larımız anında silinir.
	for child in section_content_panel.get_children():
		if child == section_body_label:
			continue
		var node_name := str(child.name)
		if (
			bool(child.get_meta("novagate_section_dynamic", false))
			or node_name.begins_with("RankV1")
			or node_name.begins_with("ClaNV1")
			or node_name.begins_with("QuestSystem")
			or node_name == "SkillTreeContainer"
		):
			child.free()nfunc _show_section(section_name: String) -> void:
	print("AÇILAn MEnÜ:", section_name)
	# Her yeni menü tıklaması önceki Klan/İstatistik async isteklerini geçersiz kılar.
	_menu_section_generation += 1
	_active_menu_section = section_name.to_upper()
	var request_generation: int = _menu_section_generatio

	# Orijinal menü geçiş davranışını koru.
	if main_menu != null:
		main_menu.visible = false
	if hangar_screen != null:
		hangar_screen.visible = false
	if section_screen != null:
		section_screen.visible = true
	if market_host != null:
		market_host.visible = false
	if section_content_panel != null:
		section_content_panel.visible = true
	if section_title_label != null:
		section_title_label.visible = true
		section_title_label.text = section_name.to_upper()
	# Eski Klan / Rütbe dinamiklerini ANINDA temizle.
	_clear_section_dynamic_now()
	# Rutbe ekrani panel yuksekligini kendisi ayarlar; diger bolumler normal boyut.
	_rank_apply_panel_height(false)
	section_body_label.visible = true
	section_body_label.position = Vector2(30, 30)
	section_body_label.size = Vector2(900, 500)
	match section_name.to_upper():
		"YETENEK AĞACI":
			open_skill_tree()
		"EKİPMAn":
			section_body_label.text = "EKİPMA
NGemi, lazer, kalkan, jeneratör ve ekipman yönetimi burada gösterilecek."
		"MARKET":
			print("MARKET MEnÜ İÇİNDE AÇILIYOR")
			if section_title_label != null:
				section_title_label.visible = false
			if section_content_panel != null:
				section_content_panel.visible = false
			if market_host != null:
				market_host.visible = true
			if market_instance == null or not is_instance_valid(market_instance):
				var market_scene := preload("res://market/market.tscn")
				market_instance = market_scene.instantiate()
				if market_instance.has_method("set_embedded_mode"):
					market_instance.call("set_embedded_mode", true)
				market_host.add_child(market_instance)
		"GÖREVLER", "GÖREV":
			_show_quest_system()
		"KLAn":
			_active_menu_section = "KLAn"
			_clear_section_dynamic_now()
			section_body_label.visible = false
			_show_clan_system(request_generation)
		"İSTATİSTİKLER", "İSTATİSTİK / SIRALAMA":
			_active_menu_section = "İSTATİSTİKLER"
			_clear_section_dynamic_now()
			section_body_label.visible = false
			_show_ranking_statistics(request_generation)
		"HARİTA":
			section_body_label.text = "HARİTANHarita ve geçit bilgileri burada gösterilecek."
		"AYARLAR":
			section_body_label.text = "AYARLARNSes, görüntü, kontrol ve oyun seçenekleri burada gösterilecek."
		_:
			section_body_label.text = section_name + "NBu bölüm hazırlanıyor."nfunc open_skill_tree(refresh_from_server: bool = true) -> void:
	if section_content_panel == null:
		retur

	_clear_section_dynamic_now()
	section_body_label.visible = false
	var skill_container := PanelContainer.new()
	skill_container.name = "SkillTreeContainer"
	skill_container.custom_minimum_size = Vector2(900, 520)
	skill_container.add_theme_stylebox_override("panel", novaGateUITheme.panel())
	skill_container.add_theme_constant_override("panel_corner_radius", 8)
	section_content_panel.add_child(skill_container)
	var link := novaGateSkillLink.new()
	link.name = "SkillTreeLink"
	link.position = Vector2.ZERO
	link.size = skill_container.custom_minimum_size
	link.mouse_filter = Control.MOUSE_FILTER_IGNORE
	skill_container.add_child(link)
	var top_vbox := VBoxContainer.new()
	top_vbox.name = "SkillTreeTop"
	top_vbox.position = Vector2(24, 18)
	top_vbox.size = Vector2(860, 56)
	top_vbox.add_theme_constant_override("separation", 4)
	skill_container.add_child(top_vbox)
	var title := Label.new()
	title.text = "YETENEK AĞACI"
	novaGateUITheme.title_label(title, 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top_vbox.add_child(title)
	var used := 30 - int(GlobalState.skill_points)
	var info := Label.new()
	info.text = "LOG DISK: %s      PILOT PUANI: %s / 30      KULLANILAn: %s      KALAn: %s" % [
		_format_number(int(GlobalState.log_disks)),
		str(int(GlobalState.skill_points)),
		str(used),
		str(int(GlobalState.skill_points))
	]
	novaGateUITheme.dim_label(info, 14)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top_vbox.add_child(info)
	var skills: Array[Dictionary] = [
		{"id":"laser_power","name":"Lazer Gücü"},
		{"id":"npc_damage","name":"NPC Hasarı"},
		{"id":"critical_damage","name":"Kritik Hasar"},
		{"id":"shield_power","name":"Kalkan Gücü"},
		{"id":"hp_power","name":"HP Gücü"},
		{"id":"motor_power","name":"Motor Gücü"}
	]
	var node_panels: Array[PanelContainer] = []
	var node_centers: Array[Vector2] = []
	var node_colors: Array[Color] = []
	var row_y1 := 86.0
	var row_y2 := 236.0
	var start_x := 30.0
	var node_w := 270.0
	var node_h := 128.0
	var gap := 24.0
	for idx in range(skills.size()):
		var skill: Dictionary = skills[idx]
		var skill_id := str(skill["id"])
		var skill_name := str(skill["name"])
		var current_level := int(GlobalState.get_skill_level(skill_id))
		var maxed := current_level >= 5
		var disabled := false
		if not maxed and GlobalState.skill_points >= 30:
			disabled = true
		var icon_path: String = ""
		match skill_id:
			"laser_power":
				icon_path = "res://assets/equipment/laser3.png"
			"npc_damage":
				icon_path = "res://assets/equipment/missile1.png"
			"critical_damage":
				icon_path = "res://assets/equipment/laser2.png"
			"shield_power":
				icon_path = "res://assets/equipment/shield2.png"
			"hp_power":
				icon_path = "res://market/assets/boosters/HP-B01.png"
			"motor_power":
				icon_path = "res://assets/equipment/engine2.png"
		var icon_tex: Texture2D = null
		if icon_path != "":
			var loaded: Resource = load(icon_path)
			if loaded is Texture2D:
				icon_tex = loaded
		var row: int = 0 if idx < 3 else 1
		var col: int = idx % 3
		var nx: float = start_x + col * (node_w + gap)
		var ny: float = row_y1 if row == 0 else row_y2
		var node: PanelContainer = PanelContainer.new()
		node.name = "Skillnode_" + skill_id
		node.position = Vector2(nx, ny)
		node.size = Vector2(node_w, node_h)
		node.custom_minimum_size = Vector2(node_w, node_h)
		if maxed:
			node.add_theme_stylebox_override("panel", novaGateUITheme.skill_maxed())
		elif disabled:
			node.add_theme_stylebox_override("panel", novaGateUITheme.skill_available())
		else:
			node.add_theme_stylebox_override("panel", novaGateUITheme.skill_upgradeable())
		node.add_theme_constant_override("panel_corner_radius", 10)
		if not maxed and not disabled:
			node.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		node.anchor_preset = Control.PRESET_TOP_LEFT
		node.offset_left = nx
		node.offset_top = ny
		node.offset_right = nx + node_w
		node.offset_bottom = ny + node_h
		var i
ner := VBoxContainer.new()
		i
ner.name = "SkillnodeI
ner"
		i
ner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		i
ner.size_flags_vertical = Control.SIZE_EXPAND_FILL
		i
ner.add_theme_constant_override("separation", 2)
		node.add_child(i
ner)
		var icon_rect := TextureRect.new()
		icon_rect.name = "SkillIcon"
		icon_rect.size = Vector2(48, 48)
		icon_rect.custom_minimum_size = Vector2(48, 48)
		icon_rect.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		icon_rect.vertical_alignment = Control.VERTICAL_ALIGNMENT_CENTER
		if icon_tex != null:
			icon_rect.texture = icon_tex
		i
ner.add_child(icon_rect)
		var name_label := Label.new()
		name_label.text = skill_name
		novaGateUITheme.title_label(name_label, 14)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		i
ner.add_child(name_label)
		var level_label := Label.new()
		level_label.text = "Seviye: %d / 5" % current_level
		novaGateUITheme.dim_label(level_label, 12)
		level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		i
ner.add_child(level_label)
		var progress_hbox := HBoxContainer.new()
		progress_hbox.name = "SkillProgressRow"
		progress_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		progress_hbox.add_theme_constant_override("separation", 8)
		i
ner.add_child(progress_hbox)
		var pg_bar := ProgressBar.new()
		pg_bar.name = "SkillProgress"
		pg_bar.max_value = 5.0
		pg_bar.value = float(current_level)
		pg_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pg_bar.custom_minimum_size = Vector2(0, 6)
		pg_bar.add_theme_color_override("tint_progress_color", PRIMARY)
		pg_bar.add_theme_color_override("tint_background_color", Color(0.12, 0.14, 0.16))
		pg_bar.add_theme_constant_override("tick_count", 0)
		progress_hbox.add_child(pg_bar)
		var cap_label := Label.new()
		cap_label.text = "%d / 5" % current_level
		novaGateUITheme.dim_label(cap_label, 10)
		cap_label.custom_minimum_size = Vector2(30, 0)
		progress_hbox.add_child(cap_label)
		var action_hbox := HBoxContainer.new()
		action_hbox.name = "SkillActioNRow"
		action_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		action_hbox.add_theme_constant_override("separation", 4)
		i
ner.add_child(action_hbox)
		if maxed:
			var done := Label.new()
			done.text = "TAMAMLANDI"
			novaGateUITheme.title_label(done, 12, GREEn)
			done.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			action_hbox.add_child(done)
		elif disabled:
			var label := Label.new()
			label.text = "30 / 30 PP"
			novaGateUITheme.dim_label(label, 12)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			action_hbox.add_child(label)
		else:
			var btn := Button.new()
			btn.name = "SkillUpgradeButton"
			btn.text = "YÜKSELT"
			novaGateUITheme.apply_button(btn)
			btn.add_theme_font_size_override("font_size", 12)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.pressed.co
nect(_upgrade_skill.bind(skill_id))
			action_hbox.add_child(btn)
		skill_container.add_child(node)
		node_panels.append(node)
		node_centers.append(node.position + node.size / 2.0)
		if maxed:
			node_colors.append(Color(GREEn, 0.9))
		elif disabled:
			node_colors.append(Color(DIM, 0.6))
		else:
			node_colors.append(PRIMARY)
	if refresh_from_server:
		_refresh_skill_tree_background()nfunc _refresh_skill_tree_background() -> void:
	var ok := await GlobalState.refresh_skill_tree_from_server()
	if ok and is_instance_valid(section_content_panel):
		open_skill_tree(false)nfunc _upgrade_skill(skill_id: String) -> void:
	var result: Dictionary = await GlobalState.upgrade_skill_server(skill_id)
	if not bool(result.get("basarili", false)):
		print("YETENEK YÜKSELTME BAŞARISIZ: ", str(result.get("mesaj", "")))
		retur

	var live_player = get_tree().get_first_node_in_group("player")
	if live_player != null and live_player.has_method("refresh_persistent_bonuses"):
		live_player.call("refresh_persistent_bonuses")
	open_skill_tree(false)nfunc _quit_game() -> void:
	var main := get_node_or_null(main_path)
	if main != null:
		var player := main.get_node_or_null("PlayerShip")
		if player != null:
			var account_manager = load("res://scripts/account_manager.gd").new()
			account_manager.save_player_location(
				main.current_map_name,
				player.global_positio

			)
			print("KAYDEDILDI: ", main.current_map_name, " - ", player.global_position)
	get_tree().quit()nfunc _set_combat_hud_visible(state: bool) -> void:
	var main:=get_node_or_null(main_path)
	if main==null: retur

	var hud:=main.get_node_or_null("HUD")
	if hud==null: retur

	var mobile_platform:=OS.get_name()=="Android" or OS.get_name()=="iOS"
	var bottom:=hud.get_node_or_null("BottomPanel")
	if bottom!=null: bottom.visible=state
	var ammo:=hud.get_node_or_null("AmmoPanel")
	if ammo!=null: ammo.visible=state
	var laser_button:=hud.get_node_or_null("LaserToggleButton")
	if laser_button!=null: laser_button.visible=false if mobile_platform else state
	var extra_hud:=hud.get_node_or_null("ExtraHUD")
	if extra_hud!=null and mobile_platform: extra_hud.visible=false
	var combat:=main.find_child("CombatHUD",true,false)
	if combat is CanvasItem and mobile_platform: (combat as CanvasItem).visible=falsenfunc _open_menu() -> void:
				_set_combat_hud_visible(false)
				overlay.visible = true
				menu_button.visible = false
				# Ekstra kullandıktan sonra PLT değişimini oyun yenide

				# başlatılmadan anında menüye yansıt.
				refresh_info()
				_show_main_menu()
				get_tree().paused = truenfunc _close_all() -> void:
				_set_combat_hud_visible(true)
				get_tree().paused = false
				if market_host != null:
								market_host.visible = false
				if section_title_label != null:
								section_title_label.visible = true
				overlay.visible = false
				menu_button.visible = truenfunc _format_number(value:int) -> String:
				var n := int(value)
				var s := str(abs(n))
				var out := ""
				while s.length() > 3:
								out = "." + s.substr(s.length() - 3, 3) + out
								s = s.substr(0, s.length() - 3)
				out = s + out
				if n < 0:
								out = "-" + out
				return outnfunc _save_configurations() -> void:
	var account_manager = load("res://scripts/account_manager.gd").new()
	var username: String = account_manager.get_current_player()
	if username == "":
		retur

	var players = account_manager.load_players()
	# Aktif geminin güncel loadout'unu gemi anahtarına yaz.
	_ensure_ship_configuration(active_ship_id)
	ship_configurations[active_ship_id] = configurations
	for p in players:
		if p.get("username", "") == username:
			# Eski alanı aktif gemi için koruyoruz; yeni gerçek kaynak gemi-bazlı alan.
			p["configurations"] = configurations
			p["ship_configurations"] = ship_configurations
			p["selected_config"] = selected_config
			break
	account_manager.save_players(players)
	print("EKIPMAn KAYDEDILDI: ", configurations)
	if GlobalState.server_session_active: _queue_server_loadout_sync()nfunc refresh_info():
	var info = find_child("PilotInfo", true, false)
	if info:
		info.text = "PİLOT BİLGİLERİnŞirket: %sNSeviye: %dNBitcoin: %dNPLT: %dNTecrübe: %dnŞeref: %d" % [
			GlobalState.company,
			GlobalState.level,
			GlobalState.bitcoin,
			GlobalState.platinum,
			GlobalState.xp,
			GlobalState.honor
		]
# Mobil KONFİ butonu, PC C tuşuyla aynı sistemi kullanır.nfunc mobile_toggle_config() -> void:
	_set_config(2 if selected_config == 1 else 1)nfunc _queue_server_loadout_sync() -> void:
	if not GlobalState.server_session_active or server_loadout_sync_queued: retur

	server_loadout_sync_queued=true
	call_deferred("_sync_loadout_to_server")nfunc _sync_loadout_to_server() -> void:
	await get_tree().create_timer(0.15,true).timeout
	_ensure_ship_configuration(active_ship_id)
	ship_configurations[active_ship_id]=configurations
	var am=load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(am)
	var result:Dictionary=await am.server_save_loadout(ship_configurations,selected_config,active_ship_id)
	am.queue_free()
	server_loadout_sync_queued=false
	if bool(result.get("basarili",false)):
		GlobalState.ship_configurations=ship_configurations.duplicate(true)
		GlobalState.selected_config=selected_config
		GlobalState.active_ship_id=active_ship_id
		migrate_local_loadout_to_server=false
	else:
		print("LOADOUT SERVER SYNC HATA: ",result.get("mesaj",""))nfunc _refresh_available_quests() -> void:
	if _active_menu_section in ["GÖREVLER", "GÖREV"] and section_screen != null and section_screen.visible:
		_show_quest_system()nfunc _show_quest_system() -> void:
	if section_content_panel == null:
		retur

	_clear_section_dynamic_now()
	section_body_label.visible = false
	var scroll := ScrollContainer.new()
	scroll.name = "QuestSystemScroll"
	scroll.position = Vector2(18, 18)
	scroll.size = Vector2(860, 460)
	scroll.set_meta("novagate_section_dynamic", true)
	section_content_panel.add_child(scroll)
	var list := VBoxContainer.new()
	list.name = "QuestSystemList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)
	var heading := Label.new()
	heading.text = "GÖREV MERKEZİ"
	heading.add_theme_font_size_override("font_size", 24)
	list.add_child(heading)
	var active := QuestSystem.get_available_quests()
	if active.is_empty():
		var empty := Label.new()
		empty.text = "Seviyene ve görev zincirine uygun alınabilir görev yok."
		list.add_child(empty)
	for quest_id_value in active:
		_add_quest_row(list, str(quest_id_value))nfunc _add_quest_row(parent: VBoxContainer, quest_id: String) -> void:
	var quest := QuestSystem.get_quest(quest_id)
	if quest.is_empty():
		retur

	var card := PanelContainer.new()
	card.name = "QuestSystemCard_" + quest_id
	card.custom_minimum_size = Vector2(800, 96)
	parent.add_child(card)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 3)
	card.add_child(body)
	var title := Label.new()
	title.text = "Seviye %d • %s" % [int(quest.get("level", 1)), str(quest.get("title", quest_id))]
	title.add_theme_font_size_override("font_size", 17)
	body.add_child(title)
	var description := Label.new()
	description.text = str(quest.get("description", ""))
	body.add_child(description)
	var progress := Label.new()
	progress.text = "İlerleme: %d/%d" % [QuestSystem.get_progress(quest_id), QuestSystem.get_target(quest_id)]
	body.add_child(progress)
	var rewards := Label.new()
	rewards.text = "Ödül: " + _format_quest_rewards(quest.get("rewards", {}))
	body.add_child(rewards)
	var accept := Button.new()
	accept.text = "GÖREVİ AL"
	accept.pressed.co
nect(func() -> void:
		accept.disabled = true
		QuestSystem.accept_quest(quest_id)
		_refresh_available_quests.call_deferred()
	)
	body.add_child(accept)nfunc _format_quest_rewards(rewards: Dictionary) -> String:
	var parts: Array[String] = []
	for key in ["btc", "plt", "xp", "honor"]:
		if int(rewards.get(key, 0)) > 0:
			parts.append("+%d %s" % [int(rewards[key]), key.to_upper()])
	for ammo_name in (rewards.get("ammo", {}) as Dictionary).keys():
		parts.append("+%d %s" % [int((rewards["ammo"] as Dictionary)[ammo_name]), str(ammo_name)])
	for item_name in (rewards.get("items", {}) as Dictionary).keys():
		parts.append("+%d %s" % [int((rewards["items"] as Dictionary)[item_name]), str(item_name)])
	return ", ".join(parts) if not parts.is_empty() else "Yok"
