#include "timing.h"

#include <algorithm>
#include <cmath>

namespace transcribe {
namespace {

constexpr double kPi = 3.14159265358979323846;

// The tempo range the grid search covers. Wide enough for nearly everything with a
// beat; anything outside it is better served by --tempo than by a search that would
// have to break ties between octaves to include it.
constexpr double kMinBpm = 55.0;
constexpr double kMaxBpm = 185.0;

double total_weight(const std::vector<Note>& notes) {
    double sum = 0.0;
    // An amplitude of zero would make a note invisible to the search while it still
    // sounds in the file, so silence-weight is lifted to a floor instead.
    for (const Note& note : notes) sum += std::max(0.05, note.amplitude);
    return sum;
}

// The amplitude-weighted resultant of the onsets read as angles around `period`:
// |R| in [0, 1] says how well the onsets agree on a grid of that period, and arg(R)
// says where its lines fall.
void resultant(const std::vector<Note>& notes, double period,
               double& length, double& angle) {
    double x = 0.0, y = 0.0;
    for (const Note& note : notes) {
        const double weight = std::max(0.05, note.amplitude);
        const double theta = 2.0 * kPi * note.start_seconds / period;
        x += weight * std::cos(theta);
        y += weight * std::sin(theta);
    }
    const double total = total_weight(notes);
    length = total > 0.0 ? std::sqrt(x * x + y * y) / total : 0.0;
    angle = std::atan2(y, x);
}

// The smallest-magnitude representative, in [-period/2, period/2). The grid it names
// is the same whichever representative is chosen, but quantize_to_grid shifts the file
// by this value — and a mean onset offset of minus five milliseconds must shift by
// five milliseconds, not by period-minus-five, which would drag every note nearly a
// whole step early. That exact mistake produced rolls one step off the grid.
double phase_from_angle(double angle, double period) {
    double phase = angle / (2.0 * kPi) * period;
    phase = std::fmod(phase, period);
    if (phase < -period / 2.0) phase += period;
    if (phase >= period / 2.0) phase -= period;
    return phase;
}

// The confidence a set of onsets with no beat at all would still score. |R| for
// random angles concentrates near sqrt(pi/4)/sqrt(n) with n the effective onset
// count, and the tempo search takes a maximum over hundreds of candidates, which
// inflates what noise can reach. `sweep_factor` prices that in: 4 when the period
// was searched for, 2 when the user named it and there was only one candidate.
double credibility_floor(const std::vector<Note>& notes, double sweep_factor) {
    double sum = 0.0, squares = 0.0;
    for (const Note& note : notes) {
        const double weight = std::max(0.05, note.amplitude);
        sum += weight;
        squares += weight * weight;
    }
    const double effective = squares > 0.0 ? sum * sum / squares : 1.0;
    return std::max(0.2, sweep_factor * 0.886 / std::sqrt(effective));
}

}  // namespace

std::vector<Note> merge_gaps(std::vector<Note> notes, double gap_ms) {
    if (gap_ms <= 0.0 || notes.size() < 2) return notes;
    const double gap_seconds = gap_ms / 1000.0;

    std::sort(notes.begin(), notes.end(), [](const Note& a, const Note& b) {
        if (a.pitch != b.pitch) return a.pitch < b.pitch;
        return a.start_seconds < b.start_seconds;
    });

    std::vector<Note> merged;
    merged.reserve(notes.size());
    for (const Note& note : notes) {
        if (!merged.empty() && merged.back().pitch == note.pitch &&
            note.start_seconds - merged.back().end_seconds < gap_seconds) {
            Note& kept = merged.back();
            const double kept_length = kept.end_seconds - kept.start_seconds;
            const double note_length = note.end_seconds - note.start_seconds;
            const double lengths = std::max(1e-9, kept_length + note_length);
            kept.amplitude = (kept.amplitude * kept_length + note.amplitude * note_length)
                / lengths;
            kept.end_seconds = std::max(kept.end_seconds, note.end_seconds);
        } else {
            merged.push_back(note);
        }
    }

    std::sort(merged.begin(), merged.end(), [](const Note& a, const Note& b) {
        return a.start_seconds < b.start_seconds;
    });
    return merged;
}

std::vector<Note> snap_chords(std::vector<Note> notes, double window_ms) {
    if (window_ms <= 0.0 || notes.size() < 2) return notes;
    const double window_seconds = window_ms / 1000.0;

    std::sort(notes.begin(), notes.end(), [](const Note& a, const Note& b) {
        return a.start_seconds < b.start_seconds;
    });

    size_t begin = 0;
    while (begin < notes.size()) {
        size_t end = begin + 1;
        while (end < notes.size() &&
               notes[end].start_seconds - notes[begin].start_seconds < window_seconds) {
            ++end;
        }

        if (end - begin > 1) {
            double weight = 0.0, sum = 0.0;
            for (size_t i = begin; i < end; ++i) {
                const double w = std::max(0.05, notes[i].amplitude);
                weight += w;
                sum += w * notes[i].start_seconds;
            }
            const double onset = sum / weight;
            for (size_t i = begin; i < end; ++i) {
                notes[i].start_seconds = onset;
                // A note whose whole body sat before the chord's onset would end
                // before starting; audible is the floor.
                notes[i].end_seconds = std::max(notes[i].end_seconds, onset + 0.01);
            }
        }
        begin = end;
    }
    return notes;
}

Grid detect_grid(const std::vector<Note>& notes, int division, double forced_tempo) {
    Grid grid;
    if (notes.empty()) return grid;

    if (forced_tempo > 0.0) {
        grid.tempo = forced_tempo;
        grid.step_seconds = 60.0 / forced_tempo / division;
        double angle = 0.0;
        resultant(notes, grid.step_seconds, grid.confidence, angle);
        grid.phase_seconds = phase_from_angle(angle, grid.step_seconds);
        grid.credible = grid.confidence >= credibility_floor(notes, 2.0);
        return grid;
    }

    const double shortest = 60.0 / kMaxBpm / division;
    const double longest = 60.0 / kMinBpm / division;

    // Coarse sweep at 0.2% resolution, then a fine one around the winner. The score
    // surface is smooth in period — a slightly wrong period fans the angles out
    // gradually — so two sweeps find the peak without a fragile optimizer.
    double best_period = shortest;
    double best_length = -1.0;
    for (double period = shortest; period <= longest; period *= 1.002) {
        double length = 0.0, angle = 0.0;
        resultant(notes, period, length, angle);
        if (length > best_length) {
            best_length = length;
            best_period = period;
        }
    }
    for (double period = best_period * 0.997; period <= best_period * 1.003;
         period *= 1.0001) {
        double length = 0.0, angle = 0.0;
        resultant(notes, period, length, angle);
        if (length > best_length) {
            best_length = length;
            best_period = period;
        }
    }

    double angle = 0.0;
    resultant(notes, best_period, grid.confidence, angle);
    grid.step_seconds = best_period;
    grid.phase_seconds = phase_from_angle(angle, best_period);
    grid.tempo = 60.0 / (best_period * division);
    grid.credible = grid.confidence >= credibility_floor(notes, 4.0);
    return grid;
}

std::vector<Note> quantize_to_grid(std::vector<Note> notes, const Grid& grid,
                                   double strength) {
    if (strength <= 0.0 || grid.step_seconds <= 0.0) return notes;
    const double step = grid.step_seconds;

    for (Note& note : notes) {
        const double lines = std::round((note.start_seconds - grid.phase_seconds) / step);
        const double target = grid.phase_seconds + lines * step;
        const double start = note.start_seconds + strength * (target - note.start_seconds);

        const double length = note.end_seconds - note.start_seconds;
        const double target_length = std::max(step, std::round(length / step) * step);
        const double quantized_length = length + strength * (target_length - length);

        // The grid starts at zero in the file, so a quantized MIDI opens on-grid
        // rather than everything sitting `phase` late of every editor's own lines.
        note.start_seconds = std::max(0.0, start - grid.phase_seconds);
        note.end_seconds = note.start_seconds + quantized_length;
    }

    std::sort(notes.begin(), notes.end(), [](const Note& a, const Note& b) {
        return a.start_seconds < b.start_seconds;
    });
    return notes;
}

}  // namespace transcribe
