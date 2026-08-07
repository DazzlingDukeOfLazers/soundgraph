#include "soundgraph/node.h"

#include <algorithm>
#include <cstring>

namespace soundgraph {

void DspNode::initialize_parameters(Slice<ParameterDescriptor> descriptors) {
    parameter_descriptors_ = descriptors;
    for (int i = 0; i < descriptors.size() && i < kMaxParameters; ++i) {
        parameters_[static_cast<std::size_t>(i)] = descriptors[i].default_value;
    }
    for (int i = 0; i < descriptors.size() && i < kMaxParameters; ++i) {
        on_parameter_changed(i);
    }
}

void DspNode::set_parameter(int index, float value) {
    if (index < 0 || index >= kMaxParameters || index >= parameter_descriptors_.size()) {
        return;
    }
    const ParameterDescriptor& descriptor = parameter_descriptors_[index];
    // Clamping here rather than at the call site means a malformed patch or a runaway
    // automation lane cannot put a node into an undefined state.
    const float clamped = std::min(std::max(value, descriptor.min_value), descriptor.max_value);
    parameters_[static_cast<std::size_t>(index)] = clamped;
    on_parameter_changed(index);
}

float DspNode::parameter(int index) const {
    if (index < 0 || index >= kMaxParameters) {
        return 0.0f;
    }
    return parameters_[static_cast<std::size_t>(index)];
}

int NodeTypeDescriptor::find_input(const char* port_name) const {
    for (int i = 0; i < inputs.size(); ++i) {
        if (std::strcmp(inputs[i].name, port_name) == 0) {
            return i;
        }
    }
    return -1;
}

int NodeTypeDescriptor::find_output(const char* port_name) const {
    for (int i = 0; i < outputs.size(); ++i) {
        if (std::strcmp(outputs[i].name, port_name) == 0) {
            return i;
        }
    }
    return -1;
}

int NodeTypeDescriptor::find_parameter(const char* parameter_name) const {
    for (int i = 0; i < parameters.size(); ++i) {
        if (std::strcmp(parameters[i].name, parameter_name) == 0) {
            return i;
        }
    }
    return -1;
}

}  // namespace soundgraph
