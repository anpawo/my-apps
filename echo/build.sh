#!/usr/bin/env bash
# Builds and signs dist/echo.app. Does not install: `./install.sh` does.
# Ad-hoc signed: echo asks macOS for no permission, so no certificate has a grant to keep.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/echo.app"
swift build -c release --product echo
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/echo" "$APP/Contents/MacOS/echo"
cp Resources/Info.plist "$APP/Contents/"
"$APP/Contents/MacOS/echo" --selftest
codesign --force --sign - "$APP"
echo "==> $APP"
