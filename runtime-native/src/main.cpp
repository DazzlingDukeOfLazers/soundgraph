// sg-play — play a SoundGraph patch through the machine's audio device.
//
// The whole point of this program is that it contains no DSP. It opens a device, hands
// blocks to the graph, and forwards notes and knob movements. Everything that decides
// what the patch sounds like lives in dsp-core.
#include <atomic>
#include <cmath>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "miniaudio.h"
#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"

namespace {

// A small arpeggiator so that starting the program makes a sound without needing MIDI
// hardware in the room. It runs inside the audio callback, which keeps the graph's
// control queue to a single producer (the terminal thread).
class Sequencer {
public:
    void configure(const std::vector<int>& notes, double bpm, double sample_rate) {
        notes_ = notes;
        samples_per_step_ = static_cast<long long>(sample_rate * 60.0 / bpm);
        gate_samples_ = samples_per_step_ * 3 / 4;
        position_ = 0;
        step_ = 0;
        sounding_ = -1;
    }

    void set_running(bool running) { running_.store(running, std::memory_order_relaxed); }
    bool running() const { return running_.load(std::memory_order_relaxed); }

    // Advances by `frames` and emits whatever note changes fall inside that span.
    void advance(soundgraph::Graph& graph, int frames) {
        if (notes_.empty() || samples_per_step_ <= 0) {
            return;
        }
        if (!running()) {
            if (sounding_ >= 0) {
                send(graph, soundgraph::NoteEvent::Kind::NoteOff, sounding_);
                sounding_ = -1;
            }
            return;
        }

        for (int i = 0; i < frames; ++i) {
            if (position_ == 0) {
                const int note = notes_[static_cast<std::size_t>(step_)];
                if (sounding_ >= 0) {
                    send(graph, soundgraph::NoteEvent::Kind::NoteOff, sounding_);
                }
                send(graph, soundgraph::NoteEvent::Kind::NoteOn, note);
                sounding_ = note;
            } else if (position_ == gate_samples_ && sounding_ >= 0) {
                send(graph, soundgraph::NoteEvent::Kind::NoteOff, sounding_);
                sounding_ = -1;
            }

            if (++position_ >= samples_per_step_) {
                position_ = 0;
                step_ = (step_ + 1) % static_cast<int>(notes_.size());
            }
        }
    }

private:
    static void send(soundgraph::Graph& graph, soundgraph::NoteEvent::Kind kind, int note) {
        soundgraph::NoteEvent event;
        event.kind = kind;
        event.note = note;
        event.velocity = 0.9f;
        graph.dispatch_note(event);
    }

    std::vector<int> notes_;
    long long samples_per_step_ = 0;
    long long gate_samples_ = 0;
    long long position_ = 0;
    int step_ = 0;
    int sounding_ = -1;
    std::atomic<bool> running_{false};
};

struct Host {
    soundgraph::Graph graph;
    Sequencer sequencer;
    std::atomic<float> peak{0.0f};
    // Preallocated so the callback never allocates. The device is asked for far less than
    // this per period; anything beyond it is dropped rather than resized.
    std::vector<float> capture_left = std::vector<float>(8192, 0.0f);
    std::vector<float> capture_right = std::vector<float>(8192, 0.0f);
};

void audio_callback(ma_device* device, void* output, const void* input, ma_uint32 frame_count) {
    Host* host = static_cast<Host*>(device->pUserData);
    float* out = static_cast<float*>(output);
    const int frames = static_cast<int>(frame_count);

    if (input != nullptr) {
        // The device hands over interleaved stereo; the graph works in planar channels.
        const float* captured = static_cast<const float*>(input);
        const int usable = std::min(frames, static_cast<int>(host->capture_left.size()));
        for (int i = 0; i < usable; ++i) {
            host->capture_left[static_cast<std::size_t>(i)] = captured[i * 2];
            host->capture_right[static_cast<std::size_t>(i)] = captured[i * 2 + 1];
        }
        host->graph.set_audio_input(host->capture_left.data(), host->capture_right.data(), usable);
    }

    host->sequencer.advance(host->graph, frames);
    host->graph.render_interleaved(out, frames);

    float peak = 0.0f;
    for (int i = 0; i < frames * 2; ++i) {
        peak = std::max(peak, std::fabs(out[i]));
    }
    host->peak.store(peak, std::memory_order_relaxed);
}

int print_usage() {
    std::cout <<
        "usage: sg-play <patch.json> [options]\n"
        "\n"
        "options:\n"
        "  --sample-rate N    requested sample rate (default: whatever the device prefers)\n"
        "  --notes A,B,C      arpeggio notes as MIDI numbers (default 45,48,52,55)\n"
        "  --bpm N            arpeggio tempo (default 110)\n"
        "  --no-arpeggio      start silent and wait for typed notes\n"
        "  --capture          open the input device too, for patches using Audio Input\n"
        "\n"
        "while running, type:\n"
        "  60                 play MIDI note 60 (any number 0-127)\n"
        "  .                  stop all notes\n"
        "  a                  start or stop the arpeggio\n"
        "  s <node> <param> <value>   change a parameter, e.g. s filter cutoff 3000\n"
        "  ?                  list the patch's control surfaces\n"
        "  q                  quit\n";
    return 2;
}

bool parse_notes(const std::string& text, std::vector<int>& out) {
    out.clear();
    std::stringstream stream(text);
    std::string item;
    while (std::getline(stream, item, ',')) {
        if (item.empty()) {
            return false;
        }
        out.push_back(std::atoi(item.c_str()));
    }
    return !out.empty();
}

void print_controls(const soundgraph::GraphDescription& description) {
    if (description.controls.empty()) {
        std::cout << "this patch declares no control surfaces\n";
        return;
    }
    for (const soundgraph::ControlDescription& control : description.controls) {
        std::cout << "  " << control.target.node << " " << control.target.parameter << "   "
                  << (control.label.empty() ? control.id : control.label);
        if (control.has_range) {
            std::cout << "  (" << control.min_value << " to " << control.max_value << ")";
        }
        std::cout << "\n";
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2 || argv[1][0] == '-') {
        return print_usage();
    }

    const std::string patch_path = argv[1];
    int requested_sample_rate = 0;
    std::vector<int> notes = {45, 48, 52, 55};
    double bpm = 110.0;
    bool arpeggio = true;
    bool capture = false;

    for (int i = 2; i < argc; ++i) {
        const std::string flag = argv[i];
        const bool has_value = (i + 1) < argc;
        if (flag == "--sample-rate" && has_value) {
            requested_sample_rate = std::atoi(argv[++i]);
        } else if (flag == "--notes" && has_value) {
            if (!parse_notes(argv[++i], notes)) {
                return print_usage();
            }
        } else if (flag == "--bpm" && has_value) {
            bpm = std::atof(argv[++i]);
        } else if (flag == "--no-arpeggio") {
            arpeggio = false;
        } else if (flag == "--capture") {
            capture = true;
        } else {
            std::cerr << "unknown or incomplete option: " << flag << "\n";
            return print_usage();
        }
    }

    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;
    if (!soundgraph::load_patch(patch_path, description, diagnostics)) {
        for (const soundgraph::Diagnostic& diagnostic : diagnostics) {
            std::cerr << diagnostic.format() << "\n\n";
        }
        return 1;
    }

    Host host;

    ma_device_config config = ma_device_config_init(capture ? ma_device_type_duplex
                                                            : ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = 2;
    config.capture.format = ma_format_f32;
    config.capture.channels = capture ? 2 : 0;
    config.sampleRate = static_cast<ma_uint32>(requested_sample_rate);
    config.dataCallback = audio_callback;
    config.pUserData = &host;

    ma_device device;
    if (ma_device_init(nullptr, &config, &device) != MA_SUCCESS) {
        std::cerr << "Could not open an audio device.\n";
        return 1;
    }

    // The device decides the real sample rate, so the graph is built against that rather
    // than against whatever was asked for.
    soundgraph::PrepareContext context;
    context.sample_rate = static_cast<double>(device.sampleRate);

    if (!host.graph.build(description, soundgraph::NodeRegistry::builtin(), context, diagnostics)) {
        for (const soundgraph::Diagnostic& diagnostic : diagnostics) {
            std::cerr << diagnostic.format() << "\n\n";
        }
        ma_device_uninit(&device);
        return 1;
    }
    for (const soundgraph::Diagnostic& diagnostic : diagnostics) {
        std::cout << diagnostic.format() << "\n\n";
    }

    host.sequencer.configure(notes, bpm, context.sample_rate);
    host.sequencer.set_running(arpeggio);

    if (ma_device_start(&device) != MA_SUCCESS) {
        std::cerr << "Could not start the audio device.\n";
        ma_device_uninit(&device);
        return 1;
    }

    const std::string patch_name = description.metadata_value("name");
    std::cout << (patch_name.empty() ? patch_path : patch_name) << " is playing.\n"
              << "  device      " << device.playback.name << "\n"
              << "  sample rate " << device.sampleRate << " Hz\n"
              << "  nodes       " << host.graph.node_count() << "\n"
              << "\ntype ? for controls, q to quit.\n\n";

    std::string line;
    int sounding = -1;
    while (std::getline(std::cin, line)) {
        // Trim whitespace and any stray control bytes at either end — a byte-order mark
        // from a piped file should not read as an unrecognised command.
        auto is_padding = [](char character) {
            return static_cast<unsigned char>(character) <= ' ' ||
                   static_cast<unsigned char>(character) >= 0x7F;
        };
        while (!line.empty() && is_padding(line.back())) {
            line.pop_back();
        }
        std::size_t start = 0;
        while (start < line.size() && is_padding(line[start])) {
            ++start;
        }
        line = line.substr(start);
        if (line.empty()) {
            continue;
        }

        if (line == "q" || line == "quit") {
            break;
        }
        if (line == ".") {
            host.graph.all_notes_off();
            sounding = -1;
            continue;
        }
        if (line == "a") {
            host.sequencer.set_running(!host.sequencer.running());
            std::cout << "arpeggio " << (host.sequencer.running() ? "on" : "off") << "\n";
            continue;
        }
        if (line == "?") {
            print_controls(description);
            std::cout << "  peak " << host.peak.load(std::memory_order_relaxed) << "\n";
            continue;
        }
        if (line[0] == 's') {
            std::istringstream stream(line);
            std::string command;
            std::string node;
            std::string parameter;
            double value = 0.0;
            stream >> command >> node >> parameter >> value;
            if (node.empty() || parameter.empty()) {
                std::cout << "usage: s <node> <parameter> <value>\n";
            } else if (host.graph.set_parameter(node, parameter, static_cast<float>(value))) {
                std::cout << node << "." << parameter << " = " << value << "\n";
            } else {
                std::cout << "no parameter '" << parameter << "' on node '" << node << "'\n";
            }
            continue;
        }
        if (line[0] >= '0' && line[0] <= '9') {
            const int note = std::atoi(line.c_str());
            if (note < 0 || note > 127) {
                std::cout << "notes run from 0 to 127\n";
                continue;
            }
            host.sequencer.set_running(false);
            if (sounding >= 0) {
                host.graph.note_off(sounding);
            }
            host.graph.note_on(note, 0.9f);
            sounding = note;
            continue;
        }

        std::cout << "unrecognised command. type ? for controls, q to quit.\n";
    }

    ma_device_uninit(&device);
    std::cout << "stopped.\n";
    return 0;
}
