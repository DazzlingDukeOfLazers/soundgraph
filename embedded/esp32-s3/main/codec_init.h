// Codec bring-up for boards whose DAC needs configuring before it makes sound.
//
// On an i2s-dac board (PCM5102 and friends) this is a no-op: samples on the wire are
// enough. On a codec board it initialises the chip over I2C and raises the speaker
// amplifier's enable line — which on smart-speaker boards often lives behind an I/O
// expander rather than a chip GPIO.
#pragma once

#include "driver/i2c_master.h"

#include <cstdint>

#include "driver/i2s_std.h"

// Returns false if the codec could not be brought up; I2S keeps running either way, so
// the console still works and the failure is loggable.
bool codec_init(i2s_chan_handle_t tx_handle, int sample_rate);

// Output volume, 0-100. Returns false on boards with no volume hardware (a bare I2S DAC
// is as loud as its samples); use the patch's master level there instead.
bool codec_set_volume(float percent);

// ---- the other direction ------------------------------------------------------------
// The microphone side of a codec board. Separate from codec_init because it is a
// separate chip on the same wires: the Waveshare smart-speaker devkit puts an ES8311
// DAC and an ES7210 ADC on one I2C bus and one I2S clock domain, and either can be
// present without the other.
//
// Boards with no capture hardware compile this away — the whole path is behind
// SG_AUDIO_IN_PRESENT — and mic_available() answers false so a caller can say so rather
// than wait for samples that will never come.

// Brings the ADC up on an already-created I2S receive channel. Returns false if the
// chip did not answer; playback is unaffected either way.
bool mic_init(i2s_chan_handle_t rx_handle, int sample_rate);

bool mic_available();

// Reads interleaved 16-bit frames, one sample per channel per frame. Returns the number
// of frames read, or -1 if there is no microphone or the read failed. Blocking, up to
// timeout_ms.
int mic_read(int16_t* destination, int frames, int timeout_ms);

// Capture gain in dB. The ES7210's range is 0-37.5 dB in 3 dB steps; it rounds.
bool mic_set_gain(float decibels);

// The board's one I2C bus, created by codec_init. Everything else on those two pins —
// the touch controller, the RTC, the PMIC — shares it rather than creating a second
// master on the same wires, which would be a hardware fault rather than a software one.
i2c_master_bus_handle_t codec_i2c_bus();
