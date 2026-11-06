#!/bin/bash
# Run by launchd (mac.vcx-update, plist beside this file) on every push from this checkout (it rewrites
# .git/refs/remotes/origin) and every 10 minutes of awake time. Installs VCX from main once vcx/ changed there. It builds
# in a worktree of its own: the shared checkout holds other sessions' unpushed edits, which must not ship.
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
repo="$HOME/self/my-apps"
state="$HOME/.local/share/vcx-update"
tree="$state/tree"
paths=(vcx ':(exclude,glob)vcx/**/*.md' ':(exclude)vcx/docs' ':(exclude)vcx/auto-update.sh' ':(exclude)vcx/mac.vcx-update.plist')
log() { echo "$(date '+%F %T') $*"; }

# Anonymous HTTPS: launchd has no SSH key loaded. A private ref, so the sessions' origin/main never moves under them.
# Exit 75 is "deferred" to Fleet, not a failure: the next run tries again.
git -C "$repo" fetch -q https://github.com/anpawo/my-apps.git +refs/heads/main:refs/vcx-update/main || { log "fetch failed"; exit 75; }
head=$(git -C "$repo" log -1 --format=%H refs/vcx-update/main -- "${paths[@]}") || exit 75
[ "$head" = "$(cat "$state/installed" 2>/dev/null)" ] && exit 0
# A commit that failed to install keeps the card red until a newer one replaces it.
[ "$head" = "$(cat "$state/failed" 2>/dev/null)" ] && exit 1

mkdir -p "$state"
if [ -e "$tree/.git" ]; then git -C "$tree" checkout -q --detach "$head"
else git -C "$repo" worktree add -q --detach "$tree" "$head"
fi || { log "cannot check out ${head:0:7}"; exit 1; }
log "installing $(git -C "$repo" log -1 --format='%h %s' "$head")"
if (cd "$tree/vcx" && python3 install-native.py); then
    echo "$head" > "$state/installed"; rm -f "$state/failed"; log "installed ${head:0:7}"
else
    echo "$head" > "$state/failed"; log "install failed for ${head:0:7}"; exit 1
fi
