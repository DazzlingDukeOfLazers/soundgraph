// Smallest possible live patch: silence out, heartbeat up. Proves the whole
// programming chain — upload, xpatch_init call, patchMeta wiring, DSP thread
// actually invoking us at 3000 cycles/s.

#include "axo_abi.h"
#include "sg_shm.h"

#define SMOKE_ID 0x534D4B31u  // "SMK1"

static void dsp(int32_t *inbuf, int32_t *outbuf) {
  (void)inbuf;
  for (int i = 0; i < AXO_BUFSIZE * 2; i++) outbuf[i] = 0;
  SHM->heartbeat = SHM->heartbeat + 1;
}

static void dispose(void) {}

AXO_PATCH(SMOKE_ID, dsp, dispose, init_shm(SMOKE_ID))
