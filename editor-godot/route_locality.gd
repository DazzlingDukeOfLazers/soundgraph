extends SceneTree

## Routing goal 3A: which obstacles are allowed to have an opinion about a cable?
##
##   godot --headless --path editor-godot --script route_locality.gd
##
## Goal 2 found the router globally coupled — a forty-unit nudge moves a cable up to 21.3x
## the nudge and reroutes around fifty cables whose own endpoints did not move, some of them
## nearly three thousand units from the edit — and named the mechanism:
##
## > Every obstacle contributes candidate channel coordinates to every eligible cable;
## > candidates are globally reranked after any obstacle moves; no cost rewards retaining
## > the previous corridor.
##
## The contract goal 3 is working toward:
##
## > **An obstacle may influence a cable's routing candidates only if that obstacle is
## > geometrically relevant to reaching that cable's endpoints.**
##
## This substep changes no routing. It establishes how much of the current candidate set
## comes from obstacles that could not possibly be in the way, so that the fix has a number
## to beat and is not merely plausible.
##
## Every obstacle is classified against the connection it might affect, using geometry
## derived from that connection rather than a radius anybody chose:
##
##   blocking       it is in the way of one of the shapes the router tries first
##   near-corridor  it touches the envelope those shapes live in, without blocking
##   remote         it does not touch the envelope at all
##
## The envelope is the box spanning the two ports, grown by the router's own `CLEARANCE`.
## No new constant is invented, which is the same discipline the legalizer's rings and the
## structural cable cost were held to.

const PatchGraph := preload("res://patch_graph.gd")
const HarnessExit := preload("res://harness_exit.gd")

const NUDGE := 40.0

const FIXTURES := [
	"res://../examples/patches/plucked-string.json",
	"res://../examples/patches/first-synth.json",
	"res://qa/babble-tidied.json",
	"res://qa/dense-graph-tidied.json",
]

var main: Node
var graph: GraphEdit


func settle(n: int) -> void:
	for i in n:
		await process_frame


func out_dir() -> String:
	return OS.get_environment("ROUTE_LOCALITY_OUT")


## The box a cable's own geometry says its route has to live in, before any widening.
func envelope(a: Vector2, b: Vector2) -> Rect2:
	return Rect2(a, Vector2.ZERO).expand(b).grow(PatchGraph.CLEARANCE)


## Whether this obstacle is in the way of the shapes `_route` tries before it searches.
##
## The straight line and the two right-angled paths between the ports. If none of them meets
## the obstacle, the obstacle is not blocking — it may still be near enough to matter to a
## detour, which is the next class down.
func blocks(box: Rect2, a: Vector2, b: Vector2) -> bool:
	var elbows := [
		[a, Vector2(b.x, a.y)], [Vector2(b.x, a.y), b],
		[a, Vector2(a.x, b.y)], [Vector2(a.x, b.y), b],
		[a, b],
	]
	for pair: Array in elbows:
		if graph._segment_hits_rect(pair[0], pair[1], box):
			return true
	return false


func classify(box: Rect2, a: Vector2, b: Vector2) -> String:
	if blocks(box, a, b):
		return "blocking"
	if envelope(a, b).intersects(box):
		return "near-corridor"
	return "remote"


## Which obstacle each candidate channel coordinate came from, and what class it is.
##
## Reproduces `_orthogonal_candidates`' own arithmetic rather than calling it, because the
## question is *provenance* and the function returns finished polylines that have forgotten
## where their corners came from. It asks the router for the obstacle set, though, so it
## follows the locality rule instead of restating it — a harness that kept its own copy of
## "which obstacles count" would be measuring its own opinion.
func channels(a: Vector2, b: Vector2) -> Dictionary:
	var start := a + Vector2(PatchGraph.STUB, 0.0)
	var finish := b - Vector2(PatchGraph.STUB, 0.0)
	var low: float = minf(start.x, finish.x)
	var high: float = maxf(start.x, finish.x)

	var offered := {"blocking": 0, "near-corridor": 0, "remote": 0}
	var used := {"blocking": 0, "near-corridor": 0, "remote": 0}

	for box: Rect2 in graph._relevant_obstacles(a, b):
		var kind := classify(box, a, b)
		# Family one: a vertical channel at either side of the obstacle. Filtered to the
		# span between the two stubs, and by nothing else — an obstacle a thousand units
		# above the cable still offers one if its x happens to fall in the span.
		for x: float in [box.position.x - PatchGraph.CLEARANCE * 0.5,
				box.end.x + PatchGraph.CLEARANCE * 0.5]:
			offered[kind] = int(offered[kind]) + 1
			if x >= low - 1.0 and x <= high + 1.0:
				used[kind] = int(used[kind]) + 1
		# Family two: a horizontal channel above or below the obstacle, which before
		# goal 3 was filtered by nothing at all.
		for _y in 2:
			offered[kind] = int(offered[kind]) + 1
			used[kind] = int(used[kind]) + 1
	return {"offered": offered, "used": used}


## Whether the router would consult this obstacle when routing between these two ports.
##
## Asks the router what it actually consulted rather than reimplementing the rule, and asks
## for the *effective* set rather than the opening one — the validation pass inside `_route`
## can add to it, and testing against `_relevant_obstacles` alone reported two violations on
## the dense fixture that were the harness looking at the wrong list.
##
## The point of the invariant is that the router's own answer binds it: anything it declines
## to look at must not be able to change what it produces.
func _consulted(box: Rect2, a: Vector2, b: Vector2) -> bool:
	for rect: Rect2 in graph.consulted_for(a, b):
		if rect.position.distance_to(box.position) < 0.5 \
				and rect.size.distance_to(box.size) < 0.5:
			return true
	return false


## The closest this polyline comes to a rectangle.
func _reach(points: PackedVector2Array, box: Rect2) -> float:
	var nearest := INF
	for point: Vector2 in points:
		nearest = minf(nearest, point.distance_to(Vector2(
			clampf(point.x, box.position.x, box.end.x),
			clampf(point.y, box.position.y, box.end.y))))
	return 0.0 if nearest == INF else nearest


func routes_now() -> Dictionary:
	var out := {}
	for route: Dictionary in graph._routes():
		var f: Array = route["fields"]
		out["%s:%d>%s:%d" % [str(f[0]), int(f[1]), str(f[2]), int(f[3])]] = route["points"]
	return out


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

		# ---- where do the candidate channels come from? ------------------------------
		var used := {"blocking": 0, "near-corridor": 0, "remote": 0}
		var per_cable: Array = []
		for connection: Dictionary in graph.connections:
			var ends: Array = graph._endpoints(connection)
			if ends.is_empty():
				continue
			var counted := channels(ends[0], ends[1])
			for kind: String in used:
				used[kind] = int(used[kind]) + int((counted["used"] as Dictionary)[kind])
			per_cable.append(counted["used"])
		var total: int = int(used["blocking"]) + int(used["near-corridor"]) \
			+ int(used["remote"])
		print("  candidate channels  %d in all: %d blocking, %d near-corridor, %d remote"
			% [total, int(used["blocking"]), int(used["near-corridor"]),
				int(used["remote"])])
		if total > 0:
			print("  %.0f%% of every cable's candidate channels are offered by obstacles"
				% (100.0 * float(used["remote"]) / float(total))
				+ " that cannot be in its way")

		# ---- and can a remote obstacle actually move a cable? ------------------------
		#
		# Every node, four directions, exactly as goal 2 did — and then each cable that
		# changed is classified against the node that moved. That ordering is the whole
		# instrument: asking "did this cable change, and was the mover even able to reach
		# it" is a different question from "did the furthest obstacle I could find change
		# anything".
		#
		# The first version of this probe asked the second question. It nudged one obstacle
		# per cable, the furthest remote one, which is the candidate least likely to matter
		# because remote channels sort last and the router takes the first clear one — and
		# it reported zero reroutes across a hundred and forty-eight probes, which read like
		# the coupling had gone away. Goal 2 had already measured it not going away.
		var probed := 0
		var unconsulted := 0
		var by_class := {"blocking": 0, "near-corridor": 0, "remote": 0}
		var worst := 0.0
		var examples: Array = []
		for id in main.widgets:
			var widget: GraphNode = main.widgets[id]
			if not widget.visible:
				continue
			var home: Vector2 = widget.position_offset
			var before := routes_now()
			for step: Vector2 in [Vector2(NUDGE, 0.0), Vector2(-NUDGE, 0.0),
					Vector2(0.0, NUDGE), Vector2(0.0, -NUDGE)]:
				widget.position_offset = home + step
				await settle(2)
				var after := routes_now()
				var moved_box := Rect2(home, widget.size).grow(PatchGraph.CLEARANCE)
				# Whether the router consulted this node is asked in *both* states, while
				# the node is still moved and again once it is home.
				#
				# An obstacle can be irrelevant to a cable where it started and relevant
				# where it landed — it moved into the corridor, which is the ordinary
				# meaning of an obstacle getting in the way. Asking only at home called
				# that a contract violation, and it is the opposite: the router noticing
				# something that arrived.
				var consulted_moved := {}
				for connection: Dictionary in graph.connections:
					var e: Array = graph._endpoints(connection)
					if e.is_empty():
						continue
					var f: Array = graph._connection_fields(connection)
					consulted_moved["%s:%d>%s:%d" % [str(f[0]), int(f[1]), str(f[2]),
						int(f[3])]] = _consulted(
							Rect2(home + step, widget.size).grow(PatchGraph.CLEARANCE),
							e[0], e[1])
				widget.position_offset = home
				await settle(2)
				probed += 1
				for connection: Dictionary in graph.connections:
					var fields: Array = graph._connection_fields(connection)
					if str(fields[0]) == str(widget.name) \
							or str(fields[2]) == str(widget.name):
						continue        # its own endpoint moved; not the question
					var key := "%s:%d>%s:%d" % [str(fields[0]), int(fields[1]),
						str(fields[2]), int(fields[3])]
					if not before.has(key) or not after.has(key):
						continue
					var was: PackedVector2Array = before[key]
					var now: PackedVector2Array = after[key]
					var apart := 0.0
					for i in mini(was.size(), now.size()):
						apart = maxf(apart, was[i].distance_to(now[i]))
					if was.size() == now.size() and apart <= 1.0:
						continue
					var ends: Array = graph._endpoints(connection)
					var kind := classify(moved_box, ends[0], ends[1])
					by_class[kind] = int(by_class[kind]) + 1
					# The contract, asked of the router rather than of this file's own
					# idea of relevance. A node the router never consulted must not be
					# able to move a cable; a node it did consult may, whatever class the
					# plain envelope puts it in, because the widening is allowed to reach
					# past that envelope when something is genuinely in the way.
					if not _consulted(moved_box, ends[0], ends[1]) \
							and not bool(consulted_moved.get(key, false)):
						unconsulted += 1
						var gap := _reach(was, moved_box)
						worst = maxf(worst, gap)
						if examples.size() < 6:
							examples.append({"cable": key, "moved": str(widget.name),
								"units away": snappedf(gap, 1.0)})
		var stirred: int = int(by_class["blocking"]) + int(by_class["near-corridor"]) \
			+ int(by_class["remote"])
		print("  reroutes            %d probes moved %d cable(s) with still endpoints:"
			% [probed, stirred]
			+ " %d by a blocking node, %d near-corridor, %d remote"
				% [int(by_class["blocking"]), int(by_class["near-corridor"]),
					int(by_class["remote"])])
		print("  the contract        %d cable(s) moved by an obstacle the router never"
			% unconsulted + " consulted")
		if unconsulted > 0:
			print("                      the furthest was %.0f units from the cable it"
				% worst + " rerouted")
			for row: Dictionary in examples.slice(0, 3):
				print("        %s rerouted by %s, %s units away"
					% [str(row["cable"]), str(row["moved"]), str(row["units away"])])

		record[short] = {"channels": used, "per_cable": per_cable,
			"probes": probed, "reroutes_by_class": by_class,
			"unconsulted_reroutes": unconsulted,
			"furthest_unconsulted": snappedf(worst, 1.0), "examples": examples}

	var folder := out_dir()
	if folder != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var out := FileAccess.open(folder.path_join("route-locality.json"),
			FileAccess.WRITE)
		out.store_string(JSON.stringify(record, "  "))
		out.close()
		print("")
		print("-> %s" % folder.path_join("route-locality.json"))
	await HarnessExit.finish(self, main)
