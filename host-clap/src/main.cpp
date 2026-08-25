// sg-host — a headless CLAP host the size of a command line tool.
//
// Loads a .clap from disk the way a DAW would — LoadLibrary/dlopen, resolve
// `clap_entry`, walk the factory — then activates a plugin, plays notes at it, and
// measures what comes back. It exists so the plugins this repository builds can be
// tested by a host whose source we control: when a DAW misbehaves, test_plugin says
// whose bug it is *in-process*; sg-host says the same thing across the dynamic-loading
// boundary, against the shipped artifact.
//
// It is deliberately not a player. No audio device, no timers, no GUI: stdin is nobody,
// stdout is the report, the exit code is the verdict. That is what lets it sit inside
// ctest and the pre-push gate.
#include <clap/clap.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "wav.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {

// ---- loading the library -----------------------------------------------------------

// A .clap is a shared library with one exported symbol. On macOS it is a bundle
// directory and the binary lives inside; this host accepts either the bundle or the
// binary path, resolving the former to the latter.
struct PluginLibrary {
#if defined(_WIN32)
    HMODULE handle = nullptr;
#else
    void* handle = nullptr;
#endif
    const clap_plugin_entry_t* entry = nullptr;
    std::string path;

    bool open(const std::string& requested, std::string& error) {
        path = requested;
#if defined(__APPLE__)
        // SoundGraph.clap/Contents/MacOS/SoundGraph — the standard bundle layout.
        // Try the path as given first so a direct binary path also works.
#endif
#if defined(_WIN32)
        handle = LoadLibraryA(path.c_str());
        if (!handle) {
            error = "could not load " + path + " (LoadLibrary error " +
                    std::to_string(GetLastError()) + ")";
            return false;
        }
        entry = reinterpret_cast<const clap_plugin_entry_t*>(
            reinterpret_cast<void*>(GetProcAddress(handle, "clap_entry")));
#else
        handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
#if defined(__APPLE__)
        if (!handle) {
            // Resolve a bundle directory to its inner binary: <name>.clap/Contents/
            // MacOS/<name without extension>.
            const auto slash = path.find_last_of('/');
            std::string stem = slash == std::string::npos ? path : path.substr(slash + 1);
            const auto dot = stem.rfind(".clap");
            if (dot != std::string::npos) stem = stem.substr(0, dot);
            const std::string inner = path + "/Contents/MacOS/" + stem;
            handle = dlopen(inner.c_str(), RTLD_NOW | RTLD_LOCAL);
        }
#endif
        if (!handle) {
            error = "could not load " + path + " (" + dlerror() + ")";
            return false;
        }
        entry = reinterpret_cast<const clap_plugin_entry_t*>(dlsym(handle, "clap_entry"));
#endif
        if (!entry) {
            error = path + " exports no clap_entry — not a CLAP plugin";
            return false;
        }
        return true;
    }

    ~PluginLibrary() {
        // The entry is deinited by main before the library goes away; unloading is
        // last so no plugin code outlives its own image.
#if defined(_WIN32)
        if (handle) FreeLibrary(handle);
#else
        if (handle) dlclose(handle);
#endif
    }
};

// ---- the host object ---------------------------------------------------------------

// Enough host for a plugin to live in: params rescan lands in a counter, log lands on
// stdout, request_callback raises a flag that the render loop answers between blocks —
// which is exactly the main-thread promise a real host makes.
struct Host {
    clap_host_t host{};
    bool callback_requested = false;
    bool restart_requested = false;
    int rescan_count = 0;
};

const clap_host_params_t kHostParams = {
    /*rescan*/ [](const clap_host_t* host, clap_param_rescan_flags) {
        ++static_cast<Host*>(host->host_data)->rescan_count;
    },
    /*clear*/ [](const clap_host_t*, clap_id, clap_param_clear_flags) {},
    /*request_flush*/ [](const clap_host_t*) {},
};

const clap_host_log_t kHostLog = {
    /*log*/ [](const clap_host_t*, clap_log_severity severity, const char* message) {
        std::printf("  [plugin log %d] %s\n", severity, message);
    },
};

void init_host(Host& host) {
    host.host.clap_version = CLAP_VERSION;
    host.host.host_data = &host;
    host.host.name = "sg-host";
    host.host.vendor = "soundgraph";
    host.host.url = "";
    host.host.version = "1";
    host.host.get_extension = [](const clap_host_t*, const char* id) -> const void* {
        if (std::strcmp(id, CLAP_EXT_PARAMS) == 0) return &kHostParams;
        if (std::strcmp(id, CLAP_EXT_LOG) == 0) return &kHostLog;
        return nullptr;
    };
    host.host.request_restart = [](const clap_host_t* host) {
        static_cast<Host*>(host->host_data)->restart_requested = true;
    };
    host.host.request_process = [](const clap_host_t*) {};
    host.host.request_callback = [](const clap_host_t* host) {
        static_cast<Host*>(host->host_data)->callback_requested = true;
    };
}

// ---- event plumbing ----------------------------------------------------------------

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

// ---- the command line --------------------------------------------------------------

struct Options {
    std::string plugin_path;
    std::string wav_path;
    bool list = false;
    int index = 0;
    double seconds = 2.0;
    double sample_rate = 48000.0;
    int block = 512;
    double rms_min = -1.0;  // negative: report only, no verdict
    std::vector<int> notes{60};
    std::vector<std::pair<std::string, double>> params;  // by display name
};

void usage() {
    std::printf(
        "sg-host <plugin.clap> [options]\n"
        "  --list                 print the plugins and parameters, then exit\n"
        "  --index N              which plugin in the factory (default 0)\n"
        "  --seconds S            how long to render (default 2)\n"
        "  --rate HZ              sample rate (default 48000)\n"
        "  --block FRAMES         block size (default 512)\n"
        "  --note K[,K...]        MIDI keys to hold (default 60)\n"
        "  --param NAME=VALUE     set a parameter by display name, repeatable\n"
        "  --wav PATH             write the rendered audio as 32-bit float WAV\n"
        "  --rms-min X            fail (exit 1) if the render's RMS is below X\n"
        "  --env NAME=VALUE       set an environment variable first, repeatable\n");
}

bool parse(int argc, char** argv, Options& options, std::string& error) {
    if (argc < 2) {
        error = "no plugin path given";
        return false;
    }
    options.plugin_path = argv[1];
    for (int i = 2; i < argc; ++i) {
        const std::string arg = argv[i];
        auto value = [&](const char* name) -> const char* {
            if (i + 1 >= argc) {
                error = std::string(name) + " needs a value";
                return nullptr;
            }
            return argv[++i];
        };
        if (arg == "--list") {
            options.list = true;
        } else if (arg == "--index") {
            const char* v = value("--index");
            if (!v) return false;
            options.index = std::atoi(v);
        } else if (arg == "--seconds") {
            const char* v = value("--seconds");
            if (!v) return false;
            options.seconds = std::atof(v);
        } else if (arg == "--rate") {
            const char* v = value("--rate");
            if (!v) return false;
            options.sample_rate = std::atof(v);
        } else if (arg == "--block") {
            const char* v = value("--block");
            if (!v) return false;
            options.block = std::atoi(v);
        } else if (arg == "--rms-min") {
            const char* v = value("--rms-min");
            if (!v) return false;
            options.rms_min = std::atof(v);
        } else if (arg == "--wav") {
            const char* v = value("--wav");
            if (!v) return false;
            options.wav_path = v;
        } else if (arg == "--note") {
            const char* v = value("--note");
            if (!v) return false;
            options.notes.clear();
            std::string list = v;
            std::size_t start = 0;
            while (start <= list.size()) {
                const auto comma = list.find(',', start);
                const std::string one = list.substr(
                    start, comma == std::string::npos ? std::string::npos : comma - start);
                if (!one.empty()) options.notes.push_back(std::atoi(one.c_str()));
                if (comma == std::string::npos) break;
                start = comma + 1;
            }
        } else if (arg == "--param" || arg == "--env") {
            const char* v = value(arg.c_str());
            if (!v) return false;
            const std::string pair = v;
            const auto equals = pair.find('=');
            if (equals == std::string::npos) {
                error = arg + " expects NAME=VALUE, got " + pair;
                return false;
            }
            if (arg == "--param") {
                options.params.emplace_back(pair.substr(0, equals),
                                            std::atof(pair.c_str() + equals + 1));
            } else {
#if defined(_WIN32)
                _putenv_s(pair.substr(0, equals).c_str(), pair.c_str() + equals + 1);
#else
                setenv(pair.substr(0, equals).c_str(), pair.c_str() + equals + 1, 1);
#endif
            }
        } else {
            error = "unknown option " + arg;
            return false;
        }
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Options options;
    std::string error;
    if (!parse(argc, argv, options, error)) {
        std::printf("sg-host: %s\n\n", error.c_str());
        usage();
        return 2;
    }

    PluginLibrary library;
    if (!library.open(options.plugin_path, error)) {
        std::printf("sg-host: %s\n", error.c_str());
        return 1;
    }
    if (!library.entry->init(options.plugin_path.c_str())) {
        std::printf("sg-host: %s refused entry init\n", options.plugin_path.c_str());
        return 1;
    }

    const auto* factory = static_cast<const clap_plugin_factory_t*>(
        library.entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
    if (!factory) {
        std::printf("sg-host: no plugin factory\n");
        library.entry->deinit();
        return 1;
    }

    const uint32_t count = factory->get_plugin_count(factory);
    std::printf("%s: %u plugin(s)\n", options.plugin_path.c_str(), count);
    for (uint32_t i = 0; i < count; ++i) {
        const auto* descriptor = factory->get_plugin_descriptor(factory, i);
        std::printf("  [%u] %s — %s (%s)\n", i, descriptor->id, descriptor->name,
                    descriptor->vendor ? descriptor->vendor : "");
    }
    if (count == 0 || options.index < 0 || static_cast<uint32_t>(options.index) >= count) {
        std::printf("sg-host: no plugin at index %d\n", options.index);
        library.entry->deinit();
        return 1;
    }

    Host host;
    init_host(host);
    const auto* descriptor = factory->get_plugin_descriptor(factory, options.index);
    const clap_plugin_t* plugin = factory->create_plugin(factory, &host.host, descriptor->id);
    if (!plugin || !plugin->init(plugin)) {
        std::printf("sg-host: create/init failed for %s\n", descriptor->id);
        library.entry->deinit();
        return 1;
    }

    // Channel count comes from the audio-ports extension when the plugin has one;
    // stereo is the fallback every host in the world would also assume.
    uint32_t channels = 2;
    if (const auto* audio_ports = static_cast<const clap_plugin_audio_ports_t*>(
            plugin->get_extension(plugin, CLAP_EXT_AUDIO_PORTS))) {
        clap_audio_port_info_t info{};
        if (audio_ports->count(plugin, false) > 0 && audio_ports->get(plugin, 0, false, &info)) {
            channels = info.channel_count;
        }
    }

    const auto* params = static_cast<const clap_plugin_params_t*>(
        plugin->get_extension(plugin, CLAP_EXT_PARAMS));
    if (params) {
        std::printf("  %u parameter(s)\n", params->count(plugin));
    }

    if (options.list) {
        if (params) {
            for (uint32_t i = 0; i < params->count(plugin); ++i) {
                clap_param_info_t info{};
                if (!params->get_info(plugin, i, &info)) continue;
                if (info.flags & CLAP_PARAM_IS_HIDDEN) continue;
                std::printf("    %-24s [%g .. %g] default %g%s%s\n", info.name, info.min_value,
                            info.max_value, info.default_value,
                            info.module[0] ? "  module " : "", info.module);
            }
        }
        plugin->destroy(plugin);
        library.entry->deinit();
        return 0;
    }

    // --param values resolve against display names before processing starts, and ride
    // the first block's event list the way host automation would.
    EventList events;
    for (const auto& [name, value] : options.params) {
        bool found = false;
        if (params) {
            for (uint32_t i = 0; i < params->count(plugin) && !found; ++i) {
                clap_param_info_t info{};
                if (params->get_info(plugin, i, &info) && name == info.name) {
                    events.push(param_event(info.id, value));
                    found = true;
                }
            }
        }
        if (!found) {
            std::printf("sg-host: no parameter named \"%s\"\n", name.c_str());
            plugin->destroy(plugin);
            library.entry->deinit();
            return 1;
        }
    }

    if (!plugin->activate(plugin, options.sample_rate, 32,
                          static_cast<uint32_t>(options.block)) ||
        !plugin->start_processing(plugin)) {
        std::printf("sg-host: activate/start_processing failed\n");
        plugin->destroy(plugin);
        library.entry->deinit();
        return 1;
    }

    const int total_frames = static_cast<int>(options.seconds * options.sample_rate);
    const int blocks = (total_frames + options.block - 1) / options.block;
    // Notes hold for three quarters of the render, so a release tail has room to be
    // heard — a synth that only sounds while gated still registers, and one that
    // rings out is captured doing it.
    const int release_block = blocks * 3 / 4;

    std::vector<std::vector<float>> buffers(channels, std::vector<float>(options.block));
    std::vector<float*> channel_pointers(channels);
    for (uint32_t c = 0; c < channels; ++c) channel_pointers[c] = buffers[c].data();

    clap_audio_buffer_t out{};
    out.data32 = channel_pointers.data();
    out.channel_count = channels;

    clap_output_events_t out_events{};
    out_events.try_push = [](const clap_output_events_t*, const clap_event_header_t*) {
        return false;
    };

    soundgraph::AudioFile rendered;
    rendered.sample_rate = static_cast<int>(options.sample_rate);
    rendered.channels = static_cast<int>(channels);
    rendered.samples.reserve(static_cast<std::size_t>(blocks) * options.block * channels);

    for (int key : options.notes) {
        events.push(note_event(CLAP_EVENT_NOTE_ON, static_cast<int16_t>(key)));
    }

    double sum_of_squares = 0.0;
    double peak = 0.0;
    long long sample_count = 0;
    for (int block = 0; block < blocks; ++block) {
        if (block == release_block) {
            for (int key : options.notes) {
                events.push(note_event(CLAP_EVENT_NOTE_OFF, static_cast<int16_t>(key)));
            }
        }
        clap_process_t process{};
        process.steady_time = static_cast<int64_t>(block) * options.block;
        process.frames_count = static_cast<uint32_t>(options.block);
        process.audio_outputs = &out;
        process.audio_outputs_count = 1;
        process.in_events = &events.in;
        process.out_events = &out_events;
        plugin->process(plugin, &process);
        events.clear();

        // Between blocks is this host's main thread, so a requested callback is
        // answered here — patch swaps and their kin depend on this arriving.
        if (host.callback_requested) {
            host.callback_requested = false;
            plugin->on_main_thread(plugin);
        }

        for (int frame = 0; frame < options.block; ++frame) {
            for (uint32_t c = 0; c < channels; ++c) {
                const float sample = buffers[c][frame];
                rendered.samples.push_back(sample);
                sum_of_squares += static_cast<double>(sample) * sample;
                peak = std::max(peak, static_cast<double>(std::fabs(sample)));
                ++sample_count;
            }
        }
    }

    const double rms = std::sqrt(sum_of_squares / std::max(sample_count, 1LL));
    std::printf("  rendered %.2fs at %g Hz, %u channel(s): rms %f, peak %f\n",
                options.seconds, options.sample_rate, channels, rms, peak);

    if (!options.wav_path.empty()) {
        if (!soundgraph::write_wav_float(options.wav_path, rendered, error)) {
            std::printf("sg-host: %s\n", error.c_str());
            plugin->stop_processing(plugin);
            plugin->deactivate(plugin);
            plugin->destroy(plugin);
            library.entry->deinit();
            return 1;
        }
        std::printf("  wrote %s\n", options.wav_path.c_str());
    }

    plugin->stop_processing(plugin);
    plugin->deactivate(plugin);
    plugin->destroy(plugin);
    library.entry->deinit();

    if (options.rms_min >= 0.0 && rms < options.rms_min) {
        std::printf("sg-host: rms %f is below the required %f — the plugin is silent\n", rms,
                    options.rms_min);
        return 1;
    }
    return 0;
}
