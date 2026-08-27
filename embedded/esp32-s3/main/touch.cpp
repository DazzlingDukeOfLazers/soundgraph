#include "touch.h"

#include "board_config.h"

#if !SG_TOUCH_PRESENT

bool touch_init() { return false; }
bool touch_available() { return false; }
bool touch_read(int*, int*) { return false; }

#else

#include "codec_init.h"
#include "display.h"
#include "driver/gpio.h"
#include "esp_lcd_touch_ft5x06.h"
#include "esp_log.h"

namespace {
const char* const TAG = "sg-touch";
esp_lcd_touch_handle_t g_touch = nullptr;

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
    i2c_master_bus_handle_t bus = codec_i2c_bus();
    if (bus == nullptr) {
        ESP_LOGE(TAG, "no I2C bus; the codec creates it and must come up first");
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
    config.x_max = SG_DISPLAY_WIDTH;
    config.y_max = SG_DISPLAY_HEIGHT;
    config.rst_gpio_num = static_cast<gpio_num_t>(SG_TOUCH_RESET);
    config.int_gpio_num = static_cast<gpio_num_t>(SG_TOUCH_INTERRUPT);
    config.levels.reset = 0;
    config.levels.interrupt = 0;

    if (esp_lcd_touch_new_i2c_ft5x06(io, &config, &g_touch) != ESP_OK) {
        ESP_LOGE(TAG, "%s would not initialise", SG_TOUCH_CHIP);
        g_touch = nullptr;
        return false;
    }
    ESP_LOGI(TAG, "%s up on the shared I2C bus", SG_TOUCH_CHIP);
    return true;
}

bool touch_available() { return g_touch != nullptr; }

bool touch_read(int* out_x, int* out_y) {
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

    // A finger the interrupt line never mentioned. It pulses rather than holds, so the
    // gate is wrong for this part and stays off from here on.
    if (probing) {
        g_int_gated = false;
        ESP_LOGW(TAG, "%s pulses its interrupt; polling the bus instead", SG_TOUCH_CHIP);
    } else {
        // The gate delivered a touch, so the line holds while a finger is down and the
        // probe has nothing left to discover. One drag pays for the rest of the session.
        g_int_proven = true;
    }

    // Panel coordinates into logical ones: the same rotation the framebuffer applies,
    // inverted. Getting this wrong is the classic touchscreen bug where the pointer
    // moves the wrong way, so it is derived from the display's own rotation rather
    // than written out as a second set of constants.
    const int px = xs[0], py = ys[0];
    switch (display_rotation()) {
        case 90:  *out_x = py;                         *out_y = SG_DISPLAY_WIDTH - 1 - px; break;
        case 180: *out_x = SG_DISPLAY_WIDTH - 1 - px;  *out_y = SG_DISPLAY_HEIGHT - 1 - py; break;
        case 270: *out_x = SG_DISPLAY_HEIGHT - 1 - py; *out_y = px;                        break;
        default:  *out_x = px;                         *out_y = py;                        break;
    }
    return true;
}

#endif  // SG_TOUCH_PRESENT
