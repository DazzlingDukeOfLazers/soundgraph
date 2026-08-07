// Golden vectors.
//
// These do not prove correctness — test_nodes.cpp does that against measurable properties.
// What these catch is drift: a change in scheduling, coefficient maths or ordering that
// nobody meant to make. They are also the artifact the WASM and ESP32 builds will be
// compared against, which is why they are stored as 32-bit float rather than 16-bit PCM.
//
// To re-record after a deliberate change, set SOUNDGRAPH_UPDATE_GOLDEN=1 and re-run. The
// diff in the recorded file is then part of the change under review.
#include <cmath>
#include <cstdlib>
#include <string>
#include <vector>

#include "soundgraph/patch_io.h"
#include "soundgraph/soundgraph.h"
#include "test_support.h"
#include "wav.h"

namespace {

constexpr int kSampleRate = 48000;

// Tolerance for a same-target comparison. Not zero, because a different optimisation
// level may reorder a multiply-add; anything genuinely different is orders larger.
constexpr double kTolerance = 1.0e-5;

const std::string kGoldenDir = std::string(SOUNDGRAPH_TESTS_DIR) + "/golden";
const std::string kExamplesDir = SOUNDGRAPH_EXAMPLES_DIR;

bool updating() {
    const char* value = std::getenv("SOUNDGRAPH_UPDATE_GOLDEN");
    return value != nullptr && value[0] != '\0' && value[0] != '0';
}

// Compares against the recorded vector, or records one if none exists yet.
void compare_with_golden(const std::string& name, const std::vector<float>& samples, int channels) {
    const std::string path = kGoldenDir + "/" + name + ".wav";

    soundgraph::AudioFile actual;
    actual.sample_rate = kSampleRate;
    actual.channels = channels;
    actual.samples = samples;

    soundgraph::AudioFile expected;
    std::string read_error;
    const bool have_golden = soundgraph::read_wav(path, expected, read_error);

    if (updating() || !have_golden) {
        std::string write_error;
        if (!soundgraph::write_wav_float(path, actual, write_error)) {
            ::testing::report_failure(__FILE__, __LINE__, write_error);
            return;
        }
        if (!have_golden) {
            ::testing::report_failure(
                __FILE__, __LINE__,
                "no golden vector for '" + name + "' — one has been recorded at " + path +
                    ". Listen to it, confirm it is what you meant, then commit it.");
        }
        return;
    }

    if (expected.samples.size() != actual.samples.size()) {
        ::testing::report_failure(__FILE__, __LINE__,
                                  name + ": expected " + std::to_string(expected.samples.size()) +
                                      " samples, produced " + std::to_string(actual.samples.size()));
        return;
    }

    double worst = 0.0;
    std::size_t worst_index = 0;
    for (std::size_t i = 0; i < expected.samples.size(); ++i) {
        const double difference = std::fabs(static_cast<double>(expected.samples[i]) - actual.samples[i]);
        if (difference > worst) {
            worst = difference;
            worst_index = i;
        }
    }

    if (worst > kTolerance) {
        ::testing::report_failure(
            __FILE__, __LINE__,
            name + ": drifted from the recorded vector by " + std::to_string(worst) +
                " at sample " + std::to_string(worst_index) +
                ". If this change was intended, re-run with SOUNDGRAPH_UPDATE_GOLDEN=1 and "
                "commit the new vector.");
    }
}

// Renders a single node with default-ish settings into a mono vector.
std::vector<float> render_node(const std::string& type,
                               const std::vector<std::pair<std::string, float>>& parameters,
                               int frames,
                               const std::string& driven_input = std::string()) {
    const soundgraph::NodeTypeDescriptor* descriptor =
        soundgraph::NodeRegistry::builtin().find(type);
    std::unique_ptr<soundgraph::DspNode> node = soundgraph::NodeRegistry::builtin().create(type);
    if (descriptor == nullptr || !node) {
        return {};
    }

    soundgraph::PrepareContext context;
    context.sample_rate = kSampleRate;
    node->prepare(context);

    for (const auto& parameter : parameters) {
        const int index = descriptor->find_parameter(parameter.first.c_str());
        if (index >= 0) {
            node->set_parameter(index, parameter.second);
        }
    }

    std::vector<std::vector<float>> inputs(static_cast<std::size_t>(descriptor->inputs.size()),
                                           std::vector<float>(soundgraph::kBlockSize, 0.0f));
    std::vector<std::vector<float>> outputs(static_cast<std::size_t>(descriptor->outputs.size()),
                                            std::vector<float>(soundgraph::kBlockSize, 0.0f));

    const int driven = driven_input.empty() ? -1 : descriptor->find_input(driven_input.c_str());
    if (driven >= 0) {
        for (float& sample : inputs[static_cast<std::size_t>(driven)]) {
            sample = 1.0f;
        }
    }

    std::vector<float> result;
    result.reserve(static_cast<std::size_t>(frames));

    for (int position = 0; position < frames; position += soundgraph::kBlockSize) {
        const float* input_pointers[soundgraph::kMaxInputs] = {};
        float* output_pointers[soundgraph::kMaxOutputs] = {};
        for (std::size_t i = 0; i < inputs.size(); ++i) {
            input_pointers[i] = (static_cast<int>(i) == driven) ? inputs[i].data() : nullptr;
        }
        for (std::size_t i = 0; i < outputs.size(); ++i) {
            output_pointers[i] = outputs[i].data();
        }

        soundgraph::ProcessContext process_context;
        process_context.frames = soundgraph::kBlockSize;
        process_context.sample_rate = kSampleRate;
        process_context.inputs = input_pointers;
        process_context.outputs = output_pointers;
        node->process(process_context);

        for (int i = 0; i < soundgraph::kBlockSize && position + i < frames; ++i) {
            result.push_back(outputs[0][static_cast<std::size_t>(i)]);
        }
    }
    return result;
}

constexpr int kShort = 4800;  // 0.1 s

}  // namespace

TEST(sine_oscillator_vector) {
    compare_with_golden("sine", render_node("SineOscillator", {{"frequency", 440.0f}}, kShort), 1);
}

TEST(saw_oscillator_vector) {
    compare_with_golden("saw", render_node("SawOscillator", {{"frequency", 220.0f}}, kShort), 1);
}

TEST(square_oscillator_vector) {
    compare_with_golden(
        "square", render_node("SquareOscillator", {{"frequency", 330.0f}, {"pulse_width", 0.3f}}, kShort), 1);
}

TEST(noise_vector) {
    compare_with_golden("noise", render_node("Noise", {{"colour", 0.0f}, {"seed", 20260807.0f}}, kShort), 1);
}

TEST(pink_noise_vector) {
    compare_with_golden("noise-pink",
                        render_node("Noise", {{"colour", 1.0f}, {"seed", 20260807.0f}}, kShort), 1);
}

TEST(lfo_vector) {
    compare_with_golden(
        "lfo",
        render_node("LFO", {{"rate", 3.0f}, {"shape", 1.0f}, {"amount", 1.0f}, {"offset", 0.0f}}, kShort),
        1);
}

TEST(adsr_vector) {
    compare_with_golden("adsr",
                        render_node("ADSR",
                                    {{"attack", 0.01f}, {"decay", 0.03f}, {"sustain", 0.4f}, {"release", 0.05f}},
                                    kShort, "gate"),
                        1);
}

TEST(filter_sweep_vector) {
    // The full demo signal path in miniature: a saw through a resonant lowpass being
    // swept by an LFO. This is the vector most likely to move if anything in the
    // scheduler or the coefficient maths changes.
    soundgraph::GraphDescription graph;

    auto add = [&](const std::string& id, const std::string& type) {
        soundgraph::NodeDescription node;
        node.id = id;
        node.type = type;
        graph.nodes.push_back(node);
    };
    auto set = [&](const std::string& id, const std::string& parameter, double value) {
        for (soundgraph::NodeDescription& node : graph.nodes) {
            if (node.id == id) {
                node.parameters.push_back(soundgraph::ParameterValue{parameter, value});
            }
        }
    };
    auto wire = [&](const std::string& a, const std::string& ap, const std::string& b,
                    const std::string& bp) {
        graph.connections.push_back(soundgraph::ConnectionDescription{a, ap, b, bp});
    };

    add("osc", "SawOscillator");
    add("lfo", "LFO");
    add("filter", "StateVariableFilter");
    add("out", "StereoOutput");
    set("osc", "frequency", 110.0);
    set("lfo", "rate", 2.0);
    set("lfo", "amount", 1.5);
    set("filter", "cutoff", 600.0);
    set("filter", "resonance", 0.7);
    // Low enough that the output's safety limiter never engages: this vector is meant to
    // record what the filter does, not what tanh does.
    set("out", "level", 0.3);
    wire("osc", "out", "filter", "in");
    wire("lfo", "out", "filter", "cutoff_mod");
    wire("filter", "out", "out", "left");

    soundgraph::Graph runtime;
    std::vector<soundgraph::Diagnostic> diagnostics;
    soundgraph::PrepareContext context;
    context.sample_rate = kSampleRate;
    CHECK(runtime.build(graph, soundgraph::NodeRegistry::builtin(), context, diagnostics));

    std::vector<float> output(static_cast<std::size_t>(kSampleRate / 2), 0.0f);
    runtime.render(output.data(), nullptr, static_cast<int>(output.size()));
    compare_with_golden("filter-sweep", output, 1);
}

TEST(delay_feedback_vector) {
    soundgraph::GraphDescription graph;
    soundgraph::NodeDescription noise;
    noise.id = "noise";
    noise.type = "Noise";
    noise.parameters.push_back(soundgraph::ParameterValue{"seed", 777.0});
    soundgraph::NodeDescription gate;
    gate.id = "gate";
    gate.type = "Gain";
    gate.parameters.push_back(soundgraph::ParameterValue{"gain", 0.4});
    soundgraph::NodeDescription delay;
    delay.id = "delay";
    delay.type = "Delay";
    delay.parameters.push_back(soundgraph::ParameterValue{"time", 0.05});
    delay.parameters.push_back(soundgraph::ParameterValue{"feedback", 0.6});
    delay.parameters.push_back(soundgraph::ParameterValue{"mix", 0.5});
    soundgraph::NodeDescription out;
    out.id = "out";
    out.type = "StereoOutput";
    out.parameters.push_back(soundgraph::ParameterValue{"level", 0.8});

    graph.nodes = {noise, gate, delay, out};
    graph.connections = {
        soundgraph::ConnectionDescription{"noise", "out", "gate", "in"},
        soundgraph::ConnectionDescription{"gate", "out", "delay", "in"},
        soundgraph::ConnectionDescription{"delay", "out", "out", "left"},
    };

    soundgraph::Graph runtime;
    std::vector<soundgraph::Diagnostic> diagnostics;
    soundgraph::PrepareContext context;
    context.sample_rate = kSampleRate;
    CHECK(runtime.build(graph, soundgraph::NodeRegistry::builtin(), context, diagnostics));

    std::vector<float> output(static_cast<std::size_t>(kSampleRate / 4), 0.0f);
    runtime.render(output.data(), nullptr, static_cast<int>(output.size()));
    compare_with_golden("delay-feedback", output, 1);
}

TEST(the_first_synth_patch_renders_the_same_way_every_time) {
    soundgraph::GraphDescription graph;
    std::vector<soundgraph::Diagnostic> diagnostics;
    CHECK(soundgraph::load_patch(kExamplesDir + "/patches/first-synth.json", graph, diagnostics));

    soundgraph::PrepareContext context;
    context.sample_rate = kSampleRate;

    soundgraph::Graph runtime;
    CHECK(runtime.build(graph, soundgraph::NodeRegistry::builtin(), context, diagnostics));

    const int frames = kSampleRate / 2;  // half a second
    std::vector<float> output(static_cast<std::size_t>(frames), 0.0f);

    runtime.note_on(45, 0.9f);  // A2
    runtime.render(output.data(), nullptr, frames / 2);
    runtime.note_off(45);
    runtime.render(output.data() + frames / 2, nullptr, frames - frames / 2);

    float peak = 0.0f;
    for (float sample : output) {
        peak = std::max(peak, std::fabs(sample));
    }
    CHECK_MESSAGE(peak > 0.1f, "the demo patch must actually make a sound");

    compare_with_golden("first-synth", output, 1);
}

TEST_MAIN("golden tests")
