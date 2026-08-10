# OPL2 instruments, vendored from Freedoom

The `.sbi` files under `instruments/` are copied verbatim from the
[Freedoom](https://github.com/freedoom/freedoom) project's `lumps/genmidi/instruments/`,
where they are original, freely-licensed work — Freedoom's GENMIDI policy forbids
SBI files taken from the web, and its instrument set traces to OpenBSD's kernel. The
licence is the modified BSD alongside them in `FREEDOOM-COPYING.adoc`; this directory
must keep that file for as long as it keeps the instruments.

`tools/opl2-import.mjs` maps each instrument onto a SoundGraph patch in
`examples/patches/fm/`, through the oscillators' linear `pm` input. The mapping and its
approximations are documented at the top of that script and recorded per-patch in the
metadata; the plan for making them measurements instead of approximations is a
Nuked-OPL3 oracle, per `docs/fm-import-sources.md`.

Currently vendored: all 128 General MIDI melodic primary voices. Not yet imported:
the `-2` second voices of dual-voice instruments (a detuned richness layer) and the 47
percussion entries (note-mapped drum hits, a different kind of library). The importer
handles any `.sbi` dropped in here.
