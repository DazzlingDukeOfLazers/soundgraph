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
extern const NodeTypeDescriptor kNoiseOscillator;
extern const NodeTypeDescriptor kLfo;
extern const NodeTypeDescriptor kConstant;

// Filters and time
extern const NodeTypeDescriptor kStateVariableFilter;
extern const NodeTypeDescriptor kOnePoleFilter;
extern const NodeTypeDescriptor kDelay;
extern const NodeTypeDescriptor kPhaser;

// Shaping: envelopes, pitch movement and retriggering
extern const NodeTypeDescriptor kAhdEnvelope;
extern const NodeTypeDescriptor kSlide;
extern const NodeTypeDescriptor kArpeggio;
extern const NodeTypeDescriptor kRetrigger;
extern const NodeTypeDescriptor kClock;

// Amplitude and maths
extern const NodeTypeDescriptor kGain;
extern const NodeTypeDescriptor kLevel;
extern const NodeTypeDescriptor kStereoLevel;
extern const NodeTypeDescriptor kMixer;
extern const NodeTypeDescriptor kAdsr;
extern const NodeTypeDescriptor kAdd;
extern const NodeTypeDescriptor kMultiply;
extern const NodeTypeDescriptor kClip;
extern const NodeTypeDescriptor kAbs;
extern const NodeTypeDescriptor kMinMax;
extern const NodeTypeDescriptor kCompare;
extern const NodeTypeDescriptor kSampleHold;
extern const NodeTypeDescriptor kDrive;

// Terminals
extern const NodeTypeDescriptor kNoteInput;
extern const NodeTypeDescriptor kNoteTriggers;
extern const NodeTypeDescriptor kTriggerBus;
extern const NodeTypeDescriptor kAudioInput;
extern const NodeTypeDescriptor kStereoOutput;

}  // namespace nodes
}  // namespace soundgraph
