#!/usr/bin/env python3
"""Fleet's MESSAGES block, from Beeper Server's local index (read on a copy, never written).

Writes ~/.local/state/fleet/blocks/messages.json: the three chats with unread messages heard from
last, each a click away from a VCX session that reads it, and a notice for what came in since the
last run, which Fleet posts as a banner. Run every 10 s by the fleet.messages LaunchAgent.

  messages.py            one run
  messages.py --test     the self-check, on a made-up index
"""
import json, os, plistlib, shutil, sqlite3, subprocess, sys, tempfile, time

SRC = os.path.expanduser("~/.beeper/profiles/server/background/index.db")
BEEPER_ID = "com.automattic.beeper.desktop"
BEEPER_PREFS = os.path.expanduser("~/Library/Application Support/BeeperTexts/account.db")
# macOS 26 keeps per-app notification settings here, not in com.apple.ncprefs.
NC_PREFS = os.path.expanduser("~/Library/Group Containers/group.com.apple.usernoted/Library/"
                              "Preferences/group.com.apple.usernoted.plist")
OUT = os.path.expanduser("~/.local/state/fleet/blocks/messages.json")
CURSOR = os.path.expanduser("~/.local/state/fleet/messages-cursor.json")
# Each network's icon, copied beside the block: Fleet reads pictures from its blocks folder.
ICONS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
SHOWN = 3
SKIP = ("HIDDEN", "REACTION", "MEMBERSHIP", "NOTICE")
# A message read within this many seconds (Beeper, or his phone through the read receipt) gets no banner.
GRACE = 30

THREADS = """
select threadID id, accountID account, timestamp ts,
       coalesce(nullif(json_extract(thread,'$.title'), ''),
                (select group_concat(full_name, ', ') from participants p where p.room_id = threadID
                 and not coalesce(p.is_self, 0) and not coalesce(p.is_network_bot, 0)), '') title,
       coalesce(json_extract(thread,'$.unreadCount'), 0) unread,
       json_extract(thread,'$.extra.protocol') protocol
from threads where accountID not like '$%' and json_extract(thread,'$.unreadCount') > 0
order by timestamp desc"""

INCOMING = f"""
select m.eventID id, m.roomID room, m.timestamp ts, m.type, m.senderContactID sender,
       json_extract(m.message,'$.text') text
from mx_room_messages m
where m.isSentByMe = 0 and m.shouldNotify = 1 and not m.isDeleted
  and m.seenByMeAt is null
  and m.type not in ({",".join("?" * len(SKIP))}) and m.timestamp > ? and m.timestamp <= ?
order by m.timestamp"""


def network(protocol, account):
    p = (protocol or account or "?").split("/")[-1].split("mautrix-")[-1]
    p = p.split(".")[0].split("_")[0]
    p = p[:-2] if p.endswith("go") else p
    return "sms" if p.startswith("gmessages") else {"hungryserv": "beeper", "": "?"}.get(p, p)


def title(raw):
    # His WhatsApp self-chat is titled with his phone number.
    return "Note to self" if sum(c.isdigit() for c in raw or "") >= 6 else (raw or "?")


def words(row):
    if row["type"] in ("TEXT",) and row["text"]:
        return " ".join(row["text"].split())
    return {"VOICE": "voice message", "IMAGE": "photo", "VIDEO": "video", "FILE": "file",
            "STICKER": "sticker"}.get(row["type"], row["type"].lower())


def beeper_covers():
    """The chat types ("single", "group") whose banner Beeper Desktop shows itself, so Fleet stays quiet."""
    try:
        if subprocess.run(["pgrep", "-xq", "Beeper Desktop"]).returncode:
            return set()
        with open(NC_PREFS, "rb") as f:
            flags = next((a.get("flags", 0) for a in plistlib.load(f).get("apps", [])
                          if a.get("bundle-id") == BEEPER_ID), 0)
        # Alert style None, or the "Desktop" box unticked (bit 31): macOS shows Beeper nothing.
        if not (flags >> 3) & 7 or flags >> 31 & 1:
            return set()
        db = sqlite3.connect(f"file:{BEEPER_PREFS}?mode=ro", uri=True)
        row = db.execute("select value from store where key='ad:com.beeper.desktop.prefs'").fetchone()
        db.close()
        prefs = json.loads(row[0]) if row else {}
        return {kind for kind, key in (("single", "message_notifications"), ("group", "group_message_notifications"))
                if prefs.get(key, True)}
    except (OSError, ValueError, sqlite3.Error):
        return set()


def ago(ms, now):
    s = max(0, now - ms / 1000)
    return f"{int(s // 60)} min" if s < 3600 else f"{int(s // 3600)} h" if s < 86400 else f"{int(s // 86400)} d"


def build(db, after, now, covered=frozenset()):
    """The block and the cursor to keep. `after` None: a first run, which announces nothing.
    `covered`: the chat types Beeper Desktop already banners."""
    db.row_factory = sqlite3.Row
    names = {}

    def sender(room, contact):
        if room not in names:
            names[room] = {r[0]: r[1] for r in db.execute(
                "select id, full_name from participants where room_id=?", (room,))}
        return names[room].get(contact) or "someone"

    chats = db.execute(THREADS).fetchall()
    last = {}
    for chat in chats[:SHOWN]:
        row = db.execute(f"select type, json_extract(message,'$.text') text from mx_room_messages "
                         f"where roomID=? and isSentByMe=0 and type not in ({','.join('?' * len(SKIP))}) "
                         f"order by timestamp desc limit 1", (chat["id"], *SKIP)).fetchone()
        last[chat["id"]] = words(row) if row else ""
    items = []
    for chat in chats[:SHOWN]:
        name, net = title(chat["title"]), network(chat["protocol"], chat["account"])
        items.append({
            "text": f"{name} · {last[chat['id']]}"[:90],
            "detail": ago(chat['ts'], now),
            "image": f"icons/{net}.png",
            "help": f"{chat['unread']} unread on {net}. Click: a VCX session reads the chat with you.",
            "open": {"cwd": os.path.expanduser("~/self"),
                     "prompt": f"Read my {net} chat \"{name}\" on Beeper (/messages), tell me in a few "
                               f"lines what they want from me and what I should answer."},
        })
    total = sum(1 for _ in chats)
    block = {"title": "Messages", "tint": "#3E6FB0",
             "groups": [{"title": f"{total} unread chat{'s' if total != 1 else ''}", "items": items}]}

    newest = db.execute("select max(timestamp) from mx_room_messages").fetchone()[0] or 0
    if after is None:
        return block, newest
    cutoff = int((now - GRACE) * 1000)
    fresh = db.execute(INCOMING, (*SKIP, after, cutoff)).fetchall()
    if covered:
        kinds = {}
        for r in fresh:
            if r["room"] not in kinds:
                row = db.execute("select json_extract(thread,'$.type') from threads where threadID=?",
                                 (r["room"],)).fetchone()
                kinds[r["room"]] = row[0] if row else None
        fresh = [r for r in fresh if kinds[r["room"]] not in covered]
    if fresh:
        rooms = {r["id"]: r for r in chats}
        def where(room):
            r = rooms.get(room)
            return (title(r["title"]), network(r["protocol"], r["account"])) if r else (None, None)
        by_room = {}
        for r in fresh:
            by_room.setdefault(r["room"], []).append(r)
        if len(by_room) == 1:
            room, rows = next(iter(by_room.items()))
            name, net = where(room)
            who = sender(room, rows[-1]["sender"])
            head = f"{who}" + (f" in {name}" if name and name != who else "") + (f" · {net}" if net else "")
            body = words(rows[-1]) if len(rows) == 1 else f"{len(rows)} messages, last: {words(rows[-1])}"
        else:
            head = f"{len(fresh)} new messages"
            body = ", ".join(dict.fromkeys(where(room)[0] or sender(room, rows[-1]["sender"])
                                           for room, rows in reversed(list(by_room.items()))))
        block["notify"] = [{"id": fresh[-1]["id"], "title": head, "body": body[:200]}]
    return block, max(after, min(newest, cutoff))


def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def main():
    after = None
    try:
        with open(CURSOR) as f:
            after = json.load(f)["after"]
    except (OSError, ValueError, KeyError):
        pass
    with tempfile.TemporaryDirectory() as tmp:
        for ext in ("", "-wal", "-shm"):
            if os.path.exists(SRC + ext):
                shutil.copy2(SRC + ext, os.path.join(tmp, "index.db" + ext))
        db = sqlite3.connect(os.path.join(tmp, "index.db"))
        block, cursor = build(db, after, time.time(), beeper_covers())
        db.close()
    # The notice goes once: a block rewritten next minute without it is what Fleet expects.
    previous = None
    try:
        with open(OUT) as f:
            previous = json.load(f)
    except (OSError, ValueError):
        pass
    icons = os.path.join(os.path.dirname(OUT), "icons")
    os.makedirs(icons, exist_ok=True)
    for name in os.listdir(ICONS):
        if not os.path.exists(os.path.join(icons, name)):
            shutil.copy2(os.path.join(ICONS, name), icons)
    if block != previous:
        write(OUT, block)
    write(CURSOR, {"after": cursor})


def test():
    db = sqlite3.connect(":memory:")
    db.executescript("""
        create table threads (threadID, accountID, thread, timestamp);
        create table participants (room_id, id, full_name, is_self, is_network_bot);
        create table mx_room_messages (eventID, roomID, timestamp, type, senderContactID, isSentByMe,
                                       shouldNotify, isDeleted, message, seenByMeAt);""")
    now = 1_800_000_000
    def thread(room, name, unread, ts, proto, kind="single"):
        db.execute("insert into threads values (?,?,?,?)", (room, "whatsapp", json.dumps(
            {"title": name, "unreadCount": unread, "type": kind, "extra": {"protocol": proto}}), ts))
    def msg(eid, room, ts, text, me=0, notify=1, kind="TEXT", seen=None):
        db.execute("insert into mx_room_messages values (?,?,?,?,?,?,?,?,?,?)",
                   (eid, room, ts, kind, "c1", me, notify, 0, json.dumps({"text": text}), seen))
    thread("!a", "Mat", 2, (now - 120) * 1000, "mautrix-whatsapp")
    thread("!b", "+33 6 12 34 56 78", 1, (now - 7200) * 1000, "mautrix-whatsapp")
    thread("!c", "Old", 0, (now - 9000) * 1000, "teams")
    db.execute("insert into participants values ('!a','c1','Mat',0,0)")
    msg("e1", "!a", (now - 200) * 1000, "hello")
    msg("e2", "!a", (now - 120) * 1000, "are you there?")
    msg("e3", "!b", (now - 7200) * 1000, "note")
    msg("e4", "!a", (now - 100) * 1000, "mine", me=1)
    msg("e5", "!c", (now - 90) * 1000, "muted", notify=0)

    block, cursor = build(db, None, now)
    assert "notify" not in block, "a first run announces nothing"
    assert cursor == (now - 90) * 1000
    items = block["groups"][0]["items"]
    assert block["groups"][0]["title"] == "2 unread chats", block
    assert items[0]["text"] == "Mat · are you there?", items[0]
    assert items[0]["detail"] == "2 min", items[0]
    assert items[0]["image"] == "icons/whatsapp.png", items[0]
    assert all(os.path.exists(os.path.join(ICONS, i["image"][6:])) for i in items), "an icon per network"
    assert items[1]["text"].startswith("Note to self"), "a phone number never shows"
    assert "Mat" in items[0]["open"]["prompt"]

    block, _ = build(db, (now - 150) * 1000, now)
    assert block["notify"] == [{"id": "e2", "title": "Mat · whatsapp", "body": "are you there?"}], block["notify"]
    block, _ = build(db, (now - 250) * 1000, now)
    assert block["notify"][0]["body"] == "2 messages, last: are you there?", block["notify"]
    block, _ = build(db, (now - 50) * 1000, now)
    assert "notify" not in block, "mine and muted ones say nothing"
    block, _ = build(db, (now - 150) * 1000, now, {"single", "group"})
    assert "notify" not in block, "Beeper Desktop banners it, Fleet does not"
    block, _ = build(db, (now - 150) * 1000, now, {"group"})
    assert block["notify"][0]["id"] == "e2", "Beeper's DM banners are off, Fleet speaks"
    msg("e6", "!a", (now - 60) * 1000, "read on the phone", seen=(now - 55) * 1000)
    block, _ = build(db, (now - 80) * 1000, now)
    assert "notify" not in block, "a message he read elsewhere says nothing"
    msg("e7", "!a", (now - 10) * 1000, "just now")
    block, cursor = build(db, (now - 80) * 1000, now)
    assert "notify" not in block and cursor == (now - GRACE) * 1000, "a message within the grace waits"
    block, _ = build(db, cursor, now + GRACE)
    assert block["notify"][0]["id"] == "e7", "still unread after the grace: the banner comes"
    print("messages.py: all good")


if __name__ == "__main__":
    test() if "--test" in sys.argv else main()
