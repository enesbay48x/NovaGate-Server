extends Node

var auto_fire: bool = false
var fire_interval: float = 1.0
var timer: float = 0.0
var target = null

var current_laser := 0 # x1
var previous_laser := 0
var rsb_cooldown := false

const AMMO_KEYS := ["RLX-1", "RLX-2", "BLX-3", "WLX-4", "SAB", "RSB"]

const LASERS = {
	0: {"name":"x1", "damage":1.0, "effect":"laser1"},
	1: {"name":"x2", "damage":2.0, "effect":"laser2"},
	2: {"name":"x3", "damage":3.0, "effect":"laser3"},
	3: {"name":"x4", "damage":4.0, "effect":"laser4"},
	4: {"name":"SAB", "damage":3.0, "effect":"sab"},
	5: {"name":"RSB", "damage":6.0, "effect":"laser6"}
}
func select_laser(id: int):
	if id < 0 or id > 5:
		return

	if id == 5 and rsb_cooldown:
		print("RSB HAZIR DEĞİL - ÖNCEKİ LAZER DEVAM EDİYOR")
		return

	if id == 5 and current_laser != 5:
		previous_laser = current_laser

	current_laser = id
	AmmoSystem.select_ammo(AMMO_KEYS[current_laser])

	print("SEÇİLEN LAZER:", current_laser + 1, " STOK:", AmmoSystem.get_current_amount())
func toggle_auto_fire():
	auto_fire = not auto_fire
	if auto_fire:
		timer = 0.0
		fire_selected_weapon()
		print("OTOMATİK ATEŞ BAŞLADI")
	else:
		print("OTOMATİK ATEŞ DURDU")

func set_target(new_target):
	target = new_target

func get_player_target():
	var player = get_tree().get_first_node_in_group("player")
	if player and player.has_method("get_locked_target"):
		return player.get_locked_target()
	if player and "locked_target" in player:
		return player.locked_target
	return target

func _process(delta):
	if not auto_fire:
		return
	timer -= delta
	if timer <= 0:
		timer = fire_interval
		fire_selected_weapon()

func fire_selected_weapon():
	if current_laser == 5 and rsb_cooldown:
		return

	var current_target = get_player_target()
	if current_target == null or not is_instance_valid(current_target):
		return

	var player = get_tree().get_first_node_in_group("player")

	# Cephane yoksa atış gönderilmez.
	if not AmmoSystem.use_ammo():
		return
	# DarkOrbit NAZ: Saldiriyi BASLATAN oyuncu korumasini aninda kaybeder.
	# Sadece GERCEK atis (stok dusen) sonrasi isaretlenir; menzil/hedef
	# yoksa koruma kalkmaz.
	if player and player.has_signal("fire_requested"):
		# PlayerShip/main.gd cephane numarasını 1-6 aralığında kullanır.
		# NAZ: saldırganlık SADECE gerçek atış gerçekleştiğinde _on_fire_requested içinde işaretlenir.
		player.fire_requested.emit(current_target.global_position, current_laser + 1)
		print("ATEŞ EDİLEN LAZER:", current_laser + 1)

	if current_laser == 5:
		var old_laser: int = clampi(previous_laser, 0, 4)
		rsb_cooldown = true

		current_laser = old_laser
		AmmoSystem.select_ammo(AMMO_KEYS[old_laser])

		var player_node = get_tree().get_first_node_in_group("player")
		if player_node != null and "active_slot" in player_node:
			player_node.active_slot = old_laser + 1
		if player_node != null and player_node.has_signal("ammo_changed"):
			player_node.ammo_changed.emit(old_laser + 1)

		await get_tree().create_timer(3.0).timeout
		rsb_cooldown = false
