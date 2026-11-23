#!/usr/bin/env bash
# Builds and ad-hoc signs dist/Text Viewer.app. Does not install: `./install.sh` does.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Text Viewer.app"
swift run -c release check
swift build -c release --product text
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/text" "$APP/Contents/MacOS/TextViewer"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "==> $APP"
