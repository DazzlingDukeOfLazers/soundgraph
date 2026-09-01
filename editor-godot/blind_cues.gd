extends SceneTree

## Goal 3's blind test: can the type cue be named without the answer key?
##
## The sheet that chose the transverse rib was read by somebody who knew which column was
## which, and that is not evidence about legibility — it is evidence that a mark exists.
## This exports endpoint-free grayscale crops under shuffled names, writes the key to a
## file, and prints **nothing** that would give it away.
##
##   godot --path editor-godot --script blind_cues.gd
##
## with BLIND_CUES_OUT naming a directory. Read the crops, write down audio or control for
## each, and only then open `answers.json`.
##
## The shuffle is seeded from the clock, so the order is not a property of this file and
## re-reading the source does not reveal it.
##
## The bar, and it is deliberately not perfection: this is a redundant accessibility
## channel and not the primary classifier, so it should be substantially better than chance
## and unambiguous once noticed. If every crop has to be searched for "the little thing",
## the cadence or the mark needs work rather than the reader needing more patience.

const PatchGraph := preload("res://patch_graph.gd")
const CableArt := preload("res://cable_art.gd")
const HarnessExit := preload("res://harness_exit.gd")
const PATCH := "res://qa/cable-types.json"

## Big enough to hold a cadence and a bit, small enough that a crop is a crop.
const CROP := Vector2i(300, 84)
const MAGNIFY := 2

## Where along each cable the crops are taken. Deliberately not all at the middle: a mark
## that is only findable when it is under the crosshair has not been found.
const ALONG := [0.3, 0.42, 0.55, 0.68]

var main: Node
var graph: GraphEdit
var cords: CanvasItem


func out_dir() -> String:
	var asked := OS.get_environment("BLIND_CUES_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func arc_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


func at_fraction(points: PackedVector2Array, fraction: float) -> Vector2:
	var wanted := arc_length(points) * fraction
	var walked := 0.0
	for i in range(points.size() - 1):
		var span := points[i].distance_to(points[i + 1])
		if walked + span >= wanted and span > 0.0001:
			return points[i].lerp(points[i + 1], (wanted - walked) / span)
		walked += span
	return points[points.size() - 1]


func clear_of_nodes(graph_at: Vector2) -> bool:
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget == null or not widget.visible:
			continue
		if Rect2(widget.position_offset, widget.size).grow(220.0).has_point(graph_at):
			return false
	return true


func crop_at(graph_at: Vector2) -> Image:
	graph.scroll_offset = graph_at * graph.zoom - graph.size * 0.5
	await settle(5)
	cords.queue_redraw()
	await settle(4)
	var shot := root.get_texture().get_image()
	shot.convert(Image.FORMAT_RGBA8)
	for y in shot.get_height():
		for x in shot.get_width():
			var was: Color = shot.get_pixel(x, y)
			var luma: float = was.r * 0.2126 + was.g * 0.7152 + was.b * 0.0722
			shot.set_pixel(x, y, Color(luma, luma, luma, was.a))
	var here: Vector2 = graph_at * graph.zoom - graph.scroll_offset \
		+ Vector2(cords.global_position)
	var origin := Vector2i(here) - CROP / 2
	origin.x = clampi(origin.x, 0, shot.get_width() - CROP.x)
	origin.y = clampi(origin.y, 0, shot.get_height() - CROP.y)
	var piece := shot.get_region(Rect2i(origin, CROP))
	piece.resize(CROP.x * MAGNIFY, CROP.y * MAGNIFY, Image.INTERPOLATE_NEAREST)
	return piece


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
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
	await settle(10)
	for child in graph.get_children():
		if child.has_method("crossing_sites"):
			cords = child
	if cords == null:
		printerr("no cord layer")
		await HarnessExit.finish(self, main, 1)
		return

	# Every clear span on every long cable, as [graph position, class].
	var wanted: Array = []
	for entry in cords._lay():
		var points: PackedVector2Array = entry[0]
		if arc_length(points) < 900.0:
			continue
		for fraction: float in ALONG:
			var at := at_fraction(points, fraction)
			var graph_at: Vector2 = (at + graph.scroll_offset) / graph.zoom
			if clear_of_nodes(graph_at):
				wanted.append({"at": graph_at,
					"class": "audio" if int(entry[5]) == CableArt.SignalClass.AUDIO
						else "control"})

	# Shuffled from the clock, so the order is not a property of this file and re-reading
	# the source does not reveal it.
	var shuffler := RandomNumberGenerator.new()
	shuffler.seed = hash(str(Time.get_unix_time_from_system()))
	for i in range(wanted.size() - 1, 0, -1):
		var j := shuffler.randi_range(0, i)
		var swap: Dictionary = wanted[i]
		wanted[i] = wanted[j]
		wanted[j] = swap

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)
	var key := {}
	for i in wanted.size():
		var piece := await crop_at(wanted[i]["at"])
		var name := "crop-%02d.png" % (i + 1)
		piece.save_png(folder.path_join(name))
		key[name] = str(wanted[i]["class"])
	var out := FileAccess.open(folder.path_join("answers.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(key, "  "))
	out.close()

	# Nothing about which is which, on purpose.
	print("%d crops -> %s" % [wanted.size(), folder])
	print("the key is in answers.json; do not open it first")
	await HarnessExit.finish(self, main)
