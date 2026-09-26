
extends Control

var products = {
	"LAZER":[
		{"name":"LF1","stat":"Hasar: 75","price":"40.000 BTC"},
		{"name":"LF2","stat":"Hasar: 110","price":"80.000 BTC"},
		{"name":"LF3","stat":"Hasar: 175","price":"20.000 PLT"}
	],
	"KALKAN":[
		{"name":"Kalkan 1","stat":"+5000 Kalkan","price":"125.000 BTC"},
		{"name":"Kalkan 2","stat":"+10000 Kalkan","price":"15.000 PLT"}
	],
	"HIZ":[
		{"name":"Hız 1","stat":"+7 Hız","price":"125.000 BTC"},
		{"name":"Hız 2","stat":"+10 Hız","price":"10.000 PLT"}
	],
	"EXTRA":[
		{"name":"EMA","stat":"Kaçış sistemi","price":"150.000 PLT"},
		{"name":"ENC","stat":"Hasar emme","price":"95.000 PLT"}
	]
}

func load_category(category:String):
	return products.get(category, [])
