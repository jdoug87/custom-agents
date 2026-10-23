#!/bin/bash
# Launch the Design Review Committee (security, perf, dx reviewers) in parallel
# against an RFC pull request. They share one read-only worktree of the PR.
#
# Usage: trigger_rfc_swarm.sh <PR_NUMBER>
source "$(dirname "$0")/lib/common.sh"

[[ $# -eq 1 && $1 =~ ^[0-9]+$ ]] || die "usage: $(basename "$0") <PR_NUMBER>"
pr=$1

wt=$("$AGENT_SCRIPTS/prepare_worktree.sh" pr "$pr" review --no-setup)
gh_app pr edit "$pr" --add-label rfc >/dev/null
set_label pr "$pr" rfc:in-review

for persona in security perf dx; do
  spawn_agent "review-$persona-$pr" "$persona-reviewer" "$wt" \
    "Review RFC PR #$pr. Post your structured critique as a PR review, then stop." || true
done
