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
            CHECK_NEAR(node.x, 800.0, 0.001);
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

    // A module inside a module.
    std::string nested = modular_patch();
    nested.replace(nested.find("\"id\": \"env\", \"type\": \"ADSR\""), 27,
                   "\"id\": \"env\", \"type\": \"module\", \"module\": \"voice\"");
    CHECK(refuses(nested, "module_nesting"));

    // A top-level node whose literal name collides with an expansion.
    std::string collision = modular_patch();
    collision.replace(collision.find("\"id\": \"note\""), 12, "\"id\": \"a.osc\"");
    CHECK(refuses(collision, "module_id_collision"));
}

TEST_MAIN("patch io tests")

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

TEST(seams_hold_the_scope_rule_in_both_directions) {
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

    // A seam at the top level is where the graph meets the machine, so it has to say
    // which part of it.
    CHECK(refuses(swap(seam_patch(), ",  \"host\": \"note\"", ""),
                  "top_level_seam_needs_host"));

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
