#!/usr/bin/env bash
# Builds, copies to ~/Applications, and registers a LaunchAgent: it starts at login and comes
# back if anything kills it. Not `open -a`: an app opened from a Claude Code session is reaped by
# Fleet once that session ends (see screenshot's install.sh).
set -euo pipefail

cd "$(dirname "$0")"

LABEL="app.alt-tab"
DEST="$HOME/Applications/Alt-tab.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# The one build path; --arch native because this machine is the only one that will run it.
python3 build.py --arch native

echo "==> Installing to $DEST"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -f "Alt-tab.app/Contents/MacOS/alt-tab" 2>/dev/null || true
rm -rf "$DEST"; mkdir -p "$HOME/Applications"; cp -R dist/Alt-tab.app "$DEST"

echo "==> Starting"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/alt-tab</string>
		<string>--agent</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>/tmp/alt-tab.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$UID" "$PLIST"

echo
echo "Installed, and invisible: no Dock icon and nothing in the menu bar."
echo
echo "Hold ⌘ and press Tab to switch windows; Escape cancels. With ⌘ still held,"
echo "click a tile to switch to it, or the red cross on its picture to close it."
echo "It holds ⌘Tab in place of the system switcher, and hands it back when it quits;"
echo "open the app to change the chord, and for everything else it can be told to do."
echo
echo "The first time you commit a switch, macOS will ask for Accessibility."
echo "Until it is granted the panel lists applications without window names,"
echo "and cannot raise anything: System Settings → Privacy & Security → Accessibility."
echo
echo "  See what it sees:  $DEST/Contents/MacOS/alt-tab --render"
echo "  Logs:              ~/Library/Logs/alt-tab.log"
echo "  Uninstall:         ./uninstall.sh"
