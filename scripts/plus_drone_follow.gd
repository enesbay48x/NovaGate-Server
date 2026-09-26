extends Node2D

@export var slot_index: int = 0

const DIRECTION_COUNT: int = 72
const FRAME_SIZE: Vector2 = Vector2(51.0, 51.0)
const FRAME_GAP: int = 2
const FIRST_ROW_COUNT: int = 38

@onready var player: PlayerShip = get_parent().get_parent() as PlayerShip
@onready var sprite: Sprite2D = $Sprite

var atlas_texture: Texture2D = preload("res://assets/droids/plus_droid.png")
var current_frame: int = -1

# Mevcut 8'li düzen aynen korunuyor.
var offsets: Array[Vector2] = [
	Vector2(0.0, -210.0),
	Vector2(-65.0, -165.0),
	Vector2(65.0, -165.0),
	Vector2(0.0, -125.0),

	Vector2(-120.0, -20.0),
	Vector2(-120.0, 50.0),

	Vector2(120.0, -20.0),
	Vector2(120.0, 50.0)
]


func _ready() -> void:
	sprite.centered = true
	sprite.scale = Vector2(0.96, 0.96)

	if player != null:
		_update_from_visible_ship_direction()
	else:
		position = offsets[clampi(slot_index, 0, offsets.size() - 1)]


func _process(_delta: float) -> void:
	if player == null or not is_instance_valid(player):
		player = get_parent().get_parent() as PlayerShip
		if player == null:
			return

	_update_from_visible_ship_direction()


func _update_from_visible_ship_direction() -> void:
	var local_offset: Vector2 = offsets[clampi(slot_index, 0, offsets.size() - 1)]

	# Formasyon KESİNLİKLE döndürülmez.
	# DroidManager oyuncunun child'i olduğu için bu local position,
	# gemi hareket ettikçe otomatik olarak gemiyle birlikte taşınır.
	position = local_offset

	# Node/Sprite fiziksel olarak çevrilmez.
	# Yalnızca 72 karelik görsel, geminin baktığı yöne göre değiştirilir.
	rotation = 0.0
	sprite.rotation = 0.0
	_set_direction_frame(player.direction_frame)


func _set_direction_frame(frame_index: int) -> void:
	var normalized_frame: int = posmod(frame_index, DIRECTION_COUNT)
	if normalized_frame == current_frame:
		return

	current_frame = normalized_frame

	var frame_x: int
	var frame_y: int

	if normalized_frame < FIRST_ROW_COUNT:
		frame_x = FRAME_GAP + normalized_frame * (int(FRAME_SIZE.x) + FRAME_GAP)
		frame_y = FRAME_GAP
	else:
		var second_row_index: int = normalized_frame - FIRST_ROW_COUNT
		frame_x = FRAME_GAP + second_row_index * (int(FRAME_SIZE.x) + FRAME_GAP)
		frame_y = FRAME_GAP + int(FRAME_SIZE.y) + FRAME_GAP

	var frame_texture := AtlasTexture.new()
	frame_texture.atlas = atlas_texture
	frame_texture.region = Rect2(Vector2(frame_x, frame_y), FRAME_SIZE)
	sprite.texture = frame_texture
