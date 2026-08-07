#include "soundgraph/types.h"

#include <cstring>

namespace soundgraph {

const char* to_string(SignalType type) {
    switch (type) {
        case SignalType::Audio:   return "audio";
        case SignalType::Control: return "control";
        case SignalType::Event:   return "event";
        case SignalType::Note:    return "note";
    }
    return "audio";
}

bool parse_signal_type(const char* text, SignalType& out) {
    if (text == nullptr) {
        return false;
    }
    if (std::strcmp(text, "audio") == 0)   { out = SignalType::Audio;   return true; }
    if (std::strcmp(text, "control") == 0) { out = SignalType::Control; return true; }
    if (std::strcmp(text, "event") == 0)   { out = SignalType::Event;   return true; }
    if (std::strcmp(text, "note") == 0)    { out = SignalType::Note;    return true; }
    return false;
}

bool signal_types_compatible(SignalType from, SignalType to) {
    if (from == to) {
        return true;
    }
    // audio and control are both float sample streams. Letting them interconvert is what
    // makes audio-rate modulation and control-rate mixing work without conversion nodes.
    const bool from_stream = (from == SignalType::Audio || from == SignalType::Control);
    const bool to_stream = (to == SignalType::Audio || to == SignalType::Control);
    return from_stream && to_stream;
}

std::string Diagnostic::format() const {
    std::string result;
    switch (severity) {
        case Severity::Error:   result = "error"; break;
        case Severity::Warning: result = "warning"; break;
        case Severity::Info:    result = "info"; break;
    }
    result += ": ";
    result += message;

    if (!node_ids.empty()) {
        result += "\n  at: ";
        for (std::size_t i = 0; i < node_ids.size(); ++i) {
            if (i > 0) {
                result += " -> ";
            }
            result += node_ids[i];
        }
    }
    if (!suggestion.empty()) {
        result += "\n  try: ";
        result += suggestion;
    }
    return result;
}

}  // namespace soundgraph
