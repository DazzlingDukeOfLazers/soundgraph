// The text boundary: parsing, serialising, and surviving the round trip.
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
            CHECK_NEAR(node.x, 500.0, 0.001);
            CHECK_NEAR(node.y, 160.0, 0.001);
        }
    }
    CHECK_MESSAGE(found, "the filter node should be in the example patch");
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

TEST_MAIN("patch io tests")
