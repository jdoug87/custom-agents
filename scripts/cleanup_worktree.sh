#!/bin/bash
# Remove an agent worktree and its per-worktree databases.
# Refuses to remove a worktree with uncommitted or unpushed work unless --force.
#
# Usage: cleanup_worktree.sh <key> [--force]
#   key is the directory name under WORKTREE_ROOT, e.g. issue-12, pr-42-qa, merge-master
source "$(dirname "$0")/lib/common.sh"
require git

[[ $# -ge 1 && $1 =~ ^[a-z0-9-]+$ ]] || die "usage: $(basename "$0") <key> [--force]"
key=$1 force=${2:-}
[[ -z $force || $force == --force ]] || die "unknown option: $force"
path="$WORKTREE_ROOT/$key"
[[ -d $path ]] || { log "no worktree at $path"; exit 0; }

if [[ $force != --force ]]; then
  [[ -z $(git -C "$path" status --porcelain) ]] || die "$path has uncommitted changes (use --force to discard)"
  if git -C "$path" symbolic-ref -q HEAD >/dev/null; then
    upstream=$(git -C "$path" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)
    if [[ -z $upstream || -n $(git -C "$path" log --oneline "$upstream..HEAD" 2>/dev/null) ]]; then
      die "$path has commits that aren't pushed (use --force to discard)"
    fi
  fi
fi

# Drop only this worktree's databases (dev, test, and parallel test workers).
suffix=$(db_suffix "$key")
base=$(db_base)
if [[ -n $base ]] && command -v psql >/dev/null 2>&1; then
  for db in $(psql -d postgres -Atc \
      "select datname from pg_database where datname like '${base}_%$suffix' or datname like '${base}_%$suffix-%'"); do
    case $db in
      "${base}_development$suffix"|"${base}_test$suffix"|"${base}_test$suffix"-*)
        dropdb --if-exists "$db" && log "dropped database $db" ;;
    esac
  done
fi

git -C "$APP_REPO" worktree remove ${force:+--force} "$path"
git -C "$APP_REPO" worktree prune
log "removed worktree $key"
