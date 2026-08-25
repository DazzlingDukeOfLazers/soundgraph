// Somebody else's plugin, as far as the core is concerned.
//
// dsp-core describes the node; the runtime supplies the plugin. That split is not new
// here — it is what terminals already do, where the core fully describes a
// HostAudioSource it cannot possibly implement and the runtime moves the samples. A
// hosted plugin has the same shape, so it arrives the same way: resolved by the graph
// before prepare(), handed down through PrepareContext, exactly as a sampler's buffer
// is.
//
// Nothing in this header knows what a DLL is. That is the point: LoadLibrary, bundles,
// COM and clap_entry live in the desktop runtime, and the core keeps its promise to
// depend on nothing but the standard library. A target with no plugins simply has no
// provider, which is a fact rather than an error.
//
// See docs/hosted-plugins-design.md.
#pragma once

#include <memory>
#include <string>
#include <vector>

namespace soundgraph {

// What a patch asks for. Identity is the question; everything else is a hint that
// makes a failure readable, and no hint is ever the thing looked up — a path is a fine
// thing to remember and a terrible thing to depend on.
struct PluginRequest {
    std::string format;     // "CLAP" or "VST3"
    std::string identity;   // format-native unique id: reverse-DNS, or a VST3 class UID
    std::string vendor;     // hint
    std::string name;       // hint
    std::string path_hint;  // hint
    std::string state;      // the plugin's own opaque state, empty for its defaults
    // Slot index to the plugin's own parameter id; -1 for an unbound slot. The provider
    // needs these because it, not the node, knows how to speak to that plugin — the
    // node only ever counts from zero.
    std::vector<int> slots;
};

// One loaded, activated plugin. The runtime hands these out; the node just uses one.
//
// Deliberately narrower than the plugin formats themselves: audio in, audio out,
// controls, and notes. An effect never receives the last of those, which is why they
// are virtual rather than pure.
class HostedPluginInstance {
public:
    virtual ~HostedPluginInstance() = default;

    // Called from prepare(), where allocation is allowed.
    virtual void prepare(double sample_rate, int max_block_frames) = 0;

    // Called from the audio thread. Buffers are the graph's; the plugin may write only
    // to `outputs`, and `frames` never exceeds the max_block_frames it was prepared
    // with. A hosted plugin makes no promise about allocation or locking — see the
    // design doc, which says so out loud rather than pretending otherwise.
    virtual void process(const float* const* inputs, int input_channels,
                         float* const* outputs, int output_channels, int frames) = 0;

    // Slot 0..n, always normalised 0..1, whatever the plugin's own range is. The node
    // sends these only when they change.
    virtual void set_control(int slot, float value) = 0;

    // Notes, for an instrument. One instance receives all of them — the plugin does
    // its own voice allocation, which is the whole reason it is not cloned per voice.
    virtual void note_on(int note, float velocity) { (void)note; (void)velocity; }
    virtual void note_off(int note) { (void)note; }
    virtual void all_notes_off() {}

    // Reported, and not yet compensated for. See the design doc.
    virtual int latency_frames() const { return 0; }

    // ---- the plugin's own face --------------------------------------------------
    // A hosted plugin usually draws itself, and an editor that can only offer sixteen
    // numbered slots has hidden the instrument behind a mixing desk. So the editor
    // lends the plugin a window and the plugin fills it.
    //
    // `parent` is a platform window handle — an HWND, an NSView, an X11 window id —
    // and nothing in this file looks at it. That is what keeps the promise: the core
    // still knows no more about windows than it does about DLLs, and the handle passes
    // from whoever owns a window to whoever can draw in one without either end being
    // named here.
    //
    // Every one of these has a do-nothing default, because most of the world has no
    // answer: a plugin with no editor, a runtime with no windows, an ESP32. Not
    // showing an editor is an ordinary outcome and never an error.
    virtual bool has_gui() { return false; }
    virtual bool open_gui(void* parent) { (void)parent; return false; }
    virtual void close_gui() {}
    virtual bool gui_size(int& width, int& height) {
        (void)width;
        (void)height;
        return false;
    }

    // The host's main thread, between blocks. An open editor is the reason this
    // matters: a plugin that has been clicked defers the work to its main thread and
    // waits, and a host that never offers one leaves the editor half-dead — knobs that
    // move and a sound that does not follow. Whoever owns the window calls this.
    virtual void main_thread_tick() {}
};

// How a runtime offers plugins. A target that has none has no provider, and a graph
// with no provider still builds — the effect passes its audio through untouched, and
// the patch says so once rather than failing.
class PluginProvider {
public:
    virtual ~PluginProvider() = default;

    // Null is a legitimate answer: "not on this machine", or "not on this target".
    // The graph turns it into a diagnostic, never into a build failure.
    virtual std::unique_ptr<HostedPluginInstance> acquire(const PluginRequest& request) = 0;
};

}  // namespace soundgraph
