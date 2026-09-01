extends SceneTree

## Routing goal 1.1: makes every crossing-count disagreement explain itself.
##
##   godot --headless --path editor-godot --script crossing_semantics.gd
##
## Goal 1 reported two numbers for the same patch — the cord layer's twenty-six against
## this programme's own enumeration of forty-two, and seven against ten — and could not say
## why. That is not a tolerable thing to carry into an optimiser, because the next goal
## wants to make a crossing count an objective, and an objective nobody can reproduce is a
## way to lose a measurement quietly.
##
## The answer turned out to have two parts, and only the second one is about crossings.
##
## **First, they were not looking at the same drawing.** The editor opens in CATENARY cable
## style. The cord layer draws hanging curves; `_routes()` returns the PCB router's
## polylines. Different vertex counts, different shapes, different meetings. Any comparison
## between them was a category error, and the routing baseline's own figures are figures
## about the router's geometry rather than about the picture on screen.
##
## **Second, on one geometry, two counts remain and both are real.** A mark is a crossing
## treatment the layer paints; a meeting is a place two cables actually cross. They differ
## because `CableArt.crossings` takes the first hit on each segment of the upper cable, so a
## meeting near a vertex is reported twice and a second meeting inside one segment is not
## reported at all. Which number is right depends on the question, so this file reports both
## and names them, and `CableCrossings.tally` is where that naming lives.
##
## No exclusion rule changed here. The traits are described, not enforced.

const PatchGraph := preload("res://patch_graph.gd")
const CableCrossings := preload("res://cable_crossings.gd")

## The renderer's counts before any of this goal's refactoring, from the goal 1 baseline.
## The refactor is only trustworthy if it moved none of them.
const BEFORE := {
	"first-synth": 0, "plucked-string": 1,
	"dense-graph-tidied": 26, "babble-tidied": 7,
}

const FIXTURES := [
	"res://../examples/patches/first-synth.json",
	"res://../examples/patches/plucked-string.json",
	"res://qa/dense-graph-tidied.json",
	"res://qa/babble-tidied.json",
]

var main: Node
var graph: GraphEdit
var layer: Node
var failures: Array = []


func settle(n: int) -> void:
	for i in n:
		await process_frame


## Where the record goes, or empty for "do not write one".
func out_dir() -> String:
	return OS.get_environment("CROSSING_SEMANTICS_OUT")


func check(passed: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if passed else "FAIL", what])
	if not passed:
		failures.append(what)


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	for child in graph.get_children():
		if child.has_method("crossing_sites"):
			layer = child

	var record := {}
	for path: String in FIXTURES:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		var short := path.get_file().get_basename()
		await main._load_text(file.get_as_text())
		await settle(24)
		main._set_roll_open(false)
		graph.zoom = 1.0
		await settle(10)

		print("")
		print("%s" % short)

		# The style the editor actually opens in, and the style the router's own
		# representation describes. Asked separately and never averaged.
		var drawn: Array = layer._lay()
		var drawn_hits := CableCrossings.classify(drawn)
		var drawn_tally := CableCrossings.tally(drawn_hits)

		var was: int = graph.cable_style
		graph.cable_style = 1                     # PCB, the routed geometry
		await settle(6)
		var routed: Array = layer._lay()
		var routed_hits := CableCrossings.classify(routed)
		var routed_tally := CableCrossings.tally(routed_hits)
		graph.cable_style = was
		await settle(6)

		print("  geometry     catenary %d cables / %d verts, routed %d cables / %d verts"
			% [drawn.size(), _verts(drawn), routed.size(), _verts(routed)])
		print("  as drawn     %d marks, %d meetings, %d raw intersections"
			% [drawn_tally["marks"], drawn_tally["meetings"],
				drawn_tally["intersections"]])
		print("  as routed    %d marks, %d meetings, %d raw intersections"
			% [routed_tally["marks"], routed_tally["meetings"],
				routed_tally["intersections"]])
		print("  excluded     drawn %s, routed %s"
			% [str(drawn_tally["excluded"]), str(routed_tally["excluded"])])
		print("  traits       drawn %s" % [str(_traits(drawn_hits))])
		print("               routed %s" % [str(_traits(routed_hits))])

		# The refactor's own acceptance: the renderer counts what it counted before, and
		# the shared classifier and the renderer cannot disagree, because they are now the
		# same call. Checked anyway — "they are the same code" is a claim about the code,
		# and this programme has been wrong about that before.
		var sites: int = (layer.crossing_sites() as Array).size()
		check(sites == int(BEFORE.get(short, -1)),
			"%s still counts %d crossings" % [short, int(BEFORE.get(short, -1))])
		check(sites == int(drawn_tally["marks"]),
			"and the layer and the classifier agree on it (%d/%d)"
				% [sites, drawn_tally["marks"]])
		check(int(main._layout_crossings()) == sites,
			"and so does the number layout optimises against")

		# Goal 1 guessed that babble's three near-terminal meetings were socket congestion.
		# They are something else, and the difference matters: a cable converging on the
		# same node as another by a different port is not fighting for a corridor.
		var converging := _converging(drawn_hits)
		var converging_routed := _converging(routed_hits)
		print("  converging   %d of %d drawn, %d of %d routed"
			% [converging, drawn_tally["meetings"], converging_routed,
				routed_tally["meetings"]])

		record[short] = {
			"as_drawn": drawn_tally, "as_routed": routed_tally,
			"cable_style_at_open": was, "converging": converging,
			"converging_routed": converging_routed,
			"routed_meetings": _listing(routed_hits),
			"layer_sites": sites,
			"meetings": _listing(drawn_hits),
		}

	# The record is written where it is asked for and nowhere else. This file is on the
	# push gate as well as being a proof, and a gate that leaves an untracked artefact in
	# the source tree every time it runs is a gate people start ignoring.
	var folder := out_dir()
	if folder != "":
		DirAccess.make_dir_recursive_absolute(folder)
		var out := FileAccess.open(folder.path_join("crossing-semantics.json"),
			FileAccess.WRITE)
		out.store_string(JSON.stringify(record, "  "))
		out.close()
		print("")
		print("-> %s" % folder.path_join("crossing-semantics.json"))
	print("")
	if failures.is_empty():
		print("all crossing semantics checks passed")
	else:
		print("%d checks failed" % failures.size())
	quit(0 if failures.is_empty() else 1)


func _verts(cords: Array) -> int:
	var total := 0
	for cord: Array in cords:
		total += (cord[0] as PackedVector2Array).size()
	return total


## Rendered meetings whose two cables end at the same node by different ports.
func _converging(hits: Array) -> int:
	var found := 0
	for hit: Dictionary in hits:
		if not bool(hit["rendered"]) or bool(hit["coincident_with_earlier"]):
			continue
		if (hit["traits"] as Array).has("converging"):
			found += 1
	return found


func _traits(hits: Array) -> Dictionary:
	var seen := {}
	for hit: Dictionary in hits:
		for name: String in hit["traits"]:
			seen[name] = int(seen.get(name, 0)) + 1
	return seen


## Every intersection, whether or not anything draws it. The record this goal exists to
## produce: a reader can take any disagreement about a crossing count to this listing and
## find the row that explains it.
func _listing(hits: Array) -> Array:
	var rows: Array = []
	for hit: Dictionary in hits:
		rows.append({
			"over": hit["over"], "under": hit["under"],
			"at": [snappedf((hit["at"] as Vector2).x, 0.1),
				snappedf((hit["at"] as Vector2).y, 0.1)],
			"angle": hit["angle"],
			"from_over_end": hit["from_over_end"],
			"from_under_end": hit["from_under_end"],
			"rendered": hit["rendered"], "reason": hit["reason"],
			"traits": hit["traits"],
			"seen_by_cable_art": hit["seen_by_cable_art"],
			"coincident_with_earlier": hit["coincident_with_earlier"],
		})
	return rows
