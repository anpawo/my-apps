#!/usr/bin/env bash
# Builds and ad-hoc signs dist/Viewer Media.app. Does not install: `./install.sh` does.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Viewer Media.app"
swift run -c release check
swift build -c release --product viewer
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/viewer" "$APP/Contents/MacOS/ViewerMedia"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "==> $APP"
