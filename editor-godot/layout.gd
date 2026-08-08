extends RefCounted
## Layered graph layout — the Sugiyama framework.
##
## Placing nodes by depth alone gets the columns right and nothing else: it says nothing
## about which node sits above which, so cables cross for no reason, and it stacks each
## column from the top, so a chain that should read as a straight line zig-zags.
##
## The standard answer is Sugiyama's five phases, and this implements four of them (the
## fifth, edge routing, is patch_graph.gd):
##
##   1. cycle removal      a feedback loop is temporarily reversed so the rest can assume
##                         a DAG — SoundGraph only permits cycles through a Delay anyway
##   2. layer assignment   longest path, then sources pulled right to sit beside whatever
##                         they drive, so an LFO lands next to its filter
##   3. crossing reduction  ordering within each layer: the median heuristic swept both
##                         ways, then adjacent-swap transposition, keeping the best
##                         ordering actually measured rather than assumed
##   4. coordinates        each node pulled toward the median of its neighbours, resolved
##                         against no-overlap constraints by isotonic regression, which
##                         gives the closest legal placement rather than a guess
##
## Long edges get dummy nodes in the layers they span. Without them a cable crossing three
## columns is invisible to the crossing count and to the spacing, so it happily cuts
## straight across whatever is in the way. Dummy chains are also weighted heavily in
## phase 4, which is what keeps a long cable straight instead of bowed.
##
## References: Sugiyama, Tagawa & Toda (1981); Gansner, Koutsofios, North & Vo, "A
## Technique for Drawing Directed Graphs" (1993) for median + transpose; Brandes & Köpf,
## "Fast and Simple Horizontal Coordinate Assignment" (2002) for the idea of aligning to
## medians, though phase 4 here solves the simpler isotonic problem directly.

const SWEEPS := 8


## request:
##   nodes         Array of node ids to place
##   edges         Array of [from_id, to_id]; endpoints outside `nodes` are anchors
##   sizes         id -> Vector2, for every node and anchor
##   anchors       id -> Vector2, fixed positions of nodes that must not move
##   grid, column_pitch, column_gutter, row_gutter
##
## Returns id -> Vector2 for every id in `nodes`.
static func arrange(request: Dictionary) -> Dictionary:
	var ids: Array = request["nodes"]
	if ids.is_empty():
		return {}

	var sizes: Dictionary = request["sizes"]
	var anchors: Dictionary = request.get("anchors", {})
	var grid: float = request.get("grid", 40.0)
	var column_pitch: float = request.get("column_pitch", 400.0)
	var column_gutter: float = request.get("column_gutter", 80.0)
	var row_gutter: float = request.get("row_gutter", 24.0)

	var movable := {}
	for id in ids:
		movable[id] = true

	# Only edges between movable nodes shape the hierarchy; edges to anchors pull on the
	# coordinates later without dictating the columns.
	var edges := []
	var external := []
	for edge in request["edges"]:
		if movable.has(edge[0]) and movable.has(edge[1]):
			edges.append(edge)
		elif movable.has(edge[0]) or movable.has(edge[1]):
			external.append(edge)

	edges = _remove_cycles(ids, edges)
	var depths := _assign_layers(ids, edges)

	var built := _build_layers(ids, edges, depths)
	var layers: Array = built["layers"]
	var chain_edges: Array = built["edges"]
	var dummies: Dictionary = built["dummies"]

	_reduce_crossings(layers, chain_edges)

	return _assign_coordinates({
		"layers": layers, "edges": chain_edges, "dummies": dummies,
		"sizes": sizes, "anchors": anchors, "external": external,
		"grid": grid, "column_pitch": column_pitch,
		"column_gutter": column_gutter, "row_gutter": row_gutter,
	})


# ---------------------------------------------------------------------------------
# Phase 1 — cycle removal
# ---------------------------------------------------------------------------------

## Reverses back edges so the remaining phases can assume a DAG. A SoundGraph cycle is
## always a deliberate feedback loop through a Delay, so reversing one for layout purposes
## simply draws the loop the way a person would: forward along the signal, back underneath.
static func _remove_cycles(ids: Array, edges: Array) -> Array:
	var successors := {}
	for id in ids:
		successors[id] = []
	for edge in edges:
		successors[edge[0]].append(edge[1])

	var state := {}          # 0 unvisited, 1 on stack, 2 done
	for id in ids:
		state[id] = 0
	var back_edges := {}

	for start in ids:
		if state[start] != 0:
			continue
		var stack := [[start, 0]]
		state[start] = 1
		while not stack.is_empty():
			var frame: Array = stack[stack.size() - 1]
			var node = frame[0]
			if frame[1] < successors[node].size():
				var next = successors[node][frame[1]]
				frame[1] += 1
				if state[next] == 1:
					back_edges["%s>%s" % [node, next]] = true
				elif state[next] == 0:
					state[next] = 1
					stack.append([next, 0])
			else:
				state[node] = 2
				stack.pop_back()

	var result := []
	for edge in edges:
		if back_edges.has("%s>%s" % [edge[0], edge[1]]):
			result.append([edge[1], edge[0]])   # reversed for layout only
		else:
			result.append(edge)
	return result


# ---------------------------------------------------------------------------------
# Phase 2 — layer assignment
# ---------------------------------------------------------------------------------

static func _assign_layers(ids: Array, edges: Array) -> Dictionary:
	var incoming := {}
	var outgoing := {}
	for id in ids:
		incoming[id] = []
		outgoing[id] = []
	for edge in edges:
		outgoing[edge[0]].append(edge[1])
		incoming[edge[1]].append(edge[0])

	var depths := {}
	for id in ids:
		depths[id] = 0

	for _pass in range(ids.size() + 1):
		var changed := false
		for id in ids:
			var deepest := 0
			for source in incoming[id]:
				deepest = maxi(deepest, int(depths[source]) + 1)
			if deepest != int(depths[id]):
				depths[id] = deepest
				changed = true
		if not changed:
			break

	# A source with no inputs belongs beside what it drives, not stranded at the origin.
	for id in ids:
		if incoming[id].is_empty() and not outgoing[id].is_empty():
			var earliest := 1 << 30
			for target in outgoing[id]:
				earliest = mini(earliest, int(depths[target]))
			depths[id] = maxi(0, earliest - 1)
	return depths


## Builds the layer lists and replaces every edge spanning more than one layer with a
## chain through dummy nodes.
static func _build_layers(ids: Array, edges: Array, depths: Dictionary) -> Dictionary:
	var deepest := 0
	for id in ids:
		deepest = maxi(deepest, int(depths[id]))

	var layers := []
	for i in deepest + 1:
		layers.append([])
	for id in ids:
		layers[int(depths[id])].append(id)

	var chain_edges := []
	var dummies := {}
	var counter := 0

	for edge in edges:
		var from_depth: int = depths[edge[0]]
		var to_depth: int = depths[edge[1]]
		if to_depth - from_depth <= 1:
			chain_edges.append(edge)
			continue
		var previous = edge[0]
		for depth in range(from_depth + 1, to_depth):
			# '#' is not legal in a patch node id (see schema/patch.schema.json), so a
			# dummy can never collide with a real one.
			var dummy := "#dummy%d" % counter
			counter += 1
			dummies[dummy] = true
			layers[depth].append(dummy)
			chain_edges.append([previous, dummy])
			previous = dummy
		chain_edges.append([previous, edge[1]])

	return {"layers": layers, "edges": chain_edges, "dummies": dummies}


# ---------------------------------------------------------------------------------
# Phase 3 — crossing reduction
# ---------------------------------------------------------------------------------

static func _adjacency(edges: Array) -> Dictionary:
	var down := {}
	var up := {}
	for edge in edges:
		if not down.has(edge[0]):
			down[edge[0]] = []
		down[edge[0]].append(edge[1])
		if not up.has(edge[1]):
			up[edge[1]] = []
		up[edge[1]].append(edge[0])
	return {"down": down, "up": up}


static func _positions(layer: Array) -> Dictionary:
	var index := {}
	for i in layer.size():
		index[layer[i]] = i
	return index


## Crossings between two adjacent layers: with both orders fixed, two edges cross exactly
## when their endpoints are in opposite order, so this counts inversions.
static func _count_between(upper: Array, lower: Array, down: Dictionary) -> int:
	var lower_index := _positions(lower)
	var targets := []
	for node in upper:
		var list: Array = down.get(node, [])
		var sorted := []
		for target in list:
			if lower_index.has(target):
				sorted.append(int(lower_index[target]))
		sorted.sort()
		for value in sorted:
			targets.append(value)

	var crossings := 0
	for i in targets.size():
		for j in range(i + 1, targets.size()):
			if targets[i] > targets[j]:
				crossings += 1
	return crossings


static func _count_crossings(layers: Array, adjacency: Dictionary) -> int:
	var total := 0
	for i in range(layers.size() - 1):
		total += _count_between(layers[i], layers[i + 1], adjacency["down"])
	return total


## The median of a node's neighbours in the adjacent layer. Returns -1 when it has none,
## which means "stay where you are" — moving an unconstrained node only adds churn.
static func _median(node, neighbours: Dictionary, index: Dictionary) -> float:
	var positions := []
	for neighbour in neighbours.get(node, []):
		if index.has(neighbour):
			positions.append(int(index[neighbour]))
	if positions.is_empty():
		return -1.0
	positions.sort()
	var middle := positions.size() / 2
	if positions.size() % 2 == 1:
		return float(positions[middle])
	return (float(positions[middle - 1]) + float(positions[middle])) * 0.5


static func _order_by_median(layer: Array, neighbours: Dictionary, fixed: Array) -> Array:
	var index := _positions(fixed)
	var keyed := []
	for i in layer.size():
		var node = layer[i]
		var median := _median(node, neighbours, index)
		# Nodes with no neighbour in the fixed layer keep their current position, so the
		# sort cannot shuffle them arbitrarily.
		keyed.append({"node": node, "key": median if median >= 0.0 else float(i), "was": i})
	keyed.sort_custom(func(a, b):
		if is_equal_approx(a["key"], b["key"]):
			return a["was"] < b["was"]
		return a["key"] < b["key"])

	var result := []
	for entry in keyed:
		result.append(entry["node"])
	return result


## Swaps adjacent pairs while that reduces crossings. The median heuristic gets the broad
## shape right and leaves local inversions behind; this cleans them up.
static func _transpose(layers: Array, adjacency: Dictionary) -> void:
	var improved := true
	var guard := 0
	while improved and guard < 32:
		improved = false
		guard += 1
		for i in range(layers.size() - 1):
			var upper: Array = layers[i]
			var lower: Array = layers[i + 1]
			for j in range(lower.size() - 1):
				var before := _count_between(upper, lower, adjacency["down"])
				if i + 2 < layers.size():
					before += _count_between(lower, layers[i + 2], adjacency["down"])
				var swapped := lower.duplicate()
				var carry = swapped[j]
				swapped[j] = swapped[j + 1]
				swapped[j + 1] = carry
				var after := _count_between(upper, swapped, adjacency["down"])
				if i + 2 < layers.size():
					after += _count_between(swapped, layers[i + 2], adjacency["down"])
				if after < before:
					layers[i + 1] = swapped
					lower = swapped
					improved = true


static func _reduce_crossings(layers: Array, edges: Array) -> void:
	var adjacency := _adjacency(edges)
	var best := []
	for layer in layers:
		best.append(layer.duplicate())
	var best_crossings := _count_crossings(layers, adjacency)

	for sweep in SWEEPS:
		if sweep % 2 == 0:
			for i in range(1, layers.size()):
				layers[i] = _order_by_median(layers[i], adjacency["up"], layers[i - 1])
		else:
			for i in range(layers.size() - 2, -1, -1):
				layers[i] = _order_by_median(layers[i], adjacency["down"], layers[i + 1])
		_transpose(layers, adjacency)

		# Keep what was measured, not what was hoped for: a sweep can make things worse.
		var crossings := _count_crossings(layers, adjacency)
		if crossings < best_crossings:
			best_crossings = crossings
			best = []
			for layer in layers:
				best.append(layer.duplicate())
			if crossings == 0:
				break

	for i in layers.size():
		layers[i] = best[i]


# ---------------------------------------------------------------------------------
# Phase 4 — coordinate assignment
# ---------------------------------------------------------------------------------

## Isotonic regression by pool-adjacent-violators.
##
## Each node wants to sit at the median of its neighbours, but nodes in a column must keep
## their order and not overlap. Subtracting the cumulative minimum spacing turns "ordered
## and separated" into plain "non-decreasing", and PAVA then gives the non-decreasing
## sequence closest to what was wanted — the optimal placement, not an approximation of it.
static func _fit(desired: Array, weights: Array) -> Array:
	var blocks := []   # each: {value, weight, count}
	for i in desired.size():
		blocks.append({"value": float(desired[i]), "weight": maxf(float(weights[i]), 0.0001),
			"count": 1})
		while blocks.size() >= 2 \
			and blocks[blocks.size() - 2]["value"] > blocks[blocks.size() - 1]["value"]:
			var b: Dictionary = blocks.pop_back()
			var a: Dictionary = blocks.pop_back()
			var weight: float = a["weight"] + b["weight"]
			blocks.append({
				"value": (a["value"] * a["weight"] + b["value"] * b["weight"]) / weight,
				"weight": weight,
				"count": a["count"] + b["count"],
			})

	var result := []
	for block in blocks:
		for _i in block["count"]:
			result.append(block["value"])
	return result


static func _assign_coordinates(request: Dictionary) -> Dictionary:
	var layers: Array = request["layers"]
	var dummies: Dictionary = request["dummies"]
	var sizes: Dictionary = request["sizes"]
	var anchors: Dictionary = request["anchors"]
	var grid: float = request["grid"]
	var row_gutter: float = request["row_gutter"]

	var adjacency := _adjacency(request["edges"])
	# Edges to nodes outside the selection pull on coordinates without shaping the layers.
	var external_up := {}
	for edge in request["external"]:
		if anchors.has(edge[0]):
			if not external_up.has(edge[1]):
				external_up[edge[1]] = []
			external_up[edge[1]].append(edge[0])
		if anchors.has(edge[1]):
			if not external_up.has(edge[0]):
				external_up[edge[0]] = []
			external_up[edge[0]].append(edge[1])

	var height := func(node) -> float:
		return 0.0 if dummies.has(node) else float(sizes.get(node, Vector2(240, 140)).y)

	# ---- x: one column per layer, wide nodes push their own column out ----------------
	var xs := []
	var x := 0.0
	for layer in layers:
		xs.append(x)
		var widest := 0.0
		for node in layer:
			if not dummies.has(node):
				widest = maxf(widest, float(sizes.get(node, Vector2(240, 140)).x))
		x += maxf(float(request["column_pitch"]),
			ceilf((widest + float(request["column_gutter"])) / grid) * grid)

	# ---- y: start stacked, then pull toward neighbours ------------------------------
	var y := {}
	for layer in layers:
		var cursor := 0.0
		for node in layer:
			y[node] = cursor
			cursor += height.call(node) + row_gutter

	# Alternating sweeps: downward passes align a node under what feeds it, upward passes
	# under what it feeds. Several rounds let alignment propagate along a whole chain.
	for round in SWEEPS:
		var order := range(layers.size()) if round % 2 == 0 \
			else range(layers.size() - 1, -1, -1)
		var neighbours: Dictionary = adjacency["up"] if round % 2 == 0 else adjacency["down"]

		for layer_index in order:
			var layer: Array = layers[layer_index]
			if layer.is_empty():
				continue

			var desired := []
			var weights := []
			var offset := 0.0
			for i in layer.size():
				var node = layer[i]
				var centres := []
				for neighbour in neighbours.get(node, []):
					if y.has(neighbour):
						centres.append(float(y[neighbour]) + height.call(neighbour) * 0.5)
				for neighbour in external_up.get(node, []):
					var anchor: Vector2 = anchors[neighbour]
					centres.append(anchor.y + float(sizes.get(neighbour, Vector2(240, 140)).y) * 0.5)

				var want: float = float(y[node])
				if not centres.is_empty():
					centres.sort()
					var middle := centres.size() / 2
					var centre: float = centres[middle] if centres.size() % 2 == 1 \
						else (centres[middle - 1] + centres[middle]) * 0.5
					want = centre - height.call(node) * 0.5

				# PAVA works on a non-decreasing sequence; removing the cumulative minimum
				# spacing is what converts the separation constraints into that.
				desired.append(want - offset)
				# A dummy is a point on a long cable. Weighting the chain heavily is what
				# keeps that cable straight instead of letting nodes bend it.
				weights.append(4.0 if dummies.has(node) else 1.0)
				offset += height.call(node) + row_gutter

			var fitted := _fit(desired, weights)
			var cursor := 0.0
			for i in layer.size():
				y[layer[i]] = fitted[i] + cursor
				cursor += height.call(layer[i]) + row_gutter

	# ---- snap, then guarantee separation on the grid --------------------------------
	var result := {}
	for layer_index in layers.size():
		var layer: Array = layers[layer_index]
		var lowest := INF
		for node in layer:
			lowest = minf(lowest, float(y[node]))

		var cursor := -INF
		for node in layer:
			var snapped: float = roundf(float(y[node]) / grid) * grid
			if cursor > -INF:
				snapped = maxf(snapped, cursor)
			if not dummies.has(node):
				result[node] = Vector2(xs[layer_index], snapped)
			# Gaps are grid multiples, so enforcing them cannot knock anything off-grid.
			cursor = snapped + ceilf((height.call(node) + row_gutter) / grid) * grid
	return result
