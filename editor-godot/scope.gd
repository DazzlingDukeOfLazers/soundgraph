extends Control
## Draws a slice of signal.
##
## The samples come straight from the running graph's buffers via the extension — this
## draws what is actually on the wire, it does not re-derive or approximate it. That is
## the difference between a visualiser you can trust and decoration.

var samples: PackedFloat32Array = PackedFloat32Array()
var label: String = "output"
## Read at draw time, not at class load. A static initialised once holds whatever the
## palette happened to be when the script was first touched, so switching theme left
## the scope drawn in the old one — the same trap as any cached token.
var accent: Color:
	get: return Design.AUDIO

## The scope is a window onto the signal, so it sits *below* the canvas rather than
## on the panel it lives in — a display recessed into the surface, which is what a
## meter on a piece of hardware looks like.
var BACKGROUND: Color:
	get: return Design.SURFACES[Design.Surface.CANVAS]
var GRID: Color:
	get: return Design.BORDERS[Design.Surface.RAISED]
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

	if samples.size() < 2:
		_caption(font, font_size, ascent, label, "no signal", Design.INK_DISABLED)
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
	_caption(font, font_size, ascent, label, "peak %.3f" % peak, Design.INK_SECOND)


## Both captions, on a band across the top, drawn after the trace.
##
## They used to be drawn before it, so a signal that happened to pass through the top
## of the box ran straight through the lettering and left "filter.out" looking crossed
## out. Text over a moving waveform needs something behind it or it is only readable
## when the sound is quiet.
func _caption(font: Font, font_size: int, ascent: float, left: String, right: String,
		colour: Color) -> void:
	var band := Rect2(0.0, 0.0, size.x, ascent + PAD * 1.5)
	draw_rect(band, Color(BACKGROUND.r, BACKGROUND.g, BACKGROUND.b, 0.82))
	draw_string(font, Vector2(PAD, PAD + ascent), left, HORIZONTAL_ALIGNMENT_LEFT, -1,
		font_size, colour)
	var width := font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, Vector2(size.x - width - PAD, PAD + ascent), right,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, colour)
