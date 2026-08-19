extends RefCounted
## Reads a Standard MIDI File into the shape the piano roll plays.
##
## A deliberately small reading, not a MIDI stack: note-ons, note-offs, and the
## first tempo, quantised to sixteenth-note steps. Formats 0 and 1 both land here —
## the tracks of a format 1 file are merged on their absolute tick times, which is
## what a format 0 file already is. Percussion (channel ten) is skipped: the roll
## drives one pitched instrument, and a drum map played as pitches is noise wearing
## a tune's clothes. Everything else a file may carry — controllers, pitch bend,
## sysex, markers — is stepped over at its declared length and left behind.
##
## The parser refuses quietly ({}) rather than guessing: a file that is not SMF, a
## SMPTE-timed file (division with the high bit set), or a truncated chunk all come
## back empty, and the caller says so in words.

## The roll's own ceiling, sixteen bars of sixteenths — the schema's cap.
const MAX_STEPS := 256


static func read(path: String) -> Dictionary:
	return parse(FileAccess.get_file_as_bytes(path))


static func parse(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 14 or bytes.slice(0, 4).get_string_from_ascii() != "MThd":
		return {}
	var format := (bytes[8] << 8) | bytes[9]
	var track_count := (bytes[10] << 8) | bytes[11]
	var division := (bytes[12] << 8) | bytes[13]
	if format > 1 or division == 0 or (division & 0x8000) != 0:
		return {}

	# Every note event across every track, on one absolute clock.
	var opens := {}    # note -> [{tick, step...}] awaiting their off
	var placed: Array = []
	var tempo_us := 500000.0
	var tempo_seen := false
	var at := 14
	var tracks_read := 0
	while tracks_read < track_count and at + 8 <= bytes.size():
		if bytes.slice(at, at + 4).get_string_from_ascii() != "MTrk":
			return {}
		var length := (bytes[at + 4] << 24) | (bytes[at + 5] << 16) \
			| (bytes[at + 6] << 8) | bytes[at + 7]
		var cursor := at + 8
		var end := cursor + length
		if end > bytes.size():
			return {}
		var tick := 0
		var running := 0
		while cursor < end:
			# Delta time, as a variable-length quantity.
			var delta := 0
			while cursor < end:
				var piece := bytes[cursor]
				cursor += 1
				delta = (delta << 7) | (piece & 0x7f)
				if (piece & 0x80) == 0:
					break
			tick += delta
			if cursor >= end:
				break
			var status := int(bytes[cursor])
			if status >= 0x80:
				cursor += 1
			else:
				status = running
			if status == 0:
				return {}
			match status & 0xf0:
				0x90, 0x80:
					running = status
					var note := int(bytes[cursor])
					var velocity := int(bytes[cursor + 1])
					cursor += 2
					if (status & 0x0f) == 9:
						continue  # the drum channel is not a melody
					var arriving: bool = (status & 0xf0) == 0x90 and velocity > 0
					if arriving:
						if not opens.has(note):
							opens[note] = []
						(opens[note] as Array).append(tick)
					elif opens.has(note) and not (opens[note] as Array).is_empty():
						var started: int = (opens[note] as Array).pop_front()
						placed.append({"note": note, "on": started, "off": tick})
				0xa0, 0xb0, 0xe0:
					running = status
					cursor += 2
				0xc0, 0xd0:
					running = status
					cursor += 1
				0xf0:
					running = 0
					if status == 0xff:
						var kind := int(bytes[cursor])
						cursor += 1
						var meta_length := 0
						while cursor < end:
							var piece := bytes[cursor]
							cursor += 1
							meta_length = (meta_length << 7) | (piece & 0x7f)
							if (piece & 0x80) == 0:
								break
						if kind == 0x51 and meta_length == 3 and not tempo_seen:
							tempo_us = float((bytes[cursor] << 16)
								| (bytes[cursor + 1] << 8) | bytes[cursor + 2])
							tempo_seen = true
						cursor += meta_length
					else:
						# Sysex: a length-prefixed blob to step over.
						var blob_length := 0
						while cursor < end:
							var piece := bytes[cursor]
							cursor += 1
							blob_length = (blob_length << 7) | (piece & 0x7f)
							if (piece & 0x80) == 0:
								break
						cursor += blob_length
				_:
					return {}
		at = end
		tracks_read += 1

	# Quantise to sixteenths. What starts past the roll's ceiling is dropped and
	# counted, so the caller can say "the first sixteen bars" honestly.
	var sixteenth := float(division) / 4.0
	var notes: Array = []
	var furthest := 0
	var dropped := 0
	for entry: Dictionary in placed:
		var step := int(round(float(entry["on"]) / sixteenth))
		if step >= MAX_STEPS:
			dropped += 1
			continue
		var held := maxi(1, int(round(float(entry["off"] - entry["on"]) / sixteenth)))
		notes.append({"step": step, "note": int(entry["note"]),
			"length": mini(held, MAX_STEPS - step)})
		furthest = maxi(furthest, step + mini(held, MAX_STEPS - step))
	if notes.is_empty():
		return {}
	var steps := clampi(ceili(float(furthest) / 16.0) * 16, 16, MAX_STEPS)
	return {
		"tempo": clampf(60000000.0 / tempo_us, 40.0, 240.0),
		"steps": steps,
		"notes": notes,
		"dropped": dropped,
	}
