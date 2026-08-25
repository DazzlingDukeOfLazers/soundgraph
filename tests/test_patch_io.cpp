// The text boundary: parsing, serialising, and surviving the round trip.
#include <cmath>
#include <filesystem>
#include <string>
#include <vector>

#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"
#include "test_support.h"

using soundgraph::Diagnostic;
using soundgraph::GraphDescription;

namespace {

const std::string kExamplePatch = std::string(SOUNDGRAPH_EXAMPLES_DIR) + "/patches/first-synth.json";

bool has_code(const std::vector<Diagnostic>& diagnostics, const std::string& code) {
    for (const Diagnostic& diagnostic : diagnostics) {
        if (diagnostic.code == code) {
            return true;
        }
    }
    return false;
}

std::string minimal_patch() {
    return R"({
        "schema_version": 1,
        "nodes": [
            { "id": "osc", "type": "SineOscillator", "parameters": { "frequency": 440 } },
            { "id": "out", "type": "StereoOutput" }
        ],
        "connections": [
            { "from": { "node": "osc", "port": "out" }, "to": { "node": "out", "port": "left" } }
        ]
    })";
}

bool same_graph(const GraphDescription& a, const GraphDescription& b) {
    if (a.schema_version != b.schema_version) return false;
    if (a.nodes.size() != b.nodes.size()) return false;
    if (a.connections.size() != b.connections.size()) return false;
    if (a.controls.size() != b.controls.size()) return false;
    if (a.automation.size() != b.automation.size()) return false;

    for (std::size_t i = 0; i < a.nodes.size(); ++i) {
        if (a.nodes[i].id != b.nodes[i].id) return false;
        if (a.nodes[i].type != b.nodes[i].type) return false;
        if (a.nodes[i].name != b.nodes[i].name) return false;
        if (a.nodes[i].has_position != b.nodes[i].has_position) return false;
        if (a.nodes[i].has_position &&
            (a.nodes[i].x != b.nodes[i].x || a.nodes[i].y != b.nodes[i].y)) {
            return false;
        }
        if (a.nodes[i].parameters.size() != b.nodes[i].parameters.size()) return false;
        for (std::size_t p = 0; p < a.nodes[i].parameters.size(); ++p) {
            if (a.nodes[i].parameters[p].name != b.nodes[i].parameters[p].name) return false;
            if (a.nodes[i].parameters[p].value != b.nodes[i].parameters[p].value) return false;
        }
    }
    for (std::size_t i = 0; i < a.connections.size(); ++i) {
        if (a.connections[i].from_node != b.connections[i].from_node) return false;
        if (a.connections[i].from_port != b.connections[i].from_port) return false;
        if (a.connections[i].to_node != b.connections[i].to_node) return false;
        if (a.connections[i].to_port != b.connections[i].to_port) return false;
    }
    for (std::size_t i = 0; i < a.controls.size(); ++i) {
        if (a.controls[i].id != b.controls[i].id) return false;
        if (a.controls[i].target.node != b.controls[i].target.node) return false;
        if (a.controls[i].target.parameter != b.controls[i].target.parameter) return false;
        if (a.controls[i].midi_cc != b.controls[i].midi_cc) return false;
        if (a.controls[i].min_value != b.controls[i].min_value) return false;
    }
    return true;
}

}  // namespace

TEST(the_example_patch_loads_and_validates) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::load_patch(kExamplePatch, graph, diagnostics));
    CHECK(diagnostics.empty());
    CHECK(graph.nodes.size() == 7);
    CHECK(graph.connections.size() == 7);
    CHECK(graph.controls.size() == 7);
    CHECK(graph.metadata_value("name") == "First Synth");
    CHECK(graph.tags.size() == 3);

    CHECK(soundgraph::validate(graph, soundgraph::NodeRegistry::builtin(), diagnostics));
}

TEST(every_shipped_example_loads_validates_and_round_trips) {
    const std::filesystem::path directory = std::filesystem::path(SOUNDGRAPH_EXAMPLES_DIR) / "patches";
    int checked = 0;

    for (const std::filesystem::directory_entry& entry :
         std::filesystem::directory_iterator(directory)) {
        if (entry.path().extension() != ".json") {
            continue;
        }
        const std::string path = entry.path().string();

        GraphDescription graph;
        std::vector<Diagnostic> diagnostics;
        CHECK_MESSAGE(soundgraph::load_patch(path, graph, diagnostics), path);
        CHECK_MESSAGE(soundgraph::validate(graph, soundgraph::NodeRegistry::builtin(), diagnostics),
                      path + " does not validate");

        GraphDescription reloaded;
        CHECK(soundgraph::parse_patch(soundgraph::write_patch(graph, true), reloaded, diagnostics));
        CHECK_MESSAGE(same_graph(graph, reloaded), path + " changed on a round trip");

        // An example that does not build is an example that cannot be demonstrated.
        soundgraph::Graph runtime;
        std::vector<Diagnostic> build_diagnostics;
        CHECK_MESSAGE(runtime.build(graph, soundgraph::NodeRegistry::builtin(),
                                    soundgraph::PrepareContext(), build_diagnostics),
                      path + " cannot be built");
        ++checked;
    }

    CHECK_MESSAGE(checked >= 2, "the examples directory should not be empty");
}

TEST(the_example_patch_survives_a_round_trip) {
    GraphDescription original;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::load_patch(kExamplePatch, original, diagnostics));

    const std::string text = soundgraph::write_patch(original, true);

    GraphDescription reloaded;
    CHECK(soundgraph::parse_patch(text, reloaded, diagnostics));
    CHECK_MESSAGE(same_graph(original, reloaded), "load -> save -> load changed the patch");

    // And again, to prove the written form is a fixed point rather than merely equivalent.
    CHECK(soundgraph::write_patch(reloaded, true) == text);
}

TEST(numbers_are_written_back_in_the_form_they_were_given) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(minimal_patch(), graph, diagnostics));

    const std::string text = soundgraph::write_patch(graph, true);
    CHECK_MESSAGE(text.find("\"frequency\": 440") != std::string::npos,
                  "440 must not come back as 440.00000000000006");
}

TEST(precise_values_survive_serialisation) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(minimal_patch(), graph, diagnostics));
    graph.nodes[0].parameters[0].value = 0.1 + 0.2;

    GraphDescription reloaded;
    CHECK(soundgraph::parse_patch(soundgraph::write_patch(graph, true), reloaded, diagnostics));
    CHECK(reloaded.nodes[0].parameters[0].value == graph.nodes[0].parameters[0].value);
}

TEST(editor_layout_is_carried_through_the_format) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::load_patch(kExamplePatch, graph, diagnostics));

    bool found = false;
    for (const soundgraph::NodeDescription& node : graph.nodes) {
        if (node.id == "filter") {
            found = true;
            CHECK(node.has_position);
            // The filter sits in the third column of the signal chain. Its column is
            // structural and worth pinning; its exact row is the layout algorithm's
            // business and would make this test fail every time that is tuned.
            // Columns opened from 400 to 440 apart when the graph nodes learned to
            // stack their knobs on shared axes and grew a few pixels doing it.
            CHECK_NEAR(node.x, 880.0, 0.001);
        }
    }
    CHECK_MESSAGE(found, "the filter node should be in the example patch");

    // Every shipped example is laid out on the editor's grid. A stray off-grid position
    // means someone saved from a tool that does not respect it.
    for (const soundgraph::NodeDescription& node : graph.nodes) {
        if (!node.has_position) {
            continue;
        }
        CHECK_MESSAGE(std::fmod(node.x, 40.0f) == 0.0f && std::fmod(node.y, 40.0f) == 0.0f,
                      node.id + " sits off the 40 grid");
    }
}

TEST(cable_waypoints_round_trip) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(
        R"({"schema_version": 1,
            "nodes": [{"id": "a", "type": "SineOscillator"}, {"id": "out", "type": "StereoOutput"}],
            "connections": [{"from": {"node": "a", "port": "out"},
                             "to": {"node": "out", "port": "left"},
                             "waypoint": {"x": 320, "y": -80}}]})",
        graph, diagnostics));

    CHECK(graph.connections[0].has_waypoint);
    CHECK_NEAR(graph.connections[0].waypoint_x, 320.0, 0.001);
    CHECK_NEAR(graph.connections[0].waypoint_y, -80.0, 0.001);

    // A dragged cable is layout, and layout has to survive a save like any other.
    GraphDescription reloaded;
    const std::string text = soundgraph::write_patch(graph, true);
    CHECK(text.find("\"waypoint\"") != std::string::npos);
    CHECK(soundgraph::parse_patch(text, reloaded, diagnostics));
    CHECK(reloaded.connections[0].has_waypoint);
    CHECK_NEAR(reloaded.connections[0].waypoint_x, 320.0, 0.001);

    // And a patch without one must not grow the field.
    GraphDescription plain;
    CHECK(soundgraph::parse_patch(
        R"({"schema_version": 1, "nodes": [], "connections": []})", plain, diagnostics));
    CHECK(soundgraph::write_patch(plain, true).find("waypoint") == std::string::npos);
}

TEST(malformed_json_says_where_the_problem_is) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::parse_patch("{ \"schema_version\": 1, \"nodes\": [ }", graph, diagnostics));
    CHECK(has_code(diagnostics, "invalid_json"));
    CHECK(diagnostics.front().message.find("line") != std::string::npos);
}

TEST(a_patch_without_a_schema_version_is_refused) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::parse_patch("{ \"nodes\": [] }", graph, diagnostics));
    CHECK(has_code(diagnostics, "missing_schema_version"));
    CHECK(!diagnostics.front().suggestion.empty());
}

TEST(a_node_without_an_id_is_refused) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::parse_patch(
        R"({"schema_version": 1, "nodes": [{"type": "Gain"}], "connections": []})", graph,
        diagnostics));
    CHECK(has_code(diagnostics, "node_missing_id"));
}

TEST(a_malformed_connection_is_reported_by_index) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::parse_patch(
        R"({"schema_version": 1, "nodes": [],
            "connections": [{"from": {"node": "a"}, "to": {"node": "b", "port": "in"}}]})",
        graph, diagnostics));
    CHECK(has_code(diagnostics, "connection_malformed_endpoint"));
}

TEST(a_non_numeric_parameter_warns_and_is_skipped) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(
        R"({"schema_version": 1,
            "nodes": [{"id": "g", "type": "Gain", "parameters": {"gain": "loud"}}],
            "connections": []})",
        graph, diagnostics));
    CHECK(has_code(diagnostics, "parameter_not_a_number"));
    CHECK(graph.nodes[0].parameters.empty());
}

TEST(text_with_escapes_and_non_ascii_round_trips) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(
        "{\"schema_version\": 1, \"metadata\": {\"name\": \"caf\\u00e9 \\\"quoted\\\"\\n\\ttabbed\"},"
        " \"nodes\": [], \"connections\": []}",
        graph, diagnostics));

    const std::string name = graph.metadata_value("name");
    CHECK(name.find("caf\xc3\xa9") != std::string::npos);
    CHECK(name.find('"') != std::string::npos);
    CHECK(name.find('\n') != std::string::npos);

    GraphDescription reloaded;
    CHECK(soundgraph::parse_patch(soundgraph::write_patch(graph, true), reloaded, diagnostics));
    CHECK(reloaded.metadata_value("name") == name);
}

TEST(diagnostics_serialize_with_the_nodes_and_connections_they_name) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(
        R"({"schema_version": 1,
            "nodes": [{"id": "a", "type": "Gain"}, {"id": "b", "type": "Gain"}],
            "connections": [{"from": {"node": "a", "port": "out"}, "to": {"node": "b", "port": "in"}},
                            {"from": {"node": "b", "port": "out"}, "to": {"node": "a", "port": "in"}}]})",
        graph, diagnostics));
    CHECK(!soundgraph::validate(graph, soundgraph::NodeRegistry::builtin(), diagnostics));

    const std::string json = soundgraph::write_diagnostics(diagnostics, false);
    CHECK(json.find("\"severity\":\"error\"") != std::string::npos);
    CHECK(json.find("\"code\":\"zero_delay_cycle\"") != std::string::npos);
    // A frontend has to be able to highlight the actual loop, not just print a sentence.
    CHECK(json.find("\"nodes\":[\"a\",\"b\"]") != std::string::npos);
    CHECK(json.find("\"connections\":") != std::string::npos);
    CHECK(json.find("\"suggestion\":") != std::string::npos);
}

TEST(the_registry_serializes_everything_an_editor_needs) {
    const std::string json =
        soundgraph::write_registry(soundgraph::NodeRegistry::builtin(), false);

    // An editor builds its palette, its type checking and its search from this alone.
    CHECK(json.find("\"name\":\"StateVariableFilter\"") != std::string::npos);
    CHECK(json.find("\"display_name\":\"Filter\"") != std::string::npos);
    CHECK(json.find("\"category\":\"Filters\"") != std::string::npos);
    CHECK(json.find("\"search_terms\":[") != std::string::npos);
    CHECK(json.find("remove high frequencies") != std::string::npos);
    CHECK(json.find("\"required\":true") != std::string::npos);
    CHECK(json.find("\"summing\":true") != std::string::npos);
    CHECK(json.find("\"scaling\":\"exponential\"") != std::string::npos);
    CHECK(json.find("\"enum\":[\"lowpass\"") != std::string::npos);
    CHECK(json.find("\"breaks_feedback\":true") != std::string::npos);
    CHECK(json.find("\"role\":\"host_audio_sink\"") != std::string::npos);
    CHECK(json.find("\"receives_notes\":true") != std::string::npos);

    // And it has to parse back, since that is what the browser actually does with it.
    GraphDescription unused;
    std::vector<Diagnostic> diagnostics;
    soundgraph::parse_patch(json, unused, diagnostics);
    CHECK_MESSAGE(!has_code(diagnostics, "invalid_json"), "the registry dump must be valid JSON");
}

TEST(missing_files_are_reported_rather_than_crashing) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::load_patch("no/such/patch.json", graph, diagnostics));
    CHECK(has_code(diagnostics, "file_not_readable"));
}

TEST(an_empty_patch_is_valid_but_silent) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(R"({"schema_version": 1, "nodes": [], "connections": []})", graph,
                                  diagnostics));
    CHECK(soundgraph::validate(graph, soundgraph::NodeRegistry::builtin(), diagnostics));
    CHECK(has_code(diagnostics, "empty_patch"));
}

TEST(arrangement_hints_survive_a_round_trip) {
    // Presentation only, and optional — but optional does not mean droppable. An editor
    // that arranges a rack and saves has to get the same rack back on open, or the hint
    // is decorative and nobody will trust it.
    const char* text = R"({
      "schema_version": 1,
      "arrangement": {"rack_order": ["out", "amp", "osc"]},
      "nodes": [
        {"id": "osc", "type": "SineOscillator"},
        {"id": "amp", "type": "Gain"},
        {"id": "out", "type": "StereoOutput"}
      ],
      "connections": [
        {"from": {"node": "osc", "port": "out"}, "to": {"node": "amp", "port": "in"}},
        {"from": {"node": "amp", "port": "out"}, "to": {"node": "out", "port": "left"}}
      ]
    })";

    std::vector<soundgraph::Diagnostic> diagnostics;
    soundgraph::GraphDescription description;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));
    CHECK(description.arrangement.rack_order.size() == 3);
    CHECK(description.arrangement.rack_order[0] == "out");
    CHECK(description.arrangement.rack_order[2] == "osc");

    const std::string written = soundgraph::write_patch(description);
    soundgraph::GraphDescription reloaded;
    std::vector<soundgraph::Diagnostic> again;
    CHECK(soundgraph::parse_patch(written, reloaded, again));
    CHECK(reloaded.arrangement.rack_order == description.arrangement.rack_order);
}

TEST(a_patch_with_no_arrangement_does_not_grow_one) {
    // The hint is optional in both directions: a file that never had one must not come
    // back with an empty object in it, or every patch in the repository changes the first
    // time it is opened and saved.
    const char* text = R"({
      "schema_version": 1,
      "nodes": [{"id": "out", "type": "StereoOutput"}],
      "connections": []
    })";

    std::vector<soundgraph::Diagnostic> diagnostics;
    soundgraph::GraphDescription description;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));
    CHECK(description.arrangement.empty());
    CHECK(soundgraph::write_patch(description).find("arrangement") == std::string::npos);
}

TEST(a_malformed_arrangement_is_ignored_rather_than_fatal) {
    // A patch whose rack order is nonsense still makes exactly the right sound. Refusing
    // to open it over a picture would be the wrong trade.
    const char* text = R"({
      "schema_version": 1,
      "arrangement": {"rack_order": "not an array"},
      "nodes": [{"id": "out", "type": "StereoOutput"}],
      "connections": []
    })";

    std::vector<soundgraph::Diagnostic> diagnostics;
    soundgraph::GraphDescription description;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));
    CHECK(description.arrangement.empty());
}


// ---------------------------------------------------------------------------------
// Modules — docs/modules-design.md, stage 1. The happy path is the design document's
// own example, which keeps the two from drifting apart.
// ---------------------------------------------------------------------------------

namespace {

std::string modular_patch() {
    return R"({
        "schema_version": 2,
        "modules": {
            "voice": {
                "description": "A gated sine.",
                "nodes": [
                    { "id": "osc", "type": "SineOscillator", "parameters": { "frequency": 220 } },
                    { "id": "env", "type": "ADSR", "parameters": { "attack": 0.01 } },
                    { "id": "vca", "type": "Multiply" }
                ],
                "connections": [
                    { "from": { "node": "osc", "port": "out" }, "to": { "node": "vca", "port": "a" } },
                    { "from": { "node": "env", "port": "out" }, "to": { "node": "vca", "port": "b" } }
                ],
                "inputs": [
                    { "name": "pitch", "node": "osc", "port": "frequency" },
                    { "name": "gate", "node": "env", "port": "gate" }
                ],
                "outputs": [
                    { "name": "out", "node": "vca", "port": "out" }
                ],
                "parameters": [
                    { "name": "frequency", "node": "osc", "parameter": "frequency" }
                ]
            }
        },
        "nodes": [
            { "id": "note", "type": "NoteInput" },
            { "id": "a", "type": "module", "module": "voice",
              "parameters": { "frequency": 330 } },
            { "id": "b", "type": "module", "module": "voice" },
            { "id": "out", "type": "StereoOutput" }
        ],
        "connections": [
            { "from": { "node": "note", "port": "frequency" }, "to": { "node": "a", "port": "pitch" } },
            { "from": { "node": "note", "port": "gate" }, "to": { "node": "a", "port": "gate" } },
            { "from": { "node": "note", "port": "frequency" }, "to": { "node": "b", "port": "pitch" } },
            { "from": { "node": "note", "port": "gate" }, "to": { "node": "b", "port": "gate" } },
            { "from": { "node": "a", "port": "out" }, "to": { "node": "out", "port": "left" } },
            { "from": { "node": "b", "port": "out" }, "to": { "node": "out", "port": "right" } }
        ],
        "controls": [
            { "id": "tune", "target": { "node": "b", "parameter": "frequency" } }
        ]
    })";
}

}  // namespace

TEST(modules_expand_into_plain_nodes) {
    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(modular_patch(), description, diagnostics));

    // The engine's view is flat and version 1 — the whole trick in two assertions.
    CHECK(description.schema_version == 1);
    CHECK(description.find_node("a.osc") != nullptr);
    CHECK(description.find_node("a") == nullptr);

    // 2 plain nodes + 2 instances x 3 inner nodes.
    CHECK(description.nodes.size() == 8);

    // The instance's exported parameter override reached the inner node; the other
    // instance kept the definition's default.
    const soundgraph::NodeDescription* a_osc = description.find_node("a.osc");
    const soundgraph::ParameterValue* a_freq = a_osc->find_parameter("frequency");
    CHECK(a_freq != nullptr && std::fabs(a_freq->value - 330.0) < 1e-9);
    const soundgraph::NodeDescription* b_osc = description.find_node("b.osc");
    const soundgraph::ParameterValue* b_freq = b_osc->find_parameter("frequency");
    CHECK(b_freq != nullptr && std::fabs(b_freq->value - 220.0) < 1e-9);

    // Boundary connections resolved through the declared surface.
    bool note_to_a_osc = false;
    for (const soundgraph::ConnectionDescription& connection : description.connections) {
        if (connection.from_node == "note" && connection.to_node == "a.osc" &&
            connection.to_port == "frequency") {
            note_to_a_osc = true;
        }
    }
    CHECK(note_to_a_osc);

    // The control reached through the facade too.
    CHECK(description.controls.size() == 1);
    CHECK(description.controls[0].target.node == "b.osc");
    CHECK(description.controls[0].target.parameter == "frequency");

    // And the expanded graph actually builds and validates.
    soundgraph::Graph graph;
    std::vector<Diagnostic> build_diagnostics;
    CHECK(graph.build(description, soundgraph::NodeRegistry::builtin(),
                      soundgraph::PrepareContext(), build_diagnostics));
}

TEST(modules_round_trip_preserves_the_hierarchy) {
    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(modular_patch(), description, diagnostics));

    const std::string written = soundgraph::write_patch(description);
    CHECK(written.find("\"modules\"") != std::string::npos);
    CHECK(written.find("\"schema_version\": 2") != std::string::npos);
    CHECK(written.find("a.osc") == std::string::npos);  // never the flattened form

    // And the written form parses back to the same flattened graph.
    GraphDescription again;
    std::vector<Diagnostic> again_diagnostics;
    CHECK(soundgraph::parse_patch(written, again, again_diagnostics));
    CHECK(again.nodes.size() == description.nodes.size());
    CHECK(again.connections.size() == description.connections.size());
    CHECK(soundgraph::write_patch(again) == written);  // stable from then on
}

namespace {

// The same voice wearing a face: two exports, one of them off the panel, one renamed,
// and a row naming something that does not exist.
std::string panelled_patch() {
    std::string text = modular_patch();
    const std::string exports =
        R"("parameters": [
                    { "name": "frequency", "node": "osc", "parameter": "frequency" },
                    { "name": "attack", "node": "env", "parameter": "attack" }
                ],
                "panel": {
                    "rows": [["attack", "ghost"]],
                    "labels": { "attack": "Snap" }
                })";
    const std::string original =
        R"("parameters": [
                    { "name": "frequency", "node": "osc", "parameter": "frequency" }
                ])";
    const std::size_t at = text.find(original);
    CHECK(at != std::string::npos);  // the fixture moved; this test moved with it
    text.replace(at, original.size(), exports);
    return text;
}

}  // namespace

TEST(module_panels_are_presentation_and_survive_the_round_trip) {
    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    // A row naming a parameter the module does not export is a missing knob, not a
    // refused patch — the rule arrangement follows, because a panel is presentation.
    CHECK(soundgraph::parse_patch(panelled_patch(), description, diagnostics));

    const soundgraph::ModuleDescription* voice = description.find_module("voice");
    CHECK(voice != nullptr);
    CHECK(voice->panel.rows.size() == 1);
    // "ghost" is kept verbatim rather than dropped here. A loader is not the place to
    // decide a knob is unwanted: a tool that saves a patch it does not fully understand
    // must give the file back intact, and it is the surface that renders the panel which
    // skips a name it cannot resolve. Leniency at the edge, fidelity in the middle.
    CHECK(voice->panel.rows[0].size() == 2);
    CHECK(voice->panel.rows[0][0] == "attack");
    const std::string* caption = voice->panel.label_for("attack");
    CHECK(caption != nullptr && *caption == "Snap");
    CHECK(voice->panel.label_for("frequency") == nullptr);

    // The face is not the surface: "frequency" is off the panel and still exported, so
    // instance "a" still overrides it and the engine still sees 330.
    const soundgraph::NodeDescription* a_osc = description.find_node("a.osc");
    const soundgraph::ParameterValue* a_freq = a_osc->find_parameter("frequency");
    CHECK(a_freq != nullptr && std::fabs(a_freq->value - 330.0) < 1e-9);

    // And the panel changes nothing about what gets built.
    GraphDescription plain;
    std::vector<Diagnostic> plain_diagnostics;
    CHECK(soundgraph::parse_patch(modular_patch(), plain, plain_diagnostics));
    CHECK(description.nodes.size() == plain.nodes.size());
    CHECK(description.connections.size() == plain.connections.size());
}

TEST(module_panels_round_trip_through_the_hierarchy) {
    // Written from a description that still carries its modules — the editor's path,
    // not the engine's. parse_patch flattens, so the hierarchy is rebuilt here the way
    // an authoring tool holds it.
    GraphDescription description;
    description.schema_version = 2;
    soundgraph::ModuleDescription voice;
    voice.name = "voice";
    voice.nodes.push_back(soundgraph::NodeDescription{});
    voice.nodes.back().id = "env";
    voice.nodes.back().type = "ADSR";
    voice.parameters.push_back(
        soundgraph::ModuleParameterDescription{"attack", "env", "attack"});
    voice.parameters.push_back(
        soundgraph::ModuleParameterDescription{"release", "env", "release"});
    voice.panel.rows.push_back({"attack"});
    voice.panel.rows.push_back({"release"});
    voice.panel.labels.push_back(soundgraph::ModulePanelLabel{"attack", "Snap"});
    description.modules.push_back(std::move(voice));

    const std::string written = soundgraph::write_patch(description);
    CHECK(written.find("\"panel\"") != std::string::npos);
    CHECK(written.find("\"Snap\"") != std::string::npos);

    GraphDescription again;
    std::vector<Diagnostic> again_diagnostics;
    CHECK(soundgraph::parse_patch(written, again, again_diagnostics));
    CHECK(soundgraph::write_patch(again) == written);  // stable, panel and all
}

TEST(modules_refuse_the_documented_abuses) {
    auto refuses = [](std::string text, const std::string& code) {
        GraphDescription description;
        std::vector<Diagnostic> diagnostics;
        const bool ok = soundgraph::parse_patch(text, description, diagnostics);
        return !ok && has_code(diagnostics, code);
    };

    // Modules under version 1: refused, loudly.
    std::string v1 = modular_patch();
    v1.replace(v1.find("\"schema_version\": 2"), 19, "\"schema_version\": 1");
    CHECK(refuses(v1, "modules_require_v2"));

    // An instance of a module the patch does not define.
    std::string unknown = modular_patch();
    unknown.replace(unknown.find("\"module\": \"voice\""), 17, "\"module\": \"ghost\"");
    CHECK(refuses(unknown, "unknown_module"));

    // A connection to a port the module does not declare.
    std::string undeclared = modular_patch();
    undeclared.replace(undeclared.find("\"port\": \"pitch\""), 15, "\"port\": \"secret\"");
    CHECK(refuses(undeclared, "undeclared_module_port"));

    // Setting a parameter the module does not export.
    std::string unexported = modular_patch();
    unexported.replace(unexported.find("{ \"frequency\": 330 }"), 20, "{ \"gain\": 1 }");
    CHECK(refuses(unexported, "parameter_not_exported"));

    // A module inside itself. Nesting is allowed now — see the test below — so what is
    // refused is the one shape of it that has no end: a definition that reaches itself.
    // Here directly; the indirect case is covered where nesting is exercised.
    std::string looping = modular_patch();
    looping.replace(looping.find("\"id\": \"env\", \"type\": \"ADSR\""), 27,
                    "\"id\": \"env\", \"type\": \"module\", \"module\": \"voice\"");
    CHECK(refuses(looping, "module_cycle"));

    // A top-level node whose literal name collides with an expansion.
    std::string collision = modular_patch();
    collision.replace(collision.find("\"id\": \"note\""), 12, "\"id\": \"a.osc\"");
    CHECK(refuses(collision, "module_id_collision"));
}


// ---------------------------------------------------------------------------------
// Seams
//
// "Input" and "Output" are a graph's edges written as nodes. Like modules they are
// notation: no dsp-core node is ever built for one, and a host-bound seam becomes the
// terminal that already speaks to that host. See docs/modules-design.md.
// ---------------------------------------------------------------------------------

namespace {

std::string seam_patch() {
    return R"({
      "schema_version": 1,
      "nodes": [
        { "id": "kb",  "type": "Input",  "host": "note" },
        { "id": "osc", "type": "SawOscillator", "parameters": { "frequency": 220 } },
        { "id": "out", "type": "Output", "host": "stereo" }
      ],
      "connections": [
        { "from": { "node": "kb",  "port": "frequency" }, "to": { "node": "osc", "port": "frequency" } },
        { "from": { "node": "osc", "port": "out" },       "to": { "node": "out", "port": "left" } }
      ]
    })";
}

}  // namespace

TEST(a_host_bound_seam_is_the_terminal_it_names) {
    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(seam_patch(), description, diagnostics));

    // The engine gets what it always got. Nothing downstream of the loader — not the
    // scheduler, not the golden manifest, not the firmware — learns the word "seam".
    const soundgraph::NodeDescription* keyboard = description.find_node("kb");
    const soundgraph::NodeDescription* output = description.find_node("out");
    CHECK(keyboard != nullptr && keyboard->type == "NoteInput");
    CHECK(output != nullptr && output->type == "StereoOutput");
    CHECK(keyboard->host.empty());  // consumed, not carried into the flat view

    // And the cables are untouched: a seam keeps its id and its ports, so converting it
    // is a rename rather than a rewiring.
    CHECK(description.connections.size() == 2);
    CHECK(description.connections[0].from_node == "kb");
    CHECK(description.connections[0].from_port == "frequency");
}

TEST(a_seam_is_handed_back_as_a_seam) {
    // The loader must not quietly rewrite somebody's document into the older way of
    // saying the same thing. The authored view keeps the spelling it was given.
    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(seam_patch(), description, diagnostics));

    const std::string written = soundgraph::write_patch(description);
    CHECK(written.find("\"Input\"") != std::string::npos);
    CHECK(written.find("\"host\": \"note\"") != std::string::npos);
    CHECK(written.find("NoteInput") == std::string::npos);

    GraphDescription again;
    std::vector<Diagnostic> again_diagnostics;
    CHECK(soundgraph::parse_patch(written, again, again_diagnostics));
    CHECK(soundgraph::write_patch(again) == written);  // stable from then on
}

TEST(an_unbound_top_level_seam_is_a_socket_with_nothing_in_it) {
    // Not an error. A port at the top level with no host is one the machine is not
    // driving at the moment — a patch mid-build, or a patch meant to be used as a module,
    // which declares its ports precisely so that a parent can drive them later.
    const std::string binding = ",  \"host\": \"note\"";
    std::string text = seam_patch();
    const std::size_t at = text.find(binding);
    CHECK(at != std::string::npos);
    text = text.replace(at, binding.size(), "");

    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));

    // Spliced, like a module's port: there is no dsp-core node for an empty socket.
    CHECK(description.find_node("kb") == nullptr);
    CHECK(description.find_node("osc") != nullptr);
    CHECK(description.find_node("out") != nullptr);

    // And the cable it fed goes with it, or the graph would name a node it does not have.
    // The oscillator keeps its parameter value and simply has nothing driving it, which
    // is what an unplugged input does on any instrument.
    CHECK(description.connections.size() == 1);
    CHECK(description.connections[0].from_node == "osc");

    // The document is handed back the way it was written. Splicing is what the engine
    // sees, not an edit to somebody's file: the socket is still there to plug into.
    const std::string written = soundgraph::write_patch(description);
    CHECK(written.find("\"kb\"") != std::string::npos);
    CHECK(written.find("\"host\": \"note\"") == std::string::npos);
    CHECK(written.find("\"host\": \"stereo\"") != std::string::npos);  // the bound one stays
}

TEST(seams_hold_the_scope_rule) {
    auto refuses = [](const std::string& text, const std::string& code) {
        GraphDescription description;
        std::vector<Diagnostic> diagnostics;
        const bool ok = soundgraph::parse_patch(text, description, diagnostics);
        return !ok && has_code(diagnostics, code);
    };

    // Exact substrings, asserted present before they are used. A find() that quietly
    // returns npos hands string::replace a position it refuses, and the suite dies with
    // a fastfail rather than a failed check — which is how this test first "passed".
    auto swap = [](std::string text, const std::string& from, const std::string& to) {
        const std::size_t at = text.find(from);
        CHECK(at != std::string::npos);
        return text.replace(at, from.size(), to);
    };

    // A host this runtime does not have is refused rather than ignored: a patch that
    // silently loses its keyboard is worse than one that will not open.
    CHECK(refuses(swap(seam_patch(), "\"host\": \"note\"", "\"host\": \"trumpet\""),
                  "unknown_seam_host"));

    // And the other direction. A module's seams are its ports; binding one to the
    // machine would mean every instance shared that one keyboard, which is not what
    // having two of something means.
    const std::string inside = R"({
      "schema_version": 2,
      "modules": {
        "voice": {
          "nodes": [
            { "id": "gate", "type": "Input", "host": "note" },
            { "id": "env",  "type": "ADSR" }
          ],
          "connections": [],
          "outputs": [ { "name": "out", "node": "env", "port": "out" } ]
        }
      },
      "nodes": [
        { "id": "v",   "type": "module", "module": "voice" },
        { "id": "out", "type": "Output", "host": "stereo" }
      ],
      "connections": [
        { "from": { "node": "v", "port": "out" }, "to": { "node": "out", "port": "left" } }
      ]
    })";
    CHECK(refuses(inside, "module_seam_bound_to_host"));
}

TEST(the_two_spellings_flatten_to_the_same_graph) {
    // The claim the whole seam idea rests on, held where it is cheapest and sharpest.
    // Rendering both and comparing bytes says they sound the same; comparing the
    // flattened views says *why*, and cannot be flaky about it. The audio identity was
    // confirmed once by hand with sg-render on first-synth.json — 192044 bytes, cmp
    // clean — and this is the check that keeps it true.
    const std::string terminals = R"({
      "schema_version": 1,
      "nodes": [
        { "id": "kb",  "type": "NoteInput" },
        { "id": "osc", "type": "SawOscillator", "parameters": { "frequency": 220 } },
        { "id": "out", "type": "StereoOutput" }
      ],
      "connections": [
        { "from": { "node": "kb",  "port": "frequency" }, "to": { "node": "osc", "port": "frequency" } },
        { "from": { "node": "osc", "port": "out" },       "to": { "node": "out", "port": "left" } }
      ]
    })";

    GraphDescription old_way;
    GraphDescription new_way;
    std::vector<Diagnostic> old_diagnostics;
    std::vector<Diagnostic> new_diagnostics;
    CHECK(soundgraph::parse_patch(terminals, old_way, old_diagnostics));
    CHECK(soundgraph::parse_patch(seam_patch(), new_way, new_diagnostics));

    CHECK(old_way.nodes.size() == new_way.nodes.size());
    for (std::size_t i = 0; i < old_way.nodes.size(); ++i) {
        CHECK(old_way.nodes[i].id == new_way.nodes[i].id);
        CHECK(old_way.nodes[i].type == new_way.nodes[i].type);
        CHECK(old_way.nodes[i].parameters.size() == new_way.nodes[i].parameters.size());
    }
    CHECK(old_way.connections.size() == new_way.connections.size());
    for (std::size_t i = 0; i < old_way.connections.size(); ++i) {
        CHECK(old_way.connections[i].from_node == new_way.connections[i].from_node);
        CHECK(old_way.connections[i].from_port == new_way.connections[i].from_port);
        CHECK(old_way.connections[i].to_node == new_way.connections[i].to_node);
        CHECK(old_way.connections[i].to_port == new_way.connections[i].to_port);
    }
}

TEST(a_module_can_draw_its_ports_as_seams) {
    // The same module twice: once with a declared binding, once with a seam. Both
    // flatten to the same graph, which is what makes seams a spelling and not a feature.
    const std::string by_binding_text = R"({
      "schema_version": 2,
      "modules": {
        "voice": {
          "nodes": [
            { "id": "env", "type": "ADSR" },
            { "id": "amp", "type": "Gain" }
          ],
          "connections": [
            { "from": { "node": "env", "port": "out" }, "to": { "node": "amp", "port": "gain" } }
          ],
          "inputs":  [ { "name": "gate", "node": "env", "port": "gate" } ],
          "outputs": [ { "name": "out",  "node": "amp", "port": "out" } ]
        }
      },
      "nodes": [
        { "id": "kb",  "type": "NoteInput" },
        { "id": "v",   "type": "module", "module": "voice" },
        { "id": "out", "type": "StereoOutput" }
      ],
      "connections": [
        { "from": { "node": "kb", "port": "gate" }, "to": { "node": "v", "port": "gate" } },
        { "from": { "node": "v", "port": "out" },   "to": { "node": "out", "port": "left" } }
      ]
    })";

    const std::string by_seam_text = R"({
      "schema_version": 2,
      "modules": {
        "voice": {
          "nodes": [
            { "id": "gate", "type": "Input" },
            { "id": "env",  "type": "ADSR" },
            { "id": "amp",  "type": "Gain" }
          ],
          "connections": [
            { "from": { "node": "gate", "port": "out" }, "to": { "node": "env", "port": "gate" } },
            { "from": { "node": "env",  "port": "out" }, "to": { "node": "amp", "port": "gain" } }
          ],
          "outputs": [ { "name": "out", "node": "amp", "port": "out" } ]
        }
      },
      "nodes": [
        { "id": "kb",  "type": "NoteInput" },
        { "id": "v",   "type": "module", "module": "voice" },
        { "id": "out", "type": "StereoOutput" }
      ],
      "connections": [
        { "from": { "node": "kb", "port": "gate" }, "to": { "node": "v", "port": "gate" } },
        { "from": { "node": "v", "port": "out" },   "to": { "node": "out", "port": "left" } }
      ]
    })";

    GraphDescription by_binding;
    GraphDescription by_seam;
    std::vector<Diagnostic> binding_diagnostics;
    std::vector<Diagnostic> seam_diagnostics;
    CHECK(soundgraph::parse_patch(by_binding_text, by_binding, binding_diagnostics));
    CHECK(soundgraph::parse_patch(by_seam_text, by_seam, seam_diagnostics));

    // No node is built for the seam, and the outside cable lands where it pointed.
    CHECK(by_binding.nodes.size() == by_seam.nodes.size());
    CHECK(by_seam.find_node("v.gate") == nullptr);
    CHECK(by_seam.find_node("v.env") != nullptr);
    CHECK(by_binding.connections.size() == by_seam.connections.size());
    bool landed = false;
    for (const auto& wire : by_seam.connections) {
        if (wire.from_node == "kb" && wire.to_node == "v.env" && wire.to_port == "gate") {
            landed = true;
        }
    }
    CHECK(landed);
}

TEST(a_trimmed_stereo_seam_stands_as_a_stereo_level) {
    // A stereo out that carries a level becomes a StereoLevel under the seam's id:
    // one knob, two wires, channels kept apart. The legacy whole-seam spelling
    // still resolves and still means both channels.
    const std::string text = R"({
      "schema_version": 2,
      "modules": {
        "voice": {
          "nodes": [
            { "id": "osc", "type": "SineOscillator" },
            { "id": "out", "type": "Output", "parameters": { "level": 0.5 } }
          ],
          "connections": [
            { "from": { "node": "osc", "port": "out" }, "to": { "node": "out", "port": "left" } },
            { "from": { "node": "osc", "port": "out" }, "to": { "node": "out", "port": "right" } }
          ],
          "parameters": [ { "name": "level", "node": "out", "parameter": "level" } ]
        }
      },
      "nodes": [
        { "id": "v",   "type": "module", "module": "voice",
          "parameters": { "level": 0.25 } },
        { "id": "out", "type": "StereoOutput" }
      ],
      "connections": [
        { "from": { "node": "v", "port": "out" }, "to": { "node": "out", "port": "left" } }
      ]
    })";

    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));

    const soundgraph::NodeDescription* trim = description.find_node("v.out");
    CHECK(trim != nullptr);
    if (trim != nullptr) {
        CHECK(trim->type == "StereoLevel");
        const soundgraph::ParameterValue* level = trim->find_parameter("level");
        CHECK(level != nullptr);
        CHECK(level != nullptr && level->value == 0.25);
    }

    // Inner wires keep their channel names — the pair's inlets are the node's own.
    int named_channels = 0;
    int legacy_fanout = 0;
    for (const auto& wire : description.connections) {
        if (wire.from_node == "v.osc" && wire.to_node == "v.out" &&
            (wire.to_port == "left" || wire.to_port == "right")) {
            ++named_channels;
        }
        if (wire.from_node == "v.out" && wire.to_node == "out") {
            ++legacy_fanout;
        }
    }
    CHECK(named_channels == 2);
    // The legacy spelling meant both channels, and still does.
    CHECK(legacy_fanout == 2);
}

TEST(a_stereo_seam_answers_to_its_channels) {
    // The pair's channels are ports of the instance in their own right, and a
    // cable aimed at one carries that channel alone.
    const std::string text = R"({
      "schema_version": 2,
      "modules": {
        "voice": {
          "nodes": [
            { "id": "oscl", "type": "SineOscillator" },
            { "id": "oscr", "type": "SineOscillator" },
            { "id": "out", "type": "Output", "parameters": { "level": 0.5 } }
          ],
          "connections": [
            { "from": { "node": "oscl", "port": "out" }, "to": { "node": "out", "port": "left" } },
            { "from": { "node": "oscr", "port": "out" }, "to": { "node": "out", "port": "right" } }
          ],
          "parameters": [ { "name": "level", "node": "out", "parameter": "level" } ]
        }
      },
      "nodes": [
        { "id": "v",   "type": "module", "module": "voice" },
        { "id": "out", "type": "StereoOutput" }
      ],
      "connections": [
        { "from": { "node": "v", "port": "left" },  "to": { "node": "out", "port": "left" } },
        { "from": { "node": "v", "port": "right" }, "to": { "node": "out", "port": "right" } }
      ]
    })";

    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));
    bool left_clean = false;
    bool right_clean = false;
    int crossed = 0;
    for (const auto& wire : description.connections) {
        if (wire.from_node != "v.out") {
            continue;
        }
        if (wire.from_port == "left" && wire.to_port == "left") {
            left_clean = true;
        } else if (wire.from_port == "right" && wire.to_port == "right") {
            right_clean = true;
        } else {
            ++crossed;
        }
    }
    CHECK(left_clean);
    CHECK(right_clean);
    CHECK(crossed == 0);
}

TEST(a_trimmed_mono_seam_still_stands_as_a_level_node) {
    // One inlet, not a pair: the mono Level with its summing inlet, as before.
    const std::string text = R"({
      "schema_version": 2,
      "modules": {
        "voice": {
          "nodes": [
            { "id": "osc", "type": "SineOscillator" },
            { "id": "out", "type": "Output", "parameters": { "level": 0.5 } }
          ],
          "connections": [
            { "from": { "node": "osc", "port": "out" }, "to": { "node": "out", "port": "in" } }
          ],
          "parameters": [ { "name": "level", "node": "out", "parameter": "level" } ]
        }
      },
      "nodes": [
        { "id": "v",   "type": "module", "module": "voice" },
        { "id": "out", "type": "StereoOutput" }
      ],
      "connections": [
        { "from": { "node": "v", "port": "out" }, "to": { "node": "out", "port": "left" } }
      ]
    })";

    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));
    const soundgraph::NodeDescription* trim = description.find_node("v.out");
    CHECK(trim != nullptr);
    CHECK(trim != nullptr && trim->type == "Level");
    bool summed = false;
    for (const auto& wire : description.connections) {
        if (wire.from_node == "v.osc" && wire.to_node == "v.out" && wire.to_port == "in") {
            summed = true;
        }
    }
    CHECK(summed);
}

TEST(an_untrimmed_output_seam_still_splices_away) {
    // The other half of the rule: a seam carrying no level and reached by no export
    // expands exactly as it always has — no node, cables re-aimed at the feeders —
    // so every patch that never used the trim is untouched to the byte.
    const std::string text = R"({
      "schema_version": 2,
      "modules": {
        "voice": {
          "nodes": [
            { "id": "osc", "type": "SineOscillator" },
            { "id": "out", "type": "Output" }
          ],
          "connections": [
            { "from": { "node": "osc", "port": "out" }, "to": { "node": "out", "port": "left" } }
          ]
        }
      },
      "nodes": [
        { "id": "v",   "type": "module", "module": "voice" },
        { "id": "out", "type": "StereoOutput" }
      ],
      "connections": [
        { "from": { "node": "v", "port": "out" }, "to": { "node": "out", "port": "left" } }
      ]
    })";

    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));
    CHECK(description.find_node("v.out") == nullptr);
    bool direct = false;
    for (const auto& wire : description.connections) {
        if (wire.from_node == "v.osc" && wire.to_node == "out" && wire.to_port == "left") {
            direct = true;
        }
    }
    CHECK(direct);
}

TEST(a_seam_fans_out_to_everything_it_feeds) {
    // One port, three places. A declared binding could never say this — it names exactly
    // one (node, port) — so this is the case seams add rather than restate.
    const std::string text = R"({
      "schema_version": 2,
      "modules": {
        "pair": {
          "nodes": [
            { "id": "gate", "type": "Input" },
            { "id": "a", "type": "ADSR" },
            { "id": "b", "type": "ADSR" }
          ],
          "connections": [
            { "from": { "node": "gate", "port": "out" }, "to": { "node": "a", "port": "gate" } },
            { "from": { "node": "gate", "port": "out" }, "to": { "node": "b", "port": "gate" } }
          ],
          "outputs": [ { "name": "out", "node": "a", "port": "out" } ]
        }
      },
      "nodes": [
        { "id": "kb", "type": "NoteInput" },
        { "id": "p",  "type": "module", "module": "pair" },
        { "id": "out", "type": "StereoOutput" }
      ],
      "connections": [
        { "from": { "node": "kb", "port": "gate" }, "to": { "node": "p", "port": "gate" } },
        { "from": { "node": "p", "port": "out" },   "to": { "node": "out", "port": "left" } }
      ]
    })";

    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));

    int from_keyboard = 0;
    for (const auto& wire : description.connections) {
        if (wire.from_node == "kb" && wire.from_port == "gate") {
            ++from_keyboard;
        }
    }
    CHECK(from_keyboard == 2);  // one cable in, both envelopes gated
    CHECK(description.find_node("p.gate") == nullptr);
}

TEST(a_module_may_hold_another_module) {
    // Nesting, which is what makes a graph a graph: walk in, drill down, climb out. It
    // was refused outright to prevent one case of it — a definition reaching itself —
    // and that case is now refused by name, leaving the useful ones alone.
    //
    // `stack` holds two `amp`s in series. Neither the engine nor the golden manifest
    // learns anything new: expansion runs a level at a time until nothing is left to
    // expand, and what comes out the far end is the flat graph it always was.
    const std::string text = R"({
      "schema_version": 2,
      "modules": {
        "amp": {
          "nodes": [{ "id": "g", "type": "Gain", "parameters": { "gain": 0.5 } }],
          "connections": [],
          "inputs": [{ "name": "in", "node": "g", "port": "in" }],
          "outputs": [{ "name": "out", "node": "g", "port": "out" }]
        },
        "stack": {
          "nodes": [
            { "id": "a", "type": "module", "module": "amp" },
            { "id": "b", "type": "module", "module": "amp" }
          ],
          "connections": [
            { "from": { "node": "a", "port": "out" }, "to": { "node": "b", "port": "in" } }
          ],
          "inputs": [{ "name": "in", "node": "a", "port": "in" }],
          "outputs": [{ "name": "out", "node": "b", "port": "out" }]
        }
      },
      "nodes": [
        { "id": "osc", "type": "SawOscillator", "parameters": { "frequency": 220 } },
        { "id": "quiet", "type": "module", "module": "stack" },
        { "id": "out", "type": "Output", "host": "stereo" }
      ],
      "connections": [
        { "from": { "node": "osc", "port": "out" }, "to": { "node": "quiet", "port": "in" } },
        { "from": { "node": "quiet", "port": "out" }, "to": { "node": "out", "port": "left" } }
      ]
    })";
    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, description, diagnostics));

    // Two levels down: the ids carry the whole path, so a node knows where it came from
    // however deep it was written.
    CHECK(description.find_node("quiet.a.g") != nullptr);
    CHECK(description.find_node("quiet.b.g") != nullptr);
    CHECK(description.find_node("quiet.a") == nullptr);   // the inner instance is gone
    CHECK(description.find_node("quiet") == nullptr);     // and so is the outer one

    // And the cables run through both levels of ports: osc into the first gain, the
    // first into the second, the second out.
    int into_first = 0;
    int between = 0;
    int to_output = 0;
    for (const soundgraph::ConnectionDescription& wire : description.connections) {
        if (wire.from_node == "osc" && wire.to_node == "quiet.a.g") ++into_first;
        if (wire.from_node == "quiet.a.g" && wire.to_node == "quiet.b.g") ++between;
        if (wire.from_node == "quiet.b.g" && wire.to_node == "out") ++to_output;
    }
    CHECK(into_first == 1);
    CHECK(between == 1);
    CHECK(to_output == 1);
}

TEST(a_module_may_not_reach_itself_through_another) {
    // The indirect cycle, which no single-step check would catch: amp holds stack, stack
    // holds amp. The message names the path rather than the fact, because "amp contains
    // stack contains amp" is something a person can act on.
    const std::string text = R"({
      "schema_version": 2,
      "modules": {
        "amp": {
          "nodes": [
            { "id": "g", "type": "Gain" },
            { "id": "loop", "type": "module", "module": "stack" }
          ],
          "connections": [],
          "inputs": [{ "name": "in", "node": "g", "port": "in" }],
          "outputs": [{ "name": "out", "node": "g", "port": "out" }]
        },
        "stack": {
          "nodes": [{ "id": "a", "type": "module", "module": "amp" }],
          "connections": [],
          "inputs": [{ "name": "in", "node": "a", "port": "in" }],
          "outputs": [{ "name": "out", "node": "a", "port": "out" }]
        }
      },
      "nodes": [
        { "id": "quiet", "type": "module", "module": "stack" },
        { "id": "out", "type": "Output", "host": "stereo" }
      ],
      "connections": [
        { "from": { "node": "quiet", "port": "out" }, "to": { "node": "out", "port": "left" } }
      ]
    })";
    GraphDescription description;
    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::parse_patch(text, description, diagnostics));
    bool named_the_path = false;
    for (const Diagnostic& diagnostic : diagnostics) {
        if (diagnostic.code == "module_cycle" &&
            diagnostic.message.find("contains") != std::string::npos) {
            named_the_path = true;
        }
    }
    CHECK(named_the_path);
}

// ---- buffers ------------------------------------------------------------------------

TEST(buffers_decode_from_base64_pcm16) {
    // Two samples, little-endian: 0x4000 is 16384 -> 0.5, 0xC000 is -16384 -> -0.5.
    const std::string text = R"({
        "schema_version": 3,
        "buffers": {
            "clip": { "sample_rate": 24000, "channels": 1, "format": "pcm16",
                      "data": "AEAAwA==" }
        },
        "nodes": [
            { "id": "gate", "type": "Constant", "parameters": { "value": 1 } },
            { "id": "play", "type": "Sampler", "buffer": "clip" },
            { "id": "out", "type": "StereoOutput" }
        ],
        "connections": [
            { "from": { "node": "gate", "port": "out" }, "to": { "node": "play", "port": "gate" } },
            { "from": { "node": "play", "port": "out" }, "to": { "node": "out", "port": "left" } }
        ]
    })";
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, graph, diagnostics));
    CHECK(graph.buffers.size() == 1);
    CHECK(graph.buffers[0].id == "clip");
    CHECK_NEAR(graph.buffers[0].sample_rate, 24000.0, 1e-9);
    CHECK(graph.buffers[0].samples.size() == 2);
    CHECK_NEAR(graph.buffers[0].samples[0], 0.5, 1e-6);
    CHECK_NEAR(graph.buffers[0].samples[1], -0.5, 1e-6);
    CHECK(graph.find_node("play")->buffer == "clip");
}

TEST(buffers_survive_the_round_trip_bit_for_bit) {
    GraphDescription original;
    original.schema_version = soundgraph::kSchemaVersionBuffers;
    soundgraph::BufferDescription clip;
    clip.id = "ramp";
    clip.sample_rate = 48000.0;
    for (int i = 0; i < 200; ++i) {
        clip.samples.push_back(static_cast<float>(i - 100) / 128.0f);
    }
    original.buffers.push_back(clip);
    soundgraph::NodeDescription gate;
    gate.id = "gate";
    gate.type = "Constant";
    original.nodes.push_back(gate);
    soundgraph::NodeDescription play;
    play.id = "play";
    play.type = "Sampler";
    play.buffer = "ramp";
    original.nodes.push_back(play);
    soundgraph::NodeDescription out;
    out.id = "out";
    out.type = "StereoOutput";
    original.nodes.push_back(out);
    original.connections.push_back(soundgraph::ConnectionDescription{
        "gate", "out", "play", "gate"});
    original.connections.push_back(soundgraph::ConnectionDescription{
        "play", "out", "out", "left"});

    const std::string text = soundgraph::write_patch(original, true);
    GraphDescription reloaded;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, reloaded, diagnostics));
    CHECK(reloaded.buffers.size() == 1);
    CHECK(reloaded.buffers[0].samples.size() == original.buffers[0].samples.size());
    // 32768 on the way out and 32768 on the way back makes the pcm16 grid a fixed
    // point: what decodes re-encodes to the same bytes, so text is stable too.
    CHECK(soundgraph::write_patch(reloaded, true) == text);
}

TEST(buffer_references_and_version_are_checked) {
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    const std::string wrong_version = R"({
        "schema_version": 1,
        "buffers": { "clip": { "data": "AEAAwA==" } },
        "nodes": [ { "id": "out", "type": "StereoOutput" } ],
        "connections": []
    })";
    CHECK(!soundgraph::parse_patch(wrong_version, graph, diagnostics));
    CHECK(has_code(diagnostics, "buffers_require_v3"));

    diagnostics.clear();
    const std::string missing = R"({
        "schema_version": 3,
        "nodes": [
            { "id": "play", "type": "Sampler", "buffer": "ghost" },
            { "id": "out", "type": "StereoOutput" }
        ],
        "connections": []
    })";
    CHECK(!soundgraph::parse_patch(missing, graph, diagnostics));
    CHECK(has_code(diagnostics, "unknown_buffer"));

    diagnostics.clear();
    const std::string unreferenced = R"({
        "schema_version": 3,
        "buffers": { "clip": { "data": "AEAAwA==" } },
        "nodes": [ { "id": "out", "type": "StereoOutput" } ],
        "connections": []
    })";
    CHECK(soundgraph::parse_patch(unreferenced, graph, diagnostics));
    CHECK(has_code(diagnostics, "buffer_unreferenced"));
}

namespace {

// A graph with one Sampler playing one buffer, driven by a constant gate, rendered
// mono. The stage-two tests all want this shape with different knobs.
std::vector<float> render_sampler(const std::vector<float>& samples,
                                  const std::vector<soundgraph::ParameterValue>& parameters,
                                  int frames,
                                  double gate_value = 1.0) {
    GraphDescription graph;
    graph.schema_version = soundgraph::kSchemaVersionBuffers;
    soundgraph::BufferDescription clip;
    clip.id = "clip";
    clip.sample_rate = 48000.0;
    clip.samples = samples;
    graph.buffers.push_back(clip);
    soundgraph::NodeDescription gate;
    gate.id = "gate";
    gate.type = "Constant";
    gate.parameters.push_back(soundgraph::ParameterValue{"value", gate_value});
    graph.nodes.push_back(gate);
    soundgraph::NodeDescription play;
    play.id = "play";
    play.type = "Sampler";
    play.buffer = "clip";
    play.parameters = parameters;
    play.parameters.push_back(soundgraph::ParameterValue{"level", 1.0});
    graph.nodes.push_back(play);
    soundgraph::NodeDescription out;
    out.id = "out";
    out.type = "StereoOutput";
    out.parameters.push_back(soundgraph::ParameterValue{"level", 1.0});
    graph.nodes.push_back(out);
    graph.connections.push_back(soundgraph::ConnectionDescription{"gate", "out", "play", "gate"});
    graph.connections.push_back(soundgraph::ConnectionDescription{"play", "out", "out", "left"});

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    runtime.build(graph, soundgraph::NodeRegistry::builtin(),
                  soundgraph::PrepareContext(), diagnostics);
    std::vector<float> output(static_cast<std::size_t>(frames), 0.0f);
    runtime.render(output.data(), nullptr, frames);
    return output;
}

std::vector<float> counting_ramp(int frames) {
    std::vector<float> samples;
    for (int i = 0; i < frames; ++i) {
        samples.push_back(static_cast<float>(i) / static_cast<float>(frames));
    }
    return samples;
}

}  // namespace

TEST(sampler_slice_input_picks_the_piece_on_the_gate_edge) {
    // 800 frames in 4 slices of 200. A Constant drives the slice input as well as the
    // gate would be circular, so the slice arrives via its parameter-free default of a
    // wired constant: build a variant graph inline instead.
    GraphDescription graph;
    graph.schema_version = soundgraph::kSchemaVersionBuffers;
    soundgraph::BufferDescription clip;
    clip.id = "clip";
    clip.sample_rate = 48000.0;
    clip.samples = counting_ramp(800);
    graph.buffers.push_back(clip);
    soundgraph::NodeDescription gate;
    gate.id = "gate";
    gate.type = "Constant";
    graph.nodes.push_back(gate);
    soundgraph::NodeDescription which;
    which.id = "which";
    which.type = "Constant";
    which.parameters.push_back(soundgraph::ParameterValue{"value", 0.5});
    graph.nodes.push_back(which);
    soundgraph::NodeDescription play;
    play.id = "play";
    play.type = "Sampler";
    play.buffer = "clip";
    play.parameters.push_back(soundgraph::ParameterValue{"slices", 4.0});
    play.parameters.push_back(soundgraph::ParameterValue{"level", 1.0});
    graph.nodes.push_back(play);
    soundgraph::NodeDescription out;
    out.id = "out";
    out.type = "StereoOutput";
    out.parameters.push_back(soundgraph::ParameterValue{"level", 1.0});
    graph.nodes.push_back(out);
    graph.connections.push_back(soundgraph::ConnectionDescription{"gate", "out", "play", "gate"});
    graph.connections.push_back(soundgraph::ConnectionDescription{"which", "out", "play", "slice"});
    graph.connections.push_back(soundgraph::ConnectionDescription{"play", "out", "out", "left"});

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, soundgraph::NodeRegistry::builtin(),
                        soundgraph::PrepareContext(), diagnostics));
    std::vector<float> output(400, 0.0f);
    runtime.render(output.data(), nullptr, 400);
    // 0.5 of four slices is the third: playback starts at frame 400 of the buffer.
    CHECK_NEAR(output[0], clip.samples[400], 1e-6);
    CHECK_NEAR(output[150], clip.samples[550], 1e-6);
    // And stops at the slice's end, not the buffer's: 200 frames, then silence.
    CHECK_NEAR(output[250], 0.0, 1e-9);
}

TEST(sampler_start_and_length_trim_within_the_slice) {
    const std::vector<float> output = render_sampler(
        counting_ramp(800),
        {{"slices", 4.0}, {"start", 0.5}, {"length", 0.25}}, 200);
    // Slice one of four is frames 0..199; start 0.5 begins at 100, length 0.25 plays
    // 50 frames.
    CHECK_NEAR(output[0], 100.0 / 800.0, 1e-6);
    CHECK_NEAR(output[30], 130.0 / 800.0, 1e-6);
    CHECK_NEAR(output[60], 0.0, 1e-9);
}

TEST(sampler_frequency_input_repitches_relative_to_root) {
    GraphDescription graph;
    graph.schema_version = soundgraph::kSchemaVersionBuffers;
    soundgraph::BufferDescription clip;
    clip.id = "clip";
    clip.sample_rate = 48000.0;
    clip.samples = counting_ramp(4800);
    graph.buffers.push_back(clip);
    soundgraph::NodeDescription gate;
    gate.id = "gate";
    gate.type = "Constant";
    graph.nodes.push_back(gate);
    soundgraph::NodeDescription pitch;
    pitch.id = "pitch";
    pitch.type = "Constant";
    pitch.parameters.push_back(soundgraph::ParameterValue{"value", 400.0});
    graph.nodes.push_back(pitch);
    soundgraph::NodeDescription play;
    play.id = "play";
    play.type = "Sampler";
    play.buffer = "clip";
    play.parameters.push_back(soundgraph::ParameterValue{"root", 100.0});
    play.parameters.push_back(soundgraph::ParameterValue{"level", 1.0});
    graph.nodes.push_back(play);
    soundgraph::NodeDescription out;
    out.id = "out";
    out.type = "StereoOutput";
    out.parameters.push_back(soundgraph::ParameterValue{"level", 1.0});
    graph.nodes.push_back(out);
    graph.connections.push_back(soundgraph::ConnectionDescription{"gate", "out", "play", "gate"});
    graph.connections.push_back(soundgraph::ConnectionDescription{"pitch", "out", "play", "frequency"});
    graph.connections.push_back(soundgraph::ConnectionDescription{"play", "out", "out", "left"});

    soundgraph::Graph runtime;
    std::vector<Diagnostic> diagnostics;
    CHECK(runtime.build(graph, soundgraph::NodeRegistry::builtin(),
                        soundgraph::PrepareContext(), diagnostics));
    std::vector<float> output(1000, 0.0f);
    runtime.render(output.data(), nullptr, 1000);
    // 400 Hz against a root of 100 is two octaves up: the read head moves at 4x, so
    // 100 frames in, the output reads 400 frames into the recording — exactly, which
    // is well inside the design's within-a-cent exit criterion.
    CHECK_NEAR(output[100], clip.samples[400], 1e-6);
    CHECK_NEAR(output[900], clip.samples[3600], 1e-6);
}

TEST(sampler_loop_wraps_the_slice_not_the_buffer) {
    const std::vector<float> output = render_sampler(
        counting_ramp(800),
        {{"slices", 4.0}, {"loop", 1.0}}, 500);
    // Slice one loops with period 200: the value 60 frames in recurs at 260 and 460.
    CHECK_NEAR(output[60], output[260], 1e-6);
    CHECK_NEAR(output[60], output[460], 1e-6);
    CHECK_NEAR(output[60], 60.0 / 800.0, 1e-6);
}

TEST(the_sampler_plays_its_buffer_whatever_the_host_chunk_size) {
    // The stage-one exit test from docs/sampler-design.md: a buffer-carrying patch
    // renders byte-identical however the host slices its calls.
    GraphDescription graph;
    graph.schema_version = soundgraph::kSchemaVersionBuffers;
    soundgraph::BufferDescription clip;
    clip.id = "clip";
    clip.sample_rate = 48000.0;
    for (int i = 0; i < 1000; ++i) {
        clip.samples.push_back(0.25f + 0.5f * static_cast<float>(i % 7) / 7.0f);
    }
    graph.buffers.push_back(clip);
    soundgraph::NodeDescription gate;
    gate.id = "gate";
    gate.type = "Constant";
    graph.nodes.push_back(gate);
    soundgraph::NodeDescription play;
    play.id = "play";
    play.type = "Sampler";
    play.buffer = "clip";
    graph.nodes.push_back(play);
    soundgraph::NodeDescription out;
    out.id = "out";
    out.type = "StereoOutput";
    graph.nodes.push_back(out);
    graph.connections.push_back(soundgraph::ConnectionDescription{"gate", "out", "play", "gate"});
    graph.connections.push_back(soundgraph::ConnectionDescription{"play", "out", "out", "left"});

    auto render = [&graph](int chunk) {
        soundgraph::Graph runtime;
        std::vector<Diagnostic> diagnostics;
        const bool built = runtime.build(graph, soundgraph::NodeRegistry::builtin(),
                                         soundgraph::PrepareContext(), diagnostics);
        std::string complaint;
        for (const Diagnostic& diagnostic : diagnostics) {
            complaint += diagnostic.code + " ";
        }
        CHECK_MESSAGE(built, "build failed: " + complaint);
        std::vector<float> output(4800, 0.0f);
        int written = 0;
        while (written < 4800) {
            const int frames = chunk < 4800 - written ? chunk : 4800 - written;
            runtime.render(output.data() + written, nullptr, frames);
            written += frames;
        }
        return output;
    };

    const std::vector<float> whole = render(4800);
    const std::vector<float> blocks = render(64);
    const std::vector<float> odd = render(37);
    CHECK(whole == blocks);
    CHECK(whole == odd);

    // And it is actually the recording: the sampler's default level and the output's
    // are 0.8 each. The read head stops one sample early — interpolation needs a
    // neighbour — so the last playable sample is 998.
    CHECK_NEAR(whole[0], clip.samples[0] * 0.8f * 0.8f, 1e-6);
    CHECK_NEAR(whole[998], clip.samples[998] * 0.8f * 0.8f, 1e-6);
    // Past the end, loop off: silence.
    CHECK_NEAR(whole[999], 0.0, 1e-9);
    CHECK_NEAR(whole[2000], 0.0, 1e-9);
}

// ---- plugins --------------------------------------------------------------------------

TEST(a_plugin_is_named_by_identity_and_survives_a_round_trip) {
    const std::string text = R"({
        "schema_version": 4,
        "plugins": {
            "verb": {
                "format": "VST3",
                "identity": "ABCDEF019182FAEB566D624153675854",
                "vendor": "Surge Synth Team",
                "name": "Surge XT Effects",
                "path_hint": "C:/Program Files/Common Files/VST3/Surge XT Effects.vst3",
                "state": "c3VyZ2U=",
                "slots": [12, -1, 7]
            }
        },
        "nodes": [
            { "id": "osc", "type": "SineOscillator" },
            { "id": "fx", "type": "PluginEffect", "plugin": "verb" },
            { "id": "out", "type": "StereoOutput" }
        ],
        "connections": [
            { "from": { "node": "osc", "port": "out" }, "to": { "node": "fx", "port": "left" } },
            { "from": { "node": "fx", "port": "left" }, "to": { "node": "out", "port": "left" } }
        ]
    })";
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(soundgraph::parse_patch(text, graph, diagnostics));
    CHECK(graph.plugins.size() == 1);
    CHECK(graph.plugins[0].id == "verb");
    CHECK(graph.plugins[0].format == "VST3");
    CHECK(graph.plugins[0].identity == "ABCDEF019182FAEB566D624153675854");
    CHECK(graph.plugins[0].name == "Surge XT Effects");
    // Base64 on the wire, the plugin's own bytes in memory: "c3VyZ2U=" is "surge".
    CHECK(graph.plugins[0].state == "surge");
    CHECK(graph.plugins[0].slots.size() == 3 && graph.plugins[0].slots[0] == 12 &&
          graph.plugins[0].slots[1] == -1);
    CHECK(graph.find_node("fx") != nullptr && graph.find_node("fx")->plugin == "verb");

    // Written back and read again: the identity and the state are what must not drift,
    // because between them they are the whole of what makes the patch the artifact.
    const std::string written = soundgraph::write_patch(graph);
    GraphDescription again;
    std::vector<Diagnostic> again_diagnostics;
    CHECK(soundgraph::parse_patch(written, again, again_diagnostics));
    CHECK(again.plugins.size() == 1);
    CHECK(again.plugins[0].identity == graph.plugins[0].identity);
    CHECK(again.plugins[0].state == graph.plugins[0].state);
    CHECK(again.plugins[0].slots == graph.plugins[0].slots);
    CHECK(again.find_node("fx")->plugin == "verb");
}

TEST(plugin_state_is_bytes_and_survives_being_written_down) {
    // The point of the encoding, in the one case that breaks a naive one: a plugin's
    // state is arbitrary bytes, including the zero byte and everything above 127. Put
    // straight into a JSON string it would end the string early, or produce a document
    // that is not valid UTF-8 and cannot be read back by anything.
    GraphDescription graph;
    graph.nodes.push_back(soundgraph::NodeDescription{});
    graph.nodes[0].id = "fx";
    graph.nodes[0].type = "PluginEffect";
    graph.nodes[0].plugin = "verb";

    soundgraph::PluginDescription plugin;
    plugin.id = "verb";
    plugin.format = "CLAP";
    plugin.identity = "org.surge-synth-team.surge-xt-fx";
    std::string bytes;
    for (int i = 0; i < 256; ++i) {
        bytes.push_back(static_cast<char>(i));
    }
    plugin.state = bytes;
    graph.plugins.push_back(plugin);

    const std::string text = write_patch(graph, true);
    // Nothing raw got out: the zero byte in particular never reaches the document.
    CHECK(text.find('\0') == std::string::npos);

    GraphDescription again;
    std::vector<Diagnostic> diagnostics;
    CHECK(parse_patch(text, again, diagnostics));
    CHECK(again.plugins.size() == 1);
    CHECK(again.plugins[0].state == bytes);
}

TEST(plugin_state_that_will_not_decode_is_reported_and_dropped) {
    // A hand-edited patch, or one truncated by something in the middle. The patch still
    // opens — losing a preset is bad, losing the graph would be worse — and it says so
    // rather than handing the plugin half a preset.
    const std::string text = R"({
        "schema_version": 4,
        "plugins": {
            "verb": { "format": "CLAP", "identity": "org.example.verb",
                      "state": "not base64 at all!!" }
        },
        "nodes": [ { "id": "fx", "type": "PluginEffect", "plugin": "verb" } ],
        "connections": []
    })";

    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(parse_patch(text, graph, diagnostics));
    CHECK(graph.plugins.size() == 1);
    CHECK(graph.plugins[0].state.empty());
    CHECK(has_code(diagnostics, "unreadable_plugin_state"));
}

TEST(a_plugin_without_an_identity_is_refused) {
    const std::string text = R"({
        "schema_version": 4,
        "plugins": { "verb": { "format": "VST3", "path_hint": "somewhere.vst3" } },
        "nodes": [ { "id": "fx", "type": "PluginEffect", "plugin": "verb" } ]
    })";
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::parse_patch(text, graph, diagnostics));
    CHECK(has_code(diagnostics, "plugin_no_identity"));
}

TEST(a_node_naming_a_plugin_the_patch_does_not_carry_is_refused) {
    const std::string text = R"({
        "schema_version": 4,
        "nodes": [ { "id": "fx", "type": "PluginEffect", "plugin": "ghost" } ]
    })";
    GraphDescription graph;
    std::vector<Diagnostic> diagnostics;
    CHECK(!soundgraph::parse_patch(text, graph, diagnostics));
    CHECK(has_code(diagnostics, "unknown_plugin"));
}

TEST_MAIN("patch io tests")
