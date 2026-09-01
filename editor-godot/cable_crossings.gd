extends RefCounted

## Why two cables meeting is or is not a crossing, decided once.
##
## Routing goal 1.1. The routing baseline enumerated forty-two intersections on the dense
## fixture where the cord layer counted twenty-six, and ten against seven on babble. A gap
## that size cannot be carried into an optimiser: a crossing count is about to become an
## objective, and two counters disagreeing by half over the same patch means at least one
## of them is measuring something nobody named.
##
## The first thing 1.1 found is that **they were not looking at the same drawing.** The
## editor opens in CATENARY cable style, so the cord layer draws hanging curves, while
## `_routes()` returns the PCB router's polylines. Twenty-six cables, twenty-nine vertices
## each against twenty-five, and not one of them the same shape. Forced to the same
## geometry the layer counts eleven where the baseline counted ten, and *that* residue is a
## real question about the counting rule rather than about which picture is on screen.
##
## So the factoring is deliberate about what is shared and what is not:
##
## > **The rules are shared. The geometry is a parameter, and every answer says which
## > geometry it was asked about.**
##
## A classifier that quietly picked one would be the same defect in a new place.
##
## Nothing in this file changes what is drawn. It has no exclusion of its own — it
## reproduces the cord layer's decisions exactly and reports why each one went the way it
## did, so that a later goal can promote a described population into a rule *with the
## population in front of it*.

const CableArt := preload("res://cable_art.gd")


## The reasons an intersection is or is not drawn as a crossing.
##
## Deciding reasons only. Everything else an intersection happens to be — near an end,
## shallow, doubled — is a trait, because a trait that quietly decided something would be
## an exclusion rule nobody voted for.
enum Reason {
	ORDINARY,          ## Two unrelated cables meet. Drawn.
	SHARED_PORT,       ## They leave one output or arrive at one input. A fan is not a crossing.
	COLOUR_RULE,       ## `crossing_same_colour_only` is on and the inks differ.
}

const REASONS := ["ordinary_crossing", "shared_port", "colour_rule"]

## Coincident hits are merged within this radius, in the space the cords are given in.
##
## Not a tolerance on the geometry — the intersections are exact. It is a statement about
## the eye: `CableArt.crossings` reports at most one hit per segment of the upper cable, so
## a meeting that lands within a vertex or two of one is reported from the segments either
## side of it and counted twice. Twenty-four units is a little under three cord widths,
## which is the distance below which two marks would be read as one.
const COINCIDENT := 24.0


## Every intersection between these cords, classified.
##
## `cords` is the cord layer's own row shape — [points, ink, from_key, to_key, key, class] —
## because that is the representation both consumers already hold, and asking each of them
## to translate into a third one is how the two counters drifted apart in the first place.
## Order is draw order: later rows are over earlier ones.
##
## Every intersection is returned, including the ones nothing will draw. Filtering is the
## caller's business, and the caller has to say so out loud.
static func classify(cords: Array) -> Array:
	var found: Array = []
	for upper in cords.size():
		for lower in upper:
			var a: Array = cords[upper]
			var b: Array = cords[lower]
			var hits := _all_hits(a[0], b[0])
			if hits.is_empty():
				continue
			var reason := Reason.ORDINARY
			if _shares_port(a, b):
				reason = Reason.SHARED_PORT
			elif CableArt.crossing_same_colour_only and not _same_ink(a[1], b[1]):
				reason = Reason.COLOUR_RULE
			for hit: Dictionary in hits:
				var at: Vector2 = hit["at"]
				found.append({
					"over": str(a[4]), "under": str(b[4]),
					"over_index": upper, "under_index": lower,
					"at": at,
					"angle": snappedf(_angle(hit["upper_dir"], hit["lower_dir"]), 0.1),
					"from_over_end": snappedf(_from_end(a[0], at), 0.1),
					"from_under_end": snappedf(_from_end(b[0], at), 0.1),
					"rendered": reason == Reason.ORDINARY,
					"reason": REASONS[reason],
					"traits": _traits(a, b, at, hit),
					# Whether `CableArt.crossings` would report this one. It takes the
					# first hit on each segment of the upper cable and moves on, so a
					# second meeting inside one segment is invisible to it. Recorded
					# rather than corrected: the renderer's count has to stay the
					# renderer's count.
					"seen_by_cable_art": bool(hit["first_on_segment"]),
				})
	_mark_coincident(found)
	return found


## The two counts the classification supports, and what each one means.
##
## Both are true. They answer different questions, which is the whole of goal 1.1:
##
## - `marks` is how many crossing treatments the cord layer paints. It is the renderer's
##   number, subject to the renderer's per-segment cap, and it is the right one for "how
##   much crossing grammar is on this screen".
## - `meetings` is how many places two drawn cables actually meet, with doubled reports
##   merged. It is the geometry's number and the right one for an objective, because an
##   optimiser that removed a mark by splitting it in two would otherwise score a win.
static func tally(classified: Array) -> Dictionary:
	var marks := 0
	var meetings := 0
	var excluded := {}
	for hit: Dictionary in classified:
		if not bool(hit["rendered"]):
			var why := str(hit["reason"])
			excluded[why] = int(excluded.get(why, 0)) + 1
			continue
		if bool(hit["seen_by_cable_art"]):
			marks += 1
		if not bool(hit["coincident_with_earlier"]):
			meetings += 1
	return {"marks": marks, "meetings": meetings, "excluded": excluded,
		"intersections": classified.size()}


## Whether two cords meet because they share a port rather than because they cross.
##
## The cord layer's `_joined`, moved here unchanged. Two cables leaving one output or
## arriving at one input meet **by design**, and a separation mark on that meeting says the
## opposite of what is true.
static func _shares_port(a: Array, b: Array) -> bool:
	return a[2] == b[2] or a[3] == b[3]


## Whether two cords are the same colour to a reader.
##
## The cord layer's own test, moved here unchanged, channel by channel. Written as an
## HSV comparison on the first attempt at this file, which is a different rule that happens
## to agree on most pairs — exactly the kind of near-copy this goal exists to delete.
static func _same_ink(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.02 and absf(a.g - b.g) < 0.02 and absf(a.b - b.b) < 0.02


## Descriptive facts about a meeting. None of them decides anything.
##
## `converging` is the one goal 1 went looking for and named wrongly. Three of babble's ten
## sat within fifty units of an end, and it was tempting to call that socket congestion — an
## art defect. It is structural instead: the two cables end at **the same node on different
## ports**, and the meeting is on the half of each cable nearer that node. They are not
## fighting for a corridor, they are converging on a destination. Defined by the shared node
## rather than by a distance, so no threshold has to be invented to see the population.
static func _traits(a: Array, b: Array, at: Vector2, hit: Dictionary) -> Array:
	var traits: Array = []
	var shared := _shared_node(a, b)
	if shared != "":
		traits.append("same_node")
		if _converging_on(a, at, shared) and _converging_on(b, at, shared):
			traits.append("converging")
	if _angle(hit["upper_dir"], hit["lower_dir"]) < 25.0:
		traits.append("shallow")
	return traits


## The node both cords touch, when they touch one and it is not through the same port.
static func _shared_node(a: Array, b: Array) -> String:
	if _shares_port(a, b):
		return ""
	for one: String in [str(a[2]).get_slice(":", 0), str(a[3]).get_slice(":", 0)]:
		for two: String in [str(b[2]).get_slice(":", 0), str(b[3]).get_slice(":", 0)]:
			if one == two:
				return one
	return ""


## Whether this meeting is on the half of the cord nearer the shared node.
static func _converging_on(cord: Array, at: Vector2, node: String) -> bool:
	var points: PackedVector2Array = cord[0]
	if points.size() < 2:
		return false
	var at_start := str(cord[2]).get_slice(":", 0) == node
	var along := _arc_to(points, at)
	var total := _arc_length(points)
	if total <= 0.0:
		return false
	return (along < total * 0.5) if at_start else (along > total * 0.5)


## Marks each hit that repeats one already recorded for the same pair.
##
## Per pair, not globally: two different pairs meeting at the same spot are two crossings
## that happen to coincide, and merging those would hide a genuine congestion point.
static func _mark_coincident(found: Array) -> void:
	var seen := {}
	for hit: Dictionary in found:
		var pair := "%s|%s" % [hit["over"], hit["under"]]
		# A plain Array, deliberately. The first version of this kept a
		# PackedVector2Array per pair, which is a value type in GDScript: the cast on the
		# way to `append` handed back a copy, nothing ever accumulated, and every hit
		# reported itself as the first of its kind. Two crossings eight units apart, and
		# two at identical coordinates, both came through the listing as separate
		# meetings — which is how it was caught.
		var spots: Array = seen.get(pair, [])
		var repeat := false
		for other: Vector2 in spots:
			if other.distance_to(hit["at"]) < COINCIDENT:
				repeat = true
				break
		spots.append(hit["at"])
		seen[pair] = spots
		hit["coincident_with_earlier"] = repeat


## Every segment-pair intersection, with the direction of each segment at the meeting and
## whether `CableArt.crossings` would have stopped before reaching it.
static func _all_hits(upper: PackedVector2Array,
		lower: PackedVector2Array) -> Array:
	var hits: Array = []
	if upper.size() < 2 or lower.size() < 2:
		return hits
	var box_a := _bounds(upper)
	var box_b := _bounds(lower)
	if not box_a.grow(2.0).intersects(box_b):
		return hits
	for i in upper.size() - 1:
		var p1 := upper[i]
		var p2 := upper[i + 1]
		var seg := Rect2(p1, Vector2.ZERO).expand(p2).grow(1.0)
		if not seg.intersects(box_b):
			continue
		var first := true
		for j in lower.size() - 1:
			var hit: Variant = Geometry2D.segment_intersects_segment(
				p1, p2, lower[j], lower[j + 1])
			if hit == null:
				continue
			hits.append({"at": hit as Vector2, "upper_dir": p2 - p1,
				"lower_dir": lower[j + 1] - lower[j], "first_on_segment": first})
			first = false
	return hits


## The acute angle between two crossing cables, in degrees.
static func _angle(one: Vector2, two: Vector2) -> float:
	if one.length() < 0.0001 or two.length() < 0.0001:
		return 90.0
	var degrees := rad_to_deg(absf(one.angle_to(two)))
	return minf(degrees, 180.0 - degrees)


static func _from_end(points: PackedVector2Array, at: Vector2) -> float:
	var along := _arc_to(points, at)
	return minf(along, _arc_length(points) - along)


static func _arc_to(points: PackedVector2Array, at: Vector2) -> float:
	var run := 0.0
	var best := 0.0
	var nearest := INF
	for i in points.size() - 1:
		var closest := Geometry2D.get_closest_point_to_segment(
			at, points[i], points[i + 1])
		var away := closest.distance_to(at)
		if away < nearest:
			nearest = away
			best = run + points[i].distance_to(closest)
		run += points[i].distance_to(points[i + 1])
	return best


static func _arc_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in points.size() - 1:
		total += points[i].distance_to(points[i + 1])
	return total


static func _bounds(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var box := Rect2(points[0], Vector2.ZERO)
	for point in points:
		box = box.expand(point)
	return box
