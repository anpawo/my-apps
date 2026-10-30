#!/usr/bin/env bash
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
LABEL="app.alt-tab"
APP="$APPS/Alt-Tab.app"

# First, and with the binary still on disk: a chord bound to ⌘Tab means the system's own
# switcher is currently off, and that outlives the app. Deleting it before giving the chord
# back leaves a machine with no switcher and nothing left to fix it with.
[ -x "$APP/Contents/MacOS/Alt-Tab" ] && "$APP/Contents/MacOS/Alt-Tab" --restore-hotkeys || true

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -if "Alt-tab.app/Contents/MacOS/alt-tab" 2>/dev/null || true
rm -rf "$APP"
defaults delete com.mr.alttab 2>/dev/null || true
echo "Removed, and ⌘Tab handed back to macOS."
echo "If another switcher ever leaves yours dead: alt-tab --restore-hotkeys"
