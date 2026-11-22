#!/usr/bin/env bash
# Builds, copies to ~/apps (else ~/Applications) and puts the desks command on the PATH.
set -euo pipefail
cd "$(dirname "$0")"
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
DEST="$APPS/Desks.app"

./build.sh
rm -rf "$DEST"; mkdir -p "$APPS"; cp -R dist/Desks.app "$DEST"
mkdir -p "$HOME/.local/bin"; ln -sf "$DEST/Contents/MacOS/Desks" "$HOME/.local/bin/desks"

echo "==> $DEST, and desks on the PATH"
