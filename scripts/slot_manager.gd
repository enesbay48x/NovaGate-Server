extends Node

# NovaGate oyuncu tarafından değiştirilebilir savaş kısayolları.
# 1-6 tuşlarının hangi lazer/cephaneyi seçeceği burada tutulur ve cihazda kaydedilir.
const SAVE_PATH := "user://novagate_laser_shortcuts.cfg"
const SECTION := "laser_shortcuts"
const VALID_AMMO := ["RLX-1", "RLX-2", "BLX-3", "WLX-4", "SAB", "RSB"]

var slots: Dictionary = {
	1: "RLX-1",
	2: "RLX-2",
	3: "BLX-3",
	4: "WLX-4",
	5: "SAB",
	6: "RSB"
}

func _ready() -> void:
	load_slots()

func change_slot(slot: int, ammo_name: String) -> void:
	assign_laser_to_slot(slot, ammo_name)

func get_slot(slot: int) -> String:
	return str(slots.get(slot, "RLX-1"))

func get_slot_laser(slot: int) -> String:
	return get_slot(slot)

func assign_laser_to_slot(slot: int, laser: String) -> void:
	if not slots.has(slot):
		return
	if not VALID_AMMO.has(laser):
		push_warning("Geçersiz lazer kısayolu: " + laser)
		return

	slots[slot] = laser
	save_slots()
	print("LAZER KISAYOLU: ", slot, " = ", laser)

func save_slots() -> void:
	var cfg := ConfigFile.new()
	for slot in range(1, 7):
		cfg.set_value(SECTION, str(slot), get_slot(slot))
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		push_warning("Lazer kısayolları kaydedilemedi. Hata: " + str(err))

func load_slots() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err != OK:
		return

	for slot in range(1, 7):
		var saved := str(cfg.get_value(SECTION, str(slot), get_slot(slot)))
		if VALID_AMMO.has(saved):
			slots[slot] = saved

func reset_slots() -> void:
	slots = {
		1: "RLX-1",
		2: "RLX-2",
		3: "BLX-3",
		4: "WLX-4",
		5: "SAB",
		6: "RSB"
	}
	save_slots()
