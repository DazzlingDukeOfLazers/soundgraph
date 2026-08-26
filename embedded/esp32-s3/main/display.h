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

// Colours are 0xRRGGBB. The panel is driven at 24 bits per pixel: its glass is a
// 16.7-million-colour part, and RGB565 gave green only six bits — sixty-four steps,
// visible as bands in any ramp and not enough to choose a phosphor by.

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
void display_clear(uint32_t rgb);
void display_pixel(int x, int y, uint32_t rgb);
void display_rect(int x, int y, int width, int height, uint32_t rgb);
// One pixel, blended. alpha 0-255. Anti-aliasing is worth the arithmetic here: a
// 410-pixel panel held at arm's length shows every jagged step on a circle.
void display_blend(int x, int y, uint32_t rgb, int alpha);
void display_disc(int cx, int cy, float radius, uint32_t rgb);
// Angles in degrees in the usual screen convention — 0 points right, growing clockwise
// because y grows downward. The rack uses the same one, so a knob's 135..405 travel
// reads identically in both.
void display_arc(int cx, int cy, float radius, float thickness,
                 float start_degrees, float end_degrees, uint32_t rgb);
void display_line(float x0, float y0, float x1, float y1, float width, uint32_t rgb);
// 5x7 glyphs, integer-scaled. Returns the width drawn.
int display_text(int x, int y, const char* text, int scale, uint32_t rgb);
int display_text_width(const char* text, int scale);

// Pushes the framebuffer to the glass.
bool display_present();

bool display_set_brightness(int percent);
bool display_test_card();

static inline uint32_t display_rgb(int r, int g, int b) {
    return (static_cast<uint32_t>(r & 0xFF) << 16) |
           (static_cast<uint32_t>(g & 0xFF) << 8) | static_cast<uint32_t>(b & 0xFF);
}
