extends Control

var products = [
	"LF1 - Hasar 75 - 40.000 BTC",
	"LF2 - Hasar 110 - 80.000 BTC",
	"LF3 - Hasar 175 - 20.000 PLT",
	"Kalkan 1 - 5000 - 125.000 BTC",
	"Kalkan 2 - 10000 - 15.000 PLT"
]

func _ready():
	var list = $ProductList
	for p in products:
		var b = Button.new()
		b.text = p
		list.add_child(b)
