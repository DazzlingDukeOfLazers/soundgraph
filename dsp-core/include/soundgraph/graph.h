// SoundGraph — validation, scheduling and execution.
//
// This is where a patch becomes sound. Nothing above this layer is allowed to decide
// what a graph means.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "soundgraph/events.h"
#include "soundgraph/graph_description.h"
#include "soundgraph/node.h"
#include "soundgraph/registry.h"

namespace soundgraph {

// Static analysis of a patch. Requires no audio device, no sample rate, and no built
// graph — an editor can run this on every keystroke.
//
// Returns true if the patch contains no errors. Warnings do not prevent building.
bool validate(const GraphDescription& description,
              const NodeRegistry& registry,
              std::vector<Diagnostic>& diagnostics);

bool has_errors(const std::vector<Diagnostic>& diagnostics);

class Graph {
public:
    Graph();
    ~Graph();

    Graph(const Graph&) = delete;
    Graph& operator=(const Graph&) = delete;

    // Validates, resolves, orders and allocates. All allocation happens here; after a
    // successful build, rendering touches no allocator and takes no locks.
    // Returns false and fills `diagnostics` if the patch cannot be realised.
    bool build(const GraphDescription& description,
               const NodeRegistry& registry,
               const PrepareContext& context,
               std::vector<Diagnostic>& diagnostics);

    bool is_built() const { return built_; }

    // ---- realtime section -------------------------------------------------------
    // Everything below runs on the audio thread.

    // Renders `frames` frames of interleaved stereo into `destination`, which must have
    // room for frames * 2 floats. `frames` may be any size; the graph internally runs in
    // fixed kBlockSize chunks so that output does not depend on the host buffer size.
    void render_interleaved(float* destination, int frames);

    void render(float* left, float* right, int frames);

    // Host input for HostAudioSource nodes. Pointers must stay valid across the matching
    // render call. Pass null for silence. `right` may be null for a mono source.
    void set_audio_input(const float* left, const float* right, int frames);

    // Returns all nodes and all internal state to their post-prepare condition without
    // reallocating. Safe to call between blocks.
    void reset();

    // ---- control section --------------------------------------------------------
    // Safe to call from one non-audio thread. These enqueue; they never touch DSP state.

    void note_on(int note, float velocity);
    void note_off(int note);
    void all_notes_off();

    // Audio-thread only, and never at the same time as the queueing calls above: applies
    // the event immediately instead of enqueueing it. For hosts that generate notes
    // inside the callback — sequencers, arpeggiators, a MIDI driver that runs there — so
    // that the control queue keeps its single producer.
    void dispatch_note(const NoteEvent& event);

    // Returns false if the node or parameter does not exist. Resolve the indices once
    // with node_index()/parameter_index() if you are going to move a knob continuously.
    bool set_parameter(const std::string& node_id, const std::string& parameter_name, float value);
    void set_parameter(int node_index, int parameter_index, float value);

    int node_index(const std::string& node_id) const;
    int parameter_index(int node_index, const std::string& parameter_name) const;

    // ---- inspection -------------------------------------------------------------

    double sample_rate() const { return sample_rate_; }
    int node_count() const { return static_cast<int>(nodes_.size()); }
    const std::string& node_id(int index) const;
    const NodeTypeDescriptor* node_type(int index) const;

    // The order in which nodes actually execute, as node indices. Useful for teaching
    // and for debugging scheduling problems.
    const std::vector<int>& execution_order() const { return order_; }

    // Which connections were resolved as feedback edges, i.e. deliver the previous
    // block's samples. Indices into the description's connection list.
    const std::vector<int>& feedback_connections() const { return feedback_connections_; }

    // Aggregate resource estimate, for answering "does this fit on that board?".
    ResourceCost estimated_cost() const;

    // The most recent block of output, for meters and waveform inspection.
    const float* master_left() const { return master_left_.data(); }
    const float* master_right() const { return master_right_.data(); }

private:
    struct InputBinding {
        // Resolved sources for one input port.
        std::vector<int> source_buffers;   // buffer indices; empty means unconnected
        int mix_buffer = -1;               // scratch for summing, or feedback snapshot
        bool is_feedback = false;
    };

    struct NodeSlot {
        std::string id;
        const NodeTypeDescriptor* type = nullptr;
        std::unique_ptr<DspNode> node;
        std::vector<InputBinding> inputs;
        std::vector<int> output_buffers;
    };

    float* buffer(int index);
    const float* buffer(int index) const;
    int allocate_buffer();

    void process_block();
    void drain_control_events();
    void snapshot_feedback();
    // Ensures the block FIFO has samples available, processing another block if not.
    void fill_pending();

    bool built_ = false;
    double sample_rate_ = 48000.0;

    std::vector<NodeSlot> nodes_;
    std::vector<int> order_;
    std::vector<int> feedback_connections_;
    std::vector<int> host_source_nodes_;
    std::vector<int> host_sink_nodes_;
    std::vector<int> note_receiver_nodes_;

    // One flat allocation; buffers are kBlockSize-sized windows into it. Keeping them
    // contiguous keeps the working set small, which matters on ESP32.
    std::vector<float> buffer_pool_;
    int buffer_count_ = 0;

    // The graph always runs whole kBlockSize blocks and hands the host whatever it asked
    // for out of this FIFO. Without it, a host using a buffer size that is not a multiple
    // of the block size would shift every block-rate decision — and golden vectors would
    // stop being comparable across hosts and targets.
    std::vector<float> master_left_;
    std::vector<float> master_right_;
    int pending_read_ = kBlockSize;  // == kBlockSize means "nothing buffered"

    const float* host_input_left_ = nullptr;
    const float* host_input_right_ = nullptr;
    int host_input_frames_ = 0;
    int host_input_offset_ = 0;

    ControlQueue control_queue_;
    ResourceCost cost_{};
};

}  // namespace soundgraph
