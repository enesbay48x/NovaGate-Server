extends RefCounted
class_name RankService
# Global sinif onbellegine bagimli kalmadan veri katmanini yukler.
const Ranks = preload("res://scripts/rank_data.gd")

# NovaGate rutbe hesaplama servisi.
# Tamamen SAF (stateless) ve Node/ag bagimsizdir: ayni kod hem client hem
# sunucu tarafinda calisabilir. GlobalState bu servisi cagirir; boylece
# ikinci bir rutbe/stat sistemi olusturulmaz.

# Rutbe puani kirilim satirlari (mevcut menu dokumu ile ayni kurallar).
# Sadece oyunda ZATEN tutulan veriler kullanilir; yeni stat uydurulmaz.
static func compute_rank_points(stats: Dictionary) -> Dictionary:
	var xp := maxi(int(stats.get("xp", 0)), 0)
	var honor := maxi(int(stats.get("honor", 0)), 0)
	var level := maxi(int(stats.get("level", 1)), 1)
	var player_kills := maxi(int(stats.get("player_kills", 0)), 0)
	var days := maxi(int(stats.get("days_registered", 0)), 0)
	var npc_kills := maxi(int(stats.get("npc_kills", 0)), 0)
	var missions := maxi(int(stats.get("missions_completed", 0)), 0)
	var friendly_kills := maxi(int(stats.get("friendly_kills", 0)), 0)
	var deaths := maxi(int(stats.get("deaths", 0)), 0)
	var ship_name := str(stats.get("ship_id", stats.get("ship_name", "")))
	var ship_value := Ranks.ship_rank_value(ship_name)

	var rows: Array = [
		_row("+", "Tecrübe Puanı", xp, "/ 100.000", float(xp) / 100000.0),
		_row("+", "Şeref Puanları", honor, "/ 100", float(honor) / 100.0),
		_row("+", "Oyuncu İmha Puanları", player_kills, "x 3", float(player_kills) * 3.0),
		_row("+", "Seviyen", level, "x 100", float(level) * 100.0),
		_row("+", "Kayıttan beri gün sayısı", days, "x 6", float(days) * 6.0),
		_row("+", "Geminin türü", ship_value, "x 1.000", float(ship_value) * 1000.0),
		_row("+", "NPC İmha Puanları", npc_kills, "/ 2", float(npc_kills) / 2.0),
		_row("+", "Tamamlanan görevler", missions, "x 100", float(missions) * 100.0),
		_row("-", "Dost oyuncu imha", friendly_kills, "x 100", float(friendly_kills) * 100.0),
		_row("-", "Ölümler", deaths, "x 4", float(deaths) * 4.0)
	]

	var points := 0.0
	for row in rows:
		if str(row.get("sign", "+")) == "+":
			points += float(row.get("amount", 0.0))
		else:
			points -= float(row.get("amount", 0.0))
	points = maxf(points, 0.0)

	return {
		"points": points,
		"rows": rows
	}


static func _row(sign: String, label: String, value: int, unit: String, amount: float) -> Dictionary:
	return {
		"sign": sign,
		"label": label,
		"value": value,
		"unit": unit,
		"amount": amount
	}


# Puanin hak ettigi EN YUKSEK rutbe indexi (1..21).
static func rank_index_for_points(points: float) -> int:
	var safe_points := maxf(points, 0.0)
	for entry in Ranks.RANKS:
		var key := str(entry.get("key", ""))
		if safe_points + 0.0001 >= Ranks.min_points_for_key(key):
			return int(entry.get("index", Ranks.RANK_COUNT))
	return Ranks.RANK_COUNT


static func rank_key_for_points(points: float) -> String:
	return str(Ranks.rank_entry(rank_index_for_points(points)).get("key", "basic_pilot"))


static func rank_title_for_points(points: float) -> String:
	return str(Ranks.rank_entry(rank_index_for_points(points)).get("title", ""))


# Bir ust rutbeye gecmek icin gereken puan bilgisi.
# En ust rutbede next_rank_points = -1.0 doner (mevcut GlobalState sozlesmesi).
static func next_rank_info(rank_index: int) -> Dictionary:
	var current := Ranks.clamp_rank_index(rank_index)
	if current <= 1:
		return {"title": "", "points": -1.0}
	var next_entry := Ranks.rank_entry(current - 1)
	var next_key := str(next_entry.get("key", ""))
	return {
		"title": str(next_entry.get("title", "")),
		"points": Ranks.min_points_for_key(next_key)
	}


# --- Kayit (players.json) alanlari ile calisan yardimcilar ---

static func record_id(record: Dictionary) -> String:
	var player_id := str(record.get("player_id", ""))
	if not player_id.is_empty():
		return player_id
	var username := str(record.get("username", ""))
	if not username.is_empty():
		return username
	return str(record.get("nickname", ""))


static func days_registered_from_timestamp(created_at_unix: int) -> int:
	if created_at_unix <= 0:
		return 0
	var now := int(Time.get_unix_time_from_system())
	return maxi(int((float(now) - float(created_at_unix)) / 86400.0), 0)


static func stats_from_record(record: Dictionary) -> Dictionary:
	var ship_id := str(record.get("ship_type", ""))
	if ship_id.is_empty():
		ship_id = str(record.get("active_ship", ""))
	if ship_id.is_empty():
		ship_id = str(record.get("ship_name", ""))
	return {
		"xp": int(record.get("xp", record.get("exp", 0))),
		"honor": int(record.get("honor", 0)),
		"level": int(record.get("level", 1)),
		"player_kills": int(record.get("player_kills", 0)),
		"npc_kills": int(record.get("npc_kills", 0)),
		"missions_completed": int(record.get("missions_completed", 0)),
		"friendly_kills": int(record.get("friendly_kills", 0)),
		"deaths": int(record.get("deaths", record.get("player_deaths", 0))),
		"ship_id": ship_id,
		"ship_name": str(record.get("ship_name", "")),
		"days_registered": days_registered_from_timestamp(int(record.get("created_at", 0)))
	}


static func points_for_record(record: Dictionary) -> float:
	return float(compute_rank_points(stats_from_record(record)).get("points", 0.0))


# Kesin (deterministik) siralama: puan -> xp -> kullanici adi.
# Lambda yerine statik karsilastirma kullanilir; tum platformlarda ayni sonuc.
static func _sorts_before(a: Dictionary, b: Dictionary) -> bool:
	# Ham kayitlarda rank_points olmayabilir; o durumda puan yeniden hesaplanir.
	var pa := float(a.get("rank_points", points_for_record(a)))
	var pb := float(b.get("rank_points", points_for_record(b)))
	if not is_equal_approx(pa, pb):
		return pa > pb
	var xa := int(a.get("xp", a.get("exp", 0)))
	var xb := int(b.get("xp", b.get("exp", 0)))
	if xa != xb:
		return xa > xb
	return str(a.get("username", "")).to_lower() < str(b.get("username", "")).to_lower()


static func sort_players(players: Array) -> Array:
	# Insertion sort: deterministiktir ve nufus kucuk oldugu icin yeterlidir.
	var sorted: Array = []
	for record in players:
		if not (record is Dictionary):
			continue
		sorted.append(record)
	var i := 1
	while i < sorted.size():
		var current = sorted[i]
		var j := i - 1
		while j >= 0 and _sorts_before(current, sorted[j]):
			sorted[j + 1] = sorted[j]
			j -= 1
		sorted[j + 1] = current
		i += 1
	return sorted


# Sirket ici dagitim: ust rutbeler sabit kontenjan, alt rutbeler yuzde tavani.
# A rutbesi bu dagitima dahil EDILMEZ (GlobalState sozlesmesi).
static func resolve_company(players: Array) -> Dictionary:
	var candidates: Array = []
	for record in players:
		if not (record is Dictionary):
			continue
		if bool((record as Dictionary).get("a_rank", false)):
			continue
		candidates.append(record)

	var ordered := sort_players(candidates)
	var results := {}
	var population := ordered.size()
	if population == 0:
		return results

	var capacities := {}
	for entry in Ranks.RANKS:
		var key := str(entry.get("key", ""))
		capacities[key] = Ranks.quota_for_key(key, population)

	var position := 0
	for record in ordered:
		position += 1
		var points := float(record.get("rank_points", points_for_record(record)))
		var start_index := rank_index_for_points(points)
		var placed_index := Ranks.RANK_COUNT
		for index in range(start_index, Ranks.RANK_COUNT + 1):
			var key := str(Ranks.rank_entry(index).get("key", ""))
			var remaining := int(capacities.get(key, -1))
			if remaining < 0 or remaining > 0:
				placed_index = index
				if remaining > 0:
					capacities[key] = remaining - 1
				break
		results[str(record.get("username", ""))] = {
			"player_id": str(record.get("player_id", "")),
			"username": str(record.get("username", "")),
			"nickname": str(record.get("nickname", record.get("username", ""))),
			"company": str(record.get("company", "")),
			"rank_index": placed_index,
			"rank_key": str(Ranks.rank_entry(placed_index).get("key", "")),
			"rank_title": str(Ranks.rank_entry(placed_index).get("title", "")),
			"rank_points": points,
			"position": position,
			"population": population
		}
	return results


# Tum sirketleri ayri ayri hesaplar + genel sirayi uretir.
# A rutbeli hesaplar normal hiyerarsiden tamamen cikarilir.
static func resolve_all(players: Array) -> Dictionary:
	var by_company := {}
	var global_candidates: Array = []
	for record in players:
		if not (record is Dictionary):
			continue
		var value: Dictionary = record
		if str(value.get("username", "")).is_empty():
			continue
		# A rutbesi: kontenjana, yuzdeye ve genel siralamaya girmez.
		if bool(value.get("a_rank", false)):
			continue
		global_candidates.append(value)
		var code := Ranks.normalize_company(str(value.get("company", "")))
		if code.is_empty():
			continue
		if not by_company.has(code):
			by_company[code] = []
		by_company[code].append(value)

	var results := {}
	var company_population := {}
	var company_order := {}
	for code in Ranks.COMPANY_CODES:
		var company_players: Array = by_company.get(code, [])
		company_population[code] = company_players.size()
		var company_result: Dictionary = resolve_company(company_players)
		company_order[code] = sort_players(company_players)
		for username in company_result.keys():
			results[username] = company_result[username]

	var global_ordered := sort_players(global_candidates)
	var position := 0
	for record in global_ordered:
		position += 1
		var username := str(record.get("username", ""))
		if results.has(username):
			results[username]["global_position"] = position
			results[username]["global_population"] = global_ordered.size()

	return {
		"players": results,
		"company_population": company_population,
		"company_order": company_order,
		"global_population": global_ordered.size()
	}


# Sirket siralamasi listesi (A rutbeliler en ustte "A" olarak isaretlenir).
# a_rank_visible = false ise A rutbesi disaridan gorunmez (normal rutbe gosterilir).
static func company_leaderboard(
	players: Array,
	company_code: String,
	limit: int = 10,
	a_rank_visible: bool = false
) -> Array:
	var code := Ranks.normalize_company(company_code)
	var scoped: Array = []
	for record in players:
		if not (record is Dictionary):
			continue
		var value: Dictionary = record
		if str(value.get("username", "")).is_empty():
			continue
		if not code.is_empty() and Ranks.normalize_company(str(value.get("company", ""))) != code:
			continue
		scoped.append(value)

	var resolution: Dictionary = resolve_all(scoped) if code.is_empty() else {
		"players": resolve_company(scoped)
	}
	var resolved: Dictionary = resolution.get("players", {})

	var rows: Array = []
	for record in sort_players(scoped):
		var value: Dictionary = record
		var username := str(value.get("username", ""))
		var is_a := bool(value.get("a_rank", false))
		var entry: Dictionary = resolved.get(username, {})
		var rank_key := str(entry.get("rank_key", ""))
		var rank_title := str(entry.get("rank_title", ""))
		if is_a:
			# A rutbesi yalnizca yetkili goruntuleyiciye acik edilir.
			if a_rank_visible:
				rank_key = Ranks.RANK_A_KEY
				rank_title = Ranks.RANK_A_TITLE
			else:
				rank_key = "private"
				rank_title = ""
		rows.append({
			"username": username,
			"player_id": str(value.get("player_id", "")),
			"nickname": str(value.get("nickname", username)),
			"company": str(value.get("company", "")),
			"rank_key": rank_key,
			"rank_title": rank_title,
			"rank_points": float(value.get("rank_points", points_for_record(value))),
			"position": int(entry.get("position", 0)),
			"population": int(entry.get("population", scoped.size())),
			"a_rank": is_a
		})

	if limit > 0 and rows.size() > limit:
		return rows.slice(0, limit)
	return rows


# --- A rutbesi yardimcilari ---

static func a_rank_badge_key() -> String:
	return Ranks.RANK_A_ICON


static func a_rank_title() -> String:
	return Ranks.RANK_A_TITLE


# Runtime stat carpani: A rutbesi aktifken BASE x 2 uygulanir.
# Cagiran taraf her zaman TABAN degerden hesapladigi icin ustune eklenme olmaz.
static func stat_multiplier(a_rank_active: bool) -> float:
	return Ranks.RANK_A_STAT_MULTIPLIER if a_rank_active else 1.0