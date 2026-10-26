#!/usr/bin/env bash
# Builds, tests and signs dist/autocorrect.app. Does not install: `./install.sh` does.
# Signed with a certificate when there is one: macOS ties the Accessibility grant to the signature, and an
# ad-hoc one changes with every build, so the grant would have to be given again after each.
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/autocorrect.app"
IDENTITY="Shot Self-Signed"
swift build -c release --product autocorrect
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/autocorrect" "$APP/Contents/MacOS/autocorrect"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/words.tsv "$APP/Contents/Resources/"
"$APP/Contents/MacOS/autocorrect" --selftest > /dev/null || "$APP/Contents/MacOS/autocorrect" --selftest
if [[ "$(security find-identity -v -p codesigning)" == *"$IDENTITY"* ]]; then
  # A keychain dialog would hold a script forever; give up after a minute.
  perl -e 'alarm 60; exec @ARGV' codesign --force --sign "$IDENTITY" "$APP"
else
  echo "==> No \"$IDENTITY\" certificate: signed ad-hoc, Accessibility is asked again after every build."
  codesign --force --sign - "$APP"
fi
echo "==> $APP"
