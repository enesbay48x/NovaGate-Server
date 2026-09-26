extends Node
## Local roster authority. No network or persistent mock groups.
signal group_changed
signal invite_received(from_player: String)
signal notice(text: String)
signal outbound(operation: String, payload: Dictionary)
const Model = preload("res://scripts/social_model.gd")
const MAX_MEMBERS := 4
var username := ""
var group_id := ""
var members: Dictionary = {}
var invites: Dictionary = {}
var sent_invites: Dictionary = {}

func activate_profile(value: String) -> void:
	if username == value:
		return
	leave_group()
	invites.clear()
	username = value

func create_group() -> bool:
	if username.is_empty() or not members.is_empty():
		return false
	group_id = username + ":" + str(Time.get_ticks_usec())
	members[username] = Model.member(username, true)
	group_changed.emit()
	return true

func in_group(player: String = "") -> bool:
	return members.has(username if player.is_empty() else player)

func is_leader() -> bool:
	return members.has(username) and bool(members[username].get("is_leader", false))

func get_members() -> Array:
	return members.values().duplicate(true)

func invite_player(player: String) -> bool:
	if not Model.valid_name(player) or player == username:
		return false
	if members.is_empty():
		create_group()
	if not is_leader() or members.has(player) or members.size() >= MAX_MEMBERS or sent_invites.has(player):
		notice.emit("Takım dolu (4/4) veya davet gönderilemiyor.")
		return false
	sent_invites[player] = group_id
	outbound.emit("invite", {"from": username, "to": player, "group_id": group_id})
	return true

## Mock/transport response to a previously sent invitation.
func receive_invite_response(player: String, accepted: bool) -> bool:
	if sent_invites.get(player, "") != group_id or group_id.is_empty():
		return false
	sent_invites.erase(player)
	if accepted:
		if members.size() >= MAX_MEMBERS or members.has(player):
			return false
		members[player] = Model.member(player)
		group_changed.emit()
	return true

func receive_invite(from_player: String, id: String, roster: Array) -> bool:
	if in_group() or not Model.valid_name(from_player) or id.is_empty() or invites.size() >= 20:
		return false
	var checked: Dictionary = {}
	for entry in roster:
		if not entry is Dictionary or not Model.valid_name(str(entry.get("username", ""))):
			return false
		var name_value := str(entry.get("username", ""))
		if checked.has(name_value) or name_value == username:
			return false
		checked[name_value] = Model.member(name_value, name_value == from_player)
	if not checked.has(from_player) or checked.size() >= MAX_MEMBERS:
		return false
	invites[from_player] = {"group_id": id, "members": checked}
	invite_received.emit(from_player)
	group_changed.emit()
	return true

func accept_invite(from_player: String) -> bool:
	if in_group() or not invites.has(from_player):
		return false
	var invitation: Dictionary = invites[from_player]
	group_id = str(invitation.get("group_id", ""))
	members = (invitation.get("members", {}) as Dictionary).duplicate(true)
	members[username] = Model.member(username)
	invites.clear()
	outbound.emit("accept_invite", {"from": from_player, "group_id": group_id})
	group_changed.emit()
	return true

func reject_invite(from_player: String) -> bool:
	if not invites.has(from_player):
		return false
	invites.erase(from_player)
	outbound.emit("reject_invite", {"from": from_player})
	group_changed.emit()
	return true

func leave_group() -> bool:
	var existed := not group_id.is_empty()
	outbound.emit("leave_group", {"group_id": group_id})
	group_id = ""
	members.clear()
	sent_invites.clear()
	group_changed.emit()
	return existed

func disband_group() -> bool:
	if not is_leader():
		return false
	return leave_group()

func remove_member(player: String) -> bool:
	if not is_leader() or not members.has(player) or player == username:
		return false
	members.erase(player)
	group_changed.emit()
	return true

func update_member(player: String, status: Dictionary) -> void:
	if not members.has(player):
		return
	for key in ["level", "hp", "max_hp", "shield", "max_shield"]:
		if status.has(key):
			members[player][key] = maxi(0, int(status[key]))
	if status.has("online"):
		members[player]["online"] = bool(status["online"])
	if status.has("map"):
		members[player]["map"] = str(status["map"])
	group_changed.emit()

func get_invite_views() -> Array:
	var out: Array = []
	for from_player in invites.keys():
		out.append({"from": from_player, "group_id": str(invites[from_player].get("group_id", ""))})
	return out

func get_leader_name() -> String:
	for name_value in members.keys():
		if bool(members[name_value].get("is_leader", false)):
			return str(name_value)
	return ""

