#!/usr/bin/env bash
# Builds and copies to ~/apps, where mac-guard.sh looks for it, then registers it with LaunchServices: a banner
# takes its icon from there.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
DEST="$HOME/apps/mac-guard.app"
rm -rf "$DEST"; mkdir -p "$HOME/apps"; cp -R dist/mac-guard.app "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "==> $DEST"
