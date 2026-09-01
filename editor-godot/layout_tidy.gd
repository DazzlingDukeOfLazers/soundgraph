class_name LayoutTidy
extends RefCounted

## Improving the agreement between a graph's topology and its left-to-right drawing.
##
## Layout goal 4, and its mandate is deliberately narrower than "make the graph better":
##
## > **Tidy this area: improve the correspondence between topology and left-to-right layout,
## > while preserving legality and disturbing as little authored placement as possible.**
##
## It is not a miniature Auto-place. The boundary between the three operations is the whole
## point of having three:
##
## [codeblock]
## Resolve overlaps    owns tier 1
## Tidy flow           owns a restricted part of tier 2
## Auto-place          keeps permission to regenerate structure
## [/codeblock]
##
## ## What it optimises, and what it only watches
##
## The four topology-derived properties, as an **ordered vector** rather than a weighted
## score, for the same reason the objective contract is lexicographic:
##
## [codeblock]
## 1  stage_violations   a later stage standing left of an earlier one
## 2  backward           a cable ending left of where it began
## 3  stage_spread       bands one logical stage is scattered across
## 4  surplus_columns    bands beyond what the graph's own depth requires
## [/codeblock]
##
## Crossings and cable length are **guards, not objectives**. A tidy move that increases
## crossings is refused while any non-worsening move exists for the same stage improvement.
## Beginning from the assumption that stage order must be bought with crossings would be
## assuming the answer; if the fixtures show the rule is too strict, the fixtures can loosen
## it.
##
## ## X strongly, Y reluctantly
##
## The single most important behavioural rule here.
##
## > **Stage tidy owns X strongly and Y reluctantly.**
##
## Horizontal position is what the topology has an opinion about. Vertical position usually
## encodes something the topology cannot know — oscillators grouped, modulation under audio,
## voices stacked — so a node is moved toward its stage band in X, keeps its Y, and is
## nudged vertically only to stay legal. Vertical *order* is never reshuffled because some
## other ordering would look tidier.
##
## ## A component moves as one
##
## Stages come from the condensation, so a strongly connected component is one stage unit.
## Forcing an internal left-to-right order onto a feedback loop is correcting it into
## nonsense, so the members of a component are offered the same offset and keep their
## internal arrangement.

## How far along the way to its stage band a node is offered, as fractions of the distance.
## Partial steps first: the objective is agreement, not alignment, and a node that only has
## to move a little to stop being a violation should only move a little.
const STEPS := [1.0, 0.5, 0.25]

## And the furthest one move may go, in grid steps.
##
## Without it a node whose stage band is three thousand units away moves three thousand
## units, which is a relocation whatever it did to the stage count — babble tidied four
## nodes a median of 2720 units before this existed. A bound turns the operation into a
## sequence of nudges that stops when it can no longer improve locally, which is what
## "tidy" means and what "arrange" does not.
const REACH := 8

## Vertical nudges, in grid steps, offered **only** to keep a horizontal move legal. Never
## as an improvement in their own right.
const Y_REPAIR := [0, 1, -1]


## Which stage each node is at, from the **whole** connected topology.
##
## Whole, even when only a few nodes may move. Deriving depth from a selection's induced
## subgraph would convince the algorithm that three middle nodes are sources, and it would
## then destroy their relationship to everything around them — a tidy operation that makes
## a selection internally consistent and globally wrong.
static func stages(ids: Array, edges: Array) -> Dictionary:
	return LayoutObjective.depths(ids, edges, LayoutObjective.components(ids, edges))


## Where a stage sits, taken from the nodes already in it.
##
## The median centre of the cohort rather than an evenly spaced grid, because the target is
## the author's own arrangement made consistent — not a fresh one. A stage whose members all
## agree already has a target they are all at, and nothing moves.
static func band_of(boxes: Dictionary, cohort: Array, without: String) -> float:
	var centres: Array = []
	for id: String in cohort:
		if id == without:
			continue
		centres.append((boxes[id] as Rect2).get_center().x)
	if centres.is_empty():
		return INF
	centres.sort()
	return float(centres[centres.size() / 2])


## The stage/flow vector, in the order it is compared.
##
## `boxes` is node id to Rect2, `depth` is node id to stage, `edges` is the connection list
## as [from, to] pairs. Crossings and cable are not in here on purpose: they are watched
## elsewhere and are not what this operation is for.
static func vector(boxes: Dictionary, depth: Dictionary, edges: Array,
		tolerance: float) -> Array:
	var ids: Array = boxes.keys()
	var violations := 0
	for i in ids.size():
		for j in ids.size():
			if i == j:
				continue
			if int(depth[ids[i]]) < int(depth[ids[j]]) \
					and (boxes[ids[j]] as Rect2).get_center().x \
						< (boxes[ids[i]] as Rect2).get_center().x:
				violations += 1

	var backward := 0
	for edge: Array in edges:
		if not boxes.has(edge[0]) or not boxes.has(edge[1]):
			continue
		if (boxes[edge[1]] as Rect2).get_center().x \
				< (boxes[edge[0]] as Rect2).get_center().x:
			backward += 1

	var cohorts := {}
	var centres: Array = []
	for id: String in ids:
		var at: int = depth[id]
		if not cohorts.has(at):
			cohorts[at] = []
		(cohorts[at] as Array).append((boxes[id] as Rect2).get_center().x)
		centres.append((boxes[id] as Rect2).get_center().x)
	var spread := 0
	for at: int in cohorts:
		spread += (LayoutObjective.bands(cohorts[at], tolerance) as Array).size() - 1
	var surplus: int = maxi(0,
		(LayoutObjective.bands(centres, tolerance) as Array).size() - cohorts.size())

	return [violations, backward, spread, surplus]


## Whether one stage/flow vector is better than another. Lexicographic, first difference
## decides, and equal means equal — a move that changes nothing about stage order is not an
## improvement however tidy it looks.
static func better(after: Array, before: Array) -> bool:
	for i in mini(after.size(), before.size()):
		if int(after[i]) == int(before[i]):
			continue
		return int(after[i]) < int(before[i])
	return false


## The horizontal offsets a node is offered, toward its own stage band.
##
## Snapped to the grid, nearest first, and never past the target: overshooting a band to
## improve a count is how a tidy operation starts rearranging.
static func toward(from_centre: float, target: float, grid: float) -> Array:
	if target == INF:
		return []
	var out: Array = []
	var delta := target - from_centre
	if absf(delta) < grid * 0.5:
		return []
	for fraction: float in STEPS:
		var step := snappedf(delta * fraction, grid)
		if absf(step) < grid * 0.5:
			continue
		step = clampf(step, -float(REACH) * grid, float(REACH) * grid)
		step = snappedf(step, grid)
		if not out.has(step):
			out.append(step)
	return out
