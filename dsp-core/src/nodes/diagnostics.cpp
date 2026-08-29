// Nodes that exist to look at the editor rather than to make sound.
//
// The first resident is CableTest: eight lanes straight through, built for staring at
// patch cables. Eight matters — it is the width of the candy palette the editor walks
// when this node feeds a cable, so two of these wired straight across show every cable
// colour the system has, once each, in order. A rendering change that costs a colour
// its identity shows up here as two cables that suddenly match.
//
// It lives in dsp-core because the schema is the contract: a patch that uses CableTest
// has to load, validate and run everywhere a patch runs, firmware included. The DSP is
// honest passthrough — silence in, silence out, signal in, signal out — so leaving one
// in a patch costs eight buffer copies and nothing else.

#include <memory>

#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

constexpr PortDescriptor kCableTestInputs[] = {
    {"in1", SignalType::Audio, "", false, false, "Lane 1, passed straight to out1."},
    {"in2", SignalType::Audio, "", false, false, "Lane 2, passed straight to out2."},
    {"in3", SignalType::Audio, "", false, false, "Lane 3, passed straight to out3."},
    {"in4", SignalType::Audio, "", false, false, "Lane 4, passed straight to out4."},
    {"in5", SignalType::Audio, "", false, false, "Lane 5, passed straight to out5."},
    {"in6", SignalType::Audio, "", false, false, "Lane 6, passed straight to out6."},
    {"in7", SignalType::Audio, "", false, false, "Lane 7, passed straight to out7."},
    {"in8", SignalType::Audio, "", false, false, "Lane 8, passed straight to out8."},
};

constexpr PortDescriptor kCableTestOutputs[] = {
    {"out1", SignalType::Audio, "", false, false, "Lane 1. A cable from here wears cable colour 1."},
    {"out2", SignalType::Audio, "", false, false, "Lane 2. A cable from here wears cable colour 2."},
    {"out3", SignalType::Audio, "", false, false, "Lane 3. A cable from here wears cable colour 3."},
    {"out4", SignalType::Audio, "", false, false, "Lane 4. A cable from here wears cable colour 4."},
    {"out5", SignalType::Audio, "", false, false, "Lane 5. A cable from here wears cable colour 5."},
    {"out6", SignalType::Audio, "", false, false, "Lane 6. A cable from here wears cable colour 6."},
    {"out7", SignalType::Audio, "", false, false, "Lane 7. A cable from here wears cable colour 7."},
    {"out8", SignalType::Audio, "", false, false, "Lane 8. A cable from here wears cable colour 8."},
};

class CableTestNode final : public DspNode {
public:
    void prepare(const PrepareContext&) override {}
    void reset() override {}

    void process(const ProcessContext& context) override {
        for (int lane = 0; lane < 8; ++lane) {
            const float* in = context.inputs[lane];
            float* out = context.outputs[lane];
            if (out == nullptr) {
                continue;
            }
            for (int i = 0; i < context.frames; ++i) {
                out[i] = in != nullptr ? in[i] : 0.0f;
            }
        }
    }
};

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

}  // namespace

const NodeTypeDescriptor kCableTest = {
    "CableTest", "Cable Test", "Utilities",
    "Eight lanes straight through. The editor colours its cables with the first eight "
    "cable colours in order, for looking at the cable rendering itself.",
    "cable|cables|test|colours|colors|palette|diagnostic|patch cords|rendering",
    Slice<PortDescriptor>(kCableTestInputs),
    Slice<PortDescriptor>(kCableTestOutputs),
    Slice<ParameterDescriptor>(),
    false, NodeRole::Processor, false,
    ResourceCost{0.5f, 0, 0},
    &make<CableTestNode>,
};

}  // namespace nodes
}  // namespace soundgraph
