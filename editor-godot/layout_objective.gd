class_name LayoutObjective
extends RefCounted

## What an arrangement is supposed to achieve, as a contract rather than as a score.
##
## The layout baseline found that `_auto_place()` answers a different question from the one
## a person asks when they say "make this patch easier to understand": on the hostile graph
## it removes six node overlaps and three trespasses, and pays fifty-one per cent more cable
## and fifty-six per cent more crossings for them. Neither arrangement is wrong. They are
## optimising different things, and nobody had written down which thing arrangement is for.
##
## So, before any algorithm changes:
##
## > **Arrangement has two jobs: legalize the drawing, then improve its readability. Those
## > are not the same optimisation.**
##
## ## Lexicographic, not weighted
##
## Deliberately **not** a single weighted score. A weighted sum has to claim that one
## crossing is worth three hundred and seventeen pixels of cable, or that a fifth of a
## square megaunit of area is worth a backward edge, and nobody believes any of those
## numbers — they are a way of writing down that the question was not answered.
##
## The tiers are ordered and compared in order. The first tier that differs decides, and
## nothing in a lower tier can buy a regression in a higher one:
##
## [codeblock]
## 0  invariants      what the author pinned, and what the document means
## 1  legalization    is the drawing even valid
## 2  readability     can the computation be seen
## 3  route economy   how much cable it costs
## 4  spatial economy how much room it takes
## 5  disturbance     how much of the author's arrangement survived
## [/codeblock]
##
## Which gives the rule a future arranger is held to:
##
## > **Arrangement is monotonic against this contract. Never accept a move that improves a
## > lower tier by worsening a higher one.**
##
## That is the protection against another dense-graph result — an engine that legalizes a
## drawing and destroys its structure on the way past has traded tier 2 for tier 1 without
## anybody deciding it should.
##
## ## What this file does not do
##
## It does not arrange anything. It measures, and it compares two measurements. Whether the
## contract is the *right* contract is a question for the fixtures, not for this file.

## The tiers, and the metrics each is compared on, in the order they are compared.
##
## Every metric here is "smaller is better". A metric that is not gets negated where it is
## computed, so that this table can be read as one rule rather than as a list of exceptions.
const TIERS := [
	{"name": "invariants", "metrics": ["topology_changed", "anchors_moved"]},
	{"name": "legalization", "metrics": ["overlaps", "trespass", "clearance_faults"]},
	{"name": "readability", "metrics": ["stage_violations", "crossings", "backward",
		"stage_spread", "surplus_columns", "fanout_spread"]},
	{"name": "route", "metrics": ["cable_longest", "cable_p90", "cable_total"]},
	{"name": "spatial", "metrics": ["area", "aspect", "whitespace"]},
	{"name": "disturbance", "metrics": ["moved", "displacement_max",
		"displacement_median", "displacement_total"]},
]

## How close two horizontal positions must be to count as one band, as a fraction of the
## median node width. Bands are what a reader calls columns; a definition in absolute units
## would mean something different in a patch of narrow nodes than in a patch of wide ones.
const BAND_FRACTION := 0.5

## A cable in the top decile of length is an outlier and is reported separately, because one
## cable across three quarters of a graph is worse than twenty slightly longer ones and a
## mean cannot say so.
const OUTLIER_DECILE := 0.9


# ---------------------------------------------------------------------------------
# Graph structure
#
# The stages a reader is really looking for are not columns on a grid — they are how far
# through the computation a node is. That is a property of the topology, so it is computed
# from the topology: collapse the feedback loops, then measure depth on what is left.
# ---------------------------------------------------------------------------------

## Strongly connected components, iteratively.
##
## Feedback loops are one unit. A delay feeding back into its own input is not "later than
## itself", and a depth function that tried to say so would either loop forever or pick an
## arbitrary member to be first. Collapsing them is what makes depth well defined.
##
## Iterative Tarjan rather than the recursive one: a patch is small, but a stack overflow in
## a measurement harness is a measurement that stops rather than one that is wrong, and
## those are the expensive kind to diagnose.
static func components(ids: Array, edges: Array) -> Dictionary:
	var out := {}
	for id: String in ids:
		out[id] = -1
	var after := {}
	for id: String in ids:
		after[id] = []
	for edge: Array in edges:
		if after.has(edge[0]) and out.has(edge[1]):
			(after[edge[0]] as Array).append(edge[1])

	var index := {}
	var low := {}
	var on_stack := {}
	var stack: Array = []
	var counter := 0

	for root: String in ids:
		if index.has(root):
			continue
		# Each frame is [node, how many of its successors have been dealt with].
		var work: Array = [[root, 0]]
		index[root] = counter
		low[root] = counter
		counter += 1
		stack.append(root)
		on_stack[root] = true
		while not work.is_empty():
			var frame: Array = work[work.size() - 1]
			var here: String = frame[0]
			var successors: Array = after[here]
			if frame[1] < successors.size():
				var next: String = successors[frame[1]]
				frame[1] += 1
				if not index.has(next):
					index[next] = counter
					low[next] = counter
					counter += 1
					stack.append(next)
					on_stack[next] = true
					work.append([next, 0])
				elif on_stack.get(next, false):
					low[here] = mini(int(low[here]), int(index[next]))
			else:
				work.pop_back()
				if not work.is_empty():
					var above: String = (work[work.size() - 1] as Array)[0]
					low[above] = mini(int(low[above]), int(low[here]))
				if int(low[here]) == int(index[here]):
					var name := "c%d" % int(index[here])
					while true:
						var member: String = stack.pop_back()
						on_stack[member] = false
						out[member] = name
						if member == here:
							break
	return out


## How far through the computation each component is, on the condensation.
##
## Longest path from a source rather than shortest, because a node's stage is decided by the
## deepest thing that reaches it: an oscillator feeding both a filter and the output does not
## make the output stage one.
static func depths(ids: Array, edges: Array, component: Dictionary) -> Dictionary:
	var after := {}
	var incoming := {}
	for id: String in ids:
		var group: String = component[id]
		if not after.has(group):
			after[group] = {}
			incoming[group] = 0
	for edge: Array in edges:
		if not component.has(edge[0]) or not component.has(edge[1]):
			continue
		var from: String = component[edge[0]]
		var to: String = component[edge[1]]
		if from == to or (after[from] as Dictionary).has(to):
			continue
		(after[from] as Dictionary)[to] = true
		incoming[to] = int(incoming[to]) + 1

	var depth := {}
	var ready: Array = []
	for group: String in after:
		depth[group] = 0
		if int(incoming[group]) == 0:
			ready.append(group)
	while not ready.is_empty():
		var here: String = ready.pop_front()
		for next: String in after[here]:
			depth[next] = maxi(int(depth[next]), int(depth[here]) + 1)
			incoming[next] = int(incoming[next]) - 1
			if int(incoming[next]) == 0:
				ready.append(next)

	var out := {}
	for id: String in ids:
		out[id] = int(depth.get(component[id], 0))
	return out


## Horizontal bands, by clustering the centres rather than by snapping them to a grid.
##
## A band is what a reader calls a column: nodes whose horizontal centres are close enough
## together to read as one stage of the drawing. Derived from the gaps between the centres,
## so a patch of narrow nodes and a patch of wide ones are measured by the same rule and not
## by the same number.
static func bands(centres: Array, tolerance: float) -> Array:
	if centres.is_empty():
		return []
	var sorted := centres.duplicate()
	sorted.sort()
	var out: Array = [[sorted[0]]]
	for i in range(1, sorted.size()):
		if float(sorted[i]) - float(sorted[i - 1]) > tolerance:
			out.append([])
		(out[out.size() - 1] as Array).append(sorted[i])
	return out


# ---------------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------------

## Whether `candidate` is a better arrangement than `incumbent`, by the contract.
##
## Returns 1 when the candidate is better, -1 when it is worse, 0 when the two are
## indistinguishable — every metric in every tier equal. The first tier that differs
## decides, and within a tier the first metric that differs decides.
static func compare(candidate: Dictionary, incumbent: Dictionary) -> int:
	for tier: Dictionary in TIERS:
		for metric: String in tier["metrics"]:
			var mine := float(candidate.get(metric, 0.0))
			var theirs := float(incumbent.get(metric, 0.0))
			if absf(mine - theirs) < 0.0001:
				continue
			return 1 if mine < theirs else -1
	return 0


## Which tier two arrangements first differ in, and on which metric. For reporting: "worse,
## and it is a readability regression" is a different sentence from "worse on area".
static func differs_at(candidate: Dictionary, incumbent: Dictionary) -> String:
	for tier: Dictionary in TIERS:
		for metric: String in tier["metrics"]:
			var mine := float(candidate.get(metric, 0.0))
			var theirs := float(incumbent.get(metric, 0.0))
			if absf(mine - theirs) < 0.0001:
				continue
			return "%s / %s" % [str(tier["name"]), metric]
	return "identical"


## The rule a future arranger is held to, as a function rather than as a paragraph.
##
## A move is admissible when it improves some tier and worsens no higher one. Written here
## so that when an algorithm finally exists, the thing it must not do is already spelt.
static func admissible(after: Dictionary, before: Dictionary) -> bool:
	for tier: Dictionary in TIERS:
		for metric: String in tier["metrics"]:
			var mine := float(after.get(metric, 0.0))
			var theirs := float(before.get(metric, 0.0))
			if absf(mine - theirs) < 0.0001:
				continue
			# The first difference in tier order is the deciding one: better means the
			# move is admissible, worse means it has bought a lower tier with a higher.
			return mine < theirs
	return false
