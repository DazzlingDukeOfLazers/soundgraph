extends SceneTree

## Cable pass, goal 2: does a route become identifiable when the rest of the field gets
## quieter?
##
## Aimed at the long-route problem the baseline measured — a median cable of 357 units
## against a longest of 2955, in a patch 4016 wide, so one cable crosses three quarters of
## the graph and is visually detached from both its ends.
##
## The mechanism is the point and it is stated as a prohibition: **the focused cable is
## drawn at its ordinary resting appearance.** No extra width, no saturation, no glow, no
## brightening. If focus works here it works because the noise left, and that is a
## different thing from the chosen route shouting — a graph where the answer is louder is
## a graph that gets louder every time you ask it a question.
##
##   godot --path editor-godot --script focus_sheet.gd
##
## with FOCUS_SHEET_OUT naming a directory. Not headless: it captures pixels.
##
## ## The two questions it separates
##
## **Cable hover** focuses one connection. **Port hover** focuses everything plugged into
## that one port, because an output with three cables on it really is one source feeding
## three destinations and should read as a family. Neither propagates: a cable graph is not
## a semantic signal chain — the nodes in between transform things — and lighting the whole
## downstream network is a different feature with a different meaning.
##
## ## What it asserts as well as photographs
##
## Suppression must not move anything. Every invariant below is checked at each level, on
## the whole hostile graph, and a failure is printed rather than left to somebody's eye:
##
##   the focused cable's route is point-identical to its unfocused route
##   every suppressed cable keeps its width and its path
##   the crossing count and every knockout location are unchanged by focus
##   port hover leaves exactly the cables on that port unsuppressed
##   cable hover leaves exactly that one connection unsuppressed
##   no pixel outside the cable layer moves

const PatchGraph := preload("res://patch_graph.gd")
const CableArt := preload("res://cable_art.gd")
const HarnessExit := preload("res://harness_exit.gd")
const PATCH := "res://qa/dense-graph.json"

const ZOOMS := [1.0, 0.40, 0.28]
const WINDOW := Vector2i(1920, 1200)

var main: Node
var graph: GraphEdit
var cords: CanvasItem
var complaints: Array = []


func out_dir() -> String:
	var asked := OS.get_environment("FOCUS_SHEET_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func note(what: String) -> void:
	complaints.append(what)


func redraw() -> void:
	cords.queue_redraw()
	await settle(4)


func frame() -> Image:
	var shot := root.get_texture().get_image()
	shot.convert(Image.FORMAT_RGBA8)
	return shot


func grey(shot: Image) -> Image:
	var out := shot.duplicate()
	for y in out.get_height():
		for x in out.get_width():
			var was: Color = out.get_pixel(x, y)
			var luma: float = was.r * 0.2126 + was.g * 0.7152 + was.b * 0.0722
			out.set_pixel(x, y, Color(luma, luma, luma, was.a))
	return out


## The mean luminance of the cables in a frame, split by whether they are the focused ones.
##
## Sampled along the routes themselves rather than over the whole picture: a frame-wide
## average is mostly canvas and would move by a hundredth when a cable halves. Taken a
## little off the path's own centre so the reading is the body rather than the highlight.
func luminance_of(shot: Image, routes: Array) -> float:
	var total := 0.0
	var samples := 0
	for points: PackedVector2Array in routes:
		for i in range(points.size() - 1):
			var span := points[i].distance_to(points[i + 1])
			var steps := maxi(1, int(span / 6.0))
			for s in steps:
				var at: Vector2 = points[i].lerp(points[i + 1],
					(float(s) + 0.5) / float(steps)) + Vector2(cords.global_position)
				if at.x < 1.0 or at.y < 1.0 or at.x >= shot.get_width() - 1 \
						or at.y >= shot.get_height() - 1:
					continue
				var pixel: Color = shot.get_pixel(int(at.x), int(at.y))
				total += pixel.r * 0.2126 + pixel.g * 0.7152 + pixel.b * 0.0722
				samples += 1
	# -1 rather than 0 when nothing was sampled. Zero is a luminance and would be averaged
	# in as "this cable is black": the port-hover scenes sit off-screen at 100% in a patch
	# four thousand units wide, and their empty readings dragged the focused set's figure
	# to 0.505 — which reads as the treatment dimming the cable it is supposed to leave
	# alone, and is instead the instrument averaging in a cable it never saw.
	return -1.0 if samples == 0 else total / float(samples)


## How many sampled pixels inside node rectangles differ between two frames.
##
## Cables are drawn under the nodes, so nothing inside one is a cable: this is exactly the
## claim the brief makes, that cable focus alters no node, title, port, warning or
## selection.
func node_pixels_between(a: Image, b: Image) -> int:
	var strays := 0
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget == null or not widget.visible:
			continue
		# Inset, because a node's own rectangle is not all node. A cable passes *under* a
		# node and its body and shadow reach a few pixels inside the frame's edge, so the
		# outermost band legitimately changes when that cable is suppressed — thirteen
		# sampled pixels of it, consistently, which is a cable at an edge and not a node
		# being disturbed. The inset is the cord's own outer extent at this zoom.
		var box := widget.get_global_rect().grow(-14.0)
		if box.size.x <= 0.0 or box.size.y <= 0.0:
			continue
		var from := Vector2i(maxf(box.position.x, 0.0), maxf(box.position.y, 0.0))
		var to := Vector2i(minf(box.end.x, float(a.get_width() - 1)),
			minf(box.end.y, float(a.get_height() - 1)))
		for y in range(from.y, to.y, 3):
			for x in range(from.x, to.x, 3):
				var was: Color = a.get_pixel(x, y)
				var now: Color = b.get_pixel(x, y)
				if absf(was.r - now.r) > 0.01 or absf(was.g - now.g) > 0.01 						or absf(was.b - now.b) > 0.01:
					strays += 1
	return strays


func centre() -> void:
	var box := Rect2()
	var first := true
	for child in graph.get_children():
		var node := child as GraphNode
		if node == null or not node.visible:
			continue
		var own := Rect2(node.position_offset, node.size)
		box = own if first else box.merge(own)
		first = false
	graph.scroll_offset = box.get_center() * graph.zoom - graph.size * 0.5
	await settle(4)


## Every cord as the layer has it, keyed the way the layer keys them.
func lay() -> Array:
	return cords._lay()


## A route in graph space, which is the only space an invariant can be stated in.
##
## The layer works in its own coordinates and those move with the scroll, so a route
## compared against one recorded at a different scroll differs at every point — which is
## what the geometry check reported the moment the sheet started centring on the cables it
## was photographing. The document's coordinates do not move; these are them.
func in_graph(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point: Vector2 in points:
		out.append((point + graph.scroll_offset) / graph.zoom)
	return out


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(WINDOW)
	root.content_scale_size = WINDOW
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	var file := FileAccess.open(PATCH, FileAccess.READ)
	await main._load_text(file.get_as_text())
	await settle(20)
	main._set_roll_open(false)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	graph.zoom = 1.0
	await settle(12)
	for child in graph.get_children():
		if child.has_method("crossing_sites"):
			cords = child
	if cords == null:
		printerr("no cord layer")
		await HarnessExit.finish(self, main, 1)
		return

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	await centre()

	# The specimens the brief names, found rather than written down: the longest cable in
	# the patch, the shortest, and the output port carrying the widest fan-out.
	var longest := {}
	var shortest := {}
	var best := -1.0
	var worst := INF
	var fan := {}
	for connection in graph.get_connection_list():
		var route: PackedVector2Array = cords._lay()[0][0]
		fan["%s:%d" % [str(connection["from_node"]), int(connection["from_port"])]] = \
			int(fan.get("%s:%d" % [str(connection["from_node"]),
				int(connection["from_port"])], 0)) + 1
	for entry in lay():
		var run := 0.0
		var points: PackedVector2Array = entry[0]
		for i in range(points.size() - 1):
			run += points[i].distance_to(points[i + 1])
		if run > best:
			best = run
			longest = {"key": entry[4], "cable": entry}
		if run < worst:
			worst = run
			shortest = {"key": entry[4], "cable": entry}
	var widest := ""
	var most := 0
	for port: String in fan:
		if int(fan[port]) > most:
			most = int(fan[port])
			widest = port
	print("longest cable %.0f units, shortest %.0f, widest fan-out %s with %d cables"
		% [best, worst, widest, most])

	# A destination port, from the mixer that four cables arrive at.
	var destination := ""
	for entry in lay():
		if str(entry[3]).begins_with("Master") or destination == "":
			destination = str(entry[3])

	# ---- the scenes -----------------------------------------------------------------
	var scenes := [
		{"name": "baseline", "cable": {}, "port": ""},
		{"name": "long-cable", "cable": longest["cable"], "port": ""},
		{"name": "short-cable", "cable": shortest["cable"], "port": ""},
		{"name": "fanout-port", "cable": {}, "port": "%s:right:%s"
			% [widest.split(":")[0], widest.split(":")[1]]},
		{"name": "destination-port", "cable": {}, "port": "%s:left:%s"
			% [destination.split(":")[0], destination.split(":")[1]]},
	]

	var record := {"levels": {}, "longest": snappedf(best, 0.1),
		"shortest": snappedf(worst, 0.1), "fan_out": most}

	# The routes as drawn with nothing focused, kept for the geometry invariant.
	graph.focus_port = ""
	graph.hovered_cable = {}
	await redraw()
	var resting: Dictionary = {}
	for entry in lay():
		resting[entry[4]] = in_graph(entry[0])
	var resting_sites: Array = []
	for site: Dictionary in cords.crossing_sites():
		resting_sites.append((site["at"] as Vector2 + graph.scroll_offset) / graph.zoom)
	var resting_frame := frame()


	for level: float in CableArt.SUPPRESSION_LEVELS:
		CableArt.suppression = level
		var label := "%d" % int(roundf(level * 100.0))
		var focused_luma := 0.0
		var background_luma := 0.0
		var readings := 0
		for scene: Dictionary in scenes:
			_wear(scene)
			for zoom: float in ZOOMS:
				graph.zoom = zoom
				graph._update_detail()
				main._apply_detail(graph.detail)
				await settle(6)
				await centre()
				await redraw()
				var shot := frame()
				shot.save_png(folder.path_join("focus-%s-%s-%d.png"
					% [label, str(scene["name"]), int(roundf(zoom * 100.0))]))
			var reading: Dictionary = await _audit(scene, resting, resting_sites, label)
			if not reading.is_empty() and str(scene["name"]) != "baseline":
				focused_luma += float(reading["focused"])
				background_luma += float(reading["background"])
				readings += 1
		# Both figures are "how much of its resting luminance did this set keep". The
		# focused set must keep all of it — that is the prohibition — and the background
		# set keeping less is the whole of the treatment.
		var kept_lit := focused_luma / maxf(float(readings), 1.0)
		var kept_dim := background_luma / maxf(float(readings), 1.0)
		record["levels"][label] = {
			"focused_keeps": snappedf(kept_lit, 0.001),
			"background_keeps": snappedf(kept_dim, 0.001),
			"ratio": snappedf(kept_lit / maxf(kept_dim, 0.0001), 0.01),
		}

	# One grayscale proof: suppression has to work without hue, because that is the one
	# channel the cable body does not have a second copy of.
	CableArt.suppression = 0.45
	_wear(scenes[1])
	graph.zoom = 1.0
	await settle(4)
	await centre()
	await redraw()
	grey(frame()).save_png(folder.path_join("focus-grey-long-cable.png"))

	graph.focus_port = ""
	graph.hovered_cable = {}
	await redraw()

	print("")
	print("%-10s %14s %18s %10s" % ["level", "focused keeps", "background keeps",
		"ratio"])
	for label: String in record["levels"]:
		var entry: Dictionary = record["levels"][label]
		print("%-10s %14.3f %18.3f %10.2f" % [label, float(entry["focused_keeps"]),
			float(entry["background_keeps"]), float(entry["ratio"])])
	print("")
	if complaints.is_empty():
		print("no complaints")
	else:
		print("%d complaints:" % complaints.size())
		for one: String in complaints:
			print("  %s" % one)
	record["complaints"] = complaints
	var out := FileAccess.open(folder.path_join("focus.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()
	print("-> %s" % folder)
	await HarnessExit.finish(self, main)


func _wear(scene: Dictionary) -> void:
	graph.focus_port = str(scene["port"])
	var cable: Variant = scene["cable"]
	if typeof(cable) == TYPE_ARRAY:
		var parts: PackedStringArray = str(cable[4]).split(">")
		var from: PackedStringArray = parts[0].split(":")
		var to: PackedStringArray = parts[1].split(":")
		graph.hovered_cable = {"from_node": from[0], "from_port": int(from[1]),
			"to_node": to[0], "to_port": int(to[1])}
	else:
		graph.hovered_cable = {}


## Everything suppression must not have done.
func _audit(scene: Dictionary, resting: Dictionary, resting_sites: Array,
		level: String) -> Dictionary:
	graph.zoom = 1.0
	await settle(4)
	# On the cables being asked about, not on the whole patch. The graph is four thousand
	# units wide and the viewport is not, so centring globally left the port-hover scenes
	# entirely off screen — nothing to photograph and nothing to measure.
	var interest := Rect2()
	var seen := false
	var asked: Dictionary = cords._focus_of(lay())
	for entry in lay():
		if not asked.has(entry[4]):
			continue
		for point: Vector2 in (entry[0] as PackedVector2Array):
			var at: Vector2 = (point + graph.scroll_offset) / graph.zoom
			interest = Rect2(at, Vector2.ZERO) if not seen else interest.expand(at)
			seen = true
	if seen:
		graph.scroll_offset = interest.get_center() * graph.zoom - graph.size * 0.5
		await settle(4)
	else:
		await centre()
	await redraw()
	var where := "%s @%s%%" % [str(scene["name"]), level]

	# Geometry, point by point. A focus that moves a cable is a focus that has changed the
	# patch, and the route is a fact about the document.
	for entry in lay():
		var was: PackedVector2Array = resting.get(entry[4], PackedVector2Array())
		var now: PackedVector2Array = in_graph(entry[0])
		if was.size() != now.size():
			note("%s: %s changed from %d points to %d"
				% [where, str(entry[4]), was.size(), now.size()])
			continue
		for i in was.size():
			if was[i].distance_to(now[i]) > 0.01:
				note("%s: %s moved at point %d" % [where, str(entry[4]), i])
				break

	# Crossings. A dimmed cable still crosses rather than joins, and which one is over must
	# not depend on what the pointer is doing.
	var sites: Array = []
	for site: Dictionary in cords.crossing_sites():
		sites.append((site["at"] as Vector2 + graph.scroll_offset) / graph.zoom)
	if sites.size() != resting_sites.size():
		note("%s: %d crossings against %d at rest"
			% [where, sites.size(), resting_sites.size()])
	else:
		for i in sites.size():
			if (sites[i] as Vector2).distance_to(resting_sites[i] as Vector2) > 0.01:
				note("%s: crossing %d moved" % [where, i])
				break

	# Exactly the right cables are left alone.
	var wanted: Dictionary = cords._focus_of(lay())
	if str(scene["name"]) == "baseline":
		if not wanted.is_empty():
			note("%s: nothing is hovered and %d cables are focused"
				% [where, wanted.size()])
	elif str(scene["port"]) != "":
		var parts: PackedStringArray = str(scene["port"]).split(":")
		var at := "%s:%s" % [parts[0], parts[2]]
		var slot: int = 2 if parts[1] == "right" else 3
		var expected := 0
		for entry in lay():
			if str(entry[slot]) == at:
				expected += 1
		if wanted.size() != expected:
			note("%s: port hover focused %d cables, %d are on that port"
				% [where, wanted.size(), expected])
	elif wanted.size() != 1:
		note("%s: cable hover focused %d cables" % [where, wanted.size()])

	# And no node moved. Captured back to back: focus off, then focus on, nothing else
	# touched between the two frames.
	#
	# Two earlier instruments were wrong here and the second one is the instructive one.
	# Diffing against a resting frame taken at the start of the run reported a floor of 33
	# rising to 180 by the end, in the **baseline** scene where nothing is focused — not
	# jitter but drift, something in the editor settling over the minutes a full run takes.
	# A reference frame is only a reference for as long as nothing has moved, and in a live
	# program that is about four frames.
	#
	# Cables are drawn under the nodes, so nothing inside a node rectangle is a cable, and
	# the claim this checks is exactly the one the brief makes: cable focus alters no node,
	# title, port, warning or selection.
	var was_port: String = graph.focus_port
	var was_cable: Dictionary = graph.hovered_cable
	graph.focus_port = ""
	graph.hovered_cable = {}
	await redraw()
	var before := frame()
	graph.focus_port = was_port
	graph.hovered_cable = was_cable
	await redraw()
	var after := frame()
	var strays := node_pixels_between(before, after)
	if strays > 0:
		note("%s: %d node pixels changed" % [where, strays])

	# And the luminance measurement, from this same pair. It was taken against a resting
	# frame captured at the top of the run and reported the *focused* cables keeping half
	# their brightness — which would mean the prohibition was being broken — when what had
	# actually happened is that the reference had gone stale underneath it. Same lesson as
	# the node check one paragraph up, learned twice in one file.
	var lit: Array = []
	var dim: Array = []
	var focused_now: Dictionary = cords._focus_of(lay())
	for entry in lay():
		if focused_now.has(entry[4]):
			lit.append(entry[0])
		else:
			dim.append(entry[0])
	if lit.is_empty() or dim.is_empty():
		return {}
	var lit_before := luminance_of(before, lit)
	var dim_before := luminance_of(before, dim)
	if lit_before < 0.0 or dim_before < 0.0:
		return {}
	return {
		"focused": luminance_of(after, lit) / lit_before,
		"background": luminance_of(after, dim) / dim_before,
	}
