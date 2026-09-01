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
const HarnessExit := preload("res://harness_exit.gd")

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


## Everything the objective contract asks about one arrangement, in document units so two
## arrangements of the same patch are comparable.
##
## `was` maps node id to its previous top-left corner, for the disturbance tier. Empty for
## an arrangement measured on its own.
func measure(was: Dictionary = {}) -> Dictionary:
	var boxes := {}
	var box := Rect2()
	var covered := 0.0
	var widths: Array = []
	var first := true
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget == null or not widget.visible:
			continue
		var own := Rect2(widget.position_offset, widget.size)
		boxes[str(widget.name)] = own
		widths.append(own.size.x)
		covered += own.size.x * own.size.y
		box = own if first else box.merge(own)
		first = false
	widths.sort()
	var median_width: float = widths[widths.size() / 2] if not widths.is_empty() else 240.0

	# ---- tiers 2 and 3: what the arrangement makes the cables do --------------------
	var lengths: Array = []
	var backward := 0
	var routes: Array = graph._routes()
	var edges: Array = []
	var fan := {}
	for route: Dictionary in routes:
		var points: PackedVector2Array = route["points"]
		if points.size() < 2:
			continue
		lengths.append(length_of(points))
		edges.append([str(route["fields"][0]), str(route["fields"][2])])
		var from: Vector2 = points[0]
		var to: Vector2 = points[points.size() - 1]
		if to.x < from.x:
			backward += 1
		var port := "%s:%d" % [str(route["fields"][0]), int(route["fields"][1])]
		if not fan.has(port):
			fan[port] = []
		(fan[port] as Array).append(str(route["fields"][2]))
	lengths.sort()

	# A fan-out is one source feeding several places and should read as a family. How far
	# apart its destinations sit is what decides whether it does.
	var fan_spread := 0.0
	var fan_groups := 0
	for port: String in fan:
		var destinations: Array = fan[port]
		if destinations.size() < 2:
			continue
		var low := INF
		var high := -INF
		for id: String in destinations:
			if not boxes.has(id):
				continue
			var centre: float = (boxes[id] as Rect2).get_center().y
			low = minf(low, centre)
			high = maxf(high, centre)
		if low < INF:
			fan_spread += high - low
			fan_groups += 1
	fan_spread = fan_spread / maxf(float(fan_groups), 1.0)

	# ---- tier 1: is the drawing even valid ------------------------------------------
	var overlaps := 0
	var names: Array = boxes.keys()
	for i in names.size():
		for j in range(i + 1, names.size()):
			if (boxes[names[i]] as Rect2).intersects(boxes[names[j]] as Rect2):
				overlaps += 1
	# Clearance is the same test with room to breathe around it, so a drawing that is
	# technically legal and visually welded reports as the second thing rather than as
	# nothing at all.
	var clearance := 0
	for i in names.size():
		for j in range(i + 1, names.size()):
			if (boxes[names[i]] as Rect2).grow(24.0).intersects(boxes[names[j]] as Rect2):
				clearance += 1
	clearance -= overlaps

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

	# ---- tier 2: stages, from the topology rather than from the grid ----------------
	var component := LayoutObjective.components(names, edges)
	var depth := LayoutObjective.depths(names, edges, component)
	var centres: Array = []
	for id: String in names:
		centres.append((boxes[id] as Rect2).get_center().x)
	var tolerance := median_width * LayoutObjective.BAND_FRACTION
	var column_count: int = LayoutObjective.bands(centres, tolerance).size()

	# A later stage standing left of an earlier one. Counted over pairs, because the
	# question is how much of the drawing disagrees with the computation rather than
	# whether any of it does.
	var violations := 0
	var stages := {}
	for id: String in names:
		var at: int = depth[id]
		if not stages.has(at):
			stages[at] = []
		(stages[at] as Array).append((boxes[id] as Rect2).get_center().x)
	for i in names.size():
		for j in names.size():
			if i == j:
				continue
			if int(depth[names[i]]) < int(depth[names[j]]) \
					and (boxes[names[j]] as Rect2).get_center().x \
						< (boxes[names[i]] as Rect2).get_center().x:
				violations += 1

	# How scattered one logical stage is across the drawing. A stage occupying three bands
	# is three things a reader has to recognise as one.
	var spread := 0
	for at: int in stages:
		spread += LayoutObjective.bands(stages[at], tolerance).size() - 1
	# And how many bands the drawing spends beyond what the graph's own depth requires.
	var surplus: int = maxi(0, column_count - stages.size())

	# ---- tier 5: how much of the author's arrangement survived ----------------------
	var moved := 0
	var displacements: Array = []
	var travelled := 0.0
	for id: String in names:
		if not was.has(id):
			continue
		var distance: float = (was[id] as Vector2).distance_to(
			(boxes[id] as Rect2).position)
		if distance > 0.5:
			moved += 1
			displacements.append(distance)
			travelled += distance
	displacements.sort()

	var total := 0.0
	for one: float in lengths:
		total += one
	var decile: float = lengths[int(float(lengths.size() - 1)
		* LayoutObjective.OUTLIER_DECILE)] if not lengths.is_empty() else 0.0
	var corners := {}
	for id: String in names:
		corners[id] = (boxes[id] as Rect2).position

	return {
		"nodes": boxes.size(), "cables": lengths.size(),
		"extent": [snappedf(box.size.x, 0.1), snappedf(box.size.y, 0.1)],
		"corners": corners,
		# Tier 0. Nothing here arranges, so topology cannot change and there are no
		# anchors to respect; both are reported anyway, so the contract is measured whole
		# rather than in the parts that happen to be interesting today.
		"topology_changed": 0, "anchors_moved": 0,
		# Tier 1.
		"overlaps": overlaps, "trespass": trespass, "clearance_faults": clearance,
		# Tier 2.
		"stage_violations": violations,
		"crossings": (cords.crossing_sites() as Array).size(),
		"backward": backward, "stage_spread": spread, "surplus_columns": surplus,
		"fanout_spread": snappedf(fan_spread, 0.1),
		"stages": stages.size(), "columns": column_count,
		# Tier 3.
		"cable_longest": snappedf(lengths[lengths.size() - 1] if not lengths.is_empty()
			else 0.0, 0.1),
		"cable_p90": snappedf(decile, 0.1),
		"cable_total": snappedf(total, 0.1),
		"cable_median": snappedf(lengths[lengths.size() / 2] if not lengths.is_empty()
			else 0.0, 0.1),
		# Tier 4.
		"area": snappedf(box.size.x * box.size.y / 1000000.0, 0.001),
		"aspect": snappedf(maxf(box.size.x / maxf(box.size.y, 1.0),
			box.size.y / maxf(box.size.x, 1.0)), 0.01),
		"whitespace": snappedf(1.0 - covered / maxf(box.size.x * box.size.y, 1.0), 0.001),
		# Tier 5.
		"moved": moved,
		"displacement_total": snappedf(travelled, 0.1),
		"displacement_median": snappedf(displacements[displacements.size() / 2]
			if not displacements.is_empty() else 0.0, 0.1),
		"displacement_max": snappedf(displacements[displacements.size() - 1]
			if not displacements.is_empty() else 0.0, 0.1),
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
		# The same patch as the layout engine would have it. Deterministic — the same
		# graph always lands the same way — so this is a property of the patch and not of
		# where anything happened to be first.
		await main._auto_place()
		await settle(24)
		var by_engine := measure(by_hand["corners"])
		by_hand.erase("corners")
		by_engine.erase("corners")
		record[short] = {"hand": by_hand, "auto": by_engine,
			"verdict": LayoutObjective.compare(by_engine, by_hand),
			"differs_at": LayoutObjective.differs_at(by_engine, by_hand),
			"admissible": LayoutObjective.admissible(by_engine, by_hand)}

	# ---- the three-way comparison the legalized fixture exists for -------------------
	# Hand, minimally legal, and auto-place, all scored against the hand arrangement so the
	# disturbance figures are comparable. Two of the three are legal, so this is the first
	# comparison in the pass that reaches the readability tier at all.
	await open_patch("res://qa/dense-graph.json")
	var hand_only := measure()
	var hand_corners: Dictionary = hand_only["corners"]
	await open_patch("res://qa/dense-graph-legalized.json")
	var legal_only := measure(hand_corners)
	await open_patch("res://qa/dense-graph.json")
	await main._auto_place()
	await settle(24)
	var auto_only := measure(hand_corners)
	for one: Dictionary in [hand_only, legal_only, auto_only]:
		one.erase("corners")
	record["three-way"] = {"hand": hand_only, "legalized": legal_only,
		"auto": auto_only,
		"legal_vs_auto": LayoutObjective.compare(legal_only, auto_only),
		"differs_at": LayoutObjective.differs_at(legal_only, auto_only)}

	print("")
	print("the hostile graph, three ways")
	print("  %-22s %10s %14s %10s" % ["", "hand", "minimal legal", "auto"])
	for tier: Dictionary in LayoutObjective.TIERS:
		for metric: String in tier["metrics"]:
			print("  %-22s %10s %14s %10s" % [metric, str(hand_only.get(metric, 0)),
				str(legal_only.get(metric, 0)), str(auto_only.get(metric, 0))])
	for metric: String in ["columns", "stages", "cable_median"]:
		print("  %-22s %10s %14s %10s" % [metric, str(hand_only.get(metric, 0)),
			str(legal_only.get(metric, 0)), str(auto_only.get(metric, 0))])
	print("  minimal legal against auto: %s, first difference at %s"
		% ["better" if int(record["three-way"]["legal_vs_auto"]) > 0 else "worse",
			str(record["three-way"]["differs_at"])])

	print("")
	for short: String in record:
		if short == "three-way":
			continue
		var hand: Dictionary = record[short]["hand"]
		var auto: Dictionary = record[short]["auto"]
		print("%s — %d nodes, %d cables, %d graph stages"
			% [short, int(hand["nodes"]), int(hand["cables"]), int(hand["stages"])])
		for tier: Dictionary in LayoutObjective.TIERS:
			var line := ""
			for metric: String in tier["metrics"]:
				line += "%s %s>%s  " % [metric, str(hand.get(metric, 0)),
					str(auto.get(metric, 0))]
			print("  %-14s %s" % [str(tier["name"]), line])
		var verdict: int = record[short]["verdict"]
		print("  %-14s auto-place is %s; first difference at %s"
			% ["verdict", "better" if verdict > 0 else ("worse" if verdict < 0
				else "indistinguishable"), str(record[short]["differs_at"])])
		print("")

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	var out := FileAccess.open(folder.path_join("layout-baseline.json"),
		FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()
	print("-> %s" % folder.path_join("layout-baseline.json"))
	await HarnessExit.finish(self, main)
