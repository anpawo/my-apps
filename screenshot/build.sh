#!/usr/bin/env bash
# Builds and signs dist/Screenshot.app. Does not install: `./install.sh` does.
# Self-signed "Shot Self-Signed" if present (./make-signing-identity.sh), else ad-hoc — and an
# ad-hoc signature loses the Screen Recording grant at every rebuild.
# `./build.sh --release` is what a download is made of: ad-hoc whatever the keychain holds,
# since that certificate is trusted nowhere but here, and zipped.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Screenshot.app"
swift run -c release check
swift build -c release --product screenshot
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/screenshot" "$APP/Contents/MacOS/Screenshot"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Not a pipe into grep: under pipefail, grep -q closing early makes the whole test fail and
# the build silently falls back to ad-hoc — which is how the Screen Recording grant got lost.
if [[ "${1:-}" != "--release" && "$(security find-identity -v -p codesigning)" == *"Shot Self-Signed"* ]]; then
  codesign --force --sign "Shot Self-Signed" "$APP"
else
  codesign --force --sign - "$APP"
fi
if [[ "${1:-}" == "--release" ]]; then
  ZIP="dist/screenshot-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist).zip"
  # ditto, not zip: it keeps the signature intact.
  rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> $ZIP"
fi
echo "==> $APP"
