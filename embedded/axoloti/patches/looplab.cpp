// The loopback laboratory. Tone + analyzer come from sg_lab.h; this patch adds
// the raw-oscillator load bank: ctrl_nosc phase-accumulator oscillators
// (0..1024) whose output goes to a shared-memory sink, not the audio path.
// Ramping it drives dspLoadPct wherever we want while the loopback tone stays
// bit-identical — dropouts then indicate real scheduling overload.

#include "axo_abi.h"
#include "sg_shm.h"
#include "sg_lab.h"

#define LOOPLAB_ID 0x4C4F4F31u  // "LOO1"

#define MAX_OSC 1024

// Zero-initialized state lands in .bss (CCM), cleared by AXO_PATCH init.
static uint32_t osc_phase[MAX_OSC];
static uint32_t osc_step[MAX_OSC];

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
      int32_t a = sg_tone_lut[idx];
      int32_t b = sg_tone_lut[(idx + 1) & (TONE_PERIOD - 1)];
      int32_t frac = (int32_t)((ph >> 11) & 0xFFFF);
      acc += (a + (int32_t)(((int64_t)(b - a) * frac) >> 16)) >> 6;
    }
    osc_phase[o] = ph;
  }
  SHM->sink = (uint32_t)acc;
}

static void dsp(int32_t *inbuf, int32_t *outbuf) {
  sg_lab_audio(inbuf, outbuf);
  run_load_bank();
  sg_lab_tick();
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
