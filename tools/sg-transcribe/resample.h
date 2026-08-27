// Getting audio to the one rate the model knows.
//
// Basic Pitch was trained at 22050 Hz and has no opinions about anything else, so every
// recording has to arrive there first. This is a windowed-sinc resampler with a Kaiser
// window - the same family librosa reaches for, though not the same implementation, so
// a file that needed resampling will not transcribe to bit-identical activations across
// the two. It transcribes to the same notes, which is the part anybody cares about, and
// the checks say which claim is being made where.
//
// A file already at 22050 is passed through untouched, so the exactness check has a
// path with no resampling in it at all.
#pragma once

#include <vector>

namespace transcribe {

// Mono in at `from_rate`, mono out at `to_rate`.
std::vector<float> resample(const std::vector<float>& input, int from_rate, int to_rate);

}  // namespace transcribe
