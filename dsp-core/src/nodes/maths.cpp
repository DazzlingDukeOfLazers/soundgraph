// SoundGraph — the small maths family, and sample-and-hold.
//
// Add and Multiply carried the whole Maths category for a long time, and the gap showed
// up as patches that couldn't say ordinary things: "no lower than", "only when", "the
// size of". Each node here is one of those sentences. They are all a few operations per
// sample, cheap enough for the firmware, and none of them allocate.
//
// SampleHold lives here too rather than in sources.cpp: it is the stepped half of
// modulation. There is deliberately no Random node — the LFO's random shape is the
// free-running case, and Noise into SampleHold is the clocked, seedable one.

#include <algorithm>
#include <cmath>

#include "node_types.h"
#include "soundgraph/node.h"

namespace soundgraph {
namespace nodes {
namespace {

// A gate is open at or above 0.5, matching ADSR; triggers fire on the rising edge.
// Same contract as shaping.cpp, restated here because both files must agree.
inline bool gate_open(const float* gate, int frame) {
    return gate != nullptr && gate[frame] >= 0.5f;
}

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

constexpr PortDescriptor kUnaryInputs[] = {
    {"in", SignalType::Control, "", false, true, "Signal to shape."},
};

constexpr PortDescriptor kControlOutput[] = {
    {"out", SignalType::Control, "", false, false, "Result."},
};

// ---------------------------------------------------------------------------------
// Clip
//
// clamp(in, floor, ceiling). The hard limit as a patching element: keep a modulation
// inside a range, flatten the top of a wave, guarantee a cutoff never goes negative.
// Drive is the soft, musical version of this idea; Clip is the exact one.

constexpr ParameterDescriptor kClipParameters[] = {
    {"floor", "", -100000.0f, 100000.0f, -1.0f, Scaling::Linear,
     "Nothing comes out below this.", nullptr, 0},
    {"ceiling", "", -100000.0f, 100000.0f, 1.0f, Scaling::Linear,
     "Nothing comes out above this.", nullptr, 0},
};

class ClipNode final : public DspNode {
public:
    enum Param { kFloor = 0, kCeiling = 1 };

    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        float* out = context.outputs[0];
        const float lo = parameter(kFloor);
        // A floor above the ceiling clamps everything to the floor rather than
        // crossing the limits over, so dragging one knob past the other stays sane.
        const float hi = std::max(lo, parameter(kCeiling));
        for (int i = 0; i < context.frames; ++i) {
            const float x = (in != nullptr ? in[i] : 0.0f);
            out[i] = x < lo ? lo : (x > hi ? hi : x);
        }
    }
};

// ---------------------------------------------------------------------------------
// Abs
//
// Full-wave rectification. Folds a bipolar signal upward: an LFO that only ever raises,
// an audio wave whose pitch doubles into a buzz, the first stage of an envelope follower.

class AbsNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        float* out = context.outputs[0];
        for (int i = 0; i < context.frames; ++i) {
            out[i] = std::fabs(in != nullptr ? in[i] : 0.0f);
        }
    }
};

// ---------------------------------------------------------------------------------
// MinMax
//
// The smaller or the larger of two signals, chosen by mode. min is "no higher than",
// max is "no lower than", and either of them against a moving signal is a shape the
// arithmetic nodes cannot make.

constexpr const char* kMinMaxModeLabels[] = {"minimum", "maximum"};

constexpr PortDescriptor kBinaryInputs[] = {
    {"a", SignalType::Control, "", false, true, "First input."},
    {"b", SignalType::Control, "", false, true,
     "Second input. Falls back to the parameter below while unconnected."},
};

constexpr ParameterDescriptor kMinMaxParameters[] = {
    {"mode", "", 0.0f, 1.0f, 1.0f, Scaling::Linear,
     "Which of the two signals wins.", kMinMaxModeLabels, 2},
    {"other", "", -100000.0f, 100000.0f, 0.0f, Scaling::Linear,
     "Used in place of the b input while it is unconnected.", nullptr, 0},
};

class MinMaxNode final : public DspNode {
public:
    enum Param { kMode = 0, kOther = 1 };

    void process(const ProcessContext& context) override {
        const float* a = context.inputs[0];
        const float* b = context.inputs[1];
        float* out = context.outputs[0];
        const float fallback = parameter(kOther);
        const bool take_max = parameter(kMode) >= 0.5f;
        for (int i = 0; i < context.frames; ++i) {
            const float x = (a != nullptr ? a[i] : 0.0f);
            const float y = (b != nullptr ? b[i] : fallback);
            out[i] = take_max ? std::max(x, y) : std::min(x, y);
        }
    }
};

// ---------------------------------------------------------------------------------
// Compare
//
// 1 while a is at or above b, 0 while it is below: a signal turned into a gate. Feed
// the gate to an envelope and a level crossing becomes a note; feed it to a Gain and
// it is a rhythm. The output uses the same 0.5 convention every gate input listens for.

constexpr ParameterDescriptor kCompareParameters[] = {
    {"threshold", "", -100000.0f, 100000.0f, 0.0f, Scaling::Linear,
     "Used in place of the b input while it is unconnected.", nullptr, 0},
};

class CompareNode final : public DspNode {
public:
    enum Param { kThreshold = 0 };

    void process(const ProcessContext& context) override {
        const float* a = context.inputs[0];
        const float* b = context.inputs[1];
        float* out = context.outputs[0];
        const float fallback = parameter(kThreshold);
        for (int i = 0; i < context.frames; ++i) {
            const float x = (a != nullptr ? a[i] : 0.0f);
            const float y = (b != nullptr ? b[i] : fallback);
            out[i] = x >= y ? 1.0f : 0.0f;
        }
    }
};

// ---------------------------------------------------------------------------------
// SampleHold
//
// Freezes its input on each rising edge of the trigger and holds it until the next.
// The classic patch is noise in, clock on the trigger, stepped random out — but
// anything can be sampled: an LFO quantised into stairs, an envelope caught mid-fall.

constexpr PortDescriptor kSampleHoldInputs[] = {
    {"in", SignalType::Control, "", false, true, "Signal to sample."},
    {"trigger", SignalType::Control, "", true, false,
     "Rises above 0.5 to capture the input. The output holds between captures."},
};

class SampleHoldNode final : public DspNode {
public:
    void process(const ProcessContext& context) override {
        const float* in = context.inputs[0];
        const float* trigger = context.inputs[1];
        float* out = context.outputs[0];
        for (int i = 0; i < context.frames; ++i) {
            const bool open = gate_open(trigger, i);
            if (open && !was_open_) {
                held_ = (in != nullptr ? in[i] : 0.0f);
            }
            was_open_ = open;
            out[i] = held_;
        }
    }

    void reset() override {
        held_ = 0.0f;
        was_open_ = false;
    }

private:
    float held_ = 0.0f;
    bool was_open_ = false;
};

}  // namespace

const NodeTypeDescriptor kClip = {
    "Clip", "Clip", "Maths",
    "Keeps a signal between a floor and a ceiling. The hard limit as a building block.",
    "clip|clamp|limit|bound|restrict|hard clip|saturate exactly|keep in range|"
    "no lower than|no higher than|hard limiter|guard|ceiling|floor",
    Slice<PortDescriptor>(kUnaryInputs),
    Slice<PortDescriptor>(kControlOutput),
    Slice<ParameterDescriptor>(kClipParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<ClipNode>,
};

const NodeTypeDescriptor kAbs = {
    "Abs", "Abs", "Maths",
    "Folds a signal upward: negative parts become positive. Full-wave rectification.",
    "abs|absolute|rectify|rectifier|fold|full wave|magnitude|always positive",
    Slice<PortDescriptor>(kUnaryInputs),
    Slice<PortDescriptor>(kControlOutput),
    Slice<ParameterDescriptor>(),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<AbsNode>,
};

const NodeTypeDescriptor kMinMax = {
    "MinMax", "Min/Max", "Maths",
    "Passes the smaller or the larger of two signals.",
    "min|max|minimum|maximum|smaller|larger|lesser|greater|whichever|floor against|ceiling against",
    Slice<PortDescriptor>(kBinaryInputs),
    Slice<PortDescriptor>(kControlOutput),
    Slice<ParameterDescriptor>(kMinMaxParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<MinMaxNode>,
};

const NodeTypeDescriptor kCompare = {
    "Compare", "Compare", "Maths",
    "Outputs a gate: 1 while the input is at or above the threshold, 0 below.",
    "compare|greater|less|above|below|threshold|gate from signal|crossing|if|"
    "condition|logic|comparator|schmitt|detect|threshold gate",
    Slice<PortDescriptor>(kBinaryInputs),
    Slice<PortDescriptor>(kControlOutput),
    Slice<ParameterDescriptor>(kCompareParameters),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 0, 0},
    &make<CompareNode>,
};

const NodeTypeDescriptor kSampleHold = {
    "SampleHold", "Sample & Hold", "Modulation",
    "Freezes its input each time the trigger fires, and holds it until the next.",
    "sample and hold|sample hold|s&h|s+h|freeze|capture|latch|stepped|quantise lfo|"
    "staircase|random steps|hold value|glitch",
    Slice<PortDescriptor>(kSampleHoldInputs),
    Slice<PortDescriptor>(kControlOutput),
    Slice<ParameterDescriptor>(),
    false, NodeRole::Processor, false,
    ResourceCost{1.0f, 8, 0},
    &make<SampleHoldNode>,
};

}  // namespace nodes
}  // namespace soundgraph
