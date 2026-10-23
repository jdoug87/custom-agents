#!/bin/bash
# Turn a Playwright screen recording (.webm) into a shareable MP4, optionally with
# a voiceover. Narration can be an audio file or a text script spoken with macOS `say`.
#
# Usage: record_walkthrough.sh <recording.webm> <output.mp4> [--audio narration.mp3 | --script narration.txt]
# Tools: ffmpeg (`brew install ffmpeg`)
source "$(dirname "$0")/lib/common.sh"
require ffmpeg

[[ $# -ge 2 ]] || die "usage: $(basename "$0") <recording.webm> <output.mp4> [--audio file | --script file]"
input=$1 output=$2; shift 2
audio=""
case ${1:-} in
  --audio) audio=$2 ;;
  --script)
    require say
    audio=$(mktemp -t narration).aiff
    trap 'rm -f "$audio"' EXIT
    say -o "$audio" -f "$2"
    ;;
  "") ;;
  *) die "unknown option: $1" ;;
esac
[[ -f $input ]] || die "recording not found: $input"
mkdir -p "$(dirname "$output")"

video_opts=(-c:v libx264 -pix_fmt yuv420p -preset veryfast -crf 23 -movflags +faststart
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2")
if [[ -n $audio ]]; then
  ffmpeg -y -loglevel error -i "$input" -i "$audio" "${video_opts[@]}" -c:a aac -b:a 128k -shortest "$output"
else
  ffmpeg -y -loglevel error -i "$input" "${video_opts[@]}" -an "$output"
fi
log "walkthrough written to $output ($(du -h "$output" | cut -f1))"
