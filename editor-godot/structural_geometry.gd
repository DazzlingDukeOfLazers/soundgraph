extends RefCounted

## The abstract drawing: what a patch looks like with no cable renderer involved at all.
##
## Routing goal 2.4, and the second half of a pair. 2.3 made the arrangement's cable cost
## canonical — straight-line port-to-port distance, Euclidean so that no style's grammar
## sneaks back in — and left one accidental presentation dependency behind it: `Tidy flow`
## is a structural operation and was still gated on `_layout_crossings()`, which the cord
## layer answers. So a structural decision moved when somebody changed how cables were
## drawn, by two nodes on babble and two on the dense fixture.
##
## Both structural metrics now describe the same abstract drawing:
##
## > **structural length** — Euclidean distance between the two ports.
## > **structural crossing** — a proper interior intersection between two of those chords.
##
## No sag, no orthogonal corridor, no waypoint, no cable skin. If a metric in this file ever
## needs to know what style the editor is in, it has stopped being structural.

## Three exclusions, because a chord crossing should describe a relationship between
## independent parts of the graph and nothing else.
##
## **Shared port.** Two cables leaving one output meet by design; that is a fan, and the
## cable pass settled long ago that marking it says the opposite of what is true.
##
## **Shared node at either end.** Two cords converging on different ports of one module can
## always be made to cross by the port order, and `Tidy flow` moves nodes — it cannot
## reorder a module's ports, so counting these would charge it for something it has no
## instrument to fix. The routing audit already separated this population by name: they are
## terminal convergence, not a corridor conflict.
##
## **Endpoint touches and collinear overlap.** A proper interior intersection or nothing.
## Two chords that merely meet at a shared point, or lie along each other, are a degenerate
## arrangement rather than a crossing, and letting them count would make the metric jump
## about on exactly the coincidences a grid layout produces most often.
const TOUCH := 0.5


## Every connection as the straight line between its two ports.
##
## `graph` is asked for its own endpoints, so this is the same port geometry the structural
## cable cost is measured from — one definition of "where a cable begins" rather than two.
static func chords(graph) -> Array:
	var out: Array = []
	for connection: Dictionary in graph.connections:
		var ends: Array = graph._endpoints(connection)
		if ends.is_empty():
			continue
		var fields: Array = graph._connection_fields(connection)
		out.append({
			"a": ends[0], "b": ends[1],
			"from_node": str(fields[0]), "to_node": str(fields[2]),
			"from_port": "%s:%d" % [str(fields[0]), int(fields[1])],
			"to_port": "%s:%d" % [str(fields[2]), int(fields[3])],
		})
	return out


## How many pairs of chords properly cross.
##
## Named for what it is. The last several goals established that an unlabelled crossing
## number is dangerous — two counters over one patch disagreed by half, and a routing
## baseline measured a geometry the editor was not drawing — so this is never to be called
## `crossings` at a call site, and never compared with `_layout_crossings()` as though the
## two were answers to one question. They are answers to two.
static func chord_crossings(chords: Array) -> int:
	var found := 0
	for i in chords.size():
		for j in range(i + 1, chords.size()):
			if _properly_crosses(chords[i], chords[j]):
				found += 1
	return found


## The pairs themselves, for a harness that wants to say which ones.
static func chord_crossing_pairs(chords: Array) -> Array:
	var found: Array = []
	for i in chords.size():
		for j in range(i + 1, chords.size()):
			if _properly_crosses(chords[i], chords[j]):
				found.append(["%s>%s" % [chords[i]["from_port"], chords[i]["to_port"]],
					"%s>%s" % [chords[j]["from_port"], chords[j]["to_port"]]])
	return found


static func _properly_crosses(one: Dictionary, two: Dictionary) -> bool:
	if str(one["from_port"]) == str(two["from_port"]) \
			or str(one["to_port"]) == str(two["to_port"]):
		return false
	# Any shared module at either end, not merely a shared port.
	for mine: String in [str(one["from_node"]), str(one["to_node"])]:
		for theirs: String in [str(two["from_node"]), str(two["to_node"])]:
			if mine == theirs:
				return false
	var hit: Variant = Geometry2D.segment_intersects_segment(
		one["a"], one["b"], two["a"], two["b"])
	if hit == null:
		return false
	var at: Vector2 = hit
	for end: Vector2 in [one["a"], one["b"], two["a"], two["b"]]:
		if at.distance_to(end) < TOUCH:
			return false
	return true
