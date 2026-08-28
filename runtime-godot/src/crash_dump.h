// A minidump of last resort, for the crash nothing else can see.
//
// The editor suite dies of an access violation during shutdown, after every check has
// passed, perhaps one run in ten. Neither of the usual ways of looking works:
//
//   * Windows Error Reporting never sees it. Godot sets SEM_NOGPFAULTERRORBOX, which
//     turns reporting off for the process, so no dump is written however the machine is
//     configured.
//   * A debugger sees it, but attaching one changes the timing enough that it stops
//     happening: about 140 runs under one without a single crash, against roughly one in
//     sixty unattended.
//
// What is left is to be inside the process when it happens. A vectored exception handler
// runs before any of the frame-based ones and costs nothing until an exception is
// raised, so it perturbs the race far less than a debugger does.
//
// Off unless asked for. Set SOUNDGRAPH_CRASH_DUMP to a directory - or to 1 for the
// temporary directory - and a dump lands there when the process takes an access
// violation. Nothing is installed otherwise, so the shipped extension behaves as before.
//
// Windows only, and nothing links against dbghelp: it is loaded by name when the handler
// is installed, so the ordinary build gains no dependency at all.
#pragma once

namespace soundgraph_godot {

// Reads SOUNDGRAPH_CRASH_DUMP and, if it is set, installs the handler. Safe to call on
// any platform; does nothing where it does not apply.
void install_crash_dump_handler();

// Left deliberately unpaired: see the note in the implementation about why the handler
// is never removed once installed.
}  // namespace soundgraph_godot
