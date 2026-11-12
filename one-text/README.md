# one-text

One conversation per person, whatever app they wrote from: WhatsApp, Instagram, Discord, Teams, LinkedIn, SMS and Matrix, merged into one timeline.

![Lea Martin's conversation: her Instagram and WhatsApp messages in one timeline, an Instagram reel shown as a card, and at the top right the logos of both apps, Instagram highlighted as the one replies go to](docs/screenshot.png)

It reads and sends through the local [Beeper](https://www.beeper.com) Server API (its address and token come from `~/.beeper/targets/background.json` at launch; nothing is stored in the app), and starts Beeper Server when it is not answering.

- One list, people and groups together, newest first: as many as fit in the window (10 at most, fewer under many favorites), plus anyone with unread messages; scrolling past the end shows twice as many.
- ⌘R (or right-click → Alias…) gives a person or a group an alias, shown in place of the apps' name; ⌘D finds them by either name and shows both. In the ⌘D search, ⌘R aliases the highlighted row.
- A group can be hidden from the list (right-click, Hide from the list); ⌘D still finds it. A group chat shows the small logo of the app it comes from, then up to 4 of its members' pictures in one round tile (the picture their person has, yours or another app's, first); a person shows the logo of the app of their latest message, then their picture.
- Favorites sit above it as pictures only: right-click a person (or ⌘F over them, or on the highlighted row of the ⌘D search) to add or remove one. A pinned group keeps its row, under those pictures, with all its members overlapping left to right. ⌘ + arrows move the favorite under the pointer (or the open one) to order them. Favorites in no group sit on top; under them, each group you make (+ New group) is always open, its name above its pictures; the sidebar fits 5 pictures to a row. A group of more than 5 shows 4 and folds the rest into one tile of small pictures (click it to unfold); whoever has unread messages stays out of the tile, unless 5 or more do. Someone is in one group at most: drag them onto another group to move them, or onto the top strip to take them out (right-click → Move to <group> does the same). Thin white lines separate favorites, groups, pinned group chats and the list.
- Chats with the same name (word order and accents aside), the same phone number, an Instagram handle like `first.last` matching a full name, or `first_l` matching the one full name that starts that way, are one person; so is a first name alone ("Cyprien") when no app has two chats under it; and so are the chats inside one Beeper merged itself, and two chats under the same first name on two apps with the same profile photo (however each app crops it: Instagram gives no phone number to meet WhatsApp on); the ⋯ menu merges or splits them by hand.
- The logos at the top right are the apps that person is on; the highlighted one is where your reply goes (by default the app they last wrote from). Click another, or type `/ws`, `/ig`, `/dc`, `/te`, `/li`, `/sm` or `/mx`.
- Right-click → Change picture… gives a person or a group a picture of your own (kept in the app's `overrides.json`).
- A reaction to one of your messages does not count as unread, and a muted chat shows no count.
- Opening a conversation sends no read receipt.
- It opens at login, and ⌘Q or the close button only hide it, unless Allow Quitting is ticked in the one-text menu.
- Drag the sidebar's right edge to widen or narrow it; the width is kept.
- ⌘D opens a search over everyone in the middle of the window: ↑ ↓ to pick, ↵ to open, esc to close. `/discord`, `/whatsapp` (or `/dc`, `/wh`…) before a name keeps only those on that app.

## Build

    cd src-tauri && npx @tauri-apps/cli build --bundles app

## Checking it without a window

`node tests/ui.mjs <outdir>` runs the interface in headless WebKit on made-up chats, checks it, and writes screenshots.
