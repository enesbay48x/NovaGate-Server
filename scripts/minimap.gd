extends Control

@export var world_rect: Rect2 = Rect2(-5000.0,-3500.0,10000.0,7000.0)
@export var player_path: NodePath
@export var npc_container_path: NodePath
@export var npc_visible_range: float = 2500.0

@onready var player: PlayerShip = get_node_or_null(player_path) as PlayerShip
@onready var npc_container: Node2D = get_node_or_null(npc_container_path) as Node2D

const SECTOR_COLUMNS: int = 8
const SECTOR_ROWS: int = 6
const SECTOR_LETTERS: Array[String] = ["A","B","C","D","E","F"]
var OVERLAY_TEXTURE: Texture2D = null

func _load_overlay_texture() -> void:
	var path := "res://assets/mobile_minimap/sector_grid_overlay.png"
	if ResourceLoader.exists(path):
		OVERLAY_TEXTURE = load(path)

var portals: Array[Area2D] = []
var base_node: Node2D = null

var route_active: bool = false
var route_world_target: Vector2 = Vector2.ZERO
var route_sector: String = ""

var sector_label: Label
var target_label: Label


func set_map_objects(new_portals:Array, new_base:Node2D)->void:
	portals.clear()
	for p in new_portals:
		if p is Area2D:
			portals.append(p)
	base_node = new_base
	queue_redraw()


func _ready()->void:
	_load_overlay_texture()
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Mobilde dokunulabilir alanı biraz büyüt.
	if _is_mobile():
		custom_minimum_size = Vector2(250.0, 180.0)

	sector_label = Label.new()
	sector_label.name = "MobileSectorLabel"
	sector_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sector_label.position = Vector2(12, 9)
	sector_label.add_theme_font_size_override("font_size", 13)
	sector_label.add_theme_color_override("font_color", Color(0.35,1.0,0.55,1.0))
	sector_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	sector_label.add_theme_constant_override("shadow_offset_x", 1)
	sector_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(sector_label)

	target_label = Label.new()
	target_label.name = "MobileTargetSectorLabel"
	target_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	target_label.position = Vector2(12, 27)
	target_label.add_theme_font_size_override("font_size", 12)
	target_label.add_theme_color_override("font_color", Color(0.25,0.85,1.0,1.0))
	target_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	target_label.add_theme_constant_override("shadow_offset_x", 1)
	target_label.add_theme_constant_override("shadow_offset_y", 1)
	target_label.visible = false
	add_child(target_label)

	queue_redraw()


func _process(_delta:float)->void:
	if player != null and is_instance_valid(player):
		sector_label.text = "SEKTÖR " + _world_to_sector(player.global_position)

		if route_active:
			# Hedefe ulaşıldığında rota çizgisini kapat.
			if player.global_position.distance_to(route_world_target) <= 90.0:
				route_active = false
				target_label.visible = false
			elif not player.auto_navigation:
				route_active = false
				target_label.visible = false

	queue_redraw()


func _gui_input(event:InputEvent)->void:
	if player == null or not is_instance_valid(player):
		return

	# Mobilde gerçek ScreenTouch; PC'de mevcut mouse minimap navigasyonu korunur.
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_set_minimap_destination(touch.position)
			accept_event()
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and mouse_event.pressed:
			_set_minimap_destination(mouse_event.position)
			accept_event()


func _set_minimap_destination(local_point: Vector2) -> void:
	var inner := _inner_rect()
	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return

	var point := Vector2(
		clampf(local_point.x, inner.position.x, inner.end.x),
		clampf(local_point.y, inner.position.y, inner.end.y)
	)

	var normalized := (point - inner.position) / inner.size
	route_world_target = world_rect.position + normalized * world_rect.size
	route_world_target.x = clampf(route_world_target.x, world_rect.position.x, world_rect.end.x)
	route_world_target.y = clampf(route_world_target.y, world_rect.position.y, world_rect.end.y)

	route_active = true
	route_sector = _world_to_sector(route_world_target)

	target_label.text = "ROTA → " + route_sector
	target_label.visible = true

	# Ana oyun ekranına dokunma hareket ettirmez.
	# Yalnız minimap üzerinden verilen koordinat bu yolu kullanır.
	player.set_navigation_target(route_world_target)
	queue_redraw()


func _draw()->void:
	var inner := _inner_rect()

	draw_rect(Rect2(Vector2.ZERO,size), Color(0.018,0.026,0.05,0.96), true)
	draw_rect(inner, Color(0.03,0.05,0.085,1), true)
	draw_rect(inner, Color(0.20,0.68,0.85,0.88), false, 1.5)

	if inner.size.x <= 0.0 or inner.size.y <= 0.0:
		return

	# 8 sütun x 6 satır gerçek sektör grid'i.
	_draw_sector_grid(inner)

	# Kullanıcının verdiği A1-F8 görselini şeffaf overlay olarak minimapin üstüne koy.
	if OVERLAY_TEXTURE != null:
		draw_texture_rect(OVERLAY_TEXTURE, inner, false, Color(1,1,1,0.32))

	# Portallar.
	for p in portals:
		if p != null and is_instance_valid(p):
			var q := _world_to_map(p.global_position,inner)
			draw_circle(q,5.5,Color(1,0.38,0.12,0.95))
			draw_circle(q,9,Color(1,0.38,0.12,0.55),false,1.5)

	# Üs.
	if base_node != null and is_instance_valid(base_node):
		draw_circle(_world_to_map(base_node.global_position,inner),7,Color(0.25,1,0.55,0.95))

	# Yakın NPC'ler.
	if npc_container != null and is_instance_valid(npc_container) and player != null:
		for child in npc_container.get_children():
			if child is Node2D:
				var npc := child as Node2D
				if player.global_position.distance_to(npc.global_position) <= npc_visible_range:
					draw_circle(_world_to_map(npc.global_position,inner),2.4,Color(1,0.25,0.25,0.95))

	# Online oyuncular: same company -> friendly (yeşil), enemy company -> kırmızı.
	var remote_root := _find_remote_players_root()
	if remote_root != null:
		for child in remote_root.get_children():
			if child is Node2D:
				var remote := child as Node2D
				var marker_color := Color(1.0,0.82,0.18,1.0)
				var relation := str(remote.get("relation")) if remote.has_method("get") else ""
				match relation:
					"friendly":
						marker_color = Color(0.35,1.0,0.55,1.0)
					"enemy":
						marker_color = Color(1.0,0.3,0.3,1.0)
				draw_circle(_world_to_map(remote.global_position,inner),2.8,marker_color)

	if player == null or not is_instance_valid(player):
		return

	var pp := _world_to_map(player.global_position,inner)

	# WarUniverse tarzı rota çizgisi: oyuncudan seçilen minimap noktasına.
	if route_active:
		var target_point := _world_to_map(route_world_target,inner)
		draw_line(pp,target_point,Color(0.12,0.92,1.0,0.90),2.0,true)
		draw_circle(target_point,5.0,Color(0.12,0.92,1.0,0.25),true)
		draw_circle(target_point,7.0,Color(0.12,0.92,1.0,0.95),false,1.5)

	# Oyuncu.
	draw_circle(pp,4.2,Color(0.15,0.95,1,1))
	draw_circle(pp,7.0,Color(0.15,0.95,1,0.35),false,1.2)
	draw_line(pp,pp+Vector2.RIGHT.rotated(player.facing_angle)*8,Color.WHITE,2)


func _draw_sector_grid(inner: Rect2) -> void:
	var grid_color := Color(0.20,0.85,0.38,0.28)

	for column in range(1,SECTOR_COLUMNS):
		var x := inner.position.x + inner.size.x * float(column) / float(SECTOR_COLUMNS)
		draw_line(Vector2(x,inner.position.y),Vector2(x,inner.end.y),grid_color,1.0)

	for row in range(1,SECTOR_ROWS):
		var y := inner.position.y + inner.size.y * float(row) / float(SECTOR_ROWS)
		draw_line(Vector2(inner.position.x,y),Vector2(inner.end.x,y),grid_color,1.0)


func _world_to_sector(pos: Vector2) -> String:
	var normalized := (pos - world_rect.position) / world_rect.size
	var col := clampi(int(floor(normalized.x * SECTOR_COLUMNS)),0,SECTOR_COLUMNS-1)
	var row := clampi(int(floor(normalized.y * SECTOR_ROWS)),0,SECTOR_ROWS-1)
	return SECTOR_LETTERS[row] + str(col + 1)


func _world_to_map(pos:Vector2,inner:Rect2)->Vector2:
	var n := (pos-world_rect.position)/world_rect.size
	n.x = clampf(n.x,0,1)
	n.y = clampf(n.y,0,1)
	return inner.position+n*inner.size


func _inner_rect()->Rect2:
	return Rect2(Vector2(8,8),size-Vector2(16,16))


func _find_remote_players_root() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.find_child("RemotePlayers",true,false)


func _is_mobile() -> bool:
	return OS.get_name()=="Android" or OS.get_name()=="iOS"
