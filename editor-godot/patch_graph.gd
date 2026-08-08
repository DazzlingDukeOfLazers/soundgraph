extends GraphEdit
## The graph canvas: PCB-style cable routing and draggable wires.
##
## A curved cable that passes straight through a node is unreadable — you cannot tell
## where it goes or what it is connected to. So a cable is drawn as a smooth curve while
## its path is clear, and switches to a routed orthogonal trace, with 45-degree corners,
## when it would otherwise cross something. That is the same reason PCB traces look the
## way they do: legibility around obstacles.
##
## When the router's choice is still not what the user wants, they can drag the cable
## itself. The drag creates a waypoint the route must pass through, stored in the patch
## alongside the node positions, so it survives save and load like any other layout.
##
## Coordinate spaces are the subtle part here, so they are named explicitly:
##   graph space  — what position_offset and get_*_port_position use; what patches store
##   line space   — what _get_connection_line receives and returns: graph space * zoom
##   local space  — mouse events: graph space * zoom - scroll_offset

signal waypoint_changed(from_node: StringName, from_port: int, to_node: StringName,
	to_port: int, point)
## Emitted when a cable drag begins, so the editor can take an undo snapshot before the
## first movement rather than reconstructing where the cable used to be.
signal cable_drag_started

## Extra room left around a node when routing past it.
const CLEARANCE := 26.0
## How far a trace leaves a port before it is allowed to turn.
const STUB := 30.0
## Length of the 45-degree cut at each corner.
const CHAMFER := 14.0
## How close a click must be to a cable to grab it.
const GRAB_DISTANCE := 12.0

## Graph-space point each cable must pass through, keyed by connection.
var waypoints: Dictionary = {}

var _obstacles: Array[Rect2] = []
var _obstacles_frame := -1
var _dragging_key := ""
var _drag_connection: Dictionary = {}


# ---------------------------------------------------------------------------------
# Connection identity
# ---------------------------------------------------------------------------------

static func connection_key(from_node: StringName, from_port: int, to_node: StringName,
		to_port: int) -> String:
	return "%s:%d>%s:%d" % [from_node, from_port, to_node, to_port]


func _connection_fields(connection: Dictionary) -> Array:
	# Godot has used both spellings across 4.x; accept either rather than pinning a
	# version we would then have to chase.
	var from_node = connection.get("from_node", connection.get("from", ""))
	var to_node = connection.get("to_node", connection.get("to", ""))
	return [from_node, int(connection["from_port"]), to_node, int(connection["to_port"])]


## Endpoints of a connection in graph space.
func _endpoints(connection: Dictionary) -> Array:
	var fields := _connection_fields(connection)
	var from_node := get_node_or_null(NodePath(fields[0])) as GraphNode
	var to_node := get_node_or_null(NodePath(fields[2])) as GraphNode
	if from_node == null or to_node == null:
		return []
	return [
		from_node.position_offset + from_node.get_output_port_position(fields[1]),
		to_node.position_offset + to_node.get_input_port_position(fields[3]),
	]


# ---------------------------------------------------------------------------------
# Obstacles
# ---------------------------------------------------------------------------------

func _current_obstacles() -> Array[Rect2]:
	# Recomputed once per frame: nodes move constantly while dragging, and a stale
	# obstacle list means routing around where a node used to be.
	var frame := Engine.get_process_frames()
	if frame == _obstacles_frame:
		return _obstacles
	_obstacles_frame = frame
	_obstacles.clear()
	for child in get_children():
		if child is GraphNode and child.visible:
			_obstacles.append(Rect2(child.position_offset, child.size).grow(CLEARANCE))
	return _obstacles


func _segment_hits_rect(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	if rect.has_point(a) or rect.has_point(b):
		return true
	var corners := [
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	]
	for i in 4:
		if Geometry2D.segment_intersects_segment(a, b, corners[i], corners[(i + 1) % 4]) != null:
			return true
	return false


func _path_is_clear(points: PackedVector2Array, ignore: Array[Rect2]) -> bool:
	var obstacles := _current_obstacles()
	for i in range(points.size() - 1):
		for rect in obstacles:
			if ignore.has(rect):
				continue
			if _segment_hits_rect(points[i], points[i + 1], rect):
				return false
	return true


## The rectangles belonging to the two nodes a cable is attached to. A cable always
## starts and ends on its own nodes, so those must not count as obstacles.
func _own_rects(a: Vector2, b: Vector2) -> Array[Rect2]:
	var own: Array[Rect2] = []
	for rect in _current_obstacles():
		if rect.has_point(a) or rect.has_point(b):
			own.append(rect)
	return own


# ---------------------------------------------------------------------------------
# Route shapes
# ---------------------------------------------------------------------------------

func _smooth_curve(a: Vector2, b: Vector2) -> PackedVector2Array:
	var reach: float = maxf(absf(b.x - a.x) * connection_lines_curvature, 32.0)
	var c1 := a + Vector2(reach, 0.0)
	var c2 := b - Vector2(reach, 0.0)
	var points := PackedVector2Array()
	const STEPS := 24
	for i in STEPS + 1:
		var t := float(i) / STEPS
		points.append(a.bezier_interpolate(c1, c2, b, t))
	return points


func _simplify(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in points:
		if result.size() >= 1 and result[result.size() - 1].is_equal_approx(point):
			continue
		if result.size() >= 2:
			var previous: Vector2 = result[result.size() - 1]
			var before: Vector2 = result[result.size() - 2]
			# Drop the middle point of three collinear ones.
			if (previous - before).normalized().is_equal_approx((point - previous).normalized()):
				result.remove_at(result.size() - 1)
		result.append(point)
	return result


## Replaces square corners with 45-degree cuts — the PCB look, and easier to follow
## than a right angle when several traces run near each other.
func _chamfer(points: PackedVector2Array) -> PackedVector2Array:
	if points.size() < 3:
		return points
	var result := PackedVector2Array([points[0]])
	for i in range(1, points.size() - 1):
		var previous: Vector2 = points[i - 1]
		var corner: Vector2 = points[i]
		var next: Vector2 = points[i + 1]
		var cut: float = minf(CHAMFER, minf(previous.distance_to(corner), corner.distance_to(next)) * 0.5)
		result.append(corner + (previous - corner).normalized() * cut)
		result.append(corner + (next - corner).normalized() * cut)
	result.append(points[points.size() - 1])
	return result


## Candidate orthogonal routes from a to b, cheapest first.
func _orthogonal_candidates(a: Vector2, b: Vector2) -> Array:
	var start := a + Vector2(STUB, 0.0)
	var finish := b - Vector2(STUB, 0.0)
	var candidates := []

	# Family one: a vertical channel somewhere between the two stubs. This is the
	# natural shape for a cable running left to right.
	var middle_x := (start.x + finish.x) * 0.5
	var channel_xs := [middle_x]
	for rect in _current_obstacles():
		channel_xs.append(rect.position.x - CLEARANCE * 0.5)
		channel_xs.append(rect.end.x + CLEARANCE * 0.5)
	# Nearest to the midpoint first: the least surprising detour is the smallest one.
	channel_xs.sort_custom(func(p, q): return absf(p - middle_x) < absf(q - middle_x))
	for x in channel_xs:
		if x < minf(start.x, finish.x) - 1.0 or x > maxf(start.x, finish.x) + 1.0:
			continue
		candidates.append(PackedVector2Array([a, start, Vector2(x, a.y), Vector2(x, b.y), finish, b]))

	# Family two: a horizontal channel above or below everything in the way. Needed when
	# the two ports share a row (no vertical channel exists) or the cable runs backwards.
	var middle_y := (a.y + b.y) * 0.5
	var channel_ys := []
	for rect in _current_obstacles():
		channel_ys.append(rect.position.y - CLEARANCE * 0.5)
		channel_ys.append(rect.end.y + CLEARANCE * 0.5)
	channel_ys.sort_custom(func(p, q): return absf(p - middle_y) < absf(q - middle_y))
	for y in channel_ys:
		candidates.append(PackedVector2Array([
			a, start, Vector2(start.x, y), Vector2(finish.x, y), finish, b,
		]))

	return candidates


func _route(a: Vector2, b: Vector2) -> PackedVector2Array:
	var own := _own_rects(a, b)

	var smooth := _smooth_curve(a, b)
	if _path_is_clear(smooth, own):
		return smooth

	for candidate in _orthogonal_candidates(a, b):
		var simplified := _simplify(candidate)
		if _path_is_clear(simplified, own):
			return _chamfer(simplified)

	# Nothing is clear — a dense patch will do this. A staircase through the middle is
	# still more readable than a curve straight through a node.
	var middle := (a.x + b.x) * 0.5
	return _chamfer(_simplify(PackedVector2Array([
		a, a + Vector2(STUB, 0.0), Vector2(middle, a.y), Vector2(middle, b.y),
		b - Vector2(STUB, 0.0), b,
	])))


func _route_through(a: Vector2, b: Vector2, waypoint: Vector2) -> PackedVector2Array:
	# A dragged cable is the user overriding the router, so their point is honoured
	# exactly; each half is still routed around whatever is in the way.
	var first := _route(a, waypoint)
	var second := _route(waypoint, b)
	var joined := PackedVector2Array(first)
	for i in range(1, second.size()):
		joined.append(second[i])
	return _simplify(joined)


# ---------------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------------

func _get_connection_line(from_position: Vector2, to_position: Vector2) -> PackedVector2Array:
	# Godot hands these over in graph space scaled by zoom; routing happens in graph
	# space, against node rectangles, and the result is scaled back on the way out.
	var scale := zoom if zoom > 0.0 else 1.0
	var a := from_position / scale
	var b := to_position / scale

	var waypoint = _waypoint_for(a, b)
	var route := _route_through(a, b, waypoint) if waypoint != null else _route(a, b)

	var scaled := PackedVector2Array()
	for point in route:
		scaled.append(point * scale)
	return scaled


## Finds the stored waypoint for the cable with these graph-space endpoints.
func _waypoint_for(a: Vector2, b: Vector2):
	if waypoints.is_empty():
		return null
	for connection in connections:
		var ends := _endpoints(connection)
		if ends.is_empty():
			continue
		if ends[0].distance_to(a) < 1.0 and ends[1].distance_to(b) < 1.0:
			var fields := _connection_fields(connection)
			return waypoints.get(connection_key(fields[0], fields[1], fields[2], fields[3]))
	return null


# ---------------------------------------------------------------------------------
# Dragging a cable
# ---------------------------------------------------------------------------------

func _to_graph(local_position: Vector2) -> Vector2:
	var scale := zoom if zoom > 0.0 else 1.0
	return (local_position + scroll_offset) / scale


## The connection whose drawn cable passes closest to this graph-space point.
func _connection_at(point: Vector2) -> Dictionary:
	var scale := zoom if zoom > 0.0 else 1.0
	var reach := GRAB_DISTANCE / scale
	var best := {}
	var best_distance := reach

	for connection in connections:
		var ends := _endpoints(connection)
		if ends.is_empty():
			continue
		# Never grab a cable at its very ends; those belong to the ports, and stealing
		# the click there would make disconnecting impossible.
		if point.distance_to(ends[0]) < STUB or point.distance_to(ends[1]) < STUB:
			continue
		var fields := _connection_fields(connection)
		var key := connection_key(fields[0], fields[1], fields[2], fields[3])
		var stored = waypoints.get(key)
		var route := _route_through(ends[0], ends[1], stored) if stored != null \
			else _route(ends[0], ends[1])
		for i in range(route.size() - 1):
			var closest := Geometry2D.get_closest_point_to_segment(point, route[i], route[i + 1])
			var distance := point.distance_to(closest)
			if distance < best_distance:
				best_distance = distance
				best = connection
	return best


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			var point := _to_graph(button.position)
			var connection := _connection_at(point)
			if not connection.is_empty():
				var fields := _connection_fields(connection)
				_dragging_key = connection_key(fields[0], fields[1], fields[2], fields[3])
				_drag_connection = connection
				cable_drag_started.emit()
				accept_event()
				return
		elif _dragging_key != "":
			var fields := _connection_fields(_drag_connection)
			waypoint_changed.emit(fields[0], fields[1], fields[2], fields[3],
				waypoints.get(_dragging_key))
			_dragging_key = ""
			_drag_connection = {}
			accept_event()
			return

	# Right-clicking a cable straightens it again — an escape hatch from a bad drag that
	# does not require finding exactly the right undo.
	if button != null and button.button_index == MOUSE_BUTTON_RIGHT and button.pressed:
		var connection := _connection_at(_to_graph(button.position))
		if not connection.is_empty():
			var fields := _connection_fields(connection)
			var key := connection_key(fields[0], fields[1], fields[2], fields[3])
			if waypoints.has(key):
				cable_drag_started.emit()
				waypoints.erase(key)
				waypoint_changed.emit(fields[0], fields[1], fields[2], fields[3], null)
				queue_redraw()
				accept_event()
				return

	var motion := event as InputEventMouseMotion
	if motion != null and _dragging_key != "":
		var snapped_point := _to_graph(motion.position)
		if snapping_enabled and snapping_distance > 0:
			# Dragged cables land on the same grid as the nodes, so a hand-aligned patch
			# stays aligned.
			snapped_point = snapped_point.snappedf(float(snapping_distance))
		waypoints[_dragging_key] = snapped_point
		queue_redraw()
		accept_event()
		return


func set_waypoint(key: String, point: Variant) -> void:
	if point == null:
		waypoints.erase(key)
	else:
		waypoints[key] = point
	queue_redraw()


func clear_waypoints() -> void:
	waypoints.clear()
