extends SceneTree

## The twelve reserved identity cells, side by side, with their names showing.
##
## 15B asks one question about them and it is not a design question:
##
## > Does any blank cell cause more confusion than a bad glyph would?
##
## Which cannot be answered a node at a time. A single header with an empty cell always
## looks like a header with an empty cell; what would give it away is twelve of them in a
## row looking like a set of unfinished nodes rather than a set of nodes whose identity is
## carried by the word. So the sheet is the whole reserved set at once, at the size a node
## header is actually read at, with three glyph-bearing headers at the end for scale.
##
##   godot --path editor-godot --script reserved_sheet.gd
##
## with RESERVED_SHEET_OUT naming a directory. Not headless: it captures pixels.
##
## The list is computed rather than written down. A reserved cell is exactly a migrated
## type with no glyph and no identity variant, so the sheet cannot fall behind the day one
## of them is finally drawn — it will simply have eleven rows.

const HarnessExit := preload("res://harness_exit.gd")
const AIR := 14
## Three headers that do wear a mark, so the blank cells are judged against the thing they
## are the absence of rather than against each other.
const CONTROLS := ["SawOscillator", "Mixer", "Compressor"]

var main: Node
var graph: GraphEdit


func out_dir() -> String:
	var asked := OS.get_environment("RESERVED_SHEET_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


## Every migrated type whose identity cell is deliberately empty.
func reserved() -> Array:
	var found: Array = []
	for type: String in NodeIdentity.MIGRATED:
		if type.begins_with("seam:"):
			continue
		if NodeIdentity.glyph_of(type) < 0 and not NodeIdentity.VARIANT.has(type):
			found.append(type)
	found.sort()
	return found


## The header strip of a node, plus a little of the body under it so the rule beneath the
## header is in the picture — a title column is judged against the edge it sits above.
func header_of(widget: GraphNode) -> Image:
	var shot := root.get_texture().get_image()
	var bar := widget.get_titlebar_hbox()
	var tall: float = (bar.size.y if bar != null else 30.0) + 10.0
	var rect := widget.get_global_rect()
	rect.size.y = tall
	rect = rect.intersection(Rect2(Vector2.ZERO, Vector2(shot.get_size())))
	return shot.get_region(Rect2i(rect))


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(Vector2i(1920, 1200))
	root.content_scale_size = Vector2i(1920, 1200)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)

	var types := reserved()
	var listed: Array = types.duplicate()
	listed.append_array(CONTROLS)

	# Spread far enough apart that no two headers are ever in one crop, and shallow
	# enough that every one of them is on screen at once.
	var document := {"schema_version": 1, "metadata": {"name": "reserved cells"},
		"nodes": [], "connections": []}
	for i in listed.size():
		(document["nodes"] as Array).append({"id": "n%d" % i, "type": listed[i],
			"parameters": {},
			"position": {"x": float(i) * 700.0, "y": 0.0}})
	await main._load_text(JSON.stringify(document, "  "))
	await settle(20)
	main._set_roll_open(false)
	graph = main.graph_edit
	graph.zoom = 1.0
	await settle(10)

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)

	# One crop per header, taken by scrolling each node to the same spot rather than by
	# laying them all out and hoping. A node photographed at the edge of the graph is a
	# node photographed half out of frame.
	#
	# Sideways only, and every node on one line at y zero. GraphEdit clamps its own
	# vertical scroll against the content it can reach, and the plugin hosts are twelve
	# hundred pixels tall: centring one put its header above the window, and the crop then
	# took a strip of body and put two headers with no name on them into the sheet — which
	# read exactly like the defect this sheet exists to look for. A row of nodes at one
	# height has no vertical scroll to be clamped.
	var strips: Array = []
	var names: Array = []
	for i in listed.size():
		var widget: GraphNode = main.widgets.get("n%d" % i)
		if widget == null:
			continue
		graph.scroll_offset = Vector2(widget.position_offset.x - 40.0, -40.0)
		await settle(6)
		strips.append(header_of(widget))
		names.append(str(listed[i]))
		print("  %-18s title '%s'  health %d  width %.0f" % [str(listed[i]),
			widget.title, main._health_of("n%d" % i), widget.size.x])

	var wide := 0
	var tall := 0
	for strip: Image in strips:
		wide = maxi(wide, strip.get_width())
		tall = maxi(tall, strip.get_height())
	var sheet := Image.create(wide + AIR * 2,
		strips.size() * (tall + AIR) + AIR, false, Image.FORMAT_RGBA8)
	sheet.fill(Design.SURFACES[Design.Surface.CANVAS])
	for i in strips.size():
		var strip: Image = strips[i]
		strip.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(strip, Rect2i(Vector2i.ZERO, strip.get_size()),
			Vector2i(AIR, AIR + i * (tall + AIR)))
	sheet.save_png(folder.path_join("reserved-cells.png"))

	print("%d reserved cells, %d controls, sheet -> %s"
		% [types.size(), CONTROLS.size(), folder])
	var report: Variant = JSON.parse_string(
		str(main.engine.validate_patch(JSON.stringify(main.patch, "  "))))
	if typeof(report) == TYPE_DICTIONARY:
		for entry: Dictionary in report.get("diagnostics", []):
			print("  %s: %s" % [str(entry.get("severity", "")),
				str(entry.get("message", ""))])
	await HarnessExit.finish(self, main)
