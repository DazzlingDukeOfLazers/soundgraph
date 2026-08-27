// sg-transcribe — a recording becomes notes.
//
//   sg-transcribe hummed.wav
//   sg-transcribe hummed.wav --patch first-synth.json --tempo 96
//
// Always a MIDI file; a patch's piano roll as well, on request. The model is Spotify's
// Basic Pitch (Apache-2.0, model/LICENSE); everything around it is here.
//
// This replaced a Python tool that did the same job through TensorFlow at 1831 MB
// installed. The model was never the heavy part - it is 230 KB - and this is what was
// underneath once the training framework was taken away.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "soundgraph/patch_io.h"
#include "wav.h"

#include "basic_pitch.h"
#include "midi_write.h"
#include "resample.h"

namespace {

void usage() {
    std::printf(
        "usage: sg-transcribe <audio.wav> [options]\n"
        "\n"
        "options:\n"
        "  --midi <file>      where to write the MIDI (default: beside the audio)\n"
        "  --patch <file>     a patch to write the transcription into as its roll\n"
        "  --out <file>       write the patch here instead of over the original\n"
        "  --model <file>     the ONNX model (default: beside the executable)\n"
        "  --tempo N          beats per minute the roll is laid against (default 120)\n"
        "  --division N       steps per beat: 1, 2, 4, 8 or 16 (default 4)\n"
        "  --onset N          0..1, raise it when noise is heard as notes (0.5)\n"
        "  --frame N          0..1, note confidence threshold (0.3)\n"
        "  --min-ms N         drop notes shorter than this (127.7)\n"
        "  --min-pitch N      ignore notes below this MIDI number\n"
        "  --max-pitch N      ignore notes above this MIDI number\n"
        "  --no-melodia       skip the sustained-energy pass\n"
        "  --no-infer-onsets  trust the onset head alone\n"
        "  --dump <file>      write raw activations, for comparing against the Python\n"
        "  --quiet            print nothing but errors\n");
}

// The roll's own ceiling, from editor-godot/piano_roll.gd.
constexpr int kMaxSteps = 2048;

std::string directory_of(const std::string& path) {
    const size_t cut = path.find_last_of("/\\");
    return cut == std::string::npos ? std::string(".") : path.substr(0, cut);
}

bool matches(const char* argument, const char* name) {
    return std::strcmp(argument, name) == 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        usage();
        return 1;
    }

    std::string audio_path = argv[1];
    if (audio_path == "--help" || audio_path == "-h") {
        usage();
        return 0;
    }

    std::string midi_path, patch_path, out_path, model_path, dump_path;
    double tempo = 120.0;
    int division = 4;
    bool quiet = false;
    transcribe::Options options;

    for (int i = 2; i < argc; ++i) {
        const bool has_value = i + 1 < argc;
        if (matches(argv[i], "--midi") && has_value) midi_path = argv[++i];
        else if (matches(argv[i], "--patch") && has_value) patch_path = argv[++i];
        else if (matches(argv[i], "--out") && has_value) out_path = argv[++i];
        else if (matches(argv[i], "--model") && has_value) model_path = argv[++i];
        else if (matches(argv[i], "--dump") && has_value) dump_path = argv[++i];
        else if (matches(argv[i], "--tempo") && has_value) tempo = std::atof(argv[++i]);
        else if (matches(argv[i], "--division") && has_value) division = std::atoi(argv[++i]);
        else if (matches(argv[i], "--onset") && has_value) options.onset_threshold = std::atof(argv[++i]);
        else if (matches(argv[i], "--frame") && has_value) options.frame_threshold = std::atof(argv[++i]);
        else if (matches(argv[i], "--min-ms") && has_value) options.minimum_note_length_ms = std::atof(argv[++i]);
        else if (matches(argv[i], "--min-pitch") && has_value) options.minimum_pitch = std::atoi(argv[++i]);
        else if (matches(argv[i], "--max-pitch") && has_value) options.maximum_pitch = std::atoi(argv[++i]);
        else if (matches(argv[i], "--no-melodia")) options.melodia_trick = false;
        else if (matches(argv[i], "--no-infer-onsets")) options.infer_onsets = false;
        else if (matches(argv[i], "--quiet")) quiet = true;
        else {
            std::fprintf(stderr, "unknown option: %s\n", argv[i]);
            return 1;
        }
    }

    if (tempo < 20.0 || tempo > 400.0) {
        std::fprintf(stderr, "tempo out of range: %f\n", tempo);
        return 1;
    }
    if (division != 1 && division != 2 && division != 4 && division != 8 && division != 16) {
        std::fprintf(stderr, "division must be 1, 2, 4, 8 or 16\n");
        return 1;
    }

    // ---- the audio ---------------------------------------------------------------
    soundgraph::AudioFile file;
    std::string error;
    if (!soundgraph::read_wav(audio_path, file, error)) {
        std::fprintf(stderr, "%s\n", error.c_str());
        return 1;
    }

    // Mono, because that is what the model takes. Averaged rather than left-only: a
    // hard-panned part would otherwise vanish.
    std::vector<float> mono;
    mono.reserve(static_cast<size_t>(file.frames()));
    for (int f = 0; f < file.frames(); ++f) {
        double sum = 0.0;
        for (int c = 0; c < file.channels; ++c) {
            sum += file.samples[static_cast<size_t>(f) * file.channels + c];
        }
        mono.push_back(static_cast<float>(sum / std::max(1, file.channels)));
    }

    const double seconds = static_cast<double>(mono.size()) / file.sample_rate;
    if (!quiet) std::printf("listening to %s (%.1f s at %d Hz)\n", audio_path.c_str(), seconds,
        file.sample_rate);

    std::vector<float> at_model_rate =
        transcribe::resample(mono, file.sample_rate, transcribe::kSampleRate);
    if (at_model_rate.empty()) {
        std::fprintf(stderr, "there was no audio in that file\n");
        return 1;
    }

    // ---- the model ---------------------------------------------------------------
    if (model_path.empty()) {
        model_path = directory_of(argv[0]) + "/nmp.onnx";
    }
    transcribe::Model model;
    if (!model.load(model_path, error)) {
        std::fprintf(stderr, "%s\n", error.c_str());
        std::fprintf(stderr, "looked for the model at %s; --model points elsewhere\n",
                     model_path.c_str());
        return 1;
    }

    transcribe::Activations activations;
    if (!model.run(at_model_rate, activations, error)) {
        std::fprintf(stderr, "%s\n", error.c_str());
        return 1;
    }

    if (!dump_path.empty()) {
        // Raw activations, so the C++ and the Python can be compared on the model's own
        // numbers rather than on the notes downstream of them. Whichever of the two
        // disagrees, this says whether it happened before or after note-picking.
        std::FILE* handle = std::fopen(dump_path.c_str(), "wb");
        if (handle != nullptr) {
            const int frames = activations.frames;
            std::fwrite(&frames, sizeof(int), 1, handle);
            std::fwrite(activations.note.data(), sizeof(float), activations.note.size(), handle);
            std::fwrite(activations.onset.data(), sizeof(float), activations.onset.size(), handle);
            std::fclose(handle);
            if (!quiet) std::printf("  dumped %d frames of activations to %s\n", frames, dump_path.c_str());
        }
    }

    const std::vector<transcribe::Note> notes =
        transcribe::notes_from_activations(activations, options);

    // ---- the MIDI file, always ----------------------------------------------------
    if (midi_path.empty()) {
        const size_t dot = audio_path.find_last_of('.');
        midi_path = (dot == std::string::npos ? audio_path : audio_path.substr(0, dot)) + ".mid";
    }
    if (!transcribe::write_midi(midi_path, notes, tempo, error)) {
        std::fprintf(stderr, "%s\n", error.c_str());
        return 1;
    }
    if (!quiet) std::printf("wrote %s\n", midi_path.c_str());

    if (notes.empty()) {
        if (!quiet) std::printf("  no notes found - try a lower --onset\n");
        return 0;
    }

    int lowest = 127, highest = 0;
    double last = 0.0;
    for (const transcribe::Note& note : notes) {
        lowest = std::min(lowest, note.pitch);
        highest = std::max(highest, note.pitch);
        last = std::max(last, note.end_seconds);
    }
    if (!quiet) std::printf("  %d notes over %.1f s, from %d to %d\n", static_cast<int>(notes.size()), last,
        lowest, highest);

    // ---- the roll, on request -----------------------------------------------------
    if (!patch_path.empty()) {
        soundgraph::GraphDescription patch;
        std::vector<soundgraph::Diagnostic> diagnostics;
        if (!soundgraph::load_patch(patch_path, patch, diagnostics)) {
            std::fprintf(stderr, "could not read %s\n", patch_path.c_str());
            return 1;
        }

        const double step_seconds = 60.0 / tempo / division;
        patch.sequence.notes.clear();
        patch.sequence.tempo = tempo;
        patch.sequence.division = division;

        int dropped = 0;
        int furthest = 0;
        for (const transcribe::Note& note : notes) {
            soundgraph::SequenceNote laid;
            laid.step = static_cast<int>(std::lround(note.start_seconds / step_seconds));
            laid.note = note.pitch;
            laid.length = std::max(1, static_cast<int>(std::lround(
                (note.end_seconds - note.start_seconds) / step_seconds)));
            if (laid.step < 0 || laid.step + laid.length > kMaxSteps) {
                ++dropped;
                continue;
            }
            furthest = std::max(furthest, laid.step + laid.length);
            patch.sequence.notes.push_back(laid);
        }
        patch.sequence.steps = std::min(std::max(furthest + 4, 8), kMaxSteps);
        patch.has_sequence = true;

        if (dropped > 0) {
            if (!quiet) std::printf("  %d note%s past the roll's %d steps stayed behind\n", dropped,
                dropped == 1 ? "" : "s", kMaxSteps);
        }

        const std::string target = out_path.empty() ? patch_path : out_path;
        const std::string text = soundgraph::write_patch(patch, true);
        std::FILE* handle = std::fopen(target.c_str(), "wb");
        if (handle == nullptr) {
            std::fprintf(stderr, "could not open %s for writing\n", target.c_str());
            return 1;
        }
        std::fwrite(text.data(), 1, text.size(), handle);
        std::fclose(handle);
        if (!quiet) std::printf("wrote the roll into %s - %d notes at 1/%d, %d steps\n", target.c_str(),
            static_cast<int>(patch.sequence.notes.size()), division * 4,
            patch.sequence.steps);
    }

    return 0;
}
