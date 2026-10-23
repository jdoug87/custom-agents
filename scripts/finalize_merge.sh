#!/bin/bash
# Validate integration/pr-<ID> with bin/ci and, if green, squash-merge the PR.
# On failure: label the PR blocked + integration-failed, comment, and notify.
# Run from the merge-master worktree after process_merge_queue.sh.
#
# Usage: finalize_merge.sh <PR_NUMBER>
source "$(dirname "$0")/lib/common.sh"
require git gh

[[ $# -eq 1 && $1 =~ ^[0-9]+$ ]] || die "usage: $(basename "$0") <PR_NUMBER>"
pr=$1
branch="integration/pr-$pr"
[[ $(git rev-parse --abbrev-ref HEAD) == "$branch" ]] || die "expected to be on $branch"
git diff --name-only --diff-filter=U | grep -q . && die "unresolved conflicts remain"
grep -rlE '^(<<<<<<<|>>>>>>>) ' $(git diff --name-only origin/main) 2>/dev/null \
  && die "conflict markers still present in the files above"

# If the merge needed manual conflict resolution, commit it now. Those fixes
# have to be pushed to the PR branch before squash-merging.
head=$(gh pr view "$pr" --json headRefName --jq .headRefName)
resolved=0
if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  git commit -q --no-edit
  resolved=1
fi

if git diff --name-only origin/main | grep -q '^db/migrate/'; then
  log "PR has migrations; regenerating schema"
  bin/rails db:migrate >&2
  git diff --quiet db/schema.rb || { git add db/schema.rb; git commit -q -m "Regenerate db/schema.rb after integrating #$pr"; resolved=1; }
fi

mkdir -p tmp/merge
log "running bin/ci on $branch"
bin/rails db:test:prepare >/dev/null
if ! bin/ci >"tmp/merge/pr-$pr.log" 2>&1; then
  git checkout -q --detach origin/main
  git branch -q -D "$branch"
  gh_app pr edit "$pr" --add-label integration-failed >/dev/null
  "$AGENT_SCRIPTS/escalate.sh" pr "$pr" "bin/ci failed after integrating with main" \
    --log "tmp/merge/pr-$pr.log" --options "Send back to dev,Retry,Abort"
  exit 1
fi

if [[ $resolved -eq 1 ]]; then
  # Conflict fixes or schema regeneration must land on the PR branch so the
  # squash merge (and GitHub CI) include them.
  log "pushing integration fixes to $head"
  git push -q origin "HEAD:refs/heads/$head"
  log "waiting for GitHub checks on PR #$pr"
  gh pr checks "$pr" --watch --fail-fast >/dev/null || {
    "$AGENT_SCRIPTS/escalate.sh" pr "$pr" "GitHub CI failed after pushing merge-conflict fixes"; exit 1; }
fi

gh pr merge "$pr" --squash --delete-branch
for issue in $(gh pr view "$pr" --json closingIssuesReferences --jq '.closingIssuesReferences[].number'); do
  # The PR closes the issue on merge; waiting-for-deploy keeps it on the release board.
  set_label issue "$issue" waiting-for-deploy
done

git checkout -q --detach origin/main
git branch -q -D "$branch"
log "PR #$pr merged"
