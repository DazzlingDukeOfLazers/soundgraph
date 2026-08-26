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
