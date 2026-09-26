extends Control
@export var main_path: NodePath = NodePath("../..")
@export var player_path: NodePath = NodePath("../../PlayerShip")
@onready var main_node: Node = get_node_or_null(main_path)
@onready var player: Node = get_node_or_null(player_path)
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
var _clan_active_tab: int = 0
var _clan_generation: int = 0
var _clan_creating: bool = false
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
var active_nav_button: Button = null
var _logbook_filter: String = "TÜMÜ"
var _logbook_filter_buttons: Dictionary = {}
var _logbook_scroll: ScrollContainer = null
var _logbook_rows: VBoxContainer = null
# Ana ekrandaki SEYİR DEFTERİ kartının içerik etiketi (Seyir Defteri giriş noktası).
var _logbook_card_label: Label = null
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
const DRONE_SLOTS_PER_DRONE := 2
const ITEM_DATA: Dictionary = {
				"lf1": {"icon": "res://assets/equipment/pro/lf1.png", "type": "laser", "damage": 90, "title": "LF1"},
				"lf2": {"icon": "res://assets/equipment/pro/lf2.png", "type": "laser", "damage": 132, "title": "LF2"},
				"lf3": {"icon": "res://assets/equipment/pro/lf3.png", "type": "laser", "damage": 210, "title": "LF3"},
				"kalkan1": {"icon": "res://assets/equipment/pro/shield1.png", "type": "generator", "shield": 5000, "title": "Kalkan I"},
				"kalkan2": {"icon": "res://assets/equipment/pro/shield2.png", "type": "generator", "shield": 10000, "title": "Kalkan II"},
				"hiz1": {"icon": "res://assets/equipment/pro/speed1.png", "type": "generator", "speed": 7, "title": "Hız I"},
				"hiz2": {"icon": "res://assets/equipment/pro/speed2.png", "type": "generator", "speed": 10, "title": "Hız II"},
				"pbmb": {"icon": "res://assets/equipment/pro/ext1.png", "type": "extra", "title": "PBMB"},
				"wsh": {"icon": "res://assets/equipment/pro/ext2.png", "type": "extra", "title": "WSH"},
				"emp": {"icon": "res://assets/equipment/pro/ext3.png", "type": "extra", "title": "EMP"},
				"invis": {"icon": "res://assets/equipment/pro/ext4.png", "type": "extra", "title": "INVIS"},
				"frep": {"icon": "res://assets/equipment/pro/ext5.png", "type": "extra", "title": "FREP"},
				"enc": {"icon": "res://assets/equipment/pro/ext6.png", "type": "extra", "title": "ENC"},
				"acpr": {"icon": "res://assets/equipment/pro/ext7.png", "type": "extra", "title": "ACPR"},
				"DMG-B01": {"icon": "res://market/assets/boosters/DMG-B01.png", "type": "extra", "title": "DMG-B01"},
				"HP-B01": {"icon": "res://market/assets/boosters/HP-B01.png", "type": "extra", "title": "HP-B01"},
				"SHD-B01": {"icon": "res://market/assets/boosters/SHD-B01.png", "type": "extra", "title": "SHD-B01"},
				"XP-B01": {"icon": "res://market/assets/boosters/XP-B01.png", "type": "extra", "title": "XP-B01"},
				"HOn-B01": {"icon": "res://market/assets/boosters/HOn-B01.png", "type": "extra", "title": "HOn-B01"}
}
var inventory: Dictionary = {
				"lf1": 0,
				"lf2": 0,
				"lf3": 0,
				"kalkan1": 0,
				"kalkan2": 0,
				"hiz1": 0,
				"hiz2": 0,
				"pbmb": 0,
				"wsh": 0,
				"emp": 0,
				"invis": 0,
				"frep": 0,
				"enc": 0,
				"acpr": 0,
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
				if not GlobalState.logbook_changed.is_connected(_refresh_logbook_section):
					GlobalState.logbook_changed.connect(_refresh_logbook_section)
				process_mode = Node.PROCESS_MODE_ALWAYS
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
				_show_main_menu()

func _unhandled_input(event: InputEvent) -> void:
				if event is InputEventKey:
								var key_event := event as InputEventKey
								if key_event.pressed and not key_event.echo and key_event.keycode == KEY_ESCAPE and overlay != null and overlay.visible:
												_close_all()
												get_viewport().set_input_as_handled()
												return

								if key_event.pressed and not key_event.echo and key_event.keycode == KEY_C:
												_set_config(2 if selected_config == 1 else 1)
												get_viewport().set_input_as_handled()

func _initialize_configurations() -> void:
	var account_manager = load("res://scripts/account_manager.gd").new()
	var username: String = account_manager.get_current_player()
	var saved_player = account_manager.get_player(username)
	_load_ship_catalog()
	_load_owned_items(saved_player)
	# SERVER OTURUMUNDA sahiplik yalnız PostgreSQL canlı verisinden okunur.
	if GlobalState.server_session_active:
		inventory = {
			"lf1": 0, "lf2": 0, "lf3": 0,
			"kalkan1": 0, "kalkan2": 0,
			"hiz1": 0, "hiz2": 0,
			"pbmb": 0, "wsh": 0, "emp": 0, "invis": 0,
			"frep": 0, "enc": 0, "acpr": 0,
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
	# PHASE 1 - item identity migration.
	# Configurations saved before Phase 1 store DISPLAY names ("Kalkan 1").
	# ITEM_DATA is now keyed by canonical ids, so those slots would render as
	# garbage (or crash on a direct index). Every stored configuration passes
	# through this function exactly once on load, which makes it the one safe
	# place to fold the old spelling forward - existing players keep their gear.
	for slot in [lasers, generators, extras, drones]:
		for i in range(slot.size()):
			var raw = slot[i]
			if raw == null or str(raw) == "":
				continue
			slot[i] = _canonical_item_id(str(raw))
	return config


## PHASE 1: display name -> canonical item id.
##
## Mirrors account_manager.canonical_item_id() and the server's
## item_catalog.normalize_item_id(). An id that is already canonical returns
## unchanged, so this is safe to run on every load.
func _canonical_item_id(raw: String) -> String:
	var text := raw.strip_edges().to_lower()
	text = text.replace("ı", "i").replace("İ", "i")
	var spaced := " ".join(text.split(" "))
	match spaced:
		"kalkan 1", "kalkan i", "kalkan_1", "kalkan-1":
			return "kalkan1"
		"kalkan 2", "kalkan ii", "kalkan_2", "kalkan-2":
			return "kalkan2"
		"hiz 1", "hiz i", "hiz_1", "hiz-1":
			return "hiz1"
		"hiz 2", "hiz ii", "hiz_2", "hiz-2":
			return "hiz2"
		"lf 1", "lf_1", "lf-1":
			return "lf1"
		"lf 2", "lf_2", "lf-2":
			return "lf2"
		"lf 3", "lf_3", "lf-3":
			return "lf3"
		"3 saniye", "uc saniye", "uc_saniye":
			return "uc_saniye"
		"plus droid", "plus", "droid_plus_1":
			return "droid_plus_1"
		"zeus droid", "zeus", "droid_zeus_1":
			return "droid_zeus_1"
		"ema", "enc", "nukleer", "pbmb", "wsh", "emp", "invis", "frep", "acpr":
			return spaced
		"dmg-b01", "hp-b01", "shd-b01", "xp-b01", "hon-b01":
			return spaced.to_upper()
		_:
			return spaced.replace(" ", "").replace("_", "").replace("-", "")

func _load_owned_items(saved_player) -> void:
	inventory = {
		"lf1": 0,
		"lf2": 0,
		"lf3": 0,
		"kalkan1": 0,
		"kalkan2": 0,
		"hiz1": 0,
		"hiz2": 0,
		"pbmb": 0,
		"wsh": 0,
		"emp": 0,
		"invis": 0,
		"frep": 0,
		"enc": 0,
		"acpr": 0
	}
	owned_droid_types = []
	owned_ships = ["Ship10"]
	active_ship_id = "Ship10"
	active_ship_data = _get_ship_data("Ship10")
	if saved_player == null:
		return

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
		owned_droid_types.pop_back()

func _load_ship_catalog() -> void:
	ship_catalog.clear()
	var path := "res://market/data/ships.json"
	if not FileAccess.file_exists(path):
		return

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return

	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		for ship_value in parsed:
			if ship_value is Dictionary:
				var ship:Dictionary = ship_value
				ship_catalog[str(ship.get("id", ""))] = ship

func _get_ship_data(ship_id:String) -> Dictionary:
	if ship_catalog.is_empty():
		_load_ship_catalog()
	var value = ship_catalog.get(ship_id, {})
	return value if value is Dictionary else {}

func _ship_slot_limit(slot_type:String) -> int:
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
	return 0

func reload_owned_items_from_save() -> void:
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
				}

func _ensure_ship_configuration(ship_id: String) -> void:
	if ship_id == "":
		return

	if ship_configurations.has(ship_id) and ship_configurations[ship_id] is Dictionary:
		var existing: Dictionary = ship_configurations[ship_id]
		ship_configurations[ship_id] = {
			1: _normalize_configuration(existing.get("1", existing.get(1, _new_configuration()))),
			2: _normalize_configuration(existing.get("2", existing.get(2, _new_configuration())))
		}
		return

	ship_configurations[ship_id] = {
		1: _new_configuration(),
		2: _new_configuration()
	}

func _clear_new_droid_slots(old_count: int, new_count: int) -> void:
	if new_count <= old_count:
		return

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
					slots[base_index + 1] = null

func _build_menu_button() -> void:
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
				menu_button.pressed.connect(_open_menu)
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
				_update_config_indicator()

func _build_overlay() -> void:
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
				close_button.pressed.connect(_close_all)
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
				host.add_child(section_screen)

func _build_main_menu() -> Control:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_stylebox_override("panel", _panel_style(Color(0.01, 0.014, 0.022, 1.0), Color(0.05, 0.62, 0.78, 0.25), 1))
	root.mouse_filter = Control.MOUSE_FILTER_STOP

	# ÜST HUD STRIP
	var hud := Panel.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	hud.offset_left = 0.0
	hud.offset_top = 0.0
	hud.offset_right = 0.0
	hud.offset_bottom = 74.0
	hud.add_theme_stylebox_override("panel", _panel_style(Color(0.012, 0.022, 0.034, 1.0), Color(0.06, 0.62, 0.78, 0.55), 1))
	hud.add_theme_constant_override("corner_radius_top_left", 6)
	hud.add_theme_constant_override("corner_radius_top_right", 6)
	root.add_child(hud)

	var hud_inner := HBoxContainer.new()
	hud_inner.position = Vector2(8, 6)
	hud_inner.size = Vector2(hud.size.x - 16, hud.size.y - 12)
	hud_inner.add_theme_constant_override("separation", 4)
	hud.add_child(hud_inner)

	var brand := Label.new()
	brand.text = "NOVA GATE"
	brand.custom_minimum_size = Vector2(110, 30)
	brand.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	brand.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	brand.add_theme_font_size_override("font_size", 16)
	brand.add_theme_color_override("font_color", NovaGateUITheme.PRIMARY)
	hud_inner.add_child(brand)

	var center_spacer := Control.new()
	center_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud_inner.add_child(center_spacer)

	hud_inner.add_child(_hud_block("ONLINE", _online_status_text()))
	hud_inner.add_child(_hud_block("PILOT", _pilot_short_text(), true))
	hud_inner.add_child(_hud_block("LVL", str(GlobalState.level)))
	hud_inner.add_child(_hud_block("VIP", _vip_status_text()))
	hud_inner.add_child(_hud_block("XP", _format_number(GlobalState.xp)))

	var right_spacer := Control.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud_inner.add_child(right_spacer)

	hud_inner.add_child(_hud_block("BTC", _format_number(GlobalState.bitcoin)))
	hud_inner.add_child(_hud_block("PLT", _format_number(GlobalState.platinum)))
	hud_inner.add_child(_hud_block("GOLD", _format_number(GlobalState.gold)))

	# ANA İÇ PAYLAŞIMLI ALAN
	var space := Control.new()
	space.position = Vector2(0, 74)
	space.size = Vector2(root.size.x, root.size.y - 74)
	space.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(space)

	# SOL NAVİGASYON
	var left_nav_panel := Panel.new()
	left_nav_panel.position = Vector2(8, 8)
	left_nav_panel.size = Vector2(220, space.size.y - 16 - 56.0)
	left_nav_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.016, 0.026, 0.038, 1.0), Color(0.07, 0.55, 0.72, 0.45), 1))
	left_nav_panel.add_theme_constant_override("corner_radius_all", 8)
	space.add_child(left_nav_panel)

	var nav_inner := VBoxContainer.new()
	nav_inner.position = Vector2(6, 6)
	nav_inner.size = Vector2(left_nav_panel.size.x - 12, left_nav_panel.size.y - 12)
	nav_inner.add_theme_constant_override("separation", 4)
	left_nav_panel.add_child(nav_inner)

	# NAV BAŞLIK
	var nav_header := Label.new()
	nav_header.text = "KONTROL PANELİ"
	nav_header.custom_minimum_size = Vector2(nav_inner.size.x, 36)
	nav_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nav_header.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	nav_header.add_theme_font_size_override("font_size", 14)
	nav_header.add_theme_color_override("font_color", NovaGateUITheme.PRIMARY)
	nav_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nav_inner.add_child(nav_header)

	var nav_spacer := Control.new()
	nav_spacer.custom_minimum_size = Vector2(nav_inner.size.x, 6)
	nav_inner.add_child(nav_spacer)

	# Kontrol Paneli bölümleri.
	# "BİLGİ" butonu ve ayrı "SEYİR DEFTERİ" butonu kaldırıldı:
	#  * BİLGİ paneli menünün varsayılan ekranıdır (SEYİR DEFTERİ kartı burada).
	#  * Seyir Defteri o kartın üzerinden açılır; ikinci bir buton üretilmez.
	var nav_items = ["PAZAR","YETENEK AĞACI","EKİPMAN","MARKET","GÖREVLER","KLAN","İSTATİSTİKLER","HARİTA","GALAXY GATES","AYARLAR"]
	for i in range(nav_items.size()):
		var item: String = str(nav_items[i])
		var b := _nav_button(item)
		b.custom_minimum_size = Vector2(196, 30)
		if item == "EKİPMAN":
			b.pressed.connect(_show_hangar)
		else:
			b.pressed.connect(_show_section.bind(item))
		b.pressed.connect(_on_nav_pressed.bind(b))
		nav_inner.add_child(b)


	# BİLGİ PANELİ (MERKEZ + SAĞ ALAN)
	var _cta_h := 56.0
	var info_panel := Panel.new()
	info_panel.position = Vector2(228, 8)
	info_panel.size = Vector2(space.size.x - 228 - 16, space.size.y - 16 - _cta_h)
	info_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.016, 0.026, 0.038, 1.0), Color(0.07, 0.55, 0.72, 0.45), 1))
	info_panel.add_theme_constant_override("corner_radius_all", 8)
	space.add_child(info_panel)

	var info_inner := VBoxContainer.new()
	info_inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	info_inner.add_theme_constant_override("separation", 6)
	info_panel.add_child(info_inner)

	# Üst satır: SEYİR DEFTERİ | ETKİNLİKLER
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 6)
	top_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info_inner.add_child(top_row)

	# Seyir Defteri giriş noktası: Kontrol Paneli'nde ayrı bir "SEYİR DEFTERİ"
	# butonu yok; bu kart tıklanınca tam log ekranını açar.
	var logbook_card := _section_card("SEYİR DEFTERİ", "Henüz kayıt yok.\nTümünü aç ▸", true)
	_tune_card(logbook_card, 380, 0.40)
	_logbook_card_label = logbook_card.find_child("CardContent", true, false) as Label
	_make_card_clickable(logbook_card, _show_logbook_section, "Seyir Defterini aç")
	top_row.add_child(logbook_card)

	var events_card := _section_card("ETKİNLİKLER", "Yaklaşan etkinlik bulunmuyor.", true)
	_tune_card(events_card, 380, 0.40)
	top_row.add_child(events_card)

	# Alt: ONLINE OYUNCULAR
	var online_card := _section_card("ONLINE OYUNCULAR", "Online oyuncu verisi bekleniyor.", false, true)
	_tune_card(online_card, 0, 0.22)
	info_inner.add_child(online_card)

	# ALT CTA STRIP (footer — sadece content alanı, nav üzerine binmez)
	var bottom := Panel.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	bottom.offset_left = -(space.size.x - 228 - 8)
	bottom.offset_top = -56.0
	bottom.offset_right = -8.0
	bottom.offset_bottom = 0.0
	bottom.add_theme_stylebox_override("panel", _panel_style(Color(0.005, 0.01, 0.018, 0.92), Color(0.04, 0.45, 0.6, 0.4), 1))
	bottom.add_theme_constant_override("corner_radius_bottom_right", 6)
	root.add_child(bottom)

	var bottom_inner := HBoxContainer.new()
	bottom_inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bottom_inner.add_theme_constant_override("separation", 6)
	bottom.add_child(bottom_inner)

	var left_spacer := Control.new()
	left_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_inner.add_child(left_spacer)

	var cta := _cta_button()
	bottom_inner.add_child(cta)

	var cta_right_spacer := Control.new()
	cta_right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_inner.add_child(cta_right_spacer)

	# PİLOT PANELİ — refresh_info() için gerekli
	info_panel.name = "PilotInfo"

	return root

func _build_section_screen() -> Control:
				var root := Control.new()
				root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				var back := Button.new()
				back.text = "← MEnÜ"
				back.position = Vector2(8, 0)
				back.size = Vector2(112, 38)
				back.pressed.connect(_show_main_menu)
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
				return root

func _build_unified_hangar() -> Control:
				var root := Control.new()
				root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
				var back := Button.new()
				back.text = "← MEnÜ"
				back.position = Vector2(8, 0)
				back.size = Vector2(112, 38)
				NovaGateUITheme.apply_button(back)
				back.pressed.connect(_show_main_menu)
				root.add_child(back)
				var ships_tab_button := Button.new()
				ships_tab_button.text = "GEMİLER"
				ships_tab_button.position = Vector2(140, 0)
				ships_tab_button.size = Vector2(120, 38)
				NovaGateUITheme.apply_button(ships_tab_button)
				ships_tab_button.pressed.connect(_set_tab.bind("ships"))
				root.add_child(ships_tab_button)
				var ammo_tab_button := Button.new()
				ammo_tab_button.text = "CEPHANE"
				ammo_tab_button.position = Vector2(270, 0)
				ammo_tab_button.size = Vector2(120, 38)
				NovaGateUITheme.apply_button(ammo_tab_button)
				ammo_tab_button.pressed.connect(_set_tab.bind("ammo"))
				root.add_child(ammo_tab_button)
				# CONFIG 1 / CONFIG 2 — segmented control görünümü.
				config_one_button = Button.new()
				config_one_button.text = "CONFIG 1"
				config_one_button.position = Vector2(410, 0)
				config_one_button.size = Vector2(88, 38)
				NovaGateUITheme.apply_button(config_one_button)
				config_one_button.pressed.connect(_set_config.bind(1))
				root.add_child(config_one_button)
				config_two_button = Button.new()
				config_two_button.text = "CONFIG 2"
				config_two_button.position = Vector2(500, 0)
				config_two_button.size = Vector2(88, 38)
				NovaGateUITheme.apply_button(config_two_button)
				config_two_button.pressed.connect(_set_config.bind(2))
				root.add_child(config_two_button)
				ship_tab_button = Button.new()
				ship_tab_button.text = "UZAY GEMİSİ"
				ship_tab_button.position = Vector2(608, 0)
				ship_tab_button.size = Vector2(150, 38)
				NovaGateUITheme.apply_button(ship_tab_button)
				ship_tab_button.pressed.connect(_set_tab.bind("ship"))
				root.add_child(ship_tab_button)
				drone_tab_button = Button.new()
				drone_tab_button.text = "DROİDLER"
				drone_tab_button.position = Vector2(766, 0)
				drone_tab_button.size = Vector2(140, 38)
				NovaGateUITheme.apply_button(drone_tab_button)
				drone_tab_button.pressed.connect(_set_tab.bind("drones"))
				root.add_child(drone_tab_button)
				selection_label = Label.new()
				selection_label.text = "Envanterden bir ekipman seç. Sonra uygun yuvaya tıkla. Sağ tık: çıkar."
				selection_label.position = Vector2(920, 5)
				selection_label.size = Vector2(240, 30)
				selection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				selection_label.add_theme_font_size_override("font_size", 12)
				selection_label.add_theme_color_override("font_color", NovaGateUITheme.DIM)
				root.add_child(selection_label)
				var left_panel := Panel.new()
				left_panel.position = Vector2(8, 50)
				left_panel.size = Vector2(230, 520)
				left_panel.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
				root.add_child(left_panel)
				var ship_title := Label.new()
				ship_title.text = "AKTİF GEMİ"
				ship_title.position = Vector2(15, 12)
				ship_title.size = Vector2(200, 30)
				ship_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				NovaGateUITheme.title_label(ship_title, 19)
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
				center_panel.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
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
				inventory_panel.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
				root.add_child(inventory_panel)
				var inventory_title := Label.new()
				inventory_title.text = "ENVANTER"
				inventory_title.position = Vector2(12, 10)
				inventory_title.size = Vector2(272, 34)
				inventory_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				NovaGateUITheme.title_label(inventory_title, 20)
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
				return root

func _refresh_all() -> void:
				refresh_info()
				_refresh_tabs()
				_refresh_center()
				_refresh_inventory()
				_refresh_stats()

func _refresh_tabs() -> void:
				if config_one_button == null:
								return

				config_one_button.disabled = selected_config == 1
				config_two_button.disabled = selected_config == 2
				ship_tab_button.disabled = selected_tab == "ship"
				drone_tab_button.disabled = selected_tab == "drones"

func _refresh_center() -> void:
				if center_host == null:
								return

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
								_build_ship_slots(center_host)

func _build_owned_ships(parent: VBoxContainer) -> void:
				parent.add_child(_section_title("SAHİP OLUNAn GEMİLER • AKTİF: %s" % active_ship_id))
				if owned_ships.is_empty():
								var empty := Label.new()
								empty.text = "Henüz sahip olunan gemi yok."
								parent.add_child(empty)
								return

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
								use_button.pressed.connect(_activate_owned_ship.bind(ship_id))
								text_box.add_child(use_button)
								var currency := str(data.get("currency", "FREE"))
								if ship_id != "Ship10" and currency == "BTC":
												var sell_button := Button.new()
												var refund := int(data.get("price", 0)) / 2
												sell_button.text = "SAT • %s BTC" % _format_number(refund)
												sell_button.pressed.connect(_sell_owned_ship.bind(ship_id, refund))
												text_box.add_child(sell_button)
								elif ship_id != "Ship10" and currency == "PLT":
												var sale_info := Label.new()
												sale_info.text = "PLT gemisi satış BTC değeri henüz belirlenmedi."
												sale_info.add_theme_color_override("font_color", Color(0.72, 0.82, 0.9))
												text_box.add_child(sale_info)
								parent.add_child(panel)

func _activate_owned_ship(ship_id:String) -> void:
				var account_manager = load("res://scripts/account_manager.gd").new()
				var result:Dictionary = account_manager.set_active_ship(ship_id)
				if not bool(result.get("ok", false)):
								selection_label.text = str(result.get("message", "Gemi değiştirilemedi."))
								return

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
				_refresh_all()

func _sell_owned_ship(ship_id:String, refund_btc:int) -> void:
				var account_manager = load("res://scripts/account_manager.gd").new()
				var result:Dictionary = account_manager.sell_ship(ship_id, refund_btc)
				if not bool(result.get("ok", false)):
								selection_label.text = str(result.get("message", "Gemi satılamadı."))
								return

				GlobalState.bitcoin = int(result.get("bitcoin", GlobalState.bitcoin))
				GlobalState.save_game()
				reload_owned_items_from_save()
				if player != null and player.has_method("reload_active_ship_from_save"):
								player.call("reload_active_ship_from_save")
				selection_label.text = str(result.get("message", "Gemi satıldı."))

func _trim_equipment_to_ship_limits() -> void:
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
												extras[i] = null

func _build_ammo(parent: VBoxContainer) -> void:
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
								parent.add_child(label)

func _build_ship_slots(parent: VBoxContainer) -> void:
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
								extra_grid.add_child(_equipment_slot("extra", index, extras[index], "extras"))

func _build_drone_slots(parent: VBoxContainer) -> void:
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
								return

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
								sell_button.pressed.connect(_sell_droid.bind(drone_index))
								card.add_child(sell_button)
								for slot_offset in range(slot_count):
												var absolute_index := drone_index * DRONE_SLOTS_PER_DRONE + slot_offset
												var slot := _equipment_slot("drone", absolute_index, drone_slots[absolute_index], "drones")
												slot.position = Vector2(95 + slot_offset * 70, 48)
												card.add_child(slot)

func _get_droid_sell_refund(droid_type:String, same_type_count:int) -> Dictionary:
				var plus_prices := [100000, 200000, 400000, 800000, 1600000, 3200000, 6400000, 12800000]
				var zeus_prices := [12000, 20000, 35000, 60000, 100000, 170000, 300000, 500000]
				var prices:Array = plus_prices if droid_type == "PLUS" else zeus_prices
				var currency := "BTC" if droid_type == "PLUS" else "PLT"
				var price_index := clampi(maxi(same_type_count, 1) - 1, 0, prices.size() - 1)
				return {
								"refund": int(prices[price_index]) / 2,
								"currency": currency
				}

func _sell_droid(droid_index:int) -> void:
				if droid_sell_in_progress:
								return

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
								return

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
				_refresh_all()

func _refresh_inventory() -> void:
				if inventory_grid == null:
								return

				_clear_children(inventory_grid)
				for item_name in ITEM_DATA.keys():
								if int(inventory.get(item_name, 0)) > 0:
												inventory_grid.add_child(_inventory_button(str(item_name)))

func _inventory_button(item_name: String) -> Button:
				var data: Dictionary = ITEM_DATA.get(item_name, {})
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
				button.pressed.connect(_select_item.bind(item_name))
				return button

func _equipment_slot(accepted_type: String, index: int, item_value: Variant, array_key: String) -> Button:
				var button := Button.new()
				button.custom_minimum_size = Vector2(50, 50)
				button.tooltip_text = "Boş yuva"
				button.add_theme_stylebox_override("normal", _panel_style(Color(0.018, 0.035, 0.05, 0.98), _slot_color(accepted_type), 1))
				button.add_theme_stylebox_override("hover", _panel_style(Color(0.05, 0.13, 0.17, 1.0), Color(0.35, 0.95, 1.0), 2))
				if item_value != null and str(item_value) != "":
								var item_name := str(item_value)
								var data: Dictionary = ITEM_DATA.get(item_name, {})
								button.icon = load(str(data["icon"]))
								button.expand_icon = true
								button.tooltip_text = "%sNSağ tık: çıkar" % _item_tooltip(item_name)
				else:
								button.text = str(index + 1)
				button.pressed.connect(_equip_selected.bind(accepted_type, index, array_key))
				button.gui_input.connect(_slot_gui_input.bind(index, array_key))
				return button


func _equip_selected(accepted_type: String, index: int, array_key: String) -> void:
				var config: Dictionary = configurations[selected_config]
				var slots: Array = config[array_key]
				var current_item: Variant = slots[index]
				# Ekipman seçili değilse dolu yuvaya sol tıkla çıkar.
				if selected_item == "":
								if current_item != null and str(current_item) != "":
												_remove_item(index, array_key)
								return

				var data: Dictionary = ITEM_DATA.get(selected_item, {})
				var item_type := str(data["type"])
				if accepted_type == "drone":
								if item_type != "laser" and item_type != "generator":
												selection_label.text = "Droid yuvasına sadece lazer veya jeneratör takılabilir."
												return

				elif item_type != accepted_type:
								selection_label.text = "%s ekipmanı bu yuvaya takılamaz." % str(data["title"])
								return

				if _available_count(selected_item) <= 0 and str(current_item) != selected_item:
								selection_label.text = "%s bu konfigürasyon için kalmadı." % str(data["title"])
								return

				slots[index] = selected_item
				QuestSystem.record_event("equipment_equipped", {"slot_type": item_type, "item": selected_item, "amount": 1})
				_save_configurations()
				selection_label.text = "%s takıldı." % str(data["title"])
				selected_item = ""
				_refresh_all()

func _slot_gui_input(event: InputEvent, index: int, array_key: String) -> void:
				if event is InputEventMouseButton:
								var mouse_event := event as InputEventMouseButton

								if mouse_event.pressed and mouse_event.button_index == MOUSE_BUTTON_RIGHT:
												_remove_item(index, array_key)

func _remove_item(index: int, array_key: String) -> void:
				var config: Dictionary = configurations[selected_config]
				var slots: Array = config[array_key]
				var item_value: Variant = slots[index]
				if item_value == null or str(item_value) == "":
								return

				var item_name := str(item_value)
				slots[index] = null
				_save_configurations()
				selected_item = ""
				selection_label.text = "%s çıkarıldı." % str((ITEM_DATA.get(item_name, {}) as Dictionary).get("title", item_name))
				_refresh_all()

func _select_item(item_name: String) -> void:
				# Envanterde ekipmana sol tıklanınca ilk uygun boş yuvaya doğrudan takılır.
				# Böylece seçim yapıp ayrıca slota tıklamak gerekmez.
				selected_item = item_name
				if _auto_equip_selected(item_name):
								selection_label.text = "%s ilk uygun yuvaya takıldı." % str((ITEM_DATA.get(item_name, {}) as Dictionary).get("title", item_name))
								selected_item = ""
								_refresh_all()
				else:
								selection_label.text = "%s için boş ve uygun yuva yok." % str((ITEM_DATA.get(item_name, {}) as Dictionary).get("title", item_name))
								_refresh_inventory()

func _auto_equip_selected(item_name: String) -> bool:
				if _available_count(item_name) <= 0:
								return false
				var data: Dictionary = ITEM_DATA.get(item_name, {})
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
				return false

func _set_config(config_number: int) -> void:
				selected_config = clampi(config_number, 1, 2)
				selected_item = ""
				if selection_label != null:
								selection_label.text = "Konfigürasyon %d aktif. C ile değiştir." % selected_config
				if player != null and player.has_method("set_active_config"):
								player.call("set_active_config", selected_config)
				_update_config_indicator()
				_refresh_all()

func _update_config_indicator() -> void:
				if config_indicator != null:
								config_indicator.text = "KONFİGÜRASYOn %d  •  C" % selected_config

func _count_item_in_active_config(item_name: String) -> int:
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
				return count

func _available_count(item_name: String) -> int:
				return maxi(int(inventory.get(item_name, 0)) - _count_item_in_active_config(item_name), 0)

func _set_tab(tab_name: String) -> void:
				selected_tab = tab_name
				selected_item = ""
				_refresh_all()

func _refresh_stats() -> void:
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
			var data:Dictionary = ITEM_DATA.get(str(item_value), {})
			damage += int(data.get("damage", 0))
	var generators:Array = config["generators"]
	for i in range(mini(generator_limit, generators.size())):
		var item_value = generators[i]
		if item_value != null and str(item_value) != "":
			var data:Dictionary = ITEM_DATA.get(str(item_value), {})
			shield += int(data.get("shield", 0))
			speed_bonus += int(data.get("speed", 0))
	var drone_slots:Array = config["drones"]
	for index in _owned_droid_slot_indices():
		if index >= 0 and index < drone_slots.size():
			var item_value = drone_slots[index]
			if item_value != null and str(item_value) != "":
				var data:Dictionary = ITEM_DATA.get(str(item_value), {})
				damage += int(data.get("damage", 0))
				shield += int(data.get("shield", 0))
				speed_bonus += int(data.get("speed", 0))
	if active_ship_data.is_empty():
		active_ship_data = _get_ship_data(active_ship_id)
	var base_hp := int(active_ship_data.get("hp", 8000))
	var base_speed_value := int(active_ship_data.get("speed", 320))
	var total_speed := base_speed_value + speed_bonus
	if stats_label != null:
		stats_label.text = "%sNKONFİGÜRASYOn: %dNCAn: %sNLAZER HASARI: %dNKALKAn: %dNHIZ: %dNDROİD: %d / 8NLAZER YUVASA: %dNJENERATÖR YUVASA: %dNEKSTRA YUVASA: %d" % [
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
		player.call("apply_equipment_stats", damage, shield, speed_bonus)

func _section_title(text_value: String) -> Label:
				var label := Label.new()
				label.text = text_value
				label.custom_minimum_size = Vector2(550, 30)
				label.add_theme_font_size_override("font_size", 17)
				label.add_theme_color_override("font_color", Color(0.68, 0.9, 1.0))
				return label

func _new_slot_grid(columns: int) -> GridContainer:
				var grid := GridContainer.new()
				grid.columns = columns
				grid.add_theme_constant_override("h_separation", 5)
				grid.add_theme_constant_override("v_separation", 5)
				return grid

func _slot_color(slot_type: String) -> Color:
				if slot_type == "laser":
								return Color(0.08, 0.55, 0.95)
				if slot_type == "generator":
								return Color(0.15, 0.8, 0.45)
				if slot_type == "extra":
								return Color(0.95, 0.55, 0.1)
				return Color(0.55, 0.35, 0.95)

func _item_tooltip(item_name: String) -> String:
				var data: Dictionary = ITEM_DATA.get(item_name, {})
				var text := str(data["title"])
				if data.has("damage"):
								text += "NHasar: %d" % int(data["damage"])
				if data.has("shield"):
								text += "NKalkan: +%d" % int(data["shield"])
				if data.has("speed"):
								text += "NHız: +%d" % int(data["speed"])
				return text

func _clear_children(node: Node) -> void:
				for child in node.get_children():
								child.queue_free()

func _large_button(text_value: String) -> Button:
				var button := Button.new()
				button.text = text_value
				button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
				button.add_theme_font_size_override("font_size", 21)
				button.add_theme_stylebox_override("normal", _panel_style(Color(0.035, 0.08, 0.115, 0.98), Color(0.08, 0.48, 0.64, 0.95), 2))
				button.add_theme_stylebox_override("hover", _panel_style(Color(0.06, 0.16, 0.22, 1.0), Color(0.3, 0.95, 1.0), 2))
				return button


func _panel_style(fill: Color, border: Color, border_width: int, radius: int = 5) -> StyleBoxFlat:
				var style := StyleBoxFlat.new()
				style.bg_color = fill
				style.border_color = border
				style.set_border_width_all(border_width)
				style.corner_radius_top_left = radius
				style.corner_radius_top_right = radius
				style.corner_radius_bottom_left = radius
				style.corner_radius_bottom_right = radius
				style.content_margin_left = 7
				style.content_margin_right = 7
				style.content_margin_top = 5
				style.content_margin_bottom = 5
				return style

func _on_nav_pressed(b: Button) -> void:
	if active_nav_button != null and active_nav_button != b:
		active_nav_button.add_theme_stylebox_override("normal", _panel_style(Color(0.02, 0.03, 0.042, 1.0), Color(0.06, 0.5, 0.66, 0.4), 1))
		active_nav_button.add_theme_color_override("font_color", Color(0.7, 0.85, 0.98))
	active_nav_button = b
	b.add_theme_stylebox_override("normal", _panel_style(Color(0.035, 0.055, 0.075, 1.0), Color(0.12, 0.85, 1.0, 0.85), 2))
	b.add_theme_color_override("font_color", Color(0.95, 1.0, 1.0))

func _show_main_menu() -> void:
				# PLT / Bitcoin / XP gibi canlı ekonomi değerlerini menü her
				# açıldığında yeniden çiz. Extra kullanımı GlobalState.platinum
				# değerini anında değiştirir; eski PilotInfo yazısı cache'de kalmasın.
				refresh_info()
				# Ana ekrandaki SEYİR DEFTERİ kartı canlı olayları gösterir.
				_refresh_logbook_card()
				if market_host != null:
								market_host.visible = false
				if section_content_panel != null:
								section_content_panel.visible = true
				if main_menu != null:
								main_menu.visible = true
				if hangar_screen != null:
								hangar_screen.visible = false
				if section_screen != null:
								section_screen.visible = false

func _show_hangar() -> void:
				main_menu.visible = false
				hangar_screen.visible = true
				if section_screen != null:
								section_screen.visible = false
				_refresh_all()

func _rank_icon_texture(rank_id: String) -> Texture2D:
	# Badge bileseni tek kaynaktir (atlas + dikdortgen eslemesi).
	return RankBadge.texture_for(rank_id)

func _section_request_is_current(request_generation: int, expected_section: String) -> bool:
	return (
		request_generation == _menu_section_generation

		and _active_menu_section == expected_section

		and section_screen != null
		and section_screen.visible
	)

func _rank_number(value) -> String:
	var n := int(value)
	var source := str(abs(n))
	var formatted := ""
	var count := 0
	for i in range(source.length() - 1, -1, -1):
		formatted = source[i] + formatted
		count += 1
		if count % 3 == 0 and i > 0:
			formatted = "." + formatted
	return ("-" if n < 0 else "") + formatted

func _rank_add_text(parent: Control, text_value: String, pos: Vector2, size_value: Vector2, font_size: int = 15, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label := Label.new()
	label.name = "RankV1Text"
	label.set_meta("novagate_section_dynamic", true)
	label.text = text_value
	label.position = pos
	label.size = size_value
	label.horizontal_alignment = align

	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.84, 0.93, 1.0))
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	parent.add_child(label)
	return label

func _rank_add_icon(parent: Control, rank_id: String, pos: Vector2, size_value: Vector2) -> TextureRect:
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
	return icon


func _show_ranking_statistics(request_generation: int = -1) -> void:
	if request_generation < 0:
		request_generation = _menu_section_generation

	if not _section_request_is_current(request_generation, "İSTATİSTİKLER"):
		return

	section_body_label.visible = false
	# Admin icin A rutbesi yonetim bolumu de cizilir; panel o kadar uzar.
	_rank_apply_panel_height(GlobalState.is_admin)
	# Klan ekranından gelindiyse ClaNV1 node'larını da aynı anda kaldır.
	_clear_section_dynamic_now()
	var ranking: Dictionary = await GlobalState.refresh_ranking()
	if not _section_request_is_current(request_generation, "İSTATİSTİKLER"):
		return

	if ranking.is_empty():
		section_body_label.visible = true
		section_body_label.position = Vector2(30, 30)
		section_body_label.text = "İSTATİSTİK / SIRALAMANRütbe bilgileri sunucudan alınamadı."
		return

	var leaderboard: Array = await GlobalState.get_rank_leaderboard(10, true)
	if not _section_request_is_current(request_generation, "İSTATİSTİKLER"):
		return

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
		_rank_add_a_rank_admin_block(request_generation)

func _rank_apply_panel_height(admin_view: bool) -> void:
	# Rutbe ekrani ayni anda iki panel + (admin ise) A rutbesi panelini gosterir.
	if section_content_panel == null:
		return

	section_content_panel.size = Vector2(908, 620) if admin_view else Vector2(908, 430)

func _rank_add_a_rank_admin_block(request_generation: int) -> void:
	if not _section_request_is_current(request_generation, "İSTATİSTİKLER"):
		return

	if not GlobalState.is_admin:
		return

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
		if shown >= A_RANK_ADMIN_ROWS:
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
		return

	if sorted_records.size() > shown:
		_rank_add_text(
			section_content_panel,
			"… ve %d oyuncu daha (yetki veritabanından yönetilir)" % (sorted_records.size() - shown),
			Vector2(80, row_y + 2), Vector2(500, 26), 12
		)

func _rank_a_rank_sorted(records: Array) -> Array:
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
	return flagged + normal

func _rank_a_rank_icon_key(record: Dictionary, active: bool) -> String:
	# A rutbesi kendi ikonunu kullanir; digerleri puanlarindan hesaplanan rutbeyi.
	if active:
		return RankData.RANK_A_KEY
	return RankService.rank_key_for_points(RankService.points_for_record(record))

func _rank_add_a_rank_button(parent: Control, username: String, enable: bool, pos: Vector2) -> Button:
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
	button.pressed.connect(_rank_on_toggle_a_rank.bind(username, enable))
	parent.add_child(button)
	return button


func _rank_on_toggle_a_rank(username: String, enable: bool) -> void:
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
	_show_ranking_statistics()

func _clan_clear_dynamic() -> void:
	section_body_label.visible = false
	_clear_section_dynamic_now()

func _clan_label(text_value: String, pos: Vector2, size_value: Vector2, font_size: int = 14) -> Label:
	var l := Label.new()
	l.name = "ClaNV1Label"
	l.set_meta("novagate_section_dynamic", true)
	l.text = text_value
	l.position = pos
	l.size = size_value
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", Color(0.86, 0.94, 1.0))
	section_content_panel.add_child(l)
	return l

func _clan_button(text_value: String, pos: Vector2, size_value: Vector2, callback: Callable) -> Button:
	var b := Button.new()
	b.name = "ClaNV1Button"
	b.set_meta("novagate_section_dynamic", true)
	b.text = text_value
	b.position = pos
	b.size = size_value
	b.pressed.connect(callback)
	section_content_panel.add_child(b)
	return b

func _clan_text(text_value: String, pos: Vector2, font_size: int = 14, color: Color = Color(0.86, 0.94, 1.0), align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, text_width: int = 0) -> Label:
	var l := Label.new()
	l.name = "ClaNV2Text"
	l.set_meta("novagate_section_dynamic", true)
	l.text = text_value
	l.position = pos
	if text_width > 0:
		l.size = Vector2(text_width, 0)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	else:
		l.size = Vector2(0, 0)
		l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	section_content_panel.add_child(l)
	return l

func _show_clan_system(request_generation: int = -1) -> void:
	if request_generation < 0:
		request_generation = _menu_section_generation

	if not _section_request_is_current(request_generation, "KLAN"):
		return

	_clan_clear_dynamic()
	var tab_gen := _clan_generation

	_clan_text("KLAN", Vector2(20, 6), 22, NovaGateUITheme.PRIMARY, HORIZONTAL_ALIGNMENT_LEFT, 200)
	_clan_text("Bir klana katıl, kendi klanını kur ve galakside birlikte ilerle.", Vector2(20, 32), 11, NovaGateUITheme.DIM, HORIZONTAL_ALIGNMENT_LEFT, 600)

	var accent := ColorRect.new()
	accent.name = "ClaNV2Accent"
	accent.set_meta("novagate_section_dynamic", true)
	accent.position = Vector2(20, 48)
	accent.size = Vector2(100, 2)
	accent.color = NovaGateUITheme.PRIMARY
	section_content_panel.add_child(accent)

	var data: Dictionary = await GlobalState.refresh_clan()
	if not _section_request_is_current(request_generation, "KLAN"):
		return
	if tab_gen != _clan_generation:
		return

	var clan_value = data.get("clan", {})
	if not (clan_value is Dictionary):
		clan_value = {}

	var is_leader := GlobalState.clan_id > 0 and GlobalState.clan_role == "Lider"
	var tab_labels := ["KLANIM", "KLAN ARA"]
	if is_leader:
		tab_labels.append("BAŞVURULAR")
		tab_labels.append("DAVETLER")

	if _clan_active_tab >= tab_labels.size():
		_clan_active_tab = 0

	var tab_w := 138
	var tab_h := 34
	var tab_spacing := 4
	var total_w: int = tab_labels.size() * tab_w + (tab_labels.size() - 1) * tab_spacing
	var start_x: int = (908 - total_w) / 2

	for i in range(tab_labels.size()):
		var is_active := _clan_active_tab == i
		var tab_idx := i
		var btn := Button.new()
		btn.name = "ClaNV2Tab"
		btn.set_meta("novagate_section_dynamic", true)
		btn.text = tab_labels[i]
		btn.position = Vector2(start_x + i * (tab_w + tab_spacing), 56)
		btn.size = Vector2(tab_w, tab_h)
		btn.add_theme_font_size_override("font_size", 12)
		if is_active:
			btn.add_theme_stylebox_override("normal", _panel_style(NovaGateUITheme.PANEL_FILL_SELECTED, NovaGateUITheme.PRIMARY, 2, 8))
			btn.add_theme_color_override("font_color", Color.WHITE)
		else:
			btn.add_theme_stylebox_override("normal", _panel_style(NovaGateUITheme.PANEL_FILL, Color(NovaGateUITheme.SECONDARY, 0.45), 1, 8))
			btn.add_theme_color_override("font_color", NovaGateUITheme.DIM)
		btn.add_theme_stylebox_override("hover", _panel_style(NovaGateUITheme.PANEL_FILL_HOVER, NovaGateUITheme.PRIMARY, 1, 8))
		btn.add_theme_stylebox_override("pressed", _panel_style(NovaGateUITheme.PANEL_FILL_SELECTED, NovaGateUITheme.PRIMARY, 2, 8))
		btn.add_theme_color_override("font_color_hover", Color.WHITE)
		btn.add_theme_color_override("font_color_pressed", Color.WHITE)
		btn.add_theme_color_override("font_color_disabled", NovaGateUITheme.DIM)
		btn.add_theme_stylebox_override("disabled", _panel_style(NovaGateUITheme.PANEL_FILL, Color(NovaGateUITheme.SECONDARY, 0.25), 1, 8))
		btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		btn.pressed.connect(func():
			_clan_active_tab = tab_idx
			_clan_generation += 1
			_show_clan_system(request_generation)
		)
		section_content_panel.add_child(btn)

	if GlobalState.clan_id <= 0:
		match _clan_active_tab:
			0:
				_clan_show_create_form(request_generation)
			1:
				_clan_show_search(request_generation, "")
			_:
				_clan_text("Bu sekme yalnizca bir klan icindeyken kullanilir.", Vector2(20, 92), 15, NovaGateUITheme.DIM, HORIZONTAL_ALIGNMENT_LEFT, 500)
		return

	match _clan_active_tab:
		0:
			_clan_show_klanim(request_generation, clan_value, data)
		1:
			_clan_show_search(request_generation, "")
		2:
			_clan_show_basvurular(request_generation, data)
		3:
			_clan_show_invites(request_generation, data)

func _clan_show_create_form(request_generation: int) -> void:
	_clan_label("Klan kurmak icin bilgileri doldur.", Vector2(20, 92), Vector2(500, 28), 15)
	var name_edit := LineEdit.new()
	name_edit.name = "ClaNV1name"
	name_edit.set_meta("novagate_section_dynamic", true)
	name_edit.placeholder_text = "Klan adi"
	name_edit.position = Vector2(20, 120)
	name_edit.size = Vector2(260, 36)
	section_content_panel.add_child(name_edit)
	var tag_edit := LineEdit.new()
	tag_edit.name = "ClaNV1Tag"
	tag_edit.set_meta("novagate_section_dynamic", true)
	tag_edit.placeholder_text = "TAG (2-5)"
	tag_edit.position = Vector2(290, 120)
	tag_edit.size = Vector2(130, 36)
	section_content_panel.add_child(tag_edit)
	var desc_edit := LineEdit.new()
	desc_edit.name = "ClaNV1Desc"
	desc_edit.set_meta("novagate_section_dynamic", true)
	desc_edit.placeholder_text = "Klan aciklamasi"
	desc_edit.position = Vector2(20, 160)
	desc_edit.size = Vector2(400, 36)
	section_content_panel.add_child(desc_edit)
	_clan_button("KLAN KUR", Vector2(430, 120), Vector2(150, 82), func():
		var result: Dictionary = await GlobalState.create_clan(name_edit.text, tag_edit.text, desc_edit.text)
		if not _section_request_is_current(request_generation, "KLAN"):
			return
		_clan_label(str(result.get("mesaj", "")), Vector2(20, 210), Vector2(560, 28), 13)
		if bool(result.get("basarili", false)):
			_show_clan_system(request_generation)
	)

func _clan_show_search(request_generation: int, query: String) -> void:
	_clan_label("KLAN ARA", Vector2(20, 92), Vector2(300, 28), 16)
	var search_edit := LineEdit.new()
	search_edit.name = "ClaNV1Search"
	search_edit.set_meta("novagate_section_dynamic", true)
	search_edit.placeholder_text = "Klan ara..."
	search_edit.position = Vector2(20, 120)
	search_edit.size = Vector2(300, 34)
	section_content_panel.add_child(search_edit)
	_clan_button("ARA", Vector2(330, 120), Vector2(80, 34), func():
		_clan_show_search(request_generation, search_edit.text)
	)
	_clan_show_search_results(request_generation, query)

func _clan_show_search_results(request_generation: int, query: String) -> void:
	if not _section_request_is_current(request_generation, "KLAN"):
		return
	var search_rows: Array = await GlobalState.search_clans(query)
	if not _section_request_is_current(request_generation, "KLAN"):
		return
	var y := 160.0
	for row in search_rows.slice(0, 8):
		if not (row is Dictionary):
			continue
		var cid := int(row.get("id", 0))
		var text := "[%s] %s  • %d üye" % [
			str(row.get("tag", "")),
			str(row.get("name", "")),
			int(row.get("member_count", 0))
		]
		_clan_label(text, Vector2(20, y), Vector2(450, 28), 14)
		_clan_button("BAŞVUR", Vector2(480, y), Vector2(120, 28), func():
			var result: Dictionary = await GlobalState.apply_clan(cid, "novaGate klan basvurusu")
			if not _section_request_is_current(request_generation, "KLAN"):
				return
			_clan_label(str(result.get("mesaj", "")), Vector2(620, y), Vector2(260, 28), 12)
		)
		y += 32.0

func _clan_show_basvurular(request_generation: int, data: Dictionary) -> void:
	_clan_label("BAŞVURULAR", Vector2(20, 92), Vector2(240, 28), 16)
	var apps_value = data.get("applications", [])
	var y := 120.0
	if apps_value is Array:
		for app in apps_value.slice(0, 8):
			if not (app is Dictionary):
				continue
			var aid := int(app.get("id", 0))
			_clan_label(str(app.get("username", "")), Vector2(20, y), Vector2(190, 28), 13)
			if bool(GlobalState.clan_permissions.get("applications", false)):
				_clan_button("KABUL", Vector2(220, y), Vector2(78, 28), func():
					await GlobalState.decide_clan_application(aid, true)
					if _section_request_is_current(request_generation, "KLAN"):
						_show_clan_system(request_generation)
				)
				_clan_button("RED", Vector2(308, y), Vector2(65, 28), func():
					await GlobalState.decide_clan_application(aid, false)
					if _section_request_is_current(request_generation, "KLAN"):
						_show_clan_system(request_generation)
				)
			y += 32.0
	else:
		_clan_label("Bekleyen basvuru yok.", Vector2(20, 120), Vector2(300, 28), 14)

	if bool(GlobalState.clan_permissions.get("tax", false)):
		var tax_edit := LineEdit.new()
		tax_edit.name = "ClaNV1Tax"
		tax_edit.set_meta("novagate_section_dynamic", true)
		tax_edit.placeholder_text = "Vergi 0-5"
		tax_edit.position = Vector2(20, 400)
		tax_edit.size = Vector2(110, 34)
		section_content_panel.add_child(tax_edit)
		_clan_button("VERGİYİ AYARLA", Vector2(140, 400), Vector2(160, 34), func():
			await GlobalState.set_clan_tax(clampf(float(tax_edit.text), 0.0, 5.0))
			if _section_request_is_current(request_generation, "KLAN"):
				_show_clan_system(request_generation)
		)

func _clan_show_invites(request_generation: int, data: Dictionary) -> void:
	_clan_label("DAVETLİ KLANLAR", Vector2(20, 92), Vector2(300, 28), 16)
	var diplomacy_value = data.get("diplomacy", [])
	var y := 120.0
	if diplomacy_value is Array:
		for rel in diplomacy_value.slice(0, 10):
			if not (rel is Dictionary):
				continue
			_clan_label("%s [%s] • %s • %s" % [
				str(rel.get("target_name", "")),
				str(rel.get("target_tag", "")),
				str(rel.get("relation", "")),
				str(rel.get("status", ""))
			], Vector2(20, y), Vector2(500, 26), 12)
			y += 28.0
	else:
		_clan_label("Aktif diplomatik iliski yok.", Vector2(20, 120), Vector2(300, 28), 14)

func _clan_show_klanim(request_generation: int, clan_value: Dictionary, data: Dictionary) -> void:
	_clan_label(GlobalState.clan_name, Vector2(20, 92), Vector2(280, 28), 17)
	_clan_label("Etiket: %s" % GlobalState.clan_tag, Vector2(300, 92), Vector2(140, 28), 13)

	var member_count := int(clan_value.get("member_count", 0))
	var max_members := int(clan_value.get("max_members", 50))
	_clan_label("Lider: %s" % str(clan_value.get("leader_username", "")), Vector2(20, 122), Vector2(200, 24), 12)
	_clan_label("Üye: %d / %d" % [member_count, max_members], Vector2(20, 146), Vector2(200, 24), 12)

	var company := str(clan_value.get("company", clan_value.get("corporation", "")))
	_clan_label("Şirket: %s" % company, Vector2(20, 170), Vector2(200, 24), 12)

	var clan_level := int(clan_value.get("level", 0))
	_clan_label("Klan Seviyesi  %d" % clan_level, Vector2(20, 194), Vector2(240, 24), 12)

	var clan_xp := int(clan_value.get("xp", 0))
	_clan_label("Klan XP  %s" % _rank_number(clan_xp), Vector2(20, 218), Vector2(240, 24), 12)

	var clan_honor := int(clan_value.get("honor", 0))
	_clan_label("Klan Onuru  %s" % _rank_number(clan_honor), Vector2(20, 242), Vector2(240, 24), 12)

	_clan_label("ÜYELER", Vector2(20, 268), Vector2(200, 22), 14)
	var y := 290.0
	var members_value = data.get("members", [])
	if members_value is Array:
		for member in members_value.slice(0, 4):
			if not (member is Dictionary):
				continue
			var nick := str(member.get("nickname", member.get("username", "")))
			var role := str(member.get("role_name", "Üye"))
			var last_seen := float(member.get("last_seen", 0.0))
			var online := "Çevrimiçi" if last_seen > Time.get_unix_time_from_system() - 10.0 else "Çevrimdışı"
			_clan_label("%s  %s  %s" % [nick, role, online], Vector2(20, y), Vector2(380, 22), 12)
			y += 22.0

	_clan_label("KLAN BİLGİLERİ", Vector2(400, 268), Vector2(200, 22), 14)
	var desc := str(clan_value.get("description", ""))
	_clan_label("Açıklama: %s" % desc, Vector2(400, 290), Vector2(500, 22), 12)
	_clan_label("Klan seviyesi: %d" % clan_level, Vector2(400, 312), Vector2(250, 22), 12)
	_clan_label("Üye sayısı: %d / %d" % [member_count, max_members], Vector2(650, 312), Vector2(250, 22), 12)
	_clan_label("Şirket: %s" % company, Vector2(400, 334), Vector2(500, 22), 12)

	_clan_label("KLAN SOHBETİ / SON AKTİVİTELER", Vector2(20, 358), Vector2(880, 20), 14)
	var message_edit := LineEdit.new()
	message_edit.name = "ClaNV1Message"
	message_edit.set_meta("novagate_section_dynamic", true)
	message_edit.placeholder_text = "Klan mesaji..."
	message_edit.position = Vector2(20, 380)
	message_edit.size = Vector2(460, 30)
	section_content_panel.add_child(message_edit)
	_clan_button("GÖNDER", Vector2(490, 380), Vector2(110, 30), func():
		await GlobalState.send_clan_message(message_edit.text)
		if _section_request_is_current(request_generation, "KLAN"):
			_show_clan_system(request_generation)
	)
	if GlobalState.clan_role != "Lider":
		_clan_button("KLANDAn AYRIL", Vector2(790, 380), Vector2(140, 30), func():
			await GlobalState.leave_clan()
			if _section_request_is_current(request_generation, "KLAN"):
				_show_clan_system(request_generation)
		)

func _clear_section_dynamic_now() -> void:
	if section_content_panel == null:
		return

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
			or node_name.begins_with("ClaNV2")
			or node_name.begins_with("QuestSystem")
			or node_name == "SkillTreeContainer"
			or node_name == "SettingsScreen"
			or node_name == "PazarScreen"
			or node_name.begins_with("Logbook")
		):
			child.hide()
			child.queue_free()

func _show_section(section_name: String) -> void:
	print("AÇILAn MEnÜ:", section_name)
	# Her yeni menü tıklaması önceki Klan/İstatistik async isteklerini geçersiz kılar.
	_menu_section_generation += 1
	_active_menu_section = section_name.to_upper()
	var request_generation: int = _menu_section_generation

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
		# "BİLGİ" butonu kaldırıldı; ana ekrana dönüş her zaman bu yoldan
		# yapılır (footer CTA + dashboard kartları).
		"BİLGİ", "BILGI", "ANA EKRAN":
			_show_main_menu()
		"YETENEK AĞACI":
			open_skill_tree()
		"EKİPMAN":
			section_body_label.text = "EKİPMANNGemi, lazer, kalkan, jeneratör ve ekipman yönetimi burada gösterilecek."
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
		"SEYİR DEFTERİ":
			_show_logbook_section()
		"KLAN":
			_active_menu_section = "KLAN"
			_clan_active_tab = 0
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
			section_body_label.visible = false
			var sn := NovaGateSettingsScreen.new()
			sn.name = "SettingsScreen"
			section_content_panel.add_child(sn)
		"PAZAR":
			_show_pazar_screen()
		_:
			section_body_label.text = section_name + "NBu bölüm hazırlanıyor."

func _used_pilot_points() -> int:
	return clampi(GlobalState.pilot_points_spent(), 0, 30)


func _logbook_category_label(category: String) -> String:
	match category.to_upper():
		"COMBAT":
			return "SAVAŞ"
		"REWARD", "ECONOMY", "MARKET":
			return "EKONOMİ"
		"NPC":
			return "NPC"
		"QUEST":
			return "GÖREV"
		"PLAYER", "SOCIAL":
			return "OYUNCU"
		"SYSTEM":
			return "SİSTEM"
	return category.to_upper()

# İstenen kategori listesi: TÜMÜ / SAVAŞ / EKONOMİ / NPC / GÖREV / OYUNCU
# (+ SİSTEM kayıtlarını da yalnız TÜMÜ altında görebilmek için eklenir).
const LOGBOOK_FILTERS: Array = ["TÜMÜ", "SAVAŞ", "EKONOMİ", "NPC", "GÖREV", "OYUNCU", "SİSTEM"]

func _logbook_category_color(category: String) -> Color:
	match category:
		"SAVAŞ":
			return Color(0.98, 0.45, 0.42)
		"EKONOMİ":
			return Color(0.45, 0.95, 0.70)
		"NPC":
			return Color(0.98, 0.78, 0.35)
		"GÖREV":
			return Color(0.62, 0.80, 1.0)
		"OYUNCU":
			return Color(0.85, 0.65, 1.0)
	return NovaGateUITheme.PRIMARY

# DarkOrbit / WarUniverse tarzı zaman damgası: "2026-01-02T03:04:05" -> "03:04:05"
func _logbook_time_text(raw_timestamp: String) -> String:
	var text := raw_timestamp.replace("T", " ")
	if text.length() >= 19:
		return text.substr(11, 8)
	if text.length() >= 16:
		return text.substr(11, 5)
	return text

func _show_logbook_section() -> void:
	if section_content_panel == null:
		return
	_clear_section_dynamic_now()
	section_body_label.visible = false
	_logbook_filter_buttons.clear()
	_logbook_filter = "TÜMÜ"
	var root := VBoxContainer.new()
	root.name = "LogbookRoot"
	root.set_meta("novagate_section_dynamic", true)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 20.0
	root.offset_top = 18.0
	root.offset_right = -20.0
	root.offset_bottom = -18.0
	root.add_theme_constant_override("separation", 8)
	section_content_panel.add_child(root)

	var title := Label.new()
	title.name = "LogbookTitle"
	title.text = "SEYİR DEFTERİ"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", NovaGateUITheme.PRIMARY)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.name = "LogbookSubtitle"
	subtitle.text = "Son %d olay • en yeni üstte" % GlobalState.LOGBOOK_MAX_ENTRIES
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", NovaGateUITheme.DIM)
	root.add_child(subtitle)

	var filters := HFlowContainer.new()
	filters.name = "LogbookFilters"
	filters.add_theme_constant_override("h_separation", 5)
	filters.add_theme_constant_override("v_separation", 5)
	root.add_child(filters)
	for filter_name in LOGBOOK_FILTERS:
		var filter_button := Button.new()
		filter_button.name = "LogbookFilter_" + str(filter_name)
		filter_button.text = str(filter_name)
		filter_button.custom_minimum_size = Vector2(96, 32)
		filter_button.add_theme_font_size_override("font_size", 11)
		filter_button.focus_mode = Control.FOCUS_NONE
		filter_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		filter_button.pressed.connect(_set_logbook_filter.bind(str(filter_name)))
		filters.add_child(filter_button)
		_logbook_filter_buttons[str(filter_name)] = filter_button

	var header := HBoxContainer.new()
	header.name = "LogbookHeader"
	header.add_theme_constant_override("separation", 8)
	root.add_child(header)
	var logbook_width := maxf(320.0, section_content_panel.size.x - 40.0)
	for column in [["SAAT", 0.12], ["TÜR", 0.16], ["OLAY", 0.72]]:
		var label := Label.new()
		label.text = str(column[0])
		label.custom_minimum_size.x = logbook_width * float(column[1])
		label.add_theme_font_size_override("font_size", 11)
		label.add_theme_color_override("font_color", NovaGateUITheme.DIM)
		header.add_child(label)

	_logbook_scroll = ScrollContainer.new()
	_logbook_scroll.name = "LogbookScroll"
	_logbook_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_logbook_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_logbook_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_logbook_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	root.add_child(_logbook_scroll)
	_logbook_rows = VBoxContainer.new()
	_logbook_rows.name = "LogbookRows"
	_logbook_rows.custom_minimum_size = Vector2(logbook_width, 0)
	_logbook_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_logbook_rows.add_theme_constant_override("separation", 3)
	_logbook_scroll.add_child(_logbook_rows)
	_refresh_logbook_section()

func _set_logbook_filter(filter_name: String) -> void:
	_logbook_filter = filter_name
	_refresh_logbook_section()

func _refresh_logbook_section() -> void:
	_refresh_logbook_card()
	if _logbook_rows == null or not is_instance_valid(_logbook_rows):
		return
	var logbook_width := maxf(320.0, section_content_panel.size.x - 40.0)
	for filter_name in _logbook_filter_buttons.keys():
		var button: Button = _logbook_filter_buttons[filter_name]
		if is_instance_valid(button):
			var selected := str(filter_name) == _logbook_filter
			button.add_theme_stylebox_override("normal", _panel_style(
				NovaGateUITheme.PANEL_FILL_SELECTED if selected else NovaGateUITheme.PANEL_FILL,
				NovaGateUITheme.PRIMARY if selected else Color(NovaGateUITheme.SECONDARY, 0.45),
				2 if selected else 1, 5))
	for child in _logbook_rows.get_children():
		child.queue_free()
	# GlobalState.logbook en yeniden en eskiye sıralıdır; kapasitenin tamamı
	# listelenir (çok sayıda kayıt).
	var shown := 0
	for entry in GlobalState.logbook:
		if shown >= GlobalState.LOGBOOK_MAX_ENTRIES:
			break
		if not entry is Dictionary:
			continue
		var stored_category := str(entry.get("category", "")).to_upper()
		var category := _logbook_category_label(stored_category)
		if _logbook_filter != "TÜMÜ" and category != _logbook_filter:
			continue
		shown += 1
		# Satır yüksekliği sabit 28 px: uzun metin TEK satırda kalır ve
		# taşarsa "..." ile kırpılır (harf harf alt alta yazılmaz).
		var row := PanelContainer.new()
		row.name = "LogbookRow"
		row.custom_minimum_size = Vector2(logbook_width, 28)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_stylebox_override("panel", _panel_style(Color(0.008, 0.02, 0.032, 0.9), Color(0.08, 0.32, 0.45, 0.45), 1, 4))
		_logbook_rows.add_child(row)
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 8)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(line)
		var message := str(entry.get("message", ""))
		var values := [
			_logbook_time_text(str(entry.get("timestamp", ""))),
			category,
			message,
		]
		for i in range(3):
			var label := Label.new()
			label.text = str(values[i])
			label.custom_minimum_size.x = logbook_width * [0.12, 0.16, 0.72][i]
			label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			label.add_theme_font_size_override("font_size", 12)
			label.add_theme_color_override("font_color",
				_logbook_category_color(category) if i == 1 else Color(0.82, 0.9, 0.96))
			label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			if i == 2:
				label.tooltip_text = "%s  %s\n%s" % [values[0], category, message]
			line.add_child(label)


# Ana ekrandaki SEYİR DEFTERİ kartı: son 6 kaydı gösterir ve tıklanınca
# tam Seyir Defteri ekranını açar. Kontrol Paneli'nde ikinci bir buton yok.
func _refresh_logbook_card() -> void:
	if _logbook_card_label == null or not is_instance_valid(_logbook_card_label):
		return
	if GlobalState.logbook.is_empty():
		_logbook_card_label.text = "Henüz kayıt yok.\nTümünü aç ▸"
		return
	var lines: Array[String] = []
	for i in range(mini(6, GlobalState.logbook.size())):
		var entry = GlobalState.logbook[i]
		if not entry is Dictionary:
			continue
		lines.append("%s  %s" % [
			_logbook_time_text(str(entry.get("timestamp", ""))),
			str(entry.get("message", "")),
		])
	_logbook_card_label.text = "\n".join(lines) + "\n▸ TÜM KAYITLARI AÇ"


func _available_pilot_points() -> int:
	return clampi(GlobalState.pilot_points_available(), 0, 30)

func _next_cost_log_disks() -> int:
	return int(GlobalState.pilot_point_progress().get("next_cost", 0))

func open_skill_tree(refresh_from_server: bool = true) -> void:
	if section_content_panel == null:
		return

	_clear_section_dynamic_now()
	section_body_label.visible = false
	var skill_container := PanelContainer.new()
	skill_container.name = "SkillTreeContainer"
	skill_container.custom_minimum_size = section_content_panel.size
	skill_container.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
	skill_container.add_theme_constant_override("panel_corner_radius", 8)
	section_content_panel.add_child(skill_container)
	var scroll := ScrollContainer.new()
	scroll.name = "SkillTreeScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	skill_container.add_child(scroll)
	var canvas := Control.new()
	canvas.name = "SkillTreeCanvas"
	canvas.clip_contents = true
	canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	canvas.anchor_right = 1.0
	canvas.anchor_bottom = 1.0
	canvas.offset_right = 0.0
	canvas.offset_bottom = 0.0
	scroll.add_child(canvas)
	var link := NovaGateSkillLink.new()
	link.name = "SkillTreeLink"
	link.position = Vector2.ZERO
	link.size = skill_container.custom_minimum_size
	link.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(link)
	var top_vbox := VBoxContainer.new()
	top_vbox.name = "SkillTreeTop"
	top_vbox.position = Vector2(24, 18)
	top_vbox.size = Vector2(860, 56)
	top_vbox.add_theme_constant_override("separation", 4)
	canvas.add_child(top_vbox)
	var title := Label.new()
	title.text = "YETENEK AĞACI"
	NovaGateUITheme.title_label(title, 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top_vbox.add_child(title)
	var used := 30 - int(GlobalState.skill_points)
	var info := Label.new()
	info.text = "LOG DISK: %s\\n\\nSONRAKİ PİLOT PUANI\\n%s / %s\\n\\nPİLOT PUANI\\n%s / 30\\n\\nKULLANILAN\\n%s\\n\\nKALAN\\n%s" % [



		_format_number(int(GlobalState.log_disks)),
		_format_number(int(GlobalState.log_disks)),
		str(_next_cost_log_disks()),
		str(_available_pilot_points()),
		str(_used_pilot_points()),
		str(30 - _used_pilot_points())
	]
	NovaGateUITheme.dim_label(info, 14)
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
	canvas.custom_minimum_size = Vector2(start_x + 3.0 * (node_w + gap), row_y1 + float(ceili(float(skills.size()) / 3.0)) * (node_h + gap))
	for idx in range(skills.size()):
		var skill: Dictionary = skills[idx]
		var skill_id := str(skill["id"])
		var skill_name := str(skill["name"])
		var current_level := int(GlobalState.get_skill_level(skill_id))
		var maxed := current_level >= 5
		var disabled := false
		if not maxed and GlobalState.skill_points >= 30:
			disabled = true
		var icon_path := "res://assets/equipment/" + skill_id + ".png"
		var icon_tex: Texture2D = null
		if ResourceLoader.exists(icon_path):
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
			node.add_theme_stylebox_override("panel", NovaGateUITheme.skill_maxed())
		elif disabled:
			node.add_theme_stylebox_override("panel", NovaGateUITheme.skill_available())
		else:
			node.add_theme_stylebox_override("panel", NovaGateUITheme.skill_upgradeable())
		node.add_theme_constant_override("panel_corner_radius", 10)
		if not maxed and not disabled:
			node.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		node.set_anchors_preset(Control.PRESET_TOP_LEFT)
		node.offset_left = nx
		node.offset_top = ny
		node.offset_right = nx + node_w
		node.offset_bottom = ny + node_h
		var inner := VBoxContainer.new()
		inner.name = "SkillnodeInner"
		inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
		inner.add_theme_constant_override("separation", 2)
		node.add_child(inner)
		var icon_rect := TextureRect.new()
		icon_rect.name = "SkillIcon"
		icon_rect.size = Vector2(48, 48)
		icon_rect.custom_minimum_size = Vector2(48, 48)
		icon_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		if icon_tex != null:
			icon_rect.texture = icon_tex
		inner.add_child(icon_rect)
		var name_label := Label.new()
		name_label.text = skill_name
		NovaGateUITheme.title_label(name_label, 14)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner.add_child(name_label)
		var level_label := Label.new()
		level_label.text = "Seviye: %d / 5" % current_level
		NovaGateUITheme.dim_label(level_label, 12)
		level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner.add_child(level_label)
		var progress_hbox := HBoxContainer.new()
		progress_hbox.name = "SkillProgressRow"
		progress_hbox.add_theme_constant_override("separation", 8)
		inner.add_child(progress_hbox)
		var pg_bar := ProgressBar.new()
		pg_bar.name = "SkillProgress"
		pg_bar.max_value = 5.0
		pg_bar.value = float(current_level)
		pg_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pg_bar.custom_minimum_size = Vector2(0, 6)
		pg_bar.add_theme_color_override("tint_progress_color", NovaGateUITheme.PRIMARY)
		pg_bar.add_theme_color_override("tint_background_color", Color(0.12, 0.14, 0.16))
		pg_bar.add_theme_constant_override("tick_count", 0)
		progress_hbox.add_child(pg_bar)
		var cap_label := Label.new()
		cap_label.text = "%d / 5" % current_level
		NovaGateUITheme.dim_label(cap_label, 10)
		cap_label.custom_minimum_size = Vector2(30, 0)
		progress_hbox.add_child(cap_label)
		var action_hbox := HBoxContainer.new()
		action_hbox.name = "SkillActioNRow"
		action_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		action_hbox.add_theme_constant_override("separation", 4)
		inner.add_child(action_hbox)
		if maxed:
			var done := Label.new()
			done.text = "TAMAMLANDI"
			NovaGateUITheme.title_label(done, 12, NovaGateUITheme.GREEN)
			done.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			action_hbox.add_child(done)
		elif disabled:
			var label := Label.new()
			label.text = "30 / 30 PP"
			NovaGateUITheme.dim_label(label, 12)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			action_hbox.add_child(label)
		else:
			var btn := Button.new()
			btn.name = "SkillUpgradeButton"
			btn.text = "YÜKSELT"
			NovaGateUITheme.apply_button(btn)
			btn.add_theme_font_size_override("font_size", 12)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.pressed.connect(_upgrade_skill.bind(skill_id))
			action_hbox.add_child(btn)
		canvas.add_child(node)
		node_panels.append(node)
		node_centers.append(node.position + node.size / 2.0)
		if maxed:
			node_colors.append(Color(NovaGateUITheme.GREEN, 0.9))
		elif disabled:
			node_colors.append(Color(NovaGateUITheme.DIM, 0.6))
		else:
			node_colors.append(NovaGateUITheme.PRIMARY)
	if refresh_from_server:
		_refresh_skill_tree_background()

func _refresh_skill_tree_background() -> void:
	var ok := await GlobalState.refresh_skill_tree_from_server()
	if ok and is_instance_valid(section_content_panel):
		open_skill_tree(false)

func _upgrade_skill(skill_id: String) -> void:
	var result: Dictionary = await GlobalState.upgrade_skill_server(skill_id)
	if not bool(result.get("basarili", false)):
		print("YETENEK YÜKSELTME BAŞARISIZ: ", str(result.get("mesaj", "")))
		return

	var live_player = get_tree().get_first_node_in_group("player")
	if live_player != null and live_player.has_method("refresh_persistent_bonuses"):
		live_player.call("refresh_persistent_bonuses")
	open_skill_tree(false)

func _quit_game() -> void:
	var main := get_node_or_null(main_path)
	if main != null and main.has_method("client_logout_to_login"):
		await main.call("client_logout_to_login")
		return
	if main != null:
		var player := main.get_node_or_null("PlayerShip")
		if player != null:
			var account_manager = load("res://scripts/account_manager.gd").new()
			account_manager.save_player_location(main.current_map_name, player.global_position)
			print("KAYDEDILDI: ", main.current_map_name, " - ", player.global_position)
	get_tree().quit()

func _set_combat_hud_visible(state: bool) -> void:
	var main:=get_node_or_null(main_path)
	if main==null: return

	var hud:=main.get_node_or_null("HUD")
	if hud==null: return

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
	if combat is CanvasItem and mobile_platform: (combat as CanvasItem).visible=false

func _open_menu() -> void:
				_set_combat_hud_visible(false)
				overlay.visible = true
				menu_button.visible = false
				# Ekstra kullandıktan sonra PLT değişimini oyun yenide

				# başlatılmadan anında menüye yansıt.
				refresh_info()
				_show_main_menu()
				get_tree().paused = false

func _close_all() -> void:
				_set_combat_hud_visible(true)
				get_tree().paused = false
				if market_host != null:
								market_host.visible = false
				if section_title_label != null:
								section_title_label.visible = true
				overlay.visible = false
				menu_button.visible = true

func _format_number(value:int) -> String:
				var n := int(value)
				var s := str(abs(n))
				var out := ""
				while s.length() > 3:
								out = "." + s.substr(s.length() - 3, 3) + out
								s = s.substr(0, s.length() - 3)
				out = s + out
				if n < 0:
								out = "-" + out
				return out

func _save_configurations() -> void:
	var account_manager = load("res://scripts/account_manager.gd").new()
	var username: String = account_manager.get_current_player()
	if username == "":
		return

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
	if GlobalState.server_session_active: _queue_server_loadout_sync()

func refresh_info() -> void:
	var info := find_child("PilotInfo", true, false)
	if info == null:
		return
	var panel := info if info is Panel else info.get_parent() as Panel
	if panel != null:
		var all_labels: Array = panel.find_children("", "Label", true, false)
		for lbl in all_labels:
			if lbl is Label:
				match lbl.name:
					"info_level":
						lbl.set_text(str(GlobalState.level))
					"info_xp":
						lbl.set_text(_format_number(GlobalState.xp))
					"info_honor":
						lbl.set_text(str(GlobalState.honor))
					"info_btc":
						lbl.set_text(_format_number(GlobalState.bitcoin))
					"info_plt":
						lbl.set_text(_format_number(GlobalState.platinum))
					"info_cargo":
						lbl.set_text(str(int(GlobalState.log_disks)))

func mobile_toggle_config() -> void:
	_set_config(2 if selected_config == 1 else 1)

func _queue_server_loadout_sync() -> void:
	if not GlobalState.server_session_active or server_loadout_sync_queued: return

	server_loadout_sync_queued=true
	call_deferred("_sync_loadout_to_server")

func _sync_loadout_to_server() -> void:
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
		print("LOADOUT SERVER SYNC HATA: ",result.get("mesaj",""))

func _refresh_available_quests() -> void:
	if _active_menu_section in ["GÖREVLER", "GÖREV"] and section_screen != null and section_screen.visible:
		_show_quest_system()

func _show_quest_system() -> void:
	if section_content_panel == null:
		return

	_clear_section_dynamic_now()
	section_body_label.visible = false
	var root := Control.new()
	root.name = "QuestSystem"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.set_meta("novagate_section_dynamic", true)
	section_content_panel.add_child(root)

	var header := Control.new()
	header.position = Vector2(12, 8)
	header.size = Vector2(884, 72)
	root.add_child(header)
	var brand := Label.new()
	brand.text = "NOVA GATE"
	brand.position = Vector2(2, 0)
	brand.size = Vector2(220, 20)
	brand.add_theme_font_size_override("font_size", 11)
	brand.add_theme_color_override("font_color", Color(0.35, 0.92, 1.0))
	header.add_child(brand)
	var heading := Label.new()
	heading.text = "GÖREV MERKEZİ"
	heading.position = Vector2(0, 18)
	heading.size = Vector2(430, 38)
	heading.add_theme_font_size_override("font_size", 25)
	heading.add_theme_color_override("font_color", Color(0.78, 0.96, 1.0))
	header.add_child(heading)
	var stats := HBoxContainer.new()
	stats.position = Vector2(438, 5)
	stats.size = Vector2(444, 58)
	stats.add_theme_constant_override("separation", 8)
	header.add_child(stats)
	var stat_data := [
		["AKTİF GÖREVLER", "%d / %d" % [QuestSystem.get_active_quests().size(), QuestSystem.MAX_ACTIVE_QUESTS]],
		["SEVİYE", "%d" % GlobalState.level]
	]
	for stat in stat_data:
		var stat_panel := Panel.new()
		stat_panel.custom_minimum_size = Vector2(216, 52)
		var stat_style := _panel_style(Color(0.018, 0.035, 0.055, 0.98), Color(0.12, 0.52, 0.72, 0.75), 1)
		stat_style.set_corner_radius_all(8)
		stat_style.set_content_margin_all(4)
		stat_panel.add_theme_stylebox_override("panel", stat_style)
		stats.add_child(stat_panel)
		var stat_title := Label.new()
		stat_title.text = str(stat[0])
		stat_title.position = Vector2(10, 5)
		stat_title.size = Vector2(196, 15)
		stat_title.add_theme_font_size_override("font_size", 9)
		stat_title.add_theme_color_override("font_color", Color(0.55, 0.72, 0.82))
		stat_panel.add_child(stat_title)
		var stat_value := Label.new()
		stat_value.text = str(stat[1])
		stat_value.position = Vector2(10, 22)
		stat_value.size = Vector2(196, 22)
		stat_value.add_theme_font_size_override("font_size", 17)
		stat_value.add_theme_color_override("font_color", Color(0.45, 0.94, 1.0))
		stat_panel.add_child(stat_value)

	var list_panel := Panel.new()
	list_panel.name = "QuestSystemListPanel"
	list_panel.position = Vector2(12, 86)
	list_panel.size = Vector2(884, 332)
	var list_style := _panel_style(Color(0.012, 0.024, 0.038, 0.98), Color(0.12, 0.48, 0.66, 0.72), 1)
	list_style.set_corner_radius_all(10)
	list_style.set_content_margin_all(0)
	list_panel.add_theme_stylebox_override("panel", list_style)
	root.add_child(list_panel)
	var list_title := Label.new()
	list_title.text = "GÖREV LİSTESİ"
	list_title.position = Vector2(16, 10)
	list_title.size = Vector2(220, 20)
	list_title.add_theme_font_size_override("font_size", 12)
	list_title.add_theme_color_override("font_color", Color(0.48, 0.91, 1.0))
	list_panel.add_child(list_title)
	var list_count := Label.new()
	list_count.text = "%d KAYIT" % QuestSystem.definitions.size()
	list_count.position = Vector2(772, 10)
	list_count.size = Vector2(92, 20)
	list_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	list_count.add_theme_font_size_override("font_size", 10)
	list_count.add_theme_color_override("font_color", Color(0.55, 0.68, 0.76))
	list_panel.add_child(list_count)

	var scroll := ScrollContainer.new()
	scroll.name = "QuestSystemScroll"
	scroll.position = Vector2(10, 38)
	scroll.size = Vector2(864, 284)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.add_theme_constant_override("margin_left", 0)
	scroll.add_theme_constant_override("margin_right", 0)
	scroll.add_theme_constant_override("margin_top", 0)
	scroll.add_theme_constant_override("margin_bottom", 0)
	list_panel.add_child(scroll)
	var list := VBoxContainer.new()
	list.name = "QuestSystemList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 9)
	scroll.add_child(list)
	var available := QuestSystem.get_available_quests()
	if available.is_empty():
		var empty := Label.new()
		empty.text = "Seviyene ve görev zincirine uygun alınabilir görev yok."
		empty.custom_minimum_size = Vector2(840, 72)
		empty.add_theme_font_size_override("font_size", 13)
		empty.add_theme_color_override("font_color", Color(0.62, 0.74, 0.82))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		list.add_child(empty)
	for quest_id_value in available:
		_add_quest_row(list, str(quest_id_value))

func _add_quest_row(parent: VBoxContainer, quest_id: String) -> void:
	var quest := QuestSystem.get_quest(quest_id)
	if quest.is_empty():
		return

	var card := PanelContainer.new()
	card.name = "QuestSystemCard_" + quest_id
	card.custom_minimum_size = Vector2(840, 0)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	parent.add_child(card)
	var card_style := _panel_style(Color(0.022, 0.042, 0.062, 0.98), Color(0.14, 0.62, 0.82, 0.82), 1)
	card_style.set_corner_radius_all(10)
	card_style.set_content_margin_all(13)
	card_style.shadow_color = Color(0.0, 0.55, 0.85, 0.13)
	card_style.shadow_size = 7
	card_style.shadow_offset = Vector2(0, 2)
	card.add_theme_stylebox_override("panel", card_style)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	card.add_child(body)
	var top_row := HBoxContainer.new()
	top_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_theme_constant_override("separation", 9)
	body.add_child(top_row)
	var level_panel := Panel.new()
	level_panel.custom_minimum_size = Vector2(58, 23)
	var level_style := _panel_style(Color(0.035, 0.12, 0.17, 0.98), Color(0.22, 0.86, 1.0, 0.85), 1)
	level_style.set_corner_radius_all(6)
	level_style.set_content_margin_all(3)
	level_panel.add_theme_stylebox_override("panel", level_style)
	top_row.add_child(level_panel)
	var level_label := Label.new()
	level_label.text = "LV %02d" % int(quest.get("level", 1))
	level_label.add_theme_font_size_override("font_size", 10)
	level_label.add_theme_color_override("font_color", Color(0.58, 0.96, 1.0))
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	level_panel.add_child(level_label)
	var title := Label.new()
	title.text = str(quest.get("title", quest_id))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.88, 0.96, 1.0))
	top_row.add_child(title)
	var status_label := Label.new()
	status_label.text = "MEVCUT"
	status_label.custom_minimum_size = Vector2(66, 20)
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	status_label.add_theme_font_size_override("font_size", 9)
	status_label.add_theme_color_override("font_color", Color(0.48, 0.91, 1.0))
	top_row.add_child(status_label)
	var description := Label.new()
	description.text = str(quest.get("description", ""))
	description.custom_minimum_size = Vector2(816, 30)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_font_size_override("font_size", 11)
	description.add_theme_color_override("font_color", Color(0.68, 0.79, 0.86))
	body.add_child(description)
	var progress_row := HBoxContainer.new()
	progress_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_row.add_theme_constant_override("separation", 8)
	body.add_child(progress_row)
	var progress_caption := Label.new()
	progress_caption.text = "İLERLEME"
	progress_caption.custom_minimum_size = Vector2(74, 16)
	progress_caption.add_theme_font_size_override("font_size", 9)
	progress_caption.add_theme_color_override("font_color", Color(0.48, 0.91, 1.0))
	progress_row.add_child(progress_caption)
	var progress := ProgressBar.new()
	progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress.custom_minimum_size = Vector2(0, 8)
	progress.max_value = maxf(float(QuestSystem.get_target(quest_id)), 1.0)
	progress.value = clampf(float(QuestSystem.get_progress(quest_id)), 0.0, progress.max_value)
	progress.show_percentage = false
	var progress_background := StyleBoxFlat.new()
	progress_background.bg_color = Color(0.035, 0.065, 0.09, 0.95)
	progress_background.border_color = Color(0.12, 0.42, 0.58, 0.8)
	progress_background.set_border_width_all(1)
	progress_background.set_corner_radius_all(4)
	progress.add_theme_stylebox_override("background", progress_background)
	var progress_fill := StyleBoxFlat.new()
	progress_fill.bg_color = Color(0.18, 0.82, 1.0, 0.95)
	progress_fill.border_color = Color(0.55, 0.96, 1.0, 1.0)
	progress_fill.set_border_width_all(1)
	progress_fill.set_corner_radius_all(4)
	progress.add_theme_stylebox_override("fill", progress_fill)
	progress_row.add_child(progress)
	var progress_value := Label.new()
	progress_value.text = "%d / %d" % [QuestSystem.get_progress(quest_id), QuestSystem.get_target(quest_id)]
	progress_value.custom_minimum_size = Vector2(72, 16)
	progress_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	progress_value.add_theme_font_size_override("font_size", 10)
	progress_value.add_theme_color_override("font_color", Color(0.62, 0.9, 1.0))
	progress_row.add_child(progress_value)
	var rewards_row := HBoxContainer.new()
	rewards_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rewards_row.add_theme_constant_override("separation", 8)
	body.add_child(rewards_row)
	var rewards_caption := Label.new()
	rewards_caption.text = "ÖDÜLLER"
	rewards_caption.custom_minimum_size = Vector2(74, 16)
	rewards_caption.add_theme_font_size_override("font_size", 9)
	rewards_caption.add_theme_color_override("font_color", Color(0.72, 0.58, 1.0))
	rewards_row.add_child(rewards_caption)
	var rewards := Label.new()
	rewards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rewards.text = _format_quest_rewards(quest.get("rewards", {}))
	rewards.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rewards.add_theme_font_size_override("font_size", 10)
	rewards.add_theme_color_override("font_color", Color(1.0, 0.82, 0.42))
	rewards_row.add_child(rewards)
	var action_row := HBoxContainer.new()
	action_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(action_row)
	var action_spacer := Control.new()
	action_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_row.add_child(action_spacer)
	var accept := Button.new()
	accept.text = "GÖREVİ AL"
	accept.custom_minimum_size = Vector2(128, 34)
	accept.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	accept.add_theme_font_size_override("font_size", 11)
	var accept_style := _panel_style(Color(0.035, 0.12, 0.17, 0.98), Color(0.18, 0.82, 1.0, 0.9), 1)
	accept_style.set_corner_radius_all(8)
	accept_style.set_content_margin_all(4)
	accept.add_theme_stylebox_override("normal", accept_style)
	var accept_hover := _panel_style(Color(0.07, 0.22, 0.29, 1.0), Color(0.55, 0.96, 1.0, 1.0), 1)
	accept_hover.set_corner_radius_all(8)
	accept_hover.set_content_margin_all(4)
	accept.add_theme_stylebox_override("hover", accept_hover)
	accept.pressed.connect(func() -> void:
		accept.disabled = true
		QuestSystem.accept_quest(quest_id)
		_refresh_available_quests.call_deferred()
	)
	action_row.add_child(accept)

func _format_quest_rewards(rewards: Dictionary) -> String:
	var parts: Array[String] = []
	for key in ["btc", "plt", "xp", "honor"]:
		if int(rewards.get(key, 0)) > 0:
			parts.append("+%d %s" % [int(rewards[key]), key.to_upper()])
	for ammo_name in (rewards.get("ammo", {}) as Dictionary).keys():
		parts.append("+%d %s" % [int((rewards["ammo"] as Dictionary)[ammo_name]), str(ammo_name)])
	for item_name in (rewards.get("items", {}) as Dictionary).keys():
		parts.append("+%d %s" % [int((rewards["items"] as Dictionary)[item_name]), str(item_name)])
	return ", ".join(parts) if not parts.is_empty() else "Yok"

# ==========================================================================
# PAZAR (Premium Market) - BOLUM
# Gold kullanilarak premium urunler pazarlandirilir.
# Normal MARKET (BTC/PLT ile oyun ici alisveris) ile ayridir.
# ==========================================================================
const PAZAR_CATEGORIES := ["ÖNE ÇIKAN", "PLT", "VIP", "BTC", "SUPPLY", "ÖZEL"]

const PAZAR_PRODUCTS := {
	"ÖNE ÇIKAN": [
		{"id":"vip30","name":"VIP 30 GÜN","desc":"Tüm VIP avantajları: %10 XP, %10 BTC, özel rozet","price":699,"tag":"EN ÇOK TERCİH EDİLEN"},
		{"id":"plt800k","name":"800.000 PLT","desc":"Premium Platinum cephane","price":3590,"tag":"POPÜLER"},
		{"id":"btc1m","name":"1.000.000 BTC","desc":"Premium Bitcoin cephane","price":679,"tag":"YENİ"},
		{"id":"combat_supply","name":"COMBAT SUPPLY","desc":"Savaş için tam tedarik paketi","price":849,"tag":"HASSAS"},
	],
	"PLT": [
		{"id":"plt30k","name":"30.000 PLT","desc":"Platinum cephane","price":379,"tag":""},
		{"id":"plt100k","name":"100.000 PLT","desc":"Platinum cephane","price":929,"tag":""},
		{"id":"plt250k","name":"250.000 PLT","desc":"Platinum cephane","price":1590,"tag":""},
		{"id":"plt800k","name":"800.000 PLT","desc":"Platinum cephane","price":3590,"tag":""},
	],
	"VIP": [
		{"id":"vip1d","name":"1 GÜN","desc":"VIP geçerlilik: 1 gün","price":85,"tag":""},
		{"id":"vip7d","name":"7 GÜN","desc":"VIP geçerlilik: 7 gün","price":249,"tag":""},
		{"id":"vip30d","name":"30 GÜN","desc":"VIP geçerlilik: 30 gün","price":699,"tag":"EN POPÜLER"},
	],
	"BTC": [
		{"id":"btc100k","name":"100.000 BTC","desc":"Bitcoin cephane","price":85,"tag":""},
		{"id":"btc1m","name":"1.000.000 BTC","desc":"Bitcoin cephane","price":679,"tag":""},
		{"id":"btc10m","name":"10.000.000 BTC","desc":"Bitcoin cephane","price":4990,"tag":""},
	],
	"SUPPLY": [
		{"id":"std_supply","name":"STANDARD SUPPLY","desc":"Standart tedarik paketi","price":749,"tag":""},
		{"id":"combat_supply","name":"COMBAT SUPPLY","desc":"Savaş tedarik paketi","price":849,"tag":""},
		{"id":"rush_supply","name":"RUSH HOUR SUPPLY","desc":"Yoğun saat tedarik paketi","price":949,"tag":""},
	],
	"ÖZEL": [
		{"id":"novacadet","name":"NOVA CADET","desc":"Özel NovaGate program","price":"TBD","tag":""},
		{"id":"novacommander","name":"NOVA COMMANDER","desc":"Özel NovaGate program","price":"TBD","tag":""},
	],
}

func _show_pazar_screen() -> void:
	if section_content_panel == null:
		return
	_clear_section_dynamic_now()
	section_body_label.visible = false
	section_title_label.text = "NOVA GATE • PREMIUM MARKET"
	var root := VBoxContainer.new()
	root.name = "PazarScreen"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	section_content_panel.add_child(root)
	var header := HBoxContainer.new()
	header.name = "PazarHeader"
	header.add_theme_constant_override("separation", 0)
	header.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
	header.custom_minimum_size = Vector2(0, 36)
	root.add_child(header)
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(header_spacer)
	var gold_label := Label.new()
	gold_label.name = "PazarGold"
	gold_label.text = "GOLD BAKİYESİ: %s" % _format_gold(GlobalState.gold)
	gold_label.add_theme_font_size_override("font_size", 20)
	gold_label.add_theme_color_override("font_color", NovaGateUITheme.GOLD)
	header.add_child(gold_label)
	var tab_row := HBoxContainer.new()
	tab_row.name = "PazarTabs"
	tab_row.add_theme_constant_override("separation", 2)
	tab_row.custom_minimum_size = Vector2(0, 34)
	tab_row.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
	for cat in PAZAR_CATEGORIES:
		var btn := Button.new()
		btn.name = "Tab_%s" % cat
		btn.text = cat
		btn.custom_minimum_size = Vector2(0, 28)
		btn.size_flags_horizontal = SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 13)
		btn.add_theme_color_override("font_color", NovaGateUITheme.PRIMARY)
		btn.add_theme_stylebox_override("normal", NovaGateUITheme.panel())
		btn.pressed.connect(_pazar_show_category.bind(cat))
		tab_row.add_child(btn)
	root.add_child(tab_row)
	var separator := Control.new()
	separator.custom_minimum_size = Vector2(0, 1)
	separator.add_theme_color_override("color", NovaGateUITheme.PRIMARY)
	root.add_child(separator)
	var scroll := ScrollContainer.new()
	scroll.name = "PazarScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = SIZE_EXPAND_FILL
	root.add_child(scroll)
	var content_vbox := VBoxContainer.new()
	content_vbox.name = "PazarContent"
	content_vbox.add_theme_constant_override("separation", 8)
	content_vbox.add_theme_constant_override("margin_left", 10)
	content_vbox.add_theme_constant_override("margin_right", 10)
	content_vbox.add_theme_constant_override("margin_top", 10)
	content_vbox.add_theme_constant_override("margin_bottom", 10)
	scroll.add_child(content_vbox)
	var empty_label := Label.new()
	empty_label.name = "PazarEmpty"
	empty_label.text = ""
	empty_label.add_theme_font_size_override("font_size", 14)
	empty_label.add_theme_color_override("font_color", NovaGateUITheme.DIM)
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	empty_label.custom_minimum_size = Vector2(0, 180)
	content_vbox.add_child(empty_label)
	var status_label := Label.new()
	status_label.name = "PazarStatus"
	status_label.text = ""
	status_label.add_theme_font_size_override("font_size", 13)
	status_label.custom_minimum_size = Vector2(0, 22)
	root.add_child(status_label)
	var pay_label := Label.new()
	pay_label.text = "Ödeme sistemi henüz etkin değil."
	pay_label.add_theme_font_size_override("font_size", 12)
	pay_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	pay_label.add_theme_constant_override("margin_left", 10)
	root.add_child(pay_label)
	var buy_label := Label.new()
	buy_label.text = "Satın alma sistemi sonraki aşamada etkinleştirilecek."
	buy_label.add_theme_font_size_override("font_size", 12)
	buy_label.add_theme_color_override("font_color", NovaGateUITheme.DIM)
	buy_label.add_theme_constant_override("margin_left", 10)
	root.add_child(buy_label)

func _pazar_show_category(category: String) -> void:
	var scroll := section_content_panel.find_child("PazarScroll", true) as ScrollContainer
	if scroll == null:
		return
	var content := scroll.find_child("PazarContent", true) as VBoxContainer
	if content == null:
		return
	for child in content.get_children():
		child.queue_free()
	_pazar_populate_category(content, category)

func _pazar_populate_category(content: VBoxContainer, category: String) -> void:
	var products: Array = PAZAR_PRODUCTS.get(category, [])
	var row: HBoxContainer = null
	for i in range(products.size()):
		if i % 3 == 0:
			row = HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			content.add_child(row)
		var card := _pazar_create_card(products[i])
		row.add_child(card)

func _pazar_create_card(product: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(280, 155)
	card.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
	card.add_theme_constant_override("panel_corner_radius", 6)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	card.add_child(vbox)

	if product.has("tag") and not product["tag"].is_empty():
		var tag := Label.new()
		tag.text = product["tag"]
		tag.add_theme_font_size_override("font_size", 10)
		tag.add_theme_color_override("font_color", NovaGateUITheme.GREEN)
		vbox.add_child(tag)

	var name_l := Label.new()
	name_l.text = product["name"]
	name_l.add_theme_font_size_override("font_size", 16)
	name_l.add_theme_color_override("font_color", NovaGateUITheme.PRIMARY)
	vbox.add_child(name_l)

	var desc := Label.new()
	desc.text = str(product["desc"])
	desc.add_theme_font_size_override("font_size", 12)
	desc.add_theme_color_override("font_color", NovaGateUITheme.DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(250, 28)
	vbox.add_child(desc)

	var price_l := Label.new()
	if product["price"] is int:
		price_l.text = "%s GOLD" % _format_gold(product["price"])
	else:
		price_l.text = str(product["price"])
	price_l.add_theme_font_size_override("font_size", 18)
	price_l.add_theme_color_override("font_color", NovaGateUITheme.GOLD)
	vbox.add_child(price_l)

	var buy_btn := Button.new()
	buy_btn.text = "SATIN AL"
	buy_btn.custom_minimum_size = Vector2(130, 28)
	buy_btn.add_theme_font_size_override("font_size", 13)
	buy_btn.pressed.connect(_pazar_buy_pressed.bind(product))
	vbox.add_child(buy_btn)

	return card

func _pazar_buy_pressed(product: Dictionary) -> void:
	var status := section_content_panel.find_child("PazarStatus", true) as Label
	if product["price"] is int:
		var price: int = product["price"]
		if GlobalState.gold >= price:
			GlobalState.gold -= price
			var product_name := str(product["name"])
			GlobalState.add_logbook_entry("ECONOMY", "%s satın alındı" % product_name, product_name)
			GlobalState.add_logbook_entry("ECONOMY", "-%s GOLD" % _format_gold(price), product_name)
			if status != null:
				status.text = "%s satın alındı! -%s GOLD" % [product["name"], _format_gold(price)]
				status.add_theme_color_override("font_color", NovaGateUITheme.GREEN)
			var gold_lbl := section_content_panel.find_child("PazarGold", true) as Label
			if gold_lbl != null:
				gold_lbl.text = "GOLD BAKİYESİ: %s" % _format_gold(GlobalState.gold)
			print("PAZAR SATIN ALINDI: %s -%d GOLD" % [product["name"], price])
		else:
			if status != null:
				status.text = "Yeterli GOLD yok! Gereken: %s, Mevcut: %s" % [_format_gold(price), _format_gold(GlobalState.gold)]
				status.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	else:
		if status != null:
			status.text = "Satın alma sistemi sonraki aşamada etkinleştirilecek."
			status.add_theme_color_override("font_color", NovaGateUITheme.DIM)

func _format_gold(amount: int) -> String:
	var n := int(amount)
	var s := str(abs(n))
	var out := ""
	while s.length() > 3:
		out = "." + s.substr(s.length() - 3, 3) + out
		s = s.substr(0, s.length() - 3)
	out = s + out
	if n < 0:
		out = "-" + out
	return out

func _online_status_text() -> String:
	return "ÇEVRİMİÇİ"

func _pilot_short_text() -> String:
	return str(GlobalState.player_id) if GlobalState.player_id != "" else "PILOT"

func _vip_status_text() -> String:
	return "VIP" if GlobalState.vip_expire_timestamp > int(Time.get_unix_time_from_system()) else "STANDART"

func _active_ship_label() -> String:
	return GlobalState.ship_name if GlobalState.ship_name != "" else "AKTİF GEMİ"

func _hp_value() -> String:
	return str(int(GlobalState.saved_hp)) if GlobalState.saved_hp >= 0 else "0"

func _hp_max() -> String:
	if player != null:
		var mh = player.get("max_health")
		if typeof(mh) != TYPE_NIL:
			return str(int(mh))
	return "100"

func _shield_value() -> String:
	return str(int(GlobalState.saved_shield)) if GlobalState.saved_shield >= 0 else "0"

func _shield_max() -> String:
	if player != null:
		var ms = player.get("max_shield")
		if typeof(ms) != TYPE_NIL:
			return str(int(ms))
	return "100"

func _speed_text() -> String:
	var speed_bonus := 0
	var config: Dictionary = configurations.get(selected_config, {})
	if config.has("generators"):
		var generators: Array = config["generators"]
		var gen_limit := _ship_slot_limit("generator")
		for i in range(mini(gen_limit, generators.size())):
			var item = generators[i]
			if item != null and str(item) != "" and ITEM_DATA.has(str(item)):
				speed_bonus += int(ITEM_DATA[str(item)].get("speed", 0))
	if active_ship_data.is_empty():
		active_ship_data = _get_ship_data(active_ship_id)
	return str(int(active_ship_data.get("speed", 320)) + speed_bonus)

func _damage_text() -> String:
	var damage := 0
	var config: Dictionary = configurations.get(selected_config, {})
	if config.has("lasers"):
		var lasers: Array = config["lasers"]
		var laser_limit := _ship_slot_limit("laser")
		for i in range(mini(laser_limit, lasers.size())):
			var item = lasers[i]
			if item != null and str(item) != "" and ITEM_DATA.has(str(item)):
				damage += int(ITEM_DATA[str(item)].get("damage", 0))
	return str(damage)

func _rank_text() -> String:
	return GlobalState.rank_title if GlobalState.rank_title != "" else "NOVAPIMPLE"

func _pilot_name_text() -> String:
	return GlobalState.company if GlobalState.company != "" else "PİLOT"

func _map_text() -> String:
	return GlobalState.start_map if GlobalState.start_map != "" else "BİLİNMİYOR"

func _coord_text_x() -> String:
	if player != null:
		var pos = player.get("global_position")
		if typeof(pos) == TYPE_VECTOR2:
			return str(int(pos.x))
	return str(int(GlobalState.server_pos_x))

func _coord_text_y() -> String:
	if player != null:
		var pos = player.get("global_position")
		if typeof(pos) == TYPE_VECTOR2:
			return str(int(pos.y))
	return str(int(GlobalState.server_pos_y))

func _syslog_text() -> String:
	return "[12:45] NovaGate Kontrol Paneli yüklendi.\n[12:46] Sistem bağlantısı sağlandı.\n[12:50] Kontrol paneli hazır."

func _hud_block(title_text: String, value_text: String, emphasize: bool = false) -> Panel:
	var block := Panel.new()
	block.custom_minimum_size = Vector2(72, 56)
	block.add_theme_stylebox_override("panel", _panel_style(Color(0.012, 0.018, 0.028, 1.0), Color(0.08, 0.6, 0.78, 0.35), 1))
	block.add_theme_constant_override("corner_radius_all", 5)
	var inner := VBoxContainer.new()
	inner.position = Vector2(4, 4)
	inner.size = Vector2(block.size.x - 8, block.size.y - 8)
	inner.add_theme_constant_override("separation", 2)
	block.add_child(inner)
	var label := Label.new()
	label.text = title_text
	label.size = Vector2(inner.size.x, 14)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 8)
	label.add_theme_color_override("font_color", NovaGateUITheme.DIM)
	inner.add_child(label)
	var value := Label.new()
	value.text = value_text
	value.size = Vector2(inner.size.x, 22)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", 13 if emphasize else 12)
	value.add_theme_color_override("font_color", NovaGateUITheme.PRIMARY if emphasize else Color(0.85, 0.95, 1.0))
	inner.add_child(value)
	return block


func _nav_button(text_value: String) -> Button:
	var b := Button.new()
	b.text = text_value
	b.custom_minimum_size = Vector2(196, 34)
	b.add_theme_stylebox_override("normal", _panel_style(Color(0.02, 0.03, 0.042, 1.0), Color(0.06, 0.5, 0.66, 0.3), 1))
	b.add_theme_stylebox_override("hover", _panel_style(Color(0.04, 0.06, 0.08, 1.0), Color(0.15, 0.85, 1.0, 0.85), 2))
	b.add_theme_stylebox_override("pressed", _panel_style(Color(0.05, 0.08, 0.11, 1.0), Color(0.25, 0.95, 1.0, 1.0), 2))
	b.add_theme_constant_override("corner_radius_all", 5)
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", Color(0.7, 0.85, 0.98))
	b.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	b.add_theme_color_override("font_pressed_color", Color(1.0, 1.0, 1.0))
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	return b


func _pilot_row(label_text: String, value_text: String, value_right: bool, height: int) -> Panel:
	var row := Panel.new()
	row.custom_minimum_size = Vector2(336, height)
	row.add_theme_stylebox_override("panel", _panel_style(Color(0.02, 0.03, 0.044, 1.0), Color(0.05, 0.42, 0.56, 0.3), 1))
	row.add_theme_constant_override("corner_radius_all", 4)
	var inner := HBoxContainer.new()
	inner.position = Vector2(6, 4)
	inner.size = Vector2(row.size.x - 12, row.size.y - 8)
	inner.add_theme_constant_override("separation", 6)
	row.add_child(inner)
	var label := Label.new()
	label.text = label_text
	label.size = Vector2(120, inner.size.y)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", NovaGateUITheme.DIM)
	inner.add_child(label)
	var value := Label.new()
	value.name = "pilot_value"
	value.text = value_text
	value.size = Vector2(inner.size.x - 120, inner.size.y)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT if value_right else HORIZONTAL_ALIGNMENT_LEFT
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", 12)
	value.add_theme_color_override("font_color", Color(0.9, 0.97, 1.0))
	inner.add_child(value)
	return row

func _status_block(title_text: String, value_text: String, max_text: String, accent_color: Color) -> Panel:
	var block := Panel.new()
	block.custom_minimum_size = Vector2(130, 92)
	block.add_theme_stylebox_override("panel", _panel_style(Color(0.014, 0.022, 0.032, 1.0), accent_color, 1))
	block.add_theme_constant_override("corner_radius_all", 6)
	var inner := VBoxContainer.new()
	inner.position = Vector2(4, 4)
	inner.size = Vector2(block.size.x - 8, block.size.y - 8)
	inner.add_theme_constant_override("separation", 4)
	block.add_child(inner)
	var label := Label.new()
	label.text = title_text
	label.size = Vector2(inner.size.x, 16)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", NovaGateUITheme.DIM)
	inner.add_child(label)
	var value := Label.new()
	value.text = value_text
	value.size = Vector2(inner.size.x, 18)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", 14)
	value.add_theme_color_override("font_color", accent_color)
	inner.add_child(value)
	if max_text != "":
		var maxlabel := Label.new()
		maxlabel.text = "MAX " + max_text
		maxlabel.size = Vector2(inner.size.x, 12)
		maxlabel.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		maxlabel.add_theme_font_size_override("font_size", 8)
		maxlabel.add_theme_color_override("font_color", Color(0.55, 0.7, 0.85))
		inner.add_child(maxlabel)
	var bar := ColorRect.new()
	bar.position = Vector2(8, inner.position.y + inner.size.y + 2)
	bar.size = Vector2(block.size.x - 16, 6)
	bar.color = Color(0.12, 0.18, 0.24, 1.0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	block.add_child(bar)
	return block


func _info_badge(title_text: String, value_text: String, value_name: String) -> Panel:
	var badge := Panel.new()
	badge.custom_minimum_size = Vector2(54, 54)
	badge.add_theme_stylebox_override("panel", _panel_style(Color(0.016, 0.026, 0.04, 1.0), Color(0.08, 0.62, 0.82, 0.35), 1))
	badge.add_theme_constant_override("corner_radius_all", 5)
	var inner := VBoxContainer.new()
	inner.position = Vector2(4, 4)
	inner.size = Vector2(badge.size.x - 8, badge.size.y - 8)
	inner.add_theme_constant_override("separation", 2)
	badge.add_child(inner)
	var label := Label.new()
	label.text = title_text
	label.size = Vector2(inner.size.x, 16)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 8)
	label.add_theme_color_override("font_color", NovaGateUITheme.DIM)
	inner.add_child(label)
	var value := Label.new()
	value.name = value_name
	value.text = value_text
	value.size = Vector2(inner.size.x, 18)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", 13)
	value.add_theme_color_override("font_color", Color(0.9, 0.96, 1.0))
	inner.add_child(value)
	return badge


func _tune_card(card: Panel, min_width: float = 200.0, v_stretch: float = 0.45) -> void:
	card.custom_minimum_size = Vector2(min_width, 180)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if v_stretch > 0.0:
		card.size_flags_stretch_ratio = v_stretch
	var inner_box := card.get_child(0) as VBoxContainer
	if inner_box != null:
		inner_box.set_anchors_preset(Control.PRESET_FULL_RECT)
		inner_box.offset_left = 6
		inner_box.offset_top = 6
		inner_box.offset_right = -6
		inner_box.offset_bottom = -6
		var title_label := inner_box.get_child(0) as Label
		if title_label != null:
			title_label.add_theme_font_size_override("font_size", 13)
			title_label.custom_minimum_size = Vector2(0, 20)
		var scroll := inner_box.get_child(1) as ScrollContainer
		if scroll != null:
			scroll.custom_minimum_size = Vector2(0, 70)
			scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
			scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
			var content_label := scroll.get_child(0) as Label
			if content_label != null:
				content_label.add_theme_font_size_override("font_size", 12)
				content_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
				content_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP


func _section_card(title_text: String, content_text: String, two_column: bool = false, full_width: bool = false) -> Panel:
	var card := Panel.new()
	if full_width:
		card.custom_minimum_size = Vector2(336, 100)
	else:
		card.custom_minimum_size = Vector2(158, 100)
	card.add_theme_stylebox_override("panel", _panel_style(Color(0.014, 0.022, 0.034, 1.0), Color(0.07, 0.55, 0.72, 0.35), 1))
	card.add_theme_constant_override("corner_radius_all", 6)
	var inner := VBoxContainer.new()
	inner.position = Vector2(6, 6)
	inner.size = Vector2(card.size.x - 12, card.size.y - 12)
	inner.add_theme_constant_override("separation", 4)
	card.add_child(inner)
	var title := Label.new()
	title.text = title_text
	title.custom_minimum_size = Vector2(inner.size.x, 18)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", NovaGateUITheme.PRIMARY)
	inner.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(inner.size.x, 52)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.add_theme_stylebox_override("panel", _panel_style(Color(0.008, 0.014, 0.022, 1.0), Color(0.0, 0.0, 0.0, 0.0), 0))
	inner.add_child(scroll)
	var content := Label.new()
	content.name = "CardContent"
	content.text = content_text
	content.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	content.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_theme_font_size_override("font_size", 10)
	content.add_theme_color_override("font_color", Color(0.55, 0.7, 0.85))
	content.add_theme_color_override("font_underline_color", Color(0.0, 0.0, 0.0, 0.0))
	scroll.add_child(content)
	return card

# Bir dashboard kartının tamamını tıklanabilir yapar (şeffaf buton kaplaması).
# Panel API'si değişmez, diğer kartlar etkilenmez.
func _make_card_clickable(card: Panel, callback: Callable, tooltip: String = "") -> void:
	if card == null or not is_instance_valid(card) or not callback.is_valid():
		return
	var hit := Button.new()
	hit.name = "CardHit"
	hit.flat = true
	hit.focus_mode = Control.FOCUS_NONE
	hit.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	hit.tooltip_text = tooltip
	hit.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hit.pressed.connect(callback)
	card.add_child(hit)


func _quick_card(title_text: String, subtitle_text: String, hint_text: String) -> Panel:
	var card := Panel.new()
	card.custom_minimum_size = Vector2(150, 68)
	card.add_theme_stylebox_override("panel", _panel_style(Color(0.014, 0.022, 0.034, 1.0), Color(0.06, 0.5, 0.68, 0.35), 1))
	card.add_theme_constant_override("corner_radius_all", 6)
	var inner := VBoxContainer.new()
	inner.position = Vector2(6, 6)
	inner.size = Vector2(card.size.x - 12, card.size.y - 12)
	inner.add_theme_constant_override("separation", 2)
	card.add_child(inner)
	var icon := TextureRect.new()
	icon.texture = load("res://assets/ship.svg")
	icon.size = Vector2(22, 22)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(icon)
	var title := Label.new()
	title.text = title_text
	title.size = Vector2(inner.size.x, 18)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", NovaGateUITheme.PRIMARY)
	inner.add_child(title)
	var sub := Label.new()
	sub.text = subtitle_text
	sub.size = Vector2(inner.size.x, 14)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	sub.add_theme_font_size_override("font_size", 9)
	sub.add_theme_color_override("font_color", Color(0.55, 0.7, 0.85))
	inner.add_child(sub)
	var hint := Label.new()
	hint.text = hint_text
	hint.size = Vector2(inner.size.x, 12)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	hint.add_theme_font_size_override("font_size", 8)
	hint.add_theme_color_override("font_color", Color(0.35, 0.5, 0.65))
	inner.add_child(hint)
	var arrow := Label.new()
	arrow.text = "›"
	arrow.size = Vector2(12, inner.size.y)
	arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	arrow.add_theme_font_size_override("font_size", 16)
	arrow.add_theme_color_override("font_color", Color(0.5, 0.8, 0.95))
	inner.add_child(arrow)
	return card

func _cta_button() -> Button:
	var b := Button.new()
	b.text = "DEVAM ET // UZAYA ÇIK  ›"
	b.custom_minimum_size = Vector2(220, 44)
	b.add_theme_stylebox_override("normal", _panel_style(Color(0.02, 0.06, 0.08, 1.0), Color(0.1, 0.85, 1.0, 0.55), 2))
	b.add_theme_stylebox_override("hover", _panel_style(Color(0.06, 0.14, 0.18, 1.0), Color(0.35, 1.0, 1.0, 1.0), 2))
	b.add_theme_stylebox_override("pressed", _panel_style(Color(0.04, 0.1, 0.14, 1.0), Color(0.2, 0.9, 1.0, 0.9), 2))
	b.add_theme_constant_override("corner_radius_all", 10)
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_color_override("font_color", Color(0.95, 1.0, 1.0))
	b.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	b.add_theme_color_override("font_pressed_color", Color(1.0, 1.0, 1.0))
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(_close_all)
	return b
