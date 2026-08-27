// Audio in, notes out, natively.
//
// A port of Spotify's Basic Pitch inference pipeline: the model is theirs, in
// model/nmp.onnx (Apache-2.0, see model/LICENSE), and this is the arithmetic that
// surrounds it — the windowing that feeds it and the note-picking that reads its
// three output heads.
//
// The whole model is 230 KB and takes raw audio, because the constant-Q front end is
// baked into the graph. That is the entire reason this can be a small native tool
// rather than a Python environment: nothing here needs a training framework, only the
// ability to multiply the matrices somebody already trained.
//
// Ported from basic_pitch/inference.py and basic_pitch/note_creation.py rather than
// invented, because the numbers have to agree with a model that was trained against
// them. Where a constant looks arbitrary it is: it came from over there, and the
// comments say so instead of pretending to a reason.
#pragma once

#include <string>
#include <vector>

namespace transcribe {

// From basic_pitch/constants.py. The model was trained at these and nothing else works.
constexpr int kSampleRate = 22050;
constexpr int kFftHop = 256;
constexpr int kWindowSeconds = 2;
// 22050 * 2 - 256. The odd shape is the model's actual input width.
constexpr int kAudioSamples = kSampleRate * kWindowSeconds - kFftHop;
constexpr int kFramesPerSecond = kSampleRate / kFftHop;         // 86
constexpr int kFramesPerWindow = kFramesPerSecond * kWindowSeconds;  // 172
constexpr int kSemitones = 88;                                  // a piano's worth
constexpr int kContourBinsPerSemitone = 3;
constexpr int kMidiOffset = 21;                                 // bin 0 is A0
constexpr int kMaxFreqIndex = kSemitones - 1;

// Windows are fed with 30 frames of overlap and the halves trimmed off afterwards, so
// that a note straddling a window boundary is seen whole by at least one of them.
constexpr int kOverlappingFrames = 30;

struct Note {
    double start_seconds = 0.0;
    double end_seconds = 0.0;
    int pitch = 0;          // MIDI note number
    double amplitude = 0.0; // 0..1, the mean frame activation across the note
};

struct Options {
    // Basic Pitch's own defaults, from the signature of predict().
    double onset_threshold = 0.5;
    double frame_threshold = 0.3;
    double minimum_note_length_ms = 127.7;
    int minimum_pitch = 0;
    int maximum_pitch = 127;
    // Both default true over there. Inferred onsets catch notes the onset head missed
    // but the frame head clearly shows starting; the melodia trick sweeps up sustained
    // energy that never had a detected onset at all.
    bool infer_onsets = true;
    bool melodia_trick = true;
};

// The model's three output heads, unwrapped into one continuous timeline.
struct Activations {
    std::vector<float> note;     // frames x 88
    std::vector<float> onset;    // frames x 88
    std::vector<float> contour;  // frames x 264, read by nothing here yet
    int frames = 0;
};

// Loads the model once. Cheap to keep, expensive to build.
class Model {
public:
    Model();
    ~Model();
    Model(const Model&) = delete;
    Model& operator=(const Model&) = delete;

    bool load(const std::string& onnx_path, std::string& error);

    // `samples` is mono at kSampleRate. Anything else is the caller's problem, because
    // resampling belongs to whoever read the file.
    bool run(const std::vector<float>& samples, Activations& out, std::string& error);

private:
    struct State;
    State* state_ = nullptr;
};

// The three heads into note events. Pure arithmetic on the activations - no model, no
// files - so it can be tested against the Python on the same matrices.
std::vector<Note> notes_from_activations(const Activations& activations,
                                         const Options& options);

// Frame index to seconds. Not simply frame * hop / rate: the windows the model was fed
// overlap, and the offset that removes accumulates once per window. The 0.0018 is a
// magic number in basic_pitch/note_creation.py, described there as needed for
// alignment, and it is carried across rather than explained.
double frame_to_seconds(int frame);

}  // namespace transcribe
