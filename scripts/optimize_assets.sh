#!/bin/bash
# Optimize static image assets and enforce the size budgets from asset-generator:
# icons < 2 KB, illustrations (SVG) < 15 KB, raster images < 200 KB.
# Exit 0 = all within budget, 1 = over budget.
#
# Usage: optimize_assets.sh [file-or-dir ...]   (default: app/assets/images)
# Tools: SVGO via npx (downloaded on demand, not added to package.json),
#        cwebp (`brew install webp`) for PNG/JPEG → WebP.
source "$(dirname "$0")/lib/common.sh"

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(app/assets/images)

files=$(find "${targets[@]}" -type f \( -iname '*.svg' -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \))
[[ -n $files ]] || { log "no images found"; exit 0; }

svgs=$(grep -iE '\.svg$' <<<"$files" || true)
if [[ -n $svgs ]]; then
  log "optimizing $(wc -l <<<"$svgs" | tr -d ' ') SVG(s) with svgo"
  # shellcheck disable=SC2086
  npx --yes svgo@3 --multipass --quiet $svgs
fi

if command -v cwebp >/dev/null 2>&1; then
  while IFS= read -r img; do
    [[ -z $img ]] && continue
    webp="${img%.*}.webp"
    [[ -f $webp && $webp -nt $img ]] && continue
    cwebp -quiet -q 82 "$img" -o "$webp" && log "wrote $webp"
  done < <(grep -iE '\.(png|jpe?g)$' <<<"$files" || true)
else
  log "cwebp not installed; skipping WebP conversion (brew install webp)"
fi

over=0
while IFS= read -r f; do
  [[ -z $f ]] && continue
  size=$(wc -c <"$f" | tr -d ' ')
  case $f in
    */icons/*.svg) limit=2048 ;;
    *.svg|*.SVG) limit=15360 ;;
    *) limit=204800 ;;
  esac
  if [[ $size -gt $limit ]]; then
    log "over budget: $f ($((size / 1024)) KB > $((limit / 1024)) KB)"
    over=1
  fi
done < <(find "${targets[@]}" -type f \( -iname '*.svg' -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \))

exit $over
