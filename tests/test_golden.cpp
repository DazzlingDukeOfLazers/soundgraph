// Golden vectors.
//
// These do not prove correctness — test_nodes.cpp does that against measurable
// properties. What these catch is drift: a change in scheduling, coefficient maths or
// ordering that nobody meant to make.
//
// Every case is an ordinary patch under tests/golden/cases/, listed in
// tests/golden/cases.json. The WebAssembly runner (editor-web/verify-goldens.mjs) renders
// exactly the same files through the same C++ core and compares against the same
// recordings, and the embedded runner will too. Keeping the case definitions in the patch
// format rather than in test code is what makes "the same graph everywhere" checkable
// rather than merely claimed.
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

// The manifest is JSON, and the test binary already links patch-io — but patch-io only
// exposes patches. Reading the manifest reuses the same parser through its internal
// header, which is fair game for a test that lives in the same repository.
#include "../patch-io/src/json.h"

namespace {

// Tolerance for a same-target comparison. Not zero, because a different optimisation
// level may reorder a multiply-add; anything genuinely different is orders larger.
// Cross-target tolerances are recorded in docs/test-matrix.md.
constexpr double kTolerance = 1.0e-5;

const std::string kGoldenDir = std::string(SOUNDGRAPH_TESTS_DIR) + "/golden";

bool updating() {
    const char* value = std::getenv("SOUNDGRAPH_UPDATE_GOLDEN");
    return value != nullptr && value[0] != '\0' && value[0] != '0';
}

std::string read_file(const std::string& path) {
    std::FILE* file = std::fopen(path.c_str(), "rb");
    if (file == nullptr) {
        return std::string();
    }
    std::string contents;
    char buffer[4096];
    std::size_t read = 0;
    while ((read = std::fread(buffer, 1, sizeof(buffer), file)) > 0) {
        contents.append(buffer, read);
    }
    std::fclose(file);
    return contents;
}

struct Event {
    int frame = 0;
    bool note_on = true;
    int note = 60;
    float velocity = 1.0f;
};

struct Case {
    std::string name;
    std::string patch_path;
    int frames = 0;
    std::vector<Event> events;
};

// Compares against the recorded vector, or records one if none exists yet.
void compare_with_golden(const std::string& name, const std::vector<float>& samples,
                         int sample_rate) {
    const std::string path = kGoldenDir + "/vectors/" + name + ".wav";

    soundgraph::AudioFile actual;
    actual.sample_rate = sample_rate;
    actual.channels = 1;
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
        const double difference =
            std::fabs(static_cast<double>(expected.samples[i]) - actual.samples[i]);
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

bool load_manifest(int& sample_rate, std::vector<Case>& cases) {
    const std::string text = read_file(kGoldenDir + "/cases.json");
    if (text.empty()) {
        return false;
    }

    soundgraph::json::Value root;
    std::string error;
    if (!soundgraph::json::parse(text, root, error)) {
        ::testing::report_failure(__FILE__, __LINE__, "cases.json: " + error);
        return false;
    }

    const soundgraph::json::Value* rate = root.find("sample_rate");
    sample_rate = rate != nullptr ? static_cast<int>(rate->as_number(48000.0)) : 48000;

    const soundgraph::json::Value* entries = root.find("cases");
    if (entries == nullptr || !entries->is_array()) {
        return false;
    }

    for (const soundgraph::json::Value& entry : entries->array()) {
        Case item;
        if (const soundgraph::json::Value* value = entry.find("name")) {
            item.name = value->as_string();
        }
        if (const soundgraph::json::Value* value = entry.find("patch")) {
            item.patch_path = value->as_string();
        }
        if (const soundgraph::json::Value* value = entry.find("frames")) {
            item.frames = static_cast<int>(value->as_number(0.0));
        }
        if (const soundgraph::json::Value* events = entry.find("events")) {
            if (events->is_array()) {
                for (const soundgraph::json::Value& raw : events->array()) {
                    Event event;
                    if (const soundgraph::json::Value* value = raw.find("frame")) {
                        event.frame = static_cast<int>(value->as_number(0.0));
                    }
                    if (const soundgraph::json::Value* value = raw.find("type")) {
                        event.note_on = value->as_string() == "note_on";
                    }
                    if (const soundgraph::json::Value* value = raw.find("note")) {
                        event.note = static_cast<int>(value->as_number(60.0));
                    }
                    if (const soundgraph::json::Value* value = raw.find("velocity")) {
                        event.velocity = static_cast<float>(value->as_number(1.0));
                    }
                    item.events.push_back(event);
                }
            }
        }
        cases.push_back(item);
    }
    return !cases.empty();
}

std::vector<float> render_case(const Case& item, int sample_rate, bool& ok) {
    ok = false;
    soundgraph::GraphDescription description;
    std::vector<soundgraph::Diagnostic> diagnostics;

    const std::string path = kGoldenDir + "/" + item.patch_path;
    if (!soundgraph::load_patch(path, description, diagnostics)) {
        ::testing::report_failure(__FILE__, __LINE__, "could not load " + path);
        return {};
    }

    soundgraph::PrepareContext context;
    context.sample_rate = sample_rate;

    soundgraph::Graph graph;
    if (!graph.build(description, soundgraph::NodeRegistry::builtin(), context, diagnostics)) {
        std::string message = item.name + ": patch does not build";
        for (const soundgraph::Diagnostic& diagnostic : diagnostics) {
            message += "\n    " + diagnostic.format();
        }
        ::testing::report_failure(__FILE__, __LINE__, message);
        return {};
    }

    std::vector<float> output(static_cast<std::size_t>(item.frames), 0.0f);

    // Events are delivered on block boundaries, exactly as a live host would.
    std::size_t next_event = 0;
    int position = 0;
    while (position < item.frames) {
        const int frames = std::min(soundgraph::kBlockSize, item.frames - position);
        while (next_event < item.events.size() &&
               item.events[next_event].frame < position + frames) {
            const Event& event = item.events[next_event];
            if (event.note_on) {
                graph.note_on(event.note, event.velocity);
            } else {
                graph.note_off(event.note);
            }
            ++next_event;
        }
        graph.render(output.data() + position, nullptr, frames);
        position += frames;
    }

    ok = true;
    return output;
}

}  // namespace

TEST(every_golden_case_still_renders_the_way_it_was_recorded) {
    int sample_rate = 48000;
    std::vector<Case> cases;
    if (!load_manifest(sample_rate, cases)) {
        ::testing::report_failure(__FILE__, __LINE__, "could not read tests/golden/cases.json");
        return;
    }

    CHECK_MESSAGE(cases.size() >= 10, "the golden set should cover the whole node vocabulary");

    for (const Case& item : cases) {
        bool ok = false;
        const std::vector<float> output = render_case(item, sample_rate, ok);
        if (!ok) {
            continue;
        }

        float peak = 0.0f;
        for (float sample : output) {
            peak = std::max(peak, std::fabs(sample));
        }
        CHECK_MESSAGE(peak > 1.0e-4f, item.name + " rendered silence");

        compare_with_golden(item.name, output, sample_rate);
    }
}

TEST(the_golden_manifest_and_the_recorded_vectors_agree) {
    int sample_rate = 48000;
    std::vector<Case> cases;
    CHECK(load_manifest(sample_rate, cases));

    for (const Case& item : cases) {
        soundgraph::AudioFile vector;
        std::string error;
        const std::string path = kGoldenDir + "/vectors/" + item.name + ".wav";
        if (!soundgraph::read_wav(path, vector, error)) {
            continue;  // reported by the rendering test
        }
        CHECK_MESSAGE(vector.sample_rate == sample_rate,
                      item.name + ": recorded at a different sample rate than the manifest asks for");
        CHECK_MESSAGE(static_cast<int>(vector.samples.size()) == item.frames,
                      item.name + ": recorded length does not match the manifest");
    }
}

TEST_MAIN("golden tests")
