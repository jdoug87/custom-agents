#!/bin/bash
# Create (or refresh) an isolated git worktree of the app for one agent.
# Prints the worktree path on stdout.
#
# Usage:
#   prepare_worktree.sh issue <ID>        [--no-setup]  feature/issue-<ID> branch (new from origin/main, or existing)
#   prepare_worktree.sh pr <PR> <role>    [--no-setup]  detached at the PR head; role = qa|security|visual|design|dev|review
#   prepare_worktree.sh main <name>       [--no-setup]  detached at origin/main (merge-master, agile-pm, roadmap, ...)
#
# Detached checkouts let several agents work on the same PR at once (git forbids
# one branch in two worktrees). Agents that commit push with:
#   git push origin HEAD:refs/heads/$PR_BRANCH
#
# Each worktree gets its own databases via WORKTREE_DB_SUFFIX, which
# config/database.yml must append to the development/test database names.
source "$(dirname "$0")/lib/common.sh"
require git gh

[[ $# -ge 2 ]] || die "usage: $(basename "$0") issue <ID> | pr <PR> <role> | main <name>  [--no-setup]"
mode=$1 ref=$2 role="" setup=1
case $mode in
  pr) [[ $# -ge 3 ]] || die "pr mode needs a role"; role=$3; shift 3 ;;
  issue|main) shift 2 ;;
  *) die "unknown mode: $mode" ;;
esac
[[ ${1:-} == --no-setup ]] && setup=0

git -C "$APP_REPO" fetch -q --prune origin
mkdir -p "$WORKTREE_ROOT"

case $mode in
  issue)
    key="issue-$ref" branch="feature/issue-$ref" path="$WORKTREE_ROOT/$key"
    if [[ ! -d $path ]]; then
      if git -C "$APP_REPO" show-ref -q --verify "refs/remotes/origin/$branch"; then
        git -C "$APP_REPO" worktree add -q -B "$branch" "$path" "origin/$branch"
      else
        git -C "$APP_REPO" worktree add -q -b "$branch" "$path" origin/main
      fi
    fi
    ;;
  pr)
    key="pr-$ref-$role" path="$WORKTREE_ROOT/$key"
    branch=$(gh_app pr view "$ref" --json headRefName --jq .headRefName)
    git -C "$APP_REPO" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch"
    if [[ -d $path ]]; then
      [[ -z $(git -C "$path" status --porcelain) ]] || die "$path has uncommitted changes; not refreshing"
      git -C "$path" checkout -q --detach "origin/$branch"
    else
      git -C "$APP_REPO" worktree add -q --detach "$path" "origin/$branch"
    fi
    ;;
  main)
    key="$ref" path="$WORKTREE_ROOT/$key"
    if [[ -d $path ]]; then
      [[ -z $(git -C "$path" status --porcelain) ]] || die "$path has uncommitted changes; not refreshing"
      git -C "$path" checkout -q --detach origin/main
    else
      git -C "$APP_REPO" worktree add -q --detach "$path" origin/main
    fi
    ;;
esac

suffix=$(db_suffix "$key")
if [[ $setup -eq 1 ]]; then
  if ! grep -q WORKTREE_DB_SUFFIX "$path/config/database.yml"; then
    log "warning: config/database.yml ignores WORKTREE_DB_SUFFIX; this worktree will share databases with others"
  fi
  log "running bin/setup in $path (db suffix $suffix)"
  (cd "$path" && WORKTREE_DB_SUFFIX="$suffix" bin/setup --skip-server >&2)
fi

echo "$path"
