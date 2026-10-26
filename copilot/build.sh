#!/usr/bin/env bash
# Builds and signs dist/copilot.app. Does not install: `./install.sh` does.
# Signed "Shot Self-Signed" when the keychain has it (screenshot/make-signing-identity.sh), else ad-hoc: an ad-hoc
# signature loses the Screen Recording grant at every rebuild.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/copilot.app"
swift build -c release --product copilot
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/copilot" "$APP/Contents/MacOS/copilot"
cp Resources/Info.plist "$APP/Contents/"
"$APP/Contents/MacOS/copilot" --selftest
# Not a pipe into grep: under pipefail, grep -q closing early fails the test and the build falls back to ad-hoc.
if [[ "$(security find-identity -v -p codesigning)" == *"Shot Self-Signed"* ]]; then
  codesign --force --sign "Shot Self-Signed" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "==> $APP"
