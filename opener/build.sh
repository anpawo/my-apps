#!/usr/bin/env bash
# Builds and signs dist/Opener.app. Does not install: `./install.sh` does.
# Signed with Fleet's certificate when it is there: the Accessibility grant (Firefox's new window, main.swift) is
# pinned to the signature, and an ad-hoc one changes with every build.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Opener.app"
swift build -c release --product opener
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/opener" "$APP/Contents/MacOS/Opener"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
"$APP/Contents/MacOS/Opener" --selftest
IDENTITY="Fleet Self-Signed"
[[ "$(security find-identity -v -p codesigning || true)" == *"$IDENTITY"* ]] || IDENTITY="-"
codesign --force --sign "$IDENTITY" "$APP"
echo "==> $APP"
