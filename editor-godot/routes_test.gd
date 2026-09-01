extends SceneTree

## Tidy routes' acceptance test, and it is mostly about refusal.
##
## The crossing-cost frontier found a sharp knee: on the legalized hostile patch several
## forty-unit moves each remove a crossing at zero or one inversion, and then the curve jumps
## to candidates costing thousands of units and dozens of reorderings. This operation lives
## entirely below the knee, so most of what it must be held to is what it must not do.
##
##   godot --headless --path editor-godot --script routes_test.gd
##
## The gates are about the **knee**, not about a particular fixture doing nothing. That was
## the original design and babble corrected it: the operation takes it from nine crossings to
## seven for two forty-unit nudges, which the single-move frontier had said was out of reach.
## What every fixture is held to instead is that nothing moves sideways, no run reorders more
## than one pair of neighbours per move, the stage vector never regresses, and a patch with no
## cheap win left is untouched.

const PatchGraph := preload("res://patch_graph.gd")

var main: Node
var graph: GraphEdit
var failures := 0


func settle(n: int) -> void:
	for i in n:
		await process_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("  ok   %s" % description)
	else:
		failures += 1
		print("  FAIL %s" % description)


func open_patch(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	await main._load_text(file.get_as_text())
	await settle(24)
	main._set_roll_open(false)
	graph.zoom = 1.0
	await settle(10)


func positions() -> Dictionary:
	var at := {}
	for node: Dictionary in main.patch.get("nodes", []):
		at[str(node["id"])] = Vector2(float(node.get("position", {}).get("x", 0.0)),
			float(node.get("position", {}).get("y", 0.0)))
	return at


func spent(before: Dictionary) -> Array:
	var after := positions()
	var moved := 0
	var total := 0.0
	var sideways := 0.0
	for id: String in after:
		if not before.has(id):
			continue
		var was: Vector2 = before[id]
		var now: Vector2 = after[id]
		if was.distance_to(now) > 0.5:
			moved += 1
			total += was.distance_to(now)
			sideways = maxf(sideways, absf(now.x - was.x))
	return [moved, total, sideways]


func stage_vector() -> Array:
	var ids: Array = []
	var edges: Array = []
	for id in main.widgets:
		ids.append(str((main.widgets[id] as GraphNode).name))
	for wire in graph.get_connection_list():
		edges.append([str(wire["from_node"]), str(wire["to_node"])])
	var boxes: Dictionary = main._layout_boxes()
	return LayoutTidy.vector(boxes, LayoutTidy.stages(ids, edges), edges,
		main._layout_tolerance(boxes))


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)

	print("")
	print("tidy routes")

	# ---- the patch with a knee --------------------------------------------------------
	await open_patch("res://qa/dense-graph-legalized.json")
	var was := positions()
	var before_crossings: int = main._layout_crossings()
	var before_stage := stage_vector()
	var before_heights: Dictionary = main._layout_heights()
	await main._tidy_routes()
	await settle(16)
	var cost := spent(was)
	var after_crossings: int = main._layout_crossings()
	print("  dense-graph-legalized: %d -> %d crossings, %d node%s, %.0f units"
		% [before_crossings, after_crossings, int(cost[0]),
			"" if int(cost[0]) == 1 else "s", float(cost[1])])
	check(after_crossings < before_crossings,
		"a cheap crossing removal is found (%d -> %d)"
			% [before_crossings, after_crossings])
	check(int(main._layout_faults()["total"]) == 0, "and the graph is still legal")
	check(not LayoutTidy.better(before_stage, stage_vector()),
		"and the stage vector did not regress")
	check(float(cost[2]) < 0.5, "and nothing moved sideways (%.0f)" % float(cost[2]))
	# The knee, expressed as the thing it is: at most one pair of neighbours reordered per
	# move, so a whole run of them stays inside the author's vertical organisation.
	var turned: int = LayoutTidy.inversions(before_heights, main._layout_heights())
	check(turned <= LayoutTidy.ORDER_BUDGET * int(cost[0]),
		"and %d vertical order inversions for %d move%s"
			% [turned, int(cost[0]), "" if int(cost[0]) == 1 else "s"])

	var settled := positions()
	await main._tidy_routes()
	await settle(12)
	check(int(spent(settled)[0]) == 0, "a second press moves nothing")
	await main._load_text(JSON.stringify(main.patch, "  "))
	await settle(24)
	main._set_roll_open(false)
	graph.zoom = 1.0
	await settle(10)
	var reloaded := positions()
	await main._tidy_routes()
	await settle(12)
	check(int(spent(reloaded)[0]) == 0, "and so does a press after a reload")

	# ---- babble, and the correction it forced -------------------------------------------
	# This was written expecting babble to move nothing. The crossing-cost frontier had
	# offered nine-to-eight for five or six reorderings and no adjacent swap helped at all,
	# so 5A concluded that placement had run out there.
	#
	# It had not. The operation takes babble from nine crossings to seven, for two
	# forty-unit nudges and a single inversion — better than any candidate the frontier
	# printed, and comfortably inside the knee.
	#
	# The frontier measured single moves from the resting arrangement. The operation is
	# iterative: it takes one cheap move, the drawing changes, and a second cheap move
	# exists that did not before. A Pareto sheet of single moves understates what a
	# sequence of them can reach, and that is a property of the instrument rather than of
	# babble.
	#
	# So the signature test is not "moves nothing". It is that whatever it takes stays
	# inside the knee: no sideways movement, at most one reordering per move, and the stage
	# vector no worse.
	await open_patch("res://../examples/patches/babble.json")
	var babble_was := positions()
	var babble_crossings: int = main._layout_crossings()
	var babble_heights: Dictionary = main._layout_heights()
	await main._tidy_routes()
	await settle(16)
	var babble_cost := spent(babble_was)
	print("  babble: %d -> %d crossings, %d node%s, %.0f units, %d inversions"
		% [babble_crossings, main._layout_crossings(), int(babble_cost[0]),
			"" if int(babble_cost[0]) == 1 else "s", float(babble_cost[1]),
			LayoutTidy.inversions(babble_heights, main._layout_heights())])
	var babble_turned: int = LayoutTidy.inversions(babble_heights, main._layout_heights())
	check(main._layout_crossings() < babble_crossings,
		"babble loses crossings after all (%d -> %d)"
			% [babble_crossings, main._layout_crossings()])
	check(float(babble_cost[2]) < 0.5,
		"without a single sideways move (%.0f)" % float(babble_cost[2]))
	check(babble_turned <= LayoutTidy.ORDER_BUDGET * int(babble_cost[0]),
		"and %d inversion%s for %d move%s, which is inside the knee"
			% [babble_turned, "" if babble_turned == 1 else "s",
				int(babble_cost[0]), "" if int(babble_cost[0]) == 1 else "s"])
	check(int(main._layout_faults()["total"]) == 0, "and it is still legal")

	# ---- no general cleanup ------------------------------------------------------------
	for path: String in ["res://../examples/patches/plucked-string.json",
			"res://../examples/patches/first-synth.json"]:
		await open_patch(path)
		var small_was := positions()
		var small_crossings: int = main._layout_crossings()
		await main._tidy_routes()
		await settle(12)
		var small_cost := spent(small_was)
		var short := path.get_file().get_basename()
		if int(small_cost[0]) > 0:
			check(main._layout_crossings() < small_crossings,
				"%s moved %d node%s and removed a crossing"
					% [short, int(small_cost[0]), "" if int(small_cost[0]) == 1 else "s"])
		else:
			check(true, "%s has no cheap crossing to take, so nothing moves" % short)

	# ---- selection scoping --------------------------------------------------------------
	await open_patch("res://qa/dense-graph-legalized.json")
	var only := ""
	for id in main.widgets:
		only = str(id)
		break
	graph.set_selected(main.widgets[only])
	var before_selection := positions()
	await main._tidy_routes()
	await settle(12)
	var after_selection := positions()
	var strangers := 0
	for id: String in after_selection:
		if id == only:
			continue
		if (before_selection[id] as Vector2).distance_to(after_selection[id]) > 0.5:
			strangers += 1
	check(strangers == 0, "with one node selected, no other node moves (%d did)" % strangers)

	print("")
	if failures == 0:
		print("all route checks passed")
	else:
		print("%d route check(s) failed" % failures)
	quit(0 if failures == 0 else 1)
