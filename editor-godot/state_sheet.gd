extends SceneTree

## Step 11's proof: can a reader answer five questions about a node at once?
##
##   which node is selected, which is merely hovered, is anything invalid,
##   is anything showing runtime activity, and which ports are connected
##
## State design fails when two legitimate facts reach for the same channel, so the
## specimens that matter are the combined ones — selected *and* hovered, selected *and*
## broken. Isolated states always look fine.
##
## Taken from the running editor on a real patch rather than from a mock node, because a
## state treatment that only holds up on a specimen built for it is not a state treatment.
## First Synth happens to contain all three proving-ground types: its Lowpass is the
## specimen (four controls, five ports, some connected and some not, an identity glyph and
## enough body to expose over-styling), its Amp Envelope is the ADSR stage prototype, and
## its Amplifier stands in the mixed-state group.
##
##   godot --path editor-godot --script state_sheet.gd
##
## with STATE_SHEET_OUT naming a directory. Not headless: this one has to see pixels.

const SPECIMEN := "Lowpass"
const ENVELOPE := "Amp Envelope"
const GAIN := "Amplifier"

## The eight, in the order the contact sheet lays them out. Each is a set of facts that
## are true at once, which is the whole point.
const STATES := [
	{"name": "normal", "select": false, "hover": false, "active": false, "health": 0},
	{"name": "hovered", "select": false, "hover": true, "active": false, "health": 0},
	{"name": "selected", "select": true, "hover": false, "active": false, "health": 0},
	{"name": "selected-hovered", "select": true, "hover": true, "active": false,
		"health": 0},
	{"name": "active", "select": false, "hover": false, "active": true, "health": 0},
	{"name": "selected-active", "select": true, "hover": false, "active": true,
		"health": 0},
	{"name": "warning", "select": false, "hover": false, "active": false, "health": 1},
	{"name": "selected-warning", "select": true, "hover": false, "active": false,
		"health": 1},
]

## The three that have to survive the detail bands, and the zooms they are read at.
const SURVIVORS := ["selected", "active", "warning"]
const ZOOMS := [1.0, 0.66, 0.40]

## Room around the node in the crop, so a perimeter can be seen against the canvas it is
## drawn on. A border judged with nothing outside it is a border judged as a fill.
const AIR := 18

var main: Node
var graph: GraphEdit


func out_dir() -> String:
	var asked := OS.get_environment("STATE_SHEET_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func widget_of(title: String) -> GraphNode:
	for child in graph.get_children():
		var node := child as GraphNode
		if node != null and node.title == title:
			return node
	return null


## Puts one node into one set of facts and leaves every other node alone.
func wear(node: GraphNode, state: Dictionary) -> void:
	var node_id: String = str(node.get_meta("patch_id"))
	graph.set_selected(node if bool(state["select"]) else null)
	node.set_meta("hovered", bool(state["hover"]))
	var health := int(state["health"])
	main._apply_health({node_id: health} if health > 0 else {})
	main._style_widget(node, node_id)
	if bool(state["active"]):
		# Activity is local and already exists: the editor lights an output port by the
		# level measured on it. Nothing at the node level is added here, which is the
		# finding this row is meant to show rather than hide.
		if not graph.port_levels.has(String(node.name)):
			graph.port_levels[String(node.name)] = {}
		for index in node.get_output_port_count():
			graph.port_levels[String(node.name)][index] = 1.0


## The node, plus air, out of the viewport.
func crop(node: GraphNode) -> Image:
	var shot := root.get_texture().get_image()
	var rect := node.get_global_rect().grow(AIR)
	rect = rect.intersection(Rect2(Vector2.ZERO, Vector2(shot.get_size())))
	return shot.get_region(Rect2i(rect))


## Tiles crops into one sheet, on the canvas colour, at their own sizes.
func tile(shots: Array, columns: int, path: String) -> void:
	var wide := 0
	var tall := 0
	for shot: Image in shots:
		wide = maxi(wide, shot.get_width())
		tall = maxi(tall, shot.get_height())
	var rows := int(ceil(float(shots.size()) / float(columns)))
	var sheet := Image.create(columns * (wide + AIR) + AIR, rows * (tall + AIR) + AIR,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Design.SURFACES[Design.Surface.CANVAS])
	for i in shots.size():
		var shot: Image = shots[i]
		shot.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(shot, Rect2i(Vector2i.ZERO, shot.get_size()), Vector2i(
			AIR + (i % columns) * (wide + AIR), AIR + (i / columns) * (tall + AIR)))
	sheet.save_png(path)


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1440, 900))
	root.content_scale_size = Vector2i(1440, 900)
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	await main._load_example("First Synth")
	await settle(14)
	main._set_roll_open(false)
	await settle(8)
	graph = main.graph_edit
	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)

	var specimen := widget_of(SPECIMEN)
	# Centred on the specimen, so it is not half off the edge of the viewport when the
	# crop is taken.
	graph.zoom = 1.0
	await settle(4)
	graph.scroll_offset = (specimen.position_offset + specimen.size * 0.5) * graph.zoom \
		- graph.size * 0.5
	await settle(6)

	# The eight, at the size a reader actually sees.
	var eight: Array = []
	for state: Dictionary in STATES:
		wear(specimen, state)
		await settle(3)
		var shot := crop(specimen)
		shot.save_png("%s/state-%s.png" % [folder, state["name"]])
		eight.append(shot)
	tile(eight, 2, "%s/state-eight.png" % folder)

	# The three that have to survive reduction, at the three zooms.
	var bands: Array = []
	for zoom: float in ZOOMS:
		graph.zoom = zoom
		await settle(4)
		graph.scroll_offset = (specimen.position_offset + specimen.size * 0.5) * zoom \
			- graph.size * 0.5
		await settle(6)
		for name: String in SURVIVORS:
			for state: Dictionary in STATES:
				if str(state["name"]) != name:
					continue
				wear(specimen, state)
				await settle(3)
				bands.append(crop(specimen))
	tile(bands, SURVIVORS.size(), "%s/state-bands.png" % folder)

	# The envelope's stage prototype: the whole contour, one segment live.
	graph.zoom = 1.0
	await settle(4)
	var envelope := widget_of(ENVELOPE)
	graph.scroll_offset = (envelope.position_offset + envelope.size * 0.5) * graph.zoom \
		- graph.size * 0.5
	await settle(6)
	var stages: Array = []
	for stage in 4:
		envelope.set_meta("active_stage", stage)
		main._style_widget(envelope, str(envelope.get_meta("patch_id")))
		await settle(3)
		stages.append(crop(envelope))
	envelope.remove_meta("active_stage")
	tile(stages, 4, "%s/state-stages.png" % folder)

	# And the whole point: three nodes, three different things true, one picture. If a
	# reader cannot answer the five questions off this one, the vocabulary has failed
	# whatever the isolated specimens looked like.
	main._apply_health({str(widget_of(SPECIMEN).get_meta("patch_id")): 1})
	graph.set_selected(widget_of(GAIN))
	envelope.set_meta("active_stage", 1)
	for node: GraphNode in [widget_of(SPECIMEN), widget_of(GAIN), envelope]:
		main._style_widget(node, str(node.get_meta("patch_id")))
	# Cleared first: the eight-state run left levels on the specimen, and a picture that
	# answers the activity question by accident is not evidence.
	graph.port_levels.clear()
	for lit: GraphNode in [widget_of(SPECIMEN), envelope]:
		graph.port_levels[String(lit.name)] = {0: 1.0}
	# The three that are wearing something, not the whole patch. A picture fitted to
	# seven nodes lands at a third of a zoom, where the question is whether states
	# survive reduction — which the bands sheet already answers. This one is about
	# whether three facts can be told apart at a size somebody reads at.
	var box := Rect2()
	var first := true
	for node: GraphNode in [widget_of(SPECIMEN), widget_of(GAIN), envelope]:
		var rect := Rect2(node.position_offset, node.size)
		box = rect if first else box.merge(rect)
		first = false
	# Fitted rather than set. Choosing a zoom and then centring on the patch's own
	# bounding box are two different operations, and doing the second with a zoom that
	# does not fit is how the first run of this produced a picture of empty canvas.
	graph.zoom = clampf(minf(graph.size.x / box.size.x, graph.size.y / box.size.y) * 0.88,
		0.35, 1.0)
	await settle(4)
	graph.scroll_offset = box.get_center() * graph.zoom - graph.size * 0.5
	await settle(10)
	# The canvas only. The toolbar, the roll and the side panel are not what is being
	# proved here and they are two thirds of the window.
	var whole := root.get_texture().get_image()
	whole.get_region(Rect2i(graph.get_global_rect().intersection(
		Rect2(Vector2.ZERO, Vector2(whole.get_size()))))).save_png(
			"%s/state-mixed.png" % folder)

	# And the same three facts at a size somebody reads at. The fitted picture above
	# lands near a third of a zoom because the three nodes wearing something sit at
	# opposite corners of the patch, so it answers "do these survive reduction" — which
	# is worth knowing and is not the same question as "can these be told apart".
	graph.zoom = 1.0
	await settle(4)
	var pair := Rect2(widget_of(SPECIMEN).position_offset, widget_of(SPECIMEN).size) 		.merge(Rect2(widget_of(GAIN).position_offset, widget_of(GAIN).size))
	graph.scroll_offset = pair.get_center() * graph.zoom - graph.size * 0.5
	await settle(10)
	var close := root.get_texture().get_image()
	close.get_region(Rect2i(graph.get_global_rect().intersection(
		Rect2(Vector2.ZERO, Vector2(close.get_size()))))).save_png(
			"%s/state-mixed-close.png" % folder)

	print("eight states, %d bands, four stages, one mixed patch -> %s"
		% [bands.size(), folder])
	quit()
