extends TextureButton


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			print("LAZER PANEL BUTONU BASILDI")
			accept_event()


func _process(delta: float) -> void:
	pass
