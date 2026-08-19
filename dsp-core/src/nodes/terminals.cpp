// Terminals: where a graph meets whatever is hosting it.
//
// The runtime fills a HostAudioSource node's outputs before calling process(), and reads
// a HostAudioSink node's outputs after. That keeps the one genuinely target-specific
// thing — how samples reach a device — out of the nodes themselves.
#include <cmath>

#include "dsp_math.h"
#include "nodes/node_types.h"

namespace soundgraph {
namespace nodes {
namespace {

// ---------------------------------------------------------------------------------
// Note input
//
// Monophonic, last-note priority, with a held-note stack so that releasing the top note
// falls back to the one still held underneath. Polyphony is deliberately deferred; see
// docs/known-issues.md.
// ---------------------------------------------------------------------------------

constexpr int kMaxHeldNotes = 16;

constexpr PortDescriptor kNoteOutputs[] = {
    {"frequency", SignalType::Control, "Hz", false, false, "Pitch of the note being played."},
    {"gate", SignalType::Control, "", false, false, "1 while a note is held, 0 otherwise."},
    {"velocity", SignalType::Control, "", false, false, "How hard the note was struck, 0 to 1."},
    {"trigger", SignalType::Control, "", false, false,
     "A brief pulse on every note, including one played while another is still held. "
     "Use it for percussive sounds that should fire again each time a key goes down; "
     "gate is the one to use for anything that sustains."},
};

constexpr ParameterDescriptor kNoteParameters[] = {
    {"glide", "s", 0.0f, 2.0f, 0.0f, Scaling::Exponential,
     "Time to slide from the previous pitch to the new one. 0 jumps.", nullptr, 0},
    // Eight octaves each way, not the two a keyboard would need. A generated sound effect
    // is a transposing instrument: the mapper offsets the whole patch so that middle C
    // plays it at the pitch it was designed around, and across the sfxr corpus that offset
    // runs from -69.5 to +43.2 semitones. Clamped to two octaves, most of those patches
    // would have quietly played at the wrong pitch — parameters clamp on load, so the file
    // would still have said the right number.
    {"transpose", "semitones", -96.0f, 96.0f, 0.0f, Scaling::Linear,
     "Shifts every incoming note. 12 is one octave up.", nullptr, 0},
    // Read by the graph at build time, not by this node: the engine copies
    // everything downstream of this input once per voice and routes each note to
    // one copy. At 1 the graph is exactly the mono instrument it always was.
    {"voices", "", 1.0f, 16.0f, 1.0f, Scaling::Linear,
     "How many notes sound at once. Each voice is a full copy of everything "
     "downstream of this input; takes effect when the graph rebuilds.", nullptr, 0},
};

class NoteInputNode final : public DspNode {
public:
    enum Param { kGlide = 0, kTranspose = 1 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        held_count_ = 0;
        gate_ = 0.0f;
        velocity_ = 0.0f;
        target_note_ = 60.0f;
        current_note_ = 60.0f;
        trigger_remaining_ = 0;
    }

    void handle_note_event(const NoteEvent& event) override {
        switch (event.kind) {
            case NoteEvent::Kind::NoteOn:
                push_note(event.note);
                velocity_ = dsp::clampf(event.velocity, 0.0f, 1.0f);
                gate_ = 1.0f;
                // Every note, not every *first* note. A gate that is already high stays
                // high when a second key goes down, which is right for anything that
                // sustains and wrong for a drum: roll two keys together and a one-shot
                // envelope sees no new edge and stays silent. The pulse is what carries
                // "a note started" through a signal that otherwise only carries "a note
                // is being held".
                trigger_remaining_ = trigger_samples();
                break;
            case NoteEvent::Kind::NoteOff:
                remove_note(event.note);
                if (held_count_ == 0) {
                    gate_ = 0.0f;
                }
                break;
            case NoteEvent::Kind::AllNotesOff:
                held_count_ = 0;
                gate_ = 0.0f;
                break;
        }
        if (held_count_ > 0) {
            target_note_ = static_cast<float>(held_notes_[held_count_ - 1]);
        }
    }

    void process(const ProcessContext& context) override {
        float* frequency_out = context.outputs[0];
        float* gate_out = context.outputs[1];
        float* velocity_out = context.outputs[2];
        float* trigger_out = context.outputs[3];

        const float glide = parameter(kGlide);
        const float transpose = parameter(kTranspose);
        // Glide runs in note space rather than hertz, so a slide covers the same musical
        // distance whether it starts low or high.
        const float coefficient =
            glide > 0.0f ? std::exp(-6.907755f / (glide * sample_rate_)) : 0.0f;

        for (int i = 0; i < context.frames; ++i) {
            current_note_ = target_note_ + (current_note_ - target_note_) * coefficient;
            frequency_out[i] = dsp::note_to_frequency(current_note_ + transpose);
            gate_out[i] = gate_;
            velocity_out[i] = velocity_;
            trigger_out[i] = trigger_remaining_ > 0 ? 1.0f : 0.0f;
            if (trigger_remaining_ > 0) {
                --trigger_remaining_;
            }
        }
    }

private:
    // A millisecond. One sample would be enough for anything reading per sample, but a
    // pulse shorter than a block is invisible to anything that samples at block rate, and
    // there is no reason to make that a trap for a future node.
    int trigger_samples() const {
        const int samples = static_cast<int>(sample_rate_ * 0.001f);
        return samples > 1 ? samples : 1;
    }

    void push_note(int note) {
        remove_note(note);
        if (held_count_ >= kMaxHeldNotes) {
            // Drop the oldest rather than the newest: the player expects the key they
            // just pressed to sound.
            for (int i = 1; i < kMaxHeldNotes; ++i) {
                held_notes_[i - 1] = held_notes_[i];
            }
            held_count_ = kMaxHeldNotes - 1;
        }
        held_notes_[held_count_++] = note;
    }

    void remove_note(int note) {
        int write = 0;
        for (int read = 0; read < held_count_; ++read) {
            if (held_notes_[read] != note) {
                held_notes_[write++] = held_notes_[read];
            }
        }
        held_count_ = write;
    }

    float sample_rate_ = 48000.0f;
    int held_notes_[kMaxHeldNotes] = {};
    int held_count_ = 0;
    float gate_ = 0.0f;
    int trigger_remaining_ = 0;
    float velocity_ = 0.0f;
    float target_note_ = 60.0f;
    float current_note_ = 60.0f;
};

// ---------------------------------------------------------------------------------
// Audio input
// ---------------------------------------------------------------------------------

constexpr PortDescriptor kAudioInputOutputs[] = {
    {"left", SignalType::Audio, "", false, false, "Left channel from the host."},
    {"right", SignalType::Audio, "", false, false, "Right channel from the host."},
};

constexpr ParameterDescriptor kAudioInputParameters[] = {
    {"gain", "", 0.0f, 4.0f, 1.0f, Scaling::Logarithmic, "Input level.", nullptr, 0},
};

class AudioInputNode final : public DspNode {
public:
    // The runtime has already written the host's samples into the output buffers.
    void process(const ProcessContext& context) override {
        const float gain = parameter(0);
        if (gain == 1.0f) {
            return;
        }
        for (int channel = 0; channel < 2; ++channel) {
            float* out = context.outputs[channel];
            for (int i = 0; i < context.frames; ++i) {
                out[i] *= gain;
            }
        }
    }
};

// ---------------------------------------------------------------------------------
// Stereo output
// ---------------------------------------------------------------------------------

constexpr const char* kSafetyLabels[] = {"off", "on"};

constexpr PortDescriptor kStereoInputs[] = {
    {"left", SignalType::Audio, "", true, true, "Left channel. Also used for the right if that is empty."},
    {"right", SignalType::Audio, "", false, true, "Right channel."},
};

constexpr PortDescriptor kStereoOutputs[] = {
    {"left", SignalType::Audio, "", false, false, "Post-level tap of the left channel."},
    {"right", SignalType::Audio, "", false, false, "Post-level tap of the right channel."},
};

constexpr ParameterDescriptor kStereoParameters[] = {
    {"level", "", 0.0f, 2.0f, 0.8f, Scaling::Logarithmic, "Master level.", nullptr, 0},
    {"safety_limit", "", 0.0f, 1.0f, 1.0f, Scaling::Linear,
     "Softly limits anything above full scale. Leave this on unless you know why not.",
     kSafetyLabels, 2},
};

class StereoOutputNode final : public DspNode {
public:
    enum Param { kLevel = 0, kSafetyLimit = 1 };

    void process(const ProcessContext& context) override {
        const float* left_in = context.inputs[0];
        const float* right_in = context.inputs[1];
        // A patch wired in mono should still come out of both speakers.
        if (right_in == nullptr) {
            right_in = left_in;
        }

        const float level = parameter(kLevel);
        const bool limit = parameter(kSafetyLimit) >= 0.5f;

        const float* sources[2] = {left_in, right_in};
        for (int channel = 0; channel < 2; ++channel) {
            float* out = context.outputs[channel];
            const float* in = sources[channel];
            for (int i = 0; i < context.frames; ++i) {
                float sample = (in != nullptr ? in[i] : 0.0f) * level;
                if (limit && (sample > 1.0f || sample < -1.0f)) {
                    // Soft knee above full scale. A runaway feedback loop should be
                    // startling, not damaging, in front of an audience.
                    sample = std::tanh(sample);
                }
                out[i] = sample;
            }
        }
    }
};

template <typename T>
std::unique_ptr<DspNode> make() {
    return std::unique_ptr<DspNode>(new T());
}

}  // namespace

// ---------------------------------------------------------------------------------
// Note triggers
//
// The drum-routing brain: eight trigger outlets, one per chromatic step up from a
// base note, so the bottom of the keyboard becomes a row of drum pads and a piano
// roll's lanes become drum lanes. A note outside the eight is simply not for this
// node. The pulses are the same one-millisecond edge NoteInput's own trigger
// carries, because a drum wants an edge, not a level.
// ---------------------------------------------------------------------------------

constexpr int kTriggerLanes = 8;

constexpr PortDescriptor kNoteTriggersOutputs[] = {
    {"t1", SignalType::Control, "", false, false, "Fires on the base note."},
    {"t2", SignalType::Control, "", false, false, "Fires one semitone above the base."},
    {"t3", SignalType::Control, "", false, false, "Fires two semitones above the base."},
    {"t4", SignalType::Control, "", false, false, "Fires three semitones above the base."},
    {"t5", SignalType::Control, "", false, false, "Fires four semitones above the base."},
    {"t6", SignalType::Control, "", false, false, "Fires five semitones above the base."},
    {"t7", SignalType::Control, "", false, false, "Fires six semitones above the base."},
    {"t8", SignalType::Control, "", false, false, "Fires seven semitones above the base."},
};

constexpr ParameterDescriptor kNoteTriggersParameters[] = {
    {"base", "note", 0.0f, 120.0f, 48.0f, Scaling::Linear,
     "The note that fires the first outlet; each outlet above it is one semitone up. "
     "48 is C3, where the keyboard opens.", nullptr, 0},
};

class NoteTriggersNode final : public DspNode {
public:
    enum Param { kBase = 0 };

    void prepare(const PrepareContext& context) override {
        sample_rate_ = static_cast<float>(context.sample_rate);
        reset();
    }

    void reset() override {
        for (int lane = 0; lane < kTriggerLanes; ++lane) {
            remaining_[lane] = 0;
        }
    }

    void handle_note_event(const NoteEvent& event) override {
        if (event.kind != NoteEvent::Kind::NoteOn) {
            return;  // a trigger has no other side to let go of
        }
        const int lane = event.note - static_cast<int>(parameter(kBase) + 0.5f);
        if (lane >= 0 && lane < kTriggerLanes) {
            remaining_[lane] = pulse_samples();
        }
    }

    void process(const ProcessContext& context) override {
        for (int lane = 0; lane < kTriggerLanes; ++lane) {
            float* out = context.outputs[lane];
            for (int i = 0; i < context.frames; ++i) {
                out[i] = remaining_[lane] > 0 ? 1.0f : 0.0f;
                if (remaining_[lane] > 0) {
                    --remaining_[lane];
                }
            }
        }
    }

private:
    int pulse_samples() const {
        const int samples = static_cast<int>(sample_rate_ * 0.001f);
        return samples > 1 ? samples : 1;
    }

    float sample_rate_ = 48000.0f;
    int remaining_[kTriggerLanes] = {};
};

const NodeTypeDescriptor kNoteTriggers = {
    // Modulation, not Terminals, and the filing matters: importing a patch as a
    // device drops terminal nodes because the host replaces them — its keyboard,
    // its speakers. Nothing replaces a note router; filed as a terminal, the 808
    // kit arrived with its pads stripped out and every gate cable gone with them.
    "NoteTriggers", "Note Triggers", "Modulation",
    "Eight triggers from eight chromatic notes: the keyboard as a row of drum pads.",
    "trigger|drum|pad|kit|split|map|note to trigger|drum machine",
    Slice<PortDescriptor>(),
    Slice<PortDescriptor>(kNoteTriggersOutputs),
    Slice<ParameterDescriptor>(kNoteTriggersParameters),
    false, NodeRole::Processor, true,
    ResourceCost{0.5f, 64, 0},
    &make<NoteTriggersNode>,
};

const NodeTypeDescriptor kNoteInput = {
    "NoteInput", "Note Input", "Terminals",
    "Turns played notes into pitch, gate and velocity signals.",
    "note|midi|keyboard|key|play|pitch|gate|velocity|trigger|input",
    Slice<PortDescriptor>(),
    Slice<PortDescriptor>(kNoteOutputs),
    Slice<ParameterDescriptor>(kNoteParameters),
    false, NodeRole::Processor, true,
    ResourceCost{1.0f, 96, 0},
    &make<NoteInputNode>,
};

const NodeTypeDescriptor kAudioInput = {
    "AudioInput", "Audio Input", "Terminals",
    "Live audio from the host: a microphone, an instrument, or a DAW track.",
    "audio input|input|mic|microphone|line in|guitar|live|record|adc",
    Slice<PortDescriptor>(),
    Slice<PortDescriptor>(kAudioInputOutputs),
    Slice<ParameterDescriptor>(kAudioInputParameters),
    false, NodeRole::HostAudioSource, false,
    ResourceCost{1.0f, 0, 0},
    &make<AudioInputNode>,
};

const NodeTypeDescriptor kStereoOutput = {
    "StereoOutput", "Stereo Output", "Terminals",
    "Where the patch leaves the graph and reaches the speakers.",
    "output|out|speakers|master|dac|stereo|headphones|listen",
    Slice<PortDescriptor>(kStereoInputs),
    Slice<PortDescriptor>(kStereoOutputs),
    Slice<ParameterDescriptor>(kStereoParameters),
    false, NodeRole::HostAudioSink, false,
    ResourceCost{1.0f, 0, 0},
    &make<StereoOutputNode>,
};

}  // namespace nodes
}  // namespace soundgraph
