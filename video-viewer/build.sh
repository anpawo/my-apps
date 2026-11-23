#!/usr/bin/env bash
# Builds and ad-hoc signs dist/Video Viewer.app. Does not install: `./install.sh` does.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Video Viewer.app"
swift run -c release check
swift build -c release --product viewer
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/viewer" "$APP/Contents/MacOS/VideoViewer"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "==> $APP"
