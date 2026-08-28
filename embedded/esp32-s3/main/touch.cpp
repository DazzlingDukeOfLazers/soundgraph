#include "touch.h"

#include "board_config.h"

#if !SG_TOUCH_PRESENT

bool touch_init() { return false; }
bool touch_available() { return false; }
bool touch_read(int*, int*) { return false; }
bool touch_read_probe(int*, int*, int*, int*) { return false; }

#else

#include "codec_init.h"
#include "display.h"
#include "driver/gpio.h"
#if SG_TOUCH_CHIP_KIND == 1
#include "esp_lcd_touch_ft5x06.h"
#elif SG_TOUCH_CHIP_KIND == 2
#include "esp_lcd_axs15231b.h"
#endif
#include "esp_log.h"

namespace {
const char* const TAG = "sg-touch";
esp_lcd_touch_handle_t g_touch = nullptr;
i2c_master_bus_handle_t g_own_bus = nullptr;

// The bus the touch controller is on, which is not always the codec's.
//
// Every board before the 3.49 hung everything off one I2C bus, so touch could borrow the
// one the codec had already brought up. This board keeps audio on 47/48 and touch on
// 17/18, and the two never meet. Asking whether the pins match is better than a flag: a
// board that shares gets the existing bus for free, and one that does not gets its own
// without anybody having to remember to say so.
i2c_master_bus_handle_t touch_bus() {
    if (SG_TOUCH_I2C_SDA == SG_CODEC_I2C_SDA && SG_TOUCH_I2C_SCL == SG_CODEC_I2C_SCL) {
        return codec_i2c_bus();
    }
    if (g_own_bus != nullptr) return g_own_bus;

    i2c_master_bus_config_t bus = {};
    bus.i2c_port = I2C_NUM_1;
    bus.sda_io_num = static_cast<gpio_num_t>(SG_TOUCH_I2C_SDA);
    bus.scl_io_num = static_cast<gpio_num_t>(SG_TOUCH_I2C_SCL);
    bus.clk_source = I2C_CLK_SRC_DEFAULT;
    bus.glitch_ignore_cnt = 7;
    bus.flags.enable_internal_pullup = true;
    if (i2c_new_master_bus(&bus, &g_own_bus) != ESP_OK) {
        ESP_LOGE(TAG, "could not open the touch I2C bus on sda=%d scl=%d",
                 SG_TOUCH_I2C_SDA, SG_TOUCH_I2C_SCL);
        g_own_bus = nullptr;
        return nullptr;
    }
    ESP_LOGI(TAG, "touch has its own I2C bus on sda=%d scl=%d",
             SG_TOUCH_I2C_SDA, SG_TOUCH_I2C_SCL);
    return g_own_bus;
}

// Read the controller only when it says it has something.
//
// esp_lcd_touch_read_data does an unconditional I2C transaction, and the FT3168 NAKs
// when no finger is present — so polling at 30 ms filled the console with I2C errors
// that were not errors, three lines of driver noise per line of real output, and put
// pointless traffic on the bus the codec shares.
//
// The catch is that FT-series parts differ in what the interrupt line means: some hold
// it asserted for the duration of a touch, others pulse it once per report. Gating on
// the level is right for the first and would drop most of a drag for the second, and
// this board's datasheet is not to hand. So the gate carries a probe — when the line is
// idle, one read still goes through every so often, and if that read finds a finger the
// line has proved itself a pulse and the gate turns itself off for good. Worst case is
// half a second of coarse tracking once, rather than a touchscreen that quietly stops
// working.
bool g_int_gated = true;
bool g_int_proven = false;   // the line has delivered a touch, so it holds; stop probing
int g_probe_countdown = 0;
constexpr int kProbeEvery = 16;   // at a 30 ms poll, about twice a second
}  // namespace

bool touch_init() {
    i2c_master_bus_handle_t bus = touch_bus();
    if (bus == nullptr) {
        ESP_LOGE(TAG, "no I2C bus for the touch controller");
        return false;
    }

    esp_lcd_panel_io_handle_t io = nullptr;
    // Field by field rather than ESP_LCD_TOUCH_IO_I2C_FT5x06_CONFIG(): that macro is
    // written for C, whose designated initializers may appear in any order, and C++
    // requires declaration order. The address comes from the manifest, not the macro,
    // because it is a fact about the board.
    esp_lcd_panel_io_i2c_config_t io_config = {};
    io_config.dev_addr = SG_TOUCH_I2C_ADDRESS;
    io_config.scl_speed_hz = 400000;
    io_config.control_phase_bytes = 1;
    io_config.dc_bit_offset = 0;
    io_config.lcd_cmd_bits = 8;
    io_config.flags.disable_control_phase = 1;
    if (esp_lcd_new_panel_io_i2c(bus, &io_config, &io) != ESP_OK) {
        ESP_LOGE(TAG, "could not reach %s at 0x%02x", SG_TOUCH_CHIP, SG_TOUCH_I2C_ADDRESS);
        return false;
    }

    esp_lcd_touch_config_t config = {};
    // The controller reports in panel coordinates, so its limits are the panel's, not
    // the rotated logical ones. Rotation is applied in touch_read.
#if SG_TOUCH_CHIP_KIND == 2
    // The frame this part reports in, which is the panel as used rather than as
    // addressed: 640 across and 172 down on this board.
    config.x_max = SG_DISPLAY_HEIGHT;
    config.y_max = SG_DISPLAY_WIDTH;
#else
    config.x_max = SG_DISPLAY_WIDTH;
    config.y_max = SG_DISPLAY_HEIGHT;
#endif
    config.flags.mirror_x = 0;
    config.flags.mirror_y = 0;
    config.rst_gpio_num = static_cast<gpio_num_t>(SG_TOUCH_RESET);
    config.int_gpio_num = static_cast<gpio_num_t>(SG_TOUCH_INTERRUPT);
    config.levels.reset = 0;
    config.levels.interrupt = 0;

#if SG_TOUCH_CHIP_KIND == 2
    if (esp_lcd_touch_new_i2c_axs15231b(io, &config, &g_touch) != ESP_OK) {
#else
    if (esp_lcd_touch_new_i2c_ft5x06(io, &config, &g_touch) != ESP_OK) {
#endif
        ESP_LOGE(TAG, "%s would not initialise", SG_TOUCH_CHIP);
        g_touch = nullptr;
        return false;
    }
    ESP_LOGI(TAG, "%s up at 0x%02x", SG_TOUCH_CHIP, SG_TOUCH_I2C_ADDRESS);
    return true;
}

bool touch_available() { return g_touch != nullptr; }


namespace {
// The controller's report into the display's logical frame.
//
// One rotation, from the board profile, and not the display's. The two were the same
// function for a while because on the watch they happen to agree — its FT3168 reports in
// panel coordinates and its panel is mounted a half turn over, so undoing the display's
// rotation was right by coincidence. On the 3.49 they do not agree at all: the AXS15231B
// is the panel's own controller and already reports in the orientation the panel is used
// in, so undoing the display's 90 sent a touch at x=390 to x=-219. Its own report is
// simply mounted a half turn over, which is a fact about the glass and now lives with
// the other facts about the glass.
//
// 90 and 270 are written out for completeness and have never run on hardware.
void to_logical(int px, int py, int* out_x, int* out_y) {
    const int w = display_width(), h = display_height();
    switch (SG_TOUCH_ROTATION) {
        case 90:  *out_x = h - 1 - py; *out_y = px;            break;
        case 180: *out_x = w - 1 - px; *out_y = h - 1 - py;    break;
        case 270: *out_x = py;         *out_y = w - 1 - px;    break;
        default:  *out_x = px;         *out_y = py;            break;
    }
}

bool read_once(int* px, int* py) {
    if (g_touch == nullptr) return false;

    bool probing = false;
    if (g_int_gated && SG_TOUCH_INTERRUPT >= 0) {
        const bool asserted =
            gpio_get_level(static_cast<gpio_num_t>(SG_TOUCH_INTERRUPT)) == 0;
        if (asserted) {
            g_probe_countdown = kProbeEvery;
        } else if (g_int_proven) {
            return false;
        } else if (g_probe_countdown > 0) {
            --g_probe_countdown;
            return false;
        } else {
            g_probe_countdown = kProbeEvery;
            probing = true;
        }
    }

    esp_lcd_touch_read_data(g_touch);
    uint16_t xs[1] = {0}, ys[1] = {0};
    uint8_t count = 0;
    if (!esp_lcd_touch_get_coordinates(g_touch, xs, ys, nullptr, &count, 1) || count == 0) {
        return false;
    }
    if (probing) {
        g_int_gated = false;
        ESP_LOGW(TAG, "%s pulses its interrupt; polling the bus instead", SG_TOUCH_CHIP);
    } else {
        g_int_proven = true;
    }
    *px = xs[0];
    *py = ys[0];
    return true;
}
}  // namespace

bool touch_read(int* out_x, int* out_y) {
    int px = 0, py = 0;
    if (!read_once(&px, &py)) return false;
    to_logical(px, py, out_x, out_y);
    return true;
}

bool touch_read_probe(int* raw_x, int* raw_y, int* out_x, int* out_y) {
    int px = 0, py = 0;
    if (!read_once(&px, &py)) return false;
    *raw_x = px;
    *raw_y = py;
    to_logical(px, py, out_x, out_y);
    return true;
}

#endif  // SG_TOUCH_PRESENT
