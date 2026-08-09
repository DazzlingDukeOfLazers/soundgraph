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

	# Several frames, not one. The first frame has no layout: containers size themselves
	# during it, the graph nodes have not been placed, and a shot taken then shows a pile
	# of controls at the origin — which looks exactly like a broken redesign.
	for i in SETTLE_FRAMES:
		await process_frame

	var image := root.get_texture().get_image()
	var status := image.save_png(output)
	if status == OK:
		print("wrote %s (%dx%d)" % [output, image.get_width(), image.get_height()])
	else:
		printerr("could not write %s (error %d)" % [output, status])
	quit(0 if status == OK else 1)
