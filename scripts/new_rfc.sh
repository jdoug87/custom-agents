#!/bin/bash
# Scaffold the next-numbered RFC from docs/templates/rfc-template.md on a new
# rfc/<NNNN>-<slug> branch. Run from inside an app checkout or worktree.
#
# Usage: new_rfc.sh <short-slug> "<Title>"
# Example: new_rfc.sh tenant-rate-limits "Tenant-isolated rate limiting"
source "$(dirname "$0")/lib/common.sh"

[[ $# -eq 2 && $1 =~ ^[a-z0-9-]+$ ]] || die "usage: $(basename "$0") <short-slug> \"<Title>\""
slug=$1 title=$2
repo=$(git rev-parse --show-toplevel)
mkdir -p "$repo/docs/rfcs"
template="$repo/docs/templates/rfc-template.md"
[[ -f $template ]] || die "$template not found (run custom-agents/install.sh on this repo)"

last=$(find "$repo/docs/rfcs" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.md' -exec basename {} \; \
  | sort | tail -n 1 | cut -c1-4)
num=$(printf '%04d' $((10#${last:-0} + 1)))
path="docs/rfcs/$num-$slug.md"

git -C "$repo" fetch -q origin main
git -C "$repo" checkout -q -b "rfc/$num-$slug" origin/main

sed -e "s/<XXXX>/$num/g" \
    -e "s/<Title>/$(printf '%s' "$title" | sed 's/[&/\]/\\&/g')/" \
    -e "s/<YYYY-MM-DD>/$(date +%F)/" \
    "$template" >"$repo/$path"

log "created $path on branch rfc/$num-$slug"
echo "$path"
