#!/bin/bash
# Draft release notes input: every PR squash-merged between two refs, grouped
# into changelog sections from its labels. The Technical Writer rewrites the
# entries in user-facing language.
#
# Usage: release_changes.sh [from-ref] [to-ref]
#   defaults: from = latest v* tag (or the first commit), to = origin/main
source "$(dirname "$0")/lib/common.sh"
require git gh jq

git fetch -q --tags origin main
from=${1:-$(git describe --tags --abbrev=0 --match 'v*' origin/main 2>/dev/null || git rev-list --max-parents=0 origin/main)}
to=${2:-origin/main}

added="" changed="" fixed="" security="" breaking=""
for pr in $(git log --format=%s "$from..$to" | grep -oE '\(#[0-9]+\)$' | tr -dc '0-9\n'); do
  info=$(gh pr view "$pr" --json number,title,labels,url)
  line="- $(jq -r .title <<<"$info") ([#$pr]($(jq -r .url <<<"$info")))"
  labels=$(jq -r '.labels[].name' <<<"$info")
  title=$(jq -r .title <<<"$info" | tr '[:upper:]' '[:lower:]')
  if grep -qx breaking <<<"$labels"; then breaking+="$line"$'\n'
  elif grep -qE '^(security|security:failed)$' <<<"$labels" || [[ $title == *security* ]]; then security+="$line"$'\n'
  elif grep -qE '^(bug:production|bug)$' <<<"$labels" || [[ $title == fix* ]]; then fixed+="$line"$'\n'
  elif grep -qE '^(dependencies|documentation)$' <<<"$labels" || [[ $title == deps* ]]; then changed+="$line"$'\n'
  else added+="$line"$'\n'
  fi
done

echo "## Changes since $from"
for section in Breaking Added Changed Fixed Security; do
  lower=$(printf '%s' "$section" | tr '[:upper:]' '[:lower:]')
  body=${!lower}
  [[ -n $body ]] && printf '\n### %s\n%s' "$section" "$body"
done
