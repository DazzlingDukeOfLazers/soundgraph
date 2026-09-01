class_name LayoutLegalize
extends RefCounted

## Repairing an arrangement without redesigning it.
##
## Layout goal 3, and the measurement that earned it is worth restating, because it is the
## whole argument for this being a separate operation from Auto-place:
##
## [codeblock]
##                      nodes moved   median   worst    total   stage violations
## minimal legalization           9       40    1040     1520          24 -> 26
## auto-place                    29     1330    3736    50742         24 -> 133
## [/codeblock]
##
## Legality costs nine nudges. Arranging from scratch relocates the patch. They are not the
## same operation and one button should not do both.
##
## > **Legalization repairs invalid geometry and preserves intent. It is not permission to
## > regenerate the arrangement.**
##
## ## What it may change, and what it may not
##
## It may move nodes to clear **tier 1** faults, and nothing else:
##
## [codeblock]
## overlaps            two node bodies intersecting
## clearance faults    two bodies closer than CLEARANCE
## trespass            a cable through a body that is not one of its endpoints
## [/codeblock]
##
## It does **not** optimise crossings, stage order, cable length, columns, area or anything
## else. Those are later operations, and a legalizer that improved them would be
## Auto-place wearing a smaller name. Readability is *reported* here, not pursued — with one
## exception, at `guarded` below.
##
## ## Local by construction, not by hope
##
## Only nodes in a fault may move. A trespass implicates the node being crossed; the two
## endpoints of the offending cable are admitted only when moving the crossed node cannot
## clear it, and that admission is recorded. Nothing else is ever unlocked. "Local" is a
## property of the candidate set rather than an outcome somebody hopes displacement stays
## small enough to justify.

## The rings a node is nudged through, in grid steps. Small first: the objective is the
## *nearest* legal arrangement, so a search that weighed a long move against a short one
## would find a legal answer further from the author's than it needed to be.
const NEAR := [1, 2, 3]
const LOCAL := [4, 6, 8, 11, 15]
## And the escape, for a node with no legal placement in reach. Reported separately, because
## "this node was trapped" is a different event from "this node was nudged".
const ESCAPE := [20, 26, 33, 42, 54, 70]

## Up, down, left, right. A diagonal is two nudges dressed as one, and the four cardinals
## are what a person means by moving a node out of the way.
const DIRECTIONS := 4

## The same figures `layout_baseline.gd` scores with, so a graph this calls legal is a graph
## the objective contract agrees is legal.
const CLEARANCE := 24.0
const TRESPASS_MARGIN := 6.0

## How many crossings a candidate may add before it is refused in favour of an equally legal
## one that does not.
##
## The single readability guard, and it is not an optimisation. If two moves both clear the
## same overlap and one adds a dozen crossings, taking the other costs nothing and needs no
## global objective to justify. What this may never become is a crossing minimiser: it only
## ever chooses between candidates that are already equal on legality and disturbance.
const GRATUITOUS_CROSSINGS := 3


## Every tier-1 fault in an arrangement.
##
## `boxes` is node id to Rect2; `routes` is what the **router** produced, not a straight line
## between two ports. That distinction is load-bearing and cost a whole search its first
## draft: `_route` avoids obstacles, so a trial judged against an unrouted path reported
## twenty-six trespasses where the drawing had three.
static func faults(boxes: Dictionary, routes: Array) -> Dictionary:
	var overlaps: Array = []
	var clearance: Array = []
	var ids: Array = boxes.keys()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: Rect2 = boxes[ids[i]]
			var b: Rect2 = boxes[ids[j]]
			if a.intersects(b):
				overlaps.append([ids[i], ids[j]])
			elif a.grow(CLEARANCE).intersects(b):
				clearance.append([ids[i], ids[j]])

	var trespass: Array = []
	for route: Dictionary in routes:
		var points: PackedVector2Array = route["points"]
		var from := str((route["fields"] as Array)[0])
		var to := str((route["fields"] as Array)[2])
		for id: String in ids:
			if id == from or id == to:
				continue
			var body: Rect2 = (boxes[id] as Rect2).grow(TRESPASS_MARGIN)
			var hit := false
			for i in range(points.size() - 1):
				var span := points[i].distance_to(points[i + 1])
				var steps := maxi(1, int(span / 10.0))
				for s in steps:
					if body.has_point(points[i].lerp(points[i + 1],
							(float(s) + 0.5) / float(steps))):
						hit = true
						break
				if hit:
					break
			if hit:
				trespass.append([id, from, to])
	return {"overlaps": overlaps, "clearance": clearance, "trespass": trespass,
		"total": overlaps.size() + clearance.size() + trespass.size()}


## Which nodes a set of faults allows to move, and why each one is in the set.
##
## `desperate` admits the endpoints of a trespassing cable, which is the only way a
## trespass can be cleared when the node being crossed has nowhere to go.
static func implicated(found: Dictionary, desperate: bool) -> Dictionary:
	var who := {}
	for pair: Array in found["overlaps"]:
		who[pair[0]] = "overlap"
		who[pair[1]] = "overlap"
	for pair: Array in found["clearance"]:
		who[pair[0]] = "clearance"
		who[pair[1]] = "clearance"
	for one: Array in found["trespass"]:
		who[one[0]] = "crossed by a cable"
		if desperate:
			who[one[1]] = "endpoint of a trespassing cable"
			who[one[2]] = "endpoint of a trespassing cable"
	return who


## The offsets a node is offered, in the order it is offered them.
static func rings(phase: int) -> Array:
	match phase:
		0: return NEAR
		1: return LOCAL
	return ESCAPE


static func offsets(radius: int, grid: float) -> Array:
	var out: Array = []
	for step in DIRECTIONS:
		var angle := TAU * float(step) / float(DIRECTIONS)
		out.append(Vector2(cos(angle), sin(angle)) * float(radius) * grid)
	return out


## How much of the author's arrangement a trial has spent: how many nodes, how far in total,
## and how far the worst one went.
static func disturbance(at: Dictionary, home: Dictionary) -> Array:
	var moved := 0
	var total := 0.0
	var worst := 0.0
	for id: String in at:
		if not home.has(id):
			continue
		var distance: float = (home[id] as Vector2).distance_to(at[id])
		if distance > 0.5:
			moved += 1
			total += distance
			worst = maxf(worst, distance)
	return [moved, total, worst]


## Whether one candidate is preferred to another, lexicographically.
##
## The order, and it is a legalization order rather than the production objective:
##
## [codeblock]
## 1  tier-1 faults remaining        the only thing being solved
## 2  new crossings, if gratuitous   the guard, not an optimisation
## 3  nodes moved
## 4  total displacement
## 5  worst displacement
## [/codeblock]
static func prefer(a: Array, b: Array) -> bool:
	for i in mini(a.size(), b.size()):
		if absf(float(a[i]) - float(b[i])) < 0.0001:
			continue
		return float(a[i]) < float(b[i])
	return false


## A candidate's score, with the crossing guard folded into it.
##
## The guard is expressed as a step rather than as a count on purpose: a candidate that adds
## one crossing and a candidate that adds none are treated as equal, so the search is not
## quietly minimising crossings. Only a *gratuitous* addition is separated out.
static func score(remaining: int, added_crossings: int, spent: Array) -> Array:
	var out: Array = [remaining,
		1 if added_crossings > GRATUITOUS_CROSSINGS else 0]
	out.append_array(spent)
	return out
