extends Control
class_name NovaGateSettingsScreen
# ==========================================================================
# NOVAGATE SETTINGS SCREEN (BOLUM 15-24)
# Mevcut SettingsManager autoload uzerinden calisir; ekstra save sistemi
# YAZILMAZ. Account bolumu mevcut account_manager.gd change_nickname /
# change_password fonksiyonlarini kullanir.
# ==========================================================================

const AccountManagerScript := preload("res://scripts/account_manager.gd")

const GRAPHIC_QUALITIES: Array[String] = ["low", "medium", "high", "ultra"]
const GRAPHIC_QUALITY_LABELS: Array[String] = ["Low", "Medium", "High", "Ultra"]
const MAP_SCALES: Array[float] = [0.25, 0.5, 0.75, 1.0, 1.25]
const MAP_SCALE_LABELS: Array[String] = ["%25", "%50", "%75", "%100", "%125"]
const FPS_VALUES: Array[int] = [30, 60, 120, 0]
const FPS_LABELS: Array[String] = ["30", "60", "120", "Unlimited"]

const CONTROL_ACTIONS: Array[String] = [
	"move_forward", "move_back", "move_left", "move_right",
	"fire", "laser", "rocket", "config", "gate", "minimap", "menu"
]
const CONTROL_ACTION_LABELS: Array[String] = [
	"Movement (Forward)", "Movement (Back)", "Movement (Left)", "Movement (Right)",
	"Attack", "Laser", "Rocket", "Config Switch", "Gate Jump", "Minimap", "Menu"
]

var _content: Control = null
var _status_label: Label = null
var _rebind_action: String = ""
var _rebind_prompt: Label = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	_show_tab("GENERAL")


func _build() -> void:
	var tab_row := HBoxContainer.new()
	tab_row.name = "SettingsTabs"
	tab_row.add_theme_constant_override("separation", 8)
	tab_row.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	tab_row.offset_top = 6.0
	tab_row.offset_bottom = 42.0
	add_child(tab_row)

	for tab_name in ["GENERAL", "GRAPHICS", "AUDIO", "CONTROLS", "LANGUAGE", "ACCOUNT"]:
		var button := Button.new()
		button.name = "Tab_%s" % tab_name
		button.text = tab_name
		button.custom_minimum_size = Vector2(120.0, 32.0)
		button.add_theme_font_size_override("font_size", 15)
		button.pressed.connect(_show_tab.bind(tab_name))
		tab_row.add_child(button)

	_content = VBoxContainer.new()
	_content.name = "SettingsContent"
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.offset_top = 50.0
	_content.offset_bottom = -46.0
	_content.offset_left = 6.0
	_content.offset_right = -6.0
	_content.add_theme_constant_override("separation", 8)
	add_child(_content)

	_status_label = Label.new()
	_status_label.name = "SettingsStatus"
	_status_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_status_label.offset_left = 8.0
	_status_label.offset_top = -38.0
	_status_label.offset_right = -8.0
	_status_label.offset_bottom = -10.0
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(0.45, 0.95, 1.0))
	add_child(_status_label)


func _clear_content() -> void:
	if _content == null:
		return
	for child in _content.get_children():
		child.queue_free()
	_rebind_action = ""
	_rebind_prompt = null


func _show_tab(tab_name: String) -> void:
	_clear_content()
	if _content == null:
		return
	match tab_name:
		"GENERAL":
			_build_general_tab()
		"GRAPHICS":
			_build_graphics_tab()
		"AUDIO":
			_build_audio_tab()
		"CONTROLS":
			_build_controls_tab()
		"LANGUAGE":
			_build_language_tab()
		"ACCOUNT":
			_build_account_tab()
		_:
			pass


func _set_status(text_value: String) -> void:
	if _status_label != null:
		_status_label.text = text_value


# --------------------------------------------------------------------------
# GENEL (BOLUM 15)
# --------------------------------------------------------------------------
func _build_general_tab() -> void:
	_add_header("GENEL AYARLAR")
	_add_checkbox("Ses (Sound)", "audio", "sound", true)
	_add_checkbox("Müzik (Music)", "audio", "music", true)
	_add_checkbox("SFX", "audio", "sfx", true)
	_add_checkbox("Hasar Göster (Show Damage)", "gameplay", "show_damage", true)
	_add_checkbox("NPC İsimleri", "gameplay", "show_npc_names", true)
	_add_checkbox("Oyuncu İsimleri", "gameplay", "show_player_names", true)
	_add_checkbox("Koordinatlar", "gameplay", "show_coordinates", true)
	_add_checkbox("Minimap Göster", "gameplay", "show_minimap", true)
	_add_option("Minimap Ölçek", "gameplay", "minimap_scale",
		[0.75, 1.0, 1.25], ["%75", "%100", "%125"], 1.0)


# --------------------------------------------------------------------------
# GRAPHICS (BOLUM 21)
# --------------------------------------------------------------------------
func _build_graphics_tab() -> void:
	_add_header("GÖRÜNTÜ")
	_add_option("Graphics Quality", "graphics", "quality",
		GRAPHIC_QUALITIES, GRAPHIC_QUALITY_LABELS, "high")
	_add_option("Map Object Scale", "graphics", "map_scale",
		MAP_SCALES, MAP_SCALE_LABELS, 1.0)
	_add_option("FPS Limit", "graphics", "fps_limit",
		FPS_VALUES, FPS_LABELS, 60)
	_add_checkbox("Fullscreen", "graphics", "fullscreen", false)
	_add_checkbox("VSync", "graphics", "vsync", true)


# --------------------------------------------------------------------------
# AUDIO
# --------------------------------------------------------------------------
func _build_audio_tab() -> void:
	_add_header("SES")
	_add_slider("Master Volume", "audio", "master_volume", 1.0)
	_add_slider("Music Volume", "audio", "music_volume", 0.9)
	_add_slider("Effects Volume", "audio", "effects_volume", 0.9)
	_add_slider("UI Volume", "audio", "ui_volume", 0.8)



# --------------------------------------------------------------------------
# CONTROLS (BOLUM 16) - mevcut SettingsManager PC keybind sistemi
# --------------------------------------------------------------------------
func _build_controls_tab() -> void:
	_add_header("KONTROLLER (PC)")
	_add_info_label("Değiştirmek istediğin eylemin [DĞŞ] butonuna bas, sonra yeni tuşa bas.")
	_rebind_prompt = _add_info_label("")
	var defaults := {
		"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A,
		"move_right": KEY_D, "fire": KEY_SPACE, "laser": KEY_Q,
		"rocket": KEY_E, "config": KEY_C, "gate": KEY_G,
		"minimap": KEY_M, "menu": KEY_ESCAPE
	}
	for index in range(CONTROL_ACTIONS.size()):
		var action: String = CONTROL_ACTIONS[index]
		var current: int = int(SettingsManager.get_setting("controls", action, int(defaults.get(action, 0))))
		_add_control_row(CONTROL_ACTION_LABELS[index], action, current)


func _add_control_row(label_text: String, action: String, keycode: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var caption := Label.new()
	caption.text = label_text
	caption.custom_minimum_size = Vector2(210.0, 0.0)
	caption.add_theme_font_size_override("font_size", 15)
	row.add_child(caption)
	var key_label := Label.new()
	key_label.text = OS.get_keycode_string(keycode)
	key_label.custom_minimum_size = Vector2(110.0, 0.0)
	key_label.add_theme_font_size_override("font_size", 15)
	key_label.add_theme_color_override("font_color", Color(0.4, 0.95, 1.0))
	row.add_child(key_label)
	var bind_button := Button.new()
	bind_button.text = "DĞŞ"
	bind_button.custom_minimum_size = Vector2(70.0, 28.0)
	bind_button.pressed.connect(_begin_rebind.bind(action, bind_button))
	row.add_child(bind_button)
	_content.add_child(row)


func _begin_rebind(action: String, button: Button) -> void:
	_rebind_action = action
	button.disabled = true
	if _rebind_prompt != null:
		_rebind_prompt.text = "%s icin yeni tusu bekleniyor..." % action
		_rebind_prompt.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))


func _unhandled_key_input(event: InputEvent) -> void:
	if _rebind_action.is_empty() or not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	SettingsManager.set_setting("controls", _rebind_action, key_event.keycode)
	_set_status("%s -> %s kaydedildi." % [_rebind_action, OS.get_keycode_string(key_event.keycode)])
	_show_tab("CONTROLS")
	get_viewport().set_input_as_handled()


# --------------------------------------------------------------------------
# LANGUAGE (BOLUM 20)
# --------------------------------------------------------------------------
func _build_language_tab() -> void:
	_add_header("DİL / LANGUAGE")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var cap := Label.new()
	cap.text = "Language"
	cap.custom_minimum_size = Vector2(200.0, 0.0)
	cap.add_theme_font_size_override("font_size", 15)
	cap.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	row.add_child(cap)
	var option := OptionButton.new()
	option.add_item("Türkçe")
	option.add_item("English")
	var current_lang := SettingsManager.get_language()
	option.selected = 0 if current_lang == "tr" else 1
	option.custom_minimum_size = Vector2(180.0, 30.0)
	option.item_selected.connect(func(index: int) -> void:
		var lang := "tr" if index == 0 else "en"
		SettingsManager.set_language(lang)
		_set_status("Dil değiştirildi: %s" % ("Türkçe" if lang == "tr" else "English"))
	)
	row.add_child(option)
	_content.add_child(row)
	_add_info_label("Not: Dil altyapisi hazirdir; metin ceviri tablosu sonraki adimda devreye girebilir.")



# --------------------------------------------------------------------------
# ACCOUNT (BOLUM 17-19)
# --------------------------------------------------------------------------
func _build_account_tab() -> void:
	_add_header("HESAP")

	# KULLANICI ADI DEGISTIR: mevcut AccountManager hesap degistirme akisi
	# kullanilir; yeni bir authentication sistemi kurulmaz.
	_add_header("KULLANICI ADI DEĞİŞTİR")
	var nick_edit := LineEdit.new()
	nick_edit.name = "NicknameEdit"
	nick_edit.placeholder_text = "Yeni kullanıcı adı"
	nick_edit.max_length = 20
	nick_edit.custom_minimum_size = Vector2(320.0, 0.0)
	_content.add_child(nick_edit)
	var nick_button := Button.new()
	nick_button.text = "KULLANICI ADINI DEĞİŞTİR"
	nick_button.custom_minimum_size = Vector2(260.0, 34.0)
	nick_button.pressed.connect(_on_change_nickname.bind(nick_edit))
	_content.add_child(nick_button)

	_add_header("ŞİFRE DEĞİŞTİR")
	var current_edit := LineEdit.new()
	current_edit.name = "CurrentPasswordEdit"
	current_edit.placeholder_text = "Mevcut şifre"
	current_edit.secret = true
	_content.add_child(current_edit)
	var new_edit := LineEdit.new()
	new_edit.name = "NewPasswordEdit"
	new_edit.placeholder_text = "Yeni şifre (min 6 karakter)"
	new_edit.secret = true
	_content.add_child(new_edit)
	var confirm_edit := LineEdit.new()
	confirm_edit.name = "ConfirmPasswordEdit"
	confirm_edit.placeholder_text = "Yeni şifre (tekrar)"
	confirm_edit.secret = true
	_content.add_child(confirm_edit)
	var pass_button := Button.new()
	pass_button.text = "ŞİFREYİ DEĞİŞTİR"
	pass_button.custom_minimum_size = Vector2(220.0, 34.0)
	pass_button.pressed.connect(_on_change_password.bind(current_edit, new_edit, confirm_edit))
	_content.add_child(pass_button)


func _on_change_nickname(edit: LineEdit) -> void:
	var account_manager = AccountManagerScript.new()
	var result: Dictionary = account_manager.call(
		"change_nickname", GlobalState.username, str(edit.text.strip_edges()))
	account_manager.free()
	_set_status(str(result.get("message", "")))
	if bool(result.get("ok", false)):
		edit.text = ""
		_show_tab("ACCOUNT")


func _on_change_password(current_edit: LineEdit, new_edit: LineEdit, confirm_edit: LineEdit) -> void:
	var account_manager = AccountManagerScript.new()
	var result: Dictionary = account_manager.call(
		"change_password",
		GlobalState.username,
		str(current_edit.text),
		str(new_edit.text),
		str(confirm_edit.text))
	account_manager.free()
	_set_status(str(result.get("message", "")))
	if bool(result.get("ok", false)):
		current_edit.text = ""
		new_edit.text = ""
		confirm_edit.text = ""


# --------------------------------------------------------------------------
# UI YARDIMCILARI
# --------------------------------------------------------------------------
func _add_header(text_value: String) -> void:
	var header := Label.new()
	header.text = text_value
	header.add_theme_font_size_override("font_size", 20)
	header.add_theme_color_override("font_color", Color(0.4, 0.95, 1.0))
	_content.add_child(header)


func _add_info_label(text_value: String) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95))
	_content.add_child(label)
	return label


func _add_info_line(caption: String, value: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var cap := Label.new()
	cap.text = caption
	cap.custom_minimum_size = Vector2(150.0, 0.0)
	cap.add_theme_font_size_override("font_size", 15)
	cap.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	row.add_child(cap)
	var val := Label.new()
	val.text = value
	val.add_theme_font_size_override("font_size", 15)
	row.add_child(val)
	_content.add_child(row)


func _add_checkbox(label_text: String, section: String, key: String, default_value: bool) -> void:
	var check := CheckBox.new()
	check.text = label_text
	check.button_pressed = bool(SettingsManager.get_setting(section, key, default_value))
	check.add_theme_font_size_override("font_size", 15)
	check.toggled.connect(func(pressed: bool) -> void:
		SettingsManager.set_setting(section, key, pressed)
		_set_status("%s kaydedildi." % label_text))
	_content.add_child(check)


func _add_option(label_text: String, section: String, key: String, values: Array, labels: Array, default_value) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var cap := Label.new()
	cap.text = label_text
	cap.custom_minimum_size = Vector2(200.0, 0.0)
	cap.add_theme_font_size_override("font_size", 15)
	row.add_child(cap)
	var option := OptionButton.new()
	var current_index: int = 0
	for index in range(values.size()):
		option.add_item(str(labels[index]))
		if _values_equal(values[index], SettingsManager.get_setting(section, key, default_value)):
			current_index = index
	option.selected = current_index
	option.custom_minimum_size = Vector2(180.0, 30.0)
	var values_ref: Array = values.duplicate()
	option.item_selected.connect(func(index: int) -> void:
		if key == "":
			SettingsManager.set_setting(section, "", values_ref[index])
		else:
			SettingsManager.set_setting(section, key, values_ref[index])
		_set_status("%s kaydedildi." % label_text))
	row.add_child(option)
	_content.add_child(row)


func _add_slider(label_text: String, section: String, key: String, default_value: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var cap := Label.new()
	cap.text = label_text
	cap.custom_minimum_size = Vector2(200.0, 0.0)
	cap.add_theme_font_size_override("font_size", 15)
	row.add_child(cap)
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = float(SettingsManager.get_setting(section, key, default_value))
	slider.custom_minimum_size = Vector2(260.0, 24.0)
	row.add_child(slider)
	var value_label := Label.new()
	value_label.text = "%d%%" % int(round(slider.value * 100.0))
	value_label.add_theme_font_size_override("font_size", 14)
	row.add_child(value_label)
	slider.value_changed.connect(func(value: float) -> void:
		value_label.text = "%d%%" % int(round(value * 100.0))
		SettingsManager.set_setting(section, key, value))
	_content.add_child(row)


func _values_equal(a, b) -> bool:
	if a is float or b is float:
		return absf(float(a) - float(b)) < 0.001
	return a == b
