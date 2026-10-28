#!/usr/bin/env bash
# Builds, copies to ~/apps (else ~/Applications), and registers a LaunchAgent: it starts at login and comes
# back if anything kills it. Not `open -a`: an app opened from a Claude Code session inherits
# its CLAUDE_PID, and Fleet reaps it as a leftover once that session ends — which is how it kept
# "closing itself" (SIGTERM sent by Fleet, 27-09).
set -euo pipefail
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
cd "$(dirname "$0")"
./build.sh
LABEL="app.screenshot"
DEST="$APPS/screenshot.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# The agent was `com.mr.screenshot` until 27-09, when app agents took the `app.` prefix. The
# bundle id keeps the old name: the Screen Recording grant is filed under it.
launchctl bootout "gui/$UID/com.mr.screenshot" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.mr.screenshot.plist"
pkill -f "screenshot.app/Contents/MacOS/screenshot" 2>/dev/null || true
# The app was `mr. screenshot.app` until 02-10: left in place, a second copy takes ⌘⇧5 too.
rm -rf "$APPS/mr. screenshot.app"
rm -rf "$DEST"; mkdir -p "$APPS"; cp -R "dist/screenshot.app" "$DEST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/screenshot</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/screenshot.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$UID" "$PLIST"
echo "⌘⇧5 opens the bar — turn the system's ⌘⇧5 off first: Settings → Keyboard → Shortcuts → Screenshots."
