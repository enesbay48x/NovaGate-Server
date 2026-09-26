extends Node
class_name NovaGateMarketData

var items = {
	"LAZER": [
		{"name":"LF1","damage":90,"price":40000,"currency":"BTC"},
		{"name":"LF2","damage":132,"price":80000,"currency":"BTC"},
		{"name":"LF3","damage":210,"price":20000,"currency":"PLT"}
	],
	"KALKAN": [
		{"name":"Kalkan 1","power":6000,"price":125000,"currency":"BTC"},
		{"name":"Kalkan 2","power":12000,"price":15000,"currency":"PLT"}
	],
	"HIZ": [
		{"name":"Hız 1","bonus":8,"price":125000,"currency":"BTC"},
		{"name":"Hız 2","bonus":12,"price":10000,"currency":"PLT"}
	],
	"EXTRA": [
		{"name":"10'luk Extra","price":85000,"currency":"PLT"},
		{"name":"ENC","price":95000,"currency":"PLT"},
		{"name":"3 Saniye Kalkan","price":120000,"currency":"PLT"},
		{"name":"Nükleer","price":90000,"currency":"PLT"},
		{"name":"EMA","price":150000,"currency":"PLT"}
	]
}

func get_category(category:String):
	return items.get(category, [])
