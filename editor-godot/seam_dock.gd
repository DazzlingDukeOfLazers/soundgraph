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
	## How far from a socket's centre still counts as grabbing it. Larger than the socket,
	## because the socket is drawn at the size a jack looks right at rather than the size a
	## mouse can reliably hit, and missing by two pixels should not mean nothing happened.
	const GRAB := 14.0

	## A device jack was picked up. The editor takes it from there: it owns the document,
	## and where this cable may land is a question about the patch, not about the dock.
	signal jack_grabbed(socket: Dictionary)

	## {"node": id, "port": name, "type": signal type} per socket, in port order. `node` is
	## "" for a device that is on the machine but plugged into nothing.
	var ports: Array = []
	var type_colours: Dictionary = {}
	var ink := Color.WHITE
	## The socket currently in the user's hand, drawn open so it is obvious which one left.
	var lifted := -1

	func _ready() -> void:
		# PASS rather than IGNORE: the jacks have to be grabbable now, and STOP would make
		# the whole row a wall the keyboard's own buttons sit behind.
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _gui_input(event: InputEvent) -> void:
		if not (event is InputEventMouseButton) or event.button_index != MOUSE_BUTTON_LEFT \
			or not event.pressed:
			return
		var at := (event as InputEventMouseButton).position
		for i in ports.size():
			if at.distance_to(_slot(i)) <= Design.scale(GRAB):
				lifted = i
				queue_redraw()
				jack_grabbed.emit(ports[i])
				accept_event()
				return

	## Called by the editor when the drag ends, whatever became of it.
	func release() -> void:
		if lifted < 0:
			return
		lifted = -1
		queue_redraw()

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
			var measured := font.get_string_size(str(port.get("label", port["port"])),
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
			var measured := font.get_string_size(str(ports[i].get("label", ports[i]["port"])),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, size)
			var cell: float = maxf(measured.x, Design.scale(SOCKET) * 2.0)
			if i == index:
				return Vector2(x + cell * 0.5, Design.scale(SOCKET))
			x += cell + Design.scale(Design.SPACE_M)
		return Vector2.ZERO

	## The same point in viewport space, which is what draws a cable to it. Matched on the
	## node as well as the port: every device jack is called "host", so the port name alone
	## would find whichever was listed first.
	func socket_centre(port_name: String, node_id: String) -> Variant:
		for i in ports.size():
			if str(ports[i]["port"]) == port_name and str(ports[i]["node"]) == node_id:
				return get_global_transform() * _slot(i)
		return null

	func _draw() -> void:
		var font := _font()
		var size := _size()
		for i in ports.size():
			var at := _slot(i)
			var colour: Color = type_colours.get(str(ports[i].get("type", "")), ink)
			# A device plugged into nothing, or one currently in the user's hand, is drawn
			# faint: the ring says the machine has this jack, and the colour says a live
			# signal is running through it. Those are different claims and look different.
			var live: bool = str(ports[i].get("node", "")) != "" and i != lifted
			# A ring and a dark centre, the same socket the rack draws, so a jack looks
			# like a jack wherever it turns up.
			draw_circle(at, Design.scale(SOCKET), Color(0.055, 0.06, 0.07))
			draw_arc(at, Design.scale(SOCKET), 0.0, TAU, 24,
				colour if live else Color(colour, 0.35), 2.0, true)
			var text := str(ports[i].get("label", ports[i]["port"]))
			var measured := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size)
			draw_string(font, Vector2(at.x - measured.x * 0.5,
				at.y + Design.scale(SOCKET) + Design.scale(LABEL_GAP)
					+ measured.y * 0.8),
				text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size,
				ink if live else Color(ink, 0.45))


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
	## The cable in the user's hand, if any: [from, to, Color], and unclipped. A cable
	## being dragged has to be visible everywhere the cursor can go, including over the
	## dock it came from — the clip exists to stop a *settled* cable painting over the
	## chrome, and there is no settled cable here yet.
	var live: Array = []

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		z_index = 90

	func _draw() -> void:
		var inverse := get_global_transform().affine_inverse()
		if not live.is_empty():
			var held_from: Vector2 = inverse * (live[0] as Vector2)
			var held_to: Vector2 = inverse * (live[1] as Vector2)
			var held: Color = live[2]
			var slack: float = clampf(absf(held_to.x - held_from.x) * 0.30, 46.0, 260.0)
			var curve := Rack.catenary(held_from, held_to, slack)
			draw_polyline(curve, Color(0, 0, 0, 0.45), 7.0, true)
			draw_polyline(curve, held, 4.0, true)
			draw_circle(held_from, 5.0, held)
			draw_circle(held_to, 5.0, held)
		if runs.is_empty() or window.size.x <= 0.0:
			return
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		# The clip is the graph's viewport, so the cable appears to run behind everything
		# else rather than over it.
		draw_rect(Rect2(inverse * window.position, window.size), Color(0, 0, 0, 0), false)
		for run: Array in runs:
			var a: Vector2 = inverse * (run[0] as Vector2)
			var b: Vector2 = inverse * (run[1] as Vector2)
			var colour: Color = run[2]
			var sag: float = clampf(absf(b.x - a.x) * 0.30, 46.0, 260.0)
			var points := Rack.catenary(a, b, sag)
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
