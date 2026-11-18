#!/usr/bin/env bash
# Builds, copies to ~/Applications and relaunches it if it was running.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
DEST="$HOME/Applications/Trade.app"
running=$(pgrep -x Trade >/dev/null && echo 1 || true)
[[ -n "$running" ]] && { osascript -e 'quit app "Trade"'; while pgrep -x Trade >/dev/null; do sleep 0.2; done; }
rm -rf "$DEST"; mkdir -p "$HOME/Applications"; cp -R dist/Trade.app "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
[[ -n "$running" ]] && open "$DEST"
echo "==> $DEST"
