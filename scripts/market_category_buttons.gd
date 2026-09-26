extends HBoxContainer

@onready var gemi_button = $GemiButton
@onready var cephane_button = $CephaneButton
@onready var lazer_button = $LazerButton
@onready var jenerator_button = $JeneratorButton
@onready var ekstralar_button = $EkstralarButton
@onready var droid_button = $DroidButton


func _ready():
	gemi_button.pressed.connect(_gemi)
	cephane_button.pressed.connect(_cephane)
	lazer_button.pressed.connect(_lazer)
	jenerator_button.pressed.connect(_jenerator)
	ekstralar_button.pressed.connect(_ekstralar)
	droid_button.pressed.connect(_droid)


func _gemi():
	print("MARKET GEMİ")


func _cephane():
	print("MARKET CEPHANE")


func _lazer():
	print("MARKET LAZER")


func _jenerator():
	print("MARKET JENERATÖR")


func _ekstralar():
	print("MARKET EKSTRALAR")


func _droid():
	print("MARKET DROİD")
