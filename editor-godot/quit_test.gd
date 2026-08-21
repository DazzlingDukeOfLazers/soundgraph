extends SceneTree
## The exit path, alone: boot the editor, let audio run a moment, tear down the way
## editor_test does, quit. Exists to chase the crash that happens after the verdict —
## a fault inside Godot's audio thread during shutdown, which no check can see because
## every check has already passed. Run it in a loop and count Windows Error Reporting
## events; the suite itself cannot testify about its own death.

func _initialize() -> void:
	var main_scene: PackedScene = load("res://main.tscn")
	var main: Node = main_scene.instantiate()
	root.add_child(main)
	await process_frame
	for i in 30:
		await process_frame
	# The full suite's differentiator: eight game-sound voices, each an engine and a
	# playing generator, loaded moments before the teardown they then have to survive.
	if main.sandbox != null:
		main.sandbox.ensure_sounds_loaded()
		for i in 10:
			await process_frame
		if main.sandbox.sounds != null and main.sandbox.sounds.has_sound("jump"):
			main.sandbox.sounds.play("jump")
		for i in 10:
			await process_frame
	if main.has_method("shutdown_audio"):
		main.shutdown_audio()
	await process_frame
	await process_frame
	root.remove_child(main)
	main.free()
	await process_frame
	print("quit test reached the end")
	quit(0)
