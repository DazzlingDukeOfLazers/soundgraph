#include "codec_init.h"

#include "board_config.h"

#if !SG_AUDIO_IS_CODEC

// A bare I2S DAC needs no introduction.
bool codec_init(i2s_chan_handle_t, int) { return true; }
bool codec_set_volume(float) { return false; }

#else

#include "driver/i2c_master.h"
#include "esp_codec_dev.h"
#include "esp_codec_dev_defaults.h"
#include "esp_log.h"

namespace {

const char* const TAG = "sg-codec";

i2c_master_bus_handle_t g_i2c_bus = nullptr;
esp_codec_dev_handle_t g_codec = nullptr;

// TCA9555 I/O expander: pins 0-7 are port 0, 8-15 are port 1. A bit set in the config
// register makes that pin an input, so the enable pin's bit must be cleared there and
// set in the output register. Only the enable pin's port is touched — the other port
// may be wired to things this firmware knows nothing about.
#if SG_AMP_KIND == 2
bool expander_raise_pin() {
    i2c_device_config_t device_config = {};
    device_config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
    device_config.device_address = SG_AMP_I2C_ADDRESS;
    device_config.scl_speed_hz = 100000;

    i2c_master_dev_handle_t device = nullptr;
    if (i2c_master_bus_add_device(g_i2c_bus, &device_config, &device) != ESP_OK) {
        ESP_LOGE(TAG, "no I/O expander at 0x%02x", SG_AMP_I2C_ADDRESS);
        return false;
    }

    const int port = SG_AMP_EXPANDER_PIN / 8;
    const uint8_t bit = static_cast<uint8_t>(1u << (SG_AMP_EXPANDER_PIN % 8));
    const uint8_t output_register = static_cast<uint8_t>(0x02 + port);
    const uint8_t config_register = static_cast<uint8_t>(0x06 + port);

    bool ok = true;
    uint8_t read_value = 0;

    // Read-modify-write both registers: the untouched bits on this port may be keys or
    // other peripherals with their own opinions.
    uint8_t request = output_register;
    ok = ok && i2c_master_transmit_receive(device, &request, 1, &read_value, 1, 200) == ESP_OK;
    const uint8_t output_bytes[2] = {output_register, static_cast<uint8_t>(read_value | bit)};
    ok = ok && i2c_master_transmit(device, output_bytes, 2, 200) == ESP_OK;

    request = config_register;
    ok = ok && i2c_master_transmit_receive(device, &request, 1, &read_value, 1, 200) == ESP_OK;
    const uint8_t config_bytes[2] = {config_register, static_cast<uint8_t>(read_value & ~bit)};
    ok = ok && i2c_master_transmit(device, config_bytes, 2, 200) == ESP_OK;

    i2c_master_bus_rm_device(device);
    if (!ok) {
        ESP_LOGE(TAG, "could not raise the amplifier enable via the expander");
    }
    return ok;
}
#endif  // SG_AMP_KIND == 2

}  // namespace

bool codec_init(i2s_chan_handle_t tx_handle, int sample_rate) {
    // ---- I2C bus --------------------------------------------------------------------
    i2c_master_bus_config_t bus_config = {};
    bus_config.i2c_port = -1;  // auto-select
    bus_config.sda_io_num = static_cast<gpio_num_t>(SG_CODEC_I2C_SDA);
    bus_config.scl_io_num = static_cast<gpio_num_t>(SG_CODEC_I2C_SCL);
    bus_config.clk_source = I2C_CLK_SRC_DEFAULT;
    bus_config.glitch_ignore_cnt = 7;
    bus_config.flags.enable_internal_pullup = true;

    if (i2c_new_master_bus(&bus_config, &g_i2c_bus) != ESP_OK) {
        ESP_LOGE(TAG, "could not create the I2C bus on sda=%d scl=%d",
                 SG_CODEC_I2C_SDA, SG_CODEC_I2C_SCL);
        return false;
    }

    // ---- ES8311 through esp_codec_dev ----------------------------------------------
    audio_codec_i2c_cfg_t i2c_config = {};
    i2c_config.port = 0;
    i2c_config.addr = SG_CODEC_I2C_ADDRESS << 1;  // esp_codec_dev wants the 8-bit form
    i2c_config.bus_handle = g_i2c_bus;
    const audio_codec_ctrl_if_t* control_interface = audio_codec_new_i2c_ctrl(&i2c_config);

    audio_codec_i2s_cfg_t i2s_config = {};
    i2s_config.port = 0;
    i2s_config.tx_handle = tx_handle;
    const audio_codec_data_if_t* data_interface = audio_codec_new_i2s_data(&i2s_config);

    const audio_codec_gpio_if_t* gpio_interface = audio_codec_new_gpio();

    if (control_interface == nullptr || data_interface == nullptr || gpio_interface == nullptr) {
        ESP_LOGE(TAG, "esp_codec_dev interface creation failed");
        return false;
    }

    es8311_codec_cfg_t codec_config = {};
    codec_config.ctrl_if = control_interface;
    codec_config.gpio_if = gpio_interface;
    codec_config.codec_mode = ESP_CODEC_DEV_WORK_MODE_DAC;
    codec_config.master_mode = false;   // the ESP drives the I2S clocks
    codec_config.use_mclk = SG_I2S_MCLK >= 0;
    codec_config.pa_pin = -1;           // the amp enable is not a chip GPIO on this board
    codec_config.hw_gain.pa_voltage = 5.0;
    codec_config.hw_gain.codec_dac_voltage = 3.3;
    codec_config.mclk_div = 256;

    const audio_codec_if_t* codec_interface = es8311_codec_new(&codec_config);
    if (codec_interface == nullptr) {
        ESP_LOGE(TAG, "the %s did not answer at 0x%02x", SG_CODEC_CHIP, SG_CODEC_I2C_ADDRESS);
        return false;
    }

    esp_codec_dev_cfg_t device_config = {};
    device_config.dev_type = ESP_CODEC_DEV_TYPE_OUT;
    device_config.codec_if = codec_interface;
    device_config.data_if = data_interface;
    g_codec = esp_codec_dev_new(&device_config);

    esp_codec_dev_sample_info_t sample_info = {};
    sample_info.bits_per_sample = 16;
    sample_info.channel = 2;
    sample_info.channel_mask = 0x03;
    sample_info.sample_rate = static_cast<uint32_t>(sample_rate);

    if (g_codec == nullptr || esp_codec_dev_open(g_codec, &sample_info) != ESP_CODEC_DEV_OK) {
        ESP_LOGE(TAG, "could not open the codec at %d Hz", sample_rate);
        return false;
    }
    // Conservative default: the safety limiter in the graph protects the signal, this
    // protects the room. The console's `vol` command adjusts it live.
    esp_codec_dev_set_out_vol(g_codec, 55.0);

    // ---- speaker amplifier ----------------------------------------------------------
#if SG_AMP_KIND == 2
    if (!expander_raise_pin()) {
        return false;
    }
#elif SG_AMP_KIND == 1
    gpio_config_t amp_config = {};
    amp_config.pin_bit_mask = 1ULL << SG_AMP_GPIO;
    amp_config.mode = GPIO_MODE_OUTPUT;
    gpio_config(&amp_config);
    gpio_set_level(static_cast<gpio_num_t>(SG_AMP_GPIO), 1);
#endif

    ESP_LOGI(TAG, "%s up at %d Hz, amp enabled", SG_CODEC_CHIP, sample_rate);
    return true;
}

bool codec_set_volume(float percent) {
    if (g_codec == nullptr) {
        return false;
    }
    if (percent < 0.0f) percent = 0.0f;
    if (percent > 100.0f) percent = 100.0f;
    return esp_codec_dev_set_out_vol(g_codec, percent) == ESP_CODEC_DEV_OK;
}

#endif  // SG_AUDIO_IS_CODEC
