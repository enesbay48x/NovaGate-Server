extends Node2D

const MAX_DROIDS := 8
const PLUS_SCENE := preload("res://scenes/plus_droid.tscn")
const ZEUS_SCENE := preload("res://scenes/zeus_droid.tscn")

func _ready() -> void:
	call_deferred("refresh_from_save")

func refresh_from_save() -> void:
	var account_manager = load("res://scripts/account_manager.gd").new()
	var droid_types: Array = account_manager.get_droid_types()
	load_player_droids(droid_types)

func load_player_droids(droid_types: Array) -> void:
	clear_droids()

	var safe_types: Array = []
	for droid_type in droid_types:
		var normalized := str(droid_type).to_upper()
		if normalized == "PLUS" or normalized == "ZEUS":
			safe_types.append(normalized)
		if safe_types.size() >= MAX_DROIDS:
			break

	for i in range(safe_types.size()):
		var droid: Node2D
		if safe_types[i] == "PLUS":
			droid = PLUS_SCENE.instantiate()
		else:
			droid = ZEUS_SCENE.instantiate()

		droid.slot_index = i
		add_child(droid)

func clear_droids() -> void:
	for child in get_children():
		child.queue_free()
