extends Node2D
class_name RemoteShip

var ship_name := ""
var target_position := Vector2.ZERO
var ship_visual: Node2D = null
var server_data: Dictionary = {}

# Multiplayer identity (all values come from the server world_update).
var player_id := ""
var username := ""
var company := ""
var relation := "neutral"  # friendly | enemy | neutral

var entity_status_bars: Node2D
var name_label: Label = null

const FRIENDLY_COLOR := Color(0.35, 1.0, 0.55, 1.0)
const ENEMY_COLOR := Color(1.0, 0.32, 0.32, 1.0)
const NEUTRAL_COLOR := Color(1.0, 1.0, 1.0, 1.0)

func _ready() -> void:
	entity_status_bars = preload("res://scripts/entity_status_bars.gd").new()
	entity_status_bars.bind_entity(self, _status_values,
		func(): return ship_visual,
		# Remote bars only for the entity explicitly marked as current target.
		func() -> bool: return bool(server_data.get("alive", true)) and bool(server_data.get("selected", false)))
	_create_name_label()

func _status_values() -> Vector4:
	return Vector4(
		float(server_data.get("health", server_data.get("hp", 0.0))),
		float(server_data.get("max_health", server_data.get("max_hp", 0.0))),
		float(server_data.get("shield", 0.0)),
		float(server_data.get("max_shield", 0.0)))

func setup(data: Dictionary) -> void:
	server_data = data
	ship_name = str(data.get("ship", ""))
	player_id = str(data.get("player_id", ""))
	username = str(data.get("username", ""))
	company = str(data.get("company", "")).strip_edges().to_upper()
	_refresh_relation()
	global_position = Vector2(
		float(data.get("pos_x", data.get("x", 0))),
		float(data.get("pos_y", data.get("y", 0)))
	)
	target_position = global_position
	_create_visual()
	_refresh_name_label()
	if is_instance_valid(entity_status_bars):
		entity_status_bars.refresh()

func apply_world_state(data: Dictionary) -> void:
	# Continuous world_update for this remote player.
	for key in ["hp", "max_hp", "shield", "max_shield", "alive", "selected"]:
		if data.has(key):
			server_data[key] = data[key]
	if data.has("username"):
		username = str(data["username"])
	if data.has("company"):
		company = str(data["company"]).strip_edges().to_upper()
		_refresh_relation()
		_refresh_name_label()
	if data.has("ship") and str(data["ship"]) != ship_name:
		ship_name = str(data["ship"])
		if is_instance_valid(ship_visual):
			ship_visual.queue_free()
			ship_visual = null
		_create_visual()
	if is_instance_valid(entity_status_bars):
		entity_status_bars.refresh()

func _refresh_relation() -> void:
	# Team relation is derived ONLY from company values (server authoritative),
	# never from usernames.
	var own_company := str(GlobalState.company).strip_edges().to_upper()
	if company.is_empty() or own_company.is_empty():
		relation = "neutral"
	elif company == own_company:
		relation = "friendly"
	else:
		relation = "enemy"

func relation_color() -> Color:
	match relation:
		"friendly":
			return FRIENDLY_COLOR
		"enemy":
			return ENEMY_COLOR
		_:
			return NEUTRAL_COLOR

func _create_name_label() -> void:
	if name_label != null:
		return
	name_label = Label.new()
	name_label.name = "RemoteNameLabel"
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.position = Vector2(-90.0, -52.0)
	name_label.size = Vector2(180.0, 18.0)
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	name_label.add_theme_constant_override("shadow_offset_x", 1)
	name_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(name_label)
	_refresh_name_label()

func _refresh_name_label() -> void:
	if name_label == null:
		return
	# WarUniverse tarzı: [MMO] EnemyPlayer
	if company.is_empty():
		name_label.text = username
	else:
		name_label.text = "[%s] %s" % [company, username]
	name_label.add_theme_color_override("font_color", relation_color())

func apply_name_visibility(show_names: bool) -> void:
	if name_label != null:
		name_label.visible = show_names

func set_selected(value: bool) -> void:
	# Same selection pipeline as NPCs; only presentation flag on server_data.
	server_data["selected"] = value
	if is_instance_valid(entity_status_bars):
		entity_status_bars.refresh()

func _create_visual() -> void:
	if ship_visual != null:
		return

	# Remote oyuncu local PlayerShip kopyası değildir.
	# Önce gerçek gemi sahnesi/texture yollarını dene.
	var sprite := Sprite2D.new()
	sprite.name = "RemoteShipVisual"

	var paths = [
		"res://assets/ships/%s.png" % ship_name,
		"res://assets/ships/%s.png" % ship_name.to_lower(),
		"res://assets/%s.png" % ship_name
	]

	for p in paths:
		if ResourceLoader.exists(p):
			sprite.texture = load(p)
			break

	add_child(sprite)
	ship_visual = sprite

func update_visual_data(data: Dictionary) -> void:
	server_data = data
	var new_ship := str(data.get("ship", ship_name))
	if new_ship != ship_name:
		ship_name = new_ship
		if is_instance_valid(ship_visual):
			ship_visual.queue_free()
		ship_visual = null
		_create_visual()
	if is_instance_valid(entity_status_bars):
		entity_status_bars.refresh()

func set_server_position(pos: Vector2) -> void:
	target_position = pos

func _process(delta: float) -> void:
	global_position = global_position.lerp(target_position, 1.0 - exp(-10.0 * delta))
