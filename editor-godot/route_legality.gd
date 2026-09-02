extends SceneTree

## Routing goal 4A: when the router hands back a blocked route, could it have done better?
##
##   godot --headless --path editor-godot --script route_legality.gd
##
## Goal 3E's control found the thing this pass had been walking past:
##
## > **`_route_among` keeps its least-blocked candidate when nothing is clear, and returns
## > it looking exactly like a success.** On the dense fixture that is 313 of 4200 sampled
## > states while a node sits nudged — 7.5% of cables drawn through modules during an edit.
##
## No resting measurement could see it. `trespass` reads zero on every fixture at rest, and
## every baseline in this pass looked at rest.
##
## The contract that follows, and the seam `route_blocked_count` now provides:
##
## > **A route has a validity result separate from its geometry. A least-blocked fallback
## > must never be reported as legal merely because it is the best candidate found.**
##
## This substep changes no routing. It asks, of every blocked result, whether a clear route
## was demonstrably available — because "the router failed to find one" and "there was none"
## call for completely different repairs, and 3E's accidental evidence already suggests the
## first is the larger population.
##
## Five answers, first match winning, cheapest question first:
##
##   ranking or cap        a clear candidate was in the list the router already built, and
##                         it stopped before reaching it
##   wider channels        clear once every obstacle may offer a channel again, which is
##                         goal 3's locality being too tight in this instance
##   local splice          clear if the damaged run is rerouted between two of the old
##                         route's own corners — the technique 3E was reverted for, used
##                         here only as an oracle
##   family too narrow     no orthogonal candidate is clear, but a path through free space
##                         exists — the router's *shapes* are the limit, not the geometry
##   boxed in              no path exists at all. The only class where a blocked result is
##                         the honest answer.
##
## The last one needs an oracle the router does not share, or it would only ever confirm its
## own opinion, so it is a breadth-first walk over a grid of free space. Slow, and it is only
## asked when the four cheaper questions have all said no.

const PatchGraph := preload("res://patch_graph.gd")
const HarnessExit := preload("res://harness_exit.gd")

const NUDGE := 40.0

## Half the router's clearance, so the walk cannot squeeze through a gap the router would
## refuse. Derived rather than chosen.
const CELL := PatchGraph.CLEARANCE * 0.5

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
	return OS.get_environment("ROUTE_LEGALITY_OUT")


func blocked_by(points: PackedVector2Array, own: Array) -> int:
	return int(graph._blocked_count(points, own))


## Is any candidate in the router's own list clear, if nothing stops the search early?
##
## The router breaks at the first clear one and caps at `MAX_CANDIDATES`. This asks the same
## list the same question with neither limit, so a "yes" means the answer was already in the
## router's hand.
func clear_in_own_list(a: Vector2, b: Vector2, own: Array) -> bool:
	for candidate: PackedVector2Array in graph._orthogonal_candidates(a, b,
			graph._relevant_obstacles(a, b)):
		if blocked_by(graph._simplify(candidate), own) == 0:
			return true
	return false


## And with every obstacle in the graph allowed to offer a channel again.
func clear_with_every_channel(a: Vector2, b: Vector2, own: Array) -> bool:
	var everything: Array[Rect2] = []
	for rect: Rect2 in graph._current_obstacles():
		everything.append(rect)
	for candidate: PackedVector2Array in graph._orthogonal_candidates(a, b, everything):
		if blocked_by(graph._simplify(candidate), own) == 0:
			return true
	return false


## Clear if only the damaged run of the current route is replaced.
##
## 3E's expanding window, kept here as an oracle after the production version was reverted
## for breaking determinism. What it could not be trusted to *do* it can still be trusted to
## answer, because a harness may take as long as it likes and does not have to agree with
## itself twice.
func clear_with_splice(old: PackedVector2Array, a: Vector2, b: Vector2,
		own: Array) -> bool:
	if old.size() < 3:
		return false
	var broken: Array = []
	for i in range(old.size() - 1):
		if blocked_by(PackedVector2Array([old[i], old[i + 1]]), own) > 0:
			broken.append(i)
	if broken.is_empty():
		return false
	for i in range(broken.size() - 1):
		if int(broken[i + 1]) != int(broken[i]) + 1:
			return false
	var last := old.size() - 1
	for widen in range(old.size()):
		var from_at: int = maxi(0, int(broken[0]) - widen)
		var to_at: int = mini(last, int(broken[broken.size() - 1]) + 1 + widen)
		var middle: PackedVector2Array = graph._route_among(old[from_at], old[to_at], own,
			graph._relevant_obstacles(old[from_at], old[to_at]))
		if middle.size() < 2:
			continue
		var spliced := PackedVector2Array()
		for i in from_at:
			spliced.append(old[i])
		for point: Vector2 in middle:
			spliced.append(point)
		for i in range(to_at + 1, old.size()):
			spliced.append(old[i])
		if blocked_by(spliced, own) == 0:
			return true
		if from_at == 0 and to_at == last:
			break
	return false


## Does *any* path through free space exist between these two points?
##
## Breadth-first over a grid, deliberately owing nothing to the router's shapes. A "no" here
## is the only evidence that would justify the router returning a blocked route, and a "yes"
## after the three cheaper questions have failed says the candidate families are the limit.
func any_path_exists(a: Vector2, b: Vector2, own: Array) -> bool:
	var box := Rect2(a, Vector2.ZERO).expand(b)
	for rect: Rect2 in graph._current_obstacles():
		box = box.merge(rect)
	box = box.grow(PatchGraph.CLEARANCE * 2.0)
	var wide := int(box.size.x / CELL) + 1
	var high := int(box.size.y / CELL) + 1
	if wide * high > 240000:
		return true        # too large to answer honestly; do not pretend
	var blocked_cell := {}
	for rect: Rect2 in graph._current_obstacles():
		var mine := false
		for skip: Rect2 in own:
			if skip.position.is_equal_approx(rect.position):
				mine = true
		if mine:
			continue
		var lo_x := maxi(0, int((rect.position.x - box.position.x) / CELL))
		var hi_x := mini(wide - 1, int((rect.end.x - box.position.x) / CELL))
		var lo_y := maxi(0, int((rect.position.y - box.position.y) / CELL))
		var hi_y := mini(high - 1, int((rect.end.y - box.position.y) / CELL))
		for cx in range(lo_x, hi_x + 1):
			for cy in range(lo_y, hi_y + 1):
				blocked_cell[cy * wide + cx] = true

	var start := int((a.y - box.position.y) / CELL) * wide \
		+ int((a.x - box.position.x) / CELL)
	var goal := int((b.y - box.position.y) / CELL) * wide \
		+ int((b.x - box.position.x) / CELL)
	var seen := {start: true}
	var queue: Array = [start]
	var head := 0
	while head < queue.size():
		var at: int = queue[head]
		head += 1
		if at == goal:
			return true
		var cx: int = at % wide
		var cy: int = at / wide
		for step: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1),
				Vector2i(0, -1)]:
			var nx := cx + step.x
			var ny := cy + step.y
			if nx < 0 or ny < 0 or nx >= wide or ny >= high:
				continue
			var next := ny * wide + nx
			if seen.has(next) or blocked_cell.has(next):
				continue
			seen[next] = true
			queue.append(next)
	return false


## The five answers, cheapest question first, first match winning.
func attribute(old: PackedVector2Array, a: Vector2, b: Vector2, own: Array) -> String:
	if clear_in_own_list(a, b, own):
		return "ranking or cap"
	if clear_with_every_channel(a, b, own):
		return "wider channels"
	if clear_with_splice(old, a, b, own):
		return "local splice"
	if any_path_exists(a, b, own):
		return "family too narrow"
	return "boxed in"


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

		var why := {"ranking or cap": 0, "wider channels": 0, "local splice": 0,
			"family too narrow": 0, "boxed in": 0}
		var sampled := 0
		var blocked := 0
		var examples: Array = []

		for id in main.widgets:
			var widget: GraphNode = main.widgets[id]
			if not widget.visible:
				continue
			var home: Vector2 = widget.position_offset
			for step: Vector2 in [Vector2(NUDGE, 0.0), Vector2(-NUDGE, 0.0),
					Vector2(0.0, NUDGE), Vector2(0.0, -NUDGE)]:
				graph.forget_routes()
				await settle(2)
				widget.position_offset = home + step
				await settle(2)
				for route: Dictionary in graph._routes():
					sampled += 1
					if int(route["blocked"]) == 0:
						continue
					blocked += 1
					var f: Array = route["fields"]
					var connection := {"from_node": f[0], "from_port": f[1],
						"to_node": f[2], "to_port": f[3]}
					var ends: Array = graph._endpoints(connection)
					if ends.is_empty():
						continue
					var own: Array = graph._own_rects(ends[0], ends[1])
					var kind := attribute(route["points"], ends[0], ends[1], own)
					why[kind] = int(why[kind]) + 1
					if examples.size() < 40:
						examples.append({"cable": "%s:%d>%s:%d"
							% [str(f[0]), int(f[1]), str(f[2]), int(f[3])],
							"moved": str(widget.name), "why": kind,
							"through": int(route["blocked"])})
				widget.position_offset = home
				await settle(2)

		print("  blocked results     %d of %d routed states (%.1f%%)"
			% [blocked, sampled, 100.0 * float(blocked) / maxf(float(sampled), 1.0)])
		var recoverable := 0
		for kind: String in ["ranking or cap", "wider channels", "local splice",
				"family too narrow", "boxed in"]:
			print("    %-20s %d" % [kind, int(why[kind])])
			if kind != "boxed in":
				recoverable += int(why[kind])
		print("  a clear route was demonstrably available in %d of %d (%.0f%%)"
			% [recoverable, blocked,
				100.0 * float(recoverable) / maxf(float(blocked), 1.0)])
		for row: Dictionary in examples.slice(0, 4):
			print("      %s blocked by %d node(s) when %s moved — %s"
				% [str(row["cable"]), int(row["through"]), str(row["moved"]),
					str(row["why"])])

		record[short] = {"sampled": sampled, "blocked": blocked, "why": why,
			"examples": examples}

	var folder := out_dir()
	if folder != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var out := FileAccess.open(folder.path_join("route-legality.json"),
			FileAccess.WRITE)
		out.store_string(JSON.stringify(record, "  "))
		out.close()
		print("")
		print("-> %s" % folder.path_join("route-legality.json"))
	await HarnessExit.finish(self, main)
