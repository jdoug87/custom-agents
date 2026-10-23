#!/bin/bash
# Compare screenshots against baselines with ImageMagick and write diff images
# plus a Markdown table. Files are matched by name.
# Exit 0 = every screen within threshold, 1 = at least one screen over it.
#
# Usage: visual_diff.sh <baseline-dir> <current-dir> [out-dir] [threshold-percent]
#   defaults: out-dir tmp/visual, threshold 0.5
# Tools: ImageMagick 7 (`brew install imagemagick`)
source "$(dirname "$0")/lib/common.sh"
require magick

[[ $# -ge 2 ]] || die "usage: $(basename "$0") <baseline-dir> <current-dir> [out-dir] [threshold-percent]"
base=$1 cur=$2 out=${3:-tmp/visual} threshold=${4:-0.5}
mkdir -p "$out"
report="$out/report.md"
over=0

{
  echo "| Screen | Diff % | Result |"
  echo "| --- | --- | --- |"
} >"$report"

for img in "$cur"/*.png; do
  [[ -e $img ]] || die "no PNGs in $cur"
  name=$(basename "$img")
  if [[ ! -f $base/$name ]]; then
    echo "| $name | — | new (no baseline) |" >>"$report"
    continue
  fi
  if [[ $(magick identify -format '%wx%h' "$base/$name") != $(magick identify -format '%wx%h' "$img") ]]; then
    echo "| $name | 100 | **size changed** |" >>"$report"
    over=1
    continue
  fi
  # AE = count of differing pixels (with a small fuzz for antialiasing); compare exits 1 when images differ.
  pixels=$(magick compare -metric AE -fuzz 2% "$base/$name" "$img" "$out/diff-$name" 2>&1 >/dev/null || true)
  total=$(magick identify -format '%[fx:w*h]' "$img")
  pct=$(awk -v p="${pixels%% *}" -v t="$total" 'BEGIN { printf "%.3f", (p / t) * 100 }')
  if awk -v p="$pct" -v t="$threshold" 'BEGIN { exit !(p > t) }'; then
    echo "| $name | $pct | **over threshold** |" >>"$report"
    over=1
  else
    echo "| $name | $pct | ok |" >>"$report"
    rm -f "$out/diff-$name"
  fi
done

for img in "$base"/*.png; do
  [[ -e $img && ! -f $cur/$(basename "$img") ]] && echo "| $(basename "$img") | — | missing in current run |" >>"$report"
done

cat "$report"
exit $over
