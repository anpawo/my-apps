#!/usr/bin/env bash
# Builds, copies to ~/apps (else ~/Applications) and registers the app with Launch Services, so
# Finder offers it in Open With. No LaunchAgent: it is a document app, opened by its files.
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
cd "$(dirname "$0")"
./build.sh
DEST="$APPS/Viewer.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
running=false
if pgrep -xq Viewer; then
  running=true
  osascript -e 'tell application id "com.mr.viewer" to quit' || true
  while pgrep -xq Viewer; do sleep 0.2; done
fi
rm -rf "$DEST"; mkdir -p "$APPS"; cp -R "dist/Viewer.app" "$DEST"
"$LSREGISTER" -f "$DEST"
if $running; then open "$DEST"; fi
echo "==> $DEST"
