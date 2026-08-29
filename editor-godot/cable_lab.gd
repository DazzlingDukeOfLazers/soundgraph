extends SceneTree
## A bench for cable rendering, not a feature.
##
## Every open question in the cable spec is a judgement — how much highlight reads as
## rubber before it reads as chrome, how much slack looks hung rather than dropped, whether
## a plug still says "seated" at a quarter size. None of those are settled by reasoning and
## none of them are visible in source. So: draw the variants, look at them, keep the
## numbers that survive.
##
## This is the same move that worked on the watch, where a screen of knobs wired to the
## glow constants beat every guess made from the code. The difference is that here the loop
## is a second rather than a flash-and-photograph, which is worth more than it sounds.
##
##   godot --path editor-godot --script res://cable_lab.gd -- --sheet slack --out /tmp/s.png
##   godot --path editor-godot --script res://cable_lab.gd -- --scene rack
##
## With --out it renders once, writes a PNG and quits. Without, it stays open.

## Preloaded rather than referenced by class_name: a --script run does not scan the
## project, so a global class registered only in the editor's cache does not exist yet.
const CableArt := preload("res://cable_art.gd")

const SHEETS := {
	"slack": "slack, tight to loose",
	"weight": "thickness and highlight",
	"plug": "plug proportions",
	"palette": "the curated colours on every surface",
	"small": "the same cable at four zoom levels",
}

var _sheet := "slack"
var _out := ""
var _palette := Design.Palette.LAB


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		match args[i]:
			"--sheet": _sheet = args[i + 1] if i + 1 < args.size() else _sheet
			"--out": _out = args[i + 1] if i + 1 < args.size() else ""
			"--palette": _palette = int(args[i + 1]) if i + 1 < args.size() else 0

	Design.use_palette(_palette)

	var view := LabView.new()
	view.sheet = _sheet
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(view)
	root.title = "cable lab — %s" % _sheet
	root.size = Vector2i(1280, 800)

	if _out != "":
		_shoot(view)


func _shoot(view: Control) -> void:
	# Two frames: one to lay out, one to draw. Saving after a single frame catches the
	# window before the Control has its size and produces a picture of nothing.
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	var error := image.save_png(_out)
	if error == OK:
		print("wrote %s (%dx%d)" % [_out, image.get_width(), image.get_height()])
	else:
		printerr("could not write %s: %d" % [_out, error])
	quit()


class LabView extends Control:
	var sheet := "slack"

	func _draw() -> void:
		var ground: Color = Design.SURFACES[Design.Surface.CANVAS]
		draw_rect(Rect2(Vector2.ZERO, size), ground)
		match sheet:
			"weight": _sheet_weight()
			"plug": _sheet_plug()
			"palette": _sheet_palette()
			"small": _sheet_small()
			_: _sheet_slack()

	func _label(at: Vector2, text: String, bright := false) -> void:
		var font := ThemeDB.fallback_font
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Design.INK_NORMAL if bright else Design.INK_SECOND)

	## One cable, plugs and all, between two jacks on a strip of faceplate.
	func _patch(a: Vector2, b: Vector2, colour: Color, style: CableArt.Style,
			slack: float, bias: float) -> void:
		var ring: Color = Design.SURFACES[Design.Surface.RAISED]
		var canvas_colour: Color = Design.SURFACES[Design.Surface.CANVAS]
		var socket := canvas_colour.darkened(0.35)
		var radius := style.thickness * 1.5

		# The path is computed from the jack centres, then the visible body is trimmed
		# back to where the plug ends — so the plug angle and the cable's first inch
		# agree, which is the whole reason the plug is drawn along the tangent.
		var rough: Array = CableArt.control_points(a, b, slack, bias)
		var out_a := CableArt.bezier_tangent(rough[0], rough[1], rough[2], rough[3], 0.0)
		var out_b := -CableArt.bezier_tangent(rough[0], rough[1], rough[2], rough[3], 1.0)
		var ends: Array = CableArt.control_points(
			CableArt.exit_point(a, out_a, style),
			CableArt.exit_point(b, out_b, style), slack, bias)
		var points := CableArt.bezier(ends[0], ends[1], ends[2], ends[3])

		CableArt.draw_jack(self, a, radius, ring, socket)
		CableArt.draw_jack(self, b, radius, ring, socket)
		CableArt.draw_cable(self, points, colour, style)
		CableArt.draw_plug(self, a, out_a, colour, style)
		CableArt.draw_plug(self, b, out_b, colour, style)

	func _sheet_slack() -> void:
		_label(Vector2(24, 28), "SLACK — tight 0.55, medium 1.0, loose 1.4", true)
		var names := ["tight 0.55", "medium 1.00", "loose 1.40"]
		var amounts := [0.55, 1.0, 1.4]
		var spans := [120.0, 320.0, 560.0]
		var style := CableArt.Style.new()
		for row in amounts.size():
			var y := 120.0 + row * 210.0
			_label(Vector2(24, y - 24), names[row])
			var x := 150.0
			for span: float in spans:
				_patch(Vector2(x, y), Vector2(x + span, y), Design.AUDIO, style,
					amounts[row], 1.0)
				x += span + 90.0

	func _sheet_weight() -> void:
		_label(Vector2(24, 28), "WEIGHT — thickness across, highlight down", true)
		var thicknesses := [3.0, 4.0, 5.0, 7.0]
		var highlights := [0.0, 0.35, 0.65, 0.9]
		for row in highlights.size():
			var y := 110.0 + row * 170.0
			_label(Vector2(24, y - 20), "hl %.2f" % highlights[row])
			for column in thicknesses.size():
				var style := CableArt.Style.new()
				style.thickness = thicknesses[column]
				style.highlight_alpha = highlights[row]
				var x := 140.0 + column * 270.0
				_patch(Vector2(x, y), Vector2(x + 190.0, y), Design.CONTROL, style, 1.0, 1.0)
				if row == 0:
					_label(Vector2(x + 70.0, 70.0), "%.0f px" % thicknesses[column])

	func _sheet_plug() -> void:
		_label(Vector2(24, 28), "PLUG — length across, width down", true)
		var lengths := [2.0, 2.6, 3.2]
		var widths := [1.4, 1.65, 2.0]
		for row in widths.size():
			var y := 130.0 + row * 220.0
			_label(Vector2(24, y - 22), "w %.2ft" % widths[row])
			for column in lengths.size():
				var style := CableArt.Style.new()
				style.thickness = 7.0
				style.plug_length = lengths[column]
				style.plug_width = widths[row]
				var x := 150.0 + column * 360.0
				_patch(Vector2(x, y), Vector2(x + 250.0, y), Design.TRIGGER, style, 0.9, 1.0)
				if row == 0:
					_label(Vector2(x + 100.0, 80.0), "%.1ft long" % lengths[column])

	func _sheet_palette() -> void:
		_label(Vector2(24, 28), "PALETTE — the curated colours on this surface", true)
		var colours := [Design.AUDIO, Design.CONTROL, Design.TRIGGER, Design.ACCENT,
			Design.WARNING, Design.ERROR]
		var style := CableArt.Style.new()
		for i in colours.size():
			var y := 110.0 + i * 105.0
			_patch(Vector2(200, y), Vector2(1050, y), colours[i], style, 0.8, 1.0)

	func _sheet_small() -> void:
		_label(Vector2(24, 28), "SMALL — does it survive being zoomed out?", true)
		var scales := [1.0, 0.7, 0.5, 0.35]
		for i in scales.size():
			var y := 130.0 + i * 165.0
			_label(Vector2(24, y - 20), "%.0f%%" % (scales[i] * 100.0))
			var style := CableArt.Style.new()
			style.thickness = 5.0 * scales[i]
			_patch(Vector2(140, y), Vector2(140 + 420.0 * scales[i], y),
				Design.AUDIO, style, 1.0, 1.0)
			var second := CableArt.Style.new()
			second.thickness = 5.0 * scales[i]
			_patch(Vector2(700, y), Vector2(700 + 420.0 * scales[i], y),
				Design.TRIGGER, second, 1.0, -1.0)
