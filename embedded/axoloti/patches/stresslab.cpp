// The stress laboratory: everything needed to run the audio engine ragged and
// measure what breaks first, all host-driven through shared memory.
//
//   Tone     — variable frequency (ctrl_step, q32 phase acc) and amplitude
//              (ctrl_amp, q27) through dsp-core's committed sine table, so the
//              host can sweep level and frequency, not just toggle 1500 Hz.
//   Analyzer — the sg_lab per-window peak/mean-square/zero-cross set, plus a
//              Goertzel bin at the tone frequency (SINAD measurement) and two
//              cumulative defect counters that never sleep between host polls:
//              clicks (inter-sample step above ctrl_slope_max) and dropouts
//              (any 1 ms whose input peak falls under ctrl_floor).
//   Load     — the same 0..1024 integer oscillator bank as looplab
//              (ctrl_nosc), so quality can be measured *against* load.
//   SDRAM    — ctrl_sdram_words words per dsp cycle written to a 4 MB ring in
//              the off-chip SDRAM and verified 2 MB later; mismatches count in
//              cum_sdram_errs. Audio-rate FMC traffic under DSP load.

#include "axo_abi.h"
#include "sg_shm.h"
#include "sg_lab.h"

#include "sine_table.h"  // dsp-core's table, via -I

#define STRESSLAB_ID 0x53545231u  // "STR1"

// Firmware MIDI layer (midi.h at 1.0.12-2), via --just-symbols.
extern "C" {
void MidiSend3(int32_t dev, uint8_t port, uint8_t b0, uint8_t b1, uint8_t b2);
}

#define MAX_OSC 1024
#define SDRAM_BASE ((volatile uint32_t *)0xC0000000u)
#define SDRAM_RING_WORDS (1u << 20)          // 4 MB of the 8 MB chip
#define SDRAM_VERIFY_LAG (SDRAM_RING_WORDS / 2)
#define SDRAM_SEED 0x5EED5EEDu

using soundgraph::dsp::kSineTable;
using soundgraph::dsp::kSineTableSize;

// Table sine indexed straight from the q32 phase word. Integer indexing:
// (float)phase * 2^-32 can round to exactly 1.0f and index past the table,
// which would be a one-sample click injected by the tone generator itself.
static inline float sine_q32(uint32_t phase) {
  const uint32_t index = phase >> 20;  // 0..4095; kSineTable has 4097 entries
  const float fraction = (float)((phase >> 4) & 0xFFFF) * (1.0f / 65536.0f);
  const float a = kSineTable[index];
  const float b = kSineTable[index + 1];
  return a + (b - a) * fraction;
}

// Zero-initialized state (.bss, CCM), cleared by AXO_PATCH init.
static uint32_t tone_phase;
static int32_t prev_in;
static int32_t ms_peak;      // peak of the current 1 ms (48-sample) subwindow
static uint32_t ms_pos;
static float g_s1, g_s2;     // Goertzel state
static float g_tot;          // total power accumulator (sum of x^2, x in +-1)
static uint32_t sdram_wr;    // ring write index, words
static uint32_t osc_phase[MAX_OSC];
static uint32_t osc_step[MAX_OSC];

static inline float f_from_bits(uint32_t b) {
  union { uint32_t u; float f; } c;
  c.u = b;
  return c.f;
}

static inline uint32_t bits_from_f(float f) {
  union { uint32_t u; float f; } c;
  c.f = f;
  return c.u;
}

// The burst trigger: CC 119 on channel 16. When it arrives (over any
// transport — in practice the USB device port, which needs no hardware), the
// handler transmits the whole burst described by ctrl_midi_tx synchronously.
// This runs in the firmware's MIDI input thread, never the DSP thread, so the
// blocking sends (DIN's sdWrite at 31250 baud, USB's bulk write) are harmless
// backpressure rather than an audio dropout. The firmware's own MIDI-thru
// objects write from this same context.
#define MIDI_BURST_TRIGGER_CC 119

static void run_midi_burst(void) {
  uint32_t req = SHM->ctrl_midi_tx;
  const int32_t dev = (int32_t)(req >> 24);
  uint32_t remaining = req & 0x00FFFFFFu;
  uint32_t i = 0;
  while (remaining > 0) {
    MidiSend3(dev, 1, 0x90, (uint8_t)((i * 7) % 128),
              (uint8_t)(((i * 13) % 127) + 1));
    i++;
    remaining--;
    SHM->ctrl_midi_tx = remaining ? (((uint32_t)dev << 24) | remaining) : 0;
  }
}

// Called by the firmware from its input threads (one per transport), never
// from the DSP thread. Counts, checksums, and optionally echoes.
static void midi_in(midi_device_t dev, uint8_t port, uint8_t b0, uint8_t b1,
                    uint8_t b2) {
  if ((b0 & 0xFF) == 0xBF && b1 == MIDI_BURST_TRIGGER_CC) {
    run_midi_burst();  // the trigger itself is not counted
    return;
  }
  const uint32_t word = ((uint32_t)dev << 24) | ((uint32_t)b0 << 16) |
                        ((uint32_t)b1 << 8) | b2;
  if (dev == 1) SHM->cum_midi_din = SHM->cum_midi_din + 1;
  else if (dev == 2) SHM->cum_midi_usbd = SHM->cum_midi_usbd + 1;
  else if (dev == 3) SHM->cum_midi_usbh = SHM->cum_midi_usbh + 1;
  SHM->midi_checksum = SHM->midi_checksum * 31u + word;
  SHM->midi_last = word;
  if (SHM->ctrl_midi_echo & (1 << dev))
    MidiSend3(dev, port, b0, b1, b2);
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
      int32_t a = sg_tone_lut[idx];
      int32_t b = sg_tone_lut[(idx + 1) & (TONE_PERIOD - 1)];
      int32_t frac = (int32_t)((ph >> 11) & 0xFFFF);
      acc += (a + (int32_t)(((int64_t)(b - a) * frac) >> 16)) >> 6;
    }
    osc_phase[o] = ph;
  }
  SHM->sink = (uint32_t)acc;
}

static void run_sdram(void) {
  uint32_t w = SHM->ctrl_sdram_words;
  if (w == 0) return;
  if (w > 4096) w = 4096;
  uint32_t wr = sdram_wr;
  for (uint32_t k = 0; k < w; k++) {
    uint32_t idx = (wr + k) & (SDRAM_RING_WORDS - 1);
    SDRAM_BASE[idx] = (idx * 2654435761u) ^ SDRAM_SEED ^ ((wr + k) >> 20);
  }
  if (wr >= SDRAM_VERIFY_LAG) {
    uint32_t errs = 0;
    for (uint32_t k = 0; k < w; k++) {
      uint32_t pos = wr - SDRAM_VERIFY_LAG + k;
      uint32_t idx = pos & (SDRAM_RING_WORDS - 1);
      uint32_t expect = (idx * 2654435761u) ^ SDRAM_SEED ^ (pos >> 20);
      if (SDRAM_BASE[idx] != expect) errs++;
    }
    if (errs) SHM->cum_sdram_errs = SHM->cum_sdram_errs + errs;
  }
  sdram_wr = wr + w;
}

static void dsp(int32_t *inbuf, int32_t *outbuf) {
  const uint32_t step = SHM->ctrl_step;
  const int32_t amp = SHM->ctrl_amp;
  const int32_t slope_max = SHM->ctrl_slope_max;
  const int32_t floor_pk = SHM->ctrl_floor;
  const float coeff = f_from_bits(SHM->ctrl_coeff);
  const float inv_q27 = 1.0f / 134217728.0f;

  for (int i = 0; i < AXO_BUFSIZE; i++) {
    // Tone out (left), silence right.
    int32_t out_l = 0;
    if (amp != 0) {
      tone_phase += step;
      out_l = (int32_t)(sine_q32(tone_phase) * (float)amp);
    }
    outbuf[i * 2] = out_l << 4;
    outbuf[i * 2 + 1] = 0;

    // Input analysis.
    const int32_t l = inbuf[i * 2] >> 4;
    const int32_t r = inbuf[i * 2 + 1] >> 4;
    sg_analyze_sample(l, r);

    // Click detector: a step steeper than any legitimate tone slope.
    if (slope_max > 0) {
      int32_t d = l - prev_in;
      if (d < 0) d = -d;
      if (d > slope_max) SHM->cum_clicks = SHM->cum_clicks + 1;
    }
    prev_in = l;

    // Dropout detector: every millisecond must contain signal.
    int32_t al = l < 0 ? -l : l;
    if (al > ms_peak) ms_peak = al;
    if (++ms_pos >= 48) {
      if (floor_pk > 0 && ms_peak < floor_pk)
        SHM->cum_dropouts = SHM->cum_dropouts + 1;
      ms_pos = 0;
      ms_peak = 0;
    }

    // Goertzel at the tone bin + total power, for SINAD.
    const float xf = (float)l * inv_q27;
    const float s = xf + coeff * g_s1 - g_s2;
    g_s2 = g_s1;
    g_s1 = s;
    g_tot += xf * xf;
  }

  run_load_bank();
  run_sdram();

  if (sg_lab_tick()) {
    const float sig = g_s1 * g_s1 + g_s2 * g_s2 - coeff * g_s1 * g_s2;
    SHM->goertzel_sig = bits_from_f(sig);
    SHM->goertzel_tot = bits_from_f(g_tot);
    g_s1 = g_s2 = 0.0f;
    g_tot = 0.0f;
  }
}

static void dispose(void) {}

static void init_oscs(void) {
  const uint32_t base = 17895697u;   // 200 Hz
  const uint32_t delta = 157286u;    // ~1.76 Hz per oscillator
  for (uint32_t o = 0; o < MAX_OSC; o++) {
    osc_step[o] = base + o * delta;
    osc_phase[o] = o * 2654435761u;
  }
}

AXO_PATCH_MIDI(STRESSLAB_ID, dsp, dispose, midi_in, {
  init_shm(STRESSLAB_ID);
  init_oscs();
})
