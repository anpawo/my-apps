#!/bin/bash
# The one switch between the two apps: `--to rust` puts the VCX Rust launcher (`vcx` beside this file) at
# ~/.local/bin/vcx and pauses the Swift app's install job (mac.vcx-update), whose every run writes the Swift launcher
# back; `--to swift` undoes both. Fleet, spawn and the opener's ⌥⌘J start VCX through that command, so they follow.
# `--status` says which app it starts. Nothing here starts an app. VCX_BIN_HOME, VCX_RUST_STATE_HOME and
# VCX_UPDATE_HOME move its folders, for tests; launchctl is found on PATH.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bin="${VCX_BIN_HOME:-$HOME/.local/bin}"
launcher="$bin/vcx"
saved="${VCX_RUST_STATE_HOME:-$HOME/.local/state/vcx-rust}/launchers"
swift_launcher="$saved/vcx.swift"
update="${VCX_UPDATE_HOME:-$HOME/.local/share/vcx-update}"
rust_app="$HOME/Applications/VCX Rust.app"
swift_app="$HOME/Applications/Vibe Code X.app"
job=mac.vcx-update
plist="$HOME/Library/LaunchAgents/$job.plist"
service="gui/$(id -u)/$job"
rust_mark='# vcx launcher: VCX Rust'
# What install-native.py writes on its second line.
swift_mark='# vcx launcher'

usage() { echo "usage: $0 --to rust | --to swift | --status" >&2; exit 2; }
fail() { echo "switch: $*" >&2; exit 1; }

# rust, swift, none, or other (a command this switch did not write).
starts() {
    local file="$1"
    if [ ! -e "$file" ]; then echo none
    elif grep -qxF "$rust_mark" "$file"; then echo rust
    elif grep -qxF "$swift_mark" "$file" && grep -qF 'Vibe Code X.app' "$file"; then echo swift
    else echo other
    fi
}

place() {
    local temporary="$bin/.vcx-switch-$$"
    cp "$1" "$temporary"
    chmod 755 "$temporary"
    mv -f "$temporary" "$launcher"
}

to_rust() {
    case "$(starts "$launcher")" in
        rust) echo "vcx already starts VCX Rust."; return ;;
        swift) ;;
        *) fail "$launcher is not the Swift app's vcx launcher; nothing changed." ;;
    esac
    [ -x "$rust_app/Contents/MacOS/vcx-rust" ] || fail "$rust_app is not installed (vcx/build-rust.sh --install); nothing changed."
    [ "$(starts "$here/vcx")" = rust ] || fail "$here/vcx is not the VCX Rust launcher; nothing changed."
    # Disabled first, so no new run starts; a run already installing is left to finish (stopping it mid-swap could
    # leave no Swift app at all).
    launchctl disable "$service"
    if [ -e "$update/building" ] || launchctl print "$service" 2>/dev/null | grep -q 'state = running'; then
        launchctl enable "$service"
        fail "the Swift app is being installed ($job); try again once it ends. Nothing changed."
    fi
    launchctl bootout "$service" 2>/dev/null || true
    mkdir -p -m 700 "$saved"
    cp -p "$launcher" "$swift_launcher"
    place "$here/vcx"
    echo "vcx now starts VCX Rust; $job is paused. Undo: $0 --to swift"
}

to_swift() {
    case "$(starts "$launcher")" in
        swift) echo "vcx already starts the Swift app." ;;
        rust)
            [ -d "$swift_app" ] || fail "$swift_app is gone (its last build is the vcx-swift-final release); nothing changed."
            [ "$(starts "$swift_launcher")" = swift ] || fail "no saved Swift launcher at $swift_launcher (python3 vcx/install-native.py writes one); nothing changed."
            place "$swift_launcher"
            ;;
        *) fail "$launcher is not a vcx launcher; nothing changed." ;;
    esac
    launchctl enable "$service"
    # Already loaded is fine: it then runs on its own schedule.
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || true
    echo "vcx starts the Swift app; $job runs again."
}

[ $# -ge 1 ] || usage
case "$1" in
    --status) echo "vcx starts: $(starts "$launcher")" ;;
    --to)
        [ $# -eq 2 ] || usage
        case "$2" in rust) to_rust ;; swift) to_swift ;; *) usage ;; esac
        ;;
    *) usage ;;
esac
