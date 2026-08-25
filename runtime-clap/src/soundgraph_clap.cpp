// SoundGraph as a CLAP plugin — one player that loads any patch.
//
// Like sg-play, this file contains no DSP. It is the seam between the CLAP API and
// dsp-core: host events become graph events, host buffers receive graph output, and the
// plugin's entire saved state is the patch JSON itself — the canonical artifact, not a
// second format. clap-wrapper compiles this same implementation into the VST3, the
// Audio Unit and the standalone, so every format shares one seam.
//
// The parameter surface is fixed: a patch selector plus kSlotCount normalised slots,
// slot i driving control i of whatever patch is loaded. Fixed, because the VST3 model
// cannot add or remove parameters while running, and because a host is only obliged to
// honour CLAP_PARAM_RESCAN_ALL through a restart it may or may not grant (Reaper, for
// one, does not). Renaming slots needs only CLAP_PARAM_RESCAN_INFO, which every format
// applies immediately — so switching patches never has to ask the host's permission.
//
// Threading follows the graph's contract. Everything that allocates — parsing a patch,
// building a graph — happens on the main thread, into a fresh GraphInstance; the audio
// thread adopts it with one atomic exchange at the top of process() and pushes the old
// instance onto a graveyard stack the main thread later frees. The audio thread only
// ever renders and enqueues events; it never allocates, frees, or parses.

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cctype>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

#include <clap/clap.h>

#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"

// The GUI is one webview showing the embedded panel.html. choc drives the platform
// webview (WKWebView / WebView2) from plain C++, ISC-licensed and vendored like
// miniaudio. See docs/decisions.md.
#if defined(__APPLE__) || defined(_WIN32)
#define SOUNDGRAPH_HAS_GUI 1
#include "choc/gui/choc_WebView.h"
#if defined(__APPLE__)
#include "choc/platform/choc_ObjectiveCHelpers.h"
#endif
#include "panel_html.h"
#endif

#include "default_patch.h"
#include "soundgraph_clap_entry.h"

namespace {

constexpr clap_id kPatchParamId = 1;
constexpr clap_id kSlotIdBase = 1000;
constexpr int kSlotCount = 32;

const char* kFeatures[] = {CLAP_PLUGIN_FEATURE_INSTRUMENT, CLAP_PLUGIN_FEATURE_SYNTHESIZER,
                           CLAP_PLUGIN_FEATURE_STEREO, nullptr};

const clap_plugin_descriptor_t kDescriptor = {
    CLAP_VERSION_INIT,
    "org.soundgraph.player",
    "SoundGraph",
    "MutantFactory.net",
    "https://mutantfactory.net",
    "",
    "",
    "0.1.0",
    "SoundGraph by MutantFactory.net — plays any SoundGraph patch as an instrument",
    kFeatures};

enum class Scaling { Linear, Exponential };

// What the host sees of a slot. Main thread only.
struct SlotMeta {
    bool bound = false;
    std::string name;
    double min_value = 0.0;
    double max_value = 1.0;
    Scaling scaling = Scaling::Linear;
    double default_normalized = 0.0;
};

// What the audio thread needs of a slot, resolved against one particular graph and
// carried with it, so an event can never mix one patch's indices with another's nodes.
struct SlotBinding {
    bool bound = false;
    int node_index = -1;
    int parameter_index = -1;
    double min_value = 0.0;
    double max_value = 1.0;
    Scaling scaling = Scaling::Linear;
};

struct GraphInstance {
    soundgraph::Graph graph;
    std::array<SlotBinding, kSlotCount> bindings{};
    GraphInstance* graveyard_next = nullptr;
};

struct DiscoveredPatch {
    std::string label;
    std::string path;  // empty for the built-in patch
};

// A parameter change born in the GUI. It must reach two places: the graph (so the
// knob does something) and the host's input queue as an *output* event (so automation
// records and the project marks dirty). The GUI thread produces; process() — or
// flush(), when inactive — consumes.
struct GuiEvent {
    enum class Kind : std::uint8_t { GestureBegin, Value, GestureEnd };
    Kind kind = Kind::Value;
    clap_id param_id = 0;
    double value = 0.0;
};

class GuiEventQueue {
public:
    bool push(const GuiEvent& event) {
        const std::uint32_t write = write_.load(std::memory_order_relaxed);
        if (write + 1 - read_.load(std::memory_order_acquire) > kCapacity) {
            return false;
        }
        items_[write & (kCapacity - 1)] = event;
        write_.store(write + 1, std::memory_order_release);
        return true;
    }
    bool pop(GuiEvent& out) {
        const std::uint32_t read = read_.load(std::memory_order_relaxed);
        if (read == write_.load(std::memory_order_acquire)) {
            return false;
        }
        out = items_[read & (kCapacity - 1)];
        read_.store(read + 1, std::memory_order_release);
        return true;
    }

private:
    static constexpr std::uint32_t kCapacity = 512;
    std::array<GuiEvent, kCapacity> items_{};
    std::atomic<std::uint32_t> write_{0};
    std::atomic<std::uint32_t> read_{0};
};

#if defined(SOUNDGRAPH_HAS_GUI)
struct GuiState {
    std::unique_ptr<choc::ui::WebView> webview;
    double scale = 1.0;
    // Windows builds its webview asynchronously, so the bindings and the page cannot
    // be installed at create time — see finish_gui_setup. `dressed` records that they
    // finally were; `timer` is the host timer we asked for in order to keep trying.
    bool dressed = false;
    clap_id timer = CLAP_INVALID_ID;
};
constexpr uint32_t kGuiWidth = 560;
constexpr uint32_t kGuiHeight = 460;
// How often to ask an asynchronous webview whether it has finished starting, and how
// long to wait for it by hand when the host offers no timer to ask from.
constexpr uint32_t kGuiTimerMs = 16;
constexpr uint32_t kGuiPumpMs = 3000;
#endif

struct Plugin {
    clap_plugin_t plugin{};
    const clap_host_t* host = nullptr;
    const clap_host_params_t* host_params = nullptr;

    // Main thread.
    soundgraph::GraphDescription description;
    std::vector<DiscoveredPatch> patches;
    std::string patch_display;  // the loaded patch's name, shown as the params' module
    std::array<SlotMeta, kSlotCount> slots{};
    int current_patch = 0;
    std::unique_ptr<soundgraph::GraphDescription> pending_description;
    double sample_rate = 48000.0;
    bool initialized = false;  // no host callbacks (rescan) until init has returned

    // Shared.
    std::array<std::atomic<float>, kSlotCount> values{};  // normalised 0..1
    std::atomic<int> requested_patch{0};
    std::atomic<bool> active{false};
    std::atomic<int> state_version{0};  // bumped per adopt; the GUI polls it
    GuiEventQueue gui_events;
#if defined(SOUNDGRAPH_HAS_GUI)
    std::unique_ptr<GuiState> gui;
#endif

    // The live graph. `live` belongs to the audio thread while active; `incoming` is
    // the main thread's handoff; `graveyard` is the audio thread's return path.
    GraphInstance* live = nullptr;
    std::atomic<GraphInstance*> incoming{nullptr};
    std::atomic<GraphInstance*> graveyard{nullptr};
};

Plugin* self(const clap_plugin_t* plugin) {
    return static_cast<Plugin*>(plugin->plugin_data);
}

// Debug tracing, only when SOUNDGRAPH_CLAP_TRACE names a file. Never in the render path
// unless something is already going wrong enough to be chasing it.
FILE* trace_file() {
    static FILE* file = [] {
        const char* path = std::getenv("SOUNDGRAPH_CLAP_TRACE");
        return path != nullptr ? std::fopen(path, "a") : nullptr;
    }();
    return file;
}

#define SG_TRACE(...)                            \
    do {                                         \
        if (FILE* f = trace_file()) {            \
            std::fprintf(f, __VA_ARGS__);        \
            std::fputc('\n', f);                 \
            std::fflush(f);                      \
        }                                        \
    } while (false)

double slot_to_engine(double min_value, double max_value, Scaling scaling, double t) {
    t = std::min(1.0, std::max(0.0, t));
    if (scaling == Scaling::Exponential && min_value > 0.0) {
        return min_value * std::pow(max_value / min_value, t);
    }
    return min_value + t * (max_value - min_value);
}

double engine_to_slot(double min_value, double max_value, Scaling scaling, double value) {
    if (scaling == Scaling::Exponential && min_value > 0.0 && value > 0.0) {
        return std::log(value / min_value) / std::log(max_value / min_value);
    }
    if (max_value == min_value) {
        return 0.0;
    }
    return (value - min_value) / (max_value - min_value);
}

// ---- patch discovery ---------------------------------------------------------------
// The selector parameter lists whatever patches can be found when the plugin is
// created: the built-in patch, then every .json under $SOUNDGRAPH_PATCHES (a
// path-separated list) and ~/Documents/SoundGraph/Patches. A host's generic parameter
// UI is thereby enough to play any patch — no plugin GUI required yet.

void scan_directory(const std::filesystem::path& directory, std::vector<DiscoveredPatch>& out) {
    // Every step uses the error_code forms: a plain increment throws on the first
    // unreadable entry, and sandboxed plugin hosts (GarageBand's AU service, denied a
    // folder by TCC) make unreadable entries an ordinary Tuesday. An exception here
    // escapes clap_plugin.init and the host shows a warning triangle instead of a synth.
    std::error_code error;
    std::filesystem::recursive_directory_iterator iterator(directory, error);
    const std::filesystem::recursive_directory_iterator end;
    while (!error && iterator != end) {
        if (out.size() >= 256) {
            return;
        }
        const std::filesystem::directory_entry& entry = *iterator;
        if (entry.is_regular_file(error) && entry.path().extension() == ".json") {
            DiscoveredPatch patch;
            patch.label = entry.path().stem().string();
            patch.path = entry.path().string();
            out.push_back(std::move(patch));
        }
        iterator.increment(error);
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
    if (const char* home = std::getenv("USERPROFILE")) {
        scan_directory(std::filesystem::path(home) / "Documents" / "SoundGraph" / "Patches",
                       found);
    }
#else
    // Not ~/Documents: that folder is TCC-protected on macOS, and a plugin scanning it
    // makes every host pop a consent dialog — or fail inside a sandboxed AU service
    // that cannot show one. The Audio Presets folder is the convention and is not gated.
    if (const char* home = std::getenv("HOME")) {
        scan_directory(std::filesystem::path(home) / "Library" / "Audio" / "Presets" /
                           "SoundGraph" / "Patches",
                       found);
    }
#endif
    // Directory iteration order is filesystem-dependent; the selector's indices must
    // not be. The built-in patch stays at zero.
    std::sort(found.begin() + 1, found.end(),
              [](const DiscoveredPatch& a, const DiscoveredPatch& b) { return a.label < b.label; });
    return found;
}

// With nothing but the built-in patch, a selector would be a stepped parameter whose
// min equals its max — which a VST3 host normalises into NaN. No choices, no knob.
bool has_patch_param(const Plugin* plug) {
    return plug->patches.size() > 1;
}

// ---- description helpers -----------------------------------------------------------

bool parse_default_patch(soundgraph::GraphDescription& out,
                         std::vector<soundgraph::Diagnostic>& diagnostics) {
    const std::string text(reinterpret_cast<const char*>(soundgraph_clap::kDefaultPatch));
    return soundgraph::parse_patch(text, out, diagnostics);
}

Scaling scaling_of(const soundgraph::ControlDescription& control) {
    if (control.scaling == "exponential" || control.scaling == "logarithmic") {
        return Scaling::Exponential;
    }
    return Scaling::Linear;
}

// Makes `description` current: refills the slot table and resets slot values to the
// patch's own. Main thread. Safe while active — the audio thread never reads SlotMeta,
// and renaming slots needs only CLAP_PARAM_RESCAN_INFO.
void adopt_description(Plugin* plug, soundgraph::GraphDescription&& description) {
    plug->description = std::move(description);

    // The patch's own name becomes the parameters' module, so a host panel says which
    // patch this instance is playing — the one thing that tells two instances apart.
    plug->patch_display = plug->description.metadata_value("name");
    if (plug->patch_display.empty()) {
        plug->patch_display =
            plug->patches[static_cast<std::size_t>(plug->current_patch)].label;
    }

    for (int i = 0; i < kSlotCount; ++i) {
        SlotMeta& slot = plug->slots[static_cast<std::size_t>(i)];
        if (i >= static_cast<int>(plug->description.controls.size())) {
            slot = SlotMeta{};
            slot.name = "(unused)";
            plug->values[static_cast<std::size_t>(i)].store(0.0f, std::memory_order_relaxed);
            continue;
        }
        const soundgraph::ControlDescription& control =
            plug->description.controls[static_cast<std::size_t>(i)];
        slot.bound = true;
        slot.name = control.label.empty() ? control.id : control.label;
        slot.min_value = control.has_range ? control.min_value : 0.0;
        slot.max_value = control.has_range ? control.max_value : 1.0;
        slot.scaling = scaling_of(control);

        double engine_default = slot.min_value;
        if (control.has_default) {
            engine_default = control.default_value;
        } else if (const soundgraph::NodeDescription* node =
                       plug->description.find_node(control.target.node)) {
            if (const soundgraph::ParameterValue* parameter =
                    node->find_parameter(control.target.parameter)) {
                engine_default = parameter->value;
            }
        }
        slot.default_normalized =
            engine_to_slot(slot.min_value, slot.max_value, slot.scaling, engine_default);
        plug->values[static_cast<std::size_t>(i)].store(
            static_cast<float>(slot.default_normalized), std::memory_order_relaxed);
    }

    // Calling back into the host during clap_plugin.init is not allowed — the first
    // adopt happens there, and the host reads the fresh surface right afterwards anyway.
    plug->state_version.fetch_add(1, std::memory_order_relaxed);

    if (plug->initialized && plug->host_params != nullptr) {
        plug->host_params->rescan(plug->host, CLAP_PARAM_RESCAN_INFO | CLAP_PARAM_RESCAN_VALUES |
                                                  CLAP_PARAM_RESCAN_TEXT);
    }
}

// Builds a GraphInstance for the current description at the current sample rate, with
// bindings resolved and the current slot values queued so the first block already sits
// at the knob positions. Main thread; returns null if the patch cannot be realised.
GraphInstance* make_instance(Plugin* plug) {
    auto instance = std::make_unique<GraphInstance>();

    soundgraph::PrepareContext context;
    context.sample_rate = plug->sample_rate;
    std::vector<soundgraph::Diagnostic> diagnostics;
    if (!instance->graph.build(plug->description, soundgraph::NodeRegistry::builtin(), context,
                               diagnostics)) {
        return nullptr;
    }

    for (int i = 0; i < kSlotCount; ++i) {
        const SlotMeta& slot = plug->slots[static_cast<std::size_t>(i)];
        SlotBinding& binding = instance->bindings[static_cast<std::size_t>(i)];
        if (!slot.bound) {
            continue;
        }
        const soundgraph::ControlTarget& target =
            plug->description.controls[static_cast<std::size_t>(i)].target;
        binding.node_index = instance->graph.node_index(target.node);
        binding.parameter_index =
            (binding.node_index >= 0)
                ? instance->graph.parameter_index(binding.node_index, target.parameter)
                : -1;
        binding.bound = binding.node_index >= 0 && binding.parameter_index >= 0;
        binding.min_value = slot.min_value;
        binding.max_value = slot.max_value;
        binding.scaling = slot.scaling;

        if (binding.bound) {
            const double t = plug->values[static_cast<std::size_t>(i)].load(std::memory_order_relaxed);
            instance->graph.set_parameter(
                binding.node_index, binding.parameter_index,
                static_cast<float>(slot_to_engine(binding.min_value, binding.max_value,
                                                  binding.scaling, t)));
        }
    }
    return instance.release();
}

void free_graveyard(Plugin* plug) {
    GraphInstance* chain = plug->graveyard.exchange(nullptr, std::memory_order_acquire);
    while (chain != nullptr) {
        GraphInstance* next = chain->graveyard_next;
        delete chain;
        chain = next;
    }
}

// Applies whatever change is waiting — a state load or a selector move — and, while
// active, hands the audio thread a freshly built graph. Main thread.
void commit_patch(Plugin* plug) {
    SG_TRACE("commit_patch: requested=%d current=%d pending=%d active=%d",
             plug->requested_patch.load(), plug->current_patch,
             plug->pending_description ? 1 : 0, plug->active.load() ? 1 : 0);
    free_graveyard(plug);

    bool changed = false;
    if (plug->pending_description) {
        std::unique_ptr<soundgraph::GraphDescription> pending =
            std::move(plug->pending_description);
        adopt_description(plug, std::move(*pending));
        // A state-loaded patch usually exists in the discovered list under its
        // file-stem name ("Acid Bass" → "acid-bass"). When it does, the selector
        // follows, so the GUI dropdown and host parameter agree with what loaded.
        std::string stem;
        for (const char character : plug->patch_display) {
            stem += (character == ' ') ? '-' : static_cast<char>(std::tolower(
                                                   static_cast<unsigned char>(character)));
        }
        for (std::size_t i = 0; i < plug->patches.size(); ++i) {
            if (plug->patches[i].label == stem || plug->patches[i].label == plug->patch_display) {
                plug->current_patch = static_cast<int>(i);
                plug->requested_patch.store(static_cast<int>(i), std::memory_order_relaxed);
                break;
            }
        }
        changed = true;
    } else {
        const int wanted = plug->requested_patch.load(std::memory_order_relaxed);
        if (wanted != plug->current_patch) {
            const int index =
                (wanted >= 0 && wanted < static_cast<int>(plug->patches.size())) ? wanted : 0;

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
            changed = true;
        }
    }

    if (changed && plug->active.load(std::memory_order_relaxed)) {
        GraphInstance* instance = make_instance(plug);
        SG_TRACE("commit_patch: built instance %p", static_cast<void*>(instance));
        if (instance != nullptr) {
            GraphInstance* unconsumed =
                plug->incoming.exchange(instance, std::memory_order_release);
            delete unconsumed;  // main thread owns anything the audio thread never took
        }
    }
}

// ---- event handling ----------------------------------------------------------------
// Audio thread while processing (or main thread through flush while inactive). Notes
// go straight into the graph; slot events update the shared value and reach the graph
// through its control queue; a selector move is recorded and left for the main thread.

void handle_event(Plugin* plug, const clap_event_header_t* header) {
    if (header->space_id != CLAP_CORE_EVENT_SPACE_ID) {
        return;
    }
    GraphInstance* live = plug->live;
    switch (header->type) {
        case CLAP_EVENT_NOTE_ON:
        case CLAP_EVENT_NOTE_OFF:
        case CLAP_EVENT_NOTE_CHOKE: {
            if (live == nullptr) break;
            const auto* event = reinterpret_cast<const clap_event_note_t*>(header);
            soundgraph::NoteEvent note;
            note.kind = (header->type == CLAP_EVENT_NOTE_ON)
                            ? soundgraph::NoteEvent::Kind::NoteOn
                            : soundgraph::NoteEvent::Kind::NoteOff;
            note.note = event->key;
            note.velocity = static_cast<float>(event->velocity);
            live->graph.dispatch_note(note);
            break;
        }
        case CLAP_EVENT_MIDI: {
            if (live == nullptr) break;
            const auto* event = reinterpret_cast<const clap_event_midi_t*>(header);
            const std::uint8_t status = event->data[0] & 0xF0;
            soundgraph::NoteEvent note;
            note.note = event->data[1];
            note.velocity = static_cast<float>(event->data[2]) / 127.0f;
            if (status == 0x90 && event->data[2] != 0) {
                note.kind = soundgraph::NoteEvent::Kind::NoteOn;
                live->graph.dispatch_note(note);
            } else if (status == 0x80 || (status == 0x90 && event->data[2] == 0)) {
                note.kind = soundgraph::NoteEvent::Kind::NoteOff;
                live->graph.dispatch_note(note);
            } else if (status == 0xB0 && (event->data[1] == 120 || event->data[1] == 123)) {
                note.kind = soundgraph::NoteEvent::Kind::AllNotesOff;
                live->graph.dispatch_note(note);
            }
            break;
        }
        case CLAP_EVENT_PARAM_VALUE: {
            const auto* event = reinterpret_cast<const clap_event_param_value_t*>(header);
            if (event->param_id == kPatchParamId) {
                plug->requested_patch.store(static_cast<int>(event->value + 0.5),
                                            std::memory_order_relaxed);
                SG_TRACE("event: patch -> %d, requesting callback", static_cast<int>(event->value + 0.5));
                plug->host->request_callback(plug->host);
                break;
            }
            if (event->param_id < kSlotIdBase ||
                event->param_id >= kSlotIdBase + static_cast<clap_id>(kSlotCount)) {
                break;
            }
            const std::size_t index = event->param_id - kSlotIdBase;
            const float t = static_cast<float>(event->value);
            plug->values[index].store(t, std::memory_order_relaxed);
            if (live != nullptr && live->bindings[index].bound) {
                const SlotBinding& binding = live->bindings[index];
                live->graph.set_parameter(
                    binding.node_index, binding.parameter_index,
                    static_cast<float>(slot_to_engine(binding.min_value, binding.max_value,
                                                      binding.scaling, t)));
            }
            break;
        }
        default:
            break;
    }
}

// Empties the GUI's queue: each change is applied through handle_event exactly as a
// host event would be, and mirrored to the host's output queue so automation records.
// Runs on the audio thread inside process(), or on the main thread inside flush().
void drain_gui_events(Plugin* plug, const clap_output_events_t* out) {
    GuiEvent event;
    while (plug->gui_events.pop(event)) {
        if (event.kind == GuiEvent::Kind::Value) {
            clap_event_param_value_t value{};
            value.header.size = sizeof(value);
            value.header.time = 0;
            value.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
            value.header.type = CLAP_EVENT_PARAM_VALUE;
            value.param_id = event.param_id;
            value.note_id = -1;
            value.port_index = -1;
            value.channel = -1;
            value.key = -1;
            value.value = event.value;
            handle_event(plug, &value.header);
            if (out != nullptr) {
                out->try_push(out, &value.header);
            }
        } else if (out != nullptr) {
            clap_event_param_gesture_t gesture{};
            gesture.header.size = sizeof(gesture);
            gesture.header.time = 0;
            gesture.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
            gesture.header.type = (event.kind == GuiEvent::Kind::GestureBegin)
                                      ? CLAP_EVENT_PARAM_GESTURE_BEGIN
                                      : CLAP_EVENT_PARAM_GESTURE_END;
            gesture.param_id = event.param_id;
            out->try_push(out, &gesture.header);
        }
    }
}

// ---- clap_plugin_gui ---------------------------------------------------------------
// One webview showing the embedded panel. The page pulls its state through bound
// functions and pushes knob movements into the GUI queue; nothing here touches the
// audio thread directly.

#if defined(SOUNDGRAPH_HAS_GUI)

void json_escape_into(std::string& out, const std::string& text) {
    for (const char character : text) {
        switch (character) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(character) < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", character);
                    out += buffer;
                } else {
                    out += character;
                }
        }
    }
}

std::string gui_state_json(Plugin* plug) {
    std::string out = "{\"patch\":\"";
    json_escape_into(out, plug->patch_display);
    out += "\",\"version\":\"";
    json_escape_into(out, kDescriptor.version);
    out += "\",\"stateVersion\":" +
           std::to_string(plug->state_version.load(std::memory_order_relaxed));
    out += ",\"patchIndex\":" + std::to_string(plug->current_patch);
    out += ",\"patches\":[";
    for (std::size_t i = 0; i < plug->patches.size(); ++i) {
        if (i) out += ',';
        out += '"';
        json_escape_into(out, plug->patches[i].label);
        out += '"';
    }
    out += "],\"controls\":[";
    bool first = true;
    for (int i = 0; i < kSlotCount; ++i) {
        const SlotMeta& slot = plug->slots[static_cast<std::size_t>(i)];
        if (!slot.bound) continue;
        if (!first) out += ',';
        first = false;
        out += "{\"id\":" + std::to_string(kSlotIdBase + i);
        out += ",\"name\":\"";
        json_escape_into(out, slot.name);
        out += "\",\"min\":" + std::to_string(slot.min_value);
        out += ",\"max\":" + std::to_string(slot.max_value);
        out += ",\"scaling\":\"";
        out += (slot.scaling == Scaling::Exponential) ? "exp" : "linear";
        out += "\",\"default\":" + std::to_string(slot.default_normalized);
        out += ",\"value\":" +
               std::to_string(plug->values[static_cast<std::size_t>(i)].load(std::memory_order_relaxed));
        out += '}';
    }
    out += "]}";
    return out;
}

std::string gui_values_json(Plugin* plug) {
    std::string out = "{\"stateVersion\":" +
                      std::to_string(plug->state_version.load(std::memory_order_relaxed));
    out += ",\"values\":{";
    bool first = true;
    for (int i = 0; i < kSlotCount; ++i) {
        if (!plug->slots[static_cast<std::size_t>(i)].bound) continue;
        if (!first) out += ',';
        first = false;
        out += "\"" + std::to_string(kSlotIdBase + i) + "\":" +
               std::to_string(plug->values[static_cast<std::size_t>(i)].load(std::memory_order_relaxed));
    }
    out += "}}";
    return out;
}

// A GUI change enters the queue and pokes the host so the queue gets drained soon
// even when the transport is idle.
void gui_send(Plugin* plug, const GuiEvent& event) {
    plug->gui_events.push(event);
    if (plug->host_params != nullptr) {
        plug->host_params->request_flush(plug->host);
    }
}

bool gui_is_api_supported(const clap_plugin_t*, const char* api, bool is_floating) {
    if (is_floating) return false;
#if defined(__APPLE__)
    return std::strcmp(api, CLAP_WINDOW_API_COCOA) == 0;
#else
    return std::strcmp(api, CLAP_WINDOW_API_WIN32) == 0;
#endif
}

bool gui_get_preferred_api(const clap_plugin_t*, const char** api, bool* is_floating) {
#if defined(__APPLE__)
    *api = CLAP_WINDOW_API_COCOA;
#else
    *api = CLAP_WINDOW_API_WIN32;
#endif
    *is_floating = false;
    return true;
}

// Installs the bindings and the page — the moment the webview can actually take them.
//
// This is a function rather than the tail of gui_create because of a platform split
// that costs a whole GUI when it is ignored. macOS builds its WKWebView synchronously,
// so everything works if done immediately. Windows does not: choc asks WebView2 for an
// environment through CreateCoreWebView2EnvironmentWithOptions, which *completes on the
// message loop some time later*, and until it does, choc's own bind() and setHTML()
// both begin `if (! coreWebView) return false;`. Called at create time on Windows they
// are therefore not errors — they are silently discarded, leaving a real window that
// was never told to display anything. That is the black rectangle.
//
// So: idempotent, safe to call as often as anyone likes, and does nothing until the
// view says it is ready. Bindings go in before the HTML because they are installed as
// document-creation scripts, which only reach documents created after them.
bool finish_gui_setup(Plugin* plug) {
    GuiState* gui = plug->gui.get();
    if (gui == nullptr || gui->dressed) return gui != nullptr;
    if (gui->webview == nullptr || !gui->webview->isReady()) return false;

    choc::ui::WebView& view = *gui->webview;
    view.bind("sg_getState", [plug](const choc::value::ValueView&) {
        return choc::json::parse(gui_state_json(plug));
    });
    view.bind("sg_getValues", [plug](const choc::value::ValueView&) {
        return choc::json::parse(gui_values_json(plug));
    });
    view.bind("sg_setParam", [plug](const choc::value::ValueView& args) {
        gui_send(plug, {GuiEvent::Kind::Value, static_cast<clap_id>(args[0].getWithDefault<int64_t>(0)),
                        args[1].getWithDefault<double>(0.0)});
        return choc::value::Value();
    });
    view.bind("sg_begin", [plug](const choc::value::ValueView& args) {
        gui_send(plug, {GuiEvent::Kind::GestureBegin,
                        static_cast<clap_id>(args[0].getWithDefault<int64_t>(0)), 0.0});
        return choc::value::Value();
    });
    view.bind("sg_end", [plug](const choc::value::ValueView& args) {
        gui_send(plug, {GuiEvent::Kind::GestureEnd,
                        static_cast<clap_id>(args[0].getWithDefault<int64_t>(0)), 0.0});
        return choc::value::Value();
    });
    view.bind("sg_selectPatch", [plug](const choc::value::ValueView& args) {
        gui_send(plug, {GuiEvent::Kind::Value, kPatchParamId,
                        args[0].getWithDefault<double>(0.0)});
        return choc::value::Value();
    });
    view.setHTML(reinterpret_cast<const char*>(soundgraph_clap::kPanelHtml));
    gui->dressed = true;
    return true;
}

bool gui_create(const clap_plugin_t* plugin, const char* api, bool is_floating) {
    if (!gui_is_api_supported(plugin, api, is_floating)) {
        return false;
    }
    Plugin* plug = self(plugin);
    auto gui = std::make_unique<GuiState>();
    gui->webview = std::make_unique<choc::ui::WebView>(choc::ui::WebView::Options{});
    if (gui->webview == nullptr || gui->webview->getViewHandle() == nullptr) {
        return false;
    }
    plug->gui = std::move(gui);

    // Synchronous platforms are dressed here and now, and never look at the timer.
    if (finish_gui_setup(plug)) {
        return true;
    }

    // Asynchronous ones need to be asked again later. A host timer is the polite way
    // to get a main thread back, and every host that can show a GUI has one — but the
    // extension is optional, so the pump in gui_set_parent covers hosts without it.
    if (const auto* timers = static_cast<const clap_host_timer_support_t*>(
            plug->host->get_extension(plug->host, CLAP_EXT_TIMER_SUPPORT))) {
        timers->register_timer(plug->host, kGuiTimerMs, &plug->gui->timer);
    }
    return true;
}

void gui_destroy(const clap_plugin_t* plugin) {
    Plugin* plug = self(plugin);
    if (plug->gui != nullptr && plug->gui->timer != CLAP_INVALID_ID) {
        if (const auto* timers = static_cast<const clap_host_timer_support_t*>(
                plug->host->get_extension(plug->host, CLAP_EXT_TIMER_SUPPORT))) {
            timers->unregister_timer(plug->host, plug->gui->timer);
        }
    }
    plug->gui.reset();
}

void plugin_on_timer(const clap_plugin_t* plugin, clap_id timer) {
    Plugin* plug = self(plugin);
    if (plug->gui == nullptr || timer != plug->gui->timer) return;
    if (!finish_gui_setup(plug)) return;
    // Dressed at last; the timer has done the only job it was registered for.
    if (const auto* timers = static_cast<const clap_host_timer_support_t*>(
            plug->host->get_extension(plug->host, CLAP_EXT_TIMER_SUPPORT))) {
        timers->unregister_timer(plug->host, plug->gui->timer);
    }
    plug->gui->timer = CLAP_INVALID_ID;
}

const clap_plugin_timer_support_t kTimerSupport = {plugin_on_timer};

bool gui_set_scale(const clap_plugin_t* plugin, double scale) {
    Plugin* plug = self(plugin);
    if (plug->gui != nullptr) {
        plug->gui->scale = scale;
    }
    return true;
}

bool gui_get_size(const clap_plugin_t*, uint32_t* width, uint32_t* height) {
    *width = kGuiWidth;
    *height = kGuiHeight;
    return true;
}

bool gui_can_resize(const clap_plugin_t*) {
    return false;
}

bool gui_get_resize_hints(const clap_plugin_t*, clap_gui_resize_hints_t*) {
    return false;
}

bool gui_adjust_size(const clap_plugin_t* plugin, uint32_t* width, uint32_t* height) {
    return gui_get_size(plugin, width, height);
}

bool gui_set_size(const clap_plugin_t*, uint32_t width, uint32_t height) {
    return width == kGuiWidth && height == kGuiHeight;
}

bool gui_set_parent(const clap_plugin_t* plugin, const clap_window_t* window) {
    Plugin* plug = self(plugin);
    if (plug->gui == nullptr || plug->gui->webview == nullptr) {
        return false;
    }
#if defined(__APPLE__)
    struct Rect { double x = 0, y = 0, width = 0, height = 0; };
    id child = static_cast<id>(plug->gui->webview->getViewHandle());
    id parent = static_cast<id>(window->cocoa);
    choc::objc::call<void>(child, "setFrame:",
                           Rect{0, 0, static_cast<double>(kGuiWidth),
                                static_cast<double>(kGuiHeight)});
    // NSViewWidthSizable | NSViewHeightSizable
    choc::objc::call<void>(child, "setAutoresizingMask:", static_cast<unsigned long>(2 | 16));
    choc::objc::call<void>(parent, "addSubview:", child);
    return true;
#elif defined(_WIN32)
    HWND child = static_cast<HWND>(plug->gui->webview->getViewHandle());
    // choc makes its window WS_POPUP, which is right for a window that stands alone
    // and wrong for one living inside a host's: a popup reparented as-is keeps
    // top-level behaviour and does not clip or paint reliably against its new parent.
    // The style has to change with the parentage.
    ::SetWindowLongPtrW(child, GWL_STYLE, WS_CHILD | WS_VISIBLE);
    ::SetParent(child, static_cast<HWND>(window->win32));
    ::SetWindowPos(child, nullptr, 0, 0, static_cast<int>(kGuiWidth),
                   static_cast<int>(kGuiHeight), SWP_NOZORDER | SWP_SHOWWINDOW);

    // Last resort for a host that offers no timer extension: give WebView2's
    // asynchronous startup the message loop it is waiting for, briefly, here on the
    // main thread where set_parent is already required to be called. Bounded, and
    // skipped entirely the moment the view is dressed — which for a host with timers
    // it already will be.
    if (!plug->gui->dressed && plug->gui->timer == CLAP_INVALID_ID) {
        const DWORD deadline = ::GetTickCount() + kGuiPumpMs;
        while (!finish_gui_setup(plug) && ::GetTickCount() < deadline) {
            MSG message;
            while (::PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
                ::TranslateMessage(&message);
                ::DispatchMessageW(&message);
            }
            ::Sleep(4);
        }
    }
    return true;
#else
    (void)window;
    return false;
#endif
}

bool gui_set_transient(const clap_plugin_t*, const clap_window_t*) {
    return false;
}

void gui_suggest_title(const clap_plugin_t*, const char*) {}

bool gui_show(const clap_plugin_t*) {
    return true;
}

bool gui_hide(const clap_plugin_t*) {
    return true;
}

const clap_plugin_gui_t kGui = {
    gui_is_api_supported, gui_get_preferred_api, gui_create,     gui_destroy,
    gui_set_scale,        gui_get_size,          gui_can_resize, gui_get_resize_hints,
    gui_adjust_size,      gui_set_size,          gui_set_parent, gui_set_transient,
    gui_suggest_title,    gui_show,              gui_hide};

#endif  // SOUNDGRAPH_HAS_GUI

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
    return (has_patch_param(self(plugin)) ? 1 : 0) + kSlotCount;
}

bool params_get_info(const clap_plugin_t* plugin, uint32_t index, clap_param_info_t* info) {
    Plugin* plug = self(plugin);
    if (has_patch_param(plug) && index == 0) {
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
    const std::size_t slot_index = has_patch_param(plug) ? index - 1 : index;
    if (slot_index >= kSlotCount) {
        return false;
    }
    const SlotMeta& slot = plug->slots[slot_index];
    info->id = kSlotIdBase + static_cast<clap_id>(slot_index);
    info->flags = CLAP_PARAM_IS_AUTOMATABLE | (slot.bound ? 0 : CLAP_PARAM_IS_HIDDEN);
    info->cookie = nullptr;
    std::snprintf(info->name, sizeof(info->name), "%s", slot.name.c_str());
    std::snprintf(info->module, sizeof(info->module), "%s",
                  slot.bound ? plug->patch_display.c_str() : "");
    info->min_value = 0.0;
    info->max_value = 1.0;
    info->default_value = slot.default_normalized;
    return true;
}

bool params_get_value(const clap_plugin_t* plugin, clap_id param_id, double* out_value) {
    Plugin* plug = self(plugin);
    if (param_id == kPatchParamId) {
        *out_value = static_cast<double>(plug->requested_patch.load(std::memory_order_relaxed));
        return true;
    }
    if (param_id < kSlotIdBase || param_id >= kSlotIdBase + static_cast<clap_id>(kSlotCount)) {
        return false;
    }
    *out_value = static_cast<double>(
        plug->values[param_id - kSlotIdBase].load(std::memory_order_relaxed));
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
    if (param_id < kSlotIdBase || param_id >= kSlotIdBase + static_cast<clap_id>(kSlotCount)) {
        return false;
    }
    const SlotMeta& slot = plug->slots[param_id - kSlotIdBase];
    if (!slot.bound) {
        std::snprintf(out, out_size, "%s", "-");
        return true;
    }
    std::snprintf(out, out_size, "%.4g",
                  slot_to_engine(slot.min_value, slot.max_value, slot.scaling, value));
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
    if (param_id < kSlotIdBase || param_id >= kSlotIdBase + static_cast<clap_id>(kSlotCount)) {
        return false;
    }
    const SlotMeta& slot = plug->slots[param_id - kSlotIdBase];
    *out_value = engine_to_slot(slot.min_value, slot.max_value, slot.scaling, std::atof(text));
    return true;
}

void params_flush(const clap_plugin_t* plugin, const clap_input_events_t* in,
                  const clap_output_events_t* out) {
    Plugin* plug = self(plugin);
    const uint32_t count = in->size(in);
    if (count > 0) SG_TRACE("flush: %u events, active=%d", count, plug->active.load() ? 1 : 0);
    for (uint32_t i = 0; i < count; ++i) {
        handle_event(plug, in->get(in, i));
    }
    drain_gui_events(plug, out);
    // While inactive, flush arrives on the main thread — apply selector moves here and
    // now rather than waiting for a callback the host has no reason to hurry.
    if (!plug->active.load(std::memory_order_relaxed)) {
        commit_patch(plug);
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
                      const soundgraph::ControlTarget& target, double value) {
    for (soundgraph::NodeDescription& node : nodes) {
        if (node.id != target.node) {
            continue;
        }
        for (soundgraph::ParameterValue& parameter : node.parameters) {
            if (parameter.name == target.parameter) {
                parameter.value = value;
                return;
            }
        }
        soundgraph::ParameterValue parameter;
        parameter.name = target.parameter;
        parameter.value = value;
        node.parameters.push_back(std::move(parameter));
        return;
    }
}

bool state_save(const clap_plugin_t* plugin, const clap_ostream_t* stream) {
    Plugin* plug = self(plugin);

    soundgraph::GraphDescription snapshot = plug->description;
    for (std::size_t i = 0; i < snapshot.controls.size() && i < kSlotCount; ++i) {
        const SlotMeta& slot = plug->slots[i];
        if (!slot.bound) {
            continue;
        }
        const double value =
            slot_to_engine(slot.min_value, slot.max_value, slot.scaling,
                           plug->values[i].load(std::memory_order_relaxed));
        write_value_into(snapshot.nodes, snapshot.controls[i].target, value);
        if (snapshot.authored_taken && i < snapshot.authored_controls.size()) {
            write_value_into(snapshot.authored_nodes, snapshot.authored_controls[i].target, value);
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

    // state_load is a main-thread call; the swap can happen right here.
    plug->pending_description = std::move(description);
    commit_patch(plug);
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
    adopt_description(plug, std::move(description));
    plug->initialized = true;
    return true;
}

void plugin_destroy(const clap_plugin_t* plugin) {
    Plugin* plug = self(plugin);
    free_graveyard(plug);
    delete plug->incoming.exchange(nullptr);
    delete plug->live;
    delete plug;
}

bool plugin_activate(const clap_plugin_t* plugin, double sample_rate, uint32_t, uint32_t) {
    Plugin* plug = self(plugin);
    SG_TRACE("activate at %.0f", sample_rate);
    plug->sample_rate = sample_rate;
    commit_patch(plug);  // anything still waiting applies before the graph is built

    delete plug->live;
    plug->live = nullptr;
    GraphInstance* instance = make_instance(plug);
    if (instance == nullptr) {
        return false;
    }
    plug->live = instance;
    plug->active.store(true, std::memory_order_relaxed);
    return true;
}

void plugin_deactivate(const clap_plugin_t* plugin) {
    Plugin* plug = self(plugin);
    plug->active.store(false, std::memory_order_relaxed);
    free_graveyard(plug);
    delete plug->incoming.exchange(nullptr);
    delete plug->live;
    plug->live = nullptr;
}

bool plugin_start_processing(const clap_plugin_t*) {
    return true;
}

void plugin_stop_processing(const clap_plugin_t*) {}

void plugin_reset(const clap_plugin_t* plugin) {
    Plugin* plug = self(plugin);
    if (plug->live != nullptr) {
        plug->live->graph.reset();
    }
}

clap_process_status plugin_process(const clap_plugin_t* plugin, const clap_process_t* process) {
    Plugin* plug = self(plugin);

    drain_gui_events(plug, process->out_events);

    // Adopt a freshly built graph if the main thread left one, and hand back the old
    // one for the main thread to free. One exchange each way; nothing blocks.
    GraphInstance* incoming = plug->incoming.exchange(nullptr, std::memory_order_acquire);
    if (incoming != nullptr) {
        SG_TRACE("process: swapped in %p", static_cast<void*>(incoming));
        GraphInstance* old = plug->live;
        plug->live = incoming;
        if (old != nullptr) {
            old->graveyard_next = plug->graveyard.load(std::memory_order_relaxed);
            plug->graveyard.store(old, std::memory_order_release);
        }
    }

    float* left = process->audio_outputs[0].data32[0];
    float* right = process->audio_outputs[0].data32[1];
    const uint32_t total_frames = process->frames_count;

    const clap_input_events_t* events = process->in_events;
    const uint32_t event_count = events->size(events);

    if (plug->live == nullptr) {
        std::memset(left, 0, total_frames * sizeof(float));
        std::memset(right, 0, total_frames * sizeof(float));
        for (uint32_t i = 0; i < event_count; ++i) {
            handle_event(plug, events->get(events, i));
        }
        return CLAP_PROCESS_CONTINUE;
    }

    // Events land at their declared frame: render up to each event's time, apply it,
    // continue. The graph's own fixed internal blocks keep the output identical to what
    // any other host — or any other buffer segmentation — would produce.
    uint32_t cursor = 0;
    for (uint32_t i = 0; i < event_count; ++i) {
        const clap_event_header_t* header = events->get(events, i);
        if (header->time > cursor) {
            const uint32_t frames = header->time - cursor;
            plug->live->graph.render(left + cursor, right + cursor, static_cast<int>(frames));
            cursor += frames;
        }
        handle_event(plug, header);
    }
    if (cursor < total_frames) {
        plug->live->graph.render(left + cursor, right + cursor,
                                 static_cast<int>(total_frames - cursor));
    }

    return CLAP_PROCESS_CONTINUE;
}

const void* plugin_get_extension(const clap_plugin_t*, const char* id) {
    if (std::strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0) return &kAudioPorts;
    if (std::strcmp(id, CLAP_EXT_NOTE_PORTS) == 0) return &kNotePorts;
    if (std::strcmp(id, CLAP_EXT_PARAMS) == 0) return &kParams;
    if (std::strcmp(id, CLAP_EXT_STATE) == 0) return &kState;
#if defined(SOUNDGRAPH_HAS_GUI)
    if (std::strcmp(id, CLAP_EXT_GUI) == 0) return &kGui;
    if (std::strcmp(id, CLAP_EXT_TIMER_SUPPORT) == 0) return &kTimerSupport;
#endif
    return nullptr;
}

void plugin_on_main_thread(const clap_plugin_t* plugin) {
    SG_TRACE("on_main_thread");
    commit_patch(self(plugin));
}

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
