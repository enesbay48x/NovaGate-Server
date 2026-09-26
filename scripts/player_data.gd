class_name PlayerData

var player_id:String = ""
var username:String = ""
var ship_name:String = ""
var ship_type:String = "Ship10"
var owned_ships:Array = ["Ship10"]
var active_ship:String = "Ship10"
var role:String = "player"
var company:String = ""
var current_map:String = "1-1"
var position_x:float = 0.0
var position_y:float = 0.0
var level:int = 1
var xp:int = 0
var honor:int = 0
var bitcoin:int = 0
var uridium:int = 0
var platinum:int = 0

# Droid kayıtları
var plus_droids:int = 0
var zeus_droids:int = 0
var total_droids:int = 0
var droid_types:Array = []
var inventory:Dictionary = {"extra": []}
var extras:Array = []
var booster_timers:Dictionary = {}
var clan:String = ""
var npc_kills:int = 0
var last_reward_xp:int = 0
var last_reward_bitcoin:int = 0
var last_reward_uridium:int = 0


# Booster Extra sistemi
func add_extra_booster(booster_id:String):
	if not booster_id in extras:
		extras.append(booster_id)

func remove_extra_booster(booster_id:String):
	if booster_id in extras:
		extras.erase(booster_id)

func has_extra_booster(booster_id:String) -> bool:
	return booster_id in extras


# Booster satın alma kaydı
func buy_booster(booster_id:String):
	if not extras.has(booster_id):
		extras.append(booster_id)
		booster_timers[booster_id] = Time.get_unix_time_from_system() + 10800

func get_active_boosters()->Array:
	var result:Array = []
	var now = Time.get_unix_time_from_system()
	for b in extras.duplicate():
		if booster_timers.get(b,0) > now:
			result.append(b)
		else:
			extras.erase(b)
	return result
