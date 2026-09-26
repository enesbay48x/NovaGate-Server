extends Control
class_name NovaGateSkillLink
## Skill node'lari arasindaki sci-fi baglanti cizgileri (FAZ 4).
## Sadece gorsel; mouse input'u engellemez.

var link_points: Array = [] # [[Vector2, Vector2], ...]
var link_colors: Array = [] # her baglanti icin Color

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_default_cursor_shape = Control.CURSOR_ARROW

func set_links(points: Array, colors: Array) -> void:
	link_points = points
	link_colors = colors
	queue_redraw()

func _draw() -> void:
	var pair_count := int(link_points.size() / 2.0)
	for i in range(pair_count):
		var a: Vector2 = link_points[i * 2]
		var b: Vector2 = link_points[i * 2 + 1]
		var col: Color = link_colors[i] if i < link_colors.size() else Color(0.25, 0.9, 1.0, 0.35)
		# dis glow cizgisi
		draw_line(a, b, Color(col.r, col.g, col.b, col.a * 0.35), 5.0)
		# ana cizgi
		draw_line(a, b, col, 2.0)
		# baglanti uclarinda kucuk neon noktalar
		draw_circle(a, 3.0, col)
		draw_circle(b, 3.0, col)
