#!/usr/bin/env bash
# Builds and copies Disk Map to ~/apps (else ~/Applications). A plain app: no LaunchAgent, it runs when opened.
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
cd "$(dirname "$0")"
./build.sh
rm -rf "$APPS/Disk Map.app"; mkdir -p "$APPS"; cp -R "dist/Disk Map.app" "$APPS/"
echo "==> $APPS/Disk Map.app"
