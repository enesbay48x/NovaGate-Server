extends Control
class_name NovaGateMarketUI

@onready var product_list = $Panel/ProductList
@onready var title_label = $Panel/Title

var current_category = "LAZER"
var market_data = NovaGateMarketData.new()

func _ready():
	add_child(market_data)
	show_category("LAZER")

func show_category(category:String):
	current_category = category
	title_label.text = "NOVA GATE MARKET - " + category
	for child in product_list.get_children():
		child.queue_free()

	for item in market_data.get_category(category):
		var button = Button.new()
		button.text = str(item.name) + " | " + str(item.price) + " " + str(item.currency)
		product_list.add_child(button)

func _on_lazer_pressed():
	show_category("LAZER")

func _on_extra_pressed():
	show_category("EXTRA")
