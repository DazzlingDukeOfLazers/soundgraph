// sgaxo kernel library: dsp-core node inner loops, restated for the Axoloti's
// bare-metal patch environment. Every kernel is a line-for-line restatement of
// the corresponding dsp-core node's process() (dsp-core/src/nodes/*.cpp) — the
// golden-vector comparisons in tests/test_sgaxo.py are what keep them honest.
//
// Kernels run on dsp-core's native 64-frame blocks (SGAXO_FRAMES); the runtime
// FIFOs the result out to the codec's 16-frame cycles. Running at the native
// block size is not an optimization: per-block semantics (the SVF sampling its
// modulation at block start, events landing on block boundaries) are part of
// what the golden vectors recorded.
//
// Transcendentals: coefficients derived only from parameters are precomputed
// by the codegen on the host in double precision and arrive here as literals —
// bit-identical to what native computed. Only per-block modulation math runs
// on the board (exp2/tan below), as short polynomials whose error is far under
// the golden tolerance at audio-filter ranges.

#ifndef SGAXO_KERNELS_H
#define SGAXO_KERNELS_H

#include <stdint.h>

#include "sine_table.h"  // dsp-core's committed table, via -I

#define SGAXO_FRAMES 64  // == soundgraph::kBlockSize

typedef struct {
  int frame;
  int note_on;
  int note;
  float velocity;
} sgaxo_event_t;


namespace sgaxo {

using soundgraph::dsp::kSineTable;
using soundgraph::dsp::kSineTableSize;

// --- dsp_math.h, verbatim ----------------------------------------------------

inline float clampf(float value, float low, float high) {
  return value < low ? low : (value > high ? high : value);
}

inline float sine01(float phase01) {
  const float scaled = phase01 * static_cast<float>(kSineTableSize);
  const int index = static_cast<int>(scaled);
  const float fraction = scaled - static_cast<float>(index);
  const float a = kSineTable[index];
  const float b = kSineTable[index + 1];
  return a + (b - a) * fraction;
}

inline float wrap01(float phase) {
  while (phase >= 1.0f) phase -= 1.0f;
  while (phase < 0.0f) phase += 1.0f;
  return phase;
}

inline float poly_blep(float t, float dt) {
  if (dt <= 0.0f) return 0.0f;
  if (t < dt) {
    const float x = t / dt;
    return x + x - x * x - 1.0f;
  }
  if (t > 1.0f - dt) {
    const float x = (t - 1.0f) / dt;
    return x * x + x + x + 1.0f;
  }
  return 0.0f;
}

class Xorshift32 {
 public:
  // Zero-initialized so instances land in .bss (the patch .data section is
  // NOLOAD — see ramlink.ld); the generated init body must call seed().
  Xorshift32() : state_(0) {}
  void seed(unsigned int value) { state_ = (value == 0 ? 0x9E3779B9u : value); }
  unsigned int next_uint() {
    state_ ^= state_ << 13;
    state_ ^= state_ >> 17;
    state_ ^= state_ << 5;
    return state_;
  }
  float next_bipolar() {
    return static_cast<float>(next_uint() >> 8) * (1.0f / 8388608.0f) - 1.0f;
  }

 private:
  unsigned int state_;
};

// --- board-side transcendentals (per-block modulation only) ------------------

// 2^x. Exact for integer x (the polynomial is 1 at 0); relative error < 4e-8
// on the fractional part — far inside golden tolerance for modulated cutoffs.
inline float exp2f_approx(float x) {
  const float xf = x < -126.0f ? -126.0f : (x > 127.0f ? 127.0f : x);
  const int ip = (int)xf - (xf < (float)(int)xf ? 1 : 0);  // floor
  const float r = xf - (float)ip;                          // [0,1)
  // Degree-6 minimax for 2^r on [0,1), constrained to 1 at r=0.
  const float p = 1.0f +
      r * (0.69314718056f +
      r * (0.24022650695f +
      r * (0.05550411502f +
      r * (0.00961804886f +
      r * (0.00133335581f +
      r *  0.00015400290f)))));
  union { uint32_t u; float f; } s;
  s.u = (uint32_t)(ip + 127) << 23;  // 2^ip
  return p * s.f;
}

// sin(x) for |x| <= pi/2, odd minimax polynomial (error ~1e-8 absolute).
inline float sinf_poly(float x) {
  const float x2 = x * x;
  return x * (0.9999999995f +
         x2 * (-0.1666666579f +
         x2 * (0.0083333076f +
         x2 * (-0.0001984090f +
         x2 * 0.0000027526f))));
}

// tan(pi * x) for x in (0, 0.475): sin/cos from the poly (cos via co-angle).
inline float tan_pi(float x) {
  const float a = 3.14159265358979f * x;
  return sinf_poly(a) / sinf_poly(1.57079632679490f - a);
}

// tanh for the output safety limiter, |error| < 1e-6. Only reached when a
// sample exceeds full scale, which a well-behaved patch never does.
inline float tanhf_approx(float x) {
  if (x > 9.0f) return 1.0f;
  if (x < -9.0f) return -1.0f;
  const float e = exp2f_approx(2.885390082f * x);  // e^(2x)
  return (e - 1.0f) / (e + 1.0f);
}

// note -> Hz, A4 = 69 = 440. exp2f_approx is exact at integer semitone/12
// lattice points that land on integers; elsewhere ~4e-8 relative.
inline float note_to_frequency(float note) {
  return 440.0f * exp2f_approx((note - 69.0f) * (1.0f / 12.0f));
}

// --- oscillators (sources.cpp OscillatorBase) --------------------------------
// Supported subset: frequency input or parameter; fm/pm/feedback and non-sine
// shapes are refused by the codegen.

struct OscState {
  float phase;
  float hist_a;
  float hist_b;
};

template <typename RenderFn>
inline void k_osc(OscState &s, const float *frequency_in, float *out,
                  float base_frequency, float sample_rate, RenderFn render) {
  const float nyquist = sample_rate * 0.5f;
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    float frequency = frequency_in != 0 ? frequency_in[i] : base_frequency;
    frequency = clampf(frequency, 0.0f, nyquist);
    const float increment = frequency / sample_rate;
    out[i] = render(s.phase, increment);
    s.hist_b = s.hist_a;
    s.hist_a = out[i];
    s.phase = wrap01(s.phase + increment);
  }
}

inline void k_sine(OscState &s, const float *frequency_in, float *out,
                   float base_frequency, float sample_rate) {
  k_osc(s, frequency_in, out, base_frequency, sample_rate,
        [](float phase, float) { return sine01(phase); });
}

inline void k_saw(OscState &s, const float *frequency_in, float *out,
                  float base_frequency, float sample_rate) {
  k_osc(s, frequency_in, out, base_frequency, sample_rate,
        [](float phase, float increment) {
          return (2.0f * phase - 1.0f) - poly_blep(phase, increment);
        });
}

inline void k_square(OscState &s, const float *frequency_in, float *out,
                     float base_frequency, float width_param,
                     float sample_rate) {
  // SquareOscillator::render with pulse_width_sweep == 0 (codegen-enforced).
  const float width = clampf(width_param, 0.01f, 0.99f);
  k_osc(s, frequency_in, out, base_frequency, sample_rate,
        [width](float phase, float increment) {
          float value = phase < width ? 1.0f : -1.0f;
          value += poly_blep(phase, increment);
          value -= poly_blep(wrap01(phase + (1.0f - width)), increment);
          return value;
        });
}

// --- Noise (sources.cpp NoiseNode) ------------------------------------------

struct NoiseState {
  Xorshift32 rng;       // generated init body seeds with the seed parameter
  float pink_state[3];
};

inline void k_noise(NoiseState &s, float *out, int pink) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    const float white = s.rng.next_bipolar();
    if (!pink) {
      out[i] = white;
      continue;
    }
    s.pink_state[0] = 0.99765f * s.pink_state[0] + white * 0.0990460f;
    s.pink_state[1] = 0.96300f * s.pink_state[1] + white * 0.2965164f;
    s.pink_state[2] = 0.57000f * s.pink_state[2] + white * 1.0526913f;
    out[i] = (s.pink_state[0] + s.pink_state[1] + s.pink_state[2] +
              white * 0.1848f) * 0.25f;
  }
}

// --- Delay (filters.cpp DelayNode) ------------------------------------------
// The line lives in SDRAM (.sdram section, NOLOAD — the generated init body
// zeroes it, which is DelayNode::reset()). Capacity mirrors prepare():
// int(sample_rate * 2.0s) + 4.

#define SGAXO_DELAY_CAPACITY 96004

struct DelayState {
  int write_index;
};

inline void k_delay(DelayState &s, float *line, const float *in,
                    const float *time_in, const float *feedback_in, float *out,
                    float time_param, float feedback_param, float mix,
                    float sample_rate) {
  const int capacity = SGAXO_DELAY_CAPACITY;
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    const float time = time_in != 0 ? time_in[i] : time_param;
    const float feedback =
        clampf(feedback_in != 0 ? feedback_in[i] : feedback_param, 0.0f, 0.99f);
    const float delay_samples = clampf(time, 0.001f, 2.0f) * sample_rate;
    float read_position = (float)s.write_index - delay_samples;
    while (read_position < 0.0f) read_position += (float)capacity;
    const int index0 = (int)read_position;
    const int index1 = (index0 + 1) % capacity;
    const float fraction = read_position - (float)index0;
    const float delayed = line[index0 % capacity] * (1.0f - fraction) +
                          line[index1] * fraction;
    const float dry = in != 0 ? in[i] : 0.0f;
    line[s.write_index] = dry + delayed * feedback;
    s.write_index = (s.write_index + 1) % capacity;
    out[i] = dry * (1.0f - mix) + delayed * mix;
  }
}

// --- AhdEnvelope (shaping.cpp AhdEnvelopeNode) -------------------------------

struct AhdState {
  int stage;  // 0 idle, 1 attack, 2 hold, 3 decay
  float elapsed;
  float level;
  int gate_was_open;
};

inline void k_ahd(AhdState &s, const float *gate, float *out, float attack,
                  float hold, float decay, float punch, float dt) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    const int open = gate != 0 && gate[i] >= 0.5f;
    if (open && !s.gate_was_open) {
      s.stage = 1;
      s.elapsed = 0.0f;
    }
    s.gate_was_open = open;
    switch (s.stage) {
      case 0:
        s.level = 0.0f;
        break;
      case 1:
        if (s.elapsed >= attack) {
          s.stage = 2;
          s.elapsed = 0.0f;
          s.level = 1.0f + 2.0f * punch;
        } else {
          s.level = s.elapsed / attack;
        }
        break;
      case 2:
        if (s.elapsed >= hold) {
          s.stage = 3;
          s.elapsed = 0.0f;
          s.level = 1.0f;
        } else {
          s.level = 1.0f + 2.0f * punch * (1.0f - s.elapsed / hold);
        }
        break;
      case 3:
        if (s.elapsed >= decay) {
          s.stage = 0;
          s.elapsed = 0.0f;
          s.level = 0.0f;
        } else {
          s.level = 1.0f - s.elapsed / decay;
        }
        break;
    }
    out[i] = s.level;
    s.elapsed += dt;
  }
}

// --- Retrigger (shaping.cpp RetriggerNode) -----------------------------------

struct RetriggerState {
  float elapsed;
};

inline void k_retrigger(RetriggerState &s, const float *rate_in, float *out,
                        float rate_param, float width_seconds, float dt) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    const float rate =
        clampf(rate_in != 0 ? rate_in[i] : rate_param, 0.1f, 200.0f);
    const float interval = 1.0f / rate;
    out[i] = s.elapsed < width_seconds ? 1.0f : 0.0f;
    s.elapsed += dt;
    if (s.elapsed >= interval) s.elapsed -= interval;
  }
}

// --- LFO (sources.cpp LfoNode) ----------------------------------------------

struct LfoState {
  float phase;
  float sample_and_hold;
  Xorshift32 rng;  // generated init body seeds with 0x5EED1234 (LfoNode::reset)
};

inline void k_lfo(LfoState &s, const float *rate_in, float *out, float rate,
                  int shape, float amount, float offset, float sample_rate) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    const float r = rate_in != 0 ? rate_in[i] : rate;
    const float increment = clampf(r, 0.0f, sample_rate * 0.5f) / sample_rate;
    float value;
    switch (shape) {
      default:
      case 0: value = sine01(s.phase); break;
      case 1: {
        float d = s.phase - 0.5f;
        value = 4.0f * (d < 0 ? -d : d) - 1.0f;
        break;
      }
      case 2: value = (2.0f * s.phase - 1.0f) - poly_blep(s.phase, increment); break;
      case 3: value = s.phase < 0.5f ? 1.0f : -1.0f; break;
      case 4: value = s.sample_and_hold; break;
    }
    out[i] = offset + amount * value;
    const float next_phase = s.phase + increment;
    if (shape == 4 && next_phase >= 1.0f) {
      s.sample_and_hold = s.rng.next_bipolar();
    }
    s.phase = wrap01(next_phase);
  }
}

// --- StateVariableFilter (filters.cpp StateVariableFilterNode) ---------------
// Supported subset: cutoff sweep must be 0 (its per-block pow accumulates
// against a host-precomputed schedule we don't replicate yet).

struct SvfState {
  float ic1;
  float ic2;
};

inline void k_svf(SvfState &s, const float *in, const float *cutoff_in,
                  const float *cutoff_mod_in, const float *resonance_in,
                  float *out, float cutoff_param, float resonance_param,
                  int mode, float sample_rate) {
  if (in == 0) {
    for (int i = 0; i < SGAXO_FRAMES; ++i) out[i] = 0.0f;
    return;
  }
  float cutoff = cutoff_in != 0 ? cutoff_in[0] : cutoff_param;
  if (cutoff_mod_in != 0) {
    cutoff *= exp2f_approx(cutoff_mod_in[0]);
  }
  cutoff = clampf(cutoff, 10.0f, sample_rate * 0.45f);
  float resonance = resonance_in != 0 ? resonance_in[0] : resonance_param;
  resonance = clampf(resonance, 0.0f, 1.0f);
  const float k = 2.0f - 1.95f * resonance;
  const float g = tan_pi(cutoff / sample_rate);
  const float a1 = 1.0f / (1.0f + g * (g + k));
  const float a2 = g * a1;
  const float a3 = g * a2;
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    const float input = in[i];
    const float v3 = input - s.ic2;
    const float v1 = a1 * s.ic1 + a2 * v3;
    const float v2 = s.ic2 + a2 * s.ic1 + a3 * v3;
    s.ic1 = 2.0f * v1 - s.ic1;
    s.ic2 = 2.0f * v2 - s.ic2;
    switch (mode) {
      case 0: out[i] = v2; break;
      case 1: out[i] = input - k * v1 - v2; break;
      case 2: out[i] = v1; break;
      default: out[i] = input - k * v1; break;
    }
  }
}

// --- ADSR (amplitude.cpp AdsrNode) ------------------------------------------
// attack_step / decay_coefficient / release_coefficient are codegen-baked
// (host computed exp() in double, bit-identical to native's float result).

struct AdsrState {
  int stage;  // 0 idle, 1 attack, 2 decay, 3 sustain, 4 release
  float level;
  int gate_open;
};

inline void k_adsr(AdsrState &s, const float *gate, float *out,
                   float attack_step, float decay_coefficient, float sustain,
                   float release_coefficient) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    const int gate_now = gate != 0 && gate[i] >= 0.5f;
    if (gate_now && !s.gate_open) s.stage = 1;
    else if (!gate_now && s.gate_open) s.stage = 4;
    s.gate_open = gate_now;
    switch (s.stage) {
      case 0: s.level = 0.0f; break;
      case 1:
        s.level += attack_step;
        if (s.level >= 1.0f) { s.level = 1.0f; s.stage = 2; }
        break;
      case 2: {
        s.level = sustain + (s.level - sustain) * decay_coefficient;
        float d = s.level - sustain;
        if ((d < 0 ? -d : d) < 1.0e-4f) { s.level = sustain; s.stage = 3; }
        break;
      }
      case 3: s.level = sustain; break;
      case 4:
        s.level *= release_coefficient;
        if (s.level < 1.0e-5f) { s.level = 0.0f; s.stage = 0; }
        break;
    }
    out[i] = s.level;
  }
}

// --- NoteInput (terminals.cpp NoteInputNode) ---------------------------------
// glide_coefficient is codegen-baked (0 when glide is 0, exp() otherwise).

#define SGAXO_MAX_HELD_NOTES 16

struct NoteState {
  int held_notes[SGAXO_MAX_HELD_NOTES];
  int held_count;
  float gate;
  int trigger_remaining;
  float velocity;
  float target_note;   // init to 60 by the runtime
  float current_note;  // init to 60 by the runtime
};

inline void note_remove(NoteState &s, int note) {
  int write = 0;
  for (int read = 0; read < s.held_count; ++read) {
    if (s.held_notes[read] != note) s.held_notes[write++] = s.held_notes[read];
  }
  s.held_count = write;
}

inline void note_event(NoteState &s, int on, int note, float velocity,
                       float sample_rate) {
  if (on) {
    note_remove(s, note);
    if (s.held_count >= SGAXO_MAX_HELD_NOTES) {
      for (int i = 1; i < SGAXO_MAX_HELD_NOTES; ++i)
        s.held_notes[i - 1] = s.held_notes[i];
      s.held_count = SGAXO_MAX_HELD_NOTES - 1;
    }
    s.held_notes[s.held_count++] = note;
    s.velocity = clampf(velocity, 0.0f, 1.0f);
    s.gate = 1.0f;
    const int trig = (int)(sample_rate * 0.001f);
    s.trigger_remaining = trig > 1 ? trig : 1;
  } else {
    note_remove(s, note);
    if (s.held_count == 0) s.gate = 0.0f;
  }
  if (s.held_count > 0) {
    s.target_note = (float)s.held_notes[s.held_count - 1];
  }
}

inline void k_note_input(NoteState &s, float *frequency_out, float *gate_out,
                         float *velocity_out, float *trigger_out,
                         float glide_coefficient, float transpose) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    s.current_note =
        s.target_note + (s.current_note - s.target_note) * glide_coefficient;
    if (frequency_out) frequency_out[i] = note_to_frequency(s.current_note + transpose);
    if (gate_out) gate_out[i] = s.gate;
    if (velocity_out) velocity_out[i] = s.velocity;
    if (trigger_out) trigger_out[i] = s.trigger_remaining > 0 ? 1.0f : 0.0f;
    if (s.trigger_remaining > 0) --s.trigger_remaining;
  }
}

// --- Constant (sources.cpp ConstantNode) -------------------------------------

inline void k_constant(float *out, float value) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) out[i] = value;
}

// --- Add / Multiply (amplitude.cpp AddNode / MultiplyNode) -------------------
// The parameter stands in for the b input while it is unconnected.

inline void k_add(const float *a, const float *b, float *out, float offset) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    out[i] = (a != 0 ? a[i] : 0.0f) + (b != 0 ? b[i] : offset);
  }
}

inline void k_multiply(const float *a, const float *b, float *out,
                       float factor) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    out[i] = (a != 0 ? a[i] : 0.0f) * (b != 0 ? b[i] : factor);
  }
}

// --- Mixer (amplitude.cpp MixerNode) -----------------------------------------
// Channel order is the accumulation order; float addition is not associative,
// so it must match the node's channel loop exactly.

inline void k_mixer(const float *in1, const float *in2, const float *in3,
                    const float *in4, float *out, float level1, float level2,
                    float level3, float level4) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) out[i] = 0.0f;
  const float *ins[4] = {in1, in2, in3, in4};
  const float levels[4] = {level1, level2, level3, level4};
  for (int channel = 0; channel < 4; ++channel) {
    const float *in = ins[channel];
    if (in == 0) continue;
    const float level = levels[channel];
    for (int i = 0; i < SGAXO_FRAMES; ++i) out[i] += in[i] * level;
  }
}

// --- Gain (amplitude.cpp GainNode) ------------------------------------------

inline void k_gain(const float *in, const float *gain_in, float *out,
                   float gain) {
  for (int i = 0; i < SGAXO_FRAMES; ++i) {
    const float sample = in != 0 ? in[i] : 0.0f;
    const float modulation = gain_in != 0 ? gain_in[i] : 1.0f;
    out[i] = sample * gain * modulation;
  }
}

// --- StereoOutput (terminals.cpp StereoOutputNode) ---------------------------

inline void k_stereo_output(const float *left_in, const float *right_in,
                            float *out_l, float *out_r, float level,
                            int limit) {
  if (right_in == 0) right_in = left_in;
  const float *sources[2] = {left_in, right_in};
  float *outs[2] = {out_l, out_r};
  for (int channel = 0; channel < 2; ++channel) {
    float *out = outs[channel];
    const float *in = sources[channel];
    for (int i = 0; i < SGAXO_FRAMES; ++i) {
      float sample = (in != 0 ? in[i] : 0.0f) * level;
      if (limit && (sample > 1.0f || sample < -1.0f)) {
        sample = tanhf_approx(sample);
      }
      out[i] = sample;
    }
  }
}

}  // namespace sgaxo

#endif  // SGAXO_KERNELS_H
