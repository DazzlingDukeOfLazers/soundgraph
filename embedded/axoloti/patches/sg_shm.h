// Host-visible shared-memory block used by all soundgraph test patches.
//
// Placed at the start of the SRAM2 patch region (0x2001C000, ramlink.ld) so
// the host can reach it with the protocol's generic memory read/write at a
// fixed address. That section is NOLOAD: nothing here may rely on static
// initialization — init_shm() runs from xpatch_init2 before DSP starts.
//
// The Python mirror of this layout lives in tests/shm.py; keep both in sync.

#ifndef SG_SHM_H
#define SG_SHM_H

#include <stdint.h>

#define SG_SHM_ADDR 0x2001C000u

typedef struct {
  uint32_t magic;         // patch-specific; last field written by init
  uint32_t heartbeat;     // ++ every dsp cycle (3000 Hz)

  // Host-written controls (patch only reads).
  int32_t ctrl_tone;      // 0/1: emit the 1500 Hz test tone on left out
  int32_t ctrl_nosc;      // looplab: active oscillators in the load bank
  int32_t ctrl_nsine;     // nodelab: standalone soundgraph Sine nodes
  int32_t ctrl_nvoice;    // nodelab: Sine->SVF->Gain voices

  // Input analyzer, published once per completed window.
  uint32_t win_count;     // completed windows since start
  uint32_t in_msq_l;      // mean(x^2)>>10 of left in, x in q27
  uint32_t in_msq_r;      // same for right in
  int32_t in_peak_l;      // max |x| in window, left
  int32_t in_peak_r;      // max |x| in window, right
  uint32_t in_zerocross_l;// sign changes of left in per window
  int64_t in_dcsum_l;     // sum of left samples in window (DC indicator)
  uint32_t sink;          // load-bank output sink, keeps work observable

  // Stress extensions (stresslab; other patches leave them zero).
  uint32_t ctrl_step;        // tone phase step, q32 at 48 kHz (freq*2^32/48000)
  int32_t ctrl_amp;          // tone peak amplitude, q27 (0 = silence)
  uint32_t ctrl_coeff;       // Goertzel coefficient 2cos(2*pi*f/fs), float bits
  int32_t ctrl_slope_max;    // click detector: max |dx| per sample, q27 (0 = off)
  int32_t ctrl_floor;        // dropout detector: min per-ms input peak, q27 (0 = off)
  uint32_t ctrl_sdram_words; // SDRAM words written + verified per dsp cycle
  uint32_t cum_clicks;       // cumulative; host clears by writing zero
  uint32_t cum_dropouts;
  uint32_t cum_sdram_errs;
  uint32_t goertzel_sig;     // last window: Goertzel power at the tone, float bits
  uint32_t goertzel_tot;     // last window: total power (mean-square * N), float bits
} sg_shm_t;

// One analyzer window = 300 dsp cycles = 4800 samples = 100 ms at 48 kHz.
#define SG_WINDOW_CYCLES 300

static volatile sg_shm_t *const SHM = (volatile sg_shm_t *)SG_SHM_ADDR;

static inline void init_shm(uint32_t magic) {
  volatile uint32_t *p = (volatile uint32_t *)SG_SHM_ADDR;
  for (unsigned i = 0; i < sizeof(sg_shm_t) / 4; i++) p[i] = 0;
  SHM->magic = magic;  // written last: host sees zeroed block or live block
}

#endif  // SG_SHM_H
