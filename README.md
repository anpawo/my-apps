# my-lab

Little apps made for my needs. Each one is a folder at the root of this repo, and each one
runs on my Mac today.

## Using one

```sh
git clone https://github.com/anpawo/my-lab.git && cd my-lab/<app>
./install.sh
```

`install.sh` builds the app, copies it to `~/Applications` and registers a launchd agent so it
starts with your session. All it needs is a Swift toolchain and the Command Line Tools, no
Xcode. Written for macOS on Apple Silicon. MIT, see [`LICENSE`](LICENSE).

Or download it: [the latest release](https://github.com/anpawo/my-lab/releases/latest) has every app,
zipped, rebuilt on each change.

**If you took one home, leave a star.** It is the only signal I get that any of this was
useful to someone else.

## The apps

Click one for its README.

<!-- apps:start -->
### [alt-tab](alt-tab)

[![A ⌘Tab session on an invented desktop: the switcher opens over a Finder window, the selection steps from tile to tile with each Tab, and letting go of ⌘ brings the Mail window forward](alt-tab/docs/demo.gif)](alt-tab)

### [autocorrect](autocorrect)

[![Three lines typed into a text field, each word fixed on space: ça va très bien, I don't think the plan is ready, and tema, changed to team then put back with ⌫](autocorrect/docs/demo.gif)](autocorrect)

### [opener](opener)

[![opener](opener/docs/opener.png)](opener)

### [screenshot](screenshot)

[![⌘⇧5 over a desktop of three windows: the screen dims, a selection is dragged out with its size in pixels growing, the pointer names two buttons of the bar, Capture, and the shot's thumbnail comes up in the top-right corner](screenshot/docs/demo.gif)](screenshot)

### [watcher](watcher)

[![The panel: one line waiting, its subject, what the follow-up left, its age, and the buttons to move, open, set aside](watcher/docs/panel.png)](watcher)
<!-- apps:end -->
