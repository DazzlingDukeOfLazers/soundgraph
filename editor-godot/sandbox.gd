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


func _ready() -> void:
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(column)

	_status = Label.new()
	_status.text = "loading sounds…"
	column.add_child(_status)

	var help := Label.new()
	help.text = "Arrow keys or A/D to run    Space to jump    X to shoot    R to restart"
	help.add_theme_color_override("font_color", INK_DIM)
	column.add_child(help)

	var wiring := Label.new()
	wiring.text = "jump.json on jump    coin.json on pickup    hurt.json on spikes    " \
		+ "shoot.json on X    powerup.json at the flag    explode.json off the bottom"
	wiring.add_theme_color_override("font_color", INK_DIM)
	column.add_child(wiring)

	sounds = GameSounds.new()
	sounds.load_failed.connect(func(name: String, diagnostics: String) -> void:
		_status.text = "could not load %s: %s" % [name, diagnostics])
	add_child(sounds)

	# The patches live with the other examples rather than inside the editor project: they
	# are ordinary SoundGraph documents, openable in the Graph tab like anything else.
	var folder := "res://examples/game"
	var loaded := sounds.load_folder(folder)
	if loaded == 0:
		folder = ProjectSettings.globalize_path("res://").path_join("../examples/patches/game")
		loaded = sounds.load_folder(folder)
	if loaded > 0:
		_status.text = "%d sounds loaded: %s" % [loaded, ", ".join(sounds.sound_names())]
	else:
		_status.text = "no sounds found in %s — the sandbox will be silent" % folder
	# Printed as well as shown, because this is the one thing that has to be checkable from
	# outside: an exported build's res:// is a packed archive, and "did the patches come
	# along" is not a question the UI can answer if the UI is a canvas you cannot read.
	print("Sandbox: %s" % _status.text)

	var viewport_holder := SubViewportContainer.new()
	viewport_holder.stretch = true
	viewport_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewport_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(viewport_holder)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(WORLD_SIZE)
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport_holder.add_child(viewport)

	world = SandboxWorld.new()
	world.sounds = sounds
	world.status = _status
	viewport.add_child(world)


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

		var jump_held := Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_UP)
		if jump_held and _on_ground:
			_velocity.y = -JUMP_SPEED
			_on_ground = false
			sounds.play("jump")            # <- the whole integration, once per event

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
