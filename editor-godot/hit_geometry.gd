extends SceneTree

## Routing goal 2.1: is the cable you can see the cable you can touch?
##
##   godot --headless --path editor-godot --script hit_geometry.gd
##
## Goal 2 found that `_connection_at` picked against `_route` while the editor draws
## catenaries, so on babble not one of twenty-six cables could be clicked at the point it is
## drawn. The contract this file enforces:
##
## > **A cable's interactive locus is the centreline actually displayed by the active cable
## > style.**
##
## Deliberately narrow. It proves the pointer and the picture agree, in both styles, at the
## zoom bands the editor uses. It does not measure the grab radius, redesign the hit area,
## or say anything about where the router chooses to go.
##
## Three assertions, and the third is the one that stops this being satisfied by a wider net:
##
##   1. a point on the displayed centreline selects that cable
##   2. at a crossing, the point selects the **upper** strand — the picture says one is on
##      top and the pointer has to agree
##   3. a point on the hidden routing path, further than the grab radius from anything
##      displayed, selects **nothing**

const PatchGraph := preload("res://patch_graph.gd")
const CableCrossings := preload("res://cable_crossings.gd")

## Where along each cable to try, as a fraction of its arc length.
##
## The stub at each end is skipped, and the skipping is done here rather than assumed.
## `_connection_at` refuses any point within `STUB` of a port — those belong to the socket,
## and stealing the click there would make disconnecting impossible — so a sample that lands
## inside one is testing a rule that already exists. The first run of this file did not skip
## them and reported twenty-five failures on babble, every one of them a short cable whose
## 20% mark is inside its own stub. A probe that samples where the product declines to
## answer is measuring its own arithmetic.
const ALONG := [0.2, 0.35, 0.5, 0.65, 0.8]

## Zooms the editor actually presents. Picking is done in graph space, but the reach is
## `GRAB_DISTANCE / zoom`, so a defect that only bites when zoomed out would hide at 1.0.
const ZOOMS := [1.0, 0.66, 0.4]

const FIXTURES := [
	"res://../examples/patches/first-synth.json",
	"res://../examples/patches/plucked-string.json",
	"res://qa/babble-tidied.json",
	"res://qa/dense-graph-tidied.json",
]

var main: Node
var graph: GraphEdit
var layer: Node
var failures: Array = []


func settle(n: int) -> void:
	for i in n:
		await process_frame


func out_dir() -> String:
	return OS.get_environment("HIT_GEOMETRY_OUT")


func check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		failures.append(what)


## A point a given fraction along a polyline, and the node-covered test that goes with it.
func at_arc(points: PackedVector2Array, fraction: float) -> Vector2:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	var want := total * fraction
	var run := 0.0
	for i in range(points.size() - 1):
		var step := points[i].distance_to(points[i + 1])
		if run + step >= want and step > 0.0:
			return points[i].lerp(points[i + 1], (want - run) / step)
		run += step
	return points[points.size() - 1]


## Whether a node's body covers this point. A cable behind a node cannot be clicked there —
## the GraphNode takes the press — so a sample landing under one proves nothing either way.
func covered(point: Vector2) -> bool:
	for id in main.widgets:
		var widget: GraphNode = main.widgets[id]
		if widget.visible and Rect2(widget.position_offset, widget.size).has_point(point):
			return true
	return false


func key_of(connection: Dictionary) -> String:
	return "%s:%d>%s:%d" % [str(connection["from_node"]), int(connection["from_port"]),
		str(connection["to_node"]), int(connection["to_port"])]


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
		await settle(6)

		print("")
		print("%s" % short)
		record[short] = {}

		for style in 2:
			graph.cable_style = style
			var named := "catenary" if style == 0 else "routed"
			for level: float in ZOOMS:
				graph.zoom = level
				await settle(6)

				var reached := 0
				var right := 0
				var stubbed := 0
				var contested := 0
				var wrong: Array = []
				for connection: Dictionary in graph.connections:
					var key := key_of(connection)
					var shown: PackedVector2Array = graph.display_path(connection)
					if shown.size() < 2:
						continue
					var ends := [shown[0], shown[shown.size() - 1]]
					for fraction: float in ALONG:
						var here := at_arc(shown, fraction)
						if covered(here):
							continue
						if _stubbed(here, ends[0], ends[1]):
							stubbed += 1
							continue
						# Not inside a crossing: which strand wins there is the next
						# assertion's business, and a sample that lands in one would be
						# testing two rules at once.
						if _near_crossing(here):
							continue
						reached += 1
						var hit: Dictionary = graph._connection_at(here)
						var verdict := _judge(here, key, hit)
						if str(verdict["ok"]) == "true":
							right += 1
							if bool(verdict["contested"]):
								contested += 1
						elif wrong.size() < 8:
							wrong.append({"cable": key, "at": fraction,
								"got": "nothing" if hit.is_empty() else key_of(hit),
								"why": verdict["why"]})
				check(reached > 0 and right == reached,
					"%s at %d%%: %d of %d points reach the right cable"
						% [named, roundi(level * 100.0), right, reached]
					+ " (%d in a stub, %d contested)" % [stubbed, contested])
				record[short]["%s@%d" % [named, roundi(level * 100.0)]] = {
					"sampled": reached, "correct": right, "in a stub": stubbed,
					"contested": contested, "wrong": wrong}

		# The upper strand at a crossing, in the style the editor opens in.
		graph.cable_style = 0
		graph.zoom = 1.0
		await settle(6)
		var tops := 0
		var top_right := 0
		var cords: Array = layer._lay()
		for meeting: Dictionary in CableCrossings.classify(cords):
			if not bool(meeting["rendered"]) or bool(meeting["coincident_with_earlier"]):
				continue
			var at: Vector2 = (meeting["at"] as Vector2) + graph.scroll_offset
			if covered(at) or _in_a_stub(at):
				continue
			tops += 1
			var hit: Dictionary = graph._connection_at(at)
			if not hit.is_empty() and key_of(hit) == str(meeting["over"]):
				top_right += 1
		if tops > 0:
			check(top_right == tops,
				"at a crossing the pointer takes the upper strand (%d of %d)"
					% [top_right, tops])
		record[short]["crossings"] = {"sampled": tops, "upper": top_right}

		# And the inverse: the hidden path must not be clickable where nothing is drawn.
		var ghosts := 0
		var caught := 0
		for connection: Dictionary in graph.connections:
			var hidden: PackedVector2Array = graph.routing_path(connection)
			var shown: PackedVector2Array = graph.display_path(connection)
			if hidden.size() < 2 or shown.size() < 2:
				continue
			for fraction: float in ALONG:
				var here := at_arc(hidden, fraction)
				if covered(here) or _within(here, shown, PatchGraph.GRAB_DISTANCE * 2.0):
					continue
				# And nowhere near any other displayed cable either, or the refusal
				# being asserted would be indistinguishable from a correct hit.
				var busy := false
				for other: Dictionary in graph.connections:
					if _within(here, graph.display_path(other),
							PatchGraph.GRAB_DISTANCE * 2.0):
						busy = true
						break
				if busy:
					continue
				ghosts += 1
				if graph._connection_at(here).is_empty():
					caught += 1
		if ghosts > 0:
			check(caught == ghosts,
				"the hidden routing path is not clickable (%d of %d refused)"
					% [caught, ghosts])
		record[short]["ghosts"] = {"sampled": ghosts, "refused": caught}

		graph.cable_style = 0
		graph.zoom = 1.0

	var folder := out_dir()
	if folder != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var out := FileAccess.open(folder.path_join("hit-geometry.json"), FileAccess.WRITE)
		out.store_string(JSON.stringify(record, "  "))
		out.close()
		print("")
		print("-> %s" % folder.path_join("hit-geometry.json"))
	print("")
	if failures.is_empty():
		print("all hit geometry checks passed")
	else:
		print("%d checks failed" % failures.size())
	quit(0 if failures.is_empty() else 1)


func _within(point: Vector2, path: PackedVector2Array, reach: float) -> bool:
	for i in range(path.size() - 1):
		if point.distance_to(Geometry2D.get_closest_point_to_segment(
				point, path[i], path[i + 1])) < reach:
			return true
	return false


## Whether the pick at this point is the right one.
##
## Not "did it return the cable I sampled". That assertion is wrong wherever two cables
## occupy the same place, and they do so constantly and by design: a fan-out leaves one
## output as two coincident cords, two cables between the same pair of nodes run parallel,
## and in ROUTED style cables share orthogonal channels for long stretches. Asking geometry
## which of two coincident cords was "meant" has no answer.
##
## What can be demanded is exactly what the picture promises:
##
##   1. something is picked
##   2. nothing farther away than the sampled cable wins
##   3. among cables the pointer is equally near, the winner is the one drawn last — the
##      upper strand, the same priority that decides which one the knockout is cut into
##
## Point 3 is the crossing rule applied everywhere rather than only at crossings, which is
## what makes it a contract instead of a special case.
func _judge(point: Vector2, expected: String, hit: Dictionary) -> Dictionary:
	if hit.is_empty():
		return {"ok": "false", "why": "nothing was picked", "contested": false}
	var mine := INF
	var theirs := INF
	var best := INF
	var upper := ""
	# Cables whose own port is under the pointer are out of the running, because
	# `_connection_at` refuses them: the last thirty units belong to the socket. The judge
	# has to apply every rule the product applies or it will nominate a winner the product
	# is right to decline — which is exactly what it did on its first run, calling a cable
	# the upper strand at a point inside that cable's own stub.
	var eligible: Array = []
	for connection: Dictionary in graph.connections:
		var shown: PackedVector2Array = graph.display_path(connection)
		if shown.size() < 2 or _stubbed(point, shown[0], shown[shown.size() - 1]):
			continue
		var away := _distance_to(point, shown)
		eligible.append([key_of(connection), away])
		if key_of(connection) == expected:
			mine = away
		if key_of(connection) == key_of(hit):
			theirs = away
		best = minf(best, away)
	# The last cable in draw order that is within a hair of the nearest. Draw order is the
	# crossing priority, so this is the strand the picture puts on top.
	for row: Array in eligible:
		if float(row[1]) < best + PatchGraph.PICK_TIE:
			upper = str(row[0])
	if theirs > mine + PatchGraph.PICK_TIE:
		return {"ok": "false", "contested": false,
			"why": "picked a cable %.1f away when the sampled one is %.1f"
				% [theirs, mine]}
	if key_of(hit) != upper:
		return {"ok": "false", "contested": true,
			"why": "picked %s where the upper strand is %s" % [key_of(hit), upper]}
	return {"ok": "true", "why": "", "contested": key_of(hit) != expected}


func _distance_to(point: Vector2, path: PackedVector2Array) -> float:
	var nearest := INF
	for i in range(path.size() - 1):
		nearest = minf(nearest, point.distance_to(
			Geometry2D.get_closest_point_to_segment(point, path[i], path[i + 1])))
	return nearest


## Inside the stub at either end, where picking declines by rule rather than by defect.
static func _stubbed(point: Vector2, one: Vector2, two: Vector2) -> bool:
	return point.distance_to(one) < PatchGraph.STUB or point.distance_to(two) < PatchGraph.STUB


## Whether this point is inside the port stub of any cable, where picking declines by rule.
func _in_a_stub(point: Vector2) -> bool:
	for connection: Dictionary in graph.connections:
		var shown: PackedVector2Array = graph.display_path(connection)
		if shown.size() < 2:
			continue
		if _stubbed(point, shown[0], shown[shown.size() - 1]):
			return true
	return false


func _near_crossing(point: Vector2) -> bool:
	for site: Dictionary in layer.crossing_sites():
		if point.distance_to((site["at"] as Vector2) + graph.scroll_offset) < 40.0:
			return true
	return false
