extends Node2D
class_name NPCLaserEffect

const TEXTURES: Dictionary = {
	"zyron_raider": preload("res://assets/npc_lasers/alien10.png"),
	"nexar_fighter": preload("res://assets/npc_lasers/alien20.png"),
	"nexar_destroyer": preload("res://assets/npc_lasers/alien30.png"),
	"nexar_warlord": preload("res://assets/npc_lasers/alien40.png"),
	"void_reaper": preload("res://assets/npc_lasers/alien50.png"),
	"void_predator": preload("res://assets/npc_lasers/alien60.png"),
	"abyss_guardian": preload("res://assets/npc_lasers/alien70.png"),
	"void_ravager": preload("res://assets/npc_lasers/alien90.png"),
}

@onready var sprite: Sprite2D = $Sprite

var source_node: Node2D
var target_node: Node2D
var npc_type: String = ""
var travel_time: float = 0.18
var elapsed: float = 0.0
var start_pos: Vector2
var end_pos: Vector2


func setup(source: Node2D, target: Node2D, type_name: String) -> void:
	source_node = source
	target_node = target
	npc_type = type_name


func _ready() -> void:
	if TEXTURES.has(npc_type):
		sprite.texture = TEXTURES[npc_type]

	if is_instance_valid(source_node):
		start_pos = source_node.global_position
	else:
		start_pos = global_position

	if is_instance_valid(target_node):
		end_pos = target_node.global_position
	else:
		end_pos = start_pos + Vector2.RIGHT * 100.0

	global_position = start_pos
	rotation = start_pos.direction_to(end_pos).angle()

	# Görseller tek kare olduğu için hareket + pulse ile lazer animasyonu oluşturuyoruz.
	sprite.scale = Vector2(0.72, 0.72)
	sprite.modulate.a = 0.95
	z_index = 200


func _process(delta: float) -> void:
	elapsed += delta

	if is_instance_valid(source_node) and elapsed < 0.05:
		start_pos = source_node.global_position

	if is_instance_valid(target_node):
		end_pos = target_node.global_position

	var t := clampf(elapsed / travel_time, 0.0, 1.0)
	var eased := 1.0 - pow(1.0 - t, 2.5)

	global_position = start_pos.lerp(end_pos, eased)

	var direction := start_pos.direction_to(end_pos)
	if direction.length_squared() > 0.001:
		rotation = direction.angle()

	# Kısa pulse efekti: çıkışta büyür, hedefte küçülür.
	var pulse := 1.0 + sin(t * PI) * 0.28
	sprite.scale = Vector2(0.72, 0.72) * pulse
	sprite.modulate.a = lerpf(1.0, 0.15, t)

	if t >= 1.0:
		queue_free()
