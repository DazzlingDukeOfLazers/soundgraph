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
## Ceiling on how many detours are scored when none of them is clear. Routing runs per
## cable per frame, so an unbounded search in a dense patch would cost frame rate to
## improve a cable that is going to look crowded regardless.
const MAX_CANDIDATES := 192

## Half-length of the break in the cable that passes underneath a crossing. The break is
## deliberately generous: a timid gap reads as a rendering artefact, a clear one reads as
## one cable passing beneath another.
const CROSSING_BREAK := 52.0
## How much wider than the cable the break is, so it clears the line underneath.
const CROSSING_PAD := 6.0

# ---------------------------------------------------------------------------------
# Grid
#
# GraphEdit's own grid draws minor lines at the snap distance and major lines at some
# multiple of it, which leaves you counting minor lines to find the one you want to align
# to. Here the tiers are the layout's own constants instead: a major line is a column, a
# half-major is a row. The line you align to is the line the layout uses, so there is
# nothing to count.
# ---------------------------------------------------------------------------------

## Set GraphEdit's own show_grid to false and let this draw instead; the two would
## otherwise overlay two unrelated sets of major lines.
## Matches Rack.CableStyle. The graph view honours the same choice so the two views can be
## compared on the thing being tested rather than on an incidental difference.
var cable_style: int = 1   # PCB, which is what this view was built around

var draw_grid := true
## The snap step — faintest lines.
var grid_minor := 40.0
## Row pitch — the "half-major" lines.
var grid_half_major := 200.0
## Column pitch — the heaviest lines.
var grid_major := 400.0

var grid_minor_colour := Color(1, 1, 1, 0.035)
var grid_half_major_colour := Color(1, 1, 1, 0.10)
var grid_major_colour := Color(1, 1, 1, 0.22)

## Graph-space point each cable must pass through, keyed by connection.
var waypoints: Dictionary = {}

var _obstacles: Array[Rect2] = []
var _obstacles_frame := -1
var _route_cache := {}
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
	_route_cache.clear()
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


## Clear vertical gaps between obstacles, nearest the reference first. A columnar layout
## always leaves these between its columns, and they are where a trace should make its
## vertical moves — turning at a fixed distance from the port instead lands inside
## whatever node happens to occupy the next column.
func _vertical_channels(reference: float, low: float, high: float) -> Array:
	var candidates := [reference]
	for rect in _current_obstacles():
		candidates.append(rect.position.x - CLEARANCE * 0.5)
		candidates.append(rect.end.x + CLEARANCE * 0.5)

	var usable := []
	for x in candidates:
		if x >= low and x <= high:
			usable.append(x)
	usable.sort_custom(func(p, q): return absf(p - reference) < absf(q - reference))
	return usable


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

	# Family two: a horizontal channel above or below whatever is in the way. Needed when
	# the two ports share a row — no vertical channel between them can help, because the
	# route would be a straight line through the obstacle — or when the cable runs
	# backwards.
	#
	# The vertical moves happen in clear gaps between obstacles rather than at a fixed
	# distance from the port: in a columnar layout a fixed stub lands inside the next
	# column, which is exactly the case of two same-row nodes with a third between them.
	var middle_y := (a.y + b.y) * 0.5
	var channel_ys := []
	for rect in _current_obstacles():
		channel_ys.append(rect.position.y - CLEARANCE * 0.5)
		channel_ys.append(rect.end.y + CLEARANCE * 0.5)
	channel_ys.sort_custom(func(p, q): return absf(p - middle_y) < absf(q - middle_y))

	var low: float = minf(start.x, finish.x)
	var high: float = maxf(start.x, finish.x)
	# Two turn points at each end, not four. Every extra combination multiplies how many
	# candidates must be examined before the next horizontal channel is even tried — and
	# the channel matters far more than the exact turn, so spending the budget on rows
	# rather than on columns finds a clear route much sooner.
	var leaving := _vertical_channels(start.x, low, high).slice(0, 2)
	var arriving := _vertical_channels(finish.x, low, high).slice(0, 2)
	if leaving.is_empty():
		leaving = [start.x]
	if arriving.is_empty():
		arriving = [finish.x]

	for y in channel_ys:
		for x1 in leaving:
			for x2 in arriving:
				candidates.append(PackedVector2Array([
					a, Vector2(x1, a.y), Vector2(x1, y), Vector2(x2, y), Vector2(x2, b.y), b,
				]))

	return candidates


## How many obstacles a path crosses. Zero means clear; the count is used to pick the
## least bad route when a dense patch leaves no clear one at all.
func _blocked_count(points: PackedVector2Array, ignore: Array[Rect2]) -> int:
	var obstacles := _current_obstacles()
	var blocked := 0
	for i in range(points.size() - 1):
		for rect in obstacles:
			if ignore.has(rect):
				continue
			if _segment_hits_rect(points[i], points[i + 1], rect):
				blocked += 1
	return blocked


func _path_length(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


func _route(a: Vector2, b: Vector2) -> PackedVector2Array:
	# Routing is not cheap and every cable is routed on every frame it is drawn, so
	# results are kept for the life of a frame. The obstacle list is rebuilt per frame
	# too, so the cache can never outlive the geometry it was computed against.
	_current_obstacles()
	var key := "%.1f,%.1f>%.1f,%.1f" % [a.x, a.y, b.x, b.y]
	if _route_cache.has(key):
		return _route_cache[key]

	var own := _own_rects(a, b)
	var result: PackedVector2Array

	var smooth := _smooth_curve(a, b)
	if _path_is_clear(smooth, own):
		result = smooth
	else:
		var best: PackedVector2Array
		var best_blocked := 1 << 30
		var best_length := INF
		var examined := 0

		# Candidates arrive best-first, so the first clear one wins and the search stops
		# there. Scoring the rest only matters when a dense patch leaves nothing clear at
		# all, where the least-blocked route still reads better than a line through three
		# nodes — and even then the search is capped, because this runs per cable per frame.
		for candidate in _orthogonal_candidates(a, b):
			var simplified := _simplify(candidate)
			var blocked := _blocked_count(simplified, own)
			if blocked == 0:
				best = simplified
				best_blocked = 0
				break
			var length := _path_length(simplified)
			if blocked < best_blocked or (blocked == best_blocked and length < best_length):
				best_blocked = blocked
				best_length = length
				best = simplified
			examined += 1
			if examined >= MAX_CANDIDATES:
				break
		result = _chamfer(best) if not best.is_empty() else smooth

	_route_cache[key] = result
	return result


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

	# The rack's cable styles apply here too, so the A/B is a fair one. A hanging cable
	# ignores obstacles by design — that is the trade being compared, not a shortcut.
	if cable_style == Rack.CableStyle.CATENARY:
		var span := absf(b.x - a.x)
		var sag := clampf(span * Rack.SAG_FRACTION, Rack.SAG_MIN, Rack.SAG_MAX)
		var hung := Rack.catenary(a, b, sag)
		var hung_scaled := PackedVector2Array()
		for point in hung:
			hung_scaled.append(point * scale)
		return hung_scaled

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


# ---------------------------------------------------------------------------------
# Crossings
#
# Routing removes most crossings, but a graph dense enough will always produce some, and
# where two cables meet at a point there is no way to tell which is which. Schematics
# solve this by breaking the line that passes underneath, and that is what this draws: a
# short gap in the lower cable, so the upper one reads as continuous and the eye can
# follow either one through the junction.
#
# The drawing happens on a Control inserted directly after GraphEdit's own connection
# layer, so it sits above the cables and below the nodes.
# ---------------------------------------------------------------------------------

class CrossingOverlay extends Control:
	var graph: GraphEdit
	var _fingerprint := ""

	func _ready() -> void:
		# Deliberately left with no size and no anchors. GraphEdit lays out its children,
		# and a full-rect child inside it bounces resize notifications back and forth.
		# Drawing is not clipped to a Control's rect, so a zero-sized overlay still paints
		# anywhere on the canvas.
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_delta: float) -> void:
		# There is no signal for "a cable moved", so the view is watched instead — but
		# only redrawn when it actually changed. Recomputing every route on every frame
		# is enough work to hold a core down all by itself.
		if graph == null:
			return
		var current: String = graph._view_fingerprint()
		if current != _fingerprint:
			_fingerprint = current
			queue_redraw()

	func _draw() -> void:
		if graph != null:
			graph._draw_crossings(self)


## Cheap summary of everything the crossing marks depend on.
func _view_fingerprint() -> String:
	var parts := PackedStringArray()
	parts.append("%.2f,%.1f,%.1f" % [zoom, scroll_offset.x, scroll_offset.y])
	parts.append(str(connections.size()))
	parts.append(str(waypoints.size()))
	for child in get_children():
		if child is GraphNode:
			parts.append("%s:%.0f,%.0f,%.0f,%.0f" % [child.name,
				child.position_offset.x, child.position_offset.y, child.size.x, child.size.y])
	return "|".join(parts)


var _overlay: CrossingOverlay


func _ready() -> void:
	_overlay = CrossingOverlay.new()
	_overlay.graph = self
	add_child(_overlay)
	# Straight after the connection layer: above the cables, below the nodes.
	move_child(_overlay, 1)


## The grid is drawn on the GraphEdit's own canvas item, which sits below the connection
## layer — so cables and nodes stay on top of it.
func _draw() -> void:
	if not draw_grid:
		return
	var scale := zoom if zoom > 0.0 else 1.0
	var left := scroll_offset.x / scale
	var top := scroll_offset.y / scale
	var right := (scroll_offset.x + size.x) / scale
	var bottom := (scroll_offset.y + size.y) / scale

	# Heaviest last, so a column line is drawn over the row and snap lines that share it.
	for tier in [
		[grid_minor, grid_minor_colour, 1.0],
		[grid_half_major, grid_half_major_colour, 1.0],
		[grid_major, grid_major_colour, 2.0],
	]:
		var step: float = tier[0]
		if step <= 0.0 or step * scale < 5.0:
			continue   # too dense to read at this zoom, and expensive to draw
		var colour: Color = tier[1]
		var width: float = tier[2]

		var x := floorf(left / step) * step
		while x <= right:
			var screen := x * scale - scroll_offset.x
			draw_line(Vector2(screen, 0.0), Vector2(screen, size.y), colour, width)
			x += step
		var y := floorf(top / step) * step
		while y <= bottom:
			var screen := y * scale - scroll_offset.y
			draw_line(Vector2(0.0, screen), Vector2(size.x, screen), colour, width)
			y += step


## Every cable's current route in graph space, with the colour GraphEdit drew it in.
func _routes() -> Array:
	var routes := []
	for connection in connections:
		var ends := _endpoints(connection)
		if ends.is_empty():
			continue
		var fields := _connection_fields(connection)
		var stored = waypoints.get(connection_key(fields[0], fields[1], fields[2], fields[3]))
		var points := _route_through(ends[0], ends[1], stored) if stored != null \
			else _route(ends[0], ends[1])

		var colour := Color.WHITE
		var from_node := get_node_or_null(NodePath(fields[0])) as GraphNode
		if from_node != null and fields[1] < from_node.get_output_port_count():
			colour = from_node.get_output_port_color(fields[1])
		routes.append({"points": points, "colour": colour, "fields": fields})
	return routes


func _draw_crossings(canvas: CanvasItem) -> void:
	var scale := zoom if zoom > 0.0 else 1.0
	var to_local := func(point: Vector2) -> Vector2:
		return point * scale - scroll_offset

	# The colour a break is painted in. Taken from the theme so it keeps matching the
	# canvas rather than being a constant that drifts out of step with it.
	var background := get_theme_color("bg", "GraphEdit") if has_theme_color("bg", "GraphEdit") \
		else Color(0.13, 0.14, 0.17)

	var routes := _routes()
	for i in routes.size():
		for j in range(i + 1, routes.size()):
			var a: Dictionary = routes[i]
			var b: Dictionary = routes[j]
			# Cables leaving the same port, or arriving at the same one, meet by design.
			if a["fields"][0] == b["fields"][0] or a["fields"][2] == b["fields"][2]:
				continue

			# The cable drawn later passes underneath, matching GraphEdit's own order, so
			# the break appears where the eye already expects the junction to resolve.
			var over: Dictionary = a
			var under: Dictionary = b

			for point in _intersections(over["points"], under["points"]):
				var under_direction := _direction_at(under["points"], point)
				var over_direction := _direction_at(over["points"], point)
				if under_direction == Vector2.ZERO:
					continue

				# The lower cable is cut clean at the junction.
				var width: float = (connection_lines_thickness + CROSSING_PAD) * scale
				var half := under_direction * CROSSING_BREAK
				canvas.draw_line(to_local.call(point - half), to_local.call(point + half),
					background, width, true)

				# Then the upper cable is laid back over the break, so it stays unbroken
				# across the junction. Locally a route is straight, so a segment along its
				# direction follows it exactly.
				if over_direction != Vector2.ZERO:
					var extent := over_direction * CROSSING_BREAK
					canvas.draw_line(to_local.call(point - extent), to_local.call(point + extent),
						over["colour"], connection_lines_thickness * scale, true)


## Points where two routes cross.
func _intersections(first: PackedVector2Array, second: PackedVector2Array) -> Array:
	var points := []
	for i in range(first.size() - 1):
		for j in range(second.size() - 1):
			var hit = Geometry2D.segment_intersects_segment(
				first[i], first[i + 1], second[j], second[j + 1])
			if hit != null:
				points.append(hit)
	return points


## Direction of the route where it passes through a point, so the break follows the
## cable rather than being drawn at an arbitrary angle.
func _direction_at(points: PackedVector2Array, point: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_distance := INF
	for i in range(points.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(point, points[i], points[i + 1])
		var distance := point.distance_to(closest)
		if distance < best_distance:
			best_distance = distance
			best = (points[i + 1] - points[i]).normalized()
	return best


func set_waypoint(key: String, point: Variant) -> void:
	if point == null:
		waypoints.erase(key)
	else:
		waypoints[key] = point
	queue_redraw()


## Forces every cable to be routed again.
##
## GraphEdit caches the geometry it gets from _get_connection_line and only asks for it
## again when the connections change, a node moves or the zoom changes. Changing the
## routing style is none of those, so the toggle appeared to do nothing here while working
## in the rack — the style had changed and the drawing had not. Re-setting the same
## connections is the supported way to say "these need recomputing".
func refresh_cables() -> void:
	set_connections(get_connection_list())
	queue_redraw()


func clear_waypoints() -> void:
	waypoints.clear()
