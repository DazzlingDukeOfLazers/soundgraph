extends SceneTree

## Step 1 of the layout pass: what the arrangement is, before anything is changed.
##
## The third time this programme has started this way, and the first two both paid for it —
## the node baseline settled what a node was before it was redrawn, and the cable baseline
## contradicted three of seven assumptions before a line was drawn. So: measure.
##
##   godot --path editor-godot --script layout_baseline.gd
##
## with LAYOUT_BASELINE_OUT naming a directory for the JSON.
##
## ## The question
##
## > Can SoundGraph arrange a patch so its computation is visually obvious before the user
## > cleans it up by hand?
##
## Which is answerable only against a comparison, so every patch is measured twice: as its
## author left it, and as `_auto_place()` arranges it. `Layout.arrange` already exists, is
## deterministic, weights audio edges more heavily than control ones, and honours anchors.
## Whether it is better than a hand arrangement is the thing nobody has measured.
##
## ## What it does not do
##
## It does not arrange anything permanently and it does not judge. Every figure is
## descriptive. A baseline that arrived with its conclusions in it would be a baseline
## nobody could disagree with, and the last two both changed the plan they were made for.

const PatchGraph := preload("res://patch_graph.gd")

const PATCHES := [
	"res://qa/dense-graph.json",
	"res://../examples/patches/first-synth.json",
	"res://../examples/patches/plucked-string.json",
	"res://../examples/patches/babble.json",
]

var main: Node
var graph: GraphEdit
var cords: CanvasItem


func out_dir() -> String:
	var asked := OS.get_environment("LAYOUT_BASELINE_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func length_of(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## Everything measurable about one arrangement, in document units so two arrangements of
## the same patch are comparable.
func measure() -> Dictionary:
	var boxes := {}
	var box := Rect2()
	var first := true
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget == null or not widget.visible:
			continue
		var own := Rect2(widget.position_offset, widget.size)
		boxes[str(widget.name)] = own
		box = own if first else box.merge(own)
		first = false

	# ---- how much cable the arrangement costs --------------------------------------
	var lengths: Array = []
	var backward := 0
	var backward_span := 0.0
	var routes: Array = graph._routes()
	for route: Dictionary in routes:
		var points: PackedVector2Array = route["points"]
		if points.size() < 2:
			continue
		lengths.append(length_of(points))
		# Flow. A patch reads left to right, so a cable that ends left of where it began
		# is asking the eye to go backwards — which is the thing a long modulation route
		# across a graph actually costs.
		var from: Vector2 = points[0]
		var to: Vector2 = points[points.size() - 1]
		if to.x < from.x:
			backward += 1
			backward_span += from.x - to.x
	lengths.sort()

	# ---- how much the arrangement makes the cables do ------------------------------
	var crossings: int = (cords.crossing_sites() as Array).size()

	# ---- nodes standing on each other ----------------------------------------------
	var overlaps := 0
	var names: Array = boxes.keys()
	for i in names.size():
		for j in range(i + 1, names.size()):
			if (boxes[names[i]] as Rect2).intersects(boxes[names[j]] as Rect2):
				overlaps += 1

	# ---- and cables through territory they have no business in ----------------------
	var trespass := 0
	for route: Dictionary in routes:
		var points: PackedVector2Array = route["points"]
		for id: String in boxes:
			if id == str(route["fields"][0]) or id == str(route["fields"][2]):
				continue
			var grown: Rect2 = (boxes[id] as Rect2).grow(6.0)
			var inside := false
			for i in range(points.size() - 1):
				var span := points[i].distance_to(points[i + 1])
				var steps := maxi(1, int(span / 10.0))
				for s in steps:
					if grown.has_point(points[i].lerp(points[i + 1],
							(float(s) + 0.5) / float(steps))):
						inside = true
						break
				if inside:
					break
			if inside:
				trespass += 1

	# ---- columns -------------------------------------------------------------------
	# How far the arrangement is from being a set of columns at all, which is what a
	# reader means by "the signal goes this way". Measured as the number of distinct left
	# edges once they are snapped to a tolerance, against the number of nodes.
	var columns := {}
	for id: String in boxes:
		columns[int(roundf((boxes[id] as Rect2).position.x / 80.0))] = true

	var total := 0.0
	for one: float in lengths:
		total += one
	return {
		"nodes": boxes.size(),
		"extent": [snappedf(box.size.x, 0.1), snappedf(box.size.y, 0.1)],
		"area": snappedf(box.size.x * box.size.y / 1000000.0, 0.001),
		"cables": lengths.size(),
		"cable_total": snappedf(total, 0.1),
		"cable_median": snappedf(lengths[lengths.size() / 2] if not lengths.is_empty()
			else 0.0, 0.1),
		"cable_longest": snappedf(lengths[lengths.size() - 1] if not lengths.is_empty()
			else 0.0, 0.1),
		"crossings": crossings,
		"backward": backward,
		"backward_span": snappedf(backward_span, 0.1),
		"forward_fraction": snappedf(1.0 - float(backward)
			/ maxf(float(lengths.size()), 1.0), 0.001),
		"overlaps": overlaps,
		"trespass": trespass,
		"columns": columns.size(),
	}


func open_patch(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	await main._load_text(file.get_as_text())
	await settle(24)
	main._set_roll_open(false)
	graph.zoom = 1.0
	await settle(10)


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
			cords = child

	var record := {}
	for path: String in PATCHES:
		await open_patch(path)
		if main.patch.get("nodes", []).is_empty():
			continue
		var short := path.get_file().get_basename()
		var by_hand := measure()
		var before := {}
		for node: Dictionary in main.patch.get("nodes", []):
			before[str(node["id"])] = Vector2(
				float(node.get("position", {}).get("x", 0.0)),
				float(node.get("position", {}).get("y", 0.0)))
		# The same patch as the layout engine would have it. Deterministic — the same
		# graph always lands the same way — so this is a property of the patch and not of
		# where anything happened to be first.
		await main._auto_place()
		await settle(24)
		var by_engine := measure()
		# How many nodes the engine actually moved. A patch where the answer is zero is
		# either already at the engine's fixed point or was never arranged at all, and
		# those are very different findings to report as "+0% on everything".
		var moved := 0
		for node: Dictionary in main.patch.get("nodes", []):
			var was: Vector2 = before.get(str(node["id"]), Vector2.ZERO)
			var now := Vector2(float(node.get("position", {}).get("x", 0.0)),
				float(node.get("position", {}).get("y", 0.0)))
			if was.distance_to(now) > 0.5:
				moved += 1
		by_engine["moved"] = moved
		by_hand["moved"] = 0
		record[short] = {"hand": by_hand, "auto": by_engine}

	print("")
	var columns := ["nodes", "cables", "cable_total", "cable_median", "cable_longest",
		"crossings", "backward", "forward_fraction", "overlaps", "trespass", "columns",
		"area", "moved"]
	for short: String in record:
		print("%s" % short)
		print("  %-18s %14s %14s %10s" % ["", "by hand", "auto-place", "change"])
		for key: String in columns:
			var hand: float = float(record[short]["hand"][key])
			var auto: float = float(record[short]["auto"][key])
			var change := ""
			if hand != 0.0:
				change = "%+.0f%%" % ((auto / hand - 1.0) * 100.0)
			elif auto != 0.0:
				change = "new"
			print("  %-18s %14.3f %14.3f %10s" % [key, hand, auto, change])
		print("  %-18s %14s %14s" % ["extent",
			str(record[short]["hand"]["extent"]), str(record[short]["auto"]["extent"])])
		print("")

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	var out := FileAccess.open(folder.path_join("layout-baseline.json"),
		FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()
	print("-> %s" % folder.path_join("layout-baseline.json"))
	quit()
