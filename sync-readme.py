#!/usr/bin/env python3
"""Rebuilds the end of README.md: a table of every app (icon, name, one line), then each app's name and the first
picture of its README, both linking to its folder."""
import re
from pathlib import Path

root = Path(__file__).parent
START, END = "<!-- apps:start -->", "<!-- apps:end -->"
# the tables, and each app's line in its own, short enough to stay on one line: a new app needs its line
TABLES = {
    "macOS apps, reworked for my needs": {
        "alt-tab": "The ⌘Tab switcher, one tile per window with its picture.",
        "opener": "Spotlight for apps only, on ⌘Space.",
        "screenshot": "A ⌘⇧5 replacement whose file is on disk the moment you click.",
    },
    "My own apps": {
        "autocorrect": "Fixes the word you just typed, in French and in English.",
        "fleet": "Every Claude Code session on the Mac, and which ones need you.",
        "mac-guard": "Stops the processes that take the Mac down.",
        "vcx": "Vibe Code X: a native window for Claude Code, Codex and Qwen.",
        "watcher": "The answers you are waiting for, one at a time, on ⌘⌥K.",
    },
}

# folders kept as code only, shown nowhere on the page
HIDDEN = {"glance"}


def table(title, says):
    rows = [f'| <img src="{app}/docs/icon.png" width="40" alt=""> | [{app}]({app}) | {line} |' for app, line in says.items()]
    return f"#### {title}\n\n| | App | What it does |\n|:-:|---|---|\n" + "\n".join(rows)


def card(readme):
    app = readme.parent.name
    picture = re.search(r"!\[([^\]]*)\]\(([^)]+)\)", readme.read_text())
    if not picture:
        return f"### [{app}]({app})"
    alt, src = picture.groups()
    return f"### [{app}]({app})\n\n[![{alt}]({app}/{src})]({app})"


page = root / "README.md"
head, rest = page.read_text().split(START)
apps = [r for r in sorted(root.glob("*/README.md")) if not r.parent.is_symlink() and r.parent.name not in HIDDEN]
listed = [app for says in TABLES.values() for app in says]
assert sorted(listed) == [r.parent.name for r in apps], f"apps and TABLES differ: {sorted(listed)}"
assert all((root / app / "docs/icon.png").exists() for app in listed), "an app has no docs/icon.png"
tables = "\n\n".join(table(title, says) for title, says in TABLES.items())
cards = "\n\n".join(card(r) for r in apps)
page.write_text(f"{head}{START}\n{tables}\n\n{cards}\n{END}{rest.split(END)[1]}")
