#!/usr/bin/env bash
# Renders docs/report.png from docs/report.html with headless WebKit (playwright-cli), no window.
# report.html is a mock terminal session with placeholder values only; regenerate after editing it.
set -euo pipefail
cd "$(dirname "$0")"
S=firefax-demo
# WebKit here blocks the file: protocol, so hand the page over as a data: URL.
URL="data:text/html;base64,$(base64 < report.html | tr -d '\n')"
playwright-cli -s="$S" open --browser webkit "$URL" >/dev/null
playwright-cli -s="$S" resize 1040 560 >/dev/null
playwright-cli -s="$S" screenshot --filename "$PWD/report.png" --full-page --hires >/dev/null
playwright-cli -s="$S" close >/dev/null
echo "==> docs/report.png"
