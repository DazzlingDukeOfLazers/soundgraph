extends RefCounted

## How a headless harness puts the editor down before it leaves.
##
## The push gate had been printing a segmentation fault roughly one suite in ten — always
## *after* that suite had printed "all checks passed", and never in the same place twice, so
## it read as a flake. It is not a flake, and `main.gd` had already worked out why:
##
## > AudioServer mixes on its own thread and holds a reference to the generator playback the
## > editor fills every frame. Destroy the GDExtension engine while that thread is mid-mix
## > and the process dies with 0xC0000005 after all the work has finished.
##
## `shutdown_audio()` exists to close that window and is public precisely so a caller that
## can await will call it and let a couple of frames pass. `roundtrip.gd` and `editor_test.gd`
## did. Thirty-eight other harnesses did not — they instantiated `main.tscn`, did their work,
## and called `quit()` straight into the race.
##
## So this is not a new mechanism, it is the existing one applied everywhere, in one place
## rather than thirty-eight copies. A harness ends with:
##
##     await HarnessExit.finish(self, main)
##
## and gets the frames for free.
##
## Measured on `legalize_test` before and after, twelve runs each, because "the same fault
## in a different place every time" is exactly the shape of thing that looks fixed when it
## is only rarer.


## Set HARNESS_EXIT_TRACE=1 to print each step of the teardown.
##
## How the remaining crash was located, and worth keeping for the next person: with the
## trace on, `editor_test` prints "[exit] quit returned" on the runs that segfault. Every
## GDScript statement completes. Whatever is left is in Godot's own shutdown, not here.
static var _trace := OS.get_environment("HARNESS_EXIT_TRACE") != ""


## Shuts the editor's audio down, gives the mixer a gap, frees the editor, then quits.
##
## Safe to call with a null or already-freed editor: a harness that failed early still has
## to be able to leave.


static func finish(tree: SceneTree, main: Node, code: int = 0) -> void:
	if main != null and is_instance_valid(main) and main.has_method("shutdown_audio"):
		# Audio first, then frames, then the node. The frames are the gap — without them
		# stopping the player and destroying the engine happen with nothing in between,
		# which is the whole of the race.
		if _trace: print("[exit] shutdown_audio")
		main.shutdown_audio()
		await tree.process_frame
		await tree.process_frame
		if _trace: print("[exit] remove_child")
		if main.get_parent() != null:
			main.get_parent().remove_child(main)
		if _trace: print("[exit] free")
		main.free()
		if _trace: print("[exit] freed, one more frame")
		await tree.process_frame
	if _trace: print("[exit] quit")
	tree.quit(code)
	if _trace: print("[exit] quit returned")
