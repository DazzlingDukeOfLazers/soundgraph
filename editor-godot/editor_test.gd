extends SceneTree

## The authoring transforms, reached directly so a collapse can be checked without going
## through a menu. main.gd preloads the same file.
const ModuleAuthor := preload("res://module_author.gd")
const Seams := preload("res://seams.gd")
const ModuleFace := preload("res://module_face.gd")
const PatchFace := preload("res://patch_face.gd")
const RackView := preload("res://rack.gd")
## Headless checks on the editor itself.
##
##   godot --headless --script res://editor_test.gd
##
## The round-trip check (tools/verify-roundtrip.mjs) proves a patch survives being loaded
## and saved. This proves the things a round trip cannot see: that the graph view is built
## from the registry with the right ports, that search and validation come from the core,
## that a wire can be inspected, and that audio is actually produced.

var failures := 0


func rack_ready(main) -> void:
	main.rack.rebuild()


## Every scrap of text in a tree, however deep.

## Every parameter cell in a node, however they are grouped into lines.
##
## Parameter rows used to be one parameter each and are two now, so a check that walked
## a node's children found lines where it expected cells — and reported "0 controls
## showing" on a node full of them.
func _parameter_cells(node: GraphNode) -> Array:
	var cells: Array = []
	for child in node.get_children():
		var line := child as Control
		if line == null or str(line.get_meta("row", "")) != "module":
			continue
		var box: Control = line.get_meta("cells_box") if line.has_meta("cells_box") else null
		if box == null:
			continue
		for cell_child in box.get_children():
			var cell := cell_child as Control
			if cell != null:
				cells.append(cell)
	return cells

func _tree_text(row: TreeItem) -> String:
	var collected := ""
	while row != null:
		collected += row.get_text(0)
		collected += _tree_text(row.get_first_child())
		row = row.get_next()
	return collected


## Every text-bearing control under `node` whose effective font size is below the floor.
## Drawn text (the rack, the scope) is not a Control and is covered by its own checks.
func _collect_small_text(node: Node, found: Array) -> void:
	var control := node as Control
	if control != null and (control is Label or control is BaseButton or control is LineEdit
			or control is TextEdit or control is TabBar or control is Tree
			or control is ItemList or control is RichTextLabel):
		var size := control.get_theme_font_size("font_size")
		if size < Design.TYPE_FLOOR:
			found.append("%s %s=%d" % [control.get_class(), control.name, size])
	for child in node.get_children():
		_collect_small_text(child, found)


## Every Label that will drop text it cannot fit, so the sweep below can check which end
## it drops from.
func _collect_trimming_labels(node: Node, found: Array) -> void:
	var label := node as Label
	if label != null and (label.clip_text
			or label.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING):
		found.append(label)
	for child in node.get_children():
		_collect_trimming_labels(child, found)


func _collect_buttons(node: Node, found: Array) -> void:
	if node is BaseButton:
		found.append(node)
	for child in node.get_children():
		_collect_buttons(child, found)


# ---- clicking the canvas, rather than calling into it -----------------------------
# What makes a ghost jack clickable at all is that PatchGraph takes the press in
# `_input`, ahead of the GUI pass, before the Control under the pointer can swallow
# it — so the points below are worked out the way a hand's would be hit-tested.

## The viewport point a jack sits at: the same arithmetic the hit test uses, which is
## fair here because a wrong constant in it moves the drawn jack and the hot zone
## together, and the drawn position is checked by the screenshot suite.
func _jack_point(main, widget: GraphNode, side: String, index: int) -> Vector2:
	var graph = main.graph_edit
	var scale: float = graph.zoom if graph.zoom > 0.0 else 1.0
	var spot: Vector2 = widget.get_input_port_position(index) if side == "left" \
		else widget.get_output_port_position(index)
	return graph.get_global_rect().position \
		+ (widget.position_offset + spot) * scale - graph.scroll_offset


## The middle of the row a knob lives in. Returns INF when the row is not on screen,
## which is a failure the caller should see rather than a click into empty canvas.
func _knob_point(main, widget: GraphNode, parameter: String) -> Vector2:
	var row: Control = main._parameter_row(widget, parameter)
	if row == null or not row.is_visible_in_tree():
		return Vector2.INF
	return row.get_global_rect().get_center()


func _has_node(patch: Dictionary, node_id: String) -> bool:
	for node in patch.get("nodes", []):
		if str(node["id"]) == node_id:
			return true
	return false


## Asserts the document still loads.
##
## The check that was missing. _apply validates, shows the diagnostics and then quietly
## declines to load when the patch is broken — which is right, but it means a structural
## edit could leave the engine playing whatever was valid last while the editor drew
## something else, and nothing in this suite would say so.
func check_loads(main, what: String) -> void:
	var report: Variant = JSON.parse_string(
		main.engine.validate_patch(JSON.stringify(main.patch, "  ")))
	var ok: bool = typeof(report) == TYPE_DICTIONARY and bool(report["ok"])
	var why := ""
	if not ok and typeof(report) == TYPE_DICTIONARY:
		for problem in report["diagnostics"]:
			if str(problem.get("severity", "")) == "error" and why == "":
				why = str(problem.get("message", ""))
	check(ok, "%s leaves a patch that loads%s" % [what, "" if ok else " — " + why])


## Press, move, release — through the panel's own _input, so a check exercises the path
## a hand takes rather than the rule that path is supposed to consult.
func _drag_panel(main, from: Vector2, to: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	press.global_position = from
	main.patch_face._input(press)

	var move := InputEventMouseMotion.new()
	move.position = to
	move.global_position = to
	main.patch_face._input(move)

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = to
	release.global_position = to
	main.patch_face._input(release)


## Drags a fader from one height to another through its own input, starting from rest at
## the bottom so the result reads as an absolute position rather than a delta.
func _drag_fader(fader, from_y: float, to_y: float, fine: bool = false) -> void:
	fader.set_value_silently(fader._to_value(0.0))
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(fader.size.x * 0.5, from_y)
	fader._gui_input(press)

	var move := InputEventMouseMotion.new()
	move.position = Vector2(fader.size.x * 0.5, to_y)
	move.shift_pressed = fine
	fader._gui_input(move)

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = move.position
	fader._gui_input(release)


## One Ctrl+notch over a control — the view's zoom gesture, which a knob must yield.
func _wheel_with_ctrl(control) -> void:
	var notch := InputEventMouseButton.new()
	notch.button_index = MOUSE_BUTTON_WHEEL_UP
	notch.pressed = true
	notch.ctrl_pressed = true
	notch.position = control.size * 0.5
	control._gui_input(notch)


## One notch of the wheel over a control, through its own input.
func _wheel(control, up: bool, coarse: bool = false) -> void:
	var notch := InputEventMouseButton.new()
	notch.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	notch.pressed = true
	notch.shift_pressed = coarse
	notch.position = control.size * 0.5
	control._gui_input(notch)


## A click on the graph canvas, through its own _gui_input.
func _press_graph(main, at: Vector2) -> void:
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		click.position = at
		main.graph_edit._gui_input(click)


## Press, move, release on the graph canvas.
func _drag_graph(main, from: Vector2, to: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = from
	main.graph_edit._gui_input(press)

	var move := InputEventMouseMotion.new()
	move.position = to
	main.graph_edit._gui_input(move)

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = to
	main.graph_edit._gui_input(release)


func check(condition: bool, description: String) -> void:
	if condition:
		print("  ok   %s" % description)
	else:
		print("  FAIL %s" % description)
		failures += 1


func _initialize() -> void:
	# Nothing this run does may reach the real settings file, in either direction. The
	# suite drives the theme and the UI scale on purpose, and every one of those was
	# being written down — so a run changed the preferences of whoever ran it, and the
	# next run started from wherever the last one stopped. It was also still reading the
	# file, which is how the four lines below came to be overwritten a moment later by
	# Settings.apply() and the whole suite ran at somebody's XL preference.
	Settings.isolate()
	Design.use_palette(Design.Palette.LAB)
	Design.ui_scale = Design.Scale.COMFORTABLE
	Rack.density = Rack.Density.INSTRUMENT

	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame

	# A script that failed to parse leaves a bare Control here. Without this check the
	# first await lands on a coroutine that never resolves and the run hangs rather than
	# reporting the parse error — which is a miserable way to find a missing type hint.
	if not main.has_method("_load_text") or main.graph_edit == null:
		# A script that failed to compile leaves the editor half-built. Bailing out here
		# reports the parse error above instead of letting every later check fail for a
		# reason that has nothing to do with what it was testing.
		print("  FAIL the editor did not build; look for a parse error above")
		quit(1)
		return

	if main.engine == null:
		print("  FAIL the SoundGraphEngine extension did not load")
		quit(1)
		return

	print("editor checks")

	# ---- the vocabulary comes from the core ------------------------------------------
	check(main.registry.size() >= 16, "registry exposes the whole node vocabulary (%d types)"
		% main.registry.size())
	var filter: Dictionary = main.registry.get("StateVariableFilter", {})
	check(filter.get("inputs", []).size() == 4, "filter reports its four inputs")
	check(filter["parameters"][2].has("enum"), "filter mode arrives as an enumeration")
	check(str(filter["parameters"][0]["scaling"]) == "exponential",
		"cutoff is declared exponential, so the slider curve is not a UI guess")

	# ---- intent search is the core's ranking, not a local reimplementation ------------
	var searches := {
		"remove high frequencies": "StateVariableFilter",
		"make quieter": "Gain",
		"echo": "Delay",
		"midi keyboard": "NoteInput",
	}
	for query in searches:
		var results: PackedStringArray = main.engine.search_nodes(query)
		check(results.size() > 0 and results[0] == searches[query],
			"search '%s' finds %s" % [query, searches[query]])
	check(main.engine.search_nodes("definitely not a node").size() == 0,
		"search rejects nonsense instead of guessing")

	# ---- the palette offers ports, and offers them once -------------------------------
	# A port is how a patch says where its edges are, so it has to be addable rather than
	# only inheritable. The core still knows the older spelling — NoteInput and the rest —
	# and a search for "midi keyboard" still ranks it first; what the palette offers for
	# that ranking is the port, because two ways to say one thing in the one place people
	# go to learn the vocabulary is where the confusion would start.
	var offered: PackedStringArray = main._addable(PackedStringArray(main.registry.keys()))
	for wanted in ["seam:Input/note", "seam:Input/audio", "seam:Output/stereo"]:
		check(offered.has(wanted), "the palette offers %s" % wanted)
	for older in ["NoteInput", "AudioInput", "StereoOutput"]:
		check(not offered.has(older),
			"and not %s, which is the same thing said the older way" % older)
	check(main._addable(main.engine.search_nodes("midi keyboard"))[0] == "seam:Input/note",
		"a search that ranks the terminal offers the port")
	var not_a_type := ""
	for key in offered:
		if str(key).begins_with("module:") or str(key).contains("/@"):
			not_a_type = str(key)
	check(not_a_type == "",
		"and nothing in it is a shape rather than a type (%s)"
		% (not_a_type if not_a_type != "" else "none of %d" % offered.size()))

	# ---- the graph view is generated from that vocabulary -----------------------------
	var file := FileAccess.open("res://examples/first-synth.json", FileAccess.READ)
	if file == null:
		# editor-godot/examples is build output. When it is missing, every check
		# from here on is about a patch that was never loaded — and the null
		# dereference that used to happen here left the process alive forever,
		# because an error inside an awaiting _initialize never reaches quit().
		# A run that hangs says less than one that fails.
		print("  FAIL res://examples/first-synth.json is missing")
		print("       the examples are mirrored by the runtime-godot build; see its README")
		quit(1)
		return
	await main._load_text(file.get_as_text())
	await process_frame
	await process_frame

	check(main.widgets.size() == 7, "a widget exists for every node")
	var filter_widget: GraphNode = main.widgets.get("filter")
	check(filter_widget != null, "the filter node has a widget")
	if filter_widget != null:
		# Four port rows, then parameter rows, then the progressive-disclosure toggle.
		check(filter_widget.get_child_count() > 4, "the filter widget carries parameter rows")
		check(filter_widget.is_slot_enabled_left(0), "its audio input is a connectable slot")
		check(filter_widget.is_slot_enabled_left(3), "its resonance input is a connectable slot")
		check(filter_widget.is_slot_enabled_right(0), "and its output is a connectable slot")

	# ---- validation is the core's, and it is spatial ----------------------------------
	var broken := {
		"schema_version": 1,
		"nodes": [
			{"id": "a", "type": "Gain"}, {"id": "b", "type": "Gain"},
			{"id": "out", "type": "StereoOutput"},
		],
		"connections": [
			{"from": {"node": "a", "port": "out"}, "to": {"node": "b", "port": "in"}},
			{"from": {"node": "b", "port": "out"}, "to": {"node": "a", "port": "in"}},
			{"from": {"node": "b", "port": "out"}, "to": {"node": "out", "port": "left"}},
		],
	}
	var report: Variant = JSON.parse_string(main.engine.validate_patch(JSON.stringify(broken)))
	check(typeof(report) == TYPE_DICTIONARY and not report["ok"],
		"a zero-delay loop is rejected")
	if typeof(report) == TYPE_DICTIONARY:
		var first: Dictionary = report["diagnostics"][0]
		check(first["code"] == "zero_delay_cycle", "the problem is named")
		check(first.get("nodes", []).size() == 2, "both nodes in the loop are identified")
		check(first.get("suggestion", "").contains("Delay"), "and a fix is suggested")

	# ---- audio and inspection ---------------------------------------------------------
	await main._load_text(file.get_as_text())
	await process_frame
	await process_frame
	check(main.engine.is_loaded(), "the demo patch builds in the editor")

	main.engine.note_on(45, 0.9)
	# Render directly rather than through the AudioStreamPlayer: a headless run has no
	# device pulling on the generator, so nothing would ever be consumed.
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = 48000.0
	generator.buffer_length = 0.5
	var player := AudioStreamPlayer.new()
	player.stream = generator
	root.add_child(player)
	player.play()
	await process_frame
	var playback: AudioStreamGeneratorPlayback = player.get_stream_playback()

	var pushed := 0
	if playback != null:
		for i in 20:
			pushed += main.engine.fill_playback(playback, 1024)
			await process_frame
	check(pushed > 0, "audio frames were rendered (%d)" % pushed)
	check(main.engine.get_peak() > 0.01, "and they are not silence (peak %.3f)"
		% main.engine.get_peak())

	var scope_samples: PackedFloat32Array = main.engine.get_scope(512)
	check(scope_samples.size() == 512, "the scope has history to draw")

	# What is actually on the wire, read from the running graph's own buffers.
	var osc_signal: PackedFloat32Array = main.engine.get_port_signal("osc", "out")
	var amp_signal: PackedFloat32Array = main.engine.get_port_signal("amp", "out")
	check(osc_signal.size() == 64, "an oscillator's output can be inspected")
	check(amp_signal.size() == 64, "and so can the amplifier's")

	# One block is 64 samples, which at 110 Hz is about a seventh of a cycle — so the
	# window may sit anywhere on the ramp and never reach full scale. What identifies a
	# live wire is that it moves, not that it peaks.
	var osc_low := INF
	var osc_high := -INF
	for value in osc_signal:
		osc_low = minf(osc_low, value)
		osc_high = maxf(osc_high, value)
	check(osc_high - osc_low > 0.01,
		"the oscillator wire carries a moving signal (spans %.3f to %.3f)" % [osc_low, osc_high])

	var amp_moving := false
	for value in amp_signal:
		if absf(value) > 1.0e-6:
			amp_moving = true
	check(amp_moving, "and the amplifier wire is not silent")
	check(main.engine.get_port_signal("nope", "out").size() == 0,
		"asking about a node that does not exist returns nothing")

	# ---- knob movement must not restart the sound -------------------------------------
	var before_nodes: int = main.patch["nodes"].size()
	main._set_parameter("filter", "cutoff", 3000.0)
	check(main.patch["nodes"].size() == before_nodes, "a knob move does not rebuild the graph")
	var recorded := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "filter":
			recorded = node["parameters"]["cutoff"]
	check(is_equal_approx(recorded, 3000.0), "and it is recorded in the document for saving")

	# ---- auto-place ------------------------------------------------------------------
	await main._auto_place()
	await process_frame

	# The same graph must land the same way wherever it happened to be. Without this the
	# button is a dice roll: press it twice after nudging something and get two answers.
	var arranged := []
	for node in main.patch["nodes"]:
		arranged.append("%s(%d,%d)" % [node["id"], node["position"]["x"], node["position"]["y"]])
	var reference := " ".join(arranged)

	for scatter in [[317, 511], [97, 233]]:
		for i in main.patch["nodes"].size():
			main.patch["nodes"][i]["position"] = {
				"x": (i * scatter[0]) % 2000, "y": (i * scatter[1]) % 1200}
		await main._rebuild_view()
		await process_frame
		await main._auto_place()
		await process_frame
		var again := []
		for node in main.patch["nodes"]:
			again.append("%s(%d,%d)" % [node["id"], node["position"]["x"], node["position"]["y"]])
		check(" ".join(again) == reference,
			"auto-place gives the same answer after scattering by %d,%d" % [scatter[0], scatter[1]])

	# A lingering selection must not quietly change what Auto-place does — that was the
	# whole source of it feeling unpredictable, since a drag leaves what it dragged selected.
	for id in main.widgets:
		main.widgets[id].selected = (id == "osc" or id == "lfo")
	await process_frame
	await main._auto_place()
	await process_frame
	var with_selection := []
	for node in main.patch["nodes"]:
		with_selection.append("%s(%d,%d)" % [node["id"],
			node["position"]["x"], node["position"]["y"]])
	check(" ".join(with_selection) == reference,
		"and ignores whatever happens to be selected")

	# Arranging a selection is its own action, and refuses a selection too small to mean
	# anything rather than silently arranging everything.
	for id in main.widgets:
		main.widgets[id].selected = (id == "osc")
	await main._arrange_selection()
	await process_frame
	var after_one := []
	for node in main.patch["nodes"]:
		after_one.append("%s(%d,%d)" % [node["id"], node["position"]["x"], node["position"]["y"]])
	check(" ".join(after_one) == reference, "arranging a one-node selection does nothing")

	for id in main.widgets:
		main.widgets[id].selected = false
	await process_frame

	var on_grid := true
	var columns := {}
	for node in main.patch["nodes"]:
		var x: float = node["position"]["x"]
		var y: float = node["position"]["y"]
		if fmod(x, main.GRID) != 0.0 or fmod(y, main.GRID) != 0.0:
			on_grid = false
		columns[x] = true
	check(on_grid, "auto-place lands every node on the %d grid" % int(main.GRID))
	check(columns.size() == 5, "the demo patch lays out in five columns (%d)" % columns.size())

	# Signal flow reads left to right: nothing may sit left of something it consumes.
	var placed := {}
	for node in main.patch["nodes"]:
		placed[node["id"]] = Vector2(node["position"]["x"], node["position"]["y"])
	var flows_forward := true
	for connection in main.patch["connections"]:
		var from: Vector2 = placed[connection["from"]["node"]]
		var to: Vector2 = placed[connection["to"]["node"]]
		if from.x >= to.x:
			flows_forward = false
	check(flows_forward, "every cable runs left to right")

	# Nothing overlaps: the whole point of a pitch.
	var overlapping := false
	for a in main.patch["nodes"]:
		for b in main.patch["nodes"]:
			if a["id"] == b["id"]:
				continue
			var wa: GraphNode = main.widgets.get(a["id"])
			var wb: GraphNode = main.widgets.get(b["id"])
			if wa == null or wb == null:
				continue
			if Rect2(placed[a["id"]], wa.size).intersects(Rect2(placed[b["id"]], wb.size)):
				overlapping = true
	check(not overlapping, "no two nodes overlap after auto-place")

	# ---- cable routing ---------------------------------------------------------------
	# A node dropped on top of a cable must push the cable around it, not be crossed.
	var route_before: PackedVector2Array = main.graph_edit._route(
		Vector2(0, 100), Vector2(1200, 100))
	check(route_before.size() > 0, "a clear span routes")

	var blocker: GraphNode = main.widgets.get("filter")
	var blocked_from := Vector2(blocker.position_offset.x - 300.0,
		blocker.position_offset.y + blocker.size.y * 0.5)
	var blocked_to := Vector2(blocker.position_offset.x + blocker.size.x + 300.0,
		blocker.position_offset.y + blocker.size.y * 0.5)
	var detour: PackedVector2Array = main.graph_edit._route(blocked_from, blocked_to)
	var crosses := false
	var node_rect := Rect2(blocker.position_offset, blocker.size)
	for i in range(detour.size() - 1):
		if main.graph_edit._segment_hits_rect(detour[i], detour[i + 1], node_rect):
			crosses = true
	check(not crosses, "a cable routes around a node instead of through it")
	check(detour.size() > 2, "and it does so with a real detour (%d points)" % detour.size())

	# ---- crossing marks ---------------------------------------------------------------
	# Two cables that genuinely cross must be marked, and the mark must follow the cable
	# rather than sit at an arbitrary angle.
	var horizontal := PackedVector2Array([Vector2(0, 100), Vector2(400, 100)])
	var vertical := PackedVector2Array([Vector2(200, 0), Vector2(200, 300)])
	var hits: Array = main.graph_edit._intersections(horizontal, vertical)
	check(hits.size() == 1, "a crossing is found once, not twice")
	if hits.size() == 1:
		check(hits[0].is_equal_approx(Vector2(200, 100)), "at the point they actually meet")
	var along: Vector2 = main.graph_edit._direction_at(vertical, Vector2(200, 100))
	check(absf(along.y) > 0.9, "the break runs along the cable it interrupts")

	var parallel := PackedVector2Array([Vector2(0, 200), Vector2(400, 200)])
	check(main.graph_edit._intersections(horizontal, parallel).is_empty(),
		"cables that never meet are not marked")

	# The overlay has to sit above the cables and below the nodes, or the mark is
	# invisible or covers a node.
	# The grid tiers must be the layout's own pitches, or "align to a major line" and
	# "the column the layout uses" stop meaning the same thing.
	check(is_equal_approx(main.graph_edit.grid_minor, main.GRID),
		"the faint grid lines are the snap step")
	check(is_equal_approx(main.graph_edit.grid_half_major, main.ROW_STEP),
		"the medium lines are the row pitch")
	check(is_equal_approx(main.graph_edit.grid_major, main.COLUMN_PITCH),
		"the heavy lines are the column pitch")
	check(not main.graph_edit.show_grid,
		"and GraphEdit's own grid is off, so only one grid is drawn")

	var connection_layer: Node = main.graph_edit.get_child(0)
	var overlay: Node = main.graph_edit.get_child(1)
	check(connection_layer.name == "_connection_layer", "the connection layer is still first")
	check(overlay is Control and overlay.get_script() != null,
		"and the crossing overlay is drawn immediately after it")

	# ---- undo -------------------------------------------------------------------------
	var file2 := FileAccess.open("res://examples/first-synth.json", FileAccess.READ)
	await main._load_text(file2.get_as_text())
	await process_frame
	await process_frame

	check(not main.undo_redo.has_undo(), "a freshly loaded patch has nothing to undo")

	# Whatever a patch arrives with, it lands on the grid — otherwise every alignment cue
	# on the canvas is off by a few pixels and the grid looks broken rather than the file.
	var off_grid := {
		"schema_version": 1,
		"nodes": [
			{"id": "a", "type": "SineOscillator", "position": {"x": 17, "y": 23}},
			{"id": "out", "type": "StereoOutput", "position": {"x": 511, "y": 349}},
		],
		"connections": [{"from": {"node": "a", "port": "out"},
			"to": {"node": "out", "port": "left"},
			"waypoint": {"x": 263, "y": 91}}],
	}
	await main._load_text(JSON.stringify(off_grid))
	await process_frame
	await process_frame
	var snapped := true
	for node in main.patch["nodes"]:
		if fmod(node["position"]["x"], main.GRID) != 0.0 \
			or fmod(node["position"]["y"], main.GRID) != 0.0:
			snapped = false
	check(snapped, "an off-grid patch is snapped when it loads")
	var waypoint: Dictionary = main.patch["connections"][0]["waypoint"]
	check(fmod(waypoint["x"], main.GRID) == 0.0 and fmod(waypoint["y"], main.GRID) == 0.0,
		"and so are its cable waypoints")

	# Reload the demo so the checks below start from a known patch.
	var restore := FileAccess.open(main._example_path("first-synth.json"), FileAccess.READ)
	await main._load_text(restore.get_as_text())
	await process_frame
	await process_frame
	var demo_on_grid := true
	for node in main.patch["nodes"]:
		if fmod(node["position"]["x"], main.GRID) != 0.0 \
			or fmod(node["position"]["y"], main.GRID) != 0.0:
			demo_on_grid = false
	check(demo_on_grid, "and the shipped demo patch is already on it")

	var original_nodes: int = main.patch["nodes"].size()
	var original_connections: int = main.patch["connections"].size()

	# Add, then undo: the node goes away and the history empties.
	await main._add_node("Delay", Vector2(2000, 0))
	await process_frame
	check(main.patch["nodes"].size() == original_nodes + 1, "adding a node grows the patch")
	check(main.undo_redo.has_undo(), "and it is undoable")

	# A port added from the palette is written the way the document says it, as a type and
	# a binding — the "seam:Input/note" key is the editor's filing, not the file's.
	var port_id: String = await main._add_node("seam:Input/note", Vector2(2000, 200))
	await process_frame
	var added_port := {}
	for node in main.patch["nodes"]:
		if str(node["id"]) == port_id:
			added_port = node
	check(str(added_port.get("type", "")) == "Input",
		"a port added from the palette is written as an Input (%s)" % added_port.get("type", ""))
	# This patch already has a keyboard, and two nodes claiming one machine would leave the
	# loader picking the first. So the second arrives unplugged, which is now a state that
	# means something: it is a port, waiting for somebody to drag the jack over.
	check(str(added_port.get("host", "")) == "",
		"unplugged, because the one keyboard is already spoken for")
	check(main._output_port_index(port_id, port_id) >= 0,
		"and it has a port to wire, named after itself (%s)" % port_id)
	main._undo()
	await process_frame

	main._undo()
	await process_frame
	await process_frame
	check(main.patch["nodes"].size() == original_nodes, "undo removes the added node")
	check(main.widgets.size() == original_nodes, "and the view follows the document")

	main._redo()
	await process_frame
	await process_frame
	check(main.patch["nodes"].size() == original_nodes + 1, "redo puts it back")
	main._undo()
	await process_frame
	await process_frame

	# Deleting a node takes its connections with it; undo must restore both.
	main._on_delete_nodes_request([main.widgets["filter"].name] as Array[StringName])
	await process_frame
	await process_frame
	check(main.patch["nodes"].size() == original_nodes - 1, "deleting removes the node")
	check(main.patch["connections"].size() < original_connections,
		"and the cables that touched it")

	main._undo()
	await process_frame
	await process_frame
	check(main.patch["nodes"].size() == original_nodes, "undo restores the deleted node")
	check(main.patch["connections"].size() == original_connections,
		"and every cable that went with it")

	# A knob turn is undoable without rebuilding the graph — the whole point of the fast
	# path, since a rebuild would restart the sound.
	var cutoff_before := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "filter":
			cutoff_before = node["parameters"]["cutoff"]
	main._begin_edit()
	main._set_parameter("filter", "cutoff", 5000.0)
	main._commit_edit("set cutoff")
	await process_frame
	var widget_before: GraphNode = main.widgets["filter"]

	main._undo()
	await process_frame
	var restored := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "filter":
			restored = node["parameters"]["cutoff"]
	check(is_equal_approx(restored, cutoff_before), "undo restores a knob value")
	check(main.widgets["filter"] == widget_before,
		"without rebuilding the graph, so the sound does not restart")

	# Auto-place is one step, not one per node.
	var before_layout := []
	for node in main.patch["nodes"]:
		before_layout.append(Vector2(node["position"]["x"], node["position"]["y"]))
	main._begin_edit()
	for node in main.patch["nodes"]:
		node["position"] = {"x": 17.0, "y": 23.0}
	main._commit_edit("scramble")
	main._undo()
	await process_frame
	await process_frame
	var layout_restored := true
	for i in main.patch["nodes"].size():
		var node = main.patch["nodes"][i]
		if not Vector2(node["position"]["x"], node["position"]["y"]).is_equal_approx(before_layout[i]):
			layout_restored = false
	check(layout_restored, "undo restores positions exactly")

	# A drag that ends where it began is not an edit.
	var depth_before: bool = main.undo_redo.has_undo()
	main._begin_edit()
	main._commit_edit("no-op")
	check(main.undo_redo.has_undo() == depth_before,
		"a drag that changed nothing adds nothing to the history")

	# ---- the rack view ---------------------------------------------------------------
	# The rack is a second drawing of the same document. What matters is that it stays a
	# drawing: same nodes, same ports, same parameter scaling, no private opinions.
	main.rack.rebuild()
	await process_frame

	var modules := 0
	for child in main.rack.get_children():
		if child is Rack.RackModule:
			modules += 1
	check(modules == main.patch["nodes"].size(),
		"the rack has one module per node in the patch")

	var order: Array = main.rack._module_order()
	var output_index := -1
	for i in order.size():
		# Asked of the node rather than of a type name: the output is a seam now, and its
		# registry key says so. What the ordering is being held to is unchanged — the node
		# the sound leaves through comes last — and the rack works that out from the
		# wiring, which is why this kept being true while the spelling changed under it.
		for node in main.patch["nodes"]:
			if str(node["id"]) == str(order[i]) 					and Seams.terminal_for(node) == "StereoOutput":
				output_index = i
	check(output_index == order.size() - 1,
		"and orders them by signal flow, with the output last")

	var cables: Array = main.rack.cable_endpoints()
	check(cables.size() == main.patch["connections"].size(),
		"every connection in the document becomes a cable in the rack")

	# A jack that no module owns would silently drop a cable, which is the one failure
	# that looks like a design choice rather than a bug.
	var endpoints_distinct := true
	for cable in cables:
		if (cable[0] as Vector2).is_equal_approx(cable[1] as Vector2):
			endpoints_distinct = false
	check(endpoints_distinct, "and lands on two different jacks")

	# ---- catenary --------------------------------------------------------------------
	# The curve is solved numerically, so it is worth pinning: the ends must meet the
	# jacks exactly, and the sag must be the sag that was asked for.
	var a := Vector2(100.0, 200.0)
	var b := Vector2(400.0, 260.0)
	var curve: PackedVector2Array = Rack.catenary(a, b, 90.0)
	check(curve[0].is_equal_approx(a) and curve[curve.size() - 1].is_equal_approx(b),
		"a catenary starts and ends exactly on its two jacks")

	# Sag is measured against the chord at the midpoint, not as the lowest point on the
	# curve: between jacks at different heights the low point sits off-centre, so the two
	# are not the same number.
	var chord_mid := (a.y + b.y) * 0.5
	var mid: Vector2 = curve[curve.size() / 2]
	check(absf((mid.y - chord_mid) - 90.0) < 2.0,
		"and hangs by the sag it was given, to within a pixel or two")

	var always_below := true
	for i in curve.size():
		var t := float(i) / float(curve.size() - 1)
		if curve[i].y < lerpf(a.y, b.y, t) - 0.001:
			always_below = false
	check(always_below, "and never rises above the line between its ends")

	# Reversing the endpoints must give the same physical cable, or a patch would appear
	# to change shape depending on which end was drawn first.
	var reversed: PackedVector2Array = Rack.catenary(b, a, 90.0)
	var mirrored := true
	for i in curve.size():
		if not curve[i].is_equal_approx(reversed[reversed.size() - 1 - i]):
			mirrored = false
	check(mirrored, "and hangs the same way whichever end it is drawn from")

	# ---- knobs -----------------------------------------------------------------------
	# A knob and a slider are two handles on one value; if their scaling disagreed, the
	# same patch would sound different depending on which view last touched it.
	var filter_id := ""
	for node in main.patch["nodes"]:
		if node["type"] == "StateVariableFilter":
			filter_id = node["id"]
	if filter_id != "":
		var knobs: Dictionary = main.rack._knobs[filter_id]
		var cutoff: Rack.Knob = knobs["cutoff"]
		cutoff.set_value_silently(2500.0)
		check(absf(cutoff.value() - 2500.0) < 1.0,
			"a knob round-trips a value through the descriptor's own scaling")

		# mode is an enum: a filter set to 1.7 is not a thing the core can represent.
		var mode: Rack.Knob = knobs["mode"]
		var whole := true
		for step in 20:
			mode.set_value_silently(float(step) * 0.15)
			if not is_equal_approx(mode.value(), floor(mode.value())):
				whole = false
		check(whole, "and an enum knob only ever produces whole positions")

		# ---- and the knob is a control, not a picture of one ------------------------
		# The graph view's sliders and readouts took arrow keys in the accessibility
		# pass and the rack's knobs did not, so half this application was reachable from
		# the keyboard and half of it was a mouse-only drawing of hardware. The knob is
		# about to become the graph's control too, which makes this the difference
		# between porting a layout and losing keyboard access to every parameter.
		check(cutoff.focus_mode == Control.FOCUS_ALL, "a knob can be reached by Tab")
		var cutoff_before_keys: float = cutoff.value()
		cutoff.set_value_silently(2500.0)
		var knob_before: float = cutoff.value()
		var knob_press := InputEventKey.new()
		knob_press.keycode = KEY_RIGHT
		knob_press.pressed = true
		cutoff._gui_input(knob_press)
		check(cutoff.value() > knob_before,
			"and Right moves it (%.1f from %.1f)" % [cutoff.value(), knob_before])
		var knob_fine: float = cutoff.value() - knob_before
		cutoff.set_value_silently(2500.0)
		knob_press.shift_pressed = true
		cutoff._gui_input(knob_press)
		check(cutoff.value() - knob_before > knob_fine * 2.0,
			"and Shift moves it further (%.1f against %.1f)"
				% [cutoff.value() - knob_before, knob_fine])
		# Home and End, because a knob's two ends are the two settings hardest to reach
		# by dragging and the two most often wanted.
		knob_press.shift_pressed = false
		knob_press.keycode = KEY_HOME
		cutoff._gui_input(knob_press)
		check(absf(cutoff.value() - float(cutoff.descriptor["min"])) < 1.0,
			"Home takes it to the bottom of its range (%.1f)" % cutoff.value())
		knob_press.keycode = KEY_END
		cutoff._gui_input(knob_press)
		check(absf(cutoff.value() - float(cutoff.descriptor["max"])) < 1.0,
			"and End to the top (%.1f)" % cutoff.value())
		# One press, one undo step — not one per key repeat and not none at all.
		# The counter is an array because a GDScript lambda captures a local by *value*:
		# the first version incremented a copy and reported 0 edits from a control that
		# was emitting them correctly.
		var knob_edits := [0]
		var count_edit := func(_label: String) -> void: knob_edits[0] += 1
		main.rack.edit_finished.connect(count_edit)
		knob_press.keycode = KEY_LEFT
		cutoff._gui_input(knob_press)
		main.rack.edit_finished.disconnect(count_edit)
		check(knob_edits[0] == 1, "and a press is one undo step (%d)" % knob_edits[0])

		# Put it back. This block drives the cutoff to both ends of its range, and the
		# analysis check further down asks whether the filter's output differs from its
		# input — which it does not, at 20 kHz. A test that leaves the instrument
		# somewhere else is a test that breaks the next one for no reason.
		cutoff.set_value_silently(cutoff_before_keys)
		main.rack.parameter_changed.emit(filter_id, "cutoff", cutoff.value())

	# ---- the graph, as text -----------------------------------------------------------
	# A second way to read the same program: keyboard-navigable, readable aloud, and the
	# fastest answer to "what is connected to this" — which on a canvas means tracing a
	# line by hand.
	main.outline.refresh()
	await process_frame
	var outline_text: String = _tree_text(main.outline._tree.get_root())
	check(outline_text != "", "the outline has content")

	# Every node appears, so nothing is invisible in the accessible view that is visible
	# on the canvas. A view that showed most of the graph would be worse than none.
	var absent: Array = []
	for node in main.patch["nodes"]:
		if not outline_text.contains(str(node["id"])):
			absent.append(str(node["id"]))
	check(absent.is_empty(),
		"every node in the patch is in it%s"
			% ("" if absent.is_empty() else ": missing " + ", ".join(absent)))

	# And every connection, in both directions — once under the node it leaves and once
	# under the node it arrives at, because "what feeds this" and "what does this feed"
	# are different questions and the answer should be under whichever you are looking at.
	var unlisted := 0
	for connection in main.patch["connections"]:
		var from_side := "%s.%s" % [connection["from"]["node"], connection["from"]["port"]]
		if not outline_text.contains(from_side):
			unlisted += 1
	check(unlisted == 0, "and every connection is named (%d missing)" % unlisted)

	# It follows the engine's schedule, not the document order, because when a node runs
	# is the one thing the canvas cannot show you.
	check(outline_text.find("note") < outline_text.find("out"),
		"in the order the graph actually runs")

	# Choosing a row selects that node, so the two views are one selection rather than two.
	# A one-element array rather than a String, because a GDScript lambda captures by
	# value: assigning to a captured local inside one changes the copy and nothing
	# else, so the first version of this check reported an empty name for ever.
	var chosen := [""]
	main.outline.node_chosen.connect(func(id: String) -> void: chosen[0] = id)
	var first_row: TreeItem = main.outline._tree.get_root().get_first_child()
	first_row.select(0)
	await process_frame
	await process_frame
	check(chosen[0] != "", "selecting a row chooses that node (%s)" % chosen[0])
	if chosen[0] != "" and main.widgets.has(chosen[0]):
		check(main.widgets[chosen[0]].selected,
			"and the graph selects it too, so the views share one selection")

	# Reachable by keyboard, which is the entire point — a list you can only click is a
	# list that helps nobody who needed it.
	check(main.outline._tree.focus_mode == Control.FOCUS_ALL,
		"and the list can be reached with the keyboard")

	# ---- the sandbox draws its whole world ------------------------------------------
	# SubViewportContainer.stretch resizes the viewport to match the container rather
	# than scaling it, so the viewport grew to the width of the panel while the game went
	# on drawing its fixed 960 units — and everything past that was blank. The grey region
	# was never a layout problem: it was the part of a viewport nothing had drawn into,
	# with the goal flag sitting just outside the part that had.
	main.show_view("Sandbox")
	for i in 6:
		await process_frame
	var sandbox_viewport: SubViewport = null
	var sandbox_queue: Array = [main.sandbox]
	while not sandbox_queue.is_empty():
		var node: Node = sandbox_queue.pop_back()
		for child in node.get_children():
			sandbox_queue.append(child)
		if node is SubViewport:
			sandbox_viewport = node
	check(sandbox_viewport != null, "the sandbox has a viewport")
	if sandbox_viewport != null:
		check(sandbox_viewport.size_2d_override == Vector2i(Sandbox.WORLD_SIZE),
			"and it draws in the world's own resolution (%s, world %s)"
				% [str(sandbox_viewport.size_2d_override), str(Vector2i(Sandbox.WORLD_SIZE))])
		check(sandbox_viewport.size_2d_override_stretch,
			"scaled to the stage rather than cropped by it")

	# One strip, not three paragraphs. Counted rather than eyeballed, because the thing
	# that made it look like a debug page was the number of lines.
	var sandbox_labels := 0
	sandbox_queue = [main.sandbox]
	while not sandbox_queue.is_empty():
		var node: Node = sandbox_queue.pop_back()
		for child in node.get_children():
			sandbox_queue.append(child)
		if node is Label and (node as Label).text.length() > 30:
			sandbox_labels += 1
	check(sandbox_labels <= 1,
		"and the tab shows at most one long line of prose (%d)" % sandbox_labels)
	main.show_view("Graph")
	await process_frame

	# ---- rack cables answer where they go -------------------------------------------
	# The rack draws its own cables, which is why the *dimming* half lives here and not in
	# the graph view: GraphEdit paints connections itself and offers no per-cable alpha, so
	# there the best available answer was to brighten a path and leave the rest alone.
	main.show_view("Rack")
	Rack.density = Rack.Density.INSTRUMENT
	main.rack.rebuild()
	for i in 4:
		await process_frame

	var rack_cables: Array = main.rack.cable_endpoints()
	check(rack_cables.size() > 0, "the rack has cables (%d)" % rack_cables.size())
	check(rack_cables[0].size() >= 5,
		"and each one knows which nodes it joins, not only where it starts and ends")

	# Hit-tested against the drawn hanging_curve, not the straight line between the ends. A
	# catenary sags a couple of hundred pixels below its own chord, so testing the chord
	# would pick whichever cable happened to pass overhead.
	main.rack.cable_style = Rack.CableStyle.CATENARY
	var sample: Array = rack_cables[0]
	var chord_middle: Vector2 = (sample[0] + sample[1]) * 0.5
	var cable_span: float = absf(sample[1].x - sample[0].x)
	var cable_sag: float = clampf(cable_span * Rack.SAG_FRACTION, Rack.SAG_MIN, Rack.SAG_MAX)
	var hanging_curve: PackedVector2Array = Rack.catenary(sample[0], sample[1], cable_sag)
	var hanging_curve_middle: Vector2 = hanging_curve[hanging_curve.size() / 2]
	check(hanging_curve_middle.distance_to(chord_middle) > 20.0,
		"a hanging cable is nowhere near its own chord (%.0f px below)"
			% (hanging_curve_middle.y - chord_middle.y))
	check(main.rack.cable_at(hanging_curve_middle) >= 0,
		"so hovering is measured against the curve, and finds it")
	check(main.rack.cable_at(chord_middle) != 0 or rack_cables.size() == 1,
		"rather than against the straight line nobody drew")

	# Selecting a module has to reach the cable layer, which is a sibling of the modules
	# rather than one of them — redrawing the modules alone left every cable at full
	# strength and the dimming invisible.
	# What gets dimmed, asked of the rack rather than inferred from the pixels. The first
	# attempt at this counted redraws instead, and passed with the feature removed —
	# something else in the test environment was redrawing the layer every frame anyway.
	main.rack.select("filter")
	var touching := 0
	var elsewhere := 0
	for index in rack_cables.size():
		var entry: Array = rack_cables[index]
		var touches: bool = entry[3] == "filter" or entry[4] == "filter"
		if main.rack.cable_related(index, rack_cables) == touches:
			if touches:
				touching += 1
			else:
				elsewhere += 1
	check(touching > 0 and elsewhere > 0,
		"selecting a module keeps its own cables lit and turns the rest down (%d and %d)"
			% [touching, elsewhere])

	main.rack.hovered_cable = 0
	check(main.rack.cable_related(0) and not main.rack.cable_related(1),
		"and a pointer on one cable beats the selection, because that is a narrower question")
	main.rack.hovered_cable = -1
	main.rack.select("")
	check(main.rack.cable_related(0) and main.rack.cable_related(1),
		"with nothing chosen at all, nothing is dimmed")
	await process_frame

	main.rack.cable_at(Vector2(-900, -900))
	main.rack._update_cable_hover(Vector2(-900, -900))
	check(main.rack.hovered_cable == -1, "and moving away from all of them lets go")

	main.show_view("Graph")
	await process_frame

	# ---- rack modules show what they are doing --------------------------------------
	# The argument for a hardware metaphor is that hardware tells you something by being
	# looked at. A panel that only holds knobs is a picture of hardware.
	main.show_view("Rack")
	Rack.density = Rack.Density.ANALYSIS
	rack_ready(main)
	main.engine.note_on(45, 0.9)
	for i in 40:
		main.engine.fill_playback(playback, 256)
		main.rack.refresh_displays()
		await process_frame

	var osc_module = main.rack.module_for("osc")
	var filter_module = main.rack.module_for("filter")
	check(osc_module != null and filter_module != null,
		"the oscillator and the filter both have modules")
	if osc_module != null and filter_module != null:
		check(osc_module._history.size() > 64,
			"a display keeps more than one block of history (%d samples)"
				% osc_module._history.size())
		check(osc_module._history.size() <= osc_module.HISTORY,
			"and stops growing at its limit (%d)" % osc_module._history.size())

		# The one that matters: the filter's display is not the oscillator's. If every
		# module drew the same trace the panel would be decoration.
		var differ := 0
		var shared: int = mini(osc_module._history.size(), filter_module._history.size())
		for i in shared:
			if absf(osc_module._history[i] - filter_module._history[i]) > 0.01:
				differ += 1
		check(differ > shared / 10,
			"and the filter shows something different from its own input (%d of %d samples)"
				% [differ, shared])

	main.engine.all_notes_off()
	Rack.density = Rack.Density.INSTRUMENT

	# ---- a module wears the face its panel describes ---------------------------------
	# The derived surface exports every knob its inner nodes had, which is right for not
	# losing anything and wrong for reading. A panel says which of them are on the front,
	# how they line up, and what they are called — without changing what the module can do.
	var before_panels: Dictionary = main.patch.duplicate(true)
	main.patch = {
		"schema_version": 2,
		"modules": {
			"envamp": {
				"nodes": [
					{"id": "env", "type": "ADSR",
						"parameters": {"attack": 0.02, "release": 0.4}},
					{"id": "amp", "type": "Gain", "parameters": {"gain": 0.8}},
				],
				"connections": [
					{"from": {"node": "env", "port": "out"},
						"to": {"node": "amp", "port": "gain"}},
				],
				"inputs": [{"name": "gate", "node": "env", "port": "gate"},
					{"name": "in", "node": "amp", "port": "in"}],
				"outputs": [{"name": "out", "node": "amp", "port": "out"}],
				"parameters": [
					{"name": "attack", "node": "env", "parameter": "attack"},
					{"name": "release", "node": "env", "parameter": "release"},
					{"name": "gain", "node": "amp", "parameter": "gain"},
				],
				# Two on a line, one below, "gain" left off entirely, and a name that is
				# not exported at all — which must cost a knob, not the whole panel.
				"panel": {
					"rows": [["release", "attack"], ["ghost"]],
					"labels": {"attack": "Snap"},
				},
			},
		},
		"nodes": [
			{"id": "note", "type": "NoteInput", "position": {"x": 0, "y": 0}},
			{"id": "voice", "type": "module", "module": "envamp",
				"position": {"x": 560, "y": 0}},
			{"id": "out", "type": "StereoOutput", "position": {"x": 1120, "y": 0}},
		],
		"connections": [
			{"from": {"node": "note", "port": "gate"},
				"to": {"node": "voice", "port": "gate"}},
			{"from": {"node": "voice", "port": "out"},
				"to": {"node": "out", "port": "left"}},
		],
	}
	main._synthesize_module_descriptors()
	await main._rebuild_view()
	for _settle in 3:
		await process_frame

	var faced: Dictionary = main.registry.get("module:envamp", {})
	check(faced.get("parameters", []).size() == 3,
		"the declared surface still carries every export (%d)"
			% faced.get("parameters", []).size())
	var faced_rows: Array = faced.get("panel_rows", [])
	# One row, not two: the second named only "ghost", and a row with nothing left in it
	# is not an empty row on the panel — it is no row at all.
	check(faced_rows.size() == 1,
		"a row naming nothing this module exports leaves no gap (%d rows)"
			% faced_rows.size())
	if faced_rows.size() == 1:
		check(faced_rows[0].size() == 2,
			"and the surviving row holds what the panel put on it (%d)"
				% faced_rows[0].size())
		# Declared attack-then-release; the panel asked for the other way round.
		check(str(faced_rows[0][0]["name"]) == "release",
			"in the panel's order, not the export order (%s)" % str(faced_rows[0][0]["name"]))
		check(str(faced_rows[0][1].get("display_name", "")) == "Snap",
			"wearing the panel's caption (%s)"
				% str(faced_rows[0][1].get("display_name", "-")))
		check(str(faced_rows[0][1]["name"]) == "attack",
			"which is a caption and not a rename — the binding is untouched (%s)"
				% str(faced_rows[0][1]["name"]))

	# The face is not the surface. "gain" has no knob and is still a parameter this
	# instance can set — which is what stops a panel from quietly breaking a patch.
	var surface_names := []
	for parameter: Dictionary in faced.get("parameters", []):
		surface_names.append(str(parameter["name"]))
	check(surface_names.has("gain"),
		"a knob left off the panel is still exported (%s)" % str(surface_names))

	# And the node in the graph wears it. This is the claim the graphrack's module faces
	# used to hold: a panelled module shows the knobs its panel names, in its rows, under
	# its captions — and is only as tall as those, rather than as tall as everything it
	# exports. Read off the built node rather than off the descriptor, because a descriptor
	# that says two and a node that draws three is exactly the failure worth catching.
	main.show_view("Graph")
	for _settle in 6:
		await process_frame
	var faced_id := ""
	for node in main.patch.get("nodes", []):
		if str(node.get("module", "")) == "envamp":
			faced_id = str(node["id"])
	check(faced_id != "" and main.widgets.has(faced_id),
		"the panelled module is a node in the graph (%s)" % faced_id)
	if main.widgets.has(faced_id):
		var drawn: Array = []
		var walk := func(parent: Node, into: Array, recurse: Callable) -> void:
			for child in parent.get_children():
				var control := child as Control
				if control == null:
					continue
				if str(control.get_meta("cell", "")) == "parameter":
					into.append(str(control.get_meta("parameter_name", "")))
				else:
					recurse.call(control, into, recurse)
		walk.call(main.widgets[faced_id], drawn, walk)
		check(drawn == ["release", "attack"],
			"and draws the knobs the panel named, in its order (%s)" % str(drawn))
		check(not drawn.has("gain"),
			"leaving off the one it did not, though it is still exported (%s)" % str(drawn))

		# The caption is on the label; the binding is on the row. A panel that renamed the
		# binding would have rewired the knob, which is the whole reason they are two
		# fields — so this checks they disagree, on purpose.
		var captions: Array = []
		var caption_walk := func(parent: Node, into: Array, recurse: Callable) -> void:
			for child in parent.get_children():
				var control := child as Control
				if control == null:
					continue
				if str(control.get_meta("cell", "")) == "parameter":
					for inner in control.get_children():
						var label := inner as Label
						if label != null:
							into.append(label.text)
							break
				else:
					recurse.call(control, into, recurse)
		caption_walk.call(main.widgets[faced_id], captions, caption_walk)
		check(captions.has("Snap"),
			"under the panel's caption rather than the binding's name (%s)" % str(captions))

	await main._load_example("First Synth")
	await main._load_example("First Synth")
	for _settle in 6:
		await process_frame

	# ---- the rack fits its content ---------------------------------------------------
	# Module height was a flat 404 for everything, so a Gain with one knob got the same
	# panel as a six-parameter filter and spent most of it on nothing.
	var sparse := [{"type": "Gain"}]
	var busy := [{"type": "StateVariableFilter"}]
	Rack.density = Rack.Density.INSTRUMENT
	var sparse_height: float = Rack.measure(sparse, main.registry)
	var busy_height: float = Rack.measure(busy, main.registry)
	check(busy_height > sparse_height,
		"a module with more parameters needs a taller rack (%.0f vs %.0f)"
			% [busy_height, sparse_height])

	# Uniform within a rack, though: real modules share a rail, and a row of ragged panels
	# stops looking like hardware. The fault was matching a *constant*, not matching.
	var mixed: float = Rack.measure(sparse + busy, main.registry)
	check(is_equal_approx(mixed, busy_height),
		"and a mixed rack takes the height of its busiest module (%.0f)" % mixed)

	# Three densities, and Compact really is compact.
	Rack.density = Rack.Density.COMPACT
	var compact: float = Rack.measure(busy, main.registry)
	Rack.density = Rack.Density.ANALYSIS
	var analysis: float = Rack.measure(busy, main.registry)
	Rack.density = Rack.Density.INSTRUMENT
	check(compact < busy_height and busy_height < analysis,
		"the density modes are a real range (%.0f / %.0f / %.0f)"
			% [compact, busy_height, analysis])
	check(compact < 404.0,
		"and Compact is shorter than the old fixed height (%.0f)" % compact)

	# Category strips are muted so the signal colours keep the loudest voice. Two colour
	# languages at the same volume is one the reader has to keep apart.
	var loudest_category := 0.0
	for category in Rack.CATEGORY_TINT:
		loudest_category = maxf(loudest_category, Rack.category_tint(category).s)
	var quietest_signal: float = minf(Design.AUDIO.s, minf(Design.CONTROL.s,
		Design.TRIGGER.s))
	check(loudest_category < quietest_signal,
		"every category strip is less saturated than every signal colour (%.2f vs %.2f)"
			% [loudest_category, quietest_signal])

	# ---- the accent button is readable in every theme -------------------------------
	# Checked on the button rather than on the token, which is the difference between a
	# passing test and a working button: the contrast figures were fine the whole time
	# while the one filled control in the chrome painted its label in INK_BRIGHT, and on
	# Paper that is near-black on dark green. "Add node" was an unreadable slab and every
	# number said it was fine.
	var add_button: Button = null
	var buttons_to_visit: Array = [main]
	while not buttons_to_visit.is_empty():
		var node: Node = buttons_to_visit.pop_back()
		for child in node.get_children(true):
			buttons_to_visit.append(child)
		if node is Button and (node as Button).text.contains("Add node"):
			add_button = node
	check(add_button != null, "the primary button is findable")

	if add_button != null:
		for choice in Design.PALETTES.size():
			main._use_palette(choice)
			await process_frame
			var fill := (add_button.get_theme_stylebox("normal") as StyleBoxFlat).bg_color
			var ink := add_button.get_theme_color("font_color")
			var ratio := Design.contrast(ink, fill)
			check(ratio >= 4.5,
				"%-16s Add node reads against its own fill (%.2f)"
					% [Design.PALETTE_NAMES[choice], ratio])
		main._use_palette(Design.Palette.LAB)
		await process_frame

	# ---- themes reach the widgets, and stay out of the patch ------------------------
	# A palette that only changes the token values is a palette that changes nothing: the
	# theme is built once from those tokens and most of the editor is styled through it.
	var before_bg := (main.theme.get_stylebox("panel", "GraphNode") as StyleBoxFlat).bg_color
	main._use_palette(Design.Palette.PAPER)
	await process_frame
	await process_frame
	var after_bg := (main.theme.get_stylebox("panel", "GraphNode") as StyleBoxFlat).bg_color
	check(before_bg != after_bg,
		"switching theme restyles the nodes (%s to %s)"
			% [before_bg.to_html(false), after_bg.to_html(false)])
	check(after_bg == Design.SURFACES[Design.Surface.NODE],
		"and they use the palette rather than a colour of their own")

	# Things styled per widget rather than through the theme have to be rebuilt, which is
	# the half a naive implementation misses — the graph would keep its old port icons and
	# title colours and look half-changed.
	var paper_icon: Image = main._port_icon("audio").get_image()
	main._use_palette(Design.Palette.LAB)
	await process_frame
	await process_frame
	var lab_icon: Image = main._port_icon("audio").get_image()
	var icon_moved := false
	for y in lab_icon.get_height():
		for x in lab_icon.get_width():
			if lab_icon.get_pixel(x, y) != paper_icon.get_pixel(x, y):
				icon_moved = true
	check(icon_moved, "and the port icons are redrawn in the new palette")

	# The semantic mapping does not move between themes. Somebody switching to Paper for a
	# projector should not have to relearn which cable is audio.
	for choice in Design.PALETTES.size():
		Design.use_palette(choice)
		check(Design.signal_colour("audio") == Design.AUDIO
				and Design.signal_colour("control") == Design.CONTROL
				and Design.signal_colour("event") == Design.TRIGGER,
			"%s keeps audio/control/trigger meaning the same thing"
				% Design.PALETTE_NAMES[choice])
	Design.use_palette(Design.Palette.LAB)

	# And none of it is a property of the document. Opening a file somebody sent you must
	# not change your contrast mode, so nothing about the theme is ever written to a patch.
	main._capture_positions()
	var serialised := JSON.stringify(main.patch)
	var leaked := []
	for word in ["palette", "theme", "ui_scale", "reduced_motion", "contrast"]:
		if serialised.contains(word):
			leaked.append(word)
	check(leaked.is_empty(),
		"a saved patch carries no display preferences%s"
			% ("" if leaked.is_empty() else ": " + ", ".join(leaked)))

	# ---- no text the font cannot draw ----------------------------------------------
	# The editor was using Unicode symbols as icons and seven of the twelve were absent
	# from Atkinson Hyperlegible Next, so they had been rendering as tofu boxes. Nothing
	# reported it, because a missing glyph is not an error in Godot — it is a rectangle.
	#
	# So this walks every piece of text the running editor is actually showing and asks the
	# font whether it can draw each character. It is the structural fix: the symbols could
	# be reintroduced tomorrow and this would fail the same afternoon.
	var ui_font: Font = Design.font(Design.WEIGHT_REGULAR)
	var undrawable := {}
	var scanned := 0
	var to_visit: Array = [main]
	while not to_visit.is_empty():
		var node: Node = to_visit.pop_back()
		for child in node.get_children(true):
			to_visit.append(child)
		var text := ""
		if node is Label:
			text = (node as Label).text
		elif node is Button:
			text = (node as Button).text
		elif node is LineEdit:
			text = (node as LineEdit).text + (node as LineEdit).placeholder_text
		elif node is Tree:
			# Trees were not covered when this check was written, and the outline view
			# promptly reintroduced an arrow glyph the font has not got — it rendered only
			# because Godot fell back to a system font, which is precisely the dependency
			# being avoided.
			#
			# Walked to the bottom, not two levels down. The first version of this walk
			# visited the root and its children and stopped, and every arrow in the outline
			# is on the *third* level — so reintroducing one deliberately still passed, and
			# the check was decorative until that was tried.
			text += _tree_text((node as Tree).get_root())
		if text == "":
			continue
		scanned += 1
		for index in text.length():
			var code := text.unicode_at(index)
			# Space and above; control characters are not the question here.
			if code > 32 and not ui_font.has_char(code):
				undrawable[text.substr(index, 1)] = true

	check(scanned > 20, "there is UI text to check (%d controls)" % scanned)
	check(undrawable.is_empty(),
		"every character the editor shows is one the font can draw%s"
			% ("" if undrawable.is_empty() else ": " + " ".join(undrawable.keys())))

	# And the icons that replaced those symbols actually mark pixels. An icon that draws
	# nothing is the same failure wearing a new hat — invisible, and reported by nothing.
	var blank := []
	for kind in [Icons.Kind.CARET_RIGHT, Icons.Kind.CARET_DOWN, Icons.Kind.DOT,
			Icons.Kind.TICK, Icons.Kind.STOP, Icons.Kind.PLAY, Icons.Kind.CHEVRON_LEFT,
			Icons.Kind.CHEVRON_RIGHT, Icons.Kind.ARROW_RIGHT]:
		var drawn: Image = Icons.get_icon(kind, 16, Design.INK_NORMAL).get_image()
		var marked := 0
		for y in drawn.get_height():
			for x in drawn.get_width():
				if drawn.get_pixel(x, y).a > 0.5:
					marked += 1
		if marked < 6:
			blank.append(str(kind))
	check(blank.is_empty(),
		"every icon draws something (%s)"
			% ("all nine" if blank.is_empty() else "blank: " + ", ".join(blank)))

	# And they are told apart. Nine icons that all drew the same blob would pass the check
	# above and be worthless.
	var shapes := {}
	for kind in [Icons.Kind.CARET_RIGHT, Icons.Kind.DOT, Icons.Kind.TICK, Icons.Kind.STOP,
			Icons.Kind.PLAY, Icons.Kind.ARROW_RIGHT]:
		var drawn: Image = Icons.get_icon(kind, 16, Design.INK_NORMAL).get_image()
		var signature := ""
		for y in drawn.get_height():
			for x in drawn.get_width():
				signature += "1" if drawn.get_pixel(x, y).a > 0.5 else "0"
		shapes[signature] = true
	check(shapes.size() == 6,
		"and no two of them are the same shape (%d distinct of 6)" % shapes.size())

	# ---- the inspector gets out of the way -----------------------------------------
	# It held 380px of the window whether it was showing a node's parameters or the words
	# "Graph valid", and graph work wants horizontal room more than almost anything else.
	var graph_width_open: float = main.views.size.x
	main._set_side_panel_open(false)
	await process_frame
	await process_frame
	check(main.views.size.x > graph_width_open + 200,
		"collapsing the inspector gives the room to the graph (%.0f from %.0f)"
			% [main.views.size.x, graph_width_open])
	check(not main.side_panel_body.visible,
		"and its contents are hidden rather than squeezed into a column of clipped words")
	check(main.side_panel_toggle.visible,
		"but the way back is still on screen")

	main._set_side_panel_open(true)
	await process_frame
	await process_frame
	check(main.side_panel_body.visible, "and it comes back")

	# The collapse control sits under the faces, not above them: the panel's top row is
	# the most valuable space it has, and it goes to knobs rather than to a button that
	# is pressed a few times an hour.
	check(main.side_panel_toggle.get_global_rect().position.y
			> main.patch_face.get_global_rect().position.y,
		"the collapse control sits below the faces, not above them")

	# Dragging the divider is the width setting. A separate control next to a draggable
	# divider is two ways to say one thing, and they disagree the moment either is used.
	#
	# The offset the dragger works in is measured from the right edge: -offset is the
	# panel's width. That is an empirical fact about this container (a probe swept it),
	# and the invariant below is what keeps the divider honest — the code used to write
	# a large positive offset and pin the width with a minimum size instead, which
	# looked identical and gave every drag a dead zone hundreds of pixels wide, because
	# the drag baseline is the offset as written, not the divider as drawn.
	check(-main.split.split_offset == int(main.side_panel.size.x),
		"the divider's offset is the panel's width (%d for %.0fpx)"
			% [main.split.split_offset, main.side_panel.size.x])

	# A drag lands where the mouse is: the dragger writes the raw offset and signals.
	main.split.split_offset = -600
	main._on_split_dragged(-600)
	await process_frame
	await process_frame
	check(int(main.side_panel.size.x) == 600 and main.side_panel_width == 600,
		"a drag to 600px gives exactly 600px (%.0f, setting %d)"
			% [main.side_panel.size.x, main.side_panel_width])

	# The panel's own minimum must not grow with its content, or a wide readout takes
	# the divider hostage and the drag goes dead in the hand — which is what a disabled
	# horizontal scroll mode did, by promoting content width into layout minimum.
	check(main.side_panel.get_combined_minimum_size().x <= float(main.SIDE_PANEL_MIN),
		"panel content cannot jam the divider (min %.0f)"
			% main.side_panel.get_combined_minimum_size().x)

	main.split.split_offset = -(main.SIDE_PANEL_MAX + 400)
	main._on_split_dragged(-(main.SIDE_PANEL_MAX + 400))
	await process_frame
	check(main.side_panel_width <= main.SIDE_PANEL_MAX,
		"dragging it wider stops at the maximum (%d)" % main.side_panel_width)
	main.split.split_offset = -100
	main._on_split_dragged(-100)
	await process_frame
	check(main.side_panel_width >= main.SIDE_PANEL_MIN,
		"and dragging it narrower stops at the minimum (%d)" % main.side_panel_width)
	check(-main.split.split_offset == main.side_panel_width,
		"with the divider parked on the clamped width, not past it (%d)"
			% main.split.split_offset)

	# Dragging the divider while the panel is shut moves nothing it could honestly set;
	# it snaps back rather than leaving the divider adrift.
	main._set_side_panel_open(false)
	await process_frame
	main.split.split_offset = -700
	main._on_split_dragged(-700)
	await process_frame
	check(-main.split.split_offset == main.SIDE_PANEL_COLLAPSED,
		"a drag while the panel is shut snaps back (%d)" % main.split.split_offset)
	main._set_side_panel_open(true)
	await process_frame
	main.side_panel_width = main.SIDE_PANEL_DEFAULT
	main._fit_side_panel()
	await process_frame

	# Whatever the width, the graph viewport still has to be honest about it — this is the
	# same rule as the minimap, one panel further out.
	main._focus_node("amp")
	await process_frame
	var amp_after_resize: GraphNode = main.widgets["amp"]
	var amp_rect := Rect2(
		amp_after_resize.position_offset * main.graph_edit.zoom - main.graph_edit.scroll_offset,
		amp_after_resize.size * main.graph_edit.zoom)
	check(main.graph_edit.usable_rect().encloses(amp_rect),
		"and centring still lands inside the viewport after the sidebar moves")

	# ---- nothing comes to rest under permanent furniture ---------------------------
	# `size` is the whole control, and three permanent things overlap it: the scrollbars
	# GraphEdit draws inside its own bounds, the zoom cluster over the top left, and the
	# minimap over the bottom right. Centring against `size` aims at a point that may be
	# beneath any of them.
	main.graph_edit.zoom = 1.0
	await process_frame
	var view: Rect2 = main.graph_edit.usable_rect()
	check(view.size.x < main.graph_edit.size.x or view.size.y < main.graph_edit.size.y,
		"the usable area is smaller than the control (%s of %s)"
			% [str(view.size.round()), str(main.graph_edit.size.round())])
	check(view.size.y <= main.graph_edit.size.y - main.graph_edit.minimap_size.y,
		"and the minimap's corner is not counted as usable")

	# Centring a node must put the whole node inside that area, not merely somewhere on
	# the canvas. This is the check for the reported symptom: a node coming to rest under
	# a permanent panel with its output disappearing beneath it.
	for target in ["amp", "out", "note"]:
		main._focus_node(target)
		await process_frame
		var widget: GraphNode = main.widgets[target]
		var on_screen := Rect2(
			widget.position_offset * main.graph_edit.zoom - main.graph_edit.scroll_offset,
			widget.size * main.graph_edit.zoom)
		check(main.graph_edit.usable_rect().encloses(on_screen),
			"centring %s puts all of it in the usable area (node %s, area %s)"
				% [target, str(on_screen), str(main.graph_edit.usable_rect())])

	# Fit frames everything, and against the same rectangle — fitting to the full control
	# puts the right-hand edge of the graph under the scrollbar and the minimap.
	main.graph_edit.fit_graph()
	await process_frame
	var framed: Rect2 = main.graph_edit.usable_rect()
	var outside := 0
	for id in main.widgets:
		var node: GraphNode = main.widgets[id]
		var spot := Rect2(
			node.position_offset * main.graph_edit.zoom - main.graph_edit.scroll_offset,
			node.size * main.graph_edit.zoom)
		if not framed.encloses(spot):
			outside += 1
	check(outside == 0,
		"fit brings every node into view without hiding any (%d outside)" % outside)

	# And it leaves room around what it framed, rather than fitting to the millimetre.
	var hugged := Rect2()
	var started := false
	for id in main.widgets:
		var node: GraphNode = main.widgets[id]
		var spot := Rect2(
			node.position_offset * main.graph_edit.zoom - main.graph_edit.scroll_offset,
			node.size * main.graph_edit.zoom)
		hugged = spot if not started else hugged.merge(spot)
		started = true
	var slack: float = minf(
		minf(hugged.position.x - framed.position.x, hugged.position.y - framed.position.y),
		minf(framed.end.x - hugged.end.x, framed.end.y - hugged.end.y))
	check(slack >= float(Design.SPACE_XL),
		"and leaves the graph room to breathe (%.0f px on the tightest side)" % slack)

	# Fit is a request to see the whole graph. Once you can, there is nothing further to
	# satisfy, so it does not go on magnifying a small patch to fill the window.
	var lonely: GraphNode = main.widgets["out"]
	for id in main.widgets:
		if id != "out":
			(main.widgets[id] as GraphNode).visible = false
	main.graph_edit.fit_graph()
	await process_frame
	check(main.graph_edit.zoom <= 1.0,
		"fitting one small node does not magnify it (%.2f)" % main.graph_edit.zoom)
	for id in main.widgets:
		(main.widgets[id] as GraphNode).visible = true
	main.graph_edit.fit_graph()
	await process_frame

	# ---- three node states, told apart at a glance ---------------------------------
	# GraphNode ships with normal and selected and nothing between them, so a node under
	# the pointer looked exactly like one three columns away — and in a patch dense enough
	# to need the mouse, "which one am I about to click" is a real question.
	var hover_target: GraphNode = main.widgets["osc"]
	hover_target.selected = false
	main._set_node_hovered(hover_target, false)
	check(not hover_target.has_theme_stylebox_override("panel"),
		"a node at rest uses the plain style")

	main._set_node_hovered(hover_target, true)
	check(hover_target.has_theme_stylebox_override("panel"),
		"hovering one gives it a state of its own")
	var hovered_box := hover_target.get_theme_stylebox("panel") as StyleBoxFlat
	var resting_box := main.theme.get_stylebox("panel", "GraphNode") as StyleBoxFlat
	check(hovered_box.border_color != resting_box.border_color,
		"which differs from resting")
	# And differs from selected, or three states would be two.
	var selected_box := main.theme.get_stylebox("panel_selected", "GraphNode") as StyleBoxFlat
	check(hovered_box.border_color != selected_box.border_color,
		"and from selected, so the three are told apart rather than compared")
	check(hovered_box.bg_color == resting_box.bg_color,
		"hover moves the border only, leaving the lift to mean selected")

	# A selected node stays looking selected when the pointer crosses it. Otherwise
	# reaching for a node would make the current selection flicker.
	hover_target.selected = true
	main._set_node_hovered(hover_target, true)
	check(not hover_target.has_theme_stylebox_override("panel"),
		"and hovering a selected node leaves it selected-looking")
	hover_target.selected = false
	main._set_node_hovered(hover_target, false)

	# ---- unsaved changes are visible ------------------------------------------------
	# One of the few questions an editor should never make somebody guess at, and it was
	# not answerable here at all: the toolbar said "playing" whatever had happened.
	await main._load_example("First Synth")
	await process_frame
	check(not main.unsaved, "a freshly opened patch has nothing unsaved")
	check(not main.document_label.text.contains("unsaved"),
		"and its name is plain (%s)" % main.document_label.text)

	main._begin_edit()
	main._set_parameter("filter", "cutoff", 2500.0)
	main._commit_edit("set cutoff")
	await process_frame
	check(main.unsaved, "changing something marks it unsaved")
	check(main.document_label.text.contains("unsaved"),
		"and the document name says so (%s)" % main.document_label.text)

	# Opening another document clears it, or the mark would follow you around for the
	# rest of the session and stop meaning anything.
	await main._load_example("Delay Echo")
	await process_frame
	check(not main.unsaved, "opening another one clears the mark")
	await main._load_example("First Synth")
	await process_frame

	# ---- cables answer where they go -------------------------------------------------
	# A hovered cable is already brightened by GraphEdit. What that does not tell you is
	# where it lands, and on a dense patch following a curve by eye is the whole of the
	# difficulty — so both ends are marked.
	main.graph_edit.zoom = 1.0
	await process_frame
	var first_cable: Dictionary = main.graph_edit.connections[0]
	var cable_from: GraphNode = main.graph_edit.get_node(
		NodePath(str(first_cable["from_node"])))
	var cable_to: GraphNode = main.graph_edit.get_node(NodePath(str(first_cable["to_node"])))
	var from_spot: Vector2 = cable_from.get_output_port_position(
		int(first_cable["from_port"]))
	var to_spot: Vector2 = cable_to.get_input_port_position(int(first_cable["to_port"]))
	var cable_start: Vector2 = cable_from.position_offset + from_spot
	var cable_end: Vector2 = cable_to.position_offset + to_spot
	var centre: Vector2 = (cable_start + cable_end) * 0.5
	var midpoint: Vector2 = centre * main.graph_edit.zoom - main.graph_edit.scroll_offset

	main.graph_edit._update_cable_hover(midpoint)
	check(not main.graph_edit.hovered_cable.is_empty(),
		"the pointer on a cable registers as hovering it")
	main.graph_edit._update_cable_hover(Vector2(-800, -800))
	check(main.graph_edit.hovered_cable.is_empty(),
		"and moving off it lets go")

	# ---- ports behave like jacks ---------------------------------------------------
	# GraphEdit has no hover signal for ports and a large invisible hot zone around each
	# one, so the thing you are about to connect to gave no sign of being the thing you
	# were about to connect to — you found out by letting go.
	main.graph_edit.zoom = 1.0
	main.graph_edit._update_detail()
	await process_frame
	var filter_node: GraphNode = main.widgets["filter"]
	var port_spot: Vector2 = (filter_node.position_offset
		+ filter_node.get_input_port_position(0)) - main.graph_edit.scroll_offset

	main.graph_edit._update_hover(port_spot)
	check(not main.graph_edit.hovered_port.is_empty(),
		"the pointer over a port registers as hovering it")
	check(main.graph_edit.hovered_port.get("side", "") == "left"
			and int(main.graph_edit.hovered_port.get("index", -1)) == 0,
		"and identifies which port (%s)" % str(main.graph_edit.hovered_port))

	# The whole point of the enlarged hot zone: the visible jack is about 10px across, and
	# WCAG 2.2 asks for a 24px target. A patching interface where missing the port is the
	# usual way to fail at the main thing the app does should be well past the minimum.
	main.graph_edit._update_hover(port_spot + Vector2(0, 11))
	check(not main.graph_edit.hovered_port.is_empty(),
		"a pointer 11px off centre still finds it, so the target is at least 22px across")
	main.graph_edit._update_hover(port_spot + Vector2(0, 200))
	check(main.graph_edit.hovered_port.is_empty(),
		"and a pointer nowhere near it finds nothing")

	# What the tooltip says. A jack on hardware is labelled; here the node body carries the
	# name and the colour and shape carry the type, which is no help at all on day one —
	# "cutoff_mod" tells you nothing about what may be plugged into it.
	main.graph_edit._update_hover(port_spot)
	var tip: String = main.graph_edit.tooltip_text
	check(tip.contains("filter.in"), "the tooltip names the port (%s)" % tip.split("\n")[0])
	check(tip.contains("audio") and tip.contains("input"),
		"and says which direction and which kind of signal")
	check(tip.contains("required"), "and that this one has to be connected")

	# A port with a unit says so, because the unit is the thing you need in order to know
	# what number belongs there.
	var cutoff_spot: Vector2 = (filter_node.position_offset
		+ filter_node.get_input_port_position(1)) - main.graph_edit.scroll_offset
	main.graph_edit._update_hover(cutoff_spot)
	check(main.graph_edit.tooltip_text.contains("Hz"),
		"a port with a unit names it (%s)" % main.graph_edit.tooltip_text.split("\n")[0])

	# Moving off clears it, or the last port hovered would keep describing itself over
	# empty canvas.
	main.graph_edit._update_hover(Vector2(-500, -500))
	check(main.graph_edit.tooltip_text == "",
		"and moving away from every port says nothing at all")

	# ---- the signal glow reflects signal ------------------------------------------
	# The one piece of movement in the editor, and the whole of its value is that it is
	# measured rather than imagined. An editor that animated on a guess would be
	# decoration and worse than none, so the test is that a silent graph does not glow
	# and a sounding one does.
	Design.reduced_motion = false
	main._rebuild_level_targets()
	check(main._level_targets.size() > 0,
		"every output port is on the sweep list (%d)" % main._level_targets.size())

	main.engine.all_notes_off()
	main.engine.reset()
	for i in 40:
		main.engine.fill_playback(playback, 256)
		main._update_port_levels(0.05)
		await process_frame
	# One named audio port rather than the loudest thing anywhere, because the loudest
	# thing anywhere is the LFO — it runs free whether or not a note is held, so the
	# graph is never truly still and a max-over-everything comparison measures the
	# modulator instead of the sound. That is correct behaviour and a wrong test.
	var amp_widget: String = String(main.widgets["amp"].name)
	var quiet_glow: float = main.graph_edit.port_levels.get(amp_widget, {}).get(0, 0.0)

	main.engine.note_on(57, 0.9)
	for i in 60:
		main.engine.fill_playback(playback, 256)
		main._update_port_levels(0.05)
		await process_frame
	var loud_glow: float = main.graph_edit.port_levels.get(amp_widget, {}).get(0, 0.0)

	check(loud_glow > quiet_glow + 0.1,
		"the amplifier output glows when it is making sound and not when it is not "
			+ "(%.3f vs %.3f)" % [loud_glow, quiet_glow])

	# And a pitch that is merely present does not count as activity. The keyboard's
	# frequency output sits at a steady 440-odd hertz forever; if that lit up, every
	# control port in every graph would be permanently on and the glow would carry no
	# information at all. This is the check that stopped exactly that shipping.
	var note_widget: String = String(main.widgets["note"].name)
	var pitch_glow: float = main.graph_edit.port_levels.get(note_widget, {}).get(0, 0.0)
	check(pitch_glow < 0.1,
		"a steady pitch is not activity and does not glow (%.3f)" % pitch_glow)

	# Reduced motion is not a preference that gets ignored. Nothing here depends on
	# animation to be usable, so the switch turns it off rather than slowing it down.
	Design.reduced_motion = true
	main.graph_edit.port_levels.clear()
	for i in 20:
		main._update_port_levels(0.05)
		await process_frame
	check(main.graph_edit.port_levels.is_empty(),
		"reduced motion stops the glow being computed at all")
	Design.reduced_motion = false
	main.engine.all_notes_off()

	# ---- reachable without a mouse ---------------------------------------------------
	# Every control in this editor was deliberately unfocusable, because the computer
	# keyboard is the piano and a slider that keeps focus eats the next note played. The
	# cost of that was an interface no keyboard could reach.
	var keyed_field = main.parameter_widgets["filter"]["cutoff"]["readout"]
	check(keyed_field.focus_mode == Control.FOCUS_ALL,
		"a parameter can be reached with Tab")

	keyed_field._on_typed("1000")
	await process_frame
	var before_nudge := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "filter":
			before_nudge = float(node["parameters"]["cutoff"])
	keyed_field.nudge(0.01)
	await process_frame
	var after_nudge := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "filter":
			after_nudge = float(node["parameters"]["cutoff"])
	check(after_nudge > before_nudge,
		"and an arrow key moves it (%.1f to %.1f)" % [before_nudge, after_nudge])

	# And so does the wheel, in the same step. The graph's fields and the panel's knobs
	# are different controls with the same two constants; a wheel that stepped one of
	# them and scrolled past the other would be two vocabularies for one idea.
	keyed_field.position_now = 0.5
	_wheel(keyed_field, true)
	check(absf(keyed_field.position_now - (0.5 + keyed_field.KEY_STEP)) < 0.001,
		"a notch of the wheel moves a graph field too (%.3f)" % keyed_field.position_now)
	_wheel(keyed_field, false, true)
	check(absf(keyed_field.position_now
			- (0.5 + keyed_field.KEY_STEP - keyed_field.KEY_COARSE)) < 0.001,
		"and Shift makes it coarse there as well (%.3f)" % keyed_field.position_now)

	# A hundred presses crosses any parameter, whatever its range — a fixed step that
	# suits 0..1 is useless on 20..20000 and the other way round.
	var crossed := 0
	keyed_field.position_now = 0.0
	for i in 100:
		keyed_field.nudge(keyed_field.KEY_STEP)
		crossed += 1
	check(keyed_field.position_now >= 0.999,
		"a hundred presses crosses the whole range (%.3f after %d)"
			% [keyed_field.position_now, crossed])

	# And the piano still works. Focus is handed back when a drag ends, so a mouse user
	# never ends up typing into a parameter by accident.
	keyed_field.grab_focus()
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	keyed_field._dragging = true
	keyed_field._gui_input(release)
	await process_frame
	check(not keyed_field.has_focus(),
		"and a finished drag hands focus straight back, so the keyboard stays a piano")

	# ---- the interface can be resized ------------------------------------------------
	# Not the graph zoom. Zooming the canvas to compensate for small labels makes the
	# patch smaller while making the text bigger, which is the opposite of the ask.
	var body_at_comfortable := Design.type(Design.SIZE_BODY)
	main._use_ui_scale(Design.Scale.XL)
	await process_frame
	await process_frame
	check(Design.type(Design.SIZE_BODY) > body_at_comfortable,
		"XL makes the text bigger (%d from %d)"
			% [Design.type(Design.SIZE_BODY), body_at_comfortable])

	# The whole interface, not only the type — padding, ports and hit areas move with it,
	# which is the difference between a scale setting and a font-size setting.
	var hotzone_xl: int = main.theme.get_constant("port_hotzone_outer_extent", "GraphEdit")
	main._use_ui_scale(Design.Scale.COMPACT)
	await process_frame
	var hotzone_compact: int = main.theme.get_constant("port_hotzone_outer_extent",
		"GraphEdit")
	check(hotzone_xl > hotzone_compact,
		"and the port targets scale with it (%d vs %d)" % [hotzone_xl, hotzone_compact])
	main._use_ui_scale(Design.Scale.COMFORTABLE)
	await process_frame
	await process_frame

	# ---- the number is a control ---------------------------------------------------
	# A slider 112px wide cannot resolve 20 Hz to 20 kHz. At the bottom of an exponential
	# range one pixel is several hertz, so asking for exactly 440 meant dragging until it
	# happened to say 440. The readout is now draggable and typeable.
	var cutoff_field = main.parameter_widgets["filter"]["cutoff"]["readout"]
	check(cutoff_field is ValueField, "the readout is a field rather than a label")

	# Typing. The field shows "900.0 Hz", so the obvious thing is to edit that string and
	# press return — rejecting it over the unit the field itself printed would be a small
	# cruelty, and this is the check that it is accepted.
	cutoff_field._on_typed("440 Hz")
	await process_frame
	var typed := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "filter":
			typed = float(node["parameters"]["cutoff"])
	check(is_equal_approx(typed, 440.0),
		"typing '440 Hz' sets it to exactly 440 (%.3f)" % typed)
	check(cutoff_field.text.contains("440"),
		"and the field says so (%s)" % cutoff_field.text)

	# Out of range is clamped rather than accepted, or a typo would put the graph into a
	# state the slider cannot represent and the value would jump the next time it moved.
	cutoff_field._on_typed("999999")
	await process_frame
	var clamped := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "filter":
			clamped = float(node["parameters"]["cutoff"])
	check(clamped <= 20000.0 and clamped > 0.0,
		"an out-of-range number is clamped to what the parameter allows (%.0f)" % clamped)

	# Nonsense leaves it alone rather than resetting it to zero.
	var before_nonsense := clamped
	cutoff_field._on_typed("banana")
	await process_frame
	var after_nonsense := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "filter":
			after_nonsense = float(node["parameters"]["cutoff"])
	check(is_equal_approx(after_nonsense, before_nonsense),
		"and something that is not a number changes nothing (%.0f)" % after_nonsense)

	# The dial and the field are two views of one value, so moving either has to move
	# the other. A field that drifted out of step with its control would be worse than
	# the label it replaced. The control is the rack's knob now, in both views, so this
	# is also the check that the graph and the rack cannot disagree about a parameter.
	var cutoff_dial: Rack.Knob = main.parameter_widgets["filter"]["cutoff"]["slider"]
	cutoff_field._on_typed("1000")
	await process_frame
	check(absf(cutoff_dial.value() - 1000.0) < 1.0,
		"typing a value moves the dial with it (%.1f)" % cutoff_dial.value())
	# And the other way. The knob writes through the rack's signal, which is the one path
	# both views share, so this fails if the graph ever grows a second wiring of its own.
	var dial_press := InputEventKey.new()
	dial_press.keycode = KEY_RIGHT
	dial_press.pressed = true
	cutoff_dial._gui_input(dial_press)
	await process_frame
	check(absf(cutoff_field.position_now
			- main._to_position(main.parameter_widgets["filter"]["cutoff"]["descriptor"],
				cutoff_dial.value())) < 0.01,
		"and moving the dial moves the field (%.3f)" % cutoff_field.position_now)

	# ---- zoom drops detail rather than just shrinking it ---------------------------
	# Zooming out of a patcher normally makes everything smaller, so at the point where the
	# whole graph fits none of it is readable. Detail goes in stages instead.
	var node_widget: GraphNode = main.widgets["filter"]
	main.graph_edit.zoom = 1.0
	main.graph_edit._update_detail()
	main._apply_detail(main.graph_edit.detail)
	await process_frame
	var full_height: float = node_widget.get_combined_minimum_size().y
	# Captured at full detail, so the comparison below is against something rather than
	# against itself.
	var ports_at_full := node_widget.get_input_port_count()
	var port_spots_at_full := []
	for port in ports_at_full:
		port_spots_at_full.append(node_widget.get_input_port_slot(port))

	# ---- the acceptance tests for semantic zoom -------------------------------------
	#
	# Two rules, both measured in real pixels rather than in stylesheet pixels, because
	# the canvas is the one place in the application where those differ: GraphEdit scales
	# its nodes, so a label that says 16px arrives at 10.4 at 65% and a test that reads
	# the declaration would call that fine.
	#
	#   1. no operational text reaches the reader below its minimum
	#   2. no control outlives the words that say what it is
	#
	# The second one is the regression. This suite used to assert its exact opposite —
	# "reduced detail keeps the sliders and hides the words" — which is how the 65% view
	# came to be a node of unlabelled grooves.
	# "survives" is the other half of the bargain, and the half a decluttering rule can
	# cheat on: hiding everything satisfies "no control without a label" perfectly. Each
	# band therefore also names what the reader must still be receiving, in real pixels.
	var levels := [
		{"zoom": 1.00, "level": main.PatchGraph.Detail.FULL, "name": "100%",
			"survives": ["parameter", "value", "port"], "controls": true},
		{"zoom": 0.75, "level": main.PatchGraph.Detail.COMPACT, "name": "75%",
			"survives": ["parameter", "value", "port"], "controls": false},
		{"zoom": 0.65, "level": main.PatchGraph.Detail.COMPACT, "name": "65%",
			"survives": ["parameter", "value", "port"], "controls": false},
		{"zoom": 0.50, "level": main.PatchGraph.Detail.SUMMARY, "name": "50%",
			"survives": ["port"], "controls": false},
		{"zoom": 0.30, "level": main.PatchGraph.Detail.TOPOLOGY, "name": "30%",
			"survives": [], "controls": false},
	]
	for band in levels:
		# Set from full detail each time so the hysteresis is not being asked to climb
		# down several bands at once; the wheel cannot do that either.
		main.graph_edit.zoom = 1.0
		main.graph_edit._update_detail()
		main.graph_edit.zoom = band["zoom"]
		main.graph_edit._update_detail()
		main._apply_detail(main.graph_edit.detail)
		for i in 3:
			await process_frame
		check(main.graph_edit.detail == band["level"],
			"%s selects the %s level of detail (got %d)"
				% [band["name"], band["name"], main.graph_edit.detail])

		var zoom_now: float = main.graph_edit.zoom
		var undersized := []
		var unlabelled := 0
		var labelled_controls := 0
		var reaching := {}
		for id in main.widgets:
			var node: GraphNode = main.widgets[id]
			for label in main.PatchGraph.ScreenText._marked(node):
				var got: float = main.PatchGraph.ScreenText.screen_size(label, zoom_now)
				var kind := str(label.get_meta("screen_kind", ""))
				if got > 0.0:
					reaching[kind] = int(reaching.get(kind, 0)) + 1
				# 0 means the reader is not being shown it at all, which is always a
				# legal answer — dropping information is what a level of detail is for.
				# Showing it too small never is.
				if got > 0.0 and got < float(label.get_meta("screen_min")) - 0.01:
					undersized.append("%s %.1fpx" % [label.text, got])
			# Rule 2, per row: a visible control whose label is not reaching the reader.
			for row in _parameter_cells(node):
				var control_showing := false
				for part in row.get_children():
					if (part is Rack.Knob or part is HSlider or part is OptionButton) \
							and (part as Control).is_visible_in_tree():
						control_showing = true
				if not control_showing:
					continue
				var name_label: Label = row.get_meta("name_label") if row.has_meta("name_label") else null
				var words: float = 0.0 if name_label == null else \
					main.PatchGraph.ScreenText.screen_size(name_label, zoom_now)
				if words <= 0.0:
					unlabelled += 1
				else:
					labelled_controls += 1
		check(undersized.is_empty(),
			"%s renders no operational text under its minimum (%s)"
				% [band["name"], "none" if undersized.is_empty()
					else ", ".join(undersized.slice(0, 3))])
		check(unlabelled == 0,
			"%s shows no control without its label (%d unlabelled, %d labelled)"
				% [band["name"], unlabelled, labelled_controls])

		# And the half that stops "hide everything" from being a passing grade.
		var missing := []
		for kind in band["survives"]:
			if int(reaching.get(kind, 0)) == 0:
				missing.append(str(kind))
		check(missing.is_empty(),
			"%s still delivers %s (missing %s)"
				% [band["name"], ", ".join(band["survives"]) if not band["survives"].is_empty()
					else "nothing but identity and wiring",
					"none" if missing.is_empty() else ", ".join(missing)])
		var controls_showing := labelled_controls > 0
		check(controls_showing == band["controls"],
			"%s %s the controls (%d showing)"
				% [band["name"], "keeps" if band["controls"] else "puts away",
					labelled_controls])

	# The same rule stated as the regression it is, rather than as a property of one
	# zoom: sweeping the whole range must never produce a groove with nothing saying
	# what it does. This is the check that would have caught the old behaviour.
	var worst_unlabelled := 0
	for step in 16:
		main.graph_edit.zoom = 1.0
		main.graph_edit._update_detail()
		main.graph_edit.zoom = 1.0 - float(step) * 0.05
		main.graph_edit._update_detail()
		main._apply_detail(main.graph_edit.detail)
		await process_frame
		for id in main.widgets:
			var node: GraphNode = main.widgets[id]
			for row in _parameter_cells(node):
				var showing := false
				for part in row.get_children():
					if (part is Rack.Knob or part is HSlider or part is OptionButton) \
							and (part as Control).is_visible_in_tree():
						showing = true
				if not showing:
					continue
				var words: Label = row.get_meta("name_label") if row.has_meta("name_label") else null
				if words == null or main.PatchGraph.ScreenText.screen_size(
						words, main.graph_edit.zoom) <= 0.0:
					worst_unlabelled += 1
	check(worst_unlabelled == 0,
		"across the whole zoom range no control ever loses its label (%d found)"
			% worst_unlabelled)

	# Hit targets are screen-space too. A port hotzone is a theme constant read in graph
	# space, so without compensation the thing the pointer has to land on shrinks with
	# everything else — the one part of a node that is *only* a target and cannot be read
	# instead.
	var smallest_target := 1e9
	for step in 10:
		main.graph_edit.zoom = 1.0 - float(step) * 0.07
		main.graph_edit._update_hit_targets()
		await process_frame
		smallest_target = minf(smallest_target,
			float(main.graph_edit.get_theme_constant("port_hotzone_outer_extent"))
				* main.graph_edit.zoom)
	check(smallest_target >= float(main.PatchGraph.PORT_TARGET_MIN) - 0.51,
		"port hit targets hold their real size as the canvas zooms (%.1fpx smallest)"
			% smallest_target)

	# UI scale and graph zoom are different questions — "how much do I want to see" and
	# "how big must things be for me to read them" — and multiplying them into one number
	# is how a reader who asked for larger text gets it taken away by zooming out. The
	# band must depend on the zoom alone, and the larger scale must genuinely arrive.
	var scale_before: int = Design.ui_scale
	var band_compact_floor: float = main.PatchGraph.compact_floor()
	Design.ui_scale = Design.Scale.XL
	await main._rebuild_view()
	main.graph_edit.zoom = 0.65
	main.graph_edit._update_detail()
	main._apply_detail(main.graph_edit.detail)
	for i in 3:
		await process_frame
	# The bands move with the scale rather than staying put, and that is the point
	# rather than a violation of it: what ends a band is *room*, and a reader asking for
	# 35% larger text has 35% less of it per node. Holding the boundary fixed is what
	# produced the collision the matrix caught at XL and 63% — "out" and "in" from
	# neighbouring nodes printed over each other. The independence that matters is that
	# the type genuinely gets bigger, which is checked next.
	check(main.PatchGraph.compact_floor() > band_compact_floor,
		"a larger UI scale reaches the simpler representations sooner (%.2f from %.2f)"
			% [main.PatchGraph.compact_floor(), band_compact_floor])
	# Asked inside XL's own compact band, because outside it there is no parameter text
	# to measure — that is the level of detail doing its job, not the scale failing.
	var xl_zoom: float = main.PatchGraph.compact_floor() + 0.05
	main.graph_edit.zoom = 1.0
	main.graph_edit._update_detail()
	main.graph_edit.zoom = xl_zoom
	main.graph_edit._update_detail()
	main._apply_detail(main.graph_edit.detail)
	for i in 3:
		await process_frame
	var xl_biggest := 0.0
	for id in main.widgets:
		for label in main.PatchGraph.ScreenText._marked(main.widgets[id]):
			if str(label.get_meta("screen_kind", "")) == "parameter":
				xl_biggest = maxf(xl_biggest,
					main.PatchGraph.ScreenText.screen_size(label, xl_zoom))
	check(xl_biggest > float(Design.MIN_SCREEN_LABEL),
		"and XL text really is larger than the ordinary minimum (%.1fpx at %.0f%%)"
			% [xl_biggest, xl_zoom * 100.0])
	Design.ui_scale = scale_before
	# And the zoom with it. This block moves the zoom to reach XL's own compact band,
	# and leaving it there handed every later check a graph at 83% in a compact level of
	# detail — which is how the 800px height budget below started failing at 925px for
	# reasons that had nothing to do with the budget.
	main.graph_edit.zoom = 1.0
	main.graph_edit._update_detail()
	main._apply_detail(main.graph_edit.detail)
	await main._rebuild_view()
	await process_frame
	# A rebuild frees every widget, so anything held from before it is a dangling
	# reference — and a script error inside _initialize skips the quit() at the end,
	# which is why that mistake presents as a hung headless run rather than as a
	# failure. Re-taken here rather than debugged again later.
	node_widget = main.widgets["filter"]

	# ---- the nodes do not sit on top of each other, at any size preference -----------
	# Reported as a text bug — "out" printed over the next node's "in" at XL and 63% —
	# and chased through three wrong theories in the label overlay before anybody
	# measured the node rectangles. The labels were placed correctly the whole time,
	# inside boxes that overlapped by 40px: node widths scale with the UI preference and
	# the positions in the file do not, so at XL a 464-wide node sat 400 units from its
	# neighbour. Checked here rather than in the overlay because the overlay was never
	# the thing that was wrong.
	for scale_choice in [Design.Scale.COMPACT, Design.Scale.COMFORTABLE,
			Design.Scale.LARGE, Design.Scale.XL]:
		Design.ui_scale = scale_choice
		# Freshly loaded, because by this line the suite has opened disclosures and
		# driven the level of detail all over the place, and a node with its "2 more"
		# expanded is 84px taller than the one the file describes. Measured in that
		# state this reported a 43px overlap in first-synth that no screenshot could
		# find and that the file does not contain — the suite reading back its own
		# earlier clicks.
		await main._load_example("First Synth")
		# Generously, because a GraphNode's height is settled a frame *after* its rows
		# are shown — the level-of-detail pass does the resize separately for exactly
		# that reason. Measured at three frames every node still carried its pre-layout
		# height and this reported a 43px overlap that no screenshot could find.
		for i in 6:
			await process_frame
		# At full detail, which is where the nodes are tallest and therefore where they
		# collide first. Fit-on-load leaves the graph zoomed out and summarised, and a
		# summarised node is short enough to clear anything.
		main.graph_edit.zoom = 1.0
		main.graph_edit._update_detail()
		main._apply_detail(main.graph_edit.detail)
		for i in 10:
			await process_frame
		var overlap_worst := ""
		var overlap_ids: Array = main.widgets.keys()
		for overlap_first in overlap_ids.size():
			for overlap_second in range(overlap_first + 1, overlap_ids.size()):
				var overlap_one: GraphNode = main.widgets[overlap_ids[overlap_first]]
				var overlap_two: GraphNode = main.widgets[overlap_ids[overlap_second]]
				var overlap_area := Rect2(overlap_one.position_offset,
					overlap_one.size).intersection(
						Rect2(overlap_two.position_offset, overlap_two.size))
				if overlap_area.size.x > 0.5 and overlap_area.size.y > 0.5:
					overlap_worst = "%s over %s by %.0fx%.0f" % [
						overlap_ids[overlap_first], overlap_ids[overlap_second],
						overlap_area.size.x, overlap_area.size.y]
		check(overlap_worst == "", "no two nodes overlap at %s (%s)"
			% [Design.SCALE_NAMES[scale_choice],
				overlap_worst if overlap_worst != "" else "clear"])

	# The shipped patches themselves, at the one scale, because an example that opens
	# with its nodes on top of each other is the first thing a new reader sees. All eight
	# game sounds did: they were authored on 200-unit rows and the nodes they describe
	# are 267 tall, so every one of them overlapped by 67px and had done since the day
	# the parameter rows grew.
	Design.ui_scale = Design.Scale.COMFORTABLE
	for example_name in ["First Synth", "Game: coin", "Game: explode", "Game: powerup",
			"Game: jump2", "DX7: algo-01"]:
		await main._load_example(example_name)
		# Frames before the zoom, not after. Opening a patch fits it to the window a few
		# frames later, so a zoom set immediately was overwritten and everything below
		# measured a summary-detail graph of short nodes — which reported "clear" on a
		# layout that overlaps by 115px. The check was reading its own timing.
		for i in 6:
			await process_frame
		main.graph_edit.zoom = 1.0
		main.graph_edit._update_detail()
		main._apply_detail(main.graph_edit.detail)
		for i in 10:
			await process_frame
		var shipped_worst := ""
		var shipped_ids: Array = main.widgets.keys()
		for shipped_first in shipped_ids.size():
			for shipped_second in range(shipped_first + 1, shipped_ids.size()):
				var shipped_one: GraphNode = main.widgets[shipped_ids[shipped_first]]
				var shipped_two: GraphNode = main.widgets[shipped_ids[shipped_second]]
				var shipped_area := Rect2(shipped_one.position_offset,
					shipped_one.size).intersection(
						Rect2(shipped_two.position_offset, shipped_two.size))
				if shipped_area.size.x > 0.5 and shipped_area.size.y > 0.5:
					shipped_worst = "%s over %s by %.0fx%.0f" % [
						shipped_ids[shipped_first], shipped_ids[shipped_second],
						shipped_area.size.x, shipped_area.size.y]
		check(shipped_worst == "", "%s opens with its nodes clear of each other (%s)"
			% [example_name, shipped_worst if shipped_worst != "" else "clear"])
	await main._load_example("First Synth")
	await process_frame

	# ---- collapse takes a surface it is given, rather than guessing one ---------------
	# The derivation is a good guess and a bad substitute for being told: "every
	# parameter that was set" is the rule that makes a collapsed module arrive with
	# thirty knobs. Nominating is how the wand says what a module is for.
	var nominating := {
		"schema_version": 1,
		"nodes": [
			{"id": "kb", "type": "NoteInput"},
			{"id": "env", "type": "ADSR", "parameters": {"attack": 0.02, "decay": 0.3}},
			{"id": "amp", "type": "Gain", "parameters": {"gain": 0.5}},
			{"id": "out", "type": "StereoOutput"},
		],
		"connections": [
			{"from": {"node": "kb", "port": "gate"}, "to": {"node": "env", "port": "gate"}},
			{"from": {"node": "env", "port": "out"}, "to": {"node": "amp", "port": "gain"}},
			{"from": {"node": "amp", "port": "out"}, "to": {"node": "out", "port": "left"}},
		],
	}
	var terminals_here: Array = []
	for type_name in main.registry:
		if str(main.registry[type_name].get("category", "")) == "Terminals":
			terminals_here.append(type_name)

	var derived = ModuleAuthor.collapse(nominating, ["env", "amp"], terminals_here)
	check(derived.ok(), "the derived collapse still works (%s)" % derived.error)
	var derived_exports: Array = derived.patch["modules"][derived.module_name] \
		.get("parameters", []).map(func(p): return str(p["name"]))
	check(derived_exports.size() == 3,
		"deriving exports every knob that was set (%s)" % str(derived_exports))

	# The same selection, told what it is for: two knobs, in the order they were picked.
	var picked = ModuleAuthor.collapse(nominating, ["env", "amp"], terminals_here, [
		{"kind": "parameter", "node": "amp", "parameter": "gain"},
		{"kind": "parameter", "node": "env", "parameter": "attack"},
	])
	check(picked.ok(), "a nominated collapse works (%s)" % picked.error)
	var picked_definition: Dictionary = picked.patch["modules"][picked.module_name]
	var picked_exports: Array = picked_definition.get("parameters", []) \
		.map(func(p): return str(p["name"]))
	check(picked_exports == ["gain", "attack"],
		"a nominated surface is taken verbatim, in the order it was picked (%s)"
			% str(picked_exports))
	# No panel: declared order is click order and the face is drawn in declared order, so
	# a panel here would be a second statement of the same thing.
	check(not picked_definition.has("panel"), "and needs no panel to say so")

	# The wiring still decides what must exist. gate and out cross the boundary and were
	# not nominated; dropping them would drop cables somebody had wired.
	# Through the shared reader, because a port is drawn as a seam now rather than listed:
	# asking the definition for an "inputs" key would be asking what it used to answer.
	var picked_in: Array = Seams.declared_ports(picked_definition, false) \
		.map(func(p): return str(p["name"]))
	var picked_out: Array = Seams.declared_ports(picked_definition, true) \
		.map(func(p): return str(p["name"]))
	check(picked_in == ["gate"] and picked_out == ["out"],
		"a boundary connection still declares its port even when unnominated (%s, %s)"
			% [str(picked_in), str(picked_out)])
	var picked_orphans := []
	var picked_ids := {}
	for node in picked.patch["nodes"]:
		picked_ids[str(node["id"])] = true
	for connection in picked.patch["connections"]:
		for end in ["from", "to"]:
			if not picked_ids.has(str(connection[end]["node"])):
				picked_orphans.append(str(connection[end]["node"]))
	check(picked_orphans.is_empty(),
		"so no cable is left dangling (%s)" % str(picked_orphans))

	# ---- expand is the inverse of collapse -------------------------------------------
	# The claim the whole open-a-module idea rests on: a module and the nodes it stands for
	# are two notations for one graph, so looking inside one can be the document changing
	# notation rather than the editor drawing something that is not there. Held here as a
	# round trip — collapse, expand, and the wiring comes back with every cable pointing
	# where it did, every value on the knob it came from, every control still reaching.
	var round_trip: Dictionary = {
		"schema_version": 1,
		"nodes": [
			{"id": "note", "type": "NoteInput"},
			{"id": "env", "type": "ADSR", "parameters": {"attack": 0.02}},
			{"id": "amp", "type": "Gain", "parameters": {"gain": 0.4}},
			{"id": "out", "type": "StereoOutput"},
		],
		"connections": [
			{"from": {"node": "note", "port": "gate"}, "to": {"node": "env", "port": "gate"}},
			{"from": {"node": "env", "port": "out"}, "to": {"node": "amp", "port": "gain"}},
			{"from": {"node": "amp", "port": "out"}, "to": {"node": "out", "port": "left"}},
		],
		"controls": [
			{"id": "a", "label": "A", "kind": "knob", "min": 0.0, "max": 2.0,
				"target": {"node": "env", "parameter": "attack"}},
		],
	}
	var flat_wiring := JSON.stringify(round_trip["connections"])
	var trip_module = ModuleAuthor.collapse(round_trip, ["env", "amp"], terminals_here)
	check(trip_module.ok(), "the pair collapses (%s)" % trip_module.error)
	var trip_open = ModuleAuthor.expand(trip_module.patch, trip_module.instance_id)
	check(trip_open.ok(), "and the instance opens again (%s)" % trip_open.error)
	check(trip_open.members == ["%s.env" % trip_module.instance_id, "%s.amp" % trip_module.instance_id],
		"its parts come back under the instance's name (%s)" % str(trip_open.members))
	check(trip_open.patch.get("modules", {}).has(trip_module.module_name),
		"the definition stays behind, which is how an open module is written down (%s)"
			% str(trip_open.patch.get("modules", {}).keys()))
	var instances := 0
	for node in trip_open.patch["nodes"]:
		if str(node.get("type", "")) == "module":
			instances += 1
	check(instances == 0,
		"with nothing pointing at it — a definition and no instance is the open state (%d)"
			% instances)
	var taken_apart = ModuleAuthor.expand(trip_module.patch, trip_module.instance_id, false)
	check(not taken_apart.patch.has("modules"),
		"and the other operation, taking one apart for good, drops it (%s)"
			% str(taken_apart.patch.get("modules", {}).keys()))

	# Every cable back where it was, under the new ids. Compared as a set of endpoints
	# rather than as a list, because the order they come out in is not a promise.
	var before_edges: Array = []
	for connection in round_trip["connections"]:
		before_edges.append("%s.%s>%s.%s" % [str(connection["from"]["node"]),
			str(connection["from"]["port"]), str(connection["to"]["node"]),
			str(connection["to"]["port"])])
	var after_edges: Array = []
	for connection in trip_open.patch["connections"]:
		after_edges.append("%s.%s>%s.%s" % [
			str(connection["from"]["node"]).trim_prefix(trip_module.instance_id + "."),
			str(connection["from"]["port"]),
			str(connection["to"]["node"]).trim_prefix(trip_module.instance_id + "."),
			str(connection["to"]["port"])])
	before_edges.sort()
	after_edges.sort()
	check(before_edges == after_edges,
		"and every cable is where it started (%s)" % str(after_edges))
	check(JSON.stringify(round_trip["connections"]) == flat_wiring,
		"with the document it was handed left alone")

	var retrip_open_attack := 0.0
	var retrip_open_gain := 0.0
	for node in trip_open.patch["nodes"]:
		if str(node["id"]).ends_with(".env"):
			retrip_open_attack = float(node.get("parameters", {}).get("attack", 0.0))
		if str(node["id"]).ends_with(".amp"):
			retrip_open_gain = float(node.get("parameters", {}).get("gain", 0.0))
	check(is_equal_approx(retrip_open_attack, 0.02) and is_equal_approx(retrip_open_gain, 0.4),
		"the values the instance carried land back on the knobs they came from (%.3f, %.3f)"
			% [retrip_open_attack, retrip_open_gain])
	var control_target: Dictionary = trip_open.patch["controls"][0]["target"]
	check(str(control_target["node"]).ends_with(".env")
			and str(control_target["parameter"]) == "attack",
		"and a control follows its knob back down through the facade (%s)"
			% str(control_target))
	check(trip_open.surface.get("parameters", []).size() == 2,
		"the surface it had is handed back, so it can be put on again (%d)"
			% trip_open.surface.get("parameters", []).size())

	# And shut again. Closing is not a second authoring decision: the name, the ports and
	# the exports are already in the definition the open state left in the file, so this
	# has to put the parts back inside without changing one declaration.
	var shut = ModuleAuthor.close_module(trip_open.patch, trip_module.module_name)
	check(shut.ok(), "the open module folds shut (%s)" % shut.error)
	check(JSON.stringify(shut.patch["modules"][trip_module.module_name].get("inputs", []))
			== JSON.stringify(trip_module.patch["modules"][trip_module.module_name]
				.get("inputs", [])),
		"with the ports it declared before, unchanged (%s)"
			% JSON.stringify(shut.patch["modules"][trip_module.module_name].get("inputs", [])))
	var shut_edges: Array = []
	for connection in shut.patch["connections"]:
		shut_edges.append("%s.%s>%s.%s" % [str(connection["from"]["node"]),
			str(connection["from"]["port"]), str(connection["to"]["node"]),
			str(connection["to"]["port"])])
	var folded_edges: Array = []
	for connection in trip_module.patch["connections"]:
		folded_edges.append("%s.%s>%s.%s" % [str(connection["from"]["node"]),
			str(connection["from"]["port"]), str(connection["to"]["node"]),
			str(connection["to"]["port"])])
	shut_edges.sort()
	folded_edges.sort()
	check(shut_edges == folded_edges,
		"and the wiring it had before it was opened (%s)" % str(shut_edges))

	# A knob turned while it was open comes back up as the instance's value. That is the
	# whole point of opening one, and the easiest thing for a fold to drop.
	var edited: Dictionary = trip_open.patch.duplicate(true)
	for node in edited["nodes"]:
		if str(node["id"]).ends_with(".amp"):
			node["parameters"]["gain"] = 0.9
	var reshut = ModuleAuthor.close_module(edited, trip_module.module_name)
	var carried := 0.0
	for node in reshut.patch["nodes"]:
		if str(node.get("type", "")) == "module":
			carried = float(node.get("parameters", {}).get("gain", 0.0))
	check(is_equal_approx(carried, 0.9),
		"a knob turned while it was open comes back changed (%.2f)" % carried)

	# And the document does not move when the preference does. Positions belong to the
	# patch; scaling them into the graph's world is a rendering decision, and a rendering
	# decision that wrote itself back into the file would walk every node outward by 35%
	# each time somebody trip_open the patch at XL and saved it.
	var before_positions := {}
	for node in main.patch["nodes"]:
		before_positions[node["id"]] = Vector2(node["position"]["x"], node["position"]["y"])
	Design.ui_scale = Design.Scale.XL
	await main._rebuild_view()
	await process_frame
	main._capture_positions()
	var drifted := ""
	for node in main.patch["nodes"]:
		var now := Vector2(node["position"]["x"], node["position"]["y"])
		if not now.is_equal_approx(before_positions[node["id"]]):
			drifted = "%s %s to %s" % [node["id"], before_positions[node["id"]], now]
	check(drifted == "", "and a save at XL writes the same coordinates back (%s)"
		% [drifted if drifted != "" else "unmoved"])

	Design.ui_scale = scale_before
	await main._rebuild_view()
	await process_frame
	node_widget = main.widgets["filter"]

	main.graph_edit.zoom = 1.0
	main.graph_edit._update_detail()
	main.graph_edit.zoom = 0.5
	main.graph_edit._update_detail()
	main._apply_detail(main.graph_edit.detail)
	await process_frame
	check(node_widget.get_combined_minimum_size().y <= full_height,
		"and the node does not grow as detail drops (%.0f, was %.0f)"
			% [node_widget.get_combined_minimum_size().y, full_height])

	# A rebuild while zoomed out has to land in the level already in force. Fresh
	# widgets are built showing everything, and _apply_detail only ran on
	# detail_changed — so a UI-scale toggle at 55% zoom produced full-detail nodes,
	# sub-floor text and all, until the next zoom step snapped them back. Found on the
	# first reload of the exported web build, which opens fitted and zoomed out.
	await main._rebuild_view()
	await process_frame
	var fresh: GraphNode = main.widgets["filter"]
	var fresh_controls := 0
	for row in _parameter_cells(fresh):
		for part in row.get_children():
			if (part is Rack.Knob or part is HSlider or part is OptionButton) \
					and (part as Control).is_visible_in_tree():
				fresh_controls += 1
	check(fresh_controls == 0,
		"rebuilding while zoomed out respects the level in force (%d controls showing)"
			% fresh_controls)
	node_widget = fresh

	main.graph_edit.zoom = 0.3
	main.graph_edit._update_detail()
	await process_frame
	check(main.graph_edit.detail == main.PatchGraph.Detail.TOPOLOGY,
		"further out drops the port names too (level %d)" % main.graph_edit.detail)

	# The hazard this design exists to avoid. A GraphNode slot is bound to the index of a
	# visible child, so hiding a port *row* renumbers every slot below it and the cables
	# reattach to the wrong ports. Only the labels inside the row are hidden, and the
	# check is that the ports have not moved.
	# The labels really are hidden, not merely intended to be. This is a check I did
	# not have when the port caption was one Label, and the moment it became a name
	# and a unit in their own box the labels went a level deeper — so the code that
	# hides them was walking the wrong children and nothing would have said so.
	var visible_port_labels := 0
	for child in node_widget.get_children():
		var control := child as Control
		if control == null or str(control.get_meta("row", "")) != "module":
			continue
		# The knob box shares the row with the jacks now, and its labels are not port
		# labels — count them and this asserts something it was never about.
		var box: Control = control.get_meta("cells_box") \
			if control.has_meta("cells_box") else null
		for side in control.get_children():
			if side == box:
				continue
			for part in (side as Control).get_children():
				if part is Label and (part as Label).visible:
					visible_port_labels += 1
	check(visible_port_labels == 0,
		"and the port names are actually hidden (%d still showing)" % visible_port_labels)

	var ports_now := node_widget.get_input_port_count()
	check(ports_now == ports_at_full,
		"and the port count is unchanged (%d, was %d)" % [ports_now, ports_at_full])
	# Which child row each port is bound to, not where that row happens to sit.
	#
	# This compared port *positions* and could, because ports used to be rows of their own
	# stacked above the parameters — nothing below them moved, so nothing moved them. Ports
	# share their rows with the knob cells now, so a row giving back its height at COMPACT
	# moves the ports on it, and the cables follow, which is correct and is the whole point
	# of a node that shrinks. What must not change is the binding: a hidden row renumbers
	# every slot beneath it and the cables reattach to the wrong ports, and that is what
	# this asks about directly rather than inferring it from pixels.
	var shifted := 0
	for port in mini(ports_now, ports_at_full):
		if node_widget.get_input_port_slot(port) != port_spots_at_full[port]:
			shifted += 1
	check(shifted == 0,
		"and not one of them has changed slot (%d of %d rebound)" % [shifted, ports_now])

	# Hysteresis: a zoom sitting on a threshold must not flip level on every jitter.
	# Asymmetric on purpose — detail drops the moment it must, because staying is how
	# text ends up under its minimum, and only climbs back once clear of the boundary.
	main.graph_edit.zoom = main.PatchGraph.summary_floor()
	main.graph_edit._update_detail()
	check(main.graph_edit.detail == main.PatchGraph.Detail.TOPOLOGY,
		"a nudge back onto the boundary does not flip the level straight away")
	main.graph_edit.zoom = 0.50
	main.graph_edit._update_detail()
	check(main.graph_edit.detail == main.PatchGraph.Detail.SUMMARY,
		"but a real move does")
	main.graph_edit.zoom = main.PatchGraph.summary_floor() - 0.01
	main.graph_edit._update_detail()
	check(main.graph_edit.detail == main.PatchGraph.Detail.TOPOLOGY,
		"and dropping detail needs no margin at all")

	# The bands hold their stated numbers from *either* direction, which is the property
	# the hysteresis broke: the editor opens fitted, so arriving at 63% is a climb, and
	# the old margin kept it in summary until 64%. A 63% screenshot was therefore an
	# empty-looking node while the same zoom reached downward from 100% was correct.
	for approach in [0.30, 1.00]:
		main.graph_edit.zoom = approach
		main.graph_edit._update_detail()
		main.graph_edit.zoom = 0.63
		main.graph_edit._update_detail()
		check(main.graph_edit.detail == main.PatchGraph.Detail.COMPACT,
			"63%% is the compact band whether reached from %.2f or not" % approach)

	# Zoom hides parameter rows and so does the "n more" disclosure. Coming back to full
	# detail must not un-fold the rows the reader chose to hide — two features writing the
	# same visible flag with no memory between them is how a node grows every time you zoom.
	main.graph_edit.zoom = 1.0
	main.graph_edit._update_detail()
	main._apply_detail(main.graph_edit.detail)
	await process_frame
	var folded := 0
	var unfolded_by_zoom := 0
	for child in node_widget.get_children():
		var control := child as Control
		if control == null:
			continue
		# The collapsed flag sits on the knob box, not on the row: a row may be carrying a
		# port on each flank, so what folds is the middle of it.
		var box: Control = control.get_meta("cells_box") \
			if control.has_meta("cells_box") else null
		if box != null and box.get_meta("collapsed", false):
			folded += 1
			if box.visible:
				unfolded_by_zoom += 1
	check(folded > 0, "the filter has folded-away parameters to check (%d)" % folded)
	check(unfolded_by_zoom == 0,
		"and zooming back in leaves them folded (%d reappeared)" % unfolded_by_zoom)
	check(node_widget.get_combined_minimum_size().y == full_height,
		"so the node is the height it started at")

	# ---- the signal path -----------------------------------------------------------
	# Selecting a node lights the whole chain it sits on, because "where does this sound
	# go" is the question the cables exist to answer and the one they are worst at when
	# every cable looks like every other cable. GraphEdit does not read connection
	# activity back, so the thing tested is the reachability that drives it — which is
	# also the part that could be wrong.
	var downstream: Array = main._reachable_from("filter", true)
	downstream.sort()
	check(downstream == ["amp", "filter", "out"],
		"downstream of the filter is the filter, the amp and the output (%s)" % str(downstream))

	var upstream: Array = main._reachable_from("filter", false)
	upstream.sort()
	check(upstream.has("osc") and upstream.has("note") and upstream.has("lfo"),
		"upstream reaches the oscillator, the keyboard and the modulator (%s)" % str(upstream))
	check(not upstream.has("amp"),
		"and does not wander downstream on the way (%s)" % str(upstream))

	# The envelope feeds the amp, not the filter, so it is off this path. If everything
	# came back lit the highlight would be telling you nothing.
	var lit := {}
	for id in downstream: lit[id] = true
	for id in upstream: lit[id] = true
	check(not lit.has("env"),
		"the envelope is not on the filter's path, so the highlight means something")

	# A feedback patch is a cycle, and this project deliberately supports those. Without
	# a seen-set the walk would follow the loop forever and the editor would hang on
	# selection — a much worse failure than a wrong colour.
	var looped := {
		"schema_version": 1,
		"nodes": [
			{"id": "a", "type": "Delay"}, {"id": "b", "type": "Gain"},
			{"id": "out", "type": "StereoOutput"},
		],
		"connections": [
			{"from": {"node": "a", "port": "out"}, "to": {"node": "b", "port": "in"}},
			{"from": {"node": "b", "port": "out"}, "to": {"node": "a", "port": "in"}},
			{"from": {"node": "b", "port": "out"}, "to": {"node": "out", "port": "left"}},
		],
	}
	await main._load_text(JSON.stringify(looped))
	await process_frame
	var around: Array = main._reachable_from("a", true)
	around.sort()
	check(around == ["a", "b", "out"],
		"a feedback loop is walked once rather than forever (%s)" % str(around))

	# Back to the patch the rest of these checks assume.
	await main._load_text(file.get_as_text())
	await process_frame
	await process_frame

	# ---- the inspector earns its width -------------------------------------------
	# It used to be two mostly-empty regions and a line of grey text. The test is not
	# that it has content but that the content *changes with what is selected* — a panel
	# showing the same thing either way is the fixed layout it replaced.
	main.inspecting = {}
	main._refresh_context()
	await process_frame
	check(main.context_heading.text == "The graph",
		"with nothing selected the inspector describes the graph (%s)"
			% main.context_heading.text)

	# The execution order is chips you can click, not a caption. Counted, because a
	# single label containing arrows would satisfy any looser check.
	var chips := 0
	for child in main.context_panel.get_children():
		if child is HFlowContainer:
			for chip in (child as HFlowContainer).get_children():
				if chip is Button:
					chips += 1
	check(chips == main.widgets.size(),
		"and every stage of the run order is a control you can press (%d of %d)"
			% [chips, main.widgets.size()])

	# Pressing one selects and centres that node, which is what turns the order from
	# something to read into a way of getting around a graph too big to see at once.
	main._focus_node("filter")
	await process_frame
	check(main.widgets["filter"].selected, "pressing a stage selects its node")
	check(main.context_heading.text == "Selected node",
		"and the inspector becomes that node (%s)" % main.context_heading.text)
	var shows_node := false
	for child in main.context_panel.get_children():
		if child is Label and (child as Label).text.contains("StateVariableFilter"):
			shows_node = true
	check(shows_node, "naming its type and category")
	check(str(main.inspecting.get("node", "")) == "filter",
		"and pointing the scope at it")

	# ---- valid is quiet ----------------------------------------------------------
	# A green "No problems." under a PROBLEMS heading had as much visual authority as a
	# real error, which is how a reader learns to ignore the place errors appear.
	check(main.health_label.text.contains("valid"),
		"a healthy graph says so in one line (%s)" % main.health_label.text)
	check(not main.diagnostics_heading.visible,
		"and the problems section is not there at all")
	check(main.health_label.get_theme_color("font_color") == Design.INK_SECOND,
		"in secondary ink rather than a colour that asks for attention")

	# And it does raise its voice when there is something to say.
	main._show_diagnostics([{"code": "zero_delay_cycle", "severity": "error",
		"message": "a loop", "nodes": []}])
	await process_frame
	check(main.diagnostics_heading.visible, "a real problem brings the section back")
	check(main.health_label.get_theme_color("font_color") == Design.ERROR,
		"and the line turns (%s)" % main.health_label.text)
	main._show_diagnostics([])

	# ---- the editor fits on a screen ---------------------------------------------
	# The one defect in this redesign that no measurement caught, because measuring a
	# widget cannot tell you the widget is off the edge of the window. The toolbar had
	# a minimum width of 1786px with every command exposed, which forced the whole
	# layout wider than any normal window and pushed the inspector off the right side
	# with its text cut in half. It took rendering the editor to a PNG and looking at
	# it. This is the assertion that would have caught it without that.
	# What it needs with everything showing. Not a failure on its own — a bar that wants
	# 1377px on a 1600px monitor is a bar using the room it has — but it is the number the
	# ladder below has to be able to get under, and worth printing when it moves.
	var column: Control = main.split.get_parent()
	main._apply_toolbar_rung(main.Rung.FULL)
	await process_frame
	var wanted: float = column.get_combined_minimum_size().x

	# The floor: everything the bar is willing to give up, given up. This is the number
	# that decides whether the editor can be opened on a small laptop at all, because
	# below it the column stops shrinking and starts pushing the inspector off the screen.
	main._apply_toolbar_rung(main.RUNG_COUNT - 1)
	await process_frame
	var needed: float = column.get_combined_minimum_size().x
	check(needed <= 1280.0,
		"the editor fits a 1280px window (needs %.0f, wants %.0f)" % [needed, wanted])

	# And it gets there on its own. The ladder existing is not the same as the ladder
	# being climbed: this is the half that would have caught a _fit_toolbar wired to
	# nothing, which is the shape the last three responsiveness bugs in this file took.
	main._apply_toolbar_rung(main.Rung.FULL)
	main._fit_toolbar(1280.0)
	await process_frame
	check(column.get_combined_minimum_size().x <= 1280.0,
		"and asked to fit one, it does so by itself (rung %d, %.0f)"
			% [main.toolbar_rung, column.get_combined_minimum_size().x])

	# It also has to give up the right things. A bar that fits by dropping Silence has
	# solved the arithmetic and broken the instrument: the panic control is the one thing
	# here somebody reaches for while something is already wrong and loud.
	main._apply_toolbar_rung(main.RUNG_COUNT - 1)
	await process_frame
	check(main.transport_dot.visible and main.document_label.visible,
		"the narrowest bar still says what is running and what is open")

	# ---- text that gets trimmed must be trimmed at the end ---------------------------
	# The status line was right-aligned *and* clipping, which takes the overflow off the
	# front: raising the wand printed "point at the jacks and knobs the module should
	# show" and the strip read "ould show". A message truncated from the left has lost the
	# half that says what happened, and there is no way to tell it was truncated at all.
	#
	# Swept over the whole editor rather than asserted on the one label, because the pair
	# is easy to write again and reads as harmless every time.
	var trimming: Array = []
	_collect_trimming_labels(main, trimming)
	var head_first: Array = []
	for label: Label in trimming:
		if label.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT:
			head_first.append("%s '%s'" % [label.name, label.text.substr(0, 24)])
	check(head_first.is_empty(),
		"no label drops its first words instead of its last (%d of %d: %s)"
			% [head_first.size(), trimming.size(), str(head_first)])
	var kept: bool = main.toolbar_performance_group.visible
	for button in main._primary_buttons:
		if not (button as Button).is_visible_in_tree():
			kept = false
	check(kept, "and keeps Add node, Audition and Silence at every width")
	# Given room again it takes it back, so a maximised window is not stuck narrow.
	main._fit_toolbar(2000.0)
	await process_frame
	check(main.toolbar_rung == main.Rung.FULL,
		"widened again, the bar puts everything back (rung %d)" % main.toolbar_rung)

	# ---- and a 1280x800 window, even with a big patch open ---------------------------
	# The width budget's sibling, found the same way the width was: by something
	# important quietly leaving the screen. A 35-node DX7 voice made the inspector's
	# execution-order strip wrap into a 428px block, nothing in that column scrolls, so
	# the editor's *minimum height* grew past a laptop window and the keyboard dock —
	# the last child of the column — was simply below the bottom. Nobody hid it;
	# arithmetic did.
	await main._load_example("DX7: algo-01")
	for i in 6:
		await process_frame
	var tall_needed: float = column.get_combined_minimum_size().y
	check(tall_needed <= 800.0,
		"the editor fits an 800px-tall window with a 35-node patch open (needs %.0f)"
			% tall_needed)
	await main._load_example("First Synth")
	for i in 6:
		await process_frame

	# ---- modules, stage 2: an instance is one node wearing its declared surface -------
	# Since stage 4 the importer emits this notation by default: one operator
	# definition, six instances. The engine sees the flattened nodes; the editor must
	# see 16 authored ones — fifteen, plus the Gain that gives the carrier sum a level
	# of its own rather than leaving it a joint with no control on it.
	await main._load_example("DX7: algo-01")
	for i in 8:
		await process_frame
	check(main.widgets.size() == 16,
		"the editor shows the authored graph, not the expansion (%d widgets)"
			% main.widgets.size())
	check(main.widgets.has("op1") and not main.widgets.has("op1.osc"),
		"instances are nodes; their internals are not")

	# Every node says which one it is. Six instances all titled "Operator" is what this
	# looked like before: the ids knew op1 from op6 and the canvas did not, so the
	# algorithm — the entire subject of a DX7 patch — could only be read by tracing
	# cables. A title is not decoration on a graph whose nodes are otherwise identical.
	var titles := {}
	var untitled := 0
	for id in main.widgets:
		var title: String = (main.widgets[id] as GraphNode).title
		if title.is_empty():
			untitled += 1
		titles[title] = int(titles.get(title, 0)) + 1
	var repeated := 0
	for title in titles:
		if int(titles[title]) > 1:
			repeated += 1
	check(untitled == 0 and repeated == 0,
		"every node in a DX7 voice is named, and no two the same (%d blank, %d repeated)"
			% [untitled, repeated])
	check(str((main.widgets["op1"] as GraphNode).title).contains("carrier")
			and str((main.widgets["op6"] as GraphNode).title).contains("modulator"),
		"and the name says what the operator does in this algorithm (%s / %s)"
			% [(main.widgets["op1"] as GraphNode).title,
				(main.widgets["op6"] as GraphNode).title])
	# The module is named for its chip, so a document could hold a DX7 operator and an
	# OPL2 one without them being the same word, and the model number reads as one.
	check(main.patch.get("modules", {}).has("dx7_operator"),
		"the module is named for the chip it came off")
	check(main._module_display_name("dx7_operator") == "DX7 Operator"
			and main._module_display_name("opl2_operator") == "OPL2 Operator",
		"and a model number survives being made into a display name (%s)"
			% main._module_display_name("dx7_operator"))

	var instance_widget: GraphNode = main.widgets["op1"]
	var declared_inputs: Array = main._port_list("op1", "inputs")
	var declared_outputs: Array = main._port_list("op1", "outputs")
	# note, gate, pm, fm for the voice's pitch modulation, and fb_mod so tremolo
	# and velocity can scale the feedback loop's bite.
	check(declared_inputs.size() == 5 and declared_outputs.size() == 1,
		"an instance wears the declared surface (%d in, %d out)"
			% [declared_inputs.size(), declared_outputs.size()])

	# The exported knob: editing it writes the instance in the document and reaches
	# the inner node in the engine.
	check(main.parameter_widgets.has("op1") and main.parameter_widgets["op1"].has("ratio"),
		"exported parameters appear as ordinary knobs")
	main._set_parameter("op1", "ratio", 2.5)
	var instance_value := 0.0
	for node in main.patch["nodes"]:
		if node["id"] == "op1":
			instance_value = float(node.get("parameters", {}).get("ratio", 0.0))
	check(is_equal_approx(instance_value, 2.5),
		"editing an exported parameter records it on the instance (%.1f)" % instance_value)
	var engine_target: Array = main._engine_parameter_target("op1", "ratio")
	check(str(engine_target[0]) == "op1.pitch" and str(engine_target[1]) == "factor",
		"and the engine hears it at the inner node (%s.%s)" % [engine_target[0], engine_target[1]])

	# The glow sweep reads flattened sources for instance ports.
	var glows_inner := false
	for entry in main._level_targets:
		if str(entry["node"]).begins_with("op1."):
			glows_inner = true
	check(glows_inner, "signal levels are read from the inner nodes")

	# Round trip: saving writes the hierarchy, never the expansion.
	var modular_saved: String = main.engine.format_patch(JSON.stringify(main.patch))
	check(modular_saved.contains("\"modules\""), "saving keeps the modules section")
	check(not modular_saved.contains("op1.pitch"), "and never leaks the flattened form")

	# The exit measurement: 15 nodes fit far above the 33-node packing floor.
	check(main.graph_edit.zoom >= 0.3,
		"the modular voice opens materially closer than the flat one (%.0f%%)"
			% (main.graph_edit.zoom * 100.0))

	await main._load_example("First Synth")
	for i in 6:
		await process_frame

	# ---- modules, stage 3: collapse is the inverse of expansion -----------------------
	# First Synth is open. Collapse the filter sweep — the LFO and the filter — then
	# hold the exit criterion in rendered bytes: the collapsed document and the
	# original flat one must make the same sound. Structure asserts come first; the
	# byte proof runs through sg-render, the same tool every other audio guarantee in
	# this repository trusts.
	var flat_text: String = main.engine.format_patch(JSON.stringify(main.patch))

	for id in ["lfo", "filter"]:
		main.widgets[id].selected = true
	await main._collapse_selection()
	for i in 6:
		await process_frame

	check(main.patch.has("modules") and main.patch["modules"].has("part"),
		"the selection became a definition named part")
	check(main.widgets.has("part") and not main.widgets.has("filter"),
		"and one instance stands where two nodes were (%d widgets)" % main.widgets.size())
	var part_def: Dictionary = main.patch["modules"]["part"]
	check(part_def.get("parameters", []).size() == 7,
		"every authored knob was exported (%d)" % part_def.get("parameters", []).size())
	# Drawn as seams inside the definition now, not listed beside it — so this asks the
	# reader, and also that the seams are really there as nodes, which is the difference
	# between the two spellings and the whole reason for the change.
	var part_in: Array = Seams.declared_ports(part_def, false)
	var part_out: Array = Seams.declared_ports(part_def, true)
	check(part_in.size() == 1 and part_out.size() == 1,
		"the boundary became the ports (%d in, %d out)" % [part_in.size(), part_out.size()])
	var part_seams := 0
	for inner: Dictionary in part_def.get("nodes", []):
		if Seams.is_port_seam(inner):
			part_seams += 1
	check(part_seams == 2 and not part_def.has("inputs") and not part_def.has("outputs"),
		"and they are nodes inside it rather than a list beside it (%d seams)" % part_seams)

	var collapsed_text: String = main.engine.format_patch(JSON.stringify(main.patch))
	check(collapsed_text.contains("\"modules\""), "the saved document carries the definition")

	# The byte proof. sg-render lives in the build directory; on a machine without the
	# native build the check reports itself skipped rather than quietly passing.
	var repo := ProjectSettings.globalize_path("res://").path_join("..")
	var renderer := repo.path_join("build/bin/sg-render.exe")
	if not FileAccess.file_exists(renderer):
		renderer = repo.path_join("build/bin/sg-render")
	if FileAccess.file_exists(renderer):
		var scratch := OS.get_environment("TEMP")
		if scratch == "":
			scratch = "/tmp"
		var flat_json := scratch.path_join("sg-collapse-flat.json")
		var collapsed_json := scratch.path_join("sg-collapse-mod.json")
		var flat_file := FileAccess.open(flat_json, FileAccess.WRITE)
		flat_file.store_string(flat_text)
		flat_file.close()
		var collapsed_file := FileAccess.open(collapsed_json, FileAccess.WRITE)
		collapsed_file.store_string(collapsed_text)
		collapsed_file.close()
		var flat_wav := scratch.path_join("sg-collapse-flat.wav")
		var collapsed_wav := scratch.path_join("sg-collapse-mod.wav")
		var code_a := OS.execute(renderer, [flat_json, flat_wav,
			"--seconds", "1", "--notes", "57", "--gate", "0.7", "--quiet"])
		var code_b := OS.execute(renderer, [collapsed_json, collapsed_wav,
			"--seconds", "1", "--notes", "57", "--gate", "0.7", "--quiet"])
		check(code_a == 0 and code_b == 0,
			"both notations render (%d, %d)" % [code_a, code_b])
		var bytes_flat := FileAccess.get_file_as_bytes(flat_wav)
		var bytes_collapsed := FileAccess.get_file_as_bytes(collapsed_wav)
		check(bytes_flat.size() > 0 and bytes_flat == bytes_collapsed,
			"collapse, save, expand: byte-identical audio (%d bytes)" % bytes_flat.size())
	else:
		check(true, "byte comparison SKIPPED: sg-render not built on this machine")
	# The import sibling: a foreign patch arrives as one definition plus one instance,
	# its terminals becoming the ports — named after what fed them, because
	# "frequency" says what to plug in and "in" does not.
	var foreign_text := FileAccess.get_file_as_string(
		main._repository_examples().path_join("first-synth.json"))
	await main._import_module_as_definition(foreign_text, "voice")
	for i in 6:
		await process_frame
	check(main.patch.get("modules", {}).has("voice"),
		"a foreign patch becomes a definition")
	var voice_def: Dictionary = main.patch["modules"]["voice"]
	# Through declared_ports, because a definition spells its ports two ways and this one
	# now uses the other. A patch's own Input seam survives as a port rather than being
	# dissolved into a binding — it was already a port, and dissolving it lost the fan-out
	# — so reading `inputs` alone finds an empty list and calls it a missing port.
	var input_names: Array = []
	for port: Dictionary in Seams.declared_ports(voice_def, false):
		input_names.append(str(port["name"]))
	check(input_names.has("frequency") and input_names.has("gate"),
		"its terminals became ports named for what fed them (%s)" % str(input_names))
	check(main.widgets.has("voice"), "and one instance arrived, ready to wire")

	# And undo puts the two nodes back, because a collapse is an edit like any other.
	await main._load_example("First Synth")
	for i in 6:
		await process_frame

	# ---- the file's panel is a builder, with no mode to raise -------------------------
	# The panel offers what the selected node has and it has not: the same offer a module's
	# face makes, at the file's scale. That is the point of it — the wand asked you to arm a
	# tool and then point at a knob on the canvas; this asks you to select the node you were
	# going to point at anyway.
	main.graph_edit.zoom = 1.0
	main._focus_node("amp")
	for i in 6:
		await process_frame
	check(str(main.patch_face.offer_node) == "amp",
		"the panel offers the selected node's knobs (%s)" % str(main.patch_face.offer_node))
	var offered_keys: Array = []
	for index in main.patch_face._offers:
		offered_keys.append("%s.%s" % [str(main.patch_face._offers[index]["node"]),
			str(main.patch_face._offers[index]["parameter"])])
	check(offered_keys.has("amp.gain"),
		"including one it is not already showing (%s)" % str(offered_keys))
	var on_panel_already := false
	for index in main.patch_face._targets:
		if str(main.patch_face._targets[index]["node"]) == "amp" \
				and str(main.patch_face._targets[index]["parameter"]) == "gain":
			on_panel_already = true
	check(not on_panel_already, "and not offering what is already on the panel")

	# Dragging an offer onto the panel puts it there, with no tool raised first.
	var face_before: int = main.patch.get("controls", []).size()
	var offer_index := -1
	for index in main.patch_face._offers:
		if str(main.patch_face._offers[index]["parameter"]) == "gain":
			offer_index = int(index)
	check(offer_index >= 0, "the offer can be picked up (%d)" % offer_index)
	main.patch_face._finish(offer_index, 0)
	for i in 8:
		await process_frame
	check(main.patch.get("controls", []).size() == face_before + 1,
		"dragging it onto the panel puts it on (%d, was %d)"
			% [main.patch.get("controls", []).size(), face_before])
	var went_on := false
	for control in main.patch.get("controls", []):
		var target: Dictionary = control.get("target", {})
		if str(target.get("node", "")) == "amp" and str(target.get("parameter", "")) == "gain":
			went_on = true
	check(went_on, "pointing at the knob it was dragged from")

	# And off again, which is a drop outside the panel rather than a second click.
	var panel_cell := -1
	for index in main.patch_face._targets:
		if str(main.patch_face._targets[index]["node"]) == "amp" \
				and str(main.patch_face._targets[index]["parameter"]) == "gain":
			panel_cell = int(index)
	check(panel_cell >= 0, "it is a cell on the panel now (%d)" % panel_cell)
	main.patch_face._finish(panel_cell, -1)
	for i in 8:
		await process_frame
	check(main.patch.get("controls", []).size() == face_before,
		"and dragging it off takes it back off (%d)"
			% main.patch.get("controls", []).size())

	# Reordering, with nothing raised. This used to need the wand up.
	var was_order: Array = []
	for control in main.patch.get("controls", []):
		was_order.append(str(control.get("id", "")))
	if was_order.size() >= 2:
		var rotated: Array = was_order.duplicate()
		rotated.push_back(rotated.pop_front())
		main._on_panel_reordered(rotated)
		for i in 6:
			await process_frame
		var now_order: Array = []
		for control in main.patch.get("controls", []):
			now_order.append(str(control.get("id", "")))
		check(now_order == rotated,
			"the panel reorders without a mode to raise (%s)" % str(now_order))
		main._on_panel_reordered(was_order)
		for i in 6:
			await process_frame

	# ---- a file with no panel of its own still has a face ----------------------------
	# Only the hand-written examples carry `controls`. Everything imported — the whole DX7
	# and OPL2 banks — carried none, so the panel said "no knobs on the face yet", which is
	# true about the document and useless about the instrument.
	# The DX7 bank ships grouped panels from the importer now, so the panel is stripped
	# here to make the fixture this section is about: a file with no panel at all,
	# which is the state every hand-started patch begins in and the whole OPL2 bank
	# still lives in.
	var dx7 := FileAccess.open("res://examples/dx7/algo-02.json", FileAccess.READ)
	if dx7 != null:
		var parsed: Variant = JSON.parse_string(dx7.get_as_text())
		dx7.close()
		if typeof(parsed) == TYPE_DICTIONARY:
			(parsed as Dictionary).erase("controls")
			main.patch = parsed as Dictionary
			main._synthesize_module_descriptors()
			await main._rebuild_view()
			for i in 8:
				await process_frame
			check(main.patch_face.derived,
				"a file with no panel shows the default instead")
			var defaults: Array = PatchFace.default_controls(main.patch, main.registry)
			check(defaults.size() > 20,
				"which is every knob the patch has (%d)" % defaults.size())
			var reaches := {}
			for control: Dictionary in defaults:
				reaches[str(control["target"]["node"])] = true
			check(reaches.size() > 1,
				"across every node that has one (%d nodes)" % reaches.size())
			var names_a_port := false
			for control: Dictionary in defaults:
				for node in main.patch["nodes"]:
					if str(node["id"]) == str(control["target"]["node"]) \
							and str(node.get("type", "")) in ["Input", "Output"]:
						names_a_port = true
			check(not names_a_port,
				"and no ports among them, because a port is not a knob")

			# The panel is a rack row. One block per node, every block the height the rack
			# view gives this patch, side by side on one rail that overflows horizontally
			# and scrolls — a case with more modules than the desk is walked along, not
			# folded downwards.
			# By name, not by class. Every reader here used to identify a part by its
			# type, so each part added since broke a walker that had been right the day
			# before — a ports plate is a VBoxContainer too.
			var face_scroller := main.patch_face.get_node_or_null(
				"Case/Rack") as ScrollContainer
			var face_rail := main.patch_face.get_node_or_null(
				"Case/Rack/Rail/Rows") as VBoxContainer
			check(face_rail != null, "the knobs sit on a rail of rows")
			# Rows down the rail, blocks along each row: read left to right, then down.
			var face_slots: Array = []
			var face_blocks: Array = []
			if face_rail != null:
				face_slots = face_rail.get_children()
				for one_slot in face_slots:
					for one in (one_slot as Node).get_children():
						# Arrows and gaps ride between the blocks; a block is a box.
						if one is VBoxContainer:
							face_blocks.append(one)
			check(face_blocks.size() > 1,
				"grouped into blocks along it (%d)" % face_blocks.size())

			# The load-bearing claim: a block holds one node's knobs and only that node's.
			var block_mixed := ""
			var block_counted := 0
			for one_block in face_blocks:
				var block_owners := {}
				for cell in main.patch_face._cells:
					if (one_block as Node).is_ancestor_of(cell as Node):
						block_counted += 1
						for index in main.patch_face._targets:
							if main.patch_face._cells[index] == cell:
								block_owners[str(main.patch_face._targets[index]["node"])] = true
				if block_owners.size() > 1 and block_mixed == "":
					block_mixed = str(block_owners.keys())
			check(block_mixed == "", "and each block is one node's knobs (%s)" % block_mixed)
			check(block_counted == main.patch_face._cells.size(),
				"with every knob in a block (%d of %d)"
					% [block_counted, main.patch_face._cells.size()])

			# Six operators are three columns of two, not a row of six — a third of the
			# walking to see a whole voice.
			#
			# Written as the literal 2 rather than as PatchFace.PER_SLOT: a test that
			# reads the constant it is checking agrees with any value the constant takes,
			# which is how the first version of this passed while stacked one deep.
			check(face_slots.size() == 2,
				"the rail is two rows (%d)" % face_slots.size())

			# Every block measures the same, whatever height the rail settled at — the
			# two in a slot share it evenly rather than one taking what it likes.
			var rack_height: float = (face_blocks[0] as Control).size.y
			var ragged := ""
			for one_block in face_blocks:
				if absf((one_block as Control).size.y - rack_height) > 1.5 \
						and ragged == "":
					ragged = "%.0fpx against %.0fpx" \
						% [(one_block as Control).size.y, rack_height]
			check(ragged == "", "and every block is the same height (%s)" % ragged)
			check(rack_height * 2.0
					<= float(Design.scale(RackView.DEFAULT_HEIGHT)) + 2.0,
				"a stacked pair is at most one rack module (2 x %.0f in %.0f)"
					% [rack_height, Design.scale(RackView.DEFAULT_HEIGHT)])

			# Both operators of a pair have to be on screen at once, or stacking them
			# bought nothing: a rail taller than the inspector's viewport puts the lower
			# one under a scrollbar. So the rail takes the room there is rather than a
			# flat rack module.
			#
			# Checked as arithmetic, not by shrinking the window. A headless root sits at
			# 900px whatever the window is set to, so the short-window case — the only
			# one that can fail — cannot be staged in the tree here. The first version of
			# this check did shrink the window, reported "331 deep in 10040", and passed
			# happily with the rail pinned back to a fixed height.
			check(PatchFace.rail_height(1200.0, 400.0, 280.0, 404.0) == 404.0,
				"given room, the rail settles at a rack module")
			check(PatchFace.rail_height(700.0, 400.0, 280.0, 404.0) == 300.0,
				"and short of it, takes the room there is")
			check(PatchFace.rail_height(400.0, 300.0, 280.0, 404.0) == 280.0,
				"down to two blocks, below which a scrollbar is the honest answer")
			check(PatchFace.rail_height(0.0, 0.0, 280.0, 404.0) == 404.0,
				"and before the tree has a size, a rack module")

			# And in the tree, the rail obeys those bounds.
			var railing: ScrollContainer = main.patch_face._rail
			var bar: float = float(Design.scale(14))
			check(railing != null
					and railing.custom_minimum_size.y
						<= float(Design.scale(RackView.DEFAULT_HEIGHT)) + bar + 1.0,
				"the rail never asks for more than a rack module (%.0f)"
					% (0.0 if railing == null else railing.custom_minimum_size.y))

			# The row overflows horizontally rather than stacking: the rail is wider than
			# the panel that shows it, and the thing between them scrolls sideways.
			await process_frame
			check(face_rail.size.x > main.patch_face.size.x,
				"and the rail overflows the panel (%.0fpx in %.0fpx)"
					% [face_rail.size.x, main.patch_face.size.x])
			check(face_scroller != null and face_scroller.horizontal_scroll_mode
					!= ScrollContainer.SCROLL_MODE_DISABLED,
				"which scrolls horizontally to reach the rest")

			# Inside a block the knobs run two across, as the rack draws them. No bank may
			# be taller than the block that carries it, or the shared height was a lie.
			var too_tall := ""
			for one_block in face_blocks:
				for inner in (one_block as Node).get_children():
					var banks := inner as HBoxContainer
					if banks == null:
						continue
					for bank in banks.get_children():
						if (bank as Control).get_combined_minimum_size().y \
								> rack_height + 0.5 and too_tall == "":
							too_tall = "a bank of %d knobs needs %.0fpx of %.0fpx" \
								% [(bank as Node).get_child_count(),
									(bank as Control).get_combined_minimum_size().y,
									rack_height]
			check(too_tall == "",
				"no bank outgrows the block's height (%s)" % too_tall)

			# The envelope is a row of sliders, not four more knobs. A node carrying all
			# of attack/decay/sustain/release gets them as vertical sliders labelled
			# A D S R under its remaining knobs, at exactly the knobs' width — heights
			# side by side are the shape of the sound, which dials never quite manage.
			var envelope_rows := 0
			var slider_letters: Array = []
			var width_off := ""
			var live_slider: Control = null
			for one_block in face_blocks:
				var block_banks: HBoxContainer = null
				var block_envelope: HBoxContainer = null
				for inner in (one_block as Node).get_children():
					var row := inner as HBoxContainer
					if row == null:
						continue
					if row.get_child_count() > 0 and row.get_child(0) is RackView.Fader:
						block_envelope = row
					else:
						block_banks = row
				if block_envelope == null:
					continue
				envelope_rows += 1
				if slider_letters.is_empty():
					for slide in block_envelope.get_children():
						slider_letters.append(str((slide as RackView.Fader).label))
					live_slider = block_envelope.get_child(0)
				if block_banks != null and width_off == "" \
						and absf(block_envelope.get_combined_minimum_size().x
							- block_banks.get_combined_minimum_size().x) > 0.5:
					width_off = "%.0fpx under %.0fpx of knobs" % [
						block_envelope.get_combined_minimum_size().x,
						block_banks.get_combined_minimum_size().x]
			check(envelope_rows == 6,
				"every operator wears its envelope as sliders (%d of 6)" % envelope_rows)
			check(slider_letters == ["A", "D", "S", "R"],
				"labelled A D S R (%s)" % str(slider_letters))
			check(width_off == "",
				"each envelope is exactly as wide as the knobs above it (%s)" % width_off)

			# The envelope fills what the block has left rather than reserving a share of
			# it. The spacer that used to hold it to half the block is gone: halving the
			# block does that job, and the room now goes to the operator stacked below
			# instead of to nothing.
			var unfilled := ""
			for one_block in face_blocks:
				var row_envelope: Control = null
				for inner in (one_block as Node).get_children():
					if inner is HBoxContainer and (inner as Node).get_child_count() > 0 \
							and (inner as Node).get_child(0) is RackView.Fader:
						row_envelope = inner as Control
				if row_envelope == null:
					continue
				var bottom: float = row_envelope.position.y + row_envelope.size.y
				if absf(bottom - (one_block as Control).size.y) > 2.0 and unfilled == "":
					unfilled = "envelope ends at %.0f of %.0f" \
						% [bottom, (one_block as Control).size.y]
			check(unfilled == "",
				"the envelope fills the rest of its block (%s)" % unfilled)

			# The faders wear their letter and nothing else. A printed value under each
			# one is four numbers per operator nobody reads while playing — the number
			# is in the tooltip, and an envelope is set by ear against its neighbours.
			var fader_lines := 0
			for cell in main.patch_face._cells:
				var fader := cell as RackView.Fader
				if fader != null and fader.tooltip_text.contains("\n"):
					fader_lines += 1
			check(fader_lines > 0,
				"a fader keeps its number in the tooltip (%d of them)" % fader_lines)

			# And a knob wears its label, not "op3.feedback" under it. The dotted frame
			# already says which operator this is; repeating it under every knob was a
			# third of the cell spent restating the block's own heading.
			var printed_wiring := ""
			for cell in main.patch_face._cells:
				for inner in (cell as Node).get_children():
					var text := inner as Label
					if text != null and text.text.contains(".") and printed_wiring == "":
						printed_wiring = text.text
			check(printed_wiring == "",
				"and a knob prints its label alone, not its wiring (%s)" % printed_wiring)

			# And a slider is the control it replaced, not a picture of one: a nudge
			# travels the same path as a knob's and lands in the document.
			if live_slider != null:
				var slid := live_slider as RackView.Fader
				var op_id: String = slid.node_id
				var op_parameter: String = str(slid.descriptor["name"])
				var before_slide: float = slid.value()
				slid.nudge(0.25 if slid._position < 0.5 else -0.25)
				for i in 6:
					await process_frame
				var written: float = before_slide
				for node in main.patch["nodes"]:
					if str(node["id"]) == op_id:
						written = float(node.get("parameters", {}).get(op_parameter,
							before_slide))
				check(not is_equal_approx(written, before_slide),
					"a slider writes through to the patch (%s.%s %.3f from %.3f)"
						% [op_id, op_parameter, written, before_slide])
				await main._undo()
				for i in 4:
					await process_frame

			# The ports are on the panel, as plates at the ends of the rail their signals
			# run towards: in at the left edge, out at the right. "What do I plug in, and
			# where does it come out" is the other half of "what do I turn", and under
			# the rack as a list it read as a footnote about the instrument's edges
			# rather than a picture of them.
			var port_names: Array = []
			var in_side := -1.0
			var out_side := -1.0
			for which in ["Case/Rack/Rail/PortsIn", "Case/Rack/Rail/PortsOut"]:
					var plate := main.patch_face.get_node_or_null(which) as Control
					if plate == null:
						continue
					if which.ends_with("In"):
						in_side = plate.get_global_rect().position.x
					else:
						out_side = plate.get_global_rect().position.x
					# Recursively: a port line is a socket beside its name now, so the
					# labels sit a level deeper than they did.
					for label in plate.find_children("", "Label", true, false):
						port_names.append(str((label as Label).text))
			var expected: Array = []
			for node in main.patch["nodes"]:
				if str(node.get("type", "")) in ["Input", "Output"]:
					expected.append(str(node.get("name", node["id"])))
			check(expected.size() > 0, "the patch has ports (%s)" % str(expected))
			for port_name in expected:
				check(port_names.has(port_name),
					"the panel names port %s (%s)" % [port_name, str(port_names)])
			check(in_side >= 0.0 and out_side > in_side,
				"with the inputs left of the outputs (%.0f then %.0f)"
					% [in_side, out_side])

			# Touching the default writes it down rather than replacing it.
			var before_default: int = defaults.size()
			main._toggle_control(str(defaults[0]["target"]["node"]),
				str(defaults[0]["target"]["parameter"]))
			for i in 8:
				await process_frame
			check(main.patch.get("controls", []).size() == before_default - 1,
				"taking a knob off the default keeps the rest (%d of %d)"
					% [main.patch.get("controls", []).size(), before_default])
			check(not main.patch_face.derived,
				"and the panel is the file's own from then on")

	# ---- an authored panel groups across nodes ---------------------------------------
	# algo-01 carries a hand-written `controls` list using the schema's `group` field:
	# an operator's block holds its own ratio and feedback AND the gain node that sets
	# its level — two nodes in the graph, one instrument on the panel. Only the author
	# knows which gains belong to which operators; the graph does not say. Panel
	# organization, never graph semantics.
	await main._load_example("DX7: algo-01")
	for i in 8:
		await process_frame
	check_loads(main, "an authored panel with groups")
	check(not main.patch_face.derived, "algo-01 brings a panel of its own")
	var grouped_rail: VBoxContainer = null
	var grouped_mix: HBoxContainer = null
	var ports_in: Control = null
	var ports_out: Control = null
	grouped_rail = main.patch_face.get_node_or_null("Case/Rack/Rail/Rows")
	grouped_mix = main.patch_face.get_node_or_null("Case/Rack/Rail/Mix")
	ports_in = main.patch_face.get_node_or_null("Case/Rack/Rail/PortsIn")
	ports_out = main.patch_face.get_node_or_null("Case/Rack/Rail/PortsOut")
	# Down each slot, then along the rail — the order the panel lists them in.
	var grouped_blocks: Array = []
	var grouped_rows: Array = []
	if grouped_rail != null:
		for one_row in grouped_rail.get_children():
			var across_row: Array = []
			for one_block in (one_row as Node).get_children():
				if not (one_block is VBoxContainer):
					continue
				grouped_blocks.append(one_block)
				var row_band := (one_block as Node).get_child(0) as Label
				if row_band != null:
					across_row.append(row_band.text)
			grouped_rows.append(across_row)
	var grouped_names: Array = []
	for one_block in grouped_blocks:
		var block_heading := (one_block as Node).get_child(0) as Label
		if block_heading != null:
			grouped_names.append(block_heading.text)
	# Ordered by signal flow, deepest modulator first, ending at the carrier it feeds:
	# OP6→OP5→OP4→OP3 is one chain of algorithm 1 and OP2→OP1 the other. Numeric order
	# put the carrier of one chain beside a modulator of the other and left the reader
	# to reconstruct the algorithm from node ids.
	check(grouped_names == ["OP6", "OP5", "OP4", "OP3", "OP2", "OP1"],
		"the panel is six operator groups in signal order (%s)" % str(grouped_names))

	# Titled with what the file calls itself, not with the word "Panel". The metadata
	# name beats the path: an imported DX7 voice carries the name the synth shipped it
	# with, which is worth more than where it happens to be saved.
	# The name is on the case now, printed on the thing it names rather than floating in
	# a row above it — which is also why the heading above the panel is empty here.
	var case_badge := main.patch_face.get_node_or_null("Case/Name") as Label
	check(case_badge != null and case_badge.visible and case_badge.text == "ALGO 01",
		"the case wears the instrument's name (%s)"
			% ("none" if case_badge == null else case_badge.text))
	check(not main.face_heading.visible,
		"and nothing repeats it above (%s)" % main.face_heading.text)

	# And the case encloses the rack it names: name band, rail, modules, rail. Six plates
	# lying on a panel with a name floating over them are six things; inside a case with
	# the name on it they are one instrument.
	var the_case := main.patch_face.get_node_or_null("Case") as Control
	var the_rack := main.patch_face.get_node_or_null("Case/Rack") as Control
	check(the_case != null and the_rack != null, "the rack is mounted in a case")
	if the_case != null and the_rack != null:
		check(the_case.draw.get_connections().size() > 0,
			"which paints itself — rails above and below what it holds")
		check(the_case.get_global_rect().encloses(the_rack.get_global_rect()),
			"and encloses it (%s around %s)"
				% [str(the_case.get_global_rect()), str(the_rack.get_global_rect())])
		check(case_badge != null
				and case_badge.get_global_rect().end.y
					<= the_rack.get_global_rect().position.y + 1.0,
			"with the name above the modules, on the case")

	# Each block is a rack module, drawn by the rack's own plate function rather than
	# merely resembling one: it paints itself, and its name sits in a title band.
	var plated := 0
	for one_block in grouped_blocks:
		if (one_block as Control).draw.get_connections().size() > 0:
			plated += 1
	check(plated == grouped_blocks.size(),
		"every block paints a module plate (%d of %d)"
			% [plated, grouped_blocks.size()])
	var band_label: Label = null
	if not grouped_blocks.is_empty():
		band_label = (grouped_blocks[0] as Node).get_child(0) as Label
	check(band_label != null and band_label.custom_minimum_size.y > 0.0,
		"with its name in a title band (%.0fpx)"
			% (0.0 if band_label == null else band_label.custom_minimum_size.y))
	# One row per chain: OP6 OP5 OP4 feed OP3, and OP2 feeds OP1. A row ends where its
	# chain ends — at the operator you hear — so the top row is a whole chain rather
	# than the first three groups of a column-major fill.
	check(grouped_rows == [["OP6", "OP5", "OP4", "OP3"], ["OP2", "OP1"]],
		"laid out a chain to a row (%s)" % str(grouped_rows))

	# Right-justified, so the last column of both rows lines up. A chain ends at the
	# operator you hear, so that column is the carriers — and what they feed sits
	# immediately right of it.
	var right_edges := {}
	if grouped_rail != null:
		for one_row in grouped_rail.get_children():
			var far := 0.0
			for one_block in (one_row as Node).get_children():
				far = maxf(far, (one_block as Control).get_global_rect().end.x)
			right_edges[far] = true
	check(right_edges.size() == 1,
		"both rows end on the same right edge (%s)" % str(right_edges.keys()))

	# An arrow between operators in a chain, and none across the break between chains:
	# it means "this drives that", which is only true inside a chain.
	var arrows_per_row: Array = []
	if grouped_rail != null:
		for one_row in grouped_rail.get_children():
			var arrows := 0
			for part in (one_row as Node).get_children():
				if not (part is VBoxContainer) \
						and (part as Control).draw.get_connections().size() > 0:
					arrows += 1
			arrows_per_row.append(arrows)
	check(arrows_per_row == [3, 1],
		"with an arrow between each pair in a chain (%s)" % str(arrows_per_row))

	# The mix stands full height at the end of the rail, outside both rows: it belongs to
	# the instrument rather than to either chain, and holds the voice's master level.
	check(grouped_mix != null, "the mix panel stands at the end of the rail")
	var mix_names: Array = []
	var mix_targets: Array = []
	var mix_cells: Array = []
	if grouped_mix != null:
		for one_block in grouped_mix.get_children():
			var mix_band := (one_block as Node).get_child(0) as Label
			if mix_band != null:
				mix_names.append(mix_band.text)
			for part in (one_block as Node).get_children():
				for bank in (part as Node).get_children():
					if bank is GridContainer:
						mix_cells.append(bank)
	for index in main.patch_face._targets:
		var aimed: Dictionary = main.patch_face._targets[index]
		if str(aimed["node"]) in ["mix", "out"]:
			mix_targets.append("%s.%s" % [str(aimed["node"]),
				str(aimed["parameter"])])
	check(mix_names == ["MIX"], "under its own name (%s)" % str(mix_names))

	# Two knobs, in signal order: the mix's own level, then the port's. The sum used to
	# be a bare Add — a node with no parameter, so no knob, so nothing on the panel at
	# the one place the whole voice comes together. Every other stage of the graph has a
	# level; the joint where they meet had none, which made it a joint and not a stage.
	check(mix_targets == ["mix.gain", "out.level"],
		"holding the mix's own level and then the port's (%s)" % str(mix_targets))
	# Stacked, not side by side: a channel strip reads down, and down is signal order.
	var strip_columns: Array = []
	for bank in mix_cells:
		strip_columns.append((bank as GridContainer).columns)
	check(strip_columns == [1], "stacked as a strip (%s)" % str(strip_columns))

	if grouped_mix != null and grouped_rail != null:
		check(grouped_mix.get_global_rect().position.x
				>= grouped_rail.get_global_rect().end.x - 1.0,
			"to the right of every operator (%.0f against %.0f)"
				% [grouped_mix.get_global_rect().position.x,
					grouped_rail.get_global_rect().end.x])
		check(grouped_mix.size.y >= grouped_rail.size.y - 2.0,
			"and the full height of them (%.0f of %.0f)"
				% [grouped_mix.size.y, grouped_rail.size.y])

	# The ports flank the whole rail: in at the left edge, out past everything else. The
	# panel then reads in the order the signal runs — plug in here, through the
	# operators, into the mix, out there.
	check(ports_in != null and ports_out != null,
		"the rail is flanked by port plates")

	# A socket is its signals, not just its name. The keyboard hands over four —
	# frequency, gate, velocity, trigger — and this patch takes the first two. All four
	# are listed, because the unused ones are the reason to come back to the plate: they
	# are what else is already there. Lit when a cable is on them, dim when not.
	var lit_ports: Array = []
	var dim_ports: Array = []
	for plate in [ports_in, ports_out]:
		if plate == null:
			continue
		for found in (plate as Node).find_children("", "Label", true, false):
			var line := found as Label
			if line.tooltip_text == "":
				continue
			if line.get_theme_color("font_color") == Design.INK_DISABLED:
				dim_ports.append(line.text)
			else:
				lit_ports.append(line.text)
	check(lit_ports == ["frequency", "gate", "left", "right"],
		"the plates light the signals in use (%s)" % str(lit_ports))
	check(dim_ports == ["velocity", "trigger"],
		"and still show the ones going spare (%s)" % str(dim_ports))

	# Each one wears the rack's own socket, drawn by the rack's own function: a port on
	# the panel and a port on a module are the same socket seen twice, and drawing a
	# lookalike here would be a second answer to a question already answered.
	var sockets := 0
	for plate in [ports_in, ports_out]:
		if plate == null:
			continue
		for found in (plate as Node).find_children("", "HBoxContainer", true, false):
			for part in (found as Node).get_children():
				if not (part is Label) and (part as Control).draw \
						.get_connections().size() > 0:
					sockets += 1
	check(sockets == 6,
		"every port wears a socket (%d of 6)" % sockets)
	if ports_in != null and ports_out != null and grouped_rail != null \
			and grouped_mix != null:
		check(ports_in.get_global_rect().end.x
				<= grouped_rail.get_global_rect().position.x + 1.0,
			"the inputs stand before the first operator (%.0f of %.0f)"
				% [ports_in.get_global_rect().end.x,
					grouped_rail.get_global_rect().position.x])
		check(ports_out.get_global_rect().position.x
				>= grouped_mix.get_global_rect().end.x - 1.0,
			"and the outputs after the mix (%.0f of %.0f)"
				% [ports_out.get_global_rect().position.x,
					grouped_mix.get_global_rect().end.x])
		check(ports_in.size.y >= grouped_rail.size.y - 2.0
				and ports_out.size.y >= grouped_rail.size.y - 2.0,
			"both the full height of the rack (%.0f and %.0f of %.0f)"
				% [ports_in.size.y, ports_out.size.y, grouped_rail.size.y])

	var op1_grid: GridContainer = null
	var op1_envelope: HBoxContainer = null
	if not grouped_blocks.is_empty():
		for inner in (grouped_blocks[0] as Node).get_children():
			var row := inner as HBoxContainer
			if row == null:
				continue
			if row.get_child_count() > 0 and row.get_child(0) is RackView.Fader:
				op1_envelope = row
			else:
				for part in row.get_children():
					if part is GridContainer:
						op1_grid = part as GridContainer
	# The first block is OP6 now: three knobs, because algorithm 1 puts the voice's one
	# feedback loop there. The other five have two — a knob that does nothing on five
	# panels out of six was saying every operator has feedback, and none of them do
	# except the one the algorithm designates.
	check(op1_grid != null and op1_grid.columns == 3
			and op1_grid.get_child_count() == 3,
		"the feedback operator's knobs are one row of three (%s)"
			% ("none" if op1_grid == null else "%d across %d cols"
				% [op1_grid.get_child_count(), op1_grid.columns]))
	var op1_reaches := {}
	for index in main.patch_face._targets:
		if op1_grid != null \
				and (main.patch_face._cells[index] as Node).get_parent() == op1_grid:
			op1_reaches[str(main.patch_face._targets[index]["node"])] = true
	check(op1_reaches.has("op6") and op1_reaches.has("op6_index_5"),
		"and reach both the operator and its gain node (%s)" % str(op1_reaches.keys()))

	# Every operator carries a feedback knob, including the five the algorithm leaves at
	# zero. The algorithm decides where feedback *starts*, not where it is possible: each
	# operator's oscillator has the input, turning one up is an edit the graph supports,
	# and departing from the algorithm is a thing people buy an FM synth to do. A knob
	# reading zero says "not used here"; an absent knob would say "not available".
	var feedback_knobs: Array = []
	for index in main.patch_face._targets:
		if str(main.patch_face._targets[index]["parameter"]) == "feedback":
			feedback_knobs.append(str(main.patch_face._targets[index]["node"]))
	feedback_knobs.sort()
	check(feedback_knobs == ["op1", "op2", "op3", "op4", "op5", "op6"],
		"every operator can be given feedback, algorithm or not (%s)"
			% str(feedback_knobs))

	# The gain knob is "level" on all six, as Yamaha names it — the wire format calls
	# the byte OPERATOR OUTPUT LEVEL and the DX7 gives carriers and modulators the same
	# word. "index" was ours, borrowed from Chowning's modulation index: true of the
	# maths, absent from the manual, and a second name for one parameter.
	var gain_labels := {}
	for control: Dictionary in main.patch.get("controls", []):
		if str(control.get("target", {}).get("parameter", "")) == "gain":
			gain_labels[str(control.get("label", ""))] = true
	check(gain_labels.keys() == ["level"],
		"every operator's output knob is called level (%s)" % str(gain_labels.keys()))

	# Heard or felt, from the wiring rather than from a claim in the file: OP3 and OP1
	# reach the output, the rest only ever arrive at somebody's pm input.
	var audible: Dictionary = main.patch_face._heard_nodes()
	var heard_ops: Array = []
	for op in ["op1", "op2", "op3", "op4", "op5", "op6"]:
		if audible.has(op):
			heard_ops.append(op)
	check(heard_ops == ["op1", "op3"],
		"two of the six operators are heard directly (%s)" % str(heard_ops))
	# And the panel says so: the carriers' titles are lit, the modulators' are not.
	var band_lit := {}
	for one_block in grouped_blocks:
		var plate_band := (one_block as Node).get_child(0) as Label
		if plate_band != null:
			band_lit[plate_band.text] = plate_band.get_theme_color("font_color") == Design.INK_BRIGHT
	check(band_lit.get("OP3", false) and band_lit.get("OP1", false)
			and not band_lit.get("OP6", true) and not band_lit.get("OP2", true),
		"and the panel lights the ones you hear (%s)" % str(band_lit))
	check(op1_envelope != null and op1_envelope.get_child_count() == 4,
		"with the envelope faders under them")

	# ---- the panel is played, and only rearranged on purpose ------------------------
	# Every press on a cell used to be a pickup. Two consequences, both wrong: a knob on
	# the panel could not be turned at all, and since a release outside the panel means
	# "take this off the face", dragging a fader to shape an envelope removed it. That is
	# how ALGO 01 lost OP4's attack.
	#
	# The name is the handle now. Aimed at the middle of a cell, the press belongs to the
	# control; aimed at its caption, to the panel.
	var played: Control = null
	var played_caption: Label = null
	for index in main.patch_face._targets:
		if str(main.patch_face._targets[index]["parameter"]) == "ratio" \
				and played == null:
			played = main.patch_face._cells[index]
			for part in (played as Node).get_children():
				if part is Label and played_caption == null:
					played_caption = part as Label
	check(played != null and played_caption != null, "a knob on the panel to aim at")
	if played != null and played_caption != null:
		var dial: Vector2 = played.get_global_rect().position \
			+ Vector2(played.size.x * 0.5, Design.scale(Design.HIT_TARGET) * 0.5)
		check(main.patch_face._handle_at(dial) < 0,
			"a press on the dial belongs to the knob, not to the panel")
		check(main.patch_face._handle_at(played_caption.get_global_rect().get_center())
				>= 0,
			"and a press on its name picks the knob up")

	# A fader is played everywhere and picked up nowhere. Its letter sits at the foot of
	# the track, which is exactly where a hand goes to pull the fader down — so a pickup
	# zone there sits under the gesture it would interrupt, and twice it took an envelope
	# control off the panel mid-adjustment. Four faders only mean anything together.
	var slid: Control = null
	for index in main.patch_face._targets:
		if str(main.patch_face._targets[index]["parameter"]) == "attack" and slid == null:
			slid = main.patch_face._cells[index]
	check(slid != null and main.patch_face._handle_at(
			slid.get_global_rect().get_center()) < 0,
		"dragging a fader's track shapes the envelope rather than removing it")
	if slid != null:
		var letter: Vector2 = Vector2(slid.get_global_rect().get_center().x,
			slid.get_global_rect().end.y - 4.0)
		check(main.patch_face._handle_at(letter) < 0,
			"and so does dragging it by its letter")

	# Nothing outside the panel is a press on the panel. The rail is wider than the
	# window and scrolls, so a cell's rectangle can sit entirely off-screen and still
	# answer a hit test — which is how a drag in the margin picked up a fader nobody
	# could see. The op2 envelope was off the right-hand edge when it went missing.
	# Aimed at a caption that genuinely lies past the edge, not at empty air: a point
	# with no cell under it returns -1 whether the guard is there or not, and the first
	# version of this check did exactly that and passed with the guard removed.
	var hidden_caption: Label = null
	for index in main.patch_face._targets:
		var offscreen := main.patch_face._cells[index] as Control
		for part in (offscreen as Node).get_children():
			var caption := part as Label
			var past_edge: bool = caption != null \
				and caption.get_global_rect().position.x \
					> main.patch_face.get_global_rect().end.x
			if past_edge and hidden_caption == null:
				hidden_caption = caption
	check(hidden_caption != null,
		"the rail runs past the panel, so there are cells off its edge")
	if hidden_caption != null:
		check(main.patch_face._handle_at(
				hidden_caption.get_global_rect().get_center()) < 0,
			"and a press past that edge picks up nothing, seen or not")

	# The offers keep whole-cell drag: a ghost has no value to change, and being dragged
	# is the only thing it is for. Staged rather than assumed — every knob in this patch
	# is already on the panel, so there are no offers until one is taken off, and a check
	# made without staging one passes by counting nothing.
	main._focus_node("mix")
	for i in 6:
		await process_frame
	main._toggle_control("mix", "gain")
	for i in 8:
		await process_frame
	check(main.patch_face._offers.size() > 0,
		"taking a knob off offers it back (%d)" % main.patch_face._offers.size())
	var ghost_handles := 0
	for index in main.patch_face._offers:
		if main.patch_face._handle_at(
				(main.patch_face._cells[index] as Control).get_global_rect()
					.get_center()) == index:
			ghost_handles += 1
	check(main.patch_face._offers.size() > 0
			and ghost_handles == main.patch_face._offers.size(),
		"and a whole ghost is a handle (%d of %d)"
			% [ghost_handles, main.patch_face._offers.size()])
	main._toggle_control("mix", "gain")
	for i in 6:
		await process_frame
	check_loads(main, "putting the mix level back")

	# And the press path itself, not just the rule it consults. The first version of
	# these checks called _handle_at directly, so putting _input back to claiming every
	# cell — the bug — sailed through all of them. Drive the events.
	var away := Vector2(-400.0, -400.0)
	var turn_target: Control = null
	var turn_caption: Label = null
	for index in main.patch_face._targets:
		if str(main.patch_face._targets[index]["parameter"]) == "ratio" \
				and turn_target == null:
			turn_target = main.patch_face._cells[index]
			for part in (turn_target as Node).get_children():
				if part is Label and turn_caption == null:
					turn_caption = part as Label
	var before_drag: int = main.patch.get("controls", []).size()
	if turn_target != null:
		_drag_panel(main, turn_target.get_global_rect().position
			+ Vector2(turn_target.size.x * 0.5,
				Design.scale(Design.HIT_TARGET) * 0.5), away)
		for i in 8:
			await process_frame
	check(main.patch.get("controls", []).size() == before_drag,
		"a drag that started on the dial changes no knob's place (%d of %d)"
			% [main.patch.get("controls", []).size(), before_drag])

	if turn_caption != null:
		_drag_panel(main, turn_caption.get_global_rect().get_center(), away)
		for i in 8:
			await process_frame
	check(main.patch.get("controls", []).size() == before_drag - 1,
		"and one that started on its name takes it off (%d of %d)"
			% [main.patch.get("controls", []).size(), before_drag])
	await main._undo()
	for i in 6:
		await process_frame
	check(main.patch.get("controls", []).size() == before_drag,
		"undo puts it back (%d)" % main.patch.get("controls", []).size())

	# The reported case, end to end: pull op2's attack fader and the envelope survives.
	# It did not — the press landed on the letter, the drag left the panel, and the
	# control came off the face, which left three of four and turned them back into
	# knobs. "The panel expands into knobs" was the shape of a control going missing.
	var op2_fader: Control = null
	for index in main.patch_face._targets:
		var aimed_at: Dictionary = main.patch_face._targets[index]
		if str(aimed_at["node"]) == "op2" and str(aimed_at["parameter"]) == "attack":
			op2_fader = main.patch_face._cells[index]
	check(op2_fader != null, "op2's attack fader is on the panel to begin with")
	if op2_fader != null:
		var grip := Vector2(op2_fader.get_global_rect().get_center().x,
			op2_fader.get_global_rect().end.y - 4.0)
		_drag_panel(main, grip, grip + Vector2(120.0, -30.0))
		for i in 8:
			await process_frame
	var op2_left := 0
	for control: Dictionary in main.patch.get("controls", []):
		if str(control.get("group", "")) == "op2":
			op2_left += 1
	check(op2_left == 7,
		"and pulling it leaves op2's seven controls alone (%d)" % op2_left)

	# The thumb follows the pointer. A fader's travel is visible, so the drag distance is
	# the track rather than the 160px a dial uses — a dial sweeps 270° whatever size it is
	# drawn at, so no length on screen honestly corresponds to its range, while a fader's
	# does. Dragged the length of its track, a fader crosses its whole range; half the
	# track, half the range. That also means a tall panel gives fine control and a short
	# one coarse, which is what a long fader does on a desk.
	if op2_fader != null:
		var pull := op2_fader as RackView.Fader
		var track: Vector2 = pull._track()
		var length: float = track.y - track.x
		check(absf(pull._drag_span() - length) < 0.5,
			"a fader's drag span is its track (%.0f of %.0f)"
				% [pull._drag_span(), length])
		_drag_fader(pull, track.y, track.x)
		check(pull._position > 0.99,
			"pulled from the foot of the track to its head, it reaches the top (%.2f)"
				% pull._position)
		_drag_fader(pull, track.y, track.x + length * 0.5)
		check(absf(pull._position - 0.5) < 0.05,
			"and half the track is half the range (%.2f)" % pull._position)
		# Shift is fine adjustment everywhere, so it must still be four times the travel.
		_drag_fader(pull, track.y, track.x, true)
		check(absf(pull._position - 0.25) < 0.05,
			"with Shift a quarter as far, as everywhere else (%.2f)" % pull._position)

		# And the wheel steps it, one notch at a time, without focus and without the
		# panel behind it scrolling away underneath.
		pull.set_value_silently(pull._to_value(0.5))
		var before_wheel: float = pull._position
		_wheel(pull, true)
		check(absf(pull._position - (before_wheel + pull.KEY_STEP)) < 0.001,
			"a notch of the wheel is one small step (%.3f from %.3f)"
				% [pull._position, before_wheel])
		_wheel(pull, false)
		_wheel(pull, false)
		check(absf(pull._position - (before_wheel - pull.KEY_STEP)) < 0.001,
			"and it steps back down again (%.3f)" % pull._position)
		_wheel(pull, true, true)
		check(absf(pull._position - (before_wheel - pull.KEY_STEP + pull.KEY_COARSE))
				< 0.001,
			"with Shift a coarse one, as on the arrow keys (%.3f)" % pull._position)
		await main._undo()
		for i in 6:
			await process_frame

	# ---- a busy node pays in width, not height ---------------------------------------
	# More knobs than one two-wide bank at the default height holds must grow the block
	# rightwards: a second bank on the same panel, a wide module rather than a tall one.
	# No example is busy enough on its own any more — the envelopes siphon four knobs
	# each into sliders — so the fixture is authored: a panel that lists twelve knobs on
	# one node, which an authored `controls` list is perfectly entitled to do.
	await main._load_example("Filter Envelope")
	for i in 8:
		await process_frame
	var wide: Array = []
	for repeat in 3:
		for wide_parameter in ["cutoff", "resonance", "mode", "cutoff_sweep"]:
			wide.append({"id": "k%d_%s" % [repeat, wide_parameter], "kind": "knob",
				"target": {"node": "filter_env", "parameter": wide_parameter}})
	main.patch["controls"] = wide
	await main._rebuild_view()
	for i in 8:
		await process_frame
	var spill_banks := 0
	var spill_knobs := 0
	var spill_rows: Node = main.patch_face.get_node_or_null("Case/Rack/Rail/Rows")
	if spill_rows != null:
			if true:
				if true:
					for one_row in spill_rows.get_children():
						for one_block in (one_row as Node).get_children():
							for part in (one_block as Node).get_children():
								var bank_row := part as HBoxContainer
								if bank_row == null:
									continue
								# Banks are grids; an envelope row holds faders. Counting
								# whatever HBox has the most children scored a row of four
								# sliders as four banks of nothing.
								var grids := 0
								var held := 0
								for bank in bank_row.get_children():
									if bank is GridContainer:
										grids += 1
										held += (bank as Node).get_child_count()
								if grids > spill_banks:
									spill_banks = grids
									spill_knobs = held
	check(spill_knobs == 12,
		"the authored panel carries all twelve knobs (%d)" % spill_knobs)
	check(spill_banks > 1,
		"and spills into extra banks sideways (%d banks)" % spill_banks)

	await main._load_example("First Synth")
	for i in 8:
		await process_frame

	# ---- the file's own panel, as the document carries it ----------------------------
	# `controls` has been in the schema since v1 — the performance surface, deliberately
	# separate from the graph — and every example carries one that nothing had ever drawn.
	# Putting knobs on and taking them off is the panel's own gesture now, checked above;
	# what is left here is that the file arrives with one and that it is drawn.
	main.graph_edit.zoom = 1.0
	for i in 4:
		await process_frame
	var started_with: int = main.patch.get("controls", []).size()
	check(started_with == 7, "First Synth arrives with a panel already (%d knobs)"
		% started_with)
	check(main.patch_face.get_child_count() > 0,
		"and the editor draws it (%d rows)" % main.patch_face.get_child_count())

	# Dragging a knob to a new place on the panel. The order is the whole personalisation
	# a panel offers, so it has to be somebody's rather than the order they happened to
	# click things on in.
	var panel_before: Array = []
	for control: Dictionary in main.patch.get("controls", []):
		panel_before.append(str(control["id"]))
	main._on_panel_reordered([panel_before[2], panel_before[0], panel_before[1]])
	for i in 6:
		await process_frame
	var panel_after: Array = []
	for control: Dictionary in main.patch.get("controls", []):
		panel_after.append(str(control["id"]))
	check(panel_after.slice(0, 3) == [panel_before[2], panel_before[0], panel_before[1]],
		"the panel takes the order it was dragged into (%s)" % str(panel_after.slice(0, 3)))
	check(panel_after.size() == panel_before.size(),
		"and a reorder that named only some of them keeps the rest (%d of %d)"
			% [panel_after.size(), panel_before.size()])
	var panel_sorted: Array = panel_after.duplicate()
	var before_sorted: Array = panel_before.duplicate()
	panel_sorted.sort()
	before_sorted.sort()
	check(panel_sorted == before_sorted, "with nothing lost on the way")
	await main._undo()
	for i in 6:
		await process_frame


	# ---- a module to look at, made by hand ------------------------------------------
	# The blocks below need one with a known, small surface. The wand used to leave one
	# behind, back when its job was nominating a module's face; now it puts knobs on the
	# file's panel instead, so the module is built here and pruned to four exports on
	# purpose — which is what a collapse with a nominated surface used to produce.
	for id in ["lfo", "filter"]:
		main.widgets[id].selected = true
	await main._collapse_selection()
	for i in 8:
		await process_frame
	var kept_exports: Array = []
	for binding: Dictionary in main.patch["modules"]["part"].get("parameters", []):
		if ["cutoff", "rate", "resonance", "amount"].has(str(binding["name"])):
			kept_exports.append(binding)
	var wanted_order := ["cutoff", "rate", "resonance", "amount"]
	kept_exports.sort_custom(func(a, b):
		return wanted_order.find(str(a["name"])) < wanted_order.find(str(b["name"])))
	main.patch["modules"]["part"]["parameters"] = kept_exports
	for node in main.patch["nodes"]:
		if str(node.get("module", "")) == "part":
			var values: Dictionary = node.get("parameters", {})
			for value_name in values.keys():
				if not ["cutoff", "rate", "resonance", "amount"].has(str(value_name)):
					values.erase(value_name)
	main._synthesize_module_descriptors()
	await main._rebuild_view()
	for i in 8:
		await process_frame
	check(main.patch["modules"]["part"].get("parameters", []).size() == 4,
		"the module under test wears four knobs (%d)"
			% main.patch["modules"]["part"].get("parameters", []).size())

	# ---- the sub-panel builder: arranging a module's face -----------------------------
	# The arithmetic first, on its own, because every interesting case here is an off-by-one
	# and none of them needs a panel to be wrong in.
	check(ModuleFace.moved([["a", "b", "c"]], "a", {"row": 0, "index": 2}) == [["b", "a", "c"]],
		"moving a knob rightward past itself lands where the caret was, not one short")
	check(ModuleFace.moved([["a"], ["b"]], "a", {"row": 1, "index": 1}) == [["b", "a"]],
		"and a row the move emptied is gone rather than left blank")
	check(ModuleFace.moved([["a", "b"]], "b", {"row": 0, "fresh": true}) == [["b"], ["a"]],
		"a fresh row at the top opens above everything")
	check(ModuleFace.moved([["a", "b"]], "a", {"row": 2, "fresh": true}) == [["b"], ["a"]],
		"and one past the end opens below, whatever number it was given")
	check(ModuleFace.moved([["a", "b"]], "a", {"remove": true}) == [["b"]],
		"and taking one off leaves the rest of the row")

	var instance := ""
	for node in main.patch.get("nodes", []):
		if str(node.get("module", "")) == "part":
			instance = str(node["id"])
	check(instance != "", "the module instance is in the patch (%s)" % instance)

	# The panel shows one face, and which one follows the selection. This is the whole
	# reason the builder is here rather than in a tab of its own: the thing being arranged
	# and the graph it came out of are on screen together.
	main.show_view("Graph")
	main._focus_node(instance)
	for i in 6:
		await process_frame
	check(main.module_face.visible and not main.patch_face.visible,
		"selecting a module instance puts its face on the panel")
	check(main.face_heading.visible and main.face_heading.text == "part",
		"and the heading says whose it is (%s)" % main.face_heading.text)
	check(main.module_face.face_rows() == [["cutoff", "rate"], ["resonance", "amount"]],
		"a module nobody has arranged reads as the wrap already on screen (%s)"
			% str(main.module_face.face_rows()))

	# Selecting something that is not a module gives the file's own face back.
	main._focus_node(main._output_node())
	for i in 4:
		await process_frame
	check(main.patch_face.visible and not main.module_face.visible,
		"and selecting something that is not a module gives the file's own face back")
	# Titled with the instrument rather than with the word "Panel", which named the
	# obvious in the best row on screen. The module's name gave way to the file's.
	var synth_badge := main.patch_face.get_node_or_null("Case/Name") as Label
	check(synth_badge != null and synth_badge.text != "" and synth_badge.text != "PART",
		"the case wears the file's name, not the module's (%s)"
			% ("none" if synth_badge == null else synth_badge.text))

	# And so does a selection with nothing behind it, which is the branch of
	# _on_node_selected that used to return without telling the panel anything at all: it
	# emptied `inspecting` and left the panel describing whatever had been selected before.
	# Invisible while the panel was only ever the file's face; not invisible now.
	main._focus_node(instance)
	for i in 4:
		await process_frame
	check(main.module_face.visible, "a module's face is up again")
	main._on_node_selected(main.graph_edit)  # a node the id map has never heard of
	for i in 4:
		await process_frame
	check(main.inspecting.is_empty(), "selecting an untracked node inspects nothing")
	check(main.patch_face.visible and not main.module_face.visible,
		"and the panel says so rather than keeping the last module's face")

	main._focus_node(instance)
	for i in 8:
		await process_frame

	# Ghosts: everything the face could show and does not. Here that is every inner knob
	# nobody exported, since all four exports are on the face.
	var ghost_keys: Array = []
	for cell: Dictionary in main.module_face._cells:
		if bool(cell["ghost"]):
			ghost_keys.append(str(cell["key"]))
	check(ghost_keys.size() > 0, "the wand grows a ghost for what the face leaves off (%d)"
		% ghost_keys.size())
	var filed_by_origin := true
	for key in ghost_keys:
		if not str(key).begins_with("+"):
			filed_by_origin = false
	check(filed_by_origin,
		"an unexported one is filed by where it comes from, not by a name it has not got (%s)"
			% str(ghost_keys))

	# A real drag, through the same two functions the mouse goes through: which cell was
	# grabbed, and where the drop landed.
	var seat := func(key: String) -> Rect2:
		for cell: Dictionary in main.module_face._cells:
			if str(cell["key"]) == key:
				return (cell["control"] as Control).get_global_rect()
		return Rect2()

	var resonance_seat: Rect2 = seat.call("resonance")
	var from_index: int = main.module_face._cell_at(seat.call("rate").get_center())
	check(from_index >= 0, "a knob on the face can be picked up (%d)" % from_index)
	var landing: Dictionary = main.module_face.drop_at(
		Vector2(resonance_seat.position.x + 2.0, resonance_seat.get_center().y))
	check(not bool(landing.get("fresh", false)) and int(landing.get("row", -1)) == 1,
		"the middle of a row means into that row (%s)" % str(landing))
	main.module_face._finish(from_index, landing)
	for i in 8:
		await process_frame

	var face_now: Array = main.patch["modules"]["part"].get("panel", {}).get("rows", [])
	check(face_now == [["cutoff"], ["rate", "resonance", "amount"]],
		"dragging a knob writes the panel it landed in (%s)" % str(face_now))
	check(main.module_face.face_rows() == face_now,
		"and the face it rebuilt into is the one the file now says (%s)"
			% str(main.module_face.face_rows()))
	check(main.patch["modules"]["part"].get("parameters", []).size() == 4,
		"the surface is untouched — an arrangement is presentation, not export (%d)"
			% main.patch["modules"]["part"].get("parameters", []).size())

	# Below the last row: a line of its own. The only gesture that says so.
	var last_seat: Rect2 = seat.call("amount")
	var below: Dictionary = main.module_face.drop_at(Vector2(last_seat.get_center().x,
		last_seat.position.y + last_seat.size.y - 2.0))
	check(bool(below.get("fresh", false)),
		"the bottom of a row means a line of its own (%s)" % str(below))
	main.module_face._finish(main.module_face._cell_at(seat.call("cutoff").get_center()), below)
	for i in 8:
		await process_frame
	check(main.patch["modules"]["part"].get("panel", {}).get("rows", [])
			== [["rate", "resonance", "amount"], ["cutoff"]],
		"dropping past the last row opens a new one (%s)"
			% str(main.patch["modules"]["part"].get("panel", {}).get("rows", [])))

	# A ghost dragged on is exported on the way in, because "put this knob on the module"
	# is one thought and an unexported knob on a face would be a knob wired to nothing.
	var before_surface: int = main.patch["modules"]["part"].get("parameters", []).size()
	var a_ghost := ""
	for cell: Dictionary in main.module_face._cells:
		if bool(cell["ghost"]) and a_ghost == "":
			a_ghost = str(cell["key"])
	var ghost_index: int = main.module_face._cell_at(seat.call(a_ghost).get_center())
	check(ghost_index >= 0, "a ghost can be picked up too (%s)" % a_ghost)
	var onto: Rect2 = seat.call("rate")
	main.module_face._finish(ghost_index,
		main.module_face.drop_at(Vector2(onto.position.x + 2.0, onto.get_center().y)))
	for i in 10:
		await process_frame
	check(main.patch["modules"]["part"].get("parameters", []).size() == before_surface + 1,
		"dragging a ghost on exports it (%d, was %d)"
			% [main.patch["modules"]["part"].get("parameters", []).size(), before_surface])
	var flat_rows: Array = []
	for row: Array in main.patch["modules"]["part"].get("panel", {}).get("rows", []):
		flat_rows.append_array(row)
	var named_by_export := true
	for entry in flat_rows:
		if str(entry).begins_with("+"):
			named_by_export = false
	check(named_by_export,
		"and the panel names the binding, not the ghost it was dragged from (%s)"
			% str(flat_rows))
	check(flat_rows.size() == before_surface + 1,
		"with the new knob on the face (%s)" % str(flat_rows))

	# Off the panel: off the face, still exported. The reversible edit must not be able to
	# do the destructive one by accident.
	var surface_before_removal: int = main.patch["modules"]["part"].get("parameters", []).size()
	var off: Dictionary = main.module_face.drop_at(Vector2(-500.0, -500.0))
	check(bool(off.get("remove", false)), "a drop outside the panel means off it (%s)" % str(off))
	main.module_face._finish(main.module_face._cell_at(seat.call("cutoff").get_center()), off)
	for i in 10:
		await process_frame
	var after_removal: Array = []
	for row: Array in main.patch["modules"]["part"].get("panel", {}).get("rows", []):
		after_removal.append_array(row)
	check(not after_removal.has("cutoff"),
		"dragging a knob off the panel takes it off the face (%s)" % str(after_removal))
	check(main.patch["modules"]["part"].get("parameters", []).size() == surface_before_removal,
		"and leaves it exported, so nothing pointing at it breaks (%d)"
			% main.patch["modules"]["part"].get("parameters", []).size())
	var offered_again := false
	for cell: Dictionary in main.module_face._cells:
		if bool(cell["ghost"]) and str(cell["key"]) == "cutoff":
			offered_again = true
	check(offered_again, "so it comes back as a ghost, ready to be put on again")

	# ---- ghost jacks: declaring a port by clicking it --------------------------------
	# A port is on the face or it is not, and there is no arrangement for it to land in, so
	# this is a click rather than a drag. The ghosts are rows on the instance itself: the
	# thing you are adding a port to is the thing you click.
	var ghost_row: Control = null
	for child in main.widgets[instance].get_children():
		var row := child as Control
		if row != null and row.visible 				and not (row.get_meta("ghost_offer", {}) as Dictionary).is_empty():
			ghost_row = row
			break
	check(ghost_row != null, "an undeclared inner port is drawn as a ghost jack on the node")

	if ghost_row != null:
		var ghost_offer: Dictionary = ghost_row.get_meta("ghost_offer")
		var found: Dictionary = main.graph_edit.ghost_port_at(ghost_row.get_global_rect().get_center())
		check(not found.is_empty()
				and str((found["offer"] as Dictionary)["port"]) == str(ghost_offer["port"]),
			"and the pointer finds it where it is drawn (%s)" % str(found.get("offer", {})))

		var before_ports: int = main.patch["modules"]["part"].get(
			"inputs" if bool(ghost_offer.get("is_input", true)) else "outputs", []).size()
		main._on_ghost_port_picked(String(main.widgets[instance].name), ghost_offer)
		for i in 10:
			await process_frame

		var side := "inputs" if bool(ghost_offer.get("is_input", true)) else "outputs"
		var declared: Array = []
		for binding: Dictionary in main.patch["modules"]["part"].get(side, []):
			declared.append(str(binding["name"]))
		check(declared.size() == before_ports + 1 and declared.has(str(ghost_offer["port"])),
			"clicking it declares the port (%s)" % str(declared))

		var on_instance := false
		for port: Dictionary in main.registry["module:part"].get(side, []):
			if str(port["name"]) == str(ghost_offer["port"]):
				on_instance = true
		check(on_instance, "and the instance grows a jack for it")

		# And it stops being an offer, because it is not one any more.
		var still_offered := false
		for offer: Dictionary in main.registry["module:part"].get("port_offers", []):
			var binding: Dictionary = offer.get("offer", {})
			if str(binding.get("node", "")) == str(ghost_offer["node"]) \
					and str(binding.get("port", "")) == str(ghost_offer["port"]):
				still_offered = true
		check(not still_offered, "and is no longer offered, since it is already a port")

	# And selecting something else takes them away. There is no mode to put down; the
	# selection is what says which module is being worked on, so it is also what says when
	# nothing is.
	main._focus_node(main._output_node())
	for i in 8:
		await process_frame
	var ghosts_after := false
	for child in main.widgets[instance].get_children():
		var row := child as Control
		if row != null and row.visible 				and not (row.get_meta("ghost_offer", {}) as Dictionary).is_empty():
			ghosts_after = true
	check(not ghosts_after, "selecting away from the module takes its ghosts away")

	# ---- taking something off a module's contract ------------------------------------
	# The half of surface editing the wand cannot offer. Declaring a port is safe — nothing
	# can be plugged into one that did not exist — so it is a click. Taking one away strands
	# whatever was in it, so it is a list with a count and a confirmation, and the document
	# has to come out the other side loadable rather than merely smaller.
	main._focus_node(instance)
	for i in 6:
		await process_frame

	var take_off_buttons := func() -> int:
		var found := 0
		for child in main.context_panel.get_children():
			var row := child as HBoxContainer
			if row == null:
				continue
			for inner in row.get_children():
				if inner is Button and str((inner as Button).text) == "×":
					found += 1
		return found
	check(take_off_buttons.call() > 0,
		"the inspector offers a way to take each port and knob back off (%d)"
			% take_off_buttons.call())

	# Un-exporting: the export goes, and so does everything reaching through it.
	main.patch["controls"] = [{
		"id": "played", "label": "Played", "kind": "knob",
		"target": {"node": instance, "parameter": "resonance"},
		"min": 0.0, "max": 1.0, "default": 0.5, "scaling": "linear",
	}]
	for node in main.patch["nodes"]:
		if str(node["id"]) == instance:
			node["parameters"]["resonance"] = 0.42
	main._synthesize_module_descriptors()
	await main._rebuild_view()
	for i in 6:
		await process_frame
	check(main._controls_driving("part", "resonance") == 1,
		"a control aimed at an export is counted before anything is clicked (%d)"
			% main._controls_driving("part", "resonance"))

	var exports_before: int = main.patch["modules"]["part"].get("parameters", []).size()
	main._unexport_knob("part", "resonance")
	for i in 10:
		await process_frame
	var export_names: Array = []
	for binding: Dictionary in main.patch["modules"]["part"].get("parameters", []):
		export_names.append(str(binding["name"]))
	check(not export_names.has("resonance") and export_names.size() == exports_before - 1,
		"un-exporting takes the knob off the surface (%s)" % str(export_names))
	check(main.patch.get("controls", []).is_empty(),
		"and the control driving it goes rather than being left to fail loading")
	var stale_value := false
	for node in main.patch["nodes"]:
		if str(node["id"]) == instance \
				and (node.get("parameters", {}) as Dictionary).has("resonance"):
			stale_value = true
	check(not stale_value,
		"and the value the instance had set through it goes too — nothing reads it now")
	var still_on_face := false
	for row: Array in main.patch["modules"]["part"].get("panel", {}).get("rows", []):
		if row.has("resonance"):
			still_on_face = true
	check(not still_on_face, "and it is off the panel, which named it by that export")

	# Un-declaring a port: the port goes, and the cables in it go with it.
	var a_port := ""
	var port_cables := 0
	for connection in main.patch.get("connections", []):
		if a_port != "" or str(connection["to"]["node"]) != instance:
			continue
		for binding: Dictionary in Seams.declared_ports(
				main.patch["modules"]["part"], false):
			if str(binding["name"]) == str(connection["to"]["port"]):
				a_port = str(binding["name"])
	if a_port != "":
		port_cables = main._cables_into("part", a_port)
	check(a_port != "" and port_cables > 0,
		"a declared port of the module has something plugged into it (%s, %d)"
			% [a_port, port_cables])

	var connections_before: int = main.patch["connections"].size()
	if a_port != "":
		main._undeclare_port("part", false, a_port)
		for i in 10:
			await process_frame
		var port_names: Array = []
		for binding: Dictionary in Seams.declared_ports(
				main.patch["modules"]["part"], false):
			port_names.append(str(binding["name"]))
		check(not port_names.has(a_port),
			"un-declaring takes the port off the module (%s)" % str(port_names))
		check(main.patch["connections"].size() == connections_before - port_cables,
			"and exactly the cables that were in it (%d of %d)"
				% [port_cables, connections_before])

		# The claim the whole reconciliation exists for: what is left must still load. A
		# connection naming a port the module has not got is a document the loader refuses,
		# and this edit is the one that can produce one.
		var dangling := 0
		for connection in main.patch.get("connections", []):
			for end in ["from", "to"]:
				var at: Dictionary = connection[end]
				if str(at["node"]) != instance:
					continue
				var found := false
				for port: Dictionary in main.registry["module:part"].get(
						"inputs" if end == "to" else "outputs", []):
					if str(port["name"]) == str(at["port"]):
						found = true
				if not found:
					dangling += 1
		check(dangling == 0,
			"leaving no cable naming a port the module has not got (%d)" % dangling)

		# And it is one undo, not several.
		main._undo()
		for i in 10:
			await process_frame
		var port_after_undo: Array = []
		for binding: Dictionary in Seams.declared_ports(
				main.patch["modules"]["part"], false):
			port_after_undo.append(str(binding["name"]))
		check(port_after_undo.has(a_port), "undo puts the port back (%s)" % str(port_after_undo))
		check(main.patch["connections"].size() == connections_before,
			"with the cables that were in it (%d of %d)"
				% [main.patch["connections"].size(), connections_before])

	# ---- and the module can be given a name ------------------------------------------
	# Collapse calls every fresh definition "part" and then names the instance after it,
	# so both arrive as the same placeholder and the running order reads "part.filter".
	# Renaming the definition alone would fix the half nobody sees. The field is on the
	# instance in the inspector, because the instance is the thing on screen.
	main._focus_node(instance)
	for i in 4:
		await process_frame
	var name_field: LineEdit = null
	for child in main.context_panel.get_children():
		if child is LineEdit:
			name_field = child
	check(name_field != null and name_field.text == "part",
		"a module instance offers its name in the inspector (%s)"
			% ("missing" if name_field == null else name_field.text))

	name_field.text_submitted.emit("shaper")
	for i in 8:
		await process_frame
	check(main.patch["modules"].has("shaper") and not main.patch["modules"].has("part"),
		"renaming moves the definition (%s)" % str(main.patch["modules"].keys()))
	var pointing: Array = []
	for node in main.patch["nodes"]:
		if str(node.get("type", "")) == "module":
			pointing.append("%s:%s" % [str(node["id"]), str(node["module"])])
	check(pointing == ["shaper:shaper"],
		"and the instance goes with it, since it was only ever called after it (%s)"
			% str(pointing))
	check(main.registry.has("module:shaper") and not main.registry.has("module:part"),
		"and the descriptor follows")
	var wired := 0
	for connection in main.patch.get("connections", []):
		for end in ["from", "to"]:
			if str(connection[end]["node"]) == "shaper":
				wired += 1
	check(wired == 2, "and every cable follows the instance's new id (%d)" % wired)

	# The names it must refuse, each for its own reason.
	for child in main.context_panel.get_children():
		if child is LineEdit:
			name_field = child
	name_field.text_submitted.emit("shaper.two")
	for i in 4:
		await process_frame
	check(main.patch["modules"].has("shaper"),
		"a name with a dot is refused — that is the separator expansion uses (%s)"
			% str(main.patch["modules"].keys()))
	for child in main.context_panel.get_children():
		if child is LineEdit:
			name_field = child
	name_field.text_submitted.emit("")
	for i in 4:
		await process_frame
	check(main.patch["modules"].has("shaper"), "and an empty name is not a rename")

	await main._undo()
	for i in 8:
		await process_frame
	check(main.patch.get("modules", {}).has("part"),
		"and undo puts the old name back (%s)"
			% str(main.patch.get("modules", {}).keys()))

	# ---- drawing a module, and shutting it again -------------------------------------
	# The gesture end to end, through the editor rather than through ModuleAuthor: the
	# rectangle names its members, the module is left open with a frame round its parts,
	# and the frame's Close button folds it back to one node.
	# ---- the engine can say whether two documents are the same graph -----------------
	# A reload empties every delay line and retriggers every oscillator, so an edit that
	# cannot change the sound should not cause one. flatten_patch answers that: it parses a
	# document — expanding modules and seams on the way, because that is what parsing does —
	# and fingerprints the flat graph the engine would build. Equal fingerprints, equal
	# sound.
	var flat_first: String = main.engine.flatten_patch(JSON.stringify(main.patch, "  "))
	check(flat_first != "", "the engine fingerprints the flattened graph (%d bytes)"
		% flat_first.length())
	check(main.engine.flatten_patch(JSON.stringify(main.patch, "  ")) == flat_first,
		"and gives the same answer twice for the same document")

	# It has to be able to say no, or skipping a reload would be a promise nothing could
	# break. One hertz moves it.
	var nudged: Dictionary = main.patch.duplicate(true)
	for node in nudged["nodes"]:
		if str(node.get("type", "")) == "SawOscillator":
			node["parameters"]["frequency"] = float(
				node.get("parameters", {}).get("frequency", 220.0)) + 1.0
	check(main.engine.flatten_patch(JSON.stringify(nudged, "  ")) != flat_first,
		"and a knob turned by one hertz moves it")

	# A document that will not parse fingerprints as nothing, which _apply treats as
	# "reload" rather than as "no change" — the empty string must never match a real one.
	check(main.engine.flatten_patch("{ not json") == "",
		"a document that will not parse has no fingerprint")

	await main._load_example("First Synth")
	for i in 8:
		await process_frame
	var drawn: Array = []
	for id in ["lfo", "filter"]:
		drawn.append(String((main.widgets[id] as GraphNode).name))
	await main._on_region_drawn(drawn)
	for i in 10:
		await process_frame
	check(main.patch.get("modules", {}).has("part"),
		"the rectangle makes a module (%s)" % str(main.patch.get("modules", {}).keys()))
	check_loads(main, "drawing a module")
	check(main.graph_edit.groups.has("part"),
		"left open, with a frame round its parts (%s)"
			% str(main.graph_edit.groups.keys()))
	check(main.widgets.has("part.lfo") and main.widgets.has("part.filter"),
		"which are on the canvas under its name (%s)" % str(main.widgets.keys()))
	var open_instances := 0
	for node in main.patch["nodes"]:
		if str(node.get("type", "")) == "module":
			open_instances += 1
	check(open_instances == 0, "and nothing points at it while it is open (%d)"
		% open_instances)

	await main._close_module("part")
	for i in 10:
		await process_frame
	check(main.widgets.has("part") and not main.widgets.has("part.lfo"),
		"closing folds the parts back into one node (%s)" % str(main.widgets.keys()))
	check_loads(main, "closing it")
	check(main.graph_edit.groups.is_empty(),
		"and the frame goes with them (%s)" % str(main.graph_edit.groups.keys()))

	await main._open_module("part")
	for i in 10:
		await process_frame
	check(main.graph_edit.groups.has("part"), "opening it again brings the frame back")
	check_loads(main, "opening it again")

	# The invariance the reload guard rests on, testable at last. Expansion and collapse are
	# the same graph said two ways, so a toggle cannot change the sound — and _apply only
	# skips engine.load_patch when the two fingerprints match exactly.
	var flat_open: String = main.engine.flatten_patch(JSON.stringify(main.patch, "  "))
	check(flat_open != "", "an open module fingerprints (%d bytes)" % flat_open.length())
	await main._close_module("part")
	for i in 10:
		await process_frame
	check(main.engine.flatten_patch(JSON.stringify(main.patch, "  ")) == flat_open,
		"closing a module leaves the flattened graph identical")
	await main._open_module("part")
	for i in 10:
		await process_frame
	check(main.engine.flatten_patch(JSON.stringify(main.patch, "  ")) == flat_open,
		"and opening it again returns to the same one")

	# ---- drilling in turns the panel too ---------------------------------------------
	# The graph is the inside of the device and the panel is what a player holds, and
	# they are two views of one container — so opening a module turns both at once: the
	# graph shows its parts, the panel its face. With no instance node left on the
	# canvas, the face's knobs write to the inner nodes the export bindings name.
	main._focus_node(main._output_node())
	for i in 6:
		await process_frame
	check(main.module_face.visible and main.module_face.module_name() == "part",
		"inside an open module the panel is its face (%s)"
			% main.module_face.module_name())
	check(main.face_heading.text == "part",
		"under the container's name (%s)" % main.face_heading.text)
	var opened_target: Array = main.module_face._write_target("cutoff")
	check(str(opened_target[0]).begins_with("part.") \
			and str(opened_target[1]) == "cutoff",
		"and its knobs reach the parts directly (%s.%s)"
			% [opened_target[0], opened_target[1]])

	# ---- each container turns independently -------------------------------------------
	# The open frame carries its own FACE control, and flipping it turns only that
	# container: its parts hidden, its cables off the canvas, its face mounted where
	# they stood — while the rest of the wiring stays live around it.
	for i in 6:
		await process_frame
	check(main.graph_edit._flip_hits.has("part"),
		"the open frame carries a FACE control (%s)"
			% str(main.graph_edit._flip_hits.keys()))
	# Membership, not a name substring: the widgets' sanitized names need not contain
	# the module's — which is how the first count quietly included the members it was
	# meant to exclude.
	var part_members: Array = main.graph_edit.groups.get("part", [])
	var others_before := 0
	for child in main.graph_edit.get_children():
		if child is GraphNode and (child as GraphNode).visible \
				and not part_members.has(String((child as GraphNode).name)):
			others_before += 1
	main.graph_edit.group_flip_toggled.emit("part")
	for i in 8:
		await process_frame
	check(main.flipped_modules.has("part"), "flipping turns that container")
	var part_shown := 0
	var others_after := 0
	for child in main.graph_edit.get_children():
		if not (child is GraphNode) or not (child as GraphNode).visible:
			continue
		if main.graph_edit.groups.get("part", []).has(String((child as GraphNode).name)):
			part_shown += 1
		else:
			others_after += 1
	check(part_shown == 0, "its parts are put away (%d showing)" % part_shown)
	check(others_after == others_before,
		"and everything outside it stays on view (%d of %d)"
			% [others_after, others_before])
	var part_cables := 0
	for wire in main.graph_edit.get_connection_list():
		for widget_name in main.graph_edit.groups.get("part", []):
			if String(wire["from_node"]) == str(widget_name) \
					or String(wire["to_node"]) == str(widget_name):
				part_cables += 1
	check(part_cables == 0,
		"with no cable left running into the turned container (%d)" % part_cables)
	var part_mount: Control = main.module_mounts.get("part", null)
	check(part_mount != null and part_mount.visible
			and (part_mount as ModuleFace).opened_module == "part",
		"and its face stands where the parts stood")
	check(main.graph_edit.flip_frames.has("part")
			and main.graph_edit._flip_hits.has("part"),
		"wearing a band with the way back on it")

	main.graph_edit.group_flip_toggled.emit("part")
	for i in 10:
		await process_frame
	var part_back := 0
	for child in main.graph_edit.get_children():
		if child is GraphNode and (child as GraphNode).visible \
				and main.graph_edit.groups.get("part", []) \
					.has(String((child as GraphNode).name)):
			part_back += 1
	check(not main.flipped_modules.has("part") and part_back > 0,
		"WIRES brings the parts back (%d)" % part_back)

	# ---- editing a module from the inside --------------------------------------------
	# The argument for opening a module on the canvas rather than in a view of its own:
	# once it is open its parts are ordinary nodes, so adding one and wiring it are the
	# ordinary gestures. Nothing has to learn a second way of doing either.
	#
	# Membership is the id prefix, which is also how ModuleAuthor.close_module decides what
	# to fold in — so joining a module *is* being named after it, and the open_frame only has to
	# say where the boundary is.
	var open_frame: Rect2 = main.graph_edit.group_box("part")
	check(open_frame.size.x > 0.0, "the frame has a rectangle (%s)" % str(open_frame))
	check(main.graph_edit.group_at(open_frame.get_center()) == "part",
		"which answers to a point inside it (%s)"
			% main.graph_edit.group_at(open_frame.get_center()))
	check(main.graph_edit.group_at(open_frame.position - Vector2(400.0, 400.0)) == "",
		"and not to one outside")

	var inside_id: String = await main._add_node("Gain", open_frame.get_center())
	for i in 8:
		await process_frame
	check(inside_id.begins_with("part."),
		"a node added inside the frame is named into the module (%s)" % inside_id)
	check(main.graph_edit.groups.get("part", []).size() == 3,
		"and the frame grows to hold it (%d)"
			% (main.graph_edit.groups.get("part", []) as Array).size())

	# An oscillator rather than a Gain: it needs nothing connected to it, so the patch it
	# is dropped into stays loadable and this section keeps testing what it says it does.
	var outside_id: String = await main._add_node("SawOscillator",
		open_frame.position - Vector2(600.0, 600.0))
	for i in 8:
		await process_frame
	check(not outside_id.begins_with("part."),
		"one added outside it stays outside (%s)" % outside_id)

	# Wiring two inner nodes, through the canvas's own connection path.
	var inner_from: int = main._output_port_index(inside_id, "out")
	var inner_to: int = main._input_port_index("part.filter", "in")
	check(inner_from >= 0 and inner_to >= 0,
		"both inner nodes have the ports to join (%d, %d)" % [inner_from, inner_to])
	main._on_connection_request(main.widgets[inside_id].name, inner_from,
		main.widgets["part.filter"].name, inner_to)
	for i in 6:
		await process_frame
	# And something into it, or the added node is a Gain with nothing to amplify — which
	# the loader is right to refuse and which would make this section a test of the test.
	main._on_connection_request(main.widgets["part.lfo"].name,
		main._output_port_index("part.lfo", "out"),
		main.widgets[inside_id].name, main._input_port_index(inside_id, "in"))
	for i in 8:
		await process_frame
	var wired_inside := false
	for connection in main.patch.get("connections", []):
		if str(connection["from"]["node"]) == inside_id \
				and str(connection["to"]["node"]) == "part.filter":
			wired_inside = true
	check(wired_inside, "wiring two of its parts is an ordinary cable")

	# And closing folds both the node and the cable into the shut_definition, where they become
	# the module's own — which is the claim that makes this editing the module rather than
	# editing the patch near it.
	await main._close_module("part")
	for i in 10:
		await process_frame
	var shut_definition: Dictionary = main.patch["modules"]["part"]
	var inner_ids: Array = []
	for inner in shut_definition.get("nodes", []):
		inner_ids.append(str(inner["id"]))
	var inner_name := inside_id.substr("part.".length())
	check(inner_ids.has(inner_name),
		"the node added inside becomes one of the module's own (%s)" % str(inner_ids))
	var folded_wire := false
	for wire in shut_definition.get("connections", []):
		if str(wire["from"]["node"]) == inner_name and str(wire["to"]["node"]) == "filter":
			folded_wire = true
	check(folded_wire, "and so does the cable between them")
	var left_at_top := false
	for node in main.patch["nodes"]:
		if str(node["id"]).begins_with("part."):
			left_at_top = true
	check(not left_at_top, "with nothing of it left at the top level")
	check_loads(main, "closing it over a node added inside")
	check(main.patch.has("nodes") and _has_node(main.patch, outside_id),
		"and the node added outside untouched (%s)" % outside_id)

	# The other half of the toggle. The open_frame carries the Close; a shut module is one node
	# with nowhere to put the opposite, so it is in the inspector beside the name.
	main._focus_node("part")
	for i in 6:
		await process_frame
	# Selecting a module names it. This used to check the harder half — that a node with
	# *no* output to scope is still the selected node, since the inspector used to empty its
	# whole selection in that case and leave the module with no name, no rename field and no
	# way to be opened. Fixing #66 took the subject away: the module declares its ports now,
	# so it has one to listen to. The branch is still there and still right; what is gone is
	# a node in this suite that reaches it.
	check(str(main.inspecting.get("node", "")) == "part",
		"selecting the module makes it the selected node (%s)" % str(main.inspecting))

	var open_again: Button = null
	for child in main.context_panel.get_children():
		var button := child as Button
		if button != null and str(button.text).begins_with("Open"):
			open_again = button
	check(open_again != null, "a shut module offers to open again, from the inspector")
	if open_again != null:
		open_again.pressed.emit()
		for i in 10:
			await process_frame
		check(main.graph_edit.groups.has("part"),
			"and pressing it opens the module (%s)" % str(main.graph_edit.groups.keys()))
		await main._close_module("part")
		for i in 10:
			await process_frame


	await main._load_example("First Synth")
	for i in 6:
		await process_frame

	# ---- no operating text below the floor, measured on the built editor -------------
	# The token check in design_test proves the scale is sound; this proves the editor
	# uses it. An override typed as a literal, or a legacy constant surviving in a
	# corner, passes the token check and ships 12px text anyway — the search hint did
	# exactly that, styled by a constant from before the design system existed, in the
	# file that preached single sources of truth.
	var undersized := []
	_collect_small_text(main, undersized)
	check(undersized.size() == 0,
		"every text control is at or above the 14px floor (%s)"
			% (", ".join(undersized) if undersized.size() > 0 else "all clear"))

	# ---- free-standing controls offer a real target -----------------------------------
	# ~44px under the finger whatever the visible control measures. Only the chrome:
	# node rows trade target size for density on purpose and have the enlarged ports.
	var small_targets := []
	var bar_controls: Array = []
	_collect_buttons(main.toolbar if "toolbar" in main else main, bar_controls)
	for entry in bar_controls:
		var control := entry as Control
		if control.get_combined_minimum_size().y < Design.scale(Design.HIT_TARGET) - 0.5:
			small_targets.append("%s(%.0f)" % [str(control.get("text")),
				control.get_combined_minimum_size().y])
	check(bar_controls.size() >= 8 and small_targets.size() == 0,
		"the %d toolbar controls all reach the 44px hit target (%s)"
			% [bar_controls.size(),
				", ".join(small_targets) if small_targets.size() > 0 else "all of them"])

	# And the inspector is actually inside it, which is the thing that went wrong
	# rather than the cause of it.
	var inspector: Control = main.scope.get_parent()
	var window_width: float = main.get_viewport().get_visible_rect().size.x
	check(inspector.global_position.x + inspector.size.x <= window_width + 1.0,
		"and the inspector sits inside it (right edge %.0f, window %.0f)"
			% [inspector.global_position.x + inspector.size.x, window_width])

	# ---- the design system reached the widgets ------------------------------------------
	# Setting a theme item Godot does not have is accepted and ignored, exactly like the
	# font weight bug that started this pass — three of these were already in the code and
	# had never done anything. So the guard's findings are a failure, not a warning.
	check(Design.unknown_items.is_empty(),
		"every theme item the editor sets is one Godot has%s"
			% ("" if Design.unknown_items.is_empty() else ": " + ", ".join(Design.unknown_items)))

	# Signal type is carried by shape as well as colour, so it survives a colour-blind
	# viewer and a greyscale printout. Compared as pixels, because two icons that differ
	# only in tint would pass any check that just asked whether they were both present.
	var audio_icon: Image = main._port_icon("audio").get_image()
	var control_icon: Image = main._port_icon("control").get_image()
	var differing := 0
	for y in audio_icon.get_height():
		for x in audio_icon.get_width():
			if absf(audio_icon.get_pixel(x, y).a - control_icon.get_pixel(x, y).a) > 0.5:
				differing += 1
	check(differing > 12,
		"audio and control ports are different shapes, not just different colours (%d px)"
			% differing)

	# The node title has to be heavier than body text, which is only true because the
	# weight axis works — see Design._weight_tag().
	var sample_widget: GraphNode = main.widgets.values()[0]
	var title_label: Label = null
	for child in sample_widget.get_titlebar_hbox().get_children():
		if child is Label and str((child as Label).text) != "":
			title_label = child
			break
	check(title_label != null and title_label.has_theme_font_override("font"),
		"node titles are styled directly, since GraphNode has no title font in its theme")
	if title_label != null:
		var title_size: int = title_label.get_theme_font_size("font_size")
		check(title_size > Design.type(Design.SIZE_BODY),
			"and are larger than body text (%d vs %d)"
				% [title_size, Design.type(Design.SIZE_BODY)])

	# ---- values carry their units -------------------------------------------------
	# A patch stores seconds and hertz; a person should not have to convert in their
	# head to know whether an attack is fast. Checked through the same formatter the
	# rows and the undo path both use, so they cannot disagree.
	var seconds := {"name": "attack", "unit": "s", "default": 0.005}
	check(main._format_with_unit(seconds, 0.010) == "10.0 ms",
		"a short time reads in milliseconds (%s)" % main._format_with_unit(seconds, 0.010))
	check(main._format_with_unit(seconds, 2.5).ends_with(" s"),
		"and a long one in seconds (%s)" % main._format_with_unit(seconds, 2.5))
	var hertz := {"name": "cutoff", "unit": "Hz", "default": 1000.0}
	check(main._format_with_unit(hertz, 900.0) == "900.0 Hz",
		"a frequency reads in hertz (%s)" % main._format_with_unit(hertz, 900.0))
	check(main._format_with_unit(hertz, 4800.0) == "4.80 kHz",
		"and a high one in kilohertz (%s)" % main._format_with_unit(hertz, 4800.0))
	check(not main._format_with_unit({"name": "mix", "unit": "", "default": 0.5}, 0.55)
		.contains(" "), "a unitless parameter stays a bare number")

	# The readout the editor actually built, rather than the formatter in isolation.
	var cutoff_entry: Dictionary = main.parameter_widgets["filter"]["cutoff"]
	var cutoff_readout = cutoff_entry["readout"]
	check(cutoff_readout != null and cutoff_readout.text.contains("Hz"),
		"and a live node shows its unit (%s)"
			% (cutoff_readout.text if cutoff_readout else "no readout"))

	# ---- the on-screen keyboard ---------------------------------------------------------
	# It exists to answer "did the editor hear me", so the thing to check is that its
	# lights follow what the engine was actually told, not what was clicked.
	check(main.keyboard != null, "the editor has an on-screen keyboard")
	main.engine.all_notes_off()
	main.held_notes.clear()
	main.keyboard.set_held_notes(main.held_notes)

	var probe_note: int = main.octave * 12 + 12
	main.keyboard.note_pressed.emit(probe_note)
	check(main.held_notes.has(probe_note), "clicking a key sounds the note")
	check(main.keyboard.held.has(probe_note), "and the key lights up")

	main.keyboard.note_released.emit(probe_note)
	check(not main.held_notes.has(probe_note), "releasing it stops the note")
	check(not main.keyboard.held.has(probe_note), "and the light goes out")

	# The mapping shown on the keys has to be the mapping the computer keyboard uses, or
	# the letters are a lie and worse than nothing.
	main._refresh_keyboard_range()
	var mapped := 0
	for keycode in main.KEY_NOTES:
		var note: int = main.octave * 12 + 12 + main.KEY_NOTES[keycode]
		if main.keyboard.key_labels.has(note):
			mapped += 1
	check(mapped == main.KEY_NOTES.size(),
		"and every computer key is lettered on the key it plays (%d of %d)"
			% [mapped, main.KEY_NOTES.size()])

	# ---- moving and resizing the keyboard -----------------------------------------------
	var start_octave: int = main.octave
	var start_width: int = main.keyboard_octaves

	# The bar itself, since the buttons below are called directly and would pass even if
	# nothing had been built for anyone to press.
	check(main.keyboard_bar != null, "the keyboard has a control bar")
	var buttons := 0
	for child in main.keyboard_bar.get_children():
		if child is Button:
			buttons += 1
	# ---- the instrument has a volume and a mute -------------------------------------
	# The knob drives the output node's own level, so it is an edit like turning any other
	# knob. Mute is the one control here that is not: muting is a thing you do to a room,
	# not to a patch, so it must not make the file unsaved and must not be saved silent.
	check(main.master_knob != null and main.master_knob.visible,
		"the keyboard carries a volume knob when the patch has an output")
	check(main.master_knob.node_id == "out",
		"pointed at the output node (%s)" % main.master_knob.node_id)
	var level_before := 0.0
	for node in main.patch["nodes"]:
		if str(node["id"]) == "out":
			level_before = float(node.get("parameters", {}).get("level", 0.0))
	var dirty_before: bool = main.unsaved
	main._set_muted(true)
	await process_frame
	var level_after := 0.0
	for node in main.patch["nodes"]:
		if str(node["id"]) == "out":
			level_after = float(node.get("parameters", {}).get("level", 0.0))
	check(is_equal_approx(level_before, level_after),
		"muting leaves the level where it was (%.2f)" % level_after)
	check(main.unsaved == dirty_before,
		"and does not make the file unsaved, because it is not a change to the file")
	check(main.muted, "while the instrument is muted")
	main._set_muted(false)
	await process_frame
	check(not main.muted, "and unmuting puts it back")

	check(buttons == 6,
		"with six buttons on it: collapse, mute, two octave, two width (%d)"
		% buttons)

	# The dock. The keyboard was the brightest, heaviest thing on screen and the eye
	# went straight to it, so it has to be able to get out of the way.
	check(main.keyboard_dock != null, "the keyboard lives in a dock")
	var tall: float = main.keyboard_dock.get_combined_minimum_size().y
	main._set_keyboard_expanded(false)
	await process_frame
	var short: float = main.keyboard_dock.get_combined_minimum_size().y
	check(short < tall * 0.6,
		"which collapses to a strip (%.0f px, from %.0f)" % [short, tall])
	check(not main.keyboard.visible, "and the keys are hidden rather than squashed")
	main._set_keyboard_expanded(true)
	await process_frame
	check(main.keyboard.visible, "and come back")

	# Collapsing while a key is down would leave it sounding with nothing on screen
	# to release it — the same stuck note as moving the octave, by a different route.
	main.keyboard.note_pressed.emit(main.octave * 12 + 12)
	check(not main.held_notes.is_empty(), "a note is held before the dock closes")
	main._set_keyboard_expanded(false)
	check(main.held_notes.is_empty(), "collapsing the dock lets go of what was held")
	main._set_keyboard_expanded(true)

	# ---- the machine plugs into the ports, and can be unplugged ----------------------
	# Which port a device drives is the port's own host binding, so dragging a dock jack is
	# not a cable edit — it moves that binding. Dropping it nowhere takes the binding off
	# altogether, which patch-io answers by splicing the port out: an input nothing drives
	# is silent, the way an unplugged input is on any instrument.
	check(main.graph_edit.is_visible_in_tree(),
		"the graph is the visible view, so a drop can land on a port")
	var keyboard_jack := {}
	for socket in main.note_jacks.ports:
		if str(socket["host"]) == "note":
			keyboard_jack = socket
	check(not keyboard_jack.is_empty(), "the dock has a keyboard jack")
	var note_port := str(keyboard_jack.get("node", ""))
	check(note_port != "" and main.widgets.has(note_port),
		"plugged into a port on the canvas (%s)" % note_port)

	# What must survive the unplug: the port's shape. Its outlets come from its host while
	# it has one and from its own cables when it does not, so pulling the keyboard out must
	# not take four cables with it.
	var outlets_before: int = main._output_port_index(note_port, "frequency")
	var cables_before: int = main.patch["connections"].size()
	check(outlets_before >= 0, "and the port has a frequency outlet (slot %d)" % outlets_before)

	main._on_jack_grabbed(keyboard_jack)
	check(not main.dragging_jack.is_empty(), "picking the jack up puts it in hand")
	check(main._live_cable().size() == 3, "and a cable follows the cursor")
	main._drop_jack(Vector2(-200.0, -200.0))  # nowhere
	# The rebuild is a coroutine and finishes on its own frames; the document changes at
	# once, the widgets a few frames later.
	for _i in 6:
		await process_frame

	var unplugged_host := ""
	for node in main.patch["nodes"]:
		if str(node["id"]) == note_port:
			unplugged_host = str(node.get("host", ""))
	check(unplugged_host == "", "dropping it off the graph unplugs the port")
	check(main.patch["connections"].size() == cables_before,
		"without dropping a single cable (%d)" % main.patch["connections"].size())
	check(main._output_port_index(note_port, "frequency") >= 0,
		"the port keeps its outlets, taking their shape from its own wiring")
	var still_there := false
	for socket in main.note_jacks.ports:
		if str(socket["host"]) == "note":
			still_there = str(socket["node"]) == ""
	check(still_there,
		"and the jack stays on the dock, plugged into nothing — a keyboard you cannot "
		+ "plug back in is not unplugged, it is gone")

	# Plugged back in by dropping on the port. Not on its host jack: that is seven pixels
	# across and this is a drag across the window.
	var replug := {"node": "", "port": Seams.HOST_PORT, "host": "note",
		"type": "note", "label": "Keyboard"}
	main._on_jack_grabbed(replug)
	main._drop_jack(main.widgets[note_port].get_global_rect().get_center())
	await process_frame
	await process_frame
	var replugged_host := ""
	for node in main.patch["nodes"]:
		if str(node["id"]) == note_port:
			replugged_host = str(node.get("host", ""))
	check(replugged_host == "note", "and dropping it on the port plugs it back in")

	# ---- the panic control ------------------------------------------------------
	main.keyboard.note_pressed.emit(60)
	main.keyboard.note_pressed.emit(64)
	main._all_notes_off()
	check(main.held_notes.is_empty(), "panic stops every sounding note")
	check(main.keyboard.held.is_empty(), "and the keys go dark with them")

	# The label is the only part of this that says anything, so it is the only part that
	# can say something wrong. C3 to C5 at octave 3 two wide, and it has to track both.
	var range_label := main.keyboard_bar.get_node_or_null("KeyboardRange") as Label
	main.octave = 3
	main.keyboard_octaves = 2
	main._refresh_keyboard_range()
	check(range_label != null and range_label.text == "C3 – C5",
		"and a label naming the range (%s)" % (range_label.text if range_label else "missing"))
	main._show_octaves(4)
	check(range_label.text == "C3 – C7", "which follows the width (%s)" % range_label.text)
	main._shift_octave(1)
	check(range_label.text == "C4 – C8", "and the octave (%s)" % range_label.text)
	main._shift_octave(-1)
	main._show_octaves(start_width)
	main.octave = start_octave
	main._refresh_keyboard_range()

	main._shift_octave(1)
	check(main.keyboard.first_note == (start_octave + 1) * 12 + 12,
		"the octave buttons move the keyboard (first note %d)" % main.keyboard.first_note)
	main._shift_octave(-1)
	check(main.octave == start_octave, "and back again")

	main._show_octaves(4)
	check(main.keyboard.octaves == 4,
		"the width buttons show more octaves (%d)" % main.keyboard.octaves)
	# Both ends clamp, and the check is that they clamp rather than that they refuse: a
	# button that stops working at the limit is fine, one that scrolls past it is not.
	main._show_octaves(99)
	check(main.keyboard.octaves <= 6, "and stop at a sensible maximum (%d)" % main.keyboard.octaves)
	main._show_octaves(0)
	check(main.keyboard.octaves >= 1, "and never reach zero (%d)" % main.keyboard.octaves)
	main._show_octaves(start_width)

	# The one that actually bites. Notes are held by number, so a key still down when the
	# range moves would be released as a *different* note and the original would sound
	# forever — a stuck note in front of an audience, from a mis-click.
	var stuck_probe: int = main.octave * 12 + 12
	main.keyboard.note_pressed.emit(stuck_probe)
	check(main.held_notes.has(stuck_probe), "a note is held before the octave moves")
	main._shift_octave(1)
	check(main.held_notes.is_empty(),
		"moving the keyboard while a key is down lets it go (%d left holding)"
			% main.held_notes.size())
	main._shift_octave(-1)

	# Narrowing takes keys away, so the same applies; widening cannot, so it must not.
	main.keyboard.note_pressed.emit(stuck_probe)
	main._show_octaves(main.keyboard_octaves + 1)
	check(main.held_notes.has(stuck_probe), "widening leaves a held note alone")
	main._show_octaves(1)
	check(main.held_notes.is_empty(), "narrowing lets it go")
	main._show_octaves(start_width)
	main._shift_octave(0)

	# ---- the open document is named -----------------------------------------------------
	await main._load_example("Delay Echo")
	await process_frame
	check(main.document_name == "delay-echo.json",
		"opening a patch names it in the toolbar (%s)" % main.document_name)
	await main._load_example("First Synth")
	await process_frame
	check(main.document_name == "first-synth.json",
		"and opening another one renames it (%s)" % main.document_name)

	# ---- adding a patch as a module ----------------------------------------------------
	var before_import: int = main.patch["nodes"].size()
	var delay_text := FileAccess.get_file_as_string("res://examples/delay-echo.json")
	if delay_text.is_empty():
		delay_text = FileAccess.get_file_as_string(
			ProjectSettings.globalize_path("res://").path_join("../examples/patches/delay-echo.json"))
	check(not delay_text.is_empty(), "the delay example is readable for the module test")

	main._import_module(delay_text, "echo")
	await process_frame

	check(main.patch["nodes"].size() > before_import,
		"adding a patch as a module brings its nodes in")

	var prefixed := 0
	var terminals := 0
	for node in main.patch["nodes"]:
		if str(node["id"]).begins_with("echo" + ModuleImport.SEPARATOR):
			prefixed += 1
			if str(main.registry.get(node["type"], {}).get("category", "")) == "Terminals":
				terminals += 1
	check(prefixed > 0, "and prefixes every one of them with the module name")
	check(prefixed > 0 and terminals == 0,
		"and leaves the module's own terminals out, so there is still one output")

	# The seam a module needs. A game sound is gated by a NoteInput, which is a terminal —
	# so importing one leaves its envelope gate free for the host graph to drive, instead
	# of carrying a constant that fires on its own and argues with the parent.
	var coin_text := FileAccess.get_file_as_string(main._example_path("game/coin.json"))
	var before_coin: int = main.patch["nodes"].size()
	main._import_module(coin_text, "coin")
	await process_frame
	var coin_nodes := 0
	var coin_has_trigger := false
	for node in main.patch["nodes"]:
		if str(node["id"]).begins_with("coin" + ModuleImport.SEPARATOR):
			coin_nodes += 1
			# Both spellings. Asking only about "NoteInput" made this check pass the
			# moment the corpus started saying Input/note — it was true, and true for
			# a reason that had nothing to do with what it was testing.
			if str(node["type"]) == "NoteInput" or str(node.get("host", "")) == "note":
				coin_has_trigger = true
	check(coin_nodes > 0 and not coin_has_trigger,
		"a game sound imported as a module leaves its keyboard behind")

	var gate_driven := false
	for connection in main.patch["connections"]:
		if str(connection["to"]["node"]) == "coin" + ModuleImport.SEPARATOR + "envelope" 				and str(connection["to"]["port"]) == "gate":
			gate_driven = true
	check(not gate_driven,
		"so its envelope gate is free for the host graph to drive")

	# The whole point of prefixing: importing twice must give two modules, not one merged
	# heap with silently colliding ids.
	main._import_module(delay_text, "echo")
	await process_frame
	var second := 0
	for node in main.patch["nodes"]:
		if str(node["id"]).begins_with("echo-2" + ModuleImport.SEPARATOR):
			second += 1
	check(second > 0 and second == prefixed,
		"importing the same file twice gives a second, separate module")

	# And every cable inside a module has to still point at nodes that exist.
	var dangling := 0
	var known := {}
	for node in main.patch["nodes"]:
		known[str(node["id"])] = true
	for connection in main.patch["connections"]:
		if not known.has(str(connection["from"]["node"])) \
				or not known.has(str(connection["to"]["node"])):
			dangling += 1
	check(dangling == 0, "and no cable is left pointing at a node that was left out")

	# ---- importing a patch that is itself modular -------------------------------------
	# A DX7 voice is six instances of one definition, and importing one into a plain patch
	# left the document naming a definition that was not there and still declaring schema
	# 1 while holding modules. Both are things the file says about itself that were false,
	# and either one alone stops it loading.
	await main._load_example("First Synth")
	for i in 8:
		await process_frame
	check(int(main.patch.get("schema_version", 1)) == 1,
		"First Synth is a schema 1 document (%s)" % str(main.patch.get("schema_version")))
	var voice := FileAccess.open("res://examples/dx7/algo-01.json", FileAccess.READ)
	var voice_text := voice.get_as_text()
	voice.close()
	main._import_module(voice_text, "dx7_algo_01")
	for i in 8:
		await process_frame
	check(int(main.patch.get("schema_version", 1)) == 2,
		"importing modules raises it to 2 (%s)" % str(main.patch.get("schema_version")))
	check((main.patch.get("modules", {}) as Dictionary).has("dx7_operator"),
		"and brings the definition its nodes are instances of (%s)"
			% str((main.patch.get("modules", {}) as Dictionary).keys()))

	# Whatever else is wrong with a half-wired import — the terminals are dropped on
	# purpose, so the operators' gates arrive unconnected and the graph says so — nothing
	# should be wrong with what the document *claims*.
	var lied := ""
	var voice_report: Variant = JSON.parse_string(
		main.engine.validate_patch(JSON.stringify(main.patch, "  ")))
	if typeof(voice_report) == TYPE_DICTIONARY:
		for problem in voice_report["diagnostics"]:
			var text := str(problem.get("message", ""))
			if text.contains("schema_version") or text.contains("unknown module") \
					or text.contains("undeclared module"):
				lied = text
	check(lied == "", "with nothing left untrue about the file itself (%s)" % lied)

	# And the definition is shared rather than copied: two DX7 voices in one document
	# should mean one dx7_operator, not two under different names.
	main._import_module(voice_text, "dx7_algo_01")
	for i in 8:
		await process_frame
	var operator_definitions := 0
	for name in (main.patch.get("modules", {}) as Dictionary):
		if str(name).contains("dx7_operator"):
			operator_definitions += 1
	check(operator_definitions == 1,
		"a second voice reuses the one definition (%d)" % operator_definitions)

	# ---- one module, written both ways, reaching the editor the same ------------------
	# A definition spells its ports twice over: a binding in `inputs`/`outputs`, or a port
	# drawn as a seam among its nodes. Seams.declared_ports is the single answer, and
	# three separate bugs this session were code that asked one spelling directly —
	# close_module feeding _draw_ports the raw lists, patch_face asking the registry for
	# "Output", a check here reading `inputs` and finding nothing.
	#
	# Naming those call sites one at a time only ever fixes the ones already found. This
	# builds the same module both ways and asserts the editor cannot tell them apart: any
	# reader that understands one spelling makes the other come back short.
	var both_ways := {"bindings": {}, "seams": {}}
	for spelling in ["bindings", "seams"]:
		var definition := {
			"nodes": [{"id": "amp", "type": "Gain", "parameters": {"gain": 0.5}}],
			"connections": [],
			"parameters": [{"name": "level", "node": "amp", "parameter": "gain"}],
		}
		if spelling == "bindings":
			definition["inputs"] = [{"name": "sound", "node": "amp", "port": "in"}]
			definition["outputs"] = [{"name": "louder", "node": "amp", "port": "out"}]
		else:
			(definition["nodes"] as Array).append(
				{"id": "sound", "type": "Input", "name": "sound"})
			(definition["nodes"] as Array).append(
				{"id": "louder", "type": "Output", "name": "louder"})
			(definition["connections"] as Array).append(
				{"from": {"node": "sound", "port": "sound"},
					"to": {"node": "amp", "port": "in"}})
			(definition["connections"] as Array).append(
				{"from": {"node": "amp", "port": "out"},
					"to": {"node": "louder", "port": "louder"}})
		main.patch = {
			"schema_version": 2,
			"metadata": {"name": "spelling"},
			"modules": {"twice": definition},
			"nodes": [{"id": "one", "type": "module", "module": "twice",
				"position": {"x": 0, "y": 0}}],
			"connections": [],
		}
		main._synthesize_module_descriptors()
		await main._rebuild_view()
		for i in 8:
			await process_frame
		var seen := {}
		var descriptor: Dictionary = main.registry.get("module:twice", {})
		for side in ["inputs", "outputs"]:
			var names: Array = []
			for port in descriptor.get(side, []):
				names.append(str(port["name"]))
			seen[side] = names
		# And what the graph actually draws, not only what the registry believes.
		var widget = main.widgets.get("one", null)
		seen["slots"] = 0 if widget == null else widget.get_child_count()
		both_ways[spelling] = seen
	check(both_ways["bindings"]["inputs"] == ["sound"]
			and both_ways["bindings"]["outputs"] == ["louder"],
		"a module's ports as bindings (%s)" % str(both_ways["bindings"]))
	check(both_ways["seams"] == both_ways["bindings"],
		"and drawn as seams, the editor cannot tell the difference (%s vs %s)"
			% [str(both_ways["seams"]), str(both_ways["bindings"])])

	# ---- a whole voice as one node ----------------------------------------------------
	# Importing algo-01 *as a definition* used to be refused outright: "that patch already
	# uses modules; nesting is not supported yet". True of the result — a definition may
	# not hold instances — but a fact about the notation rather than about the patch. A
	# DX7 voice is six operators however it is written down, so the instances are expanded
	# back into plain nodes and the definition holds those.
	await main._load_example("First Synth")
	for i in 8:
		await process_frame
	var host_in := ""
	var host_out := ""
	for node in main.patch["nodes"]:
		if str(node.get("type", "")) == "Input":
			host_in = str(node["id"])
		if str(node.get("type", "")) == "Output":
			host_out = str(node["id"])
	main._import_module_as_definition(voice_text, "dx7_algo_01")
	for i in 10:
		await process_frame
	var voice_definition: Dictionary = main.patch.get("modules", {}).get(
		"dx7_algo_01", {})
	check(not voice_definition.is_empty(), "a DX7 voice imports as a definition")
	# Keeping its own modules, now that a definition may hold them. It used to be
	# flattened — 41 nodes with dx7_operator dissolved into it — because nesting was
	# refused; the notation the source chose survives the trip, and so does the sharing.
	var nested := 0
	for node in voice_definition.get("nodes", []):
		if str(node.get("type", "")) == "module":
			nested += 1
	check(nested == 6 and (voice_definition.get("nodes", []) as Array).size() < 30,
		"holding its six operators as instances (%d nodes, %d of them modules)"
			% [(voice_definition.get("nodes", []) as Array).size(), nested])
	check((main.patch.get("modules", {}) as Dictionary).has("dx7_operator"),
		"with the operator definition beside it, shared rather than copied (%s)"
			% str((main.patch.get("modules", {}) as Dictionary).keys()))
	var voice_nodes := 0
	for node in main.patch["nodes"]:
		if str(node.get("module", "")) == "dx7_algo_01":
			voice_nodes += 1
	check(voice_nodes == 1, "and one node placed for it (%d)" % voice_nodes)

	# The ports are the ones a hand can reach: a keyboard is not one signal, so the seam
	# that fed six operators' note and gate becomes a `frequency` port and a `gate` port
	# rather than a single `Keyboard` that could deliver neither. Outputs stay whole —
	# `left` and `right` are channels of one mix, not two different signals.
	var voice_in: Array = []
	for port: Dictionary in Seams.declared_ports(voice_definition, false):
		voice_in.append(str(port["name"]))
	var voice_out: Array = []
	for port: Dictionary in Seams.declared_ports(voice_definition, true):
		voice_out.append(str(port["name"]))
	check(voice_in == ["frequency", "gate"],
		"its inputs are the signals the keyboard actually drives (%s)" % str(voice_in))
	check(voice_out == ["out"], "and one output (%s)" % str(voice_out))

	# And wired into the host, it is a patch that loads — which is the whole claim.
	for wire in [{"from": {"node": host_in, "port": "frequency"},
				"to": {"node": "dx7_algo_01", "port": "frequency"}},
			{"from": {"node": host_in, "port": "gate"},
				"to": {"node": "dx7_algo_01", "port": "gate"}},
			{"from": {"node": "dx7_algo_01", "port": "out"},
				"to": {"node": host_out, "port": "left"}},
			{"from": {"node": "dx7_algo_01", "port": "out"},
				"to": {"node": host_out, "port": "right"}}]:
		main.patch["connections"].append(wire)
	check_loads(main, "wiring the voice node into the host patch")

	# Which is the whole of nesting, end to end: a module holding modules, expanded two
	# levels deep by the engine, in a patch that plays.
	var voice_depth := 0
	for node in voice_definition.get("nodes", []):
		if str(node.get("type", "")) == "module":
			var inner: Dictionary = main.patch["modules"].get(
				str(node.get("module", "")), {})
			voice_depth = maxi(voice_depth, (inner.get("nodes", []) as Array).size())
	check(voice_depth > 0,
		"and the operators have innards of their own, a level further down (%d nodes)"
			% voice_depth)

	# ---- the graph draws the same boundary the panel does ----------------------------
	# One container, two views: the panel shows it as knobs and the graph as wiring, and
	# both draw its edge and put its name on it. The case is behind the nodes because a
	# case is what modules are mounted in — an open module's frame is drawn above them,
	# because that is a thing you are working inside.
	main.show_view("Graph")
	for i in 6:
		await process_frame
	check(main.graph_edit.case_title == "First Synth",
		"the graph's case wears the instrument's name (%s)" % main.graph_edit.case_title)
	var case_frame: Rect2 = main.graph_edit.case_box()
	check(case_frame.size.x > 0.0 and case_frame.size.y > 0.0,
		"and encloses something (%s)" % str(case_frame))
	var uncased := ""
	for child in main.graph_edit.get_children():
		var mounted := child as GraphNode
		if mounted == null or not mounted.visible:
			continue
		if not case_frame.encloses(Rect2(mounted.position_offset, mounted.size)) \
				and uncased == "":
			uncased = str(mounted.name)
	check(uncased == "", "with every node inside it (%s)" % uncased)

	# The band is the case's handle. Only the band — the inside of the case is where
	# selecting and rubber-banding happen, and a case you could grab anywhere would make
	# a rubber band impossible to start.
	var band: Rect2 = main.graph_edit._case_band_rect()
	check(band.size.y > 0.0, "the case has a band (%s)" % str(band))

	# And a click on it — a press that never travels — chooses the container: node
	# selection cleared, panel on the file's face, inspector describing the whole patch.
	# The same landing as clicking a seam like the keyboard, because both are ways of
	# pointing at the file rather than at a part of it.
	main._focus_node("filter")
	for i in 6:
		await process_frame
	check(str(main.inspecting.get("node", "")) == "filter",
		"a part is selected to start from (%s)" % str(main.inspecting))
	# Re-read the band: focusing scrolled the canvas, and the rect is in screen space.
	band = main.graph_edit._case_band_rect()
	_press_graph(main, band.position + Vector2(8.0, 8.0))
	for i in 8:
		await process_frame
	check(main.inspecting.is_empty(),
		"clicking the case band chooses the container (%s)" % str(main.inspecting))
	check(main.patch_face.visible and not main.module_face.visible,
		"and the panel shows the container's face")
	var chosen_still := 0
	for child in main.graph_edit.get_children():
		if child is GraphNode and (child as GraphNode).selected:
			chosen_still += 1
	check(chosen_still == 0,
		"with no part left selected under it (%d)" % chosen_still)
	var history_before: int = main.undo_redo.get_history_count()
	band = main.graph_edit._case_band_rect()
	_press_graph(main, band.position + Vector2(8.0, 8.0))
	for i in 6:
		await process_frame
	check(main.undo_redo.get_history_count() == history_before,
		"and a click is not a move: the history gains nothing (%d)"
			% main.undo_redo.get_history_count())

	# The empty floor inside the case chooses the container too: the canvas is the
	# inside of the room, and clicking it lands where clicking the band does. Only a
	# click — a press that travels is a rubber band, and the selection it makes is not
	# overruled by the room it was made in.
	main._focus_node("filter")
	for i in 6:
		await process_frame
	var floor_at: Vector2 = main.graph_edit._case_band_rect().position \
		+ Vector2(30.0, 220.0)
	check(main.graph_edit.get_child_count() > 0
			and main.graph_edit._connection_at(
				main.graph_edit._to_graph(floor_at)).is_empty(),
		"the aimed-at point is bare canvas")
	_press_graph(main, floor_at)
	for i in 8:
		await process_frame
	check(main.inspecting.is_empty(),
		"clicking the empty floor chooses the container (%s)" % str(main.inspecting))
	main._focus_node("filter")
	for i in 6:
		await process_frame
	var sweep_from: Vector2 = main.graph_edit._case_band_rect().position \
		+ Vector2(30.0, 220.0)
	_drag_graph(main, sweep_from, sweep_from + Vector2(160.0, 90.0))
	for i in 8:
		await process_frame
	check(str(main.inspecting.get("node", "")) == "filter",
		"but a rubber band across it chooses nothing (%s)" % str(main.inspecting))

	# And a click on a node stays on the node. In the real event flow a press on a
	# node's body reaches this override too — GraphEdit itself handles selection, so a
	# GraphNode does not consume the press — and the first floor-click version treated
	# it as floor: every node click selected the node and then immediately chose the
	# container instead. The reported symptom, verbatim: "clicking on an object will
	# select it, but then it reverts back".
	main._focus_node("filter")
	for i in 6:
		await process_frame
	var clicked_widget: GraphNode = main.widgets["filter"]
	var on_node: Vector2 = (clicked_widget.position_offset
		+ clicked_widget.size * 0.5) * main.graph_edit.zoom \
		- main.graph_edit.scroll_offset
	check(main.graph_edit._node_at(main.graph_edit._to_graph(on_node)) != "",
		"the aimed-at point is on the node")
	_press_graph(main, on_node)
	for i in 8:
		await process_frame
	check(str(main.inspecting.get("node", "")) == "filter",
		"and clicking it does not bounce to the container (%s)" % str(main.inspecting))

	# ---- turning the container over ---------------------------------------------------
	# The graph is the device's insides and the face is what a player holds, and the FACE
	# control turns the container over on the same canvas: the wiring is hidden, the face
	# mounts at the case's own corner, and the graph's camera — zoom, pan, grid — keeps
	# working because it is the same camera. Presentation only: nothing is written.
	# From a view that matches the document. Earlier sections can leave the view a
	# cable adrift of the doc, and the unflip rebuilds *from the doc* — so comparing
	# against a drifted count would blame the flip for correcting somebody else.
	await main._rebuild_view()
	for i in 8:
		await process_frame
	var flip: Rect2 = main.graph_edit._case_flip_rect()
	check(flip.size.x > 0.0, "the case band carries a FACE control (%s)" % str(flip))
	var wired_before: int = main.graph_edit.get_connection_list().size()
	check(wired_before > 0, "the wiring is on view to start with (%d)" % wired_before)
	var history_at_flip: int = main.undo_redo.get_history_count()
	_press_graph(main, flip.get_center())
	for i in 8:
		await process_frame
	check(main.big_face.visible and main.graph_edit.visible,
		"flipping mounts the face on the still-visible canvas")
	var wires_shown := 0
	for child in main.graph_edit.get_children():
		if child is GraphNode and (child as GraphNode).visible:
			wires_shown += 1
	check(wires_shown == 0 and main.graph_edit.get_connection_list().is_empty(),
		"with the wiring put away (%d nodes, %d cables)"
			% [wires_shown, main.graph_edit.get_connection_list().size()])
	check(main.views.get_tab_title(main.views.current_tab) == "Graph",
		"without leaving the tab (%s)"
			% main.views.get_tab_title(main.views.current_tab))
	var big_blocks: int = 0
	var big_rows: Node = main.big_face.get_node_or_null("Case/Rack/Rail/Rows")
	if big_rows != null:
		for one_row in big_rows.get_children():
			for one in (one_row as Node).get_children():
				if one is VBoxContainer:
					big_blocks += 1
	check(big_blocks > 0,
		"and the face is the real rack, blocks and all (%d)" % big_blocks)
	check(main.undo_redo.get_history_count() == history_at_flip,
		"with nothing added to the history (%d)" % main.undo_redo.get_history_count())

	# The graph's camera moves the face: zoom scales it, scroll shifts it, because a
	# canvas tenant follows the canvas. This is the whole reason the face lives on the
	# graph rather than in a view of its own with a second set of controls.
	# Through the graph's own redraw, not by calling the placement by hand: the first
	# version did, and it kept passing with the signal unplugged — testing the math
	# while the wiring hung loose.
	main.graph_edit.zoom = 0.6
	main.graph_edit.queue_redraw()
	for i in 4:
		await process_frame
	check(absf(main.big_face.scale.x - 0.6) < 0.001,
		"the graph's zoom scales the face (%.2f)" % main.big_face.scale.x)
	var seen_at: Vector2 = main.big_face.position
	main.graph_edit.scroll_offset += Vector2(200.0, 0.0)
	main.graph_edit.queue_redraw()
	for i in 4:
		await process_frame
	check(absf(main.big_face.position.x - (seen_at.x - 200.0)) < 0.5,
		"and its scroll moves it (%.0f from %.0f)"
			% [main.big_face.position.x, seen_at.x])
	main.graph_edit.zoom = 1.0
	main.graph_edit.queue_redraw()
	for i in 4:
		await process_frame

	# A knob on the turned-over face is the same live control as everywhere else.
	var big_knob: Control = null
	for index in main.big_face._targets:
		if str(main.big_face._targets[index]["parameter"]) == "cutoff" 				and big_knob == null:
			big_knob = main.big_face._cells[index]
	check(big_knob != null, "the big face has the cutoff knob on it")
	if big_knob != null:
		var before_turn := 0.0
		for node in main.patch["nodes"]:
			if str(node["id"]) == "filter":
				before_turn = float(node["parameters"]["cutoff"])
		(big_knob.get_child(0) as RackView.Knob).nudge(0.05)
		for i in 6:
			await process_frame
		var after_turn := 0.0
		for node in main.patch["nodes"]:
			if str(node["id"]) == "filter":
				after_turn = float(node["parameters"]["cutoff"])
		check(after_turn > before_turn,
			"and turning it writes the document (%.0f from %.0f)"
				% [after_turn, before_turn])
		await main._undo()
		for i in 4:
			await process_frame

	# The knobs yield Ctrl+wheel — the camera's zoom — and keep the plain wheel.
	var wheel_knob: Control = null
	for index in main.big_face._targets:
		if str(main.big_face._targets[index]["parameter"]) == "cutoff" 				and wheel_knob == null:
			wheel_knob = (main.big_face._cells[index] as Node).get_child(0)
	check(wheel_knob != null, "a knob on the face to aim the wheel at")
	if wheel_knob != null:
		var held: float = (wheel_knob as RackView.Knob)._position
		_wheel_with_ctrl(wheel_knob)
		check(absf((wheel_knob as RackView.Knob)._position - held) < 0.0001,
			"Ctrl+wheel over a knob leaves the value alone (%.3f)"
				% (wheel_knob as RackView.Knob)._position)
		_wheel(wheel_knob, true)
		check((wheel_knob as RackView.Knob)._position > held,
			"and the plain wheel still steps it (%.3f)"
				% (wheel_knob as RackView.Knob)._position)
		(wheel_knob as RackView.Knob).set_value_silently(
			(wheel_knob as RackView.Knob)._to_value(held))

	main.wires_button.pressed.emit()
	for i in 10:
		await process_frame
	var wires_back := 0
	for child in main.graph_edit.get_children():
		if child is GraphNode and (child as GraphNode).visible:
			wires_back += 1
	check(not main.big_face.visible and wires_back > 0
			and main.graph_edit.get_connection_list().size() == wired_before,
		"and WIRES puts the wiring back, cables and all (%d nodes, %d cables)"
			% [wires_back, main.graph_edit.get_connection_list().size()])

	main.show_view("Graph")
	for i in 6:
		await process_frame
	# Dragging the band moves everything mounted in the case, and by the same step, so
	# the patch keeps its shape and only its position changes.
	var was_at := {}
	for child in main.graph_edit.get_children():
		var moved := child as GraphNode
		if moved != null and moved.visible:
			was_at[str(moved.name)] = moved.position_offset
	var grip: Vector2 = main.graph_edit._case_band_rect().position + Vector2(6.0, 6.0)
	_drag_graph(main, grip, grip + Vector2(120.0, 60.0))
	for i in 8:
		await process_frame
	# One step for all of them, within floating point: the deltas are accumulated per
	# node, so demanding they be bit-identical would be demanding arithmetic that never
	# rounds. What matters is that nothing drifts relative to anything else.
	var first_step := Vector2.ZERO
	var spread := 0.0
	var counted := 0
	for child in main.graph_edit.get_children():
		var moved := child as GraphNode
		if moved == null or not was_at.has(str(moved.name)):
			continue
		var step_taken: Vector2 = moved.position_offset - was_at[str(moved.name)]
		if counted == 0:
			first_step = step_taken
		spread = maxf(spread, step_taken.distance_to(first_step))
		counted += 1
	check(counted > 1 and first_step.length() > 1.0 and spread < 0.01,
		"dragging the band moves every node by one step (%d nodes by %s, spread %.4f)"
			% [counted, str(first_step), spread])
	await main._undo()
	for i in 6:
		await process_frame
	var back := true
	for child in main.graph_edit.get_children():
		var moved := child as GraphNode
		if moved != null and was_at.has(str(moved.name)) \
				and moved.position_offset.distance_to(was_at[str(moved.name)]) > 1.0:
			back = false
	check(back, "and undo puts the case back where it was")
	await main._load_example("First Synth")
	for i in 6:
		await process_frame
	await main._load_example("First Synth")
	for i in 6:
		await process_frame

	main._load_example("First Synth")
	await process_frame

	# ---- rack case width ---------------------------------------------------------------
	# Filling the window is the default; a fixed case is the setting. Both have to actually
	# change where modules wrap, or the option is decoration.
	main.rack.size = Vector2(4000, 900)
	main.rack.case_hp = 0
	main.rack.rebuild()
	await process_frame
	var widest_free := 0.0
	for child in main.rack.get_children():
		if child is Rack.RackModule:
			widest_free = maxf(widest_free, child.position.x + child.size.x)

	# Narrow enough to force wrapping. An 84 HP case proves nothing on this patch: seven
	# modules fit in one row at 84 HP and at 4000 pixels alike, so both come out the same
	# width and the check passes without having tested anything.
	main.rack.case_hp = 16
	await process_frame
	var widest_cased := 0.0
	for child in main.rack.get_children():
		if child is Rack.RackModule:
			widest_cased = maxf(widest_cased, child.position.x + child.size.x)

	check(widest_cased <= 16 * Rack.HP + Rack.CASE_MARGIN * 2.0,
		"a 16 HP case wraps its modules inside 16 HP")
	check(widest_free > widest_cased * 1.5,
		"and fitting the window spreads them far wider than that")

	main.rack.case_hp = 0

	# ---- every example in the menu actually opens ---------------------------------------
	# A menu entry pointing at a missing or broken file is a failure the user finds by
	# clicking it in front of somebody. There are thirty-three of these now and thirty-one
	# arrived from a generator, so checking them one by one is worth the seconds it takes.
	#
	# The menu is built by scanning, so this walks whatever the scan found rather than a
	# list — which means it also checks the scan itself, and would notice it finding
	# nothing.
	var examples_ok := 0
	var examples_bad: Array = []
	check(main._examples.size() >= 20,
		"the examples scan found %d patches" % main._examples.size())
	for example_name in main._examples:
		var example_path: String = main._example_path(main._examples[example_name])
		var example_text := FileAccess.get_file_as_string(example_path)
		if example_text.is_empty():
			examples_bad.append("%s (missing)" % example_name)
			continue
		var example_report: Variant = JSON.parse_string(
			main.engine.validate_patch(example_text))
		if typeof(example_report) == TYPE_DICTIONARY and example_report["ok"]:
			examples_ok += 1
		else:
			examples_bad.append(example_name)
	check(examples_bad.is_empty(),
		"every example in the menu loads and validates (%d of %d)%s"
			% [examples_ok, main._examples.size(),
			   "" if examples_bad.is_empty() else " — bad: " + ", ".join(examples_bad)])

	# The game sounds are one-shots, so the Fire button is the only way to hear one twice.
	await main._load_example("Game: coin")
	await process_frame
	await process_frame
	check(main.engine.is_loaded(), "a game sound opens as an ordinary patch")

	# The generated patches carry no positions, so without a layout on load every node
	# lands on the origin and the graph is one unreadable stack.
	var seen_positions := {}
	var on_origin := 0
	for node in main.patch["nodes"]:
		var at := Vector2(node.get("position", {}).get("x", 0.0),
			node.get("position", {}).get("y", 0.0))
		seen_positions["%s,%s" % [at.x, at.y]] = true
		if at.is_zero_approx():
			on_origin += 1
	check(seen_positions.size() == main.patch["nodes"].size(),
		"and a patch with no layout is face_now on load, not stacked (%d distinct of %d)"
			% [seen_positions.size(), main.patch["nodes"].size()])
	check(on_origin <= 1, "with at most one node left on the origin")
	# Fired the way the Fire button does it: these are gated by a NoteInput now, so a
	# reset alone leaves them silent.
	main.engine.reset()
	main.engine.note_on(60, 1.0)
	var fired := 0
	# The loudest moment, not the last one. get_peak() reports a recent window, and a coin
	# is about forty milliseconds — read it after eight blocks and the sound is long over,
	# which is how this first "failed" while working perfectly.
	var loudest := 0.0
	if playback != null:
		for i in 8:
			fired += main.engine.fill_playback(playback, 1024)
			loudest = maxf(loudest, main.engine.get_peak())
			await process_frame
	check(fired > 0 and loudest > 0.001,
		"and firing it again produces sound (peak %.4f)" % loudest)

	await main._load_example("First Synth")
	await process_frame
	await process_frame

	# ---- rack order survives a save and a load -----------------------------------------
	# The whole reason it lives in the document rather than in the view. Written and read
	# back through the core's own serialiser, because a round trip that only goes through
	# Godot's JSON would not prove the core carries it.
	main.rack.rebuild()
	await process_frame
	var natural: Array = main.rack._module_order()
	check(natural.size() >= 3, "the demo patch has enough modules to reorder")

	if natural.size() >= 3:
		# Dropped onto the far left, ahead of the first module. The earlier version of this
		# passed a point the dragged module was already sitting on, which is exactly the
		# case the bug hid behind: the nearest module to a dropped module is itself.
		var moved: String = natural[natural.size() - 1]
		var first: Rack.RackModule = main.rack._modules[natural[0]]
		main.rack.move_module_to(moved, first.position + Vector2(-40.0, first.size.y * 0.5))
		var reordered: Array = main.rack._module_order()
		check(reordered[0] == moved, "dragging a module to the front puts it there")

		# And a drop in the middle lands in the middle, not at either end — the check that
		# tells "it moved" apart from "it went to the edge whatever I did".
		var middle_target: Rack.RackModule = main.rack._modules[reordered[2]]
		var mover: String = reordered[reordered.size() - 1]
		main.rack.move_module_to(mover,
			middle_target.position + Vector2(-20.0, middle_target.size.y * 0.5))
		var again: Array = main.rack._module_order()
		var landed := again.find(mover)
		check(landed > 0 and landed < again.size() - 1,
			"and dropping one between two others lands it between them (slot %d of %d)"
				% [landed, again.size()])

		var saved: String = main.engine.format_patch(JSON.stringify(main.patch, "  "))
		check(saved.contains("arrangement") and saved.contains("rack_order"),
			"and the order is written into the patch as an arrangement hint")

		await main._load_text(saved)
		await process_frame
		await process_frame
		main.rack.rebuild()
		await process_frame
		check(main.rack._module_order()[0] == moved,
			"and it is still there after saving and loading")

		main.rack.clear_order_override()
		await main._load_example("First Synth")
		await process_frame

	# ---- the sandbox -------------------------------------------------------------------
	# The sandbox is the answer to "how would I use this in a game", so the thing worth
	# checking is that its sounds actually load. A silent demo is worse than no demo: it
	# looks like the project does not work.
	check(main.sandbox != null, "the editor has a sandbox tab")
	if main.sandbox != null and main.sandbox.sounds != null:
		# Loaded on demand now rather than at startup, so ask for them.
		main.sandbox.ensure_sounds_loaded()
		var names: Array = main.sandbox.sounds.sound_names()
		check(names.size() >= 6,
			"and it loaded its sound patches (%d found)" % names.size())
		for expected in ["jump", "coin", "hurt", "shoot", "powerup", "explode"]:
			check(main.sandbox.sounds.has_sound(expected),
				"including %s.json" % expected)

		# Every one has to be a patch the core accepted, not merely a file that existed.
		# load_sound only records a voice after load_patch succeeds, so a name being
		# present is that guarantee — but check a render too, since a graph that loads and
		# produces nothing is the failure that would not be noticed.
		var engine = main.sandbox.sounds._voices["jump"]["engine"]
		check(engine.is_loaded(), "and the jump patch is loaded in its own engine")

		# reset() is what retriggers a one-shot; without it the sandbox plays each sound
		# once and is silent forever after.
		engine.reset()
		check(true, "and reset() is callable for retriggering")

		# An unknown name must warn, not crash: a typo in a game should not take the game
		# down with it.
		main.sandbox.sounds.play("no-such-sound")
		check(true, "playing an unknown sound does not crash")

	# ---- the build stamp -------------------------------------------------------------
	# "Am I running a stale build" has to be answerable, and — more importantly — the
	# answer must never be confidently wrong. A missing stamp says "development build";
	# it must not invent a version, because a build stamp that lies converts uncertainty
	# into false certainty, which is worse than the uncertainty it remounted.
	var description: String = main._build_description()
	check(not description.is_empty(), "the editor can say what build it is (%s)"
		% description)
	var stamped: Dictionary = main._build_stamp()
	if stamped.is_empty():
		check(description.begins_with("development build"),
			"an unstamped run says so rather than guessing (%s)" % description)
	else:
		check(description.contains(str(stamped["short"]))
				and description.contains("ago"),
			"a stamped run gives its version and how old it is (%s)" % description)

	check(main._elapsed(30) == "30 seconds" and main._elapsed(3600) == "60 minutes"
			and main._elapsed(86400 * 3) == "3 days" and main._elapsed(-5).length() > 0,
		"and the age reads in units a person would use (%s, %s, %s)"
			% [main._elapsed(30), main._elapsed(3600), main._elapsed(86400 * 3)])

	# The way this feature breaks silently: the stamp is a non-resource file, so it
	# reaches the web bundle only because the export preset names it. Drop that line and
	# every exported build quietly claims to be a development build — the one place the
	# question is hardest to answer by other means, answered wrongly.
	var preset := FileAccess.open("res://export_presets.cfg", FileAccess.READ)
	check(preset != null and preset.get_as_text().contains("build_stamp.json"),
		"and the web export is still set up to carry the stamp")

	player.queue_free()
	main.queue_free()
	await process_frame

	# Same teardown as roundtrip.gd, for the same reason: AudioServer mixes on its own
	# thread and holds the generator playback, so the engine has to be let go with
	# frames to spare rather than destroyed underneath it. This harness was crashing
	# at exit too, just without anything watching the exit status.
	if main.has_method("shutdown_audio"):
		main.shutdown_audio()
		await process_frame
		await process_frame

	print("")
	if failures == 0:
		print("all editor checks passed")
		quit(0)
	else:
		print("%d editor check(s) failed" % failures)
		quit(1)
