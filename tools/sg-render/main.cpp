// sg-render — render a patch to a WAV file, offline and deterministically.
//
// This is the tool that proves the first milestone: JSON in, sound out, no UI anywhere.
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"
#include "wav.h"

// Real plugins, when this build has the SDKs to load them. Without it a patch naming a
// PluginEffect still renders — the node passes its audio through and the graph says so
// — which is the same thing that happens on the ESP32 and in a browser.
#if defined(SOUNDGRAPH_WITH_PLUGIN_HOST)
#include "desktop_provider.h"
#endif

namespace {

struct Options {
    std::string patch_path;
    std::string output_path;
    double seconds = 3.0;
    int sample_rate = 48000;
    std::vector<int> notes = {60};
    float velocity = 0.9f;
    double gate_fraction = 0.7;
    bool float_output = false;
    bool quiet = false;
};

int print_usage() {
    std::cout <<
        "usage: sg-render <patch.json> <out.wav> [options]\n"
        "\n"
        "options:\n"
        "  --seconds N        length to render (default 3)\n"
        "  --sample-rate N    sample rate (default 48000)\n"
        "  --notes A,B,C      notes to play, spread evenly over the render (default 60)\n"
        "  --velocity N       note velocity, 0 to 1 (default 0.9)\n"
        "  --gate N           fraction of each note's slot that the key is held (default 0.7)\n"
        "  --silent           render without playing any notes\n"
        "  --float            write 32-bit float instead of 16-bit PCM\n"
        "  --quiet            print nothing but errors\n";
    return 2;
}

bool parse_notes(const std::string& text, std::vector<int>& out) {
    out.clear();
    std::string current;
    for (std::size_t i = 0; i <= text.size(); ++i) {
        if (i == text.size() || text[i] == ',') {
            if (current.empty()) {
                return false;
            }
            out.push_back(std::atoi(current.c_str()));
            current.clear();
        } else {
            current.push_back(text[i]);
        }
    }
    return !out.empty();
}

bool parse_options(int argc, char** argv, Options& options) {
    if (argc < 3) {
        return false;
    }
    options.patch_path = argv[1];
    options.output_path = argv[2];

    for (int i = 3; i < argc; ++i) {
        const std::string flag = argv[i];
        const bool has_value = (i + 1) < argc;

        if (flag == "--seconds" && has_value) {
            options.seconds = std::atof(argv[++i]);
        } else if (flag == "--sample-rate" && has_value) {
            options.sample_rate = std::atoi(argv[++i]);
        } else if (flag == "--notes" && has_value) {
            if (!parse_notes(argv[++i], options.notes)) {
                std::cerr << "could not read the note list\n";
                return false;
            }
        } else if (flag == "--velocity" && has_value) {
            options.velocity = static_cast<float>(std::atof(argv[++i]));
        } else if (flag == "--gate" && has_value) {
            options.gate_fraction = std::atof(argv[++i]);
        } else if (flag == "--silent") {
            options.notes.clear();
        } else if (flag == "--float") {
            options.float_output = true;
        } else if (flag == "--quiet") {
            options.quiet = true;
        } else {
            std::cerr << "unknown or incomplete option: " << flag << "\n";
            return false;
        }
    }

    if (options.seconds <= 0.0 || options.sample_rate <= 0) {
        std::cerr << "seconds and sample rate must be positive\n";
        return false;
    }
    return true;
}

// One entry per note change, in frames from the start of the render.
struct NoteAction {
    int frame;
    int note;
    bool on;
};

std::vector<NoteAction> build_note_schedule(const Options& options, int total_frames) {
    std::vector<NoteAction> actions;
    if (options.notes.empty()) {
        return actions;
    }
    const int slot = total_frames / static_cast<int>(options.notes.size());
    const int held = static_cast<int>(slot * options.gate_fraction);
    for (std::size_t i = 0; i < options.notes.size(); ++i) {
        const int start = static_cast<int>(i) * slot;
        actions.push_back(NoteAction{start, options.notes[i], true});
        actions.push_back(NoteAction{start + held, options.notes[i], false});
    }
    return actions;
}

}  // namespace

int main(int argc, char** argv) {
    Options options;
    if (!parse_options(argc, argv, options)) {
        return print_usage();
    }

    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;
    if (!soundgraph::load_patch(options.patch_path, description, diagnostics)) {
        for (const soundgraph::Diagnostic& diagnostic : diagnostics) {
            std::cerr << diagnostic.format() << "\n\n";
        }
        return 1;
    }

    soundgraph::PrepareContext context;
    context.sample_rate = options.sample_rate;

    soundgraph::Graph graph;
#if defined(SOUNDGRAPH_WITH_PLUGIN_HOST)
    // Declared before the graph so that it outlives it: the graph holds instances the
    // provider made, and the nodes hold pointers to those.
    std::unique_ptr<soundgraph::PluginProvider> provider =
        soundgraph::host::make_desktop_plugin_provider();
    graph.set_plugin_provider(provider.get());
#endif
    if (!graph.build(description, soundgraph::NodeRegistry::builtin(), context, diagnostics)) {
        for (const soundgraph::Diagnostic& diagnostic : diagnostics) {
            std::cerr << diagnostic.format() << "\n\n";
        }
        std::cerr << options.patch_path << ": cannot be rendered.\n";
        return 1;
    }
    if (!options.quiet) {
        for (const soundgraph::Diagnostic& diagnostic : diagnostics) {
            std::cout << diagnostic.format() << "\n\n";
        }
    }

    const int total_frames = static_cast<int>(options.seconds * options.sample_rate);
    const std::vector<NoteAction> actions = build_note_schedule(options, total_frames);

    soundgraph::AudioFile audio;
    audio.sample_rate = options.sample_rate;
    audio.channels = 2;
    audio.samples.assign(static_cast<std::size_t>(total_frames) * 2, 0.0f);

    // Render in the internal block size so that note timing lands on the same boundaries
    // it would in a live host.
    std::size_t next_action = 0;
    for (int position = 0; position < total_frames; position += soundgraph::kBlockSize) {
        const int frames = std::min(soundgraph::kBlockSize, total_frames - position);

        while (next_action < actions.size() && actions[next_action].frame < position + frames) {
            const NoteAction& action = actions[next_action];
            if (action.on) {
                graph.note_on(action.note, options.velocity);
            } else {
                graph.note_off(action.note);
            }
            ++next_action;
        }

        graph.render_interleaved(audio.samples.data() + static_cast<std::size_t>(position) * 2, frames);
    }

    float peak = 0.0f;
    double sum_of_squares = 0.0;
    for (float sample : audio.samples) {
        peak = std::max(peak, std::fabs(sample));
        sum_of_squares += static_cast<double>(sample) * sample;
    }
    const double rms = audio.samples.empty()
                           ? 0.0
                           : std::sqrt(sum_of_squares / static_cast<double>(audio.samples.size()));

    std::string error;
    const bool written = options.float_output ? soundgraph::write_wav_float(options.output_path, audio, error)
                                              : soundgraph::write_wav(options.output_path, audio, error);
    if (!written) {
        std::cerr << error << "\n";
        return 1;
    }

    if (!options.quiet) {
        std::cout << "wrote " << options.output_path << "\n"
                  << "  " << options.seconds << " s at " << options.sample_rate << " Hz, stereo\n"
                  << "  peak " << peak << "  rms " << rms << "\n";
        if (peak < 1.0e-6f) {
            std::cout << "\nThis rendered silence. Check that your chain reaches a Stereo Output, "
                         "and that something is driving the envelope.\n";
        }
    }
    return 0;
}
