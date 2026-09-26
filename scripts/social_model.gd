class_name SocialModel
extends RefCounted

## Serializable DTO dictionaries: managers validate inbound events; UI gets copies.
## Stable username is the local identity; transport can map it to server IDs later.
const CHANNELS := {"global_tr": "GLOBAL TR", "global_ku": "GLOBAL KU", "company": "SIRKET", "group": "GRUP", "whisper": "OZEL"}
const CHANNEL_ORDER := ["global_tr", "global_ku", "company", "group", "whisper"]

static func valid_name(value: String) -> bool:
	return not value.strip_edges().is_empty() and value.length() <= 48 and not "\n" in value

static func member(username: String, leader: bool = false) -> Dictionary:
	return {"username": username, "is_leader": leader, "online": true,
		"level": 1, "hp": 0, "max_hp": 1, "shield": 0, "max_shield": 1, "map": ""}

static func request(from_player: String, to_player: String) -> Dictionary:
	return {"from": from_player, "to": to_player, "timestamp": int(Time.get_unix_time_from_system())}

static func channel_title(channel: String) -> String:
	return str(CHANNELS.get(channel, channel.to_upper()))

# --- Inner data types (used by managers via preload const Model) ---

class ChatMessage:
	extends RefCounted
	var channel: String = "global_tr"
	var sender: String = ""
	var text: String = ""
	var timestamp: int = 0
	var is_mine: bool = false

	func to_view() -> Dictionary:
		var t := ""
		if timestamp > 0:
			t = "%02d:%02d" % [(timestamp % 3600) / 60, timestamp % 60]
		return {"text": text, "sender": sender, "timestamp": timestamp, "is_mine": is_mine, "time_str": t, "channel": channel}

class ChatChannel:
	extends RefCounted
	var kind: String = "global_tr"
	var title: String = "GLOBAL TR"
	var messages: Array = []
	var unread_count: int = 0
	var max_messages: int = 200

	func append_message(message: RefCounted) -> void:
		messages.append(message)
		while messages.size() > max_messages:
			messages.pop_front()
		# Own messages never raise unread; inbound messages do.
		# ChatMessage is a RefCounted: Object.get() takes exactly 1 arg, so use
		# direct property access guarded by "in" instead of 2-arg Dictionary.get().
		var mine := bool(message.is_mine) if ("is_mine" in message) else false
		if not mine:
			unread_count += 1

	func mark_read() -> void:
		unread_count = 0

	func history_views(limit: int = 60) -> Array:
		var out: Array = []
		var start := maxi(0, messages.size() - limit)
		for i in range(start, messages.size()):
			var m = messages[i]
			out.append(m.to_view() if m.has_method("to_view") else {})
		return out

class Friend:
	extends RefCounted
	var username: String = ""
	var online: bool = false
	var same_map: bool = false

	func to_view() -> Dictionary:
		return {"username": username, "online": online, "same_map": same_map}

class FriendRequest:
	extends RefCounted
	var from_player: String = ""
	var to_player: String = ""
	var status: String = "pending"
	var timestamp: int = 0

	func to_view() -> Dictionary:
		return {"from": from_player, "to": to_player, "status": status, "timestamp": timestamp}

static func build_default_channels() -> Dictionary:
	var out := {}
	for kind in CHANNEL_ORDER:
		var c := ChatChannel.new()
		c.kind = kind
		c.title = channel_title(kind)
		out[kind] = c
	return out

