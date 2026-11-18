#!/usr/bin/env bash
# Builds and signs "dist/Disk Map.app". Does not install: `./install.sh` does.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Disk Map.app"
swift build -c release --product disk-map
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/disk-map" "$APP/Contents/MacOS/Disk Map"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
"$APP/Contents/MacOS/Disk Map" --selftest
# Signed with Fleet's certificate when it is there: a Full Disk Access grant is pinned to the signature, and an
# ad-hoc one changes with every build.
IDENTITY="Fleet Self-Signed"
[[ "$(security find-identity -v -p codesigning || true)" == *"$IDENTITY"* ]] || IDENTITY="-"
codesign --force --sign "$IDENTITY" "$APP"
echo "==> $APP"
