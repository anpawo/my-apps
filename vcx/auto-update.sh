#!/bin/bash
# Run by launchd (mac.vcx-update, plist beside this file) on every push from this checkout (it rewrites
# .git/refs/remotes/origin) and every 10 minutes of awake time. Installs VCX from main once vcx/ changed there. It builds
# in a worktree of its own: the shared checkout holds other sessions' unpushed edits, which must not ship.
set -uo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
repo="$HOME/self/my-apps"
state="$HOME/.local/share/vcx-update"
tree="$state/tree"
# The Rust rebuild is a second app: its pushes must not rebuild and swap the Swift one.
paths=(vcx ':(exclude,glob)vcx/**/*.md' ':(exclude)vcx/docs' ':(exclude)vcx/auto-update.sh' ':(exclude)vcx/mac.vcx-update.plist' ':(exclude)vcx/rust' ':(exclude)vcx/build-rust.sh')
log() { echo "$(date '+%F %T') $*"; }

# Anonymous HTTPS: launchd has no SSH key loaded. A private ref, so the sessions' origin/main never moves under them.
# Exit 75 is "deferred" to Fleet, not a failure: the next run tries again.
git -C "$repo" fetch -q https://github.com/anpawo/my-apps.git +refs/heads/main:refs/vcx-update/main || { log "fetch failed"; exit 75; }
head=$(git -C "$repo" log -1 --format=%H refs/vcx-update/main -- "${paths[@]}") || exit 75
[ "$head" = "$(cat "$state/installed" 2>/dev/null)" ] && exit 0
# A failed commit is tried again on the next runs: its checks time animations and freeze reports, and a CPU-heavy
# job elsewhere on the Mac pushes them past their bounds (21-11: a 300 % python job failed 7 installs in a row).
# Past the last attempt it keeps the card red until a newer commit replaces it.
max_attempts=3
read -r failed attempts 2>/dev/null < "$state/failed"
[ "$head" = "${failed:-}" ] && [ "${attempts:-$max_attempts}" -ge "$max_attempts" ] && exit 1
# Nor does a run start beside such a job: under 4 burners on the 4 performance cores, the spin check never fired.
busy_cpu_percent=150
top_cpu=$(ps -Ao pcpu= | sort -rn | head -1); top_cpu=${top_cpu%.*}
[ "${top_cpu:-0}" -ge "$busy_cpu_percent" ] && { log "deferred: a process uses ${top_cpu}% CPU"; exit 75; }
# Nor beside several single-threaded jobs, none past the bound above (26-11: rustc and two python at ~95 % each failed
# 3 installs in 6 minutes); the Mac sits at 70 to 150 % in total when they are gone.
busy_total_percent=250
total_cpu=$(ps -Ao pcpu= | awk '{ s += $1 } END { printf "%d", s }')
[ "${total_cpu:-0}" -ge "$busy_total_percent" ] && { log "deferred: processes use ${total_cpu}% CPU in total"; exit 75; }

mkdir -p "$state"
if [ -e "$tree/.git" ]; then git -C "$tree" checkout -q --detach "$head"
else git -C "$repo" worktree add -q --detach "$tree" "$head"
fi || { log "cannot check out ${head:0:7}"; exit 1; }
log "installing $(git -C "$repo" log -1 --format='%h %s' "$head")"
# The open windows show this in their status bar while it builds, paced by the last install's duration.
started=$(date +%s)
printf '%s\t%s\n' "$started" "$(git -C "$repo" log -1 --format=%s "$head" | sed 's/^vcx: //')" > "$state/building"
trap 'rm -f "$state/building"' EXIT
if (cd "$tree/vcx" && python3 install-native.py); then
    echo "$head" > "$state/installed"; rm -f "$state/failed"; log "installed ${head:0:7}"
    echo $(( $(date +%s) - started )) > "$state/last-duration"
else
    [ "$head" = "${failed:-}" ] && attempts=$(( ${attempts:-0} + 1 )) || attempts=1
    echo "$head $attempts" > "$state/failed"; log "install failed for ${head:0:7} (attempt $attempts of $max_attempts)"; exit 1
fi
