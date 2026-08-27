#!/bin/sh
# Builds bench-cam.app. A bundle rather than a bare binary because TCC grants camera
# access to bundle identifiers, and an unbundled executable has none to grant — which is
# why every off-the-shelf CLI camera tool is refused before it can even prompt.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
APP="$HERE/bench-cam.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>bench-cam</string>
  <key>CFBundleIdentifier</key><string>net.mutantfactory.soundgraph.benchcam</string>
  <key>CFBundleName</key><string>bench-cam</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <!-- The string the permission dialog shows. Without this key macOS kills the process
       rather than asking, which looks exactly like a denial. -->
  <key>NSCameraUsageDescription</key>
  <string>bench-cam photographs hardware on the bench so the build can check its own work.</string>
  <!-- No dock icon, no menu bar: this is a shutter, not an application. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

swiftc -O -o "$APP/Contents/MacOS/bench-cam" "$HERE/main.swift" "$HERE/preview.swift" \
    -framework AVFoundation -framework AppKit -framework CoreImage -framework ImageIO

# Signing, and why this decides how often you re-authorise the camera.
#
# TCC stores a camera grant against the app's *designated requirement*. With no signing
# identity, codesign -s - produces a requirement that is nothing but the code hash:
#
#     designated => cdhash H"4617f99e..."
#
# The bundle identifier does not appear in it. So every rebuild changes the bytes,
# changes the hash, and TCC correctly concludes it has never seen this app. macOS then
# wants to prompt, an LSUIElement bundle launched through LaunchServices cannot present
# that prompt, and the process hangs for a minute and dies with no output. That is not a
# flaky permission; it is exactly one re-authorisation per rebuild.
#
# A real signing identity fixes it, because the requirement then anchors to the
# certificate instead of the bytes and survives recompilation. Any code-signing identity
# will do, including a self-signed one:
#
#     ./make-signing-cert.sh
#
# The advice you will find everywhere is Keychain Access -> Certificate Assistant. That
# advice is dead on macOS 26, which removed Keychain Access and Certificate Assistant
# both; the script does the same job with openssl.
#
# Set SG_SIGN_IDENTITY, or name it soundgraph-bench and this finds it.
IDENTITY=${SG_SIGN_IDENTITY:-}
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null \
        | grep -q "soundgraph-bench"; then
    IDENTITY="soundgraph-bench"
fi

if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" \
        --identifier net.mutantfactory.soundgraph.benchcam "$APP"
    echo "signed as $IDENTITY — the camera grant survives rebuilds"
else
    codesign --force --sign - --identifier net.mutantfactory.soundgraph.benchcam "$APP"
    echo "signed ad-hoc — expect to re-allow the camera after every rebuild."
    echo "  to stop that: make a self-signed Code Signing certificate named"
    echo "  soundgraph-bench in Keychain Access, then run this again."
fi

echo "built $APP"
echo "run: $APP/Contents/MacOS/bench-cam shot.jpg"
