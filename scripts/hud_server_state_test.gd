extends Node
##
## REAL GODOT TEST: the server-authoritative HUD panel.
##
## Drives the ACTUAL panel script against the ACTUAL `GlobalState` autoload,
## feeding it a login payload in exactly the shape the server sends
## (`apply_server_authority`), then asserting on the TEXT the panel renders.
##
## WHAT IS PROVEN
## --------------
##   H1  an unknown value renders as "--", not as 0
##   H2  a real server payload renders HP, shield, level, XP, honor
##   H3  BTC / PLT / GOLD render the server's numbers
##   H4  ship, speed bonus, config, laser, ammo, map, position render
##   H5  a SECOND payload fully replaces the first (the reconnect case: a stale
##       value surviving here is the bug this test exists to catch)
##   H7  after a logout that clears the server fields the panel shows "--"
##       again, rather than keeping the previous session's numbers
##
## Emits: HUD_E2E_RESULT passed=.. failed=..
## Usage:
##   godot --headless --path <project> res://scenes/hud_server_state_test.tscn
## ===========================================================================

var _failures: Array = []
var _checks: Array = []


func _check(name: String, ok: bool, detail: String = "") -> void:
	_checks.append({"name": name, "ok": bool(ok)})
	if ok:
		print("HUD_OK   ", name)
	else:
		_failures.append(name)
		print("HUD_FAIL ", name, "  ", detail)


func _ready() -> void:
	# The panel is instantiated directly - no scene, no mocks. GlobalState is
	# the real autoload, so this is the real object graph the game uses.
	var panel_script: Script = load("res://scripts/server_state_hud.gd")
	var panel: Control = panel_script.new()
	add_child(panel)

	_test_unknown_renders_dashes(panel)

	var payload := {
		"level": 7,
		"exp": 52000,
		"honor": 145,
		"hp": 640.0,
		"max_hp": 900.0,
		"shield": 310.0,
		"max_shield": 500.0,
		"npc_kills": 12,
		"player_kills": 3,
		"deaths": 1,
		# The economy keys are the ones the server actually sends:
		# `bitcoin` / `plt` / `gold`.
		"bitcoin": 123456,
		"plt": 65432,
		"gold": 2100,
		"ship": "Ship10",
		"map": "1-2",
		"position_x": 140.0,
		"position_y": 260.0,
		"ammo_inventory": {"ammo_lf1": 480, "ammo_lf2": 90},
		"equipment_stats": {
			"lasers": ["lf1", "lf2"],
			"laser_damage": 222,
			"shield": 5000,
			"speed_bonus": 7,
		},
	}
	GlobalState.apply_server_authority(payload)
	panel.refresh_from_server()
	_test_progression(panel)
	_test_economy(panel)
	_test_ship_and_combat(panel)

	# A second, different payload must fully replace the first.
	var second := {
		"level": 12,
		"exp": 190000,
		"honor": 12,
		"hp": 1200.0,
		"max_hp": 1200.0,
		"shield": 0.0,
		"max_shield": 700.0,
		"bitcoin": 5,
		"plt": 5,
		"gold": 0,
		"ship": "Ship12",
		"map": "3-6",
		"position_x": -40.0,
		"position_y": 12.0,
		"ammo_inventory": {"ammo_lf3": 1},
		"equipment_stats": {"lasers": ["lf3"], "laser_damage": 210,
				"shield": 10000, "speed_bonus": 10},
	}
	GlobalState.apply_server_authority(second)
	panel.refresh_from_server()
	_test_resync_after_reconnect(panel)

	# Logout: the server has confirmed nothing, so the panel must say so.
	GlobalState.server_health = -1.0
	GlobalState.server_max_health = -1.0
	GlobalState.server_shield = -1.0
	GlobalState.server_max_shield = -1.0
	GlobalState.server_has_position = false
	GlobalState.server_map = ""
	panel.refresh_from_server()
	_test_logout_clears_display(panel)

	_report()


# ---------------------------------------------------------------------------
# H1 - nothing confirmed yet
# ---------------------------------------------------------------------------
func _test_unknown_renders_dashes(panel: Control) -> void:
	# `server_health` is -1 before the first server response. Rendering that as
	# 0 would tell the player they are dead.
	_check("H1 unknown HP renders as --", panel.displayed("hp") == "--",
			"got '%s'" % panel.displayed("hp"))
	_check("H1 unknown shield renders as --",
			panel.displayed("shield") == "--",
			"got '%s'" % panel.displayed("shield"))


# ---------------------------------------------------------------------------
# H2 - progression
# ---------------------------------------------------------------------------
func _test_progression(panel: Control) -> void:
	_check("H2 level from server", panel.displayed("level") == "7",
			"got '%s'" % panel.displayed("level"))
	_check("H2 xp from server", panel.displayed("xp") == "52000",
			"got '%s'" % panel.displayed("xp"))
	_check("H2 honor from server", panel.displayed("honor") == "145",
			"got '%s'" % panel.displayed("honor"))
	_check("H2 hp/max from server", panel.displayed("hp") == "640 / 900",
			"got '%s'" % panel.displayed("hp"))
	_check("H2 shield/max from server",
			panel.displayed("shield") == "310 / 500",
			"got '%s'" % panel.displayed("shield"))


# ---------------------------------------------------------------------------
# H3 - economy
# ---------------------------------------------------------------------------
func _test_economy(panel: Control) -> void:
	_check("H3 BTC from server", panel.displayed("btc") == "123456",
			"got '%s'" % panel.displayed("btc"))
	_check("H3 PLT from server", panel.displayed("plt") == "65432",
			"got '%s'" % panel.displayed("plt"))
	_check("H3 GOLD from server", panel.displayed("gold") == "2100",
			"got '%s'" % panel.displayed("gold"))


# ---------------------------------------------------------------------------
# H4 - ship and combat
# ---------------------------------------------------------------------------
func _test_ship_and_combat(panel: Control) -> void:
	_check("H4 ship from server", panel.displayed("ship") == "Ship10",
			"got '%s'" % panel.displayed("ship"))
	_check("H4 speed bonus from server", panel.displayed("speed") == "+7",
			"got '%s'" % panel.displayed("speed"))
	_check("H4 current config", panel.displayed("config") == "1",
			"got '%s'" % panel.displayed("config"))
	_check("H4 lasers + damage from server",
			panel.displayed("laser") == "lf1,lf2 (222 dmg)",
			"got '%s'" % panel.displayed("laser"))
	_check("H4 ammo from server",
			panel.displayed("ammo").contains("ammo_lf1:480"),
			"got '%s'" % panel.displayed("ammo"))
	_check("H4 map from server", panel.displayed("map") == "1-2",
			"got '%s'" % panel.displayed("map"))
	_check("H4 position from server", panel.displayed("position") == "140, 260",
			"got '%s'" % panel.displayed("position"))


# ---------------------------------------------------------------------------
# H5 - the reconnect case
# ---------------------------------------------------------------------------
func _test_resync_after_reconnect(panel: Control) -> void:
	_check("H5 level resynced", panel.displayed("level") == "12",
			"got '%s'" % panel.displayed("level"))
	_check("H5 hp resynced", panel.displayed("hp") == "1200 / 1200",
			"got '%s'" % panel.displayed("hp"))
	_check("H5 BTC resynced", panel.displayed("btc") == "5",
			"got '%s'" % panel.displayed("btc"))
	_check("H5 map resynced", panel.displayed("map") == "3-6",
			"got '%s'" % panel.displayed("map"))
	_check("H5 position resynced", panel.displayed("position") == "-40, 12",
			"got '%s'" % panel.displayed("position"))
	_check("H5 lasers resynced",
			panel.displayed("laser") == "lf3 (210 dmg)",
			"got '%s'" % panel.displayed("laser"))
	_check("H5 no stale ammo from the first session",
			not panel.displayed("ammo").contains("ammo_lf1"),
			"got '%s'" % panel.displayed("ammo"))


# ---------------------------------------------------------------------------
# H7 - logout
# ---------------------------------------------------------------------------
func _test_logout_clears_display(panel: Control) -> void:
	# Keeping the previous session's HP on screen after a logout is exactly the
	# "old local values overwrite server state" failure this guards against.
	_check("H7 HP returns to -- after logout",
			panel.displayed("hp") == "--",
			"got '%s'" % panel.displayed("hp"))
	_check("H7 shield returns to -- after logout",
			panel.displayed("shield") == "--",
			"got '%s'" % panel.displayed("shield"))
	_check("H7 position returns to -- after logout",
			panel.displayed("position") == "--",
			"got '%s'" % panel.displayed("position"))


func _report() -> void:
	print("HUD_E2E_RESULT passed=%d failed=%d"
			% [_checks.size() - _failures.size(), _failures.size()])
	get_tree().quit(0 if _failures.is_empty() else 1)
