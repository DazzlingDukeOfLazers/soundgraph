#include "soundgraph_engine.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <sstream>

#include "soundgraph/patch_io.h"
#include "soundgraph/lpc_encoder.h"

// The desktop provider, when this build has the SDKs to load a plugin with. The guard
// is the whole of the difference: with it absent the extension is what it always was,
// and dsp-core's answer to "no provider" — the effect passes its audio through and the
// patch says so once — is the one the user gets.
#if defined(SOUNDGRAPH_WITH_PLUGIN_HOST)
#include "desktop_provider.h"
#endif

using namespace godot;

namespace soundgraph_godot {
namespace {

constexpr int kMaxFillFrames = 4096;
constexpr int kScopeSamples = 4096;
// The probe rings: five and a half seconds at 48 kHz, allocated inside the graph
// when a probe is armed. Generous on purpose — the trigger only accepts an edge
// with a whole window still after it, so the ring must dwarf the largest window.
constexpr int kTapSamples = 262144;

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

    // Made once and pointed at the graph before anything is built, because the graph
    // borrows it for the life of every patch it loads. Making one per load would mean
    // rescanning the machine each time a patch is opened.
#if defined(SOUNDGRAPH_WITH_PLUGIN_HOST)
    plugin_provider_ = soundgraph::host::make_desktop_plugin_provider();
    graph_.set_plugin_provider(plugin_provider_.get());
#endif
}

SoundGraphEngine::~SoundGraphEngine() {
    // Before the graph goes, and therefore before the instances do. A plugin still
    // drawing into a window that has been freed is a crash with nothing of ours on the
    // stack, which is the worst kind to be handed.
    close_plugin_gui(String(open_gui_node_.c_str()));
}

void SoundGraphEngine::_bind_methods() {
    ClassDB::bind_method(D_METHOD("get_registry_json"), &SoundGraphEngine::get_registry_json);
    ClassDB::bind_method(D_METHOD("search_nodes", "query"), &SoundGraphEngine::search_nodes);
    ClassDB::bind_method(D_METHOD("validate_patch", "patch_json"), &SoundGraphEngine::validate_patch);
    ClassDB::bind_method(D_METHOD("flatten_patch", "patch_json"),
                         &SoundGraphEngine::flatten_patch);
    ClassDB::bind_method(D_METHOD("format_patch", "patch_json"), &SoundGraphEngine::format_patch);

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

    ClassDB::bind_method(D_METHOD("render_block", "frames"),
                         &SoundGraphEngine::render_block);
    ClassDB::bind_method(D_METHOD("lpc_encode", "samples", "sample_rate"),
                         &SoundGraphEngine::lpc_encode);
    ClassDB::bind_method(D_METHOD("control_change", "cc", "value"),
                         &SoundGraphEngine::control_change);
    ClassDB::bind_method(D_METHOD("fill_playback", "playback", "max_frames"),
                         &SoundGraphEngine::fill_playback);
    ClassDB::bind_method(D_METHOD("get_peak"), &SoundGraphEngine::get_peak);

    ClassDB::bind_method(D_METHOD("can_host_plugins"), &SoundGraphEngine::can_host_plugins);
    ClassDB::bind_method(D_METHOD("plugin_has_gui", "node_id"),
                         &SoundGraphEngine::plugin_has_gui);
    ClassDB::bind_method(D_METHOD("open_plugin_gui", "node_id", "window_handle"),
                         &SoundGraphEngine::open_plugin_gui);
    ClassDB::bind_method(D_METHOD("close_plugin_gui", "node_id"),
                         &SoundGraphEngine::close_plugin_gui);
    ClassDB::bind_method(D_METHOD("plugin_gui_size", "node_id"),
                         &SoundGraphEngine::plugin_gui_size);
    ClassDB::bind_method(D_METHOD("plugin_state", "node_id"),
                         &SoundGraphEngine::plugin_state);
    ClassDB::bind_method(D_METHOD("tick_plugins"), &SoundGraphEngine::tick_plugins);

    ClassDB::bind_method(D_METHOD("get_scope", "samples"), &SoundGraphEngine::get_scope);
    ClassDB::bind_method(D_METHOD("get_port_signal", "node_id", "port"),
                         &SoundGraphEngine::get_port_signal);
    ClassDB::bind_method(D_METHOD("set_scope_tap", "node_id", "port"),
                         &SoundGraphEngine::set_scope_tap);
    ClassDB::bind_method(D_METHOD("set_scope_gate", "node_id", "port"),
                         &SoundGraphEngine::set_scope_gate);
    ClassDB::bind_method(D_METHOD("get_scope_tap", "samples"),
                         &SoundGraphEngine::get_scope_tap);
    ClassDB::bind_method(D_METHOD("get_scope_gate", "samples"),
                         &SoundGraphEngine::get_scope_gate);
    ClassDB::bind_method(D_METHOD("get_scope_tap_edges"),
                         &SoundGraphEngine::get_scope_tap_edges);
    ClassDB::bind_method(D_METHOD("get_scope_gate_edges"),
                         &SoundGraphEngine::get_scope_gate_edges);
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

// Modules and seams are notation: expansion happens during parse, so `description` here
// is already the flat graph the engine would build. Serialising it is therefore a
// fingerprint of the *sound*, not of the file — which is exactly what a caller needs to
// ask "would reloading change anything".
//
// Sorted, because the flat order is an implementation detail of expansion and two
// documents that differ only in it are the same graph. Parameters are printed at full
// precision: a value that survives a round trip must compare equal, and a rounded one
// would make a reload look necessary when it is not.
String SoundGraphEngine::flatten_patch(const String& patch_json) const {
    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;
    if (!soundgraph::parse_patch(to_utf8(patch_json), description, diagnostics)) {
        return String();
    }

    std::vector<std::string> lines;
    lines.reserve(description.nodes.size() + description.connections.size());
    for (const soundgraph::NodeDescription& node : description.nodes) {
        std::string line = "n " + node.id + " " + node.type;
        std::vector<std::string> settings;
        settings.reserve(node.parameters.size());
        for (const soundgraph::ParameterValue& parameter : node.parameters) {
            std::ostringstream value;
            value.precision(17);
            value << parameter.name << "=" << parameter.value;
            settings.push_back(value.str());
        }
        std::sort(settings.begin(), settings.end());
        for (const std::string& setting : settings) {
            line += " " + setting;
        }
        lines.push_back(line);
    }
    for (const soundgraph::ConnectionDescription& wire : description.connections) {
        lines.push_back("c " + wire.from_node + "." + wire.from_port + " -> " +
                        wire.to_node + "." + wire.to_port);
    }
    std::sort(lines.begin(), lines.end());

    std::string out;
    for (const std::string& line : lines) {
        out += line;
        out += "\n";
    }
    return String::utf8(out.c_str());
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

String SoundGraphEngine::format_patch(const String& patch_json) const {
    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;
    if (!soundgraph::parse_patch(to_utf8(patch_json), description, diagnostics)) {
        // Better to hand back exactly what came in than to lose the user's work to a
        // serialiser that could not read it.
        return patch_json;
    }
    return String::utf8(soundgraph::write_patch(description, true).c_str());
}

// -------------------------------------------------------------------------------------
// The live graph
// -------------------------------------------------------------------------------------

bool SoundGraphEngine::load_patch(const String& patch_json, double sample_rate) {
    // build() destroys every plugin instance and acquires new ones, so an editor left
    // open across a reload would be drawing from a plugin that no longer exists. Closed
    // first, and deliberately not reopened: the new graph may not even have that node.
    close_plugin_gui(String(open_gui_node_.c_str()));

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
    resolve_taps();
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

// A hardware controller moved. 0..127 are MIDI CCs, 128 the pitch bend, value 0..1;
// queued into the graph like a note, applied at the block boundary.
void SoundGraphEngine::control_change(int cc, float value) {
    if (!loaded_) {
        return;
    }
    graph_.control_change(cc, value);
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

// Offline pull for anything that is not the speakers: the roll capture renders a bar
// through a second engine instance with this, block by block between note events, and
// never touches the one the audio thread is filling. Mono, folded like the goldens.
PackedFloat32Array SoundGraphEngine::render_block(int frames) {
    PackedFloat32Array out;
    if (!loaded_ || frames <= 0) {
        return out;
    }
    out.resize(frames);
    int written = 0;
    while (written < frames) {
        const int chunk = std::min(frames - written, kMaxFillFrames);
        graph_.render(left_.data(), right_.data(), chunk);
        for (int i = 0; i < chunk; ++i) {
            out[written + i] = 0.5f * (left_[static_cast<std::size_t>(i)] +
                                       right_[static_cast<std::size_t>(i)]);
        }
        written += chunk;
    }
    return out;
}

// The editor half of the speak pipeline: samples in, the Speech node's bitstream
// out, as raw bytes for the editor to pack into a patch buffer. Needs no loaded
// graph — encoding a voice is not a question about the current patch.
PackedByteArray SoundGraphEngine::lpc_encode(const PackedFloat32Array& samples,
                                             float sample_rate) {
    PackedByteArray out;
    const std::vector<unsigned char> bytes = soundgraph::encode_lpc(
        samples.ptr(), static_cast<int>(samples.size()),
        static_cast<double>(sample_rate));
    out.resize(static_cast<int64_t>(bytes.size()));
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        out[static_cast<int64_t>(i)] = bytes[i];
    }
    return out;
}

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

// Re-aims the probes at the current graph. A tap keeps its name across reloads and
// simply goes quiet (-1) while the name has nothing to point at.
void SoundGraphEngine::resolve_taps() {
    tap_index_ = -1;
    tap_port_index_ = -1;
    gate_index_ = -1;
    gate_port_index_ = -1;
    if (!tap_node_.empty()) {
        const int index = graph_.node_index(tap_node_);
        const soundgraph::NodeTypeDescriptor* type = graph_.node_type(index);
        if (index >= 0 && type != nullptr) {
            const int port = type->find_output(tap_port_name_.c_str());
            if (port >= 0) {
                tap_index_ = index;
                tap_port_index_ = port;
            }
        }
    }
    if (!gate_node_.empty()) {
        const int index = graph_.node_index(gate_node_);
        const soundgraph::NodeTypeDescriptor* type = graph_.node_type(index);
        if (index >= 0 && type != nullptr) {
            const int port = type->find_output(gate_port_name_.c_str());
            if (port >= 0) {
                gate_index_ = index;
                gate_port_index_ = port;
            }
        }
    }

    // The graph does the capturing now, at real block boundaries; the wrapper only
    // points it.
    if (tap_index_ >= 0) {
        graph_.set_tap(0, tap_index_, tap_port_index_, kTapSamples);
    } else {
        graph_.clear_tap(0);
    }
    if (gate_index_ >= 0) {
        graph_.set_tap(1, gate_index_, gate_port_index_, kTapSamples);
    } else {
        graph_.clear_tap(1);
    }
}

bool SoundGraphEngine::set_scope_tap(const String& node_id, const String& port) {
    tap_node_ = to_utf8(node_id);
    tap_port_name_ = to_utf8(port);
    resolve_taps();
    return tap_node_.empty() || tap_index_ >= 0;
}

bool SoundGraphEngine::set_scope_gate(const String& node_id, const String& port) {
    gate_node_ = to_utf8(node_id);
    gate_port_name_ = to_utf8(port);
    resolve_taps();
    return gate_node_.empty() || gate_index_ >= 0;
}

PackedFloat32Array SoundGraphEngine::read_tap(int slot, int samples) const {
    PackedFloat32Array result;
    const int count = std::min(std::max(samples, 0), kTapSamples);
    result.resize(count);
    const int copied = graph_.read_tap(slot, result.ptrw(), count);
    if (copied < count) {
        result.resize(copied);
    }
    return result;
}

PackedFloat32Array SoundGraphEngine::get_scope_tap(int samples) const {
    return read_tap(0, samples);
}

PackedFloat32Array SoundGraphEngine::get_scope_gate(int samples) const {
    return read_tap(1, samples);
}

int SoundGraphEngine::get_scope_tap_edges() const {
    return static_cast<int>(graph_.tap_edges(0));
}

int SoundGraphEngine::get_scope_gate_edges() const {
    return static_cast<int>(graph_.tap_edges(1));
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

// -------------------------------------------------------------------------------------
// Hosted plugins
// -------------------------------------------------------------------------------------

bool SoundGraphEngine::can_host_plugins() const { return plugin_provider_ != nullptr; }

bool SoundGraphEngine::plugin_has_gui(const String& node_id) {
    soundgraph::HostedPluginInstance* plugin = graph_.plugin_for_node(to_utf8(node_id));
    return plugin != nullptr && plugin->has_gui();
}

bool SoundGraphEngine::open_plugin_gui(const String& node_id, int64_t window_handle) {
    if (window_handle == 0) {
        return false;
    }
    const std::string id = to_utf8(node_id);
    soundgraph::HostedPluginInstance* plugin = graph_.plugin_for_node(id);
    if (plugin == nullptr) {
        return false;
    }
    // One editor at a time. Not a limitation of the plugins — a DAW happily shows
    // several — but of this editor, which has one window to lend and one place to put
    // it. Opening a second closes the first rather than leaking it.
    if (!open_gui_node_.empty() && open_gui_node_ != id) {
        close_plugin_gui(String(open_gui_node_.c_str()));
    }
    if (!plugin->open_gui(reinterpret_cast<void*>(static_cast<std::intptr_t>(window_handle)))) {
        return false;
    }
    open_gui_node_ = id;
    return true;
}

void SoundGraphEngine::close_plugin_gui(const String& node_id) {
    const std::string id = to_utf8(node_id);
    if (id.empty()) {
        return;
    }
    if (soundgraph::HostedPluginInstance* plugin = graph_.plugin_for_node(id)) {
        plugin->close_gui();
    }
    if (open_gui_node_ == id) {
        open_gui_node_.clear();
    }
}

Vector2i SoundGraphEngine::plugin_gui_size(const String& node_id) {
    soundgraph::HostedPluginInstance* plugin = graph_.plugin_for_node(to_utf8(node_id));
    int width = 0;
    int height = 0;
    if (plugin == nullptr || !plugin->gui_size(width, height)) {
        return Vector2i(0, 0);
    }
    return Vector2i(width, height);
}

String SoundGraphEngine::plugin_state(const String& node_id) {
    soundgraph::HostedPluginInstance* plugin = graph_.plugin_for_node(to_utf8(node_id));
    std::string bytes;
    if (plugin == nullptr || !plugin->save_state(bytes) || bytes.empty()) {
        return String();
    }
    // Encoded here rather than in GDScript so that there is one spelling of a patch's
    // state in the project, and it is the one patch-io reads back.
    return String(soundgraph::to_base64(bytes).c_str());
}

void SoundGraphEngine::tick_plugins() { graph_.tick_plugins(); }

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
