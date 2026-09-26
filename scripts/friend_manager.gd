## FriendManager — autoload singleton.
## Local/mock friend/friend-request storage with a server-ready API surface.
##
## Public API:
##   send_request(to_player)        -> bool
##   accept_request(from_player)    -> bool
##   reject_request(from_player)    -> bool
##   remove_friend(username)        -> bool
##   get_friends()                  -> Array[Friend]
##   get_requests()                 -> Array[FriendRequest]
##   is_friend(username)            -> bool
##   can_add_friend()               -> bool

extends Node

const MODEL_PATH := "res://scripts/social_model.gd"
const MAX_FRIENDS := 5
const SAVE_SUBDIR := "user://novagate_social"

signal friend_added(username: String)
signal friend_removed(username: String)
signal request_received(from_player: String)
signal request_accepted(from_player: String)
signal request_rejected(from_player: String)

var _model: GDScript = load(MODEL_PATH)
var _friends: Array = []
var _requests: Array = []
var _current_player: String = ""

func _ready() -> void:
	_current_player = _resolve_current_player()
	_load()

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

func can_add_friend() -> bool:
	return _friends.size() < MAX_FRIENDS

func is_friend(username: String) -> bool:
	return _find_friend(username) != null

func get_friends() -> Array:
	return _friends.duplicate()

func get_requests() -> Array:
	return _requests.duplicate()

func send_request(to_player: String) -> bool:
	to_player = to_player.strip_edges()
	if to_player.is_empty() or to_player == _current_player:
		return false
	if is_friend(to_player):
		return false
	if _find_request_to(to_player) != null:
		return false
	if not can_add_friend():
		return false
	var req = _model.FriendRequest.new()
	req.from_player = _current_player
	req.to_player = to_player
	req.status = "pending"
	req.timestamp = Time.get_unix_time_from_system()
	_requests.append(req)
	request_received.emit(_current_player)
	_save()
	return true

func accept_request(from_player: String) -> bool:
	var req = _find_request_from(from_player)
	if req == null:
		return false
	req.status = "accepted"
	_add_friend(from_player)
	_remove_request(req)
	_save()
	request_accepted.emit(from_player)
	return true

func reject_request(from_player: String) -> bool:
	var req = _find_request_from(from_player)
	if req == null:
		return false
	_remove_request(req)
	_save()
	request_rejected.emit(from_player)
	return true

func activate_profile(value: String) -> void:
	_current_player = value.strip_edges()
	_friends.clear()
	_requests.clear()
	_load()

func get_friend_views() -> Array:
	var out: Array = []
	for f in _friends:
		out.append({"username": f.username, "online": f.online, "same_map": f.same_map})
	return out

func get_request_views() -> Array:
	var out: Array = []
	for r in _requests:
		out.append({"from": r.from_player, "to": r.to_player, "status": r.status, "timestamp": r.timestamp})
	return out

func remove_friend(username: String) -> bool:
	var idx := _find_friend_index(username)
	if idx < 0:
		return false
	_friends.remove_at(idx)
	_save()
	friend_removed.emit(username)
	return true

# --- Local/mock event helpers ------------------------------------------------
# Real server would deliver roster updates here; local mock simulates them.

func set_friend_online(username: String, online: bool, same_map: bool = false) -> void:
	var f = _find_friend(username)
	if f == null:
		return
	f.online = online
	f.same_map = same_map

func add_friend_direct(username: String) -> bool:
	if is_friend(username) or not can_add_friend():
		return false
	_add_friend(username)
	_save()
	friend_added.emit(username)
	return true

# --- Internal ---------------------------------------------------------------

func _add_friend(username: String) -> void:
	var f = _model.Friend.new()
	f.username = username
	f.online = true
	f.same_map = true
	_friends.append(f)

func _find_friend(username: String):
	for f in _friends:
		if f.username == username:
			return f
	return null

func _find_friend_index(username: String) -> int:
	for i in range(_friends.size()):
		if _friends[i].username == username:
			return i
	return -1

func _find_request_from(from_player: String):
	for r in _requests:
		if r.from_player == from_player and r.status == "pending":
			return r
	return null

func _find_request_to(to_player: String):
	for r in _requests:
		if r.to_player == to_player and r.status == "pending":
			return r
	return null

func _remove_request(req) -> void:
	for i in range(_requests.size() - 1, -1, -1):
		if _requests[i] == req:
			_requests.remove_at(i)
			break

func _save_path() -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_SUBDIR))
	return SAVE_SUBDIR.path_join(_current_player.to_lower().sha256_text() + ".json")

func _save() -> void:
	if _current_player.is_empty():
		return
	var file := FileAccess.open(_save_path(), FileAccess.WRITE)
	if file != null:
		var data := {
			"friends": [],
			"requests": [],
		}
		for f in _friends:
			data["friends"].append({"username": f.username, "online": f.online, "same_map": f.same_map})
		for r in _requests:
			data["requests"].append({
				"from": r.from_player, "to": r.to_player, "status": r.status, "timestamp": r.timestamp,
			})
		file.store_string(JSON.stringify(data))
		file.close()

func _load() -> void:
	if _current_player.is_empty():
		return
	var path := _save_path()
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return
	for entry in parsed.get("friends", []):
		if entry is Dictionary and not str(entry.get("username", "")).is_empty():
			var f = _model.Friend.new()
			f.username = entry["username"]
			f.online = entry.get("online", false)
			f.same_map = entry.get("same_map", false)
			_friends.append(f)
	for entry in parsed.get("requests", []):
		if entry is Dictionary:
			var r = _model.FriendRequest.new()
			r.from_player = entry.get("from", "")
			r.to_player = entry.get("to", "")
			r.status = entry.get("status", "pending")
			r.timestamp = entry.get("timestamp", 0)
			_requests.append(r)

