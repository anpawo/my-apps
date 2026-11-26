#!/bin/bash
# The switch from the Swift app to VCX Rust in one command, and back.
#
# --to rust, in order: refuses unless VCX Rust is installed and the vcx-swift-final release holds the Swift app's last
# build; stops the Swift app's frontends with SIGKILL, as a crash would, so their windows stay listed for recovery and
# their workers keep every session (a normal quit ends them); starts VCX Rust and has it take those windows over on
# the same workers; points the vcx command at VCX Rust (launchers/switch.sh); with --rust-worker, makes the Rust
# worker the default for new sessions; and moves the installed Swift app to the Trash.
# --to swift puts the Swift app back from the Trash, or from the release, and the vcx command with it; the windows
# VCX Rust holds stay there.
#
# Every folder follows $HOME, and VCX_SWIFT_RECOVERY, VCX_RUST_STATE_HOME, VCX_RUST_CONFIG_HOME and switch.sh's own
# variables move them, for the rehearsal (crates/vcx-app/tests/cutover.rs); `open`, `gh` and `launchctl` are found
# on PATH.
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

fail() { echo "cutover: $*" >&2; exit 1; }
usage() { echo "usage: $0 --to rust [--rust-worker] | --to swift" >&2; exit 2; }

ask() {
    printf '%s\n' "$1" | nc -U -w "$TAKEN_WAIT" "$rust_state/control.sock"
}

# The pids that own a window in the Swift recovery folder and still run as the recorded process: the Swift binary,
# started at the recorded time (Swift `ownerStart`, microseconds), so a reused pid is never stopped.
swift_frontends() {
    [ -d "$recovery" ] || return 0
    python3 - "$recovery" <<'PY'
import ctypes, json, pathlib, sys

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
    except (OSError, ValueError):
        continue
    pid, start = value.get('ownerPID'), value.get('ownerStart')
    if isinstance(pid, int) and pid > 1 and isinstance(start, int) and not value.get('closeRequested'):
        if started(pid) == ('VCX', start):
            print(pid)
PY
}

to_rust() {
    local rust_worker="$1"
    [ -x "$rust_app/Contents/MacOS/vcx-rust" ] || fail "$rust_app is not installed (vcx/build-rust.sh --install); nothing changed."
    gh release view "$release" --repo "$repository" > /dev/null || fail "the $release release is missing: publish the Swift app's last build first; nothing changed."
    local pids
    pids="$(swift_frontends | sort -u)"
    for pid in $pids; do
        kill -KILL "$pid" && echo "stopped Swift frontend $pid; its workers keep the sessions"
    done
    for pid in $pids; do
        while kill -0 "$pid" 2> /dev/null; do sleep 0.2; done
    done
    if ! ask '{"report":{}}' > /dev/null 2>&1; then
        open -g -a "$rust_app"
        local waited=0
        until ask '{"report":{}}' > /dev/null 2>&1; do
            [ "$waited" -lt $((START_WAIT * 5)) ] || fail "VCX Rust did not start; the Swift windows are still listed for recovery, run this again."
            sleep 0.2
            waited=$((waited + 1))
        done
    fi
    local taken
    taken="$(ask "{\"takeOver\":{\"from\":\"$recovery\"}}")"
    case "$taken" in *'"taken"'*) echo "VCX Rust took over: $taken" ;; *) fail "the takeover failed: $taken" ;; esac
    "$here/../launchers/switch.sh" --to rust
    if [ "$rust_worker" = 1 ]; then
        python3 - "$rust_config/settings.json" "$rust_app/Contents/MacOS/vcx-worker" <<'PY'
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
    if [ -d "$swift_app" ]; then
        [ ! -e "$trash" ] || fail "$trash already exists; the Swift app stays at $swift_app."
        mkdir -p "$(dirname "$trash")"
        mv "$swift_app" "$trash"
        echo "moved the Swift app to $trash; its last build stays in the $release release"
    fi
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
