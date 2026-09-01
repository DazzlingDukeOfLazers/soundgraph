extends SceneTree

## Goal 4's windowed probe: do the gestures actually reach the lock?
##
## The suite already holds that the lock *functions* focus the right sets. What it cannot
## hold is that a press and a release find them, because headless Godot has no input
## routing at all — a click in a headless run reaches nothing, and a check that passes
## there would be a check of an empty room.
##
## So this opens a real window and pushes real events through `Input.parse_input_event`,
## which is the same path a mouse takes. Not headless, and it cannot be made headless.
##
##   godot --path editor-godot --script cable_gestures.gd
##
## ## The one that matters
##
## The port case, because **GraphEdit owns that pointer interaction for making cables.** A
## press on a socket starts a connection drag; this only notices a press that went nowhere.
## If the two fight, the answer is not to contort the input plumbing to preserve symmetry
## with cable clicks — it is to let port focus stay hover-only and keep cable click plus
## Escape, which is already enough. Interaction grammar follows what the editor can
## reliably tell apart.

const PatchGraph := preload("res://patch_graph.gd")
const PATCH := "res://qa/dense-graph.json"

var main: Node
var graph: GraphEdit
var cords: CanvasItem
var failures := 0


func settle(n: int) -> void:
	for i in n:
		await process_frame


func check(condition: bool, description: String) -> void:
	if condition:
		print("  ok   %s" % description)
	else:
		failures += 1
		print("  FAIL %s" % description)


## A real pointer move, through the same path a mouse takes.
func move_to(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)
	await settle(3)


func click_at(at: Vector2) -> void:
	await move_to(at)
	for pressed in [true, false]:
		var button := InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.pressed = pressed
		button.position = at
		button.global_position = at
		Input.parse_input_event(button)
		await settle(3)
	await settle(4)


## A press, a travel and a release — the gesture that makes a cable, and the one a click
## must not be confused with.
func drag_from(at: Vector2, to: Vector2) -> void:
	await move_to(at)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	Input.parse_input_event(press)
	await settle(2)
	for step in 6:
		await move_to(at.lerp(to, (float(step) + 1.0) / 6.0))
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = to
	release.global_position = to
	Input.parse_input_event(release)
	await settle(4)


func press_key(code: Key) -> void:
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.keycode = code
		key.physical_keycode = code
		key.pressed = pressed
		Input.parse_input_event(key)
		await settle(3)
	await settle(3)


## Whether a window point is somewhere the graph will actually receive a pointer event.
##
## Inside the viewport with room to spare, and **not over a node**. Cables are drawn under
## the nodes and a GraphNode consumes its own motion, so a point on a cable that happens to
## pass behind one never reaches GraphEdit's `_gui_input` at all — and the probe then
## reports that the pointer cannot find a cable when what it cannot find is that pixel.
## Three of this file's first four failures were exactly that.
func pointable(at: Vector2) -> bool:
	var frame := Rect2(Vector2(90.0, 150.0),
		Vector2(root.content_scale_size) - Vector2(440.0, 420.0))
	if not frame.has_point(at):
		return false
	for child in graph.get_children():
		var widget := child as GraphNode
		if widget == null or not widget.visible:
			continue
		if widget.get_global_rect().grow(6.0).has_point(at):
			return false
	return true


## A point on a cable, in window coordinates, that the pointer can actually reach.
##
## Taken from `graph._routes()` rather than from the cord layer's own `_lay()`. They are the
## same geometry, but they are in different spaces and — more to the point — `_routes()` is
## what `_connection_at` picks against, so a point derived from it is a point the hover test
## will agree about. Deriving it from the drawing and testing it against the picker is two
## implementations of one route, which is the mistake this repository keeps catching.
func on_cable(fields: Array) -> Vector2:
	var points := PackedVector2Array()
	for route: Dictionary in graph._routes():
		if route["fields"] == fields:
			points = route["points"]
	if points.size() < 2:
		return Vector2.INF
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	for step in 40:
		var wanted := total * (0.12 + 0.019 * float(step))
		var walked := 0.0
		for i in range(points.size() - 1):
			var span := points[i].distance_to(points[i + 1])
			if walked + span >= wanted and span > 0.0001:
				var graph_at: Vector2 = points[i].lerp(points[i + 1],
					(wanted - walked) / span)
				var at := graph_at * graph.zoom - graph.scroll_offset 					+ graph.global_position
				if pointable(at) and not graph._connection_at(graph_at).is_empty():
					return at
				break
			walked += span
	return Vector2.INF


## Somewhere in the graph with no node and no cable under it.
func empty_canvas() -> Vector2:
	for down in 20:
		for across in 30:
			var at := Vector2(120.0 + float(across) * 44.0, 180.0 + float(down) * 38.0)
			if not pointable(at):
				continue
			if graph._connection_at(graph._to_graph(
					at - graph.global_position)).is_empty():
				return at
	return Vector2(150.0, 950.0)


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


func lay() -> Array:
	return cords._lay()


## A cable whose midsection is inside the window, so a synthetic pointer can land on it.
func reachable_cable() -> Array:
	for route: Dictionary in graph._routes():
		if on_cable(route["fields"]).x != INF:
			return route["fields"]
	return []


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
	await centre()

	var subject: Array = reachable_cable()
	if subject.is_empty():
		printerr("no cable landed inside the window; nothing to click")
		quit(1)
		return
	var where := on_cable(subject)
	print("")
	print("gestures, through Input.parse_input_event, in a real window")

	# ---- the pointer finds the cable at all -----------------------------------------
	await move_to(where)
	check(not graph.hovered_cable.is_empty(),
		"the pointer finds a cable to hover")

	# ---- click to lock, click again to let go ----------------------------------------
	await click_at(where)
	var locked_after_click: bool = not graph.locked_cable.is_empty()
	check(locked_after_click, "clicking a cable locks it")
	if locked_after_click:
		var fields: Array = graph._connection_fields(graph.locked_cable)
		check(fields == subject, "and locks exactly that connection")

	await click_at(where)
	check(graph.locked_cable.is_empty(), "clicking it again lets go")

	# ---- the pointer leaving comes home to the lock ----------------------------------
	await click_at(where)
	var pinned := str(graph.locked_cable.hash())
	await move_to(empty_canvas())
	await settle(4)
	check(str(graph.locked_cable.hash()) == pinned,
		"and taking the pointer off the cable does not let go of it")

	# ---- pan and zoom do not disturb it ----------------------------------------------
	graph.zoom = 0.66
	graph._update_detail()
	main._apply_detail(graph.detail)
	await settle(8)
	graph.scroll_offset += Vector2(240.0, 160.0)
	await settle(6)
	check(str(graph.locked_cable.hash()) == pinned,
		"a locked route survives a zoom and a pan")
	graph.zoom = 1.0
	graph._update_detail()
	main._apply_detail(graph.detail)
	await settle(8)
	await centre()

	# ---- escape lets go, and does not silence the instrument on the way --------------
	await press_key(KEY_ESCAPE)
	check(graph.locked_cable.is_empty(), "Escape lets go of a locked route")

	# ---- empty canvas lets go --------------------------------------------------------
	await click_at(on_cable(subject))
	var had_lock: bool = not graph.locked_cable.is_empty()
	await click_at(empty_canvas())
	check(had_lock and graph.locked_cable.is_empty(),
		"and so does a click on empty canvas")

	# ---- a drag is not a click -------------------------------------------------------
	# The gesture that moves a waypoint must not pin anything on the way past.
	graph.clear_focus_lock()
	var start := on_cable(subject)
	await drag_from(start, start + Vector2(0.0, 70.0))
	check(graph.locked_cable.is_empty(),
		"dragging a cable's waypoint does not lock it")

	# ---- the port case, which GraphEdit owns -----------------------------------------
	graph.clear_focus_lock()
	var port_at := Vector2.INF
	var wanted_port := ""
	for id in main.widgets:
		var widget: GraphNode = main.widgets[id]
		for index in widget.get_output_port_count():
			var at: Vector2 = widget.get_global_position() \
				+ widget.get_output_port_position(index) * graph.zoom
			if at.x > 120.0 and at.y > 180.0 and at.x < 1400.0 and at.y < 950.0:
				port_at = at
				wanted_port = "%s:right:%d" % [str(widget.name), index]
				break
		if port_at.x != INF:
			break
	if port_at.x == INF:
		print("  ---- no output socket landed inside the window; port case not probed")
	else:
		await move_to(port_at)
		var hovered_a_port: bool = graph.focus_port != ""
		check(hovered_a_port, "the pointer finds an output socket to hover")
		await click_at(port_at)
		check(graph.locked_port == wanted_port,
			"clicking a socket locks its family (%s against %s)"
				% [graph.locked_port, wanted_port])
		if graph.locked_port == wanted_port:
			await click_at(port_at)
			check(graph.locked_port == "", "and clicking it again lets go")

		# The gesture that makes a cable, which must survive untouched.
		graph.clear_focus_lock()
		var before_connections: int = graph.get_connection_list().size()
		await drag_from(port_at, port_at + Vector2(260.0, 40.0))
		check(graph.locked_port == "",
			"dragging from a socket does not lock anything")
		check(graph.get_connection_list().size() == before_connections,
			"and a drag that lands on nothing makes no cable")

	graph.clear_focus_lock()
	print("")
	if failures == 0:
		print("all gesture checks passed")
	else:
		print("%d gesture check(s) failed" % failures)
	quit(0 if failures == 0 else 1)
