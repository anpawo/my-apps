#!/usr/bin/env python3
"""Fleet's MESSAGES block, from Beeper Server's local index (read on a copy, never written).

Writes ~/.local/state/fleet/blocks/messages.json: the three chats with unread messages heard from
last, each a click away from a VCX session that reads it. No banners: one-text pings for messages.
Run every 10 s by the fleet.messages LaunchAgent.

  messages.py            one run
  messages.py --test     the self-check, on a made-up index
"""
import json, os, shutil, sqlite3, sys, tempfile, time

SRC = os.path.expanduser("~/.beeper/profiles/server/background/index.db")
OUT = os.path.expanduser("~/.local/state/fleet/blocks/messages.json")
# Each network's icon, copied beside the block: Fleet reads pictures from its blocks folder.
ICONS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
SHOWN = 3
SKIP = ("HIDDEN", "REACTION", "MEMBERSHIP", "NOTICE")

THREADS = """
select threadID id, accountID account, timestamp ts,
       coalesce(nullif(json_extract(thread,'$.title'), ''),
                (select group_concat(full_name, ', ') from participants p where p.room_id = threadID
                 and not coalesce(p.is_self, 0) and not coalesce(p.is_network_bot, 0)), '') title,
       coalesce(json_extract(thread,'$.unreadCount'), 0) unread,
       json_extract(thread,'$.extra.protocol') protocol
from threads where accountID not like '$%' and json_extract(thread,'$.unreadCount') > 0
order by timestamp desc"""


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


def ago(ms, now):
    s = max(0, now - ms / 1000)
    return f"{int(s // 60)} min" if s < 3600 else f"{int(s // 3600)} h" if s < 86400 else f"{int(s // 86400)} d"


def build(db, now):
    db.row_factory = sqlite3.Row
    chats = db.execute(THREADS).fetchall()
    last = {}
    for chat in chats:
        row = db.execute(f"select type, timestamp ts, json_extract(message,'$.text') text from mx_room_messages "
                         f"where roomID=? and isSentByMe=0 and seenByMeAt is null and not isDeleted "
                         f"and type not in ({','.join('?' * len(SKIP))}) "
                         f"order by timestamp desc limit 1", (chat["id"], *SKIP)).fetchone()
        if row:
            last[chat["id"]] = row
    chats = sorted((chat for chat in chats if chat["id"] in last),
                   key=lambda chat: last[chat["id"]]["ts"], reverse=True)
    items = []
    for chat in chats[:SHOWN]:
        name, net = title(chat["title"]), network(chat["protocol"], chat["account"])
        items.append({
            "text": f"{name} · {words(last[chat['id']])}"[:90],
            "detail": ago(last[chat['id']]['ts'], now),
            "image": f"icons/{net}.png",
            "help": f"{chat['unread']} unread on {net}. Click: a VCX session reads the chat with you.",
            "open": {"cwd": os.path.expanduser("~/self"),
                     "prompt": f"Read my {net} chat \"{name}\" on Beeper (/messages), tell me in a few "
                               f"lines what they want from me and what I should answer."},
        })
    total = sum(1 for _ in chats)
    return {"title": "Messages", "tint": "#3E6FB0",
            "groups": [{"title": f"{total} unread chat{'s' if total != 1 else ''}", "items": items}]}


def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        for ext in ("", "-wal", "-shm"):
            if os.path.exists(SRC + ext):
                shutil.copy2(SRC + ext, os.path.join(tmp, "index.db" + ext))
        db = sqlite3.connect(os.path.join(tmp, "index.db"))
        block = build(db, time.time())
        db.close()
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

    block = build(db, now)
    assert "notify" not in block, "Fleet never banners a message: one-text does"
    items = block["groups"][0]["items"]
    assert block["groups"][0]["title"] == "2 unread chats", block
    assert items[0]["text"] == "Mat · are you there?", items[0]
    assert items[0]["detail"] == "2 min", items[0]
    assert items[0]["image"] == "icons/whatsapp.png", items[0]
    assert all(os.path.exists(os.path.join(ICONS, i["image"][6:])) for i in items), "an icon per network"
    assert items[1]["text"].startswith("Note to self"), "a phone number never shows"
    assert "Mat" in items[0]["open"]["prompt"]

    msg("e6", "!a", (now - 60) * 1000, "read on the phone", seen=(now - 55) * 1000)
    block = build(db, now)
    assert block["groups"][0]["items"][0]["text"] == "Mat · are you there?", "preview skips read messages"
    db.execute("update mx_room_messages set isDeleted=1 where eventID='e2'")
    block = build(db, now)
    assert block["groups"][0]["items"][0]["text"] == "Mat · hello", "preview skips deleted messages"
    for i in range(4):
        room = f"!read{i}"
        thread(room, "Read chat", 1, now * 1000, "instagram")
        msg(f"read{i}", room, now * 1000, "already read", seen=now * 1000)
    thread("!d", "Unread", 1, (now - 8000) * 1000, "instagram")
    msg("e8", "!d", (now - 300) * 1000, "still unread")
    block = build(db, now)
    assert [i["text"] for i in block["groups"][0]["items"]] == [
        "Mat · hello", "Unread · still unread", "Note to self · note"], "three latest unread messages, not stale chat timestamps"
    assert block["groups"][0]["title"] == "3 unread chats", "read-only chats do not count"
    db.execute("update threads set thread=json_set(thread,'$.unreadCount',0) where threadID='!a'")
    block = build(db, now)
    assert all(not i["text"].startswith("Mat") for i in block["groups"][0]["items"])
    print("messages.py: all good")


if __name__ == "__main__":
    test() if "--test" in sys.argv else main()
