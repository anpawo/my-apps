#!/usr/bin/env bash
# Builds and signs dist/Desks.app. `./build.sh --release` signs ad-hoc whatever the keychain holds.
# Signed with alt-tab's certificate when present: an ad-hoc signature loses the Accessibility grant
# at every rebuild, and a new certificate costs password dialogs (see alt-tab/make-signing-identity.sh).
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Desks.app"
IDENTITY="Alt-tab Self-Signed"
swift run -c release check
swift build -c release --product desks
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/desks" "$APP/Contents/MacOS/Desks"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if [[ "${1:-}" != "--release" && "$(security find-identity -v -p codesigning)" == *"$IDENTITY"* ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "==> $APP"
