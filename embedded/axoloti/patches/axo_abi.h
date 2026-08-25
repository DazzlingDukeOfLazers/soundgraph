// Minimal Axoloti 1.0.12-2 patch ABI, declared standalone so test patches
// compile without the ChibiOS/firmware header tree. Layouts and calling
// conventions mirror firmware/patch.h at tag 1.0.12-2 of
// https://github.com/axoloti/axoloti and must not drift from it.
//
// A patch binary is raw code+rodata linked at 0x00011000 (the SRAM alias the
// firmware maps at 0x0), loaded by the host at 0x20011000. The firmware calls
// the first byte of the binary (thumb) as xpatch_init(fwid); init must fill
// patchMeta, setting fptr_dsp_process last — the firmware treats a null
// fptr_dsp_process after init as a failed load.

#ifndef AXO_ABI_H
#define AXO_ABI_H

#include <stdint.h>

struct ParameterExchange_t;  // opaque here; we expose no parameters

typedef int32_t midi_device_t;

typedef void (*fptr_patch_init_t)(int32_t fwid);
typedef void (*fptr_patch_dispose_t)(void);
typedef void (*fptr_patch_dsp_process_t)(int32_t *inbuf, int32_t *outbuf);
typedef void (*fptr_patch_midi_in_handler_t)(midi_device_t dev, uint8_t port,
                                             uint8_t status, uint8_t d1,
                                             uint8_t d2);
typedef void (*fptr_patch_applyPreset_t)(int32_t);

typedef struct {
  int32_t pexIndex;
  int32_t value;
} PresetParamChange_t;

typedef struct {
  fptr_patch_init_t fptr_patch_init;
  fptr_patch_dispose_t fptr_patch_dispose;
  fptr_patch_dsp_process_t fptr_dsp_process;
  fptr_patch_midi_in_handler_t fptr_MidiInHandler;
  fptr_patch_applyPreset_t fptr_applyPreset;
  uint32_t numPEx;
  ParameterExchange_t *pPExch;
  int32_t *pDisplayVector;
  uint32_t patchID;
  uint32_t initpreset_size;
  void *pInitpreset;
  uint32_t npresets;
  uint32_t npreset_entries;
  PresetParamChange_t *pPresets;
} patchMeta_t;

extern "C" {
extern patchMeta_t patchMeta;               // firmware global, via --just-symbols
void LogTextMessage(const char *format, ...);  // reaches the host as "AxoT"

// Linker-script symbols (ramlink.ld).
extern uint32_t _pbss_start;
extern uint32_t _pbss_end;
}

// The audio callback moves 16 frames of interleaved stereo int32 per call,
// 3000 calls/s at 48 kHz. Sample format on the wire is q27<<4; the generated
// patcher code works in q27 after >>4.
#define AXO_BUFSIZE 16

// Boilerplate: entry point in .boot (must be the first code in the binary),
// bss clear, and patchMeta wiring. `body` runs before fptr_dsp_process is set.
#define AXO_PATCH(patch_id_, dsp_fn_, dispose_fn_, body_)                     \
  extern "C" void xpatch_init2(int32_t fwid);                                 \
  extern "C" __attribute__((section(".boot"))) void xpatch_init(int32_t fwid) \
  {                                                                           \
    xpatch_init2(fwid);                                                       \
  }                                                                           \
  static void axo_null_midi(midi_device_t, uint8_t, uint8_t, uint8_t,         \
                            uint8_t) {}                                       \
  static void axo_null_preset(int32_t) {}                                     \
  extern "C" void xpatch_init2(int32_t fwid)                                  \
  {                                                                           \
    if (fwid != (int32_t)SG_EXPECTED_FWID)                                    \
      return;                                                                 \
    for (volatile uint32_t *p = &_pbss_start; p < &_pbss_end; p++)            \
      *p = 0;                                                                 \
    patchMeta.numPEx = 0;                                                     \
    patchMeta.pPExch = 0;                                                     \
    patchMeta.pDisplayVector = 0;                                             \
    patchMeta.npresets = 0;                                                   \
    patchMeta.npreset_entries = 0;                                            \
    patchMeta.pPresets = 0;                                                   \
    patchMeta.patchID = (patch_id_);                                          \
    patchMeta.fptr_applyPreset = axo_null_preset;                             \
    patchMeta.fptr_MidiInHandler = axo_null_midi;                             \
    patchMeta.fptr_patch_dispose = (dispose_fn_);                             \
    body_;                                                                    \
    patchMeta.fptr_dsp_process = (dsp_fn_);                                   \
  }

#endif  // AXO_ABI_H
