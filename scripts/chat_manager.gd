## ChatManager — autoload singleton.
## Local/mock implementation with a server-ready API surface.
##
## Public API (designed to swap in a server transport later):
##   send_message(channel, text)      -> bool
##   receive_message(channel, text)   -> void  (server pushes inbound here)
##   set_active_channel(channel)      -> void
##   on_channel_tab_pressed(channel)  -> void
##   toggle_chat()                   -> void
##   mark_current_read()             -> void
##   get_visible_channels()          -> Array
##   get_channel(channel)            -> ChatChannel

extends Node

const MODEL_PATH := "res://scripts/social_model.gd"
const MAX_MESSAGES_PER_CHANNEL := 200

# --- Signals ----------------------------------------------------------------
signal chat_opened
signal chat_closed
signal message_added(channel: String, message: Dictionary)
signal active_channel_changed(channel: String)
signal unread_count_changed(channel: String, count: int)

# --- Local/mock state -------------------------------------------------------
var _model: GDScript = load(MODEL_PATH)
var channels: Dictionary = {}
var active_channel: String = "global_tr"
var chat_open: bool = false
var _current_player: String = ""

func _ready() -> void:
	_rebuild_channels()
	_current_player = _resolve_current_player()
	_connect_group()

func _connect_group() -> void:
	if has_node("/root/GroupManager"):
		var gm = get_node("/root/GroupManager")
		if gm.has_signal("group_changed") and not gm.group_changed.is_connected(_on_group_changed):
			gm.group_changed.connect(_on_group_changed)

func _resolve_current_player() -> String:
	var gs = get_node_or_null("/root/GlobalState")
	if gs != null:
		var uname := str(gs.get("username"))
		if not uname.is_empty():
			return uname
	var am = load("res://scripts/account_manager.gd").new()
	var fallback := str(am.get_current_player())
	am.queue_free()
	return fallback

# --- Public API -------------------------------------------------------------

func send_message(channel: String, text: String) -> bool:
	text = text.strip_edges()
	if text.is_empty() or not channels.has(channel):
		return false
	var msg = _model.ChatMessage.new()
	msg.channel = channel
	msg.sender = _current_player
	msg.text = text
	msg.timestamp = int(Time.get_unix_time_from_system())
	msg.is_mine = true
	return _deliver(channel, msg)

func receive_message(channel: String, text: String, sender: String = "") -> void:
	if not channels.has(channel):
		return
	var msg = _model.ChatMessage.new()
	msg.channel = channel
	msg.sender = sender
	msg.text = text
	msg.timestamp = int(Time.get_unix_time_from_system())
	msg.is_mine = sender == _current_player
	_deliver(channel, msg)

func _deliver(channel: String, message) -> bool:
	var chan = channels[channel]
	chan.append_message(message)
	var view := _message_view(message)
	message_added.emit(channel, view)
	unread_count_changed.emit(channel, chan.unread_count)
	return true

func _message_view(message) -> Dictionary:
	return {
		"text": message.text,
		"sender": message.sender,
		"timestamp": message.timestamp,
		"is_mine": message.is_mine,
		"time_str": _format_time(message.timestamp),
	}

func _format_time(ts: int) -> String:
	if ts <= 0:
		return ""
	return "%02d:%02d" % [(ts % 3600) / 60, ts % 60]

func set_active_channel(channel: String) -> void:
	if not channels.has(channel):
		return
	active_channel = channel
	var chan = channels[channel]
	chan.mark_read()
	unread_count_changed.emit(channel, 0)
	active_channel_changed.emit(channel)

func on_channel_tab_pressed(channel: String) -> void:
	if not _channel_is_visible(channel):
		return
	chat_open = true
	chat_opened.emit()
	set_active_channel(channel)

func get_visible_channels() -> Array:
	var result: Array = []
	for kind in channels.keys():
		if _channel_is_visible(kind):
			result.append(kind)
	return result

func get_channel(channel: String):
	return channels.get(channel)

func get_active_channel() -> String:
	return active_channel

func get_unread_total() -> int:
	var total := 0
	for kind in get_visible_channels():
		total += channels[kind].unread_count
	return total

func toggle_chat() -> void:
	chat_open = not chat_open
	if chat_open:
		chat_opened.emit()
		if channels.has(active_channel):
			channels[active_channel].mark_read()
			unread_count_changed.emit(active_channel, 0)
	else:
		chat_closed.emit()

func mark_current_read() -> void:
	if channels.has(active_channel):
		channels[active_channel].mark_read()
		unread_count_changed.emit(active_channel, 0)

func close_chat() -> void:
	if chat_open:
		chat_open = false
		chat_closed.emit()

func _rebuild_channels() -> void:
	channels = _model.build_default_channels()

# --- Group visibility integration ------------------------------------------
# When a group forms or disbands, the GRUP channel must appear/disappear.

func activate_profile(value: String) -> void:
	_current_player = value.strip_edges()
	_rebuild_channels()

func refresh_profile() -> void:
	var resolved := _resolve_current_player()
	if not resolved.is_empty():
		_current_player = resolved

func _channel_is_visible(channel: String) -> bool:
	match channel:
		"global_tr", "global_ku", "company":
			return true
		"group":
			return _group_active()
		"whisper":
			return _has_friends()
	return false

func _has_friends() -> bool:
	var fm = get_node_or_null("/root/FriendManager") as Node
	if fm == null:
		return false
	return fm.has_method("get_friends") and int(fm.call("get_friends").size()) > 0

func get_channel_history(channel: String, limit: int = 60) -> Array:
	if not channels.has(channel):
		return []
	return channels[channel].history_views(limit)

func _group_active() -> bool:
	var gm = get_node_or_null("/root/GroupManager") as Node
	if gm == null:
		return false
	return gm.has_method("in_group") and bool(gm.call("in_group", _current_player))

func _on_group_changed() -> void:
	if channels.has("group"):
		channels["group"].mark_read()
		unread_count_changed.emit("group", 0)
	if not _group_active() and active_channel == "group":
		set_active_channel("global_tr")

