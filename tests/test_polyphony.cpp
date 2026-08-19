// The voice allocator and the cone replication, measured.
//
// The harness patch is the smallest thing that can prove polyphony: a NoteInput into
// a sine, a Multiply as the VCA so the gate actually silences a released voice, and
// the stereo sink where the voices sum. Presence of a pitch is read with a Goertzel
// probe rather than zero crossings, because the whole point of these tests is that
// several pitches are ringing at once.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "soundgraph/soundgraph.h"
#include "test_support.h"

using soundgraph::Diagnostic;
using soundgraph::GraphDescription;

namespace {

constexpr int kSampleRate = 48000;
constexpr double kA3 = 220.0;
constexpr double kE4 = 329.6276;
constexpr double kC5 = 523.2511;

// keyboard -> sine -> vca(gate) -> out, with the voice count on the keyboard.
GraphDescription harness_patch(int voices) {
    GraphDescription description;
    description.schema_version = 1;

    soundgraph::NodeDescription keyboard;
    keyboard.id = "kb";
    keyboard.type = "NoteInput";
    if (voices > 0) {
        keyboard.parameters.push_back({"voices", static_cast<double>(voices)});
    }
    description.nodes.push_back(keyboard);

    soundgraph::NodeDescription oscillator;
    oscillator.id = "osc";
    oscillator.type = "SineOscillator";
    description.nodes.push_back(oscillator);

    soundgraph::NodeDescription vca;
    vca.id = "vca";
    vca.type = "Multiply";
    description.nodes.push_back(vca);

    soundgraph::NodeDescription amp;
    amp.id = "amp";
    amp.type = "Gain";
    description.nodes.push_back(amp);

    soundgraph::NodeDescription speakers;
    speakers.id = "out";
    speakers.type = "StereoOutput";
    description.nodes.push_back(speakers);

    auto wire = [&description](const char* from_node, const char* from_port,
                               const char* to_node, const char* to_port) {
        soundgraph::ConnectionDescription connection;
        connection.from_node = from_node;
        connection.from_port = from_port;
        connection.to_node = to_node;
        connection.to_port = to_port;
        description.connections.push_back(connection);
    };
    wire("kb", "frequency", "osc", "frequency");
    wire("osc", "out", "vca", "a");
    wire("kb", "gate", "vca", "b");
    wire("vca", "out", "amp", "in");
    wire("amp", "out", "out", "left");
    return description;
}

bool build(soundgraph::Graph& graph, const GraphDescription& description) {
    soundgraph::PrepareContext context;
    context.sample_rate = kSampleRate;
    std::vector<Diagnostic> diagnostics;
    const bool ok = graph.build(description, soundgraph::NodeRegistry::builtin(),
                                context, diagnostics);
    if (!ok) {
        for (const Diagnostic& diagnostic : diagnostics) {
            std::printf("    diagnostic: %s — %s\n", diagnostic.code.c_str(),
                        diagnostic.message.c_str());
        }
    }
    return ok;
}

// Renders the left channel.
std::vector<float> render(soundgraph::Graph& graph, double seconds) {
    const int frames = static_cast<int>(seconds * kSampleRate);
    std::vector<float> left(static_cast<std::size_t>(frames), 0.0f);
    graph.render(left.data(), nullptr, frames);
    return left;
}

// Goertzel energy at one frequency, normalised by window length.
double energy_at(const std::vector<float>& samples, double frequency) {
    const double omega = 2.0 * 3.14159265358979323846 * frequency / kSampleRate;
    const double coefficient = 2.0 * std::cos(omega);
    double previous = 0.0;
    double before_that = 0.0;
    for (float sample : samples) {
        const double current = sample + coefficient * previous - before_that;
        before_that = previous;
        previous = current;
    }
    const double power = previous * previous + before_that * before_that
        - coefficient * previous * before_that;
    return std::sqrt(std::max(0.0, power)) / static_cast<double>(samples.size());
}

std::vector<float> tail(const std::vector<float>& samples) {
    return std::vector<float>(samples.begin() + static_cast<long long>(samples.size() / 2),
                              samples.end());
}

}  // namespace

TEST(one_voice_is_the_same_graph_byte_for_byte) {
    // The identity that guards every mono golden: a patch that says voices 1 and a
    // patch that says nothing render the same samples, to the bit.
    soundgraph::Graph plain;
    soundgraph::Graph counted;
    CHECK(build(plain, harness_patch(0)));
    CHECK(build(counted, harness_patch(1)));
    for (soundgraph::Graph* graph : {&plain, &counted}) {
        graph->note_on(57, 0.9f);
    }
    const std::vector<float> from_plain = render(plain, 0.5);
    const std::vector<float> from_counted = render(counted, 0.5);
    CHECK(from_plain.size() == from_counted.size());
    CHECK_MESSAGE(std::memcmp(from_plain.data(), from_counted.data(),
                              from_plain.size() * sizeof(float)) == 0,
                  "voices=1 renders byte-identically to no voices parameter");
}

TEST(voices_sound_together) {
    soundgraph::Graph graph;
    CHECK(build(graph, harness_patch(4)));
    graph.note_on(57, 0.9f);
    graph.note_on(64, 0.9f);
    const std::vector<float> heard = tail(render(graph, 1.0));
    const double a3 = energy_at(heard, kA3);
    const double e4 = energy_at(heard, kE4);
    const double control = energy_at(heard, 275.0);
    CHECK_MESSAGE(a3 > control * 10.0 && e4 > control * 10.0,
                  "both notes ring at once (A3 " + std::to_string(a3) + ", E4 " +
                      std::to_string(e4) + ", floor " + std::to_string(control) + ")");
}

TEST(mono_still_replaces_the_note) {
    // The control experiment: without voices, the second note replaces the first —
    // NoteInput's last-note priority, untouched.
    soundgraph::Graph graph;
    CHECK(build(graph, harness_patch(0)));
    graph.note_on(57, 0.9f);
    graph.note_on(64, 0.9f);
    const std::vector<float> heard = tail(render(graph, 1.0));
    const double a3 = energy_at(heard, kA3);
    const double e4 = energy_at(heard, kE4);
    CHECK_MESSAGE(e4 > a3 * 10.0,
                  "mono keeps only the last note (A3 " + std::to_string(a3) + ", E4 " +
                      std::to_string(e4) + ")");
}

TEST(stealing_takes_the_longest_held) {
    soundgraph::Graph graph;
    CHECK(build(graph, harness_patch(2)));
    graph.note_on(57, 0.9f);
    graph.note_on(64, 0.9f);
    graph.note_on(72, 0.9f);  // two voices, three notes: A3 is the oldest, and goes
    const std::vector<float> heard = tail(render(graph, 1.0));
    const double a3 = energy_at(heard, kA3);
    const double e4 = energy_at(heard, kE4);
    const double c5 = energy_at(heard, kC5);
    CHECK_MESSAGE(e4 > a3 * 10.0 && c5 > a3 * 10.0,
                  "the newest two notes survive (A3 " + std::to_string(a3) + ", E4 " +
                      std::to_string(e4) + ", C5 " + std::to_string(c5) + ")");
}

TEST(release_finds_its_voice) {
    soundgraph::Graph graph;
    CHECK(build(graph, harness_patch(2)));
    graph.note_on(57, 0.9f);
    graph.note_on(64, 0.9f);
    render(graph, 0.3);
    graph.note_off(57);
    const std::vector<float> after = tail(render(graph, 0.6));
    const double a3 = energy_at(after, kA3);
    const double e4 = energy_at(after, kE4);
    CHECK_MESSAGE(e4 > a3 * 10.0,
                  "letting go of one note leaves the other singing (A3 " +
                      std::to_string(a3) + ", E4 " + std::to_string(e4) + ")");
}

TEST(a_knob_reaches_every_voice) {
    soundgraph::Graph graph;
    CHECK(build(graph, harness_patch(4)));
    graph.note_on(57, 0.9f);
    graph.note_on(64, 0.9f);
    // The amp is inside the cone, so it exists once per voice — and the one knob
    // somebody names must land on all of them.
    CHECK(graph.set_parameter("amp", "gain", 0.0f));
    const std::vector<float> silenced = tail(render(graph, 0.5));
    double loudest = 0.0;
    for (float sample : silenced) {
        loudest = std::max(loudest, static_cast<double>(std::fabs(sample)));
    }
    CHECK_MESSAGE(loudest < 1.0e-4,
                  "zeroing the vca silences every voice (peak " +
                      std::to_string(loudest) + ")");
}

TEST(a_note_router_outside_the_cone_hears_every_note) {
    // A NoteTriggers has no inputs, so it is never downstream of the keyboard, so
    // the replicator never copies it — and the allocator used to park it in voice
    // zero's receiver list, where it heard one note in `voices`. Debugged on a real
    // desk with the probe scope: the drums fired once per eight presses. An
    // unreplicated receiver is one instrument, not a voice's share of one.
    GraphDescription description = harness_patch(4);
    soundgraph::NodeDescription pads;
    pads.id = "pads";
    pads.type = "NoteTriggers";
    description.nodes.push_back(pads);

    soundgraph::Graph graph;
    CHECK(build(graph, description));
    const int pads_index = graph.node_index("pads");
    const int t1 = graph.node_type(pads_index)->find_output("t1");
    CHECK(pads_index >= 0 && t1 >= 0);
    graph.set_tap(0, pads_index, t1, 8192);
    for (int press = 0; press < 4; ++press) {
        graph.note_on(48, 0.9f);
        render(graph, 0.05);
        graph.note_off(48);
        render(graph, 0.05);
    }
    CHECK_MESSAGE(graph.tap_edges(0) == 4,
                  "four presses through four voices are four pad triggers (" +
                      std::to_string(graph.tap_edges(0)) + ")");
}

TEST(a_poly_graph_rebuilds_cleanly) {
    // The replication is build-local: building twice from the same description must
    // not compound voices or leak replicas into the caller's document.
    GraphDescription description = harness_patch(4);
    const std::size_t nodes_before = description.nodes.size();
    soundgraph::Graph graph;
    CHECK(build(graph, description));
    CHECK(build(graph, description));
    CHECK_MESSAGE(description.nodes.size() == nodes_before,
                  "the caller's description is untouched");
    graph.note_on(57, 0.9f);
    graph.note_on(64, 0.9f);
    const std::vector<float> heard = tail(render(graph, 1.0));
    CHECK(energy_at(heard, kA3) > energy_at(heard, 275.0) * 10.0);
    CHECK(energy_at(heard, kE4) > energy_at(heard, 275.0) * 10.0);
}

TEST_MAIN("polyphony")
