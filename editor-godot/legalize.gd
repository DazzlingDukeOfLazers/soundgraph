extends SceneTree

## Layout goal 2: the nearest fully legal version of the hostile authored patch.
##
## A **legalization witness**, not a layout algorithm. Goal 1 found that three of four
## arrangement comparisons never reach the readability tier at all — the verdict is settled
## at legalization and the interesting figures are never consulted — so nothing can be
## learned about readability by comparing arrangements of different legality.
##
## The fix is a third arrangement that is legal and otherwise unchanged:
##
## [codeblock]
## dense hand        6 overlaps, 3 trespasses, and the best readability of the three
## dense legalized   0 and 0, and as close to the hand arrangement as that allows
## dense auto        0 and 0, and 29 nodes relocated a median of 1330 units
## [/codeblock]
##
## With all three legal, the comparison finally reaches tier 2, and the difference between
## the second and the third is **the price the current arranger pays beyond what legality
## actually costs.**
##
##   godot --path editor-godot --script legalize.gd
##
## writes `qa/dense-graph-legalized.json` beside its source.
##
## ## The one objective
##
## [codeblock]
## overlaps    0
## trespass    0
## clearance   0
## [/codeblock]
##
## Everything else is collateral to be measured and **not** an objective to improve. No
## column optimisation, no crossing minimisation, no stage correction, no cable shortening,
## no area tightening. Those are later goals and doing any of them here would destroy the
## measurement this fixture exists to make.
##
## Among the ways to be legal, disturbance breaks the tie: fewest nodes moved, then least
## total displacement, then least worst displacement. That is a **fixture-generation** rule
## and not the production objective — it exists to answer one question, which is what the
## authored graph looks like after paying about the minimum possible price for legality.
##
## Moves are kept local on purpose. Only nodes that are themselves in an overlap or are
## crossed by a cable may move; a node that enters the movable set for any other reason is
## recorded with the reason, because "we had to move an innocent node" is a finding.
##
## And `admissible()` deliberately does **not** constrain these moves against tier 2. If a
## move that clears an overlap adds a crossing, that crossing is exactly the evidence this
## fixture exists to collect: the unavoidable readability cost of becoming legal, as
## distinct from the gratuitous cost of an arrangement strategy.

const PatchGraph := preload("res://patch_graph.gd")
const SOURCE := "res://qa/dense-graph.json"
const TARGET := "qa/dense-graph-legalized.json"

## The grid the rest of the layout is built on, from main.gd. A legalization that lands
## nodes off it would be a fixture nobody could hand-edit afterwards.
const GRID := 40.0

## How far a node may be nudged, in grid steps, and in how many directions. Small first:
## the objective is the nearest legal arrangement, so a search that tries a long move before
## a short one would find a legal answer and the wrong one.
const RADII := [1, 2, 3, 4, 6, 8, 11, 15]
## And how far it may be nudged once the short moves have all failed. A wedge between two
## tall nodes cannot always be undone inside six hundred units, and the alternative to
## reaching further is a fixture that is still illegal — which is the one thing this file
## may not produce.
const RADII_FAR := [20, 26, 33, 42, 54, 70]
## Four, not eight. Up, down, left and right is what a person means by nudging a node out
## of the way, and a diagonal is two nudges dressed as one.
const DIRECTIONS := 4

## Clearance a node keeps from its neighbours, and how close a cable may pass to a body it
## does not belong to. Both from `layout_baseline.gd`, so the fixture is legal by the same
## measure that will score it.
const CLEARANCE := 24.0
const TRESPASS_MARGIN := 6.0

var main: Node
var graph: GraphEdit

func settle(n: int) -> void:
	for i in n:
		await process_frame


## Every tier-1 fault in the arrangement the widgets are currently standing in.
##
## Measured from `graph._routes()`, which is the router's own answer, and **not** from a
## straight line between two ports. That distinction cost this file its first draft: the
## cable router avoids obstacles, so a trial evaluated against an unrouted path reported
## twenty-six trespasses where the drawing has three. Reimplementing the router to make the
## search cheap would be a second implementation of the thing being measured — the mistake
## this repository keeps catching — so a trial is applied, drawn and asked instead.
func faults() -> Dictionary:
	var boxes := {}
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget != null and widget.visible:
			boxes[str(widget.name)] = Rect2(widget.position_offset, widget.size)

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
	for route: Dictionary in graph._routes():
		var points: PackedVector2Array = route["points"]
		for id: String in ids:
			if id == str(route["fields"][0]) or id == str(route["fields"][2]):
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
				trespass.append([id, str(route["fields"][0]), str(route["fields"][2])])
	return {"overlaps": overlaps, "clearance": clearance, "trespass": trespass,
		"total": overlaps.size() + clearance.size() + trespass.size()}


## Puts one node somewhere and lets the router see it.
func place(id: String, at: Vector2) -> void:
	var widget: GraphNode = graph.get_node_or_null(NodePath(id)) as GraphNode
	if widget != null:
		widget.position_offset = at
	await process_frame


## Who is allowed to move, and why.
##
## Only nodes that are themselves in a fault. A trespass implicates the node being crossed
## first; the two endpoints of the offending cable are admitted only when moving the crossed
## node cannot clear it, and that admission is recorded — moving an innocent node is a
## finding rather than a step.
func implicated(found: Dictionary, desperate: bool) -> Dictionary:
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


func here() -> Dictionary:
	var at := {}
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget != null and widget.visible:
			at[str(widget.name)] = widget.position_offset
	return at


func disturbance(at: Dictionary, home: Dictionary) -> Array:
	var moved := 0
	var total := 0.0
	var worst := 0.0
	for id: String in at:
		var distance: float = (home[id] as Vector2).distance_to(at[id])
		if distance > 0.5:
			moved += 1
			total += distance
			worst = maxf(worst, distance)
	return [moved, total, worst]


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	var file := FileAccess.open(SOURCE, FileAccess.READ)
	var source := file.get_as_text()
	await main._load_text(source)
	await settle(24)
	main._set_roll_open(false)
	graph.zoom = 1.0
	await settle(10)

	var home := here()
	var start := faults()
	print("")
	print("hostile patch: %d overlaps, %d clearance, %d trespasses"
		% [(start["overlaps"] as Array).size(), (start["clearance"] as Array).size(),
			(start["trespass"] as Array).size()])

	# ---- the search -----------------------------------------------------------------
	# Greedy, shortest move first, one node at a time, first improvement rather than best.
	# Not because greedy is optimal — it is not — but because the objective is "about the
	# minimum price for legality", and a search that weighed long moves against short ones
	# would find a legal answer further from the author's arrangement than it needed to be.
	var reasons := {}
	var seen := {}
	var plateaus := 0
	var rounds := 0
	while rounds < 120:
		var found := faults()
		if int(found["total"]) == 0:
			break
		rounds += 1
		var taken := false
		# Two passes on strict improvement, then a third that will accept an equal count.
		#
		# The plateau step is what gets a greedy search out of a wedge. Without it this
		# stopped at nine rounds with one overlap left: no single node could move in any of
		# four directions, at any radius out to six hundred units, without creating a fault
		# somewhere else. Two nodes pinned against each other is a local minimum, and the
		# way past it is to accept a sideways move and try again. Capped, and positions
		# already visited are refused, so it cannot walk in a circle.
		for attempt in 3:
			var desperate: bool = attempt > 0
			# The last pass reaches much further and will accept a sideways move, which
			# is what gets a greedy search out of a wedge between two tall nodes.
			var plateau: bool = attempt == 2
			var movable := implicated(found, desperate)
			var reach: Array = RADII_FAR if attempt == 2 else RADII
			for radius: int in reach:
				for step in DIRECTIONS:
					for id: String in movable:
						var angle := TAU * float(step) / float(DIRECTIONS)
						var was: Vector2 = graph.get_node(NodePath(id)).position_offset
						var trial := (was + Vector2(cos(angle), sin(angle))
							* float(radius) * GRID).snappedf(GRID)
						var visited := "%s@%.0f,%.0f" % [id, trial.x, trial.y]
						if seen.has(visited):
							continue
						await place(id, trial)
						var now := int(faults()["total"])
						if now < int(found["total"]) or (plateau
								and now == int(found["total"]) and plateaus < 8):
							if plateau and now == int(found["total"]):
								plateaus += 1
								seen[visited] = true
							if not reasons.has(id):
								reasons[id] = str(movable[id])
							taken = true
							break
						await place(id, was)
					if taken:
						break
				if taken:
					break
			if taken:
				break
		if not taken:
			print("  stuck after %d rounds, %d faults left"
				% [rounds, int(found["total"])])
			for pair: Array in found["overlaps"]:
				print("    wedged: %s and %s" % [str(pair[0]), str(pair[1])])
			for one: Array in found["trespass"]:
				print("    %s still crossed by %s to %s"
					% [str(one[0]), str(one[1]), str(one[2])])
			break

	var ended := faults()
	var at := here()
	var spent := disturbance(at, home)
	print("%d rounds: %d overlaps, %d clearance, %d trespasses left"
		% [rounds, (ended["overlaps"] as Array).size(),
			(ended["clearance"] as Array).size(), (ended["trespass"] as Array).size()])
	print("  %d nodes moved, %.0f units in total, %.0f at worst"
		% [int(spent[0]), float(spent[1]), float(spent[2])])
	for id: String in reasons:
		var distance: float = (home[id] as Vector2).distance_to(at[id])
		if distance > 0.5:
			print("    %-6s %6.0f units — %s" % [id, distance, str(reasons[id])])

	# ---- the fixture ----------------------------------------------------------------
	# The same document with new positions and nothing else. Written from the source text
	# rather than from the editor's in-memory patch, so no round trip through the schema
	# can quietly add or drop a field.
	var document: Dictionary = JSON.parse_string(source)
	document["metadata"]["name"] = "Dense QA, legalized"
	document["metadata"]["description"] = "The hostile QA patch with its tier-one faults cleared and nothing else changed. Derived by editor-godot/legalize.gd, which minimises disturbance and optimises nothing: no column tidying, no crossing reduction, no stage correction, no cable shortening, no area tightening. It exists so that the hand arrangement, the minimally legal one and auto-place can be compared at the readability tier, which a comparison against an illegal arrangement never reaches."
	# Through each widget's own , because a widget is not named after the node it
	# draws: the widgets are n0..n29 and the document says clk, keys, saw. Keying by widget
	# name matched nothing and produced a fixture byte-identical to its source; going via
	#  matched the wrong nodes and permuted twenty-four positions. The meta the
	# builder puts on the widget is the one answer that cannot be a coincidence.
	var by_document := {}
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget == null or not widget.visible:
			continue
		var patch_id := str(widget.get_meta("patch_id", ""))
		if patch_id != "" and at.has(str(widget.name)):
			by_document[patch_id] = at[str(widget.name)]
	var written := 0
	for node: Dictionary in document["nodes"]:
		var id := str(node["id"])
		if by_document.has(id):
			var to: Vector2 = by_document[id]
			node["position"] = {"x": to.x, "y": to.y}
			written += 1
	print("  %d of %d node positions written" % [written, (document["nodes"] as Array).size()])
	var out := FileAccess.open(
		ProjectSettings.globalize_path("res://").path_join(TARGET), FileAccess.WRITE)
	out.store_string(JSON.stringify(document, "  "))
	out.close()
	print("-> %s" % TARGET)
	quit()
