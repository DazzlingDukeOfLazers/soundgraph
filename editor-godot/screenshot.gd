extends SceneTree
## Renders the editor to a PNG so somebody — or something — can look at it.
##
##   godot --path editor-godot --script res://screenshot.gd -- <out.png> [width] [height]
##
## Not --headless: headless has no rendering server, so there is nothing to capture. This
## opens a real window, draws a few frames, grabs the viewport and quits. It is the whole
## difference between "the dock measures 54px collapsed" and "the dock looks right", and
## the design work in this project had been running on the first kind of evidence only.
##
## A window does appear briefly. That is the point of it.

const SETTLE_FRAMES := 12


func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	var output: String = arguments[0] if arguments.size() > 0 else "screenshot.png"
	var width: int = int(arguments[1]) if arguments.size() > 1 else 1600
	var height: int = int(arguments[2]) if arguments.size() > 2 else 1000

	DisplayServer.window_set_size(Vector2i(width, height))
	root.content_scale_size = Vector2i(width, height)

	var main = load("res://main.tscn").instantiate()
	root.add_child(main)

	# A fourth argument selects a node first, so the contextual half of the inspector
	# can be looked at as well as the resting state. Without this the only view anybody
	# ever renders is the one with nothing selected, which is the view least likely to
	# be wrong.
	var select: String = arguments[3] if arguments.size() > 3 else ""

	# A sixth argument picks a palette, so the themes can be looked at rather than
	# taken on the word of a contrast table.
	if arguments.size() > 5:
		main._use_palette(int(arguments[5]))
		for i in 4:
			await process_frame

	# Several frames, not one. The first frame has no layout: containers size themselves
	# during it, the graph nodes have not been placed, and a shot taken then shows a pile
	# of controls at the origin — which looks exactly like a broken redesign.
	for i in SETTLE_FRAMES:
		await process_frame

	# A seventh argument switches to a tab by name. After the settle loop, because
	# before it there is no tab container to switch — the first attempt ran here on
	# frame zero and found `views` still null.
	# A ninth argument sets the UI scale, so the presets can be compared side by side.
	if arguments.size() > 8 and arguments[8] != "":
		main._use_ui_scale(int(arguments[8]))
		for i in 6:
			await process_frame

	# An eighth argument sets the rack density.
	if arguments.size() > 7 and arguments[7] != "":
		Rack.density = int(arguments[7])
		main.rack.rebuild()
		for i in 4:
			await process_frame

	if arguments.size() > 6 and arguments[6] != "":
		for index in main.views.get_tab_count():
			if main.views.get_tab_title(index).to_lower() == arguments[6].to_lower():
				main.views.current_tab = index
		for i in 10:
			await process_frame

	# A fifth argument holds a note down and pumps the graph, so the signal glow has
	# something to show. A screenshot of a silent instrument cannot tell you whether
	# the "this is running" cue works.
	if arguments.size() > 4 and arguments[4] == "play":
		main.engine.note_on(57, 0.9)
		for i in 90:
			main._update_port_levels(0.05)
			await process_frame

	if select != "":
		await process_frame
		main._focus_node(select)
		for i in 6:
			await process_frame

	# A tenth argument selects a rack module, so the cable dimming can be looked at, or
	# "cable:N" to put the pointer on one — the highlight is drawn rather than computed,
	# so the only way to know it looks like anything is to look at it.
	if arguments.size() > 9 and arguments[9] != "":
		if arguments[9].begins_with("cable:"):
			main.rack.hovered_cable = int(arguments[9].split(":")[1])
			main.rack._cables.queue_redraw()
		else:
			main.rack.select(arguments[9])
		for i in 4:
			await process_frame

	var image := root.get_texture().get_image()
	var status := image.save_png(output)
	if status == OK:
		print("wrote %s (%dx%d)" % [output, image.get_width(), image.get_height()])
	else:
		printerr("could not write %s (error %d)" % [output, status])
	quit(0 if status == OK else 1)
