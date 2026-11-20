#!/usr/bin/env bash
# Builds and signs "dist/Keymap.app". Does not install: `./install.sh` does.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Keymap.app"
swift build -c release --product keymap
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/keymap" "$APP/Contents/MacOS/Keymap"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
"$APP/Contents/MacOS/Keymap" --selftest
codesign --force --sign - "$APP"
echo "==> $APP"
