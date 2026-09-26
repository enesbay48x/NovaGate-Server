extends Control
class_name NovaGateGalaxyGateUI

# ==========================================================================
# NOVAGATE GALAXY GATES ARAYUZU
# --------------------------------------------------------------------------
# X1 haritasinda gate portalina yaklasinca / portaldan acilir.
# Kapi listesi ve parca sayilari GalaxyGateData'dan gelir:
# ALPHA 34 / BETA 48 / GAMMA 82. Baska gate tanimi YOKTUR.
# Materializer 1 / 5 / 10 / 100 cevir adimlariyla calisir; para birimi,
# envanter ve kayit islemleri mevcut GalaxyGateManager + GlobalState
# ekonomisi uzerinden yapilir (paralel sistem yoktur).
# ==========================================================================

signal gate_entered(gate_id: String)

const GateData := preload("res://scripts/galaxy_gate_data.gd")

# Panel olculeri (1280x720 viewport'a ortalanir).
const PANEL_W: float = 1200.0
const PANEL_H: float = 640.0
const MAX_WINNING_LINES: int = 8

# Mevcut NovaGate renk paleti.
const ACCENT := Color(0.4, 0.95, 1.0)
const ACCENT_DIM := Color(0.75, 0.85, 0.95)
const GOLD := Color(1.0, 0.8, 0.35)
const GREEN := Color(0.45, 1.0, 0.6)

var _overlay: ColorRect = null
var _panel: Panel = null
var _rows_box: VBoxContainer = null
var _info_label: Label = null
var _rows: Dictionary = {}
var _tabs: Dictionary = {}
var _spin_buttons: Dictionary = {}
var _selected_gate_label: Label = null
var _parts_label: Label = null
var _parts_bar: ProgressBar = null
var _multiplier_label: Label = null
var _plt_label: Label = null
var _energy_label: Label = null
var _status_label: Label = null
var _enter_button: Button = null
var _activate_button: Button = null
var _winnings_box: VBoxContainer = null
var _last_winnings: Array[String] = []


func _ready() -> void:
	# Overlay acikken agac duraklatilir; arayuz yine de girdi almalidir.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


func _build() -> void:
	_overlay = ColorRect.new()
	_overlay.name = "GalaxyGateOverlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color(0.0, 0.0, 0.0, 0.62)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	_panel = Panel.new()
	_panel.name = "GalaxyGatePanel"
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.offset_left = -(PANEL_W * 0.5)
	_panel.offset_top = -(PANEL_H * 0.5)
	_panel.offset_right = PANEL_W * 0.5
	_panel.offset_bottom = PANEL_H * 0.5
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_overlay.add_child(_panel)

	_build_header()
	_build_tabs()
	_build_info_panel()
	_build_spin_buttons()
	_build_winnings_panel()
	_build_gate_overview()
	_build_footer()
	refresh()


func _build_header() -> void:
	var title := Label.new()
	title.text = "GALAXY GATES"
	title.position = Vector2(24.0, 12.0)
	title.size = Vector2(1152.0, 38.0)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", GOLD)
	_panel.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "MATERIALIZER KONTROL PANELİ"
	subtitle.position = Vector2(24.0, 46.0)
	subtitle.size = Vector2(1152.0, 20.0)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 13)
	subtitle.add_theme_color_override("font_color", ACCENT_DIM)
	_panel.add_child(subtitle)

	var close_button := Button.new()
	close_button.text = "X"
	close_button.position = Vector2(1142.0, 14.0)
	close_button.size = Vector2(46.0, 36.0)
	close_button.add_theme_font_size_override("font_size", 18)
	close_button.pressed.connect(close)
	_panel.add_child(close_button)


func _build_tabs() -> void:
	var ids: Array[String] = GateData.gate_ids()
	for index in range(ids.size()):
		var gate_id: String = ids[index]
		var button := Button.new()
		button.name = "GateTab_%s" % gate_id
		button.text = GateData.display_name(gate_id)
		button.position = Vector2(24.0 + float(index) * 162.0, 76.0)
		button.size = Vector2(150.0, 38.0)
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.add_theme_font_size_override("font_size", 18)
		button.add_theme_stylebox_override("normal", _panel_style(Color(0.03, 0.07, 0.12, 0.9), Color(0.10, 0.45, 0.65, 0.9), 1))
		button.add_theme_stylebox_override("hover", _panel_style(Color(0.06, 0.16, 0.22, 1.0), ACCENT, 2))
		button.add_theme_stylebox_override("disabled", _panel_style(Color(0.06, 0.18, 0.24, 1.0), ACCENT, 2))
		button.add_theme_color_override("font_color", ACCENT_DIM)
		button.add_theme_color_override("font_disabled_color", ACCENT)
		button.pressed.connect(_on_select_pressed.bind(gate_id))
		_panel.add_child(button)
		_tabs[gate_id] = button


# Panel stili varsayilanlari. Parametresiz cagrilar onceki gorunumu birebir
# korur; normal / hover / disabled gibi farkli renkler icin opsiyonel deger
# verilebilir.
const PANEL_FILL := Color(0.02, 0.045, 0.08, 0.97)
const PANEL_BORDER := Color(0.12, 0.66, 0.9, 1.0)
const PANEL_BORDER_WIDTH: int = 2


func _panel_style(fill: Color = PANEL_FILL, border: Color = PANEL_BORDER, border_width: int = PANEL_BORDER_WIDTH) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10.0)
	return style


func _row_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.07, 0.12, 0.85)
	style.border_color = Color(0.10, 0.45, 0.65, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6.0)
	return style


func _build_info_panel() -> void:
	# DarkOrbit Galaxy Gates mantigi: secili kapi, parca ilerlemesi,
	# multiplier, PLT ve Extra Energy tek blokta gosterilir.
	var box := Panel.new()
	box.name = "GateInfoPanel"
	box.position = Vector2(24.0, 128.0)
	box.size = Vector2(552.0, 300.0)
	box.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.055, 0.085, 0.96), Color(0.10, 0.45, 0.65, 0.9), 1))
	_panel.add_child(box)

	var grid := GridContainer.new()
	grid.name = "GateInfoGrid"
	grid.columns = 2
	grid.position = Vector2(16.0, 14.0)
	grid.size = Vector2(520.0, 150.0)
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 6)
	box.add_child(grid)

	_selected_gate_label = _info_value("ALPHA")
	_parts_label = _info_value("0 / 34")
	_multiplier_label = _info_value("x1")
	_plt_label = _info_value("0")
	_energy_label = _info_value("0")
	_add_info_row(grid, "Seçili kapı:", _selected_gate_label)
	_add_info_row(grid, "Kapı Parçaları:", _parts_label)
	_add_info_row(grid, "Multiplier:", _multiplier_label)
	_add_info_row(grid, "PLT:", _plt_label)
	_add_info_row(grid, "Extra Energy:", _energy_label)

	_parts_bar = ProgressBar.new()
	_parts_bar.name = "GatePartsBar"
	_parts_bar.position = Vector2(16.0, 176.0)
	_parts_bar.size = Vector2(520.0, 18.0)
	_parts_bar.show_percentage = true
	box.add_child(_parts_bar)

	_status_label = Label.new()
	_status_label.name = "GateStatusLabel"
	_status_label.position = Vector2(16.0, 202.0)
	_status_label.size = Vector2(520.0, 34.0)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 22)
	_status_label.add_theme_color_override("font_color", GOLD)
	box.add_child(_status_label)

	_enter_button = Button.new()
	_enter_button.name = "GateEnterButton"
	_enter_button.text = "GİR"
	_enter_button.position = Vector2(16.0, 244.0)
	_enter_button.size = Vector2(200.0, 46.0)
	_enter_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_enter_button.add_theme_font_size_override("font_size", 20)
	_enter_button.add_theme_stylebox_override("normal", _panel_style(Color(0.03, 0.12, 0.09, 0.96), Color(0.25, 0.9, 0.55, 1.0), 2))
	_enter_button.add_theme_stylebox_override("hover", _panel_style(Color(0.05, 0.20, 0.14, 1.0), Color(0.45, 1.0, 0.7, 1.0), 2))
	_enter_button.add_theme_stylebox_override("disabled", _panel_style(Color(0.05, 0.06, 0.08, 0.9), Color(0.25, 0.30, 0.35, 0.8), 1))
	_enter_button.pressed.connect(_on_enter_selected_pressed)
	box.add_child(_enter_button)

	_activate_button = Button.new()
	_activate_button.name = "GateActivateButton"
	_activate_button.text = "AKTİF ET"
	_activate_button.position = Vector2(226.0, 244.0)
	_activate_button.size = Vector2(140.0, 46.0)
	_activate_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_activate_button.add_theme_font_size_override("font_size", 16)
	_activate_button.add_theme_stylebox_override("normal", _panel_style(Color(0.035, 0.08, 0.115, 0.98), Color(0.08, 0.48, 0.64, 0.95), 2))
	_activate_button.add_theme_stylebox_override("hover", _panel_style(Color(0.06, 0.16, 0.22, 1.0), ACCENT, 2))
	_activate_button.add_theme_stylebox_override("disabled", _panel_style(Color(0.05, 0.06, 0.08, 0.9), Color(0.25, 0.30, 0.35, 0.8), 1))
	_activate_button.pressed.connect(_on_activate_selected_pressed)
	box.add_child(_activate_button)

	var hint := Label.new()
	hint.text = "Parçalar dolunca \"KAPI HAZIR\" olur ve GİR aktifleşir."
	hint.position = Vector2(378.0, 246.0)
	hint.size = Vector2(158.0, 44.0)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", ACCENT_DIM)
	box.add_child(hint)


func _build_spin_buttons() -> void:
	# 1 / 5 / 10 / 100 CEVIR: her adim sonuc uretir, hicbir adim bos degildir.
	var options: Array[int] = GateData.MATERIALIZER_SPIN_OPTIONS
	for index in range(options.size()):
		var spins: int = options[index]
		var button := Button.new()
		button.name = "SpinButton_%d" % spins
		button.text = "%d ÇEVİR" % spins
		button.position = Vector2(24.0 + float(index) * 142.0, 440.0)
		button.size = Vector2(126.0, 46.0)
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.add_theme_font_size_override("font_size", 16)
		button.add_theme_stylebox_override("normal", _panel_style(Color(0.035, 0.08, 0.115, 0.98), Color(0.08, 0.48, 0.64, 0.95), 2))
		button.add_theme_stylebox_override("hover", _panel_style(Color(0.06, 0.16, 0.22, 1.0), ACCENT, 2))
		button.add_theme_stylebox_override("disabled", _panel_style(Color(0.05, 0.06, 0.08, 0.9), Color(0.25, 0.30, 0.35, 0.8), 1))
		button.pressed.connect(_on_spin_pressed.bind(spins))
		_panel.add_child(button)
		_spin_buttons[spins] = button

	var cost_info := Label.new()
	cost_info.name = "GateSpinCostInfo"
	cost_info.text = "1 ÇEVİR = %s PLT • 5 ÇEVİR = %s PLT • 10 ÇEVİR = %s PLT • 100 ÇEVİR = %s PLT" % [
		_format_number(GateData.MATERIALIZER_PLT_COST),
		_format_number(GateData.MATERIALIZER_PLT_COST * 5),
		_format_number(GateData.MATERIALIZER_PLT_COST * 10),
		_format_number(GateData.MATERIALIZER_PLT_COST * 100)
	]
	cost_info.position = Vector2(24.0, 494.0)
	cost_info.size = Vector2(552.0, 22.0)
	cost_info.add_theme_font_size_override("font_size", 13)
	cost_info.add_theme_color_override("font_color", ACCENT_DIM)
	_panel.add_child(cost_info)

	_info_label = Label.new()
	_info_label.name = "GalaxyGateInfo"
	_info_label.position = Vector2(24.0, 520.0)
	_info_label.size = Vector2(552.0, 46.0)
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_font_size_override("font_size", 14)
	_info_label.add_theme_color_override("font_color", Color(0.8, 0.92, 1.0))
	_panel.add_child(_info_label)


func _build_winnings_panel() -> void:
	var title := Label.new()
	title.text = "SON KAZANÇLAR"
	title.position = Vector2(624.0, 128.0)
	title.size = Vector2(552.0, 26.0)
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", ACCENT)
	_panel.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.name = "GateWinningsScroll"
	scroll.position = Vector2(624.0, 158.0)
	scroll.size = Vector2(552.0, 140.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_theme_stylebox_override("panel", _panel_style(Color(0.02, 0.045, 0.075, 0.92), Color(0.08, 0.38, 0.52, 0.9), 1))
	_panel.add_child(scroll)

	_winnings_box = VBoxContainer.new()
	_winnings_box.name = "GateWinningsList"
	_winnings_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_winnings_box.add_theme_constant_override("separation", 4)
	scroll.add_child(_winnings_box)


func _build_gate_overview() -> void:
	# Tum kapilar tek listede: parca ilerlemesi + durum + secim.
	var title := Label.new()
	title.text = "KAPI DURUMU"
	title.position = Vector2(624.0, 310.0)
	title.size = Vector2(552.0, 26.0)
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", ACCENT)
	_panel.add_child(title)

	_rows_box = VBoxContainer.new()
	_rows_box.name = "GalaxyGateRows"
	_rows_box.position = Vector2(624.0, 342.0)
	_rows_box.size = Vector2(552.0, 220.0)
	_rows_box.add_theme_constant_override("separation", 8)
	_panel.add_child(_rows_box)

	for gate_id in GateData.gate_ids():
		_build_gate_row(gate_id)


func _info_value(initial_text: String) -> Label:
	var label := Label.new()
	label.text = initial_text
	label.custom_minimum_size = Vector2(280.0, 28.0)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", ACCENT)
	return label


func _add_info_row(grid: GridContainer, caption: String, value: Label) -> void:
	var caption_label := Label.new()
	caption_label.text = caption
	caption_label.custom_minimum_size = Vector2(220.0, 28.0)
	caption_label.add_theme_font_size_override("font_size", 16)
	caption_label.add_theme_color_override("font_color", ACCENT_DIM)
	grid.add_child(caption_label)
	grid.add_child(value)


func _build_gate_row(gate_id: String) -> void:
	var row_panel := PanelContainer.new()
	row_panel.name = "GateRow_%s" % gate_id
	row_panel.add_theme_stylebox_override("panel", _row_style())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row_panel.add_child(row)

	var name_label := Label.new()
	name_label.name = "GateName"
	name_label.custom_minimum_size = Vector2(80.0, 0.0)
	name_label.add_theme_font_size_override("font_size", 17)
	name_label.add_theme_color_override("font_color", Color(0.4, 0.95, 1.0))
	row.add_child(name_label)

	var parts_label := Label.new()
	parts_label.name = "GateParts"
	parts_label.custom_minimum_size = Vector2(130.0, 0.0)
	parts_label.add_theme_font_size_override("font_size", 15)
	row.add_child(parts_label)

	var status_label := Label.new()
	status_label.name = "GateStatus"
	status_label.custom_minimum_size = Vector2(96.0, 0.0)
	status_label.add_theme_font_size_override("font_size", 15)
	row.add_child(status_label)

	var select_button := Button.new()
	select_button.name = "GateSelectButton"
	select_button.text = "SEÇ"
	select_button.custom_minimum_size = Vector2(68.0, 32.0)
	select_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	select_button.add_theme_font_size_override("font_size", 14)
	select_button.pressed.connect(_on_select_pressed.bind(gate_id))
	row.add_child(select_button)

	var materialize_button := Button.new()
	materialize_button.name = "GateMaterializeButton"
	materialize_button.text = "1 ÇEVİR"
	materialize_button.custom_minimum_size = Vector2(104.0, 32.0)
	materialize_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	materialize_button.add_theme_font_size_override("font_size", 14)
	materialize_button.pressed.connect(_on_materialize_pressed.bind(gate_id))
	row.add_child(materialize_button)

	_rows_box.add_child(row_panel)
	_rows[gate_id] = {
		"name": name_label,
		"parts": parts_label,
		"status": status_label,
		"select": select_button,
		"materialize": materialize_button
	}


func _build_footer() -> void:
	# Materializer maliyeti, odul dagilimi ve parca kaynagi bilgisi.
	var footer := Label.new()
	footer.name = "GalaxyGateFooter"
	footer.position = Vector2(624.0, 570.0)
	footer.size = Vector2(552.0, 60.0)
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_theme_font_size_override("font_size", 13)
	footer.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95))
	footer.text = "Materializer: 1 çevir = %d PLT. Olasılıklar: %%%d mühimmat, %%%d kapı parçası, %%%d Xenomit, %%%d Nano Hull, %%%d tamir kuponu, %%%d log disk. X1 bonus kutularından da parça düşebilir." % [
		GateData.MATERIALIZER_PLT_COST,
		GateData.REWARD_AMMO_PERCENT,
		GateData.GATE_PART_CHANCE_PERCENT,
		GateData.REWARD_XENOMIT_PERCENT,
		GateData.REWARD_NANO_HULL_PERCENT,
		GateData.REWARD_REPAIR_COUPON_PERCENT,
		GateData.REWARD_LOG_DISK_PERCENT
	]
	_panel.add_child(footer)


# --------------------------------------------------------------------------
# DURUM / AKSIYONLAR
# --------------------------------------------------------------------------

func open() -> void:
	refresh()
	# Kapanistan sonra tekrar acilirken kok Control yine input almalidir.
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.visible = true
	if not get_tree().paused:
		get_tree().paused = true


func close() -> void:
	if _overlay != null:
		_overlay.visible = false
	# Kok Control tam ekran ve MOUSE_FILTER_STOP oldugu icin, kapaliyken
	# gorunur kalirsa oyundaki fare tiklamalarini yakalar. Gizle ve birak.
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if get_tree().paused:
		get_tree().paused = false


func refresh() -> void:
	if _rows.is_empty():
		return
	var selected: String = GalaxyGateManager.selected_gate_id()
	if selected.is_empty():
		return
	var required: int = GateData.required_parts(selected)
	var current: int = GalaxyGateManager.parts_count(selected)
	var completed: bool = GalaxyGateManager.is_completed(selected)
	var active: bool = GalaxyGateManager.is_active(selected)
	var ready: bool = GalaxyGateManager.parts_complete(selected) and not completed and not active

	# Ust bilgi blogu: secili kapi, parca, multiplier, PLT, Extra Energy.
	if _selected_gate_label != null:
		_selected_gate_label.text = GateData.display_name(selected)
	if _parts_label != null:
		_parts_label.text = "%d / %d" % [current, required]
	if _parts_bar != null:
		_parts_bar.max_value = float(maxi(required, 1))
		_parts_bar.value = float(clampi(current, 0, maxi(required, 1)))
	if _multiplier_label != null:
		_multiplier_label.text = "x%d" % _multiplier_for(selected)
	if _plt_label != null:
		_plt_label.text = _format_number(int(GlobalState.platinum))
	if _energy_label != null:
		_energy_label.text = _format_number(GalaxyGateManager.extra_energy())
	if _status_label != null:
		if completed:
			_status_label.text = "KAPI TAMAMLANDI"
			_status_label.add_theme_color_override("font_color", ACCENT_DIM)
		elif active:
			_status_label.text = "KAPI AKTİF • GİR"
			_status_label.add_theme_color_override("font_color", GREEN)
		elif ready:
			_status_label.text = "KAPI HAZIR"
			_status_label.add_theme_color_override("font_color", GOLD)
		else:
			_status_label.text = "PARÇALAR TOPLANIYOR"
			_status_label.add_theme_color_override("font_color", ACCENT)
	if _enter_button != null:
		_enter_button.disabled = completed or not (ready or active)
	if _activate_button != null:
		_activate_button.disabled = not ready

	# Kapi sekmeleri: secili kapi isaretli, parca ilerlemesi sekmede gorunur.
	for gate_id in _tabs.keys():
		var tab: Button = _tabs[gate_id]
		var tab_key: String = str(gate_id)
		tab.disabled = tab_key == selected
		tab.text = "%s  %d/%d" % [
			GateData.display_name(tab_key),
			GalaxyGateManager.parts_count(tab_key),
			GateData.required_parts(tab_key)
		]

	# Kapi durumu listesi.
	for gate_id in GateData.gate_ids():
		if not _rows.has(gate_id):
			continue
		var row: Dictionary = _rows[gate_id]
		var row_required: int = GateData.required_parts(gate_id)
		var row_current: int = GalaxyGateManager.parts_count(gate_id)
		var row_percent: int = 0 if row_required <= 0 else int(round(float(row_current) / float(row_required) * 100.0))
		(row["name"] as Label).text = GateData.display_name(gate_id)
		(row["parts"] as Label).text = "%d / %d  (%%%d)" % [row_current, row_required, row_percent]
		var status: String = GalaxyGateManager.status_text(gate_id)
		(row["status"] as Label).text = status
		match status:
			"COMPLETED":
				(row["status"] as Label).add_theme_color_override("font_color", Color(0.4, 1.0, 0.55))
			"ACTIVE":
				(row["status"] as Label).add_theme_color_override("font_color", Color(1.0, 0.8, 0.35))
			"READY":
				(row["status"] as Label).add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
			_:
				(row["status"] as Label).add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		(row["select"] as Button).disabled = gate_id == selected
		(row["materialize"] as Button).disabled = GalaxyGateManager.is_completed(gate_id)

	# Cevir butonlari: mevcut Extra Energy + PLT ile karsilanamayan adim kapali.
	var available_spins: int = GalaxyGateManager.extra_energy()
	available_spins += int(int(GlobalState.platinum) / maxi(GateData.MATERIALIZER_PLT_COST, 1))
	for spins_key in _spin_buttons.keys():
		var spin_button: Button = _spin_buttons[spins_key]
		spin_button.disabled = completed or int(spins_key) > available_spins

	if _info_label != null and _info_label.text.is_empty():
		_info_label.text = "ÇEVİR butonlarıyla materializer kullanılır; sonuçlar \"SON KAZANÇLAR\" listesine düşer."
	_refresh_winnings()


func _on_select_pressed(gate_id: String) -> void:
	GalaxyGateManager.set_selected_gate_id(gate_id)
	refresh()


func _on_materialize_pressed(gate_id: String) -> void:
	# Kapi durumu listesindeki hizli kullanim: o kapiyi secip 1 cevir yapar.
	GalaxyGateManager.set_selected_gate_id(gate_id)
	_on_spin_pressed(1)


func _on_activate_pressed(gate_id: String) -> void:
	var result: Dictionary = GalaxyGateManager.activate_gate(gate_id)
	refresh()
	_show_result(str(result.get("message", "")))
	print("GALAXY_GATE_ACTIVATE gate=", gate_id, " ok=", str(result.get("ok", false)), " ", str(result.get("message", "")))


func _on_enter_pressed(gate_id: String) -> void:
	var key: String = str(gate_id).strip_edges().to_lower()
	if key.is_empty():
		key = GalaxyGateManager.selected_gate_id()
	_enter_gate(key)


func _on_enter_selected_pressed() -> void:
	_on_enter_pressed(GalaxyGateManager.selected_gate_id())


func _on_activate_selected_pressed() -> void:
	_on_activate_pressed(GalaxyGateManager.selected_gate_id())


func _on_spin_pressed(spins: int) -> void:
	# Kullanim adimi: Extra Energy varsa once o, kalan PLT; her spin sonuc uretir.
	var gate_id: String = GalaxyGateManager.selected_gate_id()
	if gate_id.is_empty():
		return
	var result: Dictionary = GalaxyGateManager.materialize(gate_id, spins)
	if not bool(result.get("ok", false)):
		_show_result(str(result.get("message", "")))
		refresh()
		return
	var rewards = result.get("results", [])
	if rewards is Array:
		for reward_text in (rewards as Array):
			_push_winning(str(reward_text))
	var summary := "%d ÇEVİR • +%d kapı parçası • %s PLT" % [
		int(result.get("spins", spins)),
		int(result.get("parts_gained", 0)),
		_format_number(int(result.get("plt_cost", 0)))
	]
	var ee_used: int = int(result.get("ee_used", 0))
	if ee_used > 0:
		summary += " • %d Extra Energy kullanıldı" % ee_used
	_show_result(summary)
	print("GALAXY_GATE_MATERIALIZE gate=", gate_id, " spins=", spins,
		" plt=", int(result.get("plt_cost", 0)), " ee=", ee_used)
	refresh()


func _enter_gate(gate_id: String) -> void:
	# KAPI HAZIR ise once mevcut aktivasyon, sonra mevcut arena gecisi kullanilir.
	var key: String = str(gate_id).strip_edges().to_lower()
	if key.is_empty():
		return
	if not GalaxyGateManager.is_active(key):
		if not GalaxyGateManager.parts_complete(key):
			_show_result("%s için parçalar tamamlanmadı. Gereken: %d" % [
				GateData.display_name(key),
				GateData.required_parts(key)
			])
			refresh()
			return
		var activation: Dictionary = GalaxyGateManager.activate_gate(key)
		if not bool(activation.get("ok", false)) or not GalaxyGateManager.is_active(key):
			_show_result(str(activation.get("message", "Kapı aktif edilemedi.")))
			refresh()
			return
	var start_result: Dictionary = GalaxyGateManager.start_run(key)
	if not bool(start_result.get("ok", false)):
		_show_result(str(start_result.get("message", "Kapıya girilemedi.")))
		refresh()
		return
	close()
	gate_entered.emit(key)


func _multiplier_for(gate_id: String) -> int:
	# Multiplier, ayni parcanin tekrar kazanilmasindan gelir: x2 ... x6.
	var state: Dictionary = GalaxyGateManager.state_for(gate_id)
	if state.is_empty():
		return 1
	var counts = state.get("duplicate_counts", {})
	var highest: int = 0
	if counts is Dictionary:
		for key in (counts as Dictionary).keys():
			highest = maxi(highest, int((counts as Dictionary)[key]))
	if highest <= 0:
		return 1
	return GateData.duplicate_multiplier(highest)


func _format_number(value: int) -> String:
	var number_value := int(value)
	var digits := str(absi(number_value))
	var out := ""
	var count := 0
	for index in range(digits.length() - 1, -1, -1):
		out = digits[index] + out
		count += 1
		if count % 3 == 0 and index > 0:
			out = "." + out
	return ("-" if number_value < 0 else "") + out


func _push_winning(text_value: String) -> void:
	var text: String = str(text_value).strip_edges()
	if text.is_empty():
		return
	_last_winnings.push_front(text)
	while _last_winnings.size() > MAX_WINNING_LINES:
		_last_winnings.pop_back()
	_refresh_winnings()


func _refresh_winnings() -> void:
	if _winnings_box == null:
		return
	for child in _winnings_box.get_children():
		child.free()
	if _last_winnings.is_empty():
		var empty := Label.new()
		empty.text = "Henüz kazanım yok. ÇEVİR butonlarıyla materializer kullan."
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", ACCENT_DIM)
		_winnings_box.add_child(empty)
		return
	for index in range(_last_winnings.size()):
		var label := Label.new()
		label.text = _last_winnings[index]
		label.add_theme_font_size_override("font_size", 15)
		label.add_theme_color_override("font_color", GOLD if index == 0 else ACCENT_DIM)
		_winnings_box.add_child(label)


func _show_result(text_value: String) -> void:
	if _info_label == null or text_value.is_empty():
		return
	_info_label.text = text_value


func _unhandled_input(event: InputEvent) -> void:
	if _overlay == null or not _overlay.visible:
		return
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if key_event.pressed and not key_event.echo and key_event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
