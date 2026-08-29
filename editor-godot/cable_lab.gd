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
const Faceplate := preload("res://cable_faceplate.gd")

const SHEETS := {
	"slack": "slack, tight to loose",
	"weight": "thickness and highlight",
	"plug": "plug proportions",
	"palette": "the curated colours on every surface",
	"small": "the same cable at four zoom levels",
	"faceplate": "cables on a real panel, at four zooms — the one that matters",
	"detail": "one plug at 4x, so the construction can be argued with",
	"perspective": "four projection grammars at 4x and 1x — A current, B mild, C medium, D flat",
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
			"faceplate": _sheet_faceplate()
			"detail": _sheet_detail()
			"perspective": _sheet_perspective()
			_: _sheet_slack()

	func _label(at: Vector2, text: String, bright := false) -> void:
		var font := ThemeDB.fallback_font
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
			Design.INK_NORMAL if bright else Design.INK_SECOND)

	## One cable, plugs and all, between two jacks.
	##
	## Both plugs point down, because that is what a faceplate does: a cable leaves towards
	## the viewer and only then falls. Drawing the plug along the curve's own tangent, as
	## the first pass did, makes it lie flat along the cable and lose the one thing it is
	## there to say.
	func _patch(a: Vector2, b: Vector2, colour: Color, style: CableArt.Style,
			slack: float, id := "x") -> void:
		var ring: Color = Design.SURFACES[Design.Surface.RAISED]
		var canvas_colour: Color = Design.SURFACES[Design.Surface.CANVAS]
		var socket := canvas_colour.darkened(0.4)
		var radius := maxf(style.plug_width * style.thickness * 0.5 + 2.5, 5.0)
		var out := Vector2.DOWN

		CableArt.draw_socket(self, a, radius, ring, style)
		CableArt.draw_socket(self, b, radius, ring, style)
		var points := CableArt.cable_path(a, out, b, out, slack, style, id)
		CableArt.draw_cable(self, points, colour, style)
		CableArt.draw_plug(self, a, out, colour, style)
		CableArt.draw_plug(self, b, out, colour, style)

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
				_patch(Vector2(x, y), Vector2(x + span, y), CableArt.PALETTE["cyan"], style,
					amounts[row], "slack%d-%d" % [row, int(span)])
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
				_patch(Vector2(x, y), Vector2(x + 190.0, y), CableArt.PALETTE["amber"], style,
					0.82, "w%d-%d" % [row, column])
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
				_patch(Vector2(x, y), Vector2(x + 250.0, y), CableArt.PALETTE["magenta"], style,
					0.82, "p%d-%d" % [row, column])
				if row == 0:
					_label(Vector2(x + 100.0, 80.0), "%.1ft long" % lengths[column])

	func _sheet_palette() -> void:
		_label(Vector2(24, 28), "PALETTE — the curated colours on this surface", true)
		var colours: Array = []
		for name: String in CableArt.PALETTE_ORDER:
			colours.append(CableArt.PALETTE[name])
		var style := CableArt.Style.new()
		for i in colours.size():
			var y := 96.0 + i * 92.0
			_patch(Vector2(200, y), Vector2(1050, y), colours[i], style, 0.82, "pal%d" % i)

	func _sheet_faceplate() -> void:
		_label(Vector2(20, 22), "FACEPLATE — does it read as plugged into a synth?", true)
		var font := ThemeDB.fallback_font
		# Two rows. In one row the 35% panel fell off the right edge, which is a funny way
		# to fail the test that exists to ask whether small still works.
		var zooms := [1.0, 0.7, 0.5, 0.35]
		var x := 24.0
		var y := 62.0
		for index in zooms.size():
			var zoom: float = zooms[index]
			if index == 2:
				x = 24.0
				y = 470.0
			_label(Vector2(x, y - 10), "%.0f%%" % (zoom * 100.0))
			Faceplate.draw_panel(self, Vector2(x, y), zoom, font)
			x += (250.0 + 90.0 + 250.0) * zoom + 40.0

	## One plug, four times life size.
	##
	## Every other sheet judges the plug at the size it ships at, which is the right
	## question but the wrong way to find out what is wrong with it. Blown up, it is
	## obvious whether there are three shapes in a row or one dark blob with a stripe.
	func _sheet_detail() -> void:
		_label(Vector2(24, 24), "DETAIL — one plug at 4x. barrel, collar, relief, cable.", true)
		var seats := [0.28, 0.20, 0.12]
		var rings := [3.0, 2.0, 1.2]
		for row in seats.size():
			var y := 150.0 + row * 230.0
			_label(Vector2(24, y - 60), "seat %.2f, rim +%.0f" % [seats[row], rings[row]])
			for column in 2:
				var style: CableArt.Style = CableArt.Style.new().scaled(4.0)
				style.plug_seat = seats[row]
				var jack := Vector2(240.0 + column * 520.0, y)
				var out := Vector2.DOWN
				var far := jack + Vector2(360.0, 40.0)
				var ring: Color = Design.SURFACES[Design.Surface.RAISED]
				var ground: Color = Design.SURFACES[Design.Surface.CANVAS]
				var radius: float = style.plug_width * style.thickness * 0.5 + rings[row] * 4.0
				var colour: Color = CableArt.PALETTE["amber" if column == 0 else "cyan"]

				CableArt.draw_socket(self, jack, radius, ring, style)
				var points := CableArt.cable_path(jack, out, far, Vector2.UP, 0.82,
					style, "d%d%d" % [row, column])
				CableArt.draw_cable(self, points, colour, style)
				CableArt.draw_plug(self, jack, out, colour, style)

	## Four projection grammars, same jack, same colour, same path.
	##
	## The question is not which dimensions are best; it is which grammar the eye accepts.
	## So everything except the projection is held still, and each is shown at 4x to
	## diagnose the construction and at 1x because that is where it has to work. Choosing a
	## winner from the enlarged view alone would be choosing the wrong thing.
	func _sheet_perspective() -> void:
		_label(Vector2(24, 22), "PLUG-PERSPECTIVE — same cable, four grammars. 4x above, 1x below.", true)
		var variants := [
			{"name": "A  current side view", "kind": "side", "tilt": 0.0},
			{"name": "B  mild emergence 15", "kind": "emerge", "tilt": 15.0},
			{"name": "C  medium emergence 27", "kind": "emerge", "tilt": 27.0},
			{"name": "D  full top-down", "kind": "flat", "tilt": 0.0},
		]
		for column in variants.size():
			var variant: Dictionary = variants[column]
			var x := 40.0 + column * 350.0
			_label(Vector2(x, 56), variant["name"])
			_perspective_one(Vector2(x + 70.0, 150.0), 4.0, variant)
			_label(Vector2(x, 520), "1x")
			_perspective_one(Vector2(x + 70.0, 560.0), 1.0, variant)
			# And once more at 1x on a strip of panel, since a plug is never judged in
			# the void — the socket has to sit in something.
			var panel: Color = Design.SURFACES[Design.Surface.NODE]
			draw_rect(Rect2(Vector2(x + 10.0, 640.0), Vector2(300.0, 110.0)), panel)
			_label(Vector2(x, 630), "1x on panel")
			_perspective_one(Vector2(x + 70.0, 672.0), 1.0, variant)

	func _perspective_one(jack: Vector2, zoom: float, variant: Dictionary) -> void:
		var style: CableArt.Style = CableArt.Style.new().scaled(zoom)
		style.tilt_degrees = variant["tilt"]
		var ring: Color = Design.SURFACES[Design.Surface.RAISED]
		var colour: Color = CableArt.PALETTE["amber"]
		var out := Vector2.DOWN
		var far := jack + Vector2(150.0, 90.0) * zoom
		var radius: float = maxf(style.plug_width * style.thickness * 0.5 + 2.5 * zoom, 5.0)

		CableArt.draw_socket(self, jack, radius, ring, style)
		var points := CableArt.cable_path(jack, out, far, Vector2.UP, 0.7, style, "persp")
		CableArt.draw_cable(self, points, colour, style)
		match variant["kind"]:
			"emerge": CableArt.draw_plug_emergent(self, jack, out, colour, style)
			"flat": CableArt.draw_plug_topdown(self, jack, out, colour, style)
			_: CableArt.draw_plug(self, jack, out, colour, style)

	func _sheet_small() -> void:
		_label(Vector2(24, 28), "SMALL — does it survive being zoomed out?", true)
		var scales := [1.0, 0.7, 0.5, 0.35]
		for i in scales.size():
			var y := 130.0 + i * 165.0
			_label(Vector2(24, y - 20), "%.0f%%" % (scales[i] * 100.0))
			var style: CableArt.Style = CableArt.Style.new().scaled(scales[i])
			_patch(Vector2(140, y), Vector2(140 + 420.0 * scales[i], y),
				CableArt.PALETTE["cyan"], style, 0.82, "sm%d" % i)
			var second: CableArt.Style = CableArt.Style.new().scaled(scales[i])
			_patch(Vector2(700, y), Vector2(700 + 420.0 * scales[i], y),
				CableArt.PALETTE["amber"], second, 0.82, "sm2-%d" % i)
