#!/bin/sh
# Populates embedded/axoloti/sdk/ with the pieces of the official Axoloti
# 1.0.12-2 release needed to build and link test patches:
#
#   axoloti.elf   the exact firmware build stock boards run — patches link
#                 against its symbols (--just-symbols)
#   axoloti.bin   the raw flash image (for CRC verification / reflashing)
#   ramlink.ld    the patch linker script
#
# Everything is GPL-3.0 upstream material, fetched pinned by sha256 rather
# than vendored into this repository.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
SDK="$HERE/sdk"
DMG_URL="https://github.com/axoloti/axoloti/releases/download/1.0.12-2/axoloti-mac-1.0.12-2.dmg"
DMG_SHA256="7b0c1231d695dd0ff1d07f679713a1d5691a6fac3543b0aa0415356c5cc82a9c"
# CRC32 (firmware algorithm) of axoloti.bin up to _flash_end — what a stock
# board reports as its firmware ID over USB.
EXPECT_FWID="0xe95bac96"

if [ -f "$SDK/axoloti.elf" ] && [ -f "$SDK/ramlink.ld" ]; then
  echo "sdk already populated at $SDK"
  exit 0
fi

mkdir -p "$SDK"
DMG="$SDK/axoloti-mac-1.0.12-2.dmg"

if [ ! -f "$DMG" ]; then
  echo "downloading $DMG_URL"
  curl -fSL -o "$DMG" "$DMG_URL"
fi

echo "$DMG_SHA256  $DMG" | shasum -a 256 -c - || {
  echo "sha256 mismatch — refusing to use $DMG" >&2
  rm -f "$DMG"
  exit 1
}

MNT="$SDK/mnt.$$"
mkdir -p "$MNT"
# The dmg carries a license agreement prompt (GPL); accept non-interactively.
yes | hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null

JAVA="$MNT/Axoloti.app/Contents/Java"
cp "$JAVA/firmware/build/axoloti.elf" "$SDK/"
cp "$JAVA/firmware/build/axoloti.bin" "$SDK/"
cp "$JAVA/firmware/ramlink.ld" "$SDK/"

hdiutil detach "$MNT" >/dev/null
rmdir "$MNT" 2>/dev/null || true

# Verify the firmware ID this elf/bin pair corresponds to.
if command -v arm-none-eabi-nm >/dev/null 2>&1; then
  FLASH_END=$(arm-none-eabi-nm "$SDK/axoloti.elf" | awk '$3=="_flash_end"{print "0x"$1}')
  FWID=$(python3 - "$SDK/axoloti.bin" "$FLASH_END" <<'EOF'
import sys, zlib
data = open(sys.argv[1], "rb").read()
size = int(sys.argv[2], 16) & 0x07FFFFF
print(f"0x{zlib.crc32(data[:size].ljust(size, b'\xff')) & 0xFFFFFFFF:08x}")
EOF
)
  echo "sdk firmware id: $FWID (expected $EXPECT_FWID)"
  [ "$FWID" = "$EXPECT_FWID" ] || { echo "FWID MISMATCH" >&2; exit 1; }
else
  echo "arm-none-eabi-nm not found; skipping fwid verification"
fi

rm -f "$DMG"
echo "sdk ready at $SDK"
