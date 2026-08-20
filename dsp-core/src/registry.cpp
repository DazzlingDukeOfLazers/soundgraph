#include "soundgraph/registry.h"

#include <algorithm>
#include <cctype>

#include "nodes/node_types.h"

namespace soundgraph {
namespace {

std::string lowercase(const std::string& text) {
    std::string result = text;
    for (char& character : result) {
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    }
    return result;
}

// Splits the pipe-separated search_terms field into individual phrases.
std::vector<std::string> split_terms(const char* terms) {
    std::vector<std::string> result;
    if (terms == nullptr) {
        return result;
    }
    std::string current;
    for (const char* cursor = terms; *cursor != '\0'; ++cursor) {
        if (*cursor == '|') {
            if (!current.empty()) {
                result.push_back(current);
            }
            current.clear();
        } else {
            current.push_back(*cursor);
        }
    }
    if (!current.empty()) {
        result.push_back(current);
    }
    return result;
}

std::vector<std::string> split_words(const std::string& text) {
    std::vector<std::string> result;
    std::string current;
    for (char character : text) {
        if (character == ' ' || character == '\t' || character == '-') {
            if (!current.empty()) {
                result.push_back(current);
                current.clear();
            }
        } else {
            current.push_back(character);
        }
    }
    if (!current.empty()) {
        result.push_back(current);
    }
    return result;
}

// How well one search token matches a type. Zero means no match at all.
int score_token(const NodeTypeDescriptor& type, const std::string& token) {
    const std::string name = lowercase(type.name);
    const std::string display = lowercase(type.display_name);
    const std::string summary = lowercase(type.summary);

    if (name == token || display == token) {
        return 1000;
    }

    int best = 0;
    if (name.rfind(token, 0) == 0 || display.rfind(token, 0) == 0) {
        best = std::max(best, 600);
    }
    if (name.find(token) != std::string::npos || display.find(token) != std::string::npos) {
        best = std::max(best, 400);
    }

    for (const std::string& term : split_terms(type.search_terms)) {
        if (term == token) {
            best = std::max(best, 500);
        } else if (term.rfind(token, 0) == 0) {
            best = std::max(best, 300);
        } else if (term.find(token) != std::string::npos) {
            best = std::max(best, 200);
        }
    }

    if (summary.find(token) != std::string::npos) {
        best = std::max(best, 100);
    }
    return best;
}

// Every word in the query has to land somewhere, so that "midi keyboard" finds the note
// input while "definitely not a node" finds nothing — rather than matching everything
// that happens to contain "not". The whole phrase is also scored and weighted double, so
// a type that lists the exact phrase a user typed still wins.
int score_type(const NodeTypeDescriptor& type, const std::string& query) {
    const std::vector<std::string> words = split_words(query);
    if (words.empty()) {
        return 0;
    }

    int total = score_token(type, query) * 2;
    if (words.size() == 1) {
        return total;
    }

    for (const std::string& word : words) {
        const int score = score_token(type, word);
        if (score == 0) {
            return 0;
        }
        total += score;
    }
    return total;
}

}  // namespace

NodeRegistry::NodeRegistry() {
    types_ = {
        &nodes::kNoteInput,
        &nodes::kNoteTriggers,
        &nodes::kTriggerBus,
        &nodes::kAudioInput,
        &nodes::kSineOscillator,
        &nodes::kSawOscillator,
        &nodes::kSquareOscillator,
        &nodes::kNoise,
        &nodes::kNoiseOscillator,
        &nodes::kSampler,
        &nodes::kStateVariableFilter,
        &nodes::kOnePoleFilter,
        &nodes::kDelay,
        &nodes::kComb,
        &nodes::kAllpass,
        &nodes::kPhaser,
        &nodes::kGain,
        &nodes::kLevel,
        &nodes::kStereoLevel,
        &nodes::kMixer,
        &nodes::kAdsr,
        &nodes::kAhdEnvelope,
        &nodes::kSlide,
        &nodes::kArpeggio,
        &nodes::kRetrigger,
        &nodes::kClock,
        &nodes::kScaleQuantizer,
        &nodes::kStepSequencer,
        &nodes::kEuclid,
        &nodes::kLfo,
        &nodes::kConstant,
        &nodes::kAdd,
        &nodes::kMultiply,
        &nodes::kClip,
        &nodes::kAbs,
        &nodes::kMinMax,
        &nodes::kCompare,
        &nodes::kSampleHold,
        &nodes::kDrive,
        &nodes::kCrush,
        &nodes::kCompressor,
        &nodes::kStereoOutput,
    };
}

const NodeRegistry& NodeRegistry::builtin() {
    static const NodeRegistry instance;
    return instance;
}

const NodeTypeDescriptor* NodeRegistry::find(const std::string& type_name) const {
    for (const NodeTypeDescriptor* type : types_) {
        if (type_name == type->name) {
            return type;
        }
    }
    return nullptr;
}

std::unique_ptr<DspNode> NodeRegistry::create(const std::string& type_name) const {
    const NodeTypeDescriptor* type = find(type_name);
    if (type == nullptr || type->create == nullptr) {
        return nullptr;
    }
    std::unique_ptr<DspNode> node = type->create();
    if (node) {
        node->initialize_parameters(type->parameters);
    }
    return node;
}

std::vector<const NodeTypeDescriptor*> NodeRegistry::search(const std::string& query) const {
    const std::string needle = lowercase(query);
    if (needle.empty()) {
        return types_;
    }

    std::vector<std::pair<int, const NodeTypeDescriptor*>> scored;
    for (const NodeTypeDescriptor* type : types_) {
        const int score = score_type(*type, needle);
        if (score > 0) {
            scored.emplace_back(score, type);
        }
    }

    // Stable sort so that equally-scoring types keep registry order, which is roughly
    // signal-flow order and reads sensibly in a palette.
    std::stable_sort(scored.begin(), scored.end(),
                     [](const std::pair<int, const NodeTypeDescriptor*>& a,
                        const std::pair<int, const NodeTypeDescriptor*>& b) {
                         return a.first > b.first;
                     });

    std::vector<const NodeTypeDescriptor*> result;
    result.reserve(scored.size());
    for (const auto& entry : scored) {
        result.push_back(entry.second);
    }
    return result;
}

}  // namespace soundgraph
