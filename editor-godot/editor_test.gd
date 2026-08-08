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

	# ---- undo -------------------------------------------------------------------------
	var file2 := FileAccess.open("res://examples/first-synth.json", FileAccess.READ)
	await main._load_text(file2.get_as_text())
	await process_frame
	await process_frame

	check(not main.undo_redo.has_undo(), "a freshly loaded patch has nothing to undo")

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
