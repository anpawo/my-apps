#!/usr/bin/env bash
# Builds, copies to ~/apps (else ~/Applications) and registers the app with Launch Services so it
# can be chosen as the opener of text files. Changes no default app. No LaunchAgent: it is a
# document app, opened by its files.
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
cd "$(dirname "$0")"
./build.sh
DEST="$APPS/Viewer Text.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
running=false
if pgrep -xq ViewerText; then
  running=true
  osascript -e 'tell application id "com.mr.text" to quit' || true
  while pgrep -xq ViewerText; do sleep 0.2; done
fi
rm -rf "$DEST"; mkdir -p "$APPS"; cp -R "dist/Viewer Text.app" "$DEST"
"$LSREGISTER" -f "$DEST"
# Without CLAUDE_PID: an app started from a Claude Code session inherits it, and Fleet reaps it
# as a leftover once that session ends.
if $running; then env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID open "$DEST"; fi
echo "==> $DEST"
