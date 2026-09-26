extends CanvasLayer
## Scene-local shared window registry; no new autoload or account format.
const WindowPanel = preload("res://scripts/window_panel.gd")
const SAVE_PATH := "user://hud_panels.cfg"
var windows: Dictionary = {}
var panel_root: Control
var dock_layer: CanvasLayer
var dock: VBoxContainer
var modal_sources: Array[Control] = []
var modal_blocked := false
var _config := ConfigFile.new()
var _save_timer: Timer
var _layout_key := ""

func initialize_windows() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	var account := get_node_or_null("/root/GlobalState")
	var username := str(account.get("username")) if account != null else "guest"
	_layout_key = ("mobile/" if OS.get_name() in ["Android", "iOS"] else "pc/") + username.sha256_text().substr(0, 16)
	_config.load(SAVE_PATH)
	panel_root = Control.new()
	panel_root.name = "Windows"
	panel_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel_root)
	dock_layer = CanvasLayer.new()
	dock_layer.layer = 80
	add_child(dock_layer)
	dock = VBoxContainer.new()
	dock.add_theme_constant_override("separation", 4)
	dock_layer.add_child(dock)
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.3
	_save_timer.timeout.connect(save_layout)
	add_child(_save_timer)
	get_viewport().size_changed.connect(clamp_windows)

func create_window(id: String, title: String, rect: Rect2, minimum := Vector2(180, 100), persist := true):
	if windows.has(id):
		return windows[id]
	var window := WindowPanel.new()
	window.persistent = persist
	window.setup(id, title, rect, minimum)
	register_panel(window)
	return window

func register_panel(window: PanelContainer) -> void:
	var id: String = window.panel_id
	if windows.has(id):
		push_warning("Duplicate HUD window: " + id)
		return
	if window.get_parent() == null:
		panel_root.add_child(window)
	windows[id] = window
	var section := _layout_key + "/" + id
	if window.persistent:
		var pos = _config.get_value(section, "position", window.position)
		var extent = _config.get_value(section, "size", window.size)
		if pos is Vector2 and pos.is_finite():
			window.position = pos
		if extent is Vector2 and extent.is_finite():
			window.size = extent
		window.set_panel_state(str(_config.get_value(section, "state", "open")), false)
	window.state_changed.connect(_window_changed)
	window.focused.connect(bring_to_front.bind(window))
	clamp_windows()
	_refresh_dock()

func bring_to_front(window: Control) -> void:
	# Tree order within layer 50; never crosses combat/menu layers.
	if window.get_parent() == panel_root:
		panel_root.move_child(window, -1)

func register_modal(overlay: Control) -> void:
	if overlay == null or modal_sources.has(overlay):
		return
	modal_sources.append(overlay)
	overlay.visibility_changed.connect(_sync_modal)
	_sync_modal()

func _sync_modal() -> void:
	modal_blocked = false
	for overlay in modal_sources:
		if is_instance_valid(overlay) and overlay.is_visible_in_tree():
			modal_blocked = true
	panel_root.visible = not modal_blocked
	dock_layer.visible = not modal_blocked
	if modal_blocked:
		var focus := get_viewport().gui_get_focus_owner()
		if focus != null and panel_root.is_ancestor_of(focus):
			focus.release_focus()

func available_rect() -> Rect2:
	var extent := get_viewport().get_visible_rect().size
	# Keep bottom combat/joystick band and right dock clear.
	var reserve := minf(150.0, extent.y * 0.25)
	return Rect2(Vector2(8, 8), Vector2(maxf(180, extent.x - 80), maxf(120, extent.y - reserve - 16)))

func clamp_windows() -> void:
	var rect := available_rect()
	for window in windows.values():
		window.bounds = rect
		window.clamp_to_bounds()
	var vp := get_viewport().get_visible_rect().size
	dock.position = Vector2(vp.x - 68, maxf(8, (vp.y - dock.size.y) * 0.5))

func _window_changed() -> void:
	_refresh_dock()
	_save_timer.start()

func _refresh_dock() -> void:
	for child in dock.get_children():
		dock.remove_child(child)
		child.queue_free()
	for id in windows:
		var window = windows[id]
		if window.panel_state != "collapsed":
			continue
		var button := Button.new()
		button.text = str(id)
		button.tooltip_text = window.title_label.text
		button.add_theme_font_size_override("font_size", 10)
		button.custom_minimum_size = Vector2(60, 28)
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(window.reopen)
		dock.add_child(button)
	clamp_windows()

func save_layout() -> void:
	for id in windows:
		var window = windows[id]
		if not window.persistent:
			continue
		var section := _layout_key + "/" + str(id)
		_config.set_value(section, "position", window.position)
		_config.set_value(section, "size", window.size)
		_config.set_value(section, "state", window.panel_state)
	var error := _config.save(SAVE_PATH)
	if error != OK:
		push_warning("HUD layout save failed: %s" % error)

func _exit_tree() -> void:
	if panel_root != null:
		save_layout()
