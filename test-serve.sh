#!/usr/bin/env bash
# Drives `serve` and the installed hook against a throwaway HOME, with stand-in claudes: a server
# outlives its session's restart, stops within 5 s when the session is closed (Fleet's
# SessionEnd hook), and within 90 s when it dies with no hook at all (serve's own watcher).
# Run after ./install.sh. Takes about 70 s.
set -uo pipefail

HOOK="${1:-$HOME/.claude/fleet/session-state.sh}"
SERVE="${2:-$HOME/.local/bin/serve}"
[ -x "$HOOK" ] || { echo "no hook at $HOOK — run ./install.sh"; exit 1; }
[ -x "$SERVE" ] || { echo "no serve at $SERVE — run ./install.sh"; exit 1; }

FAKE=$(mktemp -d)
cleanup() {
    for r in "$FAKE"/.claude/fleet/serve/*.rec; do
        [ -f "$r" ] || continue
        p=${r##*/}; kill -KILL -- "-${p%.rec}" 2>/dev/null
    done
    for p in ${standins:-}; do kill -KILL -- "-$p" 2>/dev/null; done
    rm -rf "$FAKE"
}
trap cleanup EXIT
mkdir -p "$FAKE/.claude/sessions" "$FAKE/.claude/fleet/state" "$FAKE/.local/bin" "$FAKE/www"
cp "$SERVE" "$FAKE/.local/bin/serve"
# A copy of bash, so that `ps` names it claude as it does the real one.
cp /bin/bash "$FAKE/claude"
unset FLEET_SHELL CLAUDE_PID
fail=0 standins=
ok() { printf '  ok    %s\n' "$1"; }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=1; }
answers() { curl -s -m 1 -o /dev/null "http://127.0.0.1:$1/"; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# A stand-in claude for session $1, in a process group of its own as a terminal's would be. It
# keeps the file Claude Code keeps for a session, runs `serve` the way the Bash tool would when
# $2 names a port, and runs the hook as its own child, as Claude Code does, for each payload
# dropped in fire-<end|start>.<its pid>. Sets $pid.
session() {
    HOME="$FAKE" CLAUDE_CODE_SESSION_ID="$1" PORT_="${2:-}" HOOK="$HOOK" \
        /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- "$FAKE/claude" -c '
        printf "{\"pid\":%s,\"sessionId\":\"%s\",\"procStart\":\"%s\"}" $$ "$CLAUDE_CODE_SESSION_ID" \
            "$(TZ=UTC ps -o lstart= -p $$)" > "$HOME/.claude/sessions/$$.json"
        export CLAUDE_PID=$$
        [ -z "$PORT_" ] || ( cd "$HOME/www" && "$HOME/.local/bin/serve" web --port "$PORT_" -- \
            python3 -m http.server "$PORT_" --bind 127.0.0.1 > "$HOME/serve.$$" 2>&1 )
        while :; do
            for a in end start; do
                f="$HOME/fire-$a.$$"
                [ -f "$f" ] && { sh "$HOOK" "$a" < "$f" > "$HOME/said-$a.$$" 2>&1; rm -f "$f"; }
            done
            sleep 0.1
        done' >/dev/null 2>&1 </dev/null &
    pid=$!
    disown "$pid"
    standins="$standins $pid"
}
# Hands session pid $1 the hook payload for event $2 ($3: end or start), extra fields $4; waits
# for the hook to have run.
fire() {
    printf '{"session_id":"%s","hook_event_name":"%s","transcript_path":"/tmp/t.jsonl","cwd":"%s"%s}' \
        "$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$FAKE/.claude/sessions/$1.json")" "$2" "$FAKE/www" "$4" \
        > "$FAKE/fire-$3.$1.tmp" && mv "$FAKE/fire-$3.$1.tmp" "$FAKE/fire-$3.$1"
    n=0; while [ -f "$FAKE/fire-$3.$1" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
}
up_within() {  # $1 port: answers within 30 s
    n=0; until answers "$1" || [ $n -ge 60 ]; do sleep 0.5; n=$((n + 1)); done; answers "$1"
}
gone_within() {  # $1 port, $2 seconds: sets $took to when it stopped answering
    t0=$(date +%s); took=
    while [ $(($(date +%s) - t0)) -le "$2" ]; do
        answers "$1" || { took=$(($(date +%s) - t0)); return 0; }
        sleep 0.25
    done
    return 1
}
group_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

echo "hook: $HOOK"
echo "serve: $SERVE"
A=aaaaaaaa-0000-0000-0000-000000000001 B=bbbbbbbb-0000-0000-0000-000000000002 C=cccccccc-0000-0000-0000-000000000003
pa=$(free_port); pb=$(free_port); pc=$(free_port)
session "$A" "$pa"; a1=$pid
session "$B" "$pb"; b1=$pid
session "$C" "$pc"; c1=$pid
for p in "$pa" "$pb" "$pc"; do up_within "$p" || { ko "server on $p started" "$(cat "$FAKE"/serve.* 2>/dev/null)"; exit 1; }; done
ok "three sessions, a server each"

# Closed: the SessionEnd hook stops its servers, a /clear does not.
fire "$c1" SessionEnd end ',"reason":"clear"'
sleep 1
answers "$pc" && ok "a /clear keeps the session's server" || ko "a /clear keeps the session's server" "stopped"
fire "$c1" SessionEnd end ',"reason":"prompt_input_exit"'
if gone_within "$pc" 5; then ok "session closed: its server stopped through the hook in ${took} s"
else ko "session closed: its server stopped through the hook" "still answers after 5 s"; fi
kill -KILL -- "-$c1" 2>/dev/null

# Restarted the way Fleet's relaunch does it: the note for the fish function is written before
# the kill, Claude Code runs SessionEnd as it exits, the whole process group dies, and the fish
# function resumes the conversation in a new claude a second later.
echo "$a1 4242 /bin/claude" > "$FAKE/.claude/fleet/state/$A.shell"
mkdir -p "$FAKE/.claude/fleet/restart"; echo "$A" > "$FAKE/.claude/fleet/restart/4242"
w=$(find "$FAKE/.claude/fleet/serve" -name '*.rec' | while read -r r; do grep -q "^sid=$A" "$r" && basename "$r" .rec; done)
[ "$(group_of "$w")" != "$(group_of "$a1")" ] && ok "the server runs outside its session's process group" ||
    ko "the server runs outside its session's process group" "same group $(group_of "$a1")"
fire "$a1" SessionEnd end ',"reason":"other"'
kill -KILL -- "-$a1"; rm -f "$FAKE/.claude/sessions/$a1.json"
sleep 1
session "$A"; a2=$pid
sleep 0.5
fire "$a2" SessionStart start ',"source":"resume"'
case "$(cat "$FAKE/said-start.$a2" 2>/dev/null)" in
    *"web  http://localhost:$pa"*) ok "the resumed session is told its server is still up" ;;
    *) ko "the resumed session is told its server is still up" "said: $(cat "$FAKE/said-start.$a2" 2>/dev/null)" ;;
esac
answers "$pa" && ok "server still answers right after the restart" || ko "server still answers right after the restart" "stopped"
relaunched=$(date +%s)

# Gone with no hook (a crash, a killed terminal): the watcher stops the server on its own.
kill -KILL -- "-$b1"
if gone_within "$pb" 90; then ok "session killed with no hook: its server stopped by the watcher in ${took} s"
else ko "session killed with no hook: its server stopped by the watcher" "still answers after 90 s"; fi

# Past the point where the watcher would have stopped it, had it not found the new claude.
while [ $(($(date +%s) - relaunched)) -lt 65 ]; do sleep 1; done
answers "$pa" && ok "the restarted session's server still answers 65 s after the restart" ||
    ko "the restarted session's server still answers after the watcher's window" "stopped: $(tail -n 2 "$FAKE"/.claude/fleet/serve/web-"$w".log)"
grep -q "^owner=$a2\$" "$FAKE/.claude/fleet/serve/$w.rec" 2>/dev/null && ok "the watcher follows the session to its new claude" ||
    ko "the watcher follows the session to its new claude" "$(grep '^owner=' "$FAKE/.claude/fleet/serve/$w.rec" 2>/dev/null)"

[ $fail = 0 ] && echo "all passed" || echo "FAILED"
exit $fail
