extends RefCounted
class_name RankBadge

# NovaGate rutbe ikonu (badge) bileseni.
# Bu dosya rutbe ikonunun TEK kaynagidir: atlas, dikdortgenler ve
# rank_key -> ikon eslemesi burada tutulur.
# Onceden ayni sozluk player_ship.gd / menu_ui.gd / main.gd icinde
# kopyalanmisti; artik uc dosya da bu bileseni kullanir.

const RankData = preload("res://scripts/rank_data.gd")
const RANK_TEXTURE := preload("res://assets/ranks/ranks.png")

# ranks.png atlasindaki GERCEK ikon dikdortgenleri.
# 12 ikon vardir; 21 rutbe bu ikonlara RankData uzerinden eslenir.
const RANK_RECTS: Dictionary = {
	"admin": Rect2(170, 24, 20, 20),
	"captain": Rect2(192, 24, 20, 20),
	"colonel": Rect2(214, 24, 20, 20),
	"gen-col": Rect2(236, 24, 20, 20),
	"gen-maj": Rect2(258, 24, 20, 20),
	"general": Rect2(280, 24, 20, 20),
	"lieutenant": Rect2(302, 24, 20, 20),
	"major": Rect2(324, 24, 20, 20),
	"marshal": Rect2(346, 24, 20, 20),
	"private": Rect2(368, 24, 20, 20),
	"sergeant": Rect2(390, 24, 20, 20),
	"traitor": Rect2(412, 24, 20, 20)
}

# Bilinmeyen/gizli rutbeler icin kullanilan varsayilan ikon.
const FALLBACK_ICON := "private"
# Gizlenmis "A" rutbesi icin kullanilan gorunum anahtari.
const HIDDEN_A_KEY := "private"


static func icon_key_for(rank_key: String) -> String:
	# rank_key -> atlas ikon adi. Uydurma ikon uretilmez: atlasta
	# karsiligi olmayan anahtar varsayilan ikona duser.
	var key := rank_key.strip_edges()
	if key.is_empty():
		return FALLBACK_ICON
	if RankData.is_a_rank(key):
		return RankData.RANK_A_ICON
	var icon := str(RankData.icon_for_key(key))
	if icon.is_empty() or not RANK_RECTS.has(icon):
		return FALLBACK_ICON
	return icon


static func rect_for(rank_key: String) -> Rect2:
	return RANK_RECTS.get(icon_key_for(rank_key), RANK_RECTS[FALLBACK_ICON])


static func texture_for(rank_key: String) -> AtlasTexture:
	var atlas := AtlasTexture.new()
	atlas.atlas = RANK_TEXTURE
	atlas.region = rect_for(rank_key)
	return atlas


static func apply(target: TextureRect, rank_key: String) -> void:
	if target == null:
		return
	target.texture = texture_for(rank_key)


static func create(rank_key: String, badge_size: Vector2 = Vector2(18.0, 18.0)) -> TextureRect:
	var badge := TextureRect.new()
	badge.size = badge_size
	badge.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	badge.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	apply(badge, rank_key)
	return badge


static func title_for(rank_key: String) -> String:
	# Gizlenmis "A" rutbesi icin bos doner: hicbir rutbe bilgisi sizdirilmaz.
	var key := rank_key.strip_edges()
	if key.is_empty() or key == HIDDEN_A_KEY:
		return ""
	if RankData.is_a_rank(key):
		return RankData.RANK_A_TITLE
	if RankData.is_valid_normal_rank(key):
		return RankData.title_for_key(key)
	return ""


static func tooltip_for(rank_key: String) -> String:
	# Liderlik tablosu ve profil karti icin insan okunur etiket.
	var key := rank_key.strip_edges()
	if RankData.is_a_rank(key):
		# "A" rutbesi merdivenin disindadir; numara YAZILMAZ.
		return RankData.RANK_A_TITLE
	var title := title_for(key)
	if title.is_empty():
		return ""
	return "%s (%d. Rutbe)" % [title, RankData.index_for_key(key)]