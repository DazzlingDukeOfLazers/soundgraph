// The loopback laboratory. Three jobs in one patch, all host-driven through
// the shared-memory block (sg_shm.h):
//
//   1. Test tone: exactly 1500 Hz (48000/32) on the left output at -6 dBFS,
//      gated by ctrl_tone. Right output stays silent — the expected wiring is
//      a mono cable from audio out to audio in.
//   2. Input analyzer: per 100 ms window publishes mean-square, peak, zero
//      crossings and DC sum of the inputs, so the host can verify the analog
//      loopback (level, frequency, dropouts) without an audio interface.
//   3. Load bank: ctrl_nosc phase-accumulator oscillators (0..1024) whose
//      output goes to a shared-memory sink, not the audio path. Ramping it
//      drives dspLoadPct wherever we want while the loopback tone stays
//      bit-identical — dropouts then indicate real scheduling overload.

#include "axo_abi.h"
#include "sg_shm.h"

#define LOOPLAB_ID 0x4C4F4F31u  // "LOO1"

#define MAX_OSC 1024
#define TONE_PERIOD 32

// q26 sine (peak 2^26 = -6 dBFS in q27), one 1500 Hz period at 48 kHz.
static const int32_t sine_lut[TONE_PERIOD] = {
    0,         13092290,  25681450,  37283687,  47453133,  55798981,
    62000506,  65819386,  67108864,  65819386,  62000506,  55798981,
    47453133,  37283687,  25681450,  13092290,  0,         -13092290,
    -25681450, -37283687, -47453133, -55798981, -62000506, -65819386,
    -67108864, -65819386, -62000506, -55798981, -47453133, -37283687,
    -25681450, -13092290};

// Zero-initialized state lands in .bss (CCM), cleared by AXO_PATCH init.
static uint32_t tone_idx;
static uint32_t osc_phase[MAX_OSC];
static uint32_t osc_step[MAX_OSC];

static uint32_t cycle_in_window;
static uint64_t acc_sq_l, acc_sq_r;
static int32_t acc_peak_l, acc_peak_r;
static uint32_t acc_zc_l;
static int64_t acc_dc_l;
static int32_t zc_state;  // -1, 0, +1 hysteresis state

#define ZC_THRESHOLD (1 << 18)  // ~-54 dBFS: above line noise, below any tone

static void analyze_sample(int32_t l, int32_t r) {
  acc_sq_l += (uint64_t)((int64_t)(l >> 8) * (l >> 8));
  acc_sq_r += (uint64_t)((int64_t)(r >> 8) * (r >> 8));
  int32_t al = l < 0 ? -l : l;
  int32_t ar = r < 0 ? -r : r;
  if (al > acc_peak_l) acc_peak_l = al;
  if (ar > acc_peak_r) acc_peak_r = ar;
  acc_dc_l += l;
  if (l > ZC_THRESHOLD) {
    if (zc_state < 0) acc_zc_l++;
    zc_state = 1;
  } else if (l < -ZC_THRESHOLD) {
    if (zc_state > 0) acc_zc_l++;
    zc_state = -1;
  }
}

static void publish_window(void) {
  SHM->in_msq_l = (uint32_t)(acc_sq_l >> 20);
  SHM->in_msq_r = (uint32_t)(acc_sq_r >> 20);
  SHM->in_peak_l = acc_peak_l;
  SHM->in_peak_r = acc_peak_r;
  SHM->in_zerocross_l = acc_zc_l;
  SHM->in_dcsum_l = acc_dc_l;
  SHM->win_count = SHM->win_count + 1;
  acc_sq_l = acc_sq_r = 0;
  acc_peak_l = acc_peak_r = 0;
  acc_zc_l = 0;
  acc_dc_l = 0;
}

static void run_load_bank(void) {
  int32_t n = SHM->ctrl_nosc;
  if (n < 0) n = 0;
  if (n > MAX_OSC) n = MAX_OSC;
  int32_t acc = 0;
  for (int32_t o = 0; o < n; o++) {
    uint32_t ph = osc_phase[o];
    uint32_t st = osc_step[o];
    for (int i = 0; i < AXO_BUFSIZE; i++) {
      ph += st;
      uint32_t idx = ph >> 27;
      int32_t a = sine_lut[idx];
      int32_t b = sine_lut[(idx + 1) & (TONE_PERIOD - 1)];
      int32_t frac = (int32_t)((ph >> 11) & 0xFFFF);
      acc += (a + (int32_t)(((int64_t)(b - a) * frac) >> 16)) >> 6;
    }
    osc_phase[o] = ph;
  }
  SHM->sink = (uint32_t)acc;
}

static void dsp(int32_t *inbuf, int32_t *outbuf) {
  int tone = SHM->ctrl_tone;
  for (int i = 0; i < AXO_BUFSIZE; i++) {
    int32_t out_l = tone ? sine_lut[tone_idx] : 0;
    tone_idx = (tone_idx + 1) & (TONE_PERIOD - 1);
    outbuf[i * 2] = out_l << 4;   // q27 -> wire format
    outbuf[i * 2 + 1] = 0;
    analyze_sample(inbuf[i * 2] >> 4, inbuf[i * 2 + 1] >> 4);
  }
  run_load_bank();
  SHM->heartbeat = SHM->heartbeat + 1;
  if (++cycle_in_window >= SG_WINDOW_CYCLES) {
    cycle_in_window = 0;
    publish_window();
  }
}

static void dispose(void) {}

static void init_oscs(void) {
  // Spread the bank over ~200..2000 Hz so no two share a phase trajectory.
  // Phase steps are q32 at 48 kHz: step = freq * 2^32 / 48000, precomputed
  // as 200 Hz base plus ~1.76 Hz per oscillator (no division, no libgcc).
  const uint32_t base = 17895697u;   // 200 Hz
  const uint32_t delta = 157286u;    // (2000-200) Hz / 1024 oscillators
  for (uint32_t o = 0; o < MAX_OSC; o++) {
    osc_step[o] = base + o * delta;
    osc_phase[o] = o * 2654435761u;  // arbitrary distinct phases
  }
}

AXO_PATCH(LOOPLAB_ID, dsp, dispose, {
  init_shm(LOOPLAB_ID);
  init_oscs();
})
