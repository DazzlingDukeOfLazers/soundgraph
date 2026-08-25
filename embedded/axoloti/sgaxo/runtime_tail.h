// sgaxo generated-patch tail: included at the END of every generated patch,
// after the codegen has defined
//
//   static void sg_graph_process(const float *in_l, const float *in_r,
//                                float *out_l, float *out_r);  // 64 frames
//   static void sg_graph_init(void);                    // runtime state init
//   static void sg_note_event(int on, int note, float velocity);  // may be a no-op
//   static const sgaxo_event_t sg_events[];  static const int sg_event_count;
//   #define SGAXO_PATCH_ID       <u32>
//   #define SGAXO_FRAMES_TARGET  <frames to capture>
//
// The graph runs at dsp-core's native 64-frame block size — per-block
// semantics (SVF modulation sampling, event-on-block-boundary delivery) are
// part of what the golden vectors recorded — and a FIFO drains it to the
// codec's 16-frame cycles. Scheduled events replay the golden case; after the
// capture completes the patch keeps running and live MIDI notes (any channel,
// any transport) drive the same note handler, so the compiled patch is a
// playable instrument, not just a test subject.

#ifndef SGAXO_RUNTIME_TAIL_H
#define SGAXO_RUNTIME_TAIL_H

#include "axo_abi.h"

#define SGAXO_SHM_ADDR 0x2001C000u
#define SGAXO_CAPTURE_BASE 0xC0400000u  // above the .sdram delay lines
#define SGAXO_SHM_MAGIC 0x53475831u  // "SGX1"

typedef struct {
  uint32_t magic;
  uint32_t heartbeat;
  uint32_t frames_done;
  uint32_t frames_target;
  uint32_t capture_base;
  uint32_t status;  // 0 rendering, 1 capture complete (audio keeps running)
} sgaxo_shm_t;

static volatile sgaxo_shm_t *const SGX = (volatile sgaxo_shm_t *)SGAXO_SHM_ADDR;
static volatile float *const SGX_CAP = (volatile float *)SGAXO_CAPTURE_BASE;

#ifdef SGAXO_SD_BUFFERS
// Standalone buffer loading: no host to ship SDRAM samples, so the patch
// reads its own sidecar files at init through the firmware's FatFs
// (sdcard_loadPatch1 has already mounted the card; the table's paths are
// absolute regardless of the working directory it left behind). Chunked,
// feeding the watchdog: init runs in the DSP thread and a long uninterrupted
// read would starve it.
extern "C" {
int f_open(void *fil, const char *path, unsigned char mode);
int f_read(void *fil, void *buff, unsigned int btr, unsigned int *br);
int f_close(void *fil);
void watchdog_feed(void);
}

static void sgaxo_load_sd_buffers(void) {
  // FatFs FIL is ~560 bytes in this firmware build; 1024 aligned is safe.
  static uint8_t fil[1024] __attribute__((aligned(8)));
  for (int i = 0; i < SGAXO_SD_BUFFER_COUNT; i++) {
    const sgaxo_sd_buffer_t *b = &sgaxo_sd_buffers[i];
    uint8_t *out = (uint8_t *)b->addr;
    unsigned remaining = b->bytes;
    if (f_open(fil, b->path, 0x01 /* FA_READ|FA_OPEN_EXISTING */) != 0) {
      LogTextMessage("sgaxo: missing %s", b->path);
    } else {
      while (remaining) {
        const unsigned chunk = remaining > 4096u ? 4096u : remaining;
        unsigned got = 0;
        if (f_read(fil, out, chunk, &got) != 0 || got == 0) break;
        out += got;
        remaining -= got;
        watchdog_feed();
      }
      f_close(fil);
    }
    while (remaining) { *out++ = 0; remaining--; }  // short/missing -> silence
  }
}
#endif  // SGAXO_SD_BUFFERS

// Live MIDI -> DSP thread, single-producer single-consumer.
typedef struct { int on; int note; float velocity; } sgaxo_midi_note_t;
static sgaxo_midi_note_t sgaxo_midi_ring[16];
static volatile uint32_t sgaxo_midi_wr, sgaxo_midi_rd;

#ifdef SGAXO_BANK
extern "C" void LoadPatchIndexed(uint32_t index);
#endif

static void sgaxo_midi_in(midi_device_t dev, uint8_t port, uint8_t b0,
                          uint8_t b1, uint8_t b2) {
  (void)dev; (void)port;
  const uint8_t status = b0 & 0xF0;
#ifdef SGAXO_BANK
  // Program Change walks the SD bank: the firmware stops this patch, reads
  // index.axb, and loads line b1's directory's patch.bin — /start.bin on any
  // failure. Called from the MIDI input thread, the same context the
  // patcher's own program-change objects use.
  if (status == 0xC0) {
    LoadPatchIndexed(b1);
    return;
  }
#endif
  int on;
  if (status == 0x90 && b2 > 0) on = 1;
  else if (status == 0x80 || (status == 0x90 && b2 == 0)) on = 0;
  else return;
  const uint32_t wr = sgaxo_midi_wr;
  if (wr - sgaxo_midi_rd >= 16) return;  // full: drop rather than block
  sgaxo_midi_ring[wr & 15].on = on;
  sgaxo_midi_ring[wr & 15].note = b1;
  sgaxo_midi_ring[wr & 15].velocity = (float)b2 * (1.0f / 127.0f);
  sgaxo_midi_wr = wr + 1;
}

static float sgaxo_fifo_l[SGAXO_FRAMES], sgaxo_fifo_r[SGAXO_FRAMES];
static float sgaxo_in_l[SGAXO_FRAMES], sgaxo_in_r[SGAXO_FRAMES];
static uint32_t sgaxo_fifo_pos;   // runtime-inited to SGAXO_FRAMES (empty)
static uint32_t sgaxo_position;   // absolute frame count of rendered blocks
static int sgaxo_next_event;

static void sgaxo_render_block(void) {
  // Scheduled events land before the block containing their frame, exactly
  // like the golden runner's loop; live MIDI joins at the same boundary.
  while (sgaxo_next_event < sg_event_count &&
         (uint32_t)sg_events[sgaxo_next_event].frame <
             sgaxo_position + SGAXO_FRAMES) {
    const sgaxo_event_t *e = &sg_events[sgaxo_next_event];
    sg_note_event(e->note_on, e->note, e->velocity);
    sgaxo_next_event++;
  }
  while (sgaxo_midi_rd != sgaxo_midi_wr) {
    const sgaxo_midi_note_t *m = &sgaxo_midi_ring[sgaxo_midi_rd & 15];
    sg_note_event(m->on, m->note, m->velocity);
    sgaxo_midi_rd = sgaxo_midi_rd + 1;
  }
  sg_graph_process(sgaxo_in_l, sgaxo_in_r, sgaxo_fifo_l, sgaxo_fifo_r);
  sgaxo_position += SGAXO_FRAMES;
  sgaxo_fifo_pos = 0;
}

static void sgaxo_dsp(int32_t *inbuf, int32_t *outbuf) {
  // The codec's input rides the same FIFO phase as the output: 16 frames
  // land per cycle, and the block that renders sees the 64 input frames
  // gathered over the preceding four cycles.
  if (sgaxo_fifo_pos >= SGAXO_FRAMES) sgaxo_render_block();
  const float inv_q27 = 1.0f / 134217728.0f;
  uint32_t done = SGX->frames_done;
  for (int i = 0; i < 16; i++) {
    sgaxo_in_l[sgaxo_fifo_pos + i] = (float)(inbuf[i * 2] >> 4) * inv_q27;
    sgaxo_in_r[sgaxo_fifo_pos + i] = (float)(inbuf[i * 2 + 1] >> 4) * inv_q27;
  }
  for (int i = 0; i < 16; i++) {
    const float l = sgaxo_fifo_l[sgaxo_fifo_pos];
    const float r = sgaxo_fifo_r[sgaxo_fifo_pos];
    sgaxo_fifo_pos++;
    // Codec out, clamped shy of full scale (q27<<4 overflows at exactly 1.0).
    const float cl = l < -0.999969f ? -0.999969f : (l > 0.999969f ? 0.999969f : l);
    const float cr = r < -0.999969f ? -0.999969f : (r > 0.999969f ? 0.999969f : r);
    outbuf[i * 2] = ((int32_t)(cl * 134217728.0f)) << 4;
    outbuf[i * 2 + 1] = ((int32_t)(cr * 134217728.0f)) << 4;
    // Golden capture: the unclamped left channel, bit for bit.
#if SGAXO_FRAMES_TARGET > 0
    if (done < SGAXO_FRAMES_TARGET) {
      SGX_CAP[done] = l;
      done++;
    }
#endif
  }
  SGX->frames_done = done;
#if SGAXO_FRAMES_TARGET > 0
  if (done >= SGAXO_FRAMES_TARGET) SGX->status = 1;
#else
  SGX->status = 1;  // baked patches capture nothing; report ready at once
#endif
  SGX->heartbeat = SGX->heartbeat + 1;
}

static void sgaxo_dispose(void) {}

AXO_PATCH_MIDI(SGAXO_PATCH_ID, sgaxo_dsp, sgaxo_dispose, sgaxo_midi_in, {
  volatile uint32_t *p = (volatile uint32_t *)SGAXO_SHM_ADDR;
  for (unsigned i = 0; i < sizeof(sgaxo_shm_t) / 4; i++) p[i] = 0;
  sgaxo_fifo_pos = SGAXO_FRAMES;  // .bss is zeroed; mark the FIFO empty
#ifdef SGAXO_SD_BUFFERS
  sgaxo_load_sd_buffers();  // before sg_graph_init: Speech scans its bank
#endif
  sg_graph_init();
  SGX->frames_target = SGAXO_FRAMES_TARGET;
  SGX->capture_base = SGAXO_CAPTURE_BASE;
  SGX->magic = SGAXO_SHM_MAGIC;
})

#endif  // SGAXO_RUNTIME_TAIL_H
