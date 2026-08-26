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

swiftc -O -o "$APP/Contents/MacOS/bench-cam" "$HERE/main.swift" \
    -framework AVFoundation -framework CoreImage -framework ImageIO

# Ad-hoc signature. TCC keys its record on the signature; an unsigned bundle gets a new
# identity whenever the binary changes, so the grant would have to be given again after
# every rebuild.
codesign --force --sign - --identifier net.mutantfactory.soundgraph.benchcam "$APP"

echo "built $APP"
echo "run: $APP/Contents/MacOS/bench-cam shot.jpg"
