#!/usr/bin/env python3
"""Is this frame worth looking at?

A black JPEG and a black scene are different problems, and neither is visible by opening
the file — an underexposed room and a camera producing nothing both render as a rectangle
of nothing. Sensor noise tells them apart: a real dark frame has a floor of ones and twos,
while a camera that is asleep or shuttered emits exact zeros. Reported before anyone
spends a turn squinting at an image that has no information in it.

Pure stdlib on purpose. This runs on a bench machine with an ESP-IDF virtualenv and no
imaging libraries, and adding a dependency to read the mean of a picture is a bad trade.

    ./levels.py shot.jpg
"""
import struct
import subprocess
import sys
import tempfile
import zlib


def sample(path, width=64):
    """Mean, min and max luminance from a downscaled copy, via sips and a PNG decode."""
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
        out = tmp.name
    subprocess.run(["sips", "-s", "format", "png", "-Z", str(width), path, "--out", out],
                   capture_output=True, check=True)
    data = open(out, "rb").read()

    pos, idat, w, h, colour = 8, b"", 0, 0, 0
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, _depth, colour = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length

    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[colour]
    stride = w * channels
    previous = bytearray(stride)
    values = []
    i = 0
    for _ in range(h):
        filt = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = previous[x]
            c = previous[x - channels] if x >= channels else 0
            if filt == 1:
                line[x] = (line[x] + a) & 255
            elif filt == 2:
                line[x] = (line[x] + b) & 255
            elif filt == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        previous = line
        values.extend(line[x] for x in range(0, stride, channels))
    return values


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: levels.py <image> [...]")
    for path in sys.argv[1:]:
        values = sample(path)
        lo, hi = min(values), max(values)
        mean = sum(values) / len(values)
        zeros = sum(1 for v in values if v == 0)
        # The peak decides, not the average. A good photograph of a lit screen in a dark
        # room is mostly black and averages about 2 — indistinguishable from a shuttered
        # lens by mean alone, which called a perfectly good frame DARK. What separates
        # them is whether anything anywhere is lit.
        if hi <= 6:
            verdict = ("BLIND — sensor noise only, nothing in frame is lit. A motorised "
                       "camera may still be shuttered; give it wall-clock time to wake")
        elif hi < 40:
            verdict = "DARK — a scene, but barely; add light"
        elif sum(1 for v in values if v >= 250) > len(values) * 0.02:
            verdict = "CLIPPED — highlights are gone"
        else:
            verdict = "usable"
        print(f"{path}: mean {mean:5.1f}  min {lo:3d}  max {hi:3d}  zeros {zeros}  -> {verdict}")


if __name__ == "__main__":
    main()
