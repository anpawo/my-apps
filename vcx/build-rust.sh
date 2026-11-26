#!/usr/bin/env bash
# Builds the Rust app as "VCX Rust.app", beside the Swift app and never in its place: its own name, bundle id and
# state folders. Nothing here launches it. The Rust worker ships beside the app (Contents/MacOS/vcx-worker);
# settings.json's "worker" picks it, the Swift worker staying the default.
#
# --install [page] [worker] [app] upgrades the named parts of ~/Applications/VCX Rust.app, all three when none is
# named, each without rebuilding or restarting the others:
#   page    the template folder, copied outside the signed bundle (`Homes::page` in vcx-config), which the running
#           app's windows reload live; no cargo at all.
#   worker  vcx-worker, built and replaced; only the running Rust workers get SIGUSR1 and exec it, keeping their sessions.
#   app     vcx-rust, Info.plist and background.py, built and replaced; only the running app gets SIGUSR1, saves its
#           windows and execs the new build.
# A part whose installed copy is already the same is neither replaced nor signalled. VCX_RUST_INSTALL_DIR and
# VCX_RUST_CONFIG_HOME move the install and the page folder (scratch installs).
set -euo pipefail
cd "$(dirname "$0")"
name="VCX Rust"
app="dist/$name.app"
installed="${VCX_RUST_INSTALL_DIR:-$HOME/Applications}/$name.app"
page="${VCX_RUST_CONFIG_HOME:-$HOME/Library/Application Support/VCX Rust}/page"
template="rust/template"
[[ "$installed" != *"Vibe Code X.app" ]] || { echo "refusing to install over the Swift app" >&2; exit 1; }

usage() { echo "usage: build-rust.sh [--install [page] [worker] [app]]" >&2; exit 2; }
install=false
parts=()
for argument in "$@"; do
    case "$argument" in
        --install) install=true ;;
        page | worker | app) parts+=("$argument") ;;
        *) usage ;;
    esac
done
(( ${#parts[@]} == 0 )) || $install || usage
(( ${#parts[@]} )) || parts=(page worker app)
named() { [[ " ${parts[*]} " == *" $1 "* ]]; }
if $install && ! { named worker && named app; } && { named worker || named app; } && [[ ! -d "$installed" ]]; then
    echo "$installed is not installed yet: run --install with both worker and app first" >&2
    exit 1
fi

# Cargo unifies features across the packages it is given: a worker built without the app is another binary (syn and
# bitflags features differ), which would recompile shared crates and replace an unchanged part. Both packages are
# always given, and --bin picks what is built.
binaries=()
if named worker; then binaries+=(--bin vcx-worker); fi
if named app; then binaries+=(--bin vcx-rust); fi
if (( ${#binaries[@]} )); then
    (cd rust && ~/.local/bin/build-stack cargo build --release -j 2 -p vcx-worker -p vcx-app "${binaries[@]}")
    rm -rf "$app"
    if $install && [[ -d "$installed" ]] && ! { named worker && named app; }; then
        # The part not named stays as installed, so the bundle is sealed over it unchanged.
        ditto "$installed" "$app"
    else
        mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    fi
    if named worker; then
        cp rust/target/release/vcx-worker "$app/Contents/MacOS/vcx-worker"
        codesign --force --sign - "$app/Contents/MacOS/vcx-worker"
        # The worker runs these from ../Resources on each use, so a change to them alone needs no signal.
        for script in cleanup.py trace_archive.py conversation_archive.py; do
            cp "$script" "$app/Contents/Resources/$script"
        done
    fi
    if named app; then
        cp rust/target/release/vcx-rust "$app/Contents/MacOS/vcx-rust"
        cp background.py "$app/Contents/Resources/background.py"
        # The Swift app's icon, as its build drew it (`VCX --icon`): the Swift sources go, the picture stays.
        cp rust/VCX.icns "$app/Contents/Resources/VCX.icns"
        version="$(sed -n 's/^version = "\(.*\)"/\1/p' rust/Cargo.toml | head -1)"
        cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>vcx-rust</string>
    <key>CFBundleIconFile</key><string>VCX</string>
    <key>CFBundleGetInfoString</key><string>The VCX rebuild in Rust: many session windows in one process.</string>
    <key>CFBundleIdentifier</key><string>com.mr.vcx.rust</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
        plutil -lint "$app/Contents/Info.plist" >/dev/null
    fi
    # Python leaves byte code beside a script it ran from the bundle: sealed in, it would break the next install's seal.
    find "$app" -name __pycache__ -type d -prune -exec rm -rf {} +
    touch "$app"
    codesign --force --sign - "$app"
fi
$install || exit 0

# True when two signed executables hold the same code, whatever their signatures: sealing the bundle over a new
# worker re-signs vcx-rust without changing it.
same_code() {
    local first second same=0
    first="$(mktemp)"
    second="$(mktemp)"
    cp "$1" "$first"
    cp "$2" "$second"
    codesign --remove-signature "$first" && codesign --remove-signature "$second" && cmp -s "$first" "$second" || same=1
    rm -f "$first" "$second"
    return "$same"
}

page_created=false
if named page; then
    if [[ -d "$page" ]] && diff -rq "$template" "$page" >/dev/null; then
        echo "page: unchanged"
    else
        [[ -d "$page" ]] || page_created=true
        mkdir -p "$page"
        # One ditto writes every file within a few milliseconds, well inside the windows' settle before a reload.
        ditto "$template" "$page"
        (cd "$page" && find . -type f) | while IFS= read -r file; do
            [[ -e "$template/$file" ]] || rm "$page/$file"
        done
        echo "page: installed in $page"
    fi
fi

worker_changed=false
app_changed=false
if named worker || named app; then
    if [[ ! -d "$installed" ]]; then
        mkdir -p "$(dirname "$installed")"
        ditto "$app" "$installed"
        echo "installed $installed"
    else
        contents="$app/Contents"
        mine="$installed/Contents"
        if named worker && ! cmp -s "$contents/MacOS/vcx-worker" "$mine/MacOS/vcx-worker"; then worker_changed=true; fi
        if named app && { ! same_code "$contents/MacOS/vcx-rust" "$mine/MacOS/vcx-rust" \
            || ! cmp -s "$contents/Info.plist" "$mine/Info.plist" \
            || ! cmp -s "$contents/Resources/background.py" "$mine/Resources/background.py"; }; then app_changed=true; fi
        replaced=0
        # Each file goes in by a rename, never written over: a running process keeps the image it started from.
        while IFS= read -r file; do
            if ! cmp -s "$app/$file" "$installed/$file"; then
                mkdir -p "$(dirname "$installed/$file")"
                cp -p "$app/$file" "$installed/$file.new"
                mv -f "$installed/$file.new" "$installed/$file"
                replaced=$((replaced + 1))
            fi
        done < <(cd "$app" && find . -type f)
        while IFS= read -r file; do
            [[ -e "$app/$file" ]] || { rm "$installed/$file"; replaced=$((replaced + 1)); }
        done < <(cd "$installed" && find . -type f)
        find "$installed" -mindepth 1 -depth -type d -empty -delete
        if (( replaced )); then touch "$installed"; fi
        if named worker; then $worker_changed && echo "worker: replaced" || echo "worker: unchanged"; fi
        if named app; then $app_changed && echo "app: replaced" || echo "app: unchanged"; fi
        echo "$replaced files replaced in $installed"
    fi
fi

# Only this bundle's processes, and only those of a part that changed; the Swift app's are never signalled. A first
# page install restarts the app once: it reads the page folder only at launch.
worker="$installed/Contents/MacOS/vcx-worker"
frontend="$installed/Contents/MacOS/vcx-rust"
ps -axo pid=,comm= | while read -r pid comm; do
    if $worker_changed && [[ "$comm" == "$worker" ]]; then
        kill -USR1 "$pid" && echo "updating worker $pid"
    elif { $app_changed || $page_created; } && [[ "$comm" == "$frontend" ]]; then
        kill -USR1 "$pid" && echo "updating app $pid"
    fi
done
