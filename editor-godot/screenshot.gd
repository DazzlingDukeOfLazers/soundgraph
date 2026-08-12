extends SceneTree
## Renders the editor to a PNG so somebody — or something — can look at it.
##
##   godot --path editor-godot --script res://screenshot.gd -- <out.png> [width] [height]
##   godot --path editor-godot --script res://screenshot.gd -- --matrix <spec.json>
##
## Not --headless: headless has no rendering server, so there is nothing to capture. This
## opens a real window, draws a few frames, grabs the viewport and quits. It is the whole
## difference between "the dock measures 54px collapsed" and "the dock looks right", and
## the design work in this project had been running on the first kind of evidence only.
##
## A window does appear briefly. That is the point of it.
##
## Matrix mode exists because the review question is never "does it look right at 100%".
## It is "does it look right across the zooms, the UI scales, the themes and the views" —
## and answered one process at a time that is twenty-five Godot launches and four minutes
## of somebody's attention, which means in practice it is answered at 100% only. One
## process, one pass, a directory of labelled shots: see tools/screenshot-matrix.mjs.

const SETTLE_FRAMES := 12


## Applies one shot's worth of state and returns when the frame is worth grabbing.
##
## Every field is applied every time rather than only when it differs from the last shot.
## A matrix that carried state between entries would make each picture depend on the one
## before it, which is exactly the property that makes a regression set untrustworthy —
## the shot you are looking at has to be the shot the spec asked for.
func _stage(main, shot: Dictionary) -> void:
	main._use_palette(int(shot.get("palette", 0)))
	main._use_ui_scale(int(shot.get("ui_scale", 1)))
	for i in 4:
		await process_frame

	# The example reload also clears the selection and the held notes, so each shot
	# starts from the same place whatever the one before it did.
	await main._load_example(str(shot.get("example", "First Synth")))
	for i in 8:
		await process_frame

	var view := str(shot.get("view", ""))
	if view != "":
		for index in main.views.get_tab_count():
			if main.views.get_tab_title(index).to_lower() == view.to_lower():
				main.views.current_tab = index
		for i in 8:
			await process_frame

	if shot.get("zoom", 0.0) > 0.0:
		# Set from full detail so the level of detail is reached the same way every time,
		# rather than depending on where the fit-on-load happened to leave the zoom.
		main.graph_edit.zoom = 1.0
		main.graph_edit._update_detail()
		main.graph_edit.zoom = float(shot["zoom"])
		main.graph_edit._update_detail()
		main._apply_detail(main.graph_edit.detail)
		for i in 6:
			await process_frame

	if str(shot.get("select", "")) != "":
		main._focus_node(str(shot["select"]))
		for i in 6:
			await process_frame

	if bool(shot.get("play", false)):
		main._hold_note(57)
		for i in 40:
			main._update_port_levels(0.05)
			await process_frame


func _capture(path: String) -> bool:
	var image := root.get_texture().get_image()
	var status := image.save_png(path)
	if status != OK:
		printerr("could not write %s (error %d)" % [path, status])
	return status == OK


func _run_matrix(spec_path: String) -> void:
	var file := FileAccess.open(spec_path, FileAccess.READ)
	if file == null:
		printerr("could not read %s" % spec_path)
		quit(1)
		return
	var spec: Variant = JSON.parse_string(file.get_as_text())
	if not (spec is Dictionary):
		printerr("%s is not a matrix spec" % spec_path)
		quit(1)
		return

	var size: Vector2i = Vector2i(int(spec.get("width", 1600)), int(spec.get("height", 1000)))
	DisplayServer.window_set_size(size)
	root.content_scale_size = size

	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	for i in SETTLE_FRAMES:
		await process_frame

	var written := 0
	for entry in spec.get("shots", []):
		var shot: Dictionary = entry
		await _stage(main, shot)
		if _capture(str(shot["path"])):
			written += 1
			print("  %s" % str(shot["name"]))
	print("%d of %d shots written" % [written, spec.get("shots", []).size()])
	quit(0 if written == spec.get("shots", []).size() else 1)


func _initialize() -> void:
	# From the defaults, not from whoever is running this. A review shot taken at the
	# reviewer's own UI scale is not a shot of the product, and two people comparing the
	# same numbered file are comparing two different pictures — the shots above were
	# rendered at somebody's XL preference without saying so anywhere on them. Arguments
	# still set the scale explicitly; that is the point of having them.
	Settings.isolate()
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() > 1 and arguments[0] == "--matrix":
		await _run_matrix(arguments[1])
		return
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
		# Through the editor's own note path rather than straight at the engine, so the
		# keyboard lights up too. Poking the engine alone left every key unlit, which
		# made "play" useless for photographing the one state the piano exists to show —
		# and I nearly signed off a held-key redesign on a screenshot with nothing held.
		main._hold_note(57)
		for i in 90:
			main._update_port_levels(0.05)
			await process_frame

	if select != "":
		await process_frame
		main._focus_node(select)
		for i in 6:
			await process_frame

	# An eleventh argument loads an example by its menu label first — "DX7: algo-01" —
	# because the layout questions worth photographing are patch-dependent.
	if arguments.size() > 10 and arguments[10] != "":
		await main._load_example(arguments[10])
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

	# A twelfth argument sets the graph zoom, because the level-of-detail work is the one
	# part of this editor whose whole subject is what a node looks like at a given zoom,
	# and until now there was no way to photograph that — the measurements said 14.0px
	# and only a picture says whether the result reads as an instrument.
	if arguments.size() > 11 and arguments[11] != "":
		main.graph_edit.zoom = float(arguments[11])
		main.graph_edit._update_detail()
		main._apply_detail(main.graph_edit.detail)
		for i in 8:
			await process_frame

	var image := root.get_texture().get_image()
	var status := image.save_png(output)
	if status == OK:
		print("wrote %s (%dx%d)" % [output, image.get_width(), image.get_height()])
	else:
		printerr("could not write %s (error %d)" % [output, status])
	quit(0 if status == OK else 1)
