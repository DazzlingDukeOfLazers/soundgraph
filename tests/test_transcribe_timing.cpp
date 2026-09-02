// The transcriber's timing repairs, measured on notes whose truth is constructed.
//
// Everything here is arithmetic from tools/sg-transcribe/timing.cpp — no model, no
// audio — so the grid detector is asked about onsets laid down at a known tempo with
// known jitter, and "found the beat" means found *that* beat, not "returned a number".
#include <cmath>
#include <cstdint>
#include <vector>

#include "test_support.h"
#include "timing.h"

using transcribe::Grid;
using transcribe::Note;

namespace {

Note note_at(double start, double length, int pitch, double amplitude = 0.7) {
    Note note;
    note.start_seconds = start;
    note.end_seconds = start + length;
    note.pitch = pitch;
    note.amplitude = amplitude;
    return note;
}

// Deterministic jitter, so a failure reproduces. Uniform in [-half, half).
struct Lcg {
    uint32_t state = 12345;
    double next(double half) {
        state = state * 1664525u + 1013904223u;
        return (static_cast<double>(state) / 4294967296.0 - 0.5) * 2.0 * half;
    }
};

// A melody played against a real grid: `count` onsets on lines of `step`, offset by
// `phase`, each smeared by up to `jitter` — the shape of what the model reports.
std::vector<Note> played_against(double step, double phase, double jitter, int count) {
    Lcg random;
    std::vector<Note> notes;
    for (int k = 0; k < count; ++k) {
        if (k % 7 == 3) continue;  // rests, so the grid is not a metronome
        notes.push_back(note_at(phase + k * step + random.next(jitter),
                                step * 0.8, 48 + k % 24, 0.4 + 0.4 * (k % 3) / 2.0));
    }
    return notes;
}

}  // namespace

TEST(a_split_note_heals_and_a_real_rest_does_not) {
    std::vector<Note> notes;
    notes.push_back(note_at(1.0, 0.5, 60, 0.8));    // ends 1.5
    notes.push_back(note_at(1.53, 0.47, 60, 0.4));  // 30 ms later: the same note
    notes.push_back(note_at(2.5, 0.2, 60));         // 500 ms later: a new one
    notes.push_back(note_at(1.52, 0.5, 64));        // another pitch is never merged

    const std::vector<Note> merged = transcribe::merge_gaps(notes, 50.0);
    CHECK(merged.size() == 3);

    int sixties = 0;
    for (const Note& note : merged) {
        if (note.pitch != 60 || note.start_seconds > 2.0) continue;
        ++sixties;
        CHECK_NEAR(note.start_seconds, 1.0, 1e-9);
        CHECK_NEAR(note.end_seconds, 2.0, 1e-9);
        // Duration-weighted amplitude: (0.8 * 0.5 + 0.4 * 0.47) / 0.97.
        CHECK_NEAR(note.amplitude, 0.6062, 0.001);
    }
    CHECK(sixties == 1);
}

TEST(a_staggered_chord_becomes_one_strike) {
    std::vector<Note> notes;
    notes.push_back(note_at(1.000, 0.5, 60));
    notes.push_back(note_at(1.020, 0.5, 64));
    notes.push_back(note_at(1.035, 0.5, 67));
    notes.push_back(note_at(1.200, 0.5, 72));  // outside the window: its own event

    const std::vector<Note> snapped = transcribe::snap_chords(notes, 40.0);
    CHECK_NEAR(snapped[0].start_seconds, 1.0183, 0.0005);
    CHECK_NEAR(snapped[1].start_seconds, snapped[0].start_seconds, 1e-9);
    CHECK_NEAR(snapped[2].start_seconds, snapped[0].start_seconds, 1e-9);
    CHECK_NEAR(snapped[3].start_seconds, 1.200, 1e-9);
}

TEST(the_window_anchors_to_the_first_onset_rather_than_chaining) {
    // Onsets every 30 ms. Chained, a 40 ms window would smear all four into one;
    // anchored, they pair off.
    std::vector<Note> notes;
    for (int i = 0; i < 4; ++i) notes.push_back(note_at(1.0 + 0.03 * i, 0.2, 60 + i));

    const std::vector<Note> snapped = transcribe::snap_chords(notes, 40.0);
    CHECK_NEAR(snapped[0].start_seconds, snapped[1].start_seconds, 1e-9);
    CHECK_NEAR(snapped[2].start_seconds, snapped[3].start_seconds, 1e-9);
    CHECK(snapped[2].start_seconds - snapped[0].start_seconds > 0.02);
}

TEST(the_beat_is_found_under_jitter) {
    // 100 bpm at sixteenths: a 150 ms step, offset 0.33 s — deliberately not a
    // multiple of the step — and ±20 ms of jitter.
    const std::vector<Note> notes = played_against(0.15, 0.33, 0.02, 64);
    const Grid grid = transcribe::detect_grid(notes, 4, -1.0);

    CHECK_NEAR(grid.tempo, 100.0, 1.0);
    CHECK(grid.confidence > 0.6);
    CHECK(grid.credible);
    // The phase is only meaningful modulo the step.
    const double phase_error = std::fabs(
        std::remainder(grid.phase_seconds - 0.33, grid.step_seconds));
    CHECK_MESSAGE(phase_error < 0.015,
                  "phase " + std::to_string(grid.phase_seconds));
}

TEST(a_named_tempo_skips_the_search_but_still_finds_the_phase) {
    const std::vector<Note> notes = played_against(0.15, 0.33, 0.02, 64);
    const Grid grid = transcribe::detect_grid(notes, 4, 100.0);

    CHECK_NEAR(grid.step_seconds, 0.15, 1e-9);
    CHECK_NEAR(grid.tempo, 100.0, 1e-9);
    CHECK(grid.confidence > 0.6);
    CHECK(grid.credible);
    const double phase_error = std::fabs(
        std::remainder(grid.phase_seconds - 0.33, grid.step_seconds));
    CHECK(phase_error < 0.015);
}

TEST(aperiodic_onsets_earn_no_credibility) {
    // Two hundred onsets with no period at all. The sweep takes a maximum over
    // hundreds of candidate periods, so noise scores more than naive chance — the
    // credibility floor must price that in, or main() would quantize noise to an
    // invented beat.
    Lcg random;
    std::vector<Note> notes;
    for (int i = 0; i < 200; ++i) {
        notes.push_back(note_at(15.0 + random.next(15.0), 0.2, 40 + i % 40));
    }
    const Grid grid = transcribe::detect_grid(notes, 4, -1.0);
    CHECK_MESSAGE(!grid.credible,
                  "confidence " + std::to_string(grid.confidence));
}

TEST(full_strength_lands_exactly_on_the_grid) {
    const std::vector<Note> notes = played_against(0.15, 0.33, 0.02, 64);
    const Grid grid = transcribe::detect_grid(notes, 4, 100.0);
    const std::vector<Note> quantized = transcribe::quantize_to_grid(notes, grid, 1.0);

    CHECK(quantized.size() == notes.size());
    for (const Note& note : quantized) {
        const double start_offset = std::fabs(
            std::remainder(note.start_seconds, grid.step_seconds));
        CHECK_MESSAGE(start_offset < 1e-6,
                      "start " + std::to_string(note.start_seconds));
        const double length = note.end_seconds - note.start_seconds;
        CHECK(length >= grid.step_seconds - 1e-9);
        const double length_offset = std::fabs(
            std::remainder(length, grid.step_seconds));
        CHECK_MESSAGE(length_offset < 1e-6, "length " + std::to_string(length));
    }
}

TEST(zero_strength_changes_nothing) {
    const std::vector<Note> notes = played_against(0.15, 0.33, 0.02, 32);
    const Grid grid = transcribe::detect_grid(notes, 4, -1.0);
    const std::vector<Note> untouched = transcribe::quantize_to_grid(notes, grid, 0.0);

    CHECK(untouched.size() == notes.size());
    for (size_t i = 0; i < notes.size(); ++i) {
        CHECK_NEAR(untouched[i].start_seconds, notes[i].start_seconds, 1e-12);
        CHECK_NEAR(untouched[i].end_seconds, notes[i].end_seconds, 1e-12);
    }
}

TEST(half_strength_goes_halfway) {
    std::vector<Note> notes;
    notes.push_back(note_at(1.04, 0.25, 60));  // 40 ms late of the line at 1.0

    Grid grid;
    grid.step_seconds = 0.25;
    grid.phase_seconds = 0.0;
    const std::vector<Note> halved = transcribe::quantize_to_grid(notes, grid, 0.5);
    CHECK_NEAR(halved[0].start_seconds, 1.02, 1e-9);
}

TEST_MAIN("test_transcribe_timing")
