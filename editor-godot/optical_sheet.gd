extends SceneTree

## Step 12's audit: does the adaptive-detail machinery honour an explicit contract?
##
## The machinery is not new. Step 1 measured it, and it already sheds parameter rows and
## then the whole control panel as the zoom falls; what it has never had is a written
## statement of what each band is *for*, which is the difference between behaviour and a
## contract. `NodeOptical` is the statement and this is the check.
##
## Two things it does that a screenshot cannot:
##
## **It sweeps.** Testing at 100, 66, 40 and 28 tells you what four zooms look like. What
## goes wrong in a level-of-detail system goes wrong at the *transitions* — a title
## jumping, a value orphaned by the control it belonged to, a name reaching for its
## compact form early. So every boundary is crossed at a hundredth either side and both
## sides are recorded.
##
## **It counts ellipses.** The step 3 rule is canonical, then the written-down compact
## name, then and only then a cut. For a type that has been through the pass a cut is a
## failure, and the sweep reports the number rather than leaving it to somebody's eye.
##
##   godot --path editor-godot --script optical_sheet.gd
##
## with OPTICAL_SHEET_OUT naming a directory. Not headless: it captures pixels.

const PatchGraph := preload("res://patch_graph.gd")

## The three proving-ground nodes as they are named in First Synth, and the four that
## have not been through the pass — kept so the sheet shows the difference rather than
## asserting it.
const MIGRATED := ["Amplifier", "Lowpass", "Amp Envelope"]
const SPECIMEN := "Lowpass"

## Where the whole patch is photographed, which is what the brief asks for and what a
## reader recognises.
const PATCH_ZOOMS := [1.0, 0.66, 0.40, 0.28]

## How far either side of a boundary the sweep looks. One hundredth: close enough that
## nothing else has changed, far enough that the band certainly has.
const STRADDLE := 0.01

## The magnification on the diagnostic sheet. The first sheet judges design at the size a
## reader sees; this one diagnoses rendering, and a pixel you cannot see is a pixel you
## cannot diagnose.
const MAGNIFY := 3
const AIR := 16

var main: Node
var graph: GraphEdit


func out_dir() -> String:
	var asked := OS.get_environment("OPTICAL_SHEET_OUT")
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


## Everything the sweep needs to know about one node at one zoom.
##
## The title is asked of the renderer rather than worked out here. The step 1 baseline
## reimplemented the elision and went on reporting cut names after the renderer had
## stopped cutting them — a measurement that agrees with itself instead of with the
## program.
func facts(node: GraphNode, zoom: float) -> Dictionary:
	var controls := 0
	var labels := 0
	var queue: Array = [node]
	while not queue.is_empty():
		var next: Node = queue.pop_front()
		for child in next.get_children():
			var control := child as Control
			if control == null:
				continue
			if control.is_visible_in_tree():
				if control.get_class().contains("Button") or control is OptionButton:
					controls += 1
				elif control is Label:
					labels += 1
			queue.append(control)

	var pinned := Design.type(Design.SIZE_NODE_TITLE)
	var compensated := Design.below_screen_minimum(pinned, zoom,
		Design.screen_minimum(Design.MIN_SCREEN_NODE_TITLE))
	var shown := node.title
	if compensated:
		var room: float = node.size.x * zoom - 12.0
		if room < 20.0:
			shown = ""
		else:
			shown = PatchGraph.ScreenText._name_for(node,
				Design.font(Design.WEIGHT_SEMIBOLD),
				Design.screen_minimum(Design.MIN_SCREEN_NODE_TITLE), room)
	var glyph: Control = node.get_meta("glyph") if node.has_meta("glyph") else null
	var alert: Control = node.get_meta("alert") if node.has_meta("alert") else null
	return {
		"title": node.title,
		"shown": shown,
		"compensated": compensated,
		# The one thing that is allowed to be true of an unmigrated type and must never
		# be true of a migrated one.
		"elided": shown.ends_with("…"),
		"controls": controls,
		"labels": labels,
		"glyph": glyph != null and glyph.is_visible_in_tree() \
			and glyph.self_modulate.a > 0.0,
		"alert": alert != null and alert.visible,
		"screen": [snappedf(node.size.x * zoom, 0.1), snappedf(node.size.y * zoom, 0.1)],
	}


func look(zoom: float) -> Dictionary:
	graph.zoom = zoom
	await settle(4)
	var at := {"zoom": snappedf(zoom, 0.001),
		"band": PatchGraph.level_for(zoom), "nodes": {}}
	for child in graph.get_children():
		var node := child as GraphNode
		if node != null and node.visible:
			at["nodes"][node.title] = facts(node, zoom)
	return at


## The node, plus air, out of the viewport.
func crop(node: GraphNode) -> Image:
	var shot := root.get_texture().get_image()
	var rect := node.get_global_rect().grow(AIR)
	rect = rect.intersection(Rect2(Vector2.ZERO, Vector2(shot.get_size())))
	return shot.get_region(Rect2i(rect))


func centre_on(node: GraphNode) -> void:
	graph.scroll_offset = (node.position_offset + node.size * 0.5) * graph.zoom \
		- graph.size * 0.5
	await settle(6)


## Tiles crops left to right at their own sizes, optionally magnified.
func tile(shots: Array, path: String, times: int = 1) -> void:
	var wide := 0
	var tall := 0
	for shot: Image in shots:
		wide = maxi(wide, shot.get_width() * times)
		tall = maxi(tall, shot.get_height() * times)
	var sheet := Image.create(shots.size() * (wide + AIR) + AIR, tall + AIR * 2,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Design.SURFACES[Design.Surface.CANVAS])
	for i in shots.size():
		var shot: Image = shots[i]
		shot.convert(Image.FORMAT_RGBA8)
		if times > 1:
			shot.resize(shot.get_width() * times, shot.get_height() * times,
				Image.INTERPOLATE_NEAREST)
		sheet.blit_rect(shot, Rect2i(Vector2i.ZERO, shot.get_size()),
			Vector2i(AIR + i * (wide + AIR), AIR + (tall - shot.get_height()) / 2))
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

	var record := {"ui_scale": Design.SCALE_FACTORS[Design.ui_scale], "bands": {},
		"sweep": [], "patch": []}

	# Where the boundaries actually are, at every interface scale. Written down because
	# the contract is a claim about zooms and a claim about zooms should carry its
	# numbers.
	var was := Design.ui_scale
	for scale in Design.SCALE_FACTORS.size():
		Design.ui_scale = scale
		record["bands"][["Small", "Comfortable", "Large", "XL"][scale]] = {
			"full": snappedf(PatchGraph._full_floor(), 0.001),
			"compact": snappedf(PatchGraph.compact_floor(), 0.001),
			"summary": snappedf(PatchGraph.summary_floor(), 0.001),
			"value_px": Design.type(Design.SIZE_NUMERIC),
		}
	Design.ui_scale = was

	# The sweep. Every boundary crossed at a hundredth either side, plus the four zooms
	# the brief names, plus a coarse pass so a transition nobody predicted still shows.
	var stops := {}
	for zoom: float in PATCH_ZOOMS:
		stops[snappedf(zoom, 0.001)] = true
	for edge: float in [PatchGraph._full_floor(), PatchGraph.compact_floor(),
			PatchGraph.summary_floor()]:
		# Two distances either side, not one. The label drop that this sweep found near
		# the compact floor happens within a hundredth of the band change, and a single
		# straddle cannot say which of the two moved first.
		for offset: float in [-STRADDLE, -STRADDLE * 0.5, 0.0, STRADDLE * 0.5,
				STRADDLE]:
			stops[snappedf(edge + offset, 0.001)] = true
	for i in 16:
		stops[snappedf(1.0 - float(i) * 0.05, 0.001)] = true
	var ladder: Array = stops.keys()
	ladder.sort()
	ladder.reverse()

	var specimen := widget_of(SPECIMEN)
	graph.zoom = 1.0
	await settle(4)
	await centre_on(specimen)
	for zoom: float in ladder:
		if zoom < 0.2:
			continue
		record["sweep"].append(await look(zoom))

	# The design sheet: one node at each of the three optical states, at the size it is
	# actually drawn. No enlargement — the whole question is what this looks like on the
	# glass.
	for title: String in MIGRATED:
		var node := widget_of(title)
		var shots: Array = []
		for zoom: float in NodeOptical.sample_zooms():
			graph.zoom = zoom
			await settle(4)
			await centre_on(node)
			shots.append(crop(node))
		tile(shots, "%s/optical-%s.png" % [folder,
			title.to_lower().replace(" ", "-")])
		tile(shots, "%s/optical-%s-magnified.png" % [folder,
			title.to_lower().replace(" ", "-")], MAGNIFY)

	# The whole patch, migrated and unmigrated together, at the four zooms a reader
	# recognises. One of these is worth more than any specimen: it is where a node that
	# has been through the pass has to look better than the one beside it that has not.
	for zoom: float in PATCH_ZOOMS:
		graph.zoom = zoom
		await settle(4)
		var box := Rect2()
		var first := true
		for child in graph.get_children():
			var node := child as GraphNode
			if node == null or not node.visible:
				continue
			var rect := Rect2(node.position_offset, node.size)
			box = rect if first else box.merge(rect)
			first = false
		graph.scroll_offset = box.get_center() * zoom - graph.size * 0.5
		await settle(8)
		var shot := root.get_texture().get_image()
		shot.get_region(Rect2i(graph.get_global_rect().intersection(
			Rect2(Vector2.ZERO, Vector2(shot.get_size()))))).save_png(
				"%s/optical-patch-%d.png" % [folder, roundi(zoom * 100.0)])
		record["patch"].append(roundi(zoom * 100.0))

	var file := FileAccess.open(folder.path_join("optical-states.json"),
		FileAccess.WRITE)
	file.store_string(JSON.stringify(record, "  "))
	file.close()

	# The verdict, in the terminal, so a run that fails says so without anybody opening
	# a file.
	var cuts := 0
	var transitions := 0
	var last := -1
	for at: Dictionary in record["sweep"]:
		if int(at["band"]) != last:
			transitions += 1
			last = int(at["band"])
		for title: String in MIGRATED:
			if at["nodes"].has(title) and bool(at["nodes"][title]["elided"]):
				cuts += 1
				print("  CUT  %s at zoom %.2f -> %s"
					% [title, at["zoom"], at["nodes"][title]["shown"]])
	print("%d zooms swept, %d band changes, %d elided titles on migrated types -> %s"
		% [record["sweep"].size(), transitions, cuts, folder])
	quit()
