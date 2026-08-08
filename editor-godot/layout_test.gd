extends SceneTree
## Checks the layered layout on graphs built to have an obvious right answer.
##
##   godot --headless --script res://layout_test.gd
##
## These measure crossings and alignment rather than comparing against a recorded layout:
## a golden layout would have to be re-blessed on every tuning change, and would say
## nothing about whether the result is actually good.

const Layout := preload("res://layout.gd")

var failures := 0


func check(condition: bool, description: String) -> void:
	if condition:
		print("  ok   %s" % description)
	else:
		print("  FAIL %s" % description)
		failures += 1


## Counts pairs of cables that cross, using the placed centres of their endpoints. This
## is the thing the user actually sees, measured on the final coordinates rather than on
## the algorithm's internal ordering.
func count_crossings(edges: Array, placed: Dictionary, sizes: Dictionary) -> int:
	var segments := []
	for edge in edges:
		if not placed.has(edge[0]) or not placed.has(edge[1]):
			continue
		var from: Vector2 = placed[edge[0]] + Vector2(sizes[edge[0]].x, sizes[edge[0]].y * 0.5)
		var to: Vector2 = placed[edge[1]] + Vector2(0.0, sizes[edge[1]].y * 0.5)
		segments.append([from, to, edge])

	var crossings := 0
	for i in segments.size():
		for j in range(i + 1, segments.size()):
			# Cables sharing an endpoint fan out from one port; that is not a crossing.
			var a: Array = segments[i][2]
			var b: Array = segments[j][2]
			if a[0] == b[0] or a[1] == b[1] or a[0] == b[1] or a[1] == b[0]:
				continue
			if Geometry2D.segment_intersects_segment(
				segments[i][0], segments[i][1], segments[j][0], segments[j][1]) != null:
				crossings += 1
	return crossings


func uniform_sizes(ids: Array) -> Dictionary:
	var sizes := {}
	for id in ids:
		sizes[id] = Vector2(300, 120)
	return sizes


func arrange(ids: Array, edges: Array, extra: Dictionary = {}) -> Dictionary:
	var request := {
		"nodes": ids, "edges": edges, "sizes": uniform_sizes(ids),
		"grid": 40.0, "column_pitch": 400.0, "column_gutter": 80.0, "row_gutter": 24.0,
	}
	for key in extra:
		request[key] = extra[key]
	return Layout.arrange(request)


func _initialize() -> void:
	print("layout checks")

	# ---- the case that motivated this: crossed cables --------------------------------
	# Two parallel chains declared in an interleaved order. Placing by depth alone puts
	# a1 above b1 but b2 above a2, so the two cables cross for no reason at all.
	var ids := ["a1", "b1", "a2", "b2", "sink"]
	var edges := [["a1", "a2"], ["b1", "b2"], ["a2", "sink"], ["b2", "sink"]]
	var placed := arrange(ids, edges)
	check(count_crossings(edges, placed, uniform_sizes(ids)) == 0,
		"two parallel chains are untangled")

	# A deliberately adversarial ordering: every source declared in reverse.
	ids = ["s0", "s1", "s2", "s3", "t0", "t1", "t2", "t3"]
	edges = [["s0", "t3"], ["s1", "t2"], ["s2", "t1"], ["s3", "t0"]]
	placed = arrange(ids, edges)
	check(count_crossings(edges, placed, uniform_sizes(ids)) == 0,
		"a fully reversed bipartite graph is untangled")

	# ---- straightening ----------------------------------------------------------------
	# A single chain must come out as one straight line, not a staircase.
	ids = ["n0", "n1", "n2", "n3", "n4"]
	edges = [["n0", "n1"], ["n1", "n2"], ["n2", "n3"], ["n3", "n4"]]
	placed = arrange(ids, edges)
	var straight := true
	for id in ids:
		if not is_equal_approx(placed[id].y, placed["n0"].y):
			straight = false
	check(straight, "a straight chain is placed as a straight line")

	var increasing := true
	for i in range(1, ids.size()):
		if placed[ids[i]].x <= placed[ids[i - 1]].x:
			increasing = false
	check(increasing, "and it runs left to right")

	# A long edge skipping layers must not drag its endpoints out of line.
	ids = ["src", "mid", "far", "sink"]
	edges = [["src", "mid"], ["mid", "far"], ["far", "sink"], ["src", "sink"]]
	placed = arrange(ids, edges)
	check(placed["src"].x < placed["mid"].x and placed["mid"].x < placed["far"].x
		and placed["far"].x < placed["sink"].x, "a skipping edge keeps the chain ordered")
	check(count_crossings(edges, placed, uniform_sizes(ids)) == 0,
		"and does not cross the chain it skips over")

	# ---- the shapes SoundGraph actually makes ----------------------------------------
	# A modulator with no inputs belongs beside what it drives, not at the far left.
	ids = ["note", "osc", "lfo", "filter", "env", "amp", "out"]
	edges = [["note", "osc"], ["note", "env"], ["osc", "filter"], ["lfo", "filter"],
		["filter", "amp"], ["env", "amp"], ["amp", "out"]]
	placed = arrange(ids, edges)
	check(placed["lfo"].x == placed["osc"].x, "an LFO sits in the column beside its filter")
	check(count_crossings(edges, placed, uniform_sizes(ids)) == 0,
		"the demo patch has no crossed cables")
	var on_grid := true
	for id in ids:
		if fmod(placed[id].x, 40.0) != 0.0 or fmod(placed[id].y, 40.0) != 0.0:
			on_grid = false
	check(on_grid, "everything lands on the grid")

	var overlapping := false
	for a in ids:
		for b in ids:
			if a != b and Rect2(placed[a], Vector2(300, 120)).intersects(
				Rect2(placed[b], Vector2(300, 120))):
				overlapping = true
	check(not overlapping, "and nothing overlaps")

	# A feedback loop must not defeat layering.
	ids = ["src", "mix", "delay", "regen", "out"]
	edges = [["src", "mix"], ["mix", "delay"], ["delay", "regen"], ["regen", "mix"],
		["delay", "out"]]
	placed = arrange(ids, edges)
	check(placed.size() == 5, "a feedback loop still places every node")
	check(placed["src"].x < placed["mix"].x and placed["mix"].x < placed["delay"].x,
		"and the forward path still reads left to right")

	# ---- selection --------------------------------------------------------------------
	# Arranging part of a graph must leave the rest alone and stay near where it was.
	ids = ["a", "b", "c", "d"]
	edges = [["a", "b"], ["b", "c"], ["c", "d"]]
	var anchors := {"a": Vector2(0, 0), "d": Vector2(1600, 0)}
	var sizes := uniform_sizes(ids)
	placed = Layout.arrange({
		"nodes": ["b", "c"], "edges": edges, "sizes": sizes, "anchors": anchors,
		"grid": 40.0, "column_pitch": 400.0, "column_gutter": 80.0, "row_gutter": 24.0,
	})
	check(placed.size() == 2, "only the selected nodes are placed")
	check(not placed.has("a") and not placed.has("d"), "anchors are left untouched")

	print("")
	if failures == 0:
		print("all layout checks passed")
		quit(0)
	else:
		print("%d layout check(s) failed" % failures)
		quit(1)
