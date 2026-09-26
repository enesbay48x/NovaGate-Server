extends CanvasLayer
## NovaGate Social UI - PC first, mobile responsive compact dock.
## Chat tabs + history + input, friends max 5, group max 4 with
## HP/Shield/Level/online, group invite accept/reject.
## No search, no block/ignore, no networking, no target panel changes.

const PC_RECT := Rect2(12, 180, 340, 320)
const MOBILE_RECT := Rect2(8, 120, 300, 250)

var _chat: Node = null
var _friends: Node = null
var _group: Node = null
var _is_mobile := false
var root: PanelContainer
var tab_bar: HBoxContainer
var history: RichTextLabel
var input: LineEdit
var friend_list: VBoxContainer
var friend_input: LineEdit
var friend_title: Label
var group_list: VBoxContainer
var group_input: LineEdit
var group_title: Label
var notice_label: Label

func _ready() -> void:
	layer = 40
	_chat = get_node_or_null("/root/ChatManager")
	_friends = get_node_or_null("/root/FriendManager")
	_group = get_node_or_null("/root/GroupManager")
	_is_mobile = OS.get_name() in ["Android", "iOS"]
	_build()
	_connect_signals()
	refresh_all()
	get_viewport().size_changed.connect(_on_viewport_resized)
	_apply_layout()
func _style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.018, 0.034, 0.052, 0.92)
	sb.border_color = Color(0.20, 0.78, 0.92, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	return sb

func _small(parent: Node, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	parent.add_child(l)
	return l

func _build() -> void:
	root = PanelContainer.new()
	root.name = "SocialDock"
	root.add_theme_stylebox_override("panel", _style())
	add_child(root)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	root.add_child(col)
	var title := Label.new()
	title.text = "SOSYAL"
	title.add_theme_font_size_override("font_size", 12)
	col.add_child(title)
	tab_bar = HBoxContainer.new()
	col.add_child(tab_bar)
	history = RichTextLabel.new()
	history.bbcode_enabled = true
	history.scroll_following = true
	history.custom_minimum_size = Vector2(300, 110)
	col.add_child(history)
	input = LineEdit.new()
	input.placeholder_text = "Mesaj yaz..."
	input.text_submitted.connect(_on_message_submitted)
	col.add_child(input)
	notice_label = _small(col, "")
	friend_title = _small(col, "ARKADASLAR (0/5)")
	friend_list = VBoxContainer.new()
	col.add_child(friend_list)
	var frow := HBoxContainer.new()
	col.add_child(frow)
	friend_input = LineEdit.new()
	friend_input.placeholder_text = "Kullanici adi"
	friend_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frow.add_child(friend_input)
	var add_btn := Button.new()
	add_btn.text = "Davet"
	add_btn.pressed.connect(_on_friend_invite)
	frow.add_child(add_btn)
	group_title = _small(col, "TAKIM (0/4)")
	group_list = VBoxContainer.new()
	col.add_child(group_list)
	var grow := HBoxContainer.new()
	col.add_child(grow)
	group_input = LineEdit.new()
	group_input.placeholder_text = "Takima davet"
	group_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grow.add_child(group_input)
	var gadd := Button.new()
	gadd.text = "Davet"
	gadd.pressed.connect(_on_group_invite)
	grow.add_child(gadd)
	var gleave := Button.new()
	gleave.text = "Ayril"
	gleave.pressed.connect(_on_group_leave)
	grow.add_child(gleave)

func _connect_signals() -> void:
	if _chat != null:
		if _chat.has_signal("message_added"):
			_chat.connect("message_added", _on_message_added)
		if _chat.has_signal("active_channel_changed"):
			_chat.connect("active_channel_changed", _on_active_channel)
		if _chat.has_signal("unread_count_changed"):
			_chat.connect("unread_count_changed", _on_unread)
	if _friends != null:
		for sig in ["friend_added", "friend_removed", "request_received", "request_accepted", "request_rejected"]:
			if _friends.has_signal(sig):
				_friends.connect(sig, refresh_all)
	if _group != null:
		if _group.has_signal("group_changed"):
			_group.connect("group_changed", refresh_all)
		if _group.has_signal("invite_received"):
			_group.connect("invite_received", _on_invite_received)
		if _group.has_signal("notice"):
			_group.connect("notice", _on_notice)

func _on_viewport_resized() -> void:
	_is_mobile = OS.get_name() in ["Android", "iOS"] or get_viewport().get_visible_rect().size.x < 900.0
	_apply_layout()

func _apply_layout() -> void:
	var r := MOBILE_RECT if _is_mobile else PC_RECT
	root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	root.offset_left = r.position.x
	root.offset_top = r.position.y
	root.offset_right = r.end.x
	root.offset_bottom = r.end.y
	history.custom_minimum_size = Vector2(r.size.x - 40, 90.0 if _is_mobile else 110.0)


func refresh_all(_a = null, _b = null) -> void:
	_rebuild_tabs()
	_render_history()
	_render_friends()
	_render_group()

func _visible_channels() -> Array:
	if _chat != null and _chat.has_method("get_visible_channels"):
		return _chat.call("get_visible_channels")
	return ["global_tr", "global_ku", "company"]

func _rebuild_tabs() -> void:
	for c in tab_bar.get_children():
		c.queue_free()
	for kind in _visible_channels():
		var title := str(kind).to_upper()
		if _chat != null and _chat.has_method("get_channel"):
			var ch = _chat.call("get_channel", kind)
			# ChatChannel is a RefCounted (SocialModel.ChatChannel): read .title directly.
			if ch != null and "title" in ch and str(ch.title) != "":
				title = str(ch.title)
		var b := Button.new()
		b.text = title
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 10)
		if _chat != null and "active_channel" in _chat:
			b.button_pressed = str(_chat.active_channel) == str(kind)
		b.pressed.connect(_on_tab.bind(str(kind)))
		tab_bar.add_child(b)

func _on_tab(channel: String) -> void:
	if _chat != null and _chat.has_method("on_channel_tab_pressed"):
		_chat.call("on_channel_tab_pressed", channel)
	refresh_all()

func _on_active_channel(_channel: String) -> void:
	refresh_all()

func _on_unread(_channel: String, _count: int) -> void:
	refresh_all()

func _on_invite_received(_from_player: String) -> void:
	refresh_all()

func _on_message_added(channel: String, _message: Dictionary) -> void:
	if _chat != null and "active_channel" in _chat and str(_chat.active_channel) == channel:
		_render_history()
	_rebuild_tabs()

func _render_history() -> void:
	history.clear()
	if _chat == null:
		return
	var active := str(_chat.active_channel) if (_chat != null and "active_channel" in _chat) else "global_tr"
	var items: Array = _chat.call("get_channel_history", active, 60) if _chat.has_method("get_channel_history") else []
	for m in items:
		if not (m is Dictionary):
			continue
		var mine := bool(m.get("is_mine", false))
		var color := "#9fe8ff" if mine else "#cfe3ee"
		history.append_text("[color=#5b7a8a]%s[/color] [color=%s][b]%s:[/b] %s[/color]\n" % [str(m.get("time_str", "")), color, str(m.get("sender", "")), str(m.get("text", ""))])

func _on_message_submitted(text: String) -> void:
	if _chat == null:
		return
	var send_ch := str(_chat.active_channel) if ("active_channel" in _chat) else "global_tr"
	if bool(_chat.call("send_message", send_ch, text)):
		input.clear()
		_render_history()
func _clear_list(list: VBoxContainer) -> void:
	for c in list.get_children():
		c.queue_free()

func _render_friends() -> void:
	_clear_list(friend_list)
	if _friends == null:
		return
	var views: Array = _friends.call("get_friend_views") if _friends.has_method("get_friend_views") else []
	friend_title.text = "ARKADASLAR (%d/5)" % views.size()
	for v in views:
		if not (v is Dictionary):
			continue
		var h := HBoxContainer.new()
		friend_list.add_child(h)
		var l := Label.new()
		l.text = ("[ON] " if bool(v.get("online", false)) else "[OFF] ") + str(v.get("username", ""))
		l.add_theme_font_size_override("font_size", 11)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		var rm := Button.new()
		rm.text = "X"
		rm.pressed.connect(_on_friend_remove.bind(str(v.get("username", ""))))
		h.add_child(rm)
	var reqs: Array = _friends.call("get_request_views") if _friends.has_method("get_request_views") else []
	for r in reqs:
		if not (r is Dictionary):
			continue
		var h2 := HBoxContainer.new()
		friend_list.add_child(h2)
		var l2 := Label.new()
		l2.text = "Davet: " + str(r.get("from", ""))
		l2.add_theme_font_size_override("font_size", 11)
		l2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h2.add_child(l2)
		var ok := Button.new()
		ok.text = "Kabul"
		ok.pressed.connect(_on_friend_accept.bind(str(r.get("from", ""))))
		h2.add_child(ok)
		var no := Button.new()
		no.text = "Red"
		no.pressed.connect(_on_friend_reject.bind(str(r.get("from", ""))))
		h2.add_child(no)

func _on_friend_invite() -> void:
	if _friends == null:
		return
	if bool(_friends.call("send_request", friend_input.text)):
		friend_input.clear()
		refresh_all()
	else:
		_on_notice("Arkadas daveti gonderilemedi (max 5).")

func _on_friend_accept(who: String) -> void:
	_friends.call("accept_request", who)
	refresh_all()

func _on_friend_reject(who: String) -> void:
	_friends.call("reject_request", who)
	refresh_all()

func _on_friend_remove(who: String) -> void:
	_friends.call("remove_friend", who)
	refresh_all()

func _render_group() -> void:
	_clear_list(group_list)
	if _group == null:
		return
	var members: Array = _group.call("get_members") if _group.has_method("get_members") else []
	group_title.text = "TAKIM (%d/4)" % members.size()
	if members.is_empty():
		_small(group_list, "Takimda degilsin.")
	for m in members:
		if not (m is Dictionary):
			continue
		_small(group_list, "%s%s Lv%d HP %d/%d SH %d/%d %s" % [
			"[L] " if bool(m.get("is_leader", false)) else "",
			str(m.get("username", "")), int(m.get("level", 1)),
			int(m.get("hp", 0)), maxi(1, int(m.get("max_hp", 1))),
			int(m.get("shield", 0)), maxi(1, int(m.get("max_shield", 1))),
			"Cevrimici" if bool(m.get("online", false)) else "Cevrimdisi"])
	var invites: Array = _group.call("get_invite_views") if _group.has_method("get_invite_views") else []
	for inv in invites:
		if not (inv is Dictionary):
			continue
		var h := HBoxContainer.new()
		group_list.add_child(h)
		var l2 := Label.new()
		l2.text = "Takim daveti: " + str(inv.get("from", ""))
		l2.add_theme_font_size_override("font_size", 11)
		l2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l2)
		var ok := Button.new()
		ok.text = "Kabul"
		ok.pressed.connect(_on_group_accept.bind(str(inv.get("from", ""))))
		h.add_child(ok)
		var no := Button.new()
		no.text = "Red"
		no.pressed.connect(_on_group_reject.bind(str(inv.get("from", ""))))
		h.add_child(no)

func _on_group_invite() -> void:
	if _group == null:
		return
	if bool(_group.call("invite_player", group_input.text)):
		group_input.clear()
		refresh_all()

func _on_group_accept(who: String) -> void:
	_group.call("accept_invite", who)
	refresh_all()

func _on_group_reject(who: String) -> void:
	_group.call("reject_invite", who)
	refresh_all()

func _on_group_leave() -> void:
	if _group != null:
		_group.call("leave_group")
	refresh_all()

func _on_notice(text: String) -> void:
	notice_label.text = str(text)
