# one-text

One conversation per person, whatever app they wrote from: WhatsApp, Instagram, Discord, Teams, LinkedIn, SMS, Telegram and Matrix, merged into one timeline.

![A walk through One Text on made-up chats: favorites on top (Lea Martin, Chloe Dubois, Mom, the Climbing crew group chat) under the Friends, Family and Work groups, a list where each picture carries its app's logo and unread counts; Lea's Instagram and WhatsApp messages in one thread with a reel card, a photo, a reply quote and reactions, a heart added from the hover bar and a reply sent; Friends unfolded and the Flat 4B group chat dragged into it; tom's Discord thread with a voice message, a code block and a list, and a deleted message kept dimmed; the ⌘D search opening Hugo R and the menu under his name with a Split row per app; then Settings with the Play reels here switch and every shortcut](docs/demo.gif)

It reads and sends through the local [Beeper](https://www.beeper.com) Server API (its address and token come from `~/.beeper/targets/background.json` at launch), and starts Beeper Server when it is not answering. The recording above is `node tests/demo.mjs`: headless WebKit on made-up chats.

## Conversations

- A conversation opens on its last messages; scrolling up loads older ones, a page at a time from each app, kept in time order. It opens on the conversation you had open last (Eliot Gourdoux the first time).
- A person's bar shows the logos of the apps they are on in a row, their picture under them and their name in a pill (click it for the menu, centred under it); hover a logo for what that app knows. The ringed logo is where your reply goes (by default the app they last wrote from): click another, or type `/ws`, `/ig`, `/dc`, `/te`, `/li`, `/sm`, `/sc`, `/tg` or `/mx`.
- A click on the picture in the header, or on the open conversation's picture in the list, opens their profile from the right: what each app knows of them (name, username, phone, email); for a group, its description and members, admins first, each opening their own profile. esc closes it.
- Under your last message: Sent, then Seen and its time once they read it (in a group, Seen by how many).
- A blue "New" line sits above the first unread message until you answer or press ⌘K; in the side bar the unread count sits right of the time.
- Unsent text stays with its conversation, across launches too.

## Messages

- Hovering a message shows your 5 most used reactions beside it: click one to react, click your reaction under the message to take it back. The + at the end of that bar opens every emoji, 5 to a row, most used first: type to search them by name, ↵ picks the first.
- Right-click a message: Reply, React…, Copy; on yours, Edit (its text fills the field, ↵ saves, esc cancels) and Delete (a second click: it goes for everyone).
- A message deleted by its sender still shows what it said (Beeper keeps it), dimmed and marked Deleted; "Message deleted" only when nothing was kept.
- ⌘R replies to the message under the pointer (or to their last one), on its app. A reply shows the message it answers above it, behind a white line (in a group, with who wrote it).
- `:` and two letters list emoji by name (`:joy` → 😂): ↑ ↓ to pick, ↵ or tab to put it in.
- Voice messages play in the thread, their length shown before you play them and a dot on those you have not heard to the end; stickers show as pictures. The mic button beside send records one: click it again to send, esc to drop (macOS asks once for the microphone).
- ⌘V on an image (a screenshot, a copied picture) sends it at once; the text in the field stays.
- A picture or a video grows from its bubble to fill the window; a click beside it or esc shrinks it back.
- A shared Instagram reel shows as a card. Clicking it downloads it (a few seconds, logged out, with `yt-dlp` from Homebrew, kept in the app's cache) and plays it in the window, or opens Instagram when Play reels here is off in Settings.
- Formatted messages (Discord's lists, bold, inline code, code blocks, quotes) show their formatting.
- ⌘F finds a word in the open conversation (case and accents aside): ↵ goes to the older match, loading older messages past the last one, ⇧↵ to the newer; esc closes.

## People, merging, aliases

- Chats with the same name (word order and accents aside), the same phone number, an Instagram handle like `first.last` matching a full name, or `first_l` matching the one full name that starts that way, are one person; so is a first name alone ("Cyprien") when no app has two chats under it; so are the chats Beeper merged itself, and two chats under the same first name on two apps with the same profile photo (however each app crops it).
- The menu under the name merges (Merge with…) or splits by hand: one Split row per app, with its logo and the handle or number it goes by there (LinkedIn's handle is an opaque id, shown only to tell two LinkedIn accounts apart). Merge with… also makes two group chats one conversation (the same group on two apps).
- ⌘M (or the menu's Alias…) gives a person or a group an alias, shown in place of the apps' name; ⌘D finds them by either name and shows both.
- Change picture… gives a person or a group a picture of your own.
- Mute mutes a person or a group on every app it is on: no badge, no count, a bell struck out beside the name. A reaction to one of your messages does not count as unread either.
- A group can be hidden from the list (Hide from the list); ⌘D still finds it.

## The list, favorites, groups

- One list, people and groups together, newest first: as many as fit in the window (10 at most, fewer under many favorites), plus anyone with unread messages; scrolling past the end shows twice as many.
- A group chat shows the small logo of its app, then up to 4 of its members' pictures in one round tile; a person shows the logo of the app of their latest message, then their picture.
- Favorites sit on top as pictures, on a faint platinum sheen: right-click a person (or ⌘F over them) to add or remove one; a favorite group chat is one more picture there. ⌘ + arrows reorder them.
- Under the favorites, each group you make (the + right of the groups) holds people, its name above its pictures, 5 to a row. A group of more than 5 folds the rest into one tile of small pictures (click it to unfold); whoever has unread messages stays out of the tile. Drag someone onto another group to move them, or onto the top strip to take them out. Folded groups sit in one row that slides sideways when they do not fit.
- Drag the sidebar's right edge to widen or narrow it; the width is kept.
- ⌘D opens a search over everyone in the middle of the window: ↑ ↓ to pick, ↵ to open, esc to close; ⌘M and ⌘F work on the highlighted row. `/discord`, `/whatsapp` (or `/dc`, `/wh`…) before a name keeps only those on that app.

## Settings and keys

Settings is the gear above the list, or ⌘,. It holds the Play reels here switch (on: reels play in the window; off: they open in the browser) and lists every shortcut:

| Key | Does |
|---|---|
| ⌘D | Search people and groups |
| ⌘F | Find in the conversation; over a row, add or remove the favorite |
| ⌘K | Seen, nothing to say: clears the badge and sends the read receipt |
| Esc | The same as ⌘K on the open conversation, when its thread is scrolled to the end |
| ⌘R | Reply to the message under the pointer, or their last one |
| ⌘G | Edit my message under the pointer, or my last one |
| ⌘M | Alias the person or group under the pointer, or the open one |
| ⌘ ← ↑ ↓ → | Move the favorite under the pointer, or the open one |
| ⇧↩ | New line (↩ sends) |
| `/ig` `/ws` `/dc` `/te` `/li` `/sm` `/sc` `/mx` | Reply on that app |
| esc | Close what is open: menu, search, profile, picture, reply |
| ⌘, | Settings |

It opens at login, and ⌘Q or the close button only hide it, unless Allow Quitting is ticked in the One Text menu.

## Privacy and encryption

One Text is a window on Beeper: it talks only to Beeper Server on this Mac (`127.0.0.1`), never to Beeper's servers or to the chat apps directly. Where a message travels before it reaches that local server depends on how Beeper connects each app.

| Connection | Where it runs | What Beeper's servers see |
|---|---|---|
| Beeper Cloud (WhatsApp, Instagram, Discord, LinkedIn, Google Messages) | On Beeper's servers, which hold your login to each app | Beeper runs the connection, so it handles the messages and holds your access tokens; the history it stores is under zero-access encryption, readable only with your Recovery Code ([Beeper FAQ](https://www.beeper.com/faq), [Beeper blog](https://blog.beeper.com/2024/04/09/how-beeper-android-works/)) |
| Self-hosted bridge (a Matrix server of your own, Teams) | On this Mac (a mautrix bridge started by launchd), logged in to the app directly | Only messages already encrypted with Matrix encryption (the bridges' `encryption.require: true`), never your credentials; still in the clear: room names and topics, who is in a room, when each message was sent and by whom, read receipts |

What One Text itself does:

- **Sends nothing on its own.** Opening a conversation sends no read receipt and no typing notice. A read receipt goes out only when you answer, react, or press ⌘K (or Escape at the end of the thread).
- **Keeps no messages.** The thread is fetched from Beeper each time. What it stores stays on this Mac: favorites, groups, drafts, what you marked seen and your reaction counts in its WebKit storage; merges, aliases and your pictures in `~/Library/Application Support/com.mr.one-text/overrides.json`, profile-picture fingerprints beside it in `pictures.json`.
- **One outside call.** Playing a reel here runs `yt-dlp` logged out against instagram.com (the video is kept in the app's cache); with Play reels here off, the link opens in your browser instead. Links open in your browser.

## Build

    cd src-tauri && npx @tauri-apps/cli build --bundles app

To keep it current, copy `mac.one-text-update.plist` into `~/Library/LaunchAgents`: on every push from this checkout and
every 10 minutes, `auto-update.sh` builds the latest `one-text/` from `main` in a worktree of its own, installs it in
`~/Applications` and restarts the app if it ran (it waits while One Text is the app in front). While it builds, the
bottom of the list shows `Building update · <the commit>` over a line that fills at the pace of the last install.
Log: `~/.local/state/mac.one-text-update.log`.

## Checking it without a window

`node tests/ui.mjs <outdir>` runs the interface in headless WebKit on made-up chats, checks it, and writes screenshots.
`node tests/demo.mjs` records `docs/demo.gif` from the same chats (needs ffmpeg).
