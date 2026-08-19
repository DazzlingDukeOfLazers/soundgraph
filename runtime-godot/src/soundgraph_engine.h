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
    int fill_playback(const godot::Ref<godot::AudioStreamGeneratorPlayback>& playback,
                      int max_frames);

    double get_peak() const { return peak_; }

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
