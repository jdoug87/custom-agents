#!/bin/bash
# Claim a ready story for a Feature Developer: verify it's ready and unblocked,
# then mark it in-progress and assign it. Exits non-zero if it can't be claimed.
#
# Usage: claim_issue.sh <ISSUE_ID> [--branch]
#   --branch  also create feature/issue-<ID> from origin/main in the current checkout
#             (for manual runs; the orchestrator creates a worktree instead)
#
# Note: all agents share one GitHub account, so the assignee can't tell workers apart.
# The single orchestrator is the real lock; the label re-check guards against races.
source "$(dirname "$0")/lib/common.sh"
require gh

[[ $# -ge 1 && $1 =~ ^[0-9]+$ ]] || die "usage: $(basename "$0") <ISSUE_ID> [--branch]"
id=$1

labels=$(current_labels "$id")
grep -qx 'status:ready-for-agent' <<<"$labels" || die "#$id is not labeled status:ready-for-agent"
grep -qx 'in-progress' <<<"$labels" && die "#$id is already in progress"

blockers=$(open_blockers "$id")
[[ -z $blockers ]] || die "#$id is blocked by open issue(s): $(echo $blockers | sed 's/[0-9]*/#&/g')"

set_label issue "$id" in-progress
gh_app issue edit "$id" --add-assignee "@me" >/dev/null

labels=$(current_labels "$id")
if grep -qx 'status:ready-for-agent' <<<"$labels" || ! grep -qx 'in-progress' <<<"$labels"; then
  die "claim of #$id did not stick; another worker may have it"
fi

if [[ ${2:-} == --branch ]]; then
  git fetch -q origin main
  git checkout -q -b "feature/issue-$id" origin/main
  log "created branch feature/issue-$id"
fi
log "claimed #$id"
