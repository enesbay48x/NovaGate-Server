extends Control

@onready var username_input: LineEdit = $Username
@onready var password_input: LineEdit = $Password
@onready var login_button: Button = $LoginButton
@onready var register_button: Button = $RegisterButton

func _ready() -> void:
	if not login_button.pressed.is_connected(_on_login_pressed):
		login_button.pressed.connect(_on_login_pressed)
	if not register_button.pressed.is_connected(_on_register_pressed):
		register_button.pressed.connect(_on_register_pressed)

	# Restore only the last selected username. Passwords are never read from
	# local account/save files and are intentionally left for user entry.
	var account_manager = load("res://scripts/account_manager.gd").new()
	var active_username := str(account_manager.get_current_player()).strip_edges()
	if not active_username.is_empty():
		username_input.text = active_username
	account_manager.queue_free()

func _get_account_manager():
	var am = load("res://scripts/account_manager.gd").new()
	add_child(am)
	return am

func _on_login_pressed() -> void:
	var timing_started_msec := Time.get_ticks_msec()
	var username: String = username_input.text.strip_edges()
	var password: String = password_input.text
	if username.is_empty() or password.is_empty():
		print("Kullanıcı adı veya şifre boş")
		return
	print("LOGIN_TIMING button_pressed elapsed_ms=0")
	_set_buttons_disabled(true)

	var account_manager = _get_account_manager()
	print("LOGIN_TIMING local_login_start elapsed_ms=", Time.get_ticks_msec() - timing_started_msec)
	# Online login is one authoritative flow: local credentials are never a fallback.
	print("LOGIN_TIMING server_login_start elapsed_ms=", Time.get_ticks_msec() - timing_started_msec)
	var server_result: Dictionary = await account_manager.server_login(username, password)
	print("LOGIN_TIMING server_login_returned elapsed_ms=", Time.get_ticks_msec() - timing_started_msec, " success=", bool(server_result.get("basarili", false)))
	if not bool(server_result.get("basarili", false)):
		print("LOGIN_TIMING login_aborted elapsed_ms=", Time.get_ticks_msec() - timing_started_msec, " stage=server_login")
		account_manager.queue_free()
		_set_buttons_disabled(false)
		return

	# The server response is authoritative for routing; local player cache is not.
	GlobalState.username = username
	var server_company := str(server_result.get("company", "")).strip_edges().to_upper()
	GlobalState.company = server_company if ["EIC", "MMO", "VRU"].has(server_company) else ""
	print("LOGIN_TIMING player_data_loaded elapsed_ms=", Time.get_ticks_msec() - timing_started_msec, " username=", GlobalState.username, " company=", GlobalState.company)

	# A brand-new account has no company yet. The world WebSocket must NOT be
	# opened before the company exists: the `welcome` handshake would carry an
	# empty company, every world_update would report a neutral relation and
	# the player would have to log in a second time to get a correct session.
	# The company is picked first, then the very same login continues into
	# the world through company_select.tscn.
	if GlobalState.company.is_empty():
		account_manager.queue_free()
		_set_buttons_disabled(false)
		print("LOGIN_TIMING company_required elapsed_ms=", Time.get_ticks_msec() - timing_started_msec, " scene=res://scenes/company_select.tscn")
		get_tree().call_deferred("change_scene_to_file", "res://scenes/company_select.tscn")
		return

	var ws_url: String = account_manager._get_ws_url()
	_start_websocket_client(username, str(server_result.get("access_token", account_manager.access_token)), str(server_result.get("player_id", GlobalState.player_id)), ws_url)
	print("LOGIN_TIMING websocket_start elapsed_ms=", Time.get_ticks_msec() - timing_started_msec)
	var ws_session = get_node_or_null("/root/NovaGateWSClient")
	if ws_session == null:
		print("LOGIN_TIMING websocket_failed elapsed_ms=", Time.get_ticks_msec() - timing_started_msec, " reason=node_missing")
		account_manager.queue_free()
		_set_buttons_disabled(false)
		return
	var ws_connected := await _wait_for_websocket(ws_session, 8.0)
	print("LOGIN_TIMING websocket_connected elapsed_ms=", Time.get_ticks_msec() - timing_started_msec, " success=", ws_connected)
	if not ws_connected:
		account_manager.queue_free()
		_set_buttons_disabled(false)
		return

	GlobalState.server_session_active = true
	QuestSystem.activate_profile(GlobalState.username)
	_activate_social(GlobalState.username)
	account_manager.queue_free()
	_set_buttons_disabled(false)

	print("LOGIN_TIMING company_check elapsed_ms=", Time.get_ticks_msec() - timing_started_msec, " has_company=", not GlobalState.company.is_empty())
	var target_scene := "res://scenes/main.tscn" if not GlobalState.company.is_empty() else "res://scenes/company_select.tscn"
	print("LOGIN_TIMING scene_change elapsed_ms=", Time.get_ticks_msec() - timing_started_msec, " scene=", target_scene)
	get_tree().call_deferred("change_scene_to_file", target_scene)

func _wait_for_websocket(ws_session: Node, timeout_seconds: float) -> bool:
	var started_msec := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started_msec < int(timeout_seconds * 1000.0):
		if bool(ws_session.call("is_ws_connected")):
			return true
		await get_tree().process_frame
	return bool(ws_session.call("is_ws_connected"))


# Resolved through AccountManager so login, company_select and every other
# consumer share ONE endpoint configuration (local dev vs production).
func _get_ws_url() -> String:
	var account_manager_script = load("res://scripts/account_manager.gd")
	return account_manager_script.get_ws_endpoint()


# The player id must survive the scene change into company_select.tscn, which
# is where the world WebSocket is started for a brand-new account.
# The access token needs no hand-off: AccountManager persists it to
# user://access_token.txt in server_login, and company_select loads it back
# through the same _load_tokens() path.
func _persist_session_for_world(username: String, access_token: String, player_id: String) -> void:
	if not username.is_empty():
		GlobalState.username = username
	if not player_id.is_empty():
		GlobalState.player_id = player_id

func _start_websocket_client(username: String, access_token: String, player_id: String, ws_url: String) -> void:
	var ws_node = get_node_or_null("/root/NovaGateWSClient")
	if ws_node == null:
		var ws_script = load("res://scripts/novagate_ws_client.gd")
		ws_node = ws_script.new()
		ws_node.name = "NovaGateWSClient"
		get_tree().root.add_child(ws_node)
	if bool(ws_node.call("is_ws_connected")):
		ws_node.call("disconnect_from_server")
	var pid = player_id
	if pid.is_empty():
		pid = GlobalState.player_id
	ws_node.call("connect_to_server", ws_url, access_token, pid, username)

func _on_register_pressed() -> void:
	var username: String = username_input.text.strip_edges()
	var password: String = password_input.text
	if username.is_empty() or password.is_empty():
		print("Kayıt için kullanıcı adı ve şifre gerekli")
		return
	_set_buttons_disabled(true)

	var account_manager = _get_account_manager()

	# Step 1: create the account through the standard server pipeline.
	var server_result: Dictionary = await account_manager.server_register(username, password, username, "")
	if not bool(server_result.get("basarili", false)):
		print("Server kaydı başarısız: ", server_result.get("mesaj", "bilinmeyen hata"))
		account_manager.queue_free()
		_set_buttons_disabled(false)
		return

	print("Server hesabı oluşturuldu")

	# Step 2: a registered account continues through the SAME pipeline as a
	# normal login: server login -> WebSocket -> world snapshot. No local
	# password file is written and no offline shortcut is taken.
	var login_result: Dictionary = await account_manager.server_login(username, password)
	if not bool(login_result.get("basarili", false)):
		print("Giriş başarısız: ", login_result.get("mesaj", "bilinmeyen hata"))
		account_manager.queue_free()
		_set_buttons_disabled(false)
		return

	GlobalState.username = username
	var server_company := str(login_result.get("company", "")).strip_edges().to_upper()
	GlobalState.company = server_company if ["EIC", "MMO", "VRU"].has(server_company) else ""
	GlobalState.save_game()
	account_manager.queue_free()
	_set_buttons_disabled(false)

	# Same rule as the normal login: a new account has no company yet, so the
	# world WebSocket is only started after the company has been persisted by
	# company_select.tscn. This keeps the `welcome` payload correct without a
	# second login.
	if GlobalState.company.is_empty():
		print("ŞİRKET SEÇİMİ GEREKLİ: ", GlobalState.username)
		get_tree().call_deferred("change_scene_to_file", "res://scenes/company_select.tscn")
		return

	var access_token := str(login_result.get("access_token", ""))
	var player_id := str(login_result.get("player_id", GlobalState.player_id))
	# The WebSocket is started from company_select.tscn when a company is still
	# missing, so the access token + player id must survive this scene change.
	# They are persisted by AccountManager (server_login already saved them);
	# re-saving here keeps the pair consistent for the next scene.
	_persist_session_for_world(username, access_token, player_id)
	var ws_url: String = _get_ws_url()
	_start_websocket_client(username, access_token, player_id, ws_url)
	var ws_session = get_node_or_null("/root/NovaGateWSClient")
	if ws_session == null or not await _wait_for_websocket(ws_session, 8.0):
		print("WebSocket bağlantısı kurulamadı")
		_set_buttons_disabled(false)
		return

	GlobalState.server_session_active = true
	QuestSystem.activate_profile(GlobalState.username)
	_activate_social(GlobalState.username)
	get_tree().call_deferred("change_scene_to_file", "res://scenes/main.tscn")

func _set_buttons_disabled(value: bool) -> void:
	login_button.disabled = value
	register_button.disabled = value

func _activate_social(username: String) -> void:
	for path in ["/root/ChatManager", "/root/FriendManager", "/root/GroupManager"]:
		if has_node(path):
			var n = get_node(path)
			if n.has_method("activate_profile"):
				n.call("activate_profile", username)
