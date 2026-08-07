extends Control
## Draws a slice of signal.
##
## The samples come straight from the running graph's buffers via the extension — this
## draws what is actually on the wire, it does not re-derive or approximate it. That is
## the difference between a visualiser you can trust and decoration.

var samples: PackedFloat32Array = PackedFloat32Array()
var label: String = "output"
var accent := Color(0.43, 0.91, 0.72)

const BACKGROUND := Color(0.06, 0.07, 0.09)
const GRID := Color(0.2, 0.22, 0.26)


func show_samples(new_samples: PackedFloat32Array, new_label: String) -> void:
	samples = new_samples
	label = new_label
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, BACKGROUND)

	# Zero line and full-scale markers, so the amplitude is readable rather than relative.
	var middle := size.y * 0.5
	draw_line(Vector2(0, middle), Vector2(size.x, middle), GRID, 1.0)
	draw_line(Vector2(0, 2), Vector2(size.x, 2), GRID, 1.0)
	draw_line(Vector2(0, size.y - 2), Vector2(size.x, size.y - 2), GRID, 1.0)

	var font := get_theme_default_font()
	var font_size := 11
	draw_string(font, Vector2(6, 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
		Color(0.6, 0.65, 0.72))

	if samples.size() < 2:
		draw_string(font, Vector2(6, size.y - 8), "no signal", HORIZONTAL_ALIGNMENT_LEFT, -1,
			font_size, Color(0.45, 0.49, 0.56))
		return

	var points := PackedVector2Array()
	points.resize(samples.size())
	var step := size.x / float(samples.size() - 1)
	for i in samples.size():
		# Clamped so a runaway signal stays inside the box instead of vanishing off it.
		var value: float = clampf(samples[i], -1.5, 1.5)
		points[i] = Vector2(i * step, middle - value * (size.y * 0.45))
	draw_polyline(points, accent, 1.5, true)

	var peak := 0.0
	for value in samples:
		peak = maxf(peak, absf(value))
	draw_string(font, Vector2(size.x - 74, 14), "peak %.3f" % peak, HORIZONTAL_ALIGNMENT_LEFT,
		-1, font_size, Color(0.6, 0.65, 0.72))
