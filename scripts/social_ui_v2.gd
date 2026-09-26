extends "res://scripts/hud_manager.gd"
## NovaGate Social UI v2 - CHAT+TEAM only, click-to-interact, collapsible.
## Backend ChatManager/FriendManager/GroupManager korunur.

const CHAT_SZ := Vector2(350, 212)
const TEAM_SZ := Vector2(210, 220)
const INFO_SZ := Vector2(228, 104)
var _chat: Node = null
var _friends: Node = null
var _group: Node = null
var _gs: Node = null
var _is_mobile := false
var _collapsed := {}
var _panels := {}
var _stack_box: VBoxContainer
var _tab_bar: HBoxContainer
var _history: RichTextLabel
var _chat_input: LineEdit
var _chat_toggle: Button
var _team_list: VBoxContainer
var _team_title: Label
var _acct_lbl: Label
var _info_lbl: Label
var _notice_lbl: Label
var _player_ref: Node2D = null
var _selected_row: HBoxContainer
var _selected_label: Label
var _iname := ""
var _req: PanelContainer
var _rtext: Label
var _ntw: Tween
var _pages: TabContainer
var _scroll: ScrollContainer
var _messages: VBoxContainer
var _new_messages: Button
var _chat_holder: Control
var _history_channel := ""
var _quest_list: OptionButton
var _quest_detail: Label
var _quest_ids: Array = []
var _toast: Label

func _ready() -> void:
	initialize_windows()
	_chat = get_node_or_null("/root/ChatManager")
	_friends = get_node_or_null("/root/FriendManager")
	_group = get_node_or_null("/root/GroupManager")
	_gs = get_node_or_null("/root/GlobalState")
	_is_mobile = OS.get_name() in ["Android", "iOS"]
	_build_all()
	_build_popups()
	_build_quest_window()
	_connect_all()
	call_deferred("_integrate_scene_hud")
	refresh_all()
	get_viewport().size_changed.connect(_on_rs)
	_apply_layout()

func _sb(border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.018, 0.034, 0.052, 0.92)
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.set_content_margin_all(6)
	return s

func _lab(parent: Node, t: String, sz: int, col: Color = Color(0.8, 0.9, 0.95)) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l

func _bt(parent: Node, t: String, sz: int, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", sz)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(cb)
	parent.add_child(b)
	return b

func _mk(pid: String, title: String, pos: Vector2, sz: Vector2) -> VBoxContainer:
	var window = create_window(pid, title, Rect2(pos, sz))
	_panels[pid] = window
	return window.content
func _build_all() -> void:
	var info := _mk("INFO", "NOVAGATE PILOT", Vector2(12, 12), Vector2(190, 150))
	_info_lbl = _lab(info, "", 11)
	_acct_lbl = _lab(info, "", 11)
	var body := _mk("CHAT", "CHAT / TEAM", Vector2(12, available_rect().end.y - 230), Vector2(370, 230))
	# CHAT must survive the menu overlay modal: keep it on its own holder that
	# _sync_modal() never hides, so a pilot can open chat while the menu is up.
	var chat_window: PanelContainer = windows.get("CHAT")
	if chat_window != null and panel_root.is_ancestor_of(chat_window):
		panel_root.remove_child(chat_window)
		_chat_holder = Control.new()
		_chat_holder.name = "ChatHolder"
		_chat_holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_chat_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_chat_holder)
		_chat_holder.add_child(chat_window)
	_pages = TabContainer.new()
	_pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pages.add_theme_font_size_override("font_size", 11)
	body.add_child(_pages)
	var bc := VBoxContainer.new()
	bc.name = "CHAT"
	_pages.add_child(bc)
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 1)
	bc.add_child(_tab_bar)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size.y = 85
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	bc.add_child(_scroll)
	_messages = VBoxContainer.new()
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.add_theme_constant_override("separation", 2)
	_scroll.add_child(_messages)
	_new_messages = _bt(bc, "Yeni mesajlar ↓", 10, _scroll_bottom)
	_new_messages.hide()
	var row := HBoxContainer.new()
	bc.add_child(row)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Mesaj yaz..."
	_chat_input.add_theme_font_size_override("font_size", 11)
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.text_submitted.connect(_on_msg)
	row.add_child(_chat_input)
	_bt(row, ">", 11, _on_send)
	_notice_lbl = _lab(body, "", 10, Color(1, 0.85, 0.4))
	_notice_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var bt := VBoxContainer.new()
	bt.name = "TEAM"
	_pages.add_child(bt)
	_team_title = _lab(bt, "TAKIM", 11)
	var team_scroll := ScrollContainer.new()
	team_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	team_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bt.add_child(team_scroll)
	_team_list = VBoxContainer.new()
	_team_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	team_scroll.add_child(_team_list)
	# Hedef bilgi popup'ı kaldırıldığı için oyuncu kısayolları (arkadaşlık /
	# takım daveti / mesaj) buraya taşındı. Tıklayılan oyuncunun ADI dışında
	# ekranda hedef bilgisi (HP/SH/metre/kilit) gösterilmez.
	_selected_row = HBoxContainer.new()
	_selected_row.add_theme_constant_override("separation", 2)
	bt.add_child(_selected_row)
	_selected_label = _lab(_selected_row, "", 10, Color(0.4, 0.85, 0.95))
	_selected_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_selected_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_bt(_selected_row, "ARKADASLIK", 10, _on_if)
	_bt(_selected_row, "TAKIM", 10, _on_it)
	_bt(_selected_row, "MESAJ", 10, _on_im)
	_update_selected_row()
func _build_popups() -> void:
	_req = PanelContainer.new()
	_req.add_theme_stylebox_override("panel", _sb(Color(1, 0.8, 0.3, 0.9)))
	_req.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_req.offset_left = -262
	_req.offset_right = -12
	_req.offset_top = 150
	_req.offset_bottom = 235
	_req.hide()
	add_child(_req)
	var v2 := VBoxContainer.new()
	_req.add_child(v2)
	_lab(v2, "BILDIRIM", 10, Color(1, 0.85, 0.4))
	_rtext = _lab(v2, "", 11)
	var h2 := HBoxContainer.new()
	v2.add_child(h2)
	_bt(h2, "KABUL", 10, _on_ra)
	_bt(h2, "REDDET", 10, _on_rr)
	_req.set_meta("kind", "")
	_req.set_meta("who", "")
	_chat_toggle = Button.new()
	_chat_toggle.text = "CHAT"
	_chat_toggle.add_theme_font_size_override("font_size", 10)
	_chat_toggle.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_chat_toggle.offset_left = 12
	_chat_toggle.offset_top = -44
	_chat_toggle.offset_right = 80
	_chat_toggle.offset_bottom = -12
	_chat_toggle.pressed.connect(func(): _expand("CHAT"))
	add_child(_chat_toggle)
	_chat_toggle.hide()
func _connect_all() -> void:
	if _chat != null:
		if _chat.has_signal("message_added"):
			_chat.connect("message_added", _on_madd)
		if _chat.has_signal("active_channel_changed"):
			_chat.connect("active_channel_changed", func(_c): refresh_all())
		if _chat.has_signal("unread_count_changed"):
			_chat.connect("unread_count_changed", func(_c, _n): _rtabs())
	if _friends != null:
		for s in ["friend_added", "friend_removed", "request_received", "request_accepted", "request_rejected"]:
			if _friends.has_signal(s):
				_friends.connect(s, _on_fsig.bind(s))
	if _group != null:
		if _group.has_signal("group_changed"):
			_group.connect("group_changed", refresh_all)
		if _group.has_signal("invite_received"):
			_group.connect("invite_received", _on_ginv)
		if _group.has_signal("notice"):
			_group.connect("notice", _notice)

func _collapse(pid: String) -> void:
	var window = windows.get(pid)
	if window != null:
		window.collapse()

func _expand(pid: String) -> void:
	var window = windows.get(pid)
	if window != null:
		window.reopen()

func _rstack() -> void:
	# HudManager owns the only collapse dock.
	_refresh_dock()

func _on_stack(pid: String) -> void:
	_expand(pid)

func _on_rs() -> void:
	_is_mobile = OS.get_name() in ["Android", "iOS"] or get_viewport().get_visible_rect().size.x < 900.0
	_apply_layout()

func _apply_layout() -> void:
	# Defaults are applied once at registration; never overwrite saved/user positions.
	clamp_windows()

func _mv(pid: String, pos: Vector2) -> void:
	if windows.has(pid):
		windows[pid].position = pos
		windows[pid].clamp_to_bounds()

func refresh_all(_a = null, _b = null) -> void:
	_rtabs()
	_rhist()
	_rteam()
	_chat_toggle.visible = _collapsed.get("CHAT", false)

func _vch() -> Array:
	if _chat != null and _chat.has_method("get_visible_channels"):
		return _chat.call("get_visible_channels")
	return ["global_tr", "global_ku", "company"]

func _rtabs() -> void:
	if _tab_bar == null:
		return
	for c in _tab_bar.get_children():
		c.queue_free()
	for kind in _vch():
		var k := str(kind)
		var title := k.to_upper()
		if _chat != null and _chat.has_method("get_channel"):
			var ch = _chat.call("get_channel", k)
			if ch != null and ("title" in ch) and str(ch.title) != "":
				title = str(ch.title)
		var b := Button.new()
		b.text = title
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 10)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if _chat != null and ("active_channel" in _chat):
			b.button_pressed = str(_chat.active_channel) == k
		b.pressed.connect(_on_tab.bind(k))
		_tab_bar.add_child(b)

func _on_tab(ch: String) -> void:
	if _chat != null and _chat.has_method("on_channel_tab_pressed"):
		_chat.call("on_channel_tab_pressed", ch)
	refresh_all()

func _rhist() -> void:
	if _scroll == null or _chat == null:
		return
	var bar := _scroll.get_v_scroll_bar()
	var old_position := _scroll.scroll_vertical
	var act := str(_chat.active_channel)
	var follow := act != _history_channel or bar.value >= bar.max_value - bar.page - 4
	_history_channel = act
	for child in _messages.get_children():
		_messages.remove_child(child)
		child.queue_free()
	for m in _chat.get_channel_history(act, 200):
		var time := Time.get_datetime_dict_from_unix_time(int(m.get("timestamp", 0)))
		var line := _lab(_messages, "[%02d:%02d] %s: %s" % [time.hour, time.minute, str(m.get("sender", "")), str(m.get("text", ""))], 11)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_messages.visible = not follow
	_restore_scroll.call_deferred(follow, old_position)

func _restore_scroll(follow: bool, previous: int) -> void:
	await get_tree().process_frame
	if follow:
		_scroll_bottom()
	else:
		_scroll.scroll_vertical = previous

func _scroll_bottom() -> void:
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
	_new_messages.hide()

func _on_madd(channel: String, _m: Dictionary) -> void:
	if _chat != null and ("active_channel" in _chat) and str(_chat.active_channel) == channel:
		_rhist()
	_rtabs()

func _on_msg(text: String) -> void:
	if _chat == null:
		return
	var ch := str(_chat.active_channel) if ("active_channel" in _chat) else "global_tr"
	if bool(_chat.call("send_message", ch, text)):
		_chat_input.clear()
		_rhist()

func _on_send() -> void:
	_on_msg(_chat_input.text)

func _rteam() -> void:
	if _team_list == null:
		return
	for c in _team_list.get_children():
		c.queue_free()
	if _group == null:
		return
	var members: Array = _group.call("get_members") if _group.has_method("get_members") else []
	_team_title.text = "TAKIM %d/4" % members.size() if not members.is_empty() else "TAKIM"
	if members.is_empty():
		_lab(_team_list, "Takimda degilsin.", 10, Color(0.6, 0.7, 0.78))
		_bt(_team_list, "TAKIM OLUSTUR", 10, _on_tc)
	else:
		for m in members:
			if not (m is Dictionary):
				continue
			var star := "★ " if bool(m.get("is_leader", false)) else "● "
			_lab(_team_list, "%s%s Lv%d" % [star, str(m.get("username", "")), int(m.get("level", 1))], 11)
			_lab(_team_list, "HP %d/%d SH %d/%d" % [int(m.get("hp", 0)), maxi(1, int(m.get("max_hp", 1))), int(m.get("shield", 0)), maxi(1, int(m.get("max_shield", 1)))], 10, Color(0.6, 0.75, 0.82))
		_bt(_team_list, "AYRIL", 10, _on_tl)
	var invs: Array = _group.call("get_invite_views") if _group.has_method("get_invite_views") else []
	for inv in invs:
		if not (inv is Dictionary):
			continue
		var who := str(inv.get("from", ""))
		_lab(_team_list, "Davet: " + who, 10, Color(1, 0.85, 0.4))
		var h := HBoxContainer.new()
		_team_list.add_child(h)
		_bt(h, "Kabul", 10, _on_ta.bind(who))
		_bt(h, "Red", 10, _on_tr.bind(who))

func _on_tc() -> void:
	_group.call("create_group")
	refresh_all()

func _on_tl() -> void:
	_group.call("leave_group")
	refresh_all()

func _on_ta(who: String) -> void:
	_group.call("accept_invite", who)
	refresh_all()

func _on_tr(who: String) -> void:
	_group.call("reject_invite", who)
	refresh_all()

func _on_ginv(from_player: String) -> void:
	_show_req("team", str(from_player), "%s takima davet etti." % str(from_player))
	refresh_all()

func _on_fsig(who: String, sig: String) -> void:
	if sig == "request_received":
		_show_req("friend", str(who), "%s arkadaslik istegi gonderdi." % str(who))
	refresh_all()

func show_player_interaction(pname: String, _spos: Vector2 = Vector2(-1, -1)) -> void:
	# Hedef bilgi popup'ı kaldırıldı: tıklama artık ekranda oyuncu bilgisi
	# göstermez. Hedef SEÇİMİ (PvP ateşi / kilit) main.gd içindeki
	# _try_select_remote_at_mouse() tarafından yapılmaya devam eder.
	_iname = str(pname).strip_edges()
	_update_selected_row()

func _update_selected_row() -> void:
	if _selected_row == null or not is_instance_valid(_selected_row):
		return
	_selected_row.visible = not _iname.is_empty()
	if _selected_label != null and is_instance_valid(_selected_label):
		_selected_label.text = _iname if not _iname.is_empty() else ""

func _on_if() -> void:
	if _friends == null or _iname.is_empty():
		return
	if not bool(_friends.call("send_request", _iname)):
		_notice("ARKADAS LISTESI DOLU (5/5)" if not bool(_friends.call("can_add_friend")) else "Davet gonderilemedi.")
	else:
		_notice("Davet gonderildi: " + _iname)

func _on_it() -> void:
	if _group == null or _iname.is_empty():
		return
	if not bool(_group.call("invite_player", _iname)):
		_notice("Takim daveti gonderilemedi (4/4?).")
	else:
		_notice("Takim daveti: " + _iname)
	refresh_all()

func _on_im() -> void:
	_expand("CHAT")
	_chat_input.grab_focus()

func simulate_incoming_friend_request(from_player: String) -> void:
	_show_req("friend", str(from_player), "%s arkadaslik istegi gonderdi." % str(from_player))

func _show_req(kind: String, who: String, text: String) -> void:
	_req.set_meta("kind", kind)
	_req.set_meta("who", who)
	_rtext.text = text
	_req.show()

func _on_ra() -> void:
	var kind := str(_req.get_meta("kind"))
	var who := str(_req.get_meta("who"))
	_req.hide()
	if kind == "friend" and _friends != null:
		_friends.call("accept_request", who)
	elif kind == "team" and _group != null:
		_group.call("accept_invite", who)
	refresh_all()

func _on_rr() -> void:
	var kind := str(_req.get_meta("kind"))
	var who := str(_req.get_meta("who"))
	_req.hide()
	if kind == "friend" and _friends != null:
		_friends.call("reject_request", who)
	elif kind == "team" and _group != null:
		_group.call("reject_invite", who)
	refresh_all()

func _notice(t: String) -> void:
	_notice_lbl.text = t
	if _ntw != null and _ntw.is_valid():
		_ntw.kill()
	_ntw = create_tween()
	_ntw.tween_interval(3.0)
	_ntw.tween_callback(_clear_notice)

func _clear_notice() -> void:
	_notice_lbl.text = ""


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			if _req.visible:
				_req.hide()
				get_viewport().set_input_as_handled()
			elif not _iname.is_empty():
				_iname = ""
				_update_selected_row()
				get_viewport().set_input_as_handled()
			elif not _collapsed.get("CHAT", false):
				_collapse("CHAT")
				get_viewport().set_input_as_handled()
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_try_click(mb.position)

func _try_click(spos: Vector2) -> void:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return
	var world: Vector2 = cam.get_screen_center_position() + (spos - get_viewport().get_visible_rect().size * 0.5) / cam.zoom.x
	var best: Node2D = null
	var best_d := 70.0
	for n in get_tree().get_nodes_in_group("remote_players"):
		if n is Node2D and is_instance_valid(n):
			var d: float = (n as Node2D).global_position.distance_to(world)
			if d < best_d:
				best_d = d
				best = n
	if best == null:
		for n in get_tree().get_nodes_in_group("players"):
			if n is Node2D and is_instance_valid(n):
				var me0: Node = get_tree().get_first_node_in_group("player")
				if n == me0:
					continue
				var nm0 := str(n.get_meta("username")) if n.has_meta("username") else ""
				if nm0.is_empty() and ("username" in n):
					nm0 = str(n.get("username"))
				if nm0.is_empty():
					continue
				var d2: float = (n as Node2D).global_position.distance_to(world)
				if d2 < best_d:
					best_d = d2
					best = n
	if best == null:
		return
	if best.get_script() != null and str(best.get_script().resource_path).ends_with("npc.gd"):
		return
	var me2: Node = get_tree().get_first_node_in_group("player")
	if best == me2:
		return
	var nm2 := str(best.get_meta("username")) if best.has_meta("username") else ""
	if nm2.is_empty() and ("username" in best):
		nm2 = str(best.get("username"))
	if nm2.is_empty():
		nm2 = str((best as Node).name)
	show_player_interaction(nm2, spos)

func _process(_dt: float) -> void:
	if _info_lbl == null or _gs == null:
		return
	if _player_ref == null or not is_instance_valid(_player_ref):
		_player_ref = get_tree().get_first_node_in_group("player") as Node2D
	var nm := str(_gs.get("username")) if ("username" in _gs) else ""
	var hpv := 0.0
	var hpm := 1.0
	var shv := 0.0
	var shm := 1.0
	if _player_ref != null:
		if "health" in _player_ref:
			hpv = float(_player_ref.get("health"))
		if "max_health" in _player_ref:
			hpm = float(_player_ref.get("max_health"))
		if "shield" in _player_ref:
			shv = float(_player_ref.get("shield"))
		if "max_shield" in _player_ref:
			shm = float(_player_ref.get("max_shield"))
	_info_lbl.text = "%s\nHP %d/%d\nSH %d/%d" % [(nm if not nm.is_empty() else "-"), int(hpv), int(maxi(1, hpm)), int(shv), int(maxi(1, shm))]
	var lvl := int(_gs.get("level")) if ("level" in _gs) else 1
	var xp := int(_gs.get("xp")) if ("xp" in _gs) else 0
	var honor := int(_gs.get("honor")) if ("honor" in _gs) else 0
	var plt := int(_gs.get("platinum")) if ("platinum" in _gs) else 0
	var btc := int(_gs.get("bitcoin")) if ("bitcoin" in _gs) else 0
	_acct_lbl.text = "LVL %d\nTECRUBE %d\nSEREF %d\nPLT %s\nBTC %s" % [lvl, xp, honor, _fmt(plt), _fmt(btc)]

func _fmt(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3, 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if v < 0 else "") + s + out



func open_active_quests() -> void:
	_refresh_quests()
	windows["QUEST"].set_panel_state("open", false)

func _build_quest_window() -> void:
	var body := _mk("QUEST", "AKTİF GÖREV", Vector2(400, 12), Vector2(260, 235))
	_quest_list = OptionButton.new()
	_quest_list.fit_to_longest_item = false
	body.add_child(_quest_list)
	_quest_list.item_selected.connect(_select_quest)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_quest_detail = _lab(scroll, "", 11)
	_quest_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quest_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toast = _lab(panel_root, "", 11, Color(0.4, 1, 0.7))
	_toast.position = Vector2(400, 260)
	_toast.hide()
	var quests := get_node_or_null("/root/QuestSystem")
	if quests != null:
		quests.quests_changed.connect(_refresh_quests)
		quests.quest_completed.connect(_quest_completed)
	_refresh_quests()

func _refresh_quests() -> void:
	var quests := get_node_or_null("/root/QuestSystem")
	if quests == null:
		return
	var selected := _quest_list.selected
	_quest_ids = quests.get_active_quests()
	_quest_detail.text = "Aktif görev yok. GÖREVLER menüsünden görev al."
	_quest_list.disabled = _quest_ids.is_empty()
	_quest_list.clear()
	for id in _quest_ids:
		var data: Dictionary = quests.get_quest(id)
		_quest_list.add_item(str(data.get("title", id)))
	if not _quest_ids.is_empty():
		selected = clampi(selected, 0, _quest_ids.size() - 1)
		_quest_list.select(selected)
		_select_quest(selected)

func _select_quest(index: int) -> void:
	if index < 0 or index >= _quest_ids.size():
		return
	var quests := get_node("/root/QuestSystem")
	var id: String = _quest_ids[index]
	var data: Dictionary = quests.get_quest(id)
	var rewards: Dictionary = data.get("rewards", {})
	var lines: PackedStringArray = []
	for key in rewards:
		if rewards[key] is Dictionary:
			for item in rewards[key]:
				lines.append("%s × %s" % [item, _fmt(int(rewards[key][item]))])
		else:
			lines.append("%s %s" % [str(key).to_upper(), _fmt(int(rewards[key]))])
	_quest_detail.text = "%s\n\nAmaç: %s\nİlerleme: %d / %d\n\nÖDÜL\n%s" % [data.get("title", id), data.get("description", ""), quests.get_progress(id), quests.get_target(id), "\n".join(lines)]

func _quest_completed(id: String) -> void:
	var data: Dictionary = get_node("/root/QuestSystem").get_quest(id)
	_toast.text = "GÖREV TAMAMLANDI: " + str(data.get("title", id))
	var rewards: Dictionary = data.get("rewards", {})
	for key in rewards:
		if rewards[key] is Dictionary:
			for item in rewards[key]:
				_toast.text += "\n+%d %s" % [int(rewards[key][item]), item]
		else:
			_toast.text += "\n+%d %s" % [int(rewards[key]), str(key).to_upper()]
	_toast.show()
	get_tree().create_timer(3.0).timeout.connect(_toast.hide)

func _integrate_scene_hud() -> void:
	var main := get_parent()
	var menu := main.get_node_or_null("HUD/MenuRoot")
	if menu != null:
		register_modal(menu.get("overlay"))
	for path in ["HUD/TopPanel", "HUD/QuestTracker"]:
		var old := main.get_node_or_null(path)
		if old is CanvasItem:
			old.hide()
	_req.reparent(panel_root)
	_sync_modal()
