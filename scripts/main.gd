extends Node2D

var x1_base_position = Vector2(19, -11)
var x6_base_position = Vector2(19,-11)
var last_player_map = "1-1"

const RankBadge = preload("res://scripts/rank_badge.gd")

const MAP_NAMES: Array[String] = [
	"1-1", "1-2", "1-3", "1-4", "1-5", "1-6",
	"2-1", "2-2", "2-3", "2-4", "2-5", "2-6",
	"3-1", "3-2", "3-3", "3-4", "3-5", "3-6",
	"4-5",
	"PVP", "BOSS"
]

const MAP_BACKGROUNDS: Dictionary = {
	# Yeni harita klasör sistemi.
	# 1-1 ilk test: eski map_01.jpg yerine yeni hrta/1-1/bg.jpg.
	"1-1":"res://hrta/1-1/bg.jpg",
	"1-2":"res://hrta/1-2/bg.jpg",
	"1-3":"res://hrta/1-3/bg.jpg",
	"1-4":"res://hrta/1-4/bg.jpg",
	"1-5":"res://hrta/1-5/bg.jpg",
	"1-6":"res://hrta/1-6/bg.jpg",
	"2-1":"res://hrta/2-1/bg.jpg",
	"2-2":"res://hrta/2-2/bg.jpg",
	"2-3":"res://hrta/2-3/bg.jpg",
	"2-4":"res://hrta/2-4/bg.jpg",
	"2-5":"res://hrta/2-5/bg.jpg",
	"2-6":"res://hrta/2-6/bg.jpg",
	"3-1":"res://hrta/3-1/bg.jpg",
	"3-2":"res://hrta/3-2/bg.jpg",
	"3-3":"res://hrta/3-3/bg.jpg",
	"3-4":"res://hrta/3-4/bg.jpg",
	"3-5":"res://hrta/3-5/bg.jpg",
	"3-6":"res://hrta/3-6/bg.jpg",
	"PVP":"res://hrta/PVP/bg.jpg",
	"BOSS":"res://hrta/BOSS/bg.jpg",
	# 4-5 Uber haritası yeni asset kullanmaz: mevcut BOSS arka planı yeniden kullanılır.
	"4-5":"res://hrta/BOSS/bg.jpg"
}

const NPC_SCENE: PackedScene = preload("res://scenes/npc.tscn")
const NPC_LASER_EFFECT_SCENE: PackedScene = preload("res://scenes/npc_laser_effect.tscn")
const PORTAL_TEXTURE: Texture2D = preload("res://assets/m2_tp.png")
const AMMO_NAMES: Array[String] = ["X1", "X2", "X3", "X4", "SAB", "RSB"]
const AMMO_MULTIPLIERS: Array[float] = [1.0, 1.5, 2.25, 3.0, 1.0, 4.0]
const AMMO_COLORS: Array[Color] = [
	Color(1.0, 0.1, 0.12), Color(0.15, 1.0, 0.2), Color(0.12, 0.45, 1.0),
	Color(0.95, 0.95, 1.0), Color(0.0, 0.95, 1.0), Color(1.0, 0.55, 0.05)
]
const AMMO_ICONS: Array[Texture2D] = [
	preload("res://assets/ammo/lammo1.png"), preload("res://assets/ammo/lammo2.png"),
	preload("res://assets/ammo/lammo3.png"), preload("res://assets/ammo/lammo4.png"),
	preload("res://assets/ammo/lammo5.png"), preload("res://assets/ammo/lammo6.png")
]
const LASER_EFFECTS: Array[Texture2D] = [
	preload("res://assets/ammo/laser1.png"), preload("res://assets/ammo/laser2.png"),
	preload("res://assets/ammo/laser3.png"), preload("res://assets/ammo/laser4.png"),
	preload("res://assets/ammo/laser5.png"), preload("res://assets/ammo/laser6.png")
]
const BASE_TEXTURES: Array[Texture2D] = [
	preload("res://assets/queststation_orion.png"),
	preload("res://assets/queststation_solar.png"),
	preload("res://assets/queststation_vega.png")
]
const WORLD_RECT: Rect2 = Rect2(-7000.0, -5000.0, 14000.0, 10000.0)

# NovaGate radyasyon bölgesi
const RADIATION_MAX_PERCENT: float = 0.05
const RADIATION_TICK_SECONDS: float = 1.0
var radiation_time: float = 0.0
var radiation_tick: float = 0.0
var radiation_warning: Label = null
const SAFE_ZONE_RADIUS: float = 330.0
const BASE_SAFE_RADIUS: float = 430.0
const WARP_DURATION: float = 2.0
const PLAYER_LASER_RANGE: float = 550.0
const SAB_SHIELD_FACTOR: float = 2.0
const NPC_LASER_RANGE: float = 490.0
const PLAYER_LASER_PROJECTILE_SPEED: float = 1850.0
const PLAYER_LASER_MIN_TRAVEL_TIME: float = 0.10
const PLAYER_LASER_MAX_TRAVEL_TIME: float = 0.32
# Server-authoritative position reconciliation (online sessions).
# Small drift is eased out; a large one is a real desync and is snapped.
const POSITION_RECONCILE_STRENGTH: float = 0.25
const POSITION_SNAP_THRESHOLD: float = 400.0

# Şablon eşleştirmesi:
# 1-x = U bölgesi, 2-x = E bölgesi, 3-x = R bölgesi, PVP = T-1, BOSS = G-1.
# Şablondaki JVS, JVO ve JSO haritaları kullanılmaz.
const TEMPLATE_NAME: Dictionary = {
	"1-1":"U-1", "1-2":"U-2", "1-3":"U-3", "1-4":"U-5", "1-5":"U-6", "1-6":"U-7",
	"2-1":"E-1", "2-2":"E-2", "2-3":"E-3", "2-4":"E-5", "2-5":"E-6", "2-6":"E-7",
	"3-1":"R-1", "3-2":"R-2", "3-3":"R-3", "3-4":"R-5", "3-5":"R-6", "3-6":"R-7",
	"4-5":"G-2",
	"PVP":"T-1", "BOSS":"G-1"
}

# Gönderilen şablondaki bağlantı ağı. JVS/JVO/JSO bağlantıları dahil edilmemiştir.
const CONNECTIONS: Dictionary = {
	"1-1":["1-2"],
"1-2":["1-1","1-3"],
"1-3":["1-2","PVP"],
"1-4":["PVP","1-5","BOSS","4-5"],
"1-5":["1-4","1-6"],
"1-6":["1-5"],

"2-1":["2-2"],
"2-2":["2-1","2-3"],
"2-3":["2-2","PVP"],
"2-4":["PVP","2-5","BOSS","4-5"],
"2-5":["2-4","2-6"],
"2-6":["2-5"],

"3-1":["3-2"],
"3-2":["3-1","3-3"],
"3-3":["3-2","PVP"],
"3-4":["PVP","3-5","BOSS","4-5"],
"3-5":["3-4","3-6"],
"3-6":["3-5"],

"PVP":["1-3","2-3","3-3","1-4","2-4","3-4"],

# BOSS çıkışları PORTAL_POSITIONS["BOSS"] ile birebir aynıdır.
# BOSS'a giriş seviye 15 şartıyla 1-4/2-4/3-4 üzerinden yapılır;
# çıkış kapıları da 15+ oyuncunun girebileceği 1-5/2-5/3-6 haritalarıdır.
"BOSS":["1-5","2-5","3-6"],

# 4-5: sadece Uber NPC haritası. Cubikon BU haritada spawn OLMAZ.
"4-5":["1-4","2-4","3-4"]
}

# Portal koordinatları, şablondaki kenar/nokta yerleşimine göre elle sabitlenmiştir.
# Dünya ölçüsü 10000x7000 olduğu için kenarlar x=+-4300, y=+-2850 civarındadır.
const PORTAL_POSITIONS: Dictionary = {

"1-1":{
"1-2":Vector2(4300,-3000)
},

"1-2":{
"1-1":Vector2(-4300,3000),
"1-3":Vector2(4300,-3000)
},

"1-3":{
"1-2":Vector2(-4300,-3000),
"PVP":Vector2(4300,3000)
},

"1-4":{
"PVP":Vector2(-4300,3000),
"1-5":Vector2(4300,-3000),
"BOSS":Vector2(-4300,-3000),
"4-5":Vector2(4300,3000)
},

"1-5":{
"1-4":Vector2(-4300,-3000),
"1-6":Vector2(4300,3000),
"BOSS":Vector2(4300,-3000)
},

"1-6":{
"1-5":Vector2(-4300,3000)
},


"2-1":{
"2-2":Vector2(-4300,3000)
},

"2-2":{
"2-1":Vector2(4300,-3000),
"2-3":Vector2(-4300,-3000)
},

"2-3":{
"2-2":Vector2(4300,3000),
"PVP":Vector2(-4300,-3000)
},

"2-4":{
"PVP":Vector2(4300,-3000),
"2-5":Vector2(-4300,3000),
"BOSS":Vector2(4300,3000),
"4-5":Vector2(-4300,-3000)
},

"2-5":{
"2-4":Vector2(-4300,-3000),
"2-6":Vector2(4300,3000)
},

"2-6":{
"2-5":Vector2(-4300,3000)
},


"3-1":{
"3-2":Vector2(4300,-3000)
},

"3-2":{
"3-1":Vector2(-4300,3000),
"3-3":Vector2(4300,3000)
},

"3-3":{
"3-2":Vector2(-4300,-3000),
"PVP":Vector2(4300,3000)
},

"3-4":{
"PVP":Vector2(-4300,3000),
"3-5":Vector2(4300,-3000),
"BOSS":Vector2(-4300,-3000),
"4-5":Vector2(4300,3000)
},

"3-5":{
"3-4":Vector2(-4300,-3000),
"3-6":Vector2(4300,3000)
},

"3-6":{
"3-5":Vector2(-4300,3000)
},



"PVP":{
"1-3":Vector2(0,-4300),
"1-4":Vector2(5200,-3000),
"2-3":Vector2(0,4300),
"2-4":Vector2(5200,3000),
"3-3":Vector2(-5200,3000),
"3-4":Vector2(-5200,-3000)
},


"BOSS":{
	"1-5":Vector2(-4300,3000),
	"2-5":Vector2(4300,-3000),
	"3-6":Vector2(-4300,-3000)
},

"4-5":{
"1-4":Vector2(-4300,3000),
"2-4":Vector2(4300,-3000),
"3-4":Vector2(0,-4300)
}

}



var current_map_name: String = "1-1"

# ==============================
# NOVAGATE BONUS BOX SYSTEM
# Normal X-1..X-6: klasik bonus kutusu ödül havuzu
# BOSS: gizli harita tipi kutu, her kutu 1000 X4
# ==============================
const BONUS_BOX_SCRIPT := preload("res://scripts/bonus_box.gd")
var bonus_box_texture: Texture2D = null
const NORMAL_BONUS_BOX_COUNT: int = 60
const BOSS_BONUS_BOX_COUNT: int = 200
const BONUS_BOX_RESPAWN_MIN: float = 5.0
const BONUS_BOX_RESPAWN_MAX: float = 10.0

var bonus_box_container: Node2D = null
var bonus_box_generation: int = 0
var credits: int = 0
var rng := RandomNumberGenerator.new()
var selected_npc: SpaceNPC = null
var warp_active: bool = false
var warp_time_left: float = 0.0
var pending_destination: String = ""
var active_portals: Array[Area2D] = []
var base_node: Node2D = null
@onready var background: Sprite2D = $Background
@onready var player: PlayerShip = $PlayerShip
@onready var npc_container: Node2D = $World/NPCs
@onready var laser_container: Node2D = $World/Lasers
@onready var portal_container: Node2D = $World/Portals
@onready var base_container: Node2D = $World/Bases
@onready var map_label: Label = $HUD/TopPanel/MapLabel
@onready var coord_label: Label = $HUD/TopPanel/CoordLabel
@onready var ammo_label: Label = $HUD/TopPanel/AmmoLabel
@onready var health_bar: ProgressBar = $HUD/BottomPanel/Health
@onready var shield_bar: ProgressBar = $HUD/BottomPanel/Shield
@onready var warp_panel: Panel = $HUD/WarpPanel
@onready var warp_label: Label = $HUD/WarpPanel/WarpLabel
@onready var minimap: Control = $HUD/Minimap

var death_overlay: ColorRect = null
var death_panel: Panel = null
var repair_button: Button = null
var death_title_label: Label = null
var death_subtitle_label: Label = null
var repair_in_progress: bool = false

# PC savaş HUD: oyuncunun 1-6 tuşlarına istediği lazeri ataması.
var pending_laser_shortcut: String = ""
var laser_shortcut_hint: Label = null
var quest_tracker_panel: Panel = null
var quest_tracker_label: Label = null

# ==============================
# NOVAGATE GALAXY GATE (X1 portali + UI)
# ==============================
const GalaxyGateUI := preload("res://scripts/galaxy_gate_ui.gd")
var galaxy_gate_portal: Area2D = null
var galaxy_gate_ui: Control = null
var galaxy_gate_prompt: Label = null

const LASER_SHORTCUT_BUTTONS := {
	"x1": "RLX-1",
	"x2": "RLX-2",
	"x3": "BLX-3",
	"x4": "WLX-4",
	"SAB": "SAB",
	"RSB": "RSB"
}

const LASER_SHORTCUT_DISPLAY := {
	"RLX-1": "x1",
	"RLX-2": "x2",
	"BLX-3": "x3",
	"WLX-4": "x4",
	"SAB": "SAB",
	"RSB": "RSB"
}

func _ready() -> void:
	_activate_social_profile()
	var map_visuals = get_node_or_null("World/MapVisuals")
	if map_visuals:
		map_visuals.load_map(current_map_name)
	rng.randomize()

	# MMO Core V2: oyuncu sunucu koordinatı uygulanmadan görünmez.
	player.visible = false

	# İlk girişte Camera2D smoothing, sahnenin varsayılan noktasından kayıtlı
	# server koordinatına kayarak "önce başka yerdeyim sonra ışınlanıyorum"
	# görüntüsü oluşturuyordu. İlk yükleme bitene kadar smoothing kapalı.
	var login_camera := player.get_node_or_null("Camera2D") as Camera2D
	if login_camera != null:
		login_camera.position_smoothing_enabled = false
	$HUD/LaserToggleButton.pressed.connect(_on_laser_toggle_button_pressed)
	_setup_laser_shortcuts()
	_setup_radiation_ui()
	_setup_bonus_box_system()
	_build_quest_tracker()
	if not QuestSystem.quests_changed.is_connected(_refresh_quest_tracker):
		QuestSystem.quests_changed.connect(_refresh_quest_tracker)
	if not QuestSystem.reward_claimed.is_connected(_on_quest_reward_for_log):
		QuestSystem.reward_claimed.connect(_on_quest_reward_for_log)
	player.fire_requested.connect(_on_fire_requested)
	warp_label.add_theme_font_size_override("font_size", 12)
	player.stats_changed.connect(_on_stats_changed)
	player.selection_requested.connect(_on_selection_requested)
	player.ship_destroyed.connect(_on_player_ship_destroyed)
	_build_death_repair_ui()
	player.world_rect = WORLD_RECT
	minimap.world_rect = WORLD_RECT
	health_bar.max_value = player.max_health
	health_bar.value = player.health
	shield_bar.max_value = maxf(player.max_shield, 1.0)
	shield_bar.value = player.shield
	_setup_status_bars()
	warp_panel.visible = false
	# _build_ammo_hud() disabled: replaced by CombatHUD
	# Girişten sonra sunucudan gelen şirket/harita ana kaynaktır.
	# Eski players.json burada tekrar okunmaz.
	var initial_map: String = str(GlobalState.start_map)
	if initial_map.is_empty() or initial_map == "x-1":
		initial_map = GlobalState.company_start_map(GlobalState.company)
	GlobalState.start_map = initial_map
	last_player_map = initial_map

	# Gate state her oturumda oyuncuya ozel dosyadan yuklenir (BOLUM 16).
	GalaxyGateManager.reset_for_player()
	_setup_galaxy_gate_ui()
	apply_player_settings()
	if not SettingsManager.settings_changed.is_connected(apply_player_settings):
		SettingsManager.settings_changed.connect(apply_player_settings)

	# Offline mod: oyuncu durumu yalnızca yerel GlobalState'ten yüklenir.
	await _load_map(initial_map, "")

	# Online oturumda WS dünya katmanı (remote players/NPC sinyalleri) hazırlanır.
	_online_world_setup()

	# Online dünya/server bağlantısı yok.
	print("NOVAGATE OFFLINE: sunucu bağlantısı devre dışı.")

	# Server koordinatı, harita ve kamera tamamen hazır. Kamerayı doğrudan
	# bu koordinata sabitle ve bundan SONRA normal smoothing'i geri aç.
	var ready_camera := player.get_node_or_null("Camera2D") as Camera2D
	if ready_camera != null:
		ready_camera.reset_smoothing()
		ready_camera.position_smoothing_enabled = true

	player.visible = true
	if player.is_destroyed:
		_on_player_ship_destroyed()
	else:
		# Kayitli HP/Kalkan varsa mevcut kayit uzerinden geri yukle.
		if GlobalState.saved_hp >= 0.0:
			player.health = clampf(GlobalState.saved_hp, 0.0, player.max_health)
		if GlobalState.saved_shield >= 0.0:
			player.shield = clampf(GlobalState.saved_shield, 0.0, maxf(player.max_shield, 0.0))
		player.last_health = player.health
		player.last_shield = player.shield
		player.stats_changed.emit(player.health, player.shield)
		_on_stats_changed(player.health, player.shield)

func _activate_social_profile() -> void:
	var username := str(GlobalState.username)
	if username.is_empty():
		return
	for path in ["/root/ChatManager", "/root/FriendManager", "/root/GroupManager"]:
		if has_node(path):
			var n = get_node(path)
			if n.has_method("activate_profile"):
				n.call("activate_profile", username)

func _build_death_repair_ui() -> void:
	# Sahne dosyasını değiştirmeden ölüm/tamir arayüzünü çalışma anında oluşturur.
	death_overlay = ColorRect.new()
	death_overlay.name = "DeathRepairOverlay"
	death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	death_overlay.color = Color(0.0, 0.0, 0.0, 0.68)
	death_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	death_overlay.z_index = 4090
	death_overlay.visible = false
	$HUD.add_child(death_overlay)

	death_panel = Panel.new()
	death_panel.name = "DeathRepairPanel"
	death_panel.custom_minimum_size = Vector2(440.0, 230.0)
	death_panel.set_anchors_preset(Control.PRESET_CENTER)
	death_panel.position = Vector2(-220.0, -115.0)
	death_overlay.add_child(death_panel)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 28.0
	content.offset_top = 28.0
	content.offset_right = -28.0
	content.offset_bottom = -28.0
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	death_panel.add_child(content)

	death_title_label = Label.new()
	death_title_label.text = "GEMİ YOK OLDU"
	death_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_title_label.add_theme_font_size_override("font_size", 30)
	content.add_child(death_title_label)

	death_subtitle_label = Label.new()
	death_subtitle_label.text = "Gemini yeniden kullanmak için tamir et."
	death_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_subtitle_label.add_theme_font_size_override("font_size", 15)
	content.add_child(death_subtitle_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(1.0, 18.0)
	content.add_child(spacer)

	repair_button = Button.new()
	repair_button.text = "TAMİR ET"
	repair_button.custom_minimum_size = Vector2(220.0, 54.0)
	repair_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	repair_button.add_theme_font_size_override("font_size", 21)
	repair_button.pressed.connect(_on_repair_button_pressed)
	content.add_child(repair_button)


func _on_player_ship_destroyed() -> void:
	GlobalState.add_logbook_entry("COMBAT", "Oyuncu öldü.", "")
	if death_overlay == null:
		_build_death_repair_ui()

	repair_in_progress = false
	if repair_button != null:
		repair_button.disabled = false
		repair_button.text = "TAMİR ET"
	if death_overlay != null:
		death_overlay.visible = true


func _on_repair_button_pressed() -> void:
	if repair_in_progress:
		return
	if player == null or not player.is_destroyed:
		return

	repair_in_progress = true
	repair_button.disabled = true
	repair_button.text = "TAMİR EDİLİYOR..."

	await respawn_player_after_death()
	await get_tree().process_frame

	if is_instance_valid(player):
		player.repair_after_death()
		GlobalState.cache_world_location(current_map_name, player.global_position)
		GlobalState.save_game()

	if death_overlay != null:
		death_overlay.visible = false

	repair_in_progress = false
	repair_button.disabled = false
	repair_button.text = "TAMİR ET"


func _setup_status_bars() -> void:
	if health_bar:
		health_bar.show_percentage = false
		health_bar.custom_minimum_size = Vector2(180, 8)
		health_bar.add_theme_color_override("font_color", Color.WHITE)
	if shield_bar:
		shield_bar.show_percentage = false
		shield_bar.custom_minimum_size = Vector2(180, 8)


func _process(delta: float) -> void:
	_online_world_tick(delta)
	_update_galaxy_gate_prompt()
	_process_radiation(delta)
	_update_cubikon_sessions(delta)
	# NPC hedefi seçili olsa bile ana gemi hareket rotasyonu zorlanmaz.
	# Dönüş kontrolü ateş sistemi tarafından yönetilir; fare hareketi korunur.
	coord_label.text = "X: %04d  Y: %04d" % [int(player.global_position.x), int(player.global_position.y)]
	ammo_label.text = ""
	var nearest: Area2D = _nearest_portal()
	var portal_safe: bool = nearest != null and player.global_position.distance_to(nearest.global_position) <= SAFE_ZONE_RADIUS
	var base_safe: bool = base_node != null and player.global_position.distance_to(base_node.global_position) <= BASE_SAFE_RADIUS
	var selected_company: String = GlobalState.company.strip_edges().to_upper()
	if selected_company.is_empty():
		selected_company = "MMO"
	var own_map: bool = false

	if selected_company == "MMO":
		own_map = current_map_name.begins_with("1-")
	elif selected_company == "EIC":
		own_map = current_map_name.begins_with("2-")
	elif selected_company == "VRU":
		own_map = current_map_name.begins_with("3-")
	player.set_safe_zone(own_map and (portal_safe or base_safe) and not player.is_in_combat)
	if portal_safe and Input.is_key_pressed(KEY_J) and not warp_active:
		pending_destination = str(nearest.get_meta("destination", ""))

		if pending_destination != "":
			if GlobalState.can_enter_map(pending_destination):
				_start_warp()
			else:
				var required_level = GlobalState.map_requirements.get(pending_destination, 1)

				warp_panel.visible = true
				warp_panel.modulate.a = 1.0
				warp_label.visible = true
				warp_label.add_theme_font_size_override("font_size", 12)
				warp_label.text = "SEVİYE YETERSİZ!  GEREKLİ SEVİYE: %s" % required_level
				await get_tree().create_timer(0.8).timeout
				warp_label.visible = false
	if warp_active:
		warp_time_left = maxf(warp_time_left - delta, 0.0)
		warp_panel.modulate.a = 0.0
		if warp_time_left <= 0.0:
			warp_active = false
			warp_panel.visible = false
			_load_map(pending_destination, current_map_name)

func mobile_try_gate() -> void:
	# Mobil kapı butonu PC'deki J ile aynı canlı portal verisini kullanır.
	if warp_active:
		return

	var nearest: Area2D = _nearest_portal()
	if nearest == null:
		return

	# PC sistemindeki güvenli alan yarıçapı ile aynı.
	if player.global_position.distance_to(nearest.global_position) > SAFE_ZONE_RADIUS:
		return

	var destination: String = str(nearest.get_meta("destination", ""))
	if destination.is_empty():
		return

	pending_destination = destination

	# Admin seviye kilidini aşabilir; normal oyuncu mevcut map requirement kullanır.
	if GlobalState.is_admin or GlobalState.can_enter_map(destination):
		_start_warp()
		return

	var required_level: int = int(GlobalState.map_requirements.get(destination, 1))
	warp_panel.visible = true
	warp_panel.modulate.a = 1.0
	warp_label.visible = true
	warp_label.add_theme_font_size_override("font_size", 12)
	warp_label.text = "SEVİYE YETERSİZ!  GEREKLİ SEVİYE: %s" % required_level
	await get_tree().create_timer(0.8).timeout
	warp_label.visible = false


func _start_warp() -> void:
	warp_active = true
	warp_time_left = WARP_DURATION
	player.stop_navigation()
	player.velocity = Vector2.ZERO
	warp_panel.visible = true
	warp_label.text = ""

func _load_map(map_name: String, arrived_from: String) -> void:
	# R1/R2/R3/PVP/BOSS dahil BÜTÜN harita geçişleri aynı boru hattını kullanır.
	online_transition_serial += 1
	var my_transition: int = online_transition_serial
	online_transition_active = true

	# Eski haritada zamanlanmış network çağrılarının hemen yeniden tetiklenmesini engelle.
	presence_elapsed = 0.0
	presence_heartbeat_elapsed = 0.0
	remote_players_elapsed = 0.0
	npc_batch_elapsed = 0.0
	npc_last_sent.clear()

	# Eski remote oyuncuları yeni haritada bir kare bile gösterme.
	_clear_remote_players_for_transition()

	current_map_name = map_name if MAP_NAMES.has(map_name) else "1-1"
	QuestSystem.record_event("map_changed", {"map": current_map_name, "amount": 1})
	last_player_map = current_map_name
	# Harita değiştiği anda GlobalState'i de aynı haritaya geçir.
	# Eski başlangıç haritasının sonraki girişte tekrar yüklenmesini engeller.
	GlobalState.start_map = current_map_name
	GlobalState.add_logbook_entry("SYSTEM", "Harita değişti: %s" % current_map_name, current_map_name)
	# Server-authoritative map_id: sunucu bilgiyi doğrular ve map isolation
	# (aynı haritadaki oyuncular) bundan türetilir.
	var ws_for_map = get_node_or_null("/root/NovaGateWSClient")
	if ws_for_map != null and ws_for_map.has_method("send_map_change") \
			and bool(ws_for_map.call("is_ws_connected")):
		ws_for_map.call("send_map_change", current_map_name)
	_update_background()
	map_label.text = "%s  (%s) / %d" % [
		current_map_name,
		str(TEMPLATE_NAME.get(current_map_name, current_map_name)),
		MAP_NAMES.size()
	]

	player.velocity = Vector2.ZERO
	player.stop_navigation()
	player.set_safe_zone(false)
	_on_selection_requested(null)

	# queue_free tek karede yüzlerce node temizlerken yeni node üretimine başlamayalım.
	for node in npc_container.get_children():
		node.queue_free()
	for node in portal_container.get_children():
		node.queue_free()
	for node in base_container.get_children():
		node.queue_free()

	# Harita değişiminde Cubikon oturumları sıfırlanır (koruma NPC'leri de serbest kalır).
	cubikon_sessions.clear()

	active_portals.clear()
	base_node = null
	_clear_galaxy_gate_portal()
	_close_galaxy_gate_ui()

	# Eski node'ların gerçekten ağaçtan çıkmasına bir kare izin ver.
	await get_tree().process_frame
	if my_transition != online_transition_serial:
		return

	_create_portals(arrived_from)
	_create_company_base()
	_create_galaxy_gate_portal()
	minimap.call("set_map_objects", _minimap_portals(), base_node)

	# NPC world-state tek aşamada yüklenir. Bu tamamlanana kadar diğer online
	# sorgular kapalı kalır; böylece harita girişindeki request patlaması önlenir.
	await _load_persistent_npcs()
	if my_transition != online_transition_serial:
		return

	# Node oluşturma işini aynı frame'e yığmamak için iki frame yay.
	await get_tree().process_frame
	await get_tree().process_frame
	if my_transition != online_transition_serial:
		return

	online_transition_active = false

	# Portal/üs yerleşimi tamamlandıktan sonra son dünya konumu tek parça halinde cache'lenir.
	GlobalState.cache_world_location(current_map_name, player.global_position)
	GlobalState.save_game()

	# Yeni haritanın presence'i önce gönderilir.
	last_presence_map = ""
	presence_elapsed = PRESENCE_MIN_INTERVAL
	presence_heartbeat_elapsed = PRESENCE_HEARTBEAT
	_send_presence_now()

	# Remote oyuncular NPC yüklemesinden sonra alınır.
	# NPC batch ise timer dolana kadar bekler; harita açılır açılmaz POST yapılmaz.
	remote_players_elapsed = REMOTE_PLAYERS_INTERVAL
	npc_batch_elapsed = 0.0

	# Harita hazır olduktan sonra bonus kutularını bu haritaya özel yeniden kur.
	_rebuild_bonus_boxes()


func _clear_remote_players_for_transition() -> void:
	remote_targets.clear()
	_select_remote_ship(null)

	if remote_players_root == null:
		return

	for child in remote_players_root.get_children():
		child.queue_free()

func _update_background() -> void:
	# Eski tek resim arka plan sistemi devre dışı bırakıldı.
	# Harita görselleri artık MapVisualManager tarafından yönetilir.
	if background:
		background.texture = null

	var visual_manager = get_node_or_null("World/MapVisuals")
	if visual_manager and visual_manager.has_method("load_map"):
		visual_manager.load_map(current_map_name)

func _create_portals(arrived_from: String) -> void:
	var destinations: Array = CONNECTIONS.get(current_map_name, [])
	for i in range(destinations.size()):
		var destination: String = str(destinations[i])
		var portal := Area2D.new()
		portal.name = "Portal_%s" % destination.replace("-","_")
		portal.position = _portal_position_for_destination(destination, i, destinations.size())
		portal.set_meta("destination", destination)
		portal.collision_layer = 4
		portal.collision_mask = 1
		var sprite := Sprite2D.new()
		sprite.texture = PORTAL_TEXTURE
		sprite.scale = Vector2(0.62,0.62)
		portal.add_child(sprite)
		var shape_node := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 160.0
		shape_node.shape = circle
		portal.add_child(shape_node)
		var label := Label.new()
		label.text = destination
		label.position = Vector2(-45,110)
		label.add_theme_font_size_override("font_size",18)
		portal.add_child(label)
		portal_container.add_child(portal)
		active_portals.append(portal)
	if arrived_from != "":
		for p in active_portals:
			if str(p.get_meta("destination","")) == arrived_from:
				player.global_position = p.global_position
				return

	# Offline mod: ilk giriste kayitli X/Y varsa AYNI konumda devam et.
	# Kayit yoksa baslangic/respawn kurali uygulanir (spawn noktasina gitme hatasi olmaz).
	if arrived_from == "" and GlobalState.server_has_position and GlobalState.server_map == current_map_name:
		player.global_position = Vector2(GlobalState.server_pos_x, GlobalState.server_pos_y)
		player.target_position = player.global_position
		return
	# Offline mod: başlangıç/respawn konumu yerel harita kurallarından belirlenir.
	if current_map_name.ends_with("-1") or current_map_name.ends_with("-6"):
		player.global_position = get_respawn_position(current_map_name)
	else:
		player.global_position = Vector2(-3600.0, 0.0)

func _portal_position_for_destination(destination: String, index: int, total: int) -> Vector2:
	var map_positions: Dictionary = PORTAL_POSITIONS.get(current_map_name, {})
	if map_positions.has(destination):
		return map_positions[destination]
	# Güvenli yedek: şablonda bulunmayan bir bağlantı olursa kapıları çember üzerinde dağıtır.
	var angle: float = TAU * float(index) / float(maxi(total, 1))
	return Vector2(3900.0, 0.0).rotated(angle)

func _create_company_base() -> void:
	
	if current_map_name.ends_with("-6") == false and current_map_name.ends_with("-1") == false:
		return
	var company_index: int = -1
	if current_map_name in ["1-1", "1-6"]:
		company_index = 0
	elif current_map_name in ["2-1", "2-6"]:
		company_index = 1
	elif current_map_name in ["3-1", "3-6"]:
		company_index = 2
	if company_index < 0:
		company_index = 0
	var base := Sprite2D.new()


	base.texture = BASE_TEXTURES[company_index]
	base.position = Vector2.ZERO
	base.scale = Vector2(0.72,0.72)
	base_container.add_child(base)
	base_node = base

func get_respawn_position(map_name: String) -> Vector2:
	print("RESPAWN İSTENDİ:", map_name)
	print("X1 ÜS:", x1_base_position)
	print("X6 ÜS:", x6_base_position)

	if map_name.ends_with("-1") or map_name == "PVP":
		return x1_base_position

	elif map_name.ends_with("-4") or map_name.ends_with("-5") or map_name.ends_with("-6") or map_name == "BOSS":
		return x6_base_position

	return Vector2.ZERO
func respawn_player_after_death() -> void:
	var selected_company: String = GlobalState.company.strip_edges().to_upper()
	if selected_company.is_empty():
		selected_company = "MMO"

	var x1_spawn := "1-1"
	var x6_spawn := "1-6"

	if selected_company == "EIC":
		x1_spawn = "2-1"
		x6_spawn = "2-6"
	elif selected_company == "VRU":
		x1_spawn = "3-1"
		x6_spawn = "3-6"

	var target_map := x1_spawn

	if current_map_name == "BOSS":
		target_map = x6_spawn
	elif current_map_name.ends_with("-4") or current_map_name.ends_with("-5") or current_map_name.ends_with("-6"):
		target_map = x6_spawn
	# PVP ve x1-x3 haritalarında x1 doğma üssü kullanılır.

	print("ŞİRKET:", selected_company)
	print("ÖLEN HARİTA:", current_map_name)
	print("DOĞMA HARİTA:", target_map)

	_load_map(target_map, "")
	await get_tree().process_frame

	if player != null:
		player.global_position = get_respawn_position(target_map)


func _spawn_map_npcs() -> void:
	var map_index = MAP_NAMES.find(current_map_name) + 1

	var npc_table = {
		"1-1": [["zyron_raider", 30, 10, 4500.0, 90.0]],
		"2-1": [["zyron_raider", 30, 10, 4500.0, 90.0]],
		"3-1": [["zyron_raider", 30, 10, 4500.0, 90.0]],

		"1-2": [
			["zyron_raider", 20, 6, 4500.0, 90.0],
			["nexar_fighter", 20, 6, 8000.0, 100.0]
		],
		"2-2": [
			["zyron_raider", 20, 6, 4500.0, 90.0],
			["nexar_fighter", 20, 6, 8000.0, 100.0]
		],
		"3-2": [
			["zyron_raider", 20, 6, 4500.0, 90.0],
			["nexar_fighter", 20, 6, 8000.0, 100.0]
		],

		"1-3": [
			["nexar_fighter", 20, 6, 8000.0, 100.0],
			["nexar_destroyer", 20, 6, 7000.0, 390.0],
			["nexar_warlord", 20, 6, 16000.0, 125.0],
			["void_reaper", 10, 3, 110000.0, 175.0]
		],
		"2-3": [
			["nexar_fighter", 20, 6, 8000.0, 100.0],
			["nexar_destroyer", 20, 6, 7000.0, 390.0],
			["nexar_warlord", 20, 6, 16000.0, 125.0],
			["void_reaper", 10, 3, 110000.0, 175.0]
		],
		"3-3": [
			["nexar_fighter", 20, 6, 8000.0, 100.0],
			["nexar_destroyer", 20, 6, 7000.0, 390.0],
			["nexar_warlord", 20, 6, 16000.0, 125.0],
			["void_reaper", 10, 3, 110000.0, 175.0]
		],

		"1-4": [
			["void_predator", 30, 10, 48000.0, 290.0],
			["abyss_guardian", 15, 5, 75000.0, 260.0]
		],
		"2-4": [
			["void_predator", 30, 10, 48000.0, 290.0],
			["abyss_guardian", 15, 5, 75000.0, 260.0]
		],
		"3-4": [
			["void_predator", 30, 10, 48000.0, 290.0],
			["abyss_guardian", 15, 5, 75000.0, 260.0]
		],

		"1-5": [
			["void_predator", 30, 10, 48000.0, 290.0],
			["void_ravager", 15, 5, 120000.0, 300.0],
			["cubikon", 1, 0, 2500000.0, 30.0]
		],
		"2-5": [
			["void_predator", 30, 10, 48000.0, 290.0],
			["void_ravager", 15, 5, 120000.0, 300.0],
			["cubikon", 1, 0, 2500000.0, 30.0]
		],
		"3-5": [
			["void_predator", 30, 10, 48000.0, 290.0],
			["void_ravager", 15, 5, 120000.0, 300.0],
			["cubikon", 1, 0, 2500000.0, 30.0]
		],

		# 4-5: SADECE Uber NPC haritası. Cubikon BU haritada spawn OLMAZ.
		# 6. eleman "uber" bayrağıdır: instance taban statlarin x3 versiyonudur.
		"4-5": [
			["zyron_raider", 12, 0, 4500.0, 90.0, true],
			["nexar_fighter", 12, 0, 8000.0, 100.0, true],
			["nexar_destroyer", 10, 0, 7000.0, 390.0, true],
			["nexar_warlord", 10, 0, 16000.0, 125.0, true],
			["void_reaper", 8, 0, 110000.0, 175.0, true],
			["void_predator", 8, 0, 48000.0, 290.0, true],
			["abyss_guardian", 8, 0, 75000.0, 260.0, true],
			["void_ravager", 6, 0, 120000.0, 300.0, true],
			["void_guardian", 8, 0, 45000.0, 390.0, true],
			["titan_nemesis", 2, 0, 1900000.0, 25.0, true]
		]
	}


	if current_map_name == "PVP":
		return


	if current_map_name == "BOSS":
		for i in range(3):
			var boss_x = rng.randf_range(-7000, 7000)
			var boss_y = rng.randf_range(-7000, 7000)

			_spawn_npc(
				Vector2(boss_x, boss_y),
				"titan_nemesis",
				1900000.0,
				25.0,
				false
			)

		for i in range(27):
			var mob_x = rng.randf_range(-8000,8000)
			var mob_y = rng.randf_range(-8000,8000)

			_spawn_npc(
				Vector2(mob_x,mob_y),
				"void_guardian",
				45000.0,
				390.0,
				false
			)

		return
	if npc_table.has(current_map_name):
		for data in npc_table[current_map_name]:
			var type_name: String = str(data[0])
			var normal_count: int = int(data[1])
			var boss_count: int = int(data[2])
			var hp: float = float(data[3])
			var move_speed: float = float(data[4])
			# 6. eleman varsa "uber" bayrağıdır: taban statlarin x3 instance'ı.
			var make_uber: bool = data.size() > 5 and bool(data[5])
			var type_passive: bool = type_name in ["zyron_raider", "abyss_guardian", "void_ravager", "cubikon"]

			if make_uber:
				_spawn_uber_group(type_name, normal_count, hp, move_speed, type_passive)
				continue

			_spawn_group(type_name, normal_count, hp, move_speed, 1300.0, type_passive)
			_spawn_boss_group(type_name, boss_count, hp, move_speed, 1300.0, type_passive)


func _spawn_uber_group(type_name:String, count:int, hp:float, move_speed:float, passive:bool) -> void:
	# 4-5: mevcut NPC tipinin Uber instance'ları. AI davranışı aynen korunur.
	for i in range(count):
		var x := rng.randf_range(-5600.0, 5600.0)
		var y := rng.randf_range(-3800.0, 3800.0)
		_spawn_npc(Vector2(x, y), type_name, hp, move_speed, passive)

		if npc_container.get_child_count() <= 0:
			continue

		var uber = npc_container.get_child(npc_container.get_child_count() - 1)
		if is_instance_valid(uber) and uber.has_method("apply_uber_variant"):
			uber.apply_uber_variant(true)


func _spawn_boss_group(type_name:String, boss_count:int, hp:float, move_speed:float, distance_from_center:float, passive:bool) -> void:
	for i in range(boss_count):
		var x := rng.randf_range(-5600.0, 5600.0)
		var y := rng.randf_range(-3800.0, 3800.0)
		_spawn_npc(Vector2(x, y), type_name, hp, move_speed, passive)

		if npc_container.get_child_count() <= 0:
			continue

		var boss = npc_container.get_child(npc_container.get_child_count() - 1)
		if is_instance_valid(boss) and boss.has_method("apply_boss_variant"):
			boss.apply_boss_variant(true)


func _spawn_group(type_name:String,count:int,hp:float,move_speed:float,distance_from_center:float,passive:bool) -> void:
	for i in range(count):
		var x := rng.randf_range(-5600.0,5600.0)
		var y := rng.randf_range(-3800.0,3800.0)
		
		var pos := Vector2(x,y)
		
		_spawn_npc(pos,type_name,hp,move_speed,passive)

func _spawn_npc(pos:Vector2,type_name:String,hp:float,move_speed:float,passive:bool) -> void:
	# Boss NPC korumasi: sadece BOSS haritasinda spawn olabilir.
	# Normal haritalara eski kayit/spawn listesinden karismasini engeller.
	# 4-5 Uber haritası istisnadır: Uber Titan Nemesis instance'ı orada doğabilir.
	var boss_only_npcs := ["boss_titan_nemesis", "titan_nemesis"]
	if current_map_name != "BOSS" and current_map_name != "4-5" and type_name in boss_only_npcs:
		return
	var npc := NPC_SCENE.instantiate() as SpaceNPC
	npc.configure(type_name,hp,move_speed)

	# Cubikon sinyali sahneye girmeden bağlanır.
	if type_name == "cubikon":
		npc.cubikon_guards_requested.connect(_on_cubikon_guards_requested)

	# Yalnız x-1 haritaları pasiftir. x-2 ve sonrası normal aggro davranışı kullanır.
	npc.passive_until_attacked = passive
	npc.global_position = pos
	npc.world_rect = WORLD_RECT
	npc.safe_zone_centers.clear()
	for p in active_portals: npc.safe_zone_centers.append(p.global_position)
	if base_node != null: npc.safe_zone_centers.append(base_node.global_position)
	npc.safe_zone_radius = SAFE_ZONE_RADIUS + 90.0
	npc.destroyed.connect(_on_npc_destroyed)
	npc.respawn_requested.connect(_on_npc_respawn_requested)
	npc.attack_requested.connect(_on_npc_attack_requested)
	npc_container.add_child(npc)

	# Cubikon (X-5): pasif dev NPC; sahneye girdikten sonra kurulum (onready sprite hazır).
	if type_name == "cubikon":
		npc.setup_cubikon()


# ============================================================
# CUBIKON KORUMA SİSTEMİ (sadece X-5: 1-5 / 2-5 / 3-5)
# Mevcut _spawn_npc/NPC AI/reward sistemini yeniden kullanır.
# ============================================================
const CUBIKON_GUARD_TYPE: String = "zyron_raider"
const CUBIKON_MAX_ACTIVE_GUARDS: int = 30
const CUBIKON_MAX_TOTAL_GUARDS: int = 90
const CUBIKON_RESPAWN_INTERVAL: float = 1.2

var cubikon_sessions: Dictionary = {}


func _on_cubikon_guards_requested(cubikon: SpaceNPC, attacker: PlayerShip, count: int) -> void:
	if not is_instance_valid(cubikon):
		return
	var session := {
		"cubikon": cubikon,
		"attacker": attacker,
		"guards": [],
		"spawned_total": 0,
		"respawn_timer": 0.0
	}
	cubikon_sessions[cubikon.get_instance_id()] = session
	var initial := mini(maxi(count, 0), CUBIKON_MAX_ACTIVE_GUARDS)
	for i in range(initial):
		_spawn_cubikon_guard(session)


func _spawn_cubikon_guard(session: Dictionary) -> void:
	var cubikon: SpaceNPC = session.get("cubikon")
	if not is_instance_valid(cubikon):
		return
	var angle: float = randf_range(0.0, TAU)
	var offset: float = randf_range(140.0, 300.0)
	_spawn_npc(
		cubikon.global_position + Vector2.RIGHT.rotated(angle) * offset,
		CUBIKON_GUARD_TYPE, 4500.0, 110.0, false
	)
	if npc_container.get_child_count() <= 0:
		return
	var guard = npc_container.get_child(npc_container.get_child_count() - 1)
	if not is_instance_valid(guard):
		return
	guard.passive_until_attacked = false
	# Koruma NPC'leri ilk saldırıyı yapan oyuncuyu hedefler (mevcut AI kilidi).
	var attacker: PlayerShip = session.get("attacker")
	if is_instance_valid(attacker):
		guard.mark_attacked(attacker)
	var guards: Array = session["guards"]
	guards.append(guard)
	session["spawned_total"] = int(session.get("spawned_total", 0)) + 1


func _update_cubikon_sessions(delta: float) -> void:
	if cubikon_sessions.is_empty():
		return
	for key in cubikon_sessions.keys():
		var session: Dictionary = cubikon_sessions[key]
		# BILINÇLI untyped: kuyruktan silinmiş Cubikon'u tipli değişkene atamak
		# "invalid previously freed instance" hatası üretir; bunu engellemek için
		# geçerlilik kontrolü Variant üzerinden yapılır.
		var cubikon = session.get("cubikon")
		var cubikon_live := is_instance_valid(cubikon)
		if cubikon_live and cubikon.is_queued_for_deletion():
			cubikon_live = false
		var guards: Array = session.get("guards", [])

		# Ölü korumaları listeden düşür.
		var live_guards: Array = []
		for g in guards:
			if is_instance_valid(g) and not g.is_queued_for_deletion():
				live_guards.append(g)
		session["guards"] = live_guards

		if not cubikon_live:
			# Cubikon öldü: koruma NPC'leri kısa süre sonra kontrollü despawn olur.
			for g in live_guards:
				if g.forced_despawn_timer <= 0.0:
					g.forced_despawn_timer = randf_range(6.0, 14.0)
			cubikon_sessions.erase(key)
			continue

		# Kontrollü takviye: aktif limit + toplam spawn bütçesi ile sınırlıdır.
		if (
			cubikon.health > 0.0
			and cubikon.provoked
			and live_guards.size() < CUBIKON_MAX_ACTIVE_GUARDS
			and int(session.get("spawned_total", 0)) < CUBIKON_MAX_TOTAL_GUARDS
		):
			session["respawn_timer"] = maxf(float(session.get("respawn_timer", 0.0)) - delta, 0.0)
			if float(session["respawn_timer"]) <= 0.0:
				session["respawn_timer"] = CUBIKON_RESPAWN_INTERVAL
				_spawn_cubikon_guard(session)

func _on_npc_respawn_requested(_type_name:String, _hp:float, _move_speed:float, _passive:bool) -> void:
	# MMO Core V2: NPC respawn'ı server world tick yönetir.
	pass


func _random_npc_respawn_position() -> Vector2:
	# Üs ve kapılardan uzakta, haritanın farklı bir noktasında doğur.
	for attempt in range(30):
		var pos := Vector2(
			rng.randf_range(WORLD_RECT.position.x + 450.0, WORLD_RECT.end.x - 450.0),
			rng.randf_range(WORLD_RECT.position.y + 450.0, WORLD_RECT.end.y - 450.0)
		)

		var safe := true
		for portal in active_portals:
			if pos.distance_to(portal.global_position) < SAFE_ZONE_RADIUS + 450.0:
				safe = false
				break

		if safe and base_node != null and pos.distance_to(base_node.global_position) < BASE_SAFE_RADIUS + 500.0:
			safe = false

		if safe and is_instance_valid(player) and pos.distance_to(player.global_position) < 700.0:
			safe = false

		if safe:
			return pos

	# Güvenli nokta bulunamazsa yine haritanın rastgele bir noktasını kullan.
	return Vector2(
		rng.randf_range(WORLD_RECT.position.x + 500.0, WORLD_RECT.end.x - 500.0),
		rng.randf_range(WORLD_RECT.position.y + 500.0, WORLD_RECT.end.y - 500.0)
	)


func _nearest_portal() -> Area2D:
	var result: Area2D = null
	var best := INF
	for p in active_portals:
		var d := player.global_position.distance_to(p.global_position)
		if d < best: best=d; result=p
	return result

func _on_npc_destroyed(_position:Vector2)->void:
	credits += 25
	if not is_instance_valid(selected_npc): selected_npc=null
func _on_npc_attack_requested(source:SpaceNPC,target:PlayerShip,damage:float)->void:
	if not is_instance_valid(source) or not is_instance_valid(target):
		return

	# NPC lazer görseli: NPC merkezinden oyuncuya doğru uçan efekt.
	var laser := NPC_LASER_EFFECT_SCENE.instantiate() as NPCLaserEffect
	if laser != null:
		add_child(laser)
		laser.setup(source, target, source.npc_name)

	# Lazerin oyuncuya ulaşmasıyla hasarı yakın zamanlı hissettirmek için
	# çok kısa görsel yolculuk süresini bekliyoruz.
	await get_tree().create_timer(0.16).timeout
	if is_instance_valid(target):
		print("HASAR GELDI:", damage)
		# NAZ (DarkOrbit): korunmayan oyuncuya NPC hasarı işler.
		# take_damage içinde has_safe_zone_protection kontrolü vardır.
		GlobalState.add_logbook_entry("COMBAT", "NPC saldırısı: %s" % str(source.npc_name), str(source.npc_name))
		GlobalState.add_logbook_entry("COMBAT", "-%d SHIELD" % int(round(damage)), str(source.npc_name))
		target.take_damage(damage, true)
func _on_fire_requested(target: Vector2, ammo: int) -> void:
	# GÜVENLİ BÖLGE / NAZ (DarkOrbit):
	# Saldırıyı BAŞLATAN oyuncu güvenli bölge korumasını anında kaybeder.
	# Bu istek yalnızca NPC hedefi (selected_npc) içindir.
	# Saldırganlık SADECE gerçek atış gerçekleştiğinde işaretlenir
	# (menzil dışı / hedef yoksa koruma kalkmaz).
	if warp_active:
		return

	# PvP: seçili düşman oyuncu varsa atış server-authoritative PvP katmanına
	# gider. Friendly (aynı company) oyuncu hedef olarak gönderilemez.
	if selected_remote_ship != null and is_instance_valid(selected_remote_ship):
		var remote_ship := selected_remote_ship as RemoteShip
		if str(remote_ship.relation) == "enemy":
			var remote_distance := player.global_position.distance_to(remote_ship.global_position)
			if remote_distance <= PLAYER_LASER_RANGE:
				var ws_pvp = get_node_or_null("/root/NovaGateWSClient")
				if ws_pvp != null and ws_pvp.has_method("is_ws_connected") and bool(ws_pvp.call("is_ws_connected")):
					_log_pvp_engagement(remote_ship)
					ws_pvp.call("send_combat_fire", ammo, remote_ship.global_position.x, remote_ship.global_position.y, str(remote_ship.player_id))
					if is_instance_valid(player) and player.has_method("mark_as_aggressor"):
						player.call("mark_as_aggressor")
		return

	if not is_instance_valid(selected_npc):
		return

	var hit_npc: SpaceNPC = selected_npc
	target = hit_npc.global_position

	var distance_to_target := player.global_position.distance_to(target)
	if distance_to_target > PLAYER_LASER_RANGE:
		return

	# Online oturum: ateş isteği server-authoritative combat katmanına iletilir.
	# Server menzil/hasar doğrulamasını kendisi yapar; reddedilen atış zararsızdır.
	var ws_node = get_node_or_null("/root/NovaGateWSClient")
	if ws_node != null and ws_node.has_method("is_ws_connected") and bool(ws_node.call("is_ws_connected")):
		ws_node.call("send_combat_fire", ammo, target.x, target.y)

	# Offline mod: NPC sahipliği/aggro doğrudan yerel oyuncu tarafından yönetilir.
	if not is_instance_valid(hit_npc) or hit_npc.is_queued_for_deletion():
		return
	# Ateş gerçekleştiği anda saldırganlık işaretlenir: NAZ koruması kalkar,
	# combat/aggression state başlar. Hedef NPC de bu oyuncuya karşılık verebilir.
	if is_instance_valid(player) and player.has_method("mark_as_aggressor"):
		player.call("mark_as_aggressor")
	hit_npc.first_attacker = player
	hit_npc.player = player
	hit_npc.provoked = true
	hit_npc.first_attacker_username = GlobalState.username
	hit_npc.reward_owner_username = GlobalState.username

	if is_instance_valid(player):
		hit_npc.mark_attacked(player)

	# Ateş isteğinden gelen cephane numarası 1-6 aralığındadır.
	# Slot sözlüğüne dokunmadan lazer indeksini 0-5 aralığına çevir.
	var ammo_index_zero: int = clampi(ammo - 1, 0, AMMO_MULTIPLIERS.size() - 1)

	var travel_time := clampf(
		distance_to_target / PLAYER_LASER_PROJECTILE_SPEED,
		PLAYER_LASER_MIN_TRAVEL_TIME,
		PLAYER_LASER_MAX_TRAVEL_TIME
	)

	var origins := player.get_gun_world_positions()
	if ammo_index_zero == 4:
		_spawn_sab_transfer_visual(target, player.global_position, travel_time)
	else:
		# DarkOrbit tarzı görsel: X1/X2/X3/X4/RSB tek ışın yerine
		# dört paralel ışın halinde çıkar ve hedefe yaklaşırken içe daralır.
		var visual_origin := player.global_position
		if not origins.is_empty():
			visual_origin = Vector2.ZERO
			for gun_origin in origins:
				visual_origin += gun_origin
			visual_origin /= float(origins.size())
		_spawn_quad_laser_visual(visual_origin, target, ammo_index_zero, travel_time)

	await get_tree().create_timer(travel_time).timeout

	if not is_instance_valid(hit_npc):
		return

	var equipment_damage: float = player.get_laser_damage()
	if equipment_damage <= 0.0:
		return

	if ammo_index_zero == 4:
		var sab_power: float = equipment_damage * SAB_SHIELD_FACTOR
		var drained: float = 0.0

		if hit_npc.has_method("take_sab_damage"):
			drained = float(hit_npc.call("take_sab_damage", sab_power, player))

		if drained > 0.0 and player.has_method("add_sab_shield"):
			player.call("add_sab_shield", drained)

		var sab_extra_system = get_tree().get_first_node_in_group("extra_system")
		if sab_extra_system != null and sab_extra_system.has_method("on_player_dealt_damage"):
			sab_extra_system.call("on_player_dealt_damage", drained)

		return

	var final_damage: float = equipment_damage * AMMO_MULTIPLIERS[ammo_index_zero]
	final_damage *= randf_range(0.95, 1.15)

	var extra_before_total: float = maxf(hit_npc.health, 0.0) + maxf(hit_npc.shield, 0.0)

	if hit_npc.has_method("take_laser_damage"):
		hit_npc.call("take_laser_damage", final_damage, ammo_index_zero + 1, player)
	else:
		hit_npc.take_damage(final_damage, player)

	var extra_after_total: float = maxf(hit_npc.health, 0.0) + maxf(hit_npc.shield, 0.0)
	var extra_real_damage: float = maxf(extra_before_total - extra_after_total, 0.0)
	var extra_system = get_tree().get_first_node_in_group("extra_system")
	if extra_system != null and extra_system.has_method("on_player_dealt_damage"):
		extra_system.call("on_player_dealt_damage", extra_real_damage)




func _spawn_sab_transfer_visual(
	from_target: Vector2,
	to_player: Vector2,
	travel_time: float
) -> void:
	var root := Node2D.new()
	root.name = "SABTransferRing"
	root.global_position = from_target
	root.z_index = 40
	laser_container.add_child(root)

	var ring_sizes := [72.0, 58.0, 44.0]
	var ring_widths := [5.0, 3.5, 2.5]

	for i in range(ring_sizes.size()):
		var ring := Line2D.new()
		ring.closed = true
		ring.width = float(ring_widths[i])
		ring.default_color = Color(0.15, 0.95, 1.0, 0.95 - float(i) * 0.18)
		ring.antialiased = true

		var points := PackedVector2Array()
		var segments := 48
		for step in range(segments):
			var a := TAU * float(step) / float(segments)
			points.append(Vector2(cos(a), sin(a)) * float(ring_sizes[i]))
		ring.points = points
		root.add_child(ring)

	root.scale = Vector2(1.35, 1.35)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(root, "global_position", to_player, travel_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(root, "scale", Vector2(0.16, 0.16), travel_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(root, "modulate:a", 0.12, travel_time)
	tween.set_parallel(false)
	tween.tween_callback(root.queue_free)


func _spawn_quad_laser_visual(
	origin: Vector2,
	target: Vector2,
	ammo_zero: int,
	travel_time: float
) -> void:
	var direction := target - origin
	var distance := direction.length()
	if distance <= 1.0:
		return

	var forward := direction / distance
	var perpendicular := forward.orthogonal()

	# Başlangıçta dört ışın belirgin biçimde yan yana. Hedef tarafında
	# aralık küçülür; böylece ışınlar uçuş boyunca merkeze doğru kapanır.
	var start_offsets: Array[float] = [-27.0, -9.0, 9.0, 27.0]
	var end_offsets: Array[float] = [-6.0, -2.0, 2.0, 6.0]

	for i in range(4):
		var start_pos := origin + perpendicular * start_offsets[i]
		var end_pos := target + perpendicular * end_offsets[i]
		var beam_direction := end_pos - start_pos

		var effect := Sprite2D.new()
		effect.texture = LASER_EFFECTS[ammo_zero]
		effect.global_position = start_pos
		effect.rotation = beam_direction.angle()
		effect.z_index = 20
		effect.modulate = Color(1.0, 1.0, 1.0, 1.0)

		var texture_size := effect.texture.get_size()
		var desired_length := clampf(distance * 0.22, 58.0, 135.0)
		var desired_height := 14.0
		effect.scale = Vector2(
			desired_length / maxf(texture_size.x, 1.0),
			desired_height / maxf(texture_size.y, 1.0)
		)

		laser_container.add_child(effect)

		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_property(effect, "global_position", end_pos, travel_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.tween_property(effect, "modulate:a", 0.22, travel_time)
		# Hedefe yaklaştıkça ışın hafif incelir; dört çizgi tek noktaya
		# doğru sıkışıyormuş hissi verir.
		tween.tween_property(effect, "scale:y", effect.scale.y * 0.78, travel_time)
		tween.set_parallel(false)
		tween.tween_callback(effect.queue_free)


func _spawn_laser_visual(
	origin: Vector2,
	target: Vector2,
	ammo_zero: int,
	travel_time: float
) -> void:
	var direction := target - origin
	var distance := direction.length()
	if distance <= 1.0:
		return

	var effect := Sprite2D.new()
	effect.texture = LASER_EFFECTS[ammo_zero]
	effect.global_position = origin
	effect.rotation = direction.angle()
	effect.z_index = 20
	effect.modulate = Color(1.0, 1.0, 1.0, 1.0)

	var texture_size := effect.texture.get_size()
	var desired_length := clampf(distance * 0.30, 65.0, 170.0)
	var desired_height := 24.0 if ammo_zero != 4 else 56.0
	effect.scale = Vector2(
		desired_length / maxf(texture_size.x, 1.0),
		desired_height / maxf(texture_size.y, 1.0)
	)

	laser_container.add_child(effect)

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(effect, "global_position", target, travel_time)
	tween.tween_property(effect, "modulate:a", 0.20, travel_time)
	tween.set_parallel(false)
	tween.tween_callback(effect.queue_free)


# _build_ammo_hud disabled: replaced by CombatHUD

func _select_ammo(ammo_number: int) -> void:
	player.select_ammo(ammo_number)



func _on_stats_changed(h:float,s:float)->void:
	health_bar.max_value = player.max_health
	shield_bar.max_value = maxf(player.max_shield, 1.0)
	health_bar.value = h
	shield_bar.value = s
func _on_selection_requested(npc:SpaceNPC)->void:
	if is_instance_valid(selected_npc): selected_npc.set_selected(false)
	selected_npc=npc
	player.set_locked_target(selected_npc)
	if is_instance_valid(selected_npc): selected_npc.set_selected(true)
var safe_logout_request_started: bool = false
var client_logout_in_progress: bool = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if safe_logout_request_started:
			return
		safe_logout_request_started = true
		call_deferred("_request_safe_logout_and_quit")


func _request_safe_logout_and_quit() -> void:
	if client_logout_in_progress:
		return
	client_logout_in_progress = true
	if is_instance_valid(player):
		GlobalState.cache_world_location(current_map_name, player.global_position)
		if "health" in player and "shield" in player:
			GlobalState.saved_hp = float(player.get("health"))
			GlobalState.saved_shield = float(player.get("shield"))
	GlobalState.save_game()
	var account_manager = load("res://scripts/account_manager.gd").new()
	await account_manager.server_logout()
	account_manager.queue_free()
	get_tree().quit()

func client_logout_to_login() -> void:
	if client_logout_in_progress:
		return
	client_logout_in_progress = true
	if is_instance_valid(player):
		GlobalState.cache_world_location(current_map_name, player.global_position)
		if "health" in player and "shield" in player:
			GlobalState.saved_hp = float(player.get("health"))
			GlobalState.saved_shield = float(player.get("shield"))
	GlobalState.save_game()
	var account_manager = load("res://scripts/account_manager.gd").new()
	await account_manager.server_logout()
	account_manager.queue_free()
	get_tree().change_scene_to_file("res://scenes/Login.tscn")

func _setup_laser_shortcuts() -> void:
	var box := get_node_or_null("HUD/LaserToggleButton/LaserPanel/VBoxContainer")
	if box == null:
		push_warning("Lazer kısayol paneli bulunamadı")
		return

	for button_name in LASER_SHORTCUT_BUTTONS.keys():
		var button := box.get_node_or_null(str(button_name)) as Button
		if button == null:
			continue
		var ammo_name: String = str(LASER_SHORTCUT_BUTTONS[button_name])
		button.tooltip_text = "Sol tık: seç | Sağ tık: 1-6 tuşuna ata"
		button.gui_input.connect(_on_laser_shortcut_button_gui_input.bind(ammo_name))

	laser_shortcut_hint = Label.new()
	laser_shortcut_hint.name = "ShortcutHint"
	laser_shortcut_hint.visible = false
	laser_shortcut_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	laser_shortcut_hint.position = Vector2(-120.0, 198.0)
	laser_shortcut_hint.size = Vector2(240.0, 42.0)
	laser_shortcut_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	laser_shortcut_hint.add_theme_font_size_override("font_size", 9)
	$HUD/LaserToggleButton/LaserPanel.add_child(laser_shortcut_hint)

	_refresh_laser_shortcut_labels()


func _on_laser_shortcut_button_gui_input(event: InputEvent, ammo_name: String) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_RIGHT and mouse_event.pressed:
			pending_laser_shortcut = ammo_name
			if laser_shortcut_hint != null:
				laser_shortcut_hint.text = "%s için 1-6 tuşuna bas" % LASER_SHORTCUT_DISPLAY.get(ammo_name, ammo_name)
				laser_shortcut_hint.visible = true
			get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	# Uzak oyuncu seçimi: sol tık imlecin altındaki düşman gemisini hedef alır.
	# (Friendly hedef seçimi _try_select_remote_at_mouse içinde reddedilir.)
	if event is InputEventMouseButton:
		var select_event := event as InputEventMouseButton
		if select_event.button_index == MOUSE_BUTTON_LEFT and select_event.pressed:
			if _try_select_remote_at_mouse():
				get_viewport().set_input_as_handled()
				return

	# GALAXY GATE: X1 portalina yakin olundugunda settings'te tanimli gate
	# tusu (varsayilan G) ile gate arayuzu acilir.
	if event is InputEventKey:
		var gate_key_event := event as InputEventKey
		if gate_key_event.pressed and not gate_key_event.echo and gate_key_event.keycode == KEY_G:
			if _galaxy_gate_interaction_available():
				open_galaxy_gate_ui()
				get_viewport().set_input_as_handled()
				return
	if pending_laser_shortcut.is_empty():
		return
	if not (event is InputEventKey):
		return

	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	var slot := 0
	match key_event.keycode:
		KEY_1: slot = 1
		KEY_2: slot = 2
		KEY_3: slot = 3
		KEY_4: slot = 4
		KEY_5: slot = 5
		KEY_6: slot = 6
		KEY_ESCAPE:
			pending_laser_shortcut = ""
			if laser_shortcut_hint != null:
				laser_shortcut_hint.visible = false
			get_viewport().set_input_as_handled()
			return
		_:
			return

	var assigned_ammo := pending_laser_shortcut
	SlotManager.assign_laser_to_slot(slot, assigned_ammo)
	pending_laser_shortcut = ""
	_refresh_laser_shortcut_labels()

	if laser_shortcut_hint != null:
		laser_shortcut_hint.text = "%d = %s" % [slot, LASER_SHORTCUT_DISPLAY.get(assigned_ammo, assigned_ammo)]
		laser_shortcut_hint.visible = true
		var hint_ref := laser_shortcut_hint
		get_tree().create_timer(1.5).timeout.connect(func():
			if is_instance_valid(hint_ref):
				hint_ref.visible = false
		)

	# Atama anında yeni slotu seç; oyuncu sonucu hemen görsün.
	if is_instance_valid(player):
		player.select_ammo(slot)
	get_viewport().set_input_as_handled()


func _refresh_laser_shortcut_labels() -> void:
	var box := get_node_or_null("HUD/LaserToggleButton/LaserPanel/VBoxContainer")
	if box == null:
		return

	# Önce her lazer için atanmış tuşları bul.
	var assigned: Dictionary = {}
	for slot in range(1, 7):
		var ammo_name: String = SlotManager.get_slot_laser(slot)
		if not assigned.has(ammo_name):
			assigned[ammo_name] = []
		assigned[ammo_name].append(slot)

	for button_name in LASER_SHORTCUT_BUTTONS.keys():
		var button := box.get_node_or_null(str(button_name)) as Button
		if button == null:
			continue
		var ammo_name: String = str(LASER_SHORTCUT_BUTTONS[button_name])
		var base_name: String = str(LASER_SHORTCUT_DISPLAY.get(ammo_name, button_name))
		var keys: Array = assigned.get(ammo_name, [])
		if keys.is_empty():
			button.text = base_name
		else:
			var key_texts: Array[String] = []
			for key in keys:
				key_texts.append(str(key))
			button.text = "%s [%s]" % [base_name, ",".join(key_texts)]


func _on_laser_toggle_button_pressed() -> void:
	print("LAZER BUTON BASILDI")

	var panel = $HUD/LaserToggleButton/LaserPanel
	panel.visible = not panel.visible

	get_viewport().set_input_as_handled()
	


func _on_x1_pressed() -> void:
	player.select_ammo(1)


func _on_x2_pressed() -> void:
	player.select_ammo(2)


func _on_x3_pressed() -> void:
	player.select_ammo(3)


func _on_x4_pressed() -> void:
	player.select_ammo(4)


func _on_sab_pressed() -> void:
	player.select_ammo(5)


func _on_rsb_pressed() -> void:
	player.select_ammo(6)


func _on_x_2_pressed() -> void:
	pass # Replace with function body.

# === NovaGate persistent online world v1.1 PERFORMANCE ===
# Ağ yükü azaltıldı:
# - presence yalnız hareket/değişiklik varsa,
# - remote oyuncular ayrı aralıkla,
# - NPC'ler tek tek değil tek batch POST ile,
# - yalnız değişen NPC'ler gönderilir.

const PRESENCE_MIN_INTERVAL: float = 1.25
const PRESENCE_HEARTBEAT: float = 5.0
const PRESENCE_MOVE_THRESHOLD: float = 18.0
const REMOTE_PLAYERS_INTERVAL: float = 2.00
const NPC_BATCH_INTERVAL: float = 2.0
const NPC_MOVE_THRESHOLD: float = 32.0
const NPC_HEARTBEAT: float = 18.0
const SERVER_NPC_SNAPSHOT_INTERVAL: float = 2.5

var presence_elapsed: float = 0.0
var presence_heartbeat_elapsed: float = 0.0
var remote_players_elapsed: float = 0.0
var npc_batch_elapsed: float = 0.0
var server_npc_snapshot_elapsed: float = 0.0

var last_presence_position: Vector2 = Vector2.INF
var last_presence_map: String = ""
var npc_last_sent: Dictionary = {}

var presence_request_busy: bool = false
var remote_request_busy: bool = false
var npc_batch_request_busy: bool = false

# TÜM haritalar için ortak geçiş kilidi.
# Harita yüklenirken presence / remote player / NPC batch aynı anda çalışmaz.
var online_transition_active: bool = false
var online_transition_serial: int = 0

var remote_players_root: Node2D = null
var remote_targets: Dictionary = {}
# Seçili uzak oyuncu (PvP hedefi). Yalnızca server'dan gelen company verisine
# göre friendly/enemy ayrımı yapılır.
var selected_remote_ship: Node = null


func _on_npc_death(npc_id: String, reward: Dictionary) -> void:
	var attacker_id := str(reward.get("attacker_id", ""))
	var npc_type := str(reward.get("npc_type", ""))
	if attacker_id != "" and attacker_id != str(GlobalState.player_id):
		return
	if npc_id.is_empty() or GlobalState.recent_npc_death_ids.has(npc_id):
		return
	GlobalState.recent_npc_death_ids[npc_id] = true
	if GlobalState.recent_npc_death_ids.size() > 128:
		GlobalState.recent_npc_death_ids.clear()
		GlobalState.recent_npc_death_ids[npc_id] = true
	var server_btc := int(reward.get("bitcoin", reward.get("btc", 0)))
	var server_plt := int(reward.get("platinum", reward.get("plt", 0)))
	var xp_reward := int(reward.get("xp", 0))
	var honor_reward := int(reward.get("honor", 0))
	# BTC/PLT are already credited by the server in the same transaction that
	# produced this reward, so the client must NOT add them again locally.
	# XP/HONOR are not tracked server-side yet, so those two still advance here.
	if xp_reward != 0 or honor_reward != 0:
		GlobalState.sync_economy_delta(0, 0, xp_reward, honor_reward)
	GlobalState.npc_kills += 1
	QuestSystem.record_event("npc_kill", {"npc_type": npc_type, "boss": false, "amount": 1})
	var npc_display_name := _npc_display_name(npc_type, npc_id)
	GlobalState.add_logbook_entry("NPC", "NPC öldürüldü: %s" % npc_display_name, npc_id)
	# Always report the server-credited amounts, even though the local balance
	# was not incremented again. One entry per currency, like DarkOrbit.
	if server_btc != 0:
		GlobalState.add_logbook_entry("ECONOMY", "+%s BTC" % _format_amount(server_btc), npc_display_name)
	if server_plt != 0:
		GlobalState.add_logbook_entry("ECONOMY", "+%s PLT" % _format_amount(server_plt), npc_display_name)
	if xp_reward != 0:
		GlobalState.add_logbook_entry("ECONOMY", "+%d XP" % xp_reward, npc_display_name)
	if honor_reward != 0:
		GlobalState.add_logbook_entry("ECONOMY", "+%d HONOR" % honor_reward, npc_display_name)
	var reward_text := "+%d BTC  +%d PLT  +%d XP  +%d HONOR" % [server_btc, server_plt, xp_reward, honor_reward]
	_show_npc_reward_popup(reward_text)
	_refresh_economy_display()
	GlobalState.save_game()
	_refresh_quest_tracker()


func _show_npc_reward_popup(text: String) -> void:
	var social := get_node_or_null("/root/SocialUI")
	if social != null and social.has_method("_notice"):
		social.call("_notice", "NPC DESTROYED  |  " + text)
	else:
		print("NPC DESTROYED | ", text)


# Seyir Defteri için okunabilir NPC adı: "zyron_raider" -> "Zyrone Raider".
func _npc_display_name(npc_type: String, fallback: String) -> String:
	var raw := npc_type.strip_edges()
	if raw.is_empty():
		raw = fallback.strip_edges()
	if raw.is_empty():
		return "Bilinmeyen NPC"
	if raw.contains(" ") or raw.contains("_"):
		return raw.replace("_", " ").capitalize()
	return raw.to_upper()


# Seyir Defteri economy satırları için binlik ayraçlı sayı (GlobalState.format_amount).
func _format_amount(value: int) -> String:
	return GlobalState.format_amount(value)


# PvP başlangıcı: aynı rakipten art arda atışlarda "savaş başladı" kaydı
# yalnızca bir kez yazılır (GlobalState.add_logbook_entry tekilleştirmesi +
# aşağıdaki hedef başına sayaç birlikte çalışır).
var _pvp_engaged_targets: Dictionary = {}

func _log_pvp_engagement(remote_ship: Node) -> void:
	if remote_ship == null or not is_instance_valid(remote_ship):
		return
	var key := str(remote_ship.player_id)
	if _pvp_engaged_targets.has(key):
		return
	_pvp_engaged_targets[key] = true
	if _pvp_engaged_targets.size() > 32:
		_pvp_engaged_targets.clear()
	var enemy_name := str(remote_ship.username) if "username" in remote_ship else str(remote_ship.name)
	if enemy_name.is_empty():
		enemy_name = "Oyuncu"
	GlobalState.add_logbook_entry("PLAYER", "Oyuncu ile savaş başladı: %s" % enemy_name, key)


func _on_quest_completed_for_log(quest_id: String) -> void:
	GlobalState.add_logbook_entry("QUEST", "%s tamamlandı." % quest_id, quest_id)


func _on_quest_reward_for_log(quest_id: String) -> void:
	GlobalState.add_logbook_entry("QUEST", "%s ödülü alındı." % quest_id, quest_id)


func _online_world_setup() -> void:
	# Check if WebSocket session is active (server-authoritative mode)
	var ws_client = get_node_or_null("/root/NovaGateWSClient")
	if ws_client == null:
		remote_players_root = null
		print("NOVAGATE OFFLINE WORLD HAZIR: map=", current_map_name)
		return

	if remote_players_root == null:
		remote_players_root = Node2D.new()
		remote_players_root.name = "RemotePlayers"
		add_child(remote_players_root)

	_connect_ws_once(ws_client, "world_update", _on_world_update)
	_connect_ws_once(ws_client, "remote_player_update", _on_remote_player_update)
	_connect_ws_once(ws_client, "remote_player_left", _on_remote_player_left)
	_connect_ws_once(ws_client, "npc_death", _on_npc_death)
	_connect_ws_once(ws_client, "session_kicked", _on_session_kicked)
	_connect_ws_once(ws_client, "player_combat_event", _on_player_combat_event)
	_connect_ws_once(ws_client, "map_changed", _on_server_map_changed)

	if bool(ws_client.call("is_ws_connected")):
		# Server is authoritative about our identity/company; local values are
		# refreshed from the welcome payload instead of the other way around.
		var server_company := str(ws_client.get("company")).strip_edges().to_upper()
		if ["EIC", "MMO", "VRU"].has(server_company):
			GlobalState.company = server_company
		# Re-announce the map we are playing on (server validates it).
		ws_client.call("send_map_change", current_map_name)
		print("NOVAGATE ONLINE WORLD HAZIR: map=", current_map_name, " company=", GlobalState.company)
	else:
		print("NOVAGATE OFFLINE WORLD HAZIR: map=", current_map_name)


func _connect_ws_once(ws_client: Object, signal_name: String, handler: Callable) -> void:
	if ws_client == null:
		return
	if not ws_client.has_signal(signal_name):
		return
	if not ws_client.is_connected(signal_name, handler):
		ws_client.connect(signal_name, handler)


func _local_player_id() -> String:
	var ws_client = get_node_or_null("/root/NovaGateWSClient")
	if ws_client != null and str(ws_client.get("player_id")) != "":
		return str(ws_client.get("player_id"))
	return str(GlobalState.player_id)


func _on_session_kicked(reason: String) -> void:
	# Tek hesap = tek aktif oturum: başka bir yerden giriş yapıldı.
	# Gameplay'den çıkıp login ekranına dönülür.
	GlobalState.server_session_active = false
	print("NOVAGATE SESSION KICKED: ", reason)
	get_tree().call_deferred("change_scene_to_file", "res://scenes/Login.tscn")


func _on_server_map_changed(new_map: String) -> void:
	if not new_map.is_empty() and new_map != current_map_name:
		print("NOVAGATE SERVER MAP MISMATCH: server=", new_map, " client=", current_map_name)


func _on_player_combat_event(event: Dictionary) -> void:
	# Server-authoritative PvP: local HP/shield is only reduced when the
	# server says so (never by the client itself).
	var target_id := str(event.get("target_id", ""))
	if target_id != _local_player_id():
		return
	if not is_instance_valid(player):
		return

	var attacker_company := str(event.get("attacker_company", ""))
	var attacker_name := str(event.get("attacker_username", ""))
	if player.has_method("receive_enemy_player_attack"):
		# NAZ/safe-zone kuralı mevcut oyun tasarımımıza göre uygulanır.
		if not bool(player.call("receive_enemy_player_attack", attacker_company)):
			return

	var damage := float(event.get("damage", 0.0))
	var drain := float(event.get("shield_drain", 0.0))
	if str(event.get("type", "")) == "player_death":
		GlobalState.add_logbook_entry("PLAYER", "Öldürüldün: %s" % attacker_name, target_id)
		return
	if drain > 0.0 and player.has_method("add_sab_shield"):
		player.call("add_sab_shield", drain)
	if damage > 0.0:
		GlobalState.add_logbook_entry("PLAYER", "%s saldırısı" % (attacker_name if not attacker_name.is_empty() else "Oyuncu"), attacker_name)
		GlobalState.add_logbook_entry("COMBAT", "-%d SHIELD" % int(round(damage)), attacker_name)
		player.take_damage(damage)


func _on_remote_player_left(player_id: String) -> void:
	if remote_players_root == null:
		return
	var child_name = "P_" + player_id
	if remote_players_root.has_node(child_name):
		var child = remote_players_root.get_node(child_name)
		if selected_remote_ship == child:
			_select_remote_ship(null)
		child.queue_free()
	if remote_targets.has(player_id):
		remote_targets.erase(player_id)


func _online_world_tick(delta: float) -> void:
	if not GlobalState.server_session_active:
		return

	var ws_client = get_node_or_null("/root/NovaGateWSClient")
	if ws_client == null or not bool(ws_client.call("is_ws_connected")):
		return

	# Read server-authoritative position for local player
	var server_info: Dictionary = ws_client.call("get_server_player_state")
	if server_info.has("position"):
		# Server position metadata (kept when present)
		player.set_meta("server_position", server_info["position"])

	# Client only sends input, not position: the server integrates movement.
	var player_velocity = Vector2.ZERO
	if player.has_method("get_input_direction"):
		player_velocity = player.get_input_direction()
	elif is_instance_valid(player):
		player_velocity = player.velocity
	# The ship reports its own effective speed so the server integrates the
	# SAME movement model instead of a mismatched global constant.
	var ship_speed := 0.0
	if is_instance_valid(player) and "max_speed" in player:
		ship_speed = float(player.get("max_speed"))
	ws_client.call("send_movement_input", player_velocity.x, player_velocity.y, ship_speed)

	# Reconcile the local ship with the server-authoritative position so
	# client-side range checks (PvP/NPC) measure the same distance the server
	# measures. A visible jump larger than the snap threshold means a real
	# desync (teleport/respawn), so it is corrected immediately.
	if bool(server_info.get("has_position", false)) and is_instance_valid(player):
		var authoritative: Vector2 = server_info["position"]
		var drift := player.global_position - authoritative
		if drift.length() > POSITION_SNAP_THRESHOLD:
			player.global_position = authoritative
		elif drift.length() > 0.5:
			player.global_position = player.global_position.lerp(authoritative, POSITION_RECONCILE_STRENGTH)
	return

func _on_world_update(data: Dictionary) -> void:
	# Received from NovaGateWSClient - world state update
	# This is handled by the WS client's interpolation directly
	# This handler exists for future expansion
	pass

func _on_remote_player_update(player_id: String, position: Vector2, state: Dictionary) -> void:
	if player_id == _local_player_id():
		# Kendi oyuncumuz asla remote listesine eklenmez.
		return
	if remote_players_root == null:
		remote_players_root = Node2D.new()
		remote_players_root.name = "RemotePlayers"
		add_child(remote_players_root)

	var child_name = "P_" + player_id
	var child = remote_players_root.get_node_or_null(child_name)
	if child == null:
		# Spawn new remote player ship
		var RemoteShip = preload("res://scripts/remote_ship.gd")
		child = RemoteShip.new()
		child.name = child_name
		remote_players_root.add_child(child)
		child.setup({
			"player_id": player_id,
			"username": state.get("username", ""),
			"company": state.get("company", ""),
			"ship": state.get("ship_id", "Ship10"),
			"pos_x": position.x,
			"pos_y": position.y,
			"hp": state.get("hp", 100),
			"max_hp": state.get("max_hp", 100),
			"shield": state.get("shield", 100),
			"max_shield": state.get("max_shield", 100),
		})
		if child.has_method("apply_name_visibility"):
			child.call("apply_name_visibility", bool(SettingsManager.get_setting("gameplay", "show_player_names", true)))
	else:
		# Sürekli world_update: kimlik + can/kalkan + relation tazelenir.
		if child.has_method("apply_world_state"):
			child.call("apply_world_state", {
				"username": state.get("username", ""),
				"company": state.get("company", ""),
				"hp": state.get("hp", 100),
				"max_hp": state.get("max_hp", 100),
				"shield": state.get("shield", 100),
				"max_shield": state.get("max_shield", 100),
				"selected": selected_remote_ship == child,
			})

	# Set target position for interpolation (client only interpolates, doesn't set position directly)
	if child.has_method("set_server_position"):
		child.set_server_position(position)
	remote_targets[player_id] = position


func _select_remote_ship(ship: Node) -> void:
	if selected_remote_ship != null and is_instance_valid(selected_remote_ship) \
			and selected_remote_ship.has_method("set_selected"):
		selected_remote_ship.call("set_selected", false)
	selected_remote_ship = ship
	if selected_remote_ship != null and selected_remote_ship.has_method("set_selected"):
		selected_remote_ship.call("set_selected", true)


func _try_select_remote_at_mouse() -> bool:
	# Sol tık: imlecin altındaki uzak oyuncuyu hedef seç.
	if remote_players_root == null:
		return false
	var mouse_pos := get_global_mouse_position()
	var best: Node = null
	var best_dist := 64.0
	for child in remote_players_root.get_children():
		if child is RemoteShip and is_instance_valid(child):
			var dist: float = mouse_pos.distance_to((child as Node2D).global_position)
			if dist <= best_dist:
				best_dist = dist
				best = child
	if best == null:
		return false
	# Friendly hedef seçilemez: PvP hedefi yalnızca düşman şirket oyuncusu.
	if str(best.get("relation")) == "friendly":
		return false
	_select_remote_ship(best)
	_on_selection_requested(null)
	return true

func _refresh_economy_display() -> void:
	var menu = get_tree().get_first_node_in_group("menu_ui")
	if menu == null or not is_instance_valid(menu):
		return

	# Use the existing public refresh method for the PilotInfo panel.
	if menu.has_method("refresh_info"):
		var _ok = menu.call("refresh_info")

	# Directly update the top HUD strip value labels (BTC / PLT / GOLD blocks).
	_update_hud_strip_labels(menu)


func _update_hud_strip_labels(menu: Node) -> void:
	var values: Dictionary = {
		"BTC": int(GlobalState.bitcoin),
		"PLT": int(GlobalState.platinum),
		"GOLD": int(GlobalState.gold),
	}
	_scan_hud_blocks(menu, values, menu)


func _scan_hud_blocks(node: Node, values: Dictionary, menu: Node) -> void:
	if node is Panel:
		var panel := node as Panel
		if panel.get_child_count() > 0:
			var inner := panel.get_child(0)
			if inner is VBoxContainer:
				var kids := (inner as VBoxContainer).get_children()
				if kids.size() >= 2:
					var title_lbl := kids[0] as Label
					var value_lbl := kids[1] as Label
					if title_lbl != null and value_lbl != null:
						var title := str(title_lbl.text).strip_edges()
						if values.has(title):
							if menu.has_method("_format_number"):
								value_lbl.text = str(menu.call("_format_number", values[title]))
							else:
								value_lbl.text = str(values[title])
	for child in node.get_children():
		_scan_hud_blocks(child, values, menu)

func _send_presence_now() -> void:
	if not is_instance_valid(player):
		return
	GlobalState.cache_world_location(current_map_name, player.global_position)
func _rank_texture_for_remote(rank_id: String) -> Texture2D:
	# Uzak oyuncu ikonlari da ayni badge bileseninden uretilir.
	return RankBadge.texture_for(rank_id)


func _refresh_remote_players() -> void:
	pass
func _interpolate_remote_players(delta: float) -> void:
	if remote_players_root == null:
		return

	var weight := 1.0 - exp(-3.0 * delta)
	for child in remote_players_root.get_children():
		var id := child.name.trim_prefix("P_")
		if remote_targets.has(id):
			child.global_position = child.global_position.lerp(remote_targets[id], weight)


func _normal_npc_caps_for_map(map_name: String) -> Dictionary:
	if map_name.ends_with("-1"):
		return {"zyron_raider": 27}

	if map_name.ends_with("-2"):
		return {
			"zyron_raider": 7,
			"nexar_fighter": 7
		}

	if map_name.ends_with("-3"):
		return {
			"nexar_fighter": 13,
			"nexar_destroyer": 13,
			"nexar_warlord": 13,
			"void_reaper": 13
		}

	if map_name.ends_with("-4"):
		return {
			"void_predator": 7,
			"abyss_guardian": 7
		}

	if map_name.ends_with("-5"):
		return {
			"void_predator": 9,
			"void_ravager": 9
		}

	# PVP, BOSS ve başka özel haritalara bu normal-harita limiti uygulanmaz.
	return {}


func _limit_persistent_normal_npcs(rows: Array, map_name: String) -> Array:
	var caps := _normal_npc_caps_for_map(map_name)
	if caps.is_empty():
		return rows

	var counts: Dictionary = {}
	var limited: Array = []

	for row in rows:
		if not (row is Dictionary):
			continue

		var npc_type := str(row.get("npc_type", ""))
		if not caps.has(npc_type):
			continue

		var used := int(counts.get(npc_type, 0))
		var max_allowed := int(caps[npc_type])

		if used >= max_allowed:
			continue

		limited.append(row)
		counts[npc_type] = used + 1

	return limited


func _is_boss_npc(type_name:String) -> bool:
	return type_name in ["void_guardian","void_predator","void_reaper","void_ravager","abyss_guardian"]

func _filter_boss_npcs_for_map(rows:Array, map_name:String) -> Array:
	# Normal haritalardaki Boss Alien varyantları npc_type ile değil is_boss alanıyla ayrılır.
	# Bu fonksiyon artık serverdan gelen normal-map NPC satırlarını silmez.
	return rows

func _allowed_npc_types_for_map(map_name: String) -> Array[String]:
	# Harita adı örn. "2-3" -> suffix = 3.
	# Ayrı bir _map_suffix() fonksiyonuna bağlı değil; parse hatasını önler.
	var parts: PackedStringArray = map_name.split("-")
	if parts.size() < 2:
		return []
	var suffix: int = int(parts[parts.size() - 1])
	match suffix:
		1:
			return ["zyron_raider"]
		2:
			return ["zyron_raider", "nexar_fighter"]
		3:
			return ["nexar_fighter", "nexar_destroyer", "nexar_warlord", "void_reaper"]
		4:
			return ["void_predator", "abyss_guardian"]
		5:
			return ["void_predator", "void_ravager"]
		_:
			return []


func _npc_exact_limits_for_map(map_name: String) -> Dictionary:
	var parts: PackedStringArray = map_name.split("-")
	if parts.size() < 2:
		return {}
	var suffix: int = int(parts[parts.size() - 1])
	match suffix:
		1:
			return {"zyron_raider": {"normal": 30, "boss": 10}}
		2:
			return {
				"zyron_raider": {"normal": 20, "boss": 6},
				"nexar_fighter": {"normal": 20, "boss": 6}
			}
		3:
			return {
				"nexar_fighter": {"normal": 20, "boss": 6},
				"nexar_destroyer": {"normal": 20, "boss": 6},
				"nexar_warlord": {"normal": 20, "boss": 6},
				"void_reaper": {"normal": 10, "boss": 3}
			}
		4:
			return {
				"void_predator": {"normal": 30, "boss": 10},
				"abyss_guardian": {"normal": 15, "boss": 5}
			}
		5:
			return {
				"void_predator": {"normal": 30, "boss": 10},
				"void_ravager": {"normal": 15, "boss": 5}
			}
		_:
			return {}


func _strict_filter_npc_rows(rows: Array, map_name: String) -> Array:
	var limits: Dictionary = _npc_exact_limits_for_map(map_name)
	if limits.is_empty():
		return []

	var counts: Dictionary = {}
	var result: Array = []
	var sorted_rows: Array = rows.duplicate()

	sorted_rows.sort_custom(func(a, b):
		return str(a.get("npc_id", "")) < str(b.get("npc_id", ""))
	)

	for row in sorted_rows:
		if not (row is Dictionary):
			continue
		if not bool(row.get("alive", true)):
			continue

		var npc_type := str(row.get("npc_type", ""))
		if not limits.has(npc_type):
			continue

		var is_boss: bool = bool(row.get("is_boss", false))
		var kind: String = "boss" if is_boss else "normal"
		var type_limits: Dictionary = limits[npc_type]
		var max_allowed: int = int(type_limits.get(kind, 0))
		var counter_key: String = npc_type + ":" + kind
		var used: int = int(counts.get(counter_key, 0))

		if used >= max_allowed:
			continue

		counts[counter_key] = used + 1
		result.append(row)

	return result


func _debug_boss_rows(rows: Array, stage: String) -> void:
	var total: int = 0
	var boss_total: int = 0
	var by_type: Dictionary = {}
	for row in rows:
		if not (row is Dictionary):
			continue
		total += 1
		if bool(row.get("is_boss", false)):
			boss_total += 1
			var npc_type: String = str(row.get("npc_type", ""))
			by_type[npc_type] = int(by_type.get(npc_type, 0)) + 1
	print("[BOSS DEBUG] ", stage, " | harita=", current_map_name, " | toplam=", total, " | boss=", boss_total, " | turler=", by_type)


func _debug_scene_bosses() -> void:
	var scene_total: int = 0
	var scene_boss_total: int = 0
	var by_type: Dictionary = {}
	for child in npc_container.get_children():
		if not (child is SpaceNPC):
			continue
		scene_total += 1
		if bool(child.get_meta("is_boss", false)):
			scene_boss_total += 1
			var npc_type: String = str(child.get_meta("base_npc_type", child.npc_name))
			by_type[npc_type] = int(by_type.get(npc_type, 0)) + 1
			var shown_name: String = "<etiket yok>"
			var label = child.get_node_or_null("NameLabel")
			if label is Label:
				shown_name = label.text
			print("[BOSS DEBUG] SAHNE BOSS | id=", str(child.get_meta("world_npc_id", "")), " | type=", npc_type, " | ad=", shown_name, " | pos=", child.global_position)
	print("[BOSS DEBUG] SAHNE OZET | harita=", current_map_name, " | toplam=", scene_total, " | boss=", scene_boss_total, " | turler=", by_type)


func _load_persistent_npcs() -> void:
	# Offline mod: NPC'ler server world-state yerine yerel tablo üzerinden oluşturulur.
	# Her harita geçişinde mevcut NPC'ler temizlenir ve yerel spawn tablosu kullanılır.
	_spawn_map_npcs()
	_debug_scene_bosses()

func _push_attacked_npc_state(npc) -> void:
	# Offline modda NPC state sunucuya gönderilmez.
	return

func _find_local_npc_by_world_id(nid: String):
	for npc in npc_container.get_children():
		if is_instance_valid(npc) and str(npc.get_meta("world_npc_id", "")) == nid:
			return npc
	return null


func _refresh_server_npc_snapshot() -> void:
	pass
func _npc_needs_sync(npc, nid: String, force_all: bool) -> bool:
	if force_all or not npc_last_sent.has(nid):
		return true

	var old: Dictionary = npc_last_sent[nid]
	var old_pos := Vector2(float(old.get("x", 0.0)), float(old.get("y", 0.0)))
	var moved: bool = npc.global_position.distance_to(old_pos) >= NPC_MOVE_THRESHOLD
	var hp_changed: bool = absf(float(old.get("health", npc.health)) - float(npc.health)) >= 0.5
	var shield_changed: bool = absf(float(old.get("shield", npc.shield)) - float(npc.shield)) >= 0.5
	var alive_now: bool = float(npc.health) > 0.0
	var alive_changed: bool = bool(old.get("alive", alive_now)) != alive_now
	var age_sec: float = float(Time.get_ticks_msec() - int(old.get("sent_at", 0))) / 1000.0

	return moved or hp_changed or shield_changed or alive_changed or age_sec >= NPC_HEARTBEAT


func _sync_live_npcs_batch() -> void:
	pass
func _setup_radiation_ui() -> void:
	if radiation_warning != null and is_instance_valid(radiation_warning):
		return

	radiation_warning = Label.new()
	radiation_warning.name = "RadiationWarning"
	radiation_warning.text = ""
	radiation_warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	radiation_warning.add_theme_font_size_override("font_size", 22)
	radiation_warning.add_theme_color_override("font_color", Color(1.0, 0.25, 0.18, 1.0))
	radiation_warning.set_anchors_preset(Control.PRESET_CENTER_TOP)
	radiation_warning.position = Vector2(-280.0, 78.0)
	radiation_warning.size = Vector2(560.0, 70.0)
	radiation_warning.mouse_filter = Control.MOUSE_FILTER_IGNORE
	radiation_warning.visible = false

	var hud := get_node_or_null("HUD")
	if hud != null:
		hud.add_child(radiation_warning)


func _process_radiation(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return

	if bool(player.get("is_destroyed")):
		_reset_radiation()
		return

	var pos: Vector2 = player.global_position

	if WORLD_RECT.has_point(pos):
		_reset_radiation()
		return

	radiation_time += delta
	radiation_tick += delta

	var percent: float = clampf(
		0.01 + floorf(radiation_time) * 0.01,
		0.01,
		RADIATION_MAX_PERCENT
	)

	var safe_target := Vector2(
		clampf(pos.x, WORLD_RECT.position.x + 80.0, WORLD_RECT.end.x - 80.0),
		clampf(pos.y, WORLD_RECT.position.y + 80.0, WORLD_RECT.end.y - 80.0)
	)

	var arrow: String = _radiation_arrow(safe_target - pos)

	if radiation_warning != null and is_instance_valid(radiation_warning):
		radiation_warning.visible = true
		radiation_warning.text = "RADYASYON BÖLGESİ  %d%% MAX HP/sn   %s  HARİTAYA DÖN" % [
			int(percent * 100.0),
			arrow
		]

	while radiation_tick >= RADIATION_TICK_SECONDS:
		radiation_tick -= RADIATION_TICK_SECONDS

		if player == null or not is_instance_valid(player):
			return

		var damage: float = player.max_health * percent

		if player.has_method("take_radiation_damage"):
			player.call("take_radiation_damage", damage)
		elif player.has_method("take_damage"):
			player.call("take_damage", damage)


func _reset_radiation() -> void:
	radiation_time = 0.0
	radiation_tick = 0.0

	if radiation_warning != null and is_instance_valid(radiation_warning):
		radiation_warning.visible = false
		radiation_warning.text = ""


func _radiation_arrow(direction: Vector2) -> String:
	if direction.length_squared() < 0.001:
		return ""

	var angle := direction.angle()

	if angle >= -PI / 8.0 and angle < PI / 8.0:
		return "→"
	elif angle >= PI / 8.0 and angle < 3.0 * PI / 8.0:
		return "↘"
	elif angle >= 3.0 * PI / 8.0 and angle < 5.0 * PI / 8.0:
		return "↓"
	elif angle >= 5.0 * PI / 8.0 and angle < 7.0 * PI / 8.0:
		return "↙"
	elif angle >= 7.0 * PI / 8.0 or angle < -7.0 * PI / 8.0:
		return "←"
	elif angle >= -7.0 * PI / 8.0 and angle < -5.0 * PI / 8.0:
		return "↖"
	elif angle >= -5.0 * PI / 8.0 and angle < -3.0 * PI / 8.0:
		return "↑"
	return "↗"


# ============================================================
# BONUS BOX
# ============================================================
func _setup_bonus_box_system() -> void:
	bonus_box_texture = load("res://assets/bonusbox/bonusbox.png")
	if bonus_box_container != null and is_instance_valid(bonus_box_container):
		return
	bonus_box_container = Node2D.new()
	bonus_box_container.name = "BonusBoxes"
	$World.add_child(bonus_box_container)


func _map_uses_normal_bonus_boxes(map_name: String) -> bool:
	if map_name == "BOSS":
		return false
	for suffix in ["-1", "-2", "-3", "-4", "-5", "-6"]:
		if map_name.ends_with(suffix):
			return true
	return false


func _rebuild_bonus_boxes() -> void:
	if bonus_box_container == null or not is_instance_valid(bonus_box_container):
		_setup_bonus_box_system()

	bonus_box_generation += 1
	var generation := bonus_box_generation

	for child in bonus_box_container.get_children():
		child.queue_free()

	if current_map_name != "BOSS" and not _map_uses_normal_bonus_boxes(current_map_name):
		return

	var count := BOSS_BONUS_BOX_COUNT
	if current_map_name != "BOSS":
		match current_map_name:
			"1-1", "2-1", "3-1":
				count = 60
			"1-2", "2-2", "3-2":
				count = 80
			"1-3", "2-3", "3-3":
				count = 100
			"1-4", "2-4", "3-4":
				count = 120
			"1-5", "2-5", "3-5":
				count = 150
			"1-6", "2-6", "3-6":
				count = 180
			_:
				count = NORMAL_BONUS_BOX_COUNT
	for i in range(count):
		_spawn_one_bonus_box(generation)


func _spawn_one_bonus_box(generation: int) -> void:
	if generation != bonus_box_generation:
		return
	if bonus_box_container == null or not is_instance_valid(bonus_box_container):
		return

	var box := Area2D.new()
	box.set_script(BONUS_BOX_SCRIPT)
	box.name = "BonusBox"
	bonus_box_container.add_child(box)

	var margin := 550.0
	var x := rng.randf_range(WORLD_RECT.position.x + margin, WORLD_RECT.end.x - margin)
	var y := rng.randf_range(WORLD_RECT.position.y + margin, WORLD_RECT.end.y - margin)
	box.global_position = Vector2(x, y)

	var secret_box := current_map_name == "BOSS"
	box.call("setup_bonus_box", player, bonus_box_texture, secret_box)
	box.connect("collected", Callable(self, "_on_bonus_box_collected").bind(generation))


func _on_bonus_box_collected(generation: int) -> void:
	if generation != bonus_box_generation:
		return

	var timer := get_tree().create_timer(rng.randf_range(BONUS_BOX_RESPAWN_MIN, BONUS_BOX_RESPAWN_MAX))
	timer.timeout.connect(
		func() -> void:
			if generation == bonus_box_generation:
				_spawn_one_bonus_box(generation),
		CONNECT_ONE_SHOT
	)


func _build_quest_tracker() -> void:
	quest_tracker_panel = Panel.new()
	quest_tracker_panel.name = "QuestTracker"
	quest_tracker_panel.position = Vector2(18, 82)
	quest_tracker_panel.size = Vector2(320, 54)
	quest_tracker_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$HUD.add_child(quest_tracker_panel)
	quest_tracker_label = Label.new()
	quest_tracker_label.position = Vector2(10, 8)
	quest_tracker_label.size = Vector2(300, 40)
	quest_tracker_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quest_tracker_label.add_theme_font_size_override("font_size", 14)
	quest_tracker_panel.add_child(quest_tracker_label)
	_refresh_quest_tracker()


func _refresh_quest_tracker() -> void:
	if quest_tracker_label == null:
		return
	var active := QuestSystem.get_active_quests()
	if active.is_empty():
		quest_tracker_label.text = "Aktif görev yok"
		return
	var quest_id := str(active[0])
	var quest := QuestSystem.get_quest(quest_id)
	quest_tracker_label.text = "%s — %d/%d" % [
		str(quest.get("title", "Görev")),
		QuestSystem.get_progress(quest_id),
		QuestSystem.get_target(quest_id)
	]
# ==========================================================================
# NOVAGATE GALAXY GATE - X1 PORTALI VE ARAYUZ
# ==========================================================================

func _setup_galaxy_gate_ui() -> void:
	if galaxy_gate_ui != null and is_instance_valid(galaxy_gate_ui):
		return
	galaxy_gate_ui = GalaxyGateUI.new()
	galaxy_gate_ui.name = "GalaxyGateUI"
	galaxy_gate_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	galaxy_gate_ui.visible = false
	$HUD.add_child(galaxy_gate_ui)
	if galaxy_gate_ui.has_signal("gate_entered"):
		galaxy_gate_ui.connect("gate_entered", Callable(self, "enter_galaxy_gate"))

	galaxy_gate_prompt = Label.new()
	galaxy_gate_prompt.name = "GalaxyGatePrompt"
	galaxy_gate_prompt.position = Vector2(18, 142)
	galaxy_gate_prompt.size = Vector2(380, 26)
	galaxy_gate_prompt.add_theme_font_size_override("font_size", 15)
	galaxy_gate_prompt.add_theme_color_override("font_color", Color(0.4, 0.95, 1.0))
	galaxy_gate_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	galaxy_gate_prompt.visible = false
	$HUD.add_child(galaxy_gate_prompt)


func _create_galaxy_gate_portal() -> void:
	# X1 haritasinda, oyuncunun sirket ussunun cevresinde gate portali.
	# Portal YALNIZCA gate aktifse olusturulur (BOLUM 2 / BOLUM 14 / BOLUM 24).
	_clear_galaxy_gate_portal()
	var company: String = GlobalState.company
	if not GalaxyGateManager.portal_visible_on_map(current_map_name, company):
		return
	var gate_id: String = GalaxyGateManager.active_gate_for_company(company)
	if gate_id.is_empty():
		return
	var portal := Area2D.new()
	portal.name = "GalaxyGatePortal_%s" % gate_id.to_upper()
	portal.position = GalaxyGateManager.gate_portal_position(company)
	portal.collision_layer = 4
	portal.collision_mask = 1
	portal.input_pickable = true
	portal.set_meta("galaxy_gate_id", gate_id)
	var sprite := Sprite2D.new()
	sprite.texture = PORTAL_TEXTURE
	sprite.scale = Vector2(0.95, 0.95)
	sprite.modulate = Color(1.0, 0.72, 0.25)
	portal.add_child(sprite)
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 170.0
	shape_node.shape = circle
	portal.add_child(shape_node)
	var label := Label.new()
	label.text = "GALAXY GATE %s" % GalaxyGateManager.GateData.display_name(gate_id)
	label.position = Vector2(-140, 128)
	label.size = Vector2(280, 26)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.35))
	portal.add_child(label)
	portal.input_event.connect(_on_galaxy_gate_portal_input_event)
	portal_container.add_child(portal)
	galaxy_gate_portal = portal
	print("GALAXY_GATE_X1_PORTAL_CREATED gate=", gate_id, " map=", current_map_name,
		" position=", portal.position)


func _clear_galaxy_gate_portal() -> void:
	if galaxy_gate_portal != null and is_instance_valid(galaxy_gate_portal):
		galaxy_gate_portal.queue_free()
	galaxy_gate_portal = null
	if galaxy_gate_prompt != null:
		galaxy_gate_prompt.visible = false


func _minimap_portals() -> Array:
	# Minimap'e normal gecis kapilari + gate portali birlikte verilir.
	var combined: Array = []
	for portal in active_portals:
		combined.append(portal)
	if galaxy_gate_portal != null and is_instance_valid(galaxy_gate_portal):
		combined.append(galaxy_gate_portal)
	return combined


func _on_galaxy_gate_portal_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	open_galaxy_gate_ui()
	get_viewport().set_input_as_handled()


func _galaxy_gate_interaction_available() -> bool:
	if galaxy_gate_portal == null or not is_instance_valid(galaxy_gate_portal):
		return false
	if player == null or not is_instance_valid(player):
		return false
	return player.global_position.distance_to(galaxy_gate_portal.global_position) <= BASE_SAFE_RADIUS


func _update_galaxy_gate_prompt() -> void:
	if galaxy_gate_prompt == null:
		return
	if galaxy_gate_portal == null or not is_instance_valid(galaxy_gate_portal):
		galaxy_gate_prompt.visible = false
		return
	var near: bool = _galaxy_gate_interaction_available()
	galaxy_gate_prompt.visible = near and (galaxy_gate_ui == null or not galaxy_gate_ui.visible)
	if near:
		galaxy_gate_prompt.text = "GALAXY GATE  -  [G] veya portala tikla"


func open_galaxy_gate_ui() -> void:
	if galaxy_gate_ui == null or not is_instance_valid(galaxy_gate_ui):
		_setup_galaxy_gate_ui()
	if galaxy_gate_ui == null:
		return
	if galaxy_gate_ui.has_method("open"):
		galaxy_gate_ui.call("open")


func _close_galaxy_gate_ui() -> void:
	if galaxy_gate_ui != null and is_instance_valid(galaxy_gate_ui) and galaxy_gate_ui.has_method("close"):
		galaxy_gate_ui.call("close")


func enter_galaxy_gate(gate_id: String) -> void:
	# X1 -> Galaxy Gate instance gecisi. Mevcut sahne degistirme akisi kullanilir.
	if not GalaxyGateManager.portal_visible_on_map(current_map_name, GlobalState.company):
		return
	var started: Dictionary = GalaxyGateManager.start_run(gate_id)
	if not bool(started.get("ok", false)):
		print("GALAXY_GATE_ENTER_FAILED: ", str(started.get("message", "")))
		return
	var run: Dictionary = started.get("run", {}) if started.get("run", {}) is Dictionary else {}
	print("GALAXY_GATE_ENTER gate=", gate_id, " instance=", str(run.get("instance_id", "")))
	GlobalState.save_game()
	get_tree().call_deferred("change_scene_to_file", "res://scenes/GalaxyGateArena.tscn")


func apply_player_settings() -> void:
	# Ayarlar mevcut gorunur sistemlere uygulanir (fake toggle yok).
	var gameplay = SettingsManager.get_setting("gameplay", "", {})
	if not (gameplay is Dictionary):
		gameplay = {}
	if coord_label != null:
		coord_label.visible = bool((gameplay as Dictionary).get("show_coordinates", true))
	if minimap != null:
		minimap.visible = bool((gameplay as Dictionary).get("show_minimap", true))
		var minimap_scale: float = maxf(0.5, float((gameplay as Dictionary).get("minimap_scale", 1.0)))
		minimap.scale = Vector2(minimap_scale, minimap_scale)
	_apply_graphics_quality()
	_apply_map_object_scale()
	_apply_name_visibility()


func _apply_graphics_quality() -> void:
	var visual_manager = get_node_or_null("World/MapVisuals")
	if visual_manager == null or not visual_manager.has_method("set_layer_visibility"):
		return
	var quality: String = str(SettingsManager.get_setting("graphics", "quality", "high")).to_lower()
	var hide_layers: Array = []
	match quality:
		"low":
			hide_layers = ["nebula", "fog", "clouds_bg", "clouds_top"]
		"medium":
			hide_layers = ["fog", "clouds_top"]
		_:
			hide_layers = []
	for layer_type in ["background", "stars", "nebula", "fog", "clouds_bg", "clouds_top", "objects"]:
		visual_manager.call("set_layer_visibility", layer_type, not hide_layers.has(layer_type))
	if visual_manager.has_method("set_parallax_enabled"):
		visual_manager.call("set_parallax_enabled", quality != "low")


func _apply_map_object_scale() -> void:
	var visual_manager = get_node_or_null("World/MapVisuals")
	if visual_manager == null:
		return
	var scale_value: float = float(SettingsManager.get_setting("graphics", "map_scale", 1.0))
	if scale_value <= 0.0:
		scale_value = 1.0
	visual_manager.scale = Vector2(scale_value, scale_value)


func _apply_name_visibility() -> void:
	# NPC / uzak oyuncu isim etiketleri mevcut sinif API'leriyle guncellenir.
	var show_npc_names: bool = bool(SettingsManager.get_setting("gameplay", "show_npc_names", true))
	for child in npc_container.get_children():
		if child is SpaceNPC:
			(child as SpaceNPC).apply_name_visibility(show_npc_names)
	if remote_players_root != null and is_instance_valid(remote_players_root):
		var show_player_names: bool = bool(SettingsManager.get_setting("gameplay", "show_player_names", true))
		for child in remote_players_root.get_children():
			if child is RemoteShip:
				(child as RemoteShip).apply_name_visibility(show_player_names)
