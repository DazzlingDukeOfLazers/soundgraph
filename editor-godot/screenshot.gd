extends SceneTree

const ModuleThemes := preload("res://module_themes.gd")
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
## Every field is applied every time rather than only when it differs from the last shot,
## and a field the spec leaves out gets its default rather than its predecessor. A matrix
## that carried state between entries would make each picture depend on the one before it,
## which is exactly the property that makes a regression set untrustworthy — the shot you
## are looking at has to be the shot the spec asked for.
##
## This was written as a promise before it was true of the code; see the view and the held
## notes below, both of which leaked for as long as this comment has been here.
func _stage(main, shot: Dictionary) -> void:
	main._use_palette(int(shot.get("palette", 0)))
	main._use_ui_scale(int(shot.get("ui_scale", 1)))
	for i in 4:
		await process_frame

	# Explicitly, rather than trusting the reload to do it. The note held down for the
	# "note held" shot was still held three shots later — the accent key is lit in the
	# two DX7 pictures — because nothing ever let go of it, and a picture of a patch
	# with a stuck key is not a picture of that patch.
	main._all_notes_off()

	await main._load_example(str(shot.get("example", "First Synth")))
	for i in 8:
		await process_frame

	# The faceplate theme, applied after the load because loading brings the document's
	# own with it. Set every time rather than only when asked for, like everything else
	# here: a shot that inherited the previous one's paint would be a picture of the
	# wrong thing, which is the mistake this file has already made twice.
	main._set_patch_theme(str(shot.get("theme", ModuleThemes.CATEGORY)))
	for i in 4:
		await process_frame

	# Graph when the spec does not say, never "whatever the last shot left".
	#
	# This read `shot.get("view", "")` and skipped the switch when it was empty, which is
	# the one behaviour the note above says this function does not have: shots 22 to 27
	# inherited the Outline tab from shot 21 and were six photographs of a text listing.
	# Two of them are the large-patch pair, whose entire question is how a fifteen-node
	# DX7 patch lays out at 100% and 63% — asked, rendered, filed, and never answered.
	# Two vocabularies, and the miss was silent. "View" here can mean a lens — Rack,
	# Graph, Schematic, Face — or a tab of `main.views`, which are Patch, Sandbox and
	# Outline. The canonical shots asked for lenses, this loop only knew tabs, nothing
	# matched, and rack.png and schematic.png shipped as two identical photographs of the
	# Graph — found by the web funnel putting them side by side on a page, not by anything
	# here. A name that matches neither vocabulary is now an error instead of a shrug.
	var view := str(shot.get("view", "Graph"))
	var lenses := {"rack": main.PatchView.RACK, "graph": main.PatchView.GRAPH,
		"schematic": main.PatchView.SCHEMATIC, "face": main.PatchView.FACE}
	var named := false
	if lenses.has(view.to_lower()):
		main._set_patch_view(int(lenses[view.to_lower()]))
		named = true
	for index in main.views.get_tab_count():
		if main.views.get_tab_title(index).to_lower() == view.to_lower():
			main.views.current_tab = index
			named = true
	if not named:
		printerr("no lens or tab called '%s'" % view)
	for i in 8:
		await process_frame

	# `fit` frames the whole patch, which is what almost every review shot wants and what
	# none of them could ask for. Without it a shot inherits whatever scroll the load left,
	# and the canonical Graph picture came out showing two nodes and a corner of a third.
	if bool(shot.get("fit", false)):
		main._fit_view_zoom()
		await main.get_tree().process_frame
		await main.get_tree().process_frame

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

	# The cable pass's whole result in one frame: a focused route at its ordinary resting
	# appearance and everything else mixed toward the canvas. There was no way to ask for it
	# from a spec, so the only pictures of it were taken by its own proof sheets and are
	# about the measurement rather than about the product.
	#
	# `lock` names an output port as `<widget>:right:<index>`; the family leaving it stays
	# lit and everything else is mixed toward the canvas.
	#
	# Both fields are set. `lock_focus_on_port` is the persistent half and `focus_port` is
	# what the cord layer reads when it decides which cords are quieted — setting only the
	# first produced a picture with no suppression in it at all, which is a picture of the
	# ordinary graph wearing the caption of the golden moment.
	if str(shot.get("lock", "")) != "":
		main.graph_edit.clear_focus_lock()
		main.graph_edit.lock_focus_on_port(str(shot["lock"]))
		main.graph_edit.focus_port = str(shot["lock"])
		main.graph_edit.queue_redraw()
		await main.get_tree().process_frame
		await main.get_tree().process_frame
	else:
		main.graph_edit.clear_focus_lock()
		main.graph_edit.focus_port = ""

	if str(shot.get("select", "")) != "":
		main._focus_node(str(shot["select"]))
		for i in 6:
			await process_frame

	# `probe` points the scope at an output port, "<node>:<port>", through the panel's own
	# picker — the same path a hand takes, so the labels and the frozen state behave. Pair
	# it with `play` in the same shot: the scope draws the engine's own ring, and a silent
	# engine is a flat trace wearing the caption of a waveform.
	if str(shot.get("probe", "")) != "":
		var half := str(shot["probe"]).split(":")
		var found := false
		for index in main.scope_probe._sources.size():
			var entry: Dictionary = main.scope_probe._sources[index]
			if str(entry["node"]) == half[0] and str(entry["port"]) == half[1]:
				main.scope_probe.source_pick.selected = index + 1
				main.scope_probe._on_source_picked(index + 1)
				found = true
				break
		if not found:
			printerr("no probe wire called '%s'" % str(shot["probe"]))
		for i in 4:
			await process_frame
	else:
		main.scope_probe.source_pick.selected = 0
		main.scope_probe._on_source_picked(0)

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
