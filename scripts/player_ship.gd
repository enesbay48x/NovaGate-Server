extends CharacterBody2D
class_name PlayerShip

const RankBadge = preload("res://scripts/rank_badge.gd")

@export var max_speed: float = 300.0
@export var acceleration: float = 900.0
@export var braking: float = 1100.0
@export var rotation_speed: float = 8.5
@export var mouse_dead_zone: float = 28.0
@export var bank_strength: float = 0.14
@export var bank_smoothing: float = 9.0
@export var max_health: float = 400000.0
@export var max_shield: float = 0.0
@export var idle_bob_amount: float = 1.8
@export var idle_bob_speed: float = 1.35

const DIRECTION_COUNT: int = 72
const ADMIN_SHIP_DATA_PATH: String = "res://assets/ship108.json"
const SHIP_CATALOG_PATH: String = "res://market/data/ships.json"
# DarkOrbit NAZ: son düşmanca eylemden sonra korumanın geri gelme süresi (sn).
const COMBAT_AGGRESSION_SECONDS: float = 10.0

var health: float = 400000.0
var shield: float = 0.0
var moving: bool = false
var mouse_steering: bool = false
var is_in_combat: bool = false
# DarkOrbit NAZ: saldırıyı BAŞLATAN oyuncu güvenli bölge (NAZ) korumasını kaybeder.
var combat_aggression_timer: float = 0.0
var auto_navigation: bool = false
var target_position: Vector2 = Vector2.ZERO
var fire_cooldown: float = 0.0
var position_save_timer: float = 0.0
# NovaGate Lazer Slot Sistemi
var ammo_slots = {
	1:"RLX-1",
	2:"GLX-2",
	3:"BLX-3",
	4:"WLX-4",
	5:"SAB",
	6:"RSB"
}
var active_slot: int = 0
var bank_amount: float = 0.0
var facing_angle: float = 0.0
var direction_frame: int = 0
var ship_data: Dictionary = {}
var active_ship_id: String = "Ship10"
var active_ship_profile: Dictionary = {}
var ship_regions: Array[Rect2] = []
var ship_base_health: float = 8000.0
var ship_base_speed: float = 320.0
var laser_slot_limit: int = 1
var generator_slot_limit: int = 1
var extra_slot_limit: int = 0
var world_rect: Rect2 = Rect2(-3000.0, -2000.0, 6000.0, 4000.0)
var in_safe_zone: bool = false
var idle_time: float = 0.0
var base_speed: float = 300.0
var laser_damage: float = 0.0
var equipment_damage_raw: int = 0
var equipment_shield_raw: int = 0
var equipment_speed_raw: int = 0
var persistent_bonus_refresh_timer: float = 0.0
var persistent_bonus_signature: String = ""
var active_config: int = 1
var config_shield_values: Dictionary = {1: -1.0, 2: -1.0}
var config_shield_restore_pending: bool = false
var entity_status_bars: Node2D
var ship_status_label: Label
var rank_badge: TextureRect
var config_status_label: Label
var ammo_status_label: Label
var locked_target: Node2D = null
var is_destroyed: bool = false

# NovaGate otomatik HP/Kalkan yenileme
var regen_delay: float = 5.0
var regen_timer: float = 0.0
var last_health: float = 400000.0
var last_shield: float = 0.0
var regen_tick: float = 0.0

@onready var visual: Node2D = $Visual
var ship_sprite: Sprite2D = null
@onready var safe_zone_label: Label = $SafeZoneLabel

func _ready() -> void:
	add_to_group("player")
	facing_angle = 0.0
	target_position = global_position

	# Normal oyuncular her zaman kayıtlı aktif gemilerini yükler.
	# ADMIN gemisi aktifse test bakiyesi ve ADMIN görünümü uygulanır.
	_load_active_ship_profile()
	_recalculate_effective_stats(false)

	health = max_health
	shield = max_shield
	last_health = health
	last_shield = shield

	var flames_node: Node2D = get_node_or_null("Visual/EngineFlames") as Node2D
	if flames_node != null:
		flames_node.visible = false
	if safe_zone_label != null:
		safe_zone_label.visible = false
	_build_ship_status_labels()
	_update_ship_status_labels()
	_update_direction_frame()


func _ensure_ship_sprite() -> void:
	if ship_sprite != null and is_instance_valid(ship_sprite):
		return

	ship_sprite = get_node_or_null("Visual/Ship") as Sprite2D

	if ship_sprite == null:
		var visual := get_node_or_null("Visual")
		if visual == null:
			visual = Node2D.new()
			visual.name = "Visual"
			add_child(visual)

		ship_sprite = Sprite2D.new()
		ship_sprite.name = "Ship"
		visual.add_child(ship_sprite)

func _load_ship_data() -> void:
	_ensure_ship_sprite()
	# Admin test gemisinin eski silah pozisyon verisini korur.
	if not FileAccess.file_exists(ADMIN_SHIP_DATA_PATH):
		return
	var file: FileAccess = FileAccess.open(ADMIN_SHIP_DATA_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		ship_data = parsed as Dictionary


func reload_active_ship_from_save() -> void:
	var previous_health_ratio := 1.0
	if max_health > 0.0:
		previous_health_ratio = clampf(health / max_health, 0.0, 1.0)

	_load_active_ship_profile()

	health = max_health * previous_health_ratio
	if health <= 0.0:
		health = max_health
	shield = clampf(shield, 0.0, max_shield)
	last_health = health
	last_shield = shield
	_update_direction_frame()
	_update_ship_status_labels()
	stats_changed.emit(health, shield)


func _load_active_ship_profile() -> void:
	var account_manager = load("res://scripts/account_manager.gd").new()
	account_manager.ensure_starter_ship()
	var role:String = account_manager.get_player_role()
	active_ship_id = account_manager.get_active_ship()

	if active_ship_id == "ADMIN":
		var admin_balance = load("res://scripts/account_manager.gd").new()
		admin_balance.apply_admin_ship_balance()
		_use_admin_ship()
		return

	if active_ship_id == "ADMIN_TEST":
		active_ship_id = "ADMIN"

	var profile := _find_ship_profile(active_ship_id)
	if profile.is_empty():
		active_ship_id = "Ship10"
		profile = _find_ship_profile(active_ship_id)

	if profile.is_empty():
		push_warning("Ship10 gemi verisi bulunamadı; güvenli varsayılan kullanılıyor.")
		profile = {
			"id":"Ship10",
			"name":"Nova Scout",
			"hp":8000,
			"speed":320,
			"laser_slots":1,
			"generator_slots":1,
			"extra_slots":0,
			"image":"res://assets/gemiship/ship10.png",
			"atlas":"res://assets/gemiship/ship10.atlas"
		}

	_apply_ship_profile(profile)


func _find_ship_profile(ship_id:String) -> Dictionary:
	if not FileAccess.file_exists(SHIP_CATALOG_PATH):
		return {}
	var f := FileAccess.open(SHIP_CATALOG_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Array):
		return {}
	for value in parsed:
		if value is Dictionary:
			var data:Dictionary = value
			if str(data.get("id","")) == ship_id:
				return data
	return {}


func _apply_ship_profile(profile:Dictionary) -> void:
	active_ship_profile = profile.duplicate(true)
	ship_data = {}

	var hp_value := int(profile.get("hp", 0))
	# Can değeri henüz verilmemiş gemi aktif edilemez; güvenli olarak Ship10'a düşer.
	if hp_value <= 0:
		if str(profile.get("id","")) != "Ship10":
			var fallback := _find_ship_profile("Ship10")
			if not fallback.is_empty():
				active_ship_id = "Ship10"
				_apply_ship_profile(fallback)
				return
		hp_value = 8000

	ship_base_health = float(hp_value)
	ship_base_speed = float(profile.get("speed", 320))
	base_speed = ship_base_speed
	max_speed = ship_base_speed
	max_health = ship_base_health
	laser_slot_limit = maxi(int(profile.get("laser_slots", 1)), 0)
	generator_slot_limit = maxi(int(profile.get("generator_slots", 1)), 0)
	extra_slot_limit = maxi(int(profile.get("extra_slots", 0)), 0)
	if GlobalState.is_admin:
		laser_slot_limit = maxi(laser_slot_limit, GlobalState.server_laser_slots)
		generator_slot_limit = maxi(generator_slot_limit, GlobalState.server_generator_slots)
		extra_slot_limit = maxi(extra_slot_limit, GlobalState.server_extra_slots)

	var image_path := str(profile.get("image", ""))

	if ship_sprite == null:
		var new_sprite := Sprite2D.new()
		new_sprite.name = "ShipSprite"
		add_child(new_sprite)
		ship_sprite = new_sprite

	if image_path != "" and ResourceLoader.exists(image_path):
		ship_sprite.texture = load(image_path)

	ship_regions = _parse_texture_packer_atlas(str(profile.get("atlas", "")))
	if not ship_regions.is_empty():
		ship_sprite.region_enabled = true
		ship_sprite.hframes = 1
		ship_sprite.vframes = 1
		ship_sprite.frame = 0
		ship_sprite.region_rect = ship_regions[0]
		var max_side := maxf(ship_regions[0].size.x, ship_regions[0].size.y)
		var target_size := 105.0
		var scale_value := minf(1.0, target_size / maxf(max_side, 1.0))
		ship_sprite.scale = Vector2.ONE * scale_value
	else:
		ship_sprite.region_enabled = false


func _use_admin_ship() -> void:
	_ensure_ship_sprite()
	active_ship_profile = {}
	ship_regions.clear()
	ship_sprite.region_enabled = false
	ship_sprite.hframes = 9
	ship_sprite.vframes = 8
	ship_base_health = 400000.0
	ship_base_speed = 300.0
	base_speed = 300.0
	max_speed = 300.0
	max_health = 400000.0
	laser_slot_limit = 30
	generator_slot_limit = 16
	extra_slot_limit = 8
	_load_ship_data()


func _parse_texture_packer_atlas(atlas_path:String) -> Array[Rect2]:
	var result:Array[Rect2] = []
	if atlas_path == "" or not FileAccess.file_exists(atlas_path):
		return result

	var f := FileAccess.open(atlas_path, FileAccess.READ)
	if f == null:
		return result

	var text := f.get_as_text()
	var pending_xy := Vector2(-1.0, -1.0)
	var seen := {}

	for raw_line in text.split("
"):
		var line := str(raw_line).strip_edges()
		if line.begins_with("xy:"):
			var pieces := line.substr(3).split(",")
			if pieces.size() >= 2:
				pending_xy = Vector2(float(pieces[0].strip_edges()), float(pieces[1].strip_edges()))
		elif line.begins_with("size:") and pending_xy.x >= 0.0:
			var pieces := line.substr(5).split(",")
			if pieces.size() >= 2:
				var rect := Rect2(
					pending_xy,
					Vector2(float(pieces[0].strip_edges()), float(pieces[1].strip_edges()))
				)
				var key := "%d,%d,%d,%d" % [
					int(rect.position.x),
					int(rect.position.y),
					int(rect.size.x),
					int(rect.size.y)
				]
				if not seen.has(key):
					seen[key] = true
					result.append(rect)
				pending_xy = Vector2(-1.0, -1.0)

	return result

func _unhandled_input(event: InputEvent) -> void:
	if is_destroyed:
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		var is_mobile_platform: bool = (
			OS.get_name() == "Android"
			or OS.get_name() == "iOS"
		)

		if mouse_event.button_index == MOUSE_BUTTON_LEFT:
			if mouse_event.pressed:
				# NPC dokunması hem PC hem mobilde hedef seçmeye devam eder.
				var clicked_npc: SpaceNPC = _find_npc_at_mouse()
				if clicked_npc != null:
					selection_requested.emit(clicked_npc)
					return

				# MOBİL:
				# Boş ekrana dokunmak GEMİYİ HAREKET ETTİRMEZ.
				# Hareket yalnız sol joystick'ten gelir.
				# Kutu/diğer Area2D input_event'leri kendi scriptlerinde çalışmaya devam eder.
				if is_mobile_platform:
					mouse_steering = false
					return

				# PC:
				# Mevcut sol tık basılı tutarak hareket sistemi aynen korunur.
				mouse_steering = true
				moving = true
			else:
				if not is_mobile_platform:
					mouse_steering = false

		# Sağ tık hedef bırakma yalnız PC kontrolüdür.
		if (
			not is_mobile_platform
			and mouse_event.button_index == MOUSE_BUTTON_RIGHT
			and mouse_event.pressed
		):
			selection_requested.emit(null)

func _find_npc_at_mouse() -> SpaceNPC:
	var query := PhysicsPointQueryParameters2D.new()
	query.position = get_global_mouse_position()
	query.collision_mask = 2
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hits: Array[Dictionary] = get_world_2d().direct_space_state.intersect_point(query, 8)
	for hit: Dictionary in hits:
		var collider: Object = hit.get("collider")
		if collider is SpaceNPC:
			return collider as SpaceNPC
	return null

func set_locked_target(target: Node2D) -> void:
	# Only the CURRENT_TARGET shows its world status bars; hide the previous one.
	if locked_target != null and locked_target != target and is_instance_valid(locked_target) \
			and "entity_status_bars" in locked_target and is_instance_valid(locked_target.entity_status_bars):
		locked_target.entity_status_bars.refresh()
	locked_target = target
	if entity_status_bars != null:
		entity_status_bars.refresh()

func set_navigation_target(world_position: Vector2) -> void:
	target_position = world_position
	auto_navigation = true
	mouse_steering = false
	moving = true

func stop_navigation() -> void:
	moving = false
	auto_navigation = false
	mouse_steering = false

func has_safe_zone_protection() -> bool:
	# DarkOrbit NAZ: coğrafi güvenli bölge + saldırganlık durumu birlikte değerlendirilir.
	# Saldırıyı BAŞLATAN oyuncu korumasını kaybeder (is_in_combat / aggression timer).
	return in_safe_zone and not is_in_combat and combat_aggression_timer <= 0.0

func mark_as_aggressor() -> void:
	# Saldırı başlatıldığı anda combat/aggression state işaretlenir ve NAZ koruması kalkar.
	# Düşman şirket oyuncusu / NPC artık bu oyuncuya saldırabilir.
	is_in_combat = true
	combat_aggression_timer = COMBAT_AGGRESSION_SECONDS
	if in_safe_zone:
		in_safe_zone = false
		if is_instance_valid(safe_zone_label):
			safe_zone_label.visible = false

func receive_enemy_player_attack(_attacker_company: String = "") -> bool:
	# Düşman şirket oyuncusu saldırısı: koruma altındaki oyuncu hedef OLAMAZ.
	# Saldırmayan oyuncu güvendedir; saldırganın koruması ayrı yönetilir.
	if has_safe_zone_protection():
		return false
	return true

func set_safe_zone(value: bool) -> void:
	if value and (is_in_combat or combat_aggression_timer > 0.0):
		return
	in_safe_zone = value
	if is_instance_valid(safe_zone_label):
		safe_zone_label.visible = value

func _process(delta: float) -> void:
	# DarkOrbit NAZ: saldırganlık süresi bitince combat state düşer, koruma geri gelebilir.
	if combat_aggression_timer > 0.0:
		combat_aggression_timer = maxf(combat_aggression_timer - delta, 0.0)
		if combat_aggression_timer <= 0.0:
			is_in_combat = false
	persistent_bonus_refresh_timer -= delta
	if persistent_bonus_refresh_timer <= 0.0:
		persistent_bonus_refresh_timer = 1.0
		_refresh_persistent_bonus_if_needed()

	if is_destroyed:
		return
	_process_auto_regen(delta)
	var mouse_world: Vector2 = get_global_mouse_position()
	var mouse_vector: Vector2 = mouse_world - global_position

	if mouse_steering:
		target_position = mouse_world
		moving = mouse_vector.length() > mouse_dead_zone

	var combat_target_locked: bool = (
		is_instance_valid(locked_target)
		and _is_auto_fire_active()
		and global_position.distance_to(locked_target.global_position) <= 550.0
	)

	var steering_vector: Vector2 = Vector2.ZERO
	var should_turn: bool = false

	# Otomatik saldırı açıkken geminin burnunu yalnızca kilitli NPC belirler.
	# Hareket hedefi ve fare, geminin yönünü değiştirmez.
	if combat_target_locked:
		var target_angle: float = global_position.direction_to(locked_target.global_position).angle()
		facing_angle = lerp_angle(
			facing_angle,
			target_angle,
			1.0 - exp(-rotation_speed * delta)
		)
		bank_amount = lerpf(bank_amount, 0.0, 1.0 - exp(-bank_smoothing * delta))
		_update_direction_frame()
	else:
		if mouse_steering:
			steering_vector = mouse_vector
			should_turn = steering_vector.length() > mouse_dead_zone
		elif auto_navigation or moving:
			steering_vector = target_position - global_position
			should_turn = steering_vector.length() > mouse_dead_zone
		elif velocity.length() > 8.0:
			steering_vector = velocity
			should_turn = true

		if should_turn:
			var desired_angle: float = steering_vector.angle()
			var previous_angle: float = facing_angle
			facing_angle = lerp_angle(
				facing_angle,
				desired_angle,
				1.0 - exp(-rotation_speed * delta)
			)
			var turn_delta: float = wrapf(facing_angle - previous_angle, -PI, PI)
			var turn_speed_value: float = turn_delta / maxf(delta, 0.001)
			var target_bank: float = clampf(turn_speed_value * bank_strength, -0.20, 0.20)
			bank_amount = lerpf(
				bank_amount,
				target_bank,
				1.0 - exp(-bank_smoothing * delta)
			)
			_update_direction_frame()
		else:
			bank_amount = lerpf(
				bank_amount,
				0.0,
				1.0 - exp(-bank_smoothing * delta)
			)

	# Uzayda hafif süzülme yalnızca gemi dururken görsel katmana uygulanır.
	if not moving and velocity.length() < 5.0:
		idle_time += delta
		visual.position = Vector2(sin(idle_time * idle_bob_speed * 0.75), sin(idle_time * idle_bob_speed)) * idle_bob_amount
	else:
		idle_time = 0.0
		visual.position = visual.position.lerp(Vector2.ZERO, 1.0 - exp(-8.0 * delta))

	visual.scale = Vector2(1.0, 1.0 - absf(bank_amount) * 0.08)
	visual.skew = bank_amount * 0.10
	fire_cooldown = maxf(fire_cooldown - delta, 0.0)
	var ammo_keys: Array[Key] = [
		KEY_1,
		KEY_2,
		KEY_3,
		KEY_4,
		KEY_5,
		KEY_6
	]

	for i in range(ammo_keys.size()):
		if Input.is_key_pressed(ammo_keys[i]):
			select_ammo(i + 1)

func _physics_process(delta: float) -> void:
	if is_destroyed:
		velocity = Vector2.ZERO
		return
	if moving:
		var distance: float = global_position.distance_to(target_position)
		if distance > mouse_dead_zone + (velocity.length() * 0.35):
			var direction: Vector2 = global_position.direction_to(target_position)
			velocity = velocity.move_toward(direction * max_speed, acceleration * delta)
		else:
			velocity = velocity.move_toward(Vector2.ZERO, braking * delta)
			if auto_navigation:
				auto_navigation = false
				moving = false
	else:
		velocity = velocity.move_toward(Vector2.ZERO, braking * delta)
	move_and_slide()
	# Oyuncu harita sınırının dışına çıkabilir. Radyasyon sistemi WORLD_RECT dışında devreye girer.
	position_save_timer -= delta

	if position_save_timer <= 0:
		position_save_timer = 2.0

		var scene = get_tree().current_scene
		var map_name := ""

		if scene != null and "current_map_name" in scene:
			map_name = str(scene.current_map_name)

		GlobalState.notify_position_state(
			map_name,
			global_position
		)
func _clamp_to_world(value: Vector2) -> Vector2:
	return Vector2(
		clampf(value.x, world_rect.position.x + 60.0, world_rect.end.x - 60.0),
		clampf(value.y, world_rect.position.y + 60.0, world_rect.end.y - 60.0)
	)

func _update_direction_frame() -> void:
	var normalized_angle: float = fposmod(-facing_angle, TAU)
	if not ship_regions.is_empty():
		var frame_count := ship_regions.size()
		direction_frame = posmod(int(round(normalized_angle / TAU * float(frame_count))), frame_count)
		ship_sprite.region_rect = ship_regions[direction_frame]
		ship_sprite.frame = 0
	else:
		direction_frame = posmod(int(round(normalized_angle / TAU * float(DIRECTION_COUNT))), DIRECTION_COUNT)
		ship_sprite.frame = direction_frame

func get_gun_world_positions() -> Array[Vector2]:
	var results: Array[Vector2] = []
	var guns_value: Variant = ship_data.get("guns", [])
	if guns_value is Array:
		for gun_value: Variant in guns_value as Array:
			if gun_value is Dictionary:
				var positions_value: Variant = (gun_value as Dictionary).get("positions", [])
				if positions_value is Array:
					var positions: Array = positions_value as Array
					if direction_frame < positions.size():
						var point_value: Variant = positions[direction_frame]
						if point_value is Array and (point_value as Array).size() >= 2:
							var point: Array = point_value as Array
							results.append(to_global(Vector2(float(point[0]), float(point[1])) * ship_sprite.scale))
	if results.is_empty():
		results.append(global_position + Vector2.RIGHT.rotated(facing_angle) * 48.0)
	return results

func apply_equipment_stats(damage_value: int, shield_bonus: int, speed_bonus: int) -> void:
	equipment_damage_raw = maxi(damage_value, 0)
	equipment_shield_raw = maxi(shield_bonus, 0)
	equipment_speed_raw = maxi(speed_bonus, 0)

	if config_shield_restore_pending:
		# Config değişiminde eski config'in oranını yeni config'e taşıma.
		# Önce yeni max değerleri hesapla, sonra bu config'in kendi canlı kalkanını geri yükle.
		_recalculate_effective_stats(false)
		var saved_shield := float(config_shield_values.get(active_config, -1.0))
		if saved_shield < 0.0:
			# Config ilk kez kullanılıyorsa takılı jeneratörlerin sağladığı kalkanla dolu başlasın.
			shield = max_shield
		else:
			shield = clampf(saved_shield, 0.0, max_shield)
		config_shield_values[active_config] = shield
		config_shield_restore_pending = false
		last_shield = shield
		_update_ship_status_labels()
		stats_changed.emit(health, shield)
	else:
		_recalculate_effective_stats(true)
		config_shield_values[active_config] = shield


func _persistent_bonus_state_signature() -> String:
	return "%s|%s|%s|%s|%s|%s|%s|%s" % [
		str(GlobalState.is_booster_active("DMG-B01")),
		str(GlobalState.is_booster_active("HP-B01")),
		str(GlobalState.is_booster_active("SHD-B01")),
		str(GlobalState.get_skill_level("laser_power")),
		str(GlobalState.get_skill_level("npc_damage")),
		str(GlobalState.get_skill_level("shield_power")),
		str(GlobalState.get_skill_level("hp_power")),
		str(GlobalState.get_skill_level("motor_power"))
	]


func _refresh_persistent_bonus_if_needed() -> void:
	var new_signature := _persistent_bonus_state_signature()
	if new_signature == persistent_bonus_signature:
		return
	persistent_bonus_signature = new_signature
	_recalculate_effective_stats(true)


func refresh_persistent_bonuses() -> void:
	persistent_bonus_signature = ""
	_refresh_persistent_bonus_if_needed()


func _recalculate_effective_stats(preserve_ratios: bool = true) -> void:
	var health_ratio := 1.0
	var shield_ratio := 0.0
	if preserve_ratios and max_health > 0.0:
		health_ratio = clampf(health / max_health, 0.0, 1.0)
	if preserve_ratios and max_shield > 0.0:
		shield_ratio = clampf(shield / max_shield, 0.0, 1.0)

	var damage_multiplier := 1.0 + GlobalState.get_skill_stat_bonus("laser_power")
	damage_multiplier += GlobalState.get_booster_bonus("DMG-B01")

	var hp_multiplier := 1.0 + GlobalState.get_skill_stat_bonus("hp_power")
	hp_multiplier += GlobalState.get_booster_bonus("HP-B01")

	var shield_multiplier := 1.0 + GlobalState.get_skill_stat_bonus("shield_power")
	shield_multiplier += GlobalState.get_booster_bonus("SHD-B01")

	var speed_multiplier := 1.0 + GlobalState.get_skill_stat_bonus("motor_power")

	laser_damage = float(equipment_damage_raw) * damage_multiplier
	base_speed = (ship_base_speed + float(equipment_speed_raw)) * speed_multiplier
	max_speed = base_speed
	max_health = ship_base_health * hp_multiplier
	max_shield = float(equipment_shield_raw) * shield_multiplier

	# Admin bonus: serverdan gelen is_admin bilgisine göre uygulanır.
	# Admin hesabı client tarafından oluşturulamaz; sadece gelen yetki kullanılır.
	if GlobalState.is_admin:
		max_health *= 2.0
		max_shield *= 2.0
		laser_damage *= GlobalState.server_laser_damage_multiplier

	if preserve_ratios:
		health = clampf(max_health * health_ratio, 0.0, max_health)
		shield = clampf(max_shield * shield_ratio, 0.0, max_shield)
	else:
		health = clampf(health, 0.0, max_health)
		shield = clampf(shield, 0.0, max_shield)

	last_health = health
	last_shield = shield
	_update_ship_status_labels()
	stats_changed.emit(health, shield)

func get_ship_slot_limits() -> Dictionary:
	return {
		"laser": laser_slot_limit,
		"generator": generator_slot_limit,
		"extra": extra_slot_limit
	}


func get_active_ship_id() -> String:
	return active_ship_id


func _build_ship_status_labels() -> void:
	entity_status_bars = preload("res://scripts/entity_status_bars.gd").new()
	entity_status_bars.bind_entity(self,
		func() -> Vector4: return Vector4(health, max_health, shield, max_shield),
		func(): return ship_sprite,
		# Own ship status lives in the HUD; world bars are reserved for the current target only.
		func() -> bool: return false)
	ship_status_label = Label.new()
	ship_status_label.position = Vector2(-115.0, 72.0)
	ship_status_label.size = Vector2(230.0, 60.0)
	ship_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ship_status_label.add_theme_font_size_override("font_size", 12)
	ship_status_label.add_theme_color_override("font_color", Color(0.88, 0.96, 1.0))
	ship_status_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 1.0))
	ship_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ship_status_label)

	rank_badge = TextureRect.new()
	rank_badge.position = Vector2(-72.0, 73.0)
	rank_badge.size = Vector2(18.0, 18.0)
	rank_badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rank_badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rank_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rank_badge)
	_update_rank_badge()

	# Konfigurasyon ve lazer/cephane yazilari kaldirildi.
	config_status_label = null
	ammo_status_label = null

func _ammo_name() -> String:
	var names:Array[String] = ["X1","X2","X3","X4","SAB","RSB"]
	return names[clampi(active_slot, 0, names.size() - 1)]

func _update_rank_badge() -> void:
	# Badge bileseni tek kaynaktir; "A" rutbesi de ayni yerden gelir.
	RankBadge.apply(rank_badge, GlobalState.display_rank_key())


func _update_ship_status_labels() -> void:
	if is_instance_valid(entity_status_bars):
		entity_status_bars.refresh()
	if ship_status_label != null:
		var display_nick: String = GlobalState.nickname.strip_edges()
		if display_nick.is_empty():
			display_nick = GlobalState.username
		if not GlobalState.clan_tag.is_empty():
			display_nick = "[" + GlobalState.clan_tag + "] " + display_nick

		ship_status_label.add_theme_font_size_override("font_size", 18)
		ship_status_label.text = display_nick + "
" + _format_number(health) + "
" + _format_number(shield)
		_update_rank_badge()

		# Rütbe ikonu sabit X koordinatında kalınca [KLAN] etiketi uzadığı
		# zaman ilk harflerin üstüne biniyordu. Nick satırının gerçek piksel
		# genişliğini ölçüp ikonu yazının SOLUNA dinamik olarak yerleştiriyoruz.
		if rank_badge != null:
			var status_font: Font = ship_status_label.get_theme_font("font")
			var nick_width: float = status_font.get_string_size(
				display_nick,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				18
			).x
			rank_badge.position = Vector2(-(nick_width * 0.5) - 24.0, 72.0)

		ship_status_label.modulate = Color.WHITE

	if config_status_label != null:
		config_status_label.text = ""

	if ammo_status_label != null:
		ammo_status_label.text = ""

func select_ammo(slot:int) -> void:
	active_slot = slot

	var ammo_name = get_node("/root/SlotManager").get_slot_laser(slot)

	print("AKTİF SLOT:", slot, " LAZER:", ammo_name)

	var laser_name = get_node("/root/SlotManager").get_slot_laser(slot)

	match laser_name:
		"RLX-1":
			WeaponSystem.select_laser(0)
		"RLX-2":
			WeaponSystem.select_laser(1)
		"BLX-3":
			WeaponSystem.select_laser(2)
		"WLX-4":
			WeaponSystem.select_laser(3)
		"SAB":
			WeaponSystem.select_laser(4)
		"RSB":
			WeaponSystem.select_laser(5)

	ammo_changed.emit(slot)


func set_active_config(config_number: int) -> void:
	var new_config := clampi(config_number, 1, 2)
	if new_config == active_config:
		_update_ship_status_labels()
		return

	# Çıkılan konfigürasyonun canlı kalkanını kendi slotunda sakla.
	config_shield_values[active_config] = shield
	active_config = new_config
	config_shield_restore_pending = true
	_update_ship_status_labels()

func get_laser_damage(is_npc: bool = true) -> float:
	var result := laser_damage
	if is_npc:
		result *= 1.0 + GlobalState.get_skill_stat_bonus("npc_damage")
	result *= GlobalState.get_critical_multiplier()
	return result

func apply_server_world_state(
	health_value: float,
	shield_value: float,
	alive_value: bool
) -> void:
	if health_value >= 0.0:
		health = clampf(health_value, 0.0, max_health)
	if shield_value >= 0.0:
		shield = clampf(shield_value, 0.0, max_shield)

	last_health = health
	last_shield = shield
	is_destroyed = not alive_value or health <= 0.0

	_update_ship_status_labels()
	stats_changed.emit(health, shield)


func add_sab_shield(amount: float) -> float:
	# SAB ile emilen gerçek kalkan kadar kendi kalkanını doldur.
	if amount <= 0.0 or max_shield <= 0.0:
		return 0.0

	var before: float = shield
	shield = minf(max_shield, shield + amount)
	var gained: float = maxf(shield - before, 0.0)

	if gained > 0.0:
		regen_timer = 0.0
		regen_tick = 0.0
		_update_ship_status_labels()
		stats_changed.emit(health, shield)

	return gained


func take_radiation_damage(amount: float) -> void:
	if is_destroyed or amount <= 0.0:
		return

	# Radyasyon kalkanı ve güvenli bölgeyi yok sayar; doğrudan gövdeye işler.
	regen_timer = 0.0
	regen_tick = 0.0
	health = maxf(0.0, health - amount)

	var scene = get_tree().current_scene
	var map_name := ""
	if scene != null and "current_map_name" in scene:
		map_name = str(scene.current_map_name)
	GlobalState.notify_damage_state(health, shield, map_name, global_position)

	_show_damage_number(amount)
	_update_ship_status_labels()
	stats_changed.emit(health, shield)

	if health <= 0.0:
		_on_ship_destroyed()


func take_damage(amount: float, from_npc: bool = false) -> void:
	if is_destroyed:
		return
	# GÜVENLİ BÖLGE / NAZ (DarkOrbit):
	# Hiç saldırı başlatmamış oyuncu korunur: PvP ve NPC hasarı işlemez.
	# Saldırıyı BAŞLATAN oyuncu korumasını kaybettiği için her türlü hasarı alır.
	# (from_npc parametresi korunur; eski çağrılar bozulmaz.)
	if has_safe_zone_protection():
		return

	# NOVAGATE EXTRA HOOK: 3 saniyelik kalkan. Mevcut hasar hesabına dokunmaz.
	var extra_system = get_tree().get_first_node_in_group("extra_system")
	if extra_system != null and extra_system.has_method("is_damage_blocked"):
		if bool(extra_system.call("is_damage_blocked")):
			if extra_system.has_method("on_damage_blocked"):
				extra_system.call("on_damage_blocked", amount)
			return

	# Hasar geldi: otomatik yenileme sayacı sıfırlanır
	regen_timer = 0.0
	regen_tick = 0.0

	var hp_damage: float = amount
	if shield > 0.0:
		var shield_portion: float = amount * 0.80
		var absorbed: float = minf(shield, shield_portion)
		shield -= absorbed
		# Kalkan varken hasarın %20'si doğrudan cana geçer.
		# Kalkan %80'lik kısmı tamamen karşılayamazsa kalan da cana taşar.
		hp_damage = (amount * 0.20) + (shield_portion - absorbed)

	health = maxf(0.0, health - hp_damage)

	# Quest event: hasar alma hedefi (minimal hook).
	QuestSystem.record_event("damage_taken", {"amount": int(maxf(amount, 0.0))})

	# Combat logout için sunucuya gerçek HP/Kalkanı anında bildir.
	# Bu çağrı hasar geldikçe server logout sayacını yeniden 5 saniyeye çeker.
	var scene = get_tree().current_scene
	var map_name := ""
	if scene != null and "current_map_name" in scene:
		map_name = str(scene.current_map_name)
	GlobalState.notify_damage_state(health, shield, map_name, global_position)

	if health <= 0:
		_on_ship_destroyed()
		return

	_show_damage_number(amount)
	_update_ship_status_labels()
	stats_changed.emit(health, shield)


func _is_auto_fire_active() -> bool:
				var weapon_system = get_node_or_null("/root/WeaponSystem")
				if weapon_system != null:
								return weapon_system.auto_fire
				return false

signal fire_requested(target: Vector2, ammo: int)
signal ammo_changed(ammo: int)
signal stats_changed(health_value: float, shield_value: float)
signal selection_requested(npc: SpaceNPC)
signal ship_destroyed
func _process_auto_regen(delta: float) -> void:
	# Hasar almıyorsa 5 saniye bekle
	if health != last_health or shield != last_shield:
		regen_timer = 0.0
		regen_tick = 0.0

	last_health = health
	last_shield = shield

	regen_timer += delta

	if regen_timer < regen_delay:
		return

	regen_tick += delta

	if regen_tick >= 1.0:
		regen_tick = 0.0

		var heal_amount: float = randf_range(16000.0, 18000.0)

		if health < max_health:
			var before := health
			health = minf(max_health, health + heal_amount)
			var healed := health - before
			if healed > 0:
				_show_heal_number(healed)

		if shield < max_shield:
			shield = minf(max_shield, shield + heal_amount)

		# Regenin kendi artırdığı HP/Kalkan bir sonraki karede hasar gibi algılanmasın.
		# Böylece 5 saniye bekledikten sonra her 1 saniyede bir yenilenmeye devam eder.
		last_health = health
		last_shield = shield

		_update_ship_status_labels()
		stats_changed.emit(health, shield)


func _show_heal_number(amount: float) -> void:
	var label = Label.new()
	label.text = "+" + str(int(amount))
	label.modulate = Color(0.2, 1.0, 0.2)
	label.z_index = 4000

	get_tree().current_scene.add_child(label)

	label.global_position = global_position + Vector2(-20, -80)

	var tween = create_tween()
	tween.tween_property(label, "position", label.position + Vector2(0, -60), 1.0)
	tween.parallel().tween_property(label, "modulate:a", 0.0, 1.0)
	tween.tween_callback(label.queue_free)


func _show_damage_number(amount: float) -> void:
	var label = Label.new()
	label.text = "-" + str(int(amount))
	label.modulate = Color(1, 0, 0)
	label.z_index = 4000

	get_tree().current_scene.add_child(label)

	label.global_position = global_position + Vector2(-20, -80)

	var tween = create_tween()

	tween.tween_property(
		label,
		"position",
		label.position + Vector2(0, -60),
		1.0
	)

	tween.parallel().tween_property(
		label,
		"modulate:a",
		0.0,
		1.0
	)

	tween.tween_callback(label.queue_free)
func _format_number(value: float) -> String:
	var number = str(int(value))
	var result = ""

	while number.length() > 3:
		result = "." + number.substr(number.length() - 3, 3) + result
		number = number.substr(0, number.length() - 3)

	return number + result
func _on_ship_destroyed() -> void:
	if is_destroyed:
		return

	print("GEMİ PATLADI")
	is_destroyed = true
	health = 0.0
	regen_timer = 0.0
	regen_tick = 0.0

	var weapon_system = get_node_or_null("/root/WeaponSystem")
	if weapon_system:
		weapon_system.auto_fire = false

	locked_target = null
	moving = false
	auto_navigation = false
	mouse_steering = false
	velocity = Vector2.ZERO

	visible = false
	_update_ship_status_labels()
	stats_changed.emit(health, shield)

	# Otomatik doğma YOK. Ana sahne Tamir Et ekranını açar.
	ship_destroyed.emit()


func repair_after_death() -> void:
	# Bu fonksiyon yalnızca Tamir Et butonuna basıldıktan ve harita/doğma
	# işlemi tamamlandıktan sonra çağrılır.
	# Patlama sonrası oyuncu tam dolu doğmaz.
	# %25 gövde ve 0 kalkan ile doğar; 5 saniye hasar almazsa normal regen başlar.
	health = max_health * 0.25
	shield = 0.0
	last_health = health
	last_shield = shield
	regen_timer = 0.0
	regen_tick = 0.0
	locked_target = null
	moving = false
	auto_navigation = false
	mouse_steering = false
	velocity = Vector2.ZERO
	is_destroyed = false
	visible = true
	_update_ship_status_labels()
	stats_changed.emit(health, shield)
	print("GEMİ TAMİR EDİLDİ VE DOĞDU")


func _input(event):
	if is_destroyed:
		return
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_1:
				select_ammo(1)
			KEY_2:
				select_ammo(2)
			KEY_3:
				select_ammo(3)
			KEY_4:
				select_ammo(4)
			KEY_5:
				select_ammo(5)
			KEY_6:
				select_ammo(6)
