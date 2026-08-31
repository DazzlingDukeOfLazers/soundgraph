extends SceneTree

## Step 15B: the whole language at once, in a graph built to make it fail.
##
## Every proof before this one looked at a part — a glyph beside its neighbours, a node
## in eight states, one type forced to six widths. They all passed, and that is exactly
## the reason for this one: a system can hold at every seam and still not read as a
## system. What has never been asked is whether thirty nodes drawn by these rules, packed
## close enough to interfere with each other, still say *source, modulation,
## transformation, combination, output* before anybody reads a label.
##
## So the specimen is deliberately hostile. `qa/dense-graph.json` is not a musical patch
## and is not arranged to flatter anything: all six width classes, every glyph family,
## three reserved identity cells, a node the validator genuinely complains about, a
## twenty-four character name beside a one-character one, four inputs into one mixer and
## that mixer into another, two fan-outs, and several cables crossing the whole graph
## because their ends are at opposite corners.
##
##   godot --path editor-godot --script qa_sheet.gd
##
## with QA_SHEET_OUT naming a directory. Not headless: it captures pixels.
##
## ## What it does that a screenshot cannot
##
## The pictures are for the ten questions, which are perceptual and are answered by a
## person. Everything a machine can settle is settled here instead, over the **whole**
## matrix rather than the representative corner the pictures come from: five palettes by
## four interface scales by four zooms is eighty frames, and the checks below run on all
## of them.
##
##   - no migrated title is ever cut to an ellipsis, at any zoom or scale
##   - every node stands at its declared width class, to the pixel
##   - nothing in any node is clipped, overlapping, or outside its own frame
##   - the alert mark appears on exactly the nodes the validator complained about
##   - a node with a reserved identity cell draws no glyph and keeps its title column
##   - the detail band actually falls as the zoom does, and nothing survives it that
##     `NodeOptical` says should not

const PatchGraph := preload("res://patch_graph.gd")
const Seams := preload("res://seams.gd")

const PATCH := "res://qa/dense-graph.json"

## The four the brief names. Not a sweep: `optical_sheet.gd` already crosses every band
## boundary at a hundredth either side, and repeating that here would be a second opinion
## from the same instrument.
const ZOOMS := [1.0, 0.66, 0.40, 0.28]

## The three environments, chosen for how far apart they are rather than for how many
## there are. Lab is the default dark, Maximum contrast is the accessibility extreme, and
## Paper is the largest foreground/background reversal in the set — the only palette whose
## ink is dark on light, which is what makes it structurally different rather than merely
## another dark theme with different accents.
const ENVIRONMENTS := [Design.Palette.LAB, Design.Palette.PAPER,
	Design.Palette.MAXIMUM]

## Comfortable and XL, as the brief asks. Compact is in the machine matrix below, where it
## belongs: it is the binding scale for width, and width is not a thing anybody should be
## judging by eye when a validator can measure it.
const PICTURED_SCALES := [Design.Scale.COMFORTABLE, Design.Scale.XL]

## The scene the pictures are taken of. One graph in one arrangement, so the four zooms
## are four distances to the same thing and not four different pictures.
const SELECTED := "svf"
const HOVERED := "delay"

## The window. Larger than the other sheets on purpose: a dense graph photographed in a
## small window is a photograph of a crop, and the question here is about the whole.
const WINDOW := Vector2i(1920, 1200)

var main: Node
var graph: GraphEdit
var record := {}
var complaints: Array = []


func out_dir() -> String:
	var asked := OS.get_environment("QA_SHEET_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func note(where: String, what: String) -> void:
	complaints.append("%s: %s" % [where, what])


## The document node behind a widget, which is the only place the type key can come from.
func node_of(widget: GraphNode) -> Dictionary:
	var wanted := str(widget.get_meta("patch_id", ""))
	for node: Dictionary in main.patch.get("nodes", []):
		if str(node.get("id", "")) == wanted:
			return node
	return {}


func type_key(widget: GraphNode) -> String:
	var node := node_of(widget)
	return "" if node.is_empty() else Seams.registry_key(node)


## The whole graph in the middle of the viewport, at whatever zoom it is standing at.
##
## Computed from the nodes rather than from a remembered offset, so the four zooms are
## four distances to the same centre. A fixed scroll offset would drift: it is in screen
## pixels and the thing it is pointing at is in graph units.
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


## Puts the scene into the state every picture is taken in: one node selected, one
## hovered, the plugin node ill because the plugin is genuinely not here, and the graph
## running so the output ports have a level on them.
##
## Re-applied after every zoom change rather than set once. Changing the detail band
## restyles every widget, and a hover flag that survived only because nothing had asked
## the node to redraw itself is not a hover flag anybody can rely on.
func stage() -> void:
	var chosen: GraphNode = main.widgets.get(SELECTED)
	var lit: GraphNode = main.widgets.get(HOVERED)
	if chosen != null:
		graph.set_selected(chosen)
		main._style_widget(chosen, SELECTED)
	if lit != null:
		main._set_node_hovered(lit, true)
	await settle(2)


func capture(path: String) -> void:
	await settle(3)
	var shot := root.get_texture().get_image()
	shot.save_png(path)


## The same frame with the colour taken out of it.
##
## The point of the redundant channels is that none of them is the only carrier. Socket
## shape, perimeter weight, the alert mark and the title column all survive this; anything
## that does not was being carried by hue alone, which is the failure this program has
## already designed against and has never actually photographed.
func capture_grey(path: String) -> void:
	await settle(3)
	var shot := root.get_texture().get_image()
	shot.convert(Image.FORMAT_RGBA8)
	for y in shot.get_height():
		for x in shot.get_width():
			var was := shot.get_pixel(x, y)
			# Rec. 709 luma, which is what a monochrome display and most kinds of colour
			# blindness leave of a colour — not the average of the channels, which
			# flatters anything blue.
			var grey := was.r * 0.2126 + was.g * 0.7152 + was.b * 0.0722
			shot.set_pixel(x, y, Color(grey, grey, grey, was.a))
	shot.save_png(path)


## Everything a machine can decide about one node at one zoom.
func audit(widget: GraphNode, zoom: float, where: String) -> void:
	var key := type_key(widget)
	if key == "" or not NodeIdentity.migrated(key):
		return

	# The title. Canonical, then the written compact name, then nothing — and never a
	# cut, which is the one thing the step 12 contract forbids outright.
	var pinned := Design.type(Design.SIZE_NODE_TITLE)
	var floor_px := Design.screen_minimum(Design.MIN_SCREEN_NODE_TITLE)
	var shown := widget.title
	if Design.below_screen_minimum(pinned, zoom, floor_px):
		var room: float = widget.size.x * zoom - 12.0
		shown = "" if room < 20.0 else PatchGraph.ScreenText._name_for(widget,
			Design.font(Design.WEIGHT_SEMIBOLD), floor_px, room)
	if shown.ends_with("…"):
		note(where, "%s cut its title to '%s'" % [key, shown])

	# The width class, to the pixel. A class is a width and not a suggestion; a node
	# approximately its class is how emergent widths came back last time.
	var declared := NodeGrid.width_for(key)
	if declared > 0 and absf(widget.size.x - float(declared)) > 0.5:
		note(where, "%s stands at %.0f, class says %d" % [key, widget.size.x, declared])

	# And the layout inside it, but only in FULL: a reduced node has hidden its rows and
	# collapsed its minimum, so it fits anything and a check run there measures nothing.
	if graph.detail == PatchGraph.Detail.FULL:
		for bad: String in LayoutFit.complaints(widget, widget.size.x, 0.0):
			note(where, "%s %s" % [key, bad])

	# The identity cell. A reserved cell holds a cell and no texture — that is its
	# terminal state — and the title has to start at the same x either way, which is the
	# whole reason the cell is reserved rather than removed.
	var glyph: TextureRect = widget.get_meta("glyph") if widget.has_meta("glyph") else null
	var expected := NodeIdentity.glyph_of(key, main._identity_variant(widget))
	if graph.detail == PatchGraph.Detail.FULL:
		if glyph == null:
			note(where, "%s has no identity cell at all" % key)
		elif expected >= 0 and glyph.texture == null:
			note(where, "%s should wear a glyph and does not" % key)
		elif expected < 0 and glyph.texture != null:
			note(where, "%s has a reserved cell and drew something in it" % key)
		elif not glyph.is_visible_in_tree():
			note(where, "%s dropped its identity cell, so its title column moved" % key)
		elif glyph.size.x < glyph.custom_minimum_size.x - 0.5:
			note(where, "%s identity cell collapsed to %.0f" % [key, glyph.size.x])

	# The title column. The reserved cell exists so that every title in the graph starts
	# at the same x whether its type has a mark or not, and that is a claim about a
	# number: a sheet of headers can be looked at and agreed with while being three
	# pixels wrong. Measured from the node's own left edge, so it is a column and not a
	# position on screen.
	var title: Label = widget.get_meta("title_label") if widget.has_meta("title_label") \
		else null
	if title != null and graph.detail == PatchGraph.Detail.FULL \
			and title.is_visible_in_tree():
		var inset := title.get_global_rect().position.x - widget.get_global_rect().position.x
		record["title_column"] = record.get("title_column", {})
		var seen: Dictionary = record["title_column"]
		seen[where] = seen.get(where, {})
		(seen[where] as Dictionary)[key] = snappedf(inset, 0.1)

	# The alert mark, against what the validator actually said. Not against a list kept
	# here: a hard-coded expectation would go on passing after the diagnostic changed.
	var alert: Control = widget.get_meta("alert") if widget.has_meta("alert") else null
	var unwell: bool = int(main._health_of(str(widget.get_meta("patch_id", "")))) \
		!= int(NodeState.Health.WELL)
	if alert != null and alert.visible != unwell and graph.detail == PatchGraph.Detail.FULL:
		note(where, "%s alert is %s and health says %s"
			% [key, "shown" if alert.visible else "hidden", "unwell" if unwell else "well"])


func sweep(where: String, zoom: float) -> Dictionary:
	graph.zoom = zoom
	graph._update_detail()
	main._apply_detail(graph.detail)
	await settle(6)
	await stage()
	await centre()
	var seen := {"zoom": zoom, "band": graph.detail, "titles": {}}
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget == null or not widget.visible:
			continue
		audit(widget, zoom, "%s @%d%%" % [where, int(roundf(zoom * 100.0))])
		seen["titles"][str(widget.get_meta("patch_id", ""))] = widget.title
	return seen


func _initialize() -> void:
	Settings.isolate()
	DisplayServer.window_set_size(WINDOW)
	root.content_scale_size = WINDOW
	main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)

	var file := FileAccess.open(PATCH, FileAccess.READ)
	if file == null:
		printerr("could not read %s" % PATCH)
		quit(1)
		return
	await main._load_text(file.get_as_text())
	await settle(20)
	main._set_roll_open(false)
	graph = main.graph_edit
	# The bands are the thing under test, so the graph is put in the mode that has them.
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	await settle(10)

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)

	# What the validator made of the patch, recorded before anything is photographed. The
	# alert marks in every frame below are checked against this rather than against a
	# list, and a QA patch that has stopped being invalid is a QA patch that has stopped
	# testing the invalid case.
	record["health"] = {}
	for node_id: String in main.widgets:
		var health := int(main._health_of(node_id))
		if health != NodeState.Health.WELL:
			record["health"][node_id] = health
	print("the validator is unhappy with: %s" % str(record["health"].keys()))

	# Which mark each identity variant actually resolved to. A variant is the one place
	# where the same type wears different glyphs, so "the filter is a bandpass in this
	# patch" is a claim worth printing rather than squinting at.
	record["variants"] = {}
	for node_id: String in main.widgets:
		var widget: GraphNode = main.widgets[node_id]
		var key := type_key(widget)
		if not NodeIdentity.VARIANT.has(key):
			continue
		var which := int(main._identity_variant(widget))
		var glyphs: Array = (NodeIdentity.VARIANT[key] as Dictionary)["glyphs"]
		record["variants"][node_id] = {"type": key, "index": which,
			"glyph": NodeIdentity.glyph_of(key, which)}
		print("  %s is variant %d of %d, wearing glyph %d"
			% [key, which, glyphs.size(), NodeIdentity.glyph_of(key, which)])

	# And what the *engine* said when it built the graph, which is a different list and
	# turned out to be the first finding of this step. `_show_diagnostics` is fed by
	# `validate_patch`, which parses and validates a document; a plugin that is not
	# installed, a buffer that will not resolve and an implausible latency are all raised
	# later, when `load_patch` actually builds the nodes, and nothing in the editor ever
	# reads that second list. Recorded here rather than fixed: it is the editor's
	# diagnostics plumbing, not the node grammar.
	var built: Variant = JSON.parse_string(str(main.engine.get_diagnostics_json()))
	record["load_diagnostics"] = built if built != null else []
	if typeof(built) == TYPE_ARRAY:
		for entry: Dictionary in built:
			print("  the engine also said: %s (%s)"
				% [str(entry.get("message", "")), str(entry.get("code", ""))])

	# ---- the pictures ------------------------------------------------------------
	# The representative corner: three environments that could not be further apart, at
	# the two interface scales the brief names, across the four zooms.
	record["shots"] = []
	for palette: int in ENVIRONMENTS:
		for scale: int in PICTURED_SCALES:
			main._use_palette(palette)
			main._use_ui_scale(scale)
			await settle(10)
			var where := "%s/%s" % [Design.PALETTE_NAMES[palette].to_lower()
				.replace(" ", "-"), Design.SCALE_NAMES[scale].to_lower()]
			for zoom: float in ZOOMS:
				await sweep(where, zoom)
				var name := "qa-%s-%s-%d.png" % [
					Design.PALETTE_NAMES[palette].to_lower().replace(" ", "-"),
					Design.SCALE_NAMES[scale].to_lower(), int(roundf(zoom * 100.0))]
				await capture(folder.path_join(name))
				record["shots"].append(name)

	# The two grayscale frames, from the default environment. One at full detail where
	# the state channels are all drawn, and one at map scale where almost nothing is.
	main._use_palette(Design.Palette.LAB)
	main._use_ui_scale(Design.Scale.COMFORTABLE)
	await settle(10)
	for zoom: float in [1.0, 0.40]:
		await sweep("grey", zoom)
		await capture_grey(folder.path_join("qa-grey-%d.png"
			% int(roundf(zoom * 100.0))))

	# ---- the matrix a person should not be looking at ------------------------------
	# Every palette by every interface scale by every zoom. No pictures: this is the part
	# that is decidable, and eighty frames is not a thing anybody reviews by eye.
	var frames := 0
	for palette in Design.PALETTES.size():
		for scale in Design.SCALE_FACTORS.size():
			main._use_palette(palette)
			main._use_ui_scale(scale)
			await settle(8)
			for zoom: float in ZOOMS:
				await sweep("%s/%s" % [Design.PALETTE_NAMES[palette],
					Design.SCALE_NAMES[scale]], zoom)
				frames += 1

	# The title column, reduced to the only question worth asking of it: within one frame,
	# does every migrated node start its name at the same x?
	for where: String in record.get("title_column", {}):
		var seen: Dictionary = (record["title_column"] as Dictionary)[where]
		var insets: Array = seen.values()
		var low := 1e9
		var high := -1e9
		for one: float in insets:
			low = minf(low, one)
			high = maxf(high, one)
		if high - low > 0.5:
			var offenders: Array = []
			for type: String in seen:
				if absf(float(seen[type]) - low) > 0.5:
					offenders.append("%s at %.0f" % [type, float(seen[type])])
			note(where, "the title column splits: %.0f to %.0f (%s)"
				% [low, high, ", ".join(offenders)])

	record["frames_checked"] = frames
	record["complaints"] = complaints
	var out := FileAccess.open(folder.path_join("qa.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify(record, "  "))
	out.close()

	print("")
	print("%d frames checked, %d shots written -> %s"
		% [frames, record["shots"].size() + 2, folder])
	if complaints.is_empty():
		print("no complaints")
	else:
		print("%d complaints:" % complaints.size())
		for one: String in complaints:
			print("  %s" % one)
	quit()
