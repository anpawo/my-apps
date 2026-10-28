#!/usr/bin/env bash
# Builds, copies to ~/apps (else ~/Applications), and registers a LaunchAgent: it starts at login and comes back if anything
# kills it. Not `open -a`: an app opened from a Claude Code session inherits its CLAUDE_PID, and Fleet reaps it as
# a leftover once that session ends.
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
cd "$(dirname "$0")"
./build.sh
LABEL="app.autocorrect"
DEST="$APPS/autocorrect.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "autocorrect.app/Contents/MacOS/autocorrect" 2>/dev/null || true
rm -rf "$DEST"; mkdir -p "$APPS"; cp -R "dist/autocorrect.app" "$DEST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/autocorrect</string>
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
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Give it Accessibility (System Settings → Privacy & Security → Accessibility) and it starts fixing."
