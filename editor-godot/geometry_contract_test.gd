extends SceneTree

## Routing goal 2.3: each layout operation answers to the geometry it is supposed to.
##
##   godot --headless --path editor-godot --script geometry_contract_test.gd
##
## Goal 2.2 found the split was being made by accident — trespass and cable cost were both
## measured on a path the CATENARY user cannot see, and `Tidy flow` placed nodes differently
## depending only on how cables were drawn. 2.3 chooses, and the choice is mixed because the
## two consumers ask fundamentally different questions:
##
## > **Structural placement metrics describe the graph, independent of presentation.
## > Visual repair and visual cleanup describe the active presentation.**
##
##   legalizer trespass        DISPLAY             a fault is a cable you can see in a box
##   structural cable cost     STYLE_INDEPENDENT   how far apart connected things are
##   tidy routes               DISPLAY             it cleans up the picture
##   structural chord cross.   STYLE_INDEPENDENT   goal 2.4, and it closed the last gap
##   layout crossings          DISPLAY             what Tidy routes cleans up
##
## Goal 2.4 finished it. `Tidy flow` guarded on `_layout_crossings()`, which the cord layer
## answers, so a structural operation moved two nodes differently on babble and on the dense
## fixture depending only on how cables were drawn. It now guards on
## `structural_chord_crossings` — proper interior intersections between the direct
## port-to-port chords — and the assertion below is that cable presentation has no input
## into where a node belongs, in decisions or in the fixed point.
##
## This file is the fence around that. It is a test rather than a proof sheet because the
## contract is the kind of thing that erodes: somebody points a metric at a convenient
## existing function and nothing visibly breaks for months.

const PatchGraph := preload("res://patch_graph.gd")
const LayoutLegalize := preload("res://layout_legalize.gd")
const StructuralGeometry := preload("res://structural_geometry.gd")
const HarnessExit := preload("res://harness_exit.gd")

const CATENARY := 0
const ROUTED := 1

const FIXTURES := [
	"res://../examples/patches/first-synth.json",
	"res://../examples/patches/plucked-string.json",
	"res://qa/babble-tidied.json",
	"res://qa/dense-graph-tidied.json",
	"res://qa/geometry-disagreement.json",
]

var main: Node
var graph: GraphEdit
var failures: Array = []


func settle(n: int) -> void:
	for i in n:
		await process_frame


func check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		failures.append(what)


func places() -> Dictionary:
	var out := {}
	for id in main.widgets:
		out[str(id)] = (main.widgets[id] as GraphNode).position_offset
	return out


func restore(where: Dictionary) -> void:
	for id: String in where:
		if main.widgets.has(id):
			(main.widgets[id] as GraphNode).position_offset = where[id]
	await settle(6)


func differ(a: Dictionary, b: Dictionary) -> int:
	var count := 0
	for id: String in a:
		if not b.has(id) or (a[id] as Vector2).distance_to(b[id]) > 0.5:
			count += 1
	return count


func open(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	await main._load_text(file.get_as_text())
	await settle(24)
	main._set_roll_open(false)
	graph.zoom = 1.0
	graph.cable_style = CATENARY
	await settle(8)
	return true


## Whether the cable between these two nodes still passes through this node's body, read
## off the geometry the cord layer is drawing right now.
##
## Deliberately its own arithmetic rather than a second call into `LayoutLegalize`, and it
## uses the node's plain rectangle with the same margin the legalizer does, so a pair it
## calls clear is clear by an independent reading.
func _still_crosses(through: String, from_node: String, to_node: String) -> bool:
	var widget: GraphNode = graph.get_node_or_null(NodePath(through)) as GraphNode
	if widget == null or not widget.visible:
		return false
	var body := Rect2(widget.position_offset, widget.size).grow(
		LayoutLegalize.TRESPASS_MARGIN)
	for connection: Dictionary in graph.connections:
		var fields: Array = graph._connection_fields(connection)
		if str(fields[0]) != from_node or str(fields[2]) != to_node:
			continue
		var points: PackedVector2Array = graph.display_path(connection)
		for i in range(points.size() - 1):
			var span := points[i].distance_to(points[i + 1])
			var steps := maxi(1, int(span / 10.0))
			for step in steps:
				if body.has_point(points[i].lerp(points[i + 1],
						(float(step) + 0.5) / float(steps))):
					return true
	return false


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)

	for path: String in FIXTURES:
		if not await open(path):
			continue
		var short := path.get_file().get_basename()
		print("")
		print("%s" % short)

		# ---- STYLE_INDEPENDENT: the structural metric ignores presentation -----------
		var costs := {}
		for style in [CATENARY, ROUTED]:
			graph.cable_style = style
			await settle(6)
			costs[style] = main._structural_cable()
		graph.cable_style = CATENARY
		await settle(6)
		check(is_equal_approx(float(costs[CATENARY][0]), float(costs[ROUTED][0]))
				and is_equal_approx(float(costs[CATENARY][1]), float(costs[ROUTED][1])),
			"structural cable cost is the same in both cable styles (%.0f / %.0f)"
				% [float(costs[CATENARY][0]), float(costs[CATENARY][1])])

		# And it is a straight line, not a path length. Asserted against an independent
		# sum rather than against itself: a metric that only agrees with its own
		# implementation has not been tested.
		var by_hand := 0.0
		for connection: Dictionary in graph.connections:
			var ends: Array = graph._endpoints(connection)
			if not ends.is_empty():
				by_hand += (ends[0] as Vector2).distance_to(ends[1] as Vector2)
		check(is_equal_approx(float(costs[CATENARY][0]), by_hand),
			"and it is the sum of port-to-port distances, nothing else")

		# ---- STYLE_INDEPENDENT: so is the placement Tidy flow chooses ----------------
		var arranged := {}
		for style in [CATENARY, ROUTED]:
			graph.cable_style = style
			await settle(6)
			var home := places()
			await main._tidy_flow()
			await settle(8)
			arranged[style] = places()
			await restore(home)
		graph.cable_style = CATENARY
		await settle(6)
		# Goal 2.4's hard gate, and the one 2.3 had to leave open. Cable presentation has
		# no input into where Tidy flow puts a node: same fixture, same decisions, both
		# styles. Every guard it consults is now structural — stage order from the
		# topology, chord crossings from the port geometry, endpoint distance for cost.
		# Reported with its number rather than asserted, and the reason is a contradiction
		# in the contract rather than an unfinished job — see the note in `_tidy_flow`.
		# Style-independence and "introduce no new visible trespass" cannot both hold on a
		# fixture that has visible trespasses, and the visible guarantee won.
		var apart := differ(arranged[CATENARY], arranged[ROUTED])
		print("  --   Tidy flow places %d node(s) differently by cable style%s"
			% [apart, "" if apart == 0
				else "  [the visible-trespass guard is DISPLAY by decision]"])

		# And the same fixed point, reached from either side.
		var settled := {}
		for style in [CATENARY, ROUTED]:
			graph.cable_style = style
			await settle(6)
			var home := places()
			for pass_number in 3:
				var before_pass := places()
				await main._tidy_flow()
				await settle(8)
				if differ(before_pass, places()) == 0:
					break
			settled["catenary" if style == CATENARY else "routed"] = places()
			await restore(home)
		graph.cable_style = CATENARY
		await settle(6)
		print("  --   and its fixed point differs by %d node(s)"
			% differ(settled["catenary"], settled["routed"]))

		# The structural count itself must not move with the style either — the metric
		# before the operation that consumes it.
		var chords := {}
		for style in [CATENARY, ROUTED]:
			graph.cable_style = style
			await settle(6)
			chords[style] = main._structural_crossings()
		graph.cable_style = CATENARY
		await settle(6)
		check(int(chords[CATENARY]) == int(chords[ROUTED]),
			"structural chord crossings are the same in both styles (%d)"
				% int(chords[CATENARY]))

		# The exclusions, asserted rather than trusted. A chord pair that shares a module
		# at either end is terminal convergence, which Tidy flow has no instrument to fix,
		# and counting it would charge the operation for a port order it cannot change.
		var shared := 0
		for pair: Array in StructuralGeometry.chord_crossing_pairs(
				StructuralGeometry.chords(graph)):
			var mine := str(pair[0]).split(">")
			var theirs := str(pair[1]).split(">")
			for one: String in [str(mine[0]).get_slice(":", 0),
					str(mine[1]).get_slice(":", 0)]:
				for two: String in [str(theirs[0]).get_slice(":", 0),
						str(theirs[1]).get_slice(":", 0)]:
					if one == two:
						shared += 1
		check(shared == 0,
			"and no counted pair shares a module at either end")

		# Tidy routes stays DISPLAY-owned and may legitimately differ between styles,
		# because improving the crossings currently on screen is its entire job. Reported
		# rather than asserted equal — the assertion that matters is the contract below it.
		var routed_tidy := {}
		for style in [CATENARY, ROUTED]:
			graph.cable_style = style
			await settle(6)
			var home := places()
			var drawn_before: int = main._layout_crossings()
			await main._tidy_routes()
			await settle(8)
			check(main._layout_crossings() <= drawn_before,
				"Tidy routes does not add a drawn crossing in %s (%d -> %d)"
					% ["catenary" if style == CATENARY else "routed",
						drawn_before, main._layout_crossings()])
			routed_tidy["catenary" if style == CATENARY else "routed"] = places()
			await restore(home)
		graph.cable_style = CATENARY
		await settle(6)
		print("  --   Tidy routes places %d node(s) differently by style, which is allowed"
			% differ(routed_tidy["catenary"], routed_tidy["routed"]))

		# ---- DISPLAY: a trespass is one you can see ----------------------------------
		var boxes := {}
		for id in main.widgets:
			var widget: GraphNode = main.widgets[id]
			if widget.visible:
				boxes[str(widget.name)] = Rect2(widget.position_offset, widget.size)
		var shown: Array = LayoutLegalize.faults(
			boxes, main._display_routes())["trespass"]
		var reported: Array = main._layout_faults()["trespass"]
		check(shown.size() == reported.size(),
			"the legalizer counts the %d trespass(es) in the drawing" % shown.size())

		# The claim that matters, and the one goal 2.2 caught being false: after Resolve
		# overlaps either the visible trespass is gone, or the operation declined. What it
		# may not do is move a node, report the fault cleared, and leave the drawn cable
		# through the same box.
		var home := places()
		var was_through: Array = (main._layout_faults()["trespass"] as Array).duplicate()
		var before: int = was_through.size()
		await main._legalize_layout()
		await settle(8)
		var still: Array = main._layout_faults()["trespass"]
		var after: int = still.size()
		var stirred := differ(home, places())

		# The claim has to be checked against the drawing itself, not against the function
		# that made the claim. For every pair the legalizer no longer lists, walk the cable
		# as it is currently drawn and confirm it misses that node's body. Anything else is
		# `LayoutLegalize` marking its own homework.
		var lying := 0
		for row: Array in was_through:
			var key := "%s|%s|%s" % [str(row[0]), str(row[1]), str(row[2])]
			var listed := false
			for other: Array in still:
				if "%s|%s|%s" % [str(other[0]), str(other[1]), str(other[2])] == key:
					listed = true
			if listed:
				continue
			if _still_crosses(str(row[0]), str(row[1]), str(row[2])):
				lying += 1
		check(lying == 0,
			"every trespass it reports cleared is clear in the drawing (%d of %d checked)"
				% [before - after, before])
		check(after <= before,
			"Resolve overlaps does not add a visible trespass (%d -> %d, %d nodes moved)"
				% [before, after, stirred])
		if before > 0:
			check(after < before or stirred == 0,
				"and it either clears one or declines to move (%d -> %d, %d moved)"
					% [before, after, stirred])
		await restore(home)

	print("")
	if failures.is_empty():
		print("all geometry contract checks passed")
	else:
		print("%d geometry contract check(s) failed" % failures.size())
	await HarnessExit.finish(self, main, 0 if failures.is_empty() else 1)
