extends Area2D

signal collected

var player: Node2D = null
var is_secret_box: bool = false
var taken: bool = false
var selected_for_collection: bool = false
var collect_progress: float = 0.0
var anim_time: float = 0.0
var frame_index: int = 0
var sprite: Sprite2D = null
var collect_label: Label = null
var collection_nav_target: Vector2 = Vector2.ZERO

const FRAME_COUNT: int = 20
const FRAME_W: float = 97.0
const FRAME_H: float = 97.0
const FRAME_STEP: float = 99.0
const FRAME_Y: float = 4.0

# DarkOrbit tarzı tek tık toplama.
# PlayerShip hedefe yaklaşırken erken frenlediği için hedefi kutunun biraz ötesine koyuyoruz;
# gemi kutunun merkezinden geçerken toplama gerçekleşiyor.
const COLLECT_DISTANCE: float = 30.0
const COLLECT_TIME: float = 0.10
const NAV_OVERSHOOT: float = 150.0
const NAV_TARGET_TOLERANCE: float = 4.0


func setup_bonus_box(player_node: Node2D, texture: Texture2D, secret_box: bool) -> void:
	player = player_node
	is_secret_box = secret_box
	add_to_group("bonus_box")

	# Tıklanabilir alan. Geminin fizik hareketini engellemez.
	collision_layer = 8
	collision_mask = 0
	input_pickable = true

	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 43.0
	shape.shape = circle
	add_child(shape)

	sprite = Sprite2D.new()
	sprite.texture = texture
	sprite.region_enabled = texture != null
	if texture != null:
		sprite.region_rect = Rect2(2.0, FRAME_Y, FRAME_W, FRAME_H)
	sprite.scale = Vector2(0.72, 0.72)
	add_child(sprite)

	collect_label = Label.new()
	collect_label.text = ""
	collect_label.position = Vector2(-42.0, -62.0)
	collect_label.size = Vector2(84.0, 24.0)
	collect_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	collect_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	collect_label.add_theme_font_size_override("font_size", 16)
	collect_label.add_theme_color_override("font_color", Color(0.35, 1.0, 0.55, 1.0))
	collect_label.visible = false
	add_child(collect_label)

	z_index = -1
	input_event.connect(_on_input_event)


func _on_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if taken: return
	if event is InputEventMouseButton:
		var e:=event as InputEventMouseButton
		if e.button_index==MOUSE_BUTTON_LEFT and e.pressed:
			_start_collection()
			get_viewport().set_input_as_handled()


func mobile_collect() -> void:
	if not taken:
		_start_collection()


func _start_collection() -> void:
	if player==null or not is_instance_valid(player): return
	selected_for_collection=true
	collect_progress=0.0
	if player.has_method("set_navigation_target"):
		var to_box:=global_position-player.global_position
		var dir:=to_box.normalized() if to_box.length()>0.001 else Vector2.RIGHT
		collection_nav_target=global_position+dir*NAV_OVERSHOOT
		player.call("set_navigation_target",collection_nav_target)

func _process(delta: float) -> void:
	if taken:
		return

	_update_animation(delta)

	if not selected_for_collection:
		return
	if player == null or not is_instance_valid(player):
		_cancel_collection()
		return

	# Oyuncu kutuya giderken başka yere tıklarsa PlayerShip.target_position değişir.
	# Bu durumda kutu gemiyi tekrar kendine çekmez; toplama iptal olur.
	if "target_position" in player:
		var current_target: Vector2 = player.get("target_position")
		if current_target.distance_to(collection_nav_target) > NAV_TARGET_TOLERANCE:
			_cancel_collection()
			return

	var distance := global_position.distance_to(player.global_position)

	if distance <= COLLECT_DISTANCE:
		# Gemi kutunun merkezinden geçerken tek seferde toplama başlar.
		if player.has_method("stop_navigation"):
			player.call("stop_navigation")

		collect_progress += delta
		if collect_label != null:
			collect_label.visible = false

		if collect_progress >= COLLECT_TIME:
			_collect()
	else:
		collect_progress = 0.0
		if collect_label != null:
			collect_label.visible = false


func _cancel_collection() -> void:
	selected_for_collection = false
	collect_progress = 0.0
	collection_nav_target = Vector2.ZERO
	if collect_label != null:
		collect_label.visible = false


func _update_animation(delta: float) -> void:
	anim_time += delta
	if anim_time < 0.065:
		return
	anim_time = 0.0

	frame_index = (frame_index + 1) % FRAME_COUNT
	if sprite != null and sprite.texture != null:
		sprite.region_rect = Rect2(
			2.0 + float(frame_index) * FRAME_STEP,
			FRAME_Y,
			FRAME_W,
			FRAME_H
		)


func _collect() -> void:
	if taken:
		return
	taken = true

	var reward_text := ""
	if is_secret_box:
		GlobalState.add_ammo("X4", 1000)
		reward_text = "+1.000 X4"
	else:
		reward_text = _give_normal_reward()

	_show_reward(reward_text)
	QuestSystem.record_event("bonus_box", {"box_type": "secret" if is_secret_box else "normal", "amount": 1})
	collected.emit()
	queue_free()


func _give_normal_reward() -> String:
	# NovaGate normal harita kutuları: eski DarkOrbit tipi ödül havuzu.
	var roll := randi_range(0, 99)

	if roll < 22:
		var amount: int = [10, 20, 50].pick_random()
		GlobalState.add_ammo("X1", amount)
		return "+%d X1" % amount
	elif roll < 39:
		var amount: int = [5, 10, 20].pick_random()
		GlobalState.add_ammo("X2", amount)
		return "+%d X2" % amount
	elif roll < 54:
		var amount: int = [5, 10, 20].pick_random()
		GlobalState.add_ammo("X3", amount)
		return "+%d X3" % amount
	elif roll < 76:
		var amount: int = [200, 500, 1000].pick_random()
		GlobalState.bitcoin += amount
		GlobalState.sync_economy_delta(amount, 0, 0, 0)
		GlobalState.save_game()
		QuestSystem.record_event("currency_earned", {"currency": "BTC", "amount": amount})
		return "+%d BTC" % amount
	elif roll < 91:
		var amount: int = [20, 50, 100].pick_random()
		GlobalState.platinum += amount
		GlobalState.uridium = GlobalState.platinum
		GlobalState.sync_economy_delta(0, amount, 0, 0)
		GlobalState.save_game()
		QuestSystem.record_event("currency_earned", {"currency": "PLT", "amount": amount})
		return "+%d PLT" % amount
	else:
		var amount: int = [2, 5, 10].pick_random()
		GlobalState.add_ammo("R1", amount)
		return "+%d R1 Roket" % amount


func _show_reward(text: String) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return

	var label := Label.new()
	label.name = "BonusReward"
	label.text = text
	label.z_index = 4000
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color(0.25, 1.0, 0.45, 1.0))
	scene.add_child(label)

	# Ödül yazısı kutunun değil oyuncunun üzerinde çıkar.
	if player != null and is_instance_valid(player):
		label.global_position = player.global_position + Vector2(-60.0, -105.0)
	else:
		label.global_position = global_position + Vector2(-60.0, -80.0)

	var tween := get_tree().create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", label.global_position + Vector2(0.0, -75.0), 1.35)
	tween.tween_property(label, "modulate:a", 0.0, 1.35)
	tween.set_parallel(false)
	tween.tween_callback(label.queue_free)
