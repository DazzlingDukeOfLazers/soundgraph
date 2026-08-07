#include "soundgraph_engine.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

#include "soundgraph/patch_io.h"

using namespace godot;

namespace soundgraph_godot {
namespace {

constexpr int kMaxFillFrames = 4096;
constexpr int kScopeSamples = 4096;

std::string to_utf8(const String& text) {
    const CharString utf8 = text.utf8();
    return std::string(utf8.get_data(), static_cast<std::size_t>(utf8.length()));
}

}  // namespace

SoundGraphEngine::SoundGraphEngine() {
    left_.assign(kMaxFillFrames, 0.0f);
    right_.assign(kMaxFillFrames, 0.0f);
    frames_.resize(kMaxFillFrames);
    scope_.assign(kScopeSamples, 0.0f);
}

SoundGraphEngine::~SoundGraphEngine() = default;

void SoundGraphEngine::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_registry_json"), &SoundGraphEngine::get_registry_json);
    ClassDB::bind_method(D_METHOD("search_nodes", "query"), &SoundGraphEngine::search_nodes);
    ClassDB::bind_method(D_METHOD("validate_patch", "patch_json"), &SoundGraphEngine::validate_patch);

    ClassDB::bind_method(D_METHOD("load_patch", "patch_json", "sample_rate"),
                         &SoundGraphEngine::load_patch);
    ClassDB::bind_method(D_METHOD("is_loaded"), &SoundGraphEngine::is_loaded);
    ClassDB::bind_method(D_METHOD("get_diagnostics_json"), &SoundGraphEngine::get_diagnostics_json);
    ClassDB::bind_method(D_METHOD("get_info_json"), &SoundGraphEngine::get_info_json);

    ClassDB::bind_method(D_METHOD("note_on", "note", "velocity"), &SoundGraphEngine::note_on);
    ClassDB::bind_method(D_METHOD("note_off", "note"), &SoundGraphEngine::note_off);
    ClassDB::bind_method(D_METHOD("all_notes_off"), &SoundGraphEngine::all_notes_off);
    ClassDB::bind_method(D_METHOD("reset"), &SoundGraphEngine::reset);
    ClassDB::bind_method(D_METHOD("set_parameter", "node_id", "parameter", "value"),
                         &SoundGraphEngine::set_parameter);

    ClassDB::bind_method(D_METHOD("fill_playback", "playback", "max_frames"),
                         &SoundGraphEngine::fill_playback);
    ClassDB::bind_method(D_METHOD("get_peak"), &SoundGraphEngine::get_peak);

    ClassDB::bind_method(D_METHOD("get_scope", "samples"), &SoundGraphEngine::get_scope);
    ClassDB::bind_method(D_METHOD("get_port_signal", "node_id", "port"),
                         &SoundGraphEngine::get_port_signal);
}

// -------------------------------------------------------------------------------------
// Editor-side questions
// -------------------------------------------------------------------------------------

String SoundGraphEngine::get_registry_json() const {
    return String::utf8(
        soundgraph::write_registry(soundgraph::NodeRegistry::builtin(), false).c_str());
}

PackedStringArray SoundGraphEngine::search_nodes(const String& query) const {
    PackedStringArray results;
    for (const soundgraph::NodeTypeDescriptor* type :
         soundgraph::NodeRegistry::builtin().search(to_utf8(query))) {
        results.push_back(String::utf8(type->name));
    }
    return results;
}

String SoundGraphEngine::validate_patch(const String& patch_json) const {
    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;

    bool ok = soundgraph::parse_patch(to_utf8(patch_json), description, diagnostics);
    if (ok) {
        ok = soundgraph::validate(description, soundgraph::NodeRegistry::builtin(), diagnostics);
    }

    const std::string json = std::string("{\"ok\":") + (ok ? "true" : "false") +
                             ",\"diagnostics\":" +
                             soundgraph::write_diagnostics(diagnostics, false) + "}";
    return String::utf8(json.c_str());
}

// -------------------------------------------------------------------------------------
// The live graph
// -------------------------------------------------------------------------------------

bool SoundGraphEngine::load_patch(const String& patch_json, double sample_rate) {
    loaded_ = false;
    peak_ = 0.0;
    std::fill(scope_.begin(), scope_.end(), 0.0f);
    scope_write_ = 0;

    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;

    if (!soundgraph::parse_patch(to_utf8(patch_json), description, diagnostics)) {
        diagnostics_json_ = soundgraph::write_diagnostics(diagnostics, false);
        return false;
    }

    soundgraph::PrepareContext context;
    context.sample_rate = sample_rate > 0.0 ? sample_rate : 48000.0;

    if (!graph_.build(description, soundgraph::NodeRegistry::builtin(), context, diagnostics)) {
        diagnostics_json_ = soundgraph::write_diagnostics(diagnostics, false);
        return false;
    }

    description_ = std::move(description);
    diagnostics_json_ = soundgraph::write_diagnostics(diagnostics, false);

    // The same report the browser shows and sg-validate --explain prints.
    std::string info = "{\"nodes\":[";
    for (std::size_t i = 0; i < graph_.execution_order().size(); ++i) {
        const int index = graph_.execution_order()[i];
        const soundgraph::NodeTypeDescriptor* type = graph_.node_type(index);
        if (i > 0) {
            info += ",";
        }
        info += "{\"id\":\"" + graph_.node_id(index) + "\",\"type\":\"" +
                (type != nullptr ? type->name : "?") + "\"}";
    }
    info += "],\"feedback\":[";
    for (std::size_t i = 0; i < graph_.feedback_connections().size(); ++i) {
        const int index = graph_.feedback_connections()[i];
        if (index < 0 || index >= static_cast<int>(description_.connections.size())) {
            continue;
        }
        const soundgraph::ConnectionDescription& connection =
            description_.connections[static_cast<std::size_t>(index)];
        if (i > 0) {
            info += ",";
        }
        info += "{\"index\":" + std::to_string(index) + ",\"from\":\"" + connection.from_node +
                "." + connection.from_port + "\",\"to\":\"" + connection.to_node + "." +
                connection.to_port + "\"}";
    }
    const soundgraph::ResourceCost cost = graph_.estimated_cost();
    info += "],\"cost\":{\"cpu\":" + std::to_string(cost.cpu_cost) +
            ",\"state_bytes\":" + std::to_string(cost.state_bytes) +
            ",\"heap_bytes\":" + std::to_string(cost.heap_bytes) + "}" +
            ",\"sample_rate\":" + std::to_string(graph_.sample_rate()) +
            ",\"node_count\":" + std::to_string(graph_.node_count()) + "}";
    info_json_ = info;

    loaded_ = true;
    return true;
}

String SoundGraphEngine::get_diagnostics_json() const {
    return String::utf8(diagnostics_json_.c_str());
}

String SoundGraphEngine::get_info_json() const {
    return String::utf8(info_json_.c_str());
}

void SoundGraphEngine::note_on(int note, double velocity) {
    graph_.note_on(note, static_cast<float>(velocity));
}

void SoundGraphEngine::note_off(int note) {
    graph_.note_off(note);
}

void SoundGraphEngine::all_notes_off() {
    graph_.all_notes_off();
}

void SoundGraphEngine::reset() {
    graph_.reset();
    std::fill(scope_.begin(), scope_.end(), 0.0f);
    scope_write_ = 0;
    peak_ = 0.0;
}

bool SoundGraphEngine::set_parameter(const String& node_id, const String& parameter, double value) {
    return graph_.set_parameter(to_utf8(node_id), to_utf8(parameter), static_cast<float>(value));
}

// -------------------------------------------------------------------------------------
// Audio
// -------------------------------------------------------------------------------------

int SoundGraphEngine::fill_playback(const Ref<AudioStreamGeneratorPlayback>& playback,
                                    int max_frames) {
    if (playback.is_null() || !loaded_) {
        return 0;
    }
    const int frames = std::min(max_frames, kMaxFillFrames);
    if (frames <= 0) {
        return 0;
    }

    graph_.render(left_.data(), right_.data(), frames);

    float peak = 0.0f;
    for (int i = 0; i < frames; ++i) {
        frames_[i] = Vector2(left_[static_cast<std::size_t>(i)], right_[static_cast<std::size_t>(i)]);
        peak = std::max(peak, std::fabs(left_[static_cast<std::size_t>(i)]));
    }
    peak_ = peak;
    push_scope(left_.data(), frames);

    // push_buffer wants exactly the frames being pushed, so hand it a slice rather than
    // the whole staging array.
    if (frames == kMaxFillFrames) {
        playback->push_buffer(frames_);
    } else {
        PackedVector2Array slice = frames_.slice(0, frames);
        playback->push_buffer(slice);
    }
    return frames;
}

void SoundGraphEngine::push_scope(const float* samples, int count) {
    for (int i = 0; i < count; ++i) {
        scope_[static_cast<std::size_t>(scope_write_)] = samples[i];
        scope_write_ = (scope_write_ + 1) % kScopeSamples;
    }
}

// -------------------------------------------------------------------------------------
// Inspection
// -------------------------------------------------------------------------------------

PackedFloat32Array SoundGraphEngine::get_scope(int samples) const {
    const int count = std::min(std::max(samples, 0), kScopeSamples);
    PackedFloat32Array result;
    result.resize(count);
    for (int i = 0; i < count; ++i) {
        // Oldest first, so the display reads left to right.
        const int index = (scope_write_ - count + i + kScopeSamples * 2) % kScopeSamples;
        result[i] = scope_[static_cast<std::size_t>(index)];
    }
    return result;
}

PackedFloat32Array SoundGraphEngine::get_port_signal(const String& node_id,
                                                     const String& port) const {
    PackedFloat32Array result;
    if (!loaded_) {
        return result;
    }

    const int index = graph_.node_index(to_utf8(node_id));
    const soundgraph::NodeTypeDescriptor* type = graph_.node_type(index);
    if (index < 0 || type == nullptr) {
        return result;
    }
    const int port_index = type->find_output(to_utf8(port).c_str());
    const float* signal = graph_.port_signal(index, port_index);
    if (signal == nullptr) {
        return result;
    }

    const int count = graph_.port_signal_length();
    result.resize(count);
    for (int i = 0; i < count; ++i) {
        result[i] = signal[i];
    }
    return result;
}

}  // namespace soundgraph_godot
