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
# True while this file is the one changing the window's size, so that the change it makes
# is not mistaken for the user dragging an edge. Without it the two directions of the
# conversation answer each other forever: the plugin rounds the size, the window takes the
# rounded one, the size_changed that follows offers it back, and around it goes.
var _resizing := false

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
	# A window that cannot usefully be dragged should not look as though it can. Most
	# editors are fixed; the ones that are not usually offer their own zoom menu too,
	# which is the other half of this and arrives through _process below.
	unresizable = not _engine.plugin_gui_can_resize(_node_id)
	if not unresizable:
		size_changed.connect(_offer_size_to_plugin)

	_fit_and_take(_engine.plugin_gui_size(_node_id))
	set_process(true)


## Takes a size the plugin asked for, fitted to a screen it did not consider.
##
## Plugins are DPI-aware and ask in real pixels: Surge XT's VST3 opens at 3312x2064 on a
## 4K display, which is very nearly the whole screen and, once a title bar is added, more
## than fits in the work area. Windows answers that by maximising the window, and a
## maximised window is full width — so the editor sat 3312 wide inside a 3840-wide frame
## with five hundred pixels of Godot showing beside it.
##
## The fix is not to clamp the window but to *ask the plugin to be smaller*. A plugin
## told the size it can have keeps its own proportions; a window merely cropped to fit
## shows a border of somebody else's background, which reads as a drawing bug. The room
## available is measured with the decorations included, because the title bar is the part
## that did not fit.
func _fit_and_take(wanted: Vector2i) -> void:
	if wanted.x <= 0 or wanted.y <= 0:
		return
	var overhead := DisplayServer.window_get_size_with_decorations(get_window_id()) - size
	var room := DisplayServer.screen_get_usable_rect().size - overhead
	var fits := Vector2i(mini(wanted.x, maxi(room.x, 240)), mini(wanted.y, maxi(room.y, 160)))
	if fits != wanted:
		var taken: Vector2i = _engine.resize_plugin_gui(_node_id, fits)
		if taken.x > 0 and taken.y > 0:
			fits = taken
	_set_size_quietly(fits)


## The window changed size under the user's hand: tell the plugin, and take its answer.
##
## The answer is rarely the question. An editor with an aspect ratio, integer zoom steps
## or a minimum size rounds the request, and the window has to follow it rather than the
## other way round — a window an inch wider than the editor inside it shows an inch of
## somebody else's background, which reads as a drawing bug rather than as rounding.
func _offer_size_to_plugin() -> void:
	if not _open or _resizing or _engine == null:
		return
	# The flag alone is not enough. size_changed can arrive a frame after the assignment
	# that caused it — the operating system decides when a window has really changed —
	# by which time the flag is down and our own resize looks like the user's. So the
	# question asked is whether the plugin already knows the size the window is, which is
	# true exactly when nobody has dragged anything.
	if size == _engine.plugin_gui_size(_node_id):
		return
	var taken: Vector2i = _engine.resize_plugin_gui(_node_id, size)
	if taken.x > 0 and taken.y > 0 and taken != size:
		_set_size_quietly(taken)


## Changes the window without treating the change as the user's doing.
func _set_size_quietly(to: Vector2i) -> void:
	_resizing = true
	size = to
	_resizing = false


func _process(_delta: float) -> void:
	# The plugin's main thread, once a frame. Without it a clicked knob moves and the
	# sound does not follow: both formats let a plugin defer work to the host's main
	# thread and then wait for it, and a host that never offers one leaves that work
	# undone for as long as the editor is open.
	if not _open or _engine == null:
		return
	_engine.tick_plugins()
	# The other direction: the plugin asking to be a different size, which is what a zoom
	# menu inside somebody else's editor amounts to. Collected here rather than delivered
	# by callback, because it arrives from inside the plugin in the middle of a click and
	# this window belongs to a scene tree with opinions about when it is touched.
	var asked: Vector2i = _engine.take_plugin_gui_resize_request(_node_id)
	if asked != Vector2i.ZERO:
		_fit_and_take(asked)


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
