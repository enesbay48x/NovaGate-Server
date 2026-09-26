extends Control
class_name NovaGateExtraSystem

# NovaGate ExtraSystem - cooldown + menzil sürümü
# Mevcut lazer/slot sisteminden bağımsız çalışır.

# --- ETKİ AYARLARI ---
@export var nukleer_radius: float = 500.0
@export var ema_npc_lock_break_seconds: float = 1.5

@export var nukleer_cooldown_seconds: float = 30.0
@export var kalkan_cooldown_seconds: float = 25.0
@export var ema_cooldown_seconds: float = 40.0
@export var enc_cooldown_seconds: float = 300.0
@export var enc_duration_seconds: float = 120.0
@export var onluk_cooldown_seconds: float = 120.0

@onready var ema_button: TextureButton = get_tree().current_scene.find_child("EMAButton", true, false)
@onready var nukleer_button: TextureButton = get_tree().current_scene.find_child("NukleerButton", true, false)
@onready var onluk_button: TextureButton = get_tree().current_scene.find_child("OnlukButton", true, false)
@onready var enc_button: TextureButton = get_tree().current_scene.find_child("ENCButton", true, false)
@onready var kalkan_button: TextureButton = get_tree().current_scene.find_child("Kalkan3SnButton", true, false)

var player_ship: PlayerShip = null
var effects: Node2D = null

var onluk_active: bool = false
var enc_active: bool = false
var enc_end_time_msec: int = 0
var kalkan_active: bool = false
var kalkan_end_time_msec: int = 0
var onluk_end_time_msec: int = 0

var cooldown_end_msec: Dictionary = {
	"ema": 0,
	"nukleer": 0,
	"onluk": 0,
	"enc": 0,
	"kalkan": 0
}

var cooldown_labels: Dictionary = {}

func _ready() -> void:
	add_to_group("extra_system")

	player_ship = get_tree().get_first_node_in_group("player") as PlayerShip

	if is_instance_valid(player_ship):
		effects = player_ship.get_node_or_null("ExtraEffects") as Node2D


	if ema_button:
		ema_button.pressed.connect(_on_ema_pressed)

	if nukleer_button:
		nukleer_button.pressed.connect(_on_nukleer_pressed)

	if onluk_button:
		onluk_button.pressed.connect(_on_onluk_pressed)

	if enc_button:
		enc_button.pressed.connect(_on_enc_pressed)

	if kalkan_button:
		kalkan_button.pressed.connect(_on_kalkan_pressed)


	_create_cooldown_label("ema", ema_button)
	_create_cooldown_label("nukleer", nukleer_button)
	_create_cooldown_label("onluk", onluk_button)
	_create_cooldown_label("enc", enc_button)
	_create_cooldown_label("kalkan", kalkan_button)

	_update_cooldown_ui()
	_restore_server_effects()

func _restore_server_effects() -> void:
	# Offline build: efekt/cooldown durumu bu node tarafından yerelde yönetilir.
	GlobalState.prune_expired_extras(false)
	_update_cooldown_ui()

func _record_server_effect(key:String, cooldown:float, active:float=0.0) -> void:
	# Offline build: sunucuya gönderilmez. Süreler yerel olarak takip edilir.
	return

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()

	if enc_active and now >= enc_end_time_msec:
		enc_active = false

	if kalkan_active and now >= kalkan_end_time_msec:
		kalkan_active = false

	_update_cooldown_ui()

func _create_cooldown_label(key: String, button: TextureButton) -> void:
	var label := Label.new()
	label.name = "CooldownLabel"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.visible = false
	button.add_child(label)
	cooldown_labels[key] = label

func _remaining_seconds(key: String) -> int:
	var end_time: int = int(cooldown_end_msec.get(key, 0))
	if end_time <= 0:
		return 0
	var remaining_ms := end_time - Time.get_ticks_msec()
	if remaining_ms <= 0:
		return 0
	return int(ceil(float(remaining_ms) / 1000.0))

func _is_on_cooldown(key: String) -> bool:
	return _remaining_seconds(key) > 0

func _start_cooldown(key: String, seconds: float) -> void:
	cooldown_end_msec[key] = Time.get_ticks_msec() + int(seconds * 1000.0)
	_update_cooldown_ui()

func _set_button_cooldown_state(key: String, button: TextureButton) -> void:
	var remaining := _remaining_seconds(key)
	button.disabled = remaining > 0

	var label: Label = cooldown_labels.get(key) as Label
	if label == null:
		return

	if remaining <= 0:
		label.visible = false
		label.text = ""
		return

	label.visible = true

	var now := Time.get_ticks_msec()
	if key == "enc" and enc_active and now < enc_end_time_msec:
		var active_left := int(ceil(float(enc_end_time_msec - now) / 1000.0))
		label.text = "AKTİF
%d" % active_left
	elif key == "kalkan" and kalkan_active and now < kalkan_end_time_msec:
		var active_left := int(ceil(float(kalkan_end_time_msec - now) / 1000.0))
		label.text = "AKTİF
%d" % active_left
	elif key == "onluk" and onluk_active and now < onluk_end_time_msec:
		var active_left := int(ceil(float(onluk_end_time_msec - now) / 1000.0))
		label.text = "AKTİF
%d" % active_left
	else:
		label.text = "%d" % remaining

func _update_cooldown_ui() -> void:
	_set_button_cooldown_state("ema", ema_button)
	_set_button_cooldown_state("nukleer", nukleer_button)
	_set_button_cooldown_state("onluk", onluk_button)
	_set_button_cooldown_state("enc", enc_button)
	_set_button_cooldown_state("kalkan", kalkan_button)

func _effect(name: String) -> AnimatedSprite2D:
	if effects == null or not is_instance_valid(effects):
		if is_instance_valid(player_ship):
			effects = player_ship.get_node_or_null("ExtraEffects") as Node2D
	if effects == null:
		return null
	return effects.get_node_or_null(name) as AnimatedSprite2D

func _play_once(effect: AnimatedSprite2D) -> void:
	if effect == null:
		return
	effect.visible = true
	effect.stop()
	effect.frame = 0
	effect.sprite_frames.set_animation_loop(&"default", true)
	effect.play(&"default")
	await effect.animation_finished
	if is_instance_valid(effect):
		effect.visible = false

func _play_for(effect: AnimatedSprite2D, seconds: float) -> void:
	if effect == null:
		return
	effect.visible = true
	effect.stop()
	effect.frame = 0
	effect.sprite_frames.set_animation_loop(&"default", true)
	effect.play(&"default")

	await get_tree().create_timer(seconds).timeout
	if is_instance_valid(effect):
		effect.stop()
		effect.frame = 0
		effect.visible = false

func _heal_player(amount: float) -> float:
	if not is_instance_valid(player_ship):
		return 0.0
	if player_ship.health <= 0.0:
		return 0.0

	var before := player_ship.health
	player_ship.health = minf(player_ship.max_health, player_ship.health + maxf(amount, 0.0))
	var healed := player_ship.health - before

	if healed > 0.0:
		if player_ship.has_method("_update_ship_status_labels"):
			player_ship.call("_update_ship_status_labels")
		player_ship.stats_changed.emit(player_ship.health, player_ship.shield)

	return healed

const EXTRA_USE_COST: int = 350
const ENC_USE_COST: int = 500


func _pay_extra_use(cost: int) -> bool:
	if int(GlobalState.platinum) < cost:
		print("EKSTRA KULLANILAMADI - YETERSİZ PLT. GEREKEN: ", cost, " MEVCUT: ", GlobalState.platinum)
		return false

	# Sunucu harcamayı kabul etmeden ekstra aktif olmaz.
	var paid: bool = await GlobalState.spend_plt(cost)
	if not paid:
		print("EKSTRA KULLANILAMADI - PLT SUNUCUDA DÜŞÜRÜLEMEDİ")
		return false

	print("EKSTRA KULLANIM ÜCRETİ ÖDENDİ: ", cost, " PLT | KALAN: ", GlobalState.platinum)
	return true


# 1) EMA
# Kullanım: 40 saniyede bir.
# Savunma aracıdır; güvenli bölge korumasını kaldırmaz.
func _on_ema_pressed() -> void:
	if _is_on_cooldown("ema"):
		return
	if not await _pay_extra_use(EXTRA_USE_COST):
		return
	_start_cooldown("ema", ema_cooldown_seconds)
	_record_server_effect("ema", ema_cooldown_seconds)

	_play_for(_effect("EMAEffect"), 3.0)


	if not is_instance_valid(player_ship):
		return

	var scene := get_tree().current_scene
	if scene != null:
		var npc_root := scene.get_node_or_null("World/NPCs")
		if npc_root != null:
			for npc in npc_root.get_children():
				if npc.has_method("break_target_lock"):
					npc.call("break_target_lock", ema_npc_lock_break_seconds)

	for other in get_tree().get_nodes_in_group("player"):
		if other == player_ship:
			continue
		if "locked_target" in other and other.locked_target == player_ship:
			if other.has_method("set_locked_target"):
				other.call("set_locked_target", null)
			else:
				other.locked_target = null
# 2) NÜKLEER
# Kullanım: 30 saniyede bir.
# Menzil: 500 oyun birimi.
# Menzildeki düşmanın maksimum canının %30'u kadar hasar.
func _on_nukleer_pressed() -> void:
	if _is_on_cooldown("nukleer"):
		return
	if not await _pay_extra_use(EXTRA_USE_COST):
		return
	# Nükleer saldırı başlatıldığı anda NAZ koruması kalkar.
	if is_instance_valid(player_ship) and player_ship.has_method("mark_as_aggressor"):
		player_ship.call("mark_as_aggressor")
	_start_cooldown("nukleer", nukleer_cooldown_seconds)
	_record_server_effect("nukleer", nukleer_cooldown_seconds)

	_play_for(_effect("NukleerEffect"), 3.0)

	if not is_instance_valid(player_ship):
		return

	var scene := get_tree().current_scene
	if scene == null:
		return

	var npc_root := scene.get_node_or_null("World/NPCs")
	if npc_root == null:
		return

	for npc in npc_root.get_children():
		if not is_instance_valid(npc) or not (npc is Node2D):
			continue
		if player_ship.global_position.distance_to(npc.global_position) > nukleer_radius:
			continue
		if "max_health" in npc and npc.has_method("take_damage"):
			var blast_damage := maxf(float(npc.max_health) * 0.30, 0.0)
			npc.call("take_damage", blast_damage)

# 3) 10'LUK
# Kullanım: 120 saniyede bir.
# 10 saniye boyunca saniyede +10.000 HP.
func _on_onluk_pressed() -> void:
	if _is_on_cooldown("onluk") or onluk_active:
		return
	if not is_instance_valid(player_ship):
		return
	if not await _pay_extra_use(EXTRA_USE_COST):
		return

	_start_cooldown("onluk", onluk_cooldown_seconds)
	_record_server_effect("onluk", onluk_cooldown_seconds, 10.0)
	onluk_active = true
	onluk_end_time_msec = Time.get_ticks_msec() + 10000

	_play_for(_effect("OnlukEffect"), 10.0)

	for _i in range(10):
		await get_tree().create_timer(1.0).timeout
		if not is_instance_valid(player_ship):
			break
		_heal_player(10000.0)

	onluk_active = false

# 4) ENC
# Kullanım: 300 saniyede bir.
# Her kullanımda 120 saniye aktif.
# Aktifken verilen gerçek hasarın %10'unu HP'ye dönüştürür.
func _on_enc_pressed() -> void:
	if _is_on_cooldown("enc"):
		return
	if not await _pay_extra_use(ENC_USE_COST):
		return

	_start_cooldown("enc", enc_cooldown_seconds)
	_record_server_effect("enc", enc_cooldown_seconds, enc_duration_seconds)
	enc_active = true
	enc_end_time_msec = Time.get_ticks_msec() + int(enc_duration_seconds * 1000.0)

	_play_for(_effect("ENCEffect"), enc_duration_seconds)

func on_player_dealt_damage(real_damage: float) -> void:
	if not enc_active:
		return

	if Time.get_ticks_msec() >= enc_end_time_msec:
		enc_active = false
		return

	if real_damage <= 0.0:
		return

	_heal_player(real_damage * 0.10)

# 5) 3 SANİYELİK KALKAN
# Kullanım: 25 saniyede bir.
# 3 saniye boyunca gelen tüm hasarı engeller.
func _on_kalkan_pressed() -> void:
	if _is_on_cooldown("kalkan") or kalkan_active:
		return
	if not await _pay_extra_use(EXTRA_USE_COST):
		return

	_start_cooldown("kalkan", kalkan_cooldown_seconds)
	_record_server_effect("kalkan", kalkan_cooldown_seconds, 3.0)
	kalkan_active = true
	kalkan_end_time_msec = Time.get_ticks_msec() + 3000

	_play_for(_effect("Kalkan3SnEffect"), 3.0)

	await get_tree().create_timer(3.0).timeout
	kalkan_active = false

func is_damage_blocked() -> bool:
	return kalkan_active

func on_damage_blocked(_amount: float) -> void:
	pass


# Mobil HUD köprüsü. Masaüstü butonlarıyla aynı fonksiyonları çağırır.
func mobile_activate(extra_key: String) -> void:
	match extra_key:
		"ema": _on_ema_pressed()
		"nukleer": _on_nukleer_pressed()
		"onluk": _on_onluk_pressed()
		"enc": _on_enc_pressed()
		"kalkan": _on_kalkan_pressed()


func mobile_get_status(extra_key: String) -> Dictionary:
	var key := extra_key.strip_edges().to_lower()
	var now := Time.get_ticks_msec()
	var active_left := 0
	match key:
		"enc":
			if enc_active and now < enc_end_time_msec:
				active_left = int(ceil(float(enc_end_time_msec-now)/1000.0))
		"kalkan":
			if kalkan_active and now < kalkan_end_time_msec:
				active_left = int(ceil(float(kalkan_end_time_msec-now)/1000.0))
		"onluk":
			if onluk_active and now < onluk_end_time_msec:
				active_left = int(ceil(float(onluk_end_time_msec-now)/1000.0))
	return {"cooldown":_remaining_seconds(key),"active":maxi(active_left,0)}
