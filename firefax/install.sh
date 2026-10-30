#!/usr/bin/env bash
# Builds, then copies to ~/.local/bin/firefax. The first time firefax drives Firefox it needs
# Accessibility trust: grant it in System Settings > Privacy & Security > Accessibility when asked.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
mkdir -p "$HOME/.local/bin"
cp dist/firefax "$HOME/.local/bin/firefax"
echo "installed: ~/.local/bin/firefax"
