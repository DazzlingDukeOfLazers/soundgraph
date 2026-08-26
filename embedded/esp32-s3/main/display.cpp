#include "display.h"

#include "board_config.h"

#if !SG_DISPLAY_PRESENT

bool display_init() { return false; }
bool display_available() { return false; }
int display_width() { return 0; }
int display_height() { return 0; }
void display_set_rotation(int) {}
int display_rotation() { return 0; }
void display_clear(uint32_t) {}
void display_pixel(int, int, uint32_t) {}
void display_rect(int, int, int, int, uint32_t) {}
void display_blend(int, int, uint32_t, int) {}
void display_disc(int, int, float, uint32_t) {}
void display_arc(int, int, float, float, float, float, uint32_t) {}
void display_line(float, float, float, float, float, uint32_t) {}
void display_glow_line(float, float, float, float, float, float, int, uint32_t) {}
int display_text(int, int, const char*, int, uint32_t) { return 0; }
int display_text_width(const char*, int) { return 0; }
// Distance from a point to a segment. The glow is a field around the line rather than a
// stack of strokes, so every pixel needs to know how far off the line it is.
namespace {
float distance_to_segment(float px, float py, float x0, float y0, float x1, float y1) {
    const float dx = x1 - x0, dy = y1 - y0;
    const float len2 = dx * dx + dy * dy;
    float t = len2 > 0.0f ? ((px - x0) * dx + (py - y0) * dy) / len2 : 0.0f;
    t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
    const float ax = px - (x0 + dx * t), ay = py - (y0 + dy * t);
    return std::sqrt(ax * ax + ay * ay);
}
}  // namespace

void display_glow_line(float x0, float y0, float x1, float y1,
                       float width, float glow, int intensity, uint32_t colour) {
    const float half = width * 0.5f;
    const float spill = glow > 0.0f ? glow : 0.0f;
    const float reach = half + spill;

    // One pass over the bounding box. Stamping concentric wider strokes — the obvious
    // way — costs passes x length x radius^2 blends, and still bands visibly because a
    // handful of strokes cannot approximate a smooth falloff. Evaluating the field costs
    // the area once and is continuous by construction.
    const int x_lo = static_cast<int>(std::floor((x0 < x1 ? x0 : x1) - reach - 1.0f));
    const int x_hi = static_cast<int>(std::ceil((x0 > x1 ? x0 : x1) + reach + 1.0f));
    const int y_lo = static_cast<int>(std::floor((y0 < y1 ? y0 : y1) - reach - 1.0f));
    const int y_hi = static_cast<int>(std::ceil((y0 > y1 ? y0 : y1) + reach + 1.0f));

    for (int y = y_lo; y <= y_hi; ++y) {
        for (int x = x_lo; x <= x_hi; ++x) {
            const float d = distance_to_segment(static_cast<float>(x) + 0.5f,
                                                static_cast<float>(y) + 0.5f,
                                                x0, y0, x1, y1);
            if (d > reach + 0.5f) continue;

            // The core, with a pixel of anti-aliasing at its edge.
            float coverage = half + 0.5f - d;
            coverage = coverage < 0.0f ? 0.0f : (coverage > 1.0f ? 1.0f : coverage);
            int alpha = static_cast<int>(coverage * 255.0f + 0.5f);

            // The halo. Squared falloff because scattering falls off fast; a linear ramp
            // reads as a fat soft line rather than as a lit thin one.
            if (spill > 0.0f && d > half) {
                const float u = (d - half) / spill;
                if (u < 1.0f) {
                    const float fall = (1.0f - u) * (1.0f - u);
                    const int halo = static_cast<int>(255.0f * fall * intensity / 100.0f);
                    if (halo > alpha) alpha = halo;
                }
            }
            if (alpha > 0) display_blend(x, y, colour, alpha);
        }
    }
}

bool display_present() { return false; }
bool display_set_brightness(int) { return false; }
bool display_test_card() { return false; }

#else

#include <cmath>
#include <cstring>

#include "driver/spi_master.h"
#include "esp_heap_caps.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_lcd_sh8601.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

namespace {

const char* const TAG = "sg-display";

// The panel's own wake-up sequence, from Waveshare's BSP for this board. It belongs to
// the panel rather than the wiring, so it lives here keyed by chip rather than in the
// manifest. Without it the controller answers on QSPI and stays dark — the failure that
// looks exactly like a dead backlight. 0x2A's window (0x16..0x1AF) is 410 columns
// starting at 22, which is where the x gap comes from.
const sh8601_lcd_init_cmd_t kPanelInit[] = {
    {0x11, (uint8_t[]){0x00}, 0, 120},
    {0xC4, (uint8_t[]){0x80}, 1, 0},
    {0x44, (uint8_t[]){0x01, 0xD1}, 2, 0},
    {0x35, (uint8_t[]){0x00}, 1, 0},
    {0x53, (uint8_t[]){0x20}, 1, 10},
    {0x63, (uint8_t[]){0xFF}, 1, 10},
    {0x51, (uint8_t[]){0x00}, 1, 10},
    {0x2A, (uint8_t[]){0x00, 0x16, 0x01, 0xAF}, 4, 0},
    {0x2B, (uint8_t[]){0x00, 0x00, 0x01, 0xF5}, 4, 0},
    {0x29, (uint8_t[]){0x00}, 0, 10},
    {0x51, (uint8_t[]){0xFF}, 1, 0},
    // COLMOD last, and ours. The driver sets the pixel format before this sequence
    // runs and something in the sequence puts it back; forcing it here is what makes
    // 24-bit stick. 0x77 is RGB888.
    {0x3A, (uint8_t[]){0x77}, 1, 10},
};

// 5x7, column-major, one byte per column, bit 0 at the top. Uppercase, digits and the
// handful of marks a control surface needs — a synth panel says CUTOFF and 2400, not
// prose, so this is the whole alphabet it needs to own.
constexpr uint8_t kFont[][5] = {
    {0x00,0x00,0x00,0x00,0x00}, // space
    {0x7E,0x11,0x11,0x11,0x7E}, // A
    {0x7F,0x49,0x49,0x49,0x36}, // B
    {0x3E,0x41,0x41,0x41,0x22}, // C
    {0x7F,0x41,0x41,0x22,0x1C}, // D
    {0x7F,0x49,0x49,0x49,0x41}, // E
    {0x7F,0x09,0x09,0x09,0x01}, // F
    {0x3E,0x41,0x49,0x49,0x7A}, // G
    {0x7F,0x08,0x08,0x08,0x7F}, // H
    {0x00,0x41,0x7F,0x41,0x00}, // I
    {0x20,0x40,0x41,0x3F,0x01}, // J
    {0x7F,0x08,0x14,0x22,0x41}, // K
    {0x7F,0x40,0x40,0x40,0x40}, // L
    {0x7F,0x02,0x0C,0x02,0x7F}, // M
    {0x7F,0x04,0x08,0x10,0x7F}, // N
    {0x3E,0x41,0x41,0x41,0x3E}, // O
    {0x7F,0x09,0x09,0x09,0x06}, // P
    {0x3E,0x41,0x51,0x21,0x5E}, // Q
    {0x7F,0x09,0x19,0x29,0x46}, // R
    {0x46,0x49,0x49,0x49,0x31}, // S
    {0x01,0x01,0x7F,0x01,0x01}, // T
    {0x3F,0x40,0x40,0x40,0x3F}, // U
    {0x1F,0x20,0x40,0x20,0x1F}, // V
    {0x7F,0x20,0x18,0x20,0x7F}, // W
    {0x63,0x14,0x08,0x14,0x63}, // X
    {0x03,0x04,0x78,0x04,0x03}, // Y
    {0x61,0x51,0x49,0x45,0x43}, // Z
    {0x3E,0x51,0x49,0x45,0x3E}, // 0
    {0x00,0x42,0x7F,0x40,0x00}, // 1
    {0x42,0x61,0x51,0x49,0x46}, // 2
    {0x21,0x41,0x45,0x4B,0x31}, // 3
    {0x18,0x14,0x12,0x7F,0x10}, // 4
    {0x27,0x45,0x45,0x45,0x39}, // 5
    {0x3C,0x4A,0x49,0x49,0x30}, // 6
    {0x01,0x71,0x09,0x05,0x03}, // 7
    {0x36,0x49,0x49,0x49,0x36}, // 8
    {0x06,0x49,0x49,0x29,0x1E}, // 9
    {0x00,0x60,0x60,0x00,0x00}, // .
    {0x08,0x08,0x08,0x08,0x08}, // -
    {0x00,0x36,0x36,0x00,0x00}, // :
    {0x00,0x00,0x5F,0x00,0x00}, // !
    {0x02,0x01,0x51,0x09,0x06}, // ?
    {0x14,0x14,0x14,0x14,0x14}, // =
    {0x08,0x08,0x3E,0x08,0x08}, // +
    {0x08,0x14,0x22,0x00,0x00}, // <
    {0x00,0x00,0x22,0x14,0x08}, // >
    {0x20,0x10,0x08,0x04,0x02}, // /
    {0x40,0x40,0x40,0x40,0x40}, // _
};

int glyph_index(char c) {
    if (c == ' ') return 0;
    if (c >= 'A' && c <= 'Z') return 1 + (c - 'A');
    if (c >= 'a' && c <= 'z') return 1 + (c - 'a');
    if (c >= '0' && c <= '9') return 27 + (c - '0');
    switch (c) {
        case '.': return 37;
        case '-': return 38;
        case ':': return 39;
        case '!': return 40;
        case '?': return 41;
        case '=': return 42;
        case '+': return 43;
        case '<': return 44;
        case '>': return 45;
        case '/': return 46;
        case '_': return 47;
        default: return 0;
    }
}

esp_lcd_panel_handle_t g_panel = nullptr;
esp_lcd_panel_io_handle_t g_io = nullptr;

// Physical layout, always: the framebuffer matches the glass, and rotation happens on
// the way in rather than on the way out, so presenting is one straight blit.
//
// Three bytes a pixel, R then G then B: COLMOD 0x77, which is what makes this a
// 16.7-million-colour panel rather than a 65-thousand-colour one.
uint8_t* g_fb = nullptr;
constexpr int kBytesPerPixel = 3;

// draw_bitmap only *queues* the transfer. The bounce buffer must not be refilled until
// the DMA that is reading it has finished, or bands arrive carrying their successor's
// pixels — which looks like horizontal streaking and text drawn twice at an offset,
// because that is precisely what it is.
SemaphoreHandle_t g_trans_done = nullptr;

bool IRAM_ATTR on_trans_done(esp_lcd_panel_io_handle_t, esp_lcd_panel_io_event_data_t*,
                             void*) {
    BaseType_t woken = pdFALSE;
    if (g_trans_done != nullptr) xSemaphoreGiveFromISR(g_trans_done, &woken);
    return woken == pdTRUE;
}

int g_rotation = 0;

inline void put_physical(int px, int py, uint32_t colour) {
    if (px < 0 || py < 0 || px >= SG_DISPLAY_WIDTH || py >= SG_DISPLAY_HEIGHT) return;
    uint8_t* p = g_fb + (py * SG_DISPLAY_WIDTH + px) * kBytesPerPixel;
    p[0] = static_cast<uint8_t>(colour >> 16);
    p[1] = static_cast<uint8_t>(colour >> 8);
    p[2] = static_cast<uint8_t>(colour);
}

}  // namespace

int display_width() {
    return (g_rotation == 90 || g_rotation == 270) ? SG_DISPLAY_HEIGHT : SG_DISPLAY_WIDTH;
}

int display_height() {
    return (g_rotation == 90 || g_rotation == 270) ? SG_DISPLAY_WIDTH : SG_DISPLAY_HEIGHT;
}

void display_set_rotation(int degrees) {
    degrees %= 360;
    if (degrees < 0) degrees += 360;
    g_rotation = (degrees / 90) * 90;
}

int display_rotation() { return g_rotation; }

void display_pixel(int x, int y, uint32_t colour) {
    if (g_fb == nullptr) return;
    switch (g_rotation) {
        case 90:  put_physical(SG_DISPLAY_WIDTH - 1 - y, x, colour); break;
        case 180: put_physical(SG_DISPLAY_WIDTH - 1 - x, SG_DISPLAY_HEIGHT - 1 - y, colour); break;
        case 270: put_physical(y, SG_DISPLAY_HEIGHT - 1 - x, colour); break;
        default:  put_physical(x, y, colour); break;
    }
}

void display_clear(uint32_t colour) {
    if (g_fb == nullptr) return;
    const uint8_t r = static_cast<uint8_t>(colour >> 16);
    const uint8_t g = static_cast<uint8_t>(colour >> 8);
    const uint8_t b = static_cast<uint8_t>(colour);
    uint8_t* p = g_fb;
    for (int i = 0; i < SG_DISPLAY_WIDTH * SG_DISPLAY_HEIGHT; ++i) {
        *p++ = r; *p++ = g; *p++ = b;
    }
}

void display_rect(int x, int y, int width, int height, uint32_t colour) {
    for (int row = 0; row < height; ++row) {
        for (int col = 0; col < width; ++col) display_pixel(x + col, y + row, colour);
    }
}

void display_blend(int x, int y, uint32_t colour, int alpha) {
    if (g_fb == nullptr || alpha <= 0) return;
    if (alpha >= 255) { display_pixel(x, y, colour); return; }
    // Read-modify-write through the same rotation the writer uses, so blending happens
    // in logical space and no caller has to think about the panel's mounting.
    int px = x, py = y;
    switch (g_rotation) {
        case 90:  px = SG_DISPLAY_WIDTH - 1 - y; py = x; break;
        case 180: px = SG_DISPLAY_WIDTH - 1 - x; py = SG_DISPLAY_HEIGHT - 1 - y; break;
        case 270: px = y; py = SG_DISPLAY_HEIGHT - 1 - x; break;
        default: break;
    }
    if (px < 0 || py < 0 || px >= SG_DISPLAY_WIDTH || py >= SG_DISPLAY_HEIGHT) return;
    uint8_t* p = g_fb + (py * SG_DISPLAY_WIDTH + px) * kBytesPerPixel;
    const int cr = (colour >> 16) & 0xFF, cg = (colour >> 8) & 0xFF, cb = colour & 0xFF;
    p[0] = static_cast<uint8_t>((cr * alpha + p[0] * (255 - alpha)) / 255);
    p[1] = static_cast<uint8_t>((cg * alpha + p[1] * (255 - alpha)) / 255);
    p[2] = static_cast<uint8_t>((cb * alpha + p[2] * (255 - alpha)) / 255);
}

namespace {
// Coverage of one pixel by an edge, as a soft step across a single pixel. Cheap, and
// indistinguishable from a real area calculation at these radii.
inline int edge_alpha(float distance, float edge) {
    const float d = edge + 0.5f - distance;
    if (d <= 0.0f) return 0;
    if (d >= 1.0f) return 255;
    return static_cast<int>(d * 255.0f);
}
}  // namespace

void display_disc(int cx, int cy, float radius, uint32_t colour) {
    const int r = static_cast<int>(radius) + 2;
    for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
            const int a = edge_alpha(
                std::sqrt(static_cast<float>(dx * dx + dy * dy)), radius);
            if (a > 0) display_blend(cx + dx, cy + dy, colour, a);
        }
    }
}

void display_arc(int cx, int cy, float radius, float thickness,
                 float start_degrees, float end_degrees, uint32_t colour) {
    if (end_degrees <= start_degrees) return;
    const float outer = radius + thickness * 0.5f;
    const float inner = radius - thickness * 0.5f;
    const int r = static_cast<int>(outer) + 2;
    for (int dy = -r; dy <= r; ++dy) {
        for (int dx = -r; dx <= r; ++dx) {
            const float d = std::sqrt(static_cast<float>(dx * dx + dy * dy));
            int a = edge_alpha(d, outer);
            if (a == 0) continue;
            const float di = d - inner + 0.5f;
            if (di <= 0.0f) continue;
            if (di < 1.0f) a = static_cast<int>(a * di);

            float angle = std::atan2(static_cast<float>(dy), static_cast<float>(dx))
                          * 180.0f / 3.14159265f;
            while (angle < start_degrees) angle += 360.0f;
            if (angle > end_degrees) {
                // Feather the caps by about a pixel of arc length; stopping hard is
                // what makes short arcs look chewed.
                const float over = (angle - end_degrees) * 3.14159265f / 180.0f * d;
                if (over >= 1.0f) continue;
                a = static_cast<int>(a * (1.0f - over));
            }
            if (a > 0) display_blend(cx + dx, cy + dy, colour, a);
        }
    }
}

void display_line(float x0, float y0, float x1, float y1, float width, uint32_t colour) {
    const float dx = x1 - x0, dy = y1 - y0;
    const float length = std::sqrt(dx * dx + dy * dy);
    if (length < 0.001f) return;
    const int steps = static_cast<int>(length * 2.0f) + 1;
    for (int i = 0; i <= steps; ++i) {
        const float t = static_cast<float>(i) / steps;
        display_disc(static_cast<int>(x0 + dx * t + 0.5f),
                     static_cast<int>(y0 + dy * t + 0.5f), width * 0.5f, colour);
    }
}

int display_text_width(const char* text, int scale) {
    return static_cast<int>(std::strlen(text)) * 6 * scale;
}

int display_text(int x, int y, const char* text, int scale, uint32_t colour) {
    int cursor = x;
    for (const char* p = text; *p != '\0'; ++p) {
        const uint8_t* glyph = kFont[glyph_index(*p)];
        for (int col = 0; col < 5; ++col) {
            for (int row = 0; row < 7; ++row) {
                if ((glyph[col] >> row) & 1) {
                    display_rect(cursor + col * scale, y + row * scale, scale, scale, colour);
                }
            }
        }
        cursor += 6 * scale;
    }
    return cursor - x;
}

// Distance from a point to a segment. The glow is a field around the line rather than a
// stack of strokes, so every pixel needs to know how far off the line it is.
namespace {
float distance_to_segment(float px, float py, float x0, float y0, float x1, float y1) {
    const float dx = x1 - x0, dy = y1 - y0;
    const float len2 = dx * dx + dy * dy;
    float t = len2 > 0.0f ? ((px - x0) * dx + (py - y0) * dy) / len2 : 0.0f;
    t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
    const float ax = px - (x0 + dx * t), ay = py - (y0 + dy * t);
    return std::sqrt(ax * ax + ay * ay);
}
}  // namespace

void display_glow_line(float x0, float y0, float x1, float y1,
                       float width, float glow, int intensity, uint32_t colour) {
    const float half = width * 0.5f;
    const float spill = glow > 0.0f ? glow : 0.0f;
    const float reach = half + spill;

    // One pass over the bounding box. Stamping concentric wider strokes — the obvious
    // way — costs passes x length x radius^2 blends, and still bands visibly because a
    // handful of strokes cannot approximate a smooth falloff. Evaluating the field costs
    // the area once and is continuous by construction.
    const int x_lo = static_cast<int>(std::floor((x0 < x1 ? x0 : x1) - reach - 1.0f));
    const int x_hi = static_cast<int>(std::ceil((x0 > x1 ? x0 : x1) + reach + 1.0f));
    const int y_lo = static_cast<int>(std::floor((y0 < y1 ? y0 : y1) - reach - 1.0f));
    const int y_hi = static_cast<int>(std::ceil((y0 > y1 ? y0 : y1) + reach + 1.0f));

    for (int y = y_lo; y <= y_hi; ++y) {
        for (int x = x_lo; x <= x_hi; ++x) {
            const float d = distance_to_segment(static_cast<float>(x) + 0.5f,
                                                static_cast<float>(y) + 0.5f,
                                                x0, y0, x1, y1);
            if (d > reach + 0.5f) continue;

            // The core, with a pixel of anti-aliasing at its edge.
            float coverage = half + 0.5f - d;
            coverage = coverage < 0.0f ? 0.0f : (coverage > 1.0f ? 1.0f : coverage);
            int alpha = static_cast<int>(coverage * 255.0f + 0.5f);

            // The halo. Squared falloff because scattering falls off fast; a linear ramp
            // reads as a fat soft line rather than as a lit thin one.
            if (spill > 0.0f && d > half) {
                const float u = (d - half) / spill;
                if (u < 1.0f) {
                    const float fall = (1.0f - u) * (1.0f - u);
                    const int halo = static_cast<int>(255.0f * fall * intensity / 100.0f);
                    if (halo > alpha) alpha = halo;
                }
            }
            if (alpha > 0) display_blend(x, y, colour, alpha);
        }
    }
}

bool display_present() {
    if (g_panel == nullptr || g_fb == nullptr) return false;
    // Straight from the framebuffer, in one transfer, with no bounce buffer.
    //
    // The bounce was a bug worth remembering: a band at 24 bits is nearly 20 KB, which
    // the SPI driver splits into several transactions, while this code waited for a
    // single completion before refilling the buffer. Early bands were overwritten
    // in flight and arrived as noise; only the last, where the timing happened to work
    // out, drew correctly — knobs over a white, seething ground. Nothing writes the
    // framebuffer during a present, so DMA can read it where it lies, and the whole
    // class of hazard goes away with the copy.
    if (esp_lcd_panel_draw_bitmap(g_panel, 0, 0, SG_DISPLAY_WIDTH, SG_DISPLAY_HEIGHT,
                                  g_fb) != ESP_OK) {
        return false;
    }
    xSemaphoreTake(g_trans_done, pdMS_TO_TICKS(1000));
    return true;
}

bool display_init() {
    spi_bus_config_t bus = {};
    bus.sclk_io_num = SG_DISPLAY_QSPI_SCLK;
    bus.data0_io_num = SG_DISPLAY_QSPI_D0;
    bus.data1_io_num = SG_DISPLAY_QSPI_D1;
    bus.data2_io_num = SG_DISPLAY_QSPI_D2;
    bus.data3_io_num = SG_DISPLAY_QSPI_D3;
    bus.max_transfer_sz = SG_DISPLAY_WIDTH * SG_DISPLAY_HEIGHT * kBytesPerPixel;
    if (spi_bus_initialize(SPI2_HOST, &bus, SPI_DMA_CH_AUTO) != ESP_OK) {
        ESP_LOGE(TAG, "QSPI bus would not start");
        return false;
    }

    esp_lcd_panel_io_spi_config_t io_config = {};
    io_config.cs_gpio_num = SG_DISPLAY_QSPI_CS;
    io_config.dc_gpio_num = -1;
    io_config.spi_mode = 0;
    io_config.pclk_hz = 40 * 1000 * 1000;
    io_config.trans_queue_depth = 2;
    io_config.on_color_trans_done = on_trans_done;
    io_config.lcd_cmd_bits = 32;
    io_config.lcd_param_bits = 8;
    io_config.flags.quad_mode = true;
    if (esp_lcd_new_panel_io_spi(SPI2_HOST, &io_config, &g_io) != ESP_OK) {
        ESP_LOGE(TAG, "panel IO would not start");
        return false;
    }

    sh8601_vendor_config_t vendor = {};
    vendor.init_cmds = kPanelInit;
    vendor.init_cmds_size = sizeof(kPanelInit) / sizeof(kPanelInit[0]);
    vendor.flags.use_qspi_interface = 1;

    esp_lcd_panel_dev_config_t panel_config = {};
    panel_config.reset_gpio_num = SG_DISPLAY_RESET;
    // BGR, not RGB: this glass wires the channels the other way round, and a red fill
    // arrives blue if you take the vendor BSP's word for it. Measured on the board.
    // RGB, not BGR — and the opposite of what this panel needed at 16 bits.
    //
    // `screen fill FF0000` photographs as pure blue with BGR here and pure red with RGB,
    // so the driver plainly does act on this field; an earlier note in the history
    // claiming it ignores the field at 24 bits is wrong, and flipping the flag is what
    // disproved it. What is established is only that the correct value flipped when the
    // pixel format did. Why it flipped — a byte order in the 565 path that the 888 path
    // does not share is the obvious suspect — is not established, and guessing at it in
    // a comment is how the last wrong explanation got written down.
    //
    // Worth knowing that this failed silently for hours: the interface is green arcs and
    // white pointers on black, and green, white and black are all unchanged by swapping
    // red with blue. It took six greens chosen to differ before anything looked wrong.
    panel_config.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
    panel_config.bits_per_pixel = 24;
    panel_config.vendor_config = &vendor;
    if (esp_lcd_new_panel_sh8601(g_io, &panel_config, &g_panel) != ESP_OK) {
        ESP_LOGE(TAG, "%s would not initialise", SG_DISPLAY_CHIP);
        g_panel = nullptr;
        return false;
    }
    esp_lcd_panel_reset(g_panel);
    esp_lcd_panel_init(g_panel);
    // The controller's frame buffer is wider than the glass; without the gap every
    // pixel lands 22 columns left of where it was asked for.
    esp_lcd_panel_set_gap(g_panel, SG_DISPLAY_X_OFFSET, SG_DISPLAY_Y_OFFSET);
    esp_lcd_panel_disp_on_off(g_panel, true);

    g_fb = static_cast<uint8_t*>(heap_caps_malloc(
        SG_DISPLAY_WIDTH * SG_DISPLAY_HEIGHT * kBytesPerPixel, MALLOC_CAP_SPIRAM));
    g_trans_done = xSemaphoreCreateBinary();
    if (g_fb == nullptr || g_trans_done == nullptr) {
        ESP_LOGE(TAG, "no memory for the framebuffer");
        return false;
    }
    display_clear(0x0000);

    ESP_LOGI(TAG, "%s up, %dx%d, %d KB framebuffer in PSRAM", SG_DISPLAY_CHIP,
             SG_DISPLAY_WIDTH, SG_DISPLAY_HEIGHT,
             SG_DISPLAY_WIDTH * SG_DISPLAY_HEIGHT * kBytesPerPixel / 1024);
    return true;
}

bool display_available() { return g_panel != nullptr; }

bool display_set_brightness(int percent) {
    if (g_io == nullptr) return false;
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    // The panel's brightness register, in the 32-bit framing QSPI commands use here:
    // 0x02 marks a command write, the opcode sits in the second byte.
    const uint32_t command = (0x02u << 24) | (0x51u << 8);
    const uint8_t value = static_cast<uint8_t>(percent * 255 / 100);
    return esp_lcd_panel_io_tx_param(g_io, command, &value, 1) == ESP_OK;
}

bool display_test_card() {
    if (g_fb == nullptr) return false;
    const int w = display_width(), h = display_height();
    display_clear(display_rgb(12, 12, 16));
    const int m = 60;
    display_rect(0, 0, m, m, display_rgb(255, 0, 0));
    display_rect(w - m, 0, m, m, display_rgb(0, 255, 0));
    display_rect(0, h - m, m, m, display_rgb(0, 0, 255));
    display_rect(w - m, h - m, m, m, display_rgb(255, 255, 255));
    display_rect(w / 2 - 1, h / 2 - 40, 3, 80, display_rgb(255, 255, 255));
    display_rect(w / 2 - 40, h / 2 - 1, 80, 3, display_rgb(255, 255, 255));
    display_text(20, h / 2 + 20, "TOP LEFT IS RED", 2, display_rgb(255, 255, 255));
    for (int i = 0; i < 16; ++i) {
        const int v = i * 17;
        display_rect(i * (w / 16), h / 2 + 70, w / 16, 30, display_rgb(v, v, v));
    }
    return display_present();
}

#endif  // SG_DISPLAY_PRESENT
