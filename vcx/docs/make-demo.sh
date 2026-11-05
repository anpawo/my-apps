#!/usr/bin/env bash
# Draws docs/demo.gif again: the app renders each frame offscreen (`--render-demo`) on a made-up session, and ffmpeg
# makes them one GIF on a single palette, each frame storing only the rectangle that changed.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
frames=$(mktemp -d)
trap 'rm -rf "$frames"' EXIT
.build/debug/VCX --render-demo "$frames"
ffmpeg -v error -y -f concat -safe 0 -i "$frames/list.txt" -fps_mode vfr \
  -vf "scale=1280:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
  -loop 0 docs/demo.gif
echo "==> docs/demo.gif"
