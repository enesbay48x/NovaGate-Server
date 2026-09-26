extends Node2D
class_name MapManager

@export var map_root: String = "res://hrta/"
@export var tile_texture: String = "res://space_assets/01_solar/layer1_far.png"

var map_layer: Node2D
var object_layer: Node2D

const TILE_SIZE := Vector2(2048,2048)
const RANGE := 2

func _ready() -> void:
	map_layer = Node2D.new()
	map_layer.name = "BackgroundTiles"
	map_layer.z_index = -200
	add_child(map_layer)

	object_layer = Node2D.new()
	object_layer.name = "MapObjects"
	object_layer.z_index = -50
	add_child(object_layer)


func load_map(map_name:String="1-1") -> void:
	clear()

	# Eski tile arka plan sistemi kapatildi. Harita MapVisualManager tarafindan yukleniyor.

	var folder := map_root + map_name + "/"

	add_object(folder+"station.png", Vector2.ZERO, -70)
	add_object(folder+"planet.png", Vector2.ZERO, -80)
	add_object(folder+"rocks1.png", Vector2.ZERO, -60)
	add_object(folder+"rocks2.png", Vector2.ZERO, -60)


func create_background_tiles()->void:
	if not ResourceLoader.exists(tile_texture):
		print("Background bulunamadı:", tile_texture)
		return

	var tex = load(tile_texture)

	for x in range(-RANGE,RANGE+1):
		for y in range(-RANGE,RANGE+1):
			var s:=Sprite2D.new()
			s.texture=tex
			s.position=Vector2(x,y)*TILE_SIZE
			s.z_index=-200
			map_layer.add_child(s)


func add_object(path:String,pos:Vector2,z:int)->void:
	if not ResourceLoader.exists(path):
		return
	var s:=Sprite2D.new()
	s.texture=load(path)
	s.position=pos
	s.z_index=z
	object_layer.add_child(s)


func clear()->void:
	if map_layer:
		for c in map_layer.get_children():
			c.queue_free()
	if object_layer:
		for c in object_layer.get_children():
			c.queue_free()
