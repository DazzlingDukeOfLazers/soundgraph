// Timing repairs for a transcription: the model reports when it heard things, and
// this is where "when it heard things" becomes "when they were played".
//
// Three repairs, applied in this order:
//
//   merge_gaps    — a sustained note the frame head briefly lost comes back as two
//                   notes with a sliver of silence between them; heal the sliver.
//   snap_chords   — the notes of one struck chord cross the detection threshold a
//                   few frames apart; give them the one onset they actually had.
//   quantize      — find the beat the song was played against and pull notes onto
//                   it. detect_grid finds the grid; quantize_to_grid applies it.
//
// Pure arithmetic on Note vectors — no model, no files — so it is tested without
// ONNX Runtime (tests/test_transcribe_timing.cpp) even though the tool that uses it
// only builds when the runtime has been pointed at.
#pragma once

#include <vector>

#include "basic_pitch.h"

namespace transcribe {

// The beat as a grid of quantization steps: lines at phase + k * step. The phase is
// the smallest-magnitude representative, in [-step/2, step/2), because quantization
// shifts the file by it and a five-millisecond offset must move notes five
// milliseconds, not a step minus five. `tempo` is what the step implies at the given
// division. `confidence` is the mean resultant length of the onsets read as angles
// around the step period — 1.0 when every onset sits exactly on a grid line, near 0
// for onsets with no period — and `credible` is that confidence measured against what
// this many onsets would score with no beat at all: quantizing an incredible grid
// invents a beat rather than finding one.
struct Grid {
    double step_seconds = 0.25;
    double phase_seconds = 0.0;
    double tempo = 120.0;
    double confidence = 0.0;
    bool credible = false;
};

// Same-pitch notes separated by less than `gap_ms` of silence become one note. The
// amplitude is the duration-weighted mean, because the join is claiming the note never
// stopped, not that it restarted louder.
std::vector<Note> merge_gaps(std::vector<Note> notes, double gap_ms);

// Onsets within `window_ms` of the first note of their cluster are one strike: every
// note in the cluster gets the cluster's amplitude-weighted mean onset. Ends stay
// where they were heard. The window is anchored to the cluster's first onset rather
// than chained note-to-note, so a run of onsets 30 ms apart cannot smear into one.
std::vector<Note> snap_chords(std::vector<Note> notes, double window_ms);

// Finds the grid the onsets were played against. Each onset becomes an angle around a
// candidate step period; the period whose amplitude-weighted resultant is longest wins,
// and the resultant's own angle is the phase. `forced_tempo` > 0 skips the tempo search
// and finds only the phase of that tempo's grid — for when the user knows the song.
//
// The search covers steps implying 55 to 185 bpm at the given division. A grid twice
// as fine as the truth scores identically (every onset on the coarse grid is on the
// fine one), which the tempo range mostly excludes; where both halves fit the range,
// the finer grid wins ties, which errs toward moving notes less.
Grid detect_grid(const std::vector<Note>& notes, int division, double forced_tempo);

// Pulls each onset toward its nearest grid line by `strength` (0 none, 1 exactly on),
// rounds durations to whole steps (never below one), and shifts everything so the grid
// starts at zero — a quantized file then opens on-grid in any editor. Notes come back
// sorted by start.
std::vector<Note> quantize_to_grid(std::vector<Note> notes, const Grid& grid,
                                   double strength);

}  // namespace transcribe
