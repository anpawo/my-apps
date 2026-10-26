#!/usr/bin/env bash
# Builds, copies to ~/Applications, and registers a LaunchAgent: it starts at login and comes back if anything
# kills it. Not `open -a`: an app opened from a Claude Code session inherits its CLAUDE_PID, and Fleet reaps it as
# a leftover once that session ends.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
LABEL="app.copilot"
DEST="$HOME/Applications/copilot.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "copilot.app/Contents/MacOS/copilot" 2>/dev/null || true
rm -rf "$DEST"; mkdir -p "$HOME/Applications"; cp -R "dist/copilot.app" "$DEST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/copilot</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/copilot.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$UID" "$PLIST"
echo "⌥Space opens it."
