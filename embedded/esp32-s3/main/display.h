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

// A line with a halo. Not the same thing as a thick line: the core is the signal and the
// halo is light spilling off it, so they are lit and shaped independently — `width` is
// the bright core, `glow` how far the spill reaches past it, `intensity` how bright the
// spill starts (0-100).
void display_glow_line(float x0, float y0, float x1, float y1,
                       float width, float glow, int intensity, uint32_t rgb);
// 5x7 glyphs, integer-scaled. Returns the width drawn.
int display_text(int x, int y, const char* text, int scale, uint32_t rgb);
int display_text_width(const char* text, int scale);

// Pushes the framebuffer to the glass.
bool display_present();

// Push only these logical rows. A full frame is 602 KB over QSPI and costs 32 ms, which
// is most of a drag's latency spent redelivering pixels that did not change. Rows rather
// than a rectangle because the framebuffer is row-major: a band of rows is already
// contiguous and needs no staging copy, while a rectangle would need one.
bool display_present_rows(int y, int height);

// Clear only these logical rows, for the same reason.
void display_clear_rows(int y, int height, uint32_t rgb);

// Refuse to write outside these logical rows until the clip is released.
//
// Banded redraw is only sound if the drawing is actually confined to the band, and
// clipping the *geometry* is not the same thing. A glow line draws rounded caps past its
// endpoints, so a bar shortened to the band still painted its cap above the band top —
// into rows nobody had cleared and nobody would clear, one more cap per drag step, until
// the slider trailed a ladder of them. Clipping at the pixel is the only version that
// cannot be got wrong by a caller who forgets what their primitive draws.
void display_set_clip_rows(int y, int height);
void display_clear_clip();

bool display_set_brightness(int percent);
bool display_test_card();

// A colour scaled toward black. Correct against a true black ground, which an AMOLED
// gives for free, and the basis of every halo and dim label in the interface.
static inline uint32_t display_dim(uint32_t colour, int percent) {
    const int r = static_cast<int>((colour >> 16) & 0xFF) * percent / 100;
    const int g = static_cast<int>((colour >> 8) & 0xFF) * percent / 100;
    const int b = static_cast<int>(colour & 0xFF) * percent / 100;
    return (static_cast<uint32_t>(r & 0xFF) << 16) |
           (static_cast<uint32_t>(g & 0xFF) << 8) | static_cast<uint32_t>(b & 0xFF);
}

static inline uint32_t display_rgb(int r, int g, int b) {
    return (static_cast<uint32_t>(r & 0xFF) << 16) |
           (static_cast<uint32_t>(g & 0xFF) << 8) | static_cast<uint32_t>(b & 0xFF);
}
