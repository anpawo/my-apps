#!/usr/bin/env bash
# Draws docs/demo.gif again: Fleet renders each frame offscreen (`--render-demo`) on an invented
# fleet and side columns, ffmpeg crops the empty top and bottom of the 1512x1100 layout and makes them one
# GIF on a single palette, each frame storing only the rectangle that changed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
.build/release/Fleet --render-demo "$frames" --fake 3,2,1,1/2,1 --live
ffmpeg -v error -y -f concat -safe 0 -i "$frames/list.txt" -fps_mode vfr \
  -vf "crop=3024:1540:0:160,scale=1512:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/demo.gif
echo "==> docs/demo.gif"
