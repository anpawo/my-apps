# mac-guard

The banner of mac-guard, the script that stops what takes the Mac down
(`mac-guard.sh`, run by the `mac.guard` LaunchAgent), under its own
name and icon.

![mac-guard's icon: a white shield standing in front of a grey Apple logo, on Fleet's dark tile](docs/icon.png)

`osascript`'s `display notification` posts as Script Editor, with its icon. This app posts its one argument instead:

    ~/apps/mac-guard.app/Contents/MacOS/mac-guard "stopped Python (pid 62824, 6 GB)"

It exits 0 once macOS has the banner, 1 if mac-guard's notifications are off (the script then falls back to
`osascript`). The first run asks macOS to allow them.

A stop or a kill is not a banner while Watcher runs: it is a line in Watcher, and its resume is in the log only.

    ./install.sh    # builds, copies to ~/apps, registers it with LaunchServices
