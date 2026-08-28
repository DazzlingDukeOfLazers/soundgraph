// The touch panel, when the board has one.
//
// Reports position in the same logical coordinates the display draws in, so a knob
// drawn at (x, y) is touched at (x, y) — the rotation is applied once, here and in the
// display, rather than remembered at every call site.
#pragma once

bool touch_init();
bool touch_available();

// True while a finger is down, with its logical position. False when the panel is idle.
bool touch_read(int* x, int* y);

// One read, reported both ways: what the controller said and where that lands. For
// working out which transform a new panel wants, which is otherwise a guess between
// eight that all sound equally reasonable from a description.
//
// Both from a single read on purpose. The first version of this called the raw reader
// and then the mapped one, each doing its own transaction, and the second almost always
// found the finger gone — so 74 of 75 samples reported a mapped position of 0,0 and the
// one that got through was the only real evidence in the log.
bool touch_read_probe(int* raw_x, int* raw_y, int* x, int* y);
