extends SceneTree

## Cosmopolitan Routing, goal 1: make the router explain itself numerically.
##
## No route changes, no alternate paths, no scoring function. The question is narrower than
## "how do we reduce crossings":
##
## > **With layout frozen, what exactly is the current router spending distance, bends,
## > backtracking and crossings on?**
##
##   godot --headless --path editor-godot --script route_baseline.gd
##
## with ROUTE_BASELINE_OUT naming a directory.
##
## ## The boundary, written down first
##
## > **Routing is judged with node positions, port positions, cable endpoints, node geometry
## > and the frozen cable visual grammar all held fixed.**
##
## That is what stops the router "winning" by quietly borrowing from layout again. The
## specimens are the tidied fixtures precisely because every placement operation this
## programme is willing to make has already been asked of them and has answered.
##
## ## And it consumes what the renderer consumes
##
## Every figure here comes from `graph._routes()` — the same points the cord layer draws.
## No straight-line proxy, no second router, no inferred obstacle rectangles. Seven
## instruments in this programme have now been wrong by standing for the thing they measured
## instead of being it, and a routing baseline built on a guess about routing would be the
## eighth.

const PatchGraph := preload("res://patch_graph.gd")

const PATCHES := [
	"res://../examples/patches/first-synth.json",
	"res://../examples/patches/plucked-string.json",
	"res://qa/dense-graph-tidied.json",
	"res://qa/babble-tidied.json",
]

## Cables whose named crossing pairs are printed in full. On a hostile specimen the geometry
## of the failure is the finding, and "seven crossings" is not.
const NAME_CROSSINGS_IN := ["babble-tidied", "dense-graph-tidied"]

## A turn sharper than this counts as a bend. A routed polyline has many vertices along a
## curve and almost none of them are corners.
const BEND_DEGREES := 20.0

## How far a node is nudged for the stability probe, in graph units: one grid step, which is
## the smallest thing a user can do.
const NUDGE := 40.0

## How many points a route is resampled to when two of them are compared.
const SAMPLES := 24

var main: Node
var graph: GraphEdit


func out_dir() -> String:
	var asked := OS.get_environment("ROUTE_BASELINE_OUT")
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


func length_of(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## A route resampled to a fixed number of points by arc length, so two routes with different
## vertex counts can be compared point for point.
func resample(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var total := length_of(points)
	if points.size() < 2 or total <= 0.0:
		return points
	for step in SAMPLES:
		var wanted := total * float(step) / float(SAMPLES - 1)
		var walked := 0.0
		var landed: Vector2 = points[points.size() - 1]
		for i in range(points.size() - 1):
			var span := points[i].distance_to(points[i + 1])
			if walked + span >= wanted and span > 0.0001:
				landed = points[i].lerp(points[i + 1], (wanted - walked) / span)
				break
			walked += span
		out.append(landed)
	return out


## How far apart two routes are, as the worst and the mean of their resampled points.
func apart(a: PackedVector2Array, b: PackedVector2Array) -> Array:
	var one := resample(a)
	var two := resample(b)
	if one.size() != two.size():
		return [INF, INF]
	var worst := 0.0
	var total := 0.0
	for i in one.size():
		var gap := one[i].distance_to(two[i])
		worst = maxf(worst, gap)
		total += gap
	return [worst, total / maxf(float(one.size()), 1.0)]


## Everything worth knowing about one route on its own.
func describe(route: Dictionary, boxes: Dictionary) -> Dictionary:
	var points: PackedVector2Array = route["points"]
	var routed := length_of(points)
	var direct: float = points[0].distance_to(points[points.size() - 1])

	# Bends, and reversals. A route that wanders costs the eye more than a route of the same
	# length that does not, and the endpoint-based metrics of the layout pass could not see
	# either — a cable can begin left of where it ends and still double back twice on the
	# way.
	var bends := 0
	var reversals_x := 0
	var reversals_y := 0
	var last := Vector2.ZERO
	var sign_x := 0
	var sign_y := 0
	for i in range(points.size() - 1):
		var step := points[i + 1] - points[i]
		if step.length() < 0.001:
			continue
		var heading := step.normalized()
		if last != Vector2.ZERO:
			var turn := rad_to_deg(acos(clampf(last.dot(heading), -1.0, 1.0)))
			if turn > BEND_DEGREES:
				bends += 1
		last = heading
		var now_x := signi(int(signf(step.x)))
		var now_y := signi(int(signf(step.y)))
		if now_x != 0:
			if sign_x != 0 and now_x != sign_x:
				reversals_x += 1
			sign_x = now_x
		if now_y != 0:
			if sign_y != 0 and now_y != sign_y:
				reversals_y += 1
			sign_y = now_y

	# How close the route comes to a body it does not belong to. Says how aggressively the
	# router uses the free space it has: a route that hugs every obstacle is one nudge from
	# a trespass, and one that keeps three hundred units clear is spending distance on air.
	var clearance := INF
	var trespass := 0
	# Once per cable-and-node pair, not once per segment of the route that is inside it.
	# The first run of this reported nine trespasses in first-synth where the legalizer
	# counts one: the same cable through the same node, counted once for each segment it
	# spent in there.
	for id: String in boxes:
		if id == str((route["fields"] as Array)[0]) \
				or id == str((route["fields"] as Array)[2]):
			continue
		var body: Rect2 = boxes[id]
		var inside := false
		for i in range(points.size() - 1):
			var span := points[i].distance_to(points[i + 1])
			var steps := maxi(1, int(span / 10.0))
			for s in steps:
				var at: Vector2 = points[i].lerp(points[i + 1],
					(float(s) + 0.5) / float(steps))
				var near := Vector2(clampf(at.x, body.position.x, body.end.x),
					clampf(at.y, body.position.y, body.end.y))
				var gap := at.distance_to(near)
				clearance = minf(clearance, gap)
				if gap <= 0.0:
					inside = true
		if inside:
			trespass += 1

	return {"routed": snappedf(routed, 0.1), "direct": snappedf(direct, 0.1),
		"stretch": snappedf(routed / maxf(direct, 0.001), 0.001),
		"excess": snappedf(routed - direct, 0.1),
		"bends": bends, "reversals_x": reversals_x, "reversals_y": reversals_y,
		"clearance": snappedf(clearance if clearance < INF else -1.0, 0.1),
		"trespass": trespass, "vertices": points.size()}


func key_of(route: Dictionary) -> String:
	var fields: Array = route["fields"]
	return "%s:%d>%s:%d" % [str(fields[0]), int(fields[1]), str(fields[2]),
		int(fields[3])]


func boxes_now() -> Dictionary:
	var out := {}
	for id in main.widgets:
		var widget: GraphNode = main.widgets[id]
		if widget.visible:
			out[str(widget.name)] = Rect2(widget.position_offset, widget.size)
	return out


func routes_now() -> Dictionary:
	var out := {}
	for route: Dictionary in graph._routes():
		out[key_of(route)] = (route["points"] as PackedVector2Array).duplicate()
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
	for path: String in PATCHES:
		await open_patch(path)
		var short := path.get_file().get_basename()
		var boxes := boxes_now()
		var routes: Array = graph._routes()

		# ---- one cable at a time -----------------------------------------------------
		var each := {}
		for route: Dictionary in routes:
			if (route["points"] as PackedVector2Array).size() < 2:
				continue
			each[key_of(route)] = describe(route, boxes)

		# ---- and where they meet -----------------------------------------------------
		# Crossing concentration matters as much as the count: seven unrelated pairs and
		# one cable crossing seven others are very different router problems.
		var meetings: Array = []
		var per_cable := {}
		for key: String in each:
			per_cable[key] = 0
		for i in routes.size():
			for j in range(i + 1, routes.size()):
				var a: Dictionary = routes[i]
				var b: Dictionary = routes[j]
				var fa: Array = a["fields"]
				var fb: Array = b["fields"]
				# Cables sharing a port meet by design, exactly as the cord layer holds.
				if "%s:%d" % [str(fa[0]), int(fa[1])] == "%s:%d" % [str(fb[0]), int(fb[1])]:
					continue
				if "%s:%d" % [str(fa[2]), int(fa[3])] == "%s:%d" % [str(fb[2]), int(fb[3])]:
					continue
				# One entry per meeting, not one per segment. `CableArt.crossings` stops
				# after the first hit on each segment of the upper route, so a crossing
				# that lands near a vertex is reported twice from the two segments either
				# side of it — which is why the first run of this listed a pair twice at
				# identical coordinates and counted twelve where the cord layer counts
				# seven.
				var seen_here := {}
				for at: Vector2 in CableArt.crossings(a["points"], b["points"]):
					var spot := "%d,%d" % [int(at.x / 24.0), int(at.y / 24.0)]
					if seen_here.has(spot):
						continue
					seen_here[spot] = true
					var pa: PackedVector2Array = a["points"]
					var pb: PackedVector2Array = b["points"]
					meetings.append({"a": key_of(a), "b": key_of(b),
						"at": [snappedf(at.x, 0.1), snappedf(at.y, 0.1)],
						# How far from the nearer end of each cable, which separates
						# congestion at a socket from a genuine mid-route conflict.
						"from_end_a": snappedf(minf(at.distance_to(pa[0]),
							at.distance_to(pa[pa.size() - 1])), 0.1),
						"from_end_b": snappedf(minf(at.distance_to(pb[0]),
							at.distance_to(pb[pb.size() - 1])), 0.1)})
					per_cable[key_of(a)] = int(per_cable[key_of(a)]) + 1
					per_cable[key_of(b)] = int(per_cable[key_of(b)]) + 1

		# ---- is the same document the same drawing? ----------------------------------
		var first_pass := routes_now()
		await settle(4)
		var second_pass := routes_now()
		var drifted := 0
		for key: String in first_pass:
			if not second_pass.has(key):
				drifted += 1
				continue
			if float(apart(first_pass[key], second_pass[key])[0]) > 0.01:
				drifted += 1

		# ---- and does a small nudge produce a small change? --------------------------
		# A router can look fine standing still and feel terrible in the hand. One grid
		# step is the smallest thing a user can do; the question is whether it produces a
		# forty-unit adjustment or sends the cable down a different corridor.
		var jumps: Array = []
		var strangers := 0
		var probed := 0
		for id in main.widgets:
			var widget: GraphNode = main.widgets[id]
			var was: Vector2 = widget.position_offset
			for step: Vector2 in [Vector2(NUDGE, 0.0), Vector2(-NUDGE, 0.0),
					Vector2(0.0, NUDGE), Vector2(0.0, -NUDGE)]:
				widget.position_offset = was + step
				await process_frame
				var after := routes_now()
				widget.position_offset = was
				probed += 1
				for key: String in first_pass:
					if not after.has(key):
						continue
					var touches: bool = key.begins_with(str(widget.name) + ":") \
						or key.contains(">" + str(widget.name) + ":")
					var moved := apart(first_pass[key], after[key])
					if float(moved[0]) < 0.01:
						continue
					if touches:
						jumps.append(float(moved[0]) / NUDGE)
					else:
						# A cable neither of whose ends moved has been rerouted by the
						# node passing through its corridor, which is the router
						# responding to an obstacle rather than to an endpoint.
						strangers += 1
			await process_frame

		# ---- the report --------------------------------------------------------------
		var stretches: Array = []
		var excesses: Array = []
		var bends := 0
		var reversals := 0
		var trespasses := 0
		var longest := 0.0
		var total := 0.0
		var tightest := INF
		for key: String in each:
			var one: Dictionary = each[key]
			stretches.append(float(one["stretch"]))
			excesses.append(float(one["excess"]))
			bends += int(one["bends"])
			reversals += int(one["reversals_x"]) + int(one["reversals_y"])
			trespasses += int(one["trespass"])
			longest = maxf(longest, float(one["routed"]))
			total += float(one["routed"])
			if float(one["clearance"]) >= 0.0:
				tightest = minf(tightest, float(one["clearance"]))
		stretches.sort()
		excesses.sort()
		var busiest := 0
		for key: String in per_cable:
			busiest = maxi(busiest, int(per_cable[key]))

		var jumpiest := 0.0
		var jump_total := 0.0
		for one: float in jumps:
			jumpiest = maxf(jumpiest, one)
			jump_total += one

		# The count comes from the cord layer, which is the thing that draws them. The
		# listing below is this file's own enumeration and is for the geometry; where the
		# two disagree the layer is right, and the difference is printed rather than
		# reconciled quietly.
		var counted: int = main._layout_crossings()
		print("")
		print("%s — %d cables, %d crossings%s" % [short, each.size(), counted,
			"" if counted == meetings.size()
				else " (this file enumerates %d)" % meetings.size()])
		print("  cable        total %.0f, longest %.0f" % [total, longest])
		print("  stretch      median %.2f, worst %.2f"
			% [float(stretches[stretches.size() / 2]),
				float(stretches[stretches.size() - 1])])
		print("  excess       median %.0f, worst %.0f"
			% [float(excesses[excesses.size() / 2]),
				float(excesses[excesses.size() - 1])])
		print("  wandering    %d bends, %d axis reversals" % [bends, reversals])
		print("  clearance    tightest %.0f units" % tightest)
		print("  trespass     %d" % trespasses)
		print("  concentration  busiest cable carries %d of %d crossings"
			% [busiest, meetings.size()])
		print("  determinism  %d of %d routes differ between two reads"
			% [drifted, first_pass.size()])
		print("  stability    %d nudges; worst route change %.1fx the nudge, mean %.1fx; "
			% [probed, jumpiest, jump_total / maxf(float(jumps.size()), 1.0)]
			+ "%d reroutes of cables that did not move" % strangers)

		if NAME_CROSSINGS_IN.has(short):
			print("  the crossings, named:")
			for meeting: Dictionary in meetings:
				var a: Dictionary = each[str(meeting["a"])]
				var b: Dictionary = each[str(meeting["b"])]
				print("    %-22s x %-22s  at %.0f/%.0f from their ends; "
					% [str(meeting["a"]), str(meeting["b"]),
						float(meeting["from_end_a"]), float(meeting["from_end_b"])]
					+ "%.0f/%.0f long, stretch %.2f/%.2f"
					% [float(a["routed"]), float(b["routed"]),
						float(a["stretch"]), float(b["stretch"])])

		record[short] = {"cables": each, "crossings": meetings,
			"per_cable": per_cable, "drifted": drifted,
			"stability": {"probes": probed, "worst": snappedf(jumpiest, 0.01),
				"mean": snappedf(jump_total / maxf(float(jumps.size()), 1.0), 0.01),
				"strangers": strangers}}

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	var out := FileAccess.open(folder.path_join("route-baseline.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()
	print("")
	print("-> %s" % folder.path_join("route-baseline.json"))
	quit()
