extends SceneTree

## Layout goal 5A: what does removing a crossing actually cost?
##
## Not an operation and not an algorithm. Goal 4 ended with a measured hypothesis — babble's
## remaining disorder is not reachable by horizontal moves — and with a warning: the first
## implementation, given permission to trade, spent seven crossings and ten thousand units of
## cable to remove seventeen stage violations. Given permission to trade the other way, a
## lexicographic search would spend just as freely.
##
## So the question is not "can crossings be reduced". It is:
##
## > **What does removing a crossing cost in authored arrangement, cable and space?**
##
##   godot --headless --path editor-godot --script crossing_frontier.gd
##
## with CROSSING_FRONTIER_OUT naming a directory.
##
## ## What is held fixed
##
## [codeblock]
## tier 0        untouched
## tier 1        legal before and legal after, every candidate
## stage vector  may not worsen — goal 5 cannot buy a crossing by undoing goal 4
## X             fixed; only Y is opened
## the router    unchanged
## [/codeblock]
##
## X is held so the hypothesis is isolated rather than confirmed by accident. And the router
## is held because changing where the same two endpoints route is a different project: it
## would alter every cable in every existing patch and reopen route QA, whereas moving a node
## and letting the existing router respond is layout.
##
## ## No budget is chosen here
##
## Deliberately no answer to "a crossing is worth five hundred units". That is the weighted
## score in another costume, and the point of a frontier is to see the curve before deciding
## where on it to stand. `-1 crossing` might cost forty units; `-3` might need a vertical
## reorder and four thousand units of cable, and only the sheet can say.

const PatchGraph := preload("res://patch_graph.gd")
const HarnessExit := preload("res://harness_exit.gd")

const PATCHES := ["res://../examples/patches/babble.json",
	"res://qa/dense-graph-legalized.json"]
const GRID := 40.0

var main: Node
var graph: GraphEdit
var cords: CanvasItem


func out_dir() -> String:
	var asked := OS.get_environment("CROSSING_FRONTIER_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func open_patch(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	await main._load_text(file.get_as_text())
	await settle(24)
	main._set_roll_open(false)
	graph.zoom = 1.0
	await settle(10)


func names() -> Array:
	var out: Array = []
	for id in main.widgets:
		out.append(str((main.widgets[id] as GraphNode).name))
	out.sort()
	return out


func edges() -> Array:
	var out: Array = []
	for wire in graph.get_connection_list():
		out.append([str(wire["from_node"]), str(wire["to_node"])])
	return out


## Everything one arrangement is worth recording, in one call.
func snapshot(depth: Dictionary, wires: Array) -> Dictionary:
	var boxes: Dictionary = main._layout_boxes()
	var tolerance: float = main._layout_tolerance(boxes)
	var cable := 0.0
	var longest := 0.0
	for route: Dictionary in graph._routes():
		var points: PackedVector2Array = route["points"]
		var run := 0.0
		for i in range(points.size() - 1):
			run += points[i].distance_to(points[i + 1])
		cable += run
		longest = maxf(longest, run)
	var box := Rect2()
	var first := true
	var ys := {}
	for id: String in boxes:
		var own: Rect2 = boxes[id]
		box = own if first else box.merge(own)
		first = false
		ys[id] = own.get_center().y
	return {"crossings": main._layout_crossings(),
		"stage": LayoutTidy.vector(boxes, depth, wires, tolerance),
		"cable": cable, "longest": longest,
		"area": box.size.x * box.size.y / 1000000.0,
		"faults": int(main._layout_faults()["total"]), "ys": ys}


## Shared with the operation that uses it, rather than reimplemented here.
func inversions(before: Dictionary, after: Dictionary) -> int:
	return LayoutTidy.inversions(before, after)


## Vertical positions worth trying for one node.
##
## Generated rather than scanned. A sweep of the plane would spend its time in places no
## arrangement would ever put a node; these are the positions a person would consider —
## level with something this node is connected to, the middle of everything it is connected
## to, tucked directly above or below a neighbour, or a step from where it already is.
func candidates(name: String, boxes: Dictionary, wires: Array) -> Array:
	var own: Rect2 = boxes[name]
	var out := {}
	var linked: Array = []
	for edge: Array in wires:
		if str(edge[0]) == name and boxes.has(edge[1]):
			linked.append(str(edge[1]))
		elif str(edge[1]) == name and boxes.has(edge[0]):
			linked.append(str(edge[0]))

	var total := 0.0
	for other: String in linked:
		var centre: float = (boxes[other] as Rect2).get_center().y
		total += centre
		# Level with a neighbour: the cable between them becomes horizontal.
		out[snappedf(centre - own.size.y * 0.5, GRID)] = true
	if not linked.is_empty():
		# And the barycentre of everything it is connected to, which is where a cable
		# minimiser would put it if nothing else were in the way.
		out[snappedf(total / float(linked.size()) - own.size.y * 0.5, GRID)] = true

	for other: String in boxes:
		if other == name:
			continue
		var box: Rect2 = boxes[other]
		# Immediately above and below another node, with the clearance the legalizer
		# insists on, since those are the slots an arrangement actually has.
		out[snappedf(box.position.y - own.size.y - LayoutLegalize.CLEARANCE - 4.0,
			GRID)] = true
		out[snappedf(box.end.y + LayoutLegalize.CLEARANCE + 4.0, GRID)] = true

	for step in [-4, -3, -2, -1, 1, 2, 3, 4]:
		out[snappedf(own.position.y + float(step) * GRID, GRID)] = true

	out.erase(snappedf(own.position.y, GRID))
	return out.keys()


## Whether `a` dominates `b`: at least as good everywhere, strictly better somewhere.
func dominates(a: Dictionary, b: Dictionary) -> bool:
	var better := false
	for key: String in ["removed", "displacement", "cable", "longest", "inversions"]:
		var mine := float(a[key]) * (-1.0 if key == "removed" else 1.0)
		var theirs := float(b[key]) * (-1.0 if key == "removed" else 1.0)
		if mine > theirs + 0.0001:
			return false
		if mine < theirs - 0.0001:
			better = true
	return better


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	for child in graph.get_children():
		if child.has_method("crossing_sites"):
			cords = child

	var record := {}
	for path: String in PATCHES:
		await open_patch(path)
		var short := path.get_file().get_basename()
		var ids := names()
		var wires := edges()
		var depth := LayoutTidy.stages(ids, wires)
		var rest := snapshot(depth, wires)
		print("")
		print("%s — %d crossings, %d stage violations, %.0f cable, %.0f longest"
			% [short, int(rest["crossings"]), int((rest["stage"] as Array)[0]),
				float(rest["cable"]), float(rest["longest"])])
		if int(rest["faults"]) > 0:
			print("  not legal to begin with; skipped")
			continue

		var found: Array = []
		var boxes: Dictionary = main._layout_boxes()
		for name: String in ids:
			var widget: GraphNode = graph.get_node_or_null(NodePath(name))
			if widget == null:
				continue
			var was: Vector2 = widget.position_offset
			for y: float in candidates(name, boxes, wires):
				widget.position_offset = Vector2(was.x, y)
				await process_frame
				var now := snapshot(depth, wires)
				widget.position_offset = was
				# The hard constraints. Legality is absolute, and the stage vector may not
				# worsen — goal 5 cannot buy a crossing by undoing goal 4.
				if int(now["faults"]) > 0:
					continue
				if LayoutTidy.better(rest["stage"], now["stage"]):
					continue
				var removed: int = int(rest["crossings"]) - int(now["crossings"])
				if removed <= 0:
					continue
				found.append({"node": name, "y": y, "removed": removed,
					"displacement": absf(y - was.y),
					"cable": float(now["cable"]) - float(rest["cable"]),
					"longest": float(now["longest"]) - float(rest["longest"]),
					"area": float(now["area"]) - float(rest["area"]),
					"inversions": inversions(rest["ys"], now["ys"]),
					"stage_delta": (now["stage"] as Array)[0]
						- (rest["stage"] as Array)[0]})
			await process_frame

		# ---- the second experiment, when one node cannot do much --------------------
		# Adjacent vertical swaps: two nodes exchange heights and keep their columns. The
		# brief said to reach for this only if single-node movement proved weak, and on
		# babble it did — thirteen moves in the whole graph remove a crossing and not one
		# removes two. A swap is the smallest two-node move there is and it is the one a
		# person would try next.
		var swaps := 0
		if not found.is_empty() and int((found[0] as Dictionary)["removed"]) <= 1:
			for i in ids.size():
				for j in range(i + 1, ids.size()):
					var one: GraphNode = graph.get_node_or_null(NodePath(ids[i]))
					var two: GraphNode = graph.get_node_or_null(NodePath(ids[j]))
					if one == null or two == null:
						continue
					var was_one: Vector2 = one.position_offset
					var was_two: Vector2 = two.position_offset
					one.position_offset = Vector2(was_one.x, was_two.y)
					two.position_offset = Vector2(was_two.x, was_one.y)
					await process_frame
					var after := snapshot(depth, wires)
					one.position_offset = was_one
					two.position_offset = was_two
					if int(after["faults"]) > 0:
						continue
					if LayoutTidy.better(rest["stage"], after["stage"]):
						continue
					var gained: int = int(rest["crossings"]) - int(after["crossings"])
					if gained <= 0:
						continue
					swaps += 1
					found.append({"node": "%s+%s" % [ids[i], ids[j]], "y": 0.0,
						"removed": gained,
						"displacement": absf(was_one.y - was_two.y) * 2.0,
						"cable": float(after["cable"]) - float(rest["cable"]),
						"longest": float(after["longest"]) - float(rest["longest"]),
						"area": float(after["area"]) - float(rest["area"]),
						"inversions": inversions(rest["ys"], after["ys"]),
						"stage_delta": 0})
				await process_frame
			print("  and %d adjacent vertical swaps remove one" % swaps)

		# The frontier: everything nothing else beats outright.
		var frontier: Array = []
		for candidate: Dictionary in found:
			var beaten := false
			for other: Dictionary in found:
				if dominates(other, candidate):
					beaten = true
					break
			if not beaten:
				frontier.append(candidate)
		frontier.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["removed"]) != int(b["removed"]):
				return int(a["removed"]) > int(b["removed"])
			return float(a["displacement"]) < float(b["displacement"]))

		print("  %d single-node moves remove a crossing; %d of them are on the frontier"
			% [found.size(), frontier.size()])
		if not frontier.is_empty():
			print("  %-8s %8s %8s %10s %10s %8s %6s" % ["node", "-cross", "moved",
				"cable", "longest", "area", "inver"])
		for candidate: Dictionary in frontier:
			print("  %-8s %8d %8.0f %10.0f %10.0f %8.2f %6d"
				% [str(candidate["node"]), int(candidate["removed"]),
					float(candidate["displacement"]), float(candidate["cable"]),
					float(candidate["longest"]), float(candidate["area"]),
					int(candidate["inversions"])])
		record[short] = {"resting": {"crossings": rest["crossings"],
			"stage": rest["stage"], "cable": snappedf(float(rest["cable"]), 0.1),
			"longest": snappedf(float(rest["longest"]), 0.1)},
			"candidates": found.size(), "frontier": frontier}

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	var out := FileAccess.open(folder.path_join("crossing-frontier.json"),
		FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()
	print("")
	print("-> %s" % folder.path_join("crossing-frontier.json"))
	await HarnessExit.finish(self, main)
