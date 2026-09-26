extends Node2D
## Read-only world entity presentation. Never owns or changes combat values.
## Bars are visible only for the current selection/target (see read_alive).
const WIDTH := 72.0
const HEIGHT := 5.0
const SHIELD_HEIGHT := 4.0
const GAP := 1.0
var health_bar: ProgressBar
var shield_bar: ProgressBar
var read_values: Callable
var read_visual: Callable
var read_alive: Callable

func bind_entity(entity: Node2D, values: Callable, visual: Callable, alive: Callable,
		existing_hp: ProgressBar = null, existing_shield: ProgressBar = null) -> void:
	name = "EntityStatusBars"
	read_values = values
	read_visual = visual
	read_alive = alive
	entity.add_child(self)
	z_index = 20
	health_bar = _make_bar(existing_hp, "HealthBar", Color(0.18, 0.9, 0.35), 0.0, HEIGHT)
	shield_bar = _make_bar(existing_shield, "ShieldBar", Color(0.18, 0.58, 1.0), HEIGHT + GAP, SHIELD_HEIGHT)
	refresh()

func _make_bar(existing: ProgressBar, bar_name: String, color: Color, y: float, height: float) -> ProgressBar:
	var bar := existing
	if bar == null:
		bar = ProgressBar.new()
		bar.name = bar_name
		add_child(bar)
	else:
		bar.reparent(self, false)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.show_percentage = false
	bar.step = 0.0
	bar.min_value = 0.0
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	bar.position = Vector2(-WIDTH / 2.0, y)
	bar.size = Vector2(WIDTH, height)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.015, 0.025, 0.045, 0.9)
	background.border_color = Color(0.02, 0.04, 0.07)
	background.set_border_width_all(1)
	bar.add_theme_stylebox_override("background", background)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	bar.add_theme_stylebox_override("fill", fill)
	bar.show()
	return bar

func _process(_delta: float) -> void:
	refresh()

func refresh() -> void:
	if health_bar == null or not read_values.is_valid():
		return
	var values: Vector4 = read_values.call()
	# Only the current selection/target may show bars; nothing else on screen.
	visible = bool(read_alive.call()) and values.x > 0.0 and values.y > 0.0
	health_bar.max_value = maxf(values.y, 1.0)
	health_bar.value = clampf(values.x, 0.0, maxf(values.y, 0.0))
	shield_bar.max_value = maxf(values.w, 1.0)
	shield_bar.value = clampf(values.z, 0.0, maxf(values.w, 0.0))
	if not visible:
		return
	# Logical viewport pixels: compact at any zoom, readable on mobile stretch.
	# The node remains an entity child; canvas transform is only used for placement.
	var canvas := get_canvas_transform()
	var entity := get_parent() as Node2D
	var anchor := canvas * entity.global_position
	var top := anchor.y - 32.0
	var visual = read_visual.call()
	if is_instance_valid(visual) and visual is Sprite2D and visual.texture != null:
		var rect: Rect2 = visual.get_rect()
		var transform: Transform2D = canvas * visual.global_transform
		for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
			top = minf(top, (transform * corner).y)
	anchor.y = top - HEIGHT - SHIELD_HEIGHT - GAP - 7.0
	global_transform = canvas.affine_inverse() * Transform2D(0.0, anchor)
