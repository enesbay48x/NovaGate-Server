@tool
class_name NovaGateJoystick
extends Control

signal activated
signal released

enum JoystickMode { STATIC, DYNAMIC }

@onready var base: TextureRect = get_node_or_null("Base")
@onready var knob: TextureRect = get_node_or_null("Base/Knob")

@export var joystick_mode: JoystickMode = JoystickMode.STATIC
@export var base_texture: Texture2D
@export var knob_texture: Texture2D
@export var visual_size: Vector2 = Vector2(168.0, 168.0)
@export_range(0.0, 0.5, 0.01) var deadzone_percent: float = 0.07
@export_range(0.1, 1.0, 0.01) var max_distance_percent: float = 0.40
@export var disabled: bool = false

var finger_id: int = -1
var output_vector: Vector2 = Vector2.ZERO
var is_active: bool = false

var _center: Vector2 = Vector2.ZERO
var _deadzone: float = 0.0
var _max_dist: float = 1.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	if base != null and base_texture != null:
		base.texture = base_texture
	if knob != null and knob_texture != null:
		knob.texture = knob_texture
	_reset_visual()

func _calculate_metrics() -> void:
	var reference_size: float = minf(visual_size.x, visual_size.y)
	_deadzone = reference_size * deadzone_percent
	_max_dist = maxf(reference_size * max_distance_percent, 1.0)

func _gui_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or disabled:
		return

	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch

		if touch.pressed:
			if finger_id == -1:
				finger_id = touch.index
				_begin_input(touch.position)
				accept_event()
		elif touch.index == finger_id:
			pass
		else:
			return

		if not touch.pressed and touch.index == finger_id:
			_end_input()
			accept_event()
		return

	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == finger_id:
			_update_output(drag.position)
			accept_event()

func _begin_input(local_position: Vector2) -> void:
	_calculate_metrics()
	is_active = true

	if joystick_mode == JoystickMode.DYNAMIC:
		# KRİTİK:
		# local_position görünmez sol dokunma alanına göredir.
		# Joystick görselinin merkezi tam olarak parmağın bastığı koordinattır.
		_center = local_position
		_place_base(local_position)
	else:
		_center = size * 0.5
		_place_base(_center)

	if base != null:
		base.visible = true

	activated.emit()
	_update_output(local_position)

func _place_base(center_position: Vector2) -> void:
	if base == null:
		return

	base.size = visual_size
	base.position = center_position - visual_size * 0.5

	if knob != null:
		knob.position = visual_size * 0.5 - knob.size * 0.5

func _update_output(local_position: Vector2) -> void:
	_calculate_metrics()

	var input_delta: Vector2 = local_position - _center
	var distance: float = input_delta.length()

	if distance <= _deadzone:
		output_vector = Vector2.ZERO
	else:
		var direction: Vector2 = input_delta.normalized()
		var strength: float = clampf(
			(distance - _deadzone) / maxf(_max_dist - _deadzone, 1.0),
			0.0,
			1.0
		)
		output_vector = direction * strength

	if knob != null:
		var knob_offset: Vector2 = output_vector.limit_length(1.0) * _max_dist
		knob.position = visual_size * 0.5 + knob_offset - knob.size * 0.5

func _end_input() -> void:
	var was_active: bool = is_active

	finger_id = -1
	output_vector = Vector2.ZERO
	is_active = false

	_reset_visual()

	if was_active:
		released.emit()

func _reset_visual() -> void:
	if base != null:
		base.size = visual_size

		if joystick_mode == JoystickMode.DYNAMIC:
			# Hareket joystick'i ekranda SABİT durmaz.
			base.visible = false
		else:
			# Hedef joystick'i SABİT görünür.
			base.visible = true
			base.position = size * 0.5 - visual_size * 0.5

	if knob != null:
		knob.position = visual_size * 0.5 - knob.size * 0.5
