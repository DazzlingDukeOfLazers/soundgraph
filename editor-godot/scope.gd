extends Control
## Draws a slice of signal.
##
## The samples come straight from the running graph's buffers via the extension — this
## draws what is actually on the wire, it does not re-derive or approximate it. That is
## the difference between a visualiser you can trust and decoration.

var samples: PackedFloat32Array = PackedFloat32Array()
var label: String = "output"
static var accent := Design.ACCENT

## The scope is a window onto the signal, so it sits *below* the canvas rather than
## on the panel it lives in — a display recessed into the surface, which is what a
## meter on a piece of hardware looks like.
static var BACKGROUND := Design.SURFACES[Design.Surface.CANVAS]
static var GRID := Design.BORDERS[Design.Surface.RAISED]
## Inset from the edges. The peak readout used to be positioned by guessing a width
## in pixels, so it hung off the right-hand side the moment the font or the panel
## changed size; it is measured now.
const PAD := 8.0


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

	var font: Font = Design.numeric_font()
	var font_size := Design.scale(Design.SIZE_SECONDARY)
	var ascent := font.get_ascent(font_size)
	draw_string(font, Vector2(PAD, PAD + ascent), label, HORIZONTAL_ALIGNMENT_LEFT, -1,
		font_size, Design.INK_SECOND)

	if samples.size() < 2:
		draw_string(font, Vector2(PAD, size.y - PAD), "no signal",
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Design.INK_DISABLED)
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
	# Right-aligned by measuring the string rather than by assuming it is 74px wide,
	# which is what put "peak 0.033" half outside the box.
	var readout := "peak %.3f" % peak
	var width := font.get_string_size(readout, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, Vector2(size.x - width - PAD, PAD + ascent), readout,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Design.INK_SECOND)
