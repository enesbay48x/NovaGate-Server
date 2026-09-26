extends TextureButton

signal laser_pressed

func _ready():
    mouse_filter = Control.MOUSE_FILTER_STOP
    pressed.connect(_on_pressed)

func _on_pressed():
    print("LAZER BUTTON CALISTI")
    laser_pressed.emit()
