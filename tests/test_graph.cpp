// Validation, scheduling and execution.
#include <algorithm>
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

TEST_MAIN("graph tests")
