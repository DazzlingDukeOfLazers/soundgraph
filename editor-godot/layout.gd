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
##   edges         Array of [from_id, to_id] or [from_id, to_id, weight]; endpoints
##                 outside `nodes` are anchors. Weight decides how hard an edge pulls its
##                 ends into line — the audio path is weighted far above modulation, so
##                 the signal chain comes out as one straight spine with the control
##                 sources hanging beneath it, which is how a patch is read.
##   sizes         id -> Vector2, for every node and anchor
##   anchors       id -> Vector2, fixed positions of nodes that must not move
##   grid, column_pitch, column_gutter, row_step
##
## Returns id -> Vector2 for every id in `nodes`.
## Above this many nodes, the flat layered layout stops being readable and the modular
## path below takes over. Every existing example short of the DX7 bank sits under it,
## so nothing already laid out moves.
const CLUSTER_THRESHOLD := 18

## The largest subcircuit that contracts into one tile. Six covers a DX7 operator
## (pitch, oscillator, envelope, VCA, index) with room to spare, and stays small enough
## that a tile is a glance, not a study.
const MODULE_MAX := 6

## A row of tiles aims to be about this many times wider than tall before wrapping.
const ROW_ASPECT := 2.6
const ROW_GAP := 100.0

## Below CLUSTER_THRESHOLD, the wrap triggers on shape instead: a flat layout wider
## than this many times its height is a ribbon whatever its node count says.
const RIBBON_MIN_NODES := 10
const RIBBON_ASPECT := 3.5

## A flat layout keeping less than this fraction of its bounds as actual nodes is
## judged wasteful and re-laid modular. The big-patch flow packs about 40-70%; a deep
## chain of towers under the plain path measured 16%.
const PACKING_FLOOR := 0.22


## The request, marked to take the plain path — used for the try-flat-first probe.
static func _plain_copy(request: Dictionary) -> Dictionary:
	var copy := request.duplicate()
	copy["_plain"] = true
	return copy


static func arrange(request: Dictionary) -> Dictionary:
	var ids: Array = request["nodes"]
	if ids.is_empty():
		return {}
	# Big graphs go through the modular path: repeated subcircuits contract into tiles,
	# the tile graph is laid out flat, and its columns wrap into rows like text. The
	# inner and outer calls come back here with "_plain" set, so the recursion is one
	# level deep by construction.
	if ids.size() >= CLUSTER_THRESHOLD and not request.get("_plain", false):
		return _arrange_modular(request)
	# Middling graphs earn the same treatment by *result*, not size. The fifteen-node
	# modular DX7 voice is a chain thirteen layers deep: the plain path spread it over
	# 4744x1915 — not a ribbon by aspect, but 16% packing, five-sixths of the frame
	# spent on air. So the plain layout runs first and is judged on both counts: too
	# wide, or too empty, and the modular wrap takes over.
	if ids.size() >= RIBBON_MIN_NODES and not request.get("_plain", false):
		var flat := arrange(_plain_copy(request))
		var low := Vector2(INF, INF)
		var high := Vector2(-INF, -INF)
		var content := 0.0
		for id in ids:
			var size: Vector2 = request["sizes"].get(id, Vector2(240, 140))
			low = low.min(flat[id])
			high = high.max(flat[id] + size)
			content += size.x * size.y
		var bounds := high - low
		var ribbon: bool = bounds.x > RIBBON_ASPECT * maxf(bounds.y, 500.0)
		var wasteful: bool = content < PACKING_FLOOR * bounds.x * bounds.y
		if not ribbon and not wasteful:
			return flat
		return _arrange_modular(request)

	var sizes: Dictionary = request["sizes"]
	var anchors: Dictionary = request.get("anchors", {})
	var grid: float = request.get("grid", 40.0)
	var column_pitch: float = request.get("column_pitch", 400.0)
	var column_gutter: float = request.get("column_gutter", 80.0)
	var row_step: float = request.get("row_step", 200.0)

	var movable := {}
	for id in ids:
		movable[id] = true

	var weights := {}
	for edge in request["edges"]:
		weights["%s>%s" % [edge[0], edge[1]]] = float(edge[2]) if edge.size() > 2 else 1.0

	# Only edges between movable nodes shape the hierarchy; edges to anchors pull on the
	# coordinates later without dictating the columns.
	var edges := []
	var external := []
	for edge in request["edges"]:
		if movable.has(edge[0]) and movable.has(edge[1]):
			edges.append([edge[0], edge[1]])
		elif movable.has(edge[0]) or movable.has(edge[1]):
			external.append([edge[0], edge[1]])

	edges = _remove_cycles(ids, edges)
	var depths := _assign_layers(ids, edges)

	# Weights ride along into the layering so dummy chains inherit the pull of the edge
	# they stand in for.
	var weighted := []
	for edge in edges:
		weighted.append([edge[0], edge[1], weights.get("%s>%s" % [edge[0], edge[1]], 1.0)])

	var built := _build_layers(ids, weighted, depths)
	var layers: Array = built["layers"]
	var chain_edges: Array = built["edges"]
	var dummies: Dictionary = built["dummies"]

	_reduce_crossings(layers, chain_edges)

	return _assign_coordinates({
		"layers": layers, "edges": chain_edges, "dummies": dummies,
		"sizes": sizes, "anchors": anchors, "external": external, "weights": weights,
		"grid": grid, "column_pitch": column_pitch,
		"column_gutter": column_gutter, "row_step": row_step,
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
		var span_weight = edge[2] if edge.size() > 2 else 1.0
		var from_depth: int = depths[edge[0]]
		var to_depth: int = depths[edge[1]]
		if to_depth - from_depth <= 1:
			chain_edges.append([edge[0], edge[1], span_weight])
			continue
		var previous = edge[0]
		for depth in range(from_depth + 1, to_depth):
			# '#' is not legal in a patch node id (see schema/patch.schema.json), so a
			# dummy can never collide with a real one.
			var dummy := "#dummy%d" % counter
			counter += 1
			dummies[dummy] = true
			layers[depth].append(dummy)
			chain_edges.append([previous, dummy, span_weight])
			previous = dummy
		chain_edges.append([previous, edge[1], span_weight])

	return {"layers": layers, "edges": chain_edges, "dummies": dummies}


# ---------------------------------------------------------------------------------
# Phase 3 — crossing reduction
# ---------------------------------------------------------------------------------

static func _adjacency(edges: Array) -> Dictionary:
	var down := {}
	var up := {}
	var weight := {}
	for edge in edges:
		if not down.has(edge[0]):
			down[edge[0]] = []
		down[edge[0]].append(edge[1])
		if not up.has(edge[1]):
			up[edge[1]] = []
		up[edge[1]].append(edge[0])
		weight["%s>%s" % [edge[0], edge[1]]] = float(edge[2]) if edge.size() > 2 else 1.0
	return {"down": down, "up": up, "weight": weight}


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
	# Rows land on a coarse step rather than on every grid line. A patch aligned by hand
	# uses the major lines and one pitch for the whole stack; medians alone would scatter
	# rows onto arbitrary multiples of 40 and lose that.
	var row_step: float = request["row_step"]

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

	# Vertical separation is a whole number of row steps, so a stack of nodes lands on
	# consecutive major lines instead of wherever their heights happen to end.
	var step_for := func(node) -> float:
		if dummies.has(node):
			return row_step
		return ceilf(float(sizes.get(node, Vector2(240, 140)).y) / row_step) * row_step

	# ---- y: start stacked, then pull toward neighbours ------------------------------
	var y := {}
	for layer in layers:
		var cursor := 0.0
		for node in layer:
			y[node] = cursor
			cursor += step_for.call(node)

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

				# The pull toward each neighbour is weighted by the edge. Audio edges
				# weigh far more than control ones, so the signal chain straightens into
				# a spine and the modulation sources give way around it — which is the
				# shape a person draws by hand.
				var pulls := []
				var strongest := 0.0
				for neighbour in neighbours.get(node, []):
					if not y.has(neighbour):
						continue
					var key := "%s>%s" % [neighbour, node] if round % 2 == 0 \
						else "%s>%s" % [node, neighbour]
					var pull: float = adjacency["weight"].get(key, 1.0)
					pulls.append([float(y[neighbour]) + height.call(neighbour) * 0.5, pull])
					strongest = maxf(strongest, pull)
				for neighbour in external_up.get(node, []):
					var anchor: Vector2 = anchors[neighbour]
					pulls.append([anchor.y
						+ float(sizes.get(neighbour, Vector2(240, 140)).y) * 0.5, 1.0])

				var want: float = float(y[node])
				if not pulls.is_empty():
					# Only the strongest class of edge decides the row: averaging an audio
					# spine against a modulation cable would bend the spine.
					var centres := []
					for entry in pulls:
						if entry[1] >= strongest - 0.001:
							centres.append(float(entry[0]))
					if centres.is_empty():
						for entry in pulls:
							centres.append(float(entry[0]))
					centres.sort()
					var middle := centres.size() / 2
					var centre: float = centres[middle] if centres.size() % 2 == 1 \
						else (centres[middle - 1] + centres[middle]) * 0.5
					want = centre - height.call(node) * 0.5

				# PAVA works on a non-decreasing sequence; removing the cumulative minimum
				# spacing is what converts the separation constraints into that.
				desired.append(want - offset)
				# A dummy is a point on a long cable, and a node on the audio spine is the
				# line everything else should bend around. Both resist being moved.
				weights.append(4.0 if dummies.has(node) else maxf(1.0, strongest))
				offset += step_for.call(node)

			var fitted := _fit(desired, weights)
			var cursor := 0.0
			for i in layer.size():
				y[layer[i]] = fitted[i] + cursor
				cursor += step_for.call(layer[i])

	# ---- straighten the strongest chains --------------------------------------------
	#
	# The sweeps get every node close to its neighbours, but a weighted median is still a
	# compromise: a spine node sitting above two modulators gets pulled down a little by
	# both, and once that is snapped to a row it lands on the wrong one. The audio path
	# is not a compromise — it is the line everything else should arrange itself around —
	# so the strongest chains are put on a single row outright.
	var pinned := _pin_strong_chains(layers, request["edges"], y, dummies, row_step)

	# ---- snap to the row step, then guarantee separation ----------------------------
	var result := {}
	for layer_index in layers.size():
		var layer: Array = layers[layer_index]
		if layer.is_empty():
			continue

		var rows := []
		for node in layer:
			rows.append(roundf(float(y[node]) / row_step) * row_step)

		# A pinned node holds its row and the rest of the column gives way around it,
		# rather than the whole column sliding down from whatever sits at the top.
		var anchor := -1
		for i in layer.size():
			if pinned.has(layer[i]):
				anchor = i
				break
		if anchor >= 0:
			rows[anchor] = float(pinned[layer[anchor]])
			for i in range(anchor - 1, -1, -1):
				rows[i] = minf(rows[i], rows[i + 1] - step_for.call(layer[i]))
			for i in range(anchor + 1, layer.size()):
				rows[i] = maxf(rows[i], rows[i - 1] + step_for.call(layer[i - 1]))
		else:
			for i in range(1, layer.size()):
				rows[i] = maxf(rows[i], rows[i - 1] + step_for.call(layer[i - 1]))

		for i in layer.size():
			if not dummies.has(layer[i]):
				result[layer[i]] = Vector2(xs[layer_index], rows[i])
	return result


## Groups nodes joined by the heaviest edges and puts each group on one row. Returns
## node -> row for the nodes that were placed this way.
static func _pin_strong_chains(layers: Array, edges: Array, y: Dictionary,
		dummies: Dictionary, row_step: float) -> Dictionary:
	var strongest := 1.0
	for edge in edges:
		if edge.size() > 2:
			strongest = maxf(strongest, float(edge[2]))
	if strongest <= 1.0:
		return {}   # nothing is more important than anything else

	# Union-find over the heaviest edges only.
	var parent := {}
	var find := func(node):
		var root = node
		while parent.get(root, root) != root:
			root = parent[root]
		return root
	for edge in edges:
		if edge.size() <= 2 or float(edge[2]) < strongest - 0.001:
			continue
		parent[edge[0]] = parent.get(edge[0], edge[0])
		parent[edge[1]] = parent.get(edge[1], edge[1])
		var a = find.call(edge[0])
		var b = find.call(edge[1])
		if a != b:
			parent[a] = b

	var groups := {}
	for node in parent:
		var root = find.call(node)
		if not groups.has(root):
			groups[root] = []
		groups[root].append(node)

	# Which layer each node is in, so a group with two members in one layer is skipped —
	# they cannot share a row.
	var layer_of := {}
	for i in layers.size():
		for node in layers[i]:
			layer_of[node] = i

	var pinned := {}
	for root in groups:
		var members: Array = groups[root]
		if members.size() < 2:
			continue
		var seen := {}
		var conflict := false
		for node in members:
			var layer: int = layer_of.get(node, -1)
			if seen.has(layer):
				conflict = true
			seen[layer] = true
		if conflict:
			continue

		var rows := []
		for node in members:
			rows.append(float(y.get(node, 0.0)))
		rows.sort()
		var middle := rows.size() / 2
		var centre: float = rows[middle] if rows.size() % 2 == 1 \
			else (rows[middle - 1] + rows[middle]) * 0.5
		var row := roundf(centre / row_step) * row_step
		for node in members:
			if not dummies.has(node):
				pinned[node] = row
	return pinned


# ---------------------------------------------------------------------------------
# The modular path: big graphs as tiles of subcircuits, wrapped into rows.
#
# Two observations drive it. First, big patches are big because something repeats — a
# DX7 voice is six copies of pitch→oscillator→envelope→VCA — and laying out 33 nodes
# individually spends the algorithm's care on separating things that belong together.
# Second, one long left-to-right band is the *correct* reading order and a hopeless
# aspect ratio: the fitted view of a DX7 voice landed at 23% zoom.
#
# So: contract every exclusive-feeder subcircuit (a node whose output goes one place
# belongs to that place, up to MODULE_MAX) into a tile, lay each tile out internally,
# lay out the much smaller tile graph, and wrap its columns into rows. Repetition is
# not detected — it *emerges*: six identical operator clusters contract into six
# identical tiles, because contraction follows the same wiring in each.
# ---------------------------------------------------------------------------------

static func _arrange_modular(request: Dictionary) -> Dictionary:
	var ids: Array = request["nodes"]
	var sizes: Dictionary = request["sizes"]
	var grid: float = request.get("grid", 40.0)
	var column_gutter: float = request.get("column_gutter", 80.0)

	var movable := {}
	for id in ids:
		movable[id] = true

	# ---- contraction: a node with exactly one movable consumer joins it --------------
	var parent := {}
	for id in ids:
		parent[id] = id
	var find := func(start) -> Variant:
		var at = start
		while parent[at] != at:
			at = parent[at]
		return at

	var targets := {}
	for edge in request["edges"]:
		if movable.has(edge[0]) and movable.has(edge[1]):
			if not targets.has(edge[0]):
				targets[edge[0]] = {}
			targets[edge[0]][edge[1]] = true

	var cluster_size := {}
	var cluster_depth := {}
	for id in ids:
		cluster_size[id] = 1
		cluster_depth[id] = 1
	# A few passes reach the fixpoint: chains contract toward their consumers quickly.
	for pass_index in 8:
		var merged := false
		for id in ids:
			if not targets.has(id) or targets[id].size() != 1:
				continue
			var consumer = targets[id].keys()[0]
			var from_root = find.call(id)
			var to_root = find.call(consumer)
			if from_root == to_root:
				continue
			if cluster_size[from_root] + cluster_size[to_root] > MODULE_MAX:
				continue
			# Depth-capped as well as size-capped. Without this, a mixer chain contracts
			# into one six-layer noodle two thousand pixels wide, and the row packer has
			# to make every row that wide to hold it — tiles only pack well when they
			# are roughly the same shape, which an operator cluster and a chain segment
			# both are at depth three or less.
			if cluster_depth[from_root] + cluster_depth[to_root] > 4:
				continue
			parent[from_root] = to_root
			cluster_size[to_root] += cluster_size[from_root]
			cluster_depth[to_root] = maxi(cluster_depth[to_root],
				cluster_depth[from_root] + 1)
			merged = true
		if not merged:
			break

	var members := {}
	for id in ids:
		var root = find.call(id)
		if not members.has(root):
			members[root] = []
		members[root].append(id)

	# ---- each tile laid out on its own, tighter than the top level --------------------
	var inner_offsets := {}
	var tile_sizes := {}
	for root in members:
		var group: Array = members[root]
		if group.size() == 1:
			inner_offsets[root] = {root: Vector2.ZERO}
			tile_sizes[root] = sizes.get(root, Vector2(240, 140))
			continue
		var inner_edges := []
		for edge in request["edges"]:
			if group.has(edge[0]) and group.has(edge[1]):
				inner_edges.append(edge)
		var inner := arrange({
			"nodes": group,
			"edges": inner_edges,
			"sizes": sizes,
			"grid": grid,
			"column_pitch": request.get("column_pitch", 400.0) * 0.6,
			"column_gutter": column_gutter * 0.5,
			"row_step": request.get("row_step", 200.0),
			"_plain": true,
		})
		var low := Vector2(INF, INF)
		var high := Vector2(-INF, -INF)
		for id in group:
			var at: Vector2 = inner[id]
			var size: Vector2 = sizes.get(id, Vector2(240, 140))
			low = low.min(at)
			high = high.max(at + size)
		var offsets := {}
		for id in group:
			offsets[id] = inner[id] - low
		inner_offsets[root] = offsets
		tile_sizes[root] = high - low

	# ---- the tile graph flows into rows, the way the rack flows modules --------------
	# The first version ran Sugiyama over the tiles and then wrapped its columns, and
	# got a 3584x3427 portrait block: the layered pass stacks tiles vertically inside
	# layers before any wrap can help, and with tiles a thousand pixels wide there are
	# only two or three rows of granularity to correct it with. A flow does not fight
	# itself: order the tiles by signal depth, fill rows to a width chosen for the
	# aspect, read left to right, top to bottom. It is the rack's idea, because a rack
	# is what a big patch wants to be.
	var outer_edges := []
	for edge in request["edges"]:
		if not (movable.has(edge[0]) and movable.has(edge[1])):
			continue
		var a = find.call(edge[0])
		var b = find.call(edge[1])
		if a != b:
			outer_edges.append([a, b])
	var roots: Array = members.keys()
	var depths := _assign_layers(roots, _remove_cycles(roots, outer_edges))
	var ordered: Array = roots.duplicate()
	ordered.sort_custom(func(a, b) -> bool:
		if depths[a] != depths[b]:
			return depths[a] < depths[b]
		return roots.find(a) < roots.find(b))

	var total_width := 0.0
	var tallest := 0.0
	var widest := 0.0
	for root in ordered:
		total_width += tile_sizes[root].x + column_gutter
		tallest = maxf(tallest, tile_sizes[root].y)
		widest = maxf(widest, tile_sizes[root].x)
	# Aspect A = W / (rows * H) and rows = total / W give W = sqrt(A * H * total) —
	# where H is what a row actually costs, gap included. Using the bare tile height
	# here made the packer aim far too narrow: with short tiles the gap is half the row.
	var target: float = maxf(sqrt(ROW_ASPECT * (tallest + ROW_GAP) * total_width), widest)

	var positions := {}
	var cursor := 0.0
	var row_top := 0.0
	var row_tallest := 0.0
	for root in ordered:
		if cursor > 0.0 and cursor + tile_sizes[root].x > target:
			row_top += row_tallest + ROW_GAP
			cursor = 0.0
			row_tallest = 0.0
		for id in inner_offsets[root]:
			positions[id] = Vector2(cursor, row_top) + inner_offsets[root][id]
		row_tallest = maxf(row_tallest, tile_sizes[root].y)
		cursor += tile_sizes[root].x + column_gutter
	# Snapped like every other arranged position, so hand-editing continues on-grid.
	for id in positions:
		positions[id] = Vector2(roundf(positions[id].x / grid) * grid,
			roundf(positions[id].y / grid) * grid)
	return positions
