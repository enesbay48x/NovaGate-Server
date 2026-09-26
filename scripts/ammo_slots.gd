extends Node

# WarUniverse tarzı değiştirilebilir slot sistemi
var slots := {
				1: "RLX-1",
				2: "GLX-2",
				3: "BLX-3",
				4: "WLX-4",
				5: "SAB",
				6: "RSB"
}

func set_slot(number:int, ammo_name:String):
				if slots.has(number):
								slots[number] = ammo_name

func get_slot(number:int)->String:
				return slots.get(number, "RLX-1")
