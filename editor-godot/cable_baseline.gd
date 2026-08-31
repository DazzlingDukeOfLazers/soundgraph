extends SceneTree

## Step 1 of the cable pass: what the cables are, before anything is changed.
##
## The node pass started this way and it was worth it — `graph_baseline.gd` froze the node
## boxes, port positions and cable ends so that "the same patch opens the same way
## afterwards" could be a claim about numbers rather than about a memory of a screenshot.
## This is the same move aimed at the routes.
##
## It measures the seven problems rather than describing them, because six of the seven are
## about density and density is exactly what an impression is bad at. "There are a lot of
## crossings" is not a finding. "Thirty-two crossings, of which fifteen are between cables
## of the same colour and none of them meet at under twenty-five degrees" is a finding, and
## it is one a later goal can be held against — and it already moved this pass's first
## question, because the shallow-crossing count everybody expected to be the problem came
## back zero.
##
##   godot --headless --path editor-godot --script cable_baseline.gd
##
## with CABLE_BASELINE_OUT naming a directory for the JSON.
##
## ## What it does not do
##
## It does not judge. Every number here is descriptive, and the thresholds below are
## reporting bands rather than acceptance criteria — nothing in this file says a shallow
## crossing is bad. Deciding that is the next goal's job, and a baseline that arrived with
## its conclusions already in it would be a baseline nobody could disagree with.
##
## It also does not touch the material. `docs/cable-design.md` is a finished, frozen
## subsystem — mass, shell, glint, shadow, plug, hang, departure, crossing occlusion,
## surface response — arrived at over ten goals. This pass is about **routing and
## legibility in a dense field**, which is a different layer, and the frozen figures are
## not in scope.

const PatchGraph := preload("res://patch_graph.gd")
const PATCH := "res://qa/dense-graph.json"

## The zooms the node pass judges at, so the two baselines can be read side by side.
const ZOOMS := [1.0, 0.66, 0.40, 0.28]

## A crossing at a shallow angle is the one a reader has to work at: two strands that meet
## near head-on separate by direction alone, and two that graze share a long stretch of
## near-identical path. Twenty-five degrees is a reporting band, not a verdict.
const SHALLOW_DEGREES := 25.0

## Two routes count as running together where they are within this far of each other, in
## graph units, and headed within this many degrees of the same direction. Ten units is a
## little over a cable width; fifteen degrees is close enough that the eye reads them as
## one rail rather than as two cables that happen to be near.
const BUNDLE_GAP := 10.0
const BUNDLE_DEGREES := 15.0

## How far a route may pass from a node it has no business with before it is counted as
## crossing that node's territory. Zero would count only literal overlap; a cable running
## along a node's edge is the same reading problem.
const NEAR_NODE := 6.0

## Two colours count as the same when every channel is within this. Signal colours are
## drawn from a small palette, so this only ever collapses a colour onto itself.
const SAME_HUE := 0.02

## The cord layer's own width, and the floor under it. Copied from `CordLayer._draw`
## rather than read from `connection_lines_thickness`, which is GraphEdit's figure and is
## not what gets drawn — the cords layer took the drawing over and asking the old property
## reports zero, which is what the first run of this file said the cable area was.
const CORD_WIDTH := 8.0
const CORD_WIDTH_FLOOR := 2.4

var main: Node
var graph: GraphEdit


func out_dir() -> String:
	var asked := OS.get_environment("CABLE_BASELINE_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func length_of(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## The direction a route is heading where it passes through a point. Locally a route is
## straight, so the segment containing the point is the answer.
func direction_at(points: PackedVector2Array, point: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var nearest := INF
	for i in range(points.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(point, points[i],
			points[i + 1])
		var away := closest.distance_squared_to(point)
		if away < nearest:
			nearest = away
			best = (points[i + 1] - points[i]).normalized()
	return best


## The unsigned angle between two headings, in degrees, folded onto 0-90. A crossing does
## not care which way either cable is travelling — only how much they differ in slope.
func meeting_angle(first: Vector2, second: Vector2) -> float:
	if first == Vector2.ZERO or second == Vector2.ZERO:
		return 90.0
	var between := rad_to_deg(acos(clampf(absf(first.dot(second)), 0.0, 1.0)))
	return between


func same_colour(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < SAME_HUE and absf(a.g - b.g) < SAME_HUE \
		and absf(a.b - b.b) < SAME_HUE


## How much of two routes runs alongside each other: near enough and parallel enough that
## the eye reads a rail rather than two cables.
##
## Sampled rather than solved. The exact answer is a swept-region intersection and the
## question is "how much visual mass do these two make together", which a sample at cable
## width answers well enough and a closed form would answer no better.
func alongside(first: PackedVector2Array, second: PackedVector2Array) -> float:
	var step := BUNDLE_GAP
	var run := 0.0
	for i in range(first.size() - 1):
		var span := first[i].distance_to(first[i + 1])
		if span <= 0.001:
			continue
		var heading := (first[i + 1] - first[i]).normalized()
		var samples := maxi(1, int(span / step))
		for s in samples:
			var at: Vector2 = first[i].lerp(first[i + 1],
				(float(s) + 0.5) / float(samples))
			var near := INF
			var other := Vector2.ZERO
			for j in range(second.size() - 1):
				var closest := Geometry2D.get_closest_point_to_segment(at, second[j],
					second[j + 1])
				var away := closest.distance_to(at)
				if away < near:
					near = away
					other = (second[j + 1] - second[j]).normalized()
			if near <= BUNDLE_GAP \
					and meeting_angle(heading, other) <= BUNDLE_DEGREES:
				run += span / float(samples)
	return run


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	var file := FileAccess.open(PATCH, FileAccess.READ)
	if file == null:
		printerr("could not read %s" % PATCH)
		quit(1)
		return
	await main._load_text(file.get_as_text())
	await settle(20)
	main._set_roll_open(false)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	graph.zoom = 1.0
	await settle(12)

	var record := {"patch": "dense QA", "cables": [], "crossings": [],
		"bundles": [], "territory": [], "zooms": []}

	# The routes as the renderer has them: graph space, with the colour GraphEdit drew
	# each one in. Asked of the graph rather than recomputed, for the reason every
	# harness in this repository is written that way — a measurement that agrees with
	# itself instead of with the program measures nothing.
	var routes: Array = graph._routes()
	print("%d cables" % routes.size())

	var nodes: Array = []
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget != null and widget.visible:
			nodes.append({"name": str(widget.name), "title": widget.title,
				"rect": Rect2(widget.position_offset, widget.size)})

	# ---- one cable at a time -------------------------------------------------------
	for route: Dictionary in routes:
		var points: PackedVector2Array = route["points"]
		if points.size() < 2:
			continue
		var run := length_of(points)
		var straight := points[0].distance_to(points[points.size() - 1])
		record["cables"].append({
			"from": str(route["fields"][0]), "out": int(route["fields"][1]),
			"to": str(route["fields"][2]), "in": int(route["fields"][3]),
			"colour": str(route["colour"].to_html(false)),
			"length": snappedf(run, 0.1),
			"straight": snappedf(straight, 0.1),
			# How far the route wanders past the shortest path between its ends. One is a
			# straight line; the interesting figure is the tail.
			"detour": snappedf(run / maxf(straight, 1.0), 0.001),
		})

	# ---- where they meet -----------------------------------------------------------
	# Cables leaving one port or arriving at one meet by design and are not crossings; the
	# renderer's own crossing pass makes the same exclusion, and for the same reason.
	for i in routes.size():
		for j in range(i + 1, routes.size()):
			var a: Dictionary = routes[i]
			var b: Dictionary = routes[j]
			if a["fields"][0] == b["fields"][0] or a["fields"][2] == b["fields"][2]:
				continue
			var first: PackedVector2Array = a["points"]
			var second: PackedVector2Array = b["points"]
			for m in range(first.size() - 1):
				for n in range(second.size() - 1):
					var hit: Variant = Geometry2D.segment_intersects_segment(
						first[m], first[m + 1], second[n], second[n + 1])
					if hit == null:
						continue
					var angle := meeting_angle(
						(first[m + 1] - first[m]).normalized(),
						(second[n + 1] - second[n]).normalized())
					record["crossings"].append({
						"at": [snappedf(hit.x, 0.1), snappedf(hit.y, 0.1)],
						"angle": snappedf(angle, 0.1),
						"same_colour": same_colour(a["colour"], b["colour"]),
						"between": [str(a["fields"][0]), str(b["fields"][0])],
					})

			var run := alongside(first, second)
			if run > BUNDLE_GAP * 2.0:
				record["bundles"].append({
					"between": [str(a["fields"][0]), str(b["fields"][0])],
					"run": snappedf(run, 0.1),
					"same_colour": same_colour(a["colour"], b["colour"]),
				})

	# ---- whose territory they cross ------------------------------------------------
	for route: Dictionary in routes:
		var points: PackedVector2Array = route["points"]
		var over: Array = []
		for entry: Dictionary in nodes:
			# Its own ends are not trespass.
			if str(entry["name"]) == str(route["fields"][0]) \
					or str(entry["name"]) == str(route["fields"][2]):
				continue
			var box: Rect2 = (entry["rect"] as Rect2).grow(NEAR_NODE)
			var inside := 0.0
			for i in range(points.size() - 1):
				# Sampled at the same step the bundle test uses, so the two figures are
				# comparable and neither is more precise than it deserves to be.
				var span := points[i].distance_to(points[i + 1])
				var samples := maxi(1, int(span / BUNDLE_GAP))
				for s in samples:
					var at: Vector2 = points[i].lerp(points[i + 1],
						(float(s) + 0.5) / float(samples))
					if box.has_point(at):
						inside += span / float(samples)
			if inside > 0.0:
				over.append({"node": str(entry["title"]), "run": snappedf(inside, 0.1)})
		if not over.is_empty():
			record["territory"].append({"from": str(route["fields"][0]),
				"to": str(route["fields"][2]), "over": over})

	# ---- how much of the picture is cable, at each distance -------------------------
	# Geometric rather than sampled from pixels: total drawn cable area against the graph
	# viewport. A pixel count would have to know the palette and would change meaning the
	# day a palette did.
	#
	# The width is the cord layer's own, which does not scale linearly: `maxf(8 * zoom,
	# 2.4)` puts a floor under it, so below a zoom of 0.3 a cable stops getting thinner
	# while everything around it carries on shrinking. That floor is a decision about
	# legibility and it is also the arithmetic behind problem 7 — the reason cables become
	# a larger share of the picture as the node detail goes.
	var total := 0.0
	for route: Dictionary in routes:
		total += length_of(route["points"])
	# The patch's own extent, which is what the cable share is measured against.
	var box := Rect2()
	var first_box := true
	for entry: Dictionary in nodes:
		box = (entry["rect"] as Rect2) if first_box else box.merge(entry["rect"] as Rect2)
		first_box = false
	record["extent"] = [snappedf(box.size.x, 0.1), snappedf(box.size.y, 0.1)]
	record["cable_length"] = snappedf(total, 0.1)
	for zoom: float in ZOOMS:
		graph.zoom = zoom
		graph._update_detail()
		main._apply_detail(graph.detail)
		await settle(8)
		var width: float = maxf(CORD_WIDTH * zoom, CORD_WIDTH_FLOOR)
		var ink := total * zoom * width
		# Against the patch's own footprint on screen, not against the viewport. At 100%
		# the graph is larger than the window, so a fraction of the frame would be
		# measuring how much of the patch happens to be in shot.
		#
		# Written this way the arithmetic says something: while the width scales, the
		# fraction is a constant `8 * length / area` — cables keep their exact share of
		# the picture at every distance. It is only under the floor that it climbs, and
		# that climb is problem 7 in one column.
		var footprint := box.size.x * box.size.y * zoom * zoom
		record["zooms"].append({
			"zoom": zoom,
			"band": NodeOptical.name_of(NodeOptical.of(graph.detail)),
			"cord_width": snappedf(width, 0.01),
			"cable_area": snappedf(ink, 0.1),
			"patch_area": snappedf(footprint, 0.1),
			"ink_fraction": snappedf(ink / maxf(footprint, 1.0), 0.0001),
		})

	# ---- the report ----------------------------------------------------------------
	var lengths: Array = []
	for entry: Dictionary in record["cables"]:
		lengths.append(float(entry["length"]))
	lengths.sort()
	var longest: float = lengths[lengths.size() - 1] if not lengths.is_empty() else 0.0
	var median: float = lengths[lengths.size() / 2] if not lengths.is_empty() else 0.0

	var shallow := 0
	var same := 0
	var shallow_same := 0
	for entry: Dictionary in record["crossings"]:
		var is_shallow: bool = float(entry["angle"]) < SHALLOW_DEGREES
		if is_shallow:
			shallow += 1
		if bool(entry["same_colour"]):
			same += 1
			if is_shallow:
				shallow_same += 1

	var trespass := 0
	for entry: Dictionary in record["territory"]:
		trespass += (entry["over"] as Array).size()

	print("")
	print("cables            %d" % record["cables"].size())
	print("  median length   %.0f units" % median)
	print("  longest         %.0f units" % longest)
	print("crossings         %d" % record["crossings"].size())
	print("  same colour     %d" % same)
	print("  under %.0f deg    %d" % [SHALLOW_DEGREES, shallow])
	print("  both            %d   <- the ones a reader has to work at" % shallow_same)
	print("bundled pairs     %d  (within %.0f units, under %.0f deg, for over %.0f units)"
		% [record["bundles"].size(), BUNDLE_GAP, BUNDLE_DEGREES, BUNDLE_GAP * 2.0])
	print("node crossings    %d  (a cable over a node it has no business with)" % trespass)
	print("")
	print("patch extent      %.0f x %.0f units, %.0f units of cable in it"
		% [box.size.x, box.size.y, total])
	print("")
	print("%-8s %-8s %10s %14s" % ["zoom", "band", "cord px", "cable share"])
	for entry: Dictionary in record["zooms"]:
		print("%-8.0f %-8s %10.2f %13.1f%%" % [float(entry["zoom"]) * 100.0,
			str(entry["band"]), float(entry["cord_width"]),
			float(entry["ink_fraction"]) * 100.0])

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	var out := FileAccess.open(folder.path_join("cable-baseline.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()
	print("")
	print("-> %s" % folder.path_join("cable-baseline.json"))
	quit()
