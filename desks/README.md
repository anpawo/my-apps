# desks

Desktops (Spaces) on macOS without the slide: go to one at once, carry a window there, make a new
one, from a hotkey or the command line. The real desktops, the ones Mission Control shows, with
SIP left as it is.

| Keys | Does |
|---|---|
| ⌃⌥1 … ⌃⌥9 | go to that desktop, no animation |
| ⌃⌥← ⌃⌥→ | the desktop on that side |
| ⌃⌥⇧1 … ⌃⌥⇧9 | carry the window in front there; past the last desktop, a new one is made |

```sh
desks query                 # the desktops of the menu bar's screen, as JSON
desks focus <n|next|prev>
desks send <n|next|prev>    # the window goes, you stay
desks carry <n|next|prev>   # the window goes, you follow
desks new
```

How, since macOS gives no API for any of it:

- **Going there:** a three-finger swipe posted to the Dock, flung so fast it skips the slide
  ([InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher)'s technique, MIT).
- **Moving a window:** the window operation SkyLight hands the Dock, looked up in its symbol
  table (as yabai does since asmvik/yabai#2788).
- **A new desktop:** Mission Control's own `+`, pressed through Accessibility, so it flashes for
  half a second.

`./install.sh` builds it, puts it in `~/apps` and runs the hotkeys under the LaunchAgent
`app.desks`. It needs Accessibility (System Settings → Privacy & Security → Accessibility).
`swift run check` runs the checks.
