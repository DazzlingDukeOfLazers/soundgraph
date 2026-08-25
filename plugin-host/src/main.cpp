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

// Long enough for a 20 ms timer to fire twice, which is what clap-wrapper's VST3 shim
// needs to deliver deferred main-thread work. Paid once per run, never per block.
constexpr int kSettleMilliseconds = 60;

struct Options {
    std::string plugin_path;
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
        "  --env NAME=VALUE       set an environment variable first, repeatable\n");
}

bool ends_with(const std::string& text, const std::string& suffix) {
    if (text.size() < suffix.size()) return false;
    return std::equal(suffix.rbegin(), suffix.rend(), text.rbegin(),
                      [](char a, char b) { return std::tolower(a) == std::tolower(b); });
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
        } else if (arg == "--timeout") {
            const char* v = value("--timeout");
            if (!v) return false;
            options.timeout = std::atoi(v);
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

    plugin->deactivate();

    if (options.rms_min >= 0.0 && rms < options.rms_min) {
        std::printf("sg-host: rms %f is below the required %f — the plugin is silent\n", rms,
                    options.rms_min);
        return 1;
    }
    return 0;
}
