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

var failures := 0


func check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   %s" % message)
	else:
		print("  FAIL %s" % message)
		failures += 1


func _initialize() -> void:
	print("design system")

	# ---- surfaces are a ladder, not a puddle -----------------------------------------
	# The original complaint was that every surface was the same medium grey. The fix is
	# only real if the steps are measurable, so measure them.
	var previous := -1.0
	var names := ["canvas", "node", "raised", "active"]
	for level in Design.SURFACES.size():
		var luminance := Design.relative_luminance(Design.SURFACES[level])
		check(luminance > previous,
			"%s is lighter than the surface below it (%.4f)" % [names[level], luminance])
		previous = luminance

	# A step you cannot see is not a step. Adjacent surfaces have to differ enough to read
	# as a boundary on a cheap projector at a trade show, not only on a good monitor.
	for level in Design.SURFACES.size() - 1:
		var ratio := Design.contrast(Design.SURFACES[level + 1], Design.SURFACES[level])
		check(ratio >= 1.2,
			"%s reads as raised above %s (%.2f:1)" % [names[level + 1], names[level], ratio])

	# And not so far apart that the app turns into stripes.
	for level in Design.SURFACES.size() - 1:
		var ratio := Design.contrast(Design.SURFACES[level + 1], Design.SURFACES[level])
		check(ratio <= 2.2,
			"and does not shout about it (%.2f:1)" % ratio)

	# ---- text clears WCAG on every surface it can land on ----------------------------
	# 4.5:1 is the AA minimum for normal text. Primary text is held to the enhanced 7:1
	# instead, because this is a dense tool people stare at for hours and designing right
	# against the minimum leaves nothing for a bad screen or bright room to take away.
	var readable := {
		"bright": Design.INK_BRIGHT,
		"normal": Design.INK_NORMAL,
		"secondary": Design.INK_SECOND,
	}
	for ink_name in readable:
		for level in Design.SURFACES.size():
			var ratio := Design.contrast(readable[ink_name], Design.SURFACES[level])
			var floor_ratio := 7.0 if ink_name != "secondary" else 4.5
			check(ratio >= floor_ratio,
				"%s text on %s is %.1f:1 (needs %.1f)"
					% [ink_name, names[level], ratio, floor_ratio])

	# Secondary is allowed to be calmer, but it carries units and counts, so it gets
	# headroom over the minimum on the surfaces it actually lands on. ACTIVE is excluded
	# deliberately rather than by oversight: a pressed or selected control shows a primary
	# label, and holding secondary ink to a headroom rule *there* would have forced it
	# bright enough to collapse the difference from normal — which would have been
	# satisfying the test at the cost of the hierarchy the test exists to protect.
	for level in [Design.Surface.CANVAS, Design.Surface.NODE, Design.Surface.RAISED]:
		var ratio := Design.contrast(Design.INK_SECOND, Design.SURFACES[level])
		check(ratio >= 5.5, "and secondary has headroom on %s (%.1f:1)" % [names[level], ratio])

	# ---- the meaning colours have to be readable too ---------------------------------
	# An error message below the contrast floor is a special kind of failure.
	for entry in [["accent", Design.ACCENT], ["warning", Design.WARNING],
			["error", Design.ERROR]]:
		for level in [Design.Surface.NODE, Design.Surface.RAISED]:
			var ratio := Design.contrast(entry[1], Design.SURFACES[level])
			check(ratio >= 4.5,
				"%s on %s is %.1f:1" % [entry[0], names[level], ratio])

	# ---- the ink levels are actually distinguishable from one another ----------------
	# Four names for the same grey would be a system on paper only.
	var ladder := [Design.INK_BRIGHT, Design.INK_NORMAL, Design.INK_SECOND,
		Design.INK_DISABLED]
	var ladder_names := ["bright", "normal", "secondary", "disabled"]
	for i in ladder.size() - 1:
		var a := Design.relative_luminance(ladder[i])
		var b := Design.relative_luminance(ladder[i + 1])
		check(a > b, "%s is brighter than %s" % [ladder_names[i], ladder_names[i + 1]])

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
		sizes.append(Design.scale(Design.SIZE_BODY))
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
