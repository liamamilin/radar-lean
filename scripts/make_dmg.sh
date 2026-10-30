#!/bin/bash
# Packs dist/Radar.app into dist/Radar-<version>.dmg (drag Radar onto Applications). Run scripts/build_app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=dist/Radar.app
[ -d "$APP" ] || { echo "先运行 scripts/build_app.sh"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Radar-$VER.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Radar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
