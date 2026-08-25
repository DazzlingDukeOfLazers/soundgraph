# A window lent to somebody else's plugin.
#
# The whole of this file is a frame and a handle. Godot makes a real operating-system
# window; DisplayServer says what its native handle is; the extension passes that handle
# down through dsp-core — which never looks at it — to the loader, which knows it is an
# HWND on Windows and an NSView on macOS and hands it to the plugin. The plugin then
# draws itself, corner to corner, and this node's only remaining jobs are to be the right
# size, to give the plugin the main thread every frame, and to tell it when the window is
# going away.
#
# Nothing here is drawn by us on purpose. The plugin's own child window sits on top of
# whatever this Window renders, so anything we put behind it would only be visible in the
# gap between opening and the first paint.
#
# Why a window of its own rather than a panel inside the editor: a plugin fills what it
# is handed. Given the main window's handle it would cover the whole editor, and there is
# no portable way to ask it to occupy a rectangle instead. One window per plugin is also
# what every DAW does, so it is what the muscle memory expects.
#
# See docs/hosted-plugins-design.md.
extends Window


var _engine
var _node_id := ""
var _open := false

# Signals failure back to whoever opened the window, since attaching happens a frame
# later and cannot simply return false.
signal attach_failed(reason: String)


## Prepares the window for a node's plugin. Call before adding it to the tree.
##
## The starting size is a guess that is almost always wrong; the right one is only
## knowable once the plugin's editor exists, so the window resizes itself the moment it
## has an answer. A plugin that will not say keeps the guess.
func setup(engine_ref, node_id: String, plugin_name: String) -> void:
	_engine = engine_ref
	_node_id = node_id
	title = plugin_name if plugin_name != "" else node_id
	size = Vector2i(900, 620)
	min_size = Vector2i(240, 160)
	close_requested.connect(_close)


func _ready() -> void:
	set_process(false)
	# The native handle does not exist until the operating system window does, and it
	# does not exist until after this frame. Asking too early returns zero, which reads
	# exactly like a plugin refusing to open.
	await get_tree().process_frame
	_attach()


func _attach() -> void:
	if _engine == null or not is_instance_valid(self):
		return
	# An embedded subwindow is drawn inside the main viewport and has no window of its
	# own to lend. Standalone Godot does not embed by default, so this is a guard rather
	# than a case — but "the handle was zero" is a bad way to find it out.
	if is_embedded():
		attach_failed.emit("Godot is drawing its own subwindows, so there is no "
			+ "operating-system window to lend the plugin.")
		queue_free()
		return

	var handle := DisplayServer.window_get_native_handle(
		DisplayServer.WINDOW_HANDLE, get_window_id())
	if handle == 0:
		attach_failed.emit("This platform did not give the window a native handle.")
		queue_free()
		return

	if not _engine.open_plugin_gui(_node_id, handle):
		attach_failed.emit("The plugin declined to open its panel here.")
		queue_free()
		return

	_open = true
	# The size the plugin asks for, clamped to what the screen can hold. Plugins are
	# DPI-aware and ask in real pixels — Surge XT wants 2282x1422 on a 200% display —
	# which is fine until it is not: a window larger than the screen is one whose title
	# bar cannot be reached, so it cannot be moved or closed. Cropping the plugin's
	# panel is the lesser harm, and the window can be resized afterwards.
	var wanted: Vector2i = _engine.plugin_gui_size(_node_id)
	if wanted.x > 0 and wanted.y > 0:
		var room := DisplayServer.screen_get_usable_rect().size
		size = Vector2i(mini(wanted.x, room.x), mini(wanted.y, room.y))
	set_process(true)


func _process(_delta: float) -> void:
	# The plugin's main thread, once a frame. Without it a clicked knob moves and the
	# sound does not follow: both formats let a plugin defer work to the host's main
	# thread and then wait for it, and a host that never offers one leaves that work
	# undone for as long as the editor is open.
	if _open and _engine != null:
		_engine.tick_plugins()


func _close() -> void:
	if _open and _engine != null:
		_engine.close_plugin_gui(_node_id)
	_open = false
	set_process(false)
	queue_free()


# The other way out: the editor tearing down, a patch reloading, the whole scene going.
# Freed without close_requested, the plugin would still be drawing into a window that no
# longer exists, which is a crash with nothing of ours on the stack.
func _exit_tree() -> void:
	if _open and _engine != null:
		_engine.close_plugin_gui(_node_id)
	_open = false
