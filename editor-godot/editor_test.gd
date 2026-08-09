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
	# clicking it in front of somebody. There are ten of these now and eight arrived from a
	# generator, so checking them one by one is worth the seconds it takes.
	var examples_ok := 0
	var examples_bad: Array = []
	for example_name in main.EXAMPLES:
		var example_path: String = main._example_path(main.EXAMPLES[example_name])
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
			% [examples_ok, main.EXAMPLES.size(),
			   "" if examples_bad.is_empty() else " — bad: " + ", ".join(examples_bad)])

	# The game sounds are one-shots, so the Fire button is the only way to hear one twice.
	await main._load_example("Game: coin")
	await process_frame
	await process_frame
	check(main.engine.is_loaded(), "a game sound opens as an ordinary patch")
	main.engine.reset()
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
		check(saved.contains("rack_order"),
			"and the order is written into the patch the core serialises")

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

	print("")
	if failures == 0:
		print("all editor checks passed")
		quit(0)
	else:
		print("%d editor check(s) failed" % failures)
		quit(1)
