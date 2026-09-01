extends SceneTree

## Cable pass, goal 3: can you name a cable's signal class from its middle, in grayscale?
##
## The defect is the one the node QA's grayscale render found and filed. Socket shape
## carries the signal type at both ends and survives a monochrome display; the cable
## between them carries hue and nothing else, so tracing one wire through a crossing region
## without looking at its ends needs colour.
##
## The requirement is deliberately narrow:
##
## > Given a mid-span crop with the endpoints unavailable and the hue removed, identify the
## > cable's signal class — without mistaking the cue for a junction, a crossing, a
## > direction arrow or activity.
##
##   godot --path editor-godot --script type_cue_sheet.gd
##
## with TYPE_CUE_SHEET_OUT naming a directory. Not headless: it captures pixels.
##
## ## Why the crops hide the ends
##
## Because that is the whole question. A sheet that shows a cable with its sockets attached
## proves that sockets work, which was never in doubt. **If the reviewer needs either end,
## goal 3 has not solved its problem** — so the crops are taken from the middle of a span,
## in grayscale, with nothing else in frame.
##
## ## What it measures
##
## Ink per thousand screen pixels of cable, the cadence actually achieved, how many cues the
## exclusions refused, and — the ones that matter — that the routes, the crossings and the
## focus ratio are all exactly what they were before a cue was drawn anywhere.

const PatchGraph := preload("res://patch_graph.gd")
const CableArt := preload("res://cable_art.gd")
const HarnessExit := preload("res://harness_exit.gd")
const PATCH := "res://qa/dense-graph.json"

const ZOOMS := [1.0, 0.40, 0.28]
const WINDOW := Vector2i(1920, 1200)

## A mid-span crop: wide enough to hold two cadences at 100%, tall enough to show the cord
## and a little canvas either side, and nothing else.
const CROP := Vector2i(340, 76)
const MAGNIFY := 2

var main: Node
var graph: GraphEdit
var cords: CanvasItem
var complaints: Array = []


func out_dir() -> String:
	var asked := OS.get_environment("TYPE_CUE_SHEET_OUT")
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


func lay() -> Array:
	return cords._lay()


func in_graph(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point: Vector2 in points:
		out.append((point + graph.scroll_offset) / graph.zoom)
	return out


func arc_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## The middle of a route, in graph space, and the heading there.
func midpoint(points: PackedVector2Array) -> Dictionary:
	var half := arc_length(points) * 0.5
	var walked := 0.0
	for i in range(points.size() - 1):
		var span := points[i].distance_to(points[i + 1])
		if walked + span >= half and span > 0.0001:
			var t := (half - walked) / span
			return {"at": points[i].lerp(points[i + 1], t),
				"along": (points[i + 1] - points[i]) / span}
		walked += span
	return {"at": points[0], "along": Vector2.RIGHT}


## A crop of the middle of one cable, in grayscale, with nothing else in it.
##
## Takes the point in **graph space**. The first version took the cord and worked out its
## middle at call time, from coordinates captured before any scrolling had happened — the
## layer's space moves with the scroll, so every crop after the first was of somewhere
## else, and the sheet came back as two cables and four empty rectangles. Third time this
## file's family of harnesses has learned it.
func mid_span(graph_at: Vector2) -> Image:
	graph.scroll_offset = graph_at * graph.zoom - graph.size * 0.5
	await settle(5)
	await redraw()
	var shot := grey(frame())
	var here: Vector2 = graph_at * graph.zoom - graph.scroll_offset \
		+ Vector2(cords.global_position)
	var origin := Vector2i(here) - CROP / 2
	origin.x = clampi(origin.x, 0, shot.get_width() - CROP.x)
	origin.y = clampi(origin.y, 0, shot.get_height() - CROP.y)
	return shot.get_region(Rect2i(origin, CROP))


func tile(rows: Array, path: String, times: int) -> void:
	var pad := 8
	var wide := 0
	for row: Array in rows:
		wide = maxi(wide, row.size())
	var cell := Vector2i(CROP.x * times + pad, CROP.y * times + pad)
	var sheet := Image.create(wide * cell.x + pad, rows.size() * cell.y + pad,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.08, 0.08, 0.09))
	for r in rows.size():
		var row: Array = rows[r]
		for c in row.size():
			var crop: Image = (row[c] as Image).duplicate()
			if times > 1:
				crop.resize(CROP.x * times, CROP.y * times, Image.INTERPOLATE_NEAREST)
			sheet.blit_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()),
				Vector2i(pad + c * cell.x, pad + r * cell.y))
	sheet.save_png(path)


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


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(WINDOW)
	root.content_scale_size = WINDOW
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	main._set_roll_open(false)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	for child in graph.get_children():
		if child.has_method("crossing_sites"):
			cords = child
	if cords == null:
		printerr("no cord layer")
		await HarnessExit.finish(self, main, 1)
		return
	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)

	var candidates := [CableArt.TypeCue.NONE, CableArt.TypeCue.HIGHLIGHT,
		CableArt.TypeCue.RIBS, CableArt.TypeCue.STAMPS]
	var names := ["none", "highlight", "ribs", "stamps"]
	var record := {"candidates": {}}

	# ---- the identification test: the specimen, at 100%, grayscale, ends cropped out ---
	#
	# 100% only, and that is a finding rather than a convenience. At 40% a 340-pixel crop
	# of a patch four thousand units wide contains nodes wherever it is centred, so four of
	# the first sheet's six crops answered a different question from the one asked. At MAP
	# scale a cable exists to say topology in context and an isolated crop of one is not
	# what anybody is looking at. So: 100% identifies the vocabulary, and the whole-graph
	# frames below decide whether it stays calm.
	await open_patch("res://qa/cable-types.json")
	graph.zoom = 1.0
	graph._update_detail()
	main._apply_detail(graph.detail)
	await settle(10)

	# One clean specimen per class: the longest cable of each whose middle is clear of
	# every node, since a crop with a node in it is not endpoint-free either.
	var pick := {}
	for entry in lay():
		var klass := int(entry[5])
		var middle: Vector2 = midpoint(entry[0])["at"]
		if not clear_of_nodes(middle):
			continue
		var run := arc_length(entry[0])
		if not pick.has(klass) or run > float(pick[klass]["run"]):
			pick[klass] = {"run": run,
				"middle": (middle + graph.scroll_offset) / graph.zoom}
	print("clean specimens by class: %s  (0 audio, 1 control)" % str(pick.keys()))

	var resting := {}
	CableArt.type_cue = CableArt.TypeCue.NONE
	await redraw()
	for entry in lay():
		resting[entry[4]] = in_graph(entry[0])
	var resting_sites: Array = []
	for site: Dictionary in cords.crossing_sites():
		resting_sites.append((site["at"] as Vector2 + graph.scroll_offset) / graph.zoom)

	var rows: Array = []
	for i in candidates.size():
		CableArt.type_cue = candidates[i]
		await redraw()
		var row: Array = []
		for klass in 2:
			if pick.has(klass):
				row.append(await mid_span(pick[klass]["middle"]))
		rows.append(row)
		await _audit(resting, resting_sites, names[i])
	tile(rows, folder.path_join("cue-midspans.png"), MAGNIFY)

	# What each candidate costs, on the specimen where the classes are clean.
	graph.zoom = 1.0
	await settle(4)
	for i in candidates.size():
		CableArt.type_cue = candidates[i]
		var style: CableArt.Style = cords._style()
		var placed := 0
		var skipped := 0
		var marked := 0.0
		for entry in lay():
			style.signal_class = int(entry[5])
			style.cue_avoid = PackedVector2Array()
			var sites: Dictionary = CableArt.cue_sites(entry[0], style)
			placed += (sites["placed"] as Array).size()
			skipped += int(sites["skipped"])
			if int(entry[5]) != CableArt.SignalClass.AUDIO:
				marked += float(sites["length"])
		# Ink, as the highlight length a marked cable ends up carrying against the length
		# it carried before. Negative for the highlight candidate, which spends the sheen
		# it already had rather than adding anything — the reason it was the preferred
		# first specimen.
		var ink := 0.0
		if names[i] == "highlight":
			ink = (float(placed) * CableArt.CUE_STROKE - marked) / maxf(marked, 1.0) * 1000.0
		elif names[i] == "ribs":
			ink = float(placed) * style.thickness * 1.24 / maxf(marked, 1.0) * 1000.0
		elif names[i] == "stamps":
			ink = float(placed) * pow(style.thickness * 0.68, 2.0) * 0.5 				/ maxf(marked, 1.0) * 1000.0
		record["candidates"][names[i]] = {"placed": placed, "skipped": skipped,
			"marked_cable": snappedf(marked, 0.1),
			"cadence": snappedf(marked / maxf(float(placed), 1.0), 0.1),
			"ink_per_1000px": snappedf(ink, 0.1)}

	# ---- the integration test: the hostile graph, at the zooms a reader uses ----------
	await open_patch("res://qa/dense-graph.json")
	for i in candidates.size():
		CableArt.type_cue = candidates[i]
		for zoom: float in [1.0, 0.66, 0.40, 0.28]:
			graph.zoom = zoom
			graph._update_detail()
			main._apply_detail(graph.detail)
			await settle(6)
			await centre()
			await redraw()
			frame().save_png(folder.path_join("cue-%s-graph-%d.png"
				% [names[i], int(roundf(zoom * 100.0))]))

	print("")
	print("%-12s %7s %9s %12s %16s" % ["candidate", "cues", "refused", "cadence px",
		"ink /1000px"])
	for name: String in record["candidates"]:
		var entry: Dictionary = record["candidates"][name]
		print("%-12s %7d %9d %12.0f %16.1f" % [name, int(entry["placed"]),
			int(entry["skipped"]), float(entry["cadence"]),
			float(entry["ink_per_1000px"])])
	print("")
	if complaints.is_empty():
		print("no complaints")
	else:
		for one: String in complaints:
			print("  %s" % one)
	record["complaints"] = complaints
	var out := FileAccess.open(folder.path_join("type-cues.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()
	CableArt.type_cue = CableArt.TypeCue.NONE
	print("-> %s" % folder)
	await HarnessExit.finish(self, main)


func open_patch(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	await main._load_text(file.get_as_text())
	await settle(20)
	main._set_roll_open(false)
	graph.zoom = 1.0
	await settle(8)
	await centre()


## Whether a point in the layer's own space has no node under or beside it. A crop with a
## node in it is not endpoint-free either: the node's ports are endpoints.
func clear_of_nodes(at: Vector2) -> bool:
	var here: Vector2 = (at + graph.scroll_offset) / graph.zoom
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget == null or not widget.visible:
			continue
		if Rect2(widget.position_offset, widget.size).grow(200.0).has_point(here):
			return false
	return true


## Nothing a type cue may move.
func _audit(resting: Dictionary, resting_sites: Array, name: String) -> void:
	for entry in lay():
		var was: PackedVector2Array = resting.get(entry[4], PackedVector2Array())
		var now: PackedVector2Array = in_graph(entry[0])
		if was.size() != now.size():
			note("%s: %s changed shape" % [name, str(entry[4])])
			continue
		for i in was.size():
			if was[i].distance_to(now[i]) > 0.01:
				note("%s: %s moved" % [name, str(entry[4])])
				break
	var sites: Array = []
	for site: Dictionary in cords.crossing_sites():
		sites.append((site["at"] as Vector2 + graph.scroll_offset) / graph.zoom)
	if sites.size() != resting_sites.size():
		note("%s: %d crossings against %d" % [name, sites.size(), resting_sites.size()])
