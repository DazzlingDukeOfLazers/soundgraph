extends SceneTree

## Step 1 of the graph-node pass: what the graph is, before anything is restyled.
##
## Four zooms, one patch, every measurement the plan asks to freeze — node boxes, port
## positions, cable ends, what each node is showing, and whether its own name fits in it.
## Written to a file rather than read off a screenshot, because "the same patch opens the
## same way afterwards" is a claim about numbers.

## Where the pictures and the record go. Handed in, because a path to somebody's machine
## in a file everybody runs is a path that is wrong for everybody else.
##
##   godot --path editor-godot --script graph_baseline.gd
##
## with GRAPH_BASELINE_OUT set to a directory, or the project's own folder by default.
const ZOOMS := [1.0, 0.66, 0.40, 0.28]
const PatchGraph := preload("res://patch_graph.gd")


func out_dir() -> String:
	var asked := OS.get_environment("GRAPH_BASELINE_OUT")
	return asked if asked != "" else ProjectSettings.globalize_path("res://")


func settle(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1440, 900))
	root.content_scale_size = Vector2i(1440, 900)
	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await settle(16)
	await main._load_example("First Synth")
	await settle(14)
	main._set_roll_open(false)
	await settle(6)

	var graph = main.graph_edit
	var record := {
		"patch": "First Synth",
		"detail_mode": "ONE_TO_ONE" if graph.detail_mode == 1 else "ADAPTIVE",
		"ui_scale": Design.SCALE_NAMES[Design.ui_scale],
		"window": [1440, 900],
		"nodes": [],
		"connections": [],
		"zooms": [],
	}

	# The document's own topology, which no visual pass may touch.
	for child in graph.get_children():
		var node := child as GraphNode
		if node == null or not node.visible:
			continue
		var ports := {"in": [], "out": []}
		for index in node.get_input_port_count():
			ports["in"].append({
				"type": node.get_input_port_type(index),
				"at": [snappedf(node.get_input_port_position(index).x, 0.1),
					snappedf(node.get_input_port_position(index).y, 0.1)],
			})
		for index in node.get_output_port_count():
			ports["out"].append({
				"type": node.get_output_port_type(index),
				"at": [snappedf(node.get_output_port_position(index).x, 0.1),
					snappedf(node.get_output_port_position(index).y, 0.1)],
			})
		record["nodes"].append({
			"name": str(node.name),
			"title": node.title,
			"at": [node.position_offset.x, node.position_offset.y],
			"size": [node.size.x, node.size.y],
			"ports": ports,
		})
	for wire in graph.get_connection_list():
		record["connections"].append({
			"from": str(wire["from_node"]), "out": int(wire["from_port"]),
			"to": str(wire["to_node"]), "in": int(wire["to_port"]),
		})

	for zoom: float in ZOOMS:
		graph.zoom = zoom
		await settle(8)
		var at_zoom := {
			"zoom": zoom,
			"detail": graph.detail,
			"adaptive_would_be": graph.level_for(zoom),
			"nodes": [],
		}
		for child in graph.get_children():
			var node := child as GraphNode
			if node == null or not node.visible:
				continue
			var title_label: Label = null
			for part in node.get_titlebar_hbox().get_children():
				if part is Label:
					title_label = part
			var showing := 0
			var queue: Array = [node]
			while not queue.is_empty():
				var next: Node = queue.pop_front()
				for grandchild in next.get_children():
					var control := grandchild as Control
					if control == null:
						continue
					if control.is_visible_in_tree() and (control is Label
							or control.get_class().contains("Button")):
						showing += 1
					queue.append(control)
			# The title a reader actually sees. Under a screen minimum the node's own
			# Label is hidden and the overlay draws the name at a pinned size in the
			# room the node has on screen — which is where "Main..." comes from, and
			# it is nothing to do with the Label's own width.
			var name_shown := node.title
			var fits := true
			var pinned := Design.type(Design.SIZE_NODE_TITLE)
			var compensated := Design.below_screen_minimum(pinned, zoom,
				Design.screen_minimum(Design.MIN_SCREEN_NODE_TITLE))
			if compensated:
				var font := Design.font(Design.WEIGHT_SEMIBOLD)
				var drawn_size := Design.screen_minimum(Design.MIN_SCREEN_NODE_TITLE)
				var room: float = node.size.x * zoom - 12.0
				if room < 20.0:
					name_shown = ""
					fits = false
				else:
					# Asked of the drawing code rather than worked out again here. The
					# first version of this file reimplemented the elision, which meant
					# it went on reporting cut names after the renderer had stopped
					# cutting them — a measurement that agrees with itself instead of
					# with the program.
					name_shown = PatchGraph.ScreenText._name_for(node, font,
						drawn_size, room)
					fits = name_shown == node.title
			at_zoom["nodes"].append({
				"name": str(node.name),
				"screen_size": [snappedf(node.size.x * zoom, 0.1),
					snappedf(node.size.y * zoom, 0.1)],
				"title": name_shown,
				"compensated": compensated,
				"title_fits": fits,
				"compact_name": str(node.get_meta("compact_name", "")),
				"controls_visible": showing,
			})
		record["zooms"].append(at_zoom)
		# Centred on the patch's own bounding box at this zoom. Fitting and then setting
		# the zoom is not the same thing — fit chooses a zoom of its own and the scroll
		# it leaves behind belongs to that one, which is how the first run of this
		# produced four pictures of the top-left corner.
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
		root.get_texture().get_image().save_png(
			out_dir().path_join("baseline-%d.png") % roundi(zoom * 100.0))

	var file := FileAccess.open(out_dir().path_join("graph-baseline.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(record, "  "))
	file.close()
	print("nodes=", record["nodes"].size(), " connections=", record["connections"].size())
	for entry: Dictionary in record["zooms"]:
		# Three states, not two. A name that was swapped for its compact form is not a
		# name that was cut, and counting them together is how a fix looks like nothing
		# happening.
		var canonical := 0
		var compacted := 0
		var cut := 0
		var controls := 0
		for node: Dictionary in entry["nodes"]:
			if bool(node["title_fits"]):
				canonical += 1
			elif str(node["title"]) == str(node["compact_name"]) 					and str(node["compact_name"]) != "":
				compacted += 1
			else:
				cut += 1
			controls += int(node["controls_visible"])
		print("zoom %.0f%%  detail=%d  titles: %d canonical, %d compact, %d cut  controls=%d"
			% [entry["zoom"] * 100.0, entry["detail"], canonical, compacted, cut,
				controls])
	quit()
