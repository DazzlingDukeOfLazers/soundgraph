// The panel, when the board has one.
//
// A framebuffer in PSRAM rather than direct panel writes, for three reasons that all
// arrived the same afternoon: this glass addresses pixels in 2x2 units and rejects
// anything odd, the panel is mounted at ninety degrees to the wrist, and a knob is a
// circle. Draw into memory in logical coordinates, rotate on the way out, and present
// one aligned rectangle — every awkwardness handled in one place instead of at every
// call site.
#pragma once

#include <cstdint>

bool display_init();
bool display_available();

// Logical size, which is the physical size with the rotation applied.
int display_width();
int display_height();

// 0, 90, 180, 270. Live: the UI redraws itself in the new orientation, so this can be
// found by eye on the bench rather than derived from a mechanical drawing.
void display_set_rotation(int degrees);
int display_rotation();

// ---- drawing, all in logical coordinates ----------------------------------------
void display_clear(uint16_t rgb565);
void display_pixel(int x, int y, uint16_t rgb565);
void display_rect(int x, int y, int width, int height, uint16_t rgb565);
void display_disc(int cx, int cy, int radius, uint16_t rgb565);
void display_ring(int cx, int cy, int radius, int thickness, uint16_t rgb565);
// Angles in degrees, zero pointing straight down, growing clockwise — the convention a
// knob's travel is usually quoted in.
void display_arc(int cx, int cy, int radius, int thickness,
                 float start_degrees, float end_degrees, uint16_t rgb565);
// 5x7 glyphs, integer-scaled. Returns the width drawn.
int display_text(int x, int y, const char* text, int scale, uint16_t rgb565);
int display_text_width(const char* text, int scale);

// Pushes the framebuffer to the glass.
bool display_present();

bool display_set_brightness(int percent);
bool display_test_card();

static inline uint16_t display_rgb(int r, int g, int b) {
    return static_cast<uint16_t>(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
