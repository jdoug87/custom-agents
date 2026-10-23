#!/bin/bash
# Pick the next eligible PR and merge it into a fresh integration/pr-<ID> branch.
# Run from the merge-master worktree.
#
# Usage: process_merge_queue.sh [PR_NUMBER]
# Exit codes:
#   0  clean merge staged; next run finalize_merge.sh <ID> (PR number printed on stdout)
#   2  merge conflict; resolve markers, `git add`, then run finalize_merge.sh <ID>
#   3  queue empty
source "$(dirname "$0")/lib/common.sh"
require git gh jq

if [[ $# -ge 1 ]]; then
  pr=$1
else
  # Eligible: qa:passed + status:pr-review, no failed or blocking labels.
  # Order: priority:high, medium, low, unlabeled; then oldest first.
  pr=$(gh pr list --state open --label qa:passed --label status:pr-review --limit 100 \
        --json number,createdAt,labels,isDraft --jq '
    map(select(.isDraft | not)
        | (.labels | map(.name)) as $l
        | select(($l | map(select(. == "status:blocked" or . == "rework:in-progress" or . == "integration-failed"
                                 or . == "security:failed" or . == "visual:failed"
                                 or . == "design:changes-requested")) | length) == 0)
        | . + {rank: (if ($l | index("priority:high")) then 0 elif ($l | index("priority:medium")) then 1
                      elif ($l | index("priority:low")) then 2 else 3 end)})
    | sort_by(.rank, .createdAt) | .[0].number // empty')
fi
[[ -n $pr ]] || { log "no PRs pending merge"; exit 3; }

head=$(gh pr view "$pr" --json headRefName --jq .headRefName)
log "processing PR #$pr ($head)"

[[ -z $(git status --porcelain) ]] || die "worktree is dirty; clean it before processing the queue"
git fetch -q origin main "+refs/heads/$head:refs/remotes/origin/$head"
git checkout -q -B "integration/pr-$pr" origin/main

if ! git merge --no-ff --no-edit "origin/$head" >/dev/null 2>&1; then
  conflicts=$(git diff --name-only --diff-filter=U)
  log "merge conflict on PR #$pr in:"
  printf '  %s\n' $conflicts >&2
  if grep -qx 'db/schema.rb' <<<"$conflicts"; then
    log "db/schema.rb conflicts: take main's version, run bin/rails db:migrate, never hand-merge"
  fi
  echo "$pr"
  exit 2
fi

log "clean merge staged on integration/pr-$pr; run finalize_merge.sh $pr"
echo "$pr"
