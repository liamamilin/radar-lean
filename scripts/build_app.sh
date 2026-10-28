#!/bin/bash
# Builds Radar.app into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Radar"
APP=dist/Radar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Radar"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Radar</string>
<key>CFBundleDisplayName</key><string>Radar</string>
<key>CFBundleIdentifier</key><string>app.radar.Radar</string>
<key>CFBundleExecutable</key><string>Radar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PL
for b in "$(dirname "$BIN")"/*.bundle; do case "$b" in *Tests*) ;; *) cp -R "$b" "$APP/Contents/Resources/";; esac; done
# A stable identity keeps the Keychain "Always Allow" valid across rebuilds; ad-hoc (-) changes it every build.
codesign --force --deep --sign "${RADAR_SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
