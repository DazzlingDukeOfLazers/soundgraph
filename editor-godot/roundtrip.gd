extends SceneTree
## Headless round trip through the real editor code.
##
##   godot --headless --script res://roundtrip.gd -- <input.json> <output.json>
##
## Loads a patch exactly the way the editor does — building the graph view, generating
## parameter widgets from the registry, then reading it all back — and writes the result.
## Driving the actual editor path is the point: a round trip that bypassed the widgets
## would prove nothing about the editor, only about JSON.

func _initialize() -> void:
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() < 2:
		push_error("usage: --script res://roundtrip.gd -- <input.json> <output.json>")
		quit(2)
		return

	var input_path: String = arguments[0]
	var output_path: String = arguments[1]

	var input := FileAccess.open(input_path, FileAccess.READ)
	if input == null:
		push_error("could not open %s" % input_path)
		quit(1)
		return
	var text := input.get_as_text()

	# Left untyped on purpose: this reaches into the editor's own members, which a Node
	# annotation would make a static type error.
	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame

	if main.engine == null:
		push_error("the SoundGraphEngine extension did not load")
		quit(1)
		return

	await main._load_text(text)
	# The view builds over a couple of frames; let it settle before reading it back.
	await process_frame
	await process_frame

	main._capture_positions()

	var validation: Variant = JSON.parse_string(
		main.engine.validate_patch(JSON.stringify(main.patch, "  ")))
	if typeof(validation) != TYPE_DICTIONARY or not validation["ok"]:
		push_error("the round-tripped patch does not validate: %s" %
			main.engine.validate_patch(JSON.stringify(main.patch, "  ")))
		quit(1)
		return

	var output := FileAccess.open(output_path, FileAccess.WRITE)
	if output == null:
		push_error("could not write %s" % output_path)
		quit(1)
		return
	output.store_string(main.engine.format_patch(JSON.stringify(main.patch, "  ")))
	output.close()

	print("round tripped %s -> %s (%d nodes, %d connections)" % [
		input_path.get_file(), output_path.get_file(),
		main.patch["nodes"].size(), main.patch["connections"].size()])

	# Torn down deliberately, before quitting.
	#
	# quit() only schedules an exit, so the editor was being dismantled during
	# interpreter shutdown in an order nothing here controls — with an audio player
	# still holding a generator playback and the graph still holding GDExtension
	# objects. That is the 0xC0000005 this check has been failing with about one run in
	# five: a crash *after* the work succeeded, which reads exactly like a refusal to
	# round trip the patch and is nothing of the sort.
	# Audio first, then frames, then the node.
	#
	# AudioServer mixes on its own thread and holds the generator playback the editor
	# fills every frame. Freeing the editor in one go destroys the GDExtension engine
	# with no gap at all, and if that thread is mid-mix the process dies after the work
	# has already succeeded. The frames are the gap.
	main.shutdown_audio()
	await process_frame
	await process_frame
	root.remove_child(main)
	main.free()
	await process_frame
	quit(0)
