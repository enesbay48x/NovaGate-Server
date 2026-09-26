extends Node2D

@export var slot_index: int = 0
@export var follow_speed: float = 8.0

const DIRECTION_COUNT: int = 72
const FRAME_SIZE: Vector2 = Vector2(51.0, 51.0)
const FRAME_GAP: int = 2
const FIRST_ROW_COUNT: int = 38

@onready var player: PlayerShip = get_parent().get_parent() as PlayerShip
@onready var sprite: Sprite2D = $Sprite

var atlas_texture: Texture2D = preload("res://assets/ares_yellow.png")
var current_frame: int = -1

# WarUniverse tarzi 8'li duzen: 2 sol, 2 sag, 4 arka.
# Gemi saga bakarken +X on, -X arka, -Y sol, +Y sag.

var offsets: Array[Vector2] = [

	# GEMİNİN ARKASINDAKİ 4 DROİT
	Vector2(0.0, -210),       # D1
	Vector2(-65.0, -165.0),   # D2
	Vector2(65.0, -165.0),    # D3
	Vector2(0.0, -125.0),      # D4

	# GEMİNİN YANLARI
	Vector2(-120.0, -20.0),   # D5 sol ön
	Vector2(-120.0, 50.0),    # D6 sol arka

	Vector2(120.0, -20.0),    # D7 sağ ön
	Vector2(120.0, 50.0)      # D8 sağ arka
]

func _ready() -> void:
	sprite.centered = true
	sprite.scale = Vector2(0.96, 0.96)
	position = offsets[clampi(slot_index, 0, offsets.size() - 1)]
	print("DROIT SLOT:", slot_index)
	_set_direction_frame(player.direction_frame if player != null else 0)

func _process(delta: float) -> void:
	if player == null:
		return
	var local_offset: Vector2 = offsets[clampi(slot_index, 0, offsets.size() - 1)]
	var target_offset: Vector2 = local_offset.rotated(player.facing_angle - PI / 2)
	position = position.lerp(target_offset, 1.0 - exp(-follow_speed * delta))
	rotation = 0.0
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
