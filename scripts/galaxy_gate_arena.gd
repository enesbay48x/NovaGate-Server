extends Node2D
class_name GalaxyGateArena

# ==========================================================================
# NOVAGATE GALAXY GATE ARENA (instance sahnesi)
# --------------------------------------------------------------------------
# Her kat ayri bir gate map'idir: gg_alpha_1, gg_alpha_2, gg_gamma_5 ...
# Bu sahne normal X1 map akisindan BAGIMSIZDIR; normal NPC spawn sistemi
# burada kullanilmaz. NPC'ler mevcut npc.gd / npc.tscn varliklaridir ve
# odullerini mevcut npc.gd odul sistemi uzerinden verir (BOLUM 8 / BOLUM 28).
#
# Kat/dalga ilerlemesi GalaxyGateManager'da tutulur; sahne yalnizca
# gorunurluk + savas + gecis kapilarini yonetir.
# ==========================================================================

const GateData := preload("res://scripts/galaxy_gate_data.gd")
const NPC_SCENE: PackedScene = preload("res://scenes/npc.tscn")
const NPC_LASER_EFFECT_SCENE: PackedScene = preload("res://scenes/npc_laser_effect.tscn")
const PORTAL_TEXTURE: Texture2D = preload("res://assets/m2_tp.png")

const LASER_EFFECTS: Array[Texture2D] = [
	preload("res://assets/ammo/laser1.png"),
	preload("res://assets/ammo/laser2.png"),
	preload("res://assets/ammo/laser3.png"),
	preload("res://assets/ammo/laser4.png"),
	preload("res://assets/ammo/laser5.png"),
	preload("res://assets/ammo/laser6.png")
]

# Combat sabitleri main.gd ile ayni davranisi korur.
const AMMO_MULTIPLIERS: Array[float] = [1.0, 1.5, 2.25, 3.0, 1.0, 4.0]
const PLAYER_LASER_RANGE: float = 620.0
const SAB_SHIELD_FACTOR: float = 2.0
const PLAYER_LASER_PROJECTILE_SPEED: float = 1850.0
const PLAYER_LASER_MIN_TRAVEL_TIME: float = 0.10
const PLAYER_LASER_MAX_TRAVEL_TIME: float = 0.32

const ARENA_WORLD_RECT := Rect2(-6200.0, -4600.0, 12400.0, 9200.0)
const SPAWN_MIN_DISTANCE: float = 950.0
const SPAWN_MAX_DISTANCE: float = 2500.0
const ARENA_BG_COLOR := Color(0.06, 0.08, 0.16, 1.0)

var gate_id: String = ""
var floor_number: int = 1
var wave_number: int = 1
var map_id: String = ""
var instance_id: String = ""

var player: PlayerShip = null
var arena_root: Node2D = null
var npc_root: Node2D = null
var portal_root: Node2D = null
var laser_root: Node2D = null
var selected_npc: SpaceNPC = null
var rng := RandomNumberGenerator.new()

var alive_npcs: int = 0
var wave_active: bool = false
var wave_cleared: bool = false
var travel_busy: bool = false
var travel_portals: Array[Area2D] = []

var hud: CanvasLayer = null
var header_label: Label = null
var wave_label: Label = null
var hint_label: Label = null
var message_label: Label = null
var health_bar: ProgressBar = null
var shield_bar: ProgressBar = null

var death_overlay: ColorRect = null
var death_panel: Panel = null
var death_title: Label = null
var repair_button: Button = null
var return_button: Button = null
var repair_busy: bool = false


func _ready() -> void:
	rng.randomize()
	var run: Dictionary = GalaxyGateManager.resume_run()
	if run.is_empty():
		# Gecersiz giris: X1'e geri don (sahte arena baslatilmaz).
		_return_to_x1()
		return
	gate_id = str(run.get("gate_id", ""))
	instance_id = str(run.get("instance_id", ""))
	floor_number = clampi(int(run.get("floor", 1)), 1, GateData.max_floor(gate_id))
	wave_number = clampi(int(run.get("wave", 1)), 1, GateData.WAVES_PER_FLOOR)
	map_id = GateData.gate_map_id(gate_id, floor_number)
	print("GALAXY_GATE_ARENA_LOADED map=", map_id, " instance=", instance_id,
		" floor=", floor_number, " wave=", wave_number)
	_build_hud()
	_build_arena()
	_setup_player()
	_apply_arena_settings()
	_start_wave()


func _build_hud() -> void:
	# Gate instance HUD'i mevcut NovaGate stilinde, sahne dosyasi
	# degistirilmeden calisma aninda kurulur.
	hud = CanvasLayer.new()
	hud.name = "GateHUD"
	add_child(hud)

	var top := Panel.new()
	top.name = "TopPanel"
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 8.0
	top.offset_top = 8.0
	top.offset_right = -8.0
	top.offset_bottom = 74.0
	top.add_theme_stylebox_override("panel", _panel_style())
	hud.add_child(top)

	header_label = Label.new()
	header_label.name = "HeaderLabel"
	header_label.position = Vector2(16.0, 6.0)
	header_label.size = Vector2(860.0, 28.0)
	header_label.add_theme_font_size_override("font_size", 20)
	header_label.add_theme_color_override("font_color", Color(0.35, 0.92, 1.0))
	top.add_child(header_label)

	wave_label = Label.new()
	wave_label.name = "WaveLabel"
	wave_label.position = Vector2(16.0, 34.0)
	wave_label.size = Vector2(860.0, 26.0)
	wave_label.add_theme_font_size_override("font_size", 17)
	wave_label.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	top.add_child(wave_label)

	var bottom := Panel.new()
	bottom.name = "BottomPanel"
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 8.0
	bottom.offset_top = -74.0
	bottom.offset_right = -8.0
	bottom.offset_bottom = -8.0
	bottom.add_theme_stylebox_override("panel", _panel_style())
	hud.add_child(bottom)

	health_bar = ProgressBar.new()
	health_bar.name = "Health"
	health_bar.position = Vector2(16.0, 12.0)
	health_bar.size = Vector2(420.0, 20.0)
	health_bar.show_percentage = false
	bottom.add_child(health_bar)

	shield_bar = ProgressBar.new()
	shield_bar.name = "Shield"
	shield_bar.position = Vector2(16.0, 38.0)
	shield_bar.size = Vector2(420.0, 20.0)
	shield_bar.show_percentage = false
	bottom.add_child(shield_bar)

	hint_label = Label.new()
	hint_label.name = "HintLabel"
	hint_label.position = Vector2(16.0, 8.0)
	hint_label.size = Vector2(600.0, 22.0)
	hint_label.add_theme_font_size_override("font_size", 14)
	hint_label.add_theme_color_override("font_color", Color(0.7, 0.85, 0.95))
	add_child(hint_label)

	message_label = Label.new()
	message_label.name = "MessageLabel"
	message_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	message_label.offset_left = -320.0
	message_label.offset_top = 92.0
	message_label.offset_right = 320.0
	message_label.offset_bottom = 126.0
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.add_theme_font_size_override("font_size", 22)
	message_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.6))
	message_label.visible = false
	add_child(message_label)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.05, 0.09, 0.88)
	style.border_color = Color(0.10, 0.62, 0.85, 0.95)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(4.0)
	return style


func _build_arena() -> void:
	arena_root = get_node_or_null("ArenaRoot")
	if arena_root == null:
		arena_root = Node2D.new()
		arena_root.name = "ArenaRoot"
		add_child(arena_root)

	var background := Polygon2D.new()
	background.name = "Background"
	background.polygon = PackedVector2Array([
		ARENA_WORLD_RECT.position,
		Vector2(ARENA_WORLD_RECT.end.x, ARENA_WORLD_RECT.position.y),
		ARENA_WORLD_RECT.end,
		Vector2(ARENA_WORLD_RECT.position.x, ARENA_WORLD_RECT.end.y)
	])
	background.color = ARENA_BG_COLOR
	background.z_index = -1000
	arena_root.add_child(background)

	var ring := Line2D.new()
	ring.name = "ArenaRing"
	ring.width = 7.0
	ring.default_color = Color(0.22, 0.78, 1.0, 0.85)
	var ring_points: PackedVector2Array = []
	for step in range(0, 361, 10):
		var angle: float = deg_to_rad(float(step))
		ring_points.append(Vector2(cos(angle) * 4700.0, sin(angle) * 3500.0))
	ring.points = ring_points
	ring.closed = true
	ring.z_index = -50
	arena_root.add_child(ring)

	npc_root = get_node_or_null("ArenaRoot/NPCs")
	if npc_root == null:
		npc_root = Node2D.new()
		npc_root.name = "NPCs"
		arena_root.add_child(npc_root)

	laser_root = get_node_or_null("ArenaRoot/Lasers")
	if laser_root == null:
		laser_root = Node2D.new()
		laser_root.name = "Lasers"
		arena_root.add_child(laser_root)

	portal_root = get_node_or_null("ArenaRoot/Portals")
	if portal_root == null:
		portal_root = Node2D.new()
		portal_root.name = "Portals"
		arena_root.add_child(portal_root)


func _setup_player() -> void:
	player = get_node_or_null("PlayerShip") as PlayerShip
	if player == null:
		# Sahne dosyasinda yoksa mevcut PlayerShip bileseni kullanilir.
		player = PlayerShip.new()
		player.name = "PlayerShip"
		add_child(player)
		var shape := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = 38.0
		shape.shape = circle
		player.add_child(shape)
	if not player.is_in_group("player"):
		player.add_to_group("player")
	player.visible = true
	player.global_position = GateData.GATE_ENTRY_POSITION
	player.world_rect = ARENA_WORLD_RECT
	player.set_safe_zone(false)

	var camera := player.get_node_or_null("Camera2D") as Camera2D
	if camera == null:
		camera = Camera2D.new()
		camera.name = "Camera2D"
		player.add_child(camera)
	camera.zoom = Vector2(0.6, 0.6)
	camera.position_smoothing_enabled = true
	camera.make_current()

	if not player.fire_requested.is_connected(_on_fire_requested):
		player.fire_requested.connect(_on_fire_requested)
	if not player.selection_requested.is_connected(_on_selection_requested):
		player.selection_requested.connect(_on_selection_requested)
	if not player.stats_changed.is_connected(_on_stats_changed):
		player.stats_changed.connect(_on_stats_changed)
	if not player.ship_destroyed.is_connected(_on_player_ship_destroyed):
		player.ship_destroyed.connect(_on_player_ship_destroyed)
	health_bar.max_value = maxf(player.max_health, 1.0)
	health_bar.value = player.health
	shield_bar.max_value = maxf(player.max_shield, 1.0)
	shield_bar.value = player.shield


func _apply_arena_settings() -> void:
	# Oyuncu ayarlari gate instance'inda da gecerli olur.
	var show_damage: bool = bool(SettingsManager.get_setting("gameplay", "damage_numbers", true))
	player.set_meta("show_damage_numbers", show_damage)
	_apply_map_object_scale()


func _apply_map_object_scale() -> void:
	var scale_value: float = float(SettingsManager.get_setting("graphics", "map_scale", 1.0))
	if scale_value <= 0.0:
		scale_value = 1.0
	if arena_root != null:
		arena_root.scale = Vector2(scale_value, scale_value)


func _random_spawn_position() -> Vector2:
	# Oyuncudan ve giris noktasindan uzakta, arena sinirlari icinde dogar.
	for attempt in range(24):
		var angle: float = rng.randf_range(0.0, TAU)
		var distance: float = rng.randf_range(SPAWN_MIN_DISTANCE, SPAWN_MAX_DISTANCE)
		var candidate: Vector2 = GateData.GATE_ENTRY_POSITION + Vector2(cos(angle), sin(angle)) * distance
		if not ARENA_WORLD_RECT.has_point(candidate):
			continue
		return candidate
	return GateData.GATE_ENTRY_POSITION + Vector2(0.0, -SPAWN_MIN_DISTANCE)


func _start_wave() -> void:
	# Ayni dalga iki kere spawn edilemez (BOLUM 31).
	if not GalaxyGateManager.wave_can_spawn():
		wave_active = false
		wave_cleared = alive_npcs <= 0
		if wave_cleared:
			_show_clear_portals()
		_update_hud()
		return
	wave_number = clampi(int(GalaxyGateManager.run_snapshot(gate_id).get("wave", 1)), 1, GateData.WAVES_PER_FLOOR)
	var wave_def: Dictionary = GalaxyGateManager.current_wave_definition()
	var ids_raw = wave_def.get("npc_ids", [])
	var ids: Array = ids_raw if ids_raw is Array else []
	var difficulty: float = float(wave_def.get("difficulty", 1.0)) * GateData.difficulty_multiplier(gate_id)
	alive_npcs = 0
	for index in range(mini(ids.size(), GateData.NPCS_PER_WAVE)):
		_spawn_gate_npc(str(ids[index]), index, difficulty)
	if alive_npcs <= 0:
		# NPC uretilemedi: guvenli cikis yolu (asla kilitli kalma).
		wave_cleared = true
		_show_clear_portals()
		_update_hud()
		return
	GalaxyGateManager.mark_wave_spawned()
	wave_active = true
	wave_cleared = false
	print("GALAXY_GATE_WAVE_START map=", map_id, " wave=", wave_number, " npc=", alive_npcs)
	_update_hud()


func _spawn_gate_npc(type_name: String, index: int, difficulty: float) -> void:
	# 5'ten fazla NPC spawn edilemez (BOLUM 31).
	# queue_free edilmis (silinmeyi bekleyen) NPC'ler sayilmaz.
	var live_count: int = 0
	for child in npc_root.get_children():
		if not child.is_queued_for_deletion():
			live_count += 1
	if live_count >= GateData.NPCS_PER_WAVE:
		return
	var npc := NPC_SCENE.instantiate() as SpaceNPC
	if npc == null:
		return
	npc.name = "GG_%s_F%d_W%d_%s_%d" % [gate_id.to_upper(), floor_number, wave_number, type_name, index]
	npc.global_position = _random_spawn_position()
	# Mevcut NPC yapisi: tip/hp/hiz npc.gd npc_stats uzerinden uygulanir.
	npc.configure(type_name, 5000.0, 120.0)
	# Gate NPC kimligi: normal X1 spawn'i ile karismaz (BOLUM 28).
	npc.set_meta("gate_id", gate_id)
	npc.set_meta("gate_floor", floor_number)
	npc.set_meta("gate_wave", wave_number)
	npc.set_meta("gate_instance_id", instance_id)
	npc.set_meta("gate_npc_index", index)
	if not npc.destroyed.is_connected(_on_gate_npc_destroyed):
		npc.destroyed.connect(_on_gate_npc_destroyed)
	if not npc.attack_requested.is_connected(_on_npc_attack_requested):
		npc.attack_requested.connect(_on_npc_attack_requested)
	npc_root.add_child(npc)
	_apply_gate_difficulty(npc, difficulty)
	alive_npcs += 1


func _apply_gate_difficulty(npc: SpaceNPC, difficulty: float) -> void:
	# Gate zorluk carpani mevcut NPC statlarina uygulanir (yeni NPC tipi yok).
	if difficulty <= 1.001 or not is_instance_valid(npc):
		return
	npc.max_health = maxf(1.0, npc.max_health * difficulty)
	npc.health = npc.max_health
	if npc.max_shield > 0.0:
		npc.max_shield = npc.max_shield * difficulty
		npc.shield = npc.max_shield
	npc.attack_damage = npc.attack_damage * difficulty
	if npc.damage_min > 0:
		npc.damage_min = int(float(npc.damage_min) * difficulty)
	if npc.damage_max > 0:
		npc.damage_max = int(float(npc.damage_max) * difficulty)
	var health_bar_node := npc.get_node_or_null("HealthBar") as ProgressBar
	if health_bar_node != null:
		health_bar_node.max_value = npc.max_health
		health_bar_node.value = npc.health
	var shield_bar_node := npc.get_node_or_null("ShieldBar") as ProgressBar
	if shield_bar_node != null:
		shield_bar_node.max_value = maxf(npc.max_shield, 1.0)
		shield_bar_node.value = npc.shield


func _update_hud() -> void:
	if header_label == null:
		return
	header_label.text = "GALAXY GATE %s   |   MAP %s" % [GateData.display_name(gate_id), map_id]
	wave_label.text = "FLOOR %d / %d     WAVE %d / %d     NPC %d / %d" % [
		floor_number, GateData.max_floor(gate_id),
		wave_number, GateData.WAVES_PER_FLOOR,
		alive_npcs, GateData.NPCS_PER_WAVE
	]
	if hint_label != null:
		hint_label.text = "Hedef sec: SOL TIK   |   Otomatik ates: CTRL   |   Kapi: J / G   |   Cikis: ESC"


func _show_message(text_value: String, seconds: float = 2.5) -> void:
	if message_label == null:
		return
	message_label.text = text_value
	message_label.visible = true
	if seconds <= 0.0:
		return
	await get_tree().create_timer(seconds).timeout
	if message_label != null and message_label.text == text_value:
		message_label.visible = false


func _on_gate_npc_destroyed(_at_position: Vector2) -> void:
	# Mevcut npc.gd destroyed signal'i: odul zaten npc.gd tarafindan verildi.
	alive_npcs = maxi(0, alive_npcs - 1)
	_update_hud()
	if alive_npcs > 0 or not wave_active:
		return
	wave_active = false
	wave_cleared = true
	var result: Dictionary = GalaxyGateManager.complete_wave()
	_on_wave_completed(result)


func _on_wave_completed(result: Dictionary) -> void:
	var snapshot: Dictionary = GalaxyGateManager.run_snapshot(gate_id)
	wave_number = clampi(int(snapshot.get("wave", wave_number)), 1, GateData.WAVES_PER_FLOOR)
	floor_number = clampi(int(snapshot.get("floor", floor_number)), 1, GateData.max_floor(gate_id))
	_update_hud()
	if bool(result.get("gate_completed", false)):
		var rewards_text := str(result.get("rewards_text", ""))
		_show_message("GATE TAMAMLANDI", 3.0)
		_show_gate_complete_panel(rewards_text)
		return
	_show_message(str(result.get("message", "")), 2.5)
	_show_clear_portals(bool(result.get("floor_completed", false)))


func _clear_portals() -> void:
	for portal in travel_portals:
		if is_instance_valid(portal):
			portal.queue_free()
	travel_portals.clear()
	_clear_portal_buttons()


func _show_clear_portals(floor_completed: bool = false) -> void:
	# Dalga tamamen temizlendiginde 2 portal olusur (BOLUM 9 / BOLUM 10).
	# Wave tamamlanmadan next-wave portali olusamaz (BOLUM 31).
	if travel_busy or not wave_cleared:
		return
	if travel_portals.size() > 0:
		return
	_add_travel_portal(GateData.GATE_RETURN_PORTAL_POSITION, "X1'E DON", "return")
	_add_portal_button("X1'E DON", "return")
	if floor_completed:
		_add_travel_portal(GateData.GATE_NEXT_PORTAL_POSITION, "SONRAKI KAT", "next_floor")
		_add_portal_button("SONRAKI KAT", "next_floor")
	else:
		var next_label := "WAVE %d" % mini(wave_number + 1, GateData.WAVES_PER_FLOOR)
		_add_travel_portal(GateData.GATE_NEXT_PORTAL_POSITION, next_label, "next_wave")
		_add_portal_button(next_label, "next_wave")


func _add_travel_portal(position_value: Vector2, label_text: String, action: String) -> void:
	var portal := Area2D.new()
	portal.name = "GatePortal_%s" % action
	portal.position = position_value
	portal.collision_layer = 4
	portal.collision_mask = 1
	portal.set_meta("gate_action", action)
	var sprite := Sprite2D.new()
	sprite.texture = PORTAL_TEXTURE
	sprite.scale = Vector2(0.78, 0.78)
	portal.add_child(sprite)
	var shape_node := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 155.0
	shape_node.shape = circle
	portal.add_child(shape_node)
	var label := Label.new()
	label.text = label_text
	label.position = Vector2(-130.0, 120.0)
	label.size = Vector2(260.0, 26.0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 19)
	label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.6))
	portal.add_child(label)
	portal_root.add_child(portal)
	travel_portals.append(portal)


func _add_portal_button(label_text: String, action: String) -> void:
	# Mobil oyuncular icin: J tusu yerine dokunulabilir kapi butonu.
	if hud == null:
		return
	var button := Button.new()
	button.name = "GatePortalButton_%s" % action
	button.text = label_text
	button.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	button.offset_left = -260.0
	button.offset_top = -150.0
	button.offset_right = -20.0
	button.offset_bottom = -110.0
	if action != "return":
		button.offset_top -= 50.0
		button.offset_bottom -= 50.0
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_stylebox_override("normal", _panel_style())
	button.pressed.connect(_travel.bind(action))
	button.set_meta("novagate_gate_portal_button", true)
	hud.add_child(button)


func _clear_portal_buttons() -> void:
	if hud == null:
		return
	for child in hud.get_children():
		if child.has_meta("novagate_gate_portal_button"):
			child.queue_free()


func _travel(action: String) -> void:
	if travel_busy:
		return
	if action == "return":
		_return_to_x1()
		return
	if not wave_cleared:
		# Wave tamamlanmadan sonraki dalgaya gecilemez (BOLUM 31).
		return
	travel_busy = true
	if action == "next_floor":
		# Kat gecisi mevcut sahne degistirme akisiyla yapilir; hedef kat
		# gg_<gate>_<kat> map id'sidir (BOLUM 6).
		print("GALAXY_GATE_FLOOR_TRANSITION gate=", gate_id, " next_floor=", floor_number + 1)
		get_tree().call_deferred("change_scene_to_file", "res://scenes/GalaxyGateArena.tscn")
		return
	_advance_wave_in_place()


func _advance_wave_in_place() -> void:
	# Ayni kat icindeki dalga gecisi: sahne yeniden yuklenmez.
	_clear_portals()
	for child in npc_root.get_children():
		child.queue_free()
	alive_npcs = 0
	wave_cleared = false
	if player != null and is_instance_valid(player):
		player.global_position = GateData.GATE_ENTRY_POSITION
		player.stop_navigation()
		player.velocity = Vector2.ZERO
	travel_busy = false
	wave_number = clampi(wave_number + 1, 1, GateData.WAVES_PER_FLOOR)
	await get_tree().process_frame
	_start_wave()


func _nearest_portal_action() -> String:
	var best := INF
	var action: String = ""
	for portal in travel_portals:
		if not is_instance_valid(portal):
			continue
		var distance: float = player.global_position.distance_to(portal.global_position)
		if distance <= GateData.GATE_PORTAL_INTERACT_RADIUS and distance < best:
			best = distance
			action = str(portal.get_meta("gate_action", ""))
	return action


func _process(_delta: float) -> void:
	if hint_label == null or travel_portals.is_empty():
		return
	var action: String = _nearest_portal_action()
	if action.is_empty():
		hint_label.text = "Tum NPC'ler temizlendi. Gecis kapilarini kullan."
	else:
		hint_label.text = "KAPI HAZIR: %s  (J / G)" % action.to_upper()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	if key_event.keycode == KEY_ESCAPE:
		_return_to_x1()
		get_viewport().set_input_as_handled()
		return
	if key_event.keycode == KEY_J or key_event.keycode == KEY_G:
		var action: String = _nearest_portal_action()
		if not action.is_empty():
			_travel(action)
			get_viewport().set_input_as_handled()


func _return_to_x1() -> void:
	# Ilk kat/dalga ilerlemesi korunur (BOLUM 26); sahne X1'e doner.
	GalaxyGateManager.leave_gate()
	var home_map: String = GalaxyGateManager.company_home_map(GlobalState.company)
	GlobalState.start_map = home_map
	GlobalState.cache_world_location(home_map, GateData.gate_position_for_company(GlobalState.company))
	GlobalState.save_game()
	print("GALAXY_GATE_RETURN_TO_X1 map=", home_map)
	get_tree().call_deferred("change_scene_to_file", "res://scenes/main.tscn")


func _show_gate_complete_panel(rewards_text: String) -> void:
	if death_overlay != null:
		return
	death_overlay = ColorRect.new()
	death_overlay.name = "GateCompleteOverlay"
	death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	death_overlay.color = Color(0.0, 0.0, 0.0, 0.72)
	death_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	death_overlay.z_index = 4090
	add_child(death_overlay)

	death_panel = Panel.new()
	death_panel.set_anchors_preset(Control.PRESET_CENTER)
	death_panel.offset_left = -320.0
	death_panel.offset_top = -140.0
	death_panel.offset_right = 320.0
	death_panel.offset_bottom = 140.0
	death_panel.add_theme_stylebox_override("panel", _panel_style())
	death_overlay.add_child(death_panel)

	death_title = Label.new()
	death_title.text = "GALAXY GATE TAMAMLANDI"
	death_title.position = Vector2(20.0, 22.0)
	death_title.size = Vector2(600.0, 34.0)
	death_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_title.add_theme_font_size_override("font_size", 24)
	death_title.add_theme_color_override("font_color", Color(0.4, 1.0, 0.6))
	death_panel.add_child(death_title)

	var reward_label := Label.new()
	reward_label.text = rewards_text
	reward_label.position = Vector2(20.0, 66.0)
	reward_label.size = Vector2(600.0, 90.0)
	reward_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reward_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reward_label.add_theme_font_size_override("font_size", 17)
	death_panel.add_child(reward_label)

	return_button = Button.new()
	return_button.text = "X1'E DON"
	return_button.position = Vector2(160.0, 190.0)
	return_button.size = Vector2(280.0, 56.0)
	return_button.add_theme_font_size_override("font_size", 20)
	return_button.pressed.connect(_return_to_x1)
	death_panel.add_child(return_button)


# --------------------------------------------------------------------------
# SAVAS KOPRUSU (mevcut PlayerShip / SpaceNPC / WeaponSystem kullanilir)
# --------------------------------------------------------------------------

func _on_selection_requested(npc: SpaceNPC) -> void:
	if is_instance_valid(selected_npc):
		selected_npc.set_selected(false)
	selected_npc = npc
	if player != null and is_instance_valid(player):
		player.set_locked_target(selected_npc)
	if is_instance_valid(selected_npc):
		selected_npc.set_selected(true)


func _on_stats_changed(health_value: float, shield_value: float) -> void:
	if health_bar != null:
		health_bar.max_value = maxf(player.max_health, 1.0)
		health_bar.value = health_value
	if shield_bar != null:
		shield_bar.max_value = maxf(player.max_shield, 1.0)
		shield_bar.value = shield_value


func _on_npc_attack_requested(source: SpaceNPC, target: PlayerShip, damage: float) -> void:
	if not is_instance_valid(source) or not is_instance_valid(target):
		return
	var laser := NPC_LASER_EFFECT_SCENE.instantiate() as NPCLaserEffect
	if laser != null:
		add_child(laser)
		laser.setup(source, target, source.npc_name)
	await get_tree().create_timer(0.16).timeout
	if is_instance_valid(target):
		# NAZ: korunmasiz oyuncuya NPC hasari isler (take_damage icinde kontrol).
		target.take_damage(damage, true)


func _on_fire_requested(_target_position: Vector2, ammo: int) -> void:
	if not is_instance_valid(selected_npc) or selected_npc.is_queued_for_deletion():
		return
	var hit_npc: SpaceNPC = selected_npc
	var target: Vector2 = hit_npc.global_position
	var distance_to_target: float = player.global_position.distance_to(target)
	if distance_to_target > PLAYER_LASER_RANGE:
		return
	if player.has_method("mark_as_aggressor"):
		player.call("mark_as_aggressor")
	# Odul sahipligi mevcut npc.gd kuralina gore ilk saldiran oyuncudur.
	hit_npc.first_attacker = player
	hit_npc.player = player
	hit_npc.provoked = true
	hit_npc.first_attacker_username = GlobalState.username
	hit_npc.reward_owner_username = GlobalState.username
	hit_npc.mark_attacked(player)

	var ammo_index_zero: int = clampi(ammo - 1, 0, AMMO_MULTIPLIERS.size() - 1)
	var travel_time := clampf(
		distance_to_target / PLAYER_LASER_PROJECTILE_SPEED,
		PLAYER_LASER_MIN_TRAVEL_TIME,
		PLAYER_LASER_MAX_TRAVEL_TIME
	)
	_spawn_laser_visual(player.global_position, target, ammo_index_zero, travel_time)
	await get_tree().create_timer(travel_time).timeout

	if not is_instance_valid(hit_npc) or hit_npc.is_queued_for_deletion():
		return
	var equipment_damage: float = player.get_laser_damage()
	if equipment_damage <= 0.0:
		return
	if ammo_index_zero == 4:
		# SAB: kalkan aktarimi (main.gd ile ayni davranis).
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
	if hit_npc.has_method("take_laser_damage"):
		hit_npc.call("take_laser_damage", final_damage, ammo_index_zero + 1, player)
	else:
		hit_npc.take_damage(final_damage, player)


func _spawn_laser_visual(origin: Vector2, target: Vector2, ammo_zero: int, travel_time: float) -> void:
	var direction := target - origin
	var distance := direction.length()
	if distance <= 1.0 or laser_root == null:
		return
	var effect := Sprite2D.new()
	effect.texture = LASER_EFFECTS[clampi(ammo_zero, 0, LASER_EFFECTS.size() - 1)]
	effect.global_position = origin
	effect.rotation = direction.angle()
	effect.z_index = 20
	var texture_size := effect.texture.get_size()
	var desired_length := clampf(distance * 0.30, 65.0, 170.0)
	var desired_height := 24.0 if ammo_zero != 4 else 56.0
	effect.scale = Vector2(
		desired_length / maxf(texture_size.x, 1.0),
		desired_height / maxf(texture_size.y, 1.0)
	)
	laser_root.add_child(effect)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(effect, "global_position", target, travel_time)
	tween.tween_property(effect, "modulate:a", 0.20, travel_time)
	tween.set_parallel(false)
	tween.tween_callback(effect.queue_free)


# --------------------------------------------------------------------------
# OLUM / DEVAM (BOLUM 26) - gate ilerlemesi silinmez
# --------------------------------------------------------------------------

func _on_player_ship_destroyed() -> void:
	_build_death_panel()
	if death_overlay != null:
		death_overlay.visible = true


func _build_death_panel() -> void:
	if death_panel != null and is_instance_valid(death_panel):
		return
	death_overlay = ColorRect.new()
	death_overlay.name = "GateDeathOverlay"
	death_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	death_overlay.color = Color(0.0, 0.0, 0.0, 0.68)
	death_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	death_overlay.z_index = 4090
	add_child(death_overlay)

	death_panel = Panel.new()
	death_panel.name = "GateDeathPanel"
	death_panel.set_anchors_preset(Control.PRESET_CENTER)
	death_panel.offset_left = -300.0
	death_panel.offset_top = -130.0
	death_panel.offset_right = 300.0
	death_panel.offset_bottom = 130.0
	death_panel.add_theme_stylebox_override("panel", _panel_style())
	death_overlay.add_child(death_panel)

	death_title = Label.new()
	death_title.text = "GEMI IMHA EDILDI"
	death_title.position = Vector2(20.0, 18.0)
	death_title.size = Vector2(560.0, 32.0)
	death_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	death_title.add_theme_font_size_override("font_size", 23)
	death_title.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
	death_panel.add_child(death_title)

	var info := Label.new()
	info.name = "GateDeathInfo"
	info.text = "Gate ilerlemen korunuyor:  FLOOR %d  /  WAVE %d" % [floor_number, wave_number]
	info.position = Vector2(20.0, 58.0)
	info.size = Vector2(560.0, 26.0)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_font_size_override("font_size", 17)
	death_panel.add_child(info)

	repair_button = Button.new()
	repair_button.text = "TAMIR ET VE DEVAM ET"
	repair_button.position = Vector2(40.0, 104.0)
	repair_button.size = Vector2(240.0, 52.0)
	repair_button.add_theme_font_size_override("font_size", 17)
	repair_button.pressed.connect(_on_repair_pressed)
	death_panel.add_child(repair_button)

	return_button = Button.new()
	return_button.text = "X1'E DON"
	return_button.position = Vector2(320.0, 104.0)
	return_button.size = Vector2(240.0, 52.0)
	return_button.add_theme_font_size_override("font_size", 17)
	return_button.pressed.connect(_return_to_x1)
	death_panel.add_child(return_button)


func _on_repair_pressed() -> void:
	if repair_busy or player == null or not is_instance_valid(player) or not player.is_destroyed:
		return
	repair_busy = true
	if repair_button != null:
		repair_button.disabled = true
		repair_button.text = "TAMIR EDILIYOR..."
	# Mevcut PlayerShip tamir akisi kullanilir; dalga/kat ilerlemesi degismez.
	player.repair_after_death()
	player.global_position = GateData.GATE_ENTRY_POSITION
	if death_overlay != null:
		death_overlay.visible = false
	if repair_button != null:
		repair_button.disabled = false
		repair_button.text = "TAMIR ET VE DEVAM ET"
	repair_busy = false
