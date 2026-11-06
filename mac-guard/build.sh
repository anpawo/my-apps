#!/usr/bin/env bash
# Builds and signs dist/mac-guard.app. Does not install: `./install.sh` does.
# Ad-hoc signed: notifications are no TCC permission, so no certificate has a grant to keep.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/mac-guard.app"
swift build -c release --product mac-guard
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/mac-guard" "$APP/Contents/MacOS/mac-guard"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "==> $APP"
