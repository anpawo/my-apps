#!/usr/bin/env bash
# Builds, copies to ~/apps (else ~/Applications), and registers a LaunchAgent: it starts at login and comes back if anything
# kills it. Not `open -a`: an app opened from a Claude Code session inherits its CLAUDE_PID, and Fleet reaps it as
# a leftover once that session ends.
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
cd "$(dirname "$0")"
./build.sh
LABEL="app.autocorrect"
DEST="$APPS/Autocorrect.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# No bootout, no delete-and-copy, and the agent starts through a copy of /usr/bin/env: Background Task Management
# keys the item on the code identity of the program it runs first, and the rebuilt binary there made macOS post an
# "App Background Activity" alert on every install, one that stays until clicked (as in Fleet's install.sh).
launchctl kill SIGTERM "gui/$UID/$LABEL" 2>/dev/null || true
pkill -if "autocorrect.app/Contents/MacOS/autocorrect" 2>/dev/null || true
mkdir -p "$DEST"; rsync -a --delete dist/Autocorrect.app/ "$DEST/"
LAUNCHER="$HOME/.local/bin/agents/Autocorrect"
mkdir -p "$(dirname "$LAUNCHER")"; cp /usr/bin/env "$LAUNCHER"
# Login Items draws an agent with the icon of the file it runs, not of the app around it (only a Team ID links
# the two), so the launcher carries the icon itself.
osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(a) { $.NSWorkspace.sharedWorkspace.setIconForFileOptions($.NSImage.alloc.initWithContentsOfFile(a[0]), a[1], 0) }' \
	"$DEST/Contents/Resources/AppIcon.icns" "$LAUNCHER" >/dev/null
cat > "$PLIST.new" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$LAUNCHER</string>
		<string>$DEST/Contents/MacOS/Autocorrect</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/autocorrect.log</string>
</dict>
</plist>
EOF
if cmp -s "$PLIST.new" "$PLIST"; then
	rm "$PLIST.new"
	launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || true
	launchctl kickstart -k "gui/$UID/$LABEL"
else
	mv "$PLIST.new" "$PLIST"
	launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
	# Right after a bootout, bootstrap can fail with error 5 until launchd has let the old job go.
	launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null || { sleep 2; launchctl bootstrap "gui/$UID" "$PLIST"; }
fi
echo "Give it Accessibility (System Settings → Privacy & Security → Accessibility) and it starts fixing."
