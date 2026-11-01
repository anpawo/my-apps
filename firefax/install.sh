#!/usr/bin/env bash
# Builds, then copies to ~/.local/bin/firefax. The first time firefax drives Firefox it needs
# Accessibility trust: grant it in System Settings > Privacy & Security > Accessibility when asked.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
mkdir -p "$HOME/.local/bin"
# A copy over the old file keeps its inode and the kernel's cached signature: the new binary dies with SIGKILL.
cp dist/firefax "$HOME/.local/bin/firefax.new"
mv -f "$HOME/.local/bin/firefax.new" "$HOME/.local/bin/firefax"
echo "installed: ~/.local/bin/firefax"
