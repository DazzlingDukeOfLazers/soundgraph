// Runs a single node in isolation, so that node tests do not depend on the scheduler.
#pragma once

#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "soundgraph/soundgraph.h"

namespace testing {

class NodeHarness {
public:
    NodeHarness(const std::string& type_name, int frames, double sample_rate = 48000.0)
        : frames_(frames), sample_rate_(sample_rate) {
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
