extends RefCounted
class_name RankData

# NovaGate rutbe veri katmani.
# Bu dosya SADECE veri tutar: ag, UI ve Node bagimliligi yoktur.
# Boylece ayni veri hem client hem sunucu tarafinda kullanilabilir.
# Mevcut rutbe altyapisi (GlobalState.rank_key / rank_title / rank_points)
# korunur; bu katman o altyapinin eksik kalan yerel hesaplama verisini saglar.

# Normal rutbe sayisi (A rutbesi bu sayiya dahil DEGILDIR).
const RANK_COUNT := 21

# Sirket kodlari ve mevcut sirket renkleri.
const COMPANY_CODES: Array = ["MMO", "EIC", "VRU"]
const COMPANY_COLORS: Dictionary = {
	"MMO": Color(0.87, 0.24, 0.24),
	"EIC": Color(0.24, 0.56, 0.96),
	"VRU": Color(0.26, 0.82, 0.38)
}
const COMPANY_COLOR_DEFAULT: Color = Color(0.74, 0.80, 0.88)

# "A" rutbesi: normal rutbe hiyerarsisinin disindadir.
# Yuzdelere ve kontenjanlara girmez, sadece admin panelinden verilir.
const RANK_A_KEY := "admin"
const RANK_A_TITLE := "A Rutbesi"
const RANK_A_ICON := "admin"
# A rutbesi savas statlarina runtime carpani uygular (BASE x 2, asla ustune eklenmez).
const RANK_A_STAT_MULTIPLIER := 2.0
# A rutbesi BTC/PLT/EXP/Şeref/Rutbe Puani kazancini DEGISTIRMEZ.
# (Cift odul olusmamasi icin ekonomi tarafinda hicbir carpan uygulanmaz.)
const RANK_A_ECONOMY_MULTIPLIER := 1.0

# --- 21 rutbelik merdiven (index 1 = en yuksek rutbe, 21 = en dusuk) ---
# "icon" alani assets/ranks/ranks.png atlasindaki GERCEK ikon adidir.
# Atlas icinde toplam 12 ikon vardir; 21 rutbe bu 12 ikona eslenir.
# Eksik ikon uydurulmaz, ayni aile ikonu paylasilir.
const RANKS: Array = [
	{"index": 1, "key": "chief_general", "title": "Baş General", "icon": "general"},
	{"index": 2, "key": "general", "title": "General", "icon": "general"},
	{"index": 3, "key": "basic_general", "title": "Temel General", "icon": "gen-maj"},
	{"index": 4, "key": "chief_colonel", "title": "Baş Albay", "icon": "gen-col"},
	{"index": 5, "key": "colonel", "title": "Albay", "icon": "colonel"},
	{"index": 6, "key": "basic_colonel", "title": "Temel Albay", "icon": "colonel"},
	{"index": 7, "key": "chief_major", "title": "Baş Binbaşı", "icon": "marshal"},
	{"index": 8, "key": "major", "title": "Binbaşı", "icon": "major"},
	{"index": 9, "key": "basic_major", "title": "Temel Binbaşı", "icon": "major"},
	{"index": 10, "key": "chief_captain", "title": "Baş Yüzbaşı", "icon": "captain"},
	{"index": 11, "key": "captain", "title": "Yüzbaşı", "icon": "captain"},
	{"index": 12, "key": "basic_captain", "title": "Temel Yüzbaşı", "icon": "captain"},
	{"index": 13, "key": "chief_lieutenant", "title": "Baş Üsteğmen", "icon": "lieutenant"},
	{"index": 14, "key": "lieutenant", "title": "Üsteğmen", "icon": "lieutenant"},
	{"index": 15, "key": "basic_lieutenant", "title": "Temel Üsteğmen", "icon": "lieutenant"},
	{"index": 16, "key": "chief_sergeant", "title": "Baş Çavuş", "icon": "sergeant"},
	{"index": 17, "key": "sergeant", "title": "Çavuş", "icon": "sergeant"},
	{"index": 18, "key": "basic_sergeant", "title": "Temel Çavuş", "icon": "sergeant"},
	{"index": 19, "key": "chief_pilot", "title": "Baş Uzay Pilotu", "icon": "private"},
	{"index": 20, "key": "pilot", "title": "Uzay Pilotu", "icon": "private"},
	{"index": 21, "key": "basic_pilot", "title": "Temel Uzay Pilotu", "icon": "private"}
]

# Rutbe icin gereken minimum rutbe puani (artarak yukselir, deterministiktir).
const RANK_MIN_POINTS: Dictionary = {
	"chief_general": 2600000.0,
	"general": 2000000.0,
	"basic_general": 1550000.0,
	"chief_colonel": 1200000.0,
	"colonel": 920000.0,
	"basic_colonel": 720000.0,
	"chief_major": 560000.0,
	"major": 430000.0,
	"basic_major": 330000.0,
	"chief_captain": 250000.0,
	"captain": 190000.0,
	"basic_captain": 140000.0,
	"chief_lieutenant": 100000.0,
	"lieutenant": 70000.0,
	"basic_lieutenant": 48000.0,
	"chief_sergeant": 32000.0,
	"sergeant": 20000.0,
	"basic_sergeant": 12000.0,
	"chief_pilot": 6000.0,
	"pilot": 2000.0,
	"basic_pilot": 0.0
}

# Ust rutbeler icin SIRKET BASINA sabit kontenjan (kisi sayisi).
const FIXED_QUOTA: Dictionary = {
	"chief_general": 1,
	"general": 2,
	"basic_general": 3,
	"chief_colonel": 5,
	"colonel": 20
}

# Kalan 16 rutbe icin sirket nufusuna oranla yuzde tavani.
# basic_pilot (en alt rutbe) tavansizdir: herkes mutlaka bir rutbeye sahiptir.
const PERCENT_QUOTA: Dictionary = {
	"basic_colonel": 0.2,
	"chief_major": 0.4,
	"major": 0.7,
	"basic_major": 1.0,
	"chief_captain": 1.5,
	"captain": 2.0,
	"basic_captain": 2.6,
	"chief_lieutenant": 3.4,
	"lieutenant": 4.4,
	"basic_lieutenant": 5.6,
	"chief_sergeant": 7.0,
	"sergeant": 8.5,
	"basic_sergeant": 10.0,
	"chief_pilot": 12.0,
	"pilot": 18.0
}

# Yuzde tavanlari cok kucuk sirketlerde anlamsiz olacagi icin
# bu nufusun altinda tavanlar baglayici degildir.
const PERCENT_MIN_POPULATION := 5

# Gemi turunun rutbe puani karsiligi (mevcut menu degerleriyle birebir ayni).
const SHIP_RANK_VALUES: Dictionary = {
	"Ship10": 1, "Başlangıç Gemisi": 1, "Ship20": 2, "Ship40": 3,
	"Ship50": 4, "Ship60": 5, "Ship70": 6, "Ship80": 7,
	"Ship100": 8, "Ship106": 10
}

# --- Yardimci erisim fonksiyonlari (saf, yan etkisiz) ---

static func clamp_rank_index(index: int) -> int:
	return clampi(index, 1, RANK_COUNT)


static func rank_entry(index: int) -> Dictionary:
	var wanted := clamp_rank_index(index)
	for entry in RANKS:
		if int(entry.get("index", 0)) == wanted:
			return entry
	return RANKS[RANK_COUNT - 1]


static func rank_entry_by_key(rank_key: String) -> Dictionary:
	for entry in RANKS:
		if str(entry.get("key", "")) == rank_key:
			return entry
	return RANKS[RANK_COUNT - 1]


static func index_for_key(rank_key: String) -> int:
	for entry in RANKS:
		if str(entry.get("key", "")) == rank_key:
			return int(entry.get("index", RANK_COUNT))
	return RANK_COUNT


static func title_for_key(rank_key: String) -> String:
	return str(rank_entry_by_key(rank_key).get("title", ""))


static func icon_for_index(index: int) -> String:
	return str(rank_entry(index).get("icon", "private"))


static func icon_for_key(rank_key: String) -> String:
	if rank_key == RANK_A_KEY:
		return RANK_A_ICON
	return str(rank_entry_by_key(rank_key).get("icon", "private"))


static func min_points_for_key(rank_key: String) -> float:
	return float(RANK_MIN_POINTS.get(rank_key, 0.0))


static func company_color(company_code: String) -> Color:
	return COMPANY_COLORS.get(company_code.strip_edges().to_upper(), COMPANY_COLOR_DEFAULT)


static func normalize_company(company_code: String) -> String:
	var value := company_code.strip_edges().to_upper()
	return value if COMPANY_CODES.has(value) else ""


static func ship_rank_value(ship_name: String) -> int:
	# Bilinmeyen gemi adi icin puan UYDURULMAZ; 0 doner.
	return maxi(int(SHIP_RANK_VALUES.get(ship_name, 0)), 0)


static func quota_for_key(rank_key: String, population: int) -> int:
	# Ust rutbeler: sirket basina sabit kontenjan.
	if FIXED_QUOTA.has(rank_key):
		return int(FIXED_QUOTA[rank_key])
	# En alt rutbe: tavansiz (herkes mutlaka bir rutbeye sahip olmalidir).
	if not PERCENT_QUOTA.has(rank_key):
		return -1
	# Cok kucuk sirketlerde yuzde tavani baglayici degildir.
	if population < PERCENT_MIN_POPULATION:
		return -1
	var ratio := float(PERCENT_QUOTA[rank_key]) / 100.0
	# Yuzde tavani en az 1 kisi olacak sekilde yuvarlanir.
	return maxi(int(floor(float(population) * ratio + 0.5)), 1)


static func is_a_rank(rank_key: String) -> bool:
	return rank_key == RANK_A_KEY


static func is_valid_normal_rank(rank_key: String) -> bool:
	for entry in RANKS:
		if str(entry.get("key", "")) == rank_key:
			return true
	return false