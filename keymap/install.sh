#!/usr/bin/env bash
# Builds and copies Keymap to ~/apps (else ~/Applications). A plain app: no LaunchAgent, it runs when opened.
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
cd "$(dirname "$0")"
./build.sh
rm -rf "$APPS/Keymap.app"; mkdir -p "$APPS"; cp -R "dist/Keymap.app" "$APPS/"
echo "==> $APPS/Keymap.app"
