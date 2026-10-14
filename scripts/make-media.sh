#!/bin/bash
# Render the README showreel: docs/media/showreel.mp4 (1280×720, 60 fps) and showreel.gif.
# Needs ffmpeg. Scenes are listed in scripts/scenes.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release >/dev/null
B=.build/release/VisualSynth
WORK=$(mktemp -d)
OUT=docs/media
mkdir -p "$OUT"
WARM=60 SECS=3 FPS=60
n=0
while IFS='|' read -r name only set mod; do
    args=(--render "$WORK/$name-last.png" --only "$only" --size 1280x720 --frames $((WARM + SECS * FPS))
          --notes --bpm 124 --frames-dir "$WORK/$name")
    [ -n "$set" ] && args+=(--set "$set")
    [ -n "$mod" ] && args+=(--mod "$mod")
    "$B" "${args[@]}" >/dev/null
    ffmpeg -nostdin -loglevel error -y -framerate $FPS -start_number $WARM -i "$WORK/$name/%05d.png" \
        -frames:v $((SECS * FPS)) -c:v libx264 -pix_fmt yuv420p -crf 27 -preset slow "$WORK/clip$n.mp4"
    # GIF clip: first 2 s, 12 fps, 480 px
    ffmpeg -nostdin -loglevel error -y -i "$WORK/clip$n.mp4" -t 2 -vf "fps=12,scale=480:-1:flags=lanczos" -c:v libx264 -crf 12 "$WORK/gif$n.mp4"
    echo "file '$WORK/gif$n.mp4'" >> "$WORK/giflist.txt"
    echo "file '$WORK/clip$n.mp4'" >> "$WORK/list.txt"
    n=$((n + 1))
    echo "rendered $name"
done < <(scripts/scenes.sh)
ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i "$WORK/list.txt" -c copy "$OUT/showreel.mp4"
ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i "$WORK/giflist.txt" \
    -vf "split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
    "$OUT/showreel.gif"
rm -rf "$WORK"
ls -lh "$OUT"
