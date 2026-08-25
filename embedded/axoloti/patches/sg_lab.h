// Shared laboratory equipment for test patches: the 1500 Hz loopback tone and
// the on-board input analyzer. Both looplab and nodelab keep the audio path
// identical — deterministic tone out, analyzer on the inputs — so overload in
// whatever load they generate shows up as loopback dropouts the host can read.

#ifndef SG_LAB_H
#define SG_LAB_H

#include "axo_abi.h"
#include "sg_shm.h"

#define TONE_PERIOD 32

// q26 sine (peak 2^26 = -6 dBFS in q27), one 1500 Hz period at 48 kHz.
static const int32_t sg_tone_lut[TONE_PERIOD] = {
    0,         13092290,  25681450,  37283687,  47453133,  55798981,
    62000506,  65819386,  67108864,  65819386,  62000506,  55798981,
    47453133,  37283687,  25681450,  13092290,  0,         -13092290,
    -25681450, -37283687, -47453133, -55798981, -62000506, -65819386,
    -67108864, -65819386, -62000506, -55798981, -47453133, -37283687,
    -25681450, -13092290};

// Zero-initialized state lands in .bss (CCM), cleared by AXO_PATCH init.
static uint32_t sg_tone_idx;
static uint32_t sg_cycle_in_window;
static uint64_t sg_acc_sq_l, sg_acc_sq_r;
static int32_t sg_acc_peak_l, sg_acc_peak_r;
static uint32_t sg_acc_zc_l;
static int64_t sg_acc_dc_l;
static int32_t sg_zc_state;  // -1, 0, +1 hysteresis state

#define SG_ZC_THRESHOLD (1 << 18)  // ~-54 dBFS: above line noise, below any tone

static inline void sg_analyze_sample(int32_t l, int32_t r) {
  sg_acc_sq_l += (uint64_t)((int64_t)(l >> 8) * (l >> 8));
  sg_acc_sq_r += (uint64_t)((int64_t)(r >> 8) * (r >> 8));
  int32_t al = l < 0 ? -l : l;
  int32_t ar = r < 0 ? -r : r;
  if (al > sg_acc_peak_l) sg_acc_peak_l = al;
  if (ar > sg_acc_peak_r) sg_acc_peak_r = ar;
  sg_acc_dc_l += l;
  if (l > SG_ZC_THRESHOLD) {
    if (sg_zc_state < 0) sg_acc_zc_l++;
    sg_zc_state = 1;
  } else if (l < -SG_ZC_THRESHOLD) {
    if (sg_zc_state > 0) sg_acc_zc_l++;
    sg_zc_state = -1;
  }
}

static inline void sg_publish_window(void) {
  SHM->in_msq_l = (uint32_t)(sg_acc_sq_l >> 20);
  SHM->in_msq_r = (uint32_t)(sg_acc_sq_r >> 20);
  SHM->in_peak_l = sg_acc_peak_l;
  SHM->in_peak_r = sg_acc_peak_r;
  SHM->in_zerocross_l = sg_acc_zc_l;
  SHM->in_dcsum_l = sg_acc_dc_l;
  SHM->win_count = SHM->win_count + 1;
  sg_acc_sq_l = sg_acc_sq_r = 0;
  sg_acc_peak_l = sg_acc_peak_r = 0;
  sg_acc_zc_l = 0;
  sg_acc_dc_l = 0;
}

// Tone to left out, silence to right, analyze both inputs; call once per dsp
// cycle from the patch's process function, then do the patch's own load work.
static inline void sg_lab_audio(int32_t *inbuf, int32_t *outbuf) {
  int tone = SHM->ctrl_tone;
  for (int i = 0; i < AXO_BUFSIZE; i++) {
    int32_t out_l = tone ? sg_tone_lut[sg_tone_idx] : 0;
    sg_tone_idx = (sg_tone_idx + 1) & (TONE_PERIOD - 1);
    outbuf[i * 2] = out_l << 4;  // q27 -> wire format
    outbuf[i * 2 + 1] = 0;
    sg_analyze_sample(inbuf[i * 2] >> 4, inbuf[i * 2 + 1] >> 4);
  }
}

static inline void sg_lab_tick(void) {
  SHM->heartbeat = SHM->heartbeat + 1;
  if (++sg_cycle_in_window >= SG_WINDOW_CYCLES) {
    sg_cycle_in_window = 0;
    sg_publish_window();
  }
}

#endif  // SG_LAB_H
