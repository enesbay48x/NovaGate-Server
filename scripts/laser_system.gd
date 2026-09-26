extends Node
class_name NovaGateLaserSystem

enum LaserType { X1, X2, X3, X4, SAB, RSB }

var current_laser = LaserType.X1
var previous_laser = LaserType.X1
var rsb_cooldown := false

var damage_multiplier = {
	LaserType.X1: 1.0,
	LaserType.X2: 2.0,
	LaserType.X3: 3.0,
	LaserType.X4: 4.0,
	LaserType.SAB: 3.0,
	LaserType.RSB: 6.0
}

var effects = {
	LaserType.X1: "laser1",
	LaserType.X2: "laser2",
	LaserType.X3: "laser3",
	LaserType.X4: "laser4",
	LaserType.SAB: "sab",
	LaserType.RSB: "laser6"
}

func select_laser(type):
	if type == LaserType.RSB:
		previous_laser = current_laser
	current_laser = type

func get_damage(base_damage):
	return base_damage * damage_multiplier[current_laser]

func fire():
	if current_laser == LaserType.RSB:
		if rsb_cooldown:
			return
		rsb_cooldown = true
		await get_tree().create_timer(3.0).timeout
		rsb_cooldown = false
		if current_laser == LaserType.RSB:
			current_laser = previous_laser
