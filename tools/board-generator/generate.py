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
            f"#define SG_CODEC_I2C_SDA {i2c.get('sda', -1)}",
            f"#define SG_CODEC_I2C_SCL {i2c.get('scl', -1)}",
            f"#define SG_CODEC_I2C_ADDRESS {i2c.get('address', -1)}",
        ]

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"board-generator: {board['id']} -> {output_path}")


if __name__ == "__main__":
    main()
