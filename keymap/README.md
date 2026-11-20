# keymap

A keyboard where every key already taken by macOS shows what it does, for the modifiers you hold or click.

![Keymap with ⌘ held: Q Quit, W Close window, Space Spotlight, Tab Switch app; 5 to 8 are tabs, \ ' and / are free](docs/shot.png)

Red: macOS, in every app (Spotlight, screenshots, Mission Control). Orange: the menus most apps share (Copy,
Find, Hide). Blue: the keys of every text field (⌃A, ⌥←). A click on a colour in the top right hides or shows its
shortcuts; the choice is kept. A click on a shortcut strikes it out and counts it as free (one you give up); the
menu items few people use (⌘E, ⌘J, ⌘;, ⌥⌘C/V, the Finder folders on ⇧⌘) start out struck. With no modifier, each key says how many of its
combinations are taken. The list is macOS 26's defaults on a U.S. layout, written in `main.swift`; your own
apps' shortcuts are not in it.

    ./install.sh                                # builds, checks and copies Keymap.app to ~/apps
    .build/debug/keymap --selftest              # every listed key is on the keyboard, no combination twice
    .build/debug/keymap --render x.png ⌥⌘       # the window for ⌥⌘, drawn without showing it
