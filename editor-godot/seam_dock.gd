extends RefCounted
## The patch's own edges, on the instrument rather than on the canvas.
##
## A seam bound to a host is where the graph meets the machine — the keyboard, the
## speakers. Drawn as a node in the middle of the graph it was a node like any other, and
## it is not: you cannot move it somewhere else, there is only ever one of it, and what is
## on the far side of it is not in the file at all. So it goes where the machine is. The
## keyboard's jacks sit on the keyboard, the output's beside it, and the cables run from
## there up into the patch.
##
## The cables are the reason this is not simply a layout change. GraphEdit draws
## connections between its own children and nothing else, so a cable from the dock into the
## graph has nobody to draw it. `Cables` below is that nobody: one Control over the whole
## window, computing both ends in viewport space, clipped to the graph's own rectangle so a
## cable cannot paint over the toolbar it passes behind.

## A row of sockets for one seam's ports, with their names under them.
class Jacks extends Control:
	const SOCKET := 7.0
	const LABEL_GAP := 4.0

	## {"node": id, "port": name, "type": signal type} per socket, in port order.
	var ports: Array = []
	var type_colours: Dictionary = {}
	var ink := Color.WHITE

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _font() -> Font:
		return Design.font(Design.WEIGHT_MEDIUM)

	func _size() -> int:
		return Design.type(Design.SIZE_SECONDARY)

	## Room for the widest name under each socket, so the row never crowds itself.
	func _get_minimum_size() -> Vector2:
		if ports.is_empty():
			return Vector2.ZERO
		var font := _font()
		var size := _size()
		var width := 0.0
		var tallest := 0.0
		for port: Dictionary in ports:
			var measured := font.get_string_size(str(port["port"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, size)
			width += maxf(measured.x, Design.scale(SOCKET) * 2.0) \
				+ Design.scale(Design.SPACE_M)
			tallest = maxf(tallest, measured.y)
		return Vector2(width, Design.scale(SOCKET) * 2.0
			+ Design.scale(LABEL_GAP) + tallest)

	## Where one socket sits, in this control's own coordinates.
	func _slot(index: int) -> Vector2:
		var font := _font()
		var size := _size()
		var x := 0.0
		for i in ports.size():
			var measured := font.get_string_size(str(ports[i]["port"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, size)
			var cell: float = maxf(measured.x, Design.scale(SOCKET) * 2.0)
			if i == index:
				return Vector2(x + cell * 0.5, Design.scale(SOCKET))
			x += cell + Design.scale(Design.SPACE_M)
		return Vector2.ZERO

	## The same point in viewport space, which is what draws a cable to it.
	func socket_centre(port_name: String) -> Variant:
		for i in ports.size():
			if str(ports[i]["port"]) == port_name:
				return get_global_transform() * _slot(i)
		return null

	func _draw() -> void:
		var font := _font()
		var size := _size()
		for i in ports.size():
			var at := _slot(i)
			var colour: Color = type_colours.get(str(ports[i].get("type", "")), ink)
			# A ring and a dark centre, the same socket the rack draws, so a jack looks
			# like a jack wherever it turns up.
			draw_circle(at, Design.scale(SOCKET), Color(0.055, 0.06, 0.07))
			draw_arc(at, Design.scale(SOCKET), 0.0, TAU, 24, colour, 2.0, true)
			var text := str(ports[i]["port"])
			var measured := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size)
			draw_string(font, Vector2(at.x - measured.x * 0.5,
				at.y + Design.scale(SOCKET) + Design.scale(LABEL_GAP)
					+ measured.y * 0.8),
				text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, ink)


## The cables between the dock's sockets and the graph.
##
## Over the whole window, because that is the only place both ends exist at once. Clipped
## to the graph's rectangle: a cable leaving the keyboard passes behind the tab strip and
## the toolbar on its way to a node near the top, and a line drawn across those reads as a
## rendering fault rather than as a cable behind a panel.
class Cables extends Control:
	## Filled by the editor each frame it matters: [[from: Vector2, to: Vector2, Color]].
	var runs: Array = []
	## The rectangle cables are allowed inside, in viewport space.
	var window := Rect2()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		z_index = 90

	func _draw() -> void:
		if runs.is_empty() or window.size.x <= 0.0:
			return
		var inverse := get_global_transform().affine_inverse()
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# The clip is the graph's viewport, so the cable appears to run behind everything
		# else rather than over it.
		draw_rect(Rect2(inverse * window.position, window.size), Color(0, 0, 0, 0), false)
		for run: Array in runs:
			var a: Vector2 = inverse * (run[0] as Vector2)
			var b: Vector2 = inverse * (run[1] as Vector2)
			var colour: Color = run[2]
			var sag: float = clampf(absf(b.x - a.x) * 0.30, 46.0, 260.0)
			var points := GraphRack.catenary(a, b, sag)
			var clipped := _inside(points, Rect2(inverse * window.position, window.size))
			for run_points: PackedVector2Array in clipped:
				if run_points.size() < 2:
					continue
				draw_polyline(run_points, Color(0, 0, 0, 0.45), 7.0, true)
				draw_polyline(run_points, colour, 4.0, true)
			# The socket end is always drawn, clipped or not: it is on the dock, which is
			# where somebody is looking to see whether anything is plugged in at all.
			draw_circle(a, 5.0, colour)

	## The parts of a curve inside the rectangle, as separate runs. Cheap and per-point:
	## a cable is drawn from forty-odd samples, so a segment that straddles the edge loses
	## at most one of them and nobody can see which.
	func _inside(points: PackedVector2Array, box: Rect2) -> Array:
		var runs_out: Array = []
		var current := PackedVector2Array()
		for point in points:
			if box.has_point(point):
				current.append(point)
			elif current.size() > 0:
				runs_out.append(current)
				current = PackedVector2Array()
		if current.size() > 0:
			runs_out.append(current)
		return runs_out
