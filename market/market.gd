# NovaGate Market UI Phase 2

extends Control

var ships: Array = []
var current_category: String = "GEMİLER"
var selected_item: Dictionary = {}
var market_operation_in_progress: bool = false

var title_label: Label
var category_box: VBoxContainer
var detail_title: Label
var detail_image: TextureRect
var detail_info: Label
var detail_price: Label
var buy_button: Button
var ammo_package_box: HBoxContainer
var item_strip: HBoxContainer
var item_scroll: ScrollContainer
var embedded_mode: bool = false
# --- NovaGate PRO Market UI state (sadece görsel) ---
var category_buttons: Dictionary = {}
var item_cards: Dictionary = {}
var wallet_btc_label: Label
var wallet_plt_label: Label
var detail_stat_box: VBoxContainer
var detail_badge: Label
var detail_accent: ColorRect

# DROİD MARKET DURUMU
# Plus = 1 slot / BTC
# Zeus = 2 slot / PLT
# Toplam en fazla 8 droid satın alınabilir.
var plus_droid_count: int = 0
var zeus_droid_count: int = 0
const MAX_DROID_COUNT := 8
const PLUS_DROID_PRICES := [100000, 200000, 400000, 800000, 1600000, 3200000, 6400000, 12800000]
const ZEUS_DROID_PRICES := [12000, 20000, 35000, 60000, 100000, 170000, 300000, 500000]

func set_embedded_mode(value: bool) -> void:
	embedded_mode = value

func _begin_market_purchase() -> bool:
	if market_operation_in_progress:
		return false
	market_operation_in_progress = true
	if buy_button != null:
		buy_button.disabled = true
		buy_button.text = "SATIN ALINIYOR..."
	return true

func _end_market_purchase() -> void:
	market_operation_in_progress = false
	if buy_button != null:
		buy_button.disabled = false
		buy_button.text = "SATIN AL"

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not embedded_mode:
		add_to_group("market_overlay")
	_apply_viewport_size()
	if not embedded_mode:
		get_viewport().size_changed.connect(_apply_viewport_size)
	print("=== NOVAGATE MARKET MENÜ ENTEGRASYONU HAZIR ===")
	_load_droid_market_state()
	_load_ships()
	_build_ui()
	_open_category("GEMİLER")


func _apply_viewport_size() -> void:
	position = Vector2.ZERO
	if embedded_mode and get_parent() is Control:
		custom_minimum_size = Vector2.ZERO
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		size = get_viewport_rect().size
		custom_minimum_size = get_viewport_rect().size


func _build_ui() -> void:
	# Bu sürüm arayüzü tamamen koddan kurar; eski tscn düğümlerine bağlı değildir.
	for child in get_children():
		remove_child(child)
		child.queue_free()

	# Parent Node2D olabileceği için anchor tek başına yeterli değil.
	_apply_viewport_size()
	mouse_filter = Control.MOUSE_FILTER_STOP

	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.004, 0.01, 0.017, 0.99)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(background)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 4 if embedded_mode else 24
	panel.offset_top = 2 if embedded_mode else 20
	panel.offset_right = -4 if embedded_mode else -24
	panel.offset_bottom = -2 if embedded_mode else -20
	panel.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
	background.add_child(panel)

	var root_box := VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 8)
	panel.add_child(root_box)

	# Üst bar (PRO header: geri + başlık + cüzdan)
	var header := HBoxContainer.new()
	header.custom_minimum_size = Vector2(0, 52)
	header.add_theme_constant_override("separation", 10)
	root_box.add_child(header)

	if not embedded_mode:
		var menu_button := Button.new()
		menu_button.text = "← MENÜ"
		menu_button.custom_minimum_size = Vector2(130, 44)
		NovaGateUITheme.apply_button(menu_button)
		menu_button.pressed.connect(_on_menu_pressed)
		header.add_child(menu_button)

	title_label = Label.new()
	title_label.text = "NOVA GATE • MARKET"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	NovaGateUITheme.title_label(title_label, 22, NovaGateUITheme.PRIMARY)
	header.add_child(title_label)

	# Sağ cüzdan bloğu — mevcut GlobalState değerleri, yeni para sistemi yok.
	var wallet := HBoxContainer.new()
	wallet.add_theme_constant_override("separation", 8)
	header.add_child(wallet)
	wallet_btc_label = _market_wallet_chip(wallet, "BTC")
	wallet_plt_label = _market_wallet_chip(wallet, "PLT")
	_refresh_wallet_labels()

	if not embedded_mode:
		var close_button := Button.new()
		close_button.text = "X"
		close_button.custom_minimum_size = Vector2(52, 44)
		NovaGateUITheme.apply_button(close_button)
		close_button.pressed.connect(_on_close_pressed)
		header.add_child(close_button)

	var header_accent := ColorRect.new()
	header_accent.custom_minimum_size = Vector2(0, 2)
	header_accent.color = Color(NovaGateUITheme.SECONDARY, 0.9)
	root_box.add_child(header_accent)

	# Sol kategoriler + orta detay
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	root_box.add_child(body)

	var category_scroll := ScrollContainer.new()
	category_scroll.name = "CategoryScroll"
	category_scroll.custom_minimum_size = Vector2(220, 0)
	category_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	category_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(category_scroll)

	category_box = VBoxContainer.new()
	category_box.custom_minimum_size = Vector2(200, 0)
	category_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	category_box.add_theme_constant_override("separation", 8)
	category_scroll.add_child(category_box)

	var content_scroll := ScrollContainer.new()
	content_scroll.name = "ContentScroll"
	content_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(content_scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	content_scroll.add_child(content)

	# Seçili ürün detayı (PRO: büyük görsel + stat kartları + rozet)
	var detail_panel := PanelContainer.new()
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail_panel.add_theme_stylebox_override("panel", NovaGateUITheme.panel())
	content.add_child(detail_panel)

	var detail_box := VBoxContainer.new()
	detail_box.alignment = BoxContainer.ALIGNMENT_CENTER
	detail_box.add_theme_constant_override("separation", 10)
	detail_panel.add_child(detail_box)

	detail_accent = ColorRect.new()
	detail_accent.custom_minimum_size = Vector2(0, 3)
	detail_accent.color = Color(NovaGateUITheme.PRIMARY, 0.9)
	detail_box.add_child(detail_accent)

	detail_badge = Label.new()
	detail_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	NovaGateUITheme.dim_label(detail_badge, 12)
	detail_badge.text = ""
	detail_box.add_child(detail_badge)

	detail_title = Label.new()
	detail_title.text = "ÜRÜN SEÇ"
	detail_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	NovaGateUITheme.title_label(detail_title, 26, Color.WHITE)
	detail_box.add_child(detail_title)

	detail_image = TextureRect.new()
	detail_image.custom_minimum_size = Vector2(0, 90)
	detail_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	detail_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	detail_box.add_child(detail_image)

	detail_stat_box = VBoxContainer.new()
	detail_stat_box.alignment = BoxContainer.ALIGNMENT_CENTER
	detail_stat_box.add_theme_constant_override("separation", 4)
	detail_box.add_child(detail_stat_box)

	detail_info = Label.new()
	detail_info.custom_minimum_size = Vector2(0, 44)
	detail_info.text = "Alttaki listeden bir ürün seç."
	detail_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail_info.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	detail_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	NovaGateUITheme.dim_label(detail_info, 14)
	detail_box.add_child(detail_info)

	detail_price = Label.new()
	detail_price.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	NovaGateUITheme.price_label(detail_price, 20, true)
	detail_box.add_child(detail_price)

	# Cephane seçildiğinde sadece üç paket burada görünür.
	ammo_package_box = HBoxContainer.new()
	ammo_package_box.alignment = BoxContainer.ALIGNMENT_CENTER
	ammo_package_box.add_theme_constant_override("separation", 12)
	ammo_package_box.visible = false
	detail_box.add_child(ammo_package_box)

	buy_button = Button.new()
	buy_button.text = "SATIN AL"
	buy_button.custom_minimum_size = Vector2(240, 44)
	buy_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	buy_button.disabled = true
	NovaGateUITheme.apply_button(buy_button)
	buy_button.add_theme_font_size_override("font_size", 16)
	buy_button.pressed.connect(_on_buy_pressed)
	detail_box.add_child(buy_button)

	# Ürün/gemi listesi ALTTA YAN YANA (PRO carousel)
	var carousel_title := Label.new()
	carousel_title.text = "ÜRÜNLER"
	NovaGateUITheme.dim_label(carousel_title, 12)
	content.add_child(carousel_title)

	item_scroll = ScrollContainer.new()
	item_scroll.custom_minimum_size = Vector2(0, 132)
	item_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	item_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(item_scroll)

	item_strip = HBoxContainer.new()
	item_strip.add_theme_constant_override("separation", 10)
	item_strip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	item_scroll.add_child(item_strip)

	_build_category_buttons()


func _market_wallet_chip(parent: Control, currency: String) -> Label:
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", NovaGateUITheme.item_card())
	parent.add_child(chip)
	var l := Label.new()
	l.custom_minimum_size = Vector2(150, 40)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	NovaGateUITheme.price_label(l, 15, true)
	chip.add_child(l)
	l.set_meta("ng_currency", currency)
	return l


func _refresh_wallet_labels() -> void:
	# Canlı GlobalState bakiyeleri; yeni para sistemi yok.
	if wallet_btc_label != null:
		wallet_btc_label.text = "◈ %s BTC" % _fmt_number(GlobalState.bitcoin)
	if wallet_plt_label != null:
		wallet_plt_label.text = "⬢ %s PLT" % _fmt_number(GlobalState.platinum)


func _market_category_icon(category_name: String) -> Texture2D:
	# Mevcut asset varsa kullan, yoksa null -> text fallback.
	var candidates: Array = []
	match category_name:
		"GEMİLER":
			candidates = ["res://assets/gemiship/previews/ship10.png", "res://assets/gemiship/ship10.png"]
		"LAZERLER":
			candidates = ["res://assets/equipment/lf3.png", "res://assets/equipment/lf2.png"]
		"JENERATÖRLER":
			candidates = ["res://assets/equipment/kalkan2.png", "res://assets/equipment/hiz2.png"]
		"EKSTRALAR":
			candidates = ["res://market/assets/boosters/DMG-B01.png"]
		"DROİDLER":
			candidates = ["res://assets/droids/plus_droid.png", "res://assets/droids/zeus_droid.png"]
		"CEPHANE":
			candidates = ["res://assets/ammo/x1.png", "res://assets/rocket1icon.png"]
	for p in candidates:
		if ResourceLoader.exists(str(p)):
			return load(str(p)) as Texture2D
	return null


func _market_item_icon(item: Dictionary) -> Texture2D:
	var t := str(item.get("type", ""))
	var n := str(item.get("name", ""))
	var paths: Array = []
	if t == "ship":
		var prev := str(item.get("preview", ""))
		if prev != "":
			paths.append(prev)
		var raw = item.get("raw", {})
		if raw is Dictionary:
			if str(raw.get("image", "")) != "":
				paths.append(str(raw.get("image")))
	if n == "LF1":
		paths.append("res://assets/equipment/lf1.png")
	elif n == "LF2":
		paths.append("res://assets/equipment/lf2.png")
	elif n == "LF3":
		paths.append("res://assets/equipment/lf3.png")
	elif n.begins_with("Kalkan"):
		paths.append("res://assets/equipment/kalkan2.png")
	elif n.begins_with("Hız") or n.begins_with("Hiz"):
		paths.append("res://assets/equipment/hiz2.png")
	if str(item.get("icon", "")) != "":
		paths.push_front(str(item.get("icon")))
	for p in paths:
		if ResourceLoader.exists(str(p)):
			return load(str(p)) as Texture2D
	return null


func _market_short_stat(item: Dictionary) -> String:
	var info := str(item.get("info", ""))
	if info == "":
		return ""
	var line := info.split("\n")[0]
	if line.length() > 26:
		line = line.substr(0, 26) + "…"
	return line


func _market_owned_state(item: Dictionary) -> String:
	if bool(item.get("disabled", false)):
		var dt := str(item.get("disabled_text", ""))
		return dt if dt != "" else "KULLANILAMAZ"
	if str(item.get("type", "")) in ["ammo_selector", "log_disk_selector"]:
		return "SEÇ"
	return ""


func _build_category_buttons() -> void:
	_clear_children(category_box)
	category_buttons.clear()
	# Mobilde yatay scroll: kategori listesi dar ekranda kayabilsin.
	category_box.custom_minimum_size = Vector2(200, 0)
	var categories := ["GEMİLER", "CEPHANE", "LAZERLER", "JENERATÖRLER", "EKSTRALAR", "DROİDLER"]
	for category_name in categories:
		var b := Button.new()
		b.text = category_name
		b.custom_minimum_size = Vector2(190, 56)
		b.add_theme_font_size_override("font_size", 15)
		b.toggle_mode = true
		b.button_pressed = category_name == current_category
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		NovaGateUITheme.apply_button(b)
		var icon := _market_category_icon(category_name)
		if icon != null:
			b.icon = icon
			b.expand_icon = true
		b.pressed.connect(_open_category.bind(category_name))
		category_box.add_child(b)
		category_buttons[category_name] = b
	_refresh_category_selected()


func _refresh_category_selected() -> void:
	for cat in category_buttons.keys():
		var b: Button = category_buttons[cat]
		var sel: bool = str(cat) == current_category
		b.button_pressed = sel
		if sel:
			b.add_theme_stylebox_override("normal", NovaGateUITheme.panel_selected())
			b.add_theme_stylebox_override("hover", NovaGateUITheme.panel_selected())
			b.add_theme_stylebox_override("pressed", NovaGateUITheme.button_pressed())
		else:
			b.add_theme_stylebox_override("normal", NovaGateUITheme.button())
			b.add_theme_stylebox_override("hover", NovaGateUITheme.button_hover())
			b.add_theme_stylebox_override("pressed", NovaGateUITheme.button_pressed())


func _open_category(category_name: String) -> void:
	print("MARKET KATEGORİSİ: ", category_name)
	current_category = category_name
	title_label.text = "NOVA GATE • MARKET • " + category_name
	_refresh_category_selected()
	_refresh_wallet_labels()
	_clear_children(item_strip)
	item_cards.clear()

	var items := _get_category_items(category_name)
	for item in items:
		_add_item_card(item)

	if items.size() > 0:
		_select_item(items[0])
	else:
		_clear_detail()


func _get_category_items(category_name: String) -> Array:
	match category_name:
		"GEMİLER":
			return _ship_items()
		"CEPHANE":
			return _ammo_market_items()
		"LAZERLER":
			return [
				{"name":"LF1", "info":"LAZER HASARI: 90", "price":"40.000 BTC", "type":"laser", "currency":"BTC", "amount":40000},
				{"name":"LF2", "info":"LAZER HASARI: 132", "price":"80.000 BTC", "type":"laser", "currency":"BTC", "amount":80000},
				{"name":"LF3", "info":"LAZER HASARI: 210", "price":"20.000 PLT", "type":"laser", "currency":"PLT", "amount":20000}
			]
		"JENERATÖRLER":
			return [
				{"name":"Kalkan 1", "info":"KALKAN BONUSU: +6.000", "price":"125.000 BTC", "type":"generator", "currency":"BTC", "amount":125000},
				{"name":"Kalkan 2", "info":"KALKAN BONUSU: +12.000", "price":"15.000 PLT", "type":"generator", "currency":"PLT", "amount":15000},
				{"name":"Hız 1", "info":"HIZ BONUSU: +8", "price":"125.000 BTC", "type":"generator", "currency":"BTC", "amount":125000},
				{"name":"Hız 2", "info":"HIZ BONUSU: +12", "price":"10.000 PLT", "type":"generator", "currency":"PLT", "amount":10000}
			]
		"EKSTRALAR":
			return [
				{"name":"DMG-B01", "info":"Hasar Booster +%20 | Süre: 3 Saat", "price":"15.000 PLT", "type":"extra"},
				{"name":"HP-B01", "info":"Can Booster +%20 | Süre: 3 Saat", "price":"15.000 PLT", "type":"extra"},
				{"name":"SHD-B01", "info":"Kalkan Booster +%20 | Süre: 3 Saat", "price":"15.000 PLT", "type":"extra"},
				{"name":"XP-B01", "info":"Deneyim Booster +%20 | Süre: 3 Saat", "price":"15.000 PLT", "type":"extra"},
				{"name":"HON-B01", "info":"Şeref Booster +%20 | Süre: 3 Saat", "price":"15.000 PLT", "type":"extra"},
				{"name":"LOG DİSK", "info":"Yetenek ağacı geliştirmeleri için Log Disk satın al.", "price":"", "type":"log_disk_selector",
				 "packages":[[1,300],[50,15000],[100,30000],[1000,300000]]}
			]
		"DROİDLER":
			return _build_droid_items()
	return []


func _ammo_market_items() -> Array:
	# Alttaki şeritte paketler değil yalnızca cephane TÜRLERİ görünür.
	# Tür seçildiğinde 3 satın alma paketi orta ekranda açılır.
	var packages := {
		"X1": [[1000, 4500, "BTC"], [10000, 45000, "BTC"], [100000, 450000, "BTC"]],
		"X2": [[1000, 450000, "BTC"], [10000, 4500000, "BTC"], [100000, 45000000, "BTC"]],
		"X3": [[1000, 900, "PLT"], [10000, 9000, "PLT"], [100000, 90000, "PLT"]],
		"X4": [[1000, 2700, "PLT"], [10000, 27000, "PLT"], [100000, 270000, "PLT"]],
		"SAB": [[1000, 500, "PLT"], [10000, 5000, "PLT"], [100000, 50000, "PLT"]],
		"RSB": [[1000, 4500, "PLT"], [10000, 45000, "PLT"], [100000, 450000, "PLT"]],
		"R1": [[50, 2250, "BTC"], [500, 22500, "BTC"], [5000, 225000, "BTC"]],
		"R2": [[50, 22500, "BTC"], [500, 225000, "BTC"], [5000, 2250000, "BTC"]],
		"R3": [[50, 225, "PLT"], [500, 2250, "PLT"], [5000, 22500, "PLT"]]
	}

	var result: Array = []
	for ammo_name in ["X1", "X2", "X3", "X4", "SAB", "RSB", "R1", "R2", "R3"]:
		var info := "Mevcut stok: %s" % _fmt_number(GlobalState.get_ammo_count(ammo_name))
		if ammo_name in ["R1", "R2", "R3"]:
			info += "\nRoket menzili: lazerden +10\nStok yoksa kullanılamaz."
		else:
			info += "\nHer salvo, aktif gemi+droid lazer sayısı kadar cephane tüketir."

		result.append({
			"name": ammo_name,
			"info": info,
			"price": "",
			"type": "ammo_selector",
			"ammo_name": ammo_name,
			"item_id": ammo_name,
			"packages": packages[ammo_name]
		})

	return result


func _ship_items() -> Array:
	var result: Array = []
	var account_manager = load("res://scripts/account_manager.gd").new()
	account_manager.ensure_starter_ship()
	var owned:Array = account_manager.get_owned_ships()

	for ship_value in ships:
		if not (ship_value is Dictionary):
			continue
		var ship:Dictionary = ship_value
		var ship_id := str(ship.get("id", ""))
		var ship_name := str(ship.get("name", ship_id))
		var hp_value := int(ship.get("hp", 0))
		var currency := str(ship.get("currency", "BTC"))
		var price_amount := int(ship.get("price", 0))
		var owned_now := owned.has(ship_id)

		var hp_text := _fmt_number(hp_value) if hp_value > 0 else "BELİRLENMEDİ"
		var info := "CAN: %s\nHIZ: %s\nLAZER YUVASI: %s\nJENERATÖR YUVASI: %s\nEKSTRA YUVASI: %s" % [
			hp_text,
			_fmt_number(ship.get("speed", 0)),
			ship.get("laser_slots", 0),
			ship.get("generator_slots", 0),
			ship.get("extra_slots", 0)
		]

		var price_text := "ÜCRETSİZ • BAŞLANGIÇ" if currency == "FREE" else "%s %s" % [_fmt_number(price_amount), currency]
		result.append({
			"name": ship_name,
			"info": info,
			"price": price_text,
			"type": "ship",
			"ship_id": ship_id,
			"item_id": ship_id,
			"currency": currency,
			"amount": price_amount,
			"preview": str(ship.get("preview", "")),
			"raw": ship,
			"owned": owned_now,
			"disabled": owned_now or hp_value <= 0,
			"disabled_text": "SAHİP" if owned_now else ("CAN DEĞERİ EKSİK" if hp_value <= 0 else "")
		})
	return result


func _build_droid_items() -> Array:
	var total_owned := plus_droid_count + zeus_droid_count
	var market_full := total_owned >= MAX_DROID_COUNT

	var plus_price_index := mini(plus_droid_count, PLUS_DROID_PRICES.size() - 1)
	var zeus_price_index := mini(zeus_droid_count, ZEUS_DROID_PRICES.size() - 1)

	var plus_price := int(PLUS_DROID_PRICES[plus_price_index])
	var zeus_price := int(ZEUS_DROID_PRICES[zeus_price_index])

	var plus_info := "TEK SLOTLU DROİD\n1 ekipman yuvası\nSahip olunan Plus: %d\nToplam droid: %d / %d" % [
		plus_droid_count,
		total_owned,
		MAX_DROID_COUNT
	]

	var zeus_info := "ÇİFT SLOTLU DROİD\n2 ekipman yuvası\nSahip olunan Zeus: %d\nToplam droid: %d / %d" % [
		zeus_droid_count,
		total_owned,
		MAX_DROID_COUNT
	]

	if market_full:
		plus_info += "\n\nMAKSİMUM 8 DROİD SINIRINA ULAŞILDI."
		zeus_info += "\n\nMAKSİMUM 8 DROİD SINIRINA ULAŞILDI."

	return [
		{
			"name":"PLUS",
			"info":plus_info,
			"price":"%s BTC" % _fmt_number(plus_price),
			"type":"droid_plus",
			"currency":"BTC",
			"amount":plus_price,
			"item_id":"PLUS",
			"disabled":market_full
		},
		{
			"name":"ZEUS",
			"info":zeus_info,
			"price":"%s PLT" % _fmt_number(zeus_price),
			"type":"droid_zeus",
			"currency":"PLT",
			"amount":zeus_price,
			"item_id":"ZEUS",
			"disabled":market_full
		}
	]


func _style_market_scrollbars() -> void:
	if item_scroll == null:
		return
	var hbar := item_scroll.get_h_scroll_bar()
	if hbar != null:
		hbar.add_theme_stylebox_override("scroll", NovaGateUITheme.slot_empty())
		hbar.add_theme_stylebox_override("grabber_area", NovaGateUITheme.panel())
		hbar.add_theme_stylebox_override("grabber_area_highlight", NovaGateUITheme.panel_hover())
		hbar.custom_minimum_size = Vector2(0, 10)
	var vbar := item_scroll.get_v_scroll_bar()
	if vbar != null:
		vbar.add_theme_stylebox_override("scroll", NovaGateUITheme.slot_empty())
		vbar.custom_minimum_size = Vector2(10, 0)


func _add_item_card(item: Dictionary) -> void:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(168, 124)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var owned_state := _market_owned_state(item)
	var owned_visual := owned_state in ["SAHİP", "AKTİF", "TAMAMLANDI"]
	NovaGateUITheme.apply_card(card, owned_visual, false)
	card.set_meta("ng_owned", owned_visual)
	card.set_meta("ng_item_name", str(item.get("name", "")))
	card.set_meta("ng_item_type", str(item.get("type", "")))
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	card.add_child(box)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(56, 40)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex := _market_item_icon(item)
	if tex != null:
		icon.texture = tex
	box.add_child(icon)
	var name_label := Label.new()
	name_label.text = str(item.get("name", "ÜRÜN"))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	NovaGateUITheme.title_label(name_label, 14, Color.WHITE)
	box.add_child(name_label)
	var stat := Label.new()
	stat.text = _market_short_stat(item)
	stat.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stat.mouse_filter = Control.MOUSE_FILTER_IGNORE
	NovaGateUITheme.dim_label(stat, 11)
	box.add_child(stat)
	var price := Label.new()
	var price_text := str(item.get("price", ""))
	price.text = price_text if price_text != "" else "PAKET SEÇ"
	price.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	price.mouse_filter = Control.MOUSE_FILTER_IGNORE
	NovaGateUITheme.price_label(price, 13, true)
	box.add_child(price)
	var badge := Label.new()
	badge.text = owned_state
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if owned_visual:
		NovaGateUITheme.title_label(badge, 11, NovaGateUITheme.GREEN)
	else:
		NovaGateUITheme.dim_label(badge, 11)
	box.add_child(badge)
	var key := "%s|%s" % [str(item.get("type", "")), str(item.get("name", ""))]
	item_cards[key] = card
	card.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				_select_item(item)
				accept_event()
		if event is InputEventScreenTouch:
			var st := event as InputEventScreenTouch
			if st.pressed:
				_select_item(item)
				accept_event()
	)
	card.mouse_entered.connect(func() -> void:
		if _is_card_selected(item):
			return
		card.add_theme_stylebox_override("panel", NovaGateUITheme.panel_hover())
	)
	card.mouse_exited.connect(func() -> void:
		_refresh_item_cards_selected()
	)
	item_strip.add_child(card)


func _is_card_selected(item: Dictionary) -> bool:
	if selected_item.is_empty():
		return false
	return str(selected_item.get("name", "")) == str(item.get("name", "")) and str(selected_item.get("type", "")) == str(item.get("type", ""))


func _refresh_item_cards_selected() -> void:
	for key in item_cards.keys():
		var card: PanelContainer = item_cards[key]
		if not is_instance_valid(card):
			continue
		var sel := false
		if not selected_item.is_empty():
			var ckey := "%s|%s" % [str(selected_item.get("type", "")), str(selected_item.get("name", ""))]
			sel = str(key) == ckey
		var owned_lbl := _card_owned_visual(key)
		NovaGateUITheme.apply_card(card, owned_lbl, sel)


func _card_owned_visual(key: String) -> bool:
	var card = item_cards.get(key)
	if card != null and is_instance_valid(card) and (card as PanelContainer).has_meta("ng_owned"):
		return bool((card as PanelContainer).get_meta("ng_owned"))
	return false


func _add_item_button(item: Dictionary) -> void:
	_add_item_card(item)


func _selected_item_id() -> String:
	if selected_item.is_empty():
		return ""
	for key in ["item_id", "ship_id", "name", "ammo_name"]:
		var value := str(selected_item.get(key, "")).strip_edges()
		if value != "":
			return value
	return ""

func _select_item(item: Dictionary) -> void:
	selected_item = item
	detail_title.text = str(item.get("name", "ÜRÜN"))
	detail_info.text = str(item.get("info", ""))

	if detail_image != null:
		detail_image.texture = null
		var preview_path := str(item.get("preview", ""))
		if preview_path != "" and ResourceLoader.exists(preview_path):
			detail_image.texture = load(preview_path)

	var item_type := str(item.get("type", ""))

	if item_type == "ammo_selector":
		detail_price.text = "PAKET SEÇ"
		buy_button.visible = false
		buy_button.disabled = true
		_build_ammo_package_buttons(item)
		return

	if item_type == "log_disk_selector":
		detail_price.text = "MİKTAR SEÇ"
		buy_button.visible = false
		buy_button.disabled = true
		_build_log_disk_package_buttons(item)
		return

	if ammo_package_box != null:
		_clear_children(ammo_package_box)
		ammo_package_box.visible = false

	buy_button.visible = true
	detail_price.text = "FİYAT: " + str(item.get("price", "-"))

	var is_disabled := bool(item.get("disabled", false))
	buy_button.disabled = is_disabled
	if is_disabled:
		var disabled_text := str(item.get("disabled_text", "KULLANILAMAZ"))
		buy_button.text = disabled_text if disabled_text != "" else "KULLANILAMAZ"
	else:
		buy_button.text = "SATIN AL"


func _build_ammo_package_buttons(selector: Dictionary) -> void:
	if ammo_package_box == null:
		return

	_clear_children(ammo_package_box)
	ammo_package_box.visible = true

	var ammo_name := str(selector.get("ammo_name", ""))
	var packages = selector.get("packages", [])
	if not (packages is Array):
		return

	for package_data in packages:
		if not (package_data is Array) or package_data.size() < 3:
			continue

		var quantity := int(package_data[0])
		var cost := int(package_data[1])
		var currency := str(package_data[2])

		var button := Button.new()
		button.custom_minimum_size = Vector2(190, 72)
		button.text = "%s ADET\n%s %s" % [
			_fmt_number(quantity),
			_fmt_number(cost),
			currency
		]
		button.add_theme_font_size_override("font_size", 16)

		var purchase := {
			"name": ammo_name,
			"type": "ammo",
			"ammo_name": ammo_name,
			"quantity": quantity,
			"currency": currency,
			"amount": cost,
			"price": "%s %s" % [_fmt_number(cost), currency]
		}
		button.pressed.connect(func() -> void:
			if market_operation_in_progress:
				return
			button.disabled = true
			_buy_ammo_package(purchase, selector)
		)
		ammo_package_box.add_child(button)


func _buy_ammo_package(purchase: Dictionary, selector: Dictionary) -> void:
	if market_operation_in_progress:
		return
	selected_item = purchase
	await _buy_ammo()

	# Satın alma sonrası seçili cephanenin stok bilgisini anında yenile.
	var refreshed_selector := selector.duplicate(true)
	var ammo_name := str(selector.get("ammo_name", ""))
	var info := "Mevcut stok: %s" % _fmt_number(GlobalState.get_ammo_count(ammo_name))
	if ammo_name in ["R1", "R2", "R3"]:
		info += "\nRoket menzili: lazerden +10\nStok yoksa kullanılamaz."
	else:
		info += "\nHer salvo, aktif gemi+droid lazer sayısı kadar cephane tüketir."
	refreshed_selector["info"] = info

	selected_item = refreshed_selector
	detail_title.text = ammo_name
	detail_info.text = info
	detail_price.text = "PAKET SEÇ"
	buy_button.visible = false
	_build_ammo_package_buttons(refreshed_selector)


func _clear_detail() -> void:
	selected_item = {}
	if ammo_package_box != null:
		_clear_children(ammo_package_box)
		ammo_package_box.visible = false
	buy_button.visible = true
	detail_title.text = "ÜRÜN SEÇ"
	detail_info.text = "Alttaki listeden bir ürün seç."
	detail_price.text = ""
	if detail_image != null:
		detail_image.texture = null
	buy_button.text = "SATIN AL"
	buy_button.disabled = true


func _on_buy_pressed() -> void:
	if selected_item.is_empty():
		print("MARKET BUY CLICK: selected_item is empty")
		return
	if not _begin_market_purchase():
		print("MARKET BUY CLICK: market_operation_in_progress is true")
		return

	var item_type := str(selected_item.get("type", ""))
	var item_id := _selected_item_id()
	var username := str(GlobalState.username).strip_edges()
	if username == "":
		var account_manager = load("res://scripts/account_manager.gd").new()
		username = str(account_manager.get_current_player()).strip_edges()
		account_manager.queue_free()
	var item_currency_raw := str(selected_item.get("currency", ""))
	var normalized_currency := _normalize_currency(item_currency_raw)
	if item_type in ["ship", "droid_plus", "droid_zeus", "laser", "generator", "ammo"] and selected_item.has("currency") and normalized_currency == "":
		detail_info.text = "Geçersiz para birimi. Desteklenenler: BTC, PLT."
		_end_market_purchase()
		return
	var price_value := str(selected_item.get("amount", selected_item.get("price", "")))
	print("MARKET BUY CLICK")
	print("MARKET BUY ITEM: ", item_id)
	print("MARKET BUY USER: ", username)
	print("MARKET BUY PRICE: ", price_value)

	if item_type == "ship":
		await _buy_ship()
		_end_market_purchase()
		return

	if item_type == "droid_plus" or item_type == "droid_zeus":
		await _buy_droid(item_type)
		_end_market_purchase()
		return

	if item_type in ["laser", "generator", "equipment"]:
		await _buy_equipment()
		_end_market_purchase()
		return

	if item_type == "extra":
		await _buy_booster_extra()
		_end_market_purchase()
		return

	if item_type == "log_disk":
		await _buy_log_disk()
		_end_market_purchase()
		return

	if item_type == "ammo":
		await _buy_ammo()
		_end_market_purchase()
		return

	_end_market_purchase()
	print("SATIN ALMA İSTEĞİ: ", selected_item.get("name", "?"), " / ", selected_item.get("price", "-"))


func _build_log_disk_package_buttons(selector: Dictionary) -> void:
	if ammo_package_box == null:
		return

	_clear_children(ammo_package_box)
	ammo_package_box.visible = true

	var packages = selector.get("packages", [])
	if not (packages is Array):
		return

	for package_data in packages:
		if not (package_data is Array) or package_data.size() < 2:
			continue

		var quantity := int(package_data[0])
		var cost := int(package_data[1])

		var button := Button.new()
		button.custom_minimum_size = Vector2(190, 72)
		button.text = "%s LOG DİSK\n%s PLT" % [
			_fmt_number(quantity),
			_fmt_number(cost)
		]
		button.add_theme_font_size_override("font_size", 16)
		button.pressed.connect(func() -> void:
			if market_operation_in_progress:
				return
			button.disabled = true
			_buy_log_disk_package(quantity, cost, selector)
		)
		ammo_package_box.add_child(button)


func _buy_log_disk_package(quantity: int, cost: int, selector: Dictionary) -> void:
	if quantity <= 0 or market_operation_in_progress:
		return
	market_operation_in_progress = true

	var account_manager = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(account_manager)

	# server_market_buy ikinci parametre olarak String bekliyor.
	var result: Dictionary = await account_manager.server_market_buy("log_disk", str(quantity))

	# OFFLINE FALLBACK: YALNIZCA sunucuya hiç ulaşılamadığında yerel ekonomi
	# devreye girer. Sunucu yanıt VERDİYSE (bakiye yetersiz, item katalogda
	# yok, hata kodu) yetkisi sunucudur; yerel economy ile satın almak
	# oyuncuyu hileye açardı. account_manager artık "server_erisilemez"
	# bayrağını birlikte döndürür.
	if bool(result.get("server_erisilemez", false)):
		result = _offline_buy_log_disk(quantity)

	account_manager.queue_free()

	if not bool(result.get("basarili", false)):
		detail_info.text = str(result.get("mesaj", "Log Disk satın alma başarısız."))
		market_operation_in_progress = false
		_end_market_purchase()
		return

	_apply_server_balances(result)

	# Server cevabındaki gerçek Log Disk bakiyesi varsa onu kullan.
	if result.has("log_disks"):
		GlobalState.log_disks = int(result.get("log_disks", GlobalState.log_disks))
	else:
		GlobalState.log_disks += quantity

	GlobalState.save_game()

	detail_title.text = "LOG DİSK"
	detail_info.text = "%s Log Disk satın alındı.\nMevcut Log Disk: %s" % [
		_fmt_number(quantity),
		_fmt_number(GlobalState.log_disks)
	]
	detail_price.text = "MİKTAR SEÇ"
	buy_button.visible = false

	var refreshed := selector.duplicate(true)
	selected_item = refreshed
	_build_log_disk_package_buttons(refreshed)
	market_operation_in_progress = false
	_end_market_purchase()


func _buy_log_disk() -> void:
	# Eski tekli satın alma çağrıları için güvenli yedek.
	await _buy_log_disk_package(1, 300, selected_item)


func _buy_booster_extra() -> void:
	if market_operation_in_progress:
		return
	market_operation_in_progress = true
	var booster_name := str(selected_item.get("name", ""))
	if booster_name == "":
		market_operation_in_progress = false
		_end_market_purchase()
		return

	if GlobalState.active_extras.has(booster_name):
		var active_data = GlobalState.active_extras[booster_name]
		if int(active_data.get("expire", 0)) > Time.get_unix_time_from_system():
			market_operation_in_progress = false
			detail_info.text = "Bu booster zaten aktif."
			buy_button.disabled = false
			buy_button.text = "AKTİF"
			_end_market_purchase()
			return

	var account_manager = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(account_manager)
	var result: Dictionary = await account_manager.server_market_buy("extra", booster_name)

	# OFFLINE FALLBACK: yalnızca sunucuya ulaşılamadığında (bkz. _buy_log_disk).
	if bool(result.get("server_erisilemez", false)):
		result = _offline_buy_booster(booster_name)

	account_manager.queue_free()

	if not bool(result.get("basarili", false)):
		detail_info.text = str(result.get("mesaj", "Satın alma başarısız."))
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		market_operation_in_progress = false
		_end_market_purchase()
		return

	_apply_server_balances(result)
	GlobalState.active_extras[booster_name] = {
		"expire": Time.get_unix_time_from_system() + 10800,
		"bonus": 0.20
	}
	GlobalState.save_game()
	var live_player = get_tree().get_first_node_in_group("player")
	if live_player != null and live_player.has_method("refresh_persistent_bonuses"):
		live_player.call("refresh_persistent_bonuses")

	detail_info.text = "%s\\n\\n%s\\n3 saat aktif edildi. Bonus: +%%20" % [str(selected_item.get("info","")), str(result.get("mesaj","Satın alındı."))]
	buy_button.disabled = false
	buy_button.text = "SAHİP"
	_notify_menu_inventory_changed()
	market_operation_in_progress = false
	_end_market_purchase()


func _buy_ammo() -> void:
	if market_operation_in_progress:
		return
	market_operation_in_progress = true
	var ammo_name := str(selected_item.get("ammo_name", ""))
	var quantity := int(selected_item.get("quantity", 0))
	var currency := _normalize_currency(str(selected_item.get("currency", "")))
	var cost := int(selected_item.get("amount", 0))

	if ammo_name.is_empty() or quantity <= 0 or cost <= 0:
		market_operation_in_progress = false
		detail_info.text = "Cephane paket bilgisi hatalı."
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		return

	if currency == "":
		market_operation_in_progress = false
		detail_info.text = "Geçersiz para birimi. Desteklenenler: BTC, PLT."
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		return

	# Route purchase through server (server-authoritative)
	var item_id := "ammo_%s_%d" % [ammo_name.to_lower(), quantity]
	var account_manager = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(account_manager)
	var result: Dictionary = await account_manager.server_market_buy("ammo", item_id)
	account_manager.queue_free()

	if not bool(result.get("basarili", false)):
		detail_info.text = str(result.get("mesaj", "Satın alma başarısız."))
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		market_operation_in_progress = false
		_end_market_purchase()
		return

	_apply_server_balances(result)
	GlobalState.add_ammo(ammo_name, quantity)
	GlobalState.save_game()

	detail_info.text = "%s\n\nSATIN ALINDI: %s adet\nYENİ STOK: %s" % [
		ammo_name,
		_fmt_number(quantity),
		_fmt_number(GlobalState.get_ammo_count(ammo_name))
	]
	_refresh_wallet_labels()
	market_operation_in_progress = false
	_end_market_purchase()


func _buy_ship() -> void:
	if market_operation_in_progress:
		return
	market_operation_in_progress = true
	var ship_id := str(selected_item.get("item_id", selected_item.get("ship_id", ""))).strip_edges()

	if ship_id == "":
		market_operation_in_progress = false
		detail_info.text = "Gemi kimliği bulunamadı."
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		print("MARKET BUY ITEM: ship_id empty")
		return

	var account_manager = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(account_manager)

	print("MARKET BUY SHIP -> SERVER: ", ship_id)
	var result: Dictionary = await account_manager.server_market_buy("ship", ship_id)

	# OFFLINE FALLBACK: yalnızca sunucuya ulaşılamadığında (bkz. _buy_log_disk).
	if bool(result.get("server_erisilemez", false)):
		result = _offline_buy_ship(account_manager, ship_id)

	account_manager.queue_free()

	market_operation_in_progress = false
	if not bool(result.get("basarili", false)):
		detail_info.text = str(result.get("mesaj", "Gemi satın alma başarısız."))
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		return

	_apply_server_balances(result)
	GlobalState.save_game()

	detail_info.text += "\n\n%s\nGemi HANGAR → GEMİLER bölümüne eklendi." % str(result.get("mesaj", "Gemi satın alındı."))
	buy_button.disabled = true
	buy_button.text = "SAHİP"
	_refresh_wallet_labels()


func _buy_equipment() -> void:
	if market_operation_in_progress:
		return
	market_operation_in_progress = true
	var item_name := str(selected_item.get("name", "")).strip_edges()
	if item_name == "":
		item_name = str(selected_item.get("item_id", "")).strip_edges()
	if item_name == "":
		item_name = str(selected_item.get("laser", "")).strip_edges()
	if item_name == "":
		item_name = str(selected_item.get("equipment", "")).strip_edges()
	if item_name == "":
		detail_info.text = "Ekipman adı bulunamadı."
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		return

	# Map client item name to server catalog item_id
	var item_id := _resolve_catalog_item_id(item_name)
	if item_id == "":
		detail_info.text = "Ekipman sunucu kataloğunda bulunamadı."
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		return

	# Route purchase through server (server-authoritative)
	var account_manager = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(account_manager)
	var result: Dictionary = await account_manager.server_market_buy("equipment", item_id)
	account_manager.queue_free()

	if not bool(result.get("basarili", false)):
		detail_info.text = str(result.get("mesaj", "Satın alma başarısız."))
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		market_operation_in_progress = false
		_end_market_purchase()
		return

	_apply_server_balances(result)

	# Sunucu envanteri kanonik id'lerle döndürdü; GlobalState bunun üzerine
	# yazılır (yerel eski veri sunucuyu EZMEZ). Ardından kalıcı kayıt ve
	# ekipman/hangar yenilemesi yapılır, böylece item panelde GÖRÜNÜR.
	var live_inventory = result.get("inventory", {})
	if live_inventory is Dictionary:
		GlobalState.inventory = (live_inventory as Dictionary).duplicate(true)
	GlobalState.save_game()

	# menu_ui.gd içinde "equip_purchased_item" diye bir metot YOKTUR (yalnızca
	# eski menu_ui kopyalarında vardır), bu yüzden o çağrı sessizce düşüyor ve
	# envarter hiç yenilenmiyordu. Çalışan kanca
	# reload_owned_items_from_save -> _load_owned_items -> _refresh_all'dır;
	# kayıtta kanonik id ile yazan sunucu envanterini okuyup panele basar.
	_notify_menu_inventory_changed()

	QuestSystem.record_event("item_acquired", {"item": item_name, "amount": 1})
	# Satın almak otomatik takmayı ZORUNLU kılmaz: item önce envantere
	# düşer, oyuncu HANGAR > ÜRÜNLER'den istediği yuvaya takar. Bu, config
	# sistemine dokunmadan davranışı korur ve oyuncunun seçimini gasp etmez.
	detail_info.text = "%s\n\n%s\nEnvantere eklendi. Kullanmak için HANGAR > ÜRÜNLER bölümünden uygun yuvaya takabilirsin." % [
		str(selected_item.get("info", "")),
		"%s satın alındı." % item_name
	]
	buy_button.disabled = false
	buy_button.text = "SATIN AL"
	market_operation_in_progress = false
	_end_market_purchase()


func _buy_droid(item_type: String) -> void:
	if market_operation_in_progress:
		return
	market_operation_in_progress = true
	var droid_name := "PLUS" if item_type == "droid_plus" else "ZEUS"

	var account_manager = load("res://scripts/account_manager.gd").new()
	get_tree().root.add_child(account_manager)

	print("MARKET BUY DROID -> SERVER: ", droid_name)
	var result: Dictionary = await account_manager.server_market_buy("droid", droid_name)

	# OFFLINE FALLBACK: yalnızca sunucuya ulaşılamadığında (bkz. _buy_log_disk).
	if bool(result.get("server_erisilemez", false)):
		result = _offline_buy_droid(account_manager, droid_name)

	account_manager.queue_free()

	market_operation_in_progress = false
	if not bool(result.get("basarili", false)):
		detail_info.text = str(result.get("mesaj", "Droid satın alma başarısız."))
		buy_button.disabled = false
		buy_button.text = "SATIN AL"
		return

	_apply_server_balances(result)
	GlobalState.save_game()
	_refresh_wallet_labels()

	var refreshed_items := _build_droid_items()
	if item_type == "droid_plus" and refreshed_items.size() > 0:
		_select_item(refreshed_items[0])
	elif item_type == "droid_zeus" and refreshed_items.size() > 1:
		_select_item(refreshed_items[1])

	detail_info.text += "\n\n%s\nDroid kaydı güncellendi." % str(result.get("mesaj", "Droid satın alındı."))


func _apply_server_balances(result: Dictionary) -> void:
	if result.has("bitcoin") or result.has("btc"):
		GlobalState.bitcoin = int(result.get("bitcoin", result.get("btc", GlobalState.bitcoin)))
	if result.has("plt") or result.has("platinum") or result.has("balance"):
		GlobalState.platinum = int(result.get("plt", result.get("platinum", result.get("balance", GlobalState.platinum))))
		GlobalState.uridium = GlobalState.platinum
		# PLT'nin tek canlı kaynağı artık sunucudur.


func _load_droid_market_state() -> void:
	var account_manager = load("res://scripts/account_manager.gd").new()
	var counts: Dictionary = account_manager.get_droid_counts()

	plus_droid_count = clampi(int(counts.get("plus", 0)), 0, MAX_DROID_COUNT)
	zeus_droid_count = clampi(int(counts.get("zeus", 0)), 0, MAX_DROID_COUNT)

	if plus_droid_count + zeus_droid_count > MAX_DROID_COUNT:
		zeus_droid_count = maxi(0, MAX_DROID_COUNT - plus_droid_count)


func _normalize_currency(currency: String) -> String:
	var value := str(currency).strip_edges().to_upper()
	if value == "BTC" or value == "PLT":
		return value
	return ""


# ---------------------------------------------------------------------------
# SECURITY: Client-side currency balance checks removed.
# All currency operations are now server-authoritative via /market/buy.
# The functions _has_enough_live_currency, _take_live_currency, _add_live_currency
# are kept only for offline fallback and display purposes.
# Server validates all prices and balances.
# ---------------------------------------------------------------------------

func _get_live_currency(currency: String) -> int:
	var normalized := _normalize_currency(currency)
	if normalized == "BTC":
		return int(GlobalState.bitcoin)
	if normalized == "PLT":
		return int(GlobalState.platinum)
	return -1


func _has_enough_live_currency(currency: String, amount: int) -> bool:
	return _get_live_currency(currency) >= amount


func _take_live_currency(currency: String, amount: int) -> void:
	var normalized := _normalize_currency(currency)
	if normalized == "BTC":
		GlobalState.bitcoin = max(0, int(GlobalState.bitcoin) - amount)
	elif normalized == "PLT":
		var new_balance: int = max(0, int(GlobalState.platinum) - amount)
		GlobalState.platinum = new_balance
		GlobalState.uridium = new_balance


func _add_live_currency(currency: String, amount: int) -> void:
	if currency == "BTC":
		GlobalState.bitcoin += amount
	else:
		GlobalState.platinum += amount


func _notify_menu_inventory_changed() -> void:
	var controller := _find_menu_controller(get_tree().current_scene)
	if controller != null and controller.has_method("reload_owned_items_from_save"):
		controller.call_deferred("reload_owned_items_from_save")


func _refresh_droids_in_scene() -> void:
	var droid_root := get_tree().current_scene.find_child("Drones", true, false)
	if droid_root != null and droid_root.has_method("refresh_from_save"):
		droid_root.call_deferred("refresh_from_save")


func _on_menu_pressed() -> void:
	print("MARKET -> MENÜ")
	var controller := _find_menu_controller(get_tree().current_scene)
	if embedded_mode:
		if controller != null and controller.has_method("_show_main_menu"):
			controller.call_deferred("_show_main_menu")
		return
	if controller != null and controller.has_method("_show_main_menu"):
		queue_free()
		controller.call_deferred("_show_main_menu")
		return
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _on_close_pressed() -> void:
	print("MARKET -> X")
	if embedded_mode:
		var controller := _find_menu_controller(get_tree().current_scene)
		if controller != null and controller.has_method("_close_all"):
			controller.call_deferred("_close_all")
		return
	queue_free()


func _find_menu_controller(node: Node) -> Node:
	if node.has_method("_show_main_menu"):
		return node
	for child in node.get_children():
		var found := _find_menu_controller(child)
		if found != null:
			return found
	return null


func _load_ships() -> void:
	ships.clear()
	var path := "res://market/data/ships.json"
	if not FileAccess.file_exists(path):
		print("ships.json bulunamadı")
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		print("ships.json açılamadı")
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Array:
		ships = parsed
		print("GEMİ SAYISI: ", ships.size())


func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.012, 0.028, 0.045, 0.985)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.05, 0.75, 0.95, 1)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_right = 8
	style.corner_radius_bottom_left = 8
	return style


func _detail_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.018, 0.045, 0.065, 1)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.08, 0.38, 0.52, 1)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	return style


func _fmt_number(value) -> String:
	var n := int(value)
	var s := str(abs(n))
	var out := ""
	while s.length() > 3:
		out = "." + s.substr(s.length() - 3, 3) + out
		s = s.substr(0, s.length() - 3)
	out = s + out
	if n < 0:
		out = "-" + out
	return out


# ============================================================
# OFFLINE SATIN ALMA FALLBACK'LERİ
# Sunucu erişilemediğinde market işlemleri yerel ekonomiyle uygulanır.
# GlobalState ve players.json bakiyeleri senkron tutulur; envanter,
# gemi ve droid kayıtları mevcut lokal sistemlerin üzerinden yürür.
# ============================================================
func _find_catalog_item(item_name: String) -> Dictionary:
	for category in ["LAZERLER", "JENERATÖRLER"]:
		for item in _get_category_items(category):
			if item is Dictionary and str(item.get("name", "")) == item_name:
				return item
	return {}


func _resolve_catalog_item_id(item_name: String) -> String:
	"""Map client item name to server catalog item_id."""
	var lower_name := item_name.to_lower()
	if lower_name in ["lf1", "lf1"]:
		return "lf1"
	elif lower_name in ["lf2", "lf2"]:
		return "lf2"
	elif lower_name in ["lf3", "lf3"]:
		return "lf3"
	elif lower_name.contains("kalkan 1") or lower_name.contains("kalkan1"):
		return "kalkan1"
	elif lower_name.contains("kalkan 2") or lower_name.contains("kalkan2"):
		return "kalkan2"
	elif lower_name.contains("hız 1") or lower_name.contains("hiz 1"):
		return "hiz1"
	elif lower_name.contains("hız 2") or lower_name.contains("hiz 2"):
		return "hiz2"

	# Extra/boosters - use the lowercase name as catalog ID
	if lower_name in ["ema", "enc", "nukleer", "uc_saniye", "3 saniye"]:
		return lower_name

	return ""


func _offline_buy_ship(account_manager, ship_id: String) -> Dictionary:
	var ship: Dictionary = {}
	for s in ships:
		if s is Dictionary and str(s.get("id", "")) == ship_id:
			ship = s
			break
	if ship.is_empty():
		return {"basarili": false, "mesaj": "Gemi verisi bulunamadı."}
	if account_manager.owns_ship(ship_id):
		return {"basarili": false, "mesaj": "Bu gemiye zaten sahipsin."}

	var currency := str(ship.get("currency", "BTC"))
	var price := int(ship.get("price", 0))
	if currency == "BTC":
		if int(GlobalState.bitcoin) < price:
			return {"basarili": false, "mesaj": "Yeterli Bitcoin yok."}
		_take_live_currency("BTC", price)
	elif currency == "PLT":
		if int(GlobalState.platinum) < price:
			return {"basarili": false, "mesaj": "Yeterli PLT yok."}
		_take_live_currency("PLT", price)

	var buy_currency := "BTC" if currency != "PLT" else "PLT"
	var live_balance := int(GlobalState.bitcoin) if buy_currency == "BTC" else int(GlobalState.platinum)
	var buy_result: Dictionary = account_manager.record_ship_purchase(ship_id, buy_currency, live_balance)
	if not bool(buy_result.get("ok", false)):
		return {"basarili": false, "mesaj": str(buy_result.get("message", "Gemi satın alınamadı."))}

	return {
		"basarili": true,
		"mesaj": "%s hangara eklendi (offline)." % str(ship.get("name", ship_id)),
		"bitcoin": int(GlobalState.bitcoin),
		"plt": int(GlobalState.platinum)
	}


func _offline_buy_equipment(account_manager, item_name: String) -> Dictionary:
	var item := _find_catalog_item(item_name)
	if item.is_empty():
		return {"basarili": false, "mesaj": "Ürün fiyat bilgisi bulunamadı."}

	var currency := str(item.get("currency", "BTC"))
	var price := int(item.get("amount", 0))
	if price <= 0:
		return {"basarili": false, "mesaj": "Ürün fiyatı geçersiz."}

	# players.json defterini canlı GlobalState bakiyesiyle hizala.
	account_manager.set_local_balances(int(GlobalState.bitcoin), int(GlobalState.platinum))
	var buy_result: Dictionary = account_manager.buy_equipment(item_name, currency, price)
	if not bool(buy_result.get("ok", false)):
		return {"basarili": false, "mesaj": str(buy_result.get("message", "Satın alma başarısız."))}

	var balance := int(buy_result.get("balance", 0))
	if currency == "BTC":
		GlobalState.bitcoin = balance
	else:
		GlobalState.platinum = balance
		GlobalState.uridium = balance

	# GlobalState envanterini yerel kayıttan tazele ve item_acquired görev olayını yayınla.
	var record = account_manager.get_player(account_manager.get_current_player())
	if record != null:
		GlobalState.inventory = (record.get("inventory", {}) as Dictionary).duplicate(true)
	QuestSystem.record_event("item_acquired", {"item": item_name, "amount": 1})

	return {
		"basarili": true,
		"mesaj": "%s satın alındı (offline)." % item_name,
		"bitcoin": int(GlobalState.bitcoin),
		"plt": int(GlobalState.platinum)
	}


func _offline_buy_droid(account_manager, droid_type: String) -> Dictionary:
	var currency := "BTC" if droid_type == "PLUS" else "PLT"
	var prices: Array = PLUS_DROID_PRICES if droid_type == "PLUS" else ZEUS_DROID_PRICES

	var counts: Dictionary = account_manager.get_droid_counts()
	if int(counts.get("total", 0)) >= MAX_DROID_COUNT:
		return {"basarili": false, "mesaj": "Maksimum 8 droid sınırına ulaşıldı."}

	var type_count := int(counts.get("plus", 0)) if droid_type == "PLUS" else int(counts.get("zeus", 0))
	var price := int(prices[clampi(type_count, 0, prices.size() - 1)])

	if currency == "BTC":
		if int(GlobalState.bitcoin) < price:
			return {"basarili": false, "mesaj": "Yeterli Bitcoin yok."}
		_take_live_currency("BTC", price)
	else:
		if int(GlobalState.platinum) < price:
			return {"basarili": false, "mesaj": "Yeterli PLT yok."}
		_take_live_currency("PLT", price)

	account_manager.set_local_balances(int(GlobalState.bitcoin), int(GlobalState.platinum))
	var buy_result: Dictionary = account_manager.buy_droid(droid_type, currency, price)
	if not bool(buy_result.get("ok", false)):
		return {"basarili": false, "mesaj": str(buy_result.get("message", "Droid satın alınamadı."))}

	return {
		"basarili": true,
		"mesaj": "%s droid satın alındı (offline)." % droid_type,
		"bitcoin": int(GlobalState.bitcoin),
		"plt": int(GlobalState.platinum)
	}


func _offline_buy_booster(booster_name: String) -> Dictionary:
	if GlobalState.active_extras.has(booster_name):
		var active_data = GlobalState.active_extras[booster_name]
		if int(active_data.get("expire", 0)) > Time.get_unix_time_from_system():
			return {"basarili": false, "mesaj": "Bu booster zaten aktif."}

	var price := 15000
	if not _has_enough_live_currency("PLT", price):
		return {"basarili": false, "mesaj": "Yetersiz PLT.\nGereken: 15.000 PLT"}

	_take_live_currency("PLT", price)
	return {
		"basarili": true,
		"mesaj": "%s satın alındı (offline)." % booster_name,
		"plt": int(GlobalState.platinum)
	}


func _offline_buy_log_disk(quantity: int) -> Dictionary:
	if quantity <= 0:
		return {"basarili": false, "mesaj": "Geçersiz Log Disk miktarı."}

	var price := quantity * 300
	if not _has_enough_live_currency("PLT", price):
		return {"basarili": false, "mesaj": "Yetersiz PLT.\nGereken: %s PLT" % _fmt_number(price)}

	_take_live_currency("PLT", price)
	return {
		"basarili": true,
		"mesaj": "Log Disk satın alındı (offline).",
		"plt": int(GlobalState.platinum)
	}
