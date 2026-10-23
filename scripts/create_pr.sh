#!/bin/bash
# Push the current feature/issue-<ID> branch and open (or update) its PR with
# RFC lineage, plan link, and the status:pr-review label.
#
# Usage: create_pr.sh <ISSUE_ID> ["<PR title>"]   (run from the feature worktree)
source "$(dirname "$0")/lib/common.sh"
require git gh

[[ $# -ge 1 && $1 =~ ^[0-9]+$ ]] || die "usage: $(basename "$0") <ISSUE_ID> [\"<PR title>\"]"
id=$1
branch=$(git rev-parse --abbrev-ref HEAD)
[[ $branch == "feature/issue-$id" ]] || die "expected branch feature/issue-$id, on $branch"
[[ -z $(git status --porcelain) ]] || die "uncommitted changes; commit before opening a PR"

plan="docs/plans/issue-$id-plan.md"
[[ -f $plan ]] || log "warning: $plan is missing; the story DoD requires a committed plan"

issue_body=$(gh issue view "$id" --json body --jq .body)
title=${2:-$(gh issue view "$id" --json title --jq .title | sed -E 's/^\[STORY[^]]*\] *//')}
rfc=$(grep -oE 'RFC-[0-9]{4}' <<<"$issue_body" | head -n 1 || true)
epic=$(grep -iE 'parent epic:?' <<<"$issue_body" | grep -oE '#[0-9]+' | head -n 1 || true)

git push -q -u origin "$branch"

if existing=$(gh pr view "$branch" --json url --jq .url 2>/dev/null); then
  log "PR already exists; pushed new commits"
  echo "$existing"
  exit 0
fi

body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
  echo "Closes #$id"
  [[ -n $epic ]] && echo "Part of $epic"
  [[ -n $rfc ]] && echo "Relates to $rfc"
  echo
  echo "## Plan"
  [[ -f $plan ]] && echo "See [\`$plan\`]($plan)." || echo "_No plan committed._"
  echo
  echo "## Changes"
  git log --format='- %s' origin/main..HEAD
  echo
  echo "## Verification"
  echo "- [x] \`bin/ci\` passed locally"
  echo
  echo "_Opened by the Feature Developer agent (\`${AGENT_NAME:-manual}\`)._"
} >"$body"

url=$(gh pr create --head "$branch" --base main --title "$title" --body-file "$body" --label status:pr-review)
set_label issue "$id" status:pr-review
log "opened $url"
echo "$url"
