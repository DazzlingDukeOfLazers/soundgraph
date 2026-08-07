// Internal: the built-in node type table, assembled by registry.cpp.
#pragma once

#include "soundgraph/node.h"

namespace soundgraph {
namespace nodes {

// Sources
extern const NodeTypeDescriptor kSineOscillator;
extern const NodeTypeDescriptor kSawOscillator;
extern const NodeTypeDescriptor kSquareOscillator;
extern const NodeTypeDescriptor kNoise;
extern const NodeTypeDescriptor kLfo;
extern const NodeTypeDescriptor kConstant;

// Filters and time
extern const NodeTypeDescriptor kStateVariableFilter;
extern const NodeTypeDescriptor kDelay;

// Amplitude and maths
extern const NodeTypeDescriptor kGain;
extern const NodeTypeDescriptor kMixer;
extern const NodeTypeDescriptor kAdsr;
extern const NodeTypeDescriptor kAdd;
extern const NodeTypeDescriptor kMultiply;

// Terminals
extern const NodeTypeDescriptor kNoteInput;
extern const NodeTypeDescriptor kAudioInput;
extern const NodeTypeDescriptor kStereoOutput;

}  // namespace nodes
}  // namespace soundgraph
