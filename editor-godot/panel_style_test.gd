extends SceneTree

## The eleven panel styles, and the tokens a painted module resolves to.
const ModuleThemes := preload("res://module_themes.gd")
## The canvas, for the overlay that redraws titles too small to read.
const PatchGraph := preload("res://patch_graph.gd")
## Every node wearing a different panel style, through every way of changing one.
##
##   godot --headless --path editor-godot --script res://panel_style_test.gd
##
## Written because the styles were inconsistent in use: a panel would not show its new
## style until something else made it redraw, and one that was showing it would lose it
## again on a zoom or a trip through another view. One node in one style cannot catch
## that. Every node in a different style, rotated twice, can — a style that lands on the
## wrong module, or falls back to the patch's, is then a difference between two nodes
## rather than a colour nobody can check from memory.
##
## The rotations are +1 and then -2 for the same reason. Painting a node that has no
## style is the easy direction; the failures were in style-to-style, where an override is
## already on the widget, and in landing back on a style the node wore two steps ago.

var failures := 0


func check(condition: bool, message: String) -> void:
	if condition:
		print("  ok   %s" % message)
	else:
		print("  FAIL %s" % message)
		failures += 1


## Every knob on a node. The graph draws the rack's own control, so a skin the rack
## understands is the whole of what a dial needs.
func _knobs(widget: GraphNode) -> Array:
	var found: Array = []
	var queue: Array = widget.get_children()
	while not queue.is_empty():
		var next: Node = queue.pop_back()
		for child in next.get_children():
			queue.append(child)
		if next is Rack.Knob:
			found.append(next)
	return found


## Every node in the patch, in document order.
func _ids(main) -> Array:
	var found: Array = []
	for node in main.patch.get("nodes", []):
		found.append(str((node as Dictionary).get("id", "")))
	return found


## The style node `index` should be wearing once the whole patch has been rotated by
## `offset`. Nodes are painted from the same list they are checked against, one step
## apart, so no two nodes in a patch this size share a style.
func _expected(index: int, offset: int) -> String:
	var order: Array = ModuleThemes.ORDER
	return str(order[posmod(index + offset, order.size())])


## Paints every node its own style.
func _paint(main, offset: int) -> void:
	var ids := _ids(main)
	for index in ids.size():
		main._set_module_theme(str(ids[index]), _expected(index, offset))


## Asks the running editor what each node is actually wearing, and says which ones are
## wrong rather than only that something is.
##
## Deliberately does not wait for a frame first: "it did not show until I clicked
## something else" is the complaint, so the state is read the moment the edit returns. A
## repaint that needs a frame to land is a repaint that will sometimes be seen not to
## have landed.
## Every Label written on a node, the title excepted — it is checked against the header
## it sits on rather than against the plate.
func _lettering(main, widget: GraphNode) -> Array:
	var found: Array = []
	var title: Label = main._title_label(widget)
	var queue: Array = widget.get_children()
	while not queue.is_empty():
		var next: Node = queue.pop_back()
		for child in next.get_children():
			queue.append(child)
		var label := next as Label
		if label != null and label != title and label.text.strip_edges() != "":
			found.append(label)
	return found


func _verify(main, offset: int, when: String) -> void:
	var ids := _ids(main)
	var unresolved: Array = []
	var unpainted: Array = []
	var unheaded: Array = []
	var mistitled: Array = []
	var faint: Array = []
	var unlettered: Array = []
	var unreadable: Array = []
	var knobs_missed: Array = []
	for index in ids.size():
		var id := str(ids[index])
		var want := _expected(index, offset)
		if str(main._panel_style_of(id)) != want:
			unresolved.append("%s wants %s, resolves %s"
				% [id, want, main._panel_style_of(id)])
		var widget: GraphNode = main.widgets.get(id) as GraphNode
		if widget == null:
			continue
		var plate := ModuleThemes.token(want, "faceplate")
		var legend := ModuleThemes.token(want, "legend")

		# The body, which is the panel itself. GraphNode draws a selected node from a
		# different stylebox, so both are asked for: a style that comes off the moment
		# somebody clicks the module is not a style.
		var face := widget.get_theme_stylebox("panel") as StyleBoxFlat
		var face_selected := widget.get_theme_stylebox("panel_selected") as StyleBoxFlat
		if face == null or face.bg_color != plate \
				or face_selected == null or face_selected.bg_color != plate:
			unpainted.append("%s (%s)" % [id, want])
		# The header is the same plate with a line ruled under it. It was the edge
		# colour briefly, until the title contrast check said what that costs: a
		# legend is chosen against its faceplate, and a darker version of that plate
		# is a pair nobody measured.
		var head := widget.get_theme_stylebox("titlebar") as StyleBoxFlat
		if head == null or head.bg_color != plate \
				or head.border_width_bottom < 1 \
				or head.border_color != ModuleThemes.token(want, "edge"):
			unheaded.append("%s (%s)" % [id, want])
		var label: Label = main._title_label(widget)
		if label == null or label.get_theme_color("font_color") != legend:
			mistitled.append("%s (%s)" % [id, want])
		# The title is drawn twice in this editor — by the node's own Label, and by the
		# overlay that redraws it at a legible size once the zoom shrinks it too far.
		# Both have to know the style, or the colour changes as you turn the wheel.
		if PatchGraph.ScreenText.title_ink(widget) != legend:
			faint.append("%s (%s)" % [id, want])

		# And everything written on the plate. This is the half that made painting the
		# body wrong until it was done: port names, units and values are the editor's
		# own light ink, and a cream or mustard panel under them is unreadable. Measured
		# rather than assumed — the tokens have been right all along, twice, while what
		# was on screen was not.
		var lettering := _lettering(main, widget)
		if lettering.is_empty():
			unlettered.append("%s has nothing written on it" % id)
		for written: Label in lettering:
			var ink: Color = written.get_theme_color("font_color")
			if ink != legend:
				unlettered.append("%s: %s" % [id, written.text])
			if Design.contrast(ink, plate) < 4.5:
				unreadable.append("%s: %s on %s (%.2f)"
					% [id, written.text, want, Design.contrast(ink, plate)])

		# The dials are the rack's own control, and they take the rack's own skin.
		for knob in _knobs(widget):
			if str((knob.skin as Dictionary).get("panel", Color())) != str(plate):
				knobs_missed.append("%s (%s)" % [id, want])
				break
	check(unresolved.is_empty(), "%s: every module resolves to its own style%s"
		% [when, "" if unresolved.is_empty() else " — " + ", ".join(unresolved)])
	check(unpainted.is_empty(), "%s: every panel is painted its own faceplate%s"
		% [when, "" if unpainted.is_empty() else " — " + ", ".join(unpainted)])
	check(unheaded.is_empty(), "%s: every header is its own plate, ruled off below%s"
		% [when, "" if unheaded.is_empty() else " — " + ", ".join(unheaded)])
	check(mistitled.is_empty(), "%s: every title is lettered in its own legend%s"
		% [when, "" if mistitled.is_empty() else " — " + ", ".join(mistitled)])
	check(faint.is_empty(), "%s: and the zoomed-out title agrees with it%s"
		% [when, "" if faint.is_empty() else " — " + ", ".join(faint)])
	check(unlettered.is_empty(), "%s: and so is everything else written on the panel%s"
		% [when, "" if unlettered.is_empty() else " — " + ", ".join(unlettered)])
	check(unreadable.is_empty(), "%s: all of it readable against its own plate%s"
		% [when, "" if unreadable.is_empty() else " — " + ", ".join(unreadable)])
	check(knobs_missed.is_empty(), "%s: and the dials are wearing the skin too%s"
		% [when, "" if knobs_missed.is_empty() else " — " + ", ".join(knobs_missed)])


func _initialize() -> void:
	Settings.isolate()
	Design.use_palette(Design.Palette.LAB)
	Design.ui_scale = Design.Scale.COMFORTABLE
	Rack.density = Rack.Density.INSTRUMENT

	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	if not main.has_method("_set_module_theme") or main.graph_edit == null:
		print("  FAIL the editor did not build; look for a parse error above")
		quit(1)
		return

	print("panel styles")
	await main._load_example("First Synth")
	for i in 8:
		await process_frame

	var ids := _ids(main)
	check(ids.size() >= 4 and ids.size() <= ModuleThemes.ORDER.size(),
		"the patch has modules enough to tell the styles apart and few enough that no two share one (%d modules, %d styles)"
			% [ids.size(), ModuleThemes.ORDER.size()])

	# ---- every node a different style ------------------------------------------------
	_paint(main, 0)
	_verify(main, 0, "painted")

	# ---- and now they all move -------------------------------------------------------
	# Style to style, which is the direction that was failing: the widget already carries
	# an override, and replacing one is not the same path as adding the first.
	_paint(main, 1)
	_verify(main, 1, "rotated +1")

	_paint(main, -1)
	_verify(main, -1, "rotated -2")

	# ---- and they survive being looked at --------------------------------------------
	# Zoom first. The overlay takes the title over when it gets too small to read, so a
	# style that only lives on the Label vanishes at the far end of the zoom slider.
	for level in [0.18, 0.45, 1.0]:
		main.graph_edit.zoom = level
		for i in 3:
			await process_frame
		_verify(main, -1, "at %d%% zoom" % roundi(level * 100.0))
	main.graph_edit.zoom = 1.0
	await process_frame

	# Then the other two views. A style is a fact about the module, so leaving the graph
	# and coming back must not change one.
	await main._flip_container(true)
	for i in 8:
		await process_frame
	await main._show_graph()
	for i in 8:
		await process_frame
	_verify(main, -1, "back from the face")

	await main._show_schematic(true)
	for i in 8:
		await process_frame
	await main._show_graph()
	for i in 8:
		await process_frame
	_verify(main, -1, "back from the schematic")

	# ---- and the pointer going over them ---------------------------------------------
	# The reported fault, and the reason this suite grew a mouse. Hover and selection are
	# drawn by replacing the node's styleboxes, so a pass that knew nothing about panel
	# styles took the style off every node the pointer touched and put it back when the
	# pointer left. From the chair that reads as a style that will not stay on — and as
	# one that never arrived, since the pointer is sitting on the node you just picked a
	# style for.
	for id in ids:
		var hovered: GraphNode = main.widgets.get(str(id)) as GraphNode
		if hovered != null:
			hovered.mouse_entered.emit()
	await process_frame
	_verify(main, -1, "under the pointer")

	for id in ids:
		var left: GraphNode = main.widgets.get(str(id)) as GraphNode
		if left != null:
			left.mouse_exited.emit()
	await process_frame
	_verify(main, -1, "after the pointer leaves")

	# Selection is the same code with a different trigger, and a selected module is one
	# somebody is about to do something to — a bad moment to stop showing what it is.
	for id in ids:
		var picked: GraphNode = main.widgets.get(str(id)) as GraphNode
		if picked != null:
			picked.selected = true
			picked.mouse_entered.emit()
			picked.mouse_exited.emit()
	await process_frame
	_verify(main, -1, "selected")
	for id in ids:
		var dropped: GraphNode = main.widgets.get(str(id)) as GraphNode
		if dropped != null:
			dropped.selected = false
	await process_frame

	# ---- and being undone ------------------------------------------------------------
	# Every paint is a document edit, so the history walks back through them one at a
	# time. The view has to follow the document rather than keep the colour it last drew.
	main._undo()
	for i in 4:
		await process_frame
	var undone := str(main._panel_style_of(str(ids[ids.size() - 1])))
	check(undone == _expected(ids.size() - 1, 1),
		"undo puts the last module back to the style before it (%s)" % undone)
	main._redo()
	for i in 4:
		await process_frame
	_verify(main, -1, "redone")

	# ---- and being saved -------------------------------------------------------------
	main._capture_positions()
	var written := JSON.stringify(main.patch)
	await main._load_text(written)
	for i in 8:
		await process_frame
	_verify(main, -1, "reopened")

	# ---- and one of them going back to the patch's -----------------------------------
	# The odd one out, and the one that used to strip the title's own styling with it:
	# the default is the absence of an override, not a twelfth style.
	main._set_patch_theme("oxide-teal")
	main._set_module_theme(str(ids[0]), "")
	await process_frame
	check(str(main._panel_style_of(str(ids[0]))) == "oxide-teal",
		"a module put back on the patch's panels wears the patch's style")

	# And with the patch on no style either, which is the branch that undresses the node
	# completely. Worth saying why the patch style is cleared first: with one set, a
	# module put back on the patch's panels resolves to the patch's style and never
	# reaches this path at all — the first version of this check tested the line above
	# twice and called it two checks.
	main._set_patch_theme(ModuleThemes.CATEGORY)
	await process_frame
	check(str(main._panel_style_of(str(ids[0]))) == ModuleThemes.CATEGORY,
		"and with the patch on no style either, it wears none")
	var bare: GraphNode = main.widgets.get(str(ids[0])) as GraphNode
	if bare != null:
		var bare_title: Label = main._title_label(bare)
		check(bare_title != null and bare_title.has_theme_color_override("font_color"),
			"and it keeps a title colour of its own rather than losing its lettering")
		if bare_title != null:
			check(Design.contrast(bare_title.get_theme_color("font_color"),
				(bare.get_theme_stylebox("titlebar") as StyleBoxFlat).bg_color) >= 4.5,
				"which still reads against the header it is on")
		# The same colour an unpainted node has always had, rather than a new one that
		# happens to pass: every module that was never painted is wearing INK_BRIGHT, and
		# two defaults side by side is the inconsistency this suite exists to catch.
		var never_painted: GraphNode = main.widgets.get(str(ids[1])) as GraphNode
		var other_title: Label = main._title_label(never_painted) 			if never_painted != null else null
		if bare_title != null and other_title != null:
			main._set_module_theme(str(ids[1]), "")
			await process_frame
			check(bare_title.get_theme_color("font_color")
					== other_title.get_theme_color("font_color"),
				"and two unpainted modules are lettered alike")

	if failures == 0:
		print("all panel style checks passed")
	else:
		print("%d panel style check(s) failed" % failures)
	quit(1 if failures > 0 else 0)
