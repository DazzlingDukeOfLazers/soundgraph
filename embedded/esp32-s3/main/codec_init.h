// Codec bring-up for boards whose DAC needs configuring before it makes sound.
//
// On an i2s-dac board (PCM5102 and friends) this is a no-op: samples on the wire are
// enough. On a codec board it initialises the chip over I2C and raises the speaker
// amplifier's enable line — which on smart-speaker boards often lives behind an I/O
// expander rather than a chip GPIO.
#pragma once

#include "driver/i2s_std.h"

// Returns false if the codec could not be brought up; I2S keeps running either way, so
// the console still works and the failure is loggable.
bool codec_init(i2s_chan_handle_t tx_handle, int sample_rate);
