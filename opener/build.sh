#!/usr/bin/env bash
# Builds and signs dist/opener.app. Does not install: `./install.sh` does.
# Ad-hoc signed: opener asks macOS for no permission, so no certificate has a grant to keep.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/opener.app"
swift build -c release --product opener
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/opener" "$APP/Contents/MacOS/opener"
cp Resources/Info.plist "$APP/Contents/"
"$APP/Contents/MacOS/opener" --selftest
codesign --force --sign - "$APP"
echo "==> $APP"
