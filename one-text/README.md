# one-text

One conversation per person, whatever app they wrote from: WhatsApp, Instagram, Discord, Teams, LinkedIn, SMS and Matrix, merged into one timeline.

![Lea Martin's conversation: her Instagram and WhatsApp messages in one timeline, an Instagram reel shown as a card, and at the top right the logos of both apps, Instagram highlighted as the one replies go to](docs/screenshot.png)

It reads and sends through the local [Beeper](https://www.beeper.com) Server API (its address and token come from `~/.beeper/targets/background.json` at launch; nothing is stored in the app), and starts Beeper Server when it is not answering.

- One list, people and groups together, newest first: the 10 newest, plus anyone with unread messages.
- A group can be hidden from the list (right-click, Hide from the list); ⌘D still finds it. A small Instagram or WhatsApp group with no picture shows two of its members'.
- Favorites sit above it as pictures only: right-click a person (or ⌘F over them) to add or remove one.
- Chats with the same name (word order and accents aside), the same phone number, or an Instagram handle like `first.last` matching a full name are one person, and so are the chats inside one Beeper merged itself; the ⋯ menu merges or splits them by hand.
- The logos at the top right are the apps that person is on; the highlighted one is where your reply goes (by default the app they last wrote from). Click another, or type `/ws`, `/ig`, `/dc`, `/te`, `/li`, `/sm` or `/mx`.
- Right-click → Change picture… gives a person or a group a picture of your own (kept in the app's `overrides.json`).
- A reaction to one of your messages does not count as unread, and a muted chat shows no count.
- Opening a conversation sends no read receipt.
- ⌘D opens a search over everyone in the middle of the window: ↑ ↓ to pick, ↵ to open, esc to close.

## Build

    cd src-tauri && npx @tauri-apps/cli build --bundles app

## Checking it without a window

`node tests/ui.mjs <outdir>` runs the interface in headless WebKit on made-up chats, checks it, and writes screenshots.
