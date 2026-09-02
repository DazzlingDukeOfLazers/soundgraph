extends SceneTree

## Routing goal 2: what a forty-unit edit costs, in every geometry the product uses.
##
##   godot --headless --path editor-godot --script route_stability.gd
##
## Goal 1 reported that a single node nudge moves a cable up to 21.3x the nudge and reroutes
## around fifty cables whose own endpoints did not move, and called it an editor-behaviour
## problem. Goal 1.1 then found that the editor opens in CATENARY and draws hanging curves,
## while every one of those figures was measured on `_routes()`. So the claim has an
## unexamined step in it: **nobody has established that the user sees any of this.**
##
## The principle being tested, stated so it cannot quietly narrow to one geometry:
##
## > **A local document edit should cause local change in every geometry the product
## > actually presents or depends upon, unless the previous geometry became invalid.**
##
## Three questions, in the order that stops the later ones being wasted:
##
##   A. **Visibility.** What consumes the routed geometry while catenary is on screen?
##      Asked by switching the style and watching which answers move, not by reading code —
##      a grep finds call sites, and a call site behind a branch is not a dependency.
##   B. **Attribution.** Of the cables that change, which moved because an endpoint moved,
##      which because the moved node entered their corridor, and which for no reason this
##      harness can find.
##   C. **Order sensitivity.** Identical geometry, different connection traversal order.
##      If routes change, stranger reroutes are path-allocation order dependence rather
##      than spatial propagation, and that is a different repair entirely.
##
## No router changes. Nothing here is a fix.

const PatchGraph := preload("res://patch_graph.gd")
const CableCrossings := preload("res://cable_crossings.gd")
const LayoutLegalize := preload("res://layout_legalize.gd")
const HarnessExit := preload("res://harness_exit.gd")

const NUDGE := 40.0

## How far a polyline may sit from a node's grown box and still be called "passing" it.
## Wide enough that a cable running down a corridor is recorded as being in that corridor,
## narrow enough that the far side of the patch is not.
const CORRIDOR_BAND := 90.0

const FIXTURES := [
	"res://../examples/patches/plucked-string.json",
	"res://qa/babble-tidied.json",
	"res://qa/dense-graph-tidied.json",
]

var main: Node
var graph: GraphEdit
var layer: Node


func settle(n: int) -> void:
	for i in n:
		await process_frame


func out_dir() -> String:
	return OS.get_environment("ROUTE_STABILITY_OUT")


# ---- geometry, asked for by name -----------------------------------------------------

## The cables as the router has them, keyed by connection.
func routed() -> Dictionary:
	var out := {}
	for route: Dictionary in graph._routes():
		var fields: Array = route["fields"]
		out["%s:%d>%s:%d" % [str(fields[0]), int(fields[1]), str(fields[2]),
			int(fields[3])]] = route["points"]
	return out


## The cables as the cord layer draws them, in graph space so the two are comparable.
##
## `_lay` works in the layer's own coordinates — scaled by the zoom and shifted by the
## scroll — so the scroll is taken back out here. At zoom 1 that makes the two directly
## subtractable, which is the whole point: a deviation in one has to mean the same thing as
## a deviation in the other or the comparison is theatre.
func drawn() -> Dictionary:
	var out := {}
	for cord: Array in layer._lay():
		var points := PackedVector2Array()
		for point: Vector2 in cord[0]:
			points.append(point + graph.scroll_offset)
		out[str(cord[4])] = points
	return out


## How far apart two versions of one cable are, and how much of it moved at all.
func apart(before: PackedVector2Array, after: PackedVector2Array) -> Array:
	var worst := 0.0
	var moved := 0.0
	var total := 0.0
	for i in before.size():
		var point := before[i]
		var nearest := INF
		for j in range(maxi(after.size() - 1, 1)):
			if after.size() < 2:
				break
			nearest = minf(nearest, point.distance_to(
				Geometry2D.get_closest_point_to_segment(point, after[j], after[j + 1])))
		if nearest == INF:
			continue
		worst = maxf(worst, nearest)
		if i > 0:
			var run := before[i - 1].distance_to(point)
			total += run
			if nearest > 1.0:
				moved += run
	return [worst, 0.0 if total <= 0.0 else moved / total]


## Which side of which obstacles this cable passes, in order.
##
## Deliberately not a homotopy class. The question is only whether a cable adjusted itself
## locally or chose another hallway, and for that it is enough to know which obstacles it
## went past and on which side. Cheap, structural, and it survives the polyline being
## resampled — which a vertex-by-vertex comparison does not.
func corridor(points: PackedVector2Array, boxes: Dictionary) -> String:
	var passed: Array = []
	var last := ""
	for i in points.size():
		var point := points[i]
		var nearest := ""
		var nearest_at := CORRIDOR_BAND
		for id: String in boxes:
			var box: Rect2 = boxes[id]
			var to := box.grow(PatchGraph.CLEARANCE)
			var closest := Vector2(
				clampf(point.x, to.position.x, to.end.x),
				clampf(point.y, to.position.y, to.end.y))
			var away := point.distance_to(closest)
			if away < nearest_at:
				nearest_at = away
				nearest = id
		if nearest == "":
			continue
		var box: Rect2 = boxes[nearest]
		var centre := box.get_center()
		var side := ""
		if absf(point.x - centre.x) > absf(point.y - centre.y):
			side = "E" if point.x > centre.x else "W"
		else:
			side = "S" if point.y > centre.y else "N"
		var token := "%s%s" % [nearest, side]
		if token != last:
			passed.append(token)
			last = token
	return "/".join(passed)


func boxes_now() -> Dictionary:
	var out := {}
	for id in main.widgets:
		var widget: GraphNode = main.widgets[id]
		if widget.visible:
			out[str(widget.name)] = Rect2(widget.position_offset, widget.size)
	return out



# ---- part A: what actually consumes the routed geometry ------------------------------

## Every product pathway that could plausibly read a cable's shape, asked twice.
##
## The method is the point. A grep finds call sites, and `_get_connection_line` calls
## `_route` at a line that CATENARY never reaches — so the source says "drawing depends on
## the router" and the product says otherwise. Instead each pathway is asked for its answer
## in both cable styles with nothing else changed. An answer that moves consumes the drawn
## geometry; an answer that does not consume the routed one.
##
## Hit testing is asked differently, because "does the number move" is the wrong question
## for it. What matters there is whether the cable you can see is the cable you can click,
## so it is probed at points taken from the drawn curve and asked to name the connection.
func dependency_map() -> Dictionary:
	var out := {}

	var ask := func() -> Dictionary:
		var faults: Dictionary = main._layout_faults()
		return {
			"layout crossings": float(main._layout_crossings()),
			"structural cable, total": snappedf(float((main._structural_cable() as Array)[0]), 1.0),
			"structural cable, longest": snappedf(float((main._structural_cable() as Array)[1]), 1.0),
			"legalize trespasses": float((faults.get("trespass", []) as Array).size()),
			"crossing marks": float((layer.crossing_sites() as Array).size()),
		}

	var was: int = graph.cable_style
	var catenary: Dictionary = ask.call()
	graph.cable_style = 1
	await settle(6)
	var pcb: Dictionary = ask.call()
	graph.cable_style = was
	await settle(6)

	for name: String in catenary:
		var same: bool = absf(float(catenary[name]) - float(pcb[name])) < 0.5
		# "The answer did not move" is only evidence of reading the routed geometry when
		# the two geometries would have given different answers. On a patch where both
		# cross once, a crossing count that stays at one has told you nothing, and calling
		# that "routed" would be the instrument asserting rather than measuring.
		out[name] = {"catenary": catenary[name], "pcb": pcb[name],
			"reads": ("indeterminate here" if same and _both_agree(name)
				else ("routed" if same else "drawn"))}

	# Hit testing, on its own terms: can the user click the cable they can see?
	#
	# Sampled away from the ends, because `_connection_at` deliberately refuses the last
	# thirty units at each end — those belong to the ports, and stealing the click there
	# would make disconnecting impossible.
	var reachable := 0
	var wrong := 0
	var missed := 0
	var offsets: Array = []
	var shown := drawn()
	for key: String in shown:
		var points: PackedVector2Array = shown[key]
		if points.size() < 3:
			continue
		var at: Vector2 = points[points.size() / 2]
		var hit: Dictionary = graph._connection_at(at)
		reachable += 1
		if hit.is_empty():
			missed += 1
		else:
			var named := "%s:%d>%s:%d" % [str(hit["from_node"]), int(hit["from_port"]),
				str(hit["to_node"]), int(hit["to_port"])]
			if named != key:
				wrong += 1
		# And how far the click target actually is from the drawn cable at that point.
		var routes := routed()
		if routes.has(key):
			var line: PackedVector2Array = routes[key]
			var nearest := INF
			for j in range(line.size() - 1):
				nearest = minf(nearest, at.distance_to(
					Geometry2D.get_closest_point_to_segment(at, line[j], line[j + 1])))
			if nearest < INF:
				offsets.append(nearest)
	offsets.sort()
	out["hit test"] = {"sampled": reachable, "missed": missed, "named another cable": wrong,
		"median offset": 0.0 if offsets.is_empty()
			else snappedf(offsets[offsets.size() / 2], 0.1),
		"worst offset": 0.0 if offsets.is_empty()
			else snappedf(offsets[offsets.size() - 1], 0.1),
		"grab distance": PatchGraph.GRAB_DISTANCE}
	return out


## Whether this metric is one the two geometries are known to answer differently. Without
## that, an unmoved answer proves nothing.
func _both_agree(name: String) -> bool:
	return name in ["layout crossings", "crossing marks"]


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
		var map := await dependency_map()
		for name: String in map:
			if name == "hit test":
				continue
			var row: Dictionary = map[name]
			print("  %-24s %-8s  catenary %s / pcb %s"
				% [name, str(row["reads"]), str(row["catenary"]), str(row["pcb"])])
		var hit: Dictionary = map["hit test"]
		print("  %-24s %d sampled, %d hit nothing, %d named another cable"
			% ["hit test", int(hit["sampled"]), int(hit["missed"]),
				int(hit["named another cable"])])
		print("  %-24s median %s, worst %s, against a grab distance of %s"
			% ["  drawn-to-target gap", str(hit["median offset"]),
				str(hit["worst offset"]), str(hit["grab distance"])])

		var order := await order_sensitivity()
		print("  %-24s %d of %d routes differ when the connection order is reversed"
			% ["connection order", int(order["differ"]), int(order["cables"])])

		var moved := await perturb()
		print("")
		print("  a %d-unit nudge, %d probes" % [int(NUDGE), int(moved["probes"])])
		print("    routed     %d cables changed: %d direct, %d obstacle-local, "
			% [int(moved["routed_changed"]), int(moved["direct"]),
				int(moved["obstacle_local"])]
			+ "%d dependent, %d unexplained"
			% [int(moved["dependent"]), int(moved["stranger"])])
		print("               worst deviation %.1fx the nudge; %d changed corridor"
			% [float(moved["routed_worst"]), int(moved["corridor_changed"])])
		if int(moved["stranger"]) > 0:
			print("               the unexplained run %s to %s units from the node "
				% [str(moved["stranger_reach_median"]),
					str(moved["stranger_reach_worst"])]
				+ "that moved")
		print("    drawn      %d cables changed, %d of them with both endpoints still"
			% [int(moved["drawn_changed"]), int(moved["drawn_strangers"])])
		print("               worst deviation %.1fx the nudge; marks %+d over all probes"
			% [float(moved["drawn_worst"]), int(moved["marks_delta"])])

		record[short] = {"dependency": map, "order": order, "perturbation": moved}

	var folder := out_dir()
	if folder != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var out := FileAccess.open(folder.path_join("route-stability.json"),
			FileAccess.WRITE)
		out.store_string(JSON.stringify(record, "  "))
		out.close()
		print("")
		print("-> %s" % folder.path_join("route-stability.json"))
	await HarnessExit.finish(self, main)


# ---- part C: does the same geometry route differently in a different order? -----------

## Reverses the connection list and asks for the routes again.
##
## Expected to change nothing, and measured anyway. `_current_obstacles` collects node
## rectangles and nothing else, so `_route(a, b)` is a function of two points and a set of
## boxes and cannot see another cable — which means order cannot matter. That is a claim
## about the code, and this programme has been wrong about those. If routes do move, the
## stranger reroutes below are path-allocation order dependence rather than anything
## spatial, and that is a different repair entirely.
func order_sensitivity() -> Dictionary:
	var before := routed()
	var was: Array = graph.connections.duplicate()
	var flipped: Array = []
	for i in range(was.size() - 1, -1, -1):
		flipped.append(was[i])
	graph.connections = flipped
	await settle(4)
	var after := routed()
	graph.connections = was
	await settle(4)
	var differ := 0
	for key: String in before:
		if not after.has(key):
			differ += 1
			continue
		if float((apart(before[key], after[key]) as Array)[0]) > 1.0:
			differ += 1
	return {"cables": before.size(), "differ": differ}


# ---- part B: attribution, in both geometries -----------------------------------------

## Every cable that changes under a nudge, and why.
##
## The four populations are the point. "Fifty cables moved" is not a finding; "fifty cables
## moved and forty-nine of them were standing in the doorway" is one, and so is "fifty moved
## and nine of them were nowhere near".
##
##   direct           an endpoint of this cable is on the node that moved
##   obstacle-local   not direct, but the cable passes through the moved node's influence
##                    region — where it was, or where it went
##   dependent        neither, but it shares an obstacle with a cable that is one of those,
##                    so there is a corridor between them to carry the change
##   unexplained      none of the above: endpoints still, remote from the edit, changed
##                    anyway
##
## A prediction worth writing down before the numbers arrive: obstacles are node rectangles
## and nothing else, so a cable can only reroute if a box it cares about moved. The
## unexplained population should be **empty**, and if it is not, the influence region below
## is wrong rather than the router being mysterious.
func perturb() -> Dictionary:
	var counts := {"probes": 0, "routed_changed": 0, "drawn_changed": 0,
		"direct": 0, "obstacle_local": 0, "dependent": 0, "stranger": 0,
		"corridor_changed": 0, "drawn_strangers": 0, "marks_delta": 0}
	var routed_worst := 0.0
	var drawn_worst := 0.0
	var strangers: Array = []
	var reaches: Array = []

	for id in main.widgets:
		var widget: GraphNode = main.widgets[id]
		if not widget.visible:
			continue
		var home: Vector2 = widget.position_offset
		for step: Vector2 in [Vector2(NUDGE, 0.0), Vector2(-NUDGE, 0.0),
				Vector2(0.0, NUDGE), Vector2(0.0, -NUDGE)]:
			# The baseline is re-read immediately before each probe rather than once at
			# the top of the run. Taken once, it drifts: the first version of this
			# reported twelve cables changing "for no reason", and three of the cases it
			# named turned out to be byte-identical routes measured against a stale
			# reference. The same mistake the focus sheet made in the cable pass — a
			# resting frame from earlier is not the resting frame for this comparison.
			#
			# And since goal 3D routes are session state, the session is reset here too.
			# Otherwise this measures a short history of edits rather than one edit, which
			# is not what "a forty-unit nudge moves a cable N times the nudge" means.
			graph.forget_routes()
			await settle(2)
			var routed_before := routed()
			var drawn_before := drawn()
			var boxes_before := boxes_now()
			var corridors_before := {}
			for key: String in routed_before:
				corridors_before[key] = corridor(routed_before[key], boxes_before)
			var marks_before: int = (layer.crossing_sites() as Array).size()

			widget.position_offset = home + step
			await settle(2)
			counts["probes"] = int(counts["probes"]) + 1

			# The moved node's influence region, both where it was and where it went.
			var region: Array = [
				Rect2(home, widget.size).grow(PatchGraph.CLEARANCE + CORRIDOR_BAND),
				Rect2(home + step, widget.size).grow(
					PatchGraph.CLEARANCE + CORRIDOR_BAND)]

			var routed_after := routed()
			var drawn_after := drawn()
			var boxes_after := boxes_now()
			counts["marks_delta"] = int(counts["marks_delta"]) \
				+ (layer.crossing_sites() as Array).size() - marks_before

			# Which cables are directly attached to the node that moved, and which
			# obstacles those cables run past — the second is what "dependent" needs.
			var touching: Array = []
			var touched_obstacles := {}
			for key: String in routed_before:
				if key.begins_with(str(widget.name) + ":") \
						or key.contains(">" + str(widget.name) + ":"):
					touching.append(key)
					for token: String in str(corridors_before.get(key, "")).split("/"):
						if token != "":
							touched_obstacles[token] = true

			for key: String in routed_before:
				if not routed_after.has(key):
					continue
				var gap: Array = apart(routed_before[key], routed_after[key])
				var shifted := float(gap[0]) > 1.0
				if shifted:
					counts["routed_changed"] = int(counts["routed_changed"]) + 1
					routed_worst = maxf(routed_worst, float(gap[0]) / NUDGE)
					var lane := corridor(routed_after[key], boxes_after)
					if lane != str(corridors_before.get(key, "")):
						counts["corridor_changed"] = int(counts["corridor_changed"]) + 1
					if touching.has(key):
						counts["direct"] = int(counts["direct"]) + 1
					elif _near(routed_before[key], region) \
							or _near(routed_after[key], region):
						counts["obstacle_local"] = int(counts["obstacle_local"]) + 1
					elif _shares(str(corridors_before.get(key, "")), touched_obstacles):
						counts["dependent"] = int(counts["dependent"]) + 1
					else:
						counts["stranger"] = int(counts["stranger"]) + 1
						# How far this cable actually runs from the node that moved. The
						# number that decides whether "unexplained" means the influence
						# region is too small or the router is coupled to obstacles its
						# output never approaches.
						var away := _clearance_to(routed_before[key],
							Rect2(home, widget.size).grow(PatchGraph.CLEARANCE))
						reaches.append(away)
						if strangers.size() < 16:
							strangers.append({"cable": key, "moved": str(widget.name),
								"nudged": str(step),
								"by": snappedf(float(gap[0]), 0.1),
								"distance to the moved node": snappedf(away, 1.0),
								"corridor was": str(corridors_before.get(key, "")),
								"corridor now": lane})

				if drawn_after.has(key) and drawn_before.has(key):
					var seen: Array = apart(drawn_before[key], drawn_after[key])
					if float(seen[0]) > 1.0:
						counts["drawn_changed"] = int(counts["drawn_changed"]) + 1
						drawn_worst = maxf(drawn_worst, float(seen[0]) / NUDGE)
						if not touching.has(key):
							counts["drawn_strangers"] = \
								int(counts["drawn_strangers"]) + 1

			widget.position_offset = home
			await settle(2)

	counts["routed_worst"] = snappedf(routed_worst, 0.1)
	counts["drawn_worst"] = snappedf(drawn_worst, 0.1)
	counts["strangers"] = strangers
	reaches.sort()
	counts["stranger_reach_median"] = 0.0 if reaches.is_empty() 		else snappedf(reaches[reaches.size() / 2], 1.0)
	counts["stranger_reach_worst"] = 0.0 if reaches.is_empty() 		else snappedf(reaches[reaches.size() - 1], 1.0)
	return counts


## The closest this polyline comes to a rectangle.
func _clearance_to(points: PackedVector2Array, box: Rect2) -> float:
	var nearest := INF
	for point: Vector2 in points:
		nearest = minf(nearest, point.distance_to(Vector2(
			clampf(point.x, box.position.x, box.end.x),
			clampf(point.y, box.position.y, box.end.y))))
	return 0.0 if nearest == INF else nearest


func _near(points: PackedVector2Array, region: Array) -> bool:
	for box: Rect2 in region:
		for i in range(points.size() - 1):
			if graph._segment_hits_rect(points[i], points[i + 1], box):
				return true
	return false


func _shares(lane: String, obstacles: Dictionary) -> bool:
	for token: String in lane.split("/"):
		if token != "" and obstacles.has(token):
			return true
	return false
