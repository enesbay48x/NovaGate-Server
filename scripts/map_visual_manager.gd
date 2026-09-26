extends Node2D
class_name MapVisualManager

# =============================================================================
# NovaGate - Harita gorsel katmani yoneticisi (arka plan + atmosfer)
#
# Sadece gorsel arka plan / atmosfer katmanlarini yonetir.
# Planet, station, asteroid, smoke, NPC, boss, portal gibi dunya objelerine
# ve map_specific_objects yapisina dokunmaz.
#
# Dunya: WORLD_RECT = Rect2(-7000, -5000, 14000, 10000)
# Yeni kamera OLUSTURULMAZ; sahnedeki mevcut Camera2D kullanilir.
#
# Paralaks gercek kamera pozisyonundan hesaplanir (sin/cos sahte animasyon yok).
#
# Katman cizim sirasi (arka -> on) ve parallax oranlari:
#   background  1.00 : bg.jpg  - dunyaya sabit, ekrani kaplayan karolar
#   stars       0.10 : cok uzak yildizlar (kameradan cok daha yavas)
#   nebula      0.30 : b1g.jpg nebula
#   fog         0.50 : sis
#   clouds_bg   0.70 : uzak bulut katmani
#   clouds_top  0.80 : yakin bulut katmani
# =============================================================================

const WORLD_RECT: Rect2 = Rect2(-7000.0, -5000.0, 14000.0, 10000.0)

@export var map_path := "res://hrta/"

# Dunya boyutu - WORLD_RECT ile uyumlu
var world_size := Vector2(14000.0, 10000.0)
var map_size := Vector2(14000.0, 10000.0)
var world_rect: Rect2 = WORLD_RECT

var map_root: Node2D
var current_map := ""

# Katman yapilandirmasi.
#   parallax_ratio : kameranin kac kati hareket edecegi (1.00 = dunyaya sabit)
#   tile_cover     : her karonun ekrani kac kati kaplayacagi
#   additive       : siyah zeminli jpg katmanlari icin (nebula / yildiz isigi)
#   seamless       : komsu karolar birbirinin aynasi olur, kenar cizgisi olusmaz
const LAYER_CONFIG: Dictionary = {
	"background": {"z_index": -2100, "parallax_ratio": 1.00, "tile_cover": 1.30, "alpha": 1.00, "additive": false, "seamless": true},
	"stars": {"z_index": -2050, "parallax_ratio": 0.10, "tile_cover": 1.15, "alpha": 0.55, "additive": true, "seamless": true},
	"nebula": {"z_index": -2040, "parallax_ratio": 0.30, "tile_cover": 1.35, "alpha": 0.85, "additive": true, "seamless": false},
	"fog": {"z_index": -2030, "parallax_ratio": 0.50, "tile_cover": 1.25, "alpha": 0.30, "additive": false, "seamless": false},
	"clouds_bg": {"z_index": -2020, "parallax_ratio": 0.70, "tile_cover": 1.20, "alpha": 0.34, "additive": false, "seamless": false},
	"clouds_top": {"z_index": -2010, "parallax_ratio": 0.80, "tile_cover": 1.10, "alpha": 0.24, "additive": false, "seamless": false},
	"objects": {"z_index": -500, "parallax_ratio": 1.00, "tile_cover": 1.00, "alpha": 1.00, "additive": false, "seamless": true}
}

# Harita klasorunde aranacak dosya adlari (sirayla ilk bulunan kullanilir).
const LAYER_TEXTURE_CANDIDATES: Dictionary = {
	"background": ["bg.jpg", "bg_.jpg", "bg__.jpg", "bg1.jpg", "bg11.jpg", "bg.png"],
	"stars": ["stars.png", "stars_bg.png", "starfield.png", "star_field.png", "bg.jpg"],
	"nebula": ["b1g.jpg", "nebula.png", "bg_.jpg", "bg11.jpg", "bg__.jpg", "bg.jpg"],
	"fog": ["mist.png", "cloud_far.png", "cloud.png", "clouds_bg.png"],
	"clouds_bg": ["clouds_bg.png", "cloud_far.png", "cloud.png", "clouds1.png", "ambient1.png"],
	"clouds_top": ["clouds_top.png", "cloud_near.png", "cloud.png", "clouds2.png"]
}

# Harita klasorunde uygun asset yoksa kullanilan mevcut proje assetleri.
const FALLBACK_TEXTURE_CANDIDATES: Dictionary = {
	"background": ["res://assets/maps_visual_update/maps/bg (1).jpg"],
	"stars": ["res://assets/maps_visual_update/maps/bg (1).jpg"],
	"nebula": ["res://assets/maps_visual_update/maps/abstract.png", "res://assets/maps_visual_update/maps/red_mist.png"],
	"fog": ["res://assets/maps_visual_update/maps/ambient1.png"],
	"clouds_bg": ["res://assets/maps_visual_update/maps/ambient1.png"],
	"clouds_top": ["res://assets/maps_visual_update/maps/abstract.png"]
}

# Karolar karonun bu orani kadar araliklarla dizilir (kapsama garantisi).
const TILE_SPACING_FACTOR := 0.85
# Kamera sinirlarinin disina tasan pay (ekranin bu orani kadar).
const COVERAGE_MARGIN_FACTOR := 0.75
# Organik (sis / bulut) katmanlarda olcek ve konum cesitliligi.
const ORGANIC_SCALE_MIN := 1.0
const ORGANIC_SCALE_MAX := 1.32
const ORGANIC_JITTER := 0.06
# Kamera bulunamazsa (editor / headless test) kullanilan gorunur alan.
const DEFAULT_VIEW_SIZE: Vector2 = Vector2(2133.0, 1200.0)

# Eski API uyumlulugu.
var animation_time := 0.0
var is_animated := true

# Aktif paralaks katmanlari (paralel diziler - Variant kullanimi yok).
var parallax_sheets: Array[Node2D] = []
var parallax_ratios: Array[float] = []

var view_size_cache := Vector2.ZERO
var last_camera_center := Vector2(INF, INF)
var camera_2d: Camera2D = null
var debug_log := true


func _ready() -> void:
	_ensure_root()


func _ensure_root() -> void:
	# Gorsel kok her ortamda (editor, test, oyun) tek sefer olusturulur.
	if map_root != null:
		return

	map_root = Node2D.new()
	map_root.name = "WORLD_MAP"
	map_root.z_index = -1000
	add_child(map_root)

	animation_time = 0.0
	last_camera_center = Vector2(INF, INF)

	var viewport: Viewport = get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(_on_view_changed):
		viewport.size_changed.connect(_on_view_changed)


func _process(_delta: float) -> void:
	# Performans: her karede sadece kamera/paralaks pozisyonu guncellenir.
	if not is_animated or map_root == null:
		return
	_update_parallax()


func _on_view_changed() -> void:
	# Pencere boyutu belirgin sekilde degisirse karolar yeniden hesaplanir.
	if map_root == null or current_map.is_empty():
		return
	var view: Vector2 = _get_view_size()
	if view_size_cache.distance_to(view) < 64.0:
		return
	load_map(current_map)


# =============================================================================
# PARALAKS (kamera pozisyonundan hesaplanir)
# =============================================================================

func _update_parallax() -> void:
	var cam: Camera2D = _get_camera()
	if cam == null:
		return

	var center: Vector2 = cam.get_screen_center_position()
	if center.is_equal_approx(last_camera_center):
		return
	last_camera_center = center

	var count: int = parallax_sheets.size()
	for i in range(count):
		var sheet: Node2D = parallax_sheets[i]
		if sheet == null or not is_instance_valid(sheet):
			continue
		sheet.position = _parallax_position(center, parallax_ratios[i])


func _parallax_position(camera_center: Vector2, ratio: float) -> Vector2:
	# Gercek paralaks (sahte sin/cos animasyonu degil):
	#   ratio 1.00 -> katman dunyaya sabittir (bg.jpg), hic kaymaz.
	#   ratio 0.10 -> katman kameranin yalnizca %10'u kadar hareket eder,
	#                 bu yuzden cok uzakta duruyormus gibi gorunur.
	#   ratio 0.50 -> kameranin yarisi kadar hareket eder (orta mesafe).
	return camera_center * (1.0 - ratio)


func _get_camera() -> Camera2D:
	if camera_2d == null or not is_instance_valid(camera_2d):
		# Yeni kamera olusturulmaz; sahnedeki mevcut Camera2D kullanilir.
		var viewport: Viewport = get_viewport()
		if viewport != null:
			camera_2d = viewport.get_camera_2d()
	return camera_2d


func _get_view_size() -> Vector2:
	var view: Vector2 = DEFAULT_VIEW_SIZE
	var viewport: Viewport = get_viewport()
	if viewport != null:
		var rect: Rect2 = viewport.get_visible_rect()
		if rect.size.x > 1.0 and rect.size.y > 1.0:
			view = rect.size
	var cam: Camera2D = _get_camera()
	if cam != null:
		var zoom: Vector2 = cam.zoom
		view = Vector2(view.x / maxf(zoom.x, 0.001), view.y / maxf(zoom.y, 0.001))
	return view


# =============================================================================
# HARITA YUKLEME (assetler sadece burada olusturulur)
# =============================================================================

func load_map(map_id: String = "1-1") -> void:
	_ensure_root()
	clear_map()
	current_map = map_id

	var view: Vector2 = _get_view_size()
	view_size_cache = view
	var folder: String = map_path + current_map + "/"

	# Gorsel arka plan / atmosfer katmanlari (uzaktan yakina).
	_create_texture_layer("background", folder, view)
	_create_texture_layer("stars", folder, view)
	_create_texture_layer("nebula", folder, view)
	_create_texture_layer("fog", folder, view)
	_create_texture_layer("clouds_bg", folder, view)
	_create_texture_layer("clouds_top", folder, view)

	# Harita ozel dunya objeleri (planet, station, asteroid, smoke...) korunur.
	_load_map_specific_objects(folder, Vector2.ZERO)
	_load_default_objects(folder, Vector2.ZERO)

	_apply_camera_limits()

	# Katmanlari ilk karede dogru konuma oturt.
	last_camera_center = Vector2(INF, INF)
	_update_parallax()

	if debug_log:
		print("[MapVisual] ", current_map, " hazir - ", parallax_sheets.size(), " atmosfer katmani")


func clear_map() -> void:
	if map_root != null:
		for child in map_root.get_children():
			if child is CanvasItem:
				var item: CanvasItem = child
				item.visible = false
			child.queue_free()
	parallax_sheets.clear()
	parallax_ratios.clear()
	animation_time = 0.0
	last_camera_center = Vector2(INF, INF)


# =============================================================================
# GORSEL KATMAN OLUSTURMA
# =============================================================================

func _create_texture_layer(layer_type: String, folder: String, view: Vector2) -> void:
	if not LAYER_CONFIG.has(layer_type):
		return

	var cfg: Dictionary = LAYER_CONFIG[layer_type]
	var texture: Texture2D = _resolve_layer_texture(layer_type, folder)
	if texture == null:
		if debug_log:
			print("[MapVisual] ", current_map, " / ", layer_type, " -> asset yok, atlandi")
		return

	var tex_size: Vector2 = texture.get_size()
	if tex_size.x < 1.0 or tex_size.y < 1.0:
		return

	var ratio: float = float(cfg.get("parallax_ratio", 1.0))
	var tile_cover: float = float(cfg.get("tile_cover", 1.0))
	var alpha: float = float(cfg.get("alpha", 1.0))
	var additive: bool = bool(cfg.get("additive", false))
	var seamless: bool = bool(cfg.get("seamless", false))
	var z: int = int(cfg.get("z_index", -2000))

	# En-boy orani korunur: "cover" olcegi sayesinde her karo tek basina ekrani
	# kaplar. Boylece tek resmin 14000x10000'e gerilip bulaniklasmasi olmaz,
	# ekranda kucuk resim olarak kalmaz ve siyah bosluk olusmaz.
	var cover: float = maxf(view.x / tex_size.x, view.y / tex_size.y) * tile_cover
	var tile: Vector2 = tex_size * cover
	var spacing: Vector2 = tile if seamless else tile * TILE_SPACING_FACTOR

	var coverage: Rect2 = _layer_coverage(ratio, view)
	var cols: int = maxi(1, ceili(coverage.size.x / spacing.x))
	var rows: int = maxi(1, ceili(coverage.size.y / spacing.y))

	var sheet: Node2D = Node2D.new()
	sheet.name = "Layer_" + layer_type
	sheet.z_index = z
	sheet.set_meta("layer_type", layer_type)

	var material: CanvasItemMaterial = null
	if additive:
		# Siyah zeminli jpg katmanlari icin: siyah bolgeler hicbir sey eklemez,
		# boylece nebula/yildiz katmani arka plani kapatmaz.
		material = CanvasItemMaterial.new()
		material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(current_map + "|" + layer_type)
	var aspect: float = tex_size.x / maxf(tex_size.y, 1.0)
	var quarter_turns: bool = aspect > 0.88 and aspect < 1.14

	for iy in range(rows):
		for ix in range(cols):
			var sprite: Sprite2D = Sprite2D.new()
			sprite.texture = texture
			sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			sprite.centered = true

			var center: Vector2 = coverage.position + Vector2(float(ix), float(iy)) * spacing + tile * 0.5
			var scale_factor: float = 1.0
			var alpha_factor: float = 1.0
			var rotation_rad: float = 0.0

			# Opak karolar tam kenardan birlesir; rastgele kaydirilmaz.
			if not seamless:
				center += Vector2(
					rng.randf_range(-ORGANIC_JITTER, ORGANIC_JITTER),
					rng.randf_range(-ORGANIC_JITTER, ORGANIC_JITTER)
				) * spacing
				scale_factor = rng.randf_range(ORGANIC_SCALE_MIN, ORGANIC_SCALE_MAX)
				alpha_factor = rng.randf_range(0.7, 1.0)
				if quarter_turns:
					# Kare pufflar 90 derece adimlariyla dondurulur, kapsama bozulmaz.
					rotation_rad = float(rng.randi_range(0, 3)) * PI * 0.5

			sprite.flip_h = (ix % 2) == 1
			sprite.flip_v = (iy % 2) == 1
			sprite.position = center
			sprite.scale = Vector2(cover, cover) * scale_factor
			sprite.rotation = rotation_rad
			sprite.modulate = Color(1.0, 1.0, 1.0, clampf(alpha * alpha_factor, 0.0, 1.0))
			if material != null:
				sprite.material = material
			sheet.add_child(sprite)

	map_root.add_child(sheet)
	parallax_sheets.append(sheet)
	parallax_ratios.append(ratio)

	if debug_log:
		print(
			"[MapVisual] ", current_map, " / ", layer_type,
			" tex=", tex_size, " ratio=", ratio,
			" karo=", sheet.get_child_count(), " z=", z,
			" kaplama=", coverage.size
		)


func _layer_coverage(ratio: float, view: Vector2) -> Rect2:
	# Katmanin yerel kapsama alani: kamera dunya icinde nerede olursa olsun
	# ekranin tamami bu alanin icinde kalir.
	var rect: Rect2 = Rect2(world_rect.position * ratio, world_rect.size * ratio)
	var margin: Vector2 = view * COVERAGE_MARGIN_FACTOR
	return rect.grow_individual(margin.x, margin.y, margin.x, margin.y)


func _resolve_layer_texture(layer_type: String, folder: String) -> Texture2D:
	var names: Array = LAYER_TEXTURE_CANDIDATES.get(layer_type, [])
	for i in range(names.size()):
		var path: String = folder + str(names[i])
		var texture: Texture2D = _load_texture_if_usable(path)
		if texture != null:
			return texture

	var fallbacks: Array = FALLBACK_TEXTURE_CANDIDATES.get(layer_type, [])
	for i in range(fallbacks.size()):
		var fallback_path: String = str(fallbacks[i])
		var fallback_texture: Texture2D = _load_texture_if_usable(fallback_path)
		if fallback_texture != null:
			return fallback_texture

	return null


func _load_texture_if_usable(path: String) -> Texture2D:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null

	var texture: Texture2D = load(path) as Texture2D
	if texture == null:
		return null

	# Tamamen seffaf (bos) kaynaklari ele. Ornek: bazi haritalarda
	# clouds_bg.png tamamen bos olabiliyor.
	var image: Image = texture.get_image()
	if image != null and not image.is_empty() and image.detect_alpha() != Image.ALPHA_NONE:
		var used: Rect2i = image.get_used_rect()
		if used.size.x <= 0 or used.size.y <= 0:
			return null

	return texture


# =============================================================================
# HARITA OZEL DUNYA OBJELERI
# Bu yapi ve asset yollari AYNEN korunur (mevcut harita objeleri).
# =============================================================================

# Harita Ã¶zelinde ekstra gÃ¶rsel konumlarÄ± (varsa)
var map_specific_objects := {
	"1-1": [
		{"path": "planet.png", "pos": Vector2(500, 1100), "z": -300, "scale": 1.0},
		{"path": "station.png", "pos": Vector2(2100, 700), "z": -200, "scale": 1.0}
	],
	"1-2": [
		{"path": "planet.png", "pos": Vector2(500, 1100), "z": -300, "scale": 1.0},
		{"path": "rocks1.png", "pos": Vector2(3000, 2000), "z": -250, "scale": 1.5},
		{"path": "rocks2.png", "pos": Vector2(-2000, -1500), "z": -250, "scale": 1.5}
	],
	"1-3": [
		{"path": "planet.png", "pos": Vector2(500, 1100), "z": -300, "scale": 1.0},
		{"path": "smoke1.png", "pos": Vector2(-1500, 2000), "z": -400, "scale": 2.0},
		{"path": "smoke2.png", "pos": Vector2(2000, -1000), "z": -400, "scale": 2.0},
		{"path": "smoke3.png", "pos": Vector2(-2500, -2000), "z": -400, "scale": 2.0},
		{"path": "smoke4.png", "pos": Vector2(3000, 1500), "z": -400, "scale": 2.0}
	],
	"1-4": [
		{"path": "planet1.png", "pos": Vector2(1000, 800), "z": -300, "scale": 1.2},
		{"path": "moon1.png", "pos": Vector2(-2000, -500), "z": -350, "scale": 0.8},
		{"path": "moon2.png", "pos": Vector2(2500, 1500), "z": -350, "scale": 0.8},
		{"path": "star.png", "pos": Vector2(-3000, -2000), "z": -400, "scale": 1.5}
	],
	"1-5": [
		{"path": "Broken_station.png", "pos": Vector2(0, 0), "z": -200, "scale": 1.0}
	],
	"1-6": [
		{"path": "planet.png", "pos": Vector2(0, 0), "z": -300, "scale": 1.0},
		{"path": "asteroids.png", "pos": Vector2(3000, 2000), "z": -350, "scale": 2.0},
		{"path": "flare.png", "pos": Vector2(-2000, -1500), "z": -400, "scale": 1.5},
		{"path": "object.png", "pos": Vector2(-3000, 1000), "z": -250, "scale": 1.0}
	],
	"2-1": [
		{"path": "planet.png", "pos": Vector2(500, 1100), "z": -300, "scale": 1.0},
		{"path": "cloud.png", "pos": Vector2(-2000, 1500), "z": -400, "scale": 2.0}
	],
	"2-2": [
		{"path": "planet1.png", "pos": Vector2(1000, 800), "z": -300, "scale": 1.2}
	],
	"2-3": [
		{"path": "planet.png", "pos": Vector2(500, 1100), "z": -300, "scale": 1.0},
		{"path": "smoke1.png", "pos": Vector2(-1500, 2000), "z": -400, "scale": 2.0},
		{"path": "smoke2.png", "pos": Vector2(2000, -1000), "z": -400, "scale": 2.0},
		{"path": "smoke3.png", "pos": Vector2(-2500, -2000), "z": -400, "scale": 2.0}
	],
	"2-4": [
		{"path": "planet.png", "pos": Vector2(1000, 800), "z": -300, "scale": 1.0},
		{"path": "obj1.png", "pos": Vector2(-2000, 1500), "z": -250, "scale": 1.5},
		{"path": "obj2.png", "pos": Vector2(2500, -1000), "z": -250, "scale": 1.5},
		{"path": "cloud.png", "pos": Vector2(0, -2000), "z": -400, "scale": 2.5}
	],
	"2-5": [
		{"path": "asteroid1.png", "pos": Vector2(-2000, 2000), "z": -350, "scale": 1.5},
		{"path": "asteroid2.png", "pos": Vector2(2000, -1500), "z": -350, "scale": 1.5},
		{"path": "asteroid3.png", "pos": Vector2(0, 0), "z": -350, "scale": 2.0},
		{"path": "collision.png", "pos": Vector2(3000, 1000), "z": -250, "scale": 1.0}
	],
	"2-6": [
		{"path": "blackhole.png", "pos": Vector2(0, 0), "z": -300, "scale": 2.0},
		{"path": "hit_planet.png", "pos": Vector2(3000, 2000), "z": -250, "scale": 1.5},
		{"path": "clouds1.png", "pos": Vector2(-2000, -1500), "z": -400, "scale": 2.0},
		{"path": "clouds2.png", "pos": Vector2(2000, 1500), "z": -400, "scale": 2.0}
	],
	"3-1": [
		{"path": "Back2.png", "pos": Vector2(0, 0), "z": -400, "scale": 2.0},
		{"path": "Star.png", "pos": Vector2(3000, -2000), "z": -500, "scale": 1.5},
		{"path": "Asteroid.png", "pos": Vector2(-2000, 1500), "z": -350, "scale": 1.5},
		{"path": "Smash.png", "pos": Vector2(0, 0), "z": -200, "scale": 1.0}
	],
	"3-2": [
		{"path": "bs1.png", "pos": Vector2(2000, 1500), "z": -300, "scale": 1.5},
		{"path": "dist_ovl.png", "pos": Vector2(-2000, -1000), "z": -350, "scale": 1.5},
		{"path": "flare.png", "pos": Vector2(0, 0), "z": -400, "scale": 2.0},
		{"path": "glare.png", "pos": Vector2(3000, 2000), "z": -400, "scale": 1.5}
	],
	"3-3": [
		{"path": "nebula.png", "pos": Vector2(0, 0), "z": -1900, "scale": 2.0},
		{"path": "sol.png", "pos": Vector2(1500, 1000), "z": -300, "scale": 1.5},
		{"path": "planet.png", "pos": Vector2(-2000, 1500), "z": -350, "scale": 1.2},
		{"path": "planet2.png", "pos": Vector2(2500, -1000), "z": -350, "scale": 1.2},
		{"path": "station.png", "pos": Vector2(0, 0), "z": -200, "scale": 1.0}
	],
	"3-4": [
		{"path": "mist.png", "pos": Vector2(0, 0), "z": -1800, "scale": 2.5},
		{"path": "rocks1.png", "pos": Vector2(-2000, 2000), "z": -350, "scale": 1.5},
		{"path": "rocks2.png", "pos": Vector2(2000, -1500), "z": -350, "scale": 1.5},
		{"path": "rocks3.png", "pos": Vector2(0, 0), "z": -300, "scale": 2.0}
	],
	"3-5": [
		{"path": "bg_.jpg", "pos": Vector2(0, 0), "z": -1600, "scale": 1.0},
		{"path": "cloud_far.png", "pos": Vector2(0, 0), "z": -1800, "scale": 2.0}
	],
	"BOSS": [
		{"path": "blackhole.png", "pos": Vector2(0, 0), "z": -300, "scale": 3.0},
		{"path": "star_blue.png", "pos": Vector2(-3000, -2000), "z": -500, "scale": 1.5},
		{"path": "star_red.png", "pos": Vector2(3000, 2000), "z": -500, "scale": 1.5},
		{"path": "planet1.png", "pos": Vector2(0, 3000), "z": -350, "scale": 1.5},
		{"path": "ambient1.png", "pos": Vector2(0, 0), "z": -1800, "scale": 2.5}
	],
	"PVP": [
		{"path": "planet.png", "pos": Vector2(0, 0), "z": -300, "scale": 1.5}
	]
}

# =============================================================================
# HARITA OBJELERININ YERLESTIRILMESI
# =============================================================================

func _load_map_specific_objects(folder: String, world_center: Vector2) -> void:
	var objects: Array = map_specific_objects.get(current_map, [])
	if objects.is_empty():
		return

	for i in range(objects.size()):
		var obj_data: Dictionary = objects[i]
		var rel_path: String = str(obj_data.get("path", ""))
		if rel_path.is_empty():
			continue

		var path: String = folder + rel_path
		if not ResourceLoader.exists(path):
			continue

		var texture: Texture2D = load(path) as Texture2D
		if texture == null:
			continue

		var sprite: Sprite2D = Sprite2D.new()
		sprite.texture = texture
		sprite.position = obj_data.get("pos", Vector2.ZERO)
		sprite.z_index = int(obj_data.get("z", -250))
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

		var obj_scale: float = float(obj_data.get("scale", 1.0))
		if not is_equal_approx(obj_scale, 1.0):
			sprite.scale = Vector2(obj_scale, obj_scale)

		sprite.set_meta("layer_type", "objects")
		map_root.add_child(sprite)


func _load_default_objects(folder: String, world_center: Vector2) -> void:
	# Eski sistemle uyumluluk icin varsayilan dunya objeleri.

	# Planet
	if ResourceLoader.exists(folder + "planet.png"):
		_load_world_sprite(
			folder + "planet.png",
			Vector2(500, 1100),
			-300,
			1.0
		)

	# Station
	if ResourceLoader.exists(folder + "station.png"):
		_load_world_sprite(
			folder + "station.png",
			Vector2(2100, 700),
			-200,
			1.0
		)

	# Rocks (1-2, 3-4 gibi haritalarda)
	if ResourceLoader.exists(folder + "rocks1.png"):
		_load_world_sprite(
			folder + "rocks1.png",
			Vector2(3000, 2000),
			-250,
			1.5
		)

	if ResourceLoader.exists(folder + "rocks2.png"):
		_load_world_sprite(
			folder + "rocks2.png",
			Vector2(-2000, -1500),
			-250,
			1.5
		)

	# Smoke/fog (1-3 gibi haritalarda)
	if ResourceLoader.exists(folder + "smoke1.png"):
		_load_world_sprite(
			folder + "smoke1.png",
			Vector2(-1500, 2000),
			-400,
			2.0
		)

	if ResourceLoader.exists(folder + "smoke2.png"):
		_load_world_sprite(
			folder + "smoke2.png",
			Vector2(2000, -1000),
			-400,
			2.0
		)

	if ResourceLoader.exists(folder + "smoke3.png"):
		_load_world_sprite(
			folder + "smoke3.png",
			Vector2(-2500, -2000),
			-400,
			2.0
		)

	if ResourceLoader.exists(folder + "smoke4.png"):
		_load_world_sprite(
			folder + "smoke4.png",
			Vector2(3000, 1500),
			-400,
			2.0
		)


func _load_world_sprite(path: String, at_position: Vector2, layer: int, sprite_scale: float = 1.0) -> void:
	if not ResourceLoader.exists(path):
		return

	var texture: Texture2D = load(path) as Texture2D
	if texture == null:
		return

	var sprite: Sprite2D = Sprite2D.new()
	sprite.texture = texture
	sprite.position = at_position
	sprite.z_index = layer
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	if not is_equal_approx(sprite_scale, 1.0):
		sprite.scale = Vector2(sprite_scale, sprite_scale)

	sprite.set_meta("layer_type", "objects")
	sprite.set_meta("base_position", at_position)

	map_root.add_child(sprite)


# =============================================================================
# KAMERA
# Yeni kamera olusturulmaz; mevcut Camera2D'nin limitleri dunyaya gore ayarlanir.
# =============================================================================

func _apply_camera_limits() -> void:
	var cam: Camera2D = _get_camera()
	if cam == null:
		return
	cam.limit_left = int(world_rect.position.x)
	cam.limit_top = int(world_rect.position.y)
	cam.limit_right = int(world_rect.position.x + world_rect.size.x)
	cam.limit_bottom = int(world_rect.position.y + world_rect.size.y)


func setup_camera(camera: Camera2D) -> void:
	if camera == null:
		return

	# Kamera sinirlari - WORLD_RECT: -7000, -5000, 14000, 10000
	camera.limit_left = int(world_rect.position.x)
	camera.limit_top = int(world_rect.position.y)
	camera.limit_right = int(world_rect.position.x + world_rect.size.x)
	camera.limit_bottom = int(world_rect.position.y + world_rect.size.y)

	camera.position_smoothing_enabled = true
	camera.position_smoothing_speed = 8


# =============================================================================
# KATMAN API
# =============================================================================

func set_layer_visibility(layer_type: String, visible: bool) -> void:
	if map_root == null:
		return
	for child in map_root.get_children():
		if not (child is CanvasItem):
			continue
		var item: CanvasItem = child
		var lt: String = str(item.get_meta("layer_type", ""))
		if lt == layer_type:
			item.visible = visible


func get_layer_count(layer_type: String) -> int:
	var count: int = 0
	if map_root == null:
		return count
	for child in map_root.get_children():
		if not (child is CanvasItem):
			continue
		var item: CanvasItem = child
		var lt: String = str(item.get_meta("layer_type", ""))
		if lt != layer_type:
			continue
		if child is Sprite2D:
			count += 1
		else:
			count += child.get_child_count()
	return count


func set_parallax_enabled(enabled: bool) -> void:
	is_animated = enabled
	if enabled:
		last_camera_center = Vector2(INF, INF)
		_update_parallax()


func get_parallax_ratio(layer_type: String) -> float:
	if not LAYER_CONFIG.has(layer_type):
		return 1.0
	var cfg: Dictionary = LAYER_CONFIG[layer_type]
	return float(cfg.get("parallax_ratio", 1.0))


# =============================================================================
# DUNYA BOYUTU
# =============================================================================

func set_world_size(size: Vector2) -> void:
	world_size = size
	map_size = size
	world_rect = Rect2(-size * 0.5, size)
	_apply_camera_limits()


func get_world_size() -> Vector2:
	return world_size
