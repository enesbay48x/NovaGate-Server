extends Node

var http_request: HTTPRequest
var server_http := HTTPRequest.new()

func _ready():
	# Menü açıkken SceneTree pause oluyor. Market/login HTTP istekleri
	# pause sırasında da devam etmek zorunda.
	process_mode = Node.PROCESS_MODE_ALWAYS

	http_request = HTTPRequest.new()
	http_request.process_mode = Node.PROCESS_MODE_ALWAYS
	http_request.timeout = 20.0
	add_child(http_request)

	_load_tokens()
	if not access_token.is_empty():
		# Verify token validity asynchronously
		_verify_token_with_server()

const SAVE_FILE = "user://players.json"
const ACTIVE_USER = "user://active_user.txt"
const ACTIVE_PLAYER_ID = "user://active_player_id.txt"
const ACCESS_TOKEN_FILE = "user://access_token.txt"
const REFRESH_TOKEN_FILE = "user://refresh_token.txt"

var current_username:String = ""
var access_token: String = ""
var refresh_token: String = ""


func _save_tokens(token_access: String, token_refresh: String) -> void:
	access_token = token_access
	refresh_token = token_refresh
	var f = FileAccess.open(ACCESS_TOKEN_FILE, FileAccess.WRITE)
	if f:
		f.store_string(token_access)
		f.close()
	f = FileAccess.open(REFRESH_TOKEN_FILE, FileAccess.WRITE)
	if f:
		f.store_string(token_refresh)
		f.close()


func _load_tokens() -> void:
	var f = FileAccess.open(ACCESS_TOKEN_FILE, FileAccess.READ)
	if f:
		access_token = f.get_as_text()
		f.close()
	f = FileAccess.open(REFRESH_TOKEN_FILE, FileAccess.READ)
	if f:
		refresh_token = f.get_as_text()
		f.close()


func _clear_tokens() -> void:
	access_token = ""
	refresh_token = ""
	DirAccess.remove_absolute(ACCESS_TOKEN_FILE)
	DirAccess.remove_absolute(REFRESH_TOKEN_FILE)


func _set_server_url(url: String) -> void:
	# Setting an explicit endpoint is a process-wide switch, not a per-instance
	# one: every AccountManager must resolve the same server.
	set_server_endpoint(url)


func _get_server_url() -> String:
	# Resolved from the process-wide endpoint so every AccountManager
	# instance (login, company_select, market, player_ship...) targets the
	# SAME server instead of silently defaulting to production.
	return get_server_endpoint()

func _get_ws_url() -> String:
	# Always derived from the resolved HTTP endpoint, so the WebSocket can
	# never disagree with the REST calls (local dev stays on 127.0.0.1).
	return get_ws_endpoint()


func _verify_token_with_server() -> void:
	if access_token.is_empty():
		return

	var http := HTTPRequest.new()
	get_tree().root.add_child(http)

	var base_url := _get_server_url()
	if base_url.is_empty():
		return
	var url := base_url + "/auth/verify"
	var headers := ["Content-Type: application/json", "Authorization: Bearer " + access_token]

	var err := http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code = result[1]
	if response_code != 200:
		_clear_tokens()
		GlobalState.server_session_active = false

# PHASE 1 - canonical item ids.
#
# These keys MUST match the server's item_catalog ids (server/item_catalog.py).
# They used to be display names ("LF1", "Kalkan 1", "Hız 1"), which is why the
# server-granted `kalkan1` was invisible in the UI: the UI looked up "Kalkan 1"
# and found 0. Both spellings are now folded onto the canonical id on the way
# in, so an OLD players.json / _save.json keeps working unchanged.
func canonical_item_id(raw: String) -> String:
	var text := raw.strip_edges().to_lower()
	# Turkish dotless i -> i, so "Hiz 1" and "Hız 1" agree.
	text = text.replace("ı", "i").replace("İ", "i")
	var spaced := " ".join(text.split(" "))
	match spaced:
		"kalkan 1", "kalkan i", "kalkan_1", "kalkan-1":
			return "kalkan1"
		"kalkan 2", "kalkan ii", "kalkan_2", "kalkan-2":
			return "kalkan2"
		"hiz 1", "hiz i", "hiz_1", "hiz-1":
			return "hiz1"
		"hiz 2", "hiz ii", "hiz_2", "hiz-2":
			return "hiz2"
		"lf 1", "lf_1", "lf-1":
			return "lf1"
		"lf 2", "lf_2", "lf-2":
			return "lf2"
		"lf 3", "lf_3", "lf-3":
			return "lf3"
		"3 saniye", "uc saniye", "uc_saniye":
			return "uc_saniye"
		"plus droid", "plus", "droid_plus_1":
			return "droid_plus_1"
		"zeus droid", "zeus", "droid_zeus_1":
			return "droid_zeus_1"
		"ema", "enc", "nukleer", "pbmb", "wsh", "emp", "invis", "frep", "acpr":
			return spaced
		_:
			# Unknown: collapse separators so "Kalkan 3" -> "kalkan3".
			return spaced.replace(" ", "").replace("_", "").replace("-", "")


func _default_inventory() -> Dictionary:
	# Canonical ids, all at 0. An absent item and a 0-quantity item mean the
	# same thing, so this only establishes a stable key set for the UI.
	return {
		"lf1": 0,
		"lf2": 0,
		"lf3": 0,
		"kalkan1": 0,
		"kalkan2": 0,
		"hiz1": 0,
		"hiz2": 0,
		"ema": 0,
		"enc": 0,
		"nukleer": 0,
		"uc_saniye": 0,
		"pbmb": 0,
		"wsh": 0,
		"emp": 0,
		"invis": 0,
		"frep": 0,
		"acpr": 0,
	}


func _canonicalize_inventory(raw: Dictionary) -> Dictionary:
	# Fold every key onto its canonical id, summing any colliding spellings so
	# one physical item is never counted twice.
	var out: Dictionary = {}
	for key in raw.keys():
		var cid := canonical_item_id(str(key))
		if cid.is_empty():
			continue
		var qty := maxi(int(raw.get(key, 0)), 0)
		out[cid] = maxi(int(out.get(cid, 0)), 0) + qty
	return out

func _ensure_player_defaults(player: Dictionary) -> void:
	if not player.has("player_id"):
		player["player_id"] = generate_player_id(load_players())
	if not player.has("bitcoin"):
		player["bitcoin"] = 0
	if not player.has("uridium"):
		player["uridium"] = 0
	if not player.has("platinum"):
		player["platinum"] = 0
	if not player.has("role"):
		player["role"] = "player"

	if not player.has("starter_reward_claimed"):
		# Migration: eski kayıtlara alan eklenir ama ödül hakkı verilmez.
		# Ödül yalnızca create_account ile YENİ hesap açılırken bir kez verilir;
		# bu yüzden eski hesaplarda alan false kalır ve geriye dönük ödül verilmez.
		player["starter_reward_claimed"] = false

	var owned_ships = player.get("owned_ships", ["Ship10"])
	if not (owned_ships is Array):
		owned_ships = ["Ship10"]
	if not owned_ships.has("Ship10"):
		owned_ships.push_front("Ship10")
	player["owned_ships"] = owned_ships

	var active_ship := str(player.get("active_ship", "Ship10"))
	if not owned_ships.has(active_ship) and not (str(player.get("role", "player")) == "admin" and active_ship == "ADMIN_TEST"):
		active_ship = "Ship10"
	player["active_ship"] = active_ship

	var inv = player.get("inventory", {})
	if not (inv is Dictionary):
		inv = {}
	# PHASE 1: an existing save may still use display-name keys. Fold them onto
	# the canonical ids before anything reads the counts.
	inv = _canonicalize_inventory(inv as Dictionary)
	var defaults := _default_inventory()
	for key in defaults.keys():
		if not inv.has(key):
			inv[key] = 0
	player["inventory"] = inv

	player["plus_droids"] = clampi(int(player.get("plus_droids", 0)), 0, 8)
	player["zeus_droids"] = clampi(int(player.get("zeus_droids", 0)), 0, 8)

	var droid_types = player.get("droid_types", [])
	if not (droid_types is Array):
		droid_types = []

	# Eski kayıtta sadece adet varsa sıralı listeyi üret.
	if droid_types.is_empty():
		for i in range(int(player["plus_droids"])):
			droid_types.append("PLUS")
		for i in range(int(player["zeus_droids"])):
			droid_types.append("ZEUS")

	while droid_types.size() > 8:
		droid_types.pop_back()

	player["droid_types"] = droid_types
	player["plus_droids"] = droid_types.count("PLUS")
	player["zeus_droids"] = droid_types.count("ZEUS")
	player["total_droids"] = droid_types.size()

	# Rutbe altyapisi: A rutbesi varsayilan olarak KAPALI gelir ve yalnizca
	# admin panelinden verilebilir (bkz. set_player_a_rank).
	player["a_rank"] = bool(player.get("a_rank", false))

	# created_at (unix): rutbe puanindaki "kayittan beri gun sayisi" girdisi.
	# Eski kayitlarda alan yoktur; geriye donuk puan UYDURMAMAK icin
	# migrasyon anindan itibaren sayilir.
	if int(player.get("created_at", 0)) <= 0:
		player["created_at"] = int(Time.get_unix_time_from_system())

	# Rutbe puani girdileri; eksik alanlar 0 kabul edilir (negatif olamaz).
	for stat_key in ["npc_kills", "player_kills", "friendly_kills", "deaths", "missions_completed"]:
		player[stat_key] = maxi(int(player.get(stat_key, 0)), 0)


func generate_player_id(players:Array) -> String:
	var attempts := 0
	
	while attempts < 10000:
		var new_id := str(randi_range(10000, 99999))
		var exists := false

		for p in players:
			if str(p.get("player_id", "")) == new_id:
				exists = true
				break

		if not exists:
			return new_id

		attempts += 1

	return str(randi_range(10000, 99999))

func create_account(username:String, password:String):
	var players = load_players()
	var p := {
		"player_id": generate_player_id(players),
		"server_id": get_active_player_id(),
		"username": username,
		"password": password,
		"ship_name": username,
		"ship_type": "Ship10",
		"role": "player",
		"owned_ships": ["Ship10"],
		"active_ship": "Ship10",
		"company": "",
		"current_map": "",
		"position_x": 0.0,
		"position_y": 0.0,
		"level": 1,
		"xp": 0,
		"honor": 0,
		"bitcoin": 0,
		"uridium": 0,
		"platinum": 0,
		"inventory": _default_inventory(),
		"plus_droids": 0,
		"zeus_droids": 0,
		"total_droids": 0,
		"droid_types": [],
		"clan": "",
		# Rutbe altyapisi: yeni hesap kayit aninda olusturulur, A rutbesi kapali.
		"a_rank": false,
		"created_at": int(Time.get_unix_time_from_system()),
		"npc_kills": 0,
		"player_kills": 0,
		"friendly_kills": 0,
		"deaths": 0,
		"missions_completed": 0
	}
	# İlk kayıt ödülü: yalnızca YENİ hesap için, kayıt anında bir kez uygulanır.
	_apply_starter_reward(p)
	players.append(p)
	save_players(players)


# ==============================
# NOVAGATE İLK KAYIT ÖDÜLÜ
# 10.000 PLT + 10.000 BTC + 1.000 X1 + 100 R1 + 1 Kalkan I + 1 Hız I + 1 LF1
# Yalnızca create_account ile yeni açılan hesaba bir kez verilir.
# Mevcut hesaplarda starter_reward_claimed=false kalır; geriye dönük ödül verilmez.
# ==============================
const STARTER_REWARD_BITCOIN := 10000
const STARTER_REWARD_PLATINUM := 10000
const STARTER_REWARD_AMMO := {"X1": 1000, "R1": 100}
# PHASE 1: canonical ids, matching the server's item_catalog and
# config.FIRST_REGISTRATION_REWARD_ITEMS. The previous display names
# ("Kalkan 1") were the reason the server grant was invisible in the UI.
const STARTER_REWARD_ITEMS := ["kalkan1", "hiz1", "lf1"]


func _apply_starter_reward(player: Dictionary) -> void:
	# BTC/PLT ve ekipman doğrudan players.json kaydına yazılır;
	# GlobalState bu kayıttan yüklendiği için iki defter tutarlı kalır.
	player["bitcoin"] = int(STARTER_REWARD_BITCOIN)
	player["uridium"] = int(STARTER_REWARD_PLATINUM)
	player["platinum"] = int(STARTER_REWARD_PLATINUM)

	var inv: Dictionary = player.get("inventory", _default_inventory())
	inv = _canonicalize_inventory(inv as Dictionary)
	for item_name in STARTER_REWARD_ITEMS:
		inv[item_name] = int(inv.get(item_name, 0)) + 1
	player["inventory"] = inv

	player["starter_reward_claimed"] = true
	_grant_starter_ammo(str(player.get("username", "")))


func _grant_starter_ammo(username: String) -> void:
	# Cephane, hesap bazlı ayrı dosyada tutulur
	# (GlobalState.load_ammo_inventory ile aynı format ve aynı yol).
	if username.is_empty():
		return
	var path := "user://" + username + "_ammo.json"
	var ammo := {
		"X1": 0, "X2": 0, "X3": 0, "X4": 0,
		"SAB": 0, "RSB": 0, "R1": 0, "R2": 0, "R3": 0
	}
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Dictionary:
				for key in ammo.keys():
					ammo[key] = maxi(int((parsed as Dictionary).get(key, 0)), 0)
	for key in STARTER_REWARD_AMMO.keys():
		ammo[key] = int(ammo[key]) + int(STARTER_REWARD_AMMO[key])

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Starter cephane dosyası yazılamadı: " + path)
		return
	file.store_string(JSON.stringify(ammo))
	file.close()


func login(username:String, password:String) -> bool:
	for p in load_players():
		if p.get("username","") == username and p.get("password","") == password:
			current_username = username
			save_active_user(username)
			return true
	return false

func get_current_player() -> String:
	# Server oturumundaki kullanıcı her zaman en yüksek önceliğe sahiptir.
	# active_user.txt eski hesaptan kalmış olsa bile başka hesaba veri taşımaz.
	var live_username := str(GlobalState.username).strip_edges()
	if live_username != "":
		current_username = live_username
		return live_username

	if current_username != "":
		return current_username.strip_edges()

	if FileAccess.file_exists(ACTIVE_USER):
		var f = FileAccess.open(ACTIVE_USER, FileAccess.READ)
		if f != null:
			return f.get_as_text().strip_edges()
	return ""

func save_active_user(username:String):
	var f = FileAccess.open(ACTIVE_USER, FileAccess.WRITE)
	f.store_string(username)


func save_active_player_id(player_id:String):
	var f = FileAccess.open(ACTIVE_PLAYER_ID, FileAccess.WRITE)
	f.store_string(str(player_id))


func get_active_player_id() -> String:
	if FileAccess.file_exists(ACTIVE_PLAYER_ID):
		var f = FileAccess.open(ACTIVE_PLAYER_ID, FileAccess.READ)
		return f.get_as_text()
	return ""

func get_player(username:String):
	var players = load_players()
	for p in players:
		if p.get("username","") == username:
			_ensure_player_defaults(p)
			return p

	# Server ile giriş yapılmış ama eski players.json içinde kayıt yoksa
	# otomatik yerel cache oluştur. Bu kayıt ana veri kaynağı değildir;
	# PostgreSQL'deki oyuncunun Godot tarafındaki aynasıdır.
	if username != "" and username == get_current_player():
		var cached := {
			"player_id": generate_player_id(players),
			"server_id": get_active_player_id(),
			"username": username,
			"password": "",
			"ship_name": username,
			"ship_type": "Ship10",
			"role": "player",
			"owned_ships": GlobalState.owned_ships.duplicate(),
			"active_ship": GlobalState.active_ship_id,
			"company": GlobalState.company,
			"current_map": GlobalState.start_map,
			"position_x": 0.0,
			"position_y": 0.0,
			"level": GlobalState.level,
			"xp": GlobalState.xp,
			"honor": GlobalState.honor,
			"bitcoin": GlobalState.bitcoin,
			"uridium": GlobalState.platinum,
			"platinum": GlobalState.platinum,
			"inventory": GlobalState.inventory.duplicate(true),
			"plus_droids": GlobalState.plus_droids,
			"zeus_droids": GlobalState.zeus_droids,
			"total_droids": GlobalState.total_droids,
			"droid_types": GlobalState.droid_types.duplicate(),
			"ship_configurations": GlobalState.ship_configurations.duplicate(true),
			"selected_config": GlobalState.selected_config,
			"clan": ""
		}
		_ensure_player_defaults(cached)
		players.append(cached)
		save_players(players)
		return cached

	return null

func save_player_location(map_name:String, pos:Vector2) -> void:
	var username := get_current_player()
	if username == "":
		return

	var players = load_players()
	for p in players:
		if p.get("username", "") == username:
			p["current_map"] = map_name
			p["position_x"] = pos.x
			p["position_y"] = pos.y
			break
	save_players(players)

func get_company(username:String) -> String:
	var p = get_player(username)
	if p != null:
		return str(p.get("company",""))
	return ""

func save_company(username:String, company:String):
	var players = load_players()
	for p in players:
		if p.get("username","") == username:
			p["company"] = company
			save_players(players)
			return

func get_ship_name(username:String)->String:
	var p = get_player(username)
	if p:
		return str(p.get("ship_name", username))
	return username

func add_alien_reward(xp:int, bitcoin:int, platinum:int, honor:int):
	var username = get_current_player()
	if username == "":
		return

	var players = load_players()
	for p in players:
		if p.get("username","") == username:
			_ensure_player_defaults(p)
			p["xp"] = int(p.get("xp",0)) + xp
			p["bitcoin"] = int(p.get("bitcoin",0)) + bitcoin
			p["platinum"] = int(p.get("platinum",0)) + platinum
			p["honor"] = int(p.get("honor",0)) + honor
			save_players(players)
			return

func get_inventory() -> Dictionary:
	if GlobalState.server_session_active:
		var result := _default_inventory()
		for key in GlobalState.inventory.keys():
			result[str(key)] = int(GlobalState.inventory.get(key, 0))
		return result

	var username := get_current_player()
	if username == "":
		return _default_inventory()
	var p = get_player(username)
	if p == null:
		return _default_inventory()
	return (p.get("inventory", _default_inventory()) as Dictionary).duplicate(true)

func get_droid_types() -> Array:
	if GlobalState.server_session_active:
		return GlobalState.droid_types.duplicate()

	var username := get_current_player()
	if username == "":
		return []
	var p = get_player(username)
	if p == null:
		return []
	return (p.get("droid_types", []) as Array).duplicate()

func get_droid_counts() -> Dictionary:
	var types := get_droid_types()
	return {
		"plus": types.count("PLUS"),
		"zeus": types.count("ZEUS"),
		"total": types.size()
	}


func record_equipment_purchase(item_name:String, currency:String, live_balance:int) -> Dictionary:
	var username := get_current_player()
	if username == "":
		return {"ok": false, "message": "Aktif oyuncu bulunamadı."}

	var players = load_players()
	for p in players:
		if p.get("username","") != username:
			continue

		_ensure_player_defaults(p)

		var inv: Dictionary = p["inventory"]
		inv[item_name] = int(inv.get(item_name, 0)) + 1
		p["inventory"] = inv

		if currency == "BTC":
			p["bitcoin"] = live_balance
		else:
			# Market PLT, oyundaki Uridium bakiyesine bağlıdır.
			p["uridium"] = live_balance
			p["platinum"] = live_balance

		save_players(players)
		return {"ok": true, "message": "%s satın alındı." % item_name}

	return {"ok": false, "message": "Oyuncu kaydı bulunamadı."}


func record_droid_purchase(droid_type:String, currency:String, live_balance:int) -> Dictionary:
	var username := get_current_player()
	if username == "":
		return {"ok": false, "message": "Aktif oyuncu bulunamadı."}

	var players = load_players()
	for p in players:
		if p.get("username","") != username:
			continue

		_ensure_player_defaults(p)
		var droid_types: Array = p["droid_types"]

		if droid_types.size() >= 8:
			return {"ok": false, "message": "Maksimum 8 droid sınırına ulaşıldı."}

		droid_types.append(droid_type)
		p["droid_types"] = droid_types
		p["plus_droids"] = droid_types.count("PLUS")
		p["zeus_droids"] = droid_types.count("ZEUS")
		p["total_droids"] = droid_types.size()

		if currency == "BTC":
			p["bitcoin"] = live_balance
		else:
			p["uridium"] = live_balance
			p["platinum"] = live_balance

		save_players(players)
		return {
			"ok": true,
			"message": "%s droid satın alındı." % droid_type,
			"total": droid_types.size()
		}

	return {"ok": false, "message": "Oyuncu kaydı bulunamadı."}


func buy_equipment(item_name:String, currency:String, price:int) -> Dictionary:
	var username := get_current_player()
	if username == "":
		return {"ok": false, "message": "Aktif oyuncu bulunamadı."}

	var players = load_players()
	for p in players:
		if p.get("username","") != username:
			continue

		_ensure_player_defaults(p)
		var currency_key := "bitcoin" if currency == "BTC" else "platinum"
		var balance := int(p.get(currency_key, 0))

		if balance < price:
			return {
				"ok": false,
				"message": "Yeterli Bitcoin yok." if currency == "BTC" else "Yeterli PLT yok."
			}

		p[currency_key] = balance - price
		var inv: Dictionary = p["inventory"]
		inv[item_name] = int(inv.get(item_name, 0)) + 1
		p["inventory"] = inv
		save_players(players)
		# Quest event: ekipman satin alma hedefi (minimal hook).
		QuestSystem.record_event("item_purchased", {"item": item_name, "amount": 1})

		return {
			"ok": true,
			"message": "%s satın alındı." % item_name,
			"balance": int(p[currency_key]),
			"currency": currency
		}

	return {"ok": false, "message": "Oyuncu kaydı bulunamadı."}

func buy_droid(droid_type:String, currency:String, price:int) -> Dictionary:
	var username := get_current_player()
	if username == "":
		return {"ok": false, "message": "Aktif oyuncu bulunamadı."}

	var players = load_players()
	for p in players:
		if p.get("username","") != username:
			continue

		_ensure_player_defaults(p)
		var droid_types: Array = p["droid_types"]

		if droid_types.size() >= 8:
			return {"ok": false, "message": "Maksimum 8 droid sınırına ulaşıldı."}

		var currency_key := "bitcoin" if currency == "BTC" else "platinum"
		var balance := int(p.get(currency_key, 0))
		if balance < price:
			return {
				"ok": false,
				"message": "Yeterli Bitcoin yok." if currency == "BTC" else "Yeterli PLT yok."
			}

		p[currency_key] = balance - price
		droid_types.append(droid_type)
		p["droid_types"] = droid_types
		p["plus_droids"] = droid_types.count("PLUS")
		p["zeus_droids"] = droid_types.count("ZEUS")
		p["total_droids"] = droid_types.size()
		save_players(players)

		return {
			"ok": true,
			"message": "%s droid satın alındı." % droid_type,
			"balance": int(p[currency_key]),
			"currency": currency,
			"total": droid_types.size()
		}

	return {"ok": false, "message": "Oyuncu kaydı bulunamadı."}

func get_owned_ships() -> Array:
	if GlobalState.server_session_active:
		var ships: Array = GlobalState.owned_ships.duplicate()
		if not ships.has("Ship10"):
			ships.push_front("Ship10")
		return ships

	var username := get_current_player()
	if username == "":
		return ["Ship10"]
	var p = get_player(username)
	if p == null:
		return ["Ship10"]
	return (p.get("owned_ships", ["Ship10"]) as Array).duplicate()

func get_active_ship() -> String:
	if GlobalState.server_session_active:
		var live_ship := str(GlobalState.active_ship_id).strip_edges()
		if live_ship == "":
			live_ship = "Ship10"
		return live_ship

	var username := get_current_player()
	if username == "":
		return "Ship10"
	var p = get_player(username)
	if p == null:
		return "Ship10"
	return str(p.get("active_ship", "Ship10"))

func get_player_role() -> String:
	if GlobalState.server_session_active:
		return "admin" if GlobalState.is_admin else "player"

	var username := get_current_player()
	if username == "":
		return "player"
	var p = get_player(username)
	if p == null:
		return "player"
	return str(p.get("role", "player"))

func owns_ship(ship_id:String) -> bool:
	return get_owned_ships().has(ship_id)


func record_ship_purchase(ship_id:String, currency:String, live_balance:int) -> Dictionary:
	var username := get_current_player()
	if username == "":
		return {"ok": false, "message": "Aktif oyuncu bulunamadı."}

	var players = load_players()
	for p in players:
		if p.get("username","") != username:
			continue

		_ensure_player_defaults(p)
		var owned: Array = p["owned_ships"]
		if owned.has(ship_id):
			return {"ok": false, "message": "Bu gemiye zaten sahipsin."}

		owned.append(ship_id)
		p["owned_ships"] = owned
		if currency == "BTC":
			p["bitcoin"] = live_balance
		elif currency == "PLT":
			p["uridium"] = live_balance
			p["platinum"] = live_balance

		save_players(players)
		return {"ok": true, "message": "%s hangara eklendi." % ship_id}

	return {"ok": false, "message": "Oyuncu kaydı bulunamadı."}


func ensure_starter_ship() -> void:
	var username := get_current_player()
	if username == "":
		return
	var players = load_players()
	for p in players:
		if p.get("username","") == username:
			_ensure_player_defaults(p)
			save_players(players)
			return


func set_active_ship(ship_id:String) -> Dictionary:
	var username := get_current_player()
	if username == "":
		return {"ok": false, "message": "Aktif oyuncu bulunamadı."}

	# Server oturumunda sahiplik ve aktif gemi için canlı server state tek kaynaktır.
	if GlobalState.server_session_active:
		if not GlobalState.owned_ships.has(ship_id):
			return {"ok": false, "message": "Bu gemiye sahip değilsin."}

		GlobalState.active_ship_id = ship_id
		GlobalState.ship_name = ship_id

		# Yerel cache sadece ayna olarak güncellenir; kaynak değildir.
		var cached_players = load_players()
		for cached in cached_players:
			if str(cached.get("username", "")) == username:
				_ensure_player_defaults(cached)
				cached["active_ship"] = ship_id
				cached["ship_type"] = ship_id
				cached["owned_ships"] = GlobalState.owned_ships.duplicate()
				save_players(cached_players)
				break

		return {"ok": true, "message": "%s aktif gemi yapıldı." % ship_id}

	var players = load_players()
	for player in players:
		if player.get("username","") != username:
			continue

		_ensure_player_defaults(player)
		var role := str(player.get("role", "player"))
		var owned: Array = player["owned_ships"]

		if role == "admin" and ship_id == "ADMIN_TEST":
			player["active_ship"] = ship_id
			save_players(players)
			return {"ok": true, "message": "Admin test gemisi aktif."}

		if not owned.has(ship_id):
			return {"ok": false, "message": "Bu gemiye sahip değilsin."}

		player["active_ship"] = ship_id
		player["ship_type"] = ship_id
		save_players(players)
		return {"ok": true, "message": "%s aktif gemi yapıldı." % ship_id}

	return {"ok": false, "message": "Oyuncu kaydı bulunamadı."}

func sell_ship(ship_id:String, refund_btc:int) -> Dictionary:
	if ship_id == "Ship10":
		return {"ok": false, "message": "Başlangıç gemisi satılamaz."}

	var username := get_current_player()
	if username == "":
		return {"ok": false, "message": "Aktif oyuncu bulunamadı."}

	var players = load_players()
	for p in players:
		if p.get("username","") != username:
			continue

		_ensure_player_defaults(p)
		var owned: Array = p["owned_ships"]
		if not owned.has(ship_id):
			return {"ok": false, "message": "Bu gemiye sahip değilsin."}

		owned.erase(ship_id)
		p["owned_ships"] = owned
		if str(p.get("active_ship", "Ship10")) == ship_id:
			p["active_ship"] = "Ship10"
			p["ship_type"] = "Ship10"
		p["bitcoin"] = int(p.get("bitcoin", 0)) + maxi(refund_btc, 0)
		save_players(players)
		return {
			"ok": true,
			"message": "%s satıldı." % ship_id,
			"bitcoin": int(p["bitcoin"]),
			"active_ship": str(p["active_ship"])
		}

	return {"ok": false, "message": "Oyuncu kaydı bulunamadı."}


func sell_droid(droid_index:int) -> Dictionary:
	var username := get_current_player().strip_edges()
	if username == "":
		return {"ok": false, "basarili": false, "message": "Aktif oyuncu bulunamadı.", "mesaj": "Aktif oyuncu bulunamadı."}

	var http := HTTPRequest.new()
	http.process_mode = Node.PROCESS_MODE_ALWAYS
	http.timeout = 20.0
	get_tree().root.add_child(http)

	var base_url := _get_server_url()
	if base_url.is_empty():
		return {"ok": false, "basarili": false, "message": "Sunucu adresi tanımlı değil.", "mesaj": "Sunucu adresi tanımlı değil."}
	var url := base_url + "/market/sell_droid?username=" + username.uri_encode()
	url += "&droid_index=" + str(droid_index)

	print("DROID SELL SERVER REQUEST: ", url)
	var err := http.request(url, [], HTTPClient.METHOD_POST)
	if err != OK:
		http.queue_free()
		# OFFLINE FALLBACK: istek hiç başlatılamadıysa satış yerelde uygulanır.
		return _offline_sell_droid(droid_index)

	var result: Array = await http.request_completed
	var request_result: int = int(result[0])
	var response_code: int = int(result[1])
	var body: String = (result[3] as PackedByteArray).get_string_from_utf8()
	http.queue_free()

	if request_result != HTTPRequest.RESULT_SUCCESS:
		# OFFLINE FALLBACK: sunucuya ulaşılamadıysa satış yerelde uygulanır.
		return _offline_sell_droid(droid_index)

	var data = JSON.parse_string(body)
	if response_code != 200 or not (data is Dictionary):
		return {
			"ok": false,
			"basarili": false,
			"message": "Droid satış sunucu cevabı hatalı. HTTP: %s" % str(response_code),
			"mesaj": "Droid satış sunucu cevabı hatalı."
		}

	if not bool(data.get("basarili", false)):
		var fail_message := str(data.get("mesaj", "Droid satılamadı."))
		return {"ok": false, "basarili": false, "message": fail_message, "mesaj": fail_message}

	GlobalState.bitcoin = int(data.get("bitcoin", GlobalState.bitcoin))
	GlobalState.platinum = int(data.get("plt", GlobalState.platinum))
	GlobalState.uridium = GlobalState.platinum

	var live_droids = data.get("droid_types", [])
	GlobalState.droid_types = live_droids.duplicate() if live_droids is Array else []
	GlobalState.plus_droids = GlobalState.droid_types.count("PLUS")
	GlobalState.zeus_droids = GlobalState.droid_types.count("ZEUS")
	GlobalState.total_droids = GlobalState.droid_types.size()

	var live_inventory = data.get("inventory", {})
	GlobalState.inventory = live_inventory.duplicate(true) if live_inventory is Dictionary else {}

	var oyuncu := {
		"id": get_active_player_id(),
		"username": username,
		"company": GlobalState.company,
		"map": GlobalState.start_map,
		"level": GlobalState.level,
		"exp": GlobalState.xp,
		"honor": GlobalState.honor,
		"bitcoin": GlobalState.bitcoin,
		"plt": GlobalState.platinum,
		"is_admin": GlobalState.is_admin,
		"owned_ships": data.get("owned_ships", GlobalState.owned_ships),
		"inventory": GlobalState.inventory,
		"droid_types": GlobalState.droid_types
	}
	sync_server_player_to_local(oyuncu)

	var success_message := str(data.get("mesaj", "Droid satıldı."))
	return {
		"ok": true,
		"basarili": true,
		"message": success_message,
		"mesaj": success_message,
		"bitcoin": GlobalState.bitcoin,
		"plt": GlobalState.platinum,
		"refund": int(data.get("refund", 0)),
		"currency": str(data.get("currency", "")),
		"sold_type": str(data.get("sold_type", ""))
	}

func set_local_balances(btc: int, plt: int) -> void:
	# Offline market işlemlerinde players.json bakiyelerini canlı
	# GlobalState değerleriyle hizalar; çift kaynak sapmasını önler.
	var username := get_current_player()
	if username == "":
		return
	var players = load_players()
	for p in players:
		if p.get("username", "") == username:
			_ensure_player_defaults(p)
			p["bitcoin"] = maxi(int(btc), 0)
			p["uridium"] = maxi(int(plt), 0)
			p["platinum"] = maxi(int(plt), 0)
			save_players(players)
			return


func _offline_sell_droid(droid_index: int) -> Dictionary:
	# OFFLINE FALLBACK: sunucu erişilemediğinde droid satışı yerel
	# kayıtta uygulanır. İade, market fiyat tablosunun yarısıdır.
	var username := get_current_player().strip_edges()
	if username == "":
		return {"ok": false, "basarili": false, "message": "Aktif oyuncu bulunamadı.", "mesaj": "Aktif oyuncu bulunamadı."}
	if droid_index < 0 or droid_index >= GlobalState.droid_types.size():
		return {"ok": false, "basarili": false, "message": "Geçersiz droid kaydı.", "mesaj": "Geçersiz droid kaydı."}

	var droid_type := str(GlobalState.droid_types[droid_index])
	var same_type_count := GlobalState.droid_types.count(droid_type)

	var plus_prices := [100000, 200000, 400000, 800000, 1600000, 3200000, 6400000, 12800000]
	var zeus_prices := [12000, 20000, 35000, 60000, 100000, 170000, 300000, 500000]
	var prices: Array = plus_prices if droid_type == "PLUS" else zeus_prices
	var price_index := clampi(maxi(same_type_count, 1) - 1, 0, prices.size() - 1)
	var refund := int(prices[price_index]) / 2

	GlobalState.droid_types.remove_at(droid_index)
	GlobalState.plus_droids = GlobalState.droid_types.count("PLUS")
	GlobalState.zeus_droids = GlobalState.droid_types.count("ZEUS")
	GlobalState.total_droids = GlobalState.droid_types.size()

	if droid_type == "PLUS":
		GlobalState.bitcoin = int(GlobalState.bitcoin) + refund
	else:
		GlobalState.platinum = int(GlobalState.platinum) + refund
		GlobalState.uridium = GlobalState.platinum

	var players = load_players()
	for p in players:
		if p.get("username", "") == username:
			_ensure_player_defaults(p)
			p["droid_types"] = GlobalState.droid_types.duplicate()
			p["plus_droids"] = GlobalState.plus_droids
			p["zeus_droids"] = GlobalState.zeus_droids
			p["total_droids"] = GlobalState.total_droids
			p["bitcoin"] = int(GlobalState.bitcoin)
			p["uridium"] = int(GlobalState.platinum)
			p["platinum"] = int(GlobalState.platinum)
			break
	save_players(players)
	GlobalState.save_game()

	var success_message := "%s droidi satıldı. İade: %s" % [droid_type, str(refund)]
	return {
		"ok": true,
		"basarili": true,
		"message": success_message,
		"mesaj": success_message,
		"bitcoin": int(GlobalState.bitcoin),
		"plt": int(GlobalState.platinum),
		"refund": refund,
		"currency": "BTC" if droid_type == "PLUS" else "PLT",
		"sold_type": droid_type
	}


func get_server_player_record():
	var server_id := get_active_player_id()
	if server_id == "":
		return null

	for p in load_players():
		if str(p.get("server_id", "")) == server_id:
			return p
	return null


# --- Rutbe sistemi hesap API'si ---

func get_all_player_records() -> Array:
	# Siralamada kullanilacak TUM hesap kayitlari (varsayilanlar uygulanmis).
	# load_players() her kayda _ensure_player_defaults uygular, bu yuzden
	# eksik rutbe alanlari burada guvenle okunabilir.
	return load_players()


func get_player_record(username: String) -> Dictionary:
	var target := username.strip_edges()
	if target.is_empty():
		return {}
	for p in load_players():
		if p is Dictionary and str(p.get("username", "")) == target:
			return p
	return {}


func sync_rank_stats(username: String, stats: Dictionary) -> void:
	# Aktif oyuncunun canli rutbe statlari hesap kaydina islenir.
	# Boylece diger oyuncularin yerel siralamasi dogru hesaplanir.
	var target := username.strip_edges()
	if target.is_empty():
		return
	var players = load_players()
	for p in players:
		if not (p is Dictionary):
			continue
		if str(p.get("username", "")) != target:
			continue
		p["npc_kills"] = maxi(int(stats.get("npc_kills", 0)), 0)
		p["player_kills"] = maxi(int(stats.get("player_kills", 0)), 0)
		p["friendly_kills"] = maxi(int(stats.get("friendly_kills", 0)), 0)
		p["deaths"] = maxi(int(stats.get("deaths", 0)), 0)
		p["missions_completed"] = maxi(int(stats.get("missions_completed", 0)), 0)
		if str(p.get("ship_type", "")).is_empty():
			p["ship_type"] = "Ship10"
		save_players(players)
		return


func can_manage_a_rank() -> bool:
	# A rutbesi verme yetkisi yalnizca admin hesaplardadir.
	if GlobalState.is_admin:
		return true
	return get_player_role() == "admin"


func is_player_a_rank(username: String) -> bool:
	return bool(get_player_record(username).get("a_rank", false))


func list_a_rank_players() -> Array:
	var rows: Array = []
	for p in get_all_player_records():
		if not (p is Dictionary):
			continue
		if bool(p.get("a_rank", false)):
			rows.append(str(p.get("username", "")))
	return rows


func set_player_a_rank(username: String, enabled: bool) -> Dictionary:
	# A rutbesi merdivenin disindadir: kontenjan/yuzde hesabina girmez,
	# yalnizca runtime stat carpanini (BASE x 2) acar.
	if not can_manage_a_rank():
		return {"ok": false, "message": "A rütbesi verme yetkisi yok."}
	var target := str(username).strip_edges()
	if target.is_empty():
		return {"ok": false, "message": "Oyuncu adı boş."}
	var players = load_players()
	for p in players:
		if not (p is Dictionary):
			continue
		if str(p.get("username", "")) != target:
			continue
		p["a_rank"] = bool(enabled)
		save_players(players)
		_apply_a_rank_to_runtime(target, bool(enabled))
		return {"ok": true, "username": target, "a_rank": bool(enabled)}
	return {"ok": false, "message": "Oyuncu bulunamadı: " + target}


func _apply_a_rank_to_runtime(username: String, enabled: bool) -> void:
	# Yalnizca AKTIF oyuncunun canli verisi guncellenir; digerleri
	# sonraki girislerinde kayittan okur.
	if str(GlobalState.username) != username:
		return
	GlobalState.rank_a_active = enabled
	GlobalState.recompute_local_ranking()
	GlobalState.save_game()


func load_players():
	if not FileAccess.file_exists(SAVE_FILE):
		return []

	var f = FileAccess.open(SAVE_FILE, FileAccess.READ)

	if f == null:
		return []

	var data = JSON.parse_string(f.get_as_text())
	var players = data if data != null else []

	for p in players:
		if p is Dictionary:
			_ensure_player_defaults(p)
			if not p.has("player_id") or str(p.get("player_id", "")) == "":
				p["player_id"] = generate_player_id(players)

	save_players(players)

	return players

func save_players(data):
	var f = FileAccess.open(SAVE_FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))

func apply_admin_ship_balance() -> void:
	var username := get_current_player()
	if username == "":
		return
	var players = load_players()
	for p in players:
		if p.get("username","") == username:
			if str(p.get("active_ship","")) == "ADMIN":
				p["bitcoin"] = 20000000
				p["platinum"] = 20000000
			break
	save_players(players)


func get_player_id(username:String) -> String:
	var players = load_players()
	for p in players:
		if p is Dictionary and str(p.get("username","")) == username:
			var id_value := str(p.get("player_id",""))
			if id_value == "":
				id_value = generate_player_id(players)
				p["player_id"] = id_value
				save_players(players)
			return id_value
	return ""


# ==============================
# NOVAGATE SERVER CONNECTION
# ==============================

const SERVER_URL := "https://novagate-server-1.onrender.com"
const WS_URL := "wss://novagate-server-1.onrender.com/ws/game"
const LOCAL_SERVER_URL := "http://127.0.0.1:8000"
const LOCAL_WS_URL := "ws://127.0.0.1:8000/ws/game"

# Endpoint yapılandırması process-genelidir (static).
#
# AccountManager her yerde `load(...).new()` ile yeniden üretilir
# (login.gd, company_select.gd, player_ship.gd, market...). Instance-level
# bir alan her yeni instance'ta sıfırlandığı için `use_local_server` yalnız
# o instance'ta geçerli kalıyor ve company_select gibi sahneler üretim
# sunucusuna düşüyordu. Statik alan tüm instance'ların aynı yapılandırmayı
# paylaşmasını garanti eder.
static var _endpoint_override: String = ""
static var _use_local_server: bool = false

var server_url: String = "" : set = _set_server_url, get = _get_server_url
# Production default: connect to the live Render server. Local mode can be
# re-enabled at runtime (or via the NOVAGATE_SERVER_URL environment
# variable) for the bundled FastAPI server / login tests.
var use_local_server: bool : set = _set_use_local_server, get = _get_use_local_server


# ---------------------------------------------------------------------------
# Endpoint resolution (shared by every AccountManager instance)
# ---------------------------------------------------------------------------
static func set_server_endpoint(url: String) -> void:
	_endpoint_override = url.strip_edges().trim_suffix("/")


static func get_server_endpoint() -> String:
	if not _endpoint_override.is_empty():
		return _endpoint_override
	var env_url := OS.get_environment("NOVAGATE_SERVER_URL").strip_edges().trim_suffix("/")
	if not env_url.is_empty():
		return env_url
	if _use_local_server:
		return LOCAL_SERVER_URL
	return SERVER_URL


static func get_ws_endpoint() -> String:
	var base := get_server_endpoint()
	if base.is_empty():
		return ""
	return base.replace("https://", "wss://").replace("http://", "ws://").trim_suffix("/") + "/ws/game"


func _set_use_local_server(value: bool) -> void:
	_use_local_server = value
	if value:
		# Local mode is explicit: drop any production override so the switch
		# always takes effect instead of being masked by a stale endpoint.
		_endpoint_override = ""


func _get_use_local_server() -> bool:
	return _use_local_server



func sync_server_player_to_local(oyuncu: Dictionary) -> void:
	var username := str(oyuncu.get("username", get_current_player()))
	if username == "":
		return

	current_username = username
	save_active_user(username)

	if oyuncu.has("id"):
		save_active_player_id(str(oyuncu.get("id", "")))

	var players = load_players()
	var target: Dictionary = {}
	var found := false

	for p in players:
		if p is Dictionary and str(p.get("username", "")) == username:
			target = p
			found = true
			break

	if not found:
		target = {
			"player_id": generate_player_id(players),
			"server_id": str(oyuncu.get("id", "")),
			"username": username,
			"password": "",
			"ship_name": username,
			"ship_type": "Ship10",
			"role": "player",
			"owned_ships": ["Ship10"],
			"active_ship": "Ship10",
			"company": "",
			"current_map": "",
			"position_x": 0.0,
			"position_y": 0.0,
			"level": 1,
			"xp": 0,
			"honor": 0,
			"bitcoin": 0,
			"uridium": 0,
			"platinum": 0,
			"inventory": _default_inventory(),
			"plus_droids": 0,
			"zeus_droids": 0,
			"total_droids": 0,
			"droid_types": [],
			"clan": ""
		}
		players.append(target)

	_ensure_player_defaults(target)

	target["server_id"] = str(oyuncu.get("id", target.get("server_id", "")))
	target["company"] = str(oyuncu.get("company", target.get("company", "")))
	target["current_map"] = str(oyuncu.get("map", target.get("current_map", "")))
	target["level"] = int(oyuncu.get("level", target.get("level", 1)))
	target["xp"] = int(oyuncu.get("exp", target.get("xp", 0)))
	target["honor"] = int(oyuncu.get("honor", target.get("honor", 0)))
	target["bitcoin"] = int(oyuncu.get("bitcoin", target.get("bitcoin", 0)))
	target["platinum"] = int(oyuncu.get("plt", target.get("platinum", 0)))
	target["uridium"] = int(oyuncu.get("plt", target.get("uridium", 0)))
	target["log_disks"] = int(oyuncu.get("log_disks", target.get("log_disks", 0)))
	target["skill_points"] = int(oyuncu.get("skill_points", target.get("skill_points", 0)))
	if oyuncu.has("is_admin"):
		target["is_admin"] = bool(oyuncu.get("is_admin", false))
	else:
		target["is_admin"] = bool(target.get("is_admin", GlobalState.is_admin))
	target["role"] = "admin" if target["is_admin"] else "player"

	# Hesap sahipliği server cevabından TAM olarak yeniden kurulur.
	# Eksik alanlarda önceki/local hesabın değerini korumak veri sızıntısına yol açar.
	var server_ships: Array = []
	var ships_value = oyuncu.get("owned_ships", [])
	if ships_value is Array:
		server_ships = (ships_value as Array).duplicate()
	if not server_ships.has("Ship10"):
		server_ships.push_front("Ship10")
	target["owned_ships"] = server_ships

	var inv := _default_inventory()
	var inventory_value = oyuncu.get("inventory", {})
	if inventory_value is Dictionary:
		# PHASE 1: fold any client-side spelling onto the canonical id, and let
		# the server value win for every key it actually reports.
		var folded := _canonicalize_inventory(inventory_value as Dictionary)
		for key in folded.keys():
			inv[str(key)] = int(folded.get(key, 0))
	target["inventory"] = inv

	var types: Array = []
	var droids_value = oyuncu.get("droid_types", [])
	if droids_value is Array:
		types = (droids_value as Array).duplicate()
	while types.size() > 8:
		types.pop_back()
	target["droid_types"] = types
	target["plus_droids"] = types.count("PLUS")
	target["zeus_droids"] = types.count("ZEUS")
	target["total_droids"] = types.size()

	var server_cfg=oyuncu.get("ship_configurations",{})
	if server_cfg is Dictionary and not (server_cfg as Dictionary).is_empty():
		target["ship_configurations"]=(server_cfg as Dictionary).duplicate(true)
		target["selected_config"]=clampi(int(oyuncu.get("selected_config",1)),1,2)
		var sid:=str(oyuncu.get("active_ship_id","Ship10"))
		if server_ships.has(sid): target["active_ship"]=sid

	if GlobalState.server_session_active and str(GlobalState.username) == username:
		# PHASE 2: the level/XP pair is taken from the server payload, and
		# check_level_up() is deliberately NOT called here - the server derives
		# the level from XP in player_stats, so letting the client recompute it
		# would let a tampered save file grant levels.
		GlobalState.level = int(oyuncu.get("level", GlobalState.level))
		GlobalState.xp = int(oyuncu.get("exp", GlobalState.xp))

		# PHASES 2-7: one call applies every server-owned block (vitals, ammo,
		# equipment aggregate, confirmed map) from the same payload, so the HUD
		# and the local players.json can never disagree about any of them.
		GlobalState.apply_server_authority(oyuncu)

		if oyuncu.has("is_admin"):
			GlobalState.is_admin = bool(oyuncu.get("is_admin", false))
		GlobalState.owned_ships = server_ships.duplicate()
		GlobalState.inventory = inv.duplicate(true)
		GlobalState.droid_types = types.duplicate()
		GlobalState.plus_droids = types.count("PLUS")
		GlobalState.zeus_droids = types.count("ZEUS")
		GlobalState.total_droids = types.size()
		# PHASE 1 - server balance authority.
		# GlobalState.bitcoin / platinum / gold were ONLY ever populated from
		# the local save file, so the HUD could show 0 BTC while players.json
		# (and the server) both said 10000. The server payload is the single
		# source of truth, so it is mirrored into GlobalState here, at the same
		# moment the inventory already is. Absent keys keep the current value.
		if oyuncu.has("bitcoin"):
			GlobalState.bitcoin = int(oyuncu.get("bitcoin", GlobalState.bitcoin))
		if oyuncu.has("plt"):
			GlobalState.platinum = int(oyuncu.get("plt", GlobalState.platinum))
			GlobalState.uridium = int(oyuncu.get("plt", GlobalState.uridium))
		if oyuncu.has("gold"):
			GlobalState.gold = int(oyuncu.get("gold", GlobalState.gold))
		if oyuncu.has("honor"):
			GlobalState.honor = int(oyuncu.get("honor", GlobalState.honor))
		if oyuncu.has("log_disks"):
			GlobalState.log_disks = int(oyuncu.get("log_disks", GlobalState.log_disks))
		if oyuncu.has("skill_points"):
			GlobalState.skill_points = int(oyuncu.get("skill_points", GlobalState.skill_points))

	# Yeni bir hesaba eski aktif gemi/config taşınmasın.
	var active_ship := str(target.get("active_ship", "Ship10"))
	if not server_ships.has(active_ship):
		target["active_ship"] = "Ship10"

	save_players(players)


func server_market_buy(kind: String, item_id: String) -> Dictionary:
	var username := get_current_player().strip_edges()
	if username == "":
		return {
			"basarili": false,
			"mesaj": "Aktif oyuncu bulunamadı."
		}

	var http := HTTPRequest.new()
	http.process_mode = Node.PROCESS_MODE_ALWAYS
	http.timeout = 20.0
	get_tree().root.add_child(http)

	# Use local server if configured; server is authoritative for prices and balance
	var base_url := _get_server_url()
	var url := base_url + "/market/buy"

	# Generate idempotency key from item_id + a counter to prevent duplicate processing
	var tx_id := "%s_%s_%d" % [username, item_id, Time.get_ticks_msec()]

	var headers := ["Content-Type: application/json"]
	if not access_token.is_empty():
		headers.append("Authorization: Bearer " + access_token)

	var body := JSON.stringify({
		"item_id": item_id,
		"currency": "",  # Server determines currency from catalog
		"price": 0,      # Server ignores client price - uses catalog price
		"transaction_id": tx_id
	})

	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)

	if err != OK:
		http.queue_free()
		return {
			"basarili": false,
			"mesaj": "Market sunucusuna bağlanılamadı. Hata: %s" % str(err)
		}

	var result: Array = await http.request_completed
	var request_result: int = int(result[0])
	var response_code: int = int(result[1])
	var resp_body: String = (result[3] as PackedByteArray).get_string_from_utf8()
	http.queue_free()

	print("MARKET SERVER RESULT: ", request_result, " HTTP: ", response_code)

	if request_result != HTTPRequest.RESULT_SUCCESS:
		return {
			"basarili": false,
			"mesaj": "Market sunucu isteği tamamlanamadı. Kod: %s" % str(request_result)
		}

	var data = JSON.parse_string(resp_body)
	if response_code != 200 or not (data is Dictionary):
		# Try to extract error message from response
		var err_msg := "Market sunucu cevabı hatalı. HTTP: %s" % str(response_code)
		if data is Dictionary:
			err_msg = str(data.get("detail", err_msg))
		return {
			"basarili": false,
			"mesaj": err_msg
		}

	if bool(data.get("success", data.get("basarili", false))):
		# Sunucu yeni bakiyeleri döndürür; Seyir Defteri için fark önce
		# okunur, sonra bakiye uygulanır (satın alma: negatif delta).
		var previous_btc := int(GlobalState.bitcoin)
		var previous_plt := int(GlobalState.platinum)
		GlobalState.bitcoin = int(data.get("btc", data.get("bitcoin", GlobalState.bitcoin)))
		GlobalState.platinum = int(data.get("plt", data.get("platinum", GlobalState.platinum)))
		GlobalState.uridium = GlobalState.platinum
		_log_market_purchase(item_id, previous_btc, previous_plt)

		var live_inventory = data.get("inventory", {})
		if live_inventory is Dictionary:
			GlobalState.inventory = (live_inventory as Dictionary).duplicate(true)


		var oyuncu := {
			"id": get_active_player_id(),
			"username": username,
			"company": GlobalState.company,
			"map": GlobalState.start_map,
			"level": GlobalState.level,
			"exp": GlobalState.xp,
			"honor": GlobalState.honor,
			"bitcoin": GlobalState.bitcoin,
			"plt": GlobalState.platinum,
			"is_admin": GlobalState.is_admin,
			"owned_ships": data.get("owned_ships", []),
			"inventory": data.get("inventory", {}),
			"droid_types": data.get("droid_types", [])
		}
		sync_server_player_to_local(oyuncu)

	return data


# Sunucu onaylı market satın alımını Seyir Defteri'ne yazar.
#  1) "<ÜRÜN> satın alındı"
#  2) "-<FİYAT> BTC" / "-<FİYAT> PLT"  (yalnızca gerçekten düşen para)
func _log_market_purchase(item_id: String, previous_btc: int, previous_plt: int) -> void:
	var btc_delta := int(GlobalState.bitcoin) - previous_btc
	var plt_delta := int(GlobalState.platinum) - previous_plt
	if btc_delta == 0 and plt_delta == 0:
		return
	var label := str(item_id).strip_edges()
	if label.is_empty():
		label = "Ürün"
	GlobalState.add_logbook_entry("ECONOMY", "%s satın alındı" % label, label)
	if btc_delta < 0:
		GlobalState.add_logbook_entry("ECONOMY", "-%s BTC" % GlobalState.format_amount(-btc_delta), label)
	if plt_delta < 0:
		GlobalState.add_logbook_entry("ECONOMY", "-%s PLT" % GlobalState.format_amount(-plt_delta), label)


func server_update_company(company: String) -> Dictionary:
	var normalized_company := company.strip_edges().to_upper()
	if not ["EIC", "MMO", "VRU"].has(normalized_company):
		return {"basarili": false, "mesaj": "Geçersiz şirket."}
	if access_token.is_empty():
		return {"basarili": false, "mesaj": "Sunucu oturumu bulunamadı."}
	var http := HTTPRequest.new()
	http.process_mode = Node.PROCESS_MODE_ALWAYS
	http.timeout = 12.0
	get_tree().root.add_child(http)
	var base_url := _get_server_url()
	if base_url.is_empty():
		http.queue_free()
		return {"basarili": false, "mesaj": "Sunucu adresi tanımlı değil."}
	var err := http.request(base_url + "/account/company", [
		"Content-Type: application/json",
		"Authorization: Bearer " + access_token
	], HTTPClient.METHOD_PUT, JSON.stringify({"company": normalized_company}))
	if err != OK:
		http.queue_free()
		return {"basarili": false, "mesaj": "Şirket güncellenemedi."}
	var result: Array = await http.request_completed
	http.queue_free()
	var data = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	if int(result[1]) == 200 and data is Dictionary and bool(data.get("success", false)):
		return {"basarili": true, "mesaj": "Şirket kaydedildi.", "company": normalized_company}
	return {"basarili": false, "mesaj": "Şirket sunucuya kaydedilemedi."}


func server_login(username: String, password: String) -> Dictionary:
	var started_msec := Time.get_ticks_msec()
	var http := HTTPRequest.new()
	http.process_mode = Node.PROCESS_MODE_ALWAYS
	http.timeout = 12.0
	get_tree().root.add_child(http)

	var base_url := _get_server_url()
	if base_url.is_empty():
		return {"basarili": false, "mesaj": "Sunucu adresi tanımlı değil."}
	var url := base_url + "/auth/login"
	var body := JSON.stringify({"username": username, "password": password})
	var headers := ["Content-Type: application/json"]

	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	print("LOGIN_TIMING http_request_start elapsed_ms=", Time.get_ticks_msec() - started_msec)
	if err != OK:
		http.queue_free()
		print("LOGIN_TIMING server_login_returned elapsed_ms=", Time.get_ticks_msec() - started_msec, " status=failed")
		return {
			"basarili": false,
			"mesaj": "Sunucu bağlantı hatası"
		}

	var result: Array = await http.request_completed
	var response_code: int = int(result[1])
	var body_bytes: PackedByteArray = result[3]
	var response_body: String = body_bytes.get_string_from_utf8()
	print("LOGIN_TIMING http_response_received elapsed_ms=", Time.get_ticks_msec() - started_msec, " http_code=", response_code)
	http.queue_free()

	var data = JSON.parse_string(response_body)
	if response_code == 200 and data is Dictionary and data.has("access_token"):
		var access := str(data["access_token"])
		var refresh := str(data.get("refresh_token", ""))
		_save_tokens(access, refresh)

		if data.has("oyuncu") and data["oyuncu"] is Dictionary:
			var oyuncu: Dictionary = data["oyuncu"]
			if oyuncu.has("id"):
				save_active_player_id(str(oyuncu["id"]))
			if oyuncu.has("username"):
				save_active_user(str(oyuncu["username"]))
			# PHASE 1: the identity + session flag must be in place BEFORE the
			# sync, because sync_server_player_to_local() only mirrors the server
			# economy into GlobalState once it knows who the active player is.
			# Previously both were set afterwards, so a brand-new account loaded
			# the server inventory but kept a 0 BTC GlobalState.
			GlobalState.username = str(oyuncu.get("username", username))
			GlobalState.server_session_active = true
			sync_server_player_to_local(oyuncu)
		elif data.has("player_id"):
			save_active_user(username)
			save_active_player_id(str(data["player_id"]))
			GlobalState.username = username
			GlobalState.server_session_active = true
			sync_server_player_to_local({
				"username": username,
				"player_id": str(data["player_id"]),
				"is_admin": data.get("is_admin", false)
			})

		GlobalState.server_session_active = true
		print("LOGIN_TIMING server_login_returned elapsed_ms=", Time.get_ticks_msec() - started_msec, " status=success")
		return {
			"basarili": true,
			"mesaj": "Giriş başarılı",
			"access_token": access,
			"refresh_token": refresh,
			"player_id": get_active_player_id(),
			"company": str(data.get("company", "")).strip_edges().to_upper()
		}

	if response_code == 429:
		print("LOGIN_TIMING server_login_returned elapsed_ms=", Time.get_ticks_msec() - started_msec, " status=rate_limited")
		return {"basarili": false, "mesaj": "Çok fazla giriş denemesi. Lütfen bekleyin."}
	if int(result[0]) == HTTPRequest.RESULT_TIMEOUT:
		print("LOGIN_TIMING server_login_returned elapsed_ms=", Time.get_ticks_msec() - started_msec, " status=timeout")
		return {"basarili": false, "mesaj": "Sunucu yanıt vermedi. Lütfen tekrar deneyin."}

	print("LOGIN_TIMING server_login_returned elapsed_ms=", Time.get_ticks_msec() - started_msec, " status=failed http_code=", response_code)
	return {
		"basarili": false,
		"mesaj": "Kullanıcı adı veya şifre hatalı"
	}


func server_register(username:String, password:String, nickname:String, company:String) -> Dictionary:
	var http := HTTPRequest.new()
	http.process_mode = Node.PROCESS_MODE_ALWAYS
	http.timeout = 20.0
	get_tree().root.add_child(http)

	var base_url := _get_server_url()
	if base_url.is_empty():
		return {"basarili": false, "mesaj": "Sunucu adresi tanımlı değil."}
	var url := base_url + "/auth/register"
	var body := JSON.stringify({"username": username, "password": password, "nickname": nickname, "company": company})
	var headers := ["Content-Type: application/json"]

	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)

	if err != OK:
		http.queue_free()
		return {
			"basarili": false,
			"mesaj": "Sunucu bağlantı hatası"
		}

	var result: Array = await http.request_completed
	var response_code: int = int(result[1])
	var body_bytes: PackedByteArray = result[3]
	var response_body: String = body_bytes.get_string_from_utf8()

	http.queue_free()

	var data = JSON.parse_string(response_body)

	if response_code == 429:
		return {
			"basarili": false,
			"mesaj": "Çok fazla kayıt denemesi. Lütfen bekleyin."
		}

	# The server speaks the standard English register contract
	# ({"success": true, "player_id": ...}). Normalize it into the client's
	# basarili/mesaj contract so the caller sees ONE consistent shape.
	if response_code == 200 and data is Dictionary and bool(data.get("success", false)):
		var normalized: Dictionary = (data as Dictionary).duplicate(true)
		normalized["basarili"] = true
		normalized["mesaj"] = "Hesap oluşturuldu."
		normalized["player_id"] = str((data as Dictionary).get("player_id", ""))
		return normalized

	var detail := "Kayıt tamamlanamadı."
	if data is Dictionary and str((data as Dictionary).get("detail", "")) != "":
		detail = str((data as Dictionary).get("detail", detail))
	elif response_code == 409:
		detail = "Bu kullanıcı adı zaten kayıtlı."

	return {
		"basarili": false,
		"mesaj": detail,
		"http_code": response_code,
	}


func server_save_loadout(ship_configs: Dictionary, config_number: int, active_ship: String) -> Dictionary:
	var username:=get_current_player().strip_edges()
	if username=="": return {"basarili":false,"mesaj":"Aktif oyuncu yok"}
	var http:=HTTPRequest.new()
	http.process_mode=Node.PROCESS_MODE_ALWAYS
	http.timeout=20.0
	get_tree().root.add_child(http)
	var base_url := _get_server_url()
	if base_url.is_empty():
		return {"basarili":false,"mesaj":"Sunucu adresi tanımlı değil."}
	var url:=base_url+"/loadout/"+username.uri_encode()
	var body:=JSON.stringify({"ship_configurations":ship_configs,"selected_config":clampi(config_number,1,2),"active_ship_id":active_ship})
	var headers:=["Content-Type: application/json"]
	if not access_token.is_empty():
		headers.append("Authorization: Bearer " + access_token)
	var err: Error = http.request(url,headers,HTTPClient.METHOD_POST,body)
	if err!=OK:
		http.queue_free()
		return {"basarili":false,"mesaj":"Loadout isteği başlatılamadı"}
	var result: Array = await http.request_completed
	var code: int = int(result[1])
	var raw: String = (result[3] as PackedByteArray).get_string_from_utf8()
	http.queue_free()
	var parsed: Variant = JSON.parse_string(raw)
	if code==200 and parsed is Dictionary: return parsed
	return {"basarili":false,"mesaj":"Loadout kaydedilemedi (HTTP %d)" % code}


func server_logout() -> Dictionary:
	if access_token.is_empty() and refresh_token.is_empty():
		_clear_tokens()
		GlobalState.server_session_active = false
		return {"basarili": true, "mesaj": "Çıkış yapıldı"}

	var http := HTTPRequest.new()
	http.process_mode = Node.PROCESS_MODE_ALWAYS
	http.timeout = 5.0
	get_tree().root.add_child(http)

	var base_url := _get_server_url()
	if base_url.is_empty():
		_clear_tokens()
		GlobalState.server_session_active = false
		return {"basarili": true, "mesaj": "Çıkış yapıldı (sunucu adresi tanımlı değil)"}
	var url := base_url + "/auth/logout"
	var headers := ["Content-Type: application/json", "Authorization: Bearer " + access_token]
	var body := JSON.stringify({"refresh_token": refresh_token})

	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)

	if err != OK:
		http.queue_free()
		_clear_tokens()
		GlobalState.server_session_active = false
		return {"basarili": true, "mesaj": "Çıkış yapıldı (bağlantı hatası)"}

	var result: Array = await http.request_completed
	http.queue_free()

	_clear_tokens()
	GlobalState.server_session_active = false

	return {"basarili": true, "mesaj": "Başarıyla çıkış yapıldı"}


func server_refresh_token() -> Dictionary:
	if refresh_token.is_empty():
		return {"basarili": false, "mesaj": "Refresh token yok"}

	var http := HTTPRequest.new()
	get_tree().root.add_child(http)

	var base_url := _get_server_url()
	if base_url.is_empty():
		return {"basarili": false, "mesaj": "Sunucu adresi tanımlı değil."}
	var url := base_url + "/auth/refresh"
	var headers := ["Content-Type: application/json"]
	var body := JSON.stringify({"refresh_token": refresh_token})

	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)

	if err != OK:
		http.queue_free()
		return {"basarili": false, "mesaj": "Sunucu bağlantı hatası"}

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code = result[1]
	var body_str: String = (result[3] as PackedByteArray).get_string_from_utf8()
	var data = JSON.parse_string(body_str)

	if response_code == 200 and data != null and data.has("access_token"):
		var access := str(data["access_token"])
		var refresh := str(data.get("refresh_token", ""))
		if refresh.is_empty():
			refresh = refresh_token
		_save_tokens(access, refresh)
		return {"basarili": true, "mesaj": "Token yenilendi", "access_token": access}

	_clear_tokens()
	GlobalState.server_session_active = false
	return {"basarili": false, "mesaj": "Token yenilenemedi"}


# ==============================
# NOVAGATE SETTINGS - NICKNAME / PASSWORD (BOLUM 18 / 19)
# Yerel players.json tabanli; server aktif degilken LOCAL calisir.
# ==============================
const NICKNAME_MIN_LENGTH := 3
const NICKNAME_MAX_LENGTH := 20
const NICKNAME_CHANGE_COOLDOWN_DAYS := 7
const PASSWORD_MIN_LENGTH := 6


func _nickname_is_valid(text_value: String) -> bool:
	if text_value.length() < NICKNAME_MIN_LENGTH or text_value.length() > NICKNAME_MAX_LENGTH:
		return false
	for index in range(text_value.length()):
		var character := text_value[index]
		var is_valid := (character >= "a" and character <= "z") or (character >= "A" and character <= "Z") or (character >= "0" and character <= "9") or character == "_" or character == "-"
		if not is_valid:
			return false
	return true


func _nickname_taken(players: Array, nickname: String, exclude_username: String) -> bool:
	for player_value in players:
		if not (player_value is Dictionary):
			continue
		var player: Dictionary = player_value
		if str(player.get("username", "")) == exclude_username:
			continue
		if str(player.get("nickname", "")).strip_edges().to_lower() == nickname.to_lower():
			return true
	return false


func change_nickname(username: String, new_nickname: String) -> Dictionary:
	var clean := str(new_nickname).strip_edges()
	if clean.is_empty():
		return {"ok": false, "message": "Nickname bos olamaz."}
	if not _nickname_is_valid(clean):
		return {"ok": false, "message": "Nickname 3-20 karakter olmali; sadece harf, rakam, _ ve - kullanilabilir."}
	if username.is_empty():
		return {"ok": false, "message": "Aktif hesap bulunamadi."}
	var players = load_players()
	for player_value in players:
		if not (player_value is Dictionary):
			continue
		var player: Dictionary = player_value
		if str(player.get("username", "")) != username:
			continue
		_ensure_player_defaults(player)
		var current_nickname: String = str(player.get("nickname", username)).strip_edges()
		if current_nickname.to_lower() == clean.to_lower():
			return {"ok": false, "message": "Yeni nickname mevcut nickname ile ayni."}
		if _nickname_taken(players, clean, username):
			return {"ok": false, "message": "Bu nickname baska bir oyuncuda kayitli."}
		# 7 gunluk cooldown (BOLUM 18).
		var last_change: int = int(player.get("nickname_last_change", 0))
		var now: int = int(Time.get_unix_time_from_system())
		if last_change > 0:
			var elapsed_days: float = float(now - last_change) / 86400.0
			if elapsed_days < float(NICKNAME_CHANGE_COOLDOWN_DAYS):
				return {
					"ok": false,
					"message": "Nickname degisikligi icin kalan sure: %d gun." % int(ceil(float(NICKNAME_CHANGE_COOLDOWN_DAYS) - elapsed_days))
				}
		player["nickname"] = clean
		player["nickname_last_change"] = now
		save_players(players)
		# GlobalState ve kayit tutarli hale getirilir (username'den AYRIDIR).
		GlobalState.nickname = clean
		GlobalState.ship_name = clean
		GlobalState.save_game()
		return {"ok": true, "message": "Nickname '%s' olarak degistirildi." % clean}
	return {"ok": false, "message": "Oyuncu kaydi bulunamadi."}


func change_password(username: String, current_password: String, new_password: String, confirm_password: String) -> Dictionary:
	if username.is_empty():
		return {"ok": false, "message": "Aktif hesap bulunamadi."}
	if str(new_password).is_empty():
		return {"ok": false, "message": "Yeni sifre bos olamaz."}
	if str(new_password).length() < PASSWORD_MIN_LENGTH:
		return {"ok": false, "message": "Yeni sifre en az %d karakter olmali." % PASSWORD_MIN_LENGTH}
	if str(new_password) != str(confirm_password):
		return {"ok": false, "message": "Yeni sifre ve tekrari ayni degil."}
	var players = load_players()
	for player_value in players:
		if not (player_value is Dictionary):
			continue
		var player: Dictionary = player_value
		if str(player.get("username", "")) != username:
			continue
		_ensure_player_defaults(player)
		var stored: String = str(player.get("password", ""))
		if not stored.is_empty() and stored != str(current_password):
			return {"ok": false, "message": "Mevcut sifre hatali."}
		if stored == str(new_password):
			return {"ok": false, "message": "Yeni sifre eski sifre ile ayni olamaz."}
		player["password"] = str(new_password)
		save_players(players)
		return {"ok": true, "message": "Sifre basariyla degistirildi."}
	return {"ok": false, "message": "Oyuncu kaydi bulunamadi."}
