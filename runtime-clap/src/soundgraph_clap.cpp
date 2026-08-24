// SoundGraph as a CLAP plugin — one player that loads any patch.
//
// Like sg-play, this file contains no DSP. It is the seam between the CLAP API and
// dsp-core: host events become graph events, host buffers receive graph output, and the
// plugin's entire saved state is the patch JSON itself — the canonical artifact, not a
// second format. clap-wrapper compiles this same implementation into the VST3, the
// Audio Unit and the standalone, so every format shares one seam.
//
// Threading follows the graph's contract. Everything that allocates — parsing a patch,
// building the graph — happens on the main thread while the plugin is deactivated. The
// audio thread only ever renders and enqueues events. Switching patches while running
// therefore goes through clap_host.request_restart(): the host deactivates, the swap
// and rebuild happen on the main thread, and processing resumes on the new graph.

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <clap/clap.h>

#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"

#include "default_patch.h"
#include "soundgraph_clap_entry.h"

namespace {

constexpr clap_id kPatchParamId = 1;

const char* kFeatures[] = {CLAP_PLUGIN_FEATURE_INSTRUMENT, CLAP_PLUGIN_FEATURE_SYNTHESIZER,
                           CLAP_PLUGIN_FEATURE_STEREO, nullptr};

const clap_plugin_descriptor_t kDescriptor = {
    CLAP_VERSION_INIT,
    "org.soundgraph.player",
    "SoundGraph",
    "SoundGraph",
    "https://github.com/DazzlingDukeOfLazers/soundgraph",
    "",
    "",
    "0.1.0",
    "Plays any SoundGraph patch as an instrument",
    kFeatures};

// Parameter ids must stay stable across sessions for host automation to survive a
// project reload, so they are derived from the control's id string rather than its
// position. FNV-1a, with collisions (and the reserved patch-selector id) probed away.
std::uint32_t fnv1a(const std::string& text) {
    std::uint32_t hash = 2166136261u;
    for (const char character : text) {
        hash ^= static_cast<unsigned char>(character);
        hash *= 16777619u;
    }
    return hash;
}

struct ParamSlot {
    clap_id id = 0;
    std::string name;          // what the host displays
    double min_value = 0.0;
    double max_value = 1.0;
    double default_value = 0.0;
    bool stepped = false;
    int control_index = -1;    // into description.controls / authored_controls
    int node_index = -1;       // resolved against the built graph
    int parameter_index = -1;
};

struct DiscoveredPatch {
    std::string label;
    std::string path;  // empty for the built-in patch
};

struct Plugin {
    clap_plugin_t plugin{};
    const clap_host_t* host = nullptr;
    const clap_host_params_t* host_params = nullptr;

    soundgraph::Graph graph;
    soundgraph::GraphDescription description;
    std::vector<DiscoveredPatch> patches;

    std::vector<ParamSlot> params;
    std::unordered_map<clap_id, int> param_by_id;
    std::unique_ptr<std::atomic<float>[]> values;

    // Which entry of `patches` is loaded, and which one a patch-selector event asked
    // for. The audio thread only writes the request; the main thread performs the swap.
    int current_patch = 0;
    std::atomic<int> requested_patch{0};

    // A patch arriving through state load, waiting for the main thread while inactive.
    std::unique_ptr<soundgraph::GraphDescription> pending_description;

    bool active = false;
    double sample_rate = 48000.0;
};

Plugin* self(const clap_plugin_t* plugin) {
    return static_cast<Plugin*>(plugin->plugin_data);
}

// ---- patch discovery ---------------------------------------------------------------
// The selector parameter lists whatever patches can be found when the plugin is
// created: the built-in patch, then every .json under $SOUNDGRAPH_PATCHES (a
// path-separated list) and ~/Documents/SoundGraph/Patches. A host's generic parameter
// UI is thereby enough to play any patch — no plugin GUI required yet.

void scan_directory(const std::filesystem::path& directory, std::vector<DiscoveredPatch>& out) {
    std::error_code error;
    std::filesystem::recursive_directory_iterator iterator(directory, error);
    if (error) {
        return;
    }
    for (const auto& entry : iterator) {
        if (out.size() >= 256) {
            return;
        }
        if (entry.is_regular_file(error) && entry.path().extension() == ".json") {
            DiscoveredPatch patch;
            patch.label = entry.path().stem().string();
            patch.path = entry.path().string();
            out.push_back(std::move(patch));
        }
    }
}

std::vector<DiscoveredPatch> discover_patches() {
    std::vector<DiscoveredPatch> found;
    found.push_back({"First Synth (built in)", ""});

    if (const char* list = std::getenv("SOUNDGRAPH_PATCHES")) {
#if defined(_WIN32)
        const char separator = ';';
#else
        const char separator = ':';
#endif
        std::string remaining = list;
        while (!remaining.empty()) {
            const std::size_t cut = remaining.find(separator);
            const std::string piece = remaining.substr(0, cut);
            if (!piece.empty()) {
                scan_directory(piece, found);
            }
            remaining = (cut == std::string::npos) ? "" : remaining.substr(cut + 1);
        }
    }

#if defined(_WIN32)
    const char* home = std::getenv("USERPROFILE");
#else
    const char* home = std::getenv("HOME");
#endif
    if (home != nullptr) {
        scan_directory(std::filesystem::path(home) / "Documents" / "SoundGraph" / "Patches",
                       found);
    }
    return found;
}

// ---- description helpers -----------------------------------------------------------

bool parse_default_patch(soundgraph::GraphDescription& out,
                         std::vector<soundgraph::Diagnostic>& diagnostics) {
    const std::string text(reinterpret_cast<const char*>(soundgraph_clap::kDefaultPatch));
    return soundgraph::parse_patch(text, out, diagnostics);
}

// Rebuilds the parameter table from the description's controls. Main thread,
// deactivated only — the audio thread reads these structures during process().
void rebuild_params(Plugin* plug) {
    plug->params.clear();
    plug->param_by_id.clear();

    for (int i = 0; i < static_cast<int>(plug->description.controls.size()); ++i) {
        const soundgraph::ControlDescription& control = plug->description.controls[static_cast<std::size_t>(i)];

        ParamSlot slot;
        slot.name = control.label.empty() ? control.id : control.label;
        slot.control_index = i;
        if (control.has_range) {
            slot.min_value = control.min_value;
            slot.max_value = control.max_value;
        }
        if (control.has_default) {
            slot.default_value = control.default_value;
        } else if (const soundgraph::NodeDescription* node =
                       plug->description.find_node(control.target.node)) {
            if (const soundgraph::ParameterValue* parameter =
                    node->find_parameter(control.target.parameter)) {
                slot.default_value = parameter->value;
            }
        }
        if (slot.default_value < slot.min_value) slot.default_value = slot.min_value;
        if (slot.default_value > slot.max_value) slot.default_value = slot.max_value;

        clap_id id = fnv1a(control.id);
        while (id == kPatchParamId || id == 0 || id == CLAP_INVALID_ID ||
               plug->param_by_id.count(id) != 0) {
            ++id;
        }
        slot.id = id;

        plug->param_by_id.emplace(slot.id, static_cast<int>(plug->params.size()));
        plug->params.push_back(std::move(slot));
    }

    plug->values = std::make_unique<std::atomic<float>[]>(plug->params.size());
    for (std::size_t i = 0; i < plug->params.size(); ++i) {
        plug->values[i].store(static_cast<float>(plug->params[i].default_value),
                              std::memory_order_relaxed);
    }
}

// Applies a freshly parsed patch as the current description. Main thread, deactivated.
void adopt_description(Plugin* plug, soundgraph::GraphDescription&& description) {
    plug->description = std::move(description);
    rebuild_params(plug);
    if (plug->host_params != nullptr) {
        plug->host_params->rescan(plug->host, CLAP_PARAM_RESCAN_ALL);
    }
}

// Loads the patch the selector points at. Falls back to the built-in patch when a file
// has gone missing or no longer parses. Main thread, deactivated.
void load_selected_patch(Plugin* plug) {
    const int wanted = plug->requested_patch.load(std::memory_order_relaxed);
    const int index = (wanted >= 0 && wanted < static_cast<int>(plug->patches.size())) ? wanted : 0;

    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;
    bool loaded = false;
    const std::string& path = plug->patches[static_cast<std::size_t>(index)].path;
    if (!path.empty()) {
        loaded = soundgraph::load_patch(path, description, diagnostics);
    }
    if (!loaded) {
        description = soundgraph::GraphDescription();
        diagnostics.clear();
        if (!parse_default_patch(description, diagnostics)) {
            return;  // the embedded patch failing to parse would be a build defect
        }
    }
    plug->current_patch = index;
    plug->requested_patch.store(index, std::memory_order_relaxed);
    adopt_description(plug, std::move(description));
}

// Any patch waiting to be applied? Main thread, called while deactivated.
void apply_pending(Plugin* plug) {
    if (plug->pending_description) {
        std::unique_ptr<soundgraph::GraphDescription> pending = std::move(plug->pending_description);
        adopt_description(plug, std::move(*pending));
        return;
    }
    if (plug->requested_patch.load(std::memory_order_relaxed) != plug->current_patch) {
        load_selected_patch(plug);
    }
}

// ---- event handling ----------------------------------------------------------------
// Audio thread. Notes go straight into the graph; parameter events update the cached
// value (for host reads) and enqueue the change for the next rendered block.

void handle_event(Plugin* plug, const clap_event_header_t* header) {
    if (header->space_id != CLAP_CORE_EVENT_SPACE_ID) {
        return;
    }
    switch (header->type) {
        case CLAP_EVENT_NOTE_ON:
        case CLAP_EVENT_NOTE_OFF:
        case CLAP_EVENT_NOTE_CHOKE: {
            const auto* event = reinterpret_cast<const clap_event_note_t*>(header);
            soundgraph::NoteEvent note;
            note.kind = (header->type == CLAP_EVENT_NOTE_ON)
                            ? soundgraph::NoteEvent::Kind::NoteOn
                            : soundgraph::NoteEvent::Kind::NoteOff;
            note.note = event->key;
            note.velocity = static_cast<float>(event->velocity);
            plug->graph.dispatch_note(note);
            break;
        }
        case CLAP_EVENT_MIDI: {
            const auto* event = reinterpret_cast<const clap_event_midi_t*>(header);
            const std::uint8_t status = event->data[0] & 0xF0;
            soundgraph::NoteEvent note;
            note.note = event->data[1];
            note.velocity = static_cast<float>(event->data[2]) / 127.0f;
            if (status == 0x90 && event->data[2] != 0) {
                note.kind = soundgraph::NoteEvent::Kind::NoteOn;
                plug->graph.dispatch_note(note);
            } else if (status == 0x80 || (status == 0x90 && event->data[2] == 0)) {
                note.kind = soundgraph::NoteEvent::Kind::NoteOff;
                plug->graph.dispatch_note(note);
            } else if (status == 0xB0 && (event->data[1] == 120 || event->data[1] == 123)) {
                note.kind = soundgraph::NoteEvent::Kind::AllNotesOff;
                plug->graph.dispatch_note(note);
            }
            break;
        }
        case CLAP_EVENT_PARAM_VALUE: {
            const auto* event = reinterpret_cast<const clap_event_param_value_t*>(header);
            if (event->param_id == kPatchParamId) {
                const int wanted = static_cast<int>(event->value + 0.5);
                if (wanted != plug->current_patch) {
                    plug->requested_patch.store(wanted, std::memory_order_relaxed);
                    plug->host->request_restart(plug->host);
                }
                break;
            }
            const auto found = plug->param_by_id.find(event->param_id);
            if (found == plug->param_by_id.end()) {
                break;
            }
            const ParamSlot& slot = plug->params[static_cast<std::size_t>(found->second)];
            const float value = static_cast<float>(event->value);
            plug->values[static_cast<std::size_t>(found->second)].store(value, std::memory_order_relaxed);
            if (slot.node_index >= 0 && slot.parameter_index >= 0) {
                plug->graph.set_parameter(slot.node_index, slot.parameter_index, value);
            }
            break;
        }
        default:
            break;
    }
}

// ---- clap_plugin_audio_ports -------------------------------------------------------

uint32_t audio_ports_count(const clap_plugin_t*, bool is_input) {
    return is_input ? 0 : 1;
}

bool audio_ports_get(const clap_plugin_t*, uint32_t index, bool is_input,
                     clap_audio_port_info_t* info) {
    if (is_input || index != 0) {
        return false;
    }
    info->id = 0;
    std::snprintf(info->name, sizeof(info->name), "%s", "Output");
    info->flags = CLAP_AUDIO_PORT_IS_MAIN;
    info->channel_count = 2;
    info->port_type = CLAP_PORT_STEREO;
    info->in_place_pair = CLAP_INVALID_ID;
    return true;
}

const clap_plugin_audio_ports_t kAudioPorts = {audio_ports_count, audio_ports_get};

// ---- clap_plugin_note_ports --------------------------------------------------------

uint32_t note_ports_count(const clap_plugin_t*, bool is_input) {
    return is_input ? 1 : 0;
}

bool note_ports_get(const clap_plugin_t*, uint32_t index, bool is_input,
                    clap_note_port_info_t* info) {
    if (!is_input || index != 0) {
        return false;
    }
    info->id = 0;
    info->supported_dialects = CLAP_NOTE_DIALECT_CLAP | CLAP_NOTE_DIALECT_MIDI;
    info->preferred_dialect = CLAP_NOTE_DIALECT_CLAP;
    std::snprintf(info->name, sizeof(info->name), "%s", "Notes");
    return true;
}

const clap_plugin_note_ports_t kNotePorts = {note_ports_count, note_ports_get};

// ---- clap_plugin_params ------------------------------------------------------------

uint32_t params_count(const clap_plugin_t* plugin) {
    return 1 + static_cast<uint32_t>(self(plugin)->params.size());
}

bool params_get_info(const clap_plugin_t* plugin, uint32_t index, clap_param_info_t* info) {
    Plugin* plug = self(plugin);
    if (index == 0) {
        info->id = kPatchParamId;
        info->flags = CLAP_PARAM_IS_STEPPED;
        info->cookie = nullptr;
        std::snprintf(info->name, sizeof(info->name), "%s", "Patch");
        std::snprintf(info->module, sizeof(info->module), "%s", "");
        info->min_value = 0.0;
        info->max_value = static_cast<double>(plug->patches.size() - 1);
        info->default_value = 0.0;
        return true;
    }
    const std::size_t slot_index = index - 1;
    if (slot_index >= plug->params.size()) {
        return false;
    }
    const ParamSlot& slot = plug->params[slot_index];
    info->id = slot.id;
    info->flags = CLAP_PARAM_IS_AUTOMATABLE;
    info->cookie = nullptr;
    std::snprintf(info->name, sizeof(info->name), "%s", slot.name.c_str());
    std::snprintf(info->module, sizeof(info->module), "%s", "");
    info->min_value = slot.min_value;
    info->max_value = slot.max_value;
    info->default_value = slot.default_value;
    return true;
}

bool params_get_value(const clap_plugin_t* plugin, clap_id param_id, double* out_value) {
    Plugin* plug = self(plugin);
    if (param_id == kPatchParamId) {
        *out_value = static_cast<double>(plug->requested_patch.load(std::memory_order_relaxed));
        return true;
    }
    const auto found = plug->param_by_id.find(param_id);
    if (found == plug->param_by_id.end()) {
        return false;
    }
    *out_value = static_cast<double>(
        plug->values[static_cast<std::size_t>(found->second)].load(std::memory_order_relaxed));
    return true;
}

bool params_value_to_text(const clap_plugin_t* plugin, clap_id param_id, double value,
                          char* out, uint32_t out_size) {
    Plugin* plug = self(plugin);
    if (param_id == kPatchParamId) {
        const int index = static_cast<int>(value + 0.5);
        if (index < 0 || index >= static_cast<int>(plug->patches.size())) {
            return false;
        }
        std::snprintf(out, out_size, "%s", plug->patches[static_cast<std::size_t>(index)].label.c_str());
        return true;
    }
    std::snprintf(out, out_size, "%.4g", value);
    return true;
}

bool params_text_to_value(const clap_plugin_t* plugin, clap_id param_id, const char* text,
                          double* out_value) {
    Plugin* plug = self(plugin);
    if (param_id == kPatchParamId) {
        for (std::size_t i = 0; i < plug->patches.size(); ++i) {
            if (plug->patches[i].label == text) {
                *out_value = static_cast<double>(i);
                return true;
            }
        }
        return false;
    }
    *out_value = std::atof(text);
    return true;
}

void params_flush(const clap_plugin_t* plugin, const clap_input_events_t* in,
                  const clap_output_events_t*) {
    Plugin* plug = self(plugin);
    const uint32_t count = in->size(in);
    for (uint32_t i = 0; i < count; ++i) {
        handle_event(plug, in->get(in, i));
    }
}

const clap_plugin_params_t kParams = {params_count, params_get_info, params_get_value,
                                      params_value_to_text, params_text_to_value, params_flush};

// ---- clap_plugin_state -------------------------------------------------------------
// The state is the patch, verbatim. A project saved in a DAW carries the whole graph,
// with the current knob positions written back into the node parameters they drive —
// in both the flattened and the authored views, which stay index-parallel through
// module expansion.

void write_value_into(std::vector<soundgraph::NodeDescription>& nodes,
                      const soundgraph::ControlTarget& target, float value) {
    for (soundgraph::NodeDescription& node : nodes) {
        if (node.id != target.node) {
            continue;
        }
        for (soundgraph::ParameterValue& parameter : node.parameters) {
            if (parameter.name == target.parameter) {
                parameter.value = static_cast<double>(value);
                return;
            }
        }
        soundgraph::ParameterValue parameter;
        parameter.name = target.parameter;
        parameter.value = static_cast<double>(value);
        node.parameters.push_back(std::move(parameter));
        return;
    }
}

bool state_save(const clap_plugin_t* plugin, const clap_ostream_t* stream) {
    Plugin* plug = self(plugin);

    soundgraph::GraphDescription snapshot = plug->description;
    for (const ParamSlot& slot : plug->params) {
        const float value = plug->values[static_cast<std::size_t>(&slot - plug->params.data())]
                                .load(std::memory_order_relaxed);
        const std::size_t control_index = static_cast<std::size_t>(slot.control_index);
        write_value_into(snapshot.nodes, snapshot.controls[control_index].target, value);
        if (snapshot.authored_taken && control_index < snapshot.authored_controls.size()) {
            write_value_into(snapshot.authored_nodes,
                             snapshot.authored_controls[control_index].target, value);
        }
    }

    const std::string text = soundgraph::write_patch(snapshot, true);
    std::size_t written = 0;
    while (written < text.size()) {
        const int64_t result = stream->write(stream, text.data() + written, text.size() - written);
        if (result <= 0) {
            return false;
        }
        written += static_cast<std::size_t>(result);
    }
    return true;
}

bool state_load(const clap_plugin_t* plugin, const clap_istream_t* stream) {
    Plugin* plug = self(plugin);

    std::string text;
    char buffer[4096];
    while (true) {
        const int64_t result = stream->read(stream, buffer, sizeof(buffer));
        if (result < 0) {
            return false;
        }
        if (result == 0) {
            break;
        }
        text.append(buffer, static_cast<std::size_t>(result));
    }

    auto description = std::make_unique<soundgraph::GraphDescription>();
    std::vector<soundgraph::Diagnostic> diagnostics;
    if (!soundgraph::parse_patch(text, *description, diagnostics)) {
        return false;
    }

    plug->pending_description = std::move(description);
    if (plug->active) {
        plug->host->request_restart(plug->host);
    } else {
        apply_pending(plug);
    }
    return true;
}

const clap_plugin_state_t kState = {state_save, state_load};

// ---- clap_plugin -------------------------------------------------------------------

bool plugin_init(const clap_plugin_t* plugin) {
    Plugin* plug = self(plugin);
    plug->host_params = static_cast<const clap_host_params_t*>(
        plug->host->get_extension(plug->host, CLAP_EXT_PARAMS));

    plug->patches = discover_patches();

    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;
    if (!parse_default_patch(description, diagnostics)) {
        return false;
    }
    plug->description = std::move(description);
    rebuild_params(plug);
    return true;
}

void plugin_destroy(const clap_plugin_t* plugin) {
    delete self(plugin);
}

bool plugin_activate(const clap_plugin_t* plugin, double sample_rate, uint32_t, uint32_t) {
    Plugin* plug = self(plugin);
    apply_pending(plug);

    plug->sample_rate = sample_rate;
    soundgraph::PrepareContext context;
    context.sample_rate = sample_rate;

    std::vector<soundgraph::Diagnostic> diagnostics;
    if (!plug->graph.build(plug->description, soundgraph::NodeRegistry::builtin(), context,
                           diagnostics)) {
        return false;
    }

    // Resolve every control against the built graph, then hand the cached values to the
    // control queue so the first rendered block already sits at the knob positions.
    for (std::size_t i = 0; i < plug->params.size(); ++i) {
        ParamSlot& slot = plug->params[i];
        const soundgraph::ControlTarget& target =
            plug->description.controls[static_cast<std::size_t>(slot.control_index)].target;
        slot.node_index = plug->graph.node_index(target.node);
        slot.parameter_index = (slot.node_index >= 0)
            ? plug->graph.parameter_index(slot.node_index, target.parameter) : -1;
        if (slot.node_index >= 0 && slot.parameter_index >= 0) {
            plug->graph.set_parameter(slot.node_index, slot.parameter_index,
                                      plug->values[i].load(std::memory_order_relaxed));
        }
    }

    plug->active = true;
    return true;
}

void plugin_deactivate(const clap_plugin_t* plugin) {
    Plugin* plug = self(plugin);
    plug->active = false;
    apply_pending(plug);
}

bool plugin_start_processing(const clap_plugin_t*) {
    return true;
}

void plugin_stop_processing(const clap_plugin_t*) {}

void plugin_reset(const clap_plugin_t* plugin) {
    self(plugin)->graph.reset();
}

clap_process_status plugin_process(const clap_plugin_t* plugin, const clap_process_t* process) {
    Plugin* plug = self(plugin);

    float* left = process->audio_outputs[0].data32[0];
    float* right = process->audio_outputs[0].data32[1];
    const uint32_t total_frames = process->frames_count;

    const clap_input_events_t* events = process->in_events;
    const uint32_t event_count = events->size(events);

    // Events land at their declared frame: render up to each event's time, apply it,
    // continue. The graph's own fixed internal blocks keep the output identical to what
    // any other host — or any other buffer segmentation — would produce.
    uint32_t cursor = 0;
    for (uint32_t i = 0; i < event_count; ++i) {
        const clap_event_header_t* header = events->get(events, i);
        if (header->time > cursor) {
            const uint32_t frames = header->time - cursor;
            plug->graph.render(left + cursor, right + cursor, static_cast<int>(frames));
            cursor += frames;
        }
        handle_event(plug, header);
    }
    if (cursor < total_frames) {
        plug->graph.render(left + cursor, right + cursor, static_cast<int>(total_frames - cursor));
    }

    return CLAP_PROCESS_CONTINUE;
}

const void* plugin_get_extension(const clap_plugin_t*, const char* id) {
    if (std::strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0) return &kAudioPorts;
    if (std::strcmp(id, CLAP_EXT_NOTE_PORTS) == 0) return &kNotePorts;
    if (std::strcmp(id, CLAP_EXT_PARAMS) == 0) return &kParams;
    if (std::strcmp(id, CLAP_EXT_STATE) == 0) return &kState;
    return nullptr;
}

void plugin_on_main_thread(const clap_plugin_t*) {}

// ---- factory -----------------------------------------------------------------------

uint32_t factory_get_plugin_count(const clap_plugin_factory_t*) {
    return 1;
}

const clap_plugin_descriptor_t* factory_get_plugin_descriptor(const clap_plugin_factory_t*,
                                                              uint32_t index) {
    return index == 0 ? &kDescriptor : nullptr;
}

const clap_plugin_t* factory_create_plugin(const clap_plugin_factory_t*, const clap_host_t* host,
                                           const char* plugin_id) {
    if (std::strcmp(plugin_id, kDescriptor.id) != 0) {
        return nullptr;
    }
    Plugin* plug = new Plugin();
    plug->host = host;
    plug->plugin.desc = &kDescriptor;
    plug->plugin.plugin_data = plug;
    plug->plugin.init = plugin_init;
    plug->plugin.destroy = plugin_destroy;
    plug->plugin.activate = plugin_activate;
    plug->plugin.deactivate = plugin_deactivate;
    plug->plugin.start_processing = plugin_start_processing;
    plug->plugin.stop_processing = plugin_stop_processing;
    plug->plugin.reset = plugin_reset;
    plug->plugin.process = plugin_process;
    plug->plugin.get_extension = plugin_get_extension;
    plug->plugin.on_main_thread = plugin_on_main_thread;
    return &plug->plugin;
}

const clap_plugin_factory_t kFactory = {factory_get_plugin_count, factory_get_plugin_descriptor,
                                        factory_create_plugin};

}  // namespace

bool soundgraph_clap_init(const char*) {
    return true;
}

void soundgraph_clap_deinit() {}

const void* soundgraph_clap_get_factory(const char* factory_id) {
    if (std::strcmp(factory_id, CLAP_PLUGIN_FACTORY_ID) == 0) {
        return &kFactory;
    }
    return nullptr;
}
