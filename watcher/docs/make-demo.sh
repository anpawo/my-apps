#!/usr/bin/env bash
# Draws docs/demo.gif again: the app renders each frame offscreen (`--render-demo`) on made-up lines
# and checks, ffmpeg makes them one GIF on a single palette, each frame storing only the rectangle
# that changed. An ordered dither: the wallpaper bands without one, and a pattern fixed to the pixel
# keeps the unchanged parts of each frame out of it.
set -euo pipefail
cd "$(dirname "$0")/.."
# The app's bundle, not the bare binary: the watch list's logos are its resources.
./build.sh
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
dist/watcher.app/Contents/MacOS/watcher --render-demo "$frames"
ffmpeg -v error -y -f concat -safe 0 -i "$frames/list.txt" -fps_mode vfr \
  -vf "scale=1440:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/demo.gif
echo "==> docs/demo.gif"
