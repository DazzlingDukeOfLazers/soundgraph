class_name Sandbox
extends Control
## A small platformer, so that "patches are game sounds" is something you can hear rather
## than something you have to be told.
##
## The game is deliberately crude — hand-rolled physics, rectangles for scenery, no
## sprites. It is not the exhibit. The exhibit is `game_sounds.gd` next door and the six
## lines in this file that call it, and anything more elaborate here would bury them.
##
## What it is for: a Godot user asking "how would I use this?" gets an answer they can run,
## and then the answer they cannot get from a .wav — open the Graph tab, change the jump
## patch, come back, and the jump sounds different. No reimport, no rebuild. That is the
## whole argument for shipping instructions instead of recordings, and it takes about ten
## seconds to demonstrate.

const GRAVITY := 1800.0
const RUN_SPEED := 260.0
const JUMP_SPEED := 620.0
const PLAYER_SIZE := Vector2(26.0, 34.0)
## One from the ground, one from the air. The upper platforms are out of reach on one.
const MAX_JUMPS := 2
const WORLD_SIZE := Vector2(960.0, 540.0)

const INK := Color(0.96, 0.96, 0.97)
const INK_DIM := Color(0.72, 0.74, 0.78)
const ACCENT := Color(0.43, 0.91, 0.72)
const COIN := Color(1.0, 0.83, 0.35)
const HAZARD := Color(1.0, 0.45, 0.42)
const SKY := Color(0.09, 0.10, 0.13)
const GROUND := Color(0.20, 0.22, 0.27)

var sounds: GameSounds
var world: SandboxWorld

var _status: Label
var _loaded := false


## How the stage is fitted into whatever room the tab has.
##
## The game has a fixed logical size, and it used to be stretched across the whole panel
## — so the play area ran to the edges with nothing framing it and the empty half of the
## screen read as rendering having stopped rather than as a game 960 wide. A stage says
## where the game is: the aspect is kept, the rest is backdrop, and the size is written
## down so nobody has to guess whether what they are seeing is the whole of it.
enum Fit { ACTUAL, FIT, FILL }

const FIT_NAMES := ["Actual size", "Fit", "Fill"]

var _fit: int = Fit.FIT
var _stage: AspectRatioContainer
var _holder: SubViewportContainer
var _shortcuts: Label
var _controls_popup: PopupPanel


func _ready() -> void:
	# Inset, because the tab reaches the window edge and the first word of the shortcut
	# strip was being cut in half by it.
	var inset := MarginContainer.new()
	inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for edge in ["left", "right", "top", "bottom"]:
		inset.add_theme_constant_override("margin_" + edge, Design.scale(Design.SPACE_M))
	add_child(inset)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", Design.SPACE_S)
	inset.add_child(column)

	# ---- one strip, not three paragraphs ------------------------------------------
	# What was here: a line listing eight loaded sounds, a line of key bindings, and a
	# line mapping every patch to every event. All of it true, all of it useful once,
	# and together it made a game demo look like a debug page — three rows of prose
	# above the thing somebody came to play with.
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", Design.SPACE_M)
	column.add_child(strip)

	_shortcuts = Label.new()
	_shortcuts.text = "A D  move      Space  jump ×2      X  shoot      R  restart"
	_shortcuts.add_theme_font_override("font", Design.numeric_font())
	_shortcuts.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	_shortcuts.add_theme_color_override("font_color", Design.INK_SECOND)
	strip.add_child(_shortcuts)

	# The rest of it, one click away rather than always on screen.
	var controls := Button.new()
	controls.text = "Which sound plays when?"
	controls.flat = true
	controls.focus_mode = Control.FOCUS_NONE
	controls.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	controls.add_theme_color_override("font_color", Design.ACCENT)
	controls.pressed.connect(_show_controls)
	strip.add_child(controls)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	strip.add_child(gap)

	var fit_menu := MenuButton.new()
	fit_menu.text = "Fit"
	fit_menu.flat = false
	var fit_popup := fit_menu.get_popup()
	for index in FIT_NAMES.size():
		fit_popup.add_radio_check_item(FIT_NAMES[index], index)
	fit_popup.set_item_checked(_fit, true)
	fit_popup.id_pressed.connect(func(id: int) -> void:
		_fit = id
		for entry in FIT_NAMES.size():
			fit_popup.set_item_checked(entry, entry == id)
		_apply_fit())
	fit_menu.focus_mode = Control.FOCUS_NONE
	strip.add_child(fit_menu)

	_status = Label.new()
	_status.text = "open this tab to load the sounds"
	_status.add_theme_font_size_override("font_size",
		Design.type(Design.SIZE_SECONDARY))
	_status.add_theme_color_override("font_color", Design.INK_SECOND)
	# Left, with an ellipsis, for the same reason the toolbar's status line is: right
	# alignment plus clipping takes the overflow off the *front*, so "open this tab to
	# load the sounds" would arrive as "load the sounds" — an instruction with its verb
	# missing, and nothing on screen admitting anything was cut.
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_status.custom_minimum_size.x = Design.scale(220)
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	strip.add_child(_status)

	sounds = GameSounds.new()
	sounds.load_failed.connect(func(name: String, diagnostics: String) -> void:
		_status.text = "could not load %s" % name
		_status.tooltip_text = diagnostics)
	add_child(sounds)

	# ---- the stage --------------------------------------------------------------
	# A backdrop darker than the game, so the play area is obviously a thing sitting on
	# something rather than the panel having failed to draw to its edges.
	var backdrop := PanelContainer.new()
	backdrop.size_flags_vertical = Control.SIZE_EXPAND_FILL
	backdrop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	backdrop.add_theme_stylebox_override("panel",
		Design.panel(Design.Surface.CANVAS, 0, 0))
	column.add_child(backdrop)

	# Straight into the backdrop, with no CenterContainer.
	#
	# The first attempt wrapped it in one, and a CenterContainer sizes its child to the
	# child's *minimum* — so an AspectRatioContainer asking to expand got nothing and
	# the game vanished entirely. AspectRatioContainer already centres what it holds;
	# that is most of what it is for.
	_stage = AspectRatioContainer.new()
	_stage.ratio = WORLD_SIZE.x / WORLD_SIZE.y
	_stage.stretch_mode = AspectRatioContainer.STRETCH_FIT
	_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	backdrop.add_child(_stage)

	_holder = SubViewportContainer.new()
	_holder.stretch = true
	_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage.add_child(_holder)
	# Input follows the same rule as rendering: a world nobody can see gets nothing.
	# The container forwards events at the Node layer, which does not care that the
	# tab is hidden — and hidden, the layout is 0x0, the viewport's stretch transform
	# has no inverse, and every key pressed anywhere in the editor printed one
	# "det == 0" error from inverting it. (The render half of the same story is
	# UPDATE_WHEN_VISIBLE below.)
	_holder.visibility_changed.connect(_mute_hidden_input)
	_mute_hidden_input.call_deferred()

	var viewport := SubViewport.new()
	viewport.size = Vector2i(WORLD_SIZE)
	viewport.transparent_bg = false
	# WHEN_VISIBLE, not ALWAYS. With ALWAYS this viewport drew every frame of every
	# session, including the ones spent entirely on the Graph tab — and while the tab is
	# hidden its container is laid out at 0x0, so `stretch` drove the viewport down to
	# Godot's 2x2 floor while the override below still asked for 960x540. Rendering that
	# produced a transform with no inverse, and one "Condition det == 0 is true" per
	# frame for as long as the editor was open: about sixty a second of log noise, which
	# is the kind of thing that trains you to stop reading the console. Not rendering a
	# game world nobody is looking at is the right behaviour independently of that.
	viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	# The logical size the game is drawn in, whatever size it is displayed at.
	#
	# This is the actual cause of the empty region. SubViewportContainer.stretch
	# *resizes* the viewport to match the container rather than scaling it — so the
	# viewport became as wide as the panel while the world went on drawing its fixed
	# 960 units, and everything past that was blank. The grey area was never a layout
	# problem; it was the right-hand third of a viewport nothing had drawn into, and
	# the goal flag was sitting just outside the part that did.
	#
	# With an override the world always has 960x540 to draw in and the result is
	# scaled, which is what "fixed logical resolution" is supposed to mean.
	viewport.size_2d_override = Vector2i(WORLD_SIZE)
	viewport.size_2d_override_stretch = true
	_holder.add_child(viewport)

	world = SandboxWorld.new()
	world.sounds = sounds
	world.status = _status
	viewport.add_child(world)
	_apply_fit()


func _mute_hidden_input() -> void:
	var live := _holder.is_visible_in_tree()
	_holder.set_process_input(live)
	_holder.set_process_unhandled_input(live)


## Applies the current fit. Actual size pins the stage to the game's own resolution, so
## what you see is what a game would draw; Fit scales it to the room available while
## keeping the shape; Fill gives up the shape to use the whole panel.
func _apply_fit() -> void:
	if _stage == null:
		return
	match _fit:
		Fit.ACTUAL:
			# Pinned to the game's own resolution and centred, so what is on screen is
			# pixel for pixel what a game would draw.
			_stage.custom_minimum_size = WORLD_SIZE
			_stage.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			_stage.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			_stage.stretch_mode = AspectRatioContainer.STRETCH_FIT
		Fit.FIT:
			_stage.custom_minimum_size = Vector2.ZERO
			_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
			_stage.stretch_mode = AspectRatioContainer.STRETCH_FIT
		Fit.FILL:
			_stage.custom_minimum_size = Vector2.ZERO
			_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
			_stage.stretch_mode = AspectRatioContainer.STRETCH_COVER


## The full event-to-patch mapping, on request.
##
## Every line of it was permanently on screen. It is the most interesting thing about the
## sandbox and it is read once, which is exactly what a disclosure is for.
func _show_controls() -> void:
	if _controls_popup == null:
		_controls_popup = PopupPanel.new()
		add_child(_controls_popup)
		var body := VBoxContainer.new()
		body.add_theme_constant_override("separation", Design.SPACE_S)
		_controls_popup.add_child(body)
		for line in [
				"jump.json      when the player jumps",
				"jump2.json     on the second jump, in mid-air",
				"coin.json      picking a coin up",
				"hurt.json      touching the spikes",
				"shoot.json     firing, on X",
				"powerup.json   reaching the flag",
				"explode.json   falling off the bottom",
		]:
			var label := Label.new()
			label.text = line
			label.add_theme_font_override("font", Design.numeric_font())
			label.add_theme_font_size_override("font_size",
				Design.type(Design.SIZE_SECONDARY))
			body.add_child(label)
		var note := Label.new()
		note.text = "Every one is an ordinary patch. Open it in the Graph tab, "
		note.text += "change it, and the game plays the new version."
		note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		note.custom_minimum_size.x = Design.scale(340)
		note.add_theme_color_override("font_color", Design.INK_SECOND)
		body.add_child(note)
	_controls_popup.popup_centered()


## Loads the sounds, once, the first time anyone opens this tab.
##
## Not at startup, which is what it used to do. Eight patches means eight engines and eight
## audio players, built whether or not the tab is ever looked at — and in a headless run
## they are never released, because Godot's quit() does not unwind the tree. Ten leaked
## GDExtension objects at shutdown turned into an access violation about one run in three,
## which showed up as the round-trip check failing long after its work had succeeded.
##
## Deferring it fixes that and is the better behaviour anyway: an editor should not build a
## game's audio because the window opened.
func ensure_sounds_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	# The patches live with the other examples rather than inside the editor project: they
	# are ordinary SoundGraph documents, openable in the Graph tab like anything else.
	var folder := "res://examples/game"
	var loaded := sounds.load_folder(folder)
	if loaded == 0:
		folder = ProjectSettings.globalize_path("res://").path_join("../examples/patches/game")
		loaded = sounds.load_folder(folder)
	if loaded > 0:
		# Short enough for the strip; the list itself is in the tooltip and in the
		# controls popup, both of which are one gesture away.
		_status.text = "%d sounds ready" % loaded
		_status.tooltip_text = ", ".join(sounds.sound_names())
	else:
		_status.text = "no sounds found in %s — the sandbox will be silent" % folder
	# Printed as well as shown, because this is the one thing that has to be checkable from
	# outside: an exported build's res:// is a packed archive, and "did the patches come
	# along" is not a question the UI can answer if the UI is a canvas you cannot read.
	print("Sandbox: %s" % _status.text)


## The editor's keyboard is a piano, and this tab's keyboard is a game. Whichever is
## visible wins; main.gd asks this before it turns a key into a note.
func wants_keyboard() -> bool:
	return is_visible_in_tree()


# ---------------------------------------------------------------------------------


class SandboxWorld extends Node2D:
	var sounds: GameSounds
	var status: Label

	var _player := Vector2(80.0, 300.0)
	var _velocity := Vector2.ZERO
	var _on_ground := false
	var _jumps_used := 0
	var _jump_was_held := false
	var _facing := 1.0
	var _score := 0
	var _hurt_cooldown := 0.0
	var _finished := false

	var _platforms: Array[Rect2] = []
	var _coins: Array = []      # {"at": Vector2, "taken": bool}
	var _spikes: Array[Rect2] = []
	var _shots: Array = []      # {"at": Vector2, "velocity": Vector2}
	var _flag := Rect2()

	func _ready() -> void:
		_build_level()
		set_process(true)

	func _build_level() -> void:
		_platforms = [
			Rect2(0, 480, 340, 60),
			Rect2(420, 480, 240, 60),
			Rect2(300, 360, 120, 24),
			Rect2(560, 300, 140, 24),
			Rect2(740, 420, 220, 120),
			Rect2(140, 250, 120, 24),
		]
		_spikes = [Rect2(470, 456, 140, 24)]
		_flag = Rect2(900, 340, 14, 80)
		_coins = []
		for at in [Vector2(180, 210), Vector2(350, 320), Vector2(610, 260),
				Vector2(250, 440), Vector2(820, 380), Vector2(500, 200)]:
			_coins.append({"at": at, "taken": false})

	func _reset() -> void:
		_player = Vector2(80.0, 300.0)
		_velocity = Vector2.ZERO
		_jumps_used = 0
		_score = 0
		_finished = false
		_shots.clear()
		for coin in _coins:
			coin["taken"] = false

	func _process(delta: float) -> void:
		# Polled rather than event-driven, which is what a platformer wants and also keeps
		# this out of the way of the editor's own key handling.
		if not is_visible_in_tree():
			return
		delta = minf(delta, 1.0 / 30.0)  # a stall must not teleport the player through a floor

		if Input.is_key_pressed(KEY_R):
			_reset()

		var move := 0.0
		if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A):
			move -= 1.0
		if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D):
			move += 1.0
		if move != 0.0:
			_facing = move

		_velocity.x = move * RUN_SPEED

		# Two jumps: one from the ground and one from the air. Edge-triggered rather than
		# held, or a leaning-on-space player would spend both instantly and never reach
		# anything — which is what the single jump did to the upper platforms.
		var jump_held := Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_UP)
		if jump_held and not _jump_was_held and _jumps_used < MAX_JUMPS:
			# The second is weaker, so the pair reads as a recovery rather than a launch.
			_velocity.y = -JUMP_SPEED if _jumps_used == 0 else -JUMP_SPEED * 0.85
			_on_ground = false
			_jumps_used += 1
			sounds.play("jump" if _jumps_used == 1 else "jump2")
		_jump_was_held = jump_held

		if Input.is_key_pressed(KEY_X) and _shots.size() < 3:
			_shots.append({"at": _player, "velocity": Vector2(_facing * 620.0, 0.0)})
			sounds.play("shoot")

		_velocity.y += GRAVITY * delta
		_move(delta)
		_update_shots(delta)
		_check_pickups()
		_check_hazards(delta)
		queue_redraw()

	func _move(delta: float) -> void:
		# Axis at a time, which is the cheapest way to slide along a wall instead of
		# sticking to it. Not a physics engine; enough of one to jump on things.
		_player.x += _velocity.x * delta
		for platform in _platforms:
			if _overlaps(platform):
				_player.x -= _velocity.x * delta
				_velocity.x = 0.0
				break

		_player.y += _velocity.y * delta
		_on_ground = false
		for platform in _platforms:
			if not _overlaps(platform):
				continue
			if _velocity.y > 0.0:
				_player.y = platform.position.y - PLAYER_SIZE.y * 0.5
				_on_ground = true
				_jumps_used = 0
			else:
				_player.y = platform.end.y + PLAYER_SIZE.y * 0.5
			_velocity.y = 0.0
			break

		if _player.y > WORLD_SIZE.y + 120.0 and not _finished:
			sounds.play("explode")
			status.text = "fell off the world — R to restart"
			_reset()

	func _overlaps(rect: Rect2) -> bool:
		return rect.intersects(Rect2(_player - PLAYER_SIZE * 0.5, PLAYER_SIZE))

	func _update_shots(delta: float) -> void:
		var surviving: Array = []
		for shot in _shots:
			shot["at"] = shot["at"] + shot["velocity"] * delta
			if shot["at"].x > -20.0 and shot["at"].x < WORLD_SIZE.x + 20.0:
				surviving.append(shot)
		_shots = surviving

	func _check_pickups() -> void:
		for coin in _coins:
			if coin["taken"]:
				continue
			if _player.distance_to(coin["at"]) < 26.0:
				coin["taken"] = true
				_score += 1
				sounds.play("coin")
				status.text = "%d of %d coins" % [_score, _coins.size()]

		if not _finished and _flag.intersects(Rect2(_player - PLAYER_SIZE * 0.5, PLAYER_SIZE)):
			_finished = true
			sounds.play("powerup")
			status.text = "finished with %d of %d coins — R to play again" \
				% [_score, _coins.size()]

	func _check_hazards(delta: float) -> void:
		_hurt_cooldown = maxf(0.0, _hurt_cooldown - delta)
		if _hurt_cooldown > 0.0:
			return
		for spike in _spikes:
			if _overlaps(spike):
				sounds.play("hurt")
				_velocity = Vector2(-_facing * 320.0, -420.0)
				_hurt_cooldown = 0.6
				status.text = "ouch"
				return

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, Sandbox.WORLD_SIZE), Sandbox.SKY)

		for platform in _platforms:
			draw_rect(platform, Sandbox.GROUND)
			draw_line(platform.position, platform.position + Vector2(platform.size.x, 0.0),
				Sandbox.INK_DIM, 2.0)

		for spike in _spikes:
			var tooth := 14.0
			var x := spike.position.x
			while x + tooth <= spike.end.x:
				draw_colored_polygon(PackedVector2Array([
					Vector2(x, spike.end.y),
					Vector2(x + tooth * 0.5, spike.position.y),
					Vector2(x + tooth, spike.end.y)]), Sandbox.HAZARD)
				x += tooth

		for coin in _coins:
			if coin["taken"]:
				continue
			draw_circle(coin["at"], 9.0, Sandbox.COIN)
			draw_circle(coin["at"], 9.0, Color(0, 0, 0, 0.4), false, 1.5)

		draw_rect(_flag, Sandbox.INK_DIM)
		draw_colored_polygon(PackedVector2Array([
			_flag.position,
			_flag.position + Vector2(46.0, 14.0),
			_flag.position + Vector2(0.0, 28.0)]), Sandbox.ACCENT)

		for shot in _shots:
			draw_circle(shot["at"], 4.0, Sandbox.ACCENT)

		draw_rect(Rect2(_player - Sandbox.PLAYER_SIZE * 0.5, Sandbox.PLAYER_SIZE),
			Sandbox.ACCENT)
		# An eye, so which way it is facing is obvious without a sprite.
		draw_circle(_player + Vector2(_facing * 6.0, -6.0), 3.0, Sandbox.SKY)
