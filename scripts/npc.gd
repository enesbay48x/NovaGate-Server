extends CharacterBody2D
class_name SpaceNPC

# Hasar birleştirme havuzu
var pending_damage: float = 0.0
var damage_merge_timer: float = 0.0
var forced_despawn_timer: float = 0.0
const DAMAGE_MERGE_DELAY: float = 0.12
@onready var shield_bar = $ShieldBar

@export var npc_name: String = "zyron_raider"
@export var max_health: float = 5000.0
@export var speed: float = 105.0
@export var acceleration: float = 180.0
var npc_stats = {
	"zyron_raider": {
		"display_name": "zyron Raider",
		"health": 800.0,
		"shield": 560.0,
		"boss_health": 1600.0,
		"boss_shield": 1120.0,
		"ultra_health": 3200.0,
		"ultra_shield": 2240.0,
		"speed": 90.0,
		"damage": 50.0
	},

	"nexar_fighter": {
		"display_name": "nexar Fighter",
		"health": 3000.0,
		"shield": 2100.0,
		"boss_health": 6000.0,
		"boss_shield": 4200.0,
		"ultra_health": 12000.0,
		"ultra_shield": 8400.0,
		"speed": 100.0,
		"damage": 100.0
	},

	"nexar_destroyer": {
		"display_name": "nexar Destroyer",
		"health": 7000.0,
		"shield": 4900.0,
		"boss_health": 14000.0,
		"boss_shield": 9800.0,
		"ultra_health": 28000.0,
		"ultra_shield": 19600.0,
		"speed": 390.0,
		"damage": 250.0
	},

	"nexar_warlord": {
		"display_name": "nexar Warlord",
		"health": 16000.0,
		"shield": 11200.0,
		"boss_health": 32000.0,
		"boss_shield": 22400.0,
		"ultra_health": 64000.0,
		"ultra_shield": 44800.0,
		"speed": 125.0,
		"damage": 500.0
	},

	"void_reaper": {
		"display_name": "void Reaper",
		"health": 100000.0,
		"shield": 70000.0,
		"boss_health": 200000.0,
		"boss_shield": 140000.0,
		"ultra_health": 400000.0,
		"ultra_shield": 280000.0,
		"speed": 175.0,
		"damage": 1000.0
	},

	"void_predator": {
		"display_name": "void Predator",
		"health": 48000.0,
		"shield": 33600.0,
		"boss_health": 96000.0,
		"boss_shield": 67200.0,
		"ultra_health": 192000.0,
		"ultra_shield": 134400.0,
		"speed": 290.0,
		"damage_min": 900,
		"damage_max": 1100,
		"reward_bitcoin": 15200,
		"reward_platinum": 48,
		"reward_xp": 6542,
		"reward_honor": 24
	},

	"abyss_guardian": {
		"display_name": "abyss Guardian",
		"health": 192000.0,
		"shield": 134400.0,
		"boss_health": 384000.0,
		"boss_shield": 268800.0,
		"ultra_health": 768000.0,
		"ultra_shield": 537600.0,
		"speed": 200.0,
		"damage_min": 1800,
		"damage_max": 2200,
		"reward_bitcoin": 130000,
		"reward_platinum": 125,
		"reward_xp": 23400,
		"reward_honor": 96
	},

	"void_ravager": {
		"display_name": "void Ravager",
		"health": 384000.0,
		"shield": 268800.0,
		"boss_health": 768000.0,
		"boss_shield": 537600.0,
		"ultra_health": 1536000.0,
		"ultra_shield": 1075200.0,
		"speed": 220.0,
		"damage_min": 3000,
		"damage_max": 4000,
		"reward_bitcoin": 315792,
		"reward_platinum": 231,
		"reward_xp": 40248,
		"reward_honor": 211
	},

	"titan_nemesis": {
		"display_name": "titan Nemesis",
		"health": 1900000.0,
		"shield": 1800000.0,
		"speed": 25.0,
		"damage": 18000
	},

	"void_guardian": {
		"display_name": "void Guardian",
		"health": 45000.0,
		"shield": 31500.0,
		"boss_health": 90000.0,
		"boss_shield": 63000.0,
		"ultra_health": 180000.0,
		"ultra_shield": 126000.0,
		"speed": 390.0,
		"damage_min": 2000,
		"damage_max": 2200
	}
}
var damage_min: int = 0
var attack_damage: float = 50.0
var damage_max: int = 0
var is_boss_variant: bool = false
var boss_multiplier: float = 1.0
# 4-5 Uber varyantı: mevcut NPC tipinin x3 stat/ödül instance'ı.
# Normal NPC taban değerleri asla değişmez; sadece bu instance x3 olur.
var is_uber_variant: bool = false
var uber_multiplier: float = 1.0

# Cubikon flag
var is_cubikon: bool = false

@export var turn_speed: float = 4.5
@export var aggro_range: float = 1500.0
@export var attack_range: float = 210.0
@export var separation_radius: float = 115.0
@export var separation_force: float = 0.85
@export var patrol_radius: float = 1450.0

# Alien10 Hydro dengeleri
@export var reward_xp: int = 412
@export var reward_bitcoin: int = 824
@export var reward_platinum: int = 3
@export var reward_honor: int = 2

const DIRECTION_COUNT: int = 72
const FRAME_WIDTH: float = 224.0
const FRAME_HEIGHT: float = 224.0
const FRAME_GAP_X: float = 2.0
const FRAME_GAP_Y: float = 4.0

# Cubikon constants
const CUBIKON_REGEN_PER_SEC: float = 125000.0
const CUBIKON_GUARD_COUNT: int = 25
func get_frame_columns() -> int:

	if npc_name == "zyron_raider":
		return 9

	if npc_name == "nexar_fighter":
		return 12

	if npc_name == "nexar_destroyer":
		return 32

	if npc_name == "nexar_warlord":
		return 12

	if npc_name == "void_reaper":
		return 8

	if npc_name == "void_predator":
		return 8

	if npc_name == "abyss_guardian":
		return 8

	if npc_name == "void_ravager":
		return 8

	if npc_name == "titan_nemesis":
		return 8

	if npc_name == "void_guardian":
		return 8
	return 8
var health: float
var shield: float = 0.0
var max_shield: float = 0.0
var selected: bool = false
var player: PlayerShip = null
var home_position: Vector2
var patrol_target: Vector2
var facing_angle: float = 0.0
var direction_frame: int = 0
var attack_cooldown: float = 0.0
var flash_tween: Tween = null
var world_rect: Rect2 = Rect2(-3000.0, -2000.0, 6000.0, 4000.0)
@export var npc_texture: Texture2D
var safe_zone_centers: Array[Vector2] = []
var safe_zone_radius: float = 340.0
var passive_until_attacked: bool = false
var provoked: bool = false

# İlk saldıran oyuncu kilidi.
# NPC ölünceye kadar bu kilit değişmez.
var first_attacker: PlayerShip = null
var first_attacker_username: String = ""
var reward_owner_username: String = ""

# Basit durum tabanlı NPC yapay zekâsı.
enum AIState { PATROL, CHASE, COMBAT, RETURN_HOME, EVADE }
var ai_state: AIState = AIState.PATROL
var ai_state_timer: float = 0.0
var orbit_direction: float = 1.0
var orbit_change_timer: float = 0.0
var evade_timer: float = 0.0
var leash_radius: float = 4200.0
var last_known_target_position: Vector2 = Vector2.ZERO

# Performance: far idle NPCs run low-frequency AI; combat remains full-rate.
var lod_accumulator: float = 0.0
var separation_timer: float = randf_range(0.05, 0.20)
var separation_cache: Vector2 = Vector2.ZERO
const FAR_AI_DISTANCE: float = 2400.0
const FAR_AI_INTERVAL: float = 0.16

# NOVAGATE EXTRA HOOK: EMA geçici hedef kilidi bozma süresi.
var ema_jammed_until_msec: int = 0

func break_target_lock(seconds: float = 1.5) -> void:
	ema_jammed_until_msec = Time.get_ticks_msec() + int(maxf(seconds, 0.0) * 1000.0)
	attack_cooldown = maxf(attack_cooldown, seconds)
	velocity = Vector2.ZERO

func is_ema_jammed() -> bool:
	return Time.get_ticks_msec() < ema_jammed_until_msec

@onready var sprite: Sprite2D = $Sprite
@onready var health_bar: ProgressBar = $HealthBar
@onready var name_label: Label = $NameLabel


func _get_real_npc_texture(type_name: String) -> Texture2D:
	# EXE/PCK uyumlu: export edilen projede DirAccess ile res:// taramak yerine
	# dosyayi dogrudan res:// yolundan yukle.
	var table: Dictionary = {
		"zyron_raider": "res://assets/npc_real/alien10.png",
		"nexar_fighter": "res://assets/npc_real/alien20.png",
		"nexar_destroyer": "res://assets/npc_real/alien30.png",
		"nexar_warlord": "res://assets/npc_real/alien40.png",
		"void_reaper": "res://assets/npc_real/alien50.png",
		"void_predator": "res://assets/npc_real/alien60.png",
		"abyss_guardian": "res://assets/npc_real/alien70.png",
		"void_ravager": "res://assets/npc_real/alien90.png",
		"titan_nemesis": "res://assets/npc_real/titan_nemesis.png",
		"ship20": "res://assets/npc_real/ship20.png",
		"void_guardian": "res://assets/npc_real/void_guardian.png",
		# Cubikon yeni sprite kullanmaz: mevcut dev boss dokusunu yeniden kullanır.
		"cubikon": "res://assets/npc_real/titan_nemesis.png"
	}

	if not table.has(type_name):
		return null

	var texture_path: String = str(table[type_name])
	if not ResourceLoader.exists(texture_path):
		push_error("NPC texture bulunamadi: " + texture_path)
		return null

	return load(texture_path) as Texture2D

var entity_status_bars: Node2D

func _ready() -> void:
	if npc_texture != null:
		$sprite.texture = npc_texture

	health = max_health
	shield = max_shield

	health_bar.max_value = max_health
	health_bar.value = health
	shield_bar.max_value = max_shield
	shield_bar.value = shield
	entity_status_bars = preload("res://scripts/entity_status_bars.gd").new()
	entity_status_bars.bind_entity(self,
		func() -> Vector4: return Vector4(health, max_health, shield, max_shield),
		func(): return sprite,
		# Bar only while this NPC is the current selected target.
		func() -> bool: return selected and not is_queued_for_deletion(), health_bar, shield_bar)
	name_label.text = npc_name

	name_label.modulate = Color(1,0,0)

	var real_tex = _get_real_npc_texture(npc_name)

	if real_tex != null:
		sprite.texture = real_tex

		if npc_name == "void_guardian":
			sprite.region_enabled = true
			sprite.region_rect = Rect2(0,0,120,120)

	home_position = global_position
	player = get_tree().get_first_node_in_group("player") as PlayerShip
	collision_mask = 0
	orbit_direction = -1.0 if randi() % 2 == 0 else 1.0
	orbit_change_timer = randf_range(1.8, 4.5)
	ai_state_timer = randf_range(0.8, 2.5)
	_pick_patrol_target()
	_update_direction_frame()
	queue_redraw()

func configure(type_name: String, hp: float, move_speed: float) -> void:
	npc_name = type_name
	max_health = hp
	speed = move_speed
	health = hp
	if npc_stats.has(type_name):
		max_health = float(npc_stats[type_name].get("health", hp))
		health = max_health

		max_shield = float(npc_stats[type_name].get("shield", 0.0))
		shield = max_shield

		speed = float(npc_stats[type_name].get("speed", move_speed))

		if npc_stats[type_name].has("damage"):
			attack_damage = npc_stats[type_name]["damage"]
		elif npc_stats[type_name].has("damage_min"):
			damage_min = npc_stats[type_name]["damage_min"]
			damage_max = npc_stats[type_name]["damage_max"]

	# Alien10 / Alien70 / Alien90 saldırılana kadar pasif.
	# Boss varyantları aynı npc_name kullandığı için aynı davranışı otomatik miras alır.
	passive_until_attacked = npc_name in ["zyron_raider", "abyss_guardian", "void_ravager"]

	# Saldırgan NPC'ler artık bütün haritadan oyuncuyu algılamaz.
	# Tür büyüdükçe görüş menzili kontrollü olarak artar.
	match npc_name:
		"nexar_fighter":
			aggro_range = 1100.0
		"nexar_destroyer":
			aggro_range = 1250.0
		"nexar_warlord":
			aggro_range = 1400.0
		"void_reaper":
			aggro_range = 1550.0
		"void_predator":
			aggro_range = 1650.0
		"void_guardian":
			aggro_range = 2000.0
		"titan_nemesis":
			aggro_range = 1500.0
		_:
			aggro_range = 1400.0

	match npc_name:
		"zyron_raider":
			damage_min = 50
			damage_max = 80
			reward_bitcoin = 824
			reward_platinum = 3
			reward_xp = 412
			reward_honor = 2

		"nexar_fighter":
			damage_min = 140
			damage_max = 200
			reward_bitcoin = 1280
			reward_platinum = 8
			reward_xp = 824
			reward_honor = 4

		"nexar_destroyer":
			damage_min = 280
			damage_max = 360
			reward_bitcoin = 2600
			reward_platinum = 14
			reward_xp = 1863
			reward_honor = 6

		"nexar_warlord":
			damage_min = 400
			damage_max = 500
			reward_bitcoin = 8670
			reward_platinum = 24
			reward_xp = 3326
			reward_honor = 8

		"void_reaper":
			damage_min = 1000
			damage_max = 1400
			reward_bitcoin = 72000
			reward_platinum = 96
			reward_xp = 18376
			reward_honor = 34
	shield = max_shield

	if is_node_ready():
		health_bar.max_value = max_health
		health_bar.value = health

		shield_bar.max_value = maxf(max_shield, 1.0)
		shield_bar.value = shield

		if npc_stats.has(type_name):
			name_label.text = npc_stats[type_name].get("display_name", type_name)
		else:
			name_label.text = npc_stats[type_name].get("display_name", type_name)
func apply_boss_variant(enabled: bool) -> void:
	# Boss aynı NPC tipini/görselini kullanır. npc_name değiştirilmez;
	# böylece texture, lazer ve ödül tabloları bozulmaz.
	if is_boss_variant == enabled:
		return

	is_boss_variant = enabled
	boss_multiplier = 2.0 if enabled else 1.0
	set_meta("is_boss", enabled)
	set_meta("base_npc_type", npc_name)

	if enabled:
		max_health *= 2.0
		health = max_health
		max_shield *= 2.0
		shield = max_shield
		damage_min *= 2
		damage_max *= 2
		attack_damage *= 2.0

	if is_node_ready():
		health_bar.max_value = max_health
		health_bar.value = health
		shield_bar.max_value = maxf(max_shield, 1.0)
		shield_bar.value = shield

		var base_display := npc_name
		if npc_stats.has(npc_name):
			base_display = str(npc_stats[npc_name].get("display_name", npc_name))
		name_label.text = ("BOSS " + base_display) if enabled else base_display


func setup_cubikon() -> void:
	# Cubikon: pasif dev NPC. configure() ile npc_stats["cubikon"] değerleri uygulanır.
	is_cubikon = true
	passive_until_attacked = true
	aggro_range = 0.0
	attack_range = 420.0
	# Yeni sprite yok: mevcut doku daha büyük ölçekle kullanılır.
	sprite.scale = Vector2(1.30, 1.30)
	# Cubikon hp regen: max ~125k/s, taban health yuksek, cap max_health'i asilmaz.
	# Cubikon koruma NPC'leri mevcut NPC AI/render pipeline'ini kullanir (yeni sprite yok).
	health = max_health
	shield = max_shield
	if is_instance_valid(health_bar):
		health_bar.max_value = max_health
		health_bar.value = health
	if is_instance_valid(shield_bar):
		shield_bar.max_value = maxf(max_shield, 1.0)
		shield_bar.value = shield
	queue_redraw()


func apply_uber_variant(enabled: bool) -> void:
	# 4-5 Uber haritası: mevcut NPC tipinin x3 stat/ödül instance'ı.
	# AI/hareket/hedefleme/saldırı davranışı aynen korunur; sadece çarpan farklı.
	if is_uber_variant == enabled:
		return

	is_uber_variant = enabled
	uber_multiplier = 3.0 if enabled else 1.0
	set_meta("is_uber", enabled)

	if enabled:
		max_health *= 3.0
		health = max_health
		max_shield *= 3.0
		shield = max_shield
		damage_min *= 3
		damage_max *= 3
		attack_damage *= 3.0
		reward_bitcoin *= 3
		reward_platinum *= 3
		reward_xp *= 3
		reward_honor *= 3

	if is_node_ready():
		health_bar.max_value = max_health
		health_bar.value = health
		shield_bar.max_value = maxf(max_shield, 1.0)
		shield_bar.value = shield

		var base_display := npc_name
		if npc_stats.has(npc_name):
			base_display = str(npc_stats[npc_name].get("display_name", npc_name))
		name_label.text = ("Uber " + base_display) if enabled else base_display


func _physics_process(delta: float) -> void:
	if pending_damage > 0.0:
		damage_merge_timer -= delta
		if damage_merge_timer <= 0.0:
			_show_damage_number(pending_damage)
			pending_damage = 0.0
			damage_merge_timer = 0.0

	# Cubikon HP regen: ~125.000 HP/saniye, max HP'nin üzerine çıkmaz.
	if is_cubikon and health > 0.0 and health < max_health:
		health = minf(health + CUBIKON_REGEN_PER_SEC * delta, max_health)
		health_bar.value = health

	# Kontrollü despawn: Cubikon ölünce koruma NPC'leri dünyada kalmaz.
	if forced_despawn_timer > 0.0:
		forced_despawn_timer -= delta
		if forced_despawn_timer <= 0.0:
			queue_free()
			return

	attack_cooldown = maxf(attack_cooldown - delta, 0.0)
	orbit_change_timer -= delta
	ai_state_timer -= delta
	evade_timer = maxf(evade_timer - delta, 0.0)

	# İlk saldıran oyuncu kaybolduysa yeni oyuncuya geçme.
	# NPC sadece devriye/başlangıç bölgesine dönme davranışına geçer.
	if first_attacker != null and not is_instance_valid(first_attacker):
		first_attacker = null

	var combat_target: PlayerShip = first_attacker

	# Oyuncu referansını güncel tut.
	if not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player") as PlayerShip

	# x-1: oyuncu vurana kadar pasif.
	# x-2 ve sonrası: oyuncu aggro menziline girince normal şekilde hedef alır.
	# Güvenli bölgedeki oyuncu NPC'ye saldırmadığı sürece NPC'nin hedefi olmaz.
	if not is_instance_valid(combat_target) and not passive_until_attacked:
		if is_instance_valid(player):
			var auto_distance := global_position.distance_to(player.global_position)
			# Güvenli bölgede kendiliğinden aggro yok: NPC oyuncu vurana kadar pasif kalır.
			if auto_distance <= aggro_range and not _is_target_in_safe_zone(player):
				combat_target = player
		# Cubikon koruma NPC'leri (saldıran oyuncuyu hedefler) main tarafında spawn edilir.
		if is_cubikon and is_instance_valid(first_attacker):
			combat_target = first_attacker

	# Otomatik aggro ile alınan hedef çok uzaklaşırsa NPC kendi devriyesine döner.
	if is_instance_valid(combat_target) and first_attacker == null and not passive_until_attacked:
		if global_position.distance_to(combat_target.global_position) > aggro_range * 1.65:
			combat_target = null

	var desired_velocity := Vector2.ZERO

	# LOD: far idle NPCs update at ~4.5 Hz instead of every physics frame.
	# This preserves patrol movement without running full AI for every off-screen NPC.
	var far_idle := (
		not is_instance_valid(combat_target)
		and is_instance_valid(player)
		and global_position.distance_to(player.global_position) > FAR_AI_DISTANCE
	)
	var effective_delta := delta
	if far_idle:
		lod_accumulator += delta
		if lod_accumulator < FAR_AI_INTERVAL:
			return
		effective_delta = lod_accumulator
		lod_accumulator = 0.0
	else:
		lod_accumulator = 0.0

	if is_instance_valid(combat_target):
		last_known_target_position = combat_target.global_position
		var distance_to_target := global_position.distance_to(combat_target.global_position)
		# Güvenli bölge koruması yalnızca NPC'nin kendiliğinden saldırısını engeller.
		# Oyuncu bu NPC'ye ilk hasarı verdiyse NPC savaşa devam eder.
		var safe_zone_blocks_target := _safe_zone_blocks_target(combat_target)

		if safe_zone_blocks_target or is_ema_jammed():
			ai_state = AIState.RETURN_HOME
		elif global_position.distance_to(home_position) > leash_radius:
			ai_state = AIState.RETURN_HOME
		elif distance_to_target > aggro_range:
			ai_state = AIState.CHASE
		elif distance_to_target > attack_range + 55.0:
			ai_state = AIState.CHASE
		else:
			ai_state = AIState.COMBAT

		match ai_state:
			AIState.CHASE:
				desired_velocity = global_position.direction_to(combat_target.global_position) * speed

			AIState.COMBAT:
				desired_velocity = _combat_velocity_for_target(combat_target, distance_to_target, effective_delta)

			AIState.RETURN_HOME:
				desired_velocity = _return_home_velocity()

			_:
				desired_velocity = _patrol_velocity()
	else:
		# Hiç kimse bu NPC'ye saldırmadıysa veya ilk saldıran artık yoksa:
		# Alien70/90 dahil tüm NPC'ler sadece devriye gezer.
		if global_position.distance_to(home_position) > patrol_radius * 1.55:
			ai_state = AIState.RETURN_HOME
			desired_velocity = _return_home_velocity()
		else:
			ai_state = AIState.PATROL
			desired_velocity = _patrol_velocity()

	separation_timer -= effective_delta
	if separation_timer <= 0.0:
		separation_timer = randf_range(0.20, 0.34)
		separation_cache = _separation_velocity()
	desired_velocity += separation_cache * speed * separation_force

	if desired_velocity.length() > speed:
		desired_velocity = desired_velocity.normalized() * speed

	velocity = velocity.move_toward(desired_velocity, acceleration * effective_delta)

	var has_combat_lock := is_instance_valid(combat_target) and ai_state in [AIState.CHASE, AIState.COMBAT]
	if has_combat_lock:
		var desired_angle := global_position.direction_to(combat_target.global_position).angle()
		facing_angle = lerp_angle(facing_angle, desired_angle, 1.0 - exp(-turn_speed * effective_delta))
		_update_direction_frame()
	elif velocity.length() > 4.0:
		var desired_angle := velocity.angle()
		facing_angle = lerp_angle(facing_angle, desired_angle, 1.0 - exp(-turn_speed * effective_delta))
		_update_direction_frame()

	if far_idle:
		global_position += velocity * effective_delta
	else:
		move_and_slide()

	global_position = Vector2(
		clampf(global_position.x, world_rect.position.x + 80.0, world_rect.end.x - 80.0),
		clampf(global_position.y, world_rect.position.y + 80.0, world_rect.end.y - 80.0)
	)


func _is_target_in_safe_zone(target: PlayerShip) -> bool:
	if not is_instance_valid(target):
		return true
	# DarkOrbit NAZ: saldırıyı BAŞLATAN oyuncu coğrafi olarak bölgede olsa da korunmaz.
	# Pasif oyuncu (koruması olan) hedef olamaz, aggressor hedef olabilir.
	if target.has_method("has_safe_zone_protection") and not bool(target.call("has_safe_zone_protection")):
		return false
	for center in safe_zone_centers:
		if target.global_position.distance_to(center) < safe_zone_radius:
			return true
	return false


func _is_retaliating_against(target: PlayerShip) -> bool:
	# Güvenli bölge PvE kuralı (DarkOrbit mantığı):
	# NPC yalnızca kendisine hasar veren oyuncuya güvenli bölgede de karşılık verir.
	if not is_instance_valid(target):
		return false
	if is_instance_valid(first_attacker):
		return first_attacker == target
	# İlk saldıran oyuncu yok olduysa: NPC bu oyuncudan hasar gördüyse karşılık verebilir.
	return provoked and is_instance_valid(player) and player == target


func _safe_zone_blocks_target(target: PlayerShip) -> bool:
	# Güvenli bölge koruması NPC için sadece KENDİLİĞİNDEN saldırıyı engeller.
	# Saldırıya uğrayan (provoke edilen) NPC karşı saldırı yapabilir.
	return _is_target_in_safe_zone(target) and not _is_retaliating_against(target)


func _combat_velocity_for_target(target: PlayerShip, distance_to_target: float, delta: float) -> Vector2:
	if not is_instance_valid(target):
		return Vector2.ZERO

	var to_target := global_position.direction_to(target.global_position)

	if distance_to_target > attack_range + 55.0:
		return to_target * speed

	if distance_to_target < attack_range - 70.0:
		# Çok yaklaşınca geri açıl: NPC oyuncunun üstüne yapışmasın.
		return -to_target * speed * 0.78

	# Yapay zekâ: belirli aralıklarla sağ/sol strafe yönünü değiştirir.
	if orbit_change_timer <= 0.0:
		orbit_change_timer = randf_range(2.0, 4.8)
		if randf() < 0.45:
			orbit_direction *= -1.0

	var tangent := to_target.orthogonal() * orbit_direction
	var radial_adjust := Vector2.ZERO

	# İdeal savaş mesafesini koru.
	var ideal_range := attack_range - 8.0
	if distance_to_target > ideal_range + 18.0:
		radial_adjust = to_target * speed * 0.28
	elif distance_to_target < ideal_range - 24.0:
		radial_adjust = -to_target * speed * 0.32

	# Güvenli bölge: saldırıya uğrayan NPC karşılık verebilir; provoke edilmemiş NPC ateş etmez.
	if attack_cooldown <= 0.0 and not _safe_zone_blocks_target(target):
		attack_cooldown = randf_range(0.9, 1.15)
		var final_damage := randi_range(damage_min, damage_max)
		attack_requested.emit(self, target, final_damage)

	return tangent * speed * 0.62 + radial_adjust


func _return_home_velocity() -> Vector2:
	if global_position.distance_to(home_position) < 80.0:
		_pick_patrol_target()
		ai_state = AIState.PATROL
		return Vector2.ZERO
	return global_position.direction_to(home_position) * speed * 0.72

func _patrol_velocity() -> Vector2:
	if global_position.distance_to(patrol_target) < 55.0:
		_pick_patrol_target()
	return global_position.direction_to(patrol_target) * speed * 0.55

func _pick_patrol_target() -> void:
	var angle: float = randf_range(0.0, TAU)
	var distance: float = randf_range(patrol_radius * 0.30, patrol_radius)
	var candidate := home_position + Vector2.RIGHT.rotated(angle) * distance

	# Hedef daima gerçek harita sınırının içinde kalsın.
	# Böylece NPC sınırda takılıp titreşmez veya duvara sürtmez.
	var margin := 180.0
	patrol_target = Vector2(
		clampf(candidate.x, world_rect.position.x + margin, world_rect.end.x - margin),
		clampf(candidate.y, world_rect.position.y + margin, world_rect.end.y - margin)
	)

func _separation_velocity() -> Vector2:
	var result: Vector2 = Vector2.ZERO
	var count: int = 0
	for other: Node in get_tree().get_nodes_in_group("npc"):
		if other == self or not (other is SpaceNPC):
			continue
		var other_npc: SpaceNPC = other as SpaceNPC
		var distance: float = global_position.distance_to(other_npc.global_position)
		if distance > 0.01 and distance < separation_radius:
			result += other_npc.global_position.direction_to(global_position) * (1.0 - distance / separation_radius)
			count += 1
	if count > 0:
		result /= float(count)
	return result

func _direction_index(frame_count: int) -> int:
	var normalized_angle: float = fposmod(facing_angle, TAU)
	var index = int(round(normalized_angle / TAU * float(frame_count)))
	return clamp(index, 0, frame_count - 1)


func _update_direction_frame() -> void:

	if sprite == null or sprite.texture == null:
		return


	if npc_name == "titan_nemesis":
		sprite.region_enabled = false
		return


	var frame = _direction_index(get_frame_columns())

	match npc_name:

		"zyron_raider":
			direction_frame = _direction_index(72)
			var column: int = direction_frame % 9
			var row: int = direction_frame / 9
			sprite.region_enabled = true
			sprite.region_rect = Rect2(
				2.0 + float(column) * 226.0,
				4.0 + float(row) * 226.0,
				224.0,
				224.0
			)


		"nexar_fighter":
			sprite.region_enabled = true
			sprite.region_rect = Rect2(
			(frame % 12) * 170,
			(frame / 12) * 170,
			170,
			170
		)


		"nexar_destroyer":
			direction_frame = _direction_index(32)

			var column: int
			var row: int

			if direction_frame <= 18:
				column = direction_frame
				row = 0
			else:
				column = direction_frame - 19
				row = 1

			sprite.region_enabled = true
			sprite.region_rect = Rect2(
				float(column) * 102.0,
				float(row) * 102.0,
				102.0,
				102.0
			)

		"nexar_warlord":
			direction_frame = _direction_index(30)

			var column: int = direction_frame % 10
			var row: int = int(direction_frame / 10)

			sprite.region_enabled = true
			sprite.region_rect = Rect2(
				float(column) * 202.0,
				float(row) * 162.0,
				202.0,
				162.0
			)


		"void_reaper":
			direction_frame = _direction_index(32)

			var column: int
			var row: int

			if direction_frame < 7:
				row = 0
				column = direction_frame
			elif direction_frame < 14:
				row = 1
				column = direction_frame - 7
			elif direction_frame < 21:
				row = 2
				column = direction_frame - 14
			elif direction_frame < 28:
				row = 3
				column = direction_frame - 21
			else:
				row = 4
				column = direction_frame - 28

			sprite.region_enabled = true
			sprite.region_rect = Rect2(
				float(column) * 274.0,
				float(row) * 274.0,
				274.0,
				274.0
			)


		"void_predator":
			direction_frame = _direction_index(32)

			var column: int = direction_frame % 8
			var row: int = int(direction_frame / 8)

			sprite.region_enabled = true
			sprite.region_rect = Rect2(
				float(column) * 128.0,
				float(row) * 128.0,
				128.0,
				128.0
			)


		"void_ravager":
			direction_frame = _direction_index(64)

			var column: int = direction_frame % 8
			var row: int = int(direction_frame / 8)

			sprite.region_enabled = true
			sprite.region_rect = Rect2(
				float(column) * 156.75,
				float(row) * 156.75,
				156.75,
				156.75
			)


		"abyss_guardian":
			direction_frame = _direction_index(40)

			var column: int = direction_frame % 8
			var row: int = int(direction_frame / 8)

			sprite.region_enabled = true
			sprite.region_rect = Rect2(
				float(column) * 192.0,
				float(row) * 204.8,
				192.0,
				204.8
			)


		"void_guardian":
			direction_frame = _direction_index(72)
			sprite.region_enabled = true
			sprite.region_rect = Rect2(0.0, 0.0, 120.0, 120.0)

		_:
			sprite.region_enabled = false


func set_selected(value: bool) -> void:
	selected = value
	# Selection ring is independent of the always-visible entity status bars.
	if is_instance_valid(entity_status_bars):
		entity_status_bars.refresh()
	queue_redraw()

func _draw() -> void:
	if selected:
		draw_arc(Vector2.ZERO, 58.0, 0.0, TAU, 48, Color(0.15, 0.9, 1.0, 0.95), 3.0)
		draw_line(Vector2(-70.0, 0.0), Vector2(-53.0, 0.0), Color(0.15, 0.9, 1.0), 3.0)
		draw_line(Vector2(53.0, 0.0), Vector2(70.0, 0.0), Color(0.15, 0.9, 1.0), 3.0)

func mark_attacked(attacker: PlayerShip = null) -> bool:
	# Cubikon: ilk saldırıda koruma NPC'leri devreye girer (main spawn eder).
	# Hook ilk saldıran dalından bağımsızdır; main._on_fire_requested
	# first_attacker'ı kendisi set ettiği için burada da tetiklenmelidir.
	if is_cubikon and not has_meta("guards_spawned") and is_instance_valid(attacker):
		set_meta("guards_spawned", true)
		cubikon_guards_requested.emit(self, attacker, CUBIKON_GUARD_COUNT)
	# İlk saldırı NPC'nin sahibini belirler.
	# Sonraki oyuncular bu kilidi değiştiremez.
	if first_attacker == null and is_instance_valid(attacker):
		first_attacker = attacker
		player = attacker
		provoked = true
		first_attacker_username = str(GlobalState.username)
		reward_owner_username = first_attacker_username
		last_known_target_position = attacker.global_position
		ai_state = AIState.CHASE
		return true

	if is_instance_valid(first_attacker):
		provoked = true
		return first_attacker == attacker

	# İlk saldıran oyuncu artık yok olsa bile ödül sahibi değişmez.
	provoked = true
	return false


func take_sab_damage(amount: float, attacker: PlayerShip = null) -> float:
	if is_instance_valid(attacker):
		mark_attacked(attacker)
	provoked = true

	if amount <= 0.0 or shield <= 0.0:
		_damage_flash()
		return 0.0

	var drained: float = minf(shield, amount)
	shield = maxf(0.0, shield - drained)

	if shield_bar != null:
		shield_bar.value = shield

	pending_damage += drained
	damage_merge_timer = DAMAGE_MERGE_DELAY
	_damage_flash()
	return drained


func take_laser_damage(amount: float, ammo_type: int, attacker: PlayerShip = null) -> void:
	mark_attacked(attacker)
	provoked = true
	if is_instance_valid(attacker) and str(GlobalState.username) == str(reward_owner_username):
		QuestSystem.record_event("damage_dealt", {"amount": int(maxf(amount, 0.0))})

	var remaining: float = maxf(amount, 0.0)

	if shield > 0.0:
		var absorbed: float = minf(shield, remaining)
		shield -= absorbed
		remaining -= absorbed
		shield_bar.value = shield

	if remaining > 0.0:
		take_damage(remaining)
	else:
		_damage_flash()

func take_damage(amount: float, attacker: PlayerShip = null) -> void:
	if is_instance_valid(attacker):
		mark_attacked(attacker)
	provoked = true
	print("TAKE_DAMAGE ÇAĞRILDI | HASAR:", amount, " | CAN:", health, " | KALKAN:", shield)

	if amount > 0:
		health -= amount
		print("CAN KALDI:", health)
		health_bar.value = health
		print("CAN:", health)

	# Lazer + roket aynı anda gelirse tek toplam hasar yazısı
	pending_damage += amount
	damage_merge_timer = DAMAGE_MERGE_DELAY
	_damage_flash()

	if health <= 0:
		if is_instance_valid(entity_status_bars):
			entity_status_bars.hide()
		# Current target died: clear the lock so no bar remains until a new selection.
		if is_instance_valid(player) and "locked_target" in player and player.locked_target == self:
			player.locked_target = null
			if "entity_status_bars" in player and is_instance_valid(player.entity_status_bars):
				player.entity_status_bars.refresh()
		destroyed.emit(global_position)

		var world_id := str(get_meta("world_npc_id", ""))
		var world_map := str(get_meta("world_map", ""))
		var respawn_at := Time.get_unix_time_from_system() + randf_range(4.0, 8.0)

		if not world_id.is_empty():
			GlobalState.sync_npc_death({
				"npc_id": world_id,
				"map": world_map,
				"npc_type": npc_name,
				"x": global_position.x,
				"y": global_position.y,
				"max_health": max_health,
				"max_shield": max_shield,
				"move_speed": speed,
				"passive": passive_until_attacked,
				"respawn_at": respawn_at,
				"first_attacker_username": reward_owner_username
			})

		if _local_player_owns_reward():
			_give_reward()
			_show_reward_popup()

		# Respawn artık server world tick tarafından yapılır.
		queue_free()

func _show_damage_number(amount: float) -> void:
	var label := Label.new()
	label.name = "DamageNumber"
	label.text = "-" + _format_damage(amount)

	label.position = Vector2(-35, -130)
	label.z_index = 4000
	label.top_level = true
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 34)
	label.add_theme_color_override("font_color", Color(1.0, 0.05, 0.05, 1.0))
	get_tree().current_scene.add_child(label)
	label.global_position = global_position + Vector2(-35, -130)
	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", label.global_position + Vector2(0, -70), 1.0)
	tween.tween_property(label, "modulate:a", 0.0, 1.0)
	tween.set_parallel(false)
	tween.tween_callback(label.queue_free)


func _local_player_owns_reward() -> bool:
	# İlk vuruşu yapan oyuncu dışında hiç kimse ödül alamaz.
	if reward_owner_username == "":
		return false
	return reward_owner_username == str(GlobalState.username)


func _give_reward() -> void:
	if has_meta("reward_given"):
		return

	set_meta("reward_given", true)
	print("NPC ADI:", npc_name)
	var manager = get_node_or_null("/root/AccountManager")

	var rewards = {
		"zyron_raider": [412,824,3,2],
		"nexar_fighter": [824,1280,8,4],
		"nexar_destroyer": [1863,2600,14,6],
		"nexar_warlord": [3526,8670,24,8],
		"void_reaper": [18376,72000,96,34],
		"void_predator": [6542,15200,48,24],
		"abyss_guardian": [23400,130000,125,96],
		"void_ravager": [40248,315792,231,211],
		"cubikon": [250000,1000000,800,2500]
	}
	if rewards.has(npc_name):
		var r = rewards[npc_name]
		var reward_mult: int = 3 if is_uber_variant else (2 if is_boss_variant else 1)

		GlobalState.add_npc_reward(
			int(r[0]) * reward_mult,
			int(r[1]) * reward_mult,
			int(r[2]) * reward_mult,
			int(r[3]) * reward_mult
		)
		QuestSystem.record_event("npc_kill", {"npc_type": npc_name, "boss": is_boss_variant, "amount": 1})
		if is_boss_variant:
			QuestSystem.record_event("boss_kill", {"npc_type": npc_name, "boss": true, "amount": 1})
		QuestSystem.record_event("currency_earned", {"currency": "BTC", "amount": int(r[1]) * reward_mult})
		QuestSystem.record_event("currency_earned", {"currency": "PLT", "amount": int(r[2]) * reward_mult})

		GlobalState.save_game()

		var menu = get_tree().get_first_node_in_group("menu_ui")
		if menu and menu.has_method("_refresh_all"):
			menu._refresh_all()

		print("KAYIT YAPILDI XP:", GlobalState.xp, " BTC:", GlobalState.bitcoin, " PLT:", GlobalState.platinum)

func _show_reward_popup() -> void:
	pass


func _format_damage(amount: float) -> String:
	var value := str(int(round(amount)))
	var result := ""
	while value.length() > 3:
		result = "." + value.substr(value.length()-3, 3) + result
		value = value.substr(0, value.length()-3)
	return value + result

func _damage_flash() -> void:
	if flash_tween != null and flash_tween.is_valid():
		flash_tween.kill()
	sprite.modulate = Color(1.0, 0.35, 0.35, 1.0)
	flash_tween = create_tween()
	flash_tween.tween_property(sprite, "modulate", Color.WHITE, 0.13)

signal cubikon_guards_requested(cubikon: SpaceNPC, attacker: PlayerShip, count: int)
signal destroyed(at_position: Vector2)
signal respawn_requested(type_name: String, hp: float, move_speed: float, passive: bool)
signal attack_requested(source: SpaceNPC, target: PlayerShip, damage: float)
