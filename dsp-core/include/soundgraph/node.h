// SoundGraph — the DSP node interface.
//
// A node knows how to turn input sample streams into output sample streams. It knows
// nothing about JSON, editors, targets, or how it was scheduled.
#pragma once

#include <array>
#include <memory>

#include "soundgraph/events.h"
#include "soundgraph/types.h"

namespace soundgraph {

struct PortDescriptor {
    const char* name;
    SignalType type;
    const char* unit;      // "Hz", "s", "octaves", "" — the unit of the signal on the wire
    bool required;         // an unconnected required input is a validation error
    bool summing;          // input only: accepts several connections, summed
    const char* doc;       // how this input combines with the node's parameters
};

struct ParameterDescriptor {
    const char* name;
    const char* unit;
    float min_value;
    float max_value;
    float default_value;
    Scaling scaling;
    const char* doc;
    // Non-null for enumerated parameters. The value is the index, stored as a float so
    // that the realtime parameter API stays a single scalar type.
    const char* const* enum_labels;
    int enum_count;
};

// Rough per-node resource use, used to answer "does this patch fit on that board?".
// These are estimates, refined by measurement per target; they are advisory, never a
// gate on graph semantics.
struct ResourceCost {
    float cpu_cost;      // arbitrary units per sample, relative to a Gain node at 1.0
    int state_bytes;     // persistent state excluding I/O buffers
    int heap_bytes;      // additional memory taken at prepare() time (e.g. delay lines)
};

struct PrepareContext {
    double sample_rate = 48000.0;
    int max_block_size = kBlockSize;
};

// Everything a node is allowed to touch during processing.
//
// An unconnected input is a null pointer rather than a buffer of zeros. That distinction
// carries meaning: it lets a node fall back to its parameter value instead of being
// modulated to silence, which is what makes "drop a node and it just works" possible.
struct ProcessContext {
    int frames = 0;
    double sample_rate = 48000.0;
    const float* const* inputs = nullptr;   // kMaxInputs entries; null where unconnected
    float* const* outputs = nullptr;        // one writable buffer per declared output
};

class DspNode {
public:
    virtual ~DspNode() = default;

    // Called once before processing starts, and again whenever the sample rate changes.
    // This is where allocation is allowed. process() may not allocate.
    virtual void prepare(const PrepareContext& context) { (void)context; }

    virtual void process(const ProcessContext& context) = 0;

    // Delivered on the audio thread, before the block in which it takes effect.
    // Only nodes whose descriptor sets receives_notes are offered these.
    virtual void handle_note_event(const NoteEvent& event) { (void)event; }

    // Return to the state a freshly prepared node would be in, without reallocating.
    virtual void reset() {}

    // Parameters are stored here so that every node gets consistent clamping and
    // defaults. Nodes that cache derived values override on_parameter_changed().
    void set_parameter(int index, float value);
    float parameter(int index) const;

    // Populates parameter storage from the type descriptor. Called by the registry.
    void initialize_parameters(Slice<ParameterDescriptor> descriptors);

protected:
    virtual void on_parameter_changed(int index) { (void)index; }

    std::array<float, kMaxParameters> parameters_{};
    Slice<ParameterDescriptor> parameter_descriptors_{};
};

// Terminals exchange samples with whatever is hosting the graph. The runtime, not the
// node, owns that exchange — it is the one thing that genuinely differs per target.
enum class NodeRole {
    Processor,
    HostAudioSource,  // its outputs are filled from the host's input device
    HostAudioSink,    // its inputs are copied to the host's output device
};

struct NodeTypeDescriptor {
    const char* name;           // registry identity, as written in patch JSON
    const char* display_name;   // human label, may contain spaces
    const char* category;       // "Sources", "Filters", "Amplitude", ...
    const char* summary;        // one line, plain language

    // Alternative phrasings for intent-based search: "remove high frequencies" should
    // find StateVariableFilter without the user knowing the term. Pipe separated.
    const char* search_terms;

    Slice<PortDescriptor> inputs;
    Slice<PortDescriptor> outputs;
    Slice<ParameterDescriptor> parameters;

    // True if the node introduces at least one block of latency, which is what makes a
    // feedback loop through it well defined. See docs/decisions.md.
    bool breaks_feedback;

    NodeRole role;
    bool receives_notes;

    ResourceCost cost;

    std::unique_ptr<DspNode> (*create)();

    int find_input(const char* port_name) const;
    int find_output(const char* port_name) const;
    int find_parameter(const char* parameter_name) const;
};

}  // namespace soundgraph
