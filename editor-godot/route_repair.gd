extends SceneTree

## Routing goal 3C: when a cable had to move, did it have to move that much?
##
##   godot --headless --path editor-godot --script route_repair.gd
##
## Goal 3 settled *who* may affect a cable — an obstacle that participated in its routing
## decision, and nobody else, which took the unconsulted reroutes from thirteen and eight to
## zero. It left a different question open, and the 34.9x specimen on the dense fixture is
## the whole of it:
##
## > **When an obstacle that was allowed to affect a cable does affect it, did the edit
## > actually require throwing away that much of the existing route?**
##
## No algorithm changes here. This classifies the *old* route against the *new* obstacle
## state, because the three possible answers point at three different repairs and choosing
## between them without the evidence is how a router acquires a mechanism it did not need:
##
##   still legal        the old corridor stayed valid. The router simply preferred another
##                      one — a ranking problem, and continuity preference would fix it.
##   locally repairable the old route broke, but only near the obstacle that moved. The rest
##                      of it is still good — a local segment repair would fix it.
##   corridor-invalid   keeping the old corridor is genuinely impossible. The magnitude may
##                      be unavoidable, and the question becomes candidate richness.
##
## Route memory is deliberately not on that list. "Prefer where this cable used to be"
## introduces session-history semantics — does opening a document produce the routes the
## session that saved it had? — before anything has established that the previous path
## deserved preserving. Two of the three answers above need no memory at all.

const PatchGraph := preload("res://patch_graph.gd")
const HarnessExit := preload("res://harness_exit.gd")

const NUDGE := 40.0

## How close a point has to sit to the new route to count as unchanged.
##
## A quarter of `CLEARANCE`, so "the same corridor here" means visibly the same rather than
## numerically identical — a chamfered corner shifting a unit or two is not a reroute.
const SAME := 6.5

const FIXTURES := [
	"res://qa/babble-tidied.json",
	"res://qa/dense-graph-tidied.json",
]

var main: Node
var graph: GraphEdit


func settle(n: int) -> void:
	for i in n:
		await process_frame


func out_dir() -> String:
	return OS.get_environment("ROUTE_REPAIR_OUT")


func routes_now() -> Dictionary:
	var out := {}
	for route: Dictionary in graph._routes():
		var f: Array = route["fields"]
		out["%s:%d>%s:%d" % [str(f[0]), int(f[1]), str(f[2]), int(f[3])]] = route["points"]
	return out


func ends_now() -> Dictionary:
	var out := {}
	for connection: Dictionary in graph.connections:
		var e: Array = graph._endpoints(connection)
		if e.is_empty():
			continue
		var f: Array = graph._connection_fields(connection)
		out["%s:%d>%s:%d" % [str(f[0]), int(f[1]), str(f[2]), int(f[3])]] = e
	return out


func arc(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## How far a point is from a polyline.
func gap(point: Vector2, path: PackedVector2Array) -> float:
	var nearest := INF
	for i in range(path.size() - 1):
		nearest = minf(nearest, point.distance_to(
			Geometry2D.get_closest_point_to_segment(point, path[i], path[i + 1])))
	return 0.0 if nearest == INF else nearest


## What fraction of the old route the new one still runs along.
##
## Sampled by arc length rather than by vertex, because the two polylines rarely share a
## vertex count and a per-vertex comparison would call a resampled identical path a change.
func preserved(old: PackedVector2Array, new: PackedVector2Array) -> float:
	if old.size() < 2 or new.size() < 2:
		return 0.0
	var total := 0.0
	var kept := 0.0
	for i in range(old.size() - 1):
		var span := old[i].distance_to(old[i + 1])
		var steps := maxi(1, int(span / 8.0))
		for step in steps:
			var at := old[i].lerp(old[i + 1], (float(step) + 0.5) / float(steps))
			var piece := span / float(steps)
			total += piece
			if gap(at, new) < SAME:
				kept += piece
	return 0.0 if total <= 0.0 else kept / total


## Which segments of this route are blocked in the obstacle state as it stands now, and by
## what. `skip` is the pair of node rectangles the cable's own ends live in.
func damage(points: PackedVector2Array, skip: Array, moved: Rect2) -> Dictionary:
	var blocked: Array = []
	var only_the_mover := true
	for i in range(points.size() - 1):
		var hit := false
		var by_mover := false
		for rect: Rect2 in graph._current_obstacles():
			var own := false
			for mine: Rect2 in skip:
				if mine.position.is_equal_approx(rect.position):
					own = true
			if own:
				continue
			if not graph._segment_hits_rect(points[i], points[i + 1], rect):
				continue
			hit = true
			if rect.position.is_equal_approx(moved.position):
				by_mover = true
		if hit:
			blocked.append(i)
			if not by_mover:
				only_the_mover = false
	# Contiguous means one wound rather than several, which is what makes a local repair a
	# meaningful proposal instead of a rewrite in disguise.
	var contiguous := true
	for i in range(blocked.size() - 1):
		if int(blocked[i + 1]) != int(blocked[i]) + 1:
			contiguous = false
	return {"segments": blocked, "only_the_mover": only_the_mover,
		"contiguous": contiguous}


func classify(old: PackedVector2Array, skip: Array, moved: Rect2) -> String:
	var harm := damage(old, skip, moved)
	if (harm["segments"] as Array).is_empty():
		return "still legal"
	if bool(harm["only_the_mover"]) and bool(harm["contiguous"]):
		return "locally repairable"
	return "corridor-invalid"


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)

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

		var held_state := {}
		var classes := {"still legal": [], "locally repairable": [],
			"corridor-invalid": []}
		var loudest := {}
		var loudest_at := 0.0

		for id in main.widgets:
			var widget: GraphNode = main.widgets[id]
			if not widget.visible:
				continue
			var home: Vector2 = widget.position_offset
			for step: Vector2 in [Vector2(NUDGE, 0.0), Vector2(-NUDGE, 0.0),
					Vector2(0.0, NUDGE), Vector2(0.0, -NUDGE)]:
				# Goal 3D made routes session state, so a probe has to say which session
				# it is in — and it has to say so **per edit**, not per node.
				#
				# Forgetting once per node was not enough: the second, third and fourth
				# nudges each inherited whatever the previous nudge left retained, so what
				# was measured was not one edit but a short history of them. That read the
				# dense fixture at fifty-three reroutes against forty-four, from a change
				# that can only ever remove them, and it took three wrong probes to see it.
				#
				# Forgetting here means `before` is the arrangement routed from nothing and
				# `after` is that arrangement plus exactly one edit, which is the claim.
				graph.forget_routes()
				await settle(2)
				var before := routes_now()
				var ends := ends_now()
				widget.position_offset = home + step
				await settle(2)
				var after := routes_now()
				var moved := Rect2(home + step, widget.size).grow(PatchGraph.CLEARANCE)

				for key: String in before:
					if not after.has(key) or not ends.has(key):
						continue
					var was: PackedVector2Array = before[key]
					var now: PackedVector2Array = after[key]
					# Its own endpoints must not have moved; that is not the question.
					var fields := str(key).split(">")
					if str(fields[0]).get_slice(":", 0) == str(widget.name) \
							or str(fields[1]).get_slice(":", 0) == str(widget.name):
						continue
					var deviation := 0.0
					for point: Vector2 in was:
						deviation = maxf(deviation, gap(point, now))
					if was.size() == now.size() and deviation <= 1.0:
						continue

					var pair: Array = ends[key]
					var skip: Array = graph._own_rects(pair[0], pair[1])
					var kind := classify(was, skip, moved)
					if kind == "still legal":
						var held := str(graph.retained_state(pair[0], pair[1], was))
						held_state[held] = int(held_state.get(held, 0)) + 1
					var kept := preserved(was, now)
					var row := {
						"cable": key, "moved": str(widget.name),
						"deviation": snappedf(deviation / NUDGE, 0.1),
						"kept": snappedf(kept * 100.0, 1.0),
						"vertices": "%d -> %d" % [was.size(), now.size()],
						"length": snappedf(arc(now) - arc(was), 1.0),
					}
					(classes[kind] as Array).append(row)
					if deviation / NUDGE > loudest_at:
						loudest_at = deviation / NUDGE
						loudest = {"row": row, "kind": kind,
							"damage": damage(was, skip, moved),
							"old": _spell(was), "new": _spell(now),
							"obstacle": "%s at %s, nudged %s"
								% [str(widget.name), str(home), str(step)]}
				widget.position_offset = home
				await settle(2)

		print("  retention           fired %d time(s), refused %d as no longer legal"
			% [graph.routes_retained, graph.routes_refused])
		print("  retention held      %s for the 'still legal' reroutes" % str(held_state))
		var total := 0
		for kind: String in classes:
			total += (classes[kind] as Array).size()
		print("  %d reroute(s) with still endpoints" % total)
		for kind: String in ["still legal", "locally repairable", "corridor-invalid"]:
			var rows: Array = classes[kind]
			if rows.is_empty():
				print("    %-20s none" % kind)
				continue
			var deviations: Array = []
			var kepts: Array = []
			for row: Dictionary in rows:
				deviations.append(float(row["deviation"]))
				kepts.append(float(row["kept"]))
			deviations.sort()
			kepts.sort()
			print("    %-20s %3d   worst %.1fx, median %.1fx   kept %.0f%% of the old path"
				% [kind, rows.size(), float(deviations[deviations.size() - 1]),
					float(deviations[deviations.size() / 2]),
					float(kepts[kepts.size() / 2])])

		if not loudest.is_empty():
			var row: Dictionary = loudest["row"]
			print("")
			print("  the loudest: %s moved %.1fx the nudge — %s"
				% [str(row["cable"]), float(row["deviation"]), str(loudest["kind"])])
			print("    obstacle   %s" % str(loudest["obstacle"]))
			print("    old route  %s" % str(loudest["old"]))
			print("    new route  %s" % str(loudest["new"]))
			print("    damage     old segments blocked afterwards: %s"
				% str((loudest["damage"] as Dictionary)["segments"]))
			print("               all of them by the node that moved: %s, contiguous: %s"
				% [str((loudest["damage"] as Dictionary)["only_the_mover"]),
					str((loudest["damage"] as Dictionary)["contiguous"])])
			print("    kept       %.0f%% of the old path, vertices %s, cable %+.0f"
				% [float(row["kept"]), str(row["vertices"]), float(row["length"])])

		record[short] = {"classes": classes, "loudest": loudest}

	var folder := out_dir()
	if folder != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var out := FileAccess.open(folder.path_join("route-repair.json"), FileAccess.WRITE)
		out.store_string(JSON.stringify(record, "  "))
		out.close()
		print("")
		print("-> %s" % folder.path_join("route-repair.json"))
	await HarnessExit.finish(self, main)


## A polyline as a short readable list of corners.
func _spell(points: PackedVector2Array) -> String:
	var parts: Array = []
	for point: Vector2 in points:
		parts.append("(%d,%d)" % [roundi(point.x), roundi(point.y)])
	if parts.size() > 9:
		var head: Array = parts.slice(0, 5)
		head.append("...")
		for tail in parts.slice(parts.size() - 3):
			head.append(tail)
		parts = head
	return " ".join(parts)
