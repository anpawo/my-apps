#!/usr/bin/env python3
"""Rebuilds the end of README.md: each app's name, then the first picture of its README, both linking to its folder."""
import re
from pathlib import Path

root = Path(__file__).parent
START, END = "<!-- apps:start -->", "<!-- apps:end -->"


def card(readme):
    app = readme.parent.name
    picture = re.search(r"!\[([^\]]*)\]\(([^)]+)\)", readme.read_text())
    if not picture:
        return f"### [{app}]({app})"
    alt, src = picture.groups()
    return f"### [{app}]({app})\n\n[![{alt}]({app}/{src})]({app})"


page = root / "README.md"
head, rest = page.read_text().split(START)
cards = "\n\n".join(card(r) for r in sorted(root.glob("*/README.md")))
page.write_text(f"{head}{START}\n{cards}\n{END}{rest.split(END)[1]}")
