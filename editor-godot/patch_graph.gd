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

const Rack := preload("res://rack.gd")

signal waypoint_changed(from_node: StringName, from_port: int, to_node: StringName,
	to_port: int, point)
## Emitted when a cable drag begins, so the editor can take an undo snapshot before the
## first movement rather than reconstructing where the cable used to be.
signal cable_drag_started
## Emitted when the Delete key falls on a hovered cable — the same edit as dragging the
## cable off its port, and it goes through the same handler.
signal cable_delete_requested(from_node: StringName, from_port: int,
	to_node: StringName, to_port: int)

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

# Two states, because a grid has two jobs and they want opposite things.
#
# While you are reading a node it should be almost gone: at 0.22 the major lines were
# competing with node borders and cables for the same attention, and a background
# that argues with the foreground makes everything harder to read. While you are
# *moving* a node it is the whole point — it is what you are aligning to.
#
# So it fades in when a drag starts and back out when it ends. Same lines, and they
# arrive exactly when they are useful.
const GRID_RESTING := [0.018, 0.045, 0.09]
const GRID_MOVING := [0.05, 0.12, 0.26]
## Seconds for the fade. Long enough not to flicker on a click, short enough that the
## grid is already there by the time the node has moved anywhere.
const GRID_FADE := 0.14

var grid_minor_colour := Color(1, 1, 1, GRID_RESTING[0])
var grid_half_major_colour := Color(1, 1, 1, GRID_RESTING[1])
var grid_major_colour := Color(1, 1, 1, GRID_RESTING[2])

## How much of a node is worth drawing at the current zoom.
##
## Zooming out of a patcher normally just makes everything smaller, so at the point where
## you can finally see the whole graph none of it is readable and the view is useless for
## the one thing it is good for — seeing the shape of the thing.
##
## A map is the model, not a photograph. Zooming out of a map does not shrink the word
## "Chicago" until it is a smudge; the representation changes, and the words that survive
## stay readable. So each band is a different *drawing* of a node rather than the same
## drawing at a smaller size, and the words that survive are pinned to screen-space
## minimums by ScreenText below.
##
##   FULL      everything, edited in place
##   COMPACT   the words and the numbers; the sliders give up their room to the words
##   SUMMARY   identity, ports and port names — no control panel
##   TOPOLOGY  identity and wiring, which is all anyone is reading at this size
##
## The thresholds have hysteresis. Without it a zoom sitting exactly on a boundary makes
## every node in the graph flicker between two layouts as the mouse wheel jitters.
enum Detail { FULL, COMPACT, SUMMARY, TOPOLOGY }

## The full-detail boundary is derived, not chosen: it is the zoom at which a parameter
## value stops being legible on its own, so it is also the zoom at which the node stops
## being a control panel that can be read without help. The old hand-picked 0.68 let a
## 16px value shrink to 10.9 rendered pixels while the design system elsewhere promised
## nothing operational below 14 — the floor stopped at the canvas edge, and the canvas is
## where the most-read text in the application lives.
##
## Below here the words do not shrink and are not dropped: ScreenText draws them at their
## own minimum instead. What the boundary marks is the end of *editing in place* — the
## point past which the controls are too small to aim at and their room is better spent
## on the words that say what they are.
static func _full_floor() -> float:
	return float(Design.TYPE_FLOOR) / float(Design.SIZE_NUMERIC)

## Where the control panel stops being worth drawing, and where the node stops being a
## panel at all. Unlike the FULL boundary these are not derivable from the type scale —
## below FULL the words are screen-space pinned and stay legible at any zoom, so what
## ends each band is *room*, not legibility: at 0.60 a compensated label has stopped
## fitting beside a compensated value, and at 0.40 the node is too small to hold a row
## of text at all without the words spilling over their own node.
## Zoom must clear a boundary by this much before detail comes *back*, so a wheel click
## resting on a threshold does not flicker every node in the graph between two layouts.
const DETAIL_HYSTERESIS := 0.02

## The bands are one hysteresis *below* the numbers they are meant to honour — 0.60 for
## compact and 0.40 for summary — so those numbers hold whichever direction you arrive
## from. They did not before, and the bug only ever showed up in a picture: the editor
## opens fitted, which is often under 0.60, so zooming *up* to 63% asked the hysteresis
## to climb and it refused until 64%. A screenshot at 63% was therefore a summary node,
## empty where its parameters should have been, while the same view reached by zooming
## down from 100% was correct. A boundary that depends on which way you came is a
## boundary nobody can state.
const COMPACT_BASE := 0.60 - DETAIL_HYSTERESIS
const SUMMARY_BASE := 0.40 - DETAIL_HYSTERESIS

## …and they move with the UI-scale preference, because what ends these bands is room.
##
## A node keeps its size in graph space, so the room a row has on screen is its width
## times the zoom — while the text that has to fit in it is pinned to a screen size that
## *rises* with the reader's preference. At XL the floor is 20px in a node 217px wide at
## 63%, and the matrix showed exactly what that produces: "out" and "in" from neighbouring
## nodes collided into "oiuln", a value ran into the next node's label, and the compact
## band was drawing a control panel in a space that could not hold one.
##
## The brief's own answer, and the right one: when compensation would overcrowd, change
## the level of detail rather than allow the overlap. So a reader on XL reaches summary
## and topology sooner — the same information, one representation earlier, which is what
## asking for larger text on a smaller canvas actually costs.
static func _scaled(floor_value: float) -> float:
	return floor_value * maxf(1.0, Design.SCALE_FACTORS[Design.ui_scale])

static func compact_floor() -> float:
	return _scaled(COMPACT_BASE)

static func summary_floor() -> float:
	return _scaled(SUMMARY_BASE)

## Port hit targets, in real pixels, for the same reason the type has them.
##
## GraphEdit reads these extents in graph space, so they shrink with the zoom exactly as
## the text does: at 65% an 18px outer extent is a 11.7px target, which is smaller than
## the marker looks and well under anything aimable. Counter-scaled below so what the
## pointer has to hit stays the size the design system asked for however far out the
## canvas is — geometry may shrink, and the things a hand has to land on may not.
##
## Horizontal extents only, which is why growing them cannot make two stacked ports
## fight: their vertical share is set by the row pitch, not by these.
const PORT_HOTZONE_INNER := 14
const PORT_HOTZONE_OUTER := 18
const PORT_TARGET_MIN := 24

signal detail_changed(level: int)

## How the level of detail is chosen. ADAPTIVE is the map: the drawing changes with
## the zoom so the words that survive stay readable. ONE_TO_ONE is the photograph:
## the full module — controls, text, all of it — at every zoom, scaled as geometry.
## Nothing is pinned and nothing is swapped; far out the text is small because the
## module is far away, which is the honest reading of "1:1".
##
## The photograph is the default. The map was, until zooming out over a patch made
## its knobs vanish mid-thought — a graph that redraws itself as you move away
## reads as losing your work, not as a considerate summary. Small-but-there beats
## tidy-but-gone; the map stays one Ctrl+2 away for reading very large graphs.
enum DetailMode { ADAPTIVE, ONE_TO_ONE }

var detail_mode: int = DetailMode.ONE_TO_ONE

## Face edit: the mode where clicking a knob cell or a port nominates it for the
## document's face instead of operating it. The graph does the pointing and the
## painting; what is actually on the face is main's knowledge, written onto the
## cells as an "on_face" meta and onto seam widgets as "face_seam".
signal face_cell_toggled(node_id: String, parameter_name: String)
signal face_port_toggled(widget_name: String, side: String, index: int)

var face_edit := false:
	set(value):
		face_edit = value
		# One redraw on the way out too: the overlay's process loop only repaints
		# while the mode is on, and the frames must not outlive it.
		if _wand_overlay != null:
			_wand_overlay.queue_redraw()

var detail: int = Detail.FULL


func set_detail_mode(mode: int) -> void:
	if mode == detail_mode:
		return
	detail_mode = mode
	_update_detail()
	queue_redraw()

var _hotzone_zoom := -1.0
var _grid_emphasis := 0.0
var _grid_target := 0.0

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
			var chips := _case_chip_rects()
			# Turn the device over. The graph is its insides and the face is what a
			# player holds, and they are the same container — so the flip lives on the
			# container, in the same place on both sides. The other two are modes, and
			# they sit beside it because they answer the same question.
			if (chips.get("face_view", Rect2()) as Rect2).has_point(button.position):
				case_flipped.emit()
				accept_event()
				return
			if (chips.get("face_edit", Rect2()) as Rect2).has_point(button.position):
				case_face_edit_toggled.emit()
				accept_event()
				return
			if (chips.get("schematic", Rect2()) as Rect2).has_point(button.position):
				case_schematic_toggled.emit()
				accept_event()
				return
			if (chips.get("graph", Rect2()) as Rect2).has_point(button.position):
				case_graph_requested.emit()
				accept_event()
				return
		# The band is a handle only when there is something under it to move. While a
		# mount is up the nodes are hidden, and dragging the band would shift nodes
		# nobody can see - an edit, with an undo step, from a gesture that looks like
		# moving the picture.
		if button.pressed and not mount_up 				and _case_band_rect().has_point(button.position):
			# The band is the handle, as the caption is on a panel knob: the case's
			# inside is where the work happens — selecting, rubber-banding, dragging
			# nodes — so the one strip that is not workspace is what moves the whole of
			# it. Grabbing anywhere on the case would make a rubber band impossible.
			_case_drag_from = _to_graph(button.position)
			_case_dragging = true
			_case_drag_travel = 0.0
			case_move_started.emit()
			accept_event()
			return
		if not button.pressed and _case_dragging:
			_case_dragging = false
			# A press that never travelled is a click, and a click on the container
			# chooses the container — the same distinction a node makes between being
			# dragged and being selected. case_moved still fires, and harmlessly: a
			# drag that went nowhere is already not an edit.
			case_moved.emit()
			if _case_drag_travel < 4.0:
				case_selected.emit()
			accept_event()
			return
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
			# Empty canvas — checked, not assumed. The first version reasoned "a
			# GraphNode consumes its own presses, so anything arriving is the canvas",
			# which is false: GraphEdit itself handles selection, so a press on a node's
			# body reaches this override too, and treating it as floor meant every click
			# on a node selected it and then immediately chose the container instead.
			# Remembered but not claimed: the press still belongs to the rubber band,
			# and only the release decides which gesture this was.
			if _node_at(point) == "":
				_canvas_press_at = button.position
		elif _dragging_key != "":
			var fields := _connection_fields(_drag_connection)
			waypoint_changed.emit(fields[0], fields[1], fields[2], fields[3],
				waypoints.get(_dragging_key))
			_dragging_key = ""
			_drag_connection = {}
			accept_event()
			return
		elif _canvas_press_at.x != INF:
			# A click on the room you are standing in chooses the room: the canvas is
			# the inside of the container, so clicking its empty floor lands where
			# clicking the case band does. Travelled, it was a rubber band, and the
			# selection it made is not overruled. Not accepted either way — the native
			# rubber band still ends however it ends.
			if button.position.distance_to(_canvas_press_at) < 4.0:
				case_selected.emit()
			_canvas_press_at = Vector2.INF

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

	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_DELETE:
		if _delete_pointed_at():
			accept_event()
			return

	var motion := event as InputEventMouseMotion
	if motion != null and _case_dragging:
		# Every node by the same delta, so the patch keeps its shape and only its
		# position changes. Moving the case is moving what is mounted in it.
		var at := _to_graph(motion.position)
		var step := at - _case_drag_from
		_case_drag_from = at
		_case_drag_travel += step.length()
		for child in get_children():
			var node := child as GraphNode
			if node != null and node.visible:
				node.position_offset += step
		queue_redraw()
		accept_event()
		return

	if motion != null and _dragging_key == "":
		_update_hover(motion.position)
		_update_cable_hover(motion.position)

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


func _unhandled_key_input(event: InputEvent) -> void:
	# The canvas rarely holds keyboard focus — a click lands it on whatever was
	# clicked, and working the inspector moves it off the graph entirely. GraphEdit's
	# own Delete shortcut only listens while focused, so the key looked dead. Delete
	# is not a focus-dependent idea here: a hovered cable or a selection is already
	# the pointing. Anything that eats keys first — a search field, a value being
	# typed — still wins, because this sees only what nothing else consumed.
	if not is_visible_in_tree():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.keycode != KEY_DELETE:
		return
	if _delete_pointed_at():
		get_viewport().set_input_as_handled()


## Delete what the user is pointing at: the hovered cable first, else the selected
## nodes. A cable cannot be selected, so hover is how one is singled out — and the
## hover highlight already shows which cable would go. Ahead of the selection on
## purpose: pointing at a cable is more precise than having something selected
## somewhere. Returns whether there was anything to delete.
func _delete_pointed_at() -> bool:
	if not hovered_cable.is_empty():
		var doomed := _connection_fields(hovered_cable)
		cable_delete_requested.emit(doomed[0], doomed[1], doomed[2], doomed[3])
		hovered_cable = {}
		return true
	var chosen: Array[StringName] = []
	for child in get_children():
		var node := child as GraphNode
		# Not the hidden ones: a flipped case's insides are still selected from before
		# the flip, and deleting what cannot be seen is a trap.
		if node != null and node.selected and node.visible:
			chosen.append(node.name)
	if chosen.is_empty():
		return false
	delete_nodes_request.emit(chosen)
	return true


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
		# The cables describe the wiring, and the wiring is put away.
		if graph != null and graph.face_up:
			return
		if graph != null:
			graph._draw_crossings(self)


## Cheap summary of everything the crossing marks depend on.
func _view_fingerprint() -> String:
	var parts := PackedStringArray()
	parts.append("%.2f,%.1f,%.1f,%d" % [zoom, scroll_offset.x, scroll_offset.y,
		detail_mode])
	parts.append(str(connections.size()))
	parts.append(str(waypoints.size()))
	for child in get_children():
		if child is GraphNode:
			parts.append("%s:%.0f,%.0f,%.0f,%.0f" % [child.name,
				child.position_offset.x, child.position_offset.y, child.size.x, child.size.y])
	return "|".join(parts)


## How brightly each output port is glowing. node id -> port index -> 0..1.
##
## Fed from the running graph rather than from anything the editor imagines: the
## levels are measured off the same buffers the scope reads, so a port that lights up
## is a port with sound coming out of it. That is the entire point — an editor that
## animated on a guess would be decoration, and worse than none.
var port_levels: Dictionary = {}

## The port the pointer is over, as {"widget", "side", "index"}, or empty.
##
## GraphEdit has no hover signal for ports, and it has a large invisible hot zone
## around each one — deliberately, so they are easy to hit. The two together mean the
## thing you are about to connect to gives no sign of being the thing you are about
## to connect to, and you find out by letting go. This is what tells you first.
var hovered_port: Dictionary = {}

## The cable under the pointer, as a connection dictionary, or empty.
##
## GraphEdit brightens a hovered cable on its own once the theme says what that looks
## like. What it cannot do is show you where the cable *goes* — and on a busy canvas
## that is the only thing anybody wanted to know, which is why following one by eye is
## the gesture this view asks for most and supports least.
var hovered_cable: Dictionary = {}

signal port_hovered(widget_name: String, side: String, index: int)

# ---------------------------------------------------------------------------------
# Clicking through to what a node is holding
#
# A ghost jack is drawn inside a module's body, and a knob is a real Control that swallows
# its own clicks — so by the time GraphEdit hears about a press on one it is far too late.
# `_input` runs before the GUI pass, which is the only reason a click can reach either of
# them, and anything not wanted here falls straight through: selecting, dragging and
# panning are untouched.
#
# This used to be the wand's hook, and the wand's job was nomination — telling collapse
# which jacks and knobs a new module should show, in what order. That job went when the
# panels learned to do it after the fact: a module's face is edited on the sub-panel
# builder and the file's on its own panel, both by dragging what is offered onto what is
# shown. Nominating up front was answering the question at the one moment the answer was
# hardest to see.
# ---------------------------------------------------------------------------------

## A ghost jack was clicked: this inner port should become one of the module's own.
signal ghost_port_picked(widget_name: String, offer: Dictionary)

# ---------------------------------------------------------------------------------
# Open modules, and the rectangle that makes one
#
# A module and the nodes it stands for are two notations for one graph, so a module you
# are looking inside is not a drawing of something absent — it is the document in its
# other notation, with a dashed frame around the parts saying which of them belong to
# it. Everything inside is an ordinary node: it selects, it drags, its knobs turn.
#
# Making one is drawing the frame first. "Make module" arms a rubber band, and whatever
# ends up wholly inside it is what the module is made of. Asking for a rectangle rather
# than a selection is the difference between saying what a thing is and having said it
# earlier by accident — a selection is whatever was last clicked, and this is a question
# with a right answer at the moment it is asked.
# ---------------------------------------------------------------------------------

## Module name -> the GraphNode names of its parts on the canvas. Setting it arms the
## input hook, because an open module has a close button and a close button needs clicks
## whether or not any tool is up.
var groups: Dictionary = {}:
	set(value):
		groups = value
		if _wand_overlay != null:
			_wand_overlay.queue_redraw()
## True while a rectangle is being drawn.
## The rectangle an open module's frame occupies, in the graph's own coordinates — the ones
## node positions are in, not the ones the screen is in.
##
## Here rather than inside _draw_groups because two things need it and they must agree: the
## frame that gets drawn, and the question "is this point inside that module", which decides
## whether a node dropped there joins it. Two copies of this arithmetic would disagree at
## the edge, and the edge is exactly where somebody aims when they mean "just inside".
##
## Zero-size when the module has nothing on the canvas, which is how a caller says "not a
## frame" without a second return value.
func group_box(module_name: String) -> Rect2:
	if not groups.has(module_name):
		return Rect2()
	var box := Rect2()
	var first := true
	for widget_name in groups[module_name]:
		var node := get_node_or_null(NodePath(str(widget_name))) as GraphNode
		if node == null or not node.visible:
			continue
		var rect := Rect2(node.position_offset, node.size)
		box = rect if first else box.merge(rect)
		first = false
	if first:
		return Rect2()
	# Room at the top for the name and the button, which live on the frame rather than
	# floating beside it — a label not attached to its rectangle is a label you have to work
	# out the owner of.
	return box.grow(float(Design.scale(Design.SPACE_M))) \
		.grow_individual(0.0, float(Design.scale(34.0)), 0.0, 0.0)


## The node under a point in graph coordinates, or "" for bare canvas.
func _node_at(point: Vector2) -> String:
	for child in get_children():
		var node := child as GraphNode
		if node != null and node.visible \
				and Rect2(node.position_offset, node.size).has_point(point):
			return String(node.name)
	return ""


## Which open module a point in graph coordinates falls inside, or "".
func group_at(point: Vector2) -> String:
	for module_name in groups:
		if group_box(str(module_name)).has_point(point):
			return str(module_name)
	return ""


var drawing := false

signal region_drawn(ids: Array)
signal group_closed(module_name: String)

var _band_from := Vector2.ZERO
var _band_to := Vector2.ZERO
var _banding := false
## Module name -> the local rectangle of its close button, refreshed by the overlay each
## time it draws one. Hit-testing where something was actually drawn is the only version
## of this that cannot drift from the picture.
var _close_hits: Dictionary = {}


## Arms or disarms the rubber band. The input hook is shared with the wand, so it is
## installed while either wants it.
func set_drawing(active: bool) -> void:
	drawing = active
	_banding = false
	mouse_default_cursor_shape = Control.CURSOR_CROSS if active else Control.CURSOR_ARROW
	if _wand_overlay != null:
		_wand_overlay.queue_redraw()


## The nodes wholly inside the band, in reading order. Wholly, not touching: a rectangle
## that swallowed anything it grazed would make the gesture a matter of aim rather than of
## intent, and the one node you did not mean is the one that ruins the module.
func _nodes_within(band: Rect2) -> Array:
	var found: Array = []
	for child in get_children():
		var node := child as GraphNode
		if node == null or not node.visible:
			continue
		var scale: float = zoom if zoom > 0.0 else 1.0
		var rect := Rect2(node.position_offset * scale - scroll_offset, node.size * scale)
		if band.encloses(rect):
			found.append(String(node.name))
	return found

var _overlay: CrossingOverlay
var _glow: GlowOverlay
var _titles: ScreenText
var _wand_overlay: WandOverlay


func _ready() -> void:
	_overlay = CrossingOverlay.new()
	_overlay.graph = self
	add_child(_overlay)
	# Straight after the connection layer: above the cables, below the nodes.
	move_child(_overlay, 1)
	# Above the nodes, so a glow reads as light coming off the jack rather than as
	# something buried under the panel it belongs to.
	_glow = GlowOverlay.new()
	_glow.graph = self
	add_child(_glow)
	_titles = ScreenText.new()
	_titles.graph = self
	add_child(_titles)
	_wand_overlay = WandOverlay.new()
	_wand_overlay.graph = self
	add_child(_wand_overlay)
	# Always listening. There is no mode to arm: the two things this hook is for — the
	# rubber band while one is being drawn, and a ghost jack on a selected module — are
	# states of the document rather than of a tool, and _input returns at once when
	# neither is on screen.
	set_process_input(true)
	begin_node_move.connect(func() -> void: _grid_target = 1.0)
	end_node_move.connect(func() -> void: _grid_target = 0.0)
	set_process(true)


func _process(delta: float) -> void:
	_update_detail()
	_update_hit_targets()
	if is_equal_approx(_grid_emphasis, _grid_target):
		return
	var step := delta / GRID_FADE
	_grid_emphasis = move_toward(_grid_emphasis, _grid_target, step)
	grid_minor_colour.a = lerpf(GRID_RESTING[0], GRID_MOVING[0], _grid_emphasis)
	grid_half_major_colour.a = lerpf(GRID_RESTING[1], GRID_MOVING[1], _grid_emphasis)
	grid_major_colour.a = lerpf(GRID_RESTING[2], GRID_MOVING[2], _grid_emphasis)
	queue_redraw()


## The grid is drawn on the GraphEdit's own canvas item, which sits below the connection
## layer — so cables and nodes stay on top of it.
## The case around everything the file holds, with the instrument's name on it.
##
## The same boundary the panel draws, on the other side of the same idea: a container has
## a name, an edge, ports where signals cross it, and contents. The panel shows one of
## those containers as knobs and this shows it as wiring, and they are worth drawing alike
## because they are the same object seen from two directions.
##
## Behind the nodes, not over them — a case is what modules are mounted *in*, so it sits
## under them the way the rack's rails do. That is also why it is here in the graph's own
## _draw rather than in WandOverlay: an open module's frame is drawn above, because that
## one is a thing you are working inside and it has a button on it.
##
## From the nodes' own rectangles at this instant, like group_box: a stored rectangle is a
## second copy of where the nodes are, and the copies disagree the first time one moves.
## Where the mounted tenant sits, in graph space, or an empty rect for none.
##
## The case is normally measured from its nodes. A mount hides them, and then there is
## nothing to measure — which took the band away, and the band is where the controls for
## getting back out of that view live. The schematic became a room with no door.
var mount_box := Rect2():
	set(value):
		mount_box = value
		queue_redraw()


func case_box() -> Rect2:
	var box := Rect2()
	var first := true
	for child in get_children():
		var node := child as GraphNode
		if node == null or not node.visible:
			continue
		var rect := Rect2(node.position_offset, node.size)
		box = rect if first else box.merge(rect)
		first = false
	if first:
		if mount_box.size.x > 0.0 and mount_box.size.y > 0.0:
			return mount_box.grow_individual(0.0,
				float(Design.scale(CASE_BAND)), 0.0, 0.0)
		return Rect2()
	return box.grow(float(Design.scale(Design.SPACE_L))) \
		.grow_individual(0.0, float(Design.scale(CASE_BAND)), 0.0, 0.0)


## The band along the top of the case, where its name sits. Before UI scaling.
const CASE_BAND := 30.0

## What the case is called: the instrument's name, set by main from the document. Empty
## draws nothing at all, which is right for a patch with no nodes in it yet — a case
## around nothing is a box with a name and no reason.
var case_title := "":
	set(value):
		case_title = value
		queue_redraw()

## The band was clicked rather than dragged: the container itself was chosen, the way
## clicking a node chooses the node.
signal case_selected
## Somebody asked to turn the container over — wiring to face, or back.
signal case_flipped
## The two modes on the band. The editor owns what they mean; the graph only draws them
## lit and says when one was pressed.
signal case_face_edit_toggled
signal case_schematic_toggled
## Back to the wiring, from wherever. Not a toggle: the graph is the view everything
## else is a departure from, so asking for it twice should mean the same as asking once.
signal case_graph_requested
## The face is up: the wiring is hidden and the mounted face stands in its place. The
## overlays stand down while it is — cables, glows and frames describe the wiring, and
## the wiring is what the flip put away.
var face_up := false:
	set(value):
		face_up = value
		queue_redraw()

## Whether each band mode is on, so the chip can show it. Set by the editor.
var face_edit_on := false:
	set(value):
		face_edit_on = value
		queue_redraw()
var schematic_on := false:
	set(value):
		schematic_on = value
		queue_redraw()

## Something other than a face is mounted on the canvas - the schematic, today.
##
## Separate from face_up rather than folded into it, because face_up means "this case is
## turned over" and carries a handful of other consequences: the case stops drawing its
## own band, the FACE chip becomes WIRES, drags are read differently. A tenant that only
## needs to be kept under the camera should not have to claim all of that.
var mount_up := false:
	set(value):
		mount_up = value
		queue_redraw()

## Called every frame while any face is up, so the mounts follow the camera.
signal face_needs_placing
## An open module's FACE/WIRES control was clicked: turn that one container. The name
## is a flip key: an open group's module name, or a flipped instance node's id.
signal group_flip_toggled(module_name: String)
## Frames of turned-over open modules, in graph coordinates: name -> Rect2. Set by main
## when it mounts a face, because the members' own rectangles are hidden with the
## members and can no longer say where the container stands.
var flip_frames: Dictionary = {}
## A mounted face is being picked up by its band, so an undo step can open first.
signal face_move_started(key: String)
## One step of the drag, in graph units. Main moves what the key stands for — the
## hidden widgets are where positions live between commits — and the mount follows.
signal face_dragged(key: String, step: Vector2)
## The band was let go: write the positions down.
signal face_moved(key: String)
## A socket on a mounted face was grabbed: the start of a cable, headed for a port.
signal face_socket_grabbed(mount: Control, socket: Dictionary)
## The band was double-tapped: the container wants a new name.
signal face_rename_requested(key: String)
## The band's ✕ was pressed: take this device out of the patch.
signal face_remove_requested(key: String)
## The band's DIVE chip: descend into the turned device's definition.
signal face_dive_requested(key: String)
## A node's title was double-tapped: dive into what it stands for. This is the
## faceless module's way down — a subcircuit shows as a node, and its title is the
## same handle the device's band is.
signal node_dive_requested(widget_name: String)
var _dive_hits: Dictionary = {}
## Which turned containers may be removed from their band — instances, not open
## groups, whose ✕ would mean something murkier. Set by main beside flip_frames.
var flip_deletable: Dictionary = {}
var _remove_hits: Dictionary = {}
var _face_drag_key := ""
var _face_drag_from := Vector2.ZERO
## What the band above a turned container says, when its key is not worth reading:
## a flipped instance node is keyed by instance id but wears its module's name.
var flip_labels: Dictionary = {}
var _flip_hits: Dictionary = {}
## The case is about to move, so an undo step can be opened before anything shifts.
signal case_move_started
## The case finished moving, so the document should be told where its nodes are now.
signal case_moved

## The control that turns the container over, at the right-hand end of the band.
## The controls on the case band, right-aligned, in the order they are read: what you
## are doing to the face, then the other view, then the face itself.
##
## Three views and one mode, all on the band. They are the answers to "how am I looking
## at this patch", and they were spread across a toolbar and a case until they were not.
##
## GRAPH is named rather than implied. It used to be reachable only by turning off
## whichever view you were in — press SCHEMATIC again, or press a door labelled GRAPH
## that was really FACE VIEW wearing another name — so the wiring was the one view with
## no button of its own. Now each view has a chip, the chip says where it goes, and the
## lit one is where you are.
const CASE_CHIPS := ["face_edit", "graph", "schematic", "face_view"]
const CASE_CHIP_LABELS := {
	"face_edit": "FACE EDIT", "graph": "GRAPH",
	"schematic": "SCHEMATIC", "face_view": "FACE VIEW",
}


## Fixed labels now. The door used to say GRAPH from the face and FACE VIEW from the
## graph, which is one control with two names — readable enough until a third view
## arrived and "the other side" stopped meaning anything.
func _chip_label(key: String) -> String:
	return str(CASE_CHIP_LABELS[key])


func _chip_lit(key: String) -> bool:
	match key:
		"face_edit":
			return face_edit_on
		"schematic":
			return schematic_on
		"face_view":
			return face_up
		"graph":
			return not face_up and not schematic_on
	return false


func _case_chip_rects() -> Dictionary:
	var out: Dictionary = {}
	var band := _case_band_rect()
	if band.size.x <= 0.0:
		return out
	var font := Design.font(Design.WEIGHT_MEDIUM)
	if font == null:
		font = get_theme_default_font()
	if font == null:
		return out
	var scale := zoom if zoom > 0.0 else 1.0
	var text_size := int(maxf(float(Design.type(Design.SIZE_CONTROL)) * scale, 8.0))
	var inset := band.size.y * 0.18
	var pad := float(Design.scale(8)) * scale
	var gap := float(Design.scale(6)) * scale

	# Laid out right to left so the rightmost chip keeps its place on the band however
	# many there are, and the band's own title keeps the left.
	var edge := band.end.x - inset
	for index in range(CASE_CHIPS.size() - 1, -1, -1):
		var key: String = CASE_CHIPS[index]
		var measured := font.get_string_size(_chip_label(key),
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, text_size)
		var width := measured.x + pad * 2.0
		# The strip may take the band up to whatever the title needs, and the title is
		# only drawn on this side — the face draws its own name, centred, on itself.
		#
		# This was a flat quarter of the band, which cost the leftmost chip on any narrow
		# case: the face hugs its panels now, and at 50% on first-synth that is a 256px
		# band where three chips want 214 and the guard demanded 364. FACE EDIT was
		# dropped by about a pixel, and the control that goes first is the one furthest
		# from the door, which is the worst of the three to lose.
		var reserved := inset if face_up else band.size.x * 0.25
		if edge - width < band.position.x + reserved:
			break
		out[key] = Rect2(Vector2(edge - width, band.position.y + inset),
			Vector2(width, band.size.y - inset * 2.0))
		edge -= width + gap
	return out


## Kept under its old name because the flip is still the rightmost chip, and the press
## handling and the tests both reach for it that way.
func _case_flip_rect() -> Rect2:
	return _case_chip_rects().get("face_view", Rect2())


var _case_dragging := false
var _case_drag_from := Vector2.ZERO
var _case_drag_travel := 0.0
## Where an empty-canvas press landed, or INF while none is in flight.
var _canvas_press_at := Vector2.INF


## The case's title band, in screen coordinates: its name, and the one strip
## of it that is a handle rather than workspace.
func _case_band_rect() -> Rect2:
	if case_title == "":
		return Rect2()
	var frame := case_box()
	if frame.size.x <= 0.0:
		return Rect2()
	var scale := zoom if zoom > 0.0 else 1.0
	return Rect2(frame.position * scale - scroll_offset,
		Vector2(frame.size.x * scale, float(Design.scale(CASE_BAND)) * scale))


func _draw_case() -> void:
	if face_up or mount_up or not flip_frames.is_empty():
		face_needs_placing.emit()
	if case_title == "":
		return
	var frame := case_box()
	if frame.size.x <= 0.0:
		return
	var scale := zoom if zoom > 0.0 else 1.0
	var box := Rect2(frame.position * scale - scroll_offset, frame.size * scale)
	var band := float(Design.scale(CASE_BAND)) * scale

	var font := Design.font(Design.WEIGHT_SEMIBOLD)
	if font == null:
		return
	var text_size := int(maxf(float(Design.type(Design.SIZE_CONTROL)) * scale, 8.0))

	# The mounted face draws its own case, and two cases in one spot is one too many —
	# so the aluminium and the title are skipped while it is up. The chips are not: they
	# are how you leave, and the way out of a view cannot live only in the view you left.
	if not face_up:
		# The rack's own case colours, so the graph's boundary and the panel's are the
		# same aluminium rather than two greys that happen to be close.
		draw_rect(box, Color(Rack.PANEL_LOW.darkened(0.35), 0.55))
		draw_rect(box, Rack.PANEL_EDGE, false, 1.0)
		Rack.draw_rail(self, Rect2(box.position, Vector2(box.size.x, band)))
		draw_string(font, box.position + Vector2(float(Design.scale(Design.SPACE_M)),
			band * 0.72), case_title.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			text_size, Design.INK_SECOND)

	# The chips. Face view is a door — press it and you are somewhere else — while the
	# other two are modes you are either in or not, so those two light up when they are
	# on and the door never does.
	var chips := _case_chip_rects()
	for key in chips:
		var chip: Rect2 = chips[key]
		if chip.size.x <= 4.0:
			continue
		# Lit is where you are, or which mode is on. Three of these are views and exactly
		# one of them is always true, so there is always something lit to read.
		var lit: bool = _chip_lit(str(key))
		draw_rect(chip, Color(Design.ACCENT, 0.55 if lit else 0.16))
		draw_rect(chip, Color(Design.ACCENT, 0.9 if lit else 0.55), false, 1.0)
		var label := _chip_label(key)
		var measured := font.get_string_size(label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, text_size)
		draw_string(font, chip.position + Vector2((chip.size.x - measured.x) * 0.5,
			chip.size.y * 0.5 + measured.y * 0.34), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, text_size,
			Design.ON_ACCENT if lit else Design.ACCENT)


func _draw() -> void:
	_draw_case()
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


## Polled rather than driven by a signal, because GraphEdit does not emit one for
## zoom — and the wheel changes it without going through any code of ours.
## The band a given zoom belongs to, with no memory. Detail rises as the number falls:
## FULL is 0, TOPOLOGY is 3.
static func level_for(z: float) -> int:
	if z >= _full_floor():
		return Detail.FULL
	if z >= compact_floor():
		return Detail.COMPACT
	if z >= summary_floor():
		return Detail.SUMMARY
	return Detail.TOPOLOGY


## Keeps the port hotzones a constant size on the glass. Called with _update_detail, and
## it writes only when the zoom has actually moved: a theme override is a notification to
## every child, which is not something to do sixty times a second for no change.
func _update_hit_targets() -> void:
	if is_equal_approx(zoom, _hotzone_zoom):
		return
	_hotzone_zoom = zoom
	var compensation: float = float(PORT_TARGET_MIN) / maxf(zoom, 0.05)
	add_theme_constant_override("port_hotzone_outer_extent",
		int(roundf(maxf(float(Design.scale(PORT_HOTZONE_OUTER)), compensation))))
	# The inner extent reaches back across the node, so it is allowed to grow but not to
	# run off toward the far side of a narrow one.
	add_theme_constant_override("port_hotzone_inner_extent",
		int(roundf(minf(maxf(float(Design.scale(PORT_HOTZONE_INNER)), compensation),
			60.0))))


func _update_detail() -> void:
	# 1:1 holds FULL at every zoom: the whole point of the mode is that the drawing
	# never changes, only the distance to it.
	if detail_mode == DetailMode.ONE_TO_ONE:
		if detail != Detail.FULL:
			detail = Detail.FULL
			detail_changed.emit(Detail.FULL)
		return
	var plain := level_for(zoom)
	var level := detail
	if plain > detail:
		# Zoomed out past a boundary. Detail drops the moment it has to: staying is
		# how text ends up under its minimum, which is the one thing this may not do.
		level = plain
	elif plain < detail:
		# Zoomed in. Detail only comes back once the zoom is clear of the boundary by
		# the hysteresis margin — asked at the stricter zoom, so sitting exactly on a
		# threshold answers "stay".
		var stricter := level_for(zoom - DETAIL_HYSTERESIS)
		if stricter < detail:
			level = stricter
	if level == detail:
		return
	detail = level
	detail_changed.emit(level)


## The one piece of movement in the editor.
##
## When a port is carrying something, it and the first stretch of its cable pick up a
## faint halo in the signal-type colour, proportional to level. No colour cycling, no
## pulsing, nothing that moves when the graph is silent — the intent is that a running
## instrument looks different from a stopped one at a glance, which is true of every
## piece of hardware on a rack and true of almost no software patcher.
##
## Off entirely under reduced motion; see Design.reduced_motion.
class GlowOverlay extends Control:
	var graph: GraphEdit

	## Peak alpha at full scale. Deliberately low: this should be noticed out of the
	## corner of an eye and never read as a highlight, which is a different state.
	const MAX_ALPHA := 0.55
	const MIN_RADIUS := 8.0
	const MAX_RADIUS := 18.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# Additive, which is the whole difference between a glow and a smudge. A
		# translucent circle *mixes* with what is under it, so over a node body — which
		# is lighter than the canvas — it came out darker than its surroundings and read
		# as a stain rather than as light. Adding can only ever brighten.
		var glow_material := CanvasItemMaterial.new()
		glow_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = glow_material
		# Drawn above the nodes by z-index, not by reordering.
		#
		# The first version moved itself to the end of GraphEdit's children every frame,
		# on the theory that the move would happen once. It never stopped: GraphEdit keeps
		# its own internal children — the minimap, the zoom menu — and puts them back on
		# top, so the two of us reordered the same list sixty times a second. The round
		# trip went from 12 runs in 12 to 9 in 12, crashing at shutdown with 0xC0000005,
		# and I spent three fixes on the teardown path before measuring the commit before
		# this one and finding the flake was mine. z_index gets the same result without
		# touching the tree at all.
		z_index = 100

	func _process(_delta: float) -> void:
		if graph == null:
			return

		var anything: bool = not graph.port_levels.is_empty()
		anything = anything or not graph.hovered_port.is_empty()
		anything = anything or not graph.hovered_cable.is_empty()
		if anything:
			queue_redraw()

	## A ring around whatever the pointer is over.
	##
	## Not suppressed by reduced motion: it is a static response to where the pointer
	## already is rather than something that moves on its own, and removing it would
	## take away the only sign that a port is under the cursor at all.
	## Both ends of the cable under the pointer.
	##
	## The cable itself is already brightened by GraphEdit. The ends are the part that
	## answers the question somebody actually had: a highlighted curve still has to be
	## followed with the eye to find where it lands, and on a dense patch that is the
	## whole of the difficulty.
	func _draw_cable_ends() -> void:
		if graph.hovered_cable.is_empty():
			return
		var from_node := graph.get_node_or_null(
			NodePath(str(graph.hovered_cable["from_node"]))) as GraphNode
		var to_node := graph.get_node_or_null(
			NodePath(str(graph.hovered_cable["to_node"]))) as GraphNode
		if from_node == null or to_node == null:
			return
		var from_port := int(graph.hovered_cable["from_port"])
		var to_port := int(graph.hovered_cable["to_port"])
		if from_port >= from_node.get_output_port_count():
			return
		if to_port >= to_node.get_input_port_count():
			return

		var scale: float = graph.zoom if graph.zoom > 0.0 else 1.0
		var colour: Color = from_node.get_output_port_color(from_port)
		var ends := [
			from_node.position_offset + from_node.get_output_port_position(from_port),
			to_node.position_offset + to_node.get_input_port_position(to_port),
		]
		for spot: Vector2 in ends:
			draw_arc(spot * scale - graph.scroll_offset, 13.0 * scale, 0.0, TAU, 32,
				Color(colour.r, colour.g, colour.b, 0.9), 2.0 * scale, true)


	func _draw_hover() -> void:
		_draw_cable_ends()
		if graph.hovered_port.is_empty():
			return
		var node := graph.get_node_or_null(
			NodePath(graph.hovered_port["widget"])) as GraphNode
		if node == null:
			return
		var left: bool = graph.hovered_port["side"] == "left"
		var index: int = graph.hovered_port["index"]
		if index >= (node.get_input_port_count() if left else node.get_output_port_count()):
			return
		var spot: Vector2 = node.get_input_port_position(index) if left \
			else node.get_output_port_position(index)
		var scale: float = graph.zoom if graph.zoom > 0.0 else 1.0
		var screen := (node.position_offset + spot) * scale - graph.scroll_offset
		var colour: Color = node.get_input_port_color(index) if left \
			else node.get_output_port_color(index)
		# An outline rather than a fill, so it reads as "this one" without covering the
		# jack it is pointing at.
		draw_arc(screen, 13.0 * scale, 0.0, TAU, 32,
			Color(colour.r, colour.g, colour.b, 0.9), 2.0 * scale, true)


	func _draw() -> void:
		if graph != null and graph.face_up:
			return
		if graph == null:
			return
		_draw_hover()
		if Design.reduced_motion:
			return
		var scale: float = graph.zoom if graph.zoom > 0.0 else 1.0
		for node_name in graph.port_levels:
			var node := graph.get_node_or_null(NodePath(node_name)) as GraphNode
			if node == null:
				continue
			var ports: Dictionary = graph.port_levels[node_name]
			for port_index: int in ports:
				var level: float = ports[port_index]
				if level <= 0.01 or port_index >= node.get_output_port_count():
					continue
				var spot: Vector2 = node.position_offset \
					+ node.get_output_port_position(port_index)
				var screen := spot * scale - graph.scroll_offset
				var colour: Color = node.get_output_port_color(port_index)
				# Two rings rather than a blur, because a blurred sprite at this size on a
				# dark background turns into a grey smudge.
				var radius: float = lerpf(MIN_RADIUS, MAX_RADIUS, level) * scale
				# Three rings rather than a blur. A blurred sprite at this size on a dark
				# background turns into a grey disc; concentric additive circles fall off
				# steeply enough to read as light coming off a jack.
				for ring in [[1.0, 0.22], [0.62, 0.38], [0.3, 1.0]]:
					draw_circle(screen, radius * ring[0],
						Color(colour.r, colour.g, colour.b, MAX_ALPHA * level * ring[1]))


## The canvas furniture that is not a node: the frame round an open module, and the
## rubber band while one is being drawn.
class WandOverlay extends Control:
	var graph = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# Above the nodes: a frame drawn behind the panels it encloses is a frame nobody
		# sees. See GlowOverlay for why this is z_index and not a reorder.
		z_index = 101

	func _process(_delta: float) -> void:
		if graph != null and (graph.drawing or graph.face_edit
				or not graph.groups.is_empty()
				or not graph.flip_frames.is_empty()):
			queue_redraw()

	func _draw() -> void:
		if graph == null or graph.face_up:
			return
		if graph.face_edit:
			_draw_face_edit()
		_draw_groups()
		_draw_band()

	## Face edit's paint: a frame on every knob cell, lit when the knob is on the
	## document's face and quiet when it is not, and a ring on every seam port,
	## which is how a port gets onto the plates. What is on the face is main's
	## knowledge, carried here as metas on the cells and the seam widgets.
	func _draw_face_edit() -> void:
		var origin: Vector2 = get_global_rect().position
		var scale: float = graph.zoom if graph.zoom > 0.0 else 1.0
		for child in graph.get_children():
			var node := child as GraphNode
			if node == null or not node.visible:
				continue
			_frame_face_cells(node, origin)
			if bool(node.get_meta("face_seam", false)):
				_ring_face_ports(node, origin, scale, {})
			else:
				# A regular node rings only the ports a seam is serving — the ring
				# sits exactly where the next click would trim.
				var served: Dictionary = node.get_meta("face_served", {})
				if not served.is_empty():
					_ring_face_ports(node, origin, scale, served)

	func _frame_face_cells(parent: Node, origin: Vector2) -> void:
		for child in parent.get_children():
			var control := child as Control
			if control == null or not control.is_visible_in_tree():
				continue
			if str(control.get_meta("cell", "")) == "parameter":
				var box := Rect2(control.get_global_rect().position - origin,
					control.get_global_rect().size)
				if bool(control.get_meta("on_face", false)):
					# Lit: a soft halo, a filled wash and a firm edge. First pass
					# at the dress — tuned by looking, not by argument.
					draw_rect(box.grow(4.0), Color(Design.ACCENT, 0.06))
					draw_rect(box.grow(2.0), Color(Design.ACCENT, 0.12))
					draw_rect(box, Color(Design.ACCENT, 0.10))
					draw_rect(box, Color(Design.ACCENT, 0.9), false, 2.0)
				else:
					draw_rect(box, Color(1.0, 1.0, 1.0, 0.18), false, 1.0)
				continue
			_frame_face_cells(control, origin)

	## Rings ports. An empty `only` rings them all (a seam node, where every port is
	## a plate port); otherwise `only` holds "left:N"/"right:N" keys for the ports a
	## seam is serving on a regular node.
	func _ring_face_ports(node: GraphNode, origin: Vector2, scale: float,
			only: Dictionary) -> void:
		var node_at: Vector2 = node.get_global_rect().position - origin
		var radius: float = maxf(6.0, 9.0 * scale)
		for index in node.get_input_port_count():
			if not only.is_empty() and not only.has("left:%d" % index):
				continue
			var at: Vector2 = node_at + node.get_input_port_position(index) * scale
			draw_circle(at, radius, Color(Design.ACCENT, 0.12))
			draw_arc(at, radius, 0.0, TAU, 24, Color(Design.ACCENT, 0.9), 2.0)
		for index in node.get_output_port_count():
			if not only.is_empty() and not only.has("right:%d" % index):
				continue
			var at: Vector2 = node_at + node.get_output_port_position(index) * scale
			draw_circle(at, radius, Color(Design.ACCENT, 0.12))
			draw_arc(at, radius, 0.0, TAU, 24, Color(Design.ACCENT, 0.9), 2.0)

	## A dashed frame around the parts of an open module, with its name on it and a way to
	## shut it again.
	##
	## Around the parts rather than behind them: the frame is drawn from the bounding box of
	## whatever its members are at this instant, so dragging one of them moves the frame,
	## and it can never be out of date with the thing it encloses. The alternative — a
	## rectangle stored in the document — is a second copy of where the nodes are, and the
	## copies disagree the first time somebody drags one.
	func _draw_groups() -> void:
		_close_hits_out.clear()
		_flip_hits_out.clear()
		_remove_hits_out.clear()
		_dive_hits_out.clear()
		var scale: float = graph.zoom if graph.zoom > 0.0 else 1.0
		var font := Design.font(Design.WEIGHT_SEMIBOLD)
		var size := Design.type(Design.SIZE_CONTROL)
		var pad: float = float(Design.scale(Design.SPACE_M))

		for module_name in graph.groups:
			var frame: Rect2 = graph.group_box(str(module_name))
			if frame.size.x <= 0.0:
				continue
			var box := Rect2(frame.position * scale - graph.scroll_offset,
				frame.size * scale)
			var band := float(Design.scale(34.0)) * scale

			draw_rect(box, Color(Design.ACCENT, 0.05))
			Design.dashed_rect(self, box, Color(Design.ACCENT, 0.85), 2.0)
			draw_string(font, box.position + Vector2(pad, band * 0.7), str(module_name),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, Design.ACCENT)

			# Chips derived from the band's own height, exactly as the turned-band
			# chips below are: sized in screen constants they kept their full size
			# while the band shrank with the zoom, overflowed it leftward at a
			# fitted view, and buried the band's drag handle under FACE. What the
			# eye reads may shrink; the hit rects grow back to a clickable size.
			var chip_h: float = band * 0.72
			var chip_font: int = maxi(6, int(round(chip_h * 0.60)))
			var chip_pad: float = chip_h * 0.30
			var chip_top: float = box.position.y + (band - chip_h) * 0.5
			var chip_reach: float = maxf(0.0, (20.0 - chip_h) * 0.5)

			var label := "Close"
			var measured := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT,
				-1.0, chip_font)
			var button := Rect2(
				Vector2(box.end.x - measured.x - chip_pad * 3.0, chip_top),
				Vector2(measured.x + chip_pad * 2.0, chip_h))
			draw_rect(button, Design.ACCENT)
			draw_string(font,
				Vector2(button.position.x + chip_pad,
					button.position.y + (chip_h + font.get_ascent(chip_font)
						- font.get_descent(chip_font)) * 0.5),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, chip_font, Design.ON_ACCENT)
			_close_hits_out[module_name] = button.grow(chip_reach)

			# This container's own flip, beside Close: each case turns independently,
			# and the control for turning a thing lives on the thing.
			var face_text := "FACE"
			var face_measured := font.get_string_size(face_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, chip_font)
			var face_chip := Rect2(
				Vector2(button.position.x - face_measured.x - chip_pad * 3.0, chip_top),
				Vector2(face_measured.x + chip_pad * 2.0, chip_h))
			draw_rect(face_chip, Color(Design.ACCENT, 0.16))
			draw_rect(face_chip, Color(Design.ACCENT, 0.55), false, 1.0)
			draw_string(font,
				Vector2(face_chip.position.x + chip_pad,
					face_chip.position.y + (chip_h + font.get_ascent(chip_font)
						- font.get_descent(chip_font)) * 0.5),
				face_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, chip_font, Design.ACCENT)
			_flip_hits_out[module_name] = face_chip.grow(chip_reach)

		# Turned containers: the members are hidden, so the band is drawn from the frame
		# main recorded when it mounted the face. Name and the way back, nothing else —
		# Close would fold a module whose parts are not even on view.
		for module_name in graph.flip_frames:
			var frame: Rect2 = graph.flip_frames[module_name]
			var strip := Rect2(frame.position * scale - graph.scroll_offset,
				Vector2(frame.size.x * scale, float(Design.scale(26.0)) * scale))
			draw_rect(strip, Color(Design.ACCENT, 0.10))
			draw_string(font, strip.position + Vector2(pad, strip.size.y * 0.72),
				str(graph.flip_labels.get(module_name, module_name)),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, Design.ACCENT)
			# Small and quiet, sitting inside the title band rather than over it.
			# Everything here is derived from the strip's own height, because the
			# strip scales with the zoom and the chips must scale with the strip —
			# sized in screen constants they towered over the band at any working
			# zoom, twice the height of the title they sat beside. The hit rects
			# are grown back to a clickable size when the drawing runs small; what
			# the eye reads may shrink, what the hand aims at may not.
			var chip_h: float = strip.size.y * 0.72
			var chip_font: int = maxi(6, int(round(chip_h * 0.60)))
			var chip_pad: float = chip_h * 0.30
			var chip_top: float = strip.position.y + (strip.size.y - chip_h) * 0.5
			var chip_reach: float = maxf(0.0, (20.0 - chip_h) * 0.5)
			var chips_right: float = strip.end.x
			if not graph.flip_deletable.has(module_name):
				# WIRES belongs to turned open groups alone now: a device's way
				# into its wiring is DIVE, and a toggle beside it would be two
				# answers to one question.
				var wires_text := "WIRES"
				var wires_measured := font.get_string_size(wires_text,
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, chip_font)
				var wires_chip := Rect2(
					Vector2(strip.end.x - wires_measured.x - chip_pad * 2.0 - chip_pad,
						chip_top),
					Vector2(wires_measured.x + chip_pad * 2.0, chip_h))
				draw_rect(wires_chip, Color(Design.ACCENT, 0.16))
				draw_rect(wires_chip, Color(Design.ACCENT, 0.55), false, 1.0)
				draw_string(font,
					Vector2(wires_chip.position.x + chip_pad,
						wires_chip.position.y + (chip_h + font.get_ascent(chip_font)
							- font.get_descent(chip_font)) * 0.5),
					wires_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, chip_font, Design.ACCENT)
				_flip_hits_out[module_name] = wires_chip.grow(chip_reach)
				chips_right = wires_chip.position.x

			# The way out, for a device: an ✕ beside WIRES, drawn with strokes
			# rather than a glyph the font may not carry. Same quiet chip dress;
			# what it does is undoable, so it earns no alarm colour.
			if graph.flip_deletable.has(module_name):
				var cross_chip := Rect2(
					Vector2(chips_right - chip_h - chip_pad, chip_top),
					Vector2(chip_h, chip_h))
				draw_rect(cross_chip, Color(Design.ACCENT, 0.16))
				draw_rect(cross_chip, Color(Design.ACCENT, 0.55), false, 1.0)
				var inset: float = chip_h * 0.30
				draw_line(cross_chip.position + Vector2(inset, inset),
					cross_chip.end - Vector2(inset, inset), Design.ACCENT,
					maxf(1.0, chip_h * 0.07), true)
				draw_line(Vector2(cross_chip.end.x - inset, cross_chip.position.y + inset),
					Vector2(cross_chip.position.x + inset, cross_chip.end.y - inset),
					Design.ACCENT, maxf(1.0, chip_h * 0.07), true)
				_remove_hits_out[module_name] = cross_chip.grow(chip_reach)

				# And the way down: DIVE, in words — the double tap belongs to the
				# name, so descending gets a chip of its own.
				var dive_text := "DIVE"
				var dive_measured := font.get_string_size(dive_text,
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, chip_font)
				var dive_chip := Rect2(
					Vector2(cross_chip.position.x - dive_measured.x
						- chip_pad * 2.0 - chip_pad, chip_top),
					Vector2(dive_measured.x + chip_pad * 2.0, chip_h))
				draw_rect(dive_chip, Color(Design.ACCENT, 0.16))
				draw_rect(dive_chip, Color(Design.ACCENT, 0.55), false, 1.0)
				draw_string(font,
					Vector2(dive_chip.position.x + chip_pad,
						dive_chip.position.y + (chip_h + font.get_ascent(chip_font)
							- font.get_descent(chip_font)) * 0.5),
					dive_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, chip_font,
					Design.ACCENT)
				_dive_hits_out[module_name] = dive_chip.grow(chip_reach)

		graph._close_hits = _close_hits_out.duplicate()
		graph._flip_hits = _flip_hits_out.duplicate()
		graph._remove_hits = _remove_hits_out.duplicate()
		graph._dive_hits = _dive_hits_out.duplicate()

	var _close_hits_out: Dictionary = {}
	var _flip_hits_out: Dictionary = {}
	var _remove_hits_out: Dictionary = {}
	var _dive_hits_out: Dictionary = {}


	## The rubber band, while one is being drawn. Dashed for the same reason a target is:
	## it is a question, not a state.
	func _draw_band() -> void:
		if not graph.drawing or not graph._banding:
			return
		var band := Rect2(graph._band_from, Vector2.ZERO).expand(graph._band_to).abs()
		draw_rect(band, Color(Design.ACCENT, 0.08))
		Design.dashed_rect(self, band, Design.ACCENT, 2.0)


	func _local(rect: Rect2) -> Rect2:
		var inverse := get_global_transform().affine_inverse()
		return Rect2(inverse * rect.position, rect.size * inverse.get_scale())



## First refusal on a click, ahead of the GUI pass — which is what lets a ghost jack be
## clicked at all, since it sits inside a node and the node would otherwise take the press.
## Anything not wanted here falls through untouched, so selecting, dragging and panning are
## as they were.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var rect := get_global_rect()

	# The rubber band owns the pointer while it is armed, so nothing below sees a press.
	if drawing:
		var press := event as InputEventMouseButton
		if press != null and press.button_index == MOUSE_BUTTON_LEFT:
			if press.pressed and rect.has_point(press.position):
				_banding = true
				_band_from = press.position - rect.position
				_band_to = _band_from
				get_viewport().set_input_as_handled()
			elif _banding:
				_banding = false
				drawing = false
				mouse_default_cursor_shape = Control.CURSOR_ARROW
				region_drawn.emit(_nodes_within(Rect2(_band_from, Vector2.ZERO)
					.expand(_band_to).abs()))
				get_viewport().set_input_as_handled()
			return
		var drag := event as InputEventMouseMotion
		if drag != null and _banding:
			_band_to = drag.position - rect.position
			if _wand_overlay != null:
				_wand_overlay.queue_redraw()
			get_viewport().set_input_as_handled()
		return

	# A mounted face in hand. Motion and release are watched from here because the
	# press was claimed here, ahead of the GUI pass — the mount underneath never saw
	# it, and must not see the rest of the gesture either.
	if _face_drag_key != "":
		var moving := event as InputEventMouseMotion
		if moving != null:
			var at := _to_graph(moving.position - rect.position)
			var step := at - _face_drag_from
			_face_drag_from = at
			face_dragged.emit(_face_drag_key, step)
			get_viewport().set_input_as_handled()
			return
		var letting := event as InputEventMouseButton
		if letting != null and letting.button_index == MOUSE_BUTTON_LEFT \
				and not letting.pressed:
			var done := _face_drag_key
			_face_drag_key = ""
			face_moved.emit(done)
			get_viewport().set_input_as_handled()
		return

	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return
	if not rect.has_point(button.position):
		return

	# Face edit claims the press before the knobs can: in this mode a knob is not
	# for turning but for pointing at, and the cell's own control must not see the
	# click that nominated it. Only presses on a cell or a port are claimed — the
	# canvas, the bands and their chips stay live so the graph can still be moved
	# around while dressing the face.
	if face_edit:
		var poked_port := port_at(button.position - rect.position)
		if not poked_port.is_empty():
			face_port_toggled.emit(str(poked_port["widget"]),
				str(poked_port["side"]), int(poked_port["index"]))
			get_viewport().set_input_as_handled()
			return
		var poked_cell := face_cell_at(button.position)
		if poked_cell != null:
			face_cell_toggled.emit(str(poked_cell.get_meta("node_id", "")),
				str(poked_cell.get_meta("parameter_name", "")))
			get_viewport().set_input_as_handled()
			return

	# A frame's close button, before anything on the canvas under it.
	for module_name in _close_hits:
		if (_close_hits[module_name] as Rect2).has_point(button.position - rect.position):
			group_closed.emit(str(module_name))
			get_viewport().set_input_as_handled()
			return

	# A frame's FACE control, or a turned container's WIRES — one dictionary, since a
	# container has exactly one of the two at a time.
	for module_name in _flip_hits:
		if (_flip_hits[module_name] as Rect2).has_point(button.position - rect.position):
			group_flip_toggled.emit(str(module_name))
			get_viewport().set_input_as_handled()
			return

	# The band's ✕: take the device out. Ahead of the band's own handle, like the
	# other chips.
	for module_name in _remove_hits:
		if (_remove_hits[module_name] as Rect2).has_point(button.position - rect.position):
			face_remove_requested.emit(str(module_name))
			get_viewport().set_input_as_handled()
			return

	# The band's DIVE: down into the definition.
	for module_name in _dive_hits:
		if (_dive_hits[module_name] as Rect2).has_point(button.position - rect.position):
			face_dive_requested.emit(str(module_name))
			get_viewport().set_input_as_handled()
			return

	# The band above a turned container is its handle, as the case band is the case's:
	# the panel below is for playing, and the strip that names the thing is what a hand
	# moves it by. The chips were tested above and returned, so a press landing here is
	# the band itself.
	for key in flip_frames:
		var frame: Rect2 = flip_frames[key]
		var strip := Rect2(frame.position * zoom - scroll_offset,
			Vector2(frame.size.x * zoom, float(Design.scale(26.0)) * zoom))
		if strip.has_point(button.position - rect.position):
			# The double tap on the name asks to change it; the single press is the
			# handle, as ever.
			if button.double_click:
				face_rename_requested.emit(str(key))
				get_viewport().set_input_as_handled()
				return
			_face_drag_key = str(key)
			_face_drag_from = _to_graph(button.position - rect.position)
			face_move_started.emit(str(key))
			get_viewport().set_input_as_handled()
			return

	# An open module's frame carries the same handle: the band its name is written
	# on, under the Close and FACE chips already tested above. One drag machinery
	# for both — the key names a container either way, and main already knows a
	# group key moves every member.
	for module_name in groups:
		var open_frame: Rect2 = group_box(str(module_name))
		if open_frame.size.x <= 0.0:
			continue
		var open_strip := Rect2(open_frame.position * zoom - scroll_offset,
			Vector2(open_frame.size.x * zoom, float(Design.scale(34.0)) * zoom))
		if open_strip.has_point(button.position - rect.position):
			_face_drag_key = str(module_name)
			_face_drag_from = _to_graph(button.position - rect.position)
			face_move_started.emit(str(module_name))
			get_viewport().set_input_as_handled()
			return

	# A plate socket on a mounted face: the start of a cable. Under the bands on
	# purpose — the band is the handle, and the sockets are the jacks below it.
	for child in get_children():
		var face := child as Control
		if face == null or not face.visible or not face.has_method("socket_at"):
			continue
		var socket: Dictionary = face.socket_at(button.position)
		if not socket.is_empty():
			socket["double"] = button.double_click
			face_socket_grabbed.emit(face, socket)
			get_viewport().set_input_as_handled()
			return

	# A double tap on a node's title dives into it — the title strip only, because
	# the body is where knobs live and their own double tap means "go home".
	if button.double_click:
		var over := _node_at(_to_graph(button.position - rect.position))
		if over != "":
			var widget := get_node_or_null(NodePath(over)) as GraphNode
			if widget != null:
				var bar := widget.get_titlebar_hbox()
				if bar != null and bar.get_global_rect().grow(4.0).has_point(button.position):
					node_dive_requested.emit(over)
					get_viewport().set_input_as_handled()
					return

	# A ghost jack: an inner port the module does not expose, drawn on the instance while
	# it is selected. Tested before the node gets the press because a ghost is inside the
	# node body, and the node would otherwise swallow it.
	var ghost := ghost_port_at(button.position)
	if not ghost.is_empty():
		ghost_port_picked.emit(str(ghost["widget"]), ghost["offer"] as Dictionary)
		get_viewport().set_input_as_handled()
		return


## The parameter row under a viewport-space point, or null. Rows fold away under the
## disclosure triangle and at low zoom, and `is_visible_in_tree` is what stops the wand
## picking a knob that is not on screen to be picked.
## The ghost jack under the pointer, or {} — an inner port of a module that the module does
## not expose, drawn on the instance while the wand is up so that declaring one is a click
## on the thing itself rather than a trip to a list.
##
## Any module instance rather than only the selected ones, which is where this parts company
## with `port_at`. That rule is about *nomination*: while the wand is picking a surface out
## of a selection, a jack on a node nobody selected would be a pick from outside the thing
## being made. A ghost is not a pick — it only exists on a module, only while the wand is
## up, and does exactly one thing when clicked.
func ghost_port_at(point: Vector2) -> Dictionary:
	for child in get_children():
		var node := child as GraphNode
		if node == null or not node.visible:
			continue
		var found := _ghost_at(node, point)
		if not found.is_empty():
			return {"widget": String(node.name), "offer": found}
	return {}


func _ghost_at(parent: Node, point: Vector2) -> Dictionary:
	for child in parent.get_children():
		var control := child as Control
		if control == null or not control.is_visible_in_tree():
			continue
		var offer: Dictionary = control.get_meta("ghost_offer", {})
		if not offer.is_empty():
			if control.get_global_rect().has_point(point):
				return offer
			continue
		var deeper := _ghost_at(control, point)
		if not deeper.is_empty():
			return deeper
	return {}


func parameter_row_at(point: Vector2) -> Control:
	for child in get_children():
		var node := child as GraphNode
		if node == null or not node.visible or not node.selected:
			continue
		var found := _row_at(node, point)
		if found != null:
			return found
	return null


## The cell under the pointer on any visible node — face edit's hit test. Unlike the
## wand's `parameter_row_at` this does not ask for a selection: the face is dressed
## from the whole graph, not from a nomination.
func face_cell_at(point: Vector2) -> Control:
	for child in get_children():
		var node := child as GraphNode
		if node == null or not node.visible:
			continue
		var found := _row_at(node, point)
		if found != null:
			return found
	return null


func _row_at(parent: Node, point: Vector2) -> Control:
	for child in parent.get_children():
		var control := child as Control
		if control == null or not control.is_visible_in_tree():
			continue
		if control.get_meta("cell", "") == "parameter":
			if control.get_global_rect().has_point(point):
				return control
			continue
		var deeper := _row_at(control, point)
		if deeper != null:
			return deeper
	return null


## Finds the port nearest the pointer, within the same reach as the connection hot
## zone so that hovering and dropping agree about which port you mean. `only_selected`
## narrows it to the current selection, which is what the wand picks from.
func port_at(local_point: Vector2, only_selected: bool = false) -> Dictionary:
	var reach: float = float(get_theme_constant("port_hotzone_outer_extent"))
	var scale: float = zoom if zoom > 0.0 else 1.0
	var best := {}
	var best_distance := reach

	for child in get_children():
		var node := child as GraphNode
		if node == null or not node.visible:
			continue
		if only_selected and not node.selected:
			continue
		for side in ["left", "right"]:
			var count: int = node.get_input_port_count() if side == "left" \
				else node.get_output_port_count()
			for index in count:
				var spot: Vector2 = node.get_input_port_position(index) if side == "left" \
					else node.get_output_port_position(index)
				var screen := (node.position_offset + spot) * scale - scroll_offset
				var distance := screen.distance_to(local_point)
				if distance < best_distance:
					best_distance = distance
					best = {"widget": String(node.name), "side": side, "index": index}
	return best


func _update_hover(local_point: Vector2) -> void:
	var best := port_at(local_point)
	if best == hovered_port:
		return
	hovered_port = best
	queue_redraw()
	if best.is_empty():
		port_hovered.emit("", "", -1)
	else:
		port_hovered.emit(best["widget"], best["side"], best["index"])


## The part of the canvas nothing is sitting on top of.
##
## `size` is the whole control, and several permanent things overlap it: GraphEdit draws
## its own scrollbars inside its bounds, the zoom cluster floats over the top left, and the
## minimap floats over the bottom right. Centring a node against `size` therefore aims at a
## point that may be underneath any of them — which is how a node ends up parked behind the
## minimap, or half under the inspector once the divider moves.
##
## Everything that positions the view should use this: centring, fit, and anything that
## works out whether something is visible. Nothing important should ever come to rest
## beneath permanent furniture.
func usable_rect() -> Rect2:
	var rect := Rect2(Vector2.ZERO, size)

	# Scrollbars are inside the control, not outside it. GraphEdit 4.7 has no accessor
	# for them, so they are found among the internal children — and found rather than
	# assumed, because a fixed gutter width would be a guess that goes wrong the first
	# time somebody changes the theme.
	for child in get_children(true):
		var bar := child as ScrollBar
		if bar == null or not bar.visible:
			continue
		if bar is VScrollBar:
			rect.size.x -= bar.size.x
		else:
			rect.size.y -= bar.size.y

	# The zoom cluster, top left.
	var menu := get_menu_hbox()
	if menu != null and menu.visible:
		var taken: float = menu.size.y + Design.SPACE_S
		rect.position.y += taken
		rect.size.y -= taken

	# The minimap, bottom right. Only the height is taken back: a graph is usually wider
	# than it is tall, so losing a strip off the bottom costs less than losing a column off
	# the side, and the minimap is in the corner of both.
	if minimap_enabled:
		rect.size.y -= minimap_size.y + Design.SPACE_S

	rect.size.x = maxf(rect.size.x, 1.0)
	rect.size.y = maxf(rect.size.y, 1.0)
	return rect


## Scrolls so that a rectangle in graph space sits in the middle of the usable area.
## The 100% preset: working scale. Around the selection when there is one — "take me
## to it at real size" — and otherwise around whatever the view was already looking
## at, so the jump changes the distance and never the subject.
func zoom_actual() -> void:
	var chosen := Rect2()
	var any := false
	for child in get_children():
		var node := child as GraphNode
		if node != null and node.visible and node.selected:
			var rect := Rect2(node.position_offset, node.size)
			chosen = rect if not any else chosen.merge(rect)
			any = true
	if any:
		zoom = 1.0
		centre_on(chosen)
		# And once more after the layout settles — with the rects read FRESH. The
		# zoom change re-dresses the nodes (detail follows zoom), so a node that
		# was wearing its simplified height when this measured it grows back to
		# full dress a frame later, and the first centring parked its new bottom
		# under the minimap. Re-centring on the remembered rect would repeat the
		# same mistake with confidence; the deferred pass collects the selection
		# again. Found as a timing flake: the same suite green one night and red
		# the next, by whichever order the re-dress and the centring landed.
		_centre_on_selection.call_deferred()
		return
	var middle: Vector2 = usable_rect().get_center()
	var focus: Vector2 = (scroll_offset + middle) / maxf(zoom, 0.01)
	zoom = 1.0
	scroll_offset = focus - middle


## The deferred half of zoom_actual: wait for the selection's rects to stop
## moving — container minimums propagate over a few frames after the re-dress —
## then centre on what they settled at.
func _centre_on_selection() -> void:
	var last := Rect2()
	for settle in 8:
		var chosen := Rect2()
		var any := false
		for child in get_children():
			var node := child as GraphNode
			if node != null and node.visible and node.selected:
				var rect := Rect2(node.position_offset, node.size)
				chosen = rect if not any else chosen.merge(rect)
				any = true
		if not any:
			return
		if chosen.is_equal_approx(last):
			centre_on(chosen)
			return
		last = chosen
		await get_tree().process_frame
	centre_on(last)


func centre_on(graph_rect: Rect2) -> void:
	var view := usable_rect()
	var middle := view.position + view.size * 0.5
	scroll_offset = (graph_rect.position + graph_rect.size * 0.5) * zoom - middle


## How much of the viewport a fit leaves empty around the graph, per side.
##
## Proportional rather than a fixed 24px, because a margin is a judgement about the
## picture and not about the pixels: 24 around a graph filling a 2560-wide window is a
## hairline, and the patch ends up pressed against the frame on exactly the screens with
## the most room to spare.
##
## Floored at SPACE_XL so a small window still gets the spacing scale's answer.
const FIT_BREATHING := 0.07


## Frames the whole graph, at a zoom that fits it into the usable area.
##
## Fit has to solve for zoom *and* offset together, and against the usable rectangle
## rather than the control: fitting to the full width puts the right-hand edge of the
## graph under the scrollbar and the minimap, which is the thing this is supposed to stop.
func fit_graph() -> void:
	var bounds := Rect2()
	var found := false
	for child in get_children():
		var node := child as GraphNode
		if node == null or not node.visible:
			continue
		var node_rect := Rect2(node.position_offset, node.size)
		bounds = node_rect if not found else bounds.merge(node_rect)
		found = true
	if not found:
		return
	fit_to(bounds)


## Frames an arbitrary rectangle in graph space.
##
## Split out of fit_graph so that something which is not a node can be framed too - the
## schematic is a single mounted control, so "fit the visible nodes" has nothing to
## measure while it is up.
func fit_to(bounds: Rect2) -> void:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var view := usable_rect()
	var margin: float = maxf(float(Design.SPACE_XL),
		minf(view.size.x, view.size.y) * FIT_BREATHING)
	var room := view.size - Vector2(margin, margin) * 2.0
	var wanted: float = minf(room.x / maxf(bounds.size.x, 1.0),
		room.y / maxf(bounds.size.y, 1.0))
	# Never magnifies. Fitting a two-node patch to the window would blow it up to 200% and
	# call that framing; the request is to see the whole graph, and once you can, there is
	# nothing further to satisfy.
	zoom = clampf(wanted, zoom_min, minf(zoom_max, 1.0))
	centre_on(bounds)


## Tracks which cable the pointer is over, using the same reach as picking one up, so
## that hovering and dragging agree about which cable is meant.
func _update_cable_hover(local_point: Vector2) -> void:
	var found := _connection_at(_to_graph(local_point))
	if found == hovered_cable:
		return
	hovered_cable = found
	queue_redraw()


## Graph text at a readable size while the canvas is zoomed out.
##
## This is the layer that makes "world-space geometry, screen-space typography" true
## rather than aspirational. GraphEdit scales everything geometrically, so at 65% a 16px
## parameter label arrives as 10.4 real pixels — the stylesheet still says 16 and the
## reader still cannot read it. Checking the declared size proves nothing here; what
## matters is what lands on the glass.
##
## Counter-scaling the labels in place was tried first and the port test refused it,
## correctly: a bigger label makes a taller row, which moves every port under it, and a
## node's geometry must not depend on how far out somebody is standing. Cables would
## crawl as you zoomed. So the words move *up* here instead — drawn over the graph
## without being part of it, at their own minimum, at the place their label sits. While
## a label is being drawn up here its real one is made transparent rather than hidden,
## because hiding it would collapse the row and change the very geometry this exists to
## protect.
##
## Any Label carrying a `screen_min` meta joins in, so marking a new piece of node text
## as operational is one line at the place it is built rather than a case in here.
class ScreenText extends Control:
	var graph: GraphEdit
	var _fingerprint := ""

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# Above the nodes, under the glow.
		z_index = 99

	func _process(_delta: float) -> void:
		if graph == null:
			return
		var current: String = graph._view_fingerprint()
		if current != _fingerprint:
			_fingerprint = current
			queue_redraw()

	func _draw() -> void:
		if graph == null:
			return
		# In 1:1 the compensation stands down: the words belong to their modules again,
		# at whatever size the zoom leaves them. The alphas are put back here because
		# this class is what turned them off — leaving that to chance kept every label
		# invisible that happened to be compensated when the mode flipped.
		if graph.detail_mode == graph.DetailMode.ONE_TO_ONE:
			for child in graph.get_children():
				var node := child as GraphNode
				if node == null:
					continue
				var title: Label = node.get_meta("title_label") \
					if node.has_meta("title_label") else null
				if title != null:
					title.self_modulate.a = 1.0
				for marked in _marked(node):
					marked.self_modulate.a = 1.0
			return
		for child in graph.get_children():
			var node := child as GraphNode
			if node == null or not node.visible:
				continue
			_draw_title(node)
			_draw_labels(node)

	## The colour a node's title is drawn in, wherever it is drawn.
	##
	## Asked of the Label rather than of the styles, because the Label is what the reader
	## sees at every other zoom: this overlay drew INK_BRIGHT regardless, so a painted
	## module changed the colour of its own name halfway through a zoom, and on the pale
	## faceplates the compensated title came out near-white on cream. Two drawings of one
	## title now get their colour from one place.
	static func title_ink(node: GraphNode) -> Color:
		var label: Label = node.get_meta("title_label") 			if node.has_meta("title_label") else null
		if label != null and label.has_theme_color_override("font_color"):
			return label.get_theme_color("font_color")
		return Design.INK_BRIGHT


	## The title is drawn from the node rather than from its Label because the titlebar
	## is GraphNode's own furniture: its height is what the port rows are measured from,
	## so it is the one place where a grown label would cost the most.
	func _draw_title(node: GraphNode) -> void:
		var size := Design.type(Design.SIZE_NODE_TITLE)
		var active := Design.below_screen_minimum(size, graph.zoom,
			Design.screen_minimum(Design.MIN_SCREEN_NODE_TITLE))
		var label: Label = node.get_meta("title_label") if node.has_meta("title_label") else null
		if label != null:
			label.self_modulate.a = 0.0 if active else 1.0
		if not active:
			return

		var top_left: Vector2 = node.position_offset * graph.zoom - graph.scroll_offset
		var bar := node.get_titlebar_hbox()
		var bar_height: float = (bar.size.y if bar != null else 30.0) * graph.zoom
		var room: float = node.size.x * graph.zoom - 12.0
		if room < 20.0:
			return
		var font := Design.font(Design.WEIGHT_SEMIBOLD)
		var drawn := Design.screen_minimum(Design.MIN_SCREEN_NODE_TITLE)
		var baseline := top_left + Vector2(6.0,
			(bar_height + font.get_ascent(drawn) - font.get_descent(drawn)) * 0.5)
		draw_string(font, baseline, _elided(font, node.title, drawn, room),
			HORIZONTAL_ALIGNMENT_LEFT, room, drawn, title_ink(node))

	## Text cut to fit, with an ellipsis saying so.
	##
	## A title held at 15px inside a node three hundred pixels narrower than that title
	## simply ran off its own end, and a word that stops mid-letter reads as a rendering
	## fault rather than as a name too long for the box. The character is the difference
	## between "this is broken" and "there is more here than fits".
	static func _elided(font: Font, text: String, size: int, room: float) -> String:
		if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x <= room:
			return text
		var cut := text
		while cut.length() > 1:
			cut = cut.substr(0, cut.length() - 1)
			if font.get_string_size(cut + "…", HORIZONTAL_ALIGNMENT_LEFT, -1.0,
					size).x <= room:
				return cut.strip_edges(false, true) + "…"
		return "…"

	## How a marked label is reaching the reader.
	##
	##   IN_PLACE     the node's own label, big enough on its own
	##   COMPENSATED  drawn up here at the minimum instead
	##   NO_ROOM      its box is too narrow to hold it honestly, so it is not drawn
	enum Fit { IN_PLACE, COMPENSATED, NO_ROOM }

	## The whole screen-space typography decision, in one function.
	##
	## Split out from the drawing on purpose: the acceptance tests have to be able to ask
	## what the reader actually receives, and a test that reasons about font sizes on its
	## own is a second implementation of this rule that can agree with the stylesheet
	## while the screen disagrees with both. Asking the same function the renderer asks
	## is the only version of the check that means anything.
	static func fit_for(label: Label, zoom: float) -> Fit:
		var minimum: int = Design.screen_minimum(int(label.get_meta("screen_min", Design.TYPE_FLOOR)))
		if not Design.below_screen_minimum(label.get_theme_font_size("font_size"),
				zoom, minimum):
			return Fit.IN_PLACE
		var font := label.get_theme_font("font")
		if font == null:
			return Fit.IN_PLACE
		var needs := font.get_string_size(label.text, label.horizontal_alignment, -1.0,
			minimum).x
		return Fit.NO_ROOM if needs > room_for(label) else Fit.COMPENSATED

	## The room a label may grow into, in real pixels.
	##
	## Not its own box. A shrink-wrapped label — every port name is one — is sized to its
	## text at the *declared* size, so once the zoom has shrunk that box it is by
	## definition too small to hold the same text at the minimum: measuring against it
	## refuses precisely the compensations that most need making, and the survival test
	## caught exactly that (port names reaching nobody from 75% down while the level of
	## detail believed it was showing them).
	##
	## What must not be overrun is the neighbour, so the bound is the nearest visible
	## sibling in the direction the text grows, and the parent's edge when there is none.
	static func slot_for(label: Label) -> Vector2:
		var rect := label.get_global_rect()
		var parent := label.get_parent() as Control
		if parent == null:
			return Vector2(rect.position.x, rect.end.x)
		var bounds := parent.get_global_rect()
		var left: float = bounds.position.x
		var right: float = bounds.end.x
		for sibling in parent.get_children():
			var other := sibling as Control
			if other == null or other == label or not other.is_visible_in_tree():
				continue
			var edge := other.get_global_rect()
			if edge.end.x <= rect.position.x + 0.5:
				left = maxf(left, edge.end.x)
			elif edge.position.x >= rect.end.x - 0.5:
				right = minf(right, edge.position.x)
		left = minf(left, rect.position.x)
		right = maxf(right, rect.end.x)

		# Nothing may be drawn outside the node it belongs to. The slot is otherwise
		# derived from containers, and a container can be as wide as it likes — so at XL
		# and 63% an "out" ran past its own right edge and printed over the "in" of the
		# node beside it, which the matrix caught as "oiuln". Clamped here rather than at
		# the drawing, so the fit test refuses the same text the renderer would.
		var owner := label.get_parent()
		while owner != null and not (owner is GraphNode):
			owner = owner.get_parent()
		if owner is GraphNode:
			var body := (owner as GraphNode).get_global_rect()
			left = maxf(left, body.position.x + 2.0)
			right = minf(right, body.end.x - 2.0)
		return Vector2(left, maxf(right, left))

	static func room_for(label: Label) -> float:
		var slot := slot_for(label)
		return slot.y - slot.x

	## Which end of its slot the text should hold on to.
	##
	## Read from where the label *sits*, not from its horizontal_alignment. That property
	## describes text inside the label's own box, and a port label's box is shrink-wrapped
	## to the text — so an output label pushed to the right end of its container still
	## reports LEFT, and the first version of this grew it rightward into the container
	## edge it was already touching. Eleven port labels came out with no room at all and
	## were silently dropped: every "out", and every port on the keyboard node.
	static func anchored_right(label: Label) -> bool:
		var slot := slot_for(label)
		var rect := label.get_global_rect()
		return (rect.position.x - slot.x) > (slot.y - rect.end.x)

	## What the reader receives, in real pixels — 0 when the label is not reaching them
	## at all. The tests' unit of measurement.
	static func screen_size(label: Label, zoom: float) -> float:
		if not label.is_visible_in_tree():
			return 0.0
		match fit_for(label, zoom):
			Fit.IN_PLACE:
				return float(label.get_theme_font_size("font_size")) * zoom
			Fit.COMPENSATED:
				return float(Design.screen_minimum(int(label.get_meta("screen_min", Design.TYPE_FLOOR))))
			_:
				return 0.0

	## Every marked label inside the node, at its own screen rect.
	##
	## The rect comes from the label itself, so the node's layout keeps deciding where
	## words go and this only decides how big they are. A label whose own box has become
	## too narrow to hold its text at the minimum says nothing rather than saying it over
	## the top of its neighbour: overlapping words are worse than a band that has run out
	## of room, and running out is what the next band down is for.
	## A parameter row is one thing, so it is allocated as one thing.
	##
	## Drawn independently, the name and the value competed for the same row: the value's
	## box expands to fill what the hidden slider left, so the name was pushed back to its
	## own 96px and "resonance" at its minimum no longer fitted — the label vanished and
	## its number stayed, which is the orphan this whole exercise is against. Here the row
	## is split once: name against the left edge, value against the right, both at their
	## own minimum. If the two genuinely cannot both fit, the *value* goes, because a name
	## with no number still says what the node has and a number with no name says nothing.
	func _draw_pairs(node: GraphNode, handled: Dictionary) -> void:
		# A line, then the cells on it. This drew one pair per row because a row *was*
		# one parameter; a row holds two now, and reading the row's own metas would
		# have stretched the first cell's name across the whole line and dropped the
		# second parameter's words entirely.
		var cells: Array[Control] = []
		for child in node.get_children():
			var line := child as Control
			if line == null or str(line.get_meta("row", "")) != "module" \
					or not line.is_visible_in_tree():
				continue
			var box: Control = line.get_meta("cells_box") \
				if line.has_meta("cells_box") else null
			if box == null or not box.is_visible_in_tree():
				continue
			for cell_child in box.get_children():
				var cell := cell_child as Control
				if cell != null and cell.is_visible_in_tree():
					cells.append(cell)
		for row in cells:
			var name_label: Label = row.get_meta("name_label") \
				if row.has_meta("name_label") else null
			if name_label == null or not name_label.is_visible_in_tree():
				continue
			var value: Label = null
			for label in _marked(row):
				if str(label.get_meta("screen_kind", "")) == "value" \
						and label.is_visible_in_tree():
					value = label
			# Only when the row is being compensated at all; at full detail the real
			# controls are on screen and must not be drawn over.
			if fit_for(name_label, graph.zoom) == Fit.IN_PLACE \
					and (value == null or fit_for(value, graph.zoom) == Fit.IN_PLACE):
				continue

			var rect := row.get_global_rect()
			var pad: float = 6.0 * graph.zoom
			var span := rect.size.x - pad * 2.0
			var left := rect.position.x + pad - global_position.x
			var top := rect.position.y - global_position.y

			var name_size: int = Design.screen_minimum(int(name_label.get_meta("screen_min", Design.TYPE_FLOOR)))
			var name_font := name_label.get_theme_font("font")
			var name_width := name_font.get_string_size(name_label.text,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, name_size).x
			if name_width > span:
				continue    # nothing fits; the generic pass will hide it honestly
			handled[name_label] = true
			name_label.self_modulate.a = 0.0
			draw_string(name_font, Vector2(left,
				top + (rect.size.y + name_font.get_ascent(name_size)
					- name_font.get_descent(name_size)) * 0.5),
				name_label.text, HORIZONTAL_ALIGNMENT_LEFT, span, name_size,
				name_label.get_theme_color("font_color"))

			if value == null:
				continue
			handled[value] = true
			value.self_modulate.a = 0.0
			var value_size: int = Design.screen_minimum(int(value.get_meta("screen_min", Design.TYPE_FLOOR)))
			var value_font := value.get_theme_font("font")
			var value_width := value_font.get_string_size(value.text,
				HORIZONTAL_ALIGNMENT_RIGHT, -1.0, value_size).x
			# A gap the eye can see, so the pair reads as label-then-value rather than
			# as one run-together word: "frequency110.0 Hz" was the first attempt.
			var shown := value.text
			if name_width + value_width + 12.0 > span:
				# The unit goes before the number does. That is the decluttering order —
				# a redundant unit outranks nothing, a value outranks it — and it is the
				# difference between "transpose 0.000" and a label sitting on its own
				# with its number thrown away, which is the orphan this is against.
				var cut := shown.rfind(" ")
				if cut <= 0:
					continue
				shown = shown.substr(0, cut)
				value_width = value_font.get_string_size(shown,
					HORIZONTAL_ALIGNMENT_RIGHT, -1.0, value_size).x
				if name_width + value_width + 12.0 > span:
					continue
			draw_string(value_font, Vector2(left,
				top + (rect.size.y + value_font.get_ascent(value_size)
					- value_font.get_descent(value_size)) * 0.5),
				shown, HORIZONTAL_ALIGNMENT_RIGHT, span, value_size,
				value.get_theme_color("font_color"))

	func _draw_labels(node: GraphNode) -> void:
		var handled := {}
		_draw_pairs(node, handled)
		for label in _marked(node):
			if not label.is_visible_in_tree() or handled.has(label):
				continue
			var how := fit_for(label, graph.zoom)
			label.self_modulate.a = 1.0 if how == Fit.IN_PLACE else 0.0
			if how != Fit.COMPENSATED:
				continue

			var minimum: int = Design.screen_minimum(int(label.get_meta("screen_min", Design.TYPE_FLOOR)))
			var font := label.get_theme_font("font")
			var rect := label.get_global_rect()
			var slot := slot_for(label)
			var align := HORIZONTAL_ALIGNMENT_RIGHT if anchored_right(label) \
				else HORIZONTAL_ALIGNMENT_LEFT
			var local := Vector2(slot.x, rect.position.y) - global_position
			var baseline := local + Vector2(0.0,
				(rect.size.y + font.get_ascent(minimum) - font.get_descent(minimum)) * 0.5)
			draw_string(font, baseline, label.text, align, slot.y - slot.x,
				minimum, label.get_theme_color("font_color"))

	static func _marked(from: Node, into: Array[Label] = []) -> Array[Label]:
		for child in from.get_children():
			var label := child as Label
			if label != null and label.has_meta("screen_min"):
				into.append(label)
			if child.get_child_count() > 0:
				_marked(child, into)
		return into
