extends Node

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.physical_keycode == KEY_CTRL and key_event.pressed and not key_event.echo:
			WeaponSystem.toggle_auto_fire()
			get_viewport().set_input_as_handled()
