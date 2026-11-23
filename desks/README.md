# desks

Desktops (Spaces) on macOS from the command line: list them, make one, put a window on one
without it coming forward. Made so an agent can open and capture its test windows on a desktop
you are not looking at. The real desktops, the ones Mission Control shows, with SIP left as it is.

```sh
desks query                   # the desktops of the menu bar's screen, as JSON
desks move <window id> <n>    # that window goes to desktop n, nothing comes forward
desks new                     # a new desktop
desks focus <n|next|prev>     # go there at once, no slide
desks send <n|next|prev>      # the window in front goes there, you stay
desks carry <n|next|prev>     # the window in front goes there, you follow
desks launch <n> <app> [file…] # a test copy of the app opens on desktop n, prints its window id
```

`launch` copies the app to `$TMPDIR/desks/<Name> Test.app` with its bundle id suffixed `.test`, so
the copy keeps its own settings and history and runs beside his copy, as many times as asked. It
starts hidden (`open -g -j -n`), so an app that activates at launch must skip that when
`NSApp.isHidden` (Viewer Media does), or it pulls him to that desktop.

A window on another desktop still renders: `screencapture -x -o -l <window id> shot.png` captures
it from there.

How, since macOS gives no API for any of it:

- **Moving a window:** the window operation SkyLight hands the Dock, looked up in its symbol
  table (as yabai does since asmvik/yabai#2788).
- **A new desktop:** Mission Control's own `+`, pressed through Accessibility, so it flashes for
  half a second.
- **Going there:** a three-finger swipe posted to the Dock, flung so fast it skips the slide
  ([InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher)'s technique, MIT).

`./install.sh` builds it, puts it in `~/apps` and links `desks` into `~/.local/bin`. `new`, `focus`
and `carry` need Accessibility for whatever runs them. `swift run check` runs the checks.
