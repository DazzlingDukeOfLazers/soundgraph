// SoundGraph — core value types.
//
// This header, and everything else under dsp-core, must depend on nothing but the C++
// standard library. No JSON, no filesystem, no logging, no UI. See docs/decisions.md.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace soundgraph {

// Internal processing block size. Fixed so that steady-state processing never allocates
// and so that golden vectors do not depend on the host's buffer size.
inline constexpr int kBlockSize = 64;

inline constexpr int kMaxParameters = 8;
inline constexpr int kMaxInputs = 8;
inline constexpr int kMaxOutputs = 4;

// audio and control are both sample streams and interconvert freely.
// event and note carry discrete messages and require an exact type match.
enum class SignalType {
    Audio,
    Control,
    Event,
    Note,
};

const char* to_string(SignalType type);
bool parse_signal_type(const char* text, SignalType& out);

// Whether a connection from `from` to `to` is legal.
bool signal_types_compatible(SignalType from, SignalType to);

// How an editor should map a parameter onto a knob or slider.
enum class Scaling {
    Linear,
    Exponential,   // frequency, time — perceptually logarithmic
    Logarithmic,   // decibels
};

enum class Severity {
    Error,
    Warning,
    Info,
};

// A validation result. Deliberately spatial: it carries the node and connection
// identities involved so an editor can highlight the actual problem rather than
// printing "DSP ERROR" somewhere off to the side. See docs/UX_PRINCIPLES.md.
struct Diagnostic {
    Severity severity = Severity::Error;
    std::string code;                    // stable machine-readable identifier
    std::string message;                 // what is wrong, in human language
    std::string suggestion;              // what to do about it; may be empty
    std::vector<std::string> node_ids;   // nodes to highlight
    std::vector<int> connection_indices; // connections to highlight

    std::string format() const;
};

// A non-owning view. Node type descriptors are static data, so they hand out views
// rather than vectors; this keeps the registry allocation-free and embeddable.
template <typename T>
struct Slice {
    const T* data = nullptr;
    int count = 0;

    constexpr Slice() = default;
    constexpr Slice(const T* d, int n) : data(d), count(n) {}
    template <std::size_t N>
    constexpr explicit Slice(const T (&array)[N]) : data(array), count(static_cast<int>(N)) {}

    constexpr int size() const { return count; }
    constexpr bool empty() const { return count == 0; }
    constexpr const T& operator[](int i) const { return data[i]; }
    constexpr const T* begin() const { return data; }
    constexpr const T* end() const { return data + count; }
};

}  // namespace soundgraph
