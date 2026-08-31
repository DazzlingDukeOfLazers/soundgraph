extends SceneTree

## The faceplate themes. Their lettering has to be readable for the same reason the
## palettes' does — a panel is not decoration, it is a label you operate.
const ModuleThemes := preload("res://module_themes.gd")
## The graph, for the one piece of it that is a pure function on a name and a width.
const PatchGraph := preload("res://patch_graph.gd")
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

	# ---- every faceplate can be read -------------------------------------------------
	# A theme is a look, and a look that costs legibility is not a trade this editor
	# makes anywhere else. This covers every piece of text on a painted panel — the
	# title, a knob's name, its value, a jack's label — because on a painted panel they
	# are all one colour. They were not always: the title was themed and the knobs were
	# left on the rack's light ink, which is near-white lettering on the cream of Ivory
	# Lab, and this check went on passing because it was only ever asking about the title.
	#
	# The bar is 4.5:1 rather than the 7:1 asked of operating text:
	# a module title is large, bold and upper case, which is exactly the case the
	# standard relaxes for. Panels are also lit by a screen rather than a room, so the
	# number is a floor and not a target.
	for key in ModuleThemes.ORDER:
		var face := ModuleThemes.token(str(key), "faceplate")
		var legend := ModuleThemes.token(str(key), "legend")
		var ratio := Design.contrast(legend, face)
		check(ratio >= 4.5, "%s: its lettering reads on its panel (%.1f:1)"
			% [ModuleThemes.display_name(str(key)), ratio])

	# The pointer is the one part of a knob that has to be visible across a desk, and it
	# is drawn on the knob rather than on the panel.
	for key in ModuleThemes.ORDER:
		var body := ModuleThemes.token(str(key), "knob")
		var pointer := ModuleThemes.token(str(key), "pointer")
		var ratio := Design.contrast(pointer, body)
		check(ratio >= 3.0, "%s: its pointer reads on its knob (%.1f:1)"
			% [ModuleThemes.display_name(str(key)), ratio])

	# And the ring around a socket has to be findable against the socket field, which is
	# black in every one of them — that is the family resemblance, and it only works if
	# the ring is doing the separating.
	for key in ModuleThemes.ORDER:
		var jack := ModuleThemes.token(str(key), "jack")
		var ring := ModuleThemes.token(str(key), "ring")
		var ratio := Design.contrast(ring, jack)
		check(ratio >= 3.0, "%s: its jack rings read on the socket field (%.1f:1)"
			% [ModuleThemes.display_name(str(key)), ratio])

	# The spanning rule, on controls built for the purpose rather than on whichever node
	# happens to have a long enumeration today. A parameter whose control cannot inhabit
	# one standard column takes the whole row; one that can, shares.
	#
	# The pair is found by growing an option a letter at a time until the rule itself
	# flips, so the test straddles the real threshold rather than a second opinion about
	# where it is. The first version computed the boundary itself and disagreed with the
	# rule the moment the rule's own figure moved.
	for palette in Design.PALETTES.size():
		Design.use_palette(palette)
		var narrow := ""
		var wide := "m"
		while not NodeGrid.spans({"enum": [wide]}) and wide.length() < 200:
			narrow = wide
			wide += "m"
		check(narrow != "" and not NodeGrid.spans({"enum": [narrow]}),
			"%s: an option that fits shares its row (%d characters)"
				% [Design.PALETTE_NAMES[palette], narrow.length()])
		check(NodeGrid.spans({"enum": [wide]}),
			"%s: and one letter more takes the row (%d characters)"
				% [Design.PALETTE_NAMES[palette], wide.length()])
		# And a parameter with no enumeration never spans, whatever its numbers say: a
		# knob is a dial of a fixed diameter and fits a column by construction.
		check(not NodeGrid.spans({"unit": "octaves/s", "min": -20000.0, "max": 20000.0}),
			"%s: a knob never takes a row to itself" % Design.PALETTE_NAMES[palette])
	Design.use_palette(Design.Palette.LAB)

	# Every migrated type says what it is called when there is no room. Part of the
	# contract rather than a repair applied when today's geometry happens to need one:
	# an ellipsis in the graph means exactly one thing, a type that has not been through
	# the pass, and that only holds if every type that has been through it can fall back
	# to a written-down name instead of a cut. A type whose two names are the same says
	# so explicitly.
	for type: String in NodeIdentity.MIGRATED:
		check(NodeIdentity.has_compact(type),
			"%s has declared a compact name" % type)

	# Identity variants stay narrow. A type may declare one discrete parameter that
	# changes what operation it performs; every other type is keyed by type alone. This
	# is the check that the exception has not quietly become the rule — the general
	# version, where any moving value can drive a glyph, is how identity stops meaning
	# identity.
	for type: String in NodeIdentity.VARIANT:
		var declared: Dictionary = NodeIdentity.VARIANT[type]
		check(str(declared.get("parameter", "")) != "",
			"%s names the parameter that drives its identity" % type)
		check((declared.get("glyphs", []) as Array).size() >= 2,
			"%s has a mark for more than one of its modes" % type)
		# And the variants are all different, or the mechanism is drawing one glyph
		# under several names and saying nothing.
		var distinct := {}
		for mark: int in declared["glyphs"]:
			distinct[mark] = true
		check(distinct.size() == (declared["glyphs"] as Array).size(),
			"%s draws a different mark for each of them" % type)
		# Asking for a mode the type does not have falls back rather than failing.
		check(NodeIdentity.glyph_of(type, 99) == NodeIdentity.glyph_of(type),
			"%s falls back to its type mark for a mode it has not got" % type)
	check(NodeIdentity.variant_parameter("Gain") == "",
		"and a type that declares none has none")

	# Values are written the way somebody would say them. A table rather than a rule
	# restated in a second place: these are the readings the three proving-ground nodes
	# actually show, plus the boundaries a formatter goes wrong at — a value that is not
	# zero and nearly is, an exact integer, a negative, a unit that changes under the
	# value's feet, and an enumeration.
	var readings: Array = [
		[{"unit": "", "min": 0.0, "max": 4.0}, 0.7, "0.7"],
		[{"unit": "", "min": 0.0, "max": 4.0}, 1.0, "1"],
		[{"unit": "", "min": 0.0, "max": 4.0}, 0.755, "0.755"],
		[{"unit": "", "min": 0.0, "max": 4.0}, 4.0, "4"],
		[{"unit": "", "min": 0.0, "max": 1.0}, 0.55, "0.55"],
		[{"unit": "", "min": 0.0, "max": 1.0}, 0.0, "0"],
		[{"unit": "Hz", "min": 20.0, "max": 20000.0}, 900.0, "900 Hz"],
		[{"unit": "Hz", "min": 20.0, "max": 20000.0}, 20.0, "20 Hz"],
		[{"unit": "Hz", "min": 20.0, "max": 20000.0}, 999.0, "999 Hz"],
		[{"unit": "Hz", "min": 20.0, "max": 20000.0}, 1000.0, "1 kHz"],
		[{"unit": "Hz", "min": 20.0, "max": 20000.0}, 12345.0, "12.35 kHz"],
		[{"unit": "octaves/s", "min": -20.0, "max": 20.0}, 0.0, "0 octaves/s"],
		[{"unit": "octaves/s", "min": -20.0, "max": 20.0}, -3.5, "-3.5 octaves/s"],
		[{"unit": "s", "min": 0.0, "max": 10.0}, 0.010, "10 ms"],
		[{"unit": "s", "min": 0.0, "max": 10.0}, 0.250, "250 ms"],
		[{"unit": "s", "min": 0.0, "max": 10.0}, 0.300, "300 ms"],
		[{"unit": "s", "min": 0.0, "max": 10.0}, 0.0, "0 ms"],
		[{"unit": "s", "min": 0.0, "max": 10.0}, 2.5, "2.5 s"],
		# Not zero, and must not be written as though it were.
		[{"unit": "s", "min": 0.0, "max": 10.0}, 0.0005, "0.5 ms"],
		[{"unit": "", "min": 0.0, "max": 3.0,
			"enum": ["lowpass", "highpass", "bandpass", "notch"]}, 2.0, "bandpass"],
	]
	for reading: Array in readings:
		var got := ValueText.of(reading[0] as Dictionary, float(reading[1]))
		check(got == str(reading[2]), "%s reads as %s%s" % [
			JSON.stringify(reading[1]), reading[2],
			"" if got == str(reading[2]) else " (got %s)" % got])

	# What the field puts on screen has to come back as the value it came from. The
	# gesture that has to be a no-op — open the editor, press return, change nothing —
	# used to store ten seconds for an attack of ten milliseconds, because the display
	# converted units and the parse did not.
	# The property is a fixed point, not equality. A display is a rounding — "12.35 kHz"
	# is 12345 hertz shown to the resolution the parameter earns — so re-typing it commits
	# that rounding, and it always did. What must be true is that the reading does not
	# *drift*: what the field shows, parsed and shown again, is the same string. That
	# holds the unit conversion honest (ten milliseconds read back as ten seconds fails it
	# by a factor of a thousand) without pretending a rounded display carries every bit.
	for reading: Array in readings:
		var descriptor: Dictionary = reading[0]
		if descriptor.has("enum"):
			continue
		var shown := ValueText.of(descriptor, float(reading[1]))
		var again := ValueText.of(descriptor,
			ValueText.parse(descriptor, shown, shown))
		check(again == shown, "%s reads back as itself%s"
			% [shown, "" if again == shown else " (got %s)" % again])
		# And with the unit rubbed out, which is what a typist does when they mean to
		# replace the number: the unit that was on screen is the one they meant.
		var bare := ValueText._numeric_prefix(shown)
		var without := ValueText.of(descriptor,
			ValueText.parse(descriptor, bare, shown))
		check(without == shown, "%s without its unit still means %s%s"
			% [bare, shown, "" if without == shown else " (got %s)" % without])

	# The two cases the inference has to get right, and they want opposite answers. A
	# field showing "1 kHz" handed a bare 440 means hertz; a field showing "10 ms" handed
	# a bare 20 means milliseconds. The parameter's own range is what separates them.
	var cutoff := {"unit": "Hz", "min": 20.0, "max": 20000.0}
	var attack := {"unit": "s", "min": 0.0, "max": 10.0}
	check(is_equal_approx(ValueText.parse(cutoff, "440", "1 kHz"), 440.0),
		"440 typed over a kilohertz reading means hertz (%s)"
			% ValueText.parse(cutoff, "440", "1 kHz"))
	check(is_equal_approx(ValueText.parse(cutoff, "5", "1 kHz"), 5000.0),
		"but 5 over the same reading means kilohertz (%s)"
			% ValueText.parse(cutoff, "5", "1 kHz"))
	check(is_equal_approx(ValueText.parse(attack, "20", "10 ms"), 0.02),
		"20 typed over a millisecond reading means milliseconds (%s)"
			% ValueText.parse(attack, "20", "10 ms"))
	check(is_equal_approx(ValueText.parse(attack, "20 s", "10 ms"), 20.0),
		"and a unit that was typed on purpose is believed (%s)"
			% ValueText.parse(attack, "20 s", "10 ms"))

	# And the cell a value lives in is sized for the longest reading the parameter can
	# produce, not for its two ends. Stripped of trailing zeros the ends are often the
	# *shortest* strings a parameter has, and a cell measured on them is too narrow for
	# nearly every value it then holds — a knob that resizes its own cell while it is
	# being turned.
	for reading: Array in readings:
		var descriptor: Dictionary = reading[0]
		if descriptor.has("enum"):
			continue
		var room := ValueText.widest(descriptor).length()
		check(str(reading[2]).length() <= room,
			"%s fits the space reserved for it (%d <= %d)" % [reading[2],
				str(reading[2]).length(), room])

	# A type that has been through the pass never has its name cut. Canonical while it
	# fits, then the written-down compact name, then nothing — the governing rule of the
	# whole pass applied to its own last case, because five letters and an ellipsis is
	# not an identity. An ellipsis in the graph now means exactly one thing, and this is
	# what keeps it meaning that.
	#
	# Swept rather than sampled at four zooms: the cut this replaces only appeared below
	# 0.28, which is under every zoom anybody had photographed.
	for palette in Design.PALETTES.size():
		Design.use_palette(palette)
		for entry: Array in [["Amplifier", "Gain"], ["Lowpass", "StateVariableFilter"],
				["Amp Envelope", "ADSR"]]:
			var node := GraphNode.new()
			node.title = str(entry[0])
			node.set_meta("compact_name", NodeIdentity.compact_of(str(entry[1])))
			var width := float(NodeGrid.width_for(str(entry[1])))
			var font := Design.font(Design.WEIGHT_SEMIBOLD)
			var pinned := Design.screen_minimum(Design.MIN_SCREEN_NODE_TITLE)
			var cut := ""
			for step in 36:
				var zoom := 1.0 - float(step) * 0.025
				var drawn := PatchGraph.ScreenText._name_for(node, font, pinned,
					width * zoom - 12.0)
				if drawn.ends_with("…"):
					cut = "%s at %.3f -> %s" % [node.title, zoom, drawn]
			check(cut == "", "%s: %s is never cut%s" % [
				Design.PALETTE_NAMES[palette], entry[0],
				"" if cut == "" else " (" + cut + ")"])
			node.free()
	Design.use_palette(Design.Palette.LAB)

	# A node's title has to stay readable on every ground the state vocabulary can put
	# under it. This is the check that caught the first warning tint: it made a handsome
	# olive header and dropped the name to 5.3:1, under the program's own floor, on the
	# one node the reader most needs to read.
	for palette in Design.PALETTES.size():
		Design.use_palette(palette)
		for selected: bool in [false, true]:
			for health: int in [NodeState.Health.WELL, NodeState.Health.WARNING,
					NodeState.Health.ERROR]:
				for hovered: bool in [false, true]:
					var ground := NodeState.header(selected, hovered, health)
					var ratio := Design.contrast(Design.INK_BRIGHT, ground)
					check(ratio >= TEXT_FLOOR,
						"%s: a node title reads on a %s%s%s header (%.1f:1)" % [
							Design.PALETTE_NAMES[palette],
							["well", "warned", "failing"][health],
							" selected" if selected else "",
							" hovered" if hovered else "", ratio])
	Design.use_palette(Design.Palette.LAB)

	# Every icon marks pixels. An icon that silently draws nothing is the tofu box in a
	# new hat: not an error, just a rectangle of nothing where a mark should be, and
	# nothing in the build says so. Checked at the two sizes the set is actually used
	# at — a menu door and a node header.
	for name: String in Icons.Kind.keys():
		for size: int in [20, 24]:
			var image: Image = Icons.get_icon(int(Icons.Kind[name]), size,
				Design.INK_SECOND).get_image()
			var inked := 0
			for y in image.get_height():
				for x in image.get_width():
					if image.get_pixel(x, y).a > 0.0:
						inked += 1
			check(inked > 0, "%s draws something at %d (%d px)" % [name, size, inked])

	# And stays inside its cell. The field is what keeps a mark from crowding the word
	# beside it, and a glyph that reaches the edge of its box is a glyph that will touch
	# the title on somebody else's interface scale.
	for name: String in Icons.Kind.keys():
		var image: Image = Icons.get_icon(int(Icons.Kind[name]), 96,
			Design.INK_SECOND).get_image()
		var edge := 0
		for i in 96:
			for pair: Array in [[i, 0], [i, 95], [0, i], [95, i]]:
				if image.get_pixel(pair[0], pair[1]).a > 0.0:
					edge += 1
		check(edge == 0, "%s stays off the edge of its cell" % name)

	if failures == 0:
		print("all design checks passed")
	else:
		print("%d design check(s) failed" % failures)
	quit(1 if failures > 0 else 0)
