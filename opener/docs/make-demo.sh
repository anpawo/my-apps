#!/usr/bin/env bash
# Draws docs/demo.gif again: the app renders each frame offscreen (`--render-demo`), ffmpeg
# makes them one GIF on a single palette, each frame storing only the rectangle that changed.
# An ordered dither: the wallpaper bands without one, and a pattern fixed to the pixel keeps
# the unchanged parts of each frame out of it.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product opener
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
"$(swift build -c release --show-bin-path)/opener" --render-demo "$frames"
ffmpeg -v error -y -f concat -safe 0 -i "$frames/list.txt" -fps_mode vfr \
  -vf "scale=1440:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/demo.gif
echo "==> docs/demo.gif"
