extends Node
class_name EquipmentSystem

var lasers = {
	"LF1": {"damage":90, "count":0},
	"LF2": {"damage":132, "count":0},
	"LF3": {"damage":210, "count":0},
	# PHASE 1: canonical ids alongside the legacy display names, so a caller
	# using either spelling resolves to the same entry. No values changed.
	"lf1": {"damage":90, "count":0},
	"lf2": {"damage":132, "count":0},
	"lf3": {"damage":210, "count":0}
}

var shields = {
	"Kalkan1": {"value":6000, "count":0},
	"Kalkan2": {"value":12000, "count":0},
	"kalkan1": {"value":6000, "count":0},
	"kalkan2": {"value":12000, "count":0}
}

var laser_slots:int = 30
var generator_slots:int = 15


func total_laser_damage() -> int:
	var total := 0

	for item in lasers.values():
		total += item["damage"] * item["count"]

	return total


func total_shield() -> int:
	var total := 0

	for item in shields.values():
		total += item["value"] * item["count"]

	return total
