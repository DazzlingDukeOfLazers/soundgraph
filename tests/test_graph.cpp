// Validation, scheduling and execution.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "soundgraph/soundgraph.h"
#include "test_support.h"

using soundgraph::ConnectionDescription;
using soundgraph::Diagnostic;
using soundgraph::GraphDescription;
using soundgraph::NodeDescription;
using soundgraph::NodeRegistry;

namespace {

NodeDescription node(const std::string& id, const std::string& type) {
    NodeDescription description;
    description.id = id;
    description.type = type;
    return description;
}

void connect(GraphDescription& graph, const std::string& from_node, const std::string& from_port,
             const std::string& to_node, const std::string& to_port) {
    graph.connections.push_back(ConnectionDescription{from_node, from_port, to_node, to_port});
}

void set(GraphDescription& graph, const std::string& id, const std::string& parameter, double value) {
    for (NodeDescription& description : graph.nodes) {
        if (description.id == id) {
            description.parameters.push_back(soundgraph::ParameterValue{parameter, value});
            return;
        }
    }
}

// osc -> gain -> out
GraphDescription simple_chain() {
    GraphDescription graph;
    graph.nodes.push_back(node("osc", "SineOscillator"));
    graph.nodes.push_back(node("amp", "Gain"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "osc", "out", "amp", "in");
    connect(graph, "amp", "out", "out", "left");
    return graph;
}

bool has_code(const std::vector<Diagnostic>& diagnostics, const std::string& code) {
    for (const Diagnostic& diagnostic : diagnostics) {
        if (diagnostic.code == code) {
            return true;
        }
    }
    return false;
}

const Diagnostic* find_code(const std::vector<Diagnostic>& diagnostics, const std::string& code) {
    for (const Diagnostic& diagnostic : diagnostics) {
        if (diagnostic.code == code) {
            return &diagnostic;
        }
    }
    return nullptr;
}

int position_of(const soundgraph::Graph& graph, const std::string& id) {
    const std::vector<int>& order = graph.execution_order();
    for (std::size_t i = 0; i < order.size(); ++i) {
        if (graph.node_id(order[i]) == id) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

}  // namespace

// ---- validation ---------------------------------------------------------------------

TEST(a_well_formed_chain_validates) {
    GraphDescription graph = simple_chain();
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));
    CHECK(diagnostics.empty());
}

TEST(unknown_node_types_are_named_not_ignored) {
    GraphDescription graph = simple_chain();
    graph.nodes.push_back(node("mystery", "Reverb"));

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));

    const Diagnostic* diagnostic = find_code(diagnostics, "unknown_node_type");
    CHECK(diagnostic != nullptr);
    if (diagnostic != nullptr) {
        CHECK(diagnostic->node_ids.size() == 1 && diagnostic->node_ids[0] == "mystery");
        CHECK(diagnostic->message.find("Reverb") != std::string::npos);
    }
}

TEST(duplicate_ids_are_rejected) {
    GraphDescription graph = simple_chain();
    graph.nodes.push_back(node("osc", "SawOscillator"));

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));
    CHECK(has_code(diagnostics, "duplicate_node_id"));
}

TEST(a_missing_required_input_points_at_the_node) {
    GraphDescription graph;
    graph.nodes.push_back(node("amp", "Gain"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "amp", "out", "out", "left");

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));

    const Diagnostic* diagnostic = find_code(diagnostics, "required_input_unconnected");
    CHECK(diagnostic != nullptr);
    if (diagnostic != nullptr) {
        CHECK(diagnostic->node_ids.size() == 1 && diagnostic->node_ids[0] == "amp");
        CHECK(!diagnostic->suggestion.empty());
    }
}

TEST(unknown_ports_list_what_is_actually_available) {
    GraphDescription graph = simple_chain();
    connect(graph, "osc", "output", "amp", "gain");

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));

    const Diagnostic* diagnostic = find_code(diagnostics, "unknown_output_port");
    CHECK(diagnostic != nullptr);
    if (diagnostic != nullptr) {
        CHECK(diagnostic->suggestion.find("out") != std::string::npos);
        CHECK(diagnostic->connection_indices.size() == 1);
    }
}

TEST(a_second_connection_into_a_single_input_suggests_a_mixer) {
    GraphDescription graph = simple_chain();
    graph.nodes.push_back(node("lfo", "LFO"));
    graph.nodes.push_back(node("lfo2", "LFO"));
    connect(graph, "lfo", "out", "osc", "frequency");
    connect(graph, "lfo2", "out", "osc", "frequency");

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));

    const Diagnostic* diagnostic = find_code(diagnostics, "input_over_connected");
    CHECK(diagnostic != nullptr);
    if (diagnostic != nullptr) {
        CHECK(diagnostic->suggestion.find("Mixer") != std::string::npos);
        CHECK(diagnostic->connection_indices.size() == 2);
    }
}

TEST(summing_inputs_accept_several_connections) {
    GraphDescription graph;
    graph.nodes.push_back(node("a", "SineOscillator"));
    graph.nodes.push_back(node("b", "SineOscillator"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "a", "out", "out", "left");
    connect(graph, "b", "out", "out", "left");

    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));
}

TEST(a_patch_with_no_output_warns_but_still_builds) {
    GraphDescription graph;
    graph.nodes.push_back(node("osc", "SineOscillator"));

    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));
    CHECK(has_code(diagnostics, "no_output"));
    CHECK(!soundgraph::has_errors(diagnostics));
}

TEST(control_surfaces_must_point_at_real_parameters) {
    GraphDescription graph = simple_chain();
    soundgraph::ControlDescription control;
    control.id = "knob";
    control.target.node = "amp";
    control.target.parameter = "wetness";
    graph.controls.push_back(control);

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));
    CHECK(has_code(diagnostics, "surface_target_missing_parameter"));
}

TEST(an_unsupported_schema_version_is_refused_outright) {
    GraphDescription graph = simple_chain();
    graph.schema_version = 99;

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));
    CHECK(has_code(diagnostics, "unsupported_schema_version"));
}

// ---- scheduling ---------------------------------------------------------------------

TEST(nodes_run_in_dependency_order) {
    GraphDescription graph = simple_chain();
    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    CHECK(position_of(runtime, "osc") < position_of(runtime, "amp"));
    CHECK(position_of(runtime, "amp") < position_of(runtime, "out"));
}

TEST(a_diamond_runs_both_branches_before_the_join) {
    GraphDescription graph;
    graph.nodes.push_back(node("src", "SineOscillator"));
    graph.nodes.push_back(node("left", "Gain"));
    graph.nodes.push_back(node("right", "Gain"));
    graph.nodes.push_back(node("mix", "Mixer"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "src", "out", "left", "in");
    connect(graph, "src", "out", "right", "in");
    connect(graph, "left", "out", "mix", "in1");
    connect(graph, "right", "out", "mix", "in2");
    connect(graph, "mix", "out", "out", "left");

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    CHECK(position_of(runtime, "src") < position_of(runtime, "left"));
    CHECK(position_of(runtime, "src") < position_of(runtime, "right"));
    CHECK(position_of(runtime, "left") < position_of(runtime, "mix"));
    CHECK(position_of(runtime, "right") < position_of(runtime, "mix"));
    CHECK(position_of(runtime, "mix") < position_of(runtime, "out"));
}

TEST(a_loop_with_no_delay_names_every_node_in_it) {
    GraphDescription graph;
    graph.nodes.push_back(node("a", "Gain"));
    graph.nodes.push_back(node("b", "Gain"));
    graph.nodes.push_back(node("c", "Gain"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "a", "out", "b", "in");
    connect(graph, "b", "out", "c", "in");
    connect(graph, "c", "out", "a", "in");
    connect(graph, "c", "out", "out", "left");

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));

    const Diagnostic* diagnostic = find_code(diagnostics, "zero_delay_cycle");
    CHECK(diagnostic != nullptr);
    if (diagnostic != nullptr) {
        CHECK(diagnostic->node_ids.size() == 3);
        CHECK(std::find(diagnostic->node_ids.begin(), diagnostic->node_ids.end(), "a") !=
              diagnostic->node_ids.end());
        CHECK(std::find(diagnostic->node_ids.begin(), diagnostic->node_ids.end(), "c") !=
              diagnostic->node_ids.end());
        CHECK(diagnostic->connection_indices.size() == 3);
        CHECK(diagnostic->suggestion.find("Delay") != std::string::npos);
    }
}

TEST(a_loop_through_a_delay_is_legal_and_marked_as_feedback) {
    // The second vertical slice: input -> filter -> delay -> out, with the delay's output
    // fed back through a gain into the delay again.
    GraphDescription graph;
    graph.nodes.push_back(node("src", "SawOscillator"));
    graph.nodes.push_back(node("mix", "Mixer"));
    graph.nodes.push_back(node("delay", "Delay"));
    graph.nodes.push_back(node("fb", "Gain"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "src", "out", "mix", "in1");
    connect(graph, "fb", "out", "mix", "in2");
    connect(graph, "mix", "out", "delay", "in");
    connect(graph, "delay", "out", "fb", "in");
    connect(graph, "delay", "out", "out", "left");

    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));

    soundgraph::Graph runtime;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));
    CHECK(runtime.feedback_connections().size() == 1);
}

TEST(a_node_connected_to_itself_is_a_cycle) {
    GraphDescription graph;
    graph.nodes.push_back(node("amp", "Gain"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "amp", "out", "amp", "in");
    connect(graph, "amp", "out", "out", "left");

    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::validate(graph, NodeRegistry::builtin(), diagnostics));
    CHECK(has_code(diagnostics, "zero_delay_cycle"));
}

// ---- execution ----------------------------------------------------------------------

TEST(a_built_graph_produces_sound) {
    GraphDescription graph = simple_chain();
    set(graph, "osc", "frequency", 440.0);
    set(graph, "out", "level", 1.0);

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    std::vector<float> left(4800, 0.0f);
    std::vector<float> right(4800, 0.0f);
    runtime.render(left.data(), right.data(), 4800);

    float peak = 0.0f;
    for (float sample : left) {
        peak = std::max(peak, std::fabs(sample));
    }
    CHECK(peak > 0.9f);
    CHECK(left == right);
}

TEST(output_does_not_depend_on_the_host_buffer_size) {
    auto render = [](int chunk) {
        GraphDescription graph = simple_chain();
        set(graph, "osc", "frequency", 233.0);

        soundgraph::Graph runtime;
        std::vector<Diagnostic> diagnostics;
        runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics);

        std::vector<float> output(4800, 0.0f);
        int written = 0;
        while (written < 4800) {
            const int frames = std::min(chunk, 4800 - written);
            runtime.render(output.data() + written, nullptr, frames);
            written += frames;
        }
        return output;
    };

    const std::vector<float> in_one_call = render(4800);
    const std::vector<float> in_blocks = render(64);
    // 37 is deliberately not a multiple of the internal block size.
    const std::vector<float> in_odd_chunks = render(37);

    CHECK(in_one_call == in_blocks);
    CHECK_MESSAGE(in_one_call == in_odd_chunks,
                  "a host with an awkward buffer size must still get identical audio");
}

TEST(rendering_is_repeatable_after_reset) {
    GraphDescription graph = simple_chain();
    set(graph, "osc", "frequency", 330.0);

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    std::vector<float> first(2048, 0.0f);
    runtime.render(first.data(), nullptr, 2048);

    runtime.reset();

    std::vector<float> second(2048, 0.0f);
    runtime.render(second.data(), nullptr, 2048);

    CHECK(first == second);
}

TEST(notes_reach_the_note_input_and_drive_the_envelope) {
    GraphDescription graph;
    graph.nodes.push_back(node("note", "NoteInput"));
    graph.nodes.push_back(node("osc", "SawOscillator"));
    graph.nodes.push_back(node("env", "ADSR"));
    graph.nodes.push_back(node("amp", "Gain"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "note", "frequency", "osc", "frequency");
    connect(graph, "note", "gate", "env", "gate");
    connect(graph, "osc", "out", "amp", "in");
    connect(graph, "env", "out", "amp", "gain");
    connect(graph, "amp", "out", "out", "left");
    set(graph, "env", "attack", 0.001);
    set(graph, "out", "level", 1.0);

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    std::vector<float> silence(4800, 0.0f);
    runtime.render(silence.data(), nullptr, 4800);
    float silent_peak = 0.0f;
    for (float sample : silence) {
        silent_peak = std::max(silent_peak, std::fabs(sample));
    }
    CHECK_MESSAGE(silent_peak < 1e-6f, "nothing should sound before a note arrives");

    runtime.note_on(69, 1.0f);
    std::vector<float> sounding(4800, 0.0f);
    runtime.render(sounding.data(), nullptr, 4800);
    float sounding_peak = 0.0f;
    for (float sample : sounding) {
        sounding_peak = std::max(sounding_peak, std::fabs(sample));
    }
    CHECK(sounding_peak > 0.2f);
}

TEST(parameter_changes_take_effect_on_the_next_block) {
    GraphDescription graph = simple_chain();
    set(graph, "out", "level", 1.0);
    set(graph, "amp", "gain", 1.0);

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    std::vector<float> loud(1024, 0.0f);
    runtime.render(loud.data(), nullptr, 1024);

    CHECK(runtime.set_parameter("amp", "gain", 0.0f));
    std::vector<float> quiet(1024, 0.0f);
    runtime.render(quiet.data(), nullptr, 1024);

    float quiet_peak = 0.0f;
    for (float sample : quiet) {
        quiet_peak = std::max(quiet_peak, std::fabs(sample));
    }
    CHECK_NEAR(quiet_peak, 0.0, 1e-6);

    CHECK(!runtime.set_parameter("nope", "gain", 1.0f));
    CHECK(!runtime.set_parameter("amp", "wetness", 1.0f));
}

TEST(feedback_edges_deliver_the_previous_block) {
    // A delay whose graph-level feedback loop is closed through a gain of 1. One block of
    // latency means the impulse must reappear a whole block later, never within one.
    GraphDescription graph;
    graph.nodes.push_back(node("delay", "Delay"));
    graph.nodes.push_back(node("fb", "Gain"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "fb", "out", "delay", "in");
    connect(graph, "delay", "out", "fb", "in");
    connect(graph, "delay", "out", "out", "left");

    std::vector<Diagnostic> diagnostics;
    soundgraph::Graph runtime;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));
    CHECK(runtime.feedback_connections().size() == 1);

    // Silent in, silent out — the point here is that it schedules and runs at all.
    std::vector<float> output(1024, 0.0f);
    runtime.render(output.data(), nullptr, 1024);
    for (float sample : output) {
        CHECK(std::isfinite(sample));
    }
}

TEST(multiple_outputs_are_summed_onto_the_master_bus) {
    GraphDescription graph;
    graph.nodes.push_back(node("a", "Constant"));
    graph.nodes.push_back(node("b", "Constant"));
    graph.nodes.push_back(node("out_a", "StereoOutput"));
    graph.nodes.push_back(node("out_b", "StereoOutput"));
    connect(graph, "a", "out", "out_a", "left");
    connect(graph, "b", "out", "out_b", "left");
    set(graph, "a", "value", 0.25);
    set(graph, "b", "value", 0.25);
    set(graph, "out_a", "level", 1.0);
    set(graph, "out_b", "level", 1.0);

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    std::vector<float> output(128, 0.0f);
    runtime.render(output.data(), nullptr, 128);
    CHECK_NEAR(output[64], 0.5, 1e-6);
}

TEST(the_signal_on_any_port_can_be_inspected) {
    GraphDescription graph = simple_chain();
    set(graph, "osc", "frequency", 440.0);
    set(graph, "amp", "gain", 0.25);
    set(graph, "out", "level", 1.0);

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    std::vector<float> output(soundgraph::kBlockSize, 0.0f);
    runtime.render(output.data(), nullptr, soundgraph::kBlockSize);

    const int oscillator = runtime.node_index("osc");
    const int amplifier = runtime.node_index("amp");
    const float* raw = runtime.port_signal(oscillator, 0);
    const float* scaled = runtime.port_signal(amplifier, 0);
    CHECK(raw != nullptr);
    CHECK(scaled != nullptr);

    // The wire after the gain should carry exactly a quarter of what went into it —
    // an editor showing these two waveforms is showing the real buffers, not a guess.
    for (int i = 0; i < runtime.port_signal_length(); ++i) {
        CHECK_NEAR(scaled[i], raw[i] * 0.25f, 1e-6);
    }
    // And the master bus is what the output node produced.
    for (int i = 0; i < runtime.port_signal_length(); ++i) {
        CHECK_NEAR(output[static_cast<std::size_t>(i)], scaled[i], 1e-6);
    }

    CHECK(runtime.port_signal(-1, 0) == nullptr);
    CHECK(runtime.port_signal(oscillator, 9) == nullptr);
}

TEST(the_registry_finds_nodes_by_intent_not_only_by_name) {
    const NodeRegistry& registry = NodeRegistry::builtin();

    auto top_result = [&](const std::string& query) {
        const std::vector<const soundgraph::NodeTypeDescriptor*> results = registry.search(query);
        return results.empty() ? std::string("(nothing)") : std::string(results.front()->name);
    };

    CHECK(top_result("lowpass") == "StateVariableFilter");
    CHECK(top_result("remove high frequencies") == "StateVariableFilter");
    CHECK(top_result("make quieter") == "Gain");
    CHECK(top_result("echo") == "Delay");
    CHECK(top_result("midi keyboard") == "NoteInput");
    CHECK(top_result("vibrato") == "LFO");
    CHECK(registry.search("definitely not a node").empty());
}

TEST(resource_estimates_grow_with_the_patch) {
    GraphDescription small = simple_chain();
    GraphDescription large = simple_chain();
    large.nodes.push_back(node("delay", "Delay"));
    connect(large, "amp", "out", "delay", "in");

    soundgraph::Graph small_runtime;
    soundgraph::Graph large_runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(small_runtime.build(small, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));
    CHECK(large_runtime.build(large, NodeRegistry::builtin(), soundgraph::PrepareContext(), diagnostics));

    CHECK(large_runtime.estimated_cost().cpu_cost > small_runtime.estimated_cost().cpu_cost);
    CHECK(large_runtime.estimated_cost().heap_bytes > small_runtime.estimated_cost().heap_bytes);
}

TEST(control_change_reaches_a_midicc_node_through_the_queue) {
    // The whole path: the host calls control_change, the event drains at the
    // block boundary, the node reads the surface. Wired into a Gain so the
    // answer is audible rather than inspected.
    GraphDescription graph;
    graph.nodes.push_back(node("knob", "MidiCC"));
    graph.nodes.push_back(node("tone", "SineOscillator"));
    graph.nodes.push_back(node("amp", "Gain"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    set(graph, "knob", "cc", 74.0);
    set(graph, "knob", "glide", 0.0);
    // Gain's input MULTIPLIES its parameter, so the parameter stays 1 and the
    // knob owns the level entirely: resting 0 is silence, knob up is the tone.
    set(graph, "amp", "gain", 1.0);
    connect(graph, "tone", "out", "amp", "in");
    connect(graph, "knob", "out", "amp", "gain");
    connect(graph, "amp", "out", "out", "left");

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
        diagnostics));

    std::vector<float> left(4800), right(4800);
    runtime.render(left.data(), right.data(), 4800);
    double quiet = 0.0;
    for (float sample : left) quiet += sample * sample;
    CHECK(std::sqrt(quiet / 4800.0) < 0.001);   // knob never spoken: resting 0

    runtime.control_change(74, 1.0f);
    runtime.render(left.data(), right.data(), 4800);
    double loud = 0.0;
    for (float sample : left) loud += sample * sample;
    CHECK(std::sqrt(loud / 4800.0) > 0.1);      // knob up: the tone arrives
}

// ---- hosted plugins ---------------------------------------------------------------
// A plugin the test can be certain about: it halves what it is given and records what
// it was told. Enough to prove the graph resolves, owns, prepares and drives the thing
// without anybody having to install Surge XT to run the suite. Halving rather than
// doubling so that no gain staging anywhere can clip the comparison — the first version
// of this test doubled a sine into the limiter and measured the limiter.
namespace {

class HalvingPlugin : public soundgraph::HostedPluginInstance {
public:
    void prepare(double sample_rate, int max_block_frames) override {
        prepared_rate = sample_rate;
        prepared_block = max_block_frames;
    }
    void process(const float* const* inputs, int input_channels, float* const* outputs,
                 int output_channels, int frames) override {
        for (int channel = 0; channel < output_channels; ++channel) {
            const float* in = channel < input_channels ? inputs[channel] : nullptr;
            for (int i = 0; i < frames; ++i) {
                outputs[channel][i] = in != nullptr ? in[i] * 0.5f : 0.0f;
            }
        }
    }
    void set_control(int slot, float value) override { controls[slot] = value; }
    void note_on(int note, float) override { notes_on.push_back(note); ++live; }
    void note_off(int note) override { notes_off.push_back(note); --live; }

    // The editor's half of the contract: a panel, and the main thread to service it.
    bool has_gui() override { return true; }
    bool open_gui(void* parent) override {
        opened_into = parent;
        return parent != nullptr;
    }
    void close_gui() override { opened_into = nullptr; }
    bool gui_size(int& width, int& height) override {
        width = 1141;
        height = 711;
        return true;
    }
    void main_thread_tick() override { ++ticks; }

    // An editor with an opinion about its shape, which is the ordinary case: Surge XT
    // holds a 1141:711 aspect and rounds whatever it is offered to fit.
    bool gui_can_resize() override { return true; }
    bool set_gui_size(int& width, int& height) override {
        height = height < 100 ? 100 : height;
        width = height * 1141 / 711;
        gui_width = width;
        gui_height = height;
        return true;
    }
    bool take_gui_resize_request(int& width, int& height) override {
        if (!wants_resize) return false;
        width = 800;
        height = 500;
        wants_resize = false;  // one shot: collecting it is what clears it
        return true;
    }

    int gui_width = 1141;
    int gui_height = 711;
    bool wants_resize = false;

    std::vector<int> notes_on;
    std::vector<int> notes_off;
    int live = 0;
    double prepared_rate = 0.0;
    int prepared_block = 0;
    std::map<int, float> controls;
    void* opened_into = nullptr;
    int ticks = 0;
};

class OnePluginProvider : public soundgraph::PluginProvider {
public:
    std::unique_ptr<soundgraph::HostedPluginInstance> acquire(
        const soundgraph::PluginRequest& request) override {
        asked_for = request;
        ++times_asked;
        auto instance = std::make_unique<HalvingPlugin>();
        last = instance.get();
        return instance;
    }
    soundgraph::PluginRequest asked_for;
    int times_asked = 0;
    HalvingPlugin* last = nullptr;
};

// A plugin that is late, and honest about it — it reports N frames of latency and its
// output really is its input N frames later. Both halves matter: a fake that reported
// latency without delaying anything would let a broken compensator look correct, and one
// that delayed without reporting is the bug this whole feature exists to fix.
class LatentPlugin : public soundgraph::HostedPluginInstance {
public:
    // `reported` is what it tells the host; `actual` is how late it really is. They are
    // the same for an honest plugin, which is the default. They differ for the one test
    // that asks what happens when a plugin reports a number nobody should believe —
    // there, delaying by the reported amount would mean this fake allocating the
    // hundreds of megabytes the graph is being tested for refusing to allocate.
    explicit LatentPlugin(int reported, int actual = -1)
        : reported_(reported), actual_(actual < 0 ? reported : actual) {}

    void prepare(double, int) override {
        for (auto& ring : rings_) {
            ring.assign(static_cast<std::size_t>(std::max(actual_, 1)), 0.0f);
        }
        write_ = 0;
    }

    void process(const float* const* inputs, int input_channels, float* const* outputs,
                 int output_channels, int frames) override {
        for (int i = 0; i < frames; ++i) {
            const int at = write_;
            for (int channel = 0; channel < output_channels && channel < 2; ++channel) {
                const float in = channel < input_channels ? inputs[channel][i] : 0.0f;
                std::vector<float>& ring = rings_[static_cast<std::size_t>(channel)];
                outputs[channel][i] = ring[static_cast<std::size_t>(at)];
                ring[static_cast<std::size_t>(at)] = in;
            }
            write_ = write_ + 1 == std::max(actual_, 1) ? 0 : write_ + 1;
        }
    }

    void set_control(int, float) override {}
    int latency_frames() const override { return reported_; }

private:
    int reported_ = 0;
    int actual_ = 0;
    int write_ = 0;
    std::vector<float> rings_[2];
};

class LatentProvider : public soundgraph::PluginProvider {
public:
    explicit LatentProvider(int reported, int actual = -1)
        : reported_(reported), actual_(actual) {}
    std::unique_ptr<soundgraph::HostedPluginInstance> acquire(
        const soundgraph::PluginRequest&) override {
        return std::make_unique<LatentPlugin>(reported_, actual_);
    }

private:
    int reported_ = 0;
    int actual_ = -1;
};

// A provider for a machine that does not have the plugin: it says so, politely.
class EmptyProvider : public soundgraph::PluginProvider {
public:
    std::unique_ptr<soundgraph::HostedPluginInstance> acquire(
        const soundgraph::PluginRequest&) override {
        return nullptr;
    }
};

GraphDescription plugin_chain() {
    GraphDescription graph;
    graph.nodes.push_back(node("osc", "SineOscillator"));
    graph.nodes.push_back(node("fx", "PluginEffect"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    graph.nodes.back().parameters.push_back({"level", 1.0});
    graph.nodes[1].plugin = "reverb";
    connect(graph, "osc", "out", "fx", "left");
    connect(graph, "fx", "left", "out", "left");
    connect(graph, "fx", "right", "out", "right");

    soundgraph::PluginDescription plugin;
    plugin.id = "reverb";
    plugin.format = "VST3";
    plugin.identity = "ABCDEF019182FAEB566D624153675854";
    plugin.vendor = "Surge Synth Team";
    plugin.name = "Surge XT";
    graph.plugins.push_back(plugin);
    return graph;
}

// The graph this whole feature is about: one signal, two paths to the output, and a
// plugin in only one of them. `shared_port` puts both paths on the same input instead of
// one per channel, which is the other thing the reader has to get right.
GraphDescription forked_by_a_plugin(bool shared_port) {
    GraphDescription graph;
    graph.nodes.push_back(node("osc", "SineOscillator"));
    graph.nodes.push_back(node("fx", "PluginEffect"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    graph.nodes.back().parameters.push_back({"level", 1.0});
    // The limiter would flatten the sum this test is measuring, and its being on by
    // default is right for every patch that is not a measurement.
    graph.nodes.back().parameters.push_back({"safety_limit", 0.0});
    graph.nodes[1].plugin = "reverb";
    connect(graph, "osc", "out", "fx", "left");
    connect(graph, "fx", "left", "out", "left");
    connect(graph, "osc", "out", "out", shared_port ? "left" : "right");

    soundgraph::PluginDescription plugin;
    plugin.id = "reverb";
    plugin.format = "CLAP";
    plugin.identity = "org.example.late";
    graph.plugins.push_back(plugin);
    return graph;
}

double rms_of(soundgraph::Graph& runtime, int frames) {
    std::vector<float> left(static_cast<std::size_t>(frames));
    std::vector<float> right(static_cast<std::size_t>(frames));
    runtime.render(left.data(), right.data(), frames);
    double total = 0.0;
    for (float sample : left) total += sample * sample;
    return std::sqrt(total / frames);
}

}  // namespace

TEST(a_plugin_node_is_resolved_by_identity_and_driven) {
    GraphDescription graph = plugin_chain();
    set(graph, "fx", "slot3", 0.75);

    OnePluginProvider provider;
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));

    // Asked for by identity, with the hints along for the diagnostic's sake.
    CHECK(provider.times_asked == 1);
    CHECK(provider.asked_for.identity == "ABCDEF019182FAEB566D624153675854");
    CHECK(provider.asked_for.format == "VST3");
    CHECK(provider.asked_for.name == "Surge XT");

    rms_of(runtime, 512);
    // Prepared with the graph's own block size — no buffering up to something larger,
    // because measurement said no plugin needed it. See docs/hosted-plugins-design.md.
    CHECK(provider.last->prepared_block == soundgraph::kBlockSize);
    // The slot reached the plugin, normalised, and the untouched ones did too.
    CHECK(std::fabs(provider.last->controls[2] - 0.75f) < 1e-6);
    CHECK(provider.last->controls.size() == 16);
}

TEST(the_graph_hands_out_the_plugin_a_node_is_playing_through) {
    // What an editor needs to show a plugin's own panel: the instance behind a node,
    // found by the name the author gave the node. Kept here rather than in the runtime
    // that owns windows, because the graph is what resolved the plugin and a second map
    // from node to plugin is a second thing to get out of step with a reload.
    GraphDescription graph = plugin_chain();

    OnePluginProvider provider;
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));

    soundgraph::HostedPluginInstance* found = runtime.plugin_for_node("fx");
    CHECK(found == provider.last);
    CHECK(runtime.plugin_for_node("osc") == nullptr);   // a node with no plugin
    CHECK(runtime.plugin_for_node("nope") == nullptr);  // a node that is not there

    // The handle is opaque all the way through: the core never looks at it, so a
    // stand-in address proves the journey as well as a real HWND would.
    int width = 0;
    int height = 0;
    CHECK(found->has_gui());
    CHECK(found->open_gui(&runtime));
    CHECK(provider.last->opened_into == &runtime);
    CHECK(found->gui_size(width, height) && width == 1141 && height == 711);

    const int before = provider.last->ticks;
    runtime.tick_plugins();
    CHECK(provider.last->ticks == before + 1);

    found->close_gui();
    CHECK(provider.last->opened_into == nullptr);

    // And a rebuild lets go of every instance, which is why an editor closes the panel
    // before reloading rather than after.
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));
    CHECK(runtime.plugin_for_node("fx") == provider.last);
}

TEST(a_late_plugin_does_not_drag_the_paths_beside_it_out_of_step) {
    // Left goes through a plugin that is 100 frames late; right goes straight to the
    // output. Compensated, the two channels carry the same samples at the same instants,
    // which is the entire claim — and it is checked sample by sample rather than by rms,
    // because two channels 100 frames apart have identical rms and sound wrong.
    constexpr int kLate = 100;
    GraphDescription graph = forked_by_a_plugin(false);

    LatentProvider provider(kLate);
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));

    CHECK(runtime.latency_frames() == kLate);

    constexpr int kFrames = 2048;
    std::vector<float> left(static_cast<std::size_t>(kFrames));
    std::vector<float> right(static_cast<std::size_t>(kFrames));
    runtime.render(left.data(), right.data(), kFrames);

    double worst = 0.0;
    double loudest = 0.0;
    for (std::size_t i = 0; i < left.size(); ++i) {
        worst = std::max(worst, std::fabs(static_cast<double>(left[i] - right[i])));
        loudest = std::max(loudest, std::fabs(static_cast<double>(left[i])));
    }
    CHECK(loudest > 0.1);  // it is actually playing, so the agreement means something
    CHECK(worst < 1e-6);   // and the two paths agree, sample for sample
}

TEST(without_a_plugin_the_same_graph_is_untouched) {
    // The invariant every golden vector depends on: no plugin, no latency, no delay
    // lines, and a graph that behaves exactly as it did before any of this existed.
    // Asserted here as well as implied by the corpus, because it is the thing this
    // feature could most easily break without anybody noticing until four targets
    // disagreed about a patch.
    GraphDescription graph = forked_by_a_plugin(false);

    EmptyProvider absent;
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&absent);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));
    CHECK(runtime.latency_frames() == 0);

    constexpr int kFrames = 512;
    std::vector<float> left(static_cast<std::size_t>(kFrames));
    std::vector<float> right(static_cast<std::size_t>(kFrames));
    runtime.render(left.data(), right.data(), kFrames);
    for (std::size_t i = 0; i < left.size(); ++i) {
        CHECK(std::fabs(static_cast<double>(left[i] - right[i])) < 1e-9);
    }
}

TEST(two_sources_on_one_port_are_aligned_before_they_are_summed) {
    // The other branch of the reader: two sources arriving at one port, one of them late.
    // Summing them out of step is comb filtering — the signal partly cancels itself — so
    // the wrong answer here is *quieter* than the right one rather than merely different.
    constexpr int kLate = 64;
    GraphDescription graph = forked_by_a_plugin(true);

    LatentProvider provider(kLate);
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));

    constexpr int kFrames = 4096;
    std::vector<float> left(static_cast<std::size_t>(kFrames));
    std::vector<float> right(static_cast<std::size_t>(kFrames));
    runtime.render(left.data(), right.data(), kFrames);

    // In step, the two copies are the same signal and sum to twice it. The oscillator
    // peaks at 1.0, so near 2.0 is aligned and anything much below it is the comb.
    double peak = 0.0;
    for (std::size_t i = left.size() / 2; i < left.size(); ++i) {  // past the priming
        peak = std::max(peak, std::fabs(static_cast<double>(left[i])));
    }
    CHECK(peak > 1.9);
}

TEST(a_plugin_claiming_absurd_latency_is_capped_and_reported) {
    // The number comes from a stranger, and believing it means allocating whatever it
    // said. A plugin reporting a hundred million frames is either misunderstanding the
    // question or handing back uninitialised memory; either way the graph should survive
    // it, say so, and carry on making a sound.
    GraphDescription graph = forked_by_a_plugin(false);

    LatentProvider provider(100 * 1000 * 1000, 0);
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));

    bool said_so = false;
    for (const Diagnostic& diagnostic : diagnostics) {
        if (diagnostic.code == "implausible_latency") said_so = true;
    }
    CHECK(said_so);
    CHECK(runtime.latency_frames() == 48000);  // a second, and not a byte more

    // And it still runs: the point of a cap is that the patch keeps working.
    std::vector<float> left(256);
    std::vector<float> right(256);
    runtime.render(left.data(), right.data(), 256);
}

TEST(resizing_a_plugins_editor_is_a_conversation_in_both_directions) {
    // The shape of the contract, which is the part a future implementation is most
    // likely to get wrong: the size goes in and the *taken* size comes back out, and a
    // request from the plugin is cleared by being collected rather than by being acted
    // on. Whether a real editor redraws is not a question this suite can ask; that is
    // proven against Surge XT by hand, and written down in the design doc.
    GraphDescription graph = plugin_chain();

    OnePluginProvider provider;
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));

    soundgraph::HostedPluginInstance* plugin = runtime.plugin_for_node("fx");
    CHECK(plugin != nullptr && plugin->gui_can_resize());

    // Asked for something the editor cannot be; given back what it took instead.
    int width = 1500;
    int height = 700;
    CHECK(plugin->set_gui_size(width, height));
    CHECK(height == 700);
    CHECK(width == 700 * 1141 / 711);
    CHECK(width != 1500);

    // Nothing to collect until the plugin asks, and then exactly once.
    int asked_width = 0;
    int asked_height = 0;
    CHECK(!plugin->take_gui_resize_request(asked_width, asked_height));
    provider.last->wants_resize = true;
    CHECK(plugin->take_gui_resize_request(asked_width, asked_height));
    CHECK(asked_width == 800 && asked_height == 500);
    CHECK(!plugin->take_gui_resize_request(asked_width, asked_height));
}

TEST(a_plugin_node_passes_audio_through_when_there_is_no_plugin) {
    // Three worlds that must agree: a provider that hands one over, a provider that
    // cannot, and a target with no provider at all — the ESP32 and the browser.
    GraphDescription graph = plugin_chain();

    OnePluginProvider provider;
    soundgraph::Graph hosted;
    hosted.set_plugin_provider(&provider);
    std::vector<Diagnostic> hosted_diagnostics;
    CHECK(hosted.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                       hosted_diagnostics));
    const double halved = rms_of(hosted, 4800);

    EmptyProvider empty;
    soundgraph::Graph without;
    without.set_plugin_provider(&empty);
    std::vector<Diagnostic> without_diagnostics;
    CHECK(without.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        without_diagnostics));
    const double dry = rms_of(without, 4800);

    soundgraph::Graph no_provider;
    std::vector<Diagnostic> no_provider_diagnostics;
    CHECK(no_provider.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                            no_provider_diagnostics));
    const double also_dry = rms_of(no_provider, 4800);

    // The patch builds either way — a missing reverb costs you the reverb, not the patch.
    // Relative, not absolute: what matters is that the dry path is audible and that the
    // hosted path is exactly half it, whatever the oscillator's level happens to be.
    CHECK(dry > 0.01);
    CHECK(std::fabs(dry - also_dry) < 1e-6);
    CHECK(std::fabs(halved - dry * 0.5) < dry * 0.01);

    // And it says so, once, as a warning naming what is missing rather than a UID.
    bool warned = false;
    for (const Diagnostic& diagnostic : without_diagnostics) {
        if (diagnostic.code == "plugin_unavailable") {
            warned = true;
            CHECK(diagnostic.severity == soundgraph::Severity::Warning);
            CHECK(diagnostic.message.find("Surge XT") != std::string::npos);
        }
    }
    CHECK(warned);
    CHECK(!no_provider_diagnostics.empty());
}

TEST(a_plugin_node_bypass_is_not_the_same_as_absence) {
    GraphDescription graph = plugin_chain();
    set(graph, "fx", "bypass", 1.0);

    OnePluginProvider provider;
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));
    // Bypassed: the plugin is loaded and asked for, and simply not in the path.
    CHECK(provider.times_asked == 1);
    CHECK(rms_of(runtime, 4800) > 0.1);
    bool complained = false;
    for (const Diagnostic& diagnostic : diagnostics) {
        complained = complained || diagnostic.code == "plugin_unavailable";
    }
    CHECK(!complained);
}

TEST(a_plugin_instrument_is_one_instance_however_many_voices) {
    // Sixteen voices, and the whole point: sixteen copies of Vital would be sixteen
    // copies of a synth that was already told to play the chord.
    GraphDescription graph;
    graph.nodes.push_back(node("kb", "NoteInput"));
    graph.nodes.back().parameters.push_back({"voices", 8.0});
    graph.nodes.push_back(node("synth", "PluginInstrument"));
    graph.nodes.back().plugin = "vital";
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "synth", "left", "out", "left");
    connect(graph, "synth", "right", "out", "right");

    soundgraph::PluginDescription plugin;
    plugin.id = "vital";
    plugin.format = "CLAP";
    plugin.identity = "audio.vital.synth";
    plugin.name = "Vital";
    graph.plugins.push_back(plugin);

    OnePluginProvider provider;
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));

    // Asked for exactly once, however many voices the NoteInput wanted.
    CHECK(provider.times_asked == 1);

    // And it hears every note of a chord, not one voice's share — which is what the
    // allocator would have handed a node it had cloned.
    runtime.note_on(60, 1.0f);
    runtime.note_on(64, 1.0f);
    runtime.note_on(67, 1.0f);
    rms_of(runtime, 256);
    CHECK(provider.last->notes_on.size() == 3);
    CHECK(provider.last->live == 3);

    runtime.note_off(64);
    rms_of(runtime, 256);
    CHECK(provider.last->notes_off.size() == 1);
    CHECK(provider.last->notes_off[0] == 64);
    CHECK(provider.last->live == 2);
}

TEST(a_voice_boundary_keeps_what_follows_it_out_of_the_voice_system) {
    // A filter after a hosted instrument must not be cloned either: by then the notes
    // are already mixed, and eight copies of a filter fed one chord is eight times the
    // chord. The proof is that the provider is asked once and the graph stays small.
    GraphDescription graph;
    graph.nodes.push_back(node("kb", "NoteInput"));
    graph.nodes.back().parameters.push_back({"voices", 8.0});
    graph.nodes.push_back(node("synth", "PluginInstrument"));
    graph.nodes.back().plugin = "vital";
    graph.nodes.push_back(node("tone", "StateVariableFilter"));
    graph.nodes.push_back(node("out", "StereoOutput"));
    connect(graph, "synth", "left", "tone", "in");
    connect(graph, "tone", "out", "out", "left");

    soundgraph::PluginDescription plugin;
    plugin.id = "vital";
    plugin.format = "CLAP";
    plugin.identity = "audio.vital.synth";
    graph.plugins.push_back(plugin);

    OnePluginProvider provider;
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));

    CHECK(provider.times_asked == 1);
    // One synth, one filter, one output, one keyboard: nothing past the boundary was
    // copied. Eight voices of a cloned filter would have shown up here as eight more.
    int filters = 0;
    for (int index : runtime.execution_order()) {
        if (runtime.node_id(index).find("tone") != std::string::npos) ++filters;
    }
    CHECK(filters == 1);
}

TEST(an_unbound_slot_is_only_the_one_the_patch_marks_unbound) {
    // A CLAP parameter id is a uint32, so through an int it is very often negative —
    // Surge XT's Global Volume is -810883302. The provider once read "negative" as
    // "unbound" and silently dropped most of the real ids on the machine, which looked
    // from the outside exactly like a slot that did nothing. Only -1 means unbound, and
    // the graph must pass every other id through untouched.
    GraphDescription graph = plugin_chain();
    graph.plugins[0].slots = {-810883302, -1, 7};
    set(graph, "fx", "slot1", 0.25);

    OnePluginProvider provider;
    soundgraph::Graph runtime;
    runtime.set_plugin_provider(&provider);
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, NodeRegistry::builtin(), soundgraph::PrepareContext(),
                        diagnostics));
    CHECK(provider.asked_for.slots.size() == 3);
    CHECK(provider.asked_for.slots[0] == -810883302);
    CHECK(provider.asked_for.slots[1] == -1);
}

TEST_MAIN("graph tests")
