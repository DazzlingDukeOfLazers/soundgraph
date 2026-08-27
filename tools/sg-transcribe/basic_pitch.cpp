#include "basic_pitch.h"

#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace transcribe {
namespace {

// Index into a frames x width matrix held flat.
inline float& at(std::vector<float>& m, int width, int frame, int bin) {
    return m[static_cast<size_t>(frame) * width + bin];
}
inline float at(const std::vector<float>& m, int width, int frame, int bin) {
    return m[static_cast<size_t>(frame) * width + bin];
}

}  // namespace

struct Model::State {
    Ort::Env env{ORT_LOGGING_LEVEL_ERROR, "sg-transcribe"};
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> session;
    std::string input_name;
    // The three heads come back in the order the graph declares, which is not the order
    // they are wanted in; they are matched by shape instead of by position, because the
    // exported names are "StatefulPartitionedCall:0" and friends and say nothing.
    std::vector<std::string> output_names;
};

Model::Model() : state_(new State()) {}
Model::~Model() { delete state_; }

bool Model::load(const std::string& onnx_path, std::string& error) {
    try {
        state_->options.SetIntraOpNumThreads(0);   // let it decide
        state_->options.SetGraphOptimizationLevel(ORT_ENABLE_ALL);
#ifdef _WIN32
        std::wstring wide(onnx_path.begin(), onnx_path.end());
        state_->session = std::make_unique<Ort::Session>(state_->env, wide.c_str(),
                                                        state_->options);
#else
        state_->session = std::make_unique<Ort::Session>(state_->env, onnx_path.c_str(),
                                                        state_->options);
#endif
        Ort::AllocatorWithDefaultOptions allocator;
        state_->input_name = state_->session->GetInputNameAllocated(0, allocator).get();
        const size_t outputs = state_->session->GetOutputCount();
        for (size_t i = 0; i < outputs; ++i) {
            state_->output_names.push_back(
                state_->session->GetOutputNameAllocated(i, allocator).get());
        }
        if (outputs != 3) {
            error = "expected three output heads, found " + std::to_string(outputs);
            return false;
        }
    } catch (const Ort::Exception& problem) {
        error = std::string("could not load the model: ") + problem.what();
        return false;
    }
    return true;
}

bool Model::run(const std::vector<float>& samples, Activations& out, std::string& error) {
    if (state_->session == nullptr) {
        error = "the model was never loaded";
        return false;
    }

    // Half the overlap of silence in front, so the first window's trimmed head does not
    // eat the beginning of the audio. inference.py::get_audio_input does the same.
    const int overlap_samples = kOverlappingFrames * kFftHop;
    const int lead = overlap_samples / 2;
    std::vector<float> padded(static_cast<size_t>(lead), 0.0f);
    padded.insert(padded.end(), samples.begin(), samples.end());

    const int hop = kAudioSamples - overlap_samples;
    const int trim = kOverlappingFrames / 2;
    const int kept_per_window = kFramesPerWindow - 2 * trim;

    out.note.clear();
    out.onset.clear();
    out.contour.clear();

    Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    const char* input_names[] = {state_->input_name.c_str()};
    std::vector<const char*> output_names;
    for (const std::string& name : state_->output_names) {
        output_names.push_back(name.c_str());
    }

    std::vector<float> window(static_cast<size_t>(kAudioSamples));
    const int64_t shape[3] = {1, kAudioSamples, 1};

    for (size_t start = 0; start < padded.size(); start += static_cast<size_t>(hop)) {
        std::fill(window.begin(), window.end(), 0.0f);
        const size_t have = std::min(static_cast<size_t>(kAudioSamples),
                                     padded.size() - start);
        std::memcpy(window.data(), padded.data() + start, have * sizeof(float));

        try {
            Ort::Value input = Ort::Value::CreateTensor<float>(
                memory, window.data(), window.size(), shape, 3);
            auto results = state_->session->Run(Ort::RunOptions{nullptr}, input_names,
                                                &input, 1, output_names.data(),
                                                output_names.size());

            // Which head is which.
            //
            // Two of the three outputs are 88 wide, so width alone cannot tell the note
            // head from the onset head, and the exported names are
            // "StatefulPartitionedCall:2", ":1" and ":0" - declared in that order, and
            // carrying no meaning whatever.
            //
            // Settled by asking the model instead of by reading the names: fed a
            // sustained tone, the onset head is above 0.5 in 1% of frames and the note
            // head in 95%, because one marks a beginning and the other marks a
            // continuing. That gives declaration order 0=onset, 1=note, 2=contour.
            //
            // Getting this wrong is not loud. An earlier version sent both 88-wide
            // heads into `note` and left `onset` zero-filled, and it still produced six
            // notes of roughly the right pitches - just in the wrong order and 1.6
            // seconds late. Hence the width check below: if a future model reorders its
            // outputs, this should stop rather than quietly transcribe nonsense.
            for (size_t i = 0; i < results.size(); ++i) {
                auto info = results[i].GetTensorTypeAndShapeInfo();
                const std::vector<int64_t> dims = info.GetShape();
                if (dims.size() != 3) continue;
                const int width = static_cast<int>(dims[2]);
                const float* data = results[i].GetTensorData<float>();

                std::vector<float>* target = nullptr;
                int expected = 0;
                if (i == 0) { target = &out.onset;   expected = kSemitones; }
                else if (i == 1) { target = &out.note; expected = kSemitones; }
                else if (i == 2) { target = &out.contour;
                                   expected = kSemitones * kContourBinsPerSemitone; }
                if (target == nullptr) continue;
                if (width != expected) {
                    error = "output " + std::to_string(i) + " is " +
                            std::to_string(width) + " wide, expected " +
                            std::to_string(expected) + " - the model is not the one "
                            "this was written against";
                    return false;
                }

                for (int f = trim; f < kFramesPerWindow - trim; ++f) {
                    const float* row = data + static_cast<size_t>(f) * width;
                    target->insert(target->end(), row, row + width);
                }
            }
        } catch (const Ort::Exception& problem) {
            error = std::string("the model failed: ") + problem.what();
            return false;
        }
    }

    // Trim to the length the audio actually had, so trailing padding does not become
    // notes. floor(samples * fps / rate), as over there.
    const int frames_of_audio = static_cast<int>(
        std::floor(static_cast<double>(samples.size()) *
                   (static_cast<double>(kFramesPerSecond) / kSampleRate)));
    const int produced = static_cast<int>(out.note.size() / kSemitones);
    out.frames = std::min(frames_of_audio, produced);

    out.note.resize(static_cast<size_t>(out.frames) * kSemitones);
    out.onset.resize(static_cast<size_t>(out.frames) * kSemitones);
    out.contour.resize(static_cast<size_t>(out.frames) * kSemitones * kContourBinsPerSemitone);
    (void)kept_per_window;
    return true;
}

double frame_to_seconds(int frame) {
    const double original = static_cast<double>(frame) * kFftHop / kSampleRate;
    const double window_number = std::floor(static_cast<double>(frame) / kFramesPerWindow);
    const double window_offset =
        (static_cast<double>(kFftHop) / kSampleRate) *
            (kFramesPerWindow - (static_cast<double>(kAudioSamples) / kFftHop)) +
        0.0018;
    return original - window_offset * window_number;
}

namespace {

// Onsets the onset head missed but the frame head plainly shows: a large jump in frame
// energy is an onset whatever the other head thinks. note_creation.py::get_infered_onsets.
void infer_onsets(std::vector<float>& onsets, const std::vector<float>& frames,
                  int n_frames) {
    const int width = kSemitones;
    const int n_diff = 2;
    std::vector<float> diff(static_cast<size_t>(n_frames) * width, 0.0f);

    // The minimum across both differences, floored at zero.
    for (int f = 0; f < n_frames; ++f) {
        for (int b = 0; b < width; ++b) {
            float smallest = 0.0f;
            bool first = true;
            for (int n = 1; n <= n_diff; ++n) {
                const float before = f - n >= 0 ? at(frames, width, f - n, b) : 0.0f;
                const float value = at(frames, width, f, b) - before;
                if (first || value < smallest) {
                    smallest = value;
                    first = false;
                }
            }
            at(diff, width, f, b) = smallest < 0.0f ? 0.0f : smallest;
        }
    }
    // The first n_diff frames have nothing to be a difference from.
    for (int f = 0; f < std::min(n_diff, n_frames); ++f) {
        for (int b = 0; b < width; ++b) at(diff, width, f, b) = 0.0f;
    }

    float max_onset = 0.0f, max_diff = 0.0f;
    for (float v : onsets) max_onset = std::max(max_onset, v);
    for (float v : diff) max_diff = std::max(max_diff, v);
    if (max_diff <= 0.0f) return;

    for (size_t i = 0; i < onsets.size(); ++i) {
        onsets[i] = std::max(onsets[i], max_onset * diff[i] / max_diff);
    }
}

}  // namespace

std::vector<Note> notes_from_activations(const Activations& activations,
                                         const Options& options) {
    const int n_frames = activations.frames;
    const int width = kSemitones;
    std::vector<Note> found;
    if (n_frames <= 1) return found;

    const int min_note_frames = static_cast<int>(std::lround(
        options.minimum_note_length_ms / 1000.0 *
        (static_cast<double>(kSampleRate) / kFftHop)));
    const int energy_tolerance = 11;   // frames below threshold before a note is over

    std::vector<float> frames = activations.note;
    std::vector<float> onsets = activations.onset;

    // Registers outside the asked-for range are silenced before anything looks at them,
    // which is how a bass line is pulled out of a mix.
    for (int f = 0; f < n_frames; ++f) {
        for (int b = 0; b < width; ++b) {
            const int pitch = b + kMidiOffset;
            if (pitch < options.minimum_pitch || pitch > options.maximum_pitch) {
                at(frames, width, f, b) = 0.0f;
                at(onsets, width, f, b) = 0.0f;
            }
        }
    }

    if (options.infer_onsets) infer_onsets(onsets, frames, n_frames);

    // Onset peaks: a local maximum in time, above the threshold. Walked backwards in
    // time, as over there, because the energy each note claims is taken away from the
    // ones behind it and the order decides who gets it.
    struct Peak { int frame; int bin; };
    std::vector<Peak> peaks;
    for (int f = 1; f + 1 < n_frames; ++f) {
        for (int b = 0; b < width; ++b) {
            const float here = at(onsets, width, f, b);
            if (here <= at(onsets, width, f - 1, b)) continue;
            if (here <= at(onsets, width, f + 1, b)) continue;
            if (here >= options.onset_threshold) peaks.push_back({f, b});
        }
    }
    std::sort(peaks.begin(), peaks.end(), [](const Peak& a, const Peak& b) {
        if (a.frame != b.frame) return a.frame > b.frame;
        return a.bin > b.bin;
    });

    std::vector<float> remaining = frames;

    auto claim = [&](int from, int to, int bin) {
        for (int f = from; f < to; ++f) {
            at(remaining, width, f, bin) = 0.0f;
            if (bin < kMaxFreqIndex) at(remaining, width, f, bin + 1) = 0.0f;
            if (bin > 0) at(remaining, width, f, bin - 1) = 0.0f;
        }
    };
    auto mean_energy = [&](int from, int to, int bin) {
        if (to <= from) return 0.0;
        double total = 0.0;
        for (int f = from; f < to; ++f) total += at(activations.note, width, f, bin);
        return total / (to - from);
    };

    for (const Peak& peak : peaks) {
        if (peak.frame >= n_frames - 1) continue;

        int i = peak.frame + 1;
        int quiet = 0;
        while (i < n_frames - 1 && quiet < energy_tolerance) {
            if (at(remaining, width, i, peak.bin) < options.frame_threshold) {
                ++quiet;
            } else {
                quiet = 0;
            }
            ++i;
        }
        i -= quiet;   // back to the last frame that was still sounding

        if (i - peak.frame <= min_note_frames) continue;

        claim(peak.frame, i, peak.bin);
        Note note;
        note.start_seconds = frame_to_seconds(peak.frame);
        note.end_seconds = frame_to_seconds(i);
        note.pitch = peak.bin + kMidiOffset;
        note.amplitude = mean_energy(peak.frame, i, peak.bin);
        found.push_back(note);
    }

    // The melodia trick: sustained energy nobody claimed is still a note, it just never
    // had an onset sharp enough to be seen as one. Take the loudest leftover, grow it
    // both ways until it dies, and repeat until nothing is left above the threshold.
    if (options.melodia_trick) {
        while (true) {
            int best_frame = -1, best_bin = -1;
            float best = options.frame_threshold;
            for (int f = 0; f < n_frames; ++f) {
                for (int b = 0; b < width; ++b) {
                    const float v = at(remaining, width, f, b);
                    if (v > best) { best = v; best_frame = f; best_bin = b; }
                }
            }
            if (best_frame < 0) break;
            at(remaining, width, best_frame, best_bin) = 0.0f;

            int i = best_frame + 1;
            int quiet = 0;
            while (i < n_frames - 1 && quiet < energy_tolerance) {
                if (at(remaining, width, i, best_bin) < options.frame_threshold) {
                    ++quiet;
                } else {
                    quiet = 0;
                }
                at(remaining, width, i, best_bin) = 0.0f;
                if (best_bin < kMaxFreqIndex) at(remaining, width, i, best_bin + 1) = 0.0f;
                if (best_bin > 0) at(remaining, width, i, best_bin - 1) = 0.0f;
                ++i;
            }
            const int end = i - 1 - quiet;

            i = best_frame - 1;
            quiet = 0;
            while (i > 0 && quiet < energy_tolerance) {
                if (at(remaining, width, i, best_bin) < options.frame_threshold) {
                    ++quiet;
                } else {
                    quiet = 0;
                }
                at(remaining, width, i, best_bin) = 0.0f;
                if (best_bin < kMaxFreqIndex) at(remaining, width, i, best_bin + 1) = 0.0f;
                if (best_bin > 0) at(remaining, width, i, best_bin - 1) = 0.0f;
                --i;
            }
            const int begin = i + 1 + quiet;

            if (end - begin <= min_note_frames) continue;

            Note note;
            note.start_seconds = frame_to_seconds(begin);
            note.end_seconds = frame_to_seconds(end);
            note.pitch = best_bin + kMidiOffset;
            note.amplitude = mean_energy(begin, end, best_bin);
            found.push_back(note);
        }
    }

    std::sort(found.begin(), found.end(), [](const Note& a, const Note& b) {
        if (a.start_seconds != b.start_seconds) return a.start_seconds < b.start_seconds;
        return a.pitch < b.pitch;
    });
    return found;
}

}  // namespace transcribe
