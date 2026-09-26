extends Node

const STARTER_SHIP := "Ship10"
const ADMIN_SHIP := "ADMIN"
const SHIP_DATA_PATH := "res://market/data/ships.json"

var owned_ships:Array = []
var active_ship:String = ""
var ship_catalog:Dictionary = {}

func _ready() -> void:
	load_catalog()

func load_catalog() -> void:
	ship_catalog.clear()
	if not FileAccess.file_exists(SHIP_DATA_PATH):
		return
	var f := FileAccess.open(SHIP_DATA_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		for ship_value in parsed:
			if ship_value is Dictionary:
				var ship:Dictionary = ship_value
				ship_catalog[str(ship.get("id",""))] = ship

func initialize_ship_data(data:Dictionary) -> void:
	owned_ships = data.get("owned_ships", [STARTER_SHIP])
	if not (owned_ships is Array):
		owned_ships = [STARTER_SHIP]
	if not owned_ships.has(STARTER_SHIP):
		owned_ships.push_front(STARTER_SHIP)

	active_ship = str(data.get("active_ship", STARTER_SHIP))
	if not owned_ships.has(active_ship):
		active_ship = STARTER_SHIP

func owns_ship(ship_id:String) -> bool:
	return owned_ships.has(ship_id)

func add_ship(ship_id:String) -> bool:
	if owns_ship(ship_id):
		return false
	owned_ships.append(ship_id)
	return true

func set_active_ship(ship_id:String) -> bool:
	if not owns_ship(ship_id):
		return false
	active_ship = ship_id
	return true

func get_ship_data(ship_id:String) -> Dictionary:
	if ship_catalog.is_empty():
		load_catalog()
	var value = ship_catalog.get(ship_id, {})
	return value if value is Dictionary else {}

func get_active_ship_data() -> Dictionary:
	return get_ship_data(active_ship)

func sell_ship(ship_id:String) -> bool:
	if ship_id == STARTER_SHIP:
		return false
	if not owns_ship(ship_id):
		return false
	owned_ships.erase(ship_id)
	if active_ship == ship_id:
		active_ship = STARTER_SHIP
	return true
