# A recording becomes notes in the roll.
#
# The work is done by sg-transcribe, a separate binary, for the same reason the plugin
# scan is done by sg-host: the model behind it needs ONNX Runtime, and an editor that
# cannot start without a machine-learning runtime installed would be a poor trade for a
# feature most sessions never touch. So this locates it, runs it, and reads what it
# wrote — and when it is not there, says so plainly rather than appearing broken.
#
# Split the way plugin_picker.gd is split, and for the same reason: the half that parses
# can be tested on a machine with no transcriber on it, which is the whole difficulty
# with testing a feature that shells out.
extends RefCounted

## What the file dialog offers. sg-transcribe decodes these through miniaudio; .ogg and
## .m4a are not among them, and the tool says so itself when handed one.
const FILTERS := ["*.wav ; WAV", "*.mp3 ; MP3", "*.flac ; FLAC"]


## Where the transcriber is, if it is anywhere.
##
## Same search as PluginPicker.host_path: an explicit environment variable first, so a
## machine that keeps its build somewhere unusual can say so, then the usual build
## directories relative to the project.
static func binary_path() -> String:
	var named := OS.get_environment("SOUNDGRAPH_TRANSCRIBE")
	if named != "" and FileAccess.file_exists(named):
		return named
	var suffix := ".exe" if OS.get_name() == "Windows" else ""
	for candidate in [
		"res://../build/bin/sg-transcribe" + suffix,
		"res://../build-clap/bin/sg-transcribe" + suffix,
		"res://../../build/bin/sg-transcribe" + suffix,
	]:
		var absolute := ProjectSettings.globalize_path(candidate)
		if FileAccess.file_exists(absolute):
			return absolute
	return ""


## The patch handed to the transcriber to write into.
##
## Deliberately empty. sg-transcribe writes a roll into a patch, and the roll is the only
## part wanted here — sending the document the person is editing through a round trip of
## somebody else's writer, only to throw away everything but one section, would be a lot
## of risk for no gain.
static func carrier_text() -> String:
	return JSON.stringify({"schema_version": 1, "nodes": [], "connections": []})


## The sequence out of what the transcriber wrote. Pure, so it can be tested against a
## fixture with no binary and no audio anywhere near it.
static func sequence_from(text: String) -> Dictionary:
	# JSON.parse_string() pushes an engine error when the text is not JSON, which is
	# noise here: being handed something unreadable is an outcome this function is
	# supposed to handle, not a fault worth a stack trace in the console.
	var reader := JSON.new()
	if reader.parse(text) != OK:
		return {}
	var parsed: Variant = reader.data
	if not (parsed is Dictionary):
		return {}
	var sequence: Variant = (parsed as Dictionary).get("sequence", null)
	if not (sequence is Dictionary):
		return {}
	var notes: Variant = (sequence as Dictionary).get("notes", null)
	if not (notes is Array) or (notes as Array).is_empty():
		return {}
	return sequence as Dictionary


## Runs the transcriber over one file.
##
## Returns {"ok": bool, "sequence": Dictionary, "error": String}. Errors are sentences
## meant for a person, because every one of them is something they can act on: install
## the thing, pick a different file, or record something with notes in it.
static func run(audio_path: String, tempo: float, division: int) -> Dictionary:
	var binary := binary_path()
	if binary == "":
		return {"ok": false, "sequence": {}, "error":
			"no transcriber built — see tools/sg-transcribe/README.md"}

	var scratch := ProjectSettings.globalize_path("user://transcribe")
	DirAccess.make_dir_recursive_absolute(scratch)
	var carrier := scratch + "/carrier.json"
	var written := scratch + "/heard.json"
	var midi := scratch + "/heard.mid"

	var file := FileAccess.open(carrier, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "sequence": {}, "error": "could not write to " + scratch}
	file.store_string(carrier_text())
	file.close()

	var printed: Array = []
	var code := OS.execute(binary, [audio_path,
		"--patch", carrier, "--out", written, "--midi", midi,
		"--tempo", str(tempo), "--division", str(division), "--quiet"], printed, true)

	if code != 0:
		# The tool's own message is better than anything inventable here: it names the
		# formats it understands, or says the file was not audio at all.
		var complaint := ""
		for line in printed:
			complaint += str(line)
		complaint = complaint.strip_edges()
		return {"ok": false, "sequence": {},
			"error": complaint if complaint != "" else "the transcriber would not run"}

	if not FileAccess.file_exists(written):
		return {"ok": false, "sequence": {}, "error": "the transcriber wrote nothing"}
	var harvest := FileAccess.open(written, FileAccess.READ)
	var sequence := sequence_from(harvest.get_as_text())
	harvest.close()

	if sequence.is_empty():
		return {"ok": false, "sequence": {},
			"error": "no notes were found in that recording"}
	return {"ok": true, "sequence": sequence, "error": "", "midi": midi}
