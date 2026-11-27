#!/bin/bash
# The switch from the Swift app to VCX Rust in one command, and back.
#
# --to rust, in order: refuses unless VCX Rust is installed and the vcx-swift-final release holds a zip of the Swift
# app's last build; points the vcx command at VCX Rust and pauses the Swift app's install job (launchers/switch.sh,
# which refuses while that job installs, before anything stops); with --rust-worker, makes the Rust worker the default
# for new sessions (a VCX Rust already running reads it at its next session); stops the Swift app's frontends with
# SIGKILL, as a crash would, so their windows stay listed for recovery and their workers keep every session (a normal
# quit ends them); starts VCX Rust and has it take those windows over on the same workers; waits until every window
# the stopped frontends held shows its session in VCX Rust, with the window file's newer draft carried; only then
# removes their Swift recovery entries, so no later Swift launch takes those sessions back; and moves the installed
# Swift app to the Trash, unless VCX Rust still starts new sessions' workers from it.
# A failure once the vcx command points at VCX Rust gives everything back: VCX Rust lets the windows go, the vcx
# command and the install job are put back, and the Swift app, started again, reopens them from its recovery list.
# --to swift puts the Swift app back from the Trash, or from the release, and the vcx command with it; the windows
# VCX Rust holds stay there.
#
# Every folder follows $HOME, and VCX_SWIFT_RECOVERY, VCX_RUST_STATE_HOME, VCX_RUST_CONFIG_HOME and switch.sh's own
# variables move them, for the rehearsal (crates/vcx-app/tests/cutover.rs), as VCX_CUTOVER_ATTACH_WAIT shortens its
# wait; `open`, `gh` and `launchctl` are found on PATH.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
home="$HOME"
rust_app="$home/Applications/VCX Rust.app"
swift_app="$home/Applications/Vibe Code X.app"
trash="$home/.Trash/Vibe Code X.app"
recovery="${VCX_SWIFT_RECOVERY:-$home/.local/state/vcx/runtime/recovery}"
rust_state="${VCX_RUST_STATE_HOME:-$home/.local/state/vcx-rust}"
rust_config="${VCX_RUST_CONFIG_HOME:-$home/Library/Application Support/VCX Rust}"
release=vcx-swift-final
repository=anpawo/my-apps
# VCX Rust opens its control socket within this many seconds of being started.
START_WAIT=60
TAKEN_WAIT=90
# Every window the stopped frontends held shows its session in VCX Rust within this many seconds, or all go back.
ATTACH_WAIT="${VCX_CUTOVER_ATTACH_WAIT:-90}"
# A frontend sent SIGKILL is gone within this many seconds.
KILL_WAIT=10
POLLS_PER_SECOND=5

fail() { echo "cutover: $*" >&2; exit 1; }
usage() { echo "usage: $0 --to rust [--rust-worker] | --to swift" >&2; exit 2; }

ask() {
    printf '%s\n' "$1" | nc -U -w "$TAKEN_WAIT" "$rust_state/control.sock"
}

# "<pid> <session id>" for each window in the Swift recovery folder whose owner still runs as the recorded process: the
# Swift binary, started at the recorded time (Swift `ownerStart`, microseconds), so a reused pid is never stopped.
swift_frontends() {
    [ -d "$recovery" ] || return 0
    python3 - "$recovery" <<'PY'
import ctypes, json, pathlib, sys, uuid

class Info(ctypes.Structure):
    _fields_ = [('flags', ctypes.c_uint32), ('status', ctypes.c_uint32), ('xstatus', ctypes.c_uint32), ('pid', ctypes.c_uint32),
                ('ppid', ctypes.c_uint32), ('uid', ctypes.c_uint32), ('gid', ctypes.c_uint32), ('ruid', ctypes.c_uint32),
                ('rgid', ctypes.c_uint32), ('svuid', ctypes.c_uint32), ('svgid', ctypes.c_uint32), ('rfu', ctypes.c_uint32),
                ('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32), ('nfiles', ctypes.c_uint32), ('pgid', ctypes.c_uint32),
                ('pjobc', ctypes.c_uint32), ('e_tdev', ctypes.c_uint32), ('e_tpgid', ctypes.c_uint32), ('nice', ctypes.c_int32),
                ('start_tvsec', ctypes.c_uint64), ('start_tvusec', ctypes.c_uint64)]

libc = ctypes.CDLL(None)
PROC_PIDTBSDINFO = 3

def started(pid):
    info = Info()
    size = ctypes.sizeof(info)
    if libc.proc_pidinfo(pid, PROC_PIDTBSDINFO, ctypes.c_uint64(0), ctypes.byref(info), size) != size:
        return None
    return info.comm.decode(errors='replace'), info.start_tvsec * 1_000_000 + info.start_tvusec

for entry in sorted(pathlib.Path(sys.argv[1]).glob('*.window.json')):
    try:
        value = json.loads(entry.read_text())
        session = str(uuid.UUID(value.get('sessionId'))).upper()
    except (OSError, ValueError, TypeError, AttributeError):
        continue
    pid, start = value.get('ownerPID'), value.get('ownerStart')
    if isinstance(pid, int) and pid > 1 and isinstance(start, int) and not value.get('closeRequested'):
        if started(pid) == ('VCX', start):
            print(pid, session)
PY
}

# The takeover's steps past the takeOver request, on VCX Rust's control socket (`taken`: its answer; `expected`: the
# Swift sessions of the stopped frontends). `wait`: until each of those is taken and its window shows its session with
# the draft carried; `release`: prints the request that gives every window taken back; `retire`: their Swift entries go.
steward() {
    python3 - "$rust_state/control.sock" "$@" <<'PY'
import json, socket, sys, time

control, step, taken, expected = sys.argv[1], sys.argv[2], json.loads(sys.argv[3] or '{}'), set(sys.argv[4].split())
windows = taken.get('taken', [])
POLL_SECONDS = 0.2
ANSWER_SECONDS = 60

def ask(body):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
            stream.settimeout(ANSWER_SECONDS)
            stream.connect(control)
            stream.sendall((json.dumps(body) + '\n').encode())
            line = stream.makefile().readline()
        return json.loads(line) if line else {}
    except (OSError, ValueError):
        return {}

if step == 'wait':
    missing = sorted(expected - {window.get('from') for window in windows})
    if missing:
        sys.exit(f'cutover: VCX Rust did not take {len(missing)} of the stopped windows: {" ".join(missing)} ({json.dumps(taken)})')
    held = [window for window in windows if window.get('from') in expected]
    deadline = time.monotonic() + float(sys.argv[5])
    while True:
        shown = {window.get('sessionId'): window for window in ask({'report': {}}).get('windows', [])}
        waiting = [window['from'] for window in held if not (shown.get(window['sessionId'], {}).get('attached') and shown[window['sessionId']].get('carried'))]
        if not waiting:
            break
        if time.monotonic() > deadline:
            sys.exit(f'cutover: {len(waiting)} of the windows taken over never showed their session in VCX Rust: {" ".join(waiting)}')
        time.sleep(POLL_SECONDS)
elif step == 'release':
    print(json.dumps({'release': {'sessions': [window['sessionId'] for window in windows]}}))
elif step == 'retire':
    answer = ask({'retire': {'from': sys.argv[5], 'windows': [{'from': window['from'], 'sessionId': window['sessionId']} for window in windows]}})
    retired = set(answer.get('retired', []))
    if 'error' in answer or not expected <= retired:
        sys.exit(f'cutover: VCX Rust holds the windows, but the Swift app still lists {len(expected - retired)} of them for recovery: {" ".join(sorted(expected - retired))} {answer.get("error", "")}')
    stale = sorted(set(answer.get('kept', [])) - expected)
    if stale:
        print(f'the Swift app still lists {len(stale)} older windows VCX Rust took without their session: {" ".join(stale)}')
PY
}

taken=''
stopped=''
# On a failure once vcx points at VCX Rust: VCX Rust lets the windows go and the Swift app takes them back.
give_back() {
    local status=$?
    trap - EXIT
    [ "$status" -ne 0 ] || return 0
    echo "cutover: giving the windows back to the Swift app" >&2
    [ -z "$taken" ] || ask "$(steward release "$taken" "")" > /dev/null 2>&1 || true
    "$here/../launchers/switch.sh" --to swift >&2 || true
    [ -z "$stopped" ] || open -n -g -a "$swift_app" || true
    exit "$status"
}

to_rust() {
    local rust_worker="$1"
    [ -x "$rust_app/Contents/MacOS/vcx-rust" ] || fail "$rust_app is not installed (vcx/build-rust.sh --install); nothing changed."
    local assets
    assets="$(gh release view "$release" --repo "$repository" --json assets --jq '.assets[].name')" || fail "the $release release is missing: publish the Swift app's last build first; nothing changed."
    case "$assets" in *.zip*) ;; *) fail "the $release release holds no zip of the Swift app; nothing changed." ;; esac
    local worker="$rust_app/Contents/MacOS/vcx-worker"
    [ "$rust_worker" = 0 ] || [ -x "$worker" ] || fail "$worker is missing; nothing changed."
    # Its refusals come before anything stops; from here on, vcx starts VCX Rust.
    "$here/../launchers/switch.sh" --to rust
    trap give_back EXIT
    if [ "$rust_worker" = 1 ]; then
        python3 - "$rust_config/settings.json" "$worker" <<'PY'
import json, os, pathlib, sys
path, worker = pathlib.Path(sys.argv[1]), sys.argv[2]
value = json.loads(path.read_text()) if path.exists() else {}
value['worker'] = worker
path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
temporary = path.with_suffix('.cutover')
temporary.write_text(json.dumps(value, indent=2) + '\n')
os.chmod(temporary, 0o600)
temporary.replace(path)
PY
        echo "new sessions run on the Rust worker"
    fi
    worker="$(python3 - "$rust_config/settings.json" "$swift_app/Contents/MacOS/VCX" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text()) if path.exists() else {}
print(value['worker'] if isinstance(value, dict) and isinstance(value.get('worker'), str) else sys.argv[2])
PY
)"
    local frontends pids expected
    frontends="$(swift_frontends)"
    pids="$(printf '%s\n' "$frontends" | awk 'NF { print $1 }' | sort -u)"
    expected="$(printf '%s\n' "$frontends" | awk 'NF { print $2 }')"
    stopped="$pids"
    for pid in $pids; do
        kill -KILL "$pid" && echo "stopped Swift frontend $pid; its workers keep the sessions"
    done
    for pid in $pids; do
        local polls=0
        while kill -0 "$pid" 2> /dev/null; do
            [ "$polls" -lt $((KILL_WAIT * POLLS_PER_SECOND)) ] || fail "Swift frontend $pid is still running."
            sleep 0.2
            polls=$((polls + 1))
        done
    done
    if ! ask '{"report":{}}' > /dev/null 2>&1; then
        open -g -a "$rust_app"
        local waited=0
        until ask '{"report":{}}' > /dev/null 2>&1; do
            [ "$waited" -lt $((START_WAIT * POLLS_PER_SECOND)) ] || fail "VCX Rust did not start."
            sleep 0.2
            waited=$((waited + 1))
        done
    fi
    taken="$(ask "{\"takeOver\":{\"from\":\"$recovery\"}}")"
    case "$taken" in *'"taken"'*) ;; *) fail "the takeover failed: $taken" ;; esac
    steward wait "$taken" "$expected" "$ATTACH_WAIT" || exit 1
    echo "VCX Rust took over: $taken"
    # VCX Rust holds every window from here on: a later failure leaves them there, and this can run again.
    trap - EXIT
    steward retire "$taken" "$expected" "$recovery" || fail "run this again to remove them."
    case "$worker" in
        "$swift_app"/*) echo "the Swift app stays at $swift_app: VCX Rust starts new sessions' workers from it (--rust-worker moves them to the Rust worker)" ;;
        *)
            if [ -d "$swift_app" ]; then
                [ ! -e "$trash" ] || fail "$trash already exists; the Swift app stays at $swift_app."
                mkdir -p "$(dirname "$trash")"
                mv "$swift_app" "$trash"
                echo "moved the Swift app to $trash; its last build stays in the $release release"
            fi
            ;;
    esac
}

to_swift() {
    if [ ! -d "$swift_app" ]; then
        if [ -d "$trash" ]; then
            mv "$trash" "$swift_app"
        else
            local download
            download="$(mktemp -d)"
            gh release download "$release" --repo "$repository" --dir "$download" --pattern '*.zip'
            ditto -x -k "$download"/*.zip "$home/Applications"
        fi
        [ -d "$swift_app" ] || fail "could not put $swift_app back."
        echo "the Swift app is back at $swift_app"
    fi
    "$here/../launchers/switch.sh" --to swift
}

[ $# -ge 2 ] && [ "$1" = --to ] || usage
case "$2" in
    rust)
        rust_worker=0
        [ $# -le 3 ] || usage
        [ $# -lt 3 ] || { [ "$3" = --rust-worker ] && rust_worker=1; } || usage
        to_rust "$rust_worker"
        ;;
    swift) [ $# -eq 2 ] || usage; to_swift ;;
    *) usage ;;
esac
