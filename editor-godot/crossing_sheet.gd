extends SceneTree

## Cable pass, goal 1: can a reader tell which strand continues through a crossing?
##
## Only where it is actually hard. The baseline found zero shallow crossings in the hostile
## patch — the per-cable hang and the departure splay have already made every intersection
## transverse — and fifteen of the thirty-two are between cables of the **same colour**.
## Two identical mint strands meeting at a perfectly readable angle is the whole defect, so
## that is the whole of what this sheet photographs.
##
## Four columns, three of them candidates:
##
## [codeblock]
## NONE       nothing at all — the reference, so the sheet shows what a treatment buys
## HALO       a darker halo under the upper cable — the incumbent, shipped at goal 8
## KNOCKOUT   the lower cable erased for a short span, the upper drawn over the gap
## BUMP       the upper cable lifted into a local arc
## [/codeblock]
##
##   godot --path editor-godot --script crossing_sheet.gd
##
## with CROSSING_SHEET_OUT naming a directory. Not headless: it captures pixels.
##
## ## What it measures as well as shows
##
## The eye decides which construction wins. Two things it should not be asked to estimate
## are measured instead, by diffing each frame against the untreated one:
##
##   how many pixels the treatment touches, over the whole graph
##   how much ink it adds or removes, as a signed luminance total
##
## A treatment that says "these cross and do not join" with the least new ink is the one
## the brief is asking for, and "least" is a number.

const PatchGraph := preload("res://patch_graph.gd")
const CableArt := preload("res://cable_art.gd")
const PATCH := "res://qa/dense-graph.json"

## Actual size, and the magnification the crop is also shown at. A crossing judged at 4x is
## not judged; a crossing judged only at 1x cannot be argued with.
const CROP := 96
const MAGNIFY := 4
const AIR := 10

const ZOOMS := [1.0, 0.66, 0.40, 0.28]
const WINDOW := Vector2i(1920, 1200)

var main: Node
var graph: GraphEdit
var cords: CanvasItem


func out_dir() -> String:
	var asked := OS.get_environment("CROSSING_SHEET_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func redraw() -> void:
	cords.queue_redraw()
	await settle(4)


func frame() -> Image:
	var shot := root.get_texture().get_image()
	shot.convert(Image.FORMAT_RGBA8)
	return shot


## The crop around one crossing, clamped into the frame.
func around(shot: Image, at: Vector2) -> Image:
	var origin := Vector2i(at) + Vector2i(cords.global_position) - Vector2i(CROP, CROP) / 2
	origin.x = clampi(origin.x, 0, shot.get_width() - CROP)
	origin.y = clampi(origin.y, 0, shot.get_height() - CROP)
	return shot.get_region(Rect2i(origin, Vector2i(CROP, CROP)))


func tile(rows: Array, columns: int, path: String, times: int) -> void:
	var cell := CROP * times + AIR
	var sheet := Image.create(columns * cell + AIR, rows.size() * cell + AIR,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Design.SURFACES[Design.Surface.CANVAS])
	for r in rows.size():
		var row: Array = rows[r]
		for c in row.size():
			var crop: Image = (row[c] as Image).duplicate()
			if times > 1:
				# Nearest neighbour: a smoothed crop is a picture of a different
				# treatment, and the whole question is what the pixels do.
				crop.resize(CROP * times, CROP * times, Image.INTERPOLATE_NEAREST)
			sheet.blit_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()),
				Vector2i(AIR + c * cell, AIR + r * cell))
	sheet.save_png(path)


## How far one frame is from the untreated one: pixels touched, and signed ink.
##
## Signed, because a knockout *removes* ink and a halo *adds* it, and a single "how
## different" figure would rank them as equally busy. The brief asks for the treatment that
## introduces the least additional ink; that is the positive column.
func against(reference: Image, candidate: Image) -> Dictionary:
	var touched := 0
	var added := 0.0
	var removed := 0.0
	for y in reference.get_height():
		for x in reference.get_width():
			var was := reference.get_pixel(x, y)
			var now := candidate.get_pixel(x, y)
			if absf(was.r - now.r) < 0.004 and absf(was.g - now.g) < 0.004 \
					and absf(was.b - now.b) < 0.004:
				continue
			touched += 1
			var before := was.r * 0.2126 + was.g * 0.7152 + was.b * 0.0722
			var after := now.r * 0.2126 + now.g * 0.7152 + now.b * 0.0722
			if after > before:
				added += after - before
			else:
				removed += before - after
	return {"touched": touched, "ink_added": snappedf(added, 0.1),
		"ink_removed": snappedf(removed, 0.1)}


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
	var file := FileAccess.open(PATCH, FileAccess.READ)
	await main._load_text(file.get_as_text())
	await settle(20)
	main._set_roll_open(false)
	graph = main.graph_edit
	main._choose_detail_mode(PatchGraph.DetailMode.ADAPTIVE)
	graph.zoom = 1.0
	await settle(12)

	# The layer itself, by the one method only it has. Asked for by capability rather
	# than by node name, which nothing sets.
	for child in graph.get_children():
		if child.has_method("crossing_sites"):
			cords = child
	if cords == null:
		printerr("no cord layer; nothing to photograph")
		quit(1)
		return

	var folder := out_dir()
	DirAccess.make_dir_recursive_absolute(folder)

	# The crossings, asked of the layer that draws them. Same-colour only: that is the
	# measured defect and the rest of the sheet would be pictures of cases the colours
	# already answer.
	CableArt.crossing_same_colour_only = true
	var sites: Array = []
	for site: Dictionary in cords.crossing_sites():
		if bool(site["same_colour"]):
			sites.append(site)
	print("%d crossings, %d of them between cables of one colour"
		% [(cords.crossing_sites() as Array).size(), sites.size()])

	# The whole graph is not on screen at 100%, so a crossing has to be scrolled to before
	# it can be photographed. Each is centred in turn and cropped from its own frame.
	var order := [CableArt.Crossing.NONE, CableArt.Crossing.HALO,
		CableArt.Crossing.KNOCKOUT, CableArt.Crossing.BUMP]
	var names := ["none", "halo", "knockout", "bump"]

	# In graph space, once. A site's coordinate is in the layer's space and the layer's
	# space moves with the scroll, so a list of them collected before scrolling is a list
	# of stale numbers the moment the first crop is taken.
	var wanted: Array = []
	for site: Dictionary in sites:
		wanted.append((site["at"] as Vector2 + graph.scroll_offset) / graph.zoom)
	# And every crossing, for the broader-rule comparison at the end.
	var every: Array = []
	for site: Dictionary in cords.crossing_sites():
		every.append((site["at"] as Vector2 + graph.scroll_offset) / graph.zoom)

	var rows: Array = []
	for graph_at: Vector2 in wanted:
		# Asked for, then measured. GraphEdit clamps its own scroll against the content it
		# can reach, so a crossing near the edge of the patch does not arrive in the
		# middle of the view however politely it is asked — which is why the first run of
		# this sheet was fourteen rows of empty canvas. Where it actually landed is
		# arithmetic, so that is what the crop uses.
		graph.scroll_offset = graph_at * graph.zoom - graph.size * 0.5
		await settle(6)
		var here := graph_at * graph.zoom - graph.scroll_offset
		var row: Array = []
		for style: int in order:
			CableArt.crossing_style = style
			await redraw()
			row.append(around(frame(), here))
		rows.append(row)
	tile(rows, order.size(), folder.path_join("crossing-actual.png"), 1)
	# The magnified sheet in halves: sixteen rows at four times is six thousand pixels
	# tall, which is a picture nobody looks at.
	var half := int(ceil(float(rows.size()) * 0.5))
	tile(rows.slice(0, half), order.size(),
		folder.path_join("crossing-magnified-1.png"), MAGNIFY)
	tile(rows.slice(half), order.size(),
		folder.path_join("crossing-magnified-2.png"), MAGNIFY)

	# ---- the ink, at the crossings themselves ---------------------------------------
	# Summed over the crops above rather than diffed across the whole frame. The whole
	# frame was the first attempt and it was not reproducible: three runs gave 908, 940
	# and 890 touched pixels for the same treatment, because something else in the editor
	# moves between captures and a frame-wide diff counts that too. The crops are taken
	# back to back at one scroll position with nothing changed but the construction, so
	# they answer the question that was actually asked — how much ink does the treatment
	# introduce **at a crossing** — and they answer it the same way twice.
	var measured := {}
	for i in order.size():
		var touched := 0
		var added := 0.0
		var removed := 0.0
		for row: Array in rows:
			var one := against(row[0], row[i])
			touched += int(one["touched"])
			added += float(one["ink_added"])
			removed += float(one["ink_removed"])
		measured[names[i]] = {"touched": touched, "ink_added": snappedf(added, 0.1),
			"ink_removed": snappedf(removed, 0.1)}

	# And the same question asked of the broader rule: every crossing treated, not only
	# the same-coloured ones. Shown rather than assumed — a conditional treatment is a
	# rule with an exception in it, and those have to earn their keep.
	CableArt.crossing_same_colour_only = false
	var broad := {"touched": 0, "ink_added": 0.0, "ink_removed": 0.0}
	for graph_at: Vector2 in every:
		graph.scroll_offset = graph_at * graph.zoom - graph.size * 0.5
		await settle(6)
		var here := graph_at * graph.zoom - graph.scroll_offset
		CableArt.crossing_style = CableArt.Crossing.NONE
		await redraw()
		var plain := around(frame(), here)
		CableArt.crossing_style = CableArt.Crossing.KNOCKOUT
		await redraw()
		var one := against(plain, around(frame(), here))
		broad["touched"] = int(broad["touched"]) + int(one["touched"])
		broad["ink_added"] = float(broad["ink_added"]) + float(one["ink_added"])
		broad["ink_removed"] = float(broad["ink_removed"]) + float(one["ink_removed"])
	measured["knockout, every crossing"] = broad
	CableArt.crossing_same_colour_only = true

	print("")
	print("%-26s %10s %12s %12s" % ["treatment", "pixels", "ink added", "ink removed"])
	for key: String in measured:
		var entry: Dictionary = measured[key]
		print("%-26s %10d %12.0f %12.0f" % [key, int(entry["touched"]),
			float(entry["ink_added"]), float(entry["ink_removed"])])

	# ---- the hostile graph, four distances, one candidate at a time -----------------
	for i in order.size():
		CableArt.crossing_style = order[i]
		for zoom: float in ZOOMS:
			graph.zoom = zoom
			graph._update_detail()
			main._apply_detail(graph.detail)
			await settle(6)
			await centre()
			await redraw()
			frame().save_png(folder.path_join("crossing-%s-%d.png"
				% [names[i], int(roundf(zoom * 100.0))]))

	# And the broader rule in the whole graph, because the choice between treating twelve
	# crossings and treating twenty-seven is not settled by an ink count. A treatment that
	# appears at some crossings and not others is a channel that looks like it means
	# something; "were these two the same colour" is not a fact a reader can recover.
	CableArt.crossing_same_colour_only = false
	CableArt.crossing_style = CableArt.Crossing.KNOCKOUT
	for zoom: float in ZOOMS:
		graph.zoom = zoom
		graph._update_detail()
		main._apply_detail(graph.detail)
		await settle(6)
		await centre()
		await redraw()
		frame().save_png(folder.path_join("crossing-knockout-all-%d.png"
			% int(roundf(zoom * 100.0))))
	CableArt.crossing_same_colour_only = true

	CableArt.crossing_style = CableArt.Crossing.HALO
	var out := FileAccess.open(folder.path_join("crossings.json"), FileAccess.WRITE)
	out.store_string(JSON.stringify({"same_colour": sites.size(),
		"ink": measured}, "  "))
	out.close()
	print("")
	print("-> %s" % folder)
	quit()
