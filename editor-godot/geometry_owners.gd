extends SceneTree

## Routing goal 2.2: which geometry does each consumer actually mean?
##
##   godot --headless --path editor-godot --script geometry_owners.gd
##
## Goal 2.1 gave the two shapes names. `display_path` is what the user is looking at;
## `routing_path` is the obstacle-avoiding construction `_route` produces. Drawing, crossing
## analysis and picking are settled on the first. Two product consumers still read the
## second, and neither has ever been asked to justify it:
##
##   layout cable total and longest    the arrangement's cost
##   legalizer trespass                whether a cable passes through a node
##
## The question for each is not "which function does it call" but:
##
## > **What semantic property is this consumer trying to measure, and which geometry
## > actually owns that property?**
##
## An audit, not a correction. Nothing here changes a consumer. It exists to establish
## whether the split is harmless bookkeeping or whether the product currently makes
## decisions about geometry the user cannot see — and those are very different problems.
##
## The distinction the report turns on:
##
##   metric disagreement     the two geometries give different numbers. May be harmless.
##   decision disagreement   an operation would have chosen differently. Not harmless.

const PatchGraph := preload("res://patch_graph.gd")
const LayoutLegalize := preload("res://layout_legalize.gd")
const CableCrossings := preload("res://cable_crossings.gd")
const HarnessExit := preload("res://harness_exit.gd")

const CATENARY := 0
const ROUTED := 1

const FIXTURES := [
	"res://../examples/patches/first-synth.json",
	"res://../examples/patches/plucked-string.json",
	"res://qa/babble-tidied.json",
	"res://qa/dense-graph-tidied.json",
	# The constructed case: five nodes, built so the two geometries have to disagree.
	"res://qa/geometry-disagreement.json",
]

var main: Node
var graph: GraphEdit
var layer: Node


func settle(n: int) -> void:
	for i in n:
		await process_frame


func out_dir() -> String:
	return OS.get_environment("GEOMETRY_OWNERS_OUT")


# ---- the two geometries, in the shape the consumers want -----------------------------

## Every cable as `_routes()` returns it, but from whichever provider is asked for.
##
## The consumers take `[{points, fields}]`, so handing them the other geometry is a matter
## of building the same list from the other function. That is what makes this audit cheap
## and what makes it honest: the real consumer code runs, on real geometry, and only the
## geometry is swapped.
func routes_from(which: String) -> Array:
	var out: Array = []
	for connection: Dictionary in graph.connections:
		var points: PackedVector2Array = graph.display_path(connection) \
			if which == "display" else graph.routing_path(connection)
		if points.size() < 2:
			continue
		out.append({"points": points, "fields": graph._connection_fields(connection),
			"colour": Color.WHITE})
	return out


func cable_cost(routes: Array) -> Array:
	var total := 0.0
	var longest := 0.0
	for route: Dictionary in routes:
		var points: PackedVector2Array = route["points"]
		var run := 0.0
		for i in range(points.size() - 1):
			run += points[i].distance_to(points[i + 1])
		total += run
		longest = maxf(longest, run)
	return [total, longest]


func boxes_now() -> Dictionary:
	var out := {}
	for id in main.widgets:
		var widget: GraphNode = main.widgets[id]
		if widget.visible:
			out[str(widget.name)] = Rect2(widget.position_offset, widget.size)
	return out


func places() -> Dictionary:
	var out := {}
	for id in main.widgets:
		out[str(id)] = (main.widgets[id] as GraphNode).position_offset
	return out


func restore(where: Dictionary) -> void:
	for id: String in where:
		if main.widgets.has(id):
			(main.widgets[id] as GraphNode).position_offset = where[id]
	await settle(6)


## Everything a layout operation weighs, under one named geometry.
func objective(which: String) -> Dictionary:
	var routes := routes_from(which)
	var boxes := boxes_now()
	var faults: Dictionary = LayoutLegalize.faults(boxes, routes)
	var cost := cable_cost(routes)
	var cords: Array = layer._lay() if which == "display" else []
	var crossings := 0
	if which == "display":
		crossings = int((CableCrossings.tally(
			CableCrossings.classify(cords)) as Dictionary)["marks"])
	else:
		var as_cords: Array = []
		for route: Dictionary in routes:
			var f: Array = route["fields"]
			as_cords.append([route["points"], Color.WHITE,
				"%s:%d" % [str(f[0]), int(f[1])], "%s:%d" % [str(f[2]), int(f[3])],
				"%s:%d>%s:%d" % [str(f[0]), int(f[1]), str(f[2]), int(f[3])], 0])
		crossings = int((CableCrossings.tally(
			CableCrossings.classify(as_cords)) as Dictionary)["marks"])
	return {"overlaps": (faults["overlaps"] as Array).size(),
		"clearance": (faults["clearance"] as Array).size(),
		"trespass": (faults["trespass"] as Array).size(),
		"trespasses": faults["trespass"],
		"crossings": crossings,
		"cable": snappedf(float(cost[0]), 1.0),
		"longest": snappedf(float(cost[1]), 1.0)}


# ---- 2.2B: the four trespass states --------------------------------------------------

## Which nodes each geometry says a cable passes through, and where they disagree.
##
## The question this exists to answer is blunt:
##
## > **Can the editor call a layout legal while the cable the user is looking at visibly
## > passes through a node?**
##
## And its inverse — can the drawing be clear while the hidden path trespasses, so that
## Resolve overlaps moves a node to fix something nobody can see. Either answer means the
## word "legal" is currently ambiguous, which matters more than which way it is repaired.
func trespass_states() -> Dictionary:
	var boxes := boxes_now()
	var shown: Dictionary = {}
	var hidden: Dictionary = {}
	for row: Array in LayoutLegalize.faults(boxes, routes_from("display"))["trespass"]:
		shown["%s|%s|%s" % [str(row[0]), str(row[1]), str(row[2])]] = true
	for row: Array in LayoutLegalize.faults(boxes, routes_from("routing"))["trespass"]:
		hidden["%s|%s|%s" % [str(row[0]), str(row[1]), str(row[2])]] = true
	var both: Array = []
	var only_shown: Array = []
	var only_hidden: Array = []
	for key: String in shown:
		if hidden.has(key):
			both.append(key)
		else:
			only_shown.append(key)
	for key: String in hidden:
		if not shown.has(key):
			only_hidden.append(key)
	return {"both": both, "display only": only_shown, "routing only": only_hidden}


# ---- 2.2C and 2.2D: do the operations decide differently? ----------------------------

## Runs one product operation and reports what it did, scored under both geometries.
##
## The distinction the whole goal turns on. Two geometries giving different numbers is
## metric disagreement and may be harmless. An operation accepting a move that the other
## geometry says made things worse is decision disagreement, and means the product is
## responding to something nobody can see.
func run_operation(what: String) -> Dictionary:
	var home := places()
	var before_display := objective("display")
	var before_routing := objective("routing")

	match what:
		"resolve overlaps":
			await main._legalize_layout()
		"tidy flow":
			await main._tidy_flow()
		"tidy routes":
			await main._tidy_routes()
	await settle(8)

	var after_display := objective("display")
	var after_routing := objective("routing")
	var stirred := 0
	var now := places()
	for id: String in home:
		if (home[id] as Vector2).distance_to(now[id]) > 0.5:
			stirred += 1

	await restore(home)
	return {"moved": stirred,
		"display": {"before": before_display, "after": after_display},
		"routing": {"before": before_routing, "after": after_routing},
		"verdict": _verdict(before_display, after_display, before_routing, after_routing,
			stirred)}


## Whether the two geometries agree that this operation improved the arrangement.
##
## Deliberately coarse. It compares the direction each metric moved, not a full lexicographic
## objective, because the claim being made is only "these two would not have decided the
## same way" — and a metric that improves in one geometry while worsening in the other is
## enough to establish that without reimplementing the comparator.
func _verdict(was_shown: Dictionary, is_shown: Dictionary, was_hidden: Dictionary,
		is_hidden: Dictionary, stirred: int) -> Dictionary:
	var split: Array = []
	for name: String in ["overlaps", "clearance", "trespass", "crossings", "cable",
			"longest"]:
		var shown := signf(float(is_shown[name]) - float(was_shown[name]))
		var hidden := signf(float(is_hidden[name]) - float(was_hidden[name]))
		if shown != hidden:
			split.append("%s: drawn %+.0f, routed %+.0f"
				% [name, float(is_shown[name]) - float(was_shown[name]),
					float(is_hidden[name]) - float(was_hidden[name])])
	return {"moved nodes": stirred, "metrics that disagree in direction": split}


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
			layer = child

	var record := {}
	for path: String in FIXTURES:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var short := path.get_file().get_basename()
		await main._load_text(file.get_as_text())
		await settle(24)
		main._set_roll_open(false)
		graph.zoom = 1.0
		await settle(10)

		print("")
		print("%s" % short)
		record[short] = {}

		# ---- 2.2A: the contract table, four cells per metric ------------------------
		var cells := {}
		for style in [CATENARY, ROUTED]:
			graph.cable_style = style

			await settle(6)
			var named := "catenary" if style == CATENARY else "routed"
			for which: String in ["display", "routing"]:
				cells["%s/%s" % [named, which]] = objective(which)
		graph.cable_style = CATENARY
		await settle(6)
		record[short]["cells"] = cells

		print("  %-22s %-13s %-13s %-13s %s"
			% ["", "cat/display", "cat/routing", "rtd/display", "rtd/routing"])
		for name: String in ["cable", "longest", "trespass", "crossings"]:
			print("  %-22s %-13s %-13s %-13s %s"
				% [name,
					str((cells["catenary/display"] as Dictionary)[name]),
					str((cells["catenary/routing"] as Dictionary)[name]),
					str((cells["routed/display"] as Dictionary)[name]),
					str((cells["routed/routing"] as Dictionary)[name])])

		# ---- 2.2B: trespass, four states --------------------------------------------
		var states := trespass_states()
		record[short]["trespass states"] = states
		print("  trespass               both %d, drawn only %d, routed only %d"
			% [(states["both"] as Array).size(),
				(states["display only"] as Array).size(),
				(states["routing only"] as Array).size()])
		for key: String in states["display only"]:
			print("      drawn through %s, and the router says it is clear" % key)
		for key: String in states["routing only"]:
			print("      router says through %s, and the drawing is clear" % key)

		# ---- 2.2C: do the operations decide differently? ----------------------------
		for what: String in ["resolve overlaps", "tidy flow", "tidy routes"]:
			var ran := await run_operation(what)
			record[short][what] = ran
			var verdict: Dictionary = ran["verdict"]
			var split: Array = verdict["metrics that disagree in direction"]
			print("  %-22s moved %d nodes; %s"
				% [what, int(ran["moved"]),
					"the two geometries agree on every metric" if split.is_empty()
						else "DISAGREE — " + ", ".join(split)])

		# ---- 2.2D: does the arrangement depend on the cable style? ------------------
		var placements := {}
		for style in [CATENARY, ROUTED]:
			graph.cable_style = style
			await settle(6)
			var home := places()
			await main._tidy_flow()
			await settle(8)
			placements["catenary" if style == CATENARY else "routed"] = places()
			await restore(home)
		graph.cable_style = CATENARY
		await settle(6)
		var differ := 0
		for id: String in placements["catenary"]:
			if (placements["catenary"][id] as Vector2).distance_to(
					placements["routed"][id]) > 0.5:
				differ += 1
		record[short]["style invariance"] = {"nodes placed differently": differ}
		print("  tidy flow              %s"
			% ["places every node the same in both cable styles" if differ == 0
				else "places %d nodes differently depending on cable style" % differ])

	var folder := out_dir()
	if folder != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var out := FileAccess.open(folder.path_join("geometry-owners.json"),
			FileAccess.WRITE)
		out.store_string(JSON.stringify(record, "  "))
		out.close()
		print("")
		print("-> %s" % folder.path_join("geometry-owners.json"))
	await HarnessExit.finish(self, main)
