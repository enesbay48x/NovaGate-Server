extends CanvasLayer

@onready var player = get_tree().get_first_node_in_group("player")

func _ready() -> void:
	# Bu HUD eski/yardımcı HUD olarak sahnede kalabiliyor. Sayı tuşları artık
	# doğrudan SlotManager üzerinden oyuncunun kaydettiği atamaları kullanır.
	if OS.get_name() not in ["Android", "iOS"]:
		call_deferred("_build_pc_hud")

func select_ammo(slot: int) -> void:
	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player")
	if player != null and player.has_method("select_ammo"):
		player.select_ammo(slot)

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if not key_event.pressed or key_event.echo:
			return

		match key_event.keycode:
			KEY_1: select_ammo(1)
			KEY_2: select_ammo(2)
			KEY_3: select_ammo(3)
			KEY_4: select_ammo(4)
			KEY_5: select_ammo(5)
			KEY_6: select_ammo(6)

# PC presentation only; all gameplay stays in the original owners.
const CYAN := Color(0.20, 0.78, 0.92)
const GREEN := Color(0.22, 0.82, 0.48)
const RED := Color(0.94, 0.28, 0.28)
const GOLD := Color(0.95, 0.75, 0.3)
var pc_root: Control
var main: Node
var menu: Control
var pilot_label: Label
var sector_label: Label
var hp: ProgressBar
var shield: ProgressBar
var action_hint: Label
var last_config: int = 0
var config_buttons: Array[Button] = []
var action_slots: Array[Dictionary] = []
var normal_style: StyleBoxFlat
var selected_style: StyleBoxFlat
var fire_button: Button
var jump_button: Button
var laser_icons: Array[Texture2D] = []

func _panel_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.018, 0.034, 0.052, 0.91)
	style.border_color = color
	style.set_border_width_all(1)
	style.border_width_top = 2
	style.set_corner_radius_all(3)
	style.set_content_margin_all(6)
	return style

func _place(node: Control, anchor: Vector2, rect: Rect2) -> void:
	node.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	node.anchor_left = anchor.x
	node.anchor_right = anchor.x
	node.anchor_top = anchor.y
	node.anchor_bottom = anchor.y
	node.offset_left = rect.position.x
	node.offset_top = rect.position.y
	node.offset_right = rect.end.x
	node.offset_bottom = rect.end.y

func _text(parent: Node, text: String, color: Color = Color(0.8, 0.9, 0.95)) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", color)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	parent.add_child(label)
	return label

func _panel(id: String, anchor: Vector2, rect: Rect2) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.name = id
	panel.add_theme_stylebox_override("panel", normal_style)
	pc_root.add_child(panel)
	_place(panel, anchor, rect)
	var column := VBoxContainer.new()
	column.name = "Content"
	column.add_theme_constant_override("separation", 4)
	panel.add_child(column)
	return column

func _bar(parent: Node, color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size.y = 18
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := StyleBoxFlat.new()
	fill.bg_color = color.darkened(0.4)
	bar.add_theme_stylebox_override("fill", fill)
	bar.add_theme_stylebox_override("background", _panel_style(color.darkened(0.7)))
	parent.add_child(bar)
	var label := _text(bar, "")
	label.name = "Value"
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return bar

func _build_pc_hud() -> void:
	main = get_tree().current_scene
	if main == null or not main.has_node("HUD/MenuRoot"):
		return
	menu = main.get_node("HUD/MenuRoot")
	normal_style = _panel_style(CYAN.darkened(0.6))
	selected_style = _panel_style(CYAN)
	selected_style.bg_color = Color(0.035, 0.14, 0.20, 0.97)
	pc_root = Control.new()
	pc_root.name = "PCHUD"
	pc_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc_root.z_index = 20
	main.get_node("HUD").add_child(pc_root)
	pc_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The menu pauses gameplay; visibility must update through its signal, not _process.
	var overlay: Control = menu.get("overlay")
	overlay.visibility_changed.connect(func(): pc_root.visible = not overlay.visible)
	pc_root.visible = not overlay.visible
	var column := _panel("Pilot", Vector2.ZERO, Rect2(12, 12, 240, 90))
	column.add_theme_constant_override("separation", 2)
	_text(column, "NOVAGATE / PİLOT", CYAN)
	pilot_label = _text(column, "")
	hp = _bar(column, GREEN)
	shield = _bar(column, CYAN)
	column.get_parent().hide() # Replaced by the compact movable INFO window.
	column = _panel("Sector", Vector2(1, 0), Rect2(-212, 12, 200, 28))
	sector_label = _text(column, "", CYAN)
	_place(main.get_node("HUD/Minimap"), Vector2(1, 0), Rect2(-212, 40, 200, 130))
	main.get_node("HUD/TopPanel").hide()
	var indicator: CanvasItem = menu.get("config_indicator")
	if indicator != null:
		indicator.hide()
	_build_actions()
	_build_commands()
	var quest: Panel = main.get_node_or_null("HUD/QuestTracker")
	if quest != null:
		quest.hide()
	column = _panel("QuestWidget", Vector2(0, 1), Rect2(12, -72, 210, 60))
	var summary := _button(column, "Quests", "", _open_active_quests)
	summary.custom_minimum_size = Vector2(198, 46)
	var refresh := func():
		if not is_instance_valid(summary):
			return
		var active := QuestSystem.get_active_quests()
		summary.text = "GÖREV • Aktif görev yok"
		summary.tooltip_text = "Aktif görev yok"
		if not active.is_empty():
			var id := str(active[0])
			var data := QuestSystem.get_quest(id)
			summary.text = "%s\n%d/%d • %d aktif" % [str(data.get("title", id)), QuestSystem.get_progress(id), QuestSystem.get_target(id), active.size()]
			summary.tooltip_text = "Amaç: " + str(data.get("description", ""))
	QuestSystem.quests_changed.connect(refresh)
	summary.tree_exiting.connect(func(): QuestSystem.quests_changed.disconnect(refresh), CONNECT_ONE_SHOT)
	refresh.call()

func _open_active_quests() -> void:
	var ui := main.find_child("SocialUI", true, false)
	if ui != null and ui.has_method("open_active_quests"):
		ui.call("open_active_quests")


func _button(parent: Node, id: String, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.name = id
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 11)
	button.add_theme_stylebox_override("normal", normal_style)
	button.add_theme_stylebox_override("hover", selected_style)
	button.add_theme_stylebox_override("pressed", _panel_style(GOLD))
	button.add_theme_stylebox_override("disabled", _panel_style(Color(0.16, 0.22, 0.27)))
	button.add_theme_color_override("font_disabled_color", Color(0.4, 0.48, 0.54))
	button.tooltip_text = text.replace("\n", " ")
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.mouse_entered.connect(func(): _flash(button))
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func _relay(original: BaseButton) -> void:
	if not original.disabled and not player.is_destroyed:
		original.pressed.emit()

func _make_slot(row: Node, original: BaseButton, title: String, icon: Texture2D, kind: String, index: int) -> void:
	var button := _button(row, title, "", _relay.bind(original))
	button.custom_minimum_size = Vector2(58, 42)
	var title_label := _text(button, title)
	title_label.position = Vector2(3, 0)
	title_label.size = Vector2(52, 14)
	title_label.add_theme_font_size_override("font_size", 10)
	var image := TextureRect.new()
	image.texture = icon
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.position = Vector2(19, 12)
	image.size = Vector2(20, 17)
	button.add_child(image)
	var count := _text(button, "")
	count.position = Vector2(2, 28)
	count.size = Vector2(54, 12)
	count.add_theme_font_size_override("font_size", 10)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var cooldown := ProgressBar.new()
	cooldown.max_value = 1.0
	cooldown.show_percentage = false
	cooldown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cooldown.position = Vector2(2, 40)
	cooldown.size = Vector2(54, 2)
	cooldown.add_theme_stylebox_override("background", StyleBoxEmpty.new())
	var fill := StyleBoxFlat.new()
	fill.bg_color = GOLD
	cooldown.add_theme_stylebox_override("fill", fill)
	button.add_child(cooldown)
	action_slots.append({"button":button, "original":original, "image":image, "count":count, "cooldown":cooldown, "kind":kind, "index":index})
	if kind == "laser":
		button.gui_input.connect(func(event: InputEvent):
			if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
				original.gui_input.emit(event)
		)

func _build_actions() -> void:
	var column := _panel("Actions", Vector2(0.5, 1), Rect2(-290, -130, 580, 118))
	column.add_theme_constant_override("separation", 2)
	_text(column, "SİLAH KONTROLÜ / LASER · ROKET · EXTRA", CYAN)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	column.add_child(row)
	var names := ["x1", "x2", "x3", "x4", "SAB", "RSB"]
	for i in range(6):
		laser_icons.append(load("res://assets/ammo/lammo%d.png" % (i + 1)))
		var original: Button = main.get_node("HUD/LaserToggleButton/LaserPanel/VBoxContainer/" + names[i])
		_make_slot(row, original, "L%d [%d]" % [i + 1, i + 1], laser_icons[i], "laser", i)
	for i in range(3):
		var original: TextureButton = main.get_node("HUD/ExtraHUD/HBoxContainer/R%dButton" % (i + 1))
		_make_slot(row, original, "R%d" % (i + 1), original.texture_normal, "rocket", i)
	row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	column.add_child(row)
	var extra_names := ["EMAButton", "NukleerButton", "OnlukButton", "ENCButton", "Kalkan3SnButton"]
	var titles := ["EMA", "BOMBA", "TAMİR", "ENC", "KALKAN"]
	for i in range(5):
		var original: TextureButton = main.get_node("HUD/ExtraHUD/HBoxContainer/" + extra_names[i])
		_make_slot(row, original, titles[i], original.texture_normal, "extra", i)
	for i in range(1, 3):
		var button := _button(row, "Config%d" % i, "CFG %d\n[C]" % i, menu.call.bind("_set_config", i))
		button.custom_minimum_size = Vector2(58, 42)
		config_buttons.append(button)
	fire_button = _button(row, "AutoFire", "ATEŞ\n[CTRL]", WeaponSystem.toggle_auto_fire)
	fire_button.custom_minimum_size = Vector2(58, 42)
	jump_button = _button(row, "Jump", "GEÇİŞ\n[J]", main.call.bind("mobile_try_gate"))
	jump_button.custom_minimum_size = Vector2(58, 42)
	action_hint = _text(column, "")
	action_hint.hide() # Shortcuts remain available on individual slot tooltips.

func _open_section(section: String) -> void:
	menu.call("_open_menu")
	if section == "EKİPMAN":
		menu.call("_show_hangar")
	else:
		menu.call("_show_section", section)

func _build_commands() -> void:
	var column := _panel("Commands", Vector2(1, 1), Rect2(-234, -120, 222, 108))
	column.add_theme_constant_override("separation", 3)
	var grid := GridContainer.new()
	grid.columns = 2
	column.add_child(grid)
	var icons := ["◇", "¤", "≡", "▥"]
	var titles := ["EKİPMAN", "MARKET", "GÖREVLER", "İSTATİSTİKLER"]
	for i in range(titles.size()):
		var title: String = titles[i]
		var button := _button(grid, title, icons[i] + " " + title, _open_section.bind(title))
		button.custom_minimum_size = Vector2(102, 27)
	var launch := _button(column, "Menu", "≡ MENÜ / DİĞER KOMUTLAR", menu.call.bind("_open_menu"))
	launch.custom_minimum_size.y = 27
	var existing: Button = menu.get("menu_button")
	existing.hide()


func _update_bar(bar: ProgressBar, value: float, maximum: float, title: String, delta: float, snap: bool = false) -> void:
	bar.max_value = maxf(maximum, 1.0)
	bar.value = value if snap else lerpf(bar.value, value, 1.0 - exp(-12.0 * delta))
	bar.get_node("Value").text = "%s %d / %d" % [title, int(value), int(maximum)]

func _flash(control: Control) -> void:
	control.modulate = Color(1.4, 1.4, 1.4)
	create_tween().tween_property(control, "modulate", Color.WHITE, 0.3)

func _process(delta: float) -> void:
	if not is_instance_valid(pc_root) or not is_instance_valid(player):
		return
	menu.get("menu_button").hide()
	var bottom: Node = main.get_node_or_null("HUD/BottomPanel")
	if bottom != null:
		bottom.hide()
	var laser_toggle: Node = main.get_node_or_null("HUD/LaserToggleButton")
	if laser_toggle != null:
		laser_toggle.hide()
	var extras: Node = main.get_node_or_null("HUD/ExtraHUD")
	if extras != null:
		extras.hide()
	pilot_label.text = "%s · SV %d · %s" % [GlobalState.username if not GlobalState.username.is_empty() else "Pilot", GlobalState.level, GlobalState.company]
	_update_bar(hp, player.health, player.max_health, "HP", delta)
	_update_bar(shield, player.shield, player.max_shield, "SH", delta)
	sector_label.text = "%s | %d : %d" % [main.get("current_map_name"), player.global_position.x, player.global_position.y]
	# Hedef/NPC bilgi paneli kaldırıldı: player.locked_target hâlâ savaş sistemi
	# tarafından kullanılmaya devam eder, sadece ekranda bilgi gösterilmez.
	_update_slots()
	var config: int = player.active_config
	for i in range(2):
		config_buttons[i].add_theme_stylebox_override("normal", selected_style if config == i + 1 else normal_style)
		config_buttons[i].disabled = player.is_destroyed
	if config != last_config:
		_flash(config_buttons[config - 1])
		last_config = config
	fire_button.disabled = player.is_destroyed
	fire_button.add_theme_stylebox_override("normal", selected_style if WeaponSystem.auto_fire else normal_style)
	jump_button.disabled = player.is_destroyed or bool(main.get("warp_active"))
	var hint: Label = main.get("laser_shortcut_hint")
	action_hint.text = hint.text if hint != null and hint.visible else "Sağ tık lazer: kısayol ata • CTRL: ateş • C: config • J: geçiş"

func _update_slots() -> void:
	var rockets: Node = main.get_node("RocketSystem")
	var extras: Node = main.get_node("HUD/ExtraHUD")
	for slot: Dictionary in action_slots:
		var button: Button = slot.button
		var index: int = slot.index
		var active: bool = false
		var blocked: bool = player.is_destroyed or slot.original.disabled
		var remaining: float = 0.0
		var duration: float = 1.0
		if slot.kind == "laser":
			var ammo: String = SlotManager.get_slot_laser(index + 1)
			var market: String = AmmoSystem.AMMO_NAME_MAP.get(ammo, "X1")
			var laser: int = ["X1", "X2", "X3", "X4", "SAB", "RSB"].find(market)
			slot.image.texture = laser_icons[laser]
			slot.count.text = str(GlobalState.get_ammo_count(market))
			active = WeaponSystem.current_laser == laser
			if market == "RSB" and WeaponSystem.rsb_cooldown:
				remaining = 1.0
				blocked = true
				slot.count.text = "BEKLE"
			elif active and WeaponSystem.auto_fire:
				remaining = WeaponSystem.timer
				duration = WeaponSystem.fire_interval
			button.tooltip_text = "L%d [%d] · %s · Sağ tık: kısayol ata" % [index + 1, index + 1, market]
		elif slot.kind == "rocket":
			active = int(rockets.get("selected_rocket")) == index
			remaining = float(rockets.get("cooldown_left"))
			var data: Dictionary = rockets.get("ROCKETS")
			duration = float(data[int(rockets.get("selected_rocket"))]["interval"])
			slot.count.text = str(GlobalState.get_ammo_count("R%d" % (index + 1)))
			button.tooltip_text = slot.original.tooltip_text
		else:
			var key: String = ["ema", "nukleer", "onluk", "enc", "kalkan"][index]
			var state: Dictionary = extras.call("mobile_get_status", key)
			remaining = maxf((float(extras.get("cooldown_end_msec").get(key, 0)) - Time.get_ticks_msec()) / 1000.0, 0.0)
			duration = float(extras.get(key + "_cooldown_seconds"))
			active = int(state.active) > 0
			slot.count.text = ("AKTİF %ds" % state.active) if active else ("%ds" % ceili(remaining) if remaining > 0 else "HAZIR")
			button.tooltip_text = slot.original.tooltip_text
		button.disabled = blocked
		button.add_theme_stylebox_override("normal", selected_style if active else normal_style)
		slot.cooldown.value = clampf(remaining / maxf(duration, 0.001), 0.0, 1.0)

