#!/usr/bin/env bash
# Builds, copies to ~/apps (else ~/Applications), and registers a LaunchAgent: it starts at login and comes back if anything
# kills it. Not `open -a`: an app opened from a Claude Code session inherits its CLAUDE_PID, and Fleet reaps it as
# a leftover once that session ends.
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
cd "$(dirname "$0")"
./build.sh
LABEL="app.watcher"
DEST="$APPS/Watcher.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -if "watcher.app/Contents/MacOS/watcher" 2>/dev/null || true
rm -rf "$DEST"; mkdir -p "$APPS"; cp -R "dist/Watcher.app" "$DEST"
# Login Items draws an agent with the icon of the file it runs, not of the app around it (only a Team ID links
# the two), so the binary carries the icon itself, as in Fleet's install.sh.
osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a) { $.NSWorkspace.sharedWorkspace.setIconForFileOptions($.NSImage.alloc.initWithContentsOfFile(a[0]), a[1], 0) }' \
	"$DEST/Contents/Resources/AppIcon.icns" "$DEST/Contents/MacOS/Watcher" >/dev/null
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/Watcher</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/watcher.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$UID" "$PLIST"
echo "⌘⌥K opens it."
