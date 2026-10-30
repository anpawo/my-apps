#!/usr/bin/env bash
# Builds and signs dist/Watcher.app. Does not install: `./install.sh` does.
# Ad-hoc signed: watcher asks macOS for no permission, so no certificate has a grant to keep.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Watcher.app"
swift build -c release --product watcher
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/watcher" "$APP/Contents/MacOS/Watcher"
cp Resources/Info.plist "$APP/Contents/"
cp -R Resources/logos "$APP/Contents/Resources/"
# Not on CI: the self-test drives the checker skill in ~/.claude and the window server's blur, which a
# runner has neither of. Every local build still runs it.
[[ -n "${CI:-}" ]] || "$APP/Contents/MacOS/Watcher" --selftest
codesign --force --sign - "$APP"
echo "==> $APP"
