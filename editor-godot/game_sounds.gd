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
## reset() is what makes this work: the patches are one-shot, gated by a constant, so the
## envelope fires on the first sample and never again. Returning the graph to its freshly
## prepared state makes that first sample happen again.
func play(sound_name: String) -> void:
	var voice: Dictionary = _voices.get(sound_name, {})
	if voice.is_empty():
		push_warning("GameSounds: no sound named '%s'" % sound_name)
		return
	voice["engine"].reset()


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
