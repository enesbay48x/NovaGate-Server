extends Control
const CYAN := Color("55d9ff")
const EDGE := Color("20536d")
const PURPLE := Color("9b82ff")
const TEXT := Color("dcecf5")
const MUTED := Color("8298aa")
var menu_ui: Control
var values: Dictionary = {}
var nav: Dictionary = {}
var dashboard: Control
func _ready() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    process_mode = Node.PROCESS_MODE_ALWAYS
    visible = false
    mouse_filter = Control.MOUSE_FILTER_STOP
    call_deferred("_build")
    call_deferred("_bind")
func _style(bg: Color, edge: Color, width: int = 1) -> StyleBoxFlat:
    var s := StyleBoxFlat.new(); s.bg_color = bg; s.border_color = edge; s.set_border_width_all(width)
    s.corner_radius_top_left=4; s.corner_radius_top_right=4; s.corner_radius_bottom_left=4; s.corner_radius_bottom_right=4
    s.content_margin_left=10; s.content_margin_right=10; s.content_margin_top=7; s.content_margin_bottom=7; return s
func _label(text: String, size: int, color: Color = TEXT) -> Label:
    var l=Label.new(); l.text=text; l.autowrap_mode=TextServer.AUTOWRAP_OFF; l.clip_text=false; l.vertical_alignment=VERTICAL_ALIGNMENT_CENTER
    l.custom_minimum_size=Vector2(0,0); l.add_theme_font_size_override("font_size",size); l.add_theme_color_override("font_color",color); return l
func _button(text: String, width: float, section: String = "") -> Button:
    var b=Button.new(); b.text=text; b.custom_minimum_size=Vector2(width,32); b.focus_mode=Control.FOCUS_NONE; b.clip_text=false; b.alignment=HORIZONTAL_ALIGNMENT_LEFT
    b.add_theme_font_size_override("font_size",12); b.add_theme_color_override("font_color",TEXT); b.add_theme_color_override("font_hover_color",Color.WHITE)
    b.add_theme_stylebox_override("normal",_style(Color("091421"),EDGE)); b.add_theme_stylebox_override("hover",_style(Color("10283a"),CYAN,2)); b.add_theme_stylebox_override("pressed",_style(Color("17324a"),PURPLE,2)); b.add_theme_stylebox_override("disabled",_style(Color("070d15"),Color("20303c"))); b.add_theme_stylebox_override("focus",StyleBoxEmpty.new())
    if section!="": b.pressed.connect(_navigate.bind(section)); nav[section]=b
    return b
func _build() -> void:
    var bg=ColorRect.new(); bg.color=Color("030812"); bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); bg.mouse_filter=Control.MOUSE_FILTER_IGNORE; add_child(bg)
    var grid=ColorRect.new(); grid.color=Color(0.02,0.08,0.16,0.10); grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); grid.mouse_filter=Control.MOUSE_FILTER_IGNORE; add_child(grid)
    var m=MarginContainer.new(); m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); m.add_theme_constant_override("margin_left",10); m.add_theme_constant_override("margin_top",8); m.add_theme_constant_override("margin_right",10); m.add_theme_constant_override("margin_bottom",8); add_child(m)
    var root=VBoxContainer.new(); root.add_theme_constant_override("separation",6); m.add_child(root); root.add_child(_topbar())
    var body=HBoxContainer.new(); body.size_flags_vertical=Control.SIZE_EXPAND_FILL; body.add_theme_constant_override("separation",6); root.add_child(body); body.add_child(_nav())
    var center=PanelContainer.new(); center.size_flags_horizontal=Control.SIZE_EXPAND_FILL; center.add_theme_stylebox_override("panel",_style(Color("08121f"),EDGE)); body.add_child(center); _dashboard(center); root.add_child(_footer())
func _topbar() -> PanelContainer:
    var p=PanelContainer.new(); p.custom_minimum_size=Vector2(0,58); p.add_theme_stylebox_override("panel",_style(Color("06101b"),EDGE,2)); var row=HBoxContainer.new(); row.add_theme_constant_override("separation",8); p.add_child(row)
    var brand=_label("NOVA GATE",22,CYAN); brand.custom_minimum_size=Vector2(165,0); row.add_child(brand)
    var pilot=VBoxContainer.new(); pilot.custom_minimum_size=Vector2(145,0); pilot.add_child(_label("PILOT",9,MUTED)); var pv=_label("--",14,TEXT); values["PILOT"]=pv; pilot.add_child(pv); row.add_child(pilot)
    var sp=Control.new(); sp.size_flags_horizontal=Control.SIZE_EXPAND_FILL; row.add_child(sp)
    for key in ["LVL","RANK","VIP","XP","BTC","PLT","GOLD","PING"]:
        var box=VBoxContainer.new(); box.custom_minimum_size=Vector2(72 if key!="RANK" else 90,0); box.add_child(_label(key,9,MUTED)); var v=_label("--",14,CYAN); values[key]=v; box.add_child(v); row.add_child(box)
    var online=_label("● ONLINE",12,Color("65f0a0")); online.custom_minimum_size=Vector2(80,0); row.add_child(online); var set=_button("SETTINGS",80,"AYARLAR"); set.alignment=HORIZONTAL_ALIGNMENT_CENTER; row.add_child(set); return p
func _nav() -> PanelContainer:
    var p=PanelContainer.new(); p.custom_minimum_size=Vector2(188,0); p.add_theme_stylebox_override("panel",_style(Color("06101a"),Color("1c4a61")))
    var scroll=ScrollContainer.new(); scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED; p.add_child(scroll)
    var box=VBoxContainer.new(); box.size_flags_horizontal=Control.SIZE_EXPAND_FILL; box.add_theme_constant_override("separation",3); scroll.add_child(box); box.add_child(_label("COMMAND NAVIGATION",10,CYAN))
    # Kontrol Paneli ile aynı bölüm listesi: eski "BLG" (BİLGİ) butonu ve ayrı
    # "SEYR DEFTER" butonu kaldırıldı. Seyir Defteri artık Kontrol Paneli'nin
    # ana ekranındaki SEYİR DEFTERİ kartından açılır.
    var items=["PAZAR","YETENEK AĞACI","EKİPMAN","MARKET","GÖREVLER","KLAN","İSTATİSTİKLER","HARİTA","GALAXY GATES","AYARLAR"]
    for item in items:
        box.add_child(_button(str(item),168,str(item)))
    return p
func _dashboard(host: PanelContainer) -> void:
    var scroll=ScrollContainer.new(); scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED; host.add_child(scroll)
    dashboard=VBoxContainer.new(); dashboard.size_flags_horizontal=Control.SIZE_EXPAND_FILL; dashboard.add_theme_constant_override("separation",6); scroll.add_child(dashboard)
    dashboard.add_child(_label("PILOT DASHBOARD",20,Color.WHITE))
    var row1=HBoxContainer.new(); row1.add_theme_constant_override("separation",6); dashboard.add_child(row1)
    row1.add_child(_card("PLAYER PROFILE",["PILOT","LEVEL / RANK","COMPANY","SHIP","HP / SHIELD","XP PROGRESS"]))
    row1.add_child(_card("SHIP STATUS",["CURRENT SHIP","SPEED","DAMAGE","SHIELD","CARGO","EQUIPMENT"]))
    var row2=HBoxContainer.new(); row2.add_theme_constant_override("separation",6); dashboard.add_child(row2)
    row2.add_child(_card("MISSIONS",["ACTIVE MISSIONS","PROGRESS","REWARDS"]))
    row2.add_child(_card("EVENTS / NEWS",["• Local server session established","• Sector 1-1 is ready for deployment","• Navigation systems synchronized","• No active emergency alerts"]))
    row2.add_child(_card("ONLINE PLAYERS",["PLAYER COUNT: --","COMPANY DISTRIBUTION: --","RECENT PLAYERS: --"]))
    var quick=PanelContainer.new(); quick.add_theme_stylebox_override("panel",_style(Color("091522"),EDGE)); dashboard.add_child(quick)
    var qb=VBoxContainer.new(); quick.add_child(qb); qb.add_child(_label("QUICK ACTIONS",12,CYAN))
    var qr=HBoxContainer.new(); qr.add_theme_constant_override("separation",5); qb.add_child(qr)
    # PLAY -> "PLAY" bölümü _navigate() içinde _close() ile eşleşir; "BLG"
    # kaldırıldığı için eski ["PLAY","BLG"] çifti ölü koddu ve buton hiçbir şey
    # yapmıyordu. Etiket "PLAY" kalır, hedef menüyü kapatıp oyuna dönmektir.
    for item in [["HANGAR","EKİPMAN"],["EQUIPMENT","EKİPMAN"],["MARKET","MARKET"],["MISSIONS","GÖREVLER"],["GALAXY GATES","GALAXY GATES"],["PLAY","PLAY"]]:
        var b=_button(str(item[0]),96,str(item[1])); b.alignment=HORIZONTAL_ALIGNMENT_CENTER; qr.add_child(b)
func _card(title: String, rows: Array) -> PanelContainer:
    var p=PanelContainer.new(); p.size_flags_horizontal=Control.SIZE_EXPAND_FILL; p.add_theme_stylebox_override("panel",_style(Color("091522"),EDGE)); var box=VBoxContainer.new(); box.add_theme_constant_override("separation",3); p.add_child(box); box.add_child(_label(title,12,CYAN))
    for row in rows: box.add_child(_label(str(row),11,MUTED if str(row).ends_with(":") else TEXT))
    return p
func _footer() -> PanelContainer:
    var p=PanelContainer.new(); p.custom_minimum_size=Vector2(0,25); p.add_theme_stylebox_override("panel",_style(Color("050b13"),Color("173b50"))); p.add_child(_label("MAP: 1-1     X: ----     Y: ----     PING: ---     SERVER: ONLINE",10,MUTED)); return p
func _bind() -> void:
    menu_ui=get_tree().get_first_node_in_group("menu_ui"); if menu_ui==null: return
    var button=menu_ui.get("menu_button")
    if button!=null and button is Button and not button.pressed.is_connected(_open_professional): button.pressed.connect(_open_professional)
func _open_professional() -> void:
    visible=true; _refresh()
func _refresh() -> void:
    if values.is_empty(): return
    values["PILOT"].text=GlobalState.username if not GlobalState.username.is_empty() else "PILOT"
    values["LVL"].text=str(GlobalState.level); values["RANK"].text=GlobalState.rank_title; values["VIP"].text="ACTIVE" if GlobalState.vip_expire_timestamp>0 else "OFF"; values["XP"].text=str(GlobalState.xp); values["BTC"].text=str(GlobalState.bitcoin); values["PLT"].text=str(GlobalState.platinum); values["GOLD"].text=str(GlobalState.gold); values["PING"].text="--"
func _navigate(section: String) -> void:
    if menu_ui==null: menu_ui=get_tree().get_first_node_in_group("menu_ui")
    if menu_ui==null: return
    _open_existing()
    if section=="EKİPMAN": menu_ui.call("_show_hangar")
    elif section=="YETENEK AĞACI": menu_ui.call("open_skill_tree")
    elif section=="İSTATİSTİKLER": menu_ui.call("_show_ranking_statistics")
    elif section=="PLAY": _close()
    else: menu_ui.call("_show_section",section)
    visible=false
func _open_existing() -> void:
    if menu_ui.has_method("_open_menu"):
        var overlay=menu_ui.get("overlay")
        if overlay!=null and not bool(overlay.visible): menu_ui.call("_open_menu")
func _close() -> void:
    if menu_ui!=null and menu_ui.has_method("_close_all"): menu_ui.call("_close_all")
    visible=false
