#!/bin/bash
# Run by launchd (mac.one-text-update, plist beside this file) on every push from this checkout and every 10 minutes of
# awake time. Installs One Text from main once one-text/ changed there, built in a worktree of its own: the
# shared checkout holds other sessions' unpushed edits. The app shows the build under its list while this runs.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
repo="$HOME/self/my-apps"
state="$HOME/.local/share/one-text-update"
tree="$state/tree"
app="$HOME/Applications/One Text.app"
paths=(one-text ':(exclude,glob)one-text/**/*.md' ':(exclude)one-text/docs' ':(exclude)one-text/tests' ':(exclude)one-text/auto-update.sh' ':(exclude)one-text/mac.one-text-update.plist')
log() { echo "$(date '+%F %T') $*"; }

# Anonymous HTTPS: launchd has no SSH key loaded. A private ref, so the sessions' origin/main never moves under them.
# Exit 75 is "deferred" to Fleet, not a failure: the next run tries again.
git -C "$repo" fetch -q https://github.com/anpawo/my-apps.git +refs/heads/main:refs/one-text-update/main || { log "fetch failed"; exit 75; }
head=$(git -C "$repo" log -1 --format=%H refs/one-text-update/main -- "${paths[@]}") || exit 75
[ "$head" = "$(cat "$state/installed" 2>/dev/null)" ] && exit 0
# A commit that failed to install keeps the card red until a newer one replaces it.
[ "$head" = "$(cat "$state/failed" 2>/dev/null)" ] && exit 1

mkdir -p "$state"
if [ -e "$tree/.git" ]; then git -C "$tree" checkout -q --detach "$head"
else git -C "$repo" worktree add -q --detach "$tree" "$head"
fi || { log "cannot check out ${head:0:7}"; exit 1; }
log "installing $(git -C "$repo" log -1 --format='%h %s' "$head")"
started=$(date +%s)
printf '%s\t%s\n' "$started" "$(git -C "$repo" log -1 --format=%s "$head" | sed 's/^one-text: //')" > "$state/building"
trap 'rm -f "$state/building"' EXIT
bundle="$tree/one-text/src-tauri/target/release/bundle/macos/One Text.app"
if ! (cd "$tree/one-text/src-tauri" && build-stack npx --yes @tauri-apps/cli build --bundles app) || [ ! -d "$bundle" ]; then
    echo "$head" > "$state/failed"; log "install failed for ${head:0:7}"; exit 1
fi

# The restart drops what he is typing: it waits while One Text is the app in front (10 minutes at most).
for _ in $(seq 60); do
    lsappinfo info -only bundleid "$(lsappinfo front)" | grep -q com.mr.one-text || break
    sleep 10
done
running=$(pgrep -x one-text)
[ -n "$running" ] && { kill $running; for _ in $(seq 50); do pgrep -x one-text >/dev/null || break; sleep 0.2; done; }
rm -rf "$app" && ditto "$bundle" "$app" || { echo "$head" > "$state/failed"; log "copy failed for ${head:0:7}"; exit 1; }
[ -n "$running" ] && open -g "$app"
echo "$head" > "$state/installed"; rm -f "$state/failed"; log "installed ${head:0:7}"
echo $(( $(date +%s) - started )) > "$state/last-duration"
