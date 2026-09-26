extends PanelContainer
## Reusable HUD window. Content owners keep their gameplay/data logic.
signal state_changed
signal focused

var panel_id := ""
var panel_state := "open"
var persistent := true
var content: VBoxContainer
var header: HBoxContainer
var title_label: Label
var bounds := Rect2(8, 8, 1264, 560)
var drag_pointer := -2
var drag_offset := Vector2.ZERO
var _fade: Tween

func setup(id: String, title: String, rect: Rect2, minimum := Vector2(180, 100)) -> void:
	panel_id = id
	name = "Window_" + id
	custom_minimum_size = minimum
	position = rect.position
	size = rect.size.max(minimum)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.018, 0.034, 0.052, 0.92)
	style.border_color = Color(0.2, 0.78, 0.92, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.set_content_margin_all(5)
	add_theme_stylebox_override("panel", style)
	add_theme_font_size_override("font_size", 11)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 3)
	add_child(column)
	header = HBoxContainer.new()
	header.custom_minimum_size.y = 24
	header.mouse_filter = Control.MOUSE_FILTER_STOP
	header.gui_input.connect(_header_input)
	column.add_child(header)
	var collapse_button := Button.new()
	collapse_button.text = "<"
	collapse_button.tooltip_text = "Küçült"
	collapse_button.custom_minimum_size = Vector2(26, 24)
	collapse_button.focus_mode = Control.FOCUS_NONE
	collapse_button.pressed.connect(collapse)
	header.add_child(collapse_button)
	title_label = Label.new()
	title_label.text = title
	title_label.add_theme_font_size_override("font_size", 11)
	title_label.add_theme_color_override("font_color", Color(0.35, 0.85, 0.95))
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(title_label)
	content = VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 3)
	column.add_child(content)

func _header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and drag_pointer == -2:
			_begin_drag(-1, get_global_mouse_position())
		elif not event.pressed and drag_pointer == -1:
			_end_drag()
		header.accept_event()
	elif event is InputEventScreenTouch:
		if event.pressed and drag_pointer == -2:
			_begin_drag(event.index, header.get_global_transform() * event.position)
		elif not event.pressed and drag_pointer == event.index:
			_end_drag()
		header.accept_event()

func _begin_drag(pointer: int, point: Vector2) -> void:
	drag_pointer = pointer
	drag_offset = point - global_position
	focused.emit()

func _input(event: InputEvent) -> void:
	if drag_pointer == -2:
		return
	if not is_visible_in_tree() or get_tree().paused:
		_end_drag()
		return
	if event is InputEventMouseMotion and drag_pointer == -1:
		global_position = event.position - drag_offset
		clamp_to_bounds()
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == drag_pointer:
		global_position = event.position - drag_offset
		clamp_to_bounds()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed and drag_pointer == -1:
		_end_drag()
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch and not event.pressed and event.index == drag_pointer:
		_end_drag()
		get_viewport().set_input_as_handled()

func _end_drag() -> void:
	drag_pointer = -2
	state_changed.emit()

func clamp_to_bounds() -> void:
	size = size.max(custom_minimum_size).min(bounds.size.max(custom_minimum_size))
	position = Vector2(clampf(position.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - size.x)), clampf(position.y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - size.y)))

func collapse() -> void:
	set_panel_state("collapsed")

func close_window() -> void:
	set_panel_state("hidden")

func reopen() -> void:
	set_panel_state("open")
	focused.emit()

func set_panel_state(value: String, animate := true) -> void:
	if value not in ["open", "collapsed", "hidden"]:
		return
	panel_state = value
	drag_pointer = -2
	if _fade != null and _fade.is_valid():
		_fade.kill()
	if animate and is_inside_tree():
		_fade = create_tween()
		if value == "open":
			show()
			modulate.a = 0.0
			_fade.tween_property(self, "modulate:a", 1.0, 0.14)
		else:
			_fade.tween_property(self, "modulate:a", 0.0, 0.12)
			_fade.tween_callback(hide)
	else:
		visible = value == "open"
		modulate.a = 1.0
	state_changed.emit()
