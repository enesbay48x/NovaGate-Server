extends Node

# Bu script eski ekipman fonksiyonlarını korur; aktif geminin slot limitlerine uyum sağlar.
var laser_slots := 30
var generator_slots := 16
var extra_slots := 8
var lasers := []
var generators := []
var extras := []
var booster_icons := {
	"DMG-B01":"res://market/assets/boosters/DMG-B01.png",
	"HP-B01":"res://market/assets/boosters/HP-B01.png",
	"SHD-B01":"res://market/assets/boosters/SHD-B01.png",
	"XP-B01":"res://market/assets/boosters/XP-B01.png",
	"HON-B01":"res://market/assets/boosters/HON-B01.png"
}

var laser_damage = {"LF1":90, "LF2":132, "LF3":210, "lf1":90, "lf2":132, "lf3":210}
# PHASE 1: item ids are canonical (lf1/kalkan1/hiz1). The legacy display
# spellings are kept alongside so a hangar built before the rename still
# resolves to the same numbers - no value changes, only extra keys.
var shields = {"Kalkan1":6000, "Kalkan2":12000, "Kalkan 1":6000, "Kalkan 2":12000,
	"kalkan1":6000, "kalkan2":12000}

func _ready():
	_resize_slots()

func configure_for_ship(ship_data:Dictionary) -> void:
	laser_slots = clampi(int(ship_data.get("laser_slots", laser_slots)), 0, 30)
	generator_slots = clampi(int(ship_data.get("generator_slots", generator_slots)), 0, 16)
	extra_slots = clampi(int(ship_data.get("extra_slots", extra_slots)), 0, 8)
	_resize_slots()

func _resize_slots() -> void:
	lasers.resize(laser_slots)
	generators.resize(generator_slots)
	extras.resize(extra_slots)

func equip_laser(slot:int, item:String):
	if slot >= 0 and slot < laser_slots:
		lasers[slot] = item

func remove_laser(slot:int):
	if slot >= 0 and slot < laser_slots:
		lasers[slot] = null

func equip_generator(slot:int, item:String):
	if slot >= 0 and slot < generator_slots:
		generators[slot] = item

func remove_generator(slot:int):
	if slot >= 0 and slot < generator_slots:
		generators[slot] = null

func get_total_damage():
	var total = 0
	for item in lasers:
		if item != null:
			total += laser_damage.get(item,0)
	return total

func get_total_shield():
	var total = 0
	for item in generators:
		if item != null:
			total += shields.get(item,0)
	return total


func get_extras():
	return extras

func equip_extra(slot:int, item:String):
	if slot >= 0 and slot < extra_slots:
		extras[slot] = item

func remove_extra(slot:int):
	if slot >= 0 and slot < extra_slots:
		extras[slot] = null


func load_player_extras(player_extras:Array):
	_resize_slots()
	for i in range(extra_slots):
		extras[i] = null
	for i in range(min(player_extras.size(), extra_slots)):
		var item = player_extras[i]
		if item is Dictionary:
			extras[i] = str(item.get("name",""))
		else:
			extras[i] = str(item)

func get_active_extras() -> Array:
	return extras.filter(func(x): return x != null)
