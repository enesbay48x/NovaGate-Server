extends RefCounted
class_name GalaxyGateData

# ==========================================================================
# NOVAGATE GALAXY GATE TANIM KATMANI
# --------------------------------------------------------------------------
# Alpha / Beta / Gamma dahil TUM gate bilgisi burada tanimlanir.
# Yeni bir gate eklemek icin definitions() icindeki tabloya yeni bir kayit
# eklemek yeterlidir; arena, wave sistemi, materializer, UI ve save katmani
# tamamen bu tanimlardan beslenir. Hicbir yerde gate adi hard-code edilmez.
# ==========================================================================

# Her kat 5 dalga, her dalga 5 NPC (BOLUM 7).
const WAVES_PER_FLOOR: int = 5
const NPCS_PER_WAVE: int = 5

# DarkOrbit klasik Galaxy Gate materializer orani.
# Kaynak: board-en.darkorbit.com -> "Galaxy Gate FAQ" ve "GI Gates".
const GATE_PART_CHANCE_PERCENT: int = 13

# Ayni parca tekrar geldiginde uygulanan carpan (BOLUM 5):
# 1 tekrar = x2, 2 tekrar = x3, 3 tekrar = x4, 4 tekrar = x5, 5 tekrar = x6.
const DUPLICATE_MULTIPLIER_BASE: int = 2
const DUPLICATE_MULTIPLIER_MAX: int = 6

# Materializer spin maliyeti. Mevcut NovaGate PLT ekonomisi kullanilir.
# 1 kullanim = 100 PLT; panel adimlari 5 = 500, 10 = 1.000, 100 = 10.000 PLT.
const MATERIALIZER_PLT_COST: int = 100

# Panelde sunulan materializer kullanim adimlari.
const MATERIALIZER_SPIN_OPTIONS: Array[int] = [1, 5, 10, 100]

# Materializer odul olasiliklari. Toplam tam %100'dur:
# Muhimmat %67 + Kapi parcasi %13 + Xenomit %12 + Nano Hull %4 +
# Tamir kuponu %3 + Log disk %1.
const REWARD_AMMO_PERCENT: int = 67
const REWARD_XENOMIT_PERCENT: int = 12
const REWARD_NANO_HULL_PERCENT: int = 4
const REWARD_REPAIR_COUPON_PERCENT: int = 3
const REWARD_LOG_DISK_PERCENT: int = 1

# Xenomit odul miktar araligi.
const XENOMIT_AMOUNT_MIN: int = 1
const XENOMIT_AMOUNT_MAX: int = 3

# Odul envanteri anahtarlari (mevcut GlobalState envanteri kullanilir).
const ITEM_XENOMIT: String = "Xenomit"
const ITEM_NANO_HULL: String = "Nano Hull"
const ITEM_REPAIR_COUPON: String = "Tamir Kuponu"

# Muhimmat odulu havuzu: anahtarlar GlobalState.ammo_inventory ile birebir
# uyumludur; yeni cephane tipi uydurulmaz.
const AMMO_REWARD_POOL := [
	{"ammo": "X1", "amount_min": 40, "amount_max": 260},
	{"ammo": "X2", "amount_min": 20, "amount_max": 140},
	{"ammo": "X3", "amount_min": 10, "amount_max": 70},
	{"ammo": "X4", "amount_min": 5, "amount_max": 35},
	{"ammo": "SAB", "amount_min": 3, "amount_max": 20},
	{"ammo": "RSB", "amount_min": 2, "amount_max": 14},
	{"ammo": "R1", "amount_min": 4, "amount_max": 26},
	{"ammo": "R2", "amount_min": 2, "amount_max": 16},
	{"ammo": "R3", "amount_min": 1, "amount_max": 10}
]

# Sirket -> X1 (ev) haritasi. main.gd MAP_NAMES ile birebir uyumludur.
const COMPANY_HOME_MAP := {
	"MMO": "1-1",
	"EIC": "2-1",
	"VRU": "3-1"
}

# Sirket ussu (0,0) cevresindeki gate portali konumu. Her sirket yalnizca
# kendi portalini gorur (BOLUM 24).
const COMPANY_GATE_POSITIONS := {
	"MMO": Vector2(-2600.0, 1600.0),
	"EIC": Vector2(2600.0, 1600.0),
	"VRU": Vector2(0.0, -2400.0)
}
const GATE_COMPANY_DEFAULT_POSITION := Vector2(-2600.0, 1600.0)

# Gate instance icindeki iki gecis kapisi (BOLUM 9 / BOLUM 10).
const GATE_RETURN_PORTAL_POSITION := Vector2(-1500.0, 0.0)
const GATE_NEXT_PORTAL_POSITION := Vector2(1500.0, 0.0)
const GATE_PORTAL_INTERACT_RADIUS: float = 260.0
const GATE_ENTRY_POSITION := Vector2(0.0, 1500.0)

# Sirket kodlari: bilinmeyen/yeni sirket gelirse MMO varsayilir.
const FALLBACK_COMPANY: String = "MMO"

const GATE_IDS: Array[String] = ["alpha", "beta", "gamma"]

# NPC havuzu: tamami npc.gd npc_stats icinde tanimli tiplerdir.
# (npc.configure taninmayan tipi reddeder, bu yuzden liste kisitlidir.)
const _T_SUPPORT := "zyron_raider"
const _T_FIGHTER := "nexar_fighter"
const _T_DESTROYER := "nexar_destroyer"
const _T_WARLORD := "nexar_warlord"
const _T_REAPER := "void_reaper"
const _T_PREDATOR := "void_predator"
const _T_GUARDIAN := "abyss_guardian"
const _T_RAVAGER := "void_ravager"

static func _repeat(npc_type: String, count: int) -> Array:
	var out: Array = []
	for i in range(maxi(count, 0)):
		out.append(npc_type)
	return out


static func _wave(npc_ids: Array, difficulty: float) -> Dictionary:
	var ids: Array = npc_ids.duplicate()
	while ids.size() > NPCS_PER_WAVE:
		ids.pop_back()
	while ids.size() < NPCS_PER_WAVE and not ids.is_empty():
		ids.append(ids[ids.size() - 1])
	return {"npc_ids": ids, "difficulty": maxf(difficulty, 0.1)}


static func _build_waves(per_wave: Array, base_difficulty: float) -> Array:
	# per_wave: her elemani bir dalgaya karsilik gelen NPC tip listesi.
	var waves: Array = []
	for i in range(per_wave.size()):
		var difficulty: float = base_difficulty * (1.0 + 0.12 * float(i))
		waves.append(_wave(per_wave[i], difficulty))
	return waves


static func definitions() -> Dictionary:
	# Gate tanim tablosu. Genisletilebilir tek kaynak.
	return {
		"alpha": {
			"id": "alpha",
			"name": "ALPHA",
			"required_parts": 34,
			"max_floors": 3,
			"difficulty_multiplier": 1.0,
			"company_restriction": "",
			"portal_position": Vector2(-2600.0, 1600.0),
			"wave_definitions": _build_waves([
				_repeat(_T_SUPPORT, 5),
				[_T_SUPPORT, _T_SUPPORT, _T_SUPPORT, _T_FIGHTER, _T_FIGHTER],
				_repeat(_T_FIGHTER, 5),
				[_T_FIGHTER, _T_FIGHTER, _T_FIGHTER, _T_DESTROYER, _T_DESTROYER],
				_repeat(_T_DESTROYER, 5)
			], 1.0),
			"completion_rewards": {
				"BTC": 250000,
				"PLT": 1500,
				"XP": 120000,
				"HONOR": 600,
				"ammo": {"X2": 500, "R1": 200},
				"items": {"LF1": 1}
			}
		},
		"beta": {
			"id": "beta",
			"name": "BETA",
			"required_parts": 48,
			"max_floors": 4,
			"difficulty_multiplier": 1.6,
			"company_restriction": "",
			"portal_position": Vector2(2600.0, 1600.0),
			"wave_definitions": _build_waves([
				_repeat(_T_FIGHTER, 5),
				_repeat(_T_DESTROYER, 5),
				_repeat(_T_WARLORD, 5),
				_repeat(_T_REAPER, 5),
				_repeat(_T_PREDATOR, 5)
			], 1.6),
			"completion_rewards": {
				"BTC": 900000,
				"PLT": 5200,
				"XP": 480000,
				"HONOR": 2400,
				"ammo": {"X3": 900, "R2": 350},
				"items": {"LF2": 1}
			}
		},
		"gamma": {
			"id": "gamma",
			"name": "GAMMA",
			"required_parts": 82,
			"max_floors": 5,
			"difficulty_multiplier": 2.4,
			"company_restriction": "",
			"portal_position": Vector2(0.0, -2400.0),
			"wave_definitions": _build_waves([
				_repeat(_T_WARLORD, 5),
				_repeat(_T_REAPER, 5),
				_repeat(_T_PREDATOR, 5),
				_repeat(_T_GUARDIAN, 5),
				_repeat(_T_RAVAGER, 5)
			], 2.4),
			"completion_rewards": {
				"BTC": 3200000,
				"PLT": 16000,
				"XP": 1500000,
				"HONOR": 9000,
				"ammo": {"X4": 1500, "R3": 500},
				"items": {"LF3": 1}
			}
		}
	}


static func _normalize(gate_id: String) -> String:
	return str(gate_id).strip_edges().to_lower()


static func gate_ids() -> Array[String]:
	return GATE_IDS.duplicate()


static func has_gate(gate_id: String) -> bool:
	return definitions().has(_normalize(gate_id))


static func definition(gate_id: String) -> Dictionary:
	var table: Dictionary = definitions()
	var key: String = _normalize(gate_id)
	if not table.has(key):
		return {}
	var entry = table[key]
	return entry if entry is Dictionary else {}


static func display_name(gate_id: String) -> String:
	var def: Dictionary = definition(gate_id)
	if def.is_empty():
		return str(gate_id).strip_edges().to_upper()
	return str(def.get("name", str(gate_id).strip_edges().to_upper()))


static func required_parts(gate_id: String) -> int:
	var def: Dictionary = definition(gate_id)
	if def.is_empty():
		return 0
	return maxi(1, int(def.get("required_parts", 1)))


static func max_floor(gate_id: String) -> int:
	var def: Dictionary = definition(gate_id)
	if def.is_empty():
		return 1
	return maxi(1, int(def.get("max_floors", 1)))


static func difficulty_multiplier(gate_id: String) -> float:
	var def: Dictionary = definition(gate_id)
	if def.is_empty():
		return 1.0
	return maxf(0.1, float(def.get("difficulty_multiplier", 1.0)))


static func completion_rewards(gate_id: String) -> Dictionary:
	var rewards = definition(gate_id).get("completion_rewards", {})
	return rewards if rewards is Dictionary else {}


static func waves_for_floor(gate_id: String, floor: int) -> Array:
	var def: Dictionary = definition(gate_id)
	var waves = def.get("wave_definitions", [])
	var safe_floor: int = clampi(floor, 1, max_floor(gate_id))
	var result: Array = []
	if waves is Array:
		for wave in waves:
			if not (wave is Dictionary):
				continue
			# Kati savunma: her dalga daima tam NPCS_PER_WAVE NPC tasir.
			var entry: Dictionary = (wave as Dictionary).duplicate(true)
			var ids = entry.get("npc_ids", [])
			var clean_ids: Array = ids if ids is Array else []
			if clean_ids.is_empty():
				clean_ids = _repeat(_T_SUPPORT, NPCS_PER_WAVE)
			while clean_ids.size() < NPCS_PER_WAVE:
				clean_ids.append(clean_ids[clean_ids.size() - 1])
			while clean_ids.size() > NPCS_PER_WAVE:
				clean_ids.pop_back()
			entry["npc_ids"] = clean_ids
			var floor_scale: float = 1.0 + 0.25 * float(safe_floor - 1)
			entry["difficulty"] = maxf(0.1, float(entry.get("difficulty", 1.0)) * floor_scale)
			result.append(entry)
	while result.size() < WAVES_PER_FLOOR:
		result.append(_wave(_repeat(_T_SUPPORT, NPCS_PER_WAVE), 1.0))
	return result


static func wave_definition(gate_id: String, floor: int, wave: int) -> Dictionary:
	var waves: Array = waves_for_floor(gate_id, floor)
	var index: int = clampi(wave, 1, WAVES_PER_FLOOR) - 1
	if index < 0 or index >= waves.size():
		return _wave(_repeat(_T_SUPPORT, NPCS_PER_WAVE), 1.0)
	return waves[index]


static func gate_map_id(gate_id: String, floor: int) -> String:
	# Ornek: alpha / kat 2 -> "gg_alpha_2"
	return "gg_%s_%d" % [_normalize(gate_id), clampi(floor, 1, 99)]


static func map_id_parts(map_id: String) -> Dictionary:
	var text := str(map_id).strip_edges().to_lower()
	if not text.begins_with("gg_"):
		return {}
	var split: PackedStringArray = text.substr(3).split("_")
	if split.size() < 2:
		return {}
	return {"gate_id": split[0], "floor": maxi(1, int(split[split.size() - 1]))}


static func is_gate_map(map_id: String) -> bool:
	return not map_id_parts(map_id).is_empty()


static func resolve_company(company: String) -> String:
	var code: String = str(company).strip_edges().to_upper()
	if COMPANY_HOME_MAP.has(code):
		return code
	return FALLBACK_COMPANY


static func home_map_for_company(company: String) -> String:
	return str(COMPANY_HOME_MAP.get(resolve_company(company), COMPANY_HOME_MAP[FALLBACK_COMPANY]))


static func gate_position_for_company(company: String) -> Vector2:
	return COMPANY_GATE_POSITIONS.get(resolve_company(company), GATE_COMPANY_DEFAULT_POSITION)


static func duplicate_multiplier(duplicate_count: int) -> int:
	# 1 tekrar = x2 ... 5 tekrar = x6, sonrasi tavanda kalir.
	var step: int = maxi(duplicate_count, 1) - 1
	return clampi(DUPLICATE_MULTIPLIER_BASE + step, DUPLICATE_MULTIPLIER_BASE, DUPLICATE_MULTIPLIER_MAX)


static func default_state(gate_id: String) -> Dictionary:
	return {
		"gate_id": _normalize(gate_id),
		"active": false,
		"completed": false,
		"current_parts": 0,
		"owned_parts": [],
		"duplicate_counts": {},
		"current_floor": 1,
		"current_wave": 1,
		"spawned_wave": 0,
		"completed_floors": [],
		"completed_waves": 0,
		"instance_id": "",
		"completion_reward_claimed": false,
		"in_run": false
	}
