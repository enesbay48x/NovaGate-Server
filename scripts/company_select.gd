extends Control

@onready var mmo_button: Button = $MMO
@onready var eic_button: Button = $EIC
@onready var vru_button: Button = $VRU

func _ready() -> void:
	if not mmo_button.pressed.is_connected(_on_mmo_pressed):
		mmo_button.pressed.connect(_on_mmo_pressed)
	if not eic_button.pressed.is_connected(_on_eic_pressed):
		eic_button.pressed.connect(_on_eic_pressed)
	if not vru_button.pressed.is_connected(_on_vru_pressed):
		vru_button.pressed.connect(_on_vru_pressed)

func _on_mmo_pressed() -> void:
	await _select_company("MMO")

func _on_eic_pressed() -> void:
	await _select_company("EIC")

func _on_vru_pressed() -> void:
	await _select_company("VRU")

func _select_company(company_code: String) -> void:
	if GlobalState.username.is_empty():
		print("ŞİRKET KAYDI HATASI: username boş")
		return
	_set_buttons_disabled(true)

	var account_manager = load("res://scripts/account_manager.gd").new()
	add_child(account_manager)
	var company_result: Dictionary = await account_manager.server_update_company(company_code.strip_edges().to_upper())
	if not bool(company_result.get("basarili", false)):
		print("ŞİRKET SUNUCUYA KAYDEDİLEMEDİ: ", company_result.get("mesaj", "bilinmeyen hata"))
		account_manager.queue_free()
		_set_buttons_disabled(false)
		return

	GlobalState.company = company_code.strip_edges().to_upper()
	GlobalState.start_map = GlobalState.company_start_map(GlobalState.company)
	GlobalState.save_game()
	account_manager.save_company(GlobalState.username, GlobalState.company)
	account_manager.save_active_user(GlobalState.username)

	print("ŞİRKET KAYDEDİLDİ: ", GlobalState.company)
	print("HARİTA: ", GlobalState.start_map)

	# The world WebSocket is started ONLY after the company is persisted, so
	# the `welcome` handshake already carries the server-side company. This is
	# the first-login path: no second login is required afterwards.
	var access_token := str(account_manager.access_token)
	var player_id := str(GlobalState.player_id)
	if player_id.is_empty():
		player_id = str(account_manager.get_active_player_id())
	if not player_id.is_empty():
		GlobalState.player_id = player_id
	if access_token.is_empty() or player_id.is_empty():
		print("ŞİRKET SONRASI HATA: sunucu oturumu bulunamadı")
		account_manager.queue_free()
		_set_buttons_disabled(false)
		return

	var ws_url: String = account_manager._get_ws_url()
	account_manager.queue_free()

	_start_world_websocket(ws_url, access_token, player_id)
	var ws_session = get_node_or_null("/root/NovaGateWSClient")
	if ws_session == null or not await _wait_for_websocket(ws_session, 8.0):
		print("WebSocket bağlantısı kurulamadı")
		_set_buttons_disabled(false)
		return

	GlobalState.server_session_active = true
	# Same post-login steps the login screen performs, so a first-time player
	# is not left without quests/social once they enter the world.
	if has_node("/root/QuestSystem"):
		QuestSystem.activate_profile(GlobalState.username)
	_activate_social(GlobalState.username)
	_set_buttons_disabled(false)
	get_tree().change_scene_to_file("res://scenes/main.tscn")

# Same bring-up the login screen uses, so a first-time player and a returning
# player end up with an identical world session.
func _start_world_websocket(ws_url: String, access_token: String, player_id: String) -> void:
	var ws_node = get_node_or_null("/root/NovaGateWSClient")
	if ws_node == null:
		var ws_script = load("res://scripts/novagate_ws_client.gd")
		ws_node = ws_script.new()
		ws_node.name = "NovaGateWSClient"
		get_tree().root.add_child(ws_node)
	if bool(ws_node.call("is_ws_connected")):
		ws_node.call("disconnect_from_server")
	ws_node.call("connect_to_server", ws_url, access_token, player_id, GlobalState.username)


func _wait_for_websocket(ws_session: Node, timeout_seconds: float) -> bool:
	var started_msec := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_msec < int(timeout_seconds * 1000.0):
		if bool(ws_session.call("is_ws_connected")):
			return true
		await get_tree().process_frame
	return bool(ws_session.call("is_ws_connected"))


func _activate_social(username: String) -> void:
	for path in ["/root/ChatManager", "/root/FriendManager", "/root/GroupManager"]:
		if has_node(path):
			var n = get_node(path)
			if n.has_method("activate_profile"):
				n.call("activate_profile", username)

func _set_buttons_disabled(value: bool) -> void:
	mmo_button.disabled = value
	eic_button.disabled = value
	vru_button.disabled = value
