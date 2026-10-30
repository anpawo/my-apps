#!/usr/bin/env bash
# Builds and signs dist/Opener.app. Does not install: `./install.sh` does.
# Ad-hoc signed: opener asks macOS for no permission, so no certificate has a grant to keep.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Opener.app"
swift build -c release --product opener
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/opener" "$APP/Contents/MacOS/Opener"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
"$APP/Contents/MacOS/Opener" --selftest
codesign --force --sign - "$APP"
echo "==> $APP"
