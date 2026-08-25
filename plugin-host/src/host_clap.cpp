// The CLAP side of sg-host: dlopen/LoadLibrary a .clap, resolve clap_entry, walk the
// factory, and be enough of a host for the plugin to live in.
//
// The one thing worth knowing here is that CLAP asks for its main thread explicitly:
// request_callback comes in from the audio thread and the host answers it when it can.
// A host that never answers looks fine until a plugin tries to change something
// structural — for SoundGraph that is a patch swap — and then it silently never
// happens. main_thread_tick is where we keep that promise.
#include <clap/clap.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include "hosted_plugin.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace soundgraph::host {
namespace {

struct ClapTimer {
    clap_id id = 0;
    uint32_t period_ms = 0;
    uint64_t next_ms = 0;
};

struct ClapHost {
    clap_host_t host{};
    bool callback_requested = false;
    int rescan_count = 0;
    // A plugin's editor is usually a timer and a redraw. Surge XT registers one the
    // moment its window opens, and a host that offers no timer support at all is a host
    // it was not written against — which is how asking for a GUI came to segfault
    // before any of this existed.
    std::vector<ClapTimer> timers;
    clap_id next_timer_id = 1;
    std::thread::id main_thread = std::this_thread::get_id();
};

// The host extensions a plugin with a face expects to find. Missing ones are not a
// polite degradation: a plugin that asks for timer support and is told there is none
// may simply not draw, and one that assumes thread-check exists may do worse.
const clap_host_timer_support_t kHostTimer = {
    /*register_timer*/ [](const clap_host_t* host, uint32_t period_ms, clap_id* id) {
        auto* self = static_cast<ClapHost*>(host->host_data);
        ClapTimer timer;
        timer.id = self->next_timer_id++;
        timer.period_ms = period_ms < 8 ? 8 : period_ms;
        timer.next_ms = 0;
        self->timers.push_back(timer);
        *id = timer.id;
        return true;
    },
    /*unregister_timer*/ [](const clap_host_t* host, clap_id id) {
        auto* self = static_cast<ClapHost*>(host->host_data);
        for (std::size_t i = 0; i < self->timers.size(); ++i) {
            if (self->timers[i].id == id) {
                self->timers.erase(self->timers.begin() + static_cast<long>(i));
                return true;
            }
        }
        return false;
    },
};

const clap_host_gui_t kHostGui = {
    /*resize_hints_changed*/ [](const clap_host_t*) {},
    // A plugin may ask to be a different size than it first said. This host says yes
    // and does nothing about it, which is honest for a window nobody is laying out.
    /*request_resize*/ [](const clap_host_t*, uint32_t, uint32_t) { return true; },
    /*request_show*/ [](const clap_host_t*) { return true; },
    /*request_hide*/ [](const clap_host_t*) { return true; },
    /*closed*/ [](const clap_host_t*, bool) {},
};

// Thread check is deliberately NOT offered. This host does everything on one thread —
// there is no audio thread to be on — so every answer it could give is a lie, and a
// plugin told "you are not on the audio thread" during start_processing rightly
// complains. Offering nothing lets a plugin keep its own counsel, which is the honest
// position for a host that genuinely has one thread.

const clap_host_params_t kHostParams = {
    /*rescan*/ [](const clap_host_t* host, clap_param_rescan_flags) {
        ++static_cast<ClapHost*>(host->host_data)->rescan_count;
    },
    /*clear*/ [](const clap_host_t*, clap_id, clap_param_clear_flags) {},
    /*request_flush*/ [](const clap_host_t*) {},
};

const clap_host_log_t kHostLog = {
    /*log*/ [](const clap_host_t*, clap_log_severity severity, const char* message) {
        std::printf("  [plugin log %d] %s\n", severity, message);
    },
};

// Events are copied into flat storage because CLAP wants an array of headers pointing
// at whole structs, and the structs differ in size.
class ClapEvents {
public:
    ClapEvents() {
        in_.ctx = this;
        in_.size = [](const clap_input_events_t* list) -> uint32_t {
            return static_cast<uint32_t>(static_cast<ClapEvents*>(list->ctx)->events_.size());
        };
        in_.get = [](const clap_input_events_t* list, uint32_t index) {
            return static_cast<ClapEvents*>(list->ctx)->events_[index];
        };
    }

    template <typename Event>
    void push(const Event& event) {
        storage_.emplace_back(reinterpret_cast<const char*>(&event),
                              reinterpret_cast<const char*>(&event) + sizeof(Event));
        reindex();
    }

    void clear() {
        storage_.clear();
        events_.clear();
    }

    const clap_input_events_t* list() const { return &in_; }

private:
    void reindex() {
        events_.clear();
        for (const auto& bytes : storage_) {
            events_.push_back(reinterpret_cast<const clap_event_header_t*>(bytes.data()));
        }
    }

    std::vector<std::vector<char>> storage_;
    std::vector<const clap_event_header_t*> events_;
    clap_input_events_t in_{};
};

class ClapPlugin final : public HostedPlugin {
public:
    ~ClapPlugin() override {
        if (plugin_) {
            if (active_) {
                plugin_->stop_processing(plugin_);
                plugin_->deactivate(plugin_);
            }
            plugin_->destroy(plugin_);
        }
        if (entry_) entry_->deinit();
#if defined(_WIN32)
        if (library_) FreeLibrary(library_);
#else
        if (library_) dlclose(library_);
#endif
    }

    bool open(const std::string& path, int index, std::string& error) {
#if defined(_WIN32)
        library_ = LoadLibraryA(path.c_str());
        if (!library_) {
            error = "could not load " + path + " (LoadLibrary error " +
                    std::to_string(GetLastError()) + ")";
            return false;
        }
        entry_ = reinterpret_cast<const clap_plugin_entry_t*>(
            reinterpret_cast<void*>(GetProcAddress(library_, "clap_entry")));
#else
        library_ = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
#if defined(__APPLE__)
        if (!library_) {
            // A .clap on macOS is a bundle; the binary is Contents/MacOS/<stem>.
            const auto slash = path.find_last_of('/');
            std::string stem = slash == std::string::npos ? path : path.substr(slash + 1);
            const auto dot = stem.rfind(".clap");
            if (dot != std::string::npos) stem = stem.substr(0, dot);
            library_ = dlopen((path + "/Contents/MacOS/" + stem).c_str(), RTLD_NOW | RTLD_LOCAL);
        }
#endif
        if (!library_) {
            error = "could not load " + path + " (" + dlerror() + ")";
            return false;
        }
        entry_ = reinterpret_cast<const clap_plugin_entry_t*>(dlsym(library_, "clap_entry"));
#endif
        if (!entry_) {
            error = path + " exports no clap_entry — not a CLAP plugin";
            return false;
        }
        if (!entry_->init(path.c_str())) {
            const auto* failed = entry_;
            entry_ = nullptr;  // it refused init; it must not be deinited
            (void)failed;
            error = path + " refused entry init";
            return false;
        }

        factory_ = static_cast<const clap_plugin_factory_t*>(
            entry_->get_factory(CLAP_PLUGIN_FACTORY_ID));
        if (!factory_) {
            error = path + " has no plugin factory";
            return false;
        }

        const uint32_t count = factory_->get_plugin_count(factory_);
        for (uint32_t i = 0; i < count; ++i) {
            const auto* descriptor = factory_->get_plugin_descriptor(factory_, i);
            available_.push_back({descriptor->id ? descriptor->id : "",
                                  descriptor->name ? descriptor->name : "",
                                  descriptor->vendor ? descriptor->vendor : "", "CLAP"});
        }
        if (count == 0 || index < 0 || static_cast<uint32_t>(index) >= count) {
            error = "no plugin at index " + std::to_string(index);
            return false;
        }
        chosen_ = available_[static_cast<std::size_t>(index)];

        host_.host.clap_version = CLAP_VERSION;
        host_.host.host_data = &host_;
        host_.host.name = "sg-host";
        host_.host.vendor = "soundgraph";
        host_.host.url = "";
        host_.host.version = "1";
        host_.host.get_extension = [](const clap_host_t*, const char* id) -> const void* {
            if (std::strcmp(id, CLAP_EXT_PARAMS) == 0) return &kHostParams;
            if (std::strcmp(id, CLAP_EXT_LOG) == 0) return &kHostLog;
            if (std::strcmp(id, CLAP_EXT_TIMER_SUPPORT) == 0) return &kHostTimer;
            if (std::strcmp(id, CLAP_EXT_GUI) == 0) return &kHostGui;
            return nullptr;
        };
        host_.host.request_restart = [](const clap_host_t*) {};
        host_.host.request_process = [](const clap_host_t*) {};
        host_.host.request_callback = [](const clap_host_t* host) {
            static_cast<ClapHost*>(host->host_data)->callback_requested = true;
        };

        const auto* descriptor = factory_->get_plugin_descriptor(factory_, index);
        plugin_ = factory_->create_plugin(factory_, &host_.host, descriptor->id);
        if (!plugin_ || !plugin_->init(plugin_)) {
            error = "create/init failed for " + chosen_.id;
            return false;
        }

        params_ = static_cast<const clap_plugin_params_t*>(
            plugin_->get_extension(plugin_, CLAP_EXT_PARAMS));

        channels_ = 2;
        if (const auto* ports = static_cast<const clap_plugin_audio_ports_t*>(
                plugin_->get_extension(plugin_, CLAP_EXT_AUDIO_PORTS))) {
            clap_audio_port_info_t info{};
            if (ports->count(plugin_, false) > 0 && ports->get(plugin_, 0, false, &info)) {
                channels_ = static_cast<int>(info.channel_count);
            }
        }
        return true;
    }

    const std::vector<PluginDescription>& available() const override { return available_; }
    const PluginDescription& chosen() const override { return chosen_; }
    int channel_count() const override { return channels_; }

    std::vector<Parameter> parameters() const override {
        std::vector<Parameter> result;
        if (!params_) return result;
        const uint32_t count = params_->count(plugin_);
        for (uint32_t i = 0; i < count; ++i) {
            clap_param_info_t info{};
            if (!params_->get_info(plugin_, i, &info)) continue;
            result.push_back({info.id, info.name, info.module, info.min_value, info.max_value,
                              info.default_value, (info.flags & CLAP_PARAM_IS_HIDDEN) != 0});
        }
        return result;
    }

    bool activate(double sample_rate, int block_frames, std::string& error) override {
        if (!plugin_->activate(plugin_, sample_rate, 32, static_cast<uint32_t>(block_frames)) ||
            !plugin_->start_processing(plugin_)) {
            error = "activate/start_processing failed";
            return false;
        }
        active_ = true;
        return true;
    }

    void deactivate() override {
        if (!active_) return;
        plugin_->stop_processing(plugin_);
        plugin_->deactivate(plugin_);
        active_ = false;
    }

    void queue_parameter(uint32_t id, double value) override {
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
        events_.push(event);
    }

    void queue_note(int key, bool on) override {
        clap_event_note_t event{};
        event.header.size = sizeof(event);
        event.header.time = 0;
        event.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
        event.header.type = static_cast<uint16_t>(on ? CLAP_EVENT_NOTE_ON : CLAP_EVENT_NOTE_OFF);
        event.note_id = -1;
        event.port_index = 0;
        event.channel = 0;
        event.key = static_cast<int16_t>(key);
        event.velocity = 0.9;
        events_.push(event);
    }

    bool process(int frames, std::vector<std::vector<float>>& channels) override {
        pointers_.clear();
        for (auto& channel : channels) pointers_.push_back(channel.data());

        clap_audio_buffer_t out{};
        out.data32 = pointers_.data();
        out.channel_count = static_cast<uint32_t>(pointers_.size());

        clap_output_events_t out_events{};
        out_events.try_push = [](const clap_output_events_t*, const clap_event_header_t*) {
            return false;
        };

        clap_process_t process{};
        process.steady_time = steady_time_;
        process.frames_count = static_cast<uint32_t>(frames);
        process.audio_outputs = &out;
        process.audio_outputs_count = 1;
        process.in_events = events_.list();
        process.out_events = &out_events;
        plugin_->process(plugin_, &process);
        steady_time_ += frames;
        events_.clear();
        return true;
    }

    bool process_audio(const float* const* inputs, int input_channels, float* const* outputs,
                       int output_channels, int frames) override {
        clap_audio_buffer_t out{};
        out.data32 = const_cast<float**>(outputs);
        out.channel_count = static_cast<uint32_t>(output_channels);

        // CLAP takes input buffers as non-const, though a well-behaved plugin only
        // reads them; the graph's buffers are ours and this is the documented shape.
        clap_audio_buffer_t in{};
        in.data32 = const_cast<float**>(inputs);
        in.channel_count = static_cast<uint32_t>(input_channels);

        clap_output_events_t out_events{};
        out_events.try_push = [](const clap_output_events_t*, const clap_event_header_t*) {
            return false;
        };

        clap_process_t process{};
        process.steady_time = steady_time_;
        process.frames_count = static_cast<uint32_t>(frames);
        process.audio_inputs = inputs != nullptr ? &in : nullptr;
        process.audio_inputs_count = inputs != nullptr ? 1u : 0u;
        process.audio_outputs = &out;
        process.audio_outputs_count = 1;
        process.in_events = events_.list();
        process.out_events = &out_events;
        plugin_->process(plugin_, &process);
        steady_time_ += frames;
        events_.clear();
        return true;
    }

    // ---- the plugin's own face -------------------------------------------------
    // The sequence is the one gui.h documents, and every step of it matters: a plugin
    // asked to show before it has been given a parent draws into nothing, and one given
    // a parent before create() has nowhere to put it.
    bool has_gui() override { return gui_extension() != nullptr; }

    bool open_gui(void* parent) override {
        const clap_plugin_gui_t* gui = gui_extension();
        if (gui == nullptr || parent == nullptr) return false;
#if defined(_WIN32)
        const char* api = CLAP_WINDOW_API_WIN32;
#elif defined(__APPLE__)
        const char* api = CLAP_WINDOW_API_COCOA;
#else
        const char* api = CLAP_WINDOW_API_X11;
#endif
        if (!gui->is_api_supported(plugin_, api, false)) return false;
        if (!gui->create(plugin_, api, false)) return false;
        gui_open_ = true;
        gui->set_scale(plugin_, 1.0);

        clap_window_t window{};
        window.api = api;
#if defined(_WIN32)
        window.win32 = parent;
#elif defined(__APPLE__)
        window.cocoa = parent;
#else
        window.x11 = reinterpret_cast<unsigned long>(parent);
#endif
        if (!gui->set_parent(plugin_, &window)) {
            close_gui();
            return false;
        }
        gui->show(plugin_);
        return true;
    }

    void close_gui() override {
        const clap_plugin_gui_t* gui = gui_extension();
        if (gui == nullptr || !gui_open_) return;
        gui->hide(plugin_);
        gui->destroy(plugin_);
        gui_open_ = false;
    }

    bool gui_size(unsigned& width, unsigned& height) override {
        const clap_plugin_gui_t* gui = gui_extension();
        if (gui == nullptr || !gui_open_) return false;
        uint32_t w = 0, h = 0;
        if (!gui->get_size(plugin_, &w, &h)) return false;
        width = w;
        height = h;
        return true;
    }

    void main_thread_tick() override {
        if (host_.callback_requested) {
            host_.callback_requested = false;
            plugin_->on_main_thread(plugin_);
        }
        fire_due_timers();
    }

    void settle(int) override {
        // CLAP hands the request straight to the host, so there is nothing to wait
        // for: servicing it once is the whole of the obligation.
        main_thread_tick();
    }

private:
    // Whatever the plugin registered, fired when it is due. Without this a plugin's
    // editor is a still photograph: it draws once and never updates.
    void fire_due_timers() {
        if (host_.timers.empty()) return;
        const auto* timers = static_cast<const clap_plugin_timer_support_t*>(
            plugin_->get_extension(plugin_, CLAP_EXT_TIMER_SUPPORT));
        if (timers == nullptr) return;
        const uint64_t now = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch())
                .count());
        // Copied because on_timer may register or unregister one, and a plugin
        // rearranging the list underneath the loop walking it is a crash.
        std::vector<ClapTimer> due;
        for (ClapTimer& timer : host_.timers) {
            if (now >= timer.next_ms) {
                timer.next_ms = now + timer.period_ms;
                due.push_back(timer);
            }
        }
        for (const ClapTimer& timer : due) {
            timers->on_timer(plugin_, timer.id);
        }
    }

    const clap_plugin_gui_t* gui_extension() {
        if (plugin_ == nullptr) return nullptr;
        return static_cast<const clap_plugin_gui_t*>(
            plugin_->get_extension(plugin_, CLAP_EXT_GUI));
    }

    bool gui_open_ = false;
#if defined(_WIN32)
    HMODULE library_ = nullptr;
#else
    void* library_ = nullptr;
#endif
    const clap_plugin_entry_t* entry_ = nullptr;
    const clap_plugin_factory_t* factory_ = nullptr;
    const clap_plugin_t* plugin_ = nullptr;
    const clap_plugin_params_t* params_ = nullptr;
    ClapHost host_;
    ClapEvents events_;
    std::vector<PluginDescription> available_;
    PluginDescription chosen_;
    std::vector<float*> pointers_;
    int64_t steady_time_ = 0;
    int channels_ = 2;
    bool active_ = false;
};

}  // namespace

std::unique_ptr<HostedPlugin> open_clap(const std::string& path, int index,
                                        std::string& error) {
    auto plugin = std::make_unique<ClapPlugin>();
    if (!plugin->open(path, index, error)) return nullptr;
    return plugin;
}

}  // namespace soundgraph::host
