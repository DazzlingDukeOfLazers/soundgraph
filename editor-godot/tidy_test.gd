extends SceneTree

## The stage/flow tidy's acceptance test.
##
## The risk is the same one Goal 3 faced and it is worth naming: an operation whose mandate
## is "improve agreement between topology and drawing" can drift into "produce a better
## drawing", and the second one is Auto-place. So the gates are mostly about what it must
## **not** do.
##
##   godot --headless --path editor-godot --script tidy_test.gd
##
## The proving grounds are the two legal hostile fixtures. `dense-graph-legalized` is a
## disciplined hand arrangement with 26 residual stage violations — a good tidy makes small
## improvements with small movements rather than deciding 26 means reconstruction.
## `babble` is the interesting one: 73 violations, 4 surplus columns, and perfectly legal,
## so it is where legalization correctly did nothing and this operation has to earn its
## place.
##
## **Zero violations is not the target.** The metric describes disagreement between topology
## and spatial order, not validity: feedback, fan-in, shared modulation and deliberate
## authored composition all leave residue. 26 to 18 for five small moves is excellent; 26 to
## 4 for thirty moves has failed the product intention.

const PatchGraph := preload("res://patch_graph.gd")
const HarnessExit := preload("res://harness_exit.gd")

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
	var worst := 0.0
	var each: Array = []
	for id: String in after:
		if not before.has(id):
			continue
		var distance: float = (before[id] as Vector2).distance_to(after[id])
		if distance > 0.5:
			moved += 1
			total += distance
			worst = maxf(worst, distance)
			each.append(distance)
	each.sort()
	return [moved, total, worst,
		each[each.size() / 2] if not each.is_empty() else 0.0]


## The four numbers the operation optimises, plus the two it only watches.
func report() -> Dictionary:
	var ids: Array = []
	var edges: Array = []
	for id in main.widgets:
		ids.append(str((main.widgets[id] as GraphNode).name))
	for wire in graph.get_connection_list():
		edges.append([str(wire["from_node"]), str(wire["to_node"])])
	var boxes: Dictionary = main._layout_boxes()
	var depth := LayoutTidy.stages(ids, edges)
	var vector := LayoutTidy.vector(boxes, depth, edges, main._layout_tolerance(boxes))
	var cable := 0.0
	var longest := 0.0
	for route: Dictionary in graph._routes():
		var points: PackedVector2Array = route["points"]
		var run := 0.0
		for i in range(points.size() - 1):
			run += points[i].distance_to(points[i + 1])
		cable += run
		longest = maxf(longest, run)
	return {"violations": vector[0], "backward": vector[1], "spread": vector[2],
		"surplus": vector[3], "crossings": main._layout_crossings(),
		"cable": cable, "longest": longest,
		"faults": int(main._layout_faults()["total"])}


func show(what: String, before: Dictionary, after: Dictionary, cost: Array) -> void:
	print("  %s" % what)
	for key: String in ["violations", "backward", "spread", "surplus", "crossings",
			"cable", "longest", "faults"]:
		print("    %-12s %10.0f -> %-10.0f" % [key, float(before[key]), float(after[key])])
	print("    %-12s %d moved, %.0f total, %.0f median, %.0f worst"
		% ["cost", int(cost[0]), float(cost[1]), float(cost[3]), float(cost[2])])
	var removed: float = float(before["violations"]) - float(after["violations"])
	if int(cost[0]) > 0:
		print("    %-12s %.1f per node moved, %.1f per 1000 units"
			% ["yield", removed / float(cost[0]), removed / maxf(float(cost[1]), 1.0) * 1000.0])


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
	print("stage/flow tidy")

	for path: String in ["res://qa/dense-graph-legalized.json",
			"res://../examples/patches/babble.json"]:
		await open_patch(path)
		var short := path.get_file().get_basename()
		var was := positions()
		var before := report()
		check(int(before["faults"]) == 0, "%s starts legal" % short)
		await main._tidy_flow()
		await settle(16)
		var after := report()
		var cost := spent(was)
		show(short, before, after, cost)

		check(int(after["faults"]) == 0, "%s is still legal afterwards" % short)
		check(int(after["violations"]) <= int(before["violations"]),
			"and its stage violations did not get worse")
		check(int(after["crossings"]) <= int(before["crossings"]),
			"and neither did its crossings (%d -> %d)"
				% [int(before["crossings"]), int(after["crossings"])])
		# Local: the whole point. Auto-place moved 29 of 30 nodes on this graph.
		check(int(cost[0]) <= int(main.patch["nodes"].size()) / 2,
			"moving %d of %d nodes" % [int(cost[0]), int(main.patch["nodes"].size())])

		# A fixed point, and one that survives a save and a reload.
		var settled := positions()
		await main._tidy_flow()
		await settle(12)
		check(int(spent(settled)[0]) == 0, "and running it again moves nothing")
		# A reload on its own, before any tidying, so a difference afterwards can be
		# attributed. The editor snaps positions to its grid when a document is opened,
		# and a patch authored off-grid arrives somewhere slightly different from where
		# it was saved — which is a fact about loading rather than about this operation.
		# Reopened the way the editor opens a document, zoom and detail band included.
		# Without that the graph comes back at whatever zoom the session was left at, the
		# nodes are a different height in a different detail band, and their centres — and
		# therefore their stage bands — are somewhere else. Three more moves became
		# available and it looked like the operation was not converging, when what had
		# changed was the size of everything it was measuring.
		var saved := positions()
		var text := JSON.stringify(main.patch, "  ")
		await main._load_text(text)
		await settle(24)
		main._set_roll_open(false)
		graph.zoom = 1.0
		await settle(10)
		var reloaded := positions()
		var snapped: int = int(spent(saved)[0])
		if snapped > 0:
			print("    note: opening the document moved %d node%s by itself"
				% [snapped, "" if snapped == 1 else "s"])
		await main._tidy_flow()
		await settle(12)
		var again: int = int(spent(reloaded)[0])
		check(again == 0 or snapped > 0,
			"and still nothing after a reload (%d moved, %d snapped on open)"
				% [again, snapped])

	# ---- selection scoping ------------------------------------------------------------
	await open_patch("res://qa/dense-graph-legalized.json")
	var only := ""
	for id in main.widgets:
		only = str(id)
		break
	graph.set_selected(main.widgets[only])
	var before_selection := positions()
	await main._tidy_flow()
	await settle(12)
	var after_selection := positions()
	var strangers := 0
	for id: String in after_selection:
		if id == only:
			continue
		if (before_selection[id] as Vector2).distance_to(after_selection[id]) > 0.5:
			strangers += 1
	check(strangers == 0,
		"with one node selected, no other node moves (%d did)" % strangers)

	# ---- and it is allowed to do nothing ----------------------------------------------
	# The operation may say the author already did better than it can prove.
	await open_patch("res://../examples/patches/plucked-string.json")
	var tidy_before := positions()
	await main._tidy_flow()
	await settle(12)
	print("  plucked-string moved %d nodes" % int(spent(tidy_before)[0]))

	print("")
	if failures == 0:
		print("all tidy checks passed")
	else:
		print("%d tidy check(s) failed" % failures)
	await HarnessExit.finish(self, main, 0 if failures == 0 else 1)
