// sg-host — a headless plugin host the size of a command line tool.
//
// Loads a .clap or a .vst3 from disk the way a DAW would — the real dynamic-loading
// path, not a re-link of our own objects — then activates a plugin, plays notes at it,
// and measures what comes back. It exists so the plugins this repository builds can be
// tested by a host whose source we control: when a DAW misbehaves, test_plugin says
// whose bug it is *in-process*; sg-host says the same thing across the loading
// boundary, against the shipped artifact, in both formats.
//
// It is deliberately not a player. No audio device, no timers, no GUI: stdin is nobody,
// stdout is the report, the exit code is the verdict. That is what lets it sit inside
// ctest and the pre-push gate.
//
// Everything below the format boundary lives in host_clap.cpp and host_vst3.cpp; this
// file knows only what hosted_plugin.h declares, which is why adding a third format
// would not touch it.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "desktop_provider.h"
#include "hosted_plugin.h"
#include "wav.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace {

// A stranger's plugin can stop this program dead and never give it back.
//
// Not by crashing — that would at least be an exit. u-he's Podolski, deployed without
// the data directory its installer would have written, opens a *modal message box* from
// inside the audio setup path and waits for a click that a console application is never
// going to provide. It waited three minutes before a timeout elsewhere noticed. A rig
// that runs unattended cannot have that failure mode, and no amount of care in this
// file prevents it: by then the main thread belongs to someone else's dialog.
//
// So the answer is a thread that is not the main thread, and an exit that does not ask
// permission. std::_Exit rather than a return: whatever has the main thread also has
// whatever locks it took, and running destructors through that is how a hang becomes a
// hang plus a crash.
class Watchdog {
public:
    Watchdog(int seconds, std::string subject) : subject_(std::move(subject)) {
        if (seconds <= 0) return;  // explicitly disarmed
        thread_ = std::thread([this, seconds] {
            std::unique_lock<std::mutex> lock(mutex_);
            if (finished_.wait_for(lock, std::chrono::seconds(seconds),
                                   [this] { return done_; })) {
                return;
            }
            std::fflush(stdout);
            std::fprintf(stderr,
                         "sg-host: %s did not finish within %d seconds — abandoning it.\n"
                         "  A plugin that blocks like this is usually showing a dialog "
                         "no console will ever click.\n",
                         subject_.c_str(), seconds);
            std::fflush(stderr);
            std::_Exit(kTimedOut);
        });
    }

    ~Watchdog() {
        if (!thread_.joinable()) return;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            done_ = true;
        }
        finished_.notify_all();
        thread_.join();
    }

    static constexpr int kTimedOut = 3;  // distinct from silent (1) and misuse (2)

private:
    std::string subject_;
    std::mutex mutex_;
    std::condition_variable finished_;
    bool done_ = false;
    std::thread thread_;
};

// Windows will happily put its own modal dialogs in front of a headless process — a
// missing dependency, a hard fault — and each one is another wait with nobody to end
// it. This turns those into return codes. It does NOT stop a plugin calling MessageBox
// itself, which is exactly what Podolski does; only the watchdog answers that.
void silence_system_dialogs() {
#if defined(_WIN32)
    ::SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
#endif
}

// Shows a plugin's own window in a window of ours.
//
// The point is not the tool — nobody needs sg-host to look at Surge XT — but the
// proof. Hosting a plugin's editor is the one part of this feature that cannot be
// tested headlessly, so it is worth being able to see it working somewhere small
// before it is asked to work inside the editor, where a failure looks like Godot's
// fault. What the editor will do differently is hand over its own window handle
// instead of this one.
int show_gui(soundgraph::host::HostedPlugin& plugin, const std::string& title,
             int seconds) {
#if defined(_WIN32)
    if (!plugin.has_gui()) {
        std::printf("  this plugin has no editor to show\n");
        return 1;
    }

    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = [](HWND window, UINT message, WPARAM w, LPARAM l) -> LRESULT {
        if (message == WM_CLOSE) {
            ::PostQuitMessage(0);
            return 0;
        }
        return ::DefWindowProcW(window, message, w, l);
    };
    window_class.hInstance = ::GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"sg-host-plugin-window";
    window_class.hCursor = ::LoadCursor(nullptr, IDC_ARROW);
    ::RegisterClassExW(&window_class);

    const std::wstring wide(title.begin(), title.end());
    HWND frame = ::CreateWindowExW(0, window_class.lpszClassName, wide.c_str(),
                                   WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 900, 700,
                                   nullptr, nullptr, window_class.hInstance, nullptr);
    if (frame == nullptr) {
        std::printf("  could not make a window to put it in\n");
        return 1;
    }

    if (!plugin.open_gui(frame)) {
        std::printf("  the plugin declined to open its editor here\n");
        ::DestroyWindow(frame);
        return 1;
    }

    // Fit the frame around whatever the plugin says it wants, rather than leaving it
    // in a window of an arbitrary size with its face in one corner.
    unsigned width = 0, height = 0;
    if (plugin.gui_size(width, height) && width > 0 && height > 0) {
        RECT wanted{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
        ::AdjustWindowRect(&wanted, WS_OVERLAPPEDWINDOW, FALSE);
        ::SetWindowPos(frame, nullptr, 0, 0, wanted.right - wanted.left,
                       wanted.bottom - wanted.top, SWP_NOMOVE | SWP_NOZORDER);
        std::printf("  editor is %u x %u\n", width, height);
    }
    ::ShowWindow(frame, SW_SHOW);
    ::UpdateWindow(frame);

    const DWORD deadline = seconds > 0 ? ::GetTickCount() + seconds * 1000u : 0;
    MSG message;
    while (true) {
        while (::PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
                plugin.close_gui();
                ::DestroyWindow(frame);
                return 0;
            }
            ::TranslateMessage(&message);
            ::DispatchMessageW(&message);
        }
        plugin.main_thread_tick();
        if (deadline != 0 && ::GetTickCount() > deadline) break;
        ::Sleep(10);
    }
    plugin.close_gui();
    ::DestroyWindow(frame);
    return 0;
#else
    (void)plugin;
    (void)title;
    (void)seconds;
    std::printf("  --gui is Windows-only so far\n");
    return 1;
#endif
}

// Long enough for a 20 ms timer to fire twice, which is what clap-wrapper's VST3 shim
// needs to deliver deferred main-thread work. Paid once per run, never per block.
constexpr int kSettleMilliseconds = 60;

struct Options {
    std::string plugin_path;
    bool scan = false;
    bool gui = false;
    int gui_seconds = 0;
    std::string wav_path;
    bool list = false;
    int index = 0;
    double seconds = 2.0;
    double sample_rate = 48000.0;
    int block = 512;
    double rms_min = -1.0;  // negative: report only, no verdict
    int timeout = 60;       // seconds of wall clock before giving up; 0 disables
    std::vector<int> notes{60};
    std::vector<std::pair<std::string, double>> params;  // by display name
    std::string load_state_path;
    std::string save_state_path;
};

void usage() {
    std::printf(
        "sg-host <plugin.clap|plugin.vst3> [options]\n"
        "  --list                 print the plugins and parameters, then exit\n"
        "  --index N              which plugin in the factory (default 0)\n"
        "  --seconds S            how long to render (default 2)\n"
        "  --rate HZ              sample rate (default 48000)\n"
        "  --block FRAMES         block size (default 512)\n"
        "  --note K[,K...]        MIDI keys to hold (default 60)\n"
        "  --param NAME=VALUE     set a parameter by display name, repeatable;\n"
        "                         VALUE is in the range --list prints for it\n"
        "  --wav PATH             write the rendered audio as 32-bit float WAV\n"
        "  --rms-min X            fail (exit 1) if the render's RMS is below X\n"
        "  --env NAME=VALUE       set an environment variable first, repeatable\n"
        "  --load-state PATH      hand the plugin a state blob before it plays\n"
        "  --save-state PATH      write the plugin's own state out after the render\n");
}

// Whole-file reads and writes, binary. A plugin's state is bytes, and nothing here is
// entitled to an opinion about them — in particular not about newlines, which is why
// both sides open in binary mode on the platform that would otherwise translate them.
bool read_file(const std::string& path, std::string& bytes) {
    std::FILE* file = std::fopen(path.c_str(), "rb");
    if (file == nullptr) return false;
    char buffer[8192];
    std::size_t got = 0;
    while ((got = std::fread(buffer, 1, sizeof(buffer), file)) > 0) {
        bytes.append(buffer, got);
    }
    std::fclose(file);
    return true;
}

bool write_file(const std::string& path, const std::string& bytes) {
    std::FILE* file = std::fopen(path.c_str(), "wb");
    if (file == nullptr) return false;
    const std::size_t written =
        bytes.empty() ? 0 : std::fwrite(bytes.data(), 1, bytes.size(), file);
    std::fclose(file);
    return written == bytes.size();
}

bool ends_with(const std::string& text, const std::string& suffix) {
    if (text.size() < suffix.size()) return false;
    return std::equal(suffix.rbegin(), suffix.rend(), text.rbegin(),
                      [](char a, char b) { return std::tolower(a) == std::tolower(b); });
}

// Escapes a string for JSON. Small on purpose: plugin names contain quotes and
// backslashes often enough to matter, and everything else here is ASCII from a
// filesystem or a vendor's descriptor.
std::string json_escape(const std::string& text) {
    std::string out;
    out.reserve(text.size() + 8);
    for (const char c : text) {
        switch (c) {
            case 0x22: out += "\\\""; break;   // a quote
            case 0x5C: out += "\\\\"; break;   // a backslash
            case 0x0A: out += "\\n"; break;
            case 0x0D: out += "\\r"; break;
            case 0x09: out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                    out += buffer;
                } else {
                    out += c;
                }
        }
    }
    return out;
}

bool parse(int argc, char** argv, Options& options, std::string& error) {
    if (argc < 2) {
        error = "no plugin path given";
        return false;
    }
    // --scan is the one mode with nothing to point at: it is asking about the machine
    // rather than about a file.
    if (std::strcmp(argv[1], "--scan") == 0) {
        options.scan = true;
        return true;
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
        if (arg == "--gui") {
            options.gui = true;
        } else if (arg == "--gui-seconds") {
            const char* v = value("--gui-seconds");
            if (!v) return false;
            options.gui_seconds = std::atoi(v);
            options.gui = true;
        } else if (arg == "--list") {
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
        } else if (arg == "--timeout") {
            const char* v = value("--timeout");
            if (!v) return false;
            options.timeout = std::atoi(v);
        } else if (arg == "--rms-min") {
            const char* v = value("--rms-min");
            if (!v) return false;
            options.rms_min = std::atof(v);
        } else if (arg == "--load-state") {
            const char* v = value("--load-state");
            if (!v) return false;
            options.load_state_path = v;
        } else if (arg == "--save-state") {
            const char* v = value("--save-state");
            if (!v) return false;
            options.save_state_path = v;
        } else if (arg == "--wav") {
            const char* v = value("--wav");
            if (!v) return false;
            options.wav_path = v;
        } else if (arg == "--note") {
            const char* v = value("--note");
            if (!v) return false;
            options.notes.clear();
            const std::string list = v;
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
    using namespace soundgraph::host;

    Options options;
    std::string error;
    if (!parse(argc, argv, options, error)) {
        std::printf("sg-host: %s\n\n", error.c_str());
        usage();
        return 2;
    }

    silence_system_dialogs();

    // Scanning is its own program, really: it opens every plugin on the machine and
    // says what it found, in a shape an editor can read. Out of process on purpose —
    // opening a stranger's plugin is exactly the act that hangs or crashes, and an
    // editor should not be the process it happens in. Podolski is the standing proof.
    if (options.scan) {
        Watchdog scan_watchdog(options.timeout > 0 ? options.timeout * 4 : 0,
                               "the plugin scan");
        const auto found = soundgraph::host::scan_installed_plugins();
        std::printf("[\n");
        for (std::size_t i = 0; i < found.size(); ++i) {
            const auto& plugin = found[i];
            std::printf("  {\"format\": \"%s\", \"identity\": \"%s\", \"name\": \"%s\",\n"
                        "   \"vendor\": \"%s\", \"path\": \"%s\", \"parameters\": [",
                        json_escape(plugin.format).c_str(), json_escape(plugin.identity).c_str(),
                        json_escape(plugin.name).c_str(), json_escape(plugin.vendor).c_str(),
                        json_escape(plugin.path).c_str());
            for (std::size_t j = 0; j < plugin.parameters.size(); ++j) {
                std::printf("%s{\"id\": %d, \"name\": \"%s\"}", j == 0 ? "" : ", ",
                            plugin.parameters[j].first,
                            json_escape(plugin.parameters[j].second).c_str());
            }
            std::printf("]}%s\n", i + 1 == found.size() ? "" : ",");
        }
        std::printf("]\n");
        return 0;
    }

    // Armed before the library is even opened: loading is one of the places a plugin
    // can decide to ask the user something.
    Watchdog watchdog(options.timeout, options.plugin_path);

    // The extension picks the backend. A DAW would scan directories and trust the
    // layout; a tool given one path can simply read the name it was handed.
    std::unique_ptr<HostedPlugin> plugin;
    if (ends_with(options.plugin_path, ".clap")) {
        plugin = open_clap(options.plugin_path, options.index, error);
    } else if (ends_with(options.plugin_path, ".vst3")) {
        plugin = open_vst3(options.plugin_path, options.index, error);
    } else {
        std::printf("sg-host: %s is neither .clap nor .vst3\n", options.plugin_path.c_str());
        return 2;
    }
    if (!plugin) {
        std::printf("sg-host: %s\n", error.c_str());
        return 1;
    }

    std::printf("%s: %zu plugin(s)\n", options.plugin_path.c_str(), plugin->available().size());
    for (std::size_t i = 0; i < plugin->available().size(); ++i) {
        const auto& description = plugin->available()[i];
        std::printf("  [%zu] %s — %s (%s) [%s]\n", i, description.id.c_str(),
                    description.name.c_str(), description.vendor.c_str(),
                    description.format.c_str());
    }

    const auto parameters = plugin->parameters();
    std::printf("  %zu parameter(s), %d output channel(s)\n", parameters.size(),
                plugin->channel_count());

    // Before anything is set and before the plugin is activated, which is the order the
    // desktop provider uses too: a plugin is told what it is, and then told to play.
    if (!options.load_state_path.empty()) {
        std::string bytes;
        if (!read_file(options.load_state_path, bytes)) {
            std::printf("sg-host: could not read %s\n", options.load_state_path.c_str());
            return 1;
        }
        if (!plugin->load_state(bytes)) {
            std::printf("sg-host: the plugin refused the state in %s\n",
                        options.load_state_path.c_str());
            return 1;
        }
        std::printf("  loaded %zu bytes of state from %s\n", bytes.size(),
                    options.load_state_path.c_str());
    }

    if (options.gui) {
        // A plugin's editor usually wants the plugin activated behind it — the face is
        // a view onto something running, not a picture.
        std::string activate_error;
        plugin->activate(options.sample_rate, options.block, activate_error);
        return show_gui(*plugin, plugin->chosen().name, options.gui_seconds);
    }

    if (options.list) {
        for (const auto& parameter : parameters) {
            if (parameter.hidden) continue;
            std::printf("    %-24s [%g .. %g] default %g%s%s\n", parameter.name.c_str(),
                        parameter.minimum, parameter.maximum, parameter.default_value,
                        parameter.module.empty() ? "" : "  module ", parameter.module.c_str());
        }
        return 0;
    }

    // --param resolves against display names before processing starts, and rides the
    // first block the way host automation would.
    for (const auto& [name, value] : options.params) {
        const auto match = std::find_if(parameters.begin(), parameters.end(),
                                        [&](const Parameter& p) { return p.name == name; });
        if (match == parameters.end()) {
            std::printf("sg-host: no parameter named \"%s\"\n", name.c_str());
            return 1;
        }
        plugin->queue_parameter(match->id, value);
    }

    if (!plugin->activate(options.sample_rate, options.block, error)) {
        std::printf("sg-host: %s\n", error.c_str());
        return 1;
    }

    // Sixty-four bit because --seconds is a double and nothing stops it being large:
    // an hour at 48 kHz is already 173 million frames, and int32 gives out at about
    // twelve hours. It overflowed silently when the watchdog test asked for 200000
    // seconds — the loop simply never ran and the render reported perfect silence,
    // which is the worst way for a test rig to be wrong.
    const long long total_frames =
        static_cast<long long>(options.seconds * options.sample_rate);
    const long long blocks = (total_frames + options.block - 1) / options.block;
    // Notes hold for three quarters of the render, so a release tail has room to be
    // heard — a synth that only sounds while gated still registers, and one that rings
    // out is captured doing it.
    const long long release_block = blocks * 3 / 4;

    const int channels = plugin->channel_count();
    std::vector<std::vector<float>> buffers(static_cast<std::size_t>(channels),
                                            std::vector<float>(options.block, 0.0f));

    soundgraph::AudioFile rendered;
    rendered.sample_rate = static_cast<int>(options.sample_rate);
    rendered.channels = channels;
    // Only kept when it is going to be written: a long render otherwise grows a buffer
    // the size of its own output for no reason, and --timeout invites long renders.
    const bool keep_audio = !options.wav_path.empty();
    if (keep_audio) {
        rendered.samples.reserve(static_cast<std::size_t>(blocks) * options.block * channels);
    }

    for (int key : options.notes) plugin->queue_note(key, true);

    double sum_of_squares = 0.0;
    double peak = 0.0;
    long long sample_count = 0;
    for (long long block = 0; block < blocks; ++block) {
        if (block == release_block) {
            for (int key : options.notes) plugin->queue_note(key, false);
        }
        if (!plugin->process(options.block, buffers)) {
            std::printf("sg-host: the plugin refused to process block %lld\n", block);
            plugin->deactivate();
            return 1;
        }
        plugin->main_thread_tick();
        if (block == 0 && !options.params.empty()) {
            // The first block is where a parameter change becomes a request for
            // main-thread work — a patch swap, in SoundGraph's case. Formats that
            // defer that work to a wall-clock timer need real time to pass before the
            // rest of the render can see the result, and an offline render is far too
            // fast to give it any by accident.
            plugin->settle(kSettleMilliseconds);
        }

        for (int frame = 0; frame < options.block; ++frame) {
            for (int c = 0; c < channels; ++c) {
                const float sample = buffers[static_cast<std::size_t>(c)][frame];
                if (keep_audio) rendered.samples.push_back(sample);
                sum_of_squares += static_cast<double>(sample) * sample;
                peak = std::max(peak, static_cast<double>(std::fabs(sample)));
                ++sample_count;
            }
        }
    }

    const double rms = std::sqrt(sum_of_squares / std::max(sample_count, 1LL));
    std::printf("  rendered %.2fs at %g Hz, %d channel(s): rms %f, peak %f\n", options.seconds,
                options.sample_rate, channels, rms, peak);

    if (!options.wav_path.empty()) {
        if (!soundgraph::write_wav_float(options.wav_path, rendered, error)) {
            std::printf("sg-host: %s\n", error.c_str());
            plugin->deactivate();
            return 1;
        }
        std::printf("  wrote %s\n", options.wav_path.c_str());
    }

    // After the render rather than before it, so that a --param has actually travelled
    // through a process call — and, for a format that defers that work to a timer,
    // through the settle that follows it. State written any earlier would be the state
    // the plugin had when it was opened, which is the one nobody asked for.
    if (!options.save_state_path.empty()) {
        std::string bytes;
        if (!plugin->save_state(bytes)) {
            std::printf("sg-host: this plugin has no state to give\n");
            plugin->deactivate();
            return 1;
        }
        if (!write_file(options.save_state_path, bytes)) {
            std::printf("sg-host: could not write %s\n", options.save_state_path.c_str());
            plugin->deactivate();
            return 1;
        }
        std::printf("  wrote %zu bytes of state to %s\n", bytes.size(),
                    options.save_state_path.c_str());
    }

    plugin->deactivate();

    if (options.rms_min >= 0.0 && rms < options.rms_min) {
        std::printf("sg-host: rms %f is below the required %f — the plugin is silent\n", rms,
                    options.rms_min);
        return 1;
    }
    return 0;
}
