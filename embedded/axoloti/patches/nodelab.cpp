// How many *soundgraph* nodes fit, as opposed to raw oscillators?
//
// This patch runs faithful ports of dsp-core node inner loops — float math,
// per-sample null-checks, per-block coefficient computation, indirect dispatch
// per node per 16-frame block, per-node output buffers, and a summing mix pass
// — i.e. the costs a real scheduled graph pays, minus JSON and setup (which
// never run in steady state anyway). The oscillator reads the repo's actual
// committed sine table (dsp-core/src/sine_table.h), so its per-sample work is
// exactly the shipped SineOscillator's: clamp, phase advance, 4096-entry lerp.
//
// Ported loops (kept in step with dsp-core by eye, they are ~10 lines each):
//   sine  — sources.cpp OscillatorBase::process, sine shape, nothing connected
//   svf   — filters.cpp StateVariableFilterNode: Simper SVF, coeffs per block
//           (tan built from the same sine table; the board has no libm)
//   gain  — amplitude.cpp GainNode, with its modulation input connected
//
// Two host-controlled populations:
//   ctrl_nsine  standalone Sine nodes, outputs summed by a mix pass
//   ctrl_nvoice Sine -> SVF -> Gain chains (3 nodes each; the Gain's
//               modulation input fed by one shared 2 Hz LFO node), summed
//
// The mix goes to the shared-memory sink, not the audio path: the loopback
// tone from sg_lab.h stays deterministic, so overload shows up in the analyzer.

#include "axo_abi.h"
#include "sg_shm.h"
#include "sg_lab.h"

#include "sine_table.h"  // the real dsp-core table, via -I

#define NODELAB_ID 0x4E4F4431u  // "NOD1"

#define MAX_NODES 320  // sized to CCM: ~40 B state + 64 B buffer per node
#define MAX_VOICES ((MAX_NODES - 1) / 3)
#define SAMPLE_RATE 48000.0f

using soundgraph::dsp::kSineTable;
using soundgraph::dsp::kSineTableSize;

static inline float clampf(float v, float lo, float hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

// dsp_math.h sine01, verbatim.
static inline float sine01(float phase01) {
  const float scaled = phase01 * (float)kSineTableSize;
  const int index = (int)scaled;
  const float fraction = scaled - (float)index;
  const float a = kSineTable[index];
  const float b = kSineTable[index + 1];
  return a + (b - a) * fraction;
}

// tan(pi * x) for x in (0, 0.45), from the same table (no libm on the board).
// Only runs once per node per block, like the SVF's std::tan upstream.
static inline float tan_pi(float x) {
  const float s = sine01(x * 0.5f);
  float cphase = x * 0.5f + 0.25f;
  if (cphase >= 1.0f) cphase -= 1.0f;
  const float c = sine01(cphase);
  return s / c;
}

struct Node;
typedef void (*node_fn)(Node *);

struct Node {
  node_fn process;
  const float *in;    // null when unconnected, exactly like the scheduler
  const float *mod;   // second input (gain modulation)
  float *out;
  float p0, p1;       // parameters
  float s0, s1, s2;   // state
};

static Node nodes[MAX_NODES];
static float buffers[MAX_NODES][AXO_BUFSIZE];
static float lfo_buffer[AXO_BUFSIZE];
static float mix[AXO_BUFSIZE];
static int mix_src_count;
static const float *mix_src[MAX_NODES];

// sources.cpp OscillatorBase::process, sine shape, no inputs connected:
// the per-sample nullptr checks and the nyquist clamp are the real node's.
static void sine_process(Node *n) {
  const float *frequency_in = n->in;
  float *out = n->out;
  const float base_frequency = n->p0;
  const float nyquist = SAMPLE_RATE * 0.5f;
  float phase = n->s0;
  for (int i = 0; i < AXO_BUFSIZE; ++i) {
    float frequency = frequency_in != 0 ? frequency_in[i] : base_frequency;
    frequency = clampf(frequency, 0.0f, nyquist);
    const float increment = frequency / SAMPLE_RATE;
    out[i] = sine01(phase);
    phase += increment;
    while (phase >= 1.0f) phase -= 1.0f;
  }
  n->s0 = phase;
}

// filters.cpp StateVariableFilterNode::process, lowpass, coeffs per block.
static void svf_process(Node *n) {
  const float *in = n->in;
  float *out = n->out;
  if (in == 0) {
    for (int i = 0; i < AXO_BUFSIZE; ++i) out[i] = 0.0f;
    return;
  }
  const float cutoff = clampf(n->p0, 10.0f, SAMPLE_RATE * 0.45f);
  const float resonance = clampf(n->p1, 0.0f, 1.0f);
  const float k = 2.0f - 1.95f * resonance;
  const float g = tan_pi(cutoff / SAMPLE_RATE);
  const float a1 = 1.0f / (1.0f + g * (g + k));
  const float a2 = g * a1;
  const float a3 = g * a2;
  float ic1 = n->s0, ic2 = n->s1;
  for (int i = 0; i < AXO_BUFSIZE; ++i) {
    const float input = in[i];
    const float v3 = input - ic2;
    const float v1 = a1 * ic1 + a2 * v3;
    const float v2 = ic2 + a2 * ic1 + a3 * v3;
    ic1 = 2.0f * v1 - ic1;
    ic2 = 2.0f * v2 - ic2;
    out[i] = v2;  // lowpass
  }
  n->s0 = ic1;
  n->s1 = ic2;
}

// amplitude.cpp GainNode::process, modulation input connected.
static void gain_process(Node *n) {
  const float *in = n->in;
  const float *gain_in = n->mod;
  float *out = n->out;
  const float gain = n->p0;
  for (int i = 0; i < AXO_BUFSIZE; ++i) {
    const float sample = in != 0 ? in[i] : 0.0f;
    const float modulation = gain_in != 0 ? gain_in[i] : 1.0f;
    out[i] = sample * gain * modulation;
  }
}

// Rebuilt whenever the host changes the population. Never touches node state
// of surviving nodes' predecessors; a rebuild mid-run is a test-rig event, not
// an audio-path one (the mix feeds the sink only).
static int32_t built_nsine = -1, built_nvoice = -1;
static int node_count;
static Node lfo_node;

static void build_graph(int32_t nsine, int32_t nvoice) {
  node_count = 0;
  mix_src_count = 0;

  lfo_node.process = sine_process;
  lfo_node.in = 0;
  lfo_node.out = lfo_buffer;
  lfo_node.p0 = 2.0f;  // Hz

  for (int32_t s = 0; s < nsine && node_count < MAX_NODES; s++) {
    Node *n = &nodes[node_count];
    n->process = sine_process;
    n->in = 0;
    n->mod = 0;
    n->out = buffers[node_count];
    n->p0 = 110.0f + 7.0f * (float)s;
    n->s0 = 0.0f;
    mix_src[mix_src_count++] = n->out;
    node_count++;
  }

  for (int32_t v = 0; v < nvoice && node_count + 3 <= MAX_NODES; v++) {
    Node *osc = &nodes[node_count];
    osc->process = sine_process;
    osc->in = 0;
    osc->mod = 0;
    osc->out = buffers[node_count];
    osc->p0 = 65.0f + 3.0f * (float)v;
    osc->s0 = 0.0f;
    node_count++;

    Node *flt = &nodes[node_count];
    flt->process = svf_process;
    flt->in = osc->out;
    flt->mod = 0;
    flt->out = buffers[node_count];
    flt->p0 = 800.0f + 5.0f * (float)v;
    flt->p1 = 0.3f;
    flt->s0 = flt->s1 = 0.0f;
    node_count++;

    Node *amp = &nodes[node_count];
    amp->process = gain_process;
    amp->in = flt->out;
    amp->mod = lfo_buffer;
    amp->out = buffers[node_count];
    amp->p0 = 0.8f;
    mix_src[mix_src_count++] = amp->out;
    node_count++;
  }

  built_nsine = nsine;
  built_nvoice = nvoice;
}

static void run_graph(void) {
  int32_t nsine = SHM->ctrl_nsine;
  int32_t nvoice = SHM->ctrl_nvoice;
  if (nsine < 0) nsine = 0;
  if (nsine > MAX_NODES) nsine = MAX_NODES;
  if (nvoice < 0) nvoice = 0;
  if (nvoice > MAX_VOICES) nvoice = MAX_VOICES;
  if (nsine != built_nsine || nvoice != built_nvoice)
    build_graph(nsine, nvoice);

  if (node_count == 0) {
    SHM->sink = 0;
    return;
  }

  lfo_node.process(&lfo_node);
  for (int i = 0; i < node_count; i++) nodes[i].process(&nodes[i]);

  // The graph's summing output pass.
  for (int i = 0; i < AXO_BUFSIZE; i++) mix[i] = 0.0f;
  for (int s = 0; s < mix_src_count; s++) {
    const float *src = mix_src[s];
    for (int i = 0; i < AXO_BUFSIZE; i++) mix[i] += src[i];
  }
  SHM->sink = (uint32_t)(int32_t)(mix[0] * 128.0f);  // keep it observable
}

static void dsp(int32_t *inbuf, int32_t *outbuf) {
  sg_lab_audio(inbuf, outbuf);
  run_graph();
  sg_lab_tick();
}

static void dispose(void) {}

AXO_PATCH(NODELAB_ID, dsp, dispose, {
  init_shm(NODELAB_ID);
  built_nsine = -1;
  built_nvoice = -1;
})
