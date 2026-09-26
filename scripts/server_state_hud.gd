extends Control
##
## SERVER-AUTHORITATIVE HUD PANEL.
##
## WHAT THIS IS
## ------------
## A read-only view of the values the SERVER confirmed. Every field is read
## from the `GlobalState` autoload, which is written by
## `apply_server_authority()` from the login payload and the world snapshot.
##
## WHAT THIS IS NOT
## -----------------
## It is NOT a second source of truth. It keeps no gameplay state of its own:
## there is no `_hp`, no `_level`, no `_btc` member anywhere in this file. The
## panel holds only Node references to the Labels it writes into.
##
## That is deliberate. A parallel state system in the HUD is exactly how a
## client's numbers drift away from the server's and the player ends up looking
## at a health bar that disagrees with the damage they are taking. Here the only
## way a value can change is for the server to say so.
##
## Therefore there is also NO setter here. The panel is repainted by
## `refresh_from_server()`, and the only other thing that may write to
## GlobalState is the server path. A local edit to this file cannot invent HP.
##
## UNKNOWN VALUES
## --------------
## `server_health` / `server_shield` initialise to -1.0, meaning "the server has
## not told us yet". A -1 renders as "--" rather than as 0, so a missing value
## is visibly missing instead of looking like a dead player.

@onready var _labels: Dictionary = {}


func _ready() -> void:
	# Built entirely in code so the file has no scene dependency and can be
	# instantiated by a headless test as well as by the game.
	_build()
	refresh_from_server()


func _build() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	custom_minimum_size = Vector2(300, 430)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var box := VBoxContainer.new()
	box.name = "Rows"
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)

	_add_title(box, "NOVAGATE - SERVER STATE")
	_add_section(box, "PLAYER")
	_add_row(box, "hp", "HP")
	_add_row(box, "shield", "SHIELD")
	_add_row(box, "level", "LEVEL")
	_add_row(box, "xp", "XP")
	_add_row(box, "honor", "HONOR")
	_add_section(box, "ECONOMY")
	_add_row(box, "btc", "BTC")
	_add_row(box, "plt", "PLT")
	_add_row(box, "gold", "GOLD")
	_add_section(box, "SHIP")
	_add_row(box, "ship", "SHIP")
	_add_row(box, "speed", "SPEED")
	_add_row(box, "config", "CONFIG")
	_add_section(box, "COMBAT")
	_add_row(box, "laser", "LASER")
	_add_row(box, "ammo", "AMMO")
	_add_section(box, "WORLD")
	_add_row(box, "map", "MAP")
	_add_row(box, "position", "POSITION")
	_add_row(box, "players", "PLAYERS SEEN")


func _add_title(box: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.name = "Title"
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	box.add_child(label)


func _add_section(box: VBoxContainer, text: String) -> void:
	var label := Label.new()
	label.name = "Section_" + text
	label.text = text
	label.add_theme_font_size_override("font_size", 10)
	label.modulate = Color(0.55, 0.6, 0.7)
	box.add_child(label)


func _add_row(box: VBoxContainer, key: String, caption: String) -> void:
	var row := HBoxContainer.new()
	row.name = "Row_" + key

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.text = caption
	name_label.custom_minimum_size = Vector2(110, 0)
	name_label.modulate = Color(0.6, 0.65, 0.75)
	row.add_child(name_label)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.text = "--"
	row.add_child(value_label)

	box.add_child(row)
	_labels[key] = value_label


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------
# Re-read every field from GlobalState and repaint. Called on _ready, and again
# by the login / reconnect path, so a reconnect re-syncs the HUD from the
# server's values rather than from whatever the previous session left behind.
func refresh_from_server() -> void:
	if _labels.is_empty():
		return
	# NOTE: each line calls `text_for(...)` for its side effect and must NOT be
	# written back as `_labels[key] = ...`. `_labels` holds LABEL NODES; storing
	# the returned String there would replace the node with text, and the next
	# lookup would then try to use a String as a Label.
	text_for("hp", _fmt(server_health(), server_max_health()))
	text_for("shield", _fmt(server_shield(), server_max_shield()))
	text_for("level", str(GlobalState.level))
	text_for("xp", str(GlobalState.xp))
	text_for("honor", str(GlobalState.honor))
	text_for("btc", str(GlobalState.bitcoin))
	text_for("plt", str(GlobalState.platinum))
	text_for("gold", str(GlobalState.gold))
	text_for("ship", _ship_name())
	text_for("speed", _speed())
	text_for("config", str(_current_config()))
	text_for("laser", _laser_summary())
	text_for("ammo", _ammo_summary())
	text_for("map", _map_name())
	text_for("position", _position())
	text_for("players", str(_players_seen()))


func text_for(key: String, value: String) -> String:
	"""Write one field. Exposed so a headless test can assert the rendered text."""
	var label: Label = _labels.get(key, null)
	if label == null:
		return ""
	label.text = value
	return value


func displayed(key: String) -> String:
	"""What the panel currently shows. Read-only accessor for tests."""
	var label: Label = _labels.get(key, null)
	return "" if label == null else str(label.text)


# ---------------------------------------------------------------------------
# Value helpers - all pure reads, no writes
# ---------------------------------------------------------------------------
# A negative value is GlobalState's "server has not confirmed this yet" marker,
# so it shows as "--" rather than as a number. Showing 0 would read as "you are
# dead", which is a different and wrong statement.
func _fmt(current: float, maximum: float) -> String:
	if current < 0.0:
		return "--"
	if maximum > 0.0:
		return "%d / %d" % [int(round(current)), int(round(maximum))]
	return "%d" % int(round(current))


func server_health() -> float:
	return float(GlobalState.server_health)


func server_max_health() -> float:
	return float(GlobalState.server_max_health)


func server_shield() -> float:
	return float(GlobalState.server_shield)


func server_max_shield() -> float:
	return float(GlobalState.server_max_shield)


func _ship_name() -> String:
	var ship := str(GlobalState.active_ship_id)
	if ship.is_empty():
		ship = str(GlobalState.ship_name)
	return ship if not ship.is_empty() else "--"


func _speed() -> String:
	# Only the EQUIPMENT speed component is server-confirmed. A ship's base
	# speed is a static property of the hull and is not part of the server
	# payload, so the panel shows the confirmed part and says so, rather than
	# inventing a total the server never sent.
	return "+%d" % int(GlobalState.server_speed_bonus)


func _current_config() -> int:
	var index := int(GlobalState.selected_config)
	return index if index > 0 else 1


func _laser_summary() -> String:
	var lasers: Array = GlobalState.server_equipment_lasers
	if lasers.is_empty():
		return "--"
	return "%s (%d dmg)" % [",".join(PackedStringArray(lasers)),
			int(GlobalState.server_laser_damage)]


func _ammo_summary() -> String:
	var ammo: Dictionary = GlobalState.server_ammo
	if ammo.is_empty():
		return "--"
	var parts := PackedStringArray()
	for key in ammo.keys():
		parts.append("%s:%d" % [str(key), int(ammo[key])])
	return ", ".join(parts)


func _map_name() -> String:
	var map_id := str(GlobalState.server_map)
	if map_id.is_empty():
		map_id = str(GlobalState.start_map)
	return map_id if not map_id.is_empty() else "--"


func _position() -> String:
	if not GlobalState.server_has_position:
		return "--"
	return "%.0f, %.0f" % [float(GlobalState.server_pos_x),
			float(GlobalState.server_pos_y)]


# The world loop reports how many peers are on the map. GlobalState stores the
# population as a COMPANY-wide rank count, so that is what is shown; there is no
# separate per-map online counter in the server state today.
func _players_seen() -> int:
	return int(GlobalState.rank_company_count)


func _process(_delta: float) -> void:
	# Repaint every frame from GlobalState. Because nothing is cached locally, a
	# server update is visible on the very next frame and there is no stale copy
	# to desynchronise.
	refresh_from_server()
