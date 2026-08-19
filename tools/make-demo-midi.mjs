// Writes examples/midi/ode-to-joy.mid: the demonstration MIDI file the editor's
// importer is tested against.
//
// Generated rather than downloaded so the licence question has a one-line answer:
// the melody is Beethoven's (1824, public domain everywhere), and this encoding of
// it is this repository's own. Format 0, one track, 96 ticks per quarter, 120 bpm —
// the plainest spelling a Standard MIDI File has, which is also the point: the
// importer's first duty is the ordinary case.
//
//   node tools/make-demo-midi.mjs
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

const TICKS_PER_QUARTER = 96;

// The theme, eight bars of 4/4. Durations in quarters.
const E4 = 64, F4 = 65, G4 = 67, D4 = 62, C4 = 60;
const melody = [
  [E4, 1], [E4, 1], [F4, 1], [G4, 1],
  [G4, 1], [F4, 1], [E4, 1], [D4, 1],
  [C4, 1], [C4, 1], [D4, 1], [E4, 1],
  [E4, 1.5], [D4, 0.5], [D4, 2],
  [E4, 1], [E4, 1], [F4, 1], [G4, 1],
  [G4, 1], [F4, 1], [E4, 1], [D4, 1],
  [C4, 1], [C4, 1], [D4, 1], [E4, 1],
  [D4, 1.5], [C4, 0.5], [C4, 2],
];

function vlq(value) {
  const bytes = [value & 0x7f];
  while ((value >>= 7) > 0) {
    bytes.unshift((value & 0x7f) | 0x80);
  }
  return bytes;
}

const events = [];
const push = (delta, ...bytes) => events.push(...vlq(delta), ...bytes);
// 120 bpm: 500000 microseconds per quarter.
push(0, 0xff, 0x51, 0x03, 0x07, 0xa1, 0x20);
let carry = 0;
for (const [note, quarters] of melody) {
  const ticks = Math.round(quarters * TICKS_PER_QUARTER);
  // A hair of daylight between notes so repeated pitches retrigger; the gap
  // rides the next note-on's delta.
  const sounding = Math.max(1, ticks - 6);
  push(carry, 0x90, note, 96);
  push(sounding, 0x80, note, 0);
  carry = ticks - sounding;
}
push(carry, 0xff, 0x2f, 0x00); // end of track

const track = Buffer.from(events);
const header = Buffer.concat([
  Buffer.from("MThd"),
  Buffer.from([0, 0, 0, 6, 0, 0, 0, 1, TICKS_PER_QUARTER >> 8, TICKS_PER_QUARTER & 0xff]),
]);
const chunk = Buffer.concat([
  Buffer.from("MTrk"),
  Buffer.from([(track.length >> 24) & 0xff, (track.length >> 16) & 0xff,
               (track.length >> 8) & 0xff, track.length & 0xff]),
  track,
]);

mkdirSync(join(root, "examples", "midi"), { recursive: true });
const out = join(root, "examples", "midi", "ode-to-joy.mid");
writeFileSync(out, Buffer.concat([header, chunk]));
console.log(`wrote ${out} (${header.length + chunk.length} bytes, ${melody.length} notes)`);
