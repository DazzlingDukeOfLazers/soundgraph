# Current Phase

**Knobcon hardening** — "can this demo work thirty consecutive times in front of
strangers?" Branch `knobcon-hardening`. Sep 4 freeze, Sep 11 show.

All six milestones on the critical path (A, B, C, F) are merged to `main`. What remains
is reliability and demo polish, not features.

## The checklist

- [x] **Malformed patches on device.** `sg-serial.py abuse`: plain garbage, truncated
      JSON, wrong schema version, unknown node, zero-delay cycle, truncated upload. All
      rejected cleanly with the core's own diagnostics; device stays alive and playing;
      nothing bad persists to NVS; a good deploy works immediately after. Two real bugs
      found and fixed on the way (below).
- [x] **Power-cycle soak.** `sg-serial.py soak --cycles 30`: thirty consecutive clean
      boots, arpeggiator up every time, internal heap spread across all cycles **0
      bytes** — byte-identical free memory after every boot. Resets via close/reopen
      (which also exercises USB re-enumeration each cycle) after RTS-pulse resets proved
      stateful on the USB-JTAG bridge — the second pulse parked the chip in silent
      download mode.
- [x] **One-click deploy from the web editor** — written, not yet clicked. Chrome's Web
      Serial speaks the same `load` protocol as the python tool; board-side rejection
      diagnostics render in the same problems panel as local ones. Needs a human click
      to test: the serial port chooser is gesture-gated by design.
- [ ] **Human eyes on both editors.** Still nobody has looked at either UI. This is
      Daniel's item; everything else has been verified headlessly.

## Bugs the hardening has caught so far

- A truncated upload wedged the device console forever: with the interrupt-driven USB
  console driver, `getchar()` blocks with no timeout. Payloads now read through the
  driver directly with a bounded wait, an abandoned transfer drains stragglers, and
  stdio read-ahead is disabled so the two paths cannot fight over bytes.
- RTS-pulse resets are not idempotent on the USB-Serial-JTAG bridge. The reliable reset
  is opening the port. Encoded in `sg-serial.py`.

## Remaining before the show (docs/KNOBCon_2026.md)

Landing page, README pass, QR, getting-started, architecture diagram, board page, short
video, backup firmware/cables/board. None of it is code.

## Invariants being protected

- The device rejects; it never crashes, never persists garbage, never stops playing.
- The deploy protocol is identical from python and from the browser.
- Every diagnostic a user sees, on any surface, comes from the one validator in dsp-core.
