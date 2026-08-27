#!/usr/bin/env python3
"""Turns a board profile (board.json) into a C header for the generic firmware.

    python generate.py <board.json> <output.h>

The JSON is the canonical description of the board — see schema/board.schema.json.
This generator exists so that supporting a new board is "write a manifest", not
"edit firmware": the firmware includes the generated header and never hardcodes a pin.
"""
import json
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"board-generator: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: generate.py <board.json> <output.h>")

    board_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])

    try:
        board = json.loads(board_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"could not read {board_path}: {error}")

    for key in ("id", "name", "target", "audio_out"):
        if key not in board:
            fail(f"{board_path} is missing required field '{key}'")

    audio = board["audio_out"]
    i2s = audio.get("i2s", {})
    for key in ("bclk", "ws", "dout"):
        if key not in i2s:
            fail(f"{board_path} audio_out.i2s is missing pin '{key}'")

    psram = board.get("psram", {})

    lines = [
        "// Generated from %s by tools/board-generator/generate.py — do not edit." % board_path.name,
        "// The JSON manifest is the canonical board description; change that instead.",
        "#pragma once",
        "",
        f'#define SG_BOARD_ID "{board["id"]}"',
        f'#define SG_BOARD_NAME "{board["name"]}"',
        f'#define SG_BOARD_TARGET "{board["target"]}"',
        "",
        f"#define SG_AUDIO_SAMPLE_RATE {audio['sample_rate']}",
        f"#define SG_AUDIO_BITS {audio.get('bits', 16)}",
        f"#define SG_AUDIO_IS_CODEC {1 if audio.get('kind') == 'codec' else 0}",
        "",
        f"#define SG_I2S_BCLK {i2s['bclk']}",
        f"#define SG_I2S_WS {i2s['ws']}",
        f"#define SG_I2S_DOUT {i2s['dout']}",
        f"#define SG_I2S_MCLK {i2s.get('mclk', -1)}",
        "",
        f"#define SG_PSRAM_PRESENT {1 if psram.get('present') else 0}",
        f"#define SG_PSRAM_MEGABYTES {psram.get('megabytes', 0)}",
    ]

    if audio.get("kind") == "codec":
        i2c = audio.get("i2c", {})
        lines += [
            "",
            f'#define SG_CODEC_CHIP "{audio.get("chip", "unknown")}"',
            f"#define SG_CODEC_I2C_SDA {i2c.get('sda', -1)}",
            f"#define SG_CODEC_I2C_SCL {i2c.get('scl', -1)}",
            f"#define SG_CODEC_I2C_ADDRESS {i2c.get('address', -1)}",
        ]

        amp = audio.get("amp", {})
        if "gpio" in amp:
            lines += [
                "#define SG_AMP_KIND 1  // direct GPIO",
                f"#define SG_AMP_GPIO {amp['gpio']}",
            ]
        elif "expander" in amp:
            lines += [
                "#define SG_AMP_KIND 2  // behind an I2C I/O expander",
                f"#define SG_AMP_I2C_ADDRESS {amp.get('i2c_address', -1)}",
                f"#define SG_AMP_EXPANDER_PIN {amp.get('pin', -1)}",
            ]
        else:
            lines += ["#define SG_AMP_KIND 0  // always on"]

    # The microphone side, when the board has one. Absent on every board that does not,
    # and the firmware compiles the whole capture path out rather than carrying a driver
    # for hardware that is not there — SG_AUDIO_IN_PRESENT is what it tests.
    # The panel, when the board has one. A board with no display compiles the UI out
    # entirely — SG_DISPLAY_PRESENT is what the firmware tests — for the same reason the
    # capture path disappears on boards with no microphone.
    display = board.get("display")
    if display:
        qspi = display.get("qspi", {})
        touch = display.get("touch", {})
        lines += [
            "",
            "#define SG_DISPLAY_PRESENT 1",
            f'#define SG_DISPLAY_CHIP "{display["chip"]}"',
            f"#define SG_DISPLAY_WIDTH {display['width']}",
            f"#define SG_DISPLAY_HEIGHT {display['height']}",
            f"#define SG_DISPLAY_X_OFFSET {display.get('x_offset', 0)}",
            f"#define SG_DISPLAY_Y_OFFSET {display.get('y_offset', 0)}",
            f"#define SG_DISPLAY_QSPI_SCLK {qspi.get('sclk', -1)}",
            f"#define SG_DISPLAY_QSPI_CS {qspi.get('cs', -1)}",
            f"#define SG_DISPLAY_QSPI_D0 {qspi.get('d0', -1)}",
            f"#define SG_DISPLAY_QSPI_D1 {qspi.get('d1', -1)}",
            f"#define SG_DISPLAY_QSPI_D2 {qspi.get('d2', -1)}",
            f"#define SG_DISPLAY_QSPI_D3 {qspi.get('d3', -1)}",
            f"#define SG_DISPLAY_RESET {display.get('reset', -1)}",
            f"#define SG_DISPLAY_TE {display.get('te', -1)}",
            # A transmissive panel needs a backlight pin; an AMOLED sets brightness with
            # a command and has none. -1 says which kind of panel this is.
            f"#define SG_DISPLAY_BACKLIGHT {display.get('backlight', -1)}",
            f"#define SG_DISPLAY_ROTATION {display.get('rotation', 0)}",
        ]
        if touch:
            lines += [
                f"#define SG_TOUCH_PRESENT 1",
                f'#define SG_TOUCH_CHIP "{touch.get("chip", "unknown")}"',
                f"#define SG_TOUCH_I2C_ADDRESS {touch.get('i2c_address', -1)}",
                f"#define SG_TOUCH_I2C_SDA {touch.get('sda', -1)}",
                f"#define SG_TOUCH_I2C_SCL {touch.get('scl', -1)}",
                f"#define SG_TOUCH_INTERRUPT {touch.get('interrupt', -1)}",
                f"#define SG_TOUCH_RESET {touch.get('reset', -1)}",
            ]
        if "expander" in display:
            # Panel control lines that live on an I2C expander rather than a chip GPIO.
            # Worth a separate define rather than folding into SG_DISPLAY_RESET: an
            # expander line costs a transaction, cannot be driven from an ISR, and is not
            # available until I2C is up — so a panel reset that lives here constrains the
            # bring-up order in a way a GPIO never does.
            expander = display["expander"]
            lines += [
                "",
                "#define SG_DISPLAY_EXPANDER_PRESENT 1",
                f'#define SG_DISPLAY_EXPANDER_CHIP "{expander.get("chip", "")}"',
                f"#define SG_DISPLAY_EXPANDER_ADDRESS {expander.get('i2c_address', 32)}",
                f"#define SG_DISPLAY_EXPANDER_INT {expander.get('interrupt', -1)}",
                f"#define SG_DISPLAY_EXPANDER_RESET_PIN {expander.get('reset_pin', -1)}",
                f"#define SG_DISPLAY_EXPANDER_BL_PIN "
                f"{expander.get('backlight_enable_pin', -1)}",
            ]
        else:
            lines += ["#define SG_TOUCH_PRESENT 0"]
    else:
        lines += ["", "#define SG_DISPLAY_PRESENT 0", "#define SG_TOUCH_PRESENT 0"]

    audio_in = board.get("audio_in")
    if audio_in:
        in_i2s = audio_in.get("i2s", {})
        lines += [
            "",
            "#define SG_AUDIO_IN_PRESENT 1",
            f'#define SG_AUDIO_IN_CHIP "{audio_in.get("chip", "unknown")}"',
            f"#define SG_AUDIO_IN_I2C_ADDRESS {audio_in.get('i2c_address', -1)}",
            f"#define SG_I2S_DIN {in_i2s.get('din', -1)}",
            # How many of the ADC's four inputs are wired to microphones. The ES7210 is a
            # quad part used here for a pair, and asking for channels that are not there
            # returns silence rather than an error, which is a confusing way to find out.
            f"#define SG_AUDIO_IN_CHANNELS {audio_in.get('channels', 2)}",
        ]
    else:
        lines += ["", "#define SG_AUDIO_IN_PRESENT 0"]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"board-generator: {board['id']} -> {output_path}")


if __name__ == "__main__":
    main()
