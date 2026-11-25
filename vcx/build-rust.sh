#!/usr/bin/env bash
# Builds the Rust app as "VCX Rust.app", beside the Swift app and never in its place: its own name, bundle id and
# state folders. --install copies it to ~/Applications under that name; nothing here launches it.
set -euo pipefail
cd "$(dirname "$0")"
name="VCX Rust"
app="dist/$name.app"
installed="$HOME/Applications/$name.app"
[[ "$installed" != *"Vibe Code X.app" ]] || { echo "refusing to install over the Swift app" >&2; exit 1; }

(cd rust && ~/.local/bin/build-stack cargo build --release -j 2 -p vcx-app)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp rust/target/release/vcx-rust "$app/Contents/MacOS/vcx-rust"
cp background.py "$app/Contents/Resources/background.py"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' rust/Cargo.toml | head -1)"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>vcx-rust</string>
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
touch "$app"
codesign --force --sign - "$app"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$installed"
    ditto "$app" "$installed"
    echo "installed $installed"
fi
