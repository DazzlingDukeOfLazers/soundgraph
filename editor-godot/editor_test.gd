extends SceneTree
## Headless checks on the editor itself.
##
##   godot --headless --script res://editor_test.gd
##
## The round-trip check (tools/verify-roundtrip.mjs) proves a patch survives being loaded
## and saved. This proves the things a round trip cannot see: that the graph view is built
## from the registry with the right ports, that search and validation come from the core,
## that a wire can be inspected, and that audio is actually produced.

var failures := 0


func check(condition: bool, description: String) -> void:
	if condition:
		print("  ok   %s" % description)
	else:
		print("  FAIL %s" % description)
		failures += 1


func _initialize() -> void:
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

	# ---- the graph view is generated from that vocabulary -----------------------------
	var file := FileAccess.open("res://examples/first-synth.json", FileAccess.READ)
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
		if main.rack._type_of(order[i]) == "StereoOutput":
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
	check(not main.document_label.text.contains("●"),
		"and its name is plain (%s)" % main.document_label.text)

	main._begin_edit()
	main._set_parameter("filter", "cutoff", 2500.0)
	main._commit_edit("set cutoff")
	await process_frame
	check(main.unsaved, "changing something marks it unsaved")
	check(main.document_label.text.contains("●"),
		"and the document name says so (%s)" % main.document_label.text)

	# Opening another document clears it, or the mark would follow you around for the
	# rest of the session and stop meaning anything.
	await main._load_example("Delay Echo")
	await process_frame
	check(not main.unsaved, "opening another one clears the mark")
	await main._load_example("First Synth")
	await process_frame

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

	# The slider and the field are two views of one value, so moving either has to move
	# the other. A field that drifted out of step with its slider would be worse than the
	# label it replaced.
	var cutoff_slider: HSlider = main.parameter_widgets["filter"]["cutoff"]["slider"]
	cutoff_field._on_typed("1000")
	await process_frame
	var slider_spot: float = main._to_position(main.parameter_widgets["filter"]["cutoff"]["descriptor"],
		1000.0)
	# To within the slider's own step, because the slider quantises its position and the
	# field does not. That is the right way round: the stored value stays exactly what
	# was typed, and only the handle is snapped.
	check(absf(cutoff_slider.value - slider_spot) <= cutoff_slider.step,
		"typing a value moves the slider with it (%.6f vs %.6f, step %.4f)"
			% [cutoff_slider.value, slider_spot, cutoff_slider.step])

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
		port_spots_at_full.append(node_widget.get_input_port_position(port))

	main.graph_edit.zoom = 0.5
	main.graph_edit._update_detail()
	await process_frame
	check(main.graph_edit.detail == main.PatchGraph.Detail.REDUCED,
		"zooming out drops the parameters (level %d)" % main.graph_edit.detail)
	var medium: float = node_widget.get_combined_minimum_size().y
	check(medium < full_height,
		"and the node gets shorter for it (%.0f from %.0f)" % [medium, full_height])

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
		if control == null or str(control.get_meta("row", "")) != "port":
			continue
		for side in control.get_children():
			for part in (side as Control).get_children():
				if part is Label and (part as Label).visible:
					visible_port_labels += 1
	check(visible_port_labels == 0,
		"and the port names are actually hidden (%d still showing)" % visible_port_labels)

	var ports_now := node_widget.get_input_port_count()
	check(ports_now == ports_at_full,
		"and the port count is unchanged (%d, was %d)" % [ports_now, ports_at_full])
	var shifted := 0
	for port in mini(ports_now, ports_at_full):
		if not node_widget.get_input_port_position(port).is_equal_approx(
				port_spots_at_full[port]):
			shifted += 1
	check(shifted == 0,
		"and not one of them has moved (%d of %d shifted)" % [shifted, ports_now])

	# Hysteresis: a zoom sitting on a threshold must not flip level on every jitter.
	main.graph_edit.zoom = 0.40
	main.graph_edit._update_detail()
	check(main.graph_edit.detail == main.PatchGraph.Detail.TOPOLOGY,
		"a nudge back over the boundary does not flip the level straight away")
	main.graph_edit.zoom = 0.50
	main.graph_edit._update_detail()
	check(main.graph_edit.detail == main.PatchGraph.Detail.REDUCED,
		"but a real move does")

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
		if control != null and control.get_meta("collapsed", false):
			folded += 1
			if control.visible:
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
	check(main.context_heading.text == "THE GRAPH",
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
	check(main.context_heading.text == "SELECTED NODE",
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
	var column: Control = main.split.get_parent()
	var needed: float = column.get_combined_minimum_size().x
	check(needed <= 1280.0,
		"the editor fits a 1280px window (needs %.0f)" % needed)

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
		check(title_size > Design.scale(Design.SIZE_BODY),
			"and are larger than body text (%d vs %d)"
				% [title_size, Design.scale(Design.SIZE_BODY)])

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
	check(buttons == 5, "with five buttons on it: collapse, two octave, two width (%d)"
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
			if str(node["type"]) == "NoteInput":
				coin_has_trigger = true
	check(coin_nodes > 0 and not coin_has_trigger,
		"a game sound imported as a module leaves its NoteInput behind")

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
		"and a patch with no layout is arranged on load, not stacked (%d distinct of %d)"
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
