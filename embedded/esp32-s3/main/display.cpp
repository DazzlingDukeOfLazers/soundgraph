#include "display.h"

#include "board_config.h"

#if !SG_DISPLAY_PRESENT

bool display_init() { return false; }
bool display_available() { return false; }
int display_width() { return 0; }
int display_height() { return 0; }
void display_set_rotation(int) {}
int display_rotation() { return 0; }
void display_clear(uint16_t) {}
void display_pixel(int, int, uint16_t) {}
void display_rect(int, int, int, int, uint16_t) {}
void display_disc(int, int, int, uint16_t) {}
void display_ring(int, int, int, int, uint16_t) {}
void display_arc(int, int, int, int, float, float, uint16_t) {}
int display_text(int, int, const char*, int, uint16_t) { return 0; }
int display_text_width(const char*, int) { return 0; }
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
// the way in rather than on the way out, so presenting is one straight memcpy-and-blit.
uint16_t* g_fb = nullptr;
uint16_t* g_band = nullptr;      // internal, DMA-capable bounce for the PSRAM framebuffer
constexpr int kBandRows = 16;

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

inline void put_physical(int px, int py, uint16_t colour) {
    if (px < 0 || py < 0 || px >= SG_DISPLAY_WIDTH || py >= SG_DISPLAY_HEIGHT) return;
    g_fb[py * SG_DISPLAY_WIDTH + px] = colour;
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

void display_pixel(int x, int y, uint16_t colour) {
    if (g_fb == nullptr) return;
    switch (g_rotation) {
        case 90:  put_physical(SG_DISPLAY_WIDTH - 1 - y, x, colour); break;
        case 180: put_physical(SG_DISPLAY_WIDTH - 1 - x, SG_DISPLAY_HEIGHT - 1 - y, colour); break;
        case 270: put_physical(y, SG_DISPLAY_HEIGHT - 1 - x, colour); break;
        default:  put_physical(x, y, colour); break;
    }
}

void display_clear(uint16_t colour) {
    if (g_fb == nullptr) return;
    const int count = SG_DISPLAY_WIDTH * SG_DISPLAY_HEIGHT;
    for (int i = 0; i < count; ++i) g_fb[i] = colour;
}

void display_rect(int x, int y, int width, int height, uint16_t colour) {
    for (int row = 0; row < height; ++row) {
        for (int col = 0; col < width; ++col) display_pixel(x + col, y + row, colour);
    }
}

void display_disc(int cx, int cy, int radius, uint16_t colour) {
    for (int dy = -radius; dy <= radius; ++dy) {
        const int span = static_cast<int>(std::sqrt(
            static_cast<float>(radius * radius - dy * dy)));
        for (int dx = -span; dx <= span; ++dx) display_pixel(cx + dx, cy + dy, colour);
    }
}

void display_ring(int cx, int cy, int radius, int thickness, uint16_t colour) {
    const int inner = radius - thickness;
    const int inner_sq = inner > 0 ? inner * inner : 0;
    const int outer_sq = radius * radius;
    for (int dy = -radius; dy <= radius; ++dy) {
        for (int dx = -radius; dx <= radius; ++dx) {
            const int d = dx * dx + dy * dy;
            if (d <= outer_sq && d >= inner_sq) display_pixel(cx + dx, cy + dy, colour);
        }
    }
}

void display_arc(int cx, int cy, int radius, int thickness,
                 float start_degrees, float end_degrees, uint16_t colour) {
    if (end_degrees < start_degrees) return;
    // Step finely enough that the outermost pixels still touch.
    const float step = radius > 0 ? 40.0f / radius : 4.0f;
    for (float a = start_degrees; a <= end_degrees; a += step) {
        const float rad = (a + 90.0f) * 3.14159265f / 180.0f;
        const float c = std::cos(rad), s = std::sin(rad);
        for (int t = 0; t < thickness; ++t) {
            const float r = static_cast<float>(radius - t);
            display_pixel(cx + static_cast<int>(c * r),
                          cy + static_cast<int>(s * r), colour);
        }
    }
}

int display_text_width(const char* text, int scale) {
    return static_cast<int>(std::strlen(text)) * 6 * scale;
}

int display_text(int x, int y, const char* text, int scale, uint16_t colour) {
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

bool display_present() {
    if (g_panel == nullptr || g_fb == nullptr || g_band == nullptr) return false;
    // Band at a time through internal memory: the framebuffer lives in PSRAM, and the
    // bands keep every transfer an even number of rows, which is what the panel wants.
    for (int y = 0; y < SG_DISPLAY_HEIGHT; y += kBandRows) {
        int rows = SG_DISPLAY_HEIGHT - y;
        if (rows > kBandRows) rows = kBandRows;
        rows &= ~1;
        if (rows == 0) break;
        std::memcpy(g_band, g_fb + y * SG_DISPLAY_WIDTH,
                    rows * SG_DISPLAY_WIDTH * sizeof(uint16_t));
        if (esp_lcd_panel_draw_bitmap(g_panel, 0, y, SG_DISPLAY_WIDTH, y + rows,
                                      g_band) != ESP_OK) {
            return false;
        }
        // Wait for the DMA to let go of the bounce buffer before refilling it.
        xSemaphoreTake(g_trans_done, pdMS_TO_TICKS(200));
    }
    return true;
}

bool display_init() {
    spi_bus_config_t bus = {};
    bus.sclk_io_num = SG_DISPLAY_QSPI_SCLK;
    bus.data0_io_num = SG_DISPLAY_QSPI_D0;
    bus.data1_io_num = SG_DISPLAY_QSPI_D1;
    bus.data2_io_num = SG_DISPLAY_QSPI_D2;
    bus.data3_io_num = SG_DISPLAY_QSPI_D3;
    bus.max_transfer_sz = SG_DISPLAY_WIDTH * kBandRows * static_cast<int>(sizeof(uint16_t));
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
    panel_config.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_BGR;
    panel_config.bits_per_pixel = 16;
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

    g_fb = static_cast<uint16_t*>(heap_caps_malloc(
        SG_DISPLAY_WIDTH * SG_DISPLAY_HEIGHT * sizeof(uint16_t), MALLOC_CAP_SPIRAM));
    g_band = static_cast<uint16_t*>(heap_caps_malloc(
        SG_DISPLAY_WIDTH * kBandRows * sizeof(uint16_t),
        MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL));
    g_trans_done = xSemaphoreCreateBinary();
    if (g_fb == nullptr || g_band == nullptr || g_trans_done == nullptr) {
        ESP_LOGE(TAG, "no memory for the framebuffer");
        return false;
    }
    display_clear(0x0000);

    ESP_LOGI(TAG, "%s up, %dx%d, %d KB framebuffer in PSRAM", SG_DISPLAY_CHIP,
             SG_DISPLAY_WIDTH, SG_DISPLAY_HEIGHT,
             SG_DISPLAY_WIDTH * SG_DISPLAY_HEIGHT * 2 / 1024);
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
