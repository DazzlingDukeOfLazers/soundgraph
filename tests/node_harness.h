// Runs a single node in isolation, so that node tests do not depend on the scheduler.
#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "soundgraph/soundgraph.h"

namespace testing {

// Every type any jig has actually built, recorded as it happens.
//
// The alternative was a hand-written list of "types that have a jig", which is the shape
// of bug this project keeps paying for: two things that must agree, and nothing that
// notices when they stop. Here there is nothing to keep in step — building a node is what
// counts as covering it, so a node type nobody exercises cannot be mistaken for one that
// somebody does. `every_node_type_has_a_jig` compares this against the registry once the
// suite has run.
inline std::vector<std::string>& exercised_types() {
    static std::vector<std::string> types;
    return types;
}

// Whether building a node counts as covering it.
//
// The smoke test builds every registered type to check it starts up and produces finite
// samples at its defaults, which is worth having and is not a jig — if it counted, the
// coverage check would be satisfied by its own existence and would be measuring nothing.
// Everything else counts.
enum class Coverage { Jig, SmokeTest };

class NodeHarness {
public:
    NodeHarness(const std::string& type_name, int frames, double sample_rate = 48000.0,
                Coverage coverage = Coverage::Jig)
        : frames_(frames), sample_rate_(sample_rate) {
        if (coverage == Coverage::Jig) {
            exercised_types().push_back(type_name);
        }
        type_ = soundgraph::NodeRegistry::builtin().find(type_name);
        node_ = soundgraph::NodeRegistry::builtin().create(type_name);
        if (type_ == nullptr || !node_) {
            return;
        }
        inputs_.resize(static_cast<std::size_t>(type_->inputs.size()));
        for (auto& buffer : inputs_) {
            buffer.assign(static_cast<std::size_t>(frames), 0.0f);
        }
        outputs_.resize(static_cast<std::size_t>(type_->outputs.size()));
        for (auto& buffer : outputs_) {
            buffer.assign(static_cast<std::size_t>(frames), 0.0f);
        }
        connected_.assign(inputs_.size(), false);

        soundgraph::PrepareContext context;
        context.sample_rate = sample_rate;
        context.max_block_size = frames;
        node_->prepare(context);
    }

    bool valid() const { return type_ != nullptr && node_ != nullptr; }

    // Sets one controller on the surface the harness hands to process(), the way
    // the graph does. Until the first set, process() sees no surface at all.
    void set_cc(int cc, float value) {
        if (!cc_touched_) {
            cc_values_.fill(-1.0f);
            cc_touched_ = true;
        }
        if (cc >= 0 && cc <= 128) {
            cc_values_[static_cast<std::size_t>(cc)] = value;
        }
    }

    // Re-prepares with a sample buffer bound, the way the graph binds one to a node
    // whose description names it. For testing buffer-fed nodes without a graph.
    void bind_buffer(const std::vector<float>& samples, double buffer_rate = 8000.0) {
        buffer_ = samples;
        soundgraph::PrepareContext context;
        context.sample_rate = sample_rate_;
        context.max_block_size = frames_;
        context.buffer_data = buffer_.data();
        context.buffer_frames = static_cast<int>(buffer_.size());
        context.buffer_sample_rate = buffer_rate;
        node_->prepare(context);
    }

    // Re-prepares with a hosted plugin bound, the twin of bind_buffer: the graph
    // resolves one and hands it down, and a test can hand down whatever it likes. The
    // caller owns the instance and must outlive the harness.
    void bind_plugin(soundgraph::HostedPluginInstance* plugin) {
        soundgraph::PrepareContext context;
        context.sample_rate = sample_rate_;
        context.max_block_size = frames_;
        context.plugin = plugin;
        node_->prepare(context);
    }

    // Notes, delivered the way the graph delivers them: on the audio thread, before
    // the block they belong to. Only nodes whose descriptor sets receives_notes are
    // offered these, which the graph enforces and a jig may simply rely on.
    void note_on(int note, float velocity) {
        soundgraph::NoteEvent event;
        event.kind = soundgraph::NoteEvent::Kind::NoteOn;
        event.note = note;
        event.velocity = velocity;
        node_->handle_note_event(event);
    }

    void note_off(int note) {
        soundgraph::NoteEvent event;
        event.kind = soundgraph::NoteEvent::Kind::NoteOff;
        event.note = note;
        node_->handle_note_event(event);
    }

    // An input only counts as connected once it has been filled; that distinction is
    // exactly what the nodes key their parameter fallbacks off.
    void connect(const std::string& port, float value) {
        const int index = port_index(port);
        if (index < 0) return;
        connected_[static_cast<std::size_t>(index)] = true;
        for (float& sample : inputs_[static_cast<std::size_t>(index)]) {
            sample = value;
        }
    }

    std::vector<float>& input(const std::string& port) {
        const int index = port_index(port);
        connected_[static_cast<std::size_t>(index)] = true;
        return inputs_[static_cast<std::size_t>(index)];
    }

    // Writes an output buffer before process() runs.
    //
    // Only AudioInput needs this, and it needs it because it is the one node whose input
    // arrives through its outputs: the runtime writes the host's samples straight into
    // them and the node only scales what is already there. Without a way to say "the host
    // put this here", the node cannot be exercised at all.
    void fill_output(const std::string& port, float value) {
        const int index = type_->find_output(port.c_str());
        if (index < 0) return;
        for (float& sample : outputs_[static_cast<std::size_t>(index)]) {
            sample = value;
        }
    }

    void set(const std::string& parameter, float value) {
        const int index = type_->find_parameter(parameter.c_str());
        if (index >= 0) {
            node_->set_parameter(index, value);
        }
    }

    void process() { process(frames_); }

    void process(int frames) {
        const float* input_pointers[soundgraph::kMaxInputs] = {};
        float* output_pointers[soundgraph::kMaxOutputs] = {};
        for (std::size_t i = 0; i < inputs_.size(); ++i) {
            input_pointers[i] = connected_[i] ? inputs_[i].data() : nullptr;
        }
        for (std::size_t i = 0; i < outputs_.size(); ++i) {
            output_pointers[i] = outputs_[i].data();
        }

        soundgraph::ProcessContext context;
        context.frames = frames;
        context.sample_rate = sample_rate_;
        context.inputs = input_pointers;
        context.outputs = output_pointers;
        if (cc_touched_) {
            context.cc_values = cc_values_.data();
        }
        node_->process(context);
    }

    const std::vector<float>& output(int index = 0) const {
        return outputs_[static_cast<std::size_t>(index)];
    }

    const std::vector<float>& output(const std::string& port) const {
        return outputs_[static_cast<std::size_t>(type_->find_output(port.c_str()))];
    }

    soundgraph::DspNode& node() { return *node_; }

private:
    int port_index(const std::string& port) const { return type_->find_input(port.c_str()); }

    const soundgraph::NodeTypeDescriptor* type_ = nullptr;
    std::unique_ptr<soundgraph::DspNode> node_;
    std::vector<std::vector<float>> inputs_;
    std::vector<std::vector<float>> outputs_;
    std::vector<bool> connected_;
    int frames_ = 0;
    double sample_rate_ = 48000.0;
    std::vector<float> buffer_;
    std::array<float, 129> cc_values_{};
    bool cc_touched_ = false;
};

// Common measurements used across node tests.
inline float peak(const std::vector<float>& samples) {
    float result = 0.0f;
    for (float sample : samples) {
        result = std::max(result, std::fabs(sample));
    }
    return result;
}

inline double mean(const std::vector<float>& samples) {
    if (samples.empty()) return 0.0;
    double total = 0.0;
    for (float sample : samples) {
        total += sample;
    }
    return total / static_cast<double>(samples.size());
}

inline double rms(const std::vector<float>& samples) {
    if (samples.empty()) return 0.0;
    double total = 0.0;
    for (float sample : samples) {
        total += static_cast<double>(sample) * sample;
    }
    return std::sqrt(total / static_cast<double>(samples.size()));
}

// Counts rising zero crossings, which gives the frequency of a periodic signal without
// needing an FFT.
inline int rising_zero_crossings(const std::vector<float>& samples) {
    int count = 0;
    for (std::size_t i = 1; i < samples.size(); ++i) {
        if (samples[i - 1] < 0.0f && samples[i] >= 0.0f) {
            ++count;
        }
    }
    return count;
}

}  // namespace testing
