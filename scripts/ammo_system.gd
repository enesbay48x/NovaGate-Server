extends Node

# Market stok adlarıyla gerçek lazer slot isimlerini eşleştirir.
const AMMO_NAME_MAP := {
	"RLX-1": "X1",
	"RLX-2": "X2",
	"GLX-2": "X2",
	"BLX-3": "X3",
	"WLX-4": "X4",
	"SAB": "SAB",
	"RSB": "RSB"
}

var selected_ammo := "RLX-1"


func select_ammo(name: String) -> void:
	if AMMO_NAME_MAP.has(name):
		selected_ammo = name


func current_market_ammo_name() -> String:
	return str(AMMO_NAME_MAP.get(selected_ammo, "X1"))


func get_current_amount() -> int:
	return GlobalState.get_ammo_count(current_market_ammo_name())


func _is_laser_item(value) -> bool:
	if value == null:
		return false
	# PHASE 1: item ids are canonical now, but a configuration saved before the
	# rename can still carry a display name, so accept both.
	var item := str(value).strip_edges().to_lower()
	if item in ["lf1", "lf2", "lf3"]:
		return true
	var am = load("res://scripts/account_manager.gd")
	return str(am.canonical_item_id(item)) in ["lf1", "lf2", "lf3"]


func get_equipped_laser_count() -> int:
	# DarkOrbit/WarUniverse tipi salvo mantığı:
	# Her aktif lazer, her lazer salvosunda 1 adet seçili lazer cephanesi tüketir.
	#
	# NovaGate'te aktif konfigürasyondaki:
	# - gemi lazer yuvaları
	# - satın alınmış droidlerin lazer yuvaları
	# birlikte sayılır.
	var account_manager = load("res://scripts/account_manager.gd").new()
	var username: String = account_manager.get_current_player()
	if username.is_empty():
		return 0

	var players = account_manager.load_players()
	for player_data in players:
		if str(player_data.get("username", "")) != username:
			continue

		var selected_config := int(player_data.get("selected_config", 1))
		if selected_config != 1 and selected_config != 2:
			selected_config = 1

		var configs = player_data.get("configurations", {})
		if not (configs is Dictionary):
			return 0

		var config = configs.get(str(selected_config), configs.get(selected_config, {}))
		if not (config is Dictionary):
			return 0

		var total := 0

		var lasers = config.get("lasers", [])
		if lasers is Array:
			for value in lasers:
				if _is_laser_item(value):
					total += 1

		var drones = config.get("drones", [])
		if drones is Array:
			for value in drones:
				if _is_laser_item(value):
					total += 1

		return total

	return 0


func get_salvo_ammo_cost() -> int:
	return get_equipped_laser_count()


func use_ammo() -> bool:
	var market_name := current_market_ammo_name()
	var salvo_cost := get_salvo_ammo_cost()

	# Lazer takılı değilse lazer saldırısı yapılamaz ve cephane harcanmaz.
	if salvo_cost <= 0:
		print("ATEŞ EDİLEMEDİ: AKTİF KONFİGÜRASYONDA LAZER YOK")
		return false

	if not GlobalState.use_ammo_stock(market_name, salvo_cost):
		print(
			"CEPHANE YETERSİZ: ", market_name,
			" | GEREKEN: ", salvo_cost,
			" | STOK: ", GlobalState.get_ammo_count(market_name)
		)
		return false

	print(
		"LAZER SALVOSU: ", market_name,
		" | AKTİF LAZER: ", salvo_cost,
		" | TÜKETİLEN CEPHANE: ", salvo_cost,
		" | KALAN: ", GlobalState.get_ammo_count(market_name)
	)
	return true
