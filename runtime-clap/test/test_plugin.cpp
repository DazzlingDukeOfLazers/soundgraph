// The player plugin, driven exactly as a host would drive it — no wrapper, no DAW.
// Creates the plugin from its own factory, plays the built-in patch, switches to
// acid-bass through the selector parameter (restart cycle included), and round-trips
// state. This is the reference for what any wrapper (VST3, AU) must be able to elicit;
// when a DAW misbehaves, this test says whose bug it is.
#include <clap/clap.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "../src/soundgraph_clap_entry.h"

namespace {

int failures = 0;

#define CHECK(condition, label)                                    \
    do {                                                           \
        if (!(condition)) {                                        \
            std::printf("FAIL: %s\n", label);                      \
            ++failures;                                            \
        } else {                                                   \
            std::printf("  ok: %s\n", label);                      \
        }                                                          \
    } while (false)

// ---- a host the size of a test -----------------------------------------------------

struct TestHost {
    clap_host_t host{};
    bool restart_requested = false;
    bool callback_requested = false;
    clap_param_rescan_flags last_rescan = 0;
    int rescan_count = 0;
};

const clap_host_params_t kHostParams = {
    /*rescan*/ [](const clap_host_t* host, clap_param_rescan_flags flags) {
        auto* self = static_cast<TestHost*>(host->host_data);
        self->last_rescan = flags;
        ++self->rescan_count;
    },
    /*clear*/ [](const clap_host_t*, clap_id, clap_param_clear_flags) {},
    /*request_flush*/ [](const clap_host_t*) {},
};

TestHost make_host() {
    TestHost host;
    host.host.clap_version = CLAP_VERSION;
    host.host.host_data = &host;
    host.host.name = "soundgraph-test-host";
    host.host.vendor = "soundgraph";
    host.host.url = "";
    host.host.version = "1";
    host.host.get_extension = [](const clap_host_t*, const char* id) -> const void* {
        if (std::strcmp(id, CLAP_EXT_PARAMS) == 0) return &kHostParams;
        return nullptr;
    };
    host.host.request_restart = [](const clap_host_t* host) {
        static_cast<TestHost*>(host->host_data)->restart_requested = true;
    };
    host.host.request_process = [](const clap_host_t*) {};
    host.host.request_callback = [](const clap_host_t* host) {
        static_cast<TestHost*>(host->host_data)->callback_requested = true;
    };
    return host;
}

// ---- event list plumbing -----------------------------------------------------------

struct EventList {
    std::vector<std::vector<char>> storage;
    std::vector<const clap_event_header_t*> events;
    clap_input_events_t in{};

    EventList() {
        in.ctx = this;
        in.size = [](const clap_input_events_t* list) -> uint32_t {
            return static_cast<uint32_t>(static_cast<EventList*>(list->ctx)->events.size());
        };
        in.get = [](const clap_input_events_t* list, uint32_t index) {
            return static_cast<EventList*>(list->ctx)->events[index];
        };
    }

    template <typename Event>
    void push(const Event& event) {
        storage.emplace_back(reinterpret_cast<const char*>(&event),
                             reinterpret_cast<const char*>(&event) + sizeof(Event));
        events.clear();
        for (const auto& bytes : storage) {
            events.push_back(reinterpret_cast<const clap_event_header_t*>(bytes.data()));
        }
    }

    void clear() {
        storage.clear();
        events.clear();
    }
};

clap_event_note_t note_event(uint16_t type, int16_t key) {
    clap_event_note_t event{};
    event.header.size = sizeof(event);
    event.header.time = 0;
    event.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
    event.header.type = type;
    event.header.flags = 0;
    event.note_id = -1;
    event.port_index = 0;
    event.channel = 0;
    event.key = key;
    event.velocity = 0.9;
    return event;
}

clap_event_param_value_t param_event(clap_id id, double value) {
    clap_event_param_value_t event{};
    event.header.size = sizeof(event);
    event.header.time = 0;
    event.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
    event.header.type = CLAP_EVENT_PARAM_VALUE;
    event.param_id = id;
    event.note_id = -1;
    event.port_index = -1;
    event.channel = -1;
    event.key = -1;
    event.value = value;
    return event;
}

// Renders one second in four blocks and returns the overall RMS.
double render_seconds(const clap_plugin_t* plugin, EventList& events, int blocks) {
    constexpr int kFrames = 512;
    std::vector<float> left(kFrames), right(kFrames);
    float* channels[2] = {left.data(), right.data()};

    clap_audio_buffer_t out{};
    out.data32 = channels;
    out.channel_count = 2;

    clap_output_events_t out_events{};
    out_events.ctx = nullptr;
    out_events.try_push = [](const clap_output_events_t*, const clap_event_header_t*) {
        return false;
    };

    double total = 0.0;
    long count = 0;
    for (int block = 0; block < blocks; ++block) {
        clap_process_t process{};
        process.steady_time = block * kFrames;
        process.frames_count = kFrames;
        process.audio_outputs = &out;
        process.audio_outputs_count = 1;
        process.in_events = &events.in;
        process.out_events = &out_events;
        plugin->process(plugin, &process);
        events.clear();
        for (int i = 0; i < kFrames; ++i) {
            total += left[i] * left[i] + right[i] * right[i];
            count += 2;
        }
    }
    return std::sqrt(total / count);
}

// ---- memory streams for state ------------------------------------------------------

struct MemoryStream {
    std::string data;
    std::size_t cursor = 0;
};

}  // namespace

int main() {
    setenv("SOUNDGRAPH_PATCHES", SOUNDGRAPH_TEST_PATCHES, 1);

    CHECK(soundgraph_clap_init(""), "entry init");
    const auto* factory = static_cast<const clap_plugin_factory_t*>(
        soundgraph_clap_get_factory(CLAP_PLUGIN_FACTORY_ID));
    CHECK(factory != nullptr, "plugin factory exists");
    CHECK(factory->get_plugin_count(factory) == 1, "one plugin");
    const clap_plugin_descriptor_t* descriptor = factory->get_plugin_descriptor(factory, 0);

    TestHost host = make_host();
    const clap_plugin_t* plugin = factory->create_plugin(factory, &host.host, descriptor->id);
    CHECK(plugin != nullptr, "plugin created");
    CHECK(plugin->init(plugin), "plugin init");

    const auto* params = static_cast<const clap_plugin_params_t*>(
        plugin->get_extension(plugin, CLAP_EXT_PARAMS));
    const auto* state = static_cast<const clap_plugin_state_t*>(
        plugin->get_extension(plugin, CLAP_EXT_STATE));
    CHECK(params != nullptr, "params extension");
    CHECK(state != nullptr, "state extension");

    // The surface is fixed: a selector plus 32 slots, whatever the patch declares.
    const uint32_t initial_count = params->count(plugin);
    CHECK(initial_count == 33, "surface is selector + 32 fixed slots");

    clap_param_info_t slot_info{};
    CHECK(params->get_info(plugin, 3, &slot_info) && std::strcmp(slot_info.name, "Sweep Rate") == 0,
          "slot 2 is first-synth's Sweep Rate");
    CHECK(params->get_info(plugin, 8, &slot_info) && (slot_info.flags & CLAP_PARAM_IS_HIDDEN) != 0,
          "slot 7 is hidden while first-synth is loaded");

    // find acid-bass on the selector by name, as a generic UI would
    clap_param_info_t selector{};
    CHECK(params->get_info(plugin, 0, &selector), "selector info");
    CHECK(selector.max_value >= 1.0, "selector has discovered patches");
    double acid_index = -1.0;
    for (double value = 0; value <= selector.max_value; value += 1.0) {
        char text[256];
        if (params->value_to_text(plugin, selector.id, value, text, sizeof(text)) &&
            std::strcmp(text, "acid-bass") == 0) {
            acid_index = value;
        }
    }
    CHECK(acid_index >= 0.0, "acid-bass discovered by the selector");

    CHECK(plugin->activate(plugin, 48000.0, 32, 4096), "activate");
    CHECK(plugin->start_processing(plugin), "start processing");

    EventList events;
    events.push(note_event(CLAP_EVENT_NOTE_ON, 60));
    const double builtin_rms = render_seconds(plugin, events, 32);
    std::printf("  built-in rms: %f\n", builtin_rms);
    CHECK(builtin_rms > 0.01, "built-in patch makes sound");

    // Switch patches the way a host automation lane would: the event asks for a main
    // thread callback, the callback builds the new graph, and the next process() call
    // adopts it. No deactivation, no host cooperation beyond on_main_thread.
    events.push(param_event(selector.id, acid_index));
    render_seconds(plugin, events, 1);
    CHECK(host.callback_requested, "patch change requests a main-thread callback");

    host.rescan_count = 0;
    plugin->on_main_thread(plugin);
    CHECK(host.rescan_count > 0 && (host.last_rescan & CLAP_PARAM_RESCAN_INFO) != 0,
          "patch swap rescans param info");
    CHECK(params->count(plugin) == 33, "surface stays selector + 32 slots");
    CHECK(params->get_info(plugin, 3, &slot_info) && std::strcmp(slot_info.name, "Env Mod") == 0,
          "slot 2 renamed to acid-bass's Env Mod");
    CHECK(params->get_info(plugin, 8, &slot_info) && (slot_info.flags & CLAP_PARAM_IS_HIDDEN) == 0,
          "slot 7 visible now that acid-bass binds it");

    char patch_text[256];
    double selector_value = 0.0;
    CHECK(params->get_value(plugin, selector.id, &selector_value), "selector readback");
    CHECK(params->value_to_text(plugin, selector.id, selector_value, patch_text,
                                sizeof(patch_text)) &&
              std::strcmp(patch_text, "acid-bass") == 0,
          "selector shows acid-bass");

    // still active, still processing — the swap happens inside process()
    events.push(note_event(CLAP_EVENT_NOTE_ON, 36));
    const double acid_rms = render_seconds(plugin, events, 32);
    std::printf("  acid-bass rms: %f\n", acid_rms);
    CHECK(acid_rms > 0.01, "acid-bass makes sound without a restart");

    // state is the patch: saving now must yield the acid-bass document
    MemoryStream saved;
    clap_ostream_t out_stream{};
    out_stream.ctx = &saved;
    out_stream.write = [](const clap_ostream_t* stream, const void* buffer,
                          uint64_t size) -> int64_t {
        static_cast<MemoryStream*>(stream->ctx)
            ->data.append(static_cast<const char*>(buffer), static_cast<std::size_t>(size));
        return static_cast<int64_t>(size);
    };
    CHECK(state->save(plugin, &out_stream), "state save");
    CHECK(saved.data.find("Acid Bass") != std::string::npos, "saved state is the acid-bass patch");

    // and loading a saved state applies immediately, active or not
    MemoryStream reload;
    reload.data = saved.data;
    clap_istream_t in_stream{};
    in_stream.ctx = &reload;
    in_stream.read = [](const clap_istream_t* stream, void* buffer, uint64_t size) -> int64_t {
        auto* memory = static_cast<MemoryStream*>(stream->ctx);
        const std::size_t remaining = memory->data.size() - memory->cursor;
        const std::size_t take =
            remaining < static_cast<std::size_t>(size) ? remaining : static_cast<std::size_t>(size);
        std::memcpy(buffer, memory->data.data() + memory->cursor, take);
        memory->cursor += take;
        return static_cast<int64_t>(take);
    };
    CHECK(state->load(plugin, &in_stream), "state load");
    CHECK(params->get_info(plugin, 3, &slot_info) && std::strcmp(slot_info.name, "Env Mod") == 0,
          "loaded state keeps acid-bass's slot names");

    plugin->stop_processing(plugin);
    plugin->deactivate(plugin);
    plugin->destroy(plugin);
    soundgraph_clap_deinit();

    if (failures == 0) {
        std::printf("all clap plugin checks passed\n");
        return 0;
    }
    std::printf("%d check(s) failed\n", failures);
    return 1;
}
