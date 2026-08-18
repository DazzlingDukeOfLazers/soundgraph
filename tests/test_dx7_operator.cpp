// The middle of the pyramid: one dx7_operator alone, driven and measured.
//
// The primitives below it each have a jig in test_nodes, and the assembled voice
// above it is held to the msfa oracle across every vendored bank — but the oracle's
// comparator is deliberately coarse (a shared fundamental and actual presence), so a
// wiring mistake inside the operator could pass it while being audibly wrong. This
// harness closes that gap: it takes the operator definition from the shipped import
// itself — never a hand copy, which would drift — mounts a single instance between a
// keyboard and the speakers, and asserts the things its five nodes are supposed to
// compose into.
#include <cmath>
#include <string>
#include <vector>

#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"
#include "node_harness.h"
#include "test_support.h"

using soundgraph::Diagnostic;
using soundgraph::GraphDescription;

namespace {

constexpr int kSampleRate = 48000;
const std::string kAlgoPatch =
    std::string(SOUNDGRAPH_EXAMPLES_DIR) + "/patches/dx7/algo-01.json";

// A parameter override on the single operator instance, by export name.
struct Setting {
    std::string name;
    double value = 0.0;
};

// The harness patch: keyboard -> one operator -> speakers, with an optional sine
// modulator into one of the operator's modulation inlets. The operator definition
// is lifted from the shipped algo file so this tests what players actually get.
bool operator_patch(const std::vector<Setting>& settings, const std::string& modulate,
                    GraphDescription& out) {
    GraphDescription shipped;
    std::vector<Diagnostic> diagnostics;
    if (!soundgraph::load_patch(kAlgoPatch, shipped, diagnostics)) {
        return false;
    }
    const soundgraph::ModuleDescription* definition = shipped.find_module("dx7_operator");
    if (definition == nullptr) {
        return false;
    }

    GraphDescription harness;
    harness.schema_version = 2;
    harness.modules.push_back(*definition);

    soundgraph::NodeDescription keyboard;
    keyboard.id = "kb";
    keyboard.type = "NoteInput";
    harness.nodes.push_back(keyboard);

    soundgraph::NodeDescription op;
    op.id = "op";
    op.type = "module";
    op.module = "dx7_operator";
    for (const Setting& setting : settings) {
        op.parameters.push_back({setting.name, setting.value});
    }
    harness.nodes.push_back(op);

    soundgraph::NodeDescription speakers;
    speakers.id = "out";
    speakers.type = "StereoOutput";
    harness.nodes.push_back(speakers);

    auto wire = [&harness](const std::string& from_node, const std::string& from_port,
                           const std::string& to_node, const std::string& to_port) {
        soundgraph::ConnectionDescription connection;
        connection.from_node = from_node;
        connection.from_port = from_port;
        connection.to_node = to_node;
        connection.to_port = to_port;
        harness.connections.push_back(connection);
    };
    wire("kb", "frequency", "op", "note");
    wire("kb", "gate", "op", "gate");
    wire("op", "out", "out", "left");

    if (!modulate.empty()) {
        soundgraph::NodeDescription modulator;
        modulator.id = "mod";
        modulator.type = "SineOscillator";
        modulator.parameters.push_back({"frequency", 110.0});
        harness.nodes.push_back(modulator);
        soundgraph::NodeDescription depth;
        depth.id = "depth";
        depth.type = "Gain";
        depth.parameters.push_back({"gain", 2.0});
        harness.nodes.push_back(depth);
        wire("mod", "out", "depth", "in");
        wire("depth", "out", "op", modulate);
    }

    // Through the text and back, because expansion lives in the loader: a
    // description assembled by hand has instances, and the graph builds atoms.
    const std::string text = soundgraph::write_patch(harness, true);
    diagnostics.clear();
    return soundgraph::parse_patch(text, out, diagnostics);
}

// Renders one held note, released at `off_at` seconds when that is positive.
std::vector<float> render(const GraphDescription& description, double seconds,
                          double off_at, bool& ok) {
    ok = false;
    soundgraph::PrepareContext context;
    context.sample_rate = kSampleRate;
    std::vector<Diagnostic> diagnostics;
    soundgraph::Graph graph;
    GraphDescription copy = description;
    if (!graph.build(copy, soundgraph::NodeRegistry::builtin(), context, diagnostics)) {
        return {};
    }
    const int frames = static_cast<int>(seconds * kSampleRate);
    const int off_frame = off_at > 0.0 ? static_cast<int>(off_at * kSampleRate) : -1;
    std::vector<float> output(static_cast<std::size_t>(frames), 0.0f);
    graph.note_on(57, 1.0f);  // A3: 220 Hz, so crossings are easy to count.
    int position = 0;
    bool released = false;
    while (position < frames) {
        const int step = std::min(soundgraph::kBlockSize, frames - position);
        if (!released && off_frame >= 0 && position >= off_frame) {
            graph.note_off(57);
            released = true;
        }
        graph.render(output.data() + position, nullptr, step);
        position += step;
    }
    ok = true;
    return output;
}

double rms(const std::vector<float>& samples, double from_seconds, double to_seconds) {
    const std::size_t from = static_cast<std::size_t>(from_seconds * kSampleRate);
    const std::size_t to = std::min(samples.size(),
                                    static_cast<std::size_t>(to_seconds * kSampleRate));
    if (to <= from) {
        return 0.0;
    }
    double sum = 0.0;
    for (std::size_t i = from; i < to; ++i) {
        sum += static_cast<double>(samples[i]) * samples[i];
    }
    return std::sqrt(sum / static_cast<double>(to - from));
}

// How self-similar the steady half is one period of `frequency` later. Near 1
// for anything periodic at that rate, however jagged the wave — which is why the
// feedback test uses this and not zero crossings (feedback adds crossings).
double periodicity_at(const std::vector<float>& samples, double frequency) {
    const std::size_t lag = static_cast<std::size_t>(kSampleRate / frequency + 0.5);
    const std::size_t from = samples.size() / 2;
    double dot = 0.0;
    double norm_a = 0.0;
    double norm_b = 0.0;
    for (std::size_t i = from; i + lag < samples.size(); ++i) {
        const double a = samples[i];
        const double b = samples[i + lag];
        dot += a * b;
        norm_a += a * a;
        norm_b += b * b;
    }
    const double norm = std::sqrt(norm_a * norm_b);
    return norm > 0.0 ? dot / norm : 0.0;
}

// The fundamental over the steady half of the note, from rising zero crossings.
double fundamental(const std::vector<float>& samples) {
    const std::size_t from = samples.size() / 2;
    std::vector<float> steady(samples.begin() + static_cast<long long>(from),
                              samples.end());
    const int crossings = testing::rising_zero_crossings(steady);
    const double seconds = static_cast<double>(steady.size()) / kSampleRate;
    return static_cast<double>(crossings) / seconds;
}

}  // namespace

TEST(the_operator_pitches_at_ratio_times_the_note) {
    for (double ratio : {1.0, 2.0}) {
        GraphDescription description;
        CHECK(operator_patch({{"ratio", ratio}, {"attack", 0.005}, {"sustain", 1.0}},
                             "", description));
        bool ok = false;
        std::vector<float> heard = render(description, 1.0, -1.0, ok);
        CHECK(ok);
        const double pitch = fundamental(heard);
        const double wanted = 220.0 * ratio;
        CHECK_MESSAGE(std::fabs(pitch - wanted) < wanted * 0.03,
                      "ratio " + std::to_string(ratio) + " pitched at " +
                          std::to_string(pitch) + ", wanted ~" + std::to_string(wanted));
    }
}

TEST(the_envelope_shapes_the_note) {
    GraphDescription description;
    CHECK(operator_patch({{"ratio", 1.0}, {"attack", 0.2}, {"decay", 0.05},
                          {"sustain", 1.0}, {"release", 0.05}},
                         "", description));
    bool ok = false;
    std::vector<float> heard = render(description, 1.0, 0.6, ok);
    CHECK(ok);
    // A 200ms attack: the first 50ms is the foot of the ramp, 300-500ms the plateau.
    const double foot = rms(heard, 0.0, 0.05);
    const double plateau = rms(heard, 0.3, 0.5);
    CHECK_MESSAGE(plateau > 0.05, "the held note is audible (" + std::to_string(plateau) + ")");
    CHECK_MESSAGE(foot < plateau * 0.5,
                  "the attack ramps rather than steps (" + std::to_string(foot) + " vs " +
                      std::to_string(plateau) + ")");
    // Released at 0.6s with a 50ms release: by 0.8s the note is gone.
    const double tail = rms(heard, 0.8, 1.0);
    CHECK_MESSAGE(tail < plateau * 0.05,
                  "the release lets go (" + std::to_string(tail) + " vs " +
                      std::to_string(plateau) + ")");
}

TEST(the_pm_inlet_bends_the_phase) {
    GraphDescription clean_patch;
    GraphDescription bent_patch;
    CHECK(operator_patch({{"ratio", 1.0}, {"attack", 0.005}, {"sustain", 1.0}},
                         "", clean_patch));
    CHECK(operator_patch({{"ratio", 1.0}, {"attack", 0.005}, {"sustain", 1.0}},
                         "pm", bent_patch));
    bool ok = false;
    std::vector<float> clean = render(clean_patch, 1.0, -1.0, ok);
    CHECK(ok);
    std::vector<float> bent = render(bent_patch, 1.0, -1.0, ok);
    CHECK(ok);
    double worst = 0.0;
    double loudest = 0.0;
    for (std::size_t i = clean.size() / 2; i < clean.size(); ++i) {
        worst = std::max(worst, std::fabs(static_cast<double>(clean[i]) - bent[i]));
        loudest = std::max(loudest, std::fabs(static_cast<double>(bent[i])));
    }
    CHECK_MESSAGE(worst > 0.05,
                  "phase modulation changes the wave (" + std::to_string(worst) + ")");
    CHECK_MESSAGE(loudest < 1.5,
                  "and stays bounded (" + std::to_string(loudest) + ")");
}

TEST(feedback_thickens_the_wave_without_moving_the_pitch) {
    GraphDescription plain_patch;
    GraphDescription fed_patch;
    CHECK(operator_patch({{"ratio", 1.0}, {"attack", 0.005}, {"sustain", 1.0},
                          {"feedback", 0.0}},
                         "", plain_patch));
    // Shipped voices sit near 0.06; 0.15 is a hard but still-musical drive.
    // (Much past that the operator goes noise-like, faithfully to the DX7.)
    CHECK(operator_patch({{"ratio", 1.0}, {"attack", 0.005}, {"sustain", 1.0},
                          {"feedback", 0.15}},
                         "", fed_patch));
    bool ok = false;
    std::vector<float> plain = render(plain_patch, 1.0, -1.0, ok);
    CHECK(ok);
    std::vector<float> fed = render(fed_patch, 1.0, -1.0, ok);
    CHECK(ok);
    double worst = 0.0;
    for (std::size_t i = plain.size() / 2; i < plain.size(); ++i) {
        worst = std::max(worst, std::fabs(static_cast<double>(plain[i]) - fed[i]));
    }
    CHECK_MESSAGE(worst > 0.05,
                  "feedback changes the wave (" + std::to_string(worst) + ")");
    // Feedback corrugates the wave with extra zero crossings, so hold the pitch
    // by self-similarity one 220 Hz period apart rather than by crossing count.
    const double still_periodic = periodicity_at(fed, 220.0);
    CHECK_MESSAGE(still_periodic > 0.95,
                  "without moving the fundamental (periodicity " +
                      std::to_string(still_periodic) + ")");
}

TEST_MAIN("dx7 operator harness")
