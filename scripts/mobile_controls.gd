extends Control

signal mobile_ready

const HOLD_TO_DRAG_MS: int = 650
const MOVE_LOOKAHEAD: float = 360.0
const PREF_PATH: String = "user://mobile_hud_layout.cfg"

# WarUniverse hissi için hedef tarama konisi.
const TARGET_MAX_DISTANCE: float = 950.0
const CONE_HALF_ANGLE_DEG: float = 34.0
const CONE_SCREEN_LENGTH: float = 390.0
const CONE_SCREEN_HALF_WIDTH: float = 205.0

var mobile_enabled: bool = false
var player: Node2D = null
var left_was_active: bool = false

var action_buttons: Dictionary = {}
var press_state: Dictionary = {}

var aim_direction: Vector2 = Vector2.RIGHT
var aim_candidate: Node2D = null
var last_selected_target: Node2D = null
var aim_active: bool = false
var pulse_time: float = 0.0
var controls_locked: bool = false
var button_status_labels: Dictionary = {}
var right_press_stopped_fire: bool = false

# Kullanıcının gönderdiği lazer görsellerinin projedeki gerçek dosya yolları.
const LASER_ICONS: Array[String] = [
	"res://assets/ammo/lammo1.png",
	"res://assets/ammo/lammo2.png",
	"res://assets/ammo/lammo3.png",
	"res://assets/ammo/lammo4.png",
	"res://assets/ammo/lammo5.png",
	"res://assets/ammo/lammo6.png"
]
const ROCKET_ICONS: Array[String] = [
	"res://assets/rocket1icon.png",
	"res://assets/rocket2icon.png",
	"res://assets/rocket3icon.png"
]
const EXTRA_ICONS: Dictionary = {
	"ema": "res://assets/ext_slot_shield.png",
	"nukleer": "res://assets/ext_slot_nbomb.png",
	"onluk": "res://assets/ext_slot_fastrep.png",
	"enc": "res://assets/ext_slot_entransfer.png",
	"kalkan": "res://assets/ext_slot_emp.png"
}

@onready var left_joystick: NovaGateJoystick = $LeftJoystick
@onready var right_joystick: NovaGateJoystick = $RightJoystick

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	var platform_name: String = OS.get_name()
	mobile_enabled = platform_name == "Android" or platform_name == "iOS"

	visible = mobile_enabled
	if not mobile_enabled:
		return

	player = get_tree().get_first_node_in_group("player") as Node2D

	_build_action_buttons()
	_apply_mobile_layout()
	_load_layout()
	_hide_pc_hud()
	_apply_mobile_camera()
	_set_controls_interactive(true)
	if right_joystick != null and not right_joystick.activated.is_connected(_on_right_joystick_activated):
		right_joystick.activated.connect(_on_right_joystick_activated)

	mobile_ready.emit()
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and mobile_enabled:
		call_deferred("_apply_mobile_layout")

func _ensure_player() -> bool:
	if is_instance_valid(player):
		return true
	player = get_tree().get_first_node_in_group("player") as Node2D
	return is_instance_valid(player)

func _apply_mobile_layout() -> void:
	if not mobile_enabled:
		return

	var view: Vector2 = get_viewport_rect().size

	# HAREKET JOYSTICK:
	# Sol tarafta geniş dinamik alan. Nereye basarsan orada doğar.
	left_joystick.position = Vector2(0.0, view.y * 0.37)
	left_joystick.size = Vector2(view.x * 0.47, view.y * 0.63)

	# HEDEF JOYSTICK:
	# O da artık dinamik; fakat hareket alanından belirgin biçimde daha küçük.
	# Sağ-alt savaş bölgesinde nereye basarsan profesyonel joystick orada doğar.
	var aim_zone_size := Vector2(view.x * 0.27, view.y * 0.42)
	right_joystick.position = Vector2(
		view.x - aim_zone_size.x - 18.0,
		view.y - aim_zone_size.y - 14.0
	)
	right_joystick.size = aim_zone_size

	# Eski sabit TargetZoneFrame varsa gizle; hedefleme konisi aynen çalışır.
	var target_frame := get_node_or_null("TargetZoneFrame") as CanvasItem
	if target_frame != null:
		target_frame.visible = false

	# Mevcut profesyonel HUD konumları korunur; aim alanının içine taşmaz.
	var defaults: Dictionary = {
		"L1":Vector2(view.x*0.47,view.y*0.84), "L2":Vector2(view.x*0.525,view.y*0.84),
		"L3":Vector2(view.x*0.58,view.y*0.84), "L4":Vector2(view.x*0.635,view.y*0.84),
		"L5":Vector2(view.x*0.69,view.y*0.84), "L6":Vector2(view.x*0.745,view.y*0.84),
		"R1":Vector2(view.x*0.76,view.y*0.69), "R2":Vector2(view.x*0.815,view.y*0.69),
		"R3":Vector2(view.x*0.815,view.y*0.765),
		"EX_1":Vector2(view.x*0.018,view.y*0.18), "EX_2":Vector2(view.x*0.073,view.y*0.18),
		"EX_3":Vector2(view.x*0.128,view.y*0.18), "EX_4":Vector2(view.x*0.183,view.y*0.18),
		"EX_5":Vector2(view.x*0.238,view.y*0.18), "BOX":Vector2(view.x*0.298,view.y*0.18),
		"GATE":Vector2(view.x*0.018,view.y*0.09), "CONFIG":Vector2(view.x*0.078,view.y*0.09)
	}
	for key in action_buttons.keys():
		var b: Button = action_buttons[key]
		if not b.has_meta("custom_saved") and defaults.has(str(key)):
			b.position = defaults[str(key)]
		b.position = _clamp_button_position(b.position,b.size)

func _build_action_buttons() -> void:
	var specs: Array = [
		["L1","laser:0",LASER_ICONS[0],"laser"],["L2","laser:1",LASER_ICONS[1],"laser"],
		["L3","laser:2",LASER_ICONS[2],"laser"],["L4","laser:3",LASER_ICONS[3],"laser"],
		["L5","laser:4",LASER_ICONS[4],"laser"],["L6","laser:5",LASER_ICONS[5],"laser"],
		["R1","rocket:0",ROCKET_ICONS[0],"rocket"],["R2","rocket:1",ROCKET_ICONS[1],"rocket"],
		["R3","rocket:2",ROCKET_ICONS[2],"rocket"],
		["EX_1","extra:ema",EXTRA_ICONS["ema"],"extra"],["EX_2","extra:nukleer",EXTRA_ICONS["nukleer"],"extra"],
		["EX_3","extra:onluk",EXTRA_ICONS["onluk"],"extra"],["EX_4","extra:enc",EXTRA_ICONS["enc"],"extra"],
		["EX_5","extra:kalkan",EXTRA_ICONS["kalkan"],"extra"],
		["BOX","box","res://assets/bonusbox/bonusbox.png","box"],
		["GATE","gate","res://assets/mobile_hyper/gate_jump.png","utility"],
		["CONFIG","config","res://assets/mobile_hyper/config_switch.png","utility"]
	]

	for spec in specs:
		var b := Button.new()
		b.name=str(spec[0]); b.text=""; b.z_index=80; b.focus_mode=Control.FOCUS_NONE
		b.set_meta("action",str(spec[1])); b.set_meta("kind",str(spec[3]))
		var kind:=str(spec[3])
		b.size = Vector2(72,72) if kind=="laser" else Vector2(64,64)
		var empty:=StyleBoxEmpty.new()
		for state in ["normal","hover","pressed","focus","disabled"]:
			b.add_theme_stylebox_override(state,empty)

		# HYPER sci-fi slot frame.
		var frame:=TextureRect.new()
		frame.mouse_filter=Control.MOUSE_FILTER_IGNORE
		frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.texture=load("res://assets/mobile_hyper/hud_slot.png")
		frame.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
		frame.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		frame.modulate=Color(0.25,0.82,1.0,0.82)
		b.add_child(frame)

		var icon:=TextureRect.new()
		icon.mouse_filter=Control.MOUSE_FILTER_IGNORE
		icon.anchor_left=0.18; icon.anchor_top=0.18; icon.anchor_right=0.82; icon.anchor_bottom=0.82
		icon.expand_mode=TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var icon_path:=str(spec[2])
		if kind=="box":
			var tex=load(icon_path)
			if tex!=null:
				var atlas:=AtlasTexture.new(); atlas.atlas=tex; atlas.region=Rect2(2,4,97,97); icon.texture=atlas
		elif icon_path!="" and ResourceLoader.exists(icon_path):
			icon.texture=load(icon_path)
		b.add_child(icon)

		# İnce hazır/cooldown halkası.
		var ring:=TextureRect.new()
		ring.name="StateRing"; ring.mouse_filter=Control.MOUSE_FILTER_IGNORE
		ring.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ring.texture=load("res://assets/mobile_hyper/ready_ring.png")
		ring.expand_mode=TextureRect.EXPAND_IGNORE_SIZE; ring.stretch_mode=TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ring.modulate=Color(0.35,0.95,1.0,0.75)
		b.add_child(ring)

		b.gui_input.connect(_on_action_gui_input.bind(b))
		add_child(b); action_buttons[b.name]=b

		var status:=Label.new()
		status.mouse_filter=Control.MOUSE_FILTER_IGNORE
		status.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		status.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER; status.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
		status.add_theme_font_size_override("font_size",16)
		status.add_theme_color_override("font_color",Color.WHITE)
		status.add_theme_color_override("font_shadow_color",Color.BLACK)
		status.add_theme_constant_override("shadow_offset_x",2); status.add_theme_constant_override("shadow_offset_y",2)
		status.visible=false; b.add_child(status); button_status_labels[b.name]=status

func _process(delta: float) -> void:
	if not mobile_enabled:
		return

	# Menü/market/hangar açıkken joystick katmanı dokunmayı YUTMAZ.
	var should_lock: bool = get_tree().paused
	if should_lock != controls_locked:
		_set_controls_interactive(not should_lock)

	if should_lock:
		aim_active = false
		aim_candidate = null
		queue_redraw()
		return

	if not _ensure_player():
		return

	_hide_pc_hud()
	_update_mobile_button_status()
	pulse_time += delta

	# HAREKET
	var left_vector: Vector2 = left_joystick.output_vector
	var left_active: bool = left_vector.length() > 0.08

	if left_active:
		left_was_active = true
		if player.has_method("set_navigation_target"):
			player.call(
				"set_navigation_target",
				player.global_position + left_vector.normalized() * MOVE_LOOKAHEAD
			)
	elif left_was_active:
		left_was_active = false
		if player.has_method("stop_navigation"):
			player.call("stop_navigation")

	# HEDEF / ATEŞ
	var right_vector: Vector2 = right_joystick.output_vector

	if right_joystick.is_active and right_vector.length() > 0.12:
		aim_active = true
		aim_direction = right_vector.normalized()
		_update_target_from_cone()
	else:
		aim_active = false
		aim_candidate = null

	queue_redraw()

func _on_right_joystick_activated() -> void:
	# Ateş ederken hedef joystickine bir kez daha dokun = ateşi bırak.
	if WeaponSystem.auto_fire:
		WeaponSystem.toggle_auto_fire()
		right_press_stopped_fire = true
		last_selected_target = null
	else:
		right_press_stopped_fire = false


func _update_mobile_button_status() -> void:
	for i in range(6):
		var b: Button = action_buttons.get("L%d" % (i+1)) as Button
		if b != null:
			b.modulate = Color(1,1,1,1) if WeaponSystem.current_laser==i else Color(1,1,1,0.70)

	var extras = get_tree().get_first_node_in_group("extra_system")
	if extras==null or not extras.has_method("mobile_get_status"):
		return
	var mapping := {"EX_1":"ema","EX_2":"nukleer","EX_3":"onluk","EX_4":"enc","EX_5":"kalkan"}
	for key in mapping.keys():
		var label: Label = button_status_labels.get(key) as Label
		if label==null: continue
		var state: Dictionary = extras.call("mobile_get_status",mapping[key])
		var active_left := int(state.get("active",0))
		var cooldown_left := int(state.get("cooldown",0))
		if active_left>0:
			label.visible=true
			label.text="%ds" % active_left
			label.add_theme_color_override("font_color",Color(0.35,1.0,0.55))
		elif cooldown_left>0:
			label.visible=true
			label.text="%ds" % cooldown_left
			label.add_theme_color_override("font_color",Color.WHITE)
		else:
			label.visible=false
			label.text=""


func _collect_nearest_box() -> void:
	if not _ensure_player(): return
	var nearest: Node2D = null
	var best := 99999999.0
	for node in get_tree().get_nodes_in_group("bonus_box"):
		if node is Node2D and is_instance_valid(node):
			var d := player.global_position.distance_to((node as Node2D).global_position)
			if d<best:
				best=d
				nearest=node as Node2D
	if nearest != null and nearest.has_method("mobile_collect"):
		nearest.call("mobile_collect")


func _update_target_from_cone() -> void:
	var best: Node2D = null
	var best_angle_error: float = 999.0
	var best_distance: float = 999999.0
	var cone_cos: float = cos(deg_to_rad(CONE_HALF_ANGLE_DEG))

	# NPC'ler.
	for node in get_tree().get_nodes_in_group("npc"):
		if not (node is Node2D):
			continue
		var candidate: Node2D = node as Node2D
		if not is_instance_valid(candidate):
			continue
		var result: Dictionary = _candidate_score(candidate, cone_cos)
		if not bool(result.get("valid", false)):
			continue

		var angle_error: float = float(result.get("angle", 999.0))
		var distance: float = float(result.get("distance", 999999.0))

		if (
			angle_error < best_angle_error - 0.01
			or (
				absf(angle_error - best_angle_error) <= 0.01
				and distance < best_distance
			)
		):
			best = candidate
			best_angle_error = angle_error
			best_distance = distance

	# Online oyuncular da varsa aynı hedef joystickiyle seçilebilir.
	for group_name in ["remote_player", "online_player"]:
		for node in get_tree().get_nodes_in_group(group_name):
			if not (node is Node2D):
				continue
			var candidate: Node2D = node as Node2D
			if candidate == player or not is_instance_valid(candidate):
				continue

			var result: Dictionary = _candidate_score(candidate, cone_cos)
			if not bool(result.get("valid", false)):
				continue

			var angle_error: float = float(result.get("angle", 999.0))
			var distance: float = float(result.get("distance", 999999.0))

			if (
				angle_error < best_angle_error - 0.01
				or (
					absf(angle_error - best_angle_error) <= 0.01
					and distance < best_distance
				)
			):
				best = candidate
				best_angle_error = angle_error
				best_distance = distance

	aim_candidate = best

	# Çizgi hangi hedefe denk geldiyse ANINDA seç + ateş.
	if is_instance_valid(best) and best != last_selected_target:
		last_selected_target = best
		if player.has_signal("selection_requested"):
			player.selection_requested.emit(best)

		if not WeaponSystem.auto_fire:
			WeaponSystem.toggle_auto_fire()

func _candidate_score(candidate: Node2D, cone_cos: float) -> Dictionary:
	var delta_world: Vector2 = candidate.global_position - player.global_position
	var distance: float = delta_world.length()

	if distance < 1.0 or distance > TARGET_MAX_DISTANCE:
		return {"valid": false}

	var direction_to_target: Vector2 = delta_world / distance
	var alignment: float = aim_direction.dot(direction_to_target)

	if alignment < cone_cos:
		return {"valid": false}

	# Asıl seçim joystick çizgisine en yakın AÇIYA göre.
	var angle_error: float = absf(aim_direction.angle_to(direction_to_target))

	return {
		"valid": true,
		"angle": angle_error,
		"distance": distance
	}

func _draw() -> void:
	if not mobile_enabled or not aim_active or not _ensure_player():
		return

	var canvas_transform: Transform2D = get_viewport().get_canvas_transform()
	var origin: Vector2 = canvas_transform * player.global_position

	# Joystick yönünü ekran koordinatında kullan.
	var dir: Vector2 = aim_direction.normalized()
	var perpendicular: Vector2 = Vector2(-dir.y, dir.x)

	var end_center: Vector2 = origin + dir * CONE_SCREEN_LENGTH
	var left_end: Vector2 = end_center + perpendicular * CONE_SCREEN_HALF_WIDTH
	var right_end: Vector2 = end_center - perpendicular * CONE_SCREEN_HALF_WIDTH

	var cone_color := Color(0.0, 0.68, 0.82, 0.16)
	var edge_color := Color(0.10, 0.88, 1.0, 0.34)
	var line_color := Color(0.20, 0.92, 1.0, 0.82)

	# Şeffaf hedef seçme konisi.
	draw_colored_polygon(
		PackedVector2Array([origin, left_end, right_end]),
		cone_color
	)
	draw_line(origin, left_end, edge_color, 1.8)
	draw_line(origin, right_end, edge_color, 1.8)

	# WarUniverse benzeri koni içi halkalar.
	for factor in [0.28, 0.48, 0.68, 0.88]:
		var ring_center: Vector2 = origin + dir * (CONE_SCREEN_LENGTH * float(factor))
		var radius: float = 7.0 + 7.0 * float(factor)
		draw_circle(ring_center, radius, edge_color, false, 2.0)

	# Nişan çizgisi.
	draw_line(origin, end_center, Color(0.18, 0.94, 1.0, 0.28), 1.4)

	# Çizginin seçtiği gerçek hedefe kilit çizgisi + pulse animasyonu.
	if is_instance_valid(aim_candidate):
		var target_screen: Vector2 = canvas_transform * aim_candidate.global_position
		draw_line(origin, target_screen, line_color, 2.6)

		var pulse: float = (sin(pulse_time * 8.0) + 1.0) * 0.5
		var radius: float = 25.0 + pulse * 8.0
		var lock_color := Color(0.15, 0.95, 1.0, 0.92)

		draw_circle(target_screen, radius, lock_color, false, 2.8)
		draw_line(target_screen + Vector2(-radius - 10.0, 0), target_screen + Vector2(-radius + 4.0, 0), lock_color, 2.8)
		draw_line(target_screen + Vector2(radius - 4.0, 0), target_screen + Vector2(radius + 10.0, 0), lock_color, 2.8)
		draw_line(target_screen + Vector2(0, -radius - 10.0), target_screen + Vector2(0, -radius + 4.0), lock_color, 2.8)
		draw_line(target_screen + Vector2(0, radius - 4.0), target_screen + Vector2(0, radius + 10.0), lock_color, 2.8)

func _set_controls_interactive(enabled: bool) -> void:
	controls_locked = not enabled

	if left_joystick != null:
		left_joystick.disabled = not enabled
		left_joystick.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE

	if right_joystick != null:
		right_joystick.disabled = not enabled
		right_joystick.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE

	for button in action_buttons.values():
		if button is Button:
			var b: Button = button
			b.disabled = not enabled
			b.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE

func _on_action_gui_input(event: InputEvent, button: Button) -> void:
	if controls_locked:
		return

	var key: String = button.name

	if event is InputEventScreenTouch:
		var touch: InputEventScreenTouch = event

		if touch.pressed:
			press_state[key] = {
				"id": touch.index,
				"start": Time.get_ticks_msec(),
				"moved": false
			}
		else:
			_finish_button_press(button)

		accept_event()
		return

	if event is InputEventScreenDrag:
		var drag: InputEventScreenDrag = event
		var state: Dictionary = press_state.get(key, {})

		if state.is_empty():
			return
		if int(state.get("id", -99)) != drag.index:
			return

		if Time.get_ticks_msec() - int(state.get("start", 0)) >= HOLD_TO_DRAG_MS:
			state["moved"] = true
			press_state[key] = state
			button.position = _clamp_button_position(
				button.position + drag.relative,
				button.size
			)
			accept_event()

func _finish_button_press(button: Button) -> void:
	var state: Dictionary = press_state.get(button.name, {})
	press_state.erase(button.name)

	if state.is_empty():
		return

	if bool(state.get("moved", false)):
		button.set_meta("custom_saved", true)
		_save_layout()
		return

	_run_action(str(button.get_meta("action", "")))

func _run_action(action: String) -> void:
	if action.begins_with("laser:"):
		var laser_index: int = int(action.get_slice(":", 1))
		WeaponSystem.select_laser(laser_index)
		if _ensure_player() and player.has_method("select_ammo"):
			player.call("select_ammo", laser_index + 1)
		return

	if action.begins_with("rocket:"):
		var rocket = get_tree().get_first_node_in_group("rocket_system")
		if rocket != null and rocket.has_method("mobile_fire_rocket"):
			rocket.call(
				"mobile_fire_rocket",
				int(action.get_slice(":", 1))
			)
		return

	if action.begins_with("extra:"):
		var extra = get_tree().get_first_node_in_group("extra_system")
		if extra != null and extra.has_method("mobile_activate"):
			extra.call(
				"mobile_activate",
				action.get_slice(":", 1)
			)
		return

	if action == "gate":
		var scene = get_tree().current_scene
		if scene != null and scene.has_method("mobile_try_gate"):
			scene.call("mobile_try_gate")
		return

	if action == "box":
		_collect_nearest_box()
		return

	if action == "config":
		var menu = get_tree().get_first_node_in_group("menu_ui")
		if menu != null and menu.has_method("mobile_toggle_config"):
			menu.call("mobile_toggle_config")

func _apply_mobile_camera() -> void:
	if not _ensure_player():
		return

	var camera: Camera2D = player.get_node_or_null("Camera2D") as Camera2D
	if camera != null:
		camera.zoom = Vector2(0.82, 0.82)

func _hide_pc_hud() -> void:
	var scene = get_tree().current_scene
	if scene==null: return
	for path in ["HUD/LaserToggleButton","HUD/ExtraHUD","CombatHUD"]:
		var n=scene.get_node_or_null(path)
		if n is CanvasItem: (n as CanvasItem).visible=false
	var combat = scene.find_child("CombatHUD",true,false)
	if combat is CanvasItem: (combat as CanvasItem).visible=false

func _clamp_button_position(pos: Vector2, button_size: Vector2) -> Vector2:
	var view: Vector2 = get_viewport_rect().size
	return Vector2(
		clampf(pos.x, 0.0, maxf(view.x - button_size.x, 0.0)),
		clampf(pos.y, 0.0, maxf(view.y - button_size.y, 0.0))
	)

func _save_layout() -> void:
	var cfg: ConfigFile = ConfigFile.new()

	for key in action_buttons.keys():
		var b: Button = action_buttons[key]
		cfg.set_value("buttons", str(key), b.position)

	cfg.save(PREF_PATH)

func _load_layout() -> void:
	var cfg: ConfigFile = ConfigFile.new()

	if cfg.load(PREF_PATH) != OK:
		return

	for key in action_buttons.keys():
		var b: Button = action_buttons[key]

		if cfg.has_section_key("buttons", str(key)):
			b.position = _clamp_button_position(
				cfg.get_value("buttons", str(key), b.position),
				b.size
			)
			b.set_meta("custom_saved", true)
