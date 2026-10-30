#!/usr/bin/env bash
# Builds, selftests and signs dist/firefax (a CLI, not an app). Does not install: `./install.sh` does.
# Ad-hoc signed like the other apps here; firefax asks macOS for no entitlement of its own.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product firefax
mkdir -p dist
cp "$(swift build -c release --show-bin-path)/firefax" dist/firefax
dist/firefax --selftest
codesign --force --sign - dist/firefax
echo "==> dist/firefax"
