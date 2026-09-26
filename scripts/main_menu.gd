extends Control

func _ready() -> void:
	_connect_buttons()

func _connect_buttons() -> void:
	var play_button = get_node_or_null("Play")
	if play_button and play_button is Button and not play_button.pressed.is_connected(_play):
		play_button.pressed.connect(_play)
	var market_button = get_node_or_null("Market")
	if market_button and market_button is Button and not market_button.pressed.is_connected(_market):
		market_button.pressed.connect(_market)

func _play() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")

func _market() -> void:
	get_tree().change_scene_to_file("res://market/market.tscn")
