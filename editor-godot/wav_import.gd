extends RefCounted
## Reads a WAV file into mono floats, for feeding the engine's LPC encoder.
##
## Format parsing and nothing else — the same station midi_import.gd holds for
## tunes: GDScript may read a file's shape, the engine does everything that could
## be called signal processing. 16-bit PCM only, any channel count (averaged),
## any rate (the encoder resamples); everything Windows recorders, macOS `say`
## and this project's own sg-render write.


## {"samples": PackedFloat32Array, "rate": float}, or {} for a file this reader
## cannot hold — never a crash, the caller owns the message.
static func read(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" \
			or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return {}
	var offset := 12
	var channels := 0
	var rate := 0
	var bits := 0
	var data := PackedByteArray()
	while offset + 8 <= bytes.size():
		var id := bytes.slice(offset, offset + 4).get_string_from_ascii()
		var size := bytes.decode_u32(offset + 4)
		if id == "fmt ":
			channels = bytes.decode_u16(offset + 10)
			rate = bytes.decode_u32(offset + 12)
			bits = bytes.decode_u16(offset + 22)
		elif id == "data":
			data = bytes.slice(offset + 8, mini(offset + 8 + size, bytes.size()))
		offset += 8 + size + (size & 1)
	if channels < 1 or rate <= 0 or bits != 16 or data.size() < 2:
		return {}
	var frames := data.size() / 2 / channels
	var samples := PackedFloat32Array()
	samples.resize(frames)
	for i in frames:
		var sum := 0.0
		for c in channels:
			sum += data.decode_s16((i * channels + c) * 2) / 32768.0
		samples[i] = sum / channels
	return {"samples": samples, "rate": float(rate)}
