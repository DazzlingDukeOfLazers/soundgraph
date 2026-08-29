#!/bin/sh
# Render a cable lab sheet, or open it.
#
# Exists because the bare Godot invocation takes a project path relative to the working
# directory, and the one thing you reliably do not know when you want to look at a cable
# is which directory you are in. This one finds the project from its own location.
#
#   editor-godot/cable-lab.sh plug              # render to ./out/cable-plug.png beside the project
#   editor-godot/cable-lab.sh small out.png     # render somewhere specific
#   editor-godot/cable-lab.sh weight --open     # leave the window up instead
#
# Sheets: slack, weight, plug, palette, small.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
[ -x "$GODOT" ] || { echo "no Godot at $GODOT; set GODOT=/path/to/godot" >&2; exit 1; }

SHEET=${1:-slack}
# Beside the project rather than in /tmp: these are things you look at repeatedly and
# compare against each other, and a directory you can open in a file browser beats a path
# you have to remember. Gitignored — they are output, not work.
mkdir -p "$HERE/out"
TARGET=${2:-$HERE/out/cable-$SHEET.png}

if [ "$TARGET" = "--open" ]; then
    exec "$GODOT" --path "$HERE" --script res://cable_lab.gd -- --sheet "$SHEET"
fi

"$GODOT" --path "$HERE" --script res://cable_lab.gd -- \
    --sheet "$SHEET" --out "$TARGET" 2>&1 | grep -vE "^$|Godot Engine|OpenGL API"
