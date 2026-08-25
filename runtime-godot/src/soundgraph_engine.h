// SoundGraph — the Godot binding.
//
// Godot is a UI and education frontend, not a graph authority (docs/ARCHITECTURE.md).
// So this class holds no DSP and no graph semantics of its own: it is a translation layer
// between Godot types and the same dsp-core that the native host and the browser use.
//
// Anything the editor needs to know about a patch — the node vocabulary, whether a
// connection is legal, what is wrong with a graph, what a wire currently carries — is
// answered here by asking the core, never by reimplementing it in GDScript. That is the
// whole reason this extension exists rather than a pure-GDScript editor.
#pragma once

#include <godot_cpp/classes/audio_stream_generator_playback.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <memory>
#include <vector>

#include "soundgraph/soundgraph.h"

namespace soundgraph_godot {

class SoundGraphEngine : public godot::RefCounted {
    GDCLASS(SoundGraphEngine, godot::RefCounted)

public:
    SoundGraphEngine();
    ~SoundGraphEngine() override;

    // ---- editor-side questions, no audio required ---------------------------------

    // The node vocabulary as JSON: ports, types, units, ranges, enums, categories and
    // search terms. The editor builds its whole palette and its connection type checking
    // from this, so adding a node to the core makes it appear in Godot with no GDScript
    // change at all.
    godot::String get_registry_json() const;

    // Intent-based search over that vocabulary, scored by the core. Returns type names,
    // best match first. Shared with the command line tools so "remove high frequencies"
    // means the same thing everywhere.
    godot::PackedStringArray search_nodes(const godot::String& query) const;

    // {"ok": bool, "diagnostics": [...]}. Cheap enough to call on every edit.
    godot::String validate_patch(const godot::String& patch_json) const;

    /// A fingerprint of the graph this patch flattens to: every node, its type and its
    /// parameter values, and every connection, in a fixed order. Two documents with the
    /// same fingerprint build the same engine graph, so an edit that leaves it unchanged
    /// need not reload. Empty when the patch will not parse.
    godot::String flatten_patch(const godot::String& patch_json) const;

    // Re-writes a patch through the core's own serialiser, which is what every saved
    // patch should go through. Godot's JSON.stringify sorts keys alphabetically and
    // renders every number as a float — so a saved patch would arrive with
    // "schema_version": 1.0 and its fields shuffled. The patch format is the product;
    // it should not degrade just because of which editor wrote it.
    // Returns the input unchanged if it cannot be parsed.
    godot::String format_patch(const godot::String& patch_json) const;

    // ---- the live graph -------------------------------------------------------------

    // Builds the patch at the given sample rate. Returns false if it cannot be realised;
    // get_diagnostics_json() then says why, naming the nodes involved.
    bool load_patch(const godot::String& patch_json, double sample_rate);

    bool is_loaded() const { return loaded_; }

    godot::String get_diagnostics_json() const;

    // Execution order, feedback edges and the resource estimate, as JSON.
    godot::String get_info_json() const;

    // ---- performing -----------------------------------------------------------------

    void note_on(int note, double velocity);
    void note_off(int note);
    void all_notes_off();
    void reset();

    bool set_parameter(const godot::String& node_id, const godot::String& parameter, double value);

    // ---- audio ----------------------------------------------------------------------

    // Renders into the playback buffer and returns how many frames were pushed. Call it
    // from _process with get_frames_available(); the buffer plumbing stays in C++ so
    // GDScript never touches a sample.
    godot::PackedFloat32Array render_block(int frames);
    godot::PackedByteArray lpc_encode(const godot::PackedFloat32Array& samples,
                                      float sample_rate);
    void control_change(int cc, float value);
    int fill_playback(const godot::Ref<godot::AudioStreamGeneratorPlayback>& playback,
                      int max_frames);

    double get_peak() const { return peak_; }

    // ---- hosted plugins ---------------------------------------------------------------
    // Somebody else's plugin, playing inside this graph. The editor picks one with
    // plugin_picker.gd and the patch names it; everything below is about the running
    // instance rather than the document.
    //
    // The provider lives here, in the extension, and not in the editor's GDScript,
    // because a plugin has to be in the process that owns the audio graph. Scanning
    // stays out of process — sg-host --scan opens every plugin on the machine, which is
    // exactly the act that hangs — but a plugin being *played* cannot be at the far end
    // of a pipe.

    // Whether this build can host at all. False on the web, false in a clone that has
    // not fetched the SDKs, and worth asking before offering the user a button.
    bool can_host_plugins() const;

    // Whether the plugin this node plays through draws an editor. False for a node with
    // no plugin, for a plugin this machine does not have, and for one that has no face.
    bool plugin_has_gui(const godot::String& node_id);

    // Lends the plugin a window to draw in, and returns whether it took it.
    //
    // `window_handle` is what DisplayServer.window_get_native_handle(WINDOW_HANDLE, id)
    // gives for a Godot Window — an HWND on Windows, an NSView on macOS. It travels from
    // there through dsp-core, which never looks at it, to the loader, which knows what
    // it is. Give it a window of its own rather than the main one: the plugin fills
    // whatever it is handed, corner to corner.
    bool open_plugin_gui(const godot::String& node_id, int64_t window_handle);
    void close_plugin_gui(const godot::String& node_id);

    // The size the plugin asks for, in pixels; zero when it will not say. Only
    // meaningful once the editor is open, which is the plugin's rule and not ours.
    godot::Vector2i plugin_gui_size(const godot::String& node_id);

    // Every hosted plugin gets the main thread, once. Call it from _process: a plugin
    // that has been clicked defers work and waits, so an editor nobody ticks is one
    // whose knobs move and whose sound does not follow.
    void tick_plugins();

    // ---- inspection ------------------------------------------------------------------

    // Recent output history, for a scope. Newest sample last.
    godot::PackedFloat32Array get_scope(int samples) const;

    // What a particular wire is carrying right now: the most recent block produced by
    // that output port. Empty if the node or port does not exist.
    godot::PackedFloat32Array get_port_signal(const godot::String& node_id,
                                              const godot::String& port) const;

    // ---- the probe scope -------------------------------------------------------------
    // An external instrument: point the tap at any output port and the fill loop
    // captures a contiguous ring of that wire, block by block — get_port_signal alone
    // only ever shows the latest block, which cannot hold a waveform. The gate is a
    // second tap for triggered capture. An empty node id puts a probe away. Taps
    // survive a reload: the names are kept and re-resolved against the new graph.
    bool set_scope_tap(const godot::String& node_id, const godot::String& port);
    bool set_scope_gate(const godot::String& node_id, const godot::String& port);
    godot::PackedFloat32Array get_scope_tap(int samples) const;
    godot::PackedFloat32Array get_scope_gate(int samples) const;
    // Rising edges each tap has seen since it was armed: the trigger counter.
    int get_scope_tap_edges() const;
    int get_scope_gate_edges() const;

protected:
    static void _bind_methods();

private:
    void push_scope(const float* samples, int count);
    void resolve_taps();
    godot::PackedFloat32Array read_tap(int slot, int samples) const;

    soundgraph::Graph graph_;
    soundgraph::GraphDescription description_;

    // Built once and outliving every graph, because the graph borrows it. Null when
    // this build cannot host plugins, which the core already treats as ordinary.
    std::unique_ptr<soundgraph::PluginProvider> plugin_provider_;
    // The one node whose editor is open, so that a reload or a teardown can close it.
    // A plugin left drawing into a window that has been freed is a crash with nothing
    // of ours on the stack.
    std::string open_gui_node_;
    std::string diagnostics_json_ = "[]";
    std::string info_json_ = "{}";
    bool loaded_ = false;
    double peak_ = 0.0;

    // Interleaved staging buffer for the playback push. Sized once so that filling a
    // buffer never allocates.
    std::vector<float> left_;
    std::vector<float> right_;
    godot::PackedVector2Array frames_;

    // Ring of recent output for the scope display.
    std::vector<float> scope_;
    int scope_write_ = 0;

    // The probe scope's taps: names as the user gave them, indices as the current
    // graph resolves them (-1 when unset or unresolvable), and the capture rings.
    std::string tap_node_, tap_port_name_, gate_node_, gate_port_name_;
    int tap_index_ = -1;
    int tap_port_index_ = -1;
    int gate_index_ = -1;
    int gate_port_index_ = -1;
};

}  // namespace soundgraph_godot
