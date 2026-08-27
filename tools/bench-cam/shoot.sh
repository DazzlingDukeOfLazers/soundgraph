#!/bin/sh
# Send a console command to the board, wait for the screen to settle, photograph it.
#
# The `open` is not decoration. TCC attributes a camera request to the *responsible
# process*, and a binary run straight from a shell is attributed to the terminal — so the
# grant given to this bundle does not apply and the frame never arrives. Going through
# LaunchServices makes the app responsible for itself, which is the whole trick.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PORT=${SG_PORT:-/dev/cu.usbmodem101}
CROP=${SG_CROP:-560,250,700,800}
# pyserial lives in the IDF virtualenv rather than in the system python.
CMD=$1
OUT=$2

# An empty command is just a photograph. Requiring the board to be attached in order
# to look at the bench is backwards, and it failed exactly when the board was in
# pieces on the desk being identified.
if [ -n "$CMD" ]; then
"${SG_PYTHON:-$HOME/.espressif/python_env/idf5.5_py3.9_env/bin/python}" - "$PORT" "$CMD" <<'PY'
import sys, time, serial
port, cmd = sys.argv[1], sys.argv[2]
s = serial.Serial(port, 115200, timeout=0.3)
time.sleep(0.4)
s.write((cmd + "\n").encode())
time.sleep(1.5)
s.close()
PY
fi

rm -f "$OUT"
# SG_CROP=none takes the whole frame, which is what you want after the camera moves:
# a stale crop of a moved camera photographs the desk.
if [ "$CROP" = none ]; then
    open -a "$HERE/bench-cam.app" --args "$OUT" --warmup 12
else
    open -a "$HERE/bench-cam.app" --args "$OUT" --warmup 12 --crop "$CROP"
fi
for _ in $(seq 40); do [ -s "$OUT" ] && break; sleep 0.25; done
[ -s "$OUT" ] || { echo "shoot: no image at $OUT" >&2; exit 1; }
echo "shot $OUT"
