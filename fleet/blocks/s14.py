#!/usr/bin/env python3
"""Fleet's S14 block: the MO mailbox as a board, from the recon site's own digest of it
(recon-v3-mr/out/site/mails.json, written by the s14.recon-v3 routine through tools/mo-digest).

Red or orange: an important thread whose last word is theirs, to answer. Amber: another thread
whose last word is theirs, maybe missed. Blue: we wrote last, waiting on them. Green: settled with
Problem fixed in the last three days. A few of each, the count in the group's name; a click opens
a VCX session in ~/self/s14 on the thread. Run every 15 minutes by the fleet.s14 LaunchAgent.

  s14.py            one run
  s14.py --test     the self-check, on a made-up digest
"""
import datetime as dt, json, os, re, sys, time

SRC = os.path.expanduser("~/self/s14/recon-v3-mr/out/site/mails.json")
OUT = os.path.expanduser("~/.local/state/fleet/blocks/s14.json")
S14 = os.path.expanduser("~/self/s14")
TINT = {"red": "#C24A3E", "orange": "#D9822B", "amber": "#B8952E", "blue": "#3E6FB0", "green": "#3C9A5F"}
PREFIX = re.compile(r"^\s*(?:(?:re|fw|fwd|tr|aw)\s*:\s*)+", re.I)


def subject(text):
    return PREFIX.sub("", text or "").strip() or "(no subject)"


def item(subj, detail, tint, state, house=""):
    who = f" from {house}" if house else ""
    return {"text": subj[:80], "detail": detail, "tint": TINT[tint],
            "help": f"{state}{who}. Click: a VCX session opens the thread.",
            "open": {"cwd": S14, "prompt": f"MO mail thread \"{subj}\"{who} ({state.lower()}): read it with "
                                           f"/mo-mail and tell me in a few lines where it stands and what to answer."}}


def days(cell):
    n = cell.get("v")
    return f"{n} d" if isinstance(n, (int, float)) else cell.get("t", "")


def group(title, rows, cap):
    return {"title": f"{title} · {len(rows)}", "items": rows[:cap]} if rows else None


def build(d, now):
    groups = []
    # From the digest's own cards: who wrote last is already decided there. The card paints every
    # row orange; how urgent each is, the People tab's red, is on the same thread's row there.
    tab = {r["key"]: r["c"][0].get("f") for s in d.get("sections", []) for g in s.get("groups", []) for b in g
           if b.get("title") == "Important mails" for r in b["table"]["rows"]}
    owe = [item(subject(r["c"][1]["t"]), days(r["c"][2]), "red" if tab.get(r.get("key")) == "red" else "orange",
                "To answer", r["c"][0]["t"]) for r in d.get("card", {}).get("table", {}).get("rows", [])
           if r.get("key") not in (d.get("settled") or {})]
    owe.sort(key=lambda i: i["tint"] != TINT["red"])
    maybe = [item(subject(r["c"][1]["t"]), days(r["c"][2]), "amber", "Last word theirs", r["c"][0]["t"])
             for r in d.get("read", {}).get("table", {}).get("rows", [])]
    waiting = [item(subject(r["c"][0]["t"]), days(r["c"][2]), "blue", "Waiting on them")
               for s in d.get("sections", []) for g in s.get("groups", []) for b in g
               if b.get("title") == "We are waiting for an answer" for r in b["table"]["rows"]]
    settled = []
    for key, at in (d.get("settled") or {}).items():
        try:
            when = dt.datetime.fromisoformat(at.replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
        if now - when < 3 * 86400:
            settled.append((when, item(subject(key.rsplit(" @ ", 1)[0]), "settled", "green", "Settled")))
    settled = [i for _, i in sorted(settled, key=lambda p: p[0], reverse=True)]
    for g in (group("To answer", owe, 3), group("Maybe missed", maybe, 2),
              group("Waiting on them", waiting, 2), group("Settled", settled, 2)):
        if g:
            groups.append(g)
    if not groups:
        groups = [{"title": "Nothing waits", "items": [{"text": "MO mail all answered", "tint": TINT["green"]}]}]
    return {"title": "S14", "tint": "#7A4FB0", "layout": "board", "groups": groups}


def main():
    try:
        with open(SRC) as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        print(f"s14.py: digest not read ({e.__class__.__name__}), block left as it was", file=sys.stderr)
        return 1
    block = build(d, time.time())
    age = time.time() - os.path.getmtime(SRC)
    if age > 36 * 3600:
        block["groups"][0]["title"] += f" (digest {int(age // 86400)} d old)"
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    try:
        with open(OUT) as f:
            if json.load(f) == block:
                return 0
    except (OSError, ValueError):
        pass
    with open(OUT + ".tmp", "w") as f:
        json.dump(block, f, ensure_ascii=False, indent=1)
    os.replace(OUT + ".tmp", OUT)
    return 0


def test():
    now = 1_800_000_000
    iso = lambda s: dt.datetime.fromtimestamp(s, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    row = lambda *cells: {"c": [dict(c) for c in cells]}
    d = {"card": {"table": {"rows": [row({"t": "BofA", "f": "orange"}, {"t": "Allocs"}, {"t": "1", "v": 1}),
                                     dict(row({"t": "GS", "f": "orange"}, {"t": "RE: Missing GU"}, {"t": "4", "v": 4}),
                                          key="gu"),
                                     dict(row({"t": "MS", "f": "orange"}, {"t": "Done one"}, {"t": "9", "v": 9}),
                                          key="weekly call @ " + iso(now - 3600))]}},
         "read": {"table": {"rows": [row({"t": "JPM", "f": "blue"}, {"t": "FW: Fees"}, {"t": "0", "v": 0})]}},
         "sections": [{"tab": "People", "groups": [[
             {"title": "Important mails", "table": {"rows": [{"key": "gu", "c": [{"t": "x", "f": "red"}]}]}},
             {"title": "We are waiting for an answer",
              "table": {"rows": [row({"t": "RE: CFD alloc", "f": "blue"}, {"t": "x"}, {"t": "2", "v": 2})]}}]]}],
         "settled": {"weekly call @ " + iso(now - 3600): iso(now - 3600), "old @ x": iso(now - 9 * 86400)}}
    b = build(d, now)
    titles = [g["title"] for g in b["groups"]]
    assert titles == ["To answer · 2", "Maybe missed · 1", "Waiting on them · 1", "Settled · 1"], titles
    first = b["groups"][0]["items"][0]
    assert (first["text"], first["detail"], first["tint"]) == ("Missing GU", "4 d", TINT["red"]), first
    assert b["groups"][0]["items"][1]["tint"] == TINT["orange"]
    assert first["open"]["cwd"] == S14 and "Missing GU" in first["open"]["prompt"] and "GS" in first["open"]["prompt"]
    assert b["groups"][2]["items"][0]["text"] == "CFD alloc"
    assert b["groups"][3]["items"][0]["text"] == "weekly call"
    assert build({}, now)["groups"][0]["title"] == "Nothing waits"
    print("s14.py: all good")


if __name__ == "__main__":
    sys.exit(test() if "--test" in sys.argv else main())
