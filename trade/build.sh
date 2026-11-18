#!/usr/bin/env bash
# Builds and signs dist/Trade.app. Does not install: `./install.sh` does.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Trade.app"
swift build -c release --product trade
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/trade" "$APP/Contents/MacOS/Trade"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Not on CI: the self-test parses plan.py's output only, but the runner has no ~/self/trading either way.
[[ -n "${CI:-}" ]] || "$APP/Contents/MacOS/Trade" --selftest
codesign --force --sign - "$APP"
echo "==> $APP"
