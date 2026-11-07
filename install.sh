#!/bin/bash
# Install these agents, scripts, and templates into a target repo:
#
#   agents/*.md       → <target>/.claude/agents/    (claude --agent finds them)
#   scripts/          → <target>/.claude/scripts/   (exact mirror; removed files are removed)
#   templates/*.md    → <target>/docs/templates/    (agile-pm and rfc-author read these)
#
# It also seeds, only when missing: <target>/AGENTS.md (from scaffold/AGENTS.md)
# and the docs/ folders the agents write to (each new one gets a .gitkeep).
#
# These are copies, not symlinks, so commit them in the target repo and every
# checkout and worktree has them. Edit the originals here and re-run this script;
# use --check to see whether a target has drifted.
#
# Usage: install.sh <target-repo> [--check]
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd -P)
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
command -v rsync >/dev/null || die "rsync is required"

check=0 target=""
for arg in "$@"; do
  case $arg in
    --check) check=1 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) [[ -z $target ]] || die "only one target repo at a time"; target=$arg ;;
  esac
done
[[ -n $target ]] || die "usage: $(basename "$0") <target-repo> [--check]"
[[ -d $target ]] || die "target not found: $target"
target=$(cd "$target" && pwd -P)
[[ $target != "$SRC" ]] || die "the target must be a different repo than this one"
git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || die "$target is not a git repository"
[[ $(git -C "$target" rev-parse --show-toplevel) == "$target" ]] || die "$target is not the root of its git repository"

# pairs of "source|destination"
targets=("$SRC/agents|$target/.claude/agents"
  "$SRC/scripts|$target/.claude/scripts"
  "$SRC/templates|$target/docs/templates")

if [[ $check -eq 1 ]]; then
  drift=0
  for t in "${targets[@]}"; do
    src=${t%%|*} dst=${t#*|}
    # Only files we install count; anything else already in the destination is left alone.
    out=$(diff -rq -x __pycache__ "$src" "$dst" 2>&1 | grep -v "^Only in $dst" || true)
    if [[ -n $out ]]; then echo "$out" >&2; drift=1; fi
  done
  [[ $drift -eq 0 ]] && log "$target is in sync" || log "drift found (above); re-run install.sh"
  exit $drift
fi

for t in "${targets[@]}"; do
  dst=${t#*|}
  if [[ -L $dst ]]; then
    rm "$dst"  # removes the link only, never the folder it pointed to
    log "replaced symlink $dst with a real directory"
  fi
  mkdir -p "$dst"
done

# Agents and templates: copy ours, leave any other files in those folders alone.
cp -p "$SRC"/agents/*.md "$target/.claude/agents/"
cp -p "$SRC"/templates/*.md "$target/docs/templates/"
# Scripts: an exact mirror, so deleted or renamed scripts don't linger.
rsync -a --delete --exclude __pycache__ "$SRC/scripts/" "$target/.claude/scripts/"

# Seed what the agents expect but never overwrite: AGENTS.md and the docs/ folders they write to.
if [[ ! -f $target/AGENTS.md ]]; then
  cp "$SRC/scaffold/AGENTS.md" "$target/AGENTS.md"
  log "created $target/AGENTS.md from the scaffold; fill in its TODOs and commit it"
fi
for d in rfcs plans adr architecture api incidents security/audits; do
  dir=$target/docs/$d
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir"
    touch "$dir/.gitkeep"  # git doesn't track empty folders, and agents work in fresh worktrees
  fi
done

log "installed $(ls "$SRC"/agents/*.md | wc -l | tr -d ' ') agents, the scripts, and $(ls "$SRC"/templates/*.md | wc -l | tr -d ' ') templates into $target"

# The agents are tuned for Rails; warn about the pieces they rely on.
[[ -f $target/config/application.rb ]] || log "note: $target doesn't look like a Rails app; the agents assume Rails conventions"
if [[ -f $target/config/database.yml ]] && ! grep -q WORKTREE_DB_SUFFIX "$target/config/database.yml"; then
  log "note: add WORKTREE_DB_SUFFIX to the development/test database names in config/database.yml"
  log "      so parallel agents get their own databases (see README)"
fi

git -C "$target" status --short -- .claude docs AGENTS.md >&2
