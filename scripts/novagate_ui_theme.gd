extends RefCounted
class_name NovaGateUITheme
## Ortak NovaGate sci-fi theme helper (FAZ 1).
## Sadece görsel StyleBox üretiyor, gameplay'e dokunmuyor.
## Style'lar cache'lenir; her slot için yeni StyleBox üretilmez.

const BG_DARK := Color(0.019, 0.051, 0.078, 1.0) # #050D14
const PANEL_FILL := Color(0.03, 0.07, 0.11, 0.96)
const PANEL_FILL_HOVER := Color(0.05, 0.12, 0.18, 0.98)
const PANEL_FILL_SELECTED := Color(0.06, 0.16, 0.23, 1.0)
const PRIMARY := Color(0.25, 0.9, 1.0, 1.0)
const SECONDARY := Color(0.08, 0.48, 0.64, 1.0)
const GOLD := Color(1.0, 0.82, 0.35, 1.0)
const GREEN := Color(0.3, 1.0, 0.55, 1.0)
const RED := Color(1.0, 0.35, 0.35, 1.0)
const DIM := Color(0.45, 0.55, 0.62, 1.0)
const SLOT_EMPTY_FILL := Color(0.02, 0.05, 0.08, 0.95)
const SLOT_FILLED_FILL := Color(0.04, 0.10, 0.15, 0.98)

static var _cache := {}

static func _key(base: String, border: Color, bw: int, radius: int) -> String:
	return "%s|%s|%d|%d" % [base, border.to_html(), bw, radius]

static func _flat(fill: Color, border: Color, bw: int, radius: int = 5) -> StyleBoxFlat:
	var k := _key(fill.to_html(), border, bw, radius)
	if _cache.has(k):
		return _cache[k] as StyleBoxFlat
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = border
	s.set_border_width_all(bw)
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	s.content_margin_left = 7
	s.content_margin_right = 7
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	_cache[k] = s
	return s

static func panel() -> StyleBoxFlat:
	return _flat(PANEL_FILL, Color(SECONDARY, 0.9), 1)

static func panel_hover() -> StyleBoxFlat:
	return _flat(PANEL_FILL_HOVER, PRIMARY, 1)

static func panel_selected() -> StyleBoxFlat:
	return _flat(PANEL_FILL_SELECTED, PRIMARY, 2)

static func button() -> StyleBoxFlat:
	return _flat(Color(0.035, 0.08, 0.115, 0.98), Color(SECONDARY, 0.95), 1)

static func button_hover() -> StyleBoxFlat:
	return _flat(PANEL_FILL_HOVER, PRIMARY, 1)

static func button_pressed() -> StyleBoxFlat:
	return _flat(Color(0.08, 0.20, 0.27, 1.0), GOLD, 1)

static func button_disabled() -> StyleBoxFlat:
	return _flat(Color(0.05, 0.06, 0.08, 0.9), Color(0.25, 0.30, 0.35, 0.6), 1)

static func item_card() -> StyleBoxFlat:
	return _flat(PANEL_FILL, Color(SECONDARY, 0.85), 1, 6)

static func item_card_selected() -> StyleBoxFlat:
	return _flat(PANEL_FILL_SELECTED, PRIMARY, 2, 6)

static func item_card_owned() -> StyleBoxFlat:
	return _flat(PANEL_FILL, Color(GREEN, 0.7), 1, 6)

static func slot_empty() -> StyleBoxFlat:
	return _flat(SLOT_EMPTY_FILL, Color(SECONDARY, 0.6), 1, 4)

static func slot_filled() -> StyleBoxFlat:
	return _flat(SLOT_FILLED_FILL, Color(SECONDARY, 0.9), 1, 4)

static func slot_selected() -> StyleBoxFlat:
	return _flat(PANEL_FILL_SELECTED, PRIMARY, 2, 4)

static func skill_locked() -> StyleBoxFlat:
	return _flat(Color(0.02, 0.03, 0.05, 0.95), Color(0.25, 0.30, 0.35, 0.5), 1, 8)

static func skill_available() -> StyleBoxFlat:
	return _flat(PANEL_FILL, Color(SECONDARY, 0.9), 1, 8)

static func skill_upgradeable() -> StyleBoxFlat:
	return _flat(PANEL_FILL_SELECTED, PRIMARY, 2, 8)

static func skill_maxed() -> StyleBoxFlat:
	return _flat(PANEL_FILL, Color(GOLD, 0.9), 2, 8)

static func apply_button(b: Button) -> void:
	b.add_theme_stylebox_override("normal", button())
	b.add_theme_stylebox_override("hover", button_hover())
	b.add_theme_stylebox_override("pressed", button_pressed())
	b.add_theme_stylebox_override("disabled", button_disabled())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", DIM)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

static func apply_card(p: PanelContainer, owned: bool = false, selected: bool = false) -> void:
	if selected:
		p.add_theme_stylebox_override("panel", item_card_selected())
	elif owned:
		p.add_theme_stylebox_override("panel", item_card_owned())
	else:
		p.add_theme_stylebox_override("panel", item_card())

static func title_label(l: Label, size: int = 16, color: Color = PRIMARY) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)

static func dim_label(l: Label, size: int = 12) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", DIM)

static func price_label(l: Label, size: int = 13, affordable: bool = true) -> void:
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", GOLD if affordable else RED)
