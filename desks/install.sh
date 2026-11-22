#!/usr/bin/env bash
# Builds, copies to ~/apps (else ~/Applications) and runs the hotkeys under a LaunchAgent, as alt-tab does.
set -euo pipefail
cd "$(dirname "$0")"
APPS="$HOME/apps"; [ -d "$APPS" ] || APPS="$HOME/Applications"
LABEL="app.desks"
DEST="$APPS/Desks.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -rf "$DEST"; mkdir -p "$APPS"; cp -R dist/Desks.app "$DEST"
mkdir -p "$HOME/.local/bin"; ln -sf "$DEST/Contents/MacOS/Desks" "$HOME/.local/bin/desks"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/Desks</string>
		<string>--agent</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/desks.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$UID" "$PLIST"
echo "==> Running: ⌃⌥1…9 go to a desktop, ⌃⌥⇧1…9 carry the window there, ⌃⌥← ⌃⌥→ step."
echo "    It needs Accessibility: System Settings → Privacy & Security → Accessibility → Desks."
