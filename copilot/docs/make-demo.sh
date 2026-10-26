#!/usr/bin/env bash
# Draws docs/demo.gif again: the app renders each frame offscreen (`--render-demo`), ffmpeg makes them one GIF on a
# single palette, each frame storing only the rectangle that changed (opener's recipe).
# `--ask-again` first asks Claude about frame 001 as copilot would, to paste its answers into `Demo.answers`.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product copilot
bin="$(swift build -c release --show-bin-path)/copilot"
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
"$bin" --render-demo "$frames"
if [[ "${1:-}" == "--ask-again" ]]; then
  "$bin" --ask "$frames/001.png" "" "et si le fichier est vide ?"
  exit
fi
ffmpeg -v error -y -f concat -safe 0 -i "$frames/list.txt" -fps_mode vfr \
  -vf "scale=1440:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/demo.gif
echo "==> docs/demo.gif"
