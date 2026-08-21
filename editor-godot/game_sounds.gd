class_name GameSounds
extends Node
## Plays SoundGraph patches as game sound effects.
##
## This is the file to copy into a Godot project. It is deliberately short, because the
## point is how little there is: a patch is a JSON file, an engine renders it, and a game
## event fires it. There is no build step, no import, and no baked audio.
##
##     var sounds := GameSounds.new()
##     add_child(sounds)
##     sounds.load_folder("res://sounds")     # every .json in the folder
##     ...
##     sounds.play("jump")
##
## Why a patch rather than a .wav. A wav is one recording of one sound. A patch is the
## instructions, so it can be changed while the game runs — which is the whole argument
## for this project, and the sandbox next door exists to let somebody try it: edit the
## graph, hear the jump change, without leaving the editor.
##
## Each sound gets its own engine and its own player, and `play` retriggers rather than
## overlapping. Two coins collected in the same frame make one coin sound, not two. That is
## usually what a game wants and it keeps this file readable; real polyphony is a pool of
## voices per sound, which is a different and longer file.

## Emitted when a patch fails to load, with the diagnostics the core produced. Sound is the
## thing nobody notices is broken, so this does not fail quietly.
signal load_failed(sound_name: String, diagnostics: String)

const MIX_RATE := 48000.0

var _voices: Dictionary = {}   # name -> {"engine": ..., "player": ..., "playback": ...}


## Loads every .json in a folder, naming each sound after its file.
func load_folder(path: String) -> int:
	var directory := DirAccess.open(path)
	if directory == null:
		push_error("GameSounds: cannot open %s" % path)
		return 0

	var loaded := 0
	var seen := 0
	for file_name in directory.get_files():
		if not file_name.ends_with(".json"):
			continue
		seen += 1
		if load_sound(file_name.get_basename(), path.path_join(file_name)):
			loaded += 1

	# Counted separately on purpose. "No sounds" and "seven sounds that all failed" look
	# identical from the outside and have nothing in common: the first is a missing folder,
	# the second was a stale extension that had never heard of half the node types. Saying
	# which is the difference between a minute and an hour.
	if seen > 0 and loaded == 0:
		push_warning("GameSounds: %d patch(es) in %s, none of them loaded" % [seen, path])
	return loaded


func load_sound(sound_name: String, patch_path: String) -> bool:
	var text := FileAccess.get_file_as_string(patch_path)
	if text.is_empty():
		_report_failure(sound_name, "could not read %s" % patch_path)
		return false

	# Untyped on purpose, as in main.gd: naming SoundGraphEngine as a type would make this
	# script fail to parse when the extension is missing, so the signal below could never
	# report it.
	var engine = ClassDB.instantiate("SoundGraphEngine")
	if engine == null:
		_report_failure(sound_name, "the SoundGraphEngine extension is not loaded")
		return false

	if not engine.load_patch(text, MIX_RATE):
		_report_failure(sound_name, str(engine.get_diagnostics_json()))
		return false

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MIX_RATE
	# Short, because a game sound has to arrive on the frame it was asked for. A longer
	# buffer is safer against dropouts and audibly late for a jump.
	generator.buffer_length = 0.05

	var player := AudioStreamPlayer.new()
	player.stream = generator
	# See main.gd: web defaults to sample playback, which a generator cannot do.
	player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	add_child(player)
	player.play()

	_voices[sound_name] = {
		"engine": engine,
		"player": player,
		"playback": player.get_stream_playback(),
	}
	return true


## Fires a sound from the beginning.
##
## The patches are triggered by a NoteInput, so firing one is playing a note — which is
## also what makes them usable as modules and playable in the editor.
##
## This used to release the note first, because an AHD envelope triggers on a rising edge
## and a key already held gives it none. That worked most of the time, which is worse than
## not working: control events are drained at block boundaries, so a release and a press in
## the same frame produce no sample where the gate is low, and the envelope sees a gate
## that never moved. A double jump fired one sound instead of two, sometimes, depending on
## where the block edges fell. The patches now take NoteInput's `trigger` output, which
## pulses on every note whether or not one is held, so the release is gone and so is the
## intermittency.
##
## The pitch is ignored by these patches, which take only the trigger; a coin has a pitch
## of its own. Passing one anyway means a patch that *does* use the frequency will follow
## it, which is how a game would want to play a footstep at different pitches.
func play(sound_name: String, note: int = 60) -> void:
	var voice: Dictionary = _voices.get(sound_name, {})
	if voice.is_empty():
		push_warning("GameSounds: no sound named '%s'" % sound_name)
		return
	voice["engine"].note_on(note, 1.0)


## Both, always. A signal is only useful to whoever connected it, and the one thing that
## must never happen quietly is a sound failing to load — nobody notices missing audio
## until they are standing in front of an audience wondering why it is silent.
func _report_failure(sound_name: String, diagnostics: String) -> void:
	push_warning("GameSounds: %s failed to load: %s" % [sound_name, diagnostics])
	emit_signal("load_failed", sound_name, diagnostics)


func has_sound(sound_name: String) -> bool:
	return _voices.has(sound_name)


func sound_names() -> Array:
	var names := _voices.keys()
	names.sort()
	return names


## Let the engines go before the tree tears down.
##
## Each voice holds a SoundGraphEngine, which is a GDExtension object. Godot reported ten
## leaked at exit — the editor's one and this file's eight — and an extension object still
## alive when the extension unloads is an access violation waiting to happen. It was: the
## round-trip check began failing about one run in three with status 0xC0000005, a crash
## during shutdown, long after the work had succeeded.
## Every voice down, deliberately: stopped and unplugged under one audio lock so the
## mixer cannot be mid-block in any of them, then freed by hand rather than left to
## the tree's own ordering — which frees children on its schedule, not this one, and
## was the last place the shutdown crash could still stand.
func shutdown() -> void:
	set_process(false)
	AudioServer.lock()
	for name in _voices:
		var voice: Dictionary = _voices[name]
		if voice["player"] != null:
			voice["player"].stop()
	AudioServer.unlock()
	for name in _voices:
		var voice: Dictionary = _voices[name]
		if voice["player"] != null:
			if voice["player"].get_parent() != null:
				voice["player"].get_parent().remove_child(voice["player"])
			voice["player"].free()
		voice["engine"] = null
		voice["playback"] = null
	_voices.clear()


func _exit_tree() -> void:
	shutdown()


## Every engine renders into its own player, every frame. Filling only what the buffer has
## room for is what keeps this from either starving or blocking.
func _process(_delta: float) -> void:
	for name in _voices:
		var voice: Dictionary = _voices[name]
		var playback = voice["playback"]
		if playback == null:
			continue
		var available: int = playback.get_frames_available()
		if available > 0:
			voice["engine"].fill_playback(playback, available)
