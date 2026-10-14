#!/bin/bash
# Build VisualSynth.app in ./build
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/VisualSynth.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/VisualSynth "$APP/Contents/MacOS/"
cp -R Sources/VisualSynth/Shaders "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Visual Synth</string>
  <key>CFBundleIdentifier</key><string>local.visualsynth</string>
  <key>CFBundleExecutable</key><string>VisualSynth</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Visual Synth listens to what your Mac is playing to sync the visuals to the beat.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP"
if [ "${1:-}" = "--install" ]; then
    DEST=/Applications
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/VisualSynth.app"
    cp -R "$APP" "$DEST/"
    echo "installed $DEST/VisualSynth.app"
fi
