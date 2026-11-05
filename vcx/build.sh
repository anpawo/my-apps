#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release -j 2
app="dist/Vibe Code X.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/VCX "$app/Contents/MacOS/VCX"
.build/release/VCX --icon .build/icon.png
mkdir -p .build/VCX.iconset
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" .build/icon.png --out ".build/VCX.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" .build/icon.png --out ".build/VCX.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/VCX.iconset -o "$app/Contents/Resources/VCX.icns"
cp tests/native_peer.py "$app/Contents/Resources/native_peer.py"
cp tests/runtime_peer.py tests/runtime_probe.py tests/swap_peer.py "$app/Contents/Resources/"
cp background.py "$app/Contents/Resources/background.py"
cp Resources/Info.plist "$app/Contents/Info.plist"
# An ad-hoc signature changes with every build, and Screen Recording and Accessibility grants are pinned to it.
if [[ "$(security find-identity -v -p codesigning)" == *"Shot Self-Signed"* ]]; then
    perl -e 'alarm 60; exec @ARGV' codesign --force --sign "Shot Self-Signed" "$app"
else
    codesign --force --sign - "$app"
fi
