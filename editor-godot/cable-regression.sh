#!/usr/bin/env bash
# The cable renderer's regression set: one difficult patch, photographed the ways that
# have actually caught something.
#
# Not a pass/fail suite. There is no assertion here that a picture is right — these are
# the frames to look at when the renderer changes, because each of them is where a real
# problem showed up: the dense crossing found the muddy shadow, the stacked jacks found
# the plug that covered its neighbour, and the low zoom found the LOD measured in the
# wrong coordinate space.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
godot="${SOUNDGRAPH_GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
patch="res://examples/cable-stress.json"
out="$here/out"
mkdir -p "$out"

shoot() { # name, then rack_shot arguments
	local name="$1"; shift
	"$godot" --path "$here" --script res://rack_shot.gd -- \
		--patch "$patch" --out "out/$name.png" "$@" 2>&1 | grep -E "^wrote|rror" || true
}

# Working scale, and the same rack in the other renderer. The A/B is the point: the
# catenary is quieter and cheaper, and which one wins is a question about density.
shoot cable-style-physical --style physical --colour cable --size 1560 1180
shoot cable-style-catenary --style catenary --colour cable --size 1560 1180

# Colour by signal type, which is what the product does today: two types, so two colours.
shoot cable-colour-by-type --style physical --colour type --size 1560 1180

# Down the zoom range. The floors and the plug tiers both live here.
# The case stays 1560x1180 rack pixels throughout; only how many of them reach the frame
# changes, which is what zooming actually is.
shoot cable-zoom-70 --style physical --colour cable --zoom 0.7 --size 1092 826
shoot cable-zoom-50 --style physical --colour cable --zoom 0.5 --size 780 590
shoot cable-low-zoom --style physical --colour cable --zoom 0.35 --size 546 413
# The same frame in the other renderer, because the density question is really a question
# about zoom: the screen-space floor keeps a physical cable 2.75 px wide however far out
# you go, and a catenary is free to disappear.
shoot cable-low-zoom-catenary --style catenary --colour cable --zoom 0.35 --size 546 413

# Twice the pixels for the same rack: what a retina panel actually draws.
shoot cable-high-dpi --style physical --colour cable --zoom 2.0 --size 3120 2360

# The three regions worth looking at close up, cut from the working-scale frame so they
# cannot disagree with it.
cd "$out"
cp cable-style-physical.png cable-dense-crossing.png
sips -c 250 420 --cropOffset 830 20  cable-style-physical.png --out cable-short-local.png >/dev/null
sips -c 700 900 --cropOffset 380 560 cable-style-physical.png --out cable-long-diagonal.png >/dev/null
sips -c 200 330 --cropOffset 480 260 cable-style-physical.png --out cable-jack-stack.png >/dev/null
for f in cable-short-local cable-long-diagonal cable-jack-stack; do
	w=$(sips -g pixelWidth "$f.png" | tail -1 | tr -dc 0-9)
	h=$(sips -g pixelHeight "$f.png" | tail -1 | tr -dc 0-9)
	sips -z $((h * 2)) $((w * 2)) "$f.png" >/dev/null
done
echo "regression set in $out"
