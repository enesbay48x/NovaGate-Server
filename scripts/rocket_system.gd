extends Node

# NovaGate RocketSystem V1
# Mevcut lazer/slot/extra sisteminden bağımsızdır.
# R1/R2/R3 butonları roket türünü seçer.
# Seçili hedef varsa butona basınca bir roket atılır.
# WeaponSystem otomatik ateş aktifken seçili roket cooldown'una göre otomatik devam eder.

@export var rocket_speed: float = 900.0
@export var hit_distance: float = 20.0
@export var r3_curve_strength: float = 120.0
@export var r3_curve_speed: float = 5.0

# Lazer menzili 550; roket menzili lazerden 10 daha fazla.
const ROCKET_MAX_RANGE: float = 560.0

const ROCKETS := {
	0: {
		"name": "R1",
		"min_damage": 800,
		"max_damage": 1000,
		"interval": 1.0,
		"texture": "res://assets/rockets/r1.png",
		"scale": 0.045,
		"angle_offset": 0.38,
		"trail": false
	},
	1: {
		"name": "R2",
		"min_damage": 1800,
		"max_damage": 2000,
		"interval": 1.0,
		"texture": "res://assets/rockets/r2.png",
		"scale": 0.045,
		"angle_offset": 0.20,
		"trail": false
	},
	2: {
		"name": "R3",
		"min_damage": 3800,
		"max_damage": 4000,
		"interval": 0.5,
		"texture": "res://assets/rockets/r3.png",
		"scale": 0.045,
		"angle_offset": 0.0,
		"trail": true
	}
}

var selected_rocket: int = 0
var cooldown_left: float = 0.0
var player: Node2D = null
var rocket_world: Node2D = null
var projectiles: Array[Dictionary] = []

var impact_frames: SpriteFrames = null
var trail_frames: SpriteFrames = null

@onready var r1_button: TextureButton = get_node("../HUD/ExtraHUD/HBoxContainer/R1Button")
@onready var r2_button: TextureButton = get_node("../HUD/ExtraHUD/HBoxContainer/R2Button")
@onready var r3_button: TextureButton = get_node("../HUD/ExtraHUD/HBoxContainer/R3Button")

func _ready() -> void:
	add_to_group("rocket_system")
	player = get_tree().get_first_node_in_group("player") as Node2D
	rocket_world = get_node_or_null("../World/Rockets") as Node2D

	r1_button.pressed.connect(func(): _select_and_fire(0))
	r2_button.pressed.connect(func(): _select_and_fire(1))
	r3_button.pressed.connect(func(): _select_and_fire(2))

	impact_frames = _build_grid_frames(
		load("res://assets/rockets/rocket_impact.png") as Texture2D,
		4, 4, 24.0, false
	)
	trail_frames = _build_grid_frames(
		load("res://assets/rockets/r3_trail.png") as Texture2D,
		21, 1, 30.0, true
	)
	_update_button_state()

func _process(delta: float) -> void:
	if cooldown_left > 0.0:
		cooldown_left = maxf(cooldown_left - delta, 0.0)

	_update_projectiles(delta)

	# Ctrl ile başlayan mevcut otomatik lazer ateşi açıkken
	# seçili roket de kendi atış aralığına göre devam eder.
	if cooldown_left <= 0.0 and _weapon_auto_fire_active():
		_try_fire()

func _weapon_auto_fire_active() -> bool:
	var weapon_system := get_node_or_null("/root/WeaponSystem")
	if weapon_system == null:
		return false
	if "auto_fire" in weapon_system:
		return bool(weapon_system.auto_fire)
	return false

func _select_and_fire(index: int) -> void:
	if not ROCKETS.has(index):
		return
	selected_rocket = index
	_update_button_state()

	# Butona basmak tek atış da yapar; cooldown varsa üst üste atamaz.
	if cooldown_left <= 0.0:
		_try_fire()

func _update_button_state() -> void:
	r1_button.modulate = Color.WHITE if selected_rocket == 0 else Color(0.72, 0.72, 0.72, 1.0)
	r2_button.modulate = Color.WHITE if selected_rocket == 1 else Color(0.72, 0.72, 0.72, 1.0)
	r3_button.modulate = Color.WHITE if selected_rocket == 2 else Color(0.72, 0.72, 0.72, 1.0)

	r1_button.disabled = GlobalState.get_ammo_count("R1") <= 0
	r2_button.disabled = GlobalState.get_ammo_count("R2") <= 0
	r3_button.disabled = GlobalState.get_ammo_count("R3") <= 0

	r1_button.tooltip_text = "R1 • Stok: %d" % GlobalState.get_ammo_count("R1")
	r2_button.tooltip_text = "R2 • Stok: %d" % GlobalState.get_ammo_count("R2")
	r3_button.tooltip_text = "R3 • Stok: %d" % GlobalState.get_ammo_count("R3")

func _get_target() -> Node2D:
	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player") as Node2D
	if player == null:
		return null

	if player.has_method("get_locked_target"):
		var t = player.call("get_locked_target")
		if is_instance_valid(t) and t is Node2D:
			return t as Node2D

	if "locked_target" in player:
		var t2 = player.locked_target
		if is_instance_valid(t2) and t2 is Node2D:
			return t2 as Node2D

	return null

func _try_fire() -> void:
	var target := _get_target()
	if target == null:
		return
	if player == null or not is_instance_valid(player):
		return

	var data: Dictionary = ROCKETS[selected_rocket]
	var rocket_name := str(data["name"])

	# R1/R2/R3 satın alınmadan kullanılamaz.
	if GlobalState.get_ammo_count(rocket_name) <= 0:
		print("ROKET STOĞU YOK: ", rocket_name)
		_update_button_state()
		return

	# Roket menzili lazer menzilinden tam 10 birim daha fazladır.
	if player.global_position.distance_to(target.global_position) > ROCKET_MAX_RANGE:
		print("ROKET MENZİL DIŞI: ", rocket_name)
		return

	# NAZ: saldırganlık SADECE roket hedefi vurunca _hit_target içinde işaretlenir.
	# Gerçek atış gerçekleşmeden koruma kalkmaz, stok da düşmez.
	if not GlobalState.use_ammo_stock(rocket_name, 1):
		_update_button_state()
		return

	cooldown_left = float(data["interval"])

	_spawn_rocket(target, data)
	_update_button_state()

func _spawn_rocket(target: Node2D, data: Dictionary) -> void:
	if rocket_world == null or not is_instance_valid(rocket_world):
		rocket_world = get_node_or_null("../World/Rockets") as Node2D
	if rocket_world == null:
		return

	var rocket := Node2D.new()
	rocket.name = str(data["name"]) + "_Projectile"
	rocket.global_position = player.global_position
	rocket.z_index = 30
	rocket_world.add_child(rocket)

	var sprite := Sprite2D.new()
	sprite.texture = load(str(data["texture"])) as Texture2D
	sprite.scale = Vector2.ONE * float(data["scale"])
	rocket.add_child(sprite)

	if bool(data["trail"]):
		var trail := AnimatedSprite2D.new()
		trail.sprite_frames = trail_frames
		trail.animation = &"default"
		trail.position = Vector2(-38.0, 0.0)
		trail.scale = Vector2(0.18, 0.18)
		trail.z_index = -1
		trail.play(&"default")
		rocket.add_child(trail)

	var direction := (target.global_position - rocket.global_position).normalized()
	rocket.rotation = direction.angle() - float(data["angle_offset"])

	projectiles.append({
		"node": rocket,
		"target": target,
		"damage_min": int(data["min_damage"]),
		"damage_max": int(data["max_damage"]),
		"angle_offset": float(data["angle_offset"]),
		"curve": str(data["name"]) == "R3",
		"curve_side": 1.0 if (Time.get_ticks_msec() % 2 == 0) else -1.0,
		"curve_time": 0.0
	})

func _update_projectiles(delta: float) -> void:
	for i in range(projectiles.size() - 1, -1, -1):
		var p: Dictionary = projectiles[i]
		var rocket: Node2D = p["node"] as Node2D
		if not is_instance_valid(p["target"]):
			projectiles.remove_at(i)
			continue

		var target: Node2D = p["target"] as Node2D

		if not is_instance_valid(rocket):
			projectiles.remove_at(i)
			continue

		if not is_instance_valid(target):
			rocket.queue_free()
			projectiles.remove_at(i)
			continue

		var target_pos := target.global_position
		var dist := rocket.global_position.distance_to(target_pos)
		var step := rocket_speed * delta

		if dist <= maxf(hit_distance, step):
			rocket.global_position = target_pos
			_hit_target(target, int(p["damage_min"]), int(p["damage_max"]), target_pos)
			rocket.queue_free()
			projectiles.remove_at(i)
			continue

		var direction := (target_pos - rocket.global_position).normalized()

		if bool(p.get("curve", false)):
			p["curve_time"] = float(p.get("curve_time", 0.0)) + delta
			var side := float(p.get("curve_side", 1.0))
			var perpendicular := Vector2(-direction.y, direction.x)
			var curve_amount := sin(float(p["curve_time"]) * r3_curve_speed) * r3_curve_strength * side
			direction = (direction + perpendicular * (curve_amount / 900.0)).normalized()
			p["node"].rotation = direction.angle()
			projectiles[i] = p
		else:
			rocket.rotation = direction.angle() - float(p["angle_offset"])

		rocket.global_position += direction * step

func _hit_target(target: Node2D, min_damage: int, max_damage: int, impact_pos: Vector2) -> void:
	var rolled_damage := float(randi_range(min_damage, max_damage))

	# NAZ (DarkOrbit): roket HEDEFİ VURDUĞU anda saldırı gerçekleşir.
	# Saldırıyı BAŞLATAN oyuncu güvenli bölge korumasını kaybeder.
	if is_instance_valid(player) and player.has_method("mark_as_aggressor"):
		player.call("mark_as_aggressor")

	# NPC hedefi saldıranı bilsin ki güvenli bölgede de karşılık verebilsin.
	if target != null and target.has_method("mark_attacked") and is_instance_valid(player):
		target.call("mark_attacked", player)

	var before_total := _target_total_durability(target)

	if target.has_method("take_damage"):
		target.call("take_damage", rolled_damage)
	elif "health" in target:
		target.health = maxf(float(target.health) - rolled_damage, 0.0)

	var after_total := _target_total_durability(target)
	var real_damage := maxf(before_total - after_total, 0.0)

	# ENC aktifse roketin verdiği gerçek hasar da %10 can emmeye dahil edilir.
	var extra_system := get_tree().get_first_node_in_group("extra_system")
	if extra_system != null and extra_system.has_method("on_player_dealt_damage"):
		extra_system.call("on_player_dealt_damage", real_damage)

	_spawn_impact(impact_pos)

func _target_total_durability(target: Node) -> float:
	var total := 0.0
	if "health" in target:
		total += maxf(float(target.health), 0.0)
	if "shield" in target:
		total += maxf(float(target.shield), 0.0)
	return total

func _spawn_impact(world_pos: Vector2) -> void:
	if rocket_world == null or not is_instance_valid(rocket_world):
		return

	var impact := AnimatedSprite2D.new()
	impact.sprite_frames = impact_frames
	impact.animation = &"default"
	impact.global_position = world_pos
	impact.scale = Vector2(0.08, 0.08)
	impact.z_index = 35
	rocket_world.add_child(impact)
	impact.play(&"default")
	impact.animation_finished.connect(func():
		if is_instance_valid(impact):
			impact.queue_free()
	)

func _build_grid_frames(texture: Texture2D, columns: int, rows: int, fps: float, looped: bool) -> SpriteFrames:
	var frames := SpriteFrames.new()
	frames.clear_all()
	if not frames.has_animation(&"default"):
		frames.add_animation(&"default")
	frames.set_animation_speed(&"default", fps)
	frames.set_animation_loop(&"default", looped)

	if texture == null:
		return frames

	var frame_w := texture.get_width() / columns
	var frame_h := texture.get_height() / rows

	for y in range(rows):
		for x in range(columns):
			var atlas := AtlasTexture.new()
			atlas.atlas = texture
			atlas.region = Rect2(
				float(x * frame_w),
				float(y * frame_h),
				float(frame_w),
				float(frame_h)
			)
			frames.add_frame(&"default", atlas)

	return frames


# Mobil HUD köprüsü. Mevcut roket mantığını değiştirmez.
func mobile_fire_rocket(index: int) -> void:
	if index < 0 or index > 2:
		return
	_select_and_fire(index)
