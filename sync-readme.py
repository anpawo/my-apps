#!/usr/bin/env python3
"""Rebuilds the end of README.md: a table of every app (icon, name, one line), then each app's name and the first
picture of its README, both linking to its folder."""
import re
from pathlib import Path

root = Path(__file__).parent
START, END = "<!-- apps:start -->", "<!-- apps:end -->"
# the table's line for each app, short enough to stay on one line: a new app needs its own
SAYS = {
    "alt-tab": "The ⌘Tab switcher, one tile per window with its picture.",
    "autocorrect": "Fixes the word you just typed, in French and in English.",
    "fleet": "Every Claude Code session on the Mac, and which ones need you.",
    "glance": "Unfinished: ask Claude about what is on the screen.",
    "mac-guard": "Stops the processes that take the Mac down.",
    "opener": "Spotlight for apps only, on ⌘Space.",
    "screenshot": "A ⌘⇧5 replacement whose file is on disk the moment you click.",
    "vcx": "Vibe Code X: a native window for Claude Code, Codex and Qwen.",
    "watcher": "The answers you are waiting for, one at a time, on ⌘⌥K.",
}


def row(readme):
    app = readme.parent.name
    icon = f'<img src="{app}/docs/icon.png" width="32" alt="">' if (readme.parent / "docs/icon.png").exists() else ""
    return f"| {icon} | [{app}]({app}) | {SAYS[app]} |"


def card(readme):
    app = readme.parent.name
    picture = re.search(r"!\[([^\]]*)\]\(([^)]+)\)", readme.read_text())
    if not picture:
        return f"### [{app}]({app})"
    alt, src = picture.groups()
    return f"### [{app}]({app})\n\n[![{alt}]({app}/{src})]({app})"


page = root / "README.md"
head, rest = page.read_text().split(START)
apps = [r for r in sorted(root.glob("*/README.md")) if not r.parent.is_symlink()]
table = "| | App | What it does |\n|:-:|---|---|\n" + "\n".join(row(r) for r in apps)
cards = "\n\n".join(card(r) for r in apps)
page.write_text(f"{head}{START}\n{table}\n\n{cards}\n{END}{rest.split(END)[1]}")
