// What sg-host needs from a plugin, whatever format it arrived in.
//
// CLAP and VST3 disagree about almost everything at the call level — one passes plain
// values in a declared range, the other normalises everything to 0..1; one takes an
// event list of structs, the other an IEventList interface; one is a C API, the other
// COM. They agree about the shape of the job: tell me your parameters, take a block of
// notes, hand back audio. That agreement is this header, and it is the only thing
// main.cpp knows about.
#pragma once

#include <memory>
#include <string>
#include <vector>

namespace soundgraph::host {

// A parameter as the host sees it. `minimum`/`maximum` are the range this plugin's
// format actually accepts from a host: plain units for CLAP, normalised 0..1 for VST3,
// which is why --param takes the number in the range printed by --list rather than a
// unit this host would have to invent a conversion for.
struct Parameter {
    uint32_t id = 0;
    std::string name;
    std::string module;  // the group a format offers, if any: patch name, folder, unit
    double minimum = 0.0;
    double maximum = 1.0;
    double default_value = 0.0;
    bool hidden = false;
};

struct PluginDescription {
    std::string id;
    std::string name;
    std::string vendor;
    std::string format;  // "CLAP" or "VST3", as printed
};

// One loaded, instantiated plugin. Construction has already happened by the time a
// caller holds one of these: a null return from the open functions below means the
// failure has been reported, not that the caller should keep going.
class HostedPlugin {
public:
    virtual ~HostedPlugin() = default;

    virtual const std::vector<PluginDescription>& available() const = 0;
    virtual const PluginDescription& chosen() const = 0;
    virtual std::vector<Parameter> parameters() const = 0;
    virtual int channel_count() const = 0;

    virtual bool activate(double sample_rate, int block_frames, std::string& error) = 0;
    virtual void deactivate() = 0;

    // Queued for the next process() call, which is where both formats want them.
    virtual void queue_parameter(uint32_t id, double value) = 0;
    virtual void queue_note(int key, bool on) = 0;

    // Renders one block into `channels`, each of which already has block_frames of
    // room. Returns false only when the plugin refused outright.
    virtual bool process(int frames, std::vector<std::vector<float>>& channels) = 0;

    // Between blocks: the host's main thread. Formats that ask for a callback from
    // the audio thread — CLAP's request_callback, and anything a VST3 defers — get
    // answered here, which is the promise a real host makes.
    virtual void main_thread_tick() = 0;

    // Gives the plugin its main thread for up to `milliseconds` of *wall clock*.
    //
    // This exists because deferred main-thread work is not always delivered on demand:
    // clap-wrapper's VST3 shim services it from a 20 ms WM_TIMER on a hidden window,
    // so the work only lands if a host both pumps its message loop and lets real time
    // pass. An offline render outruns that timer — a second of audio finishes in a few
    // milliseconds — and the deferred work is simply never done, which looks exactly
    // like a plugin ignoring the request. A real DAW never notices because its message
    // loop has been running all along.
    virtual void settle(int milliseconds) = 0;
};

// Loads and instantiates plugin `index` from the file at `path`. Returns null and
// fills `error` on any failure: unreadable file, wrong format, missing entry point,
// refused init.
std::unique_ptr<HostedPlugin> open_clap(const std::string& path, int index,
                                        std::string& error);
std::unique_ptr<HostedPlugin> open_vst3(const std::string& path, int index,
                                        std::string& error);

}  // namespace soundgraph::host
