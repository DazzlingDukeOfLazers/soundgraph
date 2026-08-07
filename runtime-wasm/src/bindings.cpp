// SoundGraph — the WebAssembly boundary.
//
// A flat C surface over dsp-core and patch-io. There is no DSP here and no browser
// knowledge either: JavaScript owns the audio device and the DOM, this owns nothing but
// translation. The same graph semantics that produced the native golden vectors run
// behind these functions unchanged.
//
// Strings handed back stay valid until the next call that produces one on the same
// engine, which keeps the JavaScript side free of manual frees for read-only results.
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"

#if defined(__EMSCRIPTEN__)
#include <emscripten/emscripten.h>
#define SG_EXPORT EMSCRIPTEN_KEEPALIVE
#else
#define SG_EXPORT
#endif

namespace {

struct Engine {
    soundgraph::Graph graph;
    soundgraph::GraphDescription description;
    double sample_rate = 48000.0;
    bool loaded = false;

    std::string diagnostics_json = "[]";
    std::string info_json = "{}";
    float peak = 0.0f;
};

// Backing store for the results of the stateless calls.
std::string& scratch() {
    static std::string value;
    return value;
}

std::string describe(const soundgraph::Graph& graph,
                     const soundgraph::GraphDescription& description) {
    // Hand-built rather than routed through the JSON writer: this is a report about a
    // built graph, not a patch, and it has no round-trip obligations.
    std::string out = "{\"nodes\":[";
    for (std::size_t i = 0; i < graph.execution_order().size(); ++i) {
        const int index = graph.execution_order()[i];
        const soundgraph::NodeTypeDescriptor* type = graph.node_type(index);
        if (i > 0) {
            out += ",";
        }
        out += "{\"id\":\"" + graph.node_id(index) + "\",\"type\":\"" +
               (type != nullptr ? type->name : "?") + "\"}";
    }
    out += "],\"feedback\":[";
    for (std::size_t i = 0; i < graph.feedback_connections().size(); ++i) {
        const int index = graph.feedback_connections()[i];
        if (index < 0 || index >= static_cast<int>(description.connections.size())) {
            continue;
        }
        const soundgraph::ConnectionDescription& connection =
            description.connections[static_cast<std::size_t>(index)];
        if (i > 0) {
            out += ",";
        }
        out += "{\"index\":" + std::to_string(index) + ",\"from\":\"" + connection.from_node + "." +
               connection.from_port + "\",\"to\":\"" + connection.to_node + "." +
               connection.to_port + "\"}";
    }

    const soundgraph::ResourceCost cost = graph.estimated_cost();
    out += "],\"cost\":{\"cpu\":" + std::to_string(cost.cpu_cost) +
           ",\"state_bytes\":" + std::to_string(cost.state_bytes) +
           ",\"heap_bytes\":" + std::to_string(cost.heap_bytes) + "}" +
           ",\"sample_rate\":" + std::to_string(graph.sample_rate()) +
           ",\"node_count\":" + std::to_string(graph.node_count()) + "}";
    return out;
}

}  // namespace

extern "C" {

SG_EXPORT int sg_schema_version(void) { return soundgraph::kSchemaVersion; }

SG_EXPORT int sg_block_size(void) { return soundgraph::kBlockSize; }

// The node vocabulary, for building a palette and type-checking a drag in the editor.
SG_EXPORT const char* sg_registry_json(void) {
    scratch() = soundgraph::write_registry(soundgraph::NodeRegistry::builtin(), false);
    return scratch().c_str();
}

// Validates without building anything, so an editor can call it on every edit.
// Returns {"ok": bool, "diagnostics": [...]}.
SG_EXPORT const char* sg_validate_patch(const char* json) {
    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;

    bool ok = soundgraph::parse_patch(json != nullptr ? json : "", description, diagnostics);
    if (ok) {
        ok = soundgraph::validate(description, soundgraph::NodeRegistry::builtin(), diagnostics);
    }

    scratch() = std::string("{\"ok\":") + (ok ? "true" : "false") + ",\"diagnostics\":" +
                soundgraph::write_diagnostics(diagnostics, false) + "}";
    return scratch().c_str();
}

SG_EXPORT Engine* sg_engine_create(double sample_rate) {
    Engine* engine = new Engine();
    engine->sample_rate = sample_rate > 0.0 ? sample_rate : 48000.0;
    return engine;
}

SG_EXPORT void sg_engine_destroy(Engine* engine) { delete engine; }

SG_EXPORT int sg_engine_load_patch(Engine* engine, const char* json) {
    if (engine == nullptr) {
        return 0;
    }
    engine->loaded = false;

    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;

    if (!soundgraph::parse_patch(json != nullptr ? json : "", description, diagnostics)) {
        engine->diagnostics_json = soundgraph::write_diagnostics(diagnostics, false);
        return 0;
    }

    soundgraph::PrepareContext context;
    context.sample_rate = engine->sample_rate;

    if (!engine->graph.build(description, soundgraph::NodeRegistry::builtin(), context,
                             diagnostics)) {
        engine->diagnostics_json = soundgraph::write_diagnostics(diagnostics, false);
        return 0;
    }

    engine->description = std::move(description);
    engine->diagnostics_json = soundgraph::write_diagnostics(diagnostics, false);
    engine->info_json = describe(engine->graph, engine->description);
    engine->loaded = true;
    return 1;
}

SG_EXPORT const char* sg_engine_diagnostics(Engine* engine) {
    return engine != nullptr ? engine->diagnostics_json.c_str() : "[]";
}

SG_EXPORT const char* sg_engine_info(Engine* engine) {
    return engine != nullptr ? engine->info_json.c_str() : "{}";
}

// Planar, because that is the shape an AudioWorklet hands out.
SG_EXPORT void sg_engine_render(Engine* engine, float* left, float* right, int frames) {
    if (engine == nullptr || frames <= 0) {
        return;
    }
    if (!engine->loaded) {
        for (int i = 0; i < frames; ++i) {
            if (left != nullptr) left[i] = 0.0f;
            if (right != nullptr) right[i] = 0.0f;
        }
        engine->peak = 0.0f;
        return;
    }

    engine->graph.render(left, right, frames);

    float peak = 0.0f;
    if (left != nullptr) {
        for (int i = 0; i < frames; ++i) {
            const float magnitude = left[i] < 0.0f ? -left[i] : left[i];
            if (magnitude > peak) {
                peak = magnitude;
            }
        }
    }
    engine->peak = peak;
}

SG_EXPORT void sg_engine_note_on(Engine* engine, int note, float velocity) {
    if (engine != nullptr) {
        engine->graph.note_on(note, velocity);
    }
}

SG_EXPORT void sg_engine_note_off(Engine* engine, int note) {
    if (engine != nullptr) {
        engine->graph.note_off(note);
    }
}

SG_EXPORT void sg_engine_all_notes_off(Engine* engine) {
    if (engine != nullptr) {
        engine->graph.all_notes_off();
    }
}

SG_EXPORT int sg_engine_set_parameter(Engine* engine, const char* node, const char* parameter,
                                      float value) {
    if (engine == nullptr || node == nullptr || parameter == nullptr) {
        return 0;
    }
    return engine->graph.set_parameter(node, parameter, value) ? 1 : 0;
}

// Resolving a parameter by name costs two string comparisons over the whole graph, which
// is fine once but not on every frame of a knob drag. A host binds each control once and
// then moves it by handle, so the audio thread never touches a string.
// Returns -1 if the node or parameter does not exist.
SG_EXPORT int sg_engine_parameter_handle(Engine* engine, const char* node,
                                         const char* parameter) {
    if (engine == nullptr || node == nullptr || parameter == nullptr) {
        return -1;
    }
    const int node_index = engine->graph.node_index(node);
    if (node_index < 0) {
        return -1;
    }
    const int parameter_index = engine->graph.parameter_index(node_index, parameter);
    if (parameter_index < 0) {
        return -1;
    }
    return node_index * soundgraph::kMaxParameters + parameter_index;
}

SG_EXPORT void sg_engine_set_parameter_by_handle(Engine* engine, int handle, float value) {
    if (engine == nullptr || handle < 0) {
        return;
    }
    engine->graph.set_parameter(handle / soundgraph::kMaxParameters,
                                handle % soundgraph::kMaxParameters, value);
}

SG_EXPORT float sg_engine_peak(Engine* engine) {
    return engine != nullptr ? engine->peak : 0.0f;
}

SG_EXPORT void sg_engine_reset(Engine* engine) {
    if (engine != nullptr) {
        engine->graph.reset();
    }
}

}  // extern "C"
