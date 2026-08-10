extends SceneTree
## Checks the design system against the rules it claims to follow.
##
## A palette is a set of assertions about legibility, and assertions that nobody measures
## drift. Every pairing here is one somebody will actually read: text on the surface it
## sits on, at the weight and size the system assigns it.
##
##   godot --headless --path editor-godot --script res://design_test.gd
##
## Run by ctest as `editor_design`.

## Above the WCAG minimums on purpose; see the palette section below.
const TEXT_FLOOR := 7.0
const SEMANTIC_FLOOR := 4.5
const BOUNDARY_FLOOR := 3.25

var failures := 0


func check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   %s" % message)
	else:
		print("  FAIL %s" % message)
		failures += 1


func _initialize() -> void:
	Design.use_palette(Design.Palette.LAB)
	print("design system")

	# ---- every palette, against thresholds above the WCAG minimums -------------------
	# AA asks 4.5:1 for normal text, 3:1 for the boundaries of controls, and calls 7:1
	# enhanced. Designing exactly at a cutoff leaves nothing for a bad screen, a bright
	# room or a projector to take away, so the floors here are 7:1 for operating text,
	# 4.5:1 for semantic coloured text and 3.25:1 for boundaries.
	#
	# Run for all five palettes, which is the whole point of having them checked: a theme
	# nobody measures is a theme that ships one unreadable pairing.
	var surface_names := ["canvas", "panel", "raised", "active"]

	# The piano's type, which is not palette-dependent and so is checked once. Both are
	# floors on *rendered* size at every UI scale: the letters had been hardcoded at 12
	# and 13 pixels, under the system's own 14px floor, in the file least able to say so.
	check(Keyboard.keycap_size() >= Design.MIN_SCREEN_KEYCAP,
		"piano key letters are at least %dpx (%d)"
			% [Design.MIN_SCREEN_KEYCAP, Keyboard.keycap_size()])
	check(Keyboard.octave_size() >= Design.MIN_SCREEN_OCTAVE,
		"octave landmarks are at least %dpx (%d)"
			% [Design.MIN_SCREEN_OCTAVE, Keyboard.octave_size()])
	var scale_before: int = Design.ui_scale
	var smallest_keycap := 99
	for preset in Design.SCALE_NAMES.size():
		Design.ui_scale = preset
		smallest_keycap = mini(smallest_keycap, Keyboard.keycap_size())
	Design.ui_scale = scale_before
	check(smallest_keycap >= Design.MIN_SCREEN_KEYCAP,
		"and Compact cannot take them under it (%d)" % smallest_keycap)

	# The black keys straddle the joins between white keys, which is not decoration: it
	# is what makes one key the sharp of the note below and the flat of the note above,
	# and what makes the 2-and-3 grouping findable without counting. The five positions
	# this replaced were hand-picked and left every black key 98% over the white key to
	# its left — touching the join rather than crossing it.
	var centres: Dictionary = Keyboard.black_centres()
	var joins := {1: 1.0, 3: 2.0, 6: 4.0, 8: 5.0, 10: 6.0}
	var lean_worst := 0.0
	var lean_where := ""
	for semitone in centres:
		# How lopsided the key is across its join: 0 is a perfect half-and-half, 1 is
		# entirely on one side, which is what the hand-picked positions used to be.
		var offset: float = absf(float(centres[semitone]) - joins[semitone])
		var share: float = offset / (Keyboard.BLACK_WIDTH * 0.5)
		if share > lean_worst:
			lean_worst = share
			lean_where = str(semitone)
	check(lean_worst < 0.001,
		"every black key sits half on each of the two white keys it names "
			+ "(worst lean %.1f%%, semitone %s)" % [lean_worst * 100.0, lean_where])

	# Each group stays symmetric about its middle, which is what keeps the 2-and-3
	# pattern findable by feel.
	var cde: float = float(centres[1]) + float(centres[3])
	var fgab: float = float(centres[6]) + float(centres[10])
	check(absf(cde - 3.0) < 0.001 and absf(fgab - 10.0) < 0.001
			and absf(float(centres[8]) - 5.0) < 0.001,
		"and each group is symmetric about its centre (C-D-E %.3f, F-G-A-B %.3f)"
			% [cde * 0.5, fgab * 0.5])

	# The price of halving, stated rather than discovered later: centring on the joins
	# makes the inner white tops narrower than the outer ones, where a real piano keeps
	# them equal. Held to a floor so the thin ones stay a usable strip rather than
	# quietly closing up if the black keys are ever widened.
	var narrowest := 1.0
	for white in Keyboard.WHITE_OFFSETS:
		var low: float = 0.0
		var high: float = 1.0
		for semitone in centres:
			var edge_low: float = float(centres[semitone]) - Keyboard.BLACK_WIDTH * 0.5 \
				- float(Keyboard.WHITE_OFFSETS.find(white))
			var edge_high: float = float(centres[semitone]) + Keyboard.BLACK_WIDTH * 0.5 \
				- float(Keyboard.WHITE_OFFSETS.find(white))
			if edge_low < high and edge_high > low:
				if edge_low <= low:
					low = maxf(low, edge_high)
				else:
					high = minf(high, edge_low)
		narrowest = minf(narrowest, high - low)
	check(narrowest >= 0.3,
		"and the narrowest white key top is still a usable strip (%.2f of a key)"
			% narrowest)

	check(Keyboard.note_name(49).contains("♯") and Keyboard.note_name(49).contains("♭")
			and Keyboard.note_name(48) == "C3",
		"and a black key answers to both of its names (%s)" % Keyboard.note_name(49))

	for choice in Design.PALETTES.size():
		Design.use_palette(choice)
		var theme_name: String = Design.PALETTE_NAMES[choice]

		# Operating text, on every surface it can land on.
		var worst_text := 99.0
		var worst_where := ""
		# Primary ink anywhere; secondary everywhere except ACTIVE, which is the surface
		# of a pressed or selected control and carries a primary label by definition.
		# Holding secondary to 7:1 there would force it bright enough to collapse the
		# difference from primary, which is passing a test by destroying what it guards.
		for entry in [["primary", Design.INK_NORMAL], ["secondary", Design.INK_SECOND]]:
			var reach: int = Design.SURFACES.size() if entry[0] == "primary" \
				else Design.Surface.ACTIVE
			for level in reach:
				var ratio := Design.contrast(entry[1], Design.SURFACES[level])
				if ratio < worst_text:
					worst_text = ratio
					worst_where = "%s on %s" % [entry[0], surface_names[level]]
		check(worst_text >= TEXT_FLOOR,
			"%-16s operating text clears 7:1 (worst %.2f, %s)"
				% [theme_name, worst_text, worst_where])

		# The piano, which this suite could not see until its colours became tokens.
		#
		# It drew from private constants in keyboard.gd, so the one surface in the
		# application designed to be read while somebody's hands are busy was the one
		# surface no contrast test covered — and it was carrying its key letters at
		# 3.60:1, about half the floor every other piece of text in the editor is held
		# to. A token the suite cannot reach is a promise nobody is keeping.
		var worst_key_text := 99.0
		var key_where := ""
		for entry in [["white key", Design.WHITE_KEY_INK, Design.WHITE_KEY],
				["black key", Design.BLACK_KEY_INK, Design.BLACK_KEY]]:
			var ratio := Design.contrast(entry[1], entry[2])
			if ratio < worst_key_text:
				worst_key_text = ratio
				key_where = str(entry[0])
		check(worst_key_text >= TEXT_FLOOR,
			"%-16s piano key text clears 7:1 (worst %.2f, %s)"
				% [theme_name, worst_key_text, key_where])

		# Semantic colour, against what it is drawn on.
		var worst_signal := 99.0
		var signal_where := ""
		for entry in [["audio", Design.AUDIO], ["control", Design.CONTROL],
				["trigger", Design.TRIGGER], ["danger", Design.ERROR]]:
			for level in [Design.Surface.CANVAS, Design.Surface.NODE, Design.Surface.RAISED]:
				var ratio := Design.contrast(entry[1], Design.SURFACES[level])
				if ratio < worst_signal:
					worst_signal = ratio
					signal_where = "%s on %s" % [entry[0], surface_names[level]]
		check(worst_signal >= SEMANTIC_FLOOR,
			"%-16s semantic colour clears 4.5:1 (worst %.2f, %s)"
				% [theme_name, worst_signal, signal_where])

		# The boundaries of controls. A border you cannot see is a control with no edge,
		# which is what AA 1.4.11 is actually about.
		var worst_edge := 99.0
		for level in [Design.Surface.NODE, Design.Surface.RAISED, Design.Surface.ACTIVE]:
			worst_edge = minf(worst_edge,
				Design.contrast(Design.BOUNDARY, Design.SURFACES[level]))
		check(worst_edge >= BOUNDARY_FLOOR,
			"%-16s control boundaries clear 3.25:1 (worst %.2f)" % [theme_name, worst_edge])

		# Text on a filled accent button. Not white by default — white on mint is a poor
		# pairing, and this token exists to stop somebody reaching for it.
		var on_accent := Design.contrast(Design.ON_ACCENT, Design.ACCENT)
		check(on_accent >= TEXT_FLOOR,
			"%-16s accent buttons are readable (%.2f)" % [theme_name, on_accent])

		# Focus must be visible on everything it can be drawn over, and must not be the
		# accent — selection and keyboard focus are two states, not one effect twice.
		var worst_focus := 99.0
		for level in Design.SURFACES.size():
			worst_focus = minf(worst_focus,
				Design.contrast(Design.FOCUS, Design.SURFACES[level]))
		check(worst_focus >= TEXT_FLOOR,
			"%-16s the focus ring is unmistakable (%.2f)" % [theme_name, worst_focus])
		check(Design.FOCUS != Design.ACCENT,
			"%-16s and focus is not the selection colour" % theme_name)

		# The surfaces are a ladder rather than four names for one grey.
		var flattest := 99.0
		for level in Design.SURFACES.size() - 1:
			flattest = minf(flattest,
				Design.contrast(Design.SURFACES[level + 1], Design.SURFACES[level]))
		# 1.07 rather than the 1.23 an earlier version of this file demanded. These
		# palettes do the separating with a visible boundary and use fill for nuance,
		# which is a better division of labour than making the fill do both jobs and
		# shout to manage it.
		check(flattest >= 1.07,
			"%-16s each surface steps above the last (weakest %.2f)"
				% [theme_name, flattest])

		# The three signal colours are told apart from each other, measured by hue.
		#
		# The first version used Design.contrast() and all five palettes failed at about
		# 1.05 — correct arithmetic, wrong question. A contrast ratio is a luminance
		# ratio, and mint against blue is a hue difference at nearly identical luminance.
		# Believing that number would have had me flatten a good palette to satisfy a
		# measure that was never about hue.
		#
		# And it is half the story anyway: the port shapes carry the same distinction for
		# a reader who cannot use colour at all, which editor_test.gd checks in pixels.
		var nearest_hue := 360.0
		for pair in [[Design.AUDIO, Design.CONTROL], [Design.AUDIO, Design.TRIGGER],
				[Design.CONTROL, Design.TRIGGER]]:
			var apart: float = absf(pair[0].h - pair[1].h) * 360.0
			nearest_hue = minf(nearest_hue, minf(apart, 360.0 - apart))
		check(nearest_hue >= 40.0,
			"%-16s audio, control and trigger are far apart in hue (%.0f degrees)"
				% [theme_name, nearest_hue])

		# ---- a dimmed rack cable is quieter, not gone --------------------------------
		# The first version of the rack's cable dimming used alpha 0.3 and put unrelated
		# cables at 1.86:1 against the case — below the 3.25 this project asks of a plain
		# UI boundary, so what the code called "still part of the patch" was very nearly
		# not on screen. Both halves are checked: loud enough to read, and quiet enough
		# that the distinction is doing something.
		var case: Color = Design.SURFACES[Design.Surface.CANVAS]
		var faintest := 99.0
		var least_separation := 99.0
		for signal_colour: Color in [Design.AUDIO, Design.CONTROL, Design.TRIGGER]:
			var dimmed: Color = Design.recede(signal_colour, case, Rack.CableLayer.DIM_TARGET)
			faintest = minf(faintest, Design.contrast(dimmed, case))
			least_separation = minf(least_separation,
				Design.contrast(signal_colour, case) / Design.contrast(dimmed, case))
		check(faintest >= 3.25,
			"%-16s a dimmed cable still reads against the case (%.2f:1)"
				% [theme_name, faintest])
		# 1.75 rather than the 2.0 asked for first. Paper Lab's signal colours start at
		# about 6.5:1 against its case, so holding a dimmed one at the 3.6 floor leaves
		# 1.8 times and no more — the original threshold was describing the dark palettes
		# and calling it a rule. What closes the gap is DIM_WIDTH, checked below, which
		# does not vary with the palette.
		check(least_separation >= 1.75,
			"%-16s and is clearly quieter than a lit one (%.1f times)"
				% [theme_name, least_separation])

	Design.use_palette(Design.Palette.LAB)

	# ---- the dimming does not rely on colour alone -----------------------------------
	# Every de-emphasis in this editor that went wrong went wrong by asking one channel to
	# do all of it. A reader who cannot separate mint from blue can still see which cable
	# is thinner, and a palette with no contrast headroom left still has width to spend.
	check(Rack.CableLayer.DIM_WIDTH < 1.0,
		"a dimmed cable is drawn thinner as well as quieter (%.0f%% of the width)"
			% (Rack.CableLayer.DIM_WIDTH * 100.0))
	check(Rack.CableLayer.DIM_SHADOW > 0.0,
		"but keeps a shadow, so it does not lose its thickness twice over")

	# ---- the type scale holds its own rules ------------------------------------------
	# No operating text below 14px, at any UI scale. The floor is what turns "prefer
	# spacing and weight over shrinking text" from advice into a property — Compact used
	# to take the small sizes to 12 and nothing said so.
	var tokens := {
		"app title": Design.SIZE_APP_TITLE, "node title": Design.SIZE_NODE_TITLE,
		"body": Design.SIZE_BODY, "control": Design.SIZE_CONTROL,
		"tabs": Design.SIZE_TABS, "numeric": Design.SIZE_NUMERIC,
		"unit": Design.SIZE_UNIT, "secondary": Design.SIZE_SECONDARY,
		"heading": Design.SIZE_HEADING,
	}
	var smallest := 99
	var smallest_name := ""
	for size_name in tokens:
		if tokens[size_name] < smallest:
			smallest = tokens[size_name]
			smallest_name = size_name
	check(smallest >= Design.TYPE_FLOOR,
		"no size token sits under the 14px floor (smallest: %s at %d)"
			% [smallest_name, smallest])

	Design.ui_scale = Design.Scale.COMPACT
	var compact_unit := Design.type(Design.SIZE_UNIT)
	var compact_title := Design.type(Design.SIZE_APP_TITLE)
	Design.ui_scale = Design.Scale.COMFORTABLE
	check(compact_unit >= Design.TYPE_FLOOR,
		"Compact respects the floor: units hold at %dpx" % compact_unit)
	check(compact_title < Design.SIZE_APP_TITLE,
		"while sizes above it still compress (title %d from %d)"
			% [compact_title, Design.SIZE_APP_TITLE])

	# The ranking, so a future edit cannot quietly flatten it: places are one step under
	# actions, units one under values, headings one under the titles they sit beside.
	check(Design.SIZE_TABS < Design.SIZE_CONTROL,
		"tabs sit one step under toolbar controls")
	check(Design.SIZE_UNIT < Design.SIZE_NUMERIC,
		"units sit one step under the values they annotate")
	check(Design.SIZE_HEADING < Design.SIZE_NODE_TITLE,
		"section headings stay under node titles")

	# Three weights and only these three: no 300 — light is the first thing a projector
	# eats — and nothing reaches for 700, so real emphasis still has somewhere to go.
	check(Design.WEIGHT_REGULAR == 400 and Design.WEIGHT_MEDIUM == 500
		and Design.WEIGHT_SEMIBOLD == 600,
		"the weight tokens are 400, 500 and 600")

	# The unit face is genuinely one weight down from the value face, measured the same
	# way the StringName-tag bug was caught: by width, because a weight that does not
	# change the metrics is a weight that is not being applied.
	var value_width: float = Design.numeric_font().get_string_size(
		"0123456789 Hz", HORIZONTAL_ALIGNMENT_LEFT, -1, 32).x
	var unit_width: float = Design.unit_font().get_string_size(
		"0123456789 Hz", HORIZONTAL_ALIGNMENT_LEFT, -1, 32).x
	check(unit_width < value_width,
		"the unit face is lighter than the value face (%.0f against %.0f)"
			% [unit_width, value_width])

	# ---- the ink levels are actually distinguishable from one another ----------------
	# Four names for the same grey would be a system on paper only.
	# Bright and normal are deliberately one value now, differing by weight instead:
	# two greys a few percent apart are a distinction nobody can use, a Regular and a
	# SemiBold at one colour is one anybody can. The remaining three still have to
	# recede in order — and "recede" means towards the background, which is downwards
	# on a dark palette and upwards on Paper.
	var ladder := [Design.INK_NORMAL, Design.INK_SECOND, Design.INK_DISABLED]
	var ladder_names := ["normal", "secondary", "disabled"]
	var dark_theme := Design.relative_luminance(
		Design.SURFACES[Design.Surface.CANVAS]) < 0.3
	for i in ladder.size() - 1:
		var a := Design.relative_luminance(ladder[i])
		var b := Design.relative_luminance(ladder[i + 1])
		check(a > b if dark_theme else a < b,
			"%s stands further from the background than %s"
				% [ladder_names[i], ladder_names[i + 1]])

	# ---- the font carries the weights the system asks for ----------------------------
	# One variable file supplies Regular, Medium and SemiBold. If it were ever swapped for
	# a static face, every weight would silently collapse to one and the whole hierarchy
	# would go with it — which is exactly the state this pass set out to fix.
	var weights := [Design.WEIGHT_REGULAR, Design.WEIGHT_MEDIUM, Design.WEIGHT_SEMIBOLD]
	var widths := []
	for weight: int in weights:
		var face := Design.font(weight)
		check(face != null, "the UI font loads at weight %d" % weight)
		if face != null:
			widths.append(face.get_string_size("Handgloves", HORIZONTAL_ALIGNMENT_LEFT,
				-1, Design.SIZE_BODY).x)
	if widths.size() == weights.size():
		check(widths[2] > widths[0],
			"and SemiBold is visibly heavier than Regular (%.1f vs %.1f px)"
				% [widths[2], widths[0]])

	# ---- numbers line up -------------------------------------------------------------
	# A readout counting 111.0 -> 888.0 that jitters sideways is hard to read at exactly
	# the moment somebody is watching it move.
	var numeric := Design.numeric_font()
	check(numeric != null, "the numeric font loads%s"
		% ("" if Design.has_mono() else " (Next with tabular figures; Mono not installed)"))
	if numeric != null:
		var narrow := numeric.get_string_size("111.111", HORIZONTAL_ALIGNMENT_LEFT, -1,
			Design.SIZE_NUMERIC).x
		var wide := numeric.get_string_size("888.888", HORIZONTAL_ALIGNMENT_LEFT, -1,
			Design.SIZE_NUMERIC).x
		check(absf(narrow - wide) < 0.5,
			"and every digit is the same width (%.2f vs %.2f px)" % [narrow, wide])

	# ---- the scale presets are a real range ------------------------------------------
	var sizes := []
	for preset in Design.SCALE_FACTORS.size():
		Design.ui_scale = preset
		sizes.append(Design.type(Design.SIZE_BODY))
	Design.ui_scale = Design.Scale.COMFORTABLE
	check(sizes[0] < sizes[1] and sizes[1] < sizes[2] and sizes[2] < sizes[3],
		"the UI scale presets step up (%s)" % str(sizes))
	check(sizes[3] >= sizes[1] + 4,
		"and XL is a genuinely bigger target than Comfortable (%d vs %d)"
			% [sizes[3], sizes[1]])

	# ---- spacing is a scale, and it is the one the system says it is ------------------
	var spacing := [Design.SPACE_XS, Design.SPACE_S, Design.SPACE_M, Design.SPACE_L,
		Design.SPACE_XL, Design.SPACE_XXL]
	check(spacing == [4, 8, 12, 16, 24, 32], "the spacing scale is 4/8/12/16/24/32")
	check(Design.NODE_PADDING_H >= 12 and Design.NODE_PADDING_H <= 16,
		"node horizontal padding is in the 12–16 band (%d)" % Design.NODE_PADDING_H)

	if failures == 0:
		print("all design checks passed")
	else:
		print("%d design check(s) failed" % failures)
	quit(1 if failures > 0 else 0)
