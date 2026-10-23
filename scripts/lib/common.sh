#!/bin/bash
# Shared helpers for the agent pipeline scripts. Source this; don't execute it.
#
#   source "$(dirname "$0")/lib/common.sh"
#
# These scripts run from the copy install.sh puts in a target repo at
# <app>/.claude/scripts (or in one of its worktrees). From there everything is
# detected automatically.
#
# Environment (all optional when installed):
#   AGENT_SCRIPTS  this scripts/ directory
#   APP_REPO       main checkout of the target app (required when not installed)
#   WORKTREE_ROOT  where per-agent worktrees live (default: <app>-worktrees next to the app)
#   CLAUDE_ARGS    extra args passed to `claude` for spawned agents
#   AGENT_KIND     herdr agent kind to launch (default: claude)

set -euo pipefail

# pwd -P resolves symlinks.
AGENT_SCRIPTS="${AGENT_SCRIPTS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
if [[ -z ${APP_REPO:-} ]]; then
  if [[ $(basename "$(dirname "$AGENT_SCRIPTS")") != .claude ]]; then
    printf 'ERROR: run the installed copy in your target repo (.claude/scripts), or set APP_REPO\n' >&2
    exit 1
  fi
  # Possibly inside a worktree: the app repo is the main checkout.
  APP_REPO=$(dirname "$(git -C "$AGENT_SCRIPTS" rev-parse --path-format=absolute --git-common-dir)")
fi
WORKTREE_ROOT="${WORKTREE_ROOT:-$(dirname "$APP_REPO")/$(basename "$APP_REPO")-worktrees}"
CLAUDE_ARGS="${CLAUDE_ARGS:---permission-mode auto}"
AGENT_KIND="${AGENT_KIND:-claude}"
export AGENT_SCRIPTS APP_REPO WORKTREE_ROOT

# Status labels are mutually exclusive: setting one removes the others.
STATUS_LABELS=(status:backlog status:ready-for-agent in-progress status:pr-review
  status:blocked waiting-for-deploy deployed status:done)
# Prefix groups are also mutually exclusive within their prefix.
LABEL_PREFIX_GROUPS=(qa: visual: security: design: priority: tier: rework: reworked: rfc:)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# Database name suffix for a worktree key (issue-12 → _issue_12). Must match
# what config/database.yml appends via WORKTREE_DB_SUFFIX.
db_suffix() { printf '_%s' "$(printf '%s' "$1" | tr -c 'a-z0-9' '_')"; }

# Base database name from config/database.yml ("myapp" for myapp_development).
db_base() {
  grep -oE 'database: *[A-Za-z0-9_]+_development' "$APP_REPO/config/database.yml" 2>/dev/null \
    | head -n 1 | sed -E 's/^database: *//; s/_development$//'
}

valid_agent_name() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }

# Run gh against the app repo regardless of the caller's cwd.
gh_app() { (cd "$APP_REPO" && gh "$@"); }

# Labels currently on an issue or PR (same API for both), one per line.
current_labels() { gh_app issue view "$1" --json labels --jq '.labels[].name'; }

# Echo the labels on $1 that conflict with $2 (same status set or prefix group).
conflicting_labels() {
  local num=$1 label=$2 l s p group=""
  for s in "${STATUS_LABELS[@]}"; do [[ $label == "$s" ]] && group=status; done
  if [[ -z $group ]]; then
    for p in "${LABEL_PREFIX_GROUPS[@]}"; do [[ $label == "$p"* ]] && group=$p; done
  fi
  [[ -z $group ]] && return 0
  while IFS= read -r l; do
    [[ -z $l || $l == "$label" ]] && continue
    if [[ $group == status ]]; then
      for s in "${STATUS_LABELS[@]}"; do [[ $l == "$s" ]] && echo "$l"; done
    elif [[ $l == "$group"* ]]; then
      echo "$l"
    fi
  done < <(current_labels "$num")
}

# set_label <issue|pr> <number> <label>: add label, drop conflicting ones.
set_label() {
  local kind=$1 num=$2 label=$3 args=() l
  args+=(--add-label "$label")
  while IFS= read -r l; do [[ -n $l ]] && args+=(--remove-label "$l"); done \
    < <(conflicting_labels "$num" "$label")
  gh_app "$kind" edit "$num" "${args[@]}" >/dev/null
  log "#$num → $label"
}

# Parse "Blocked By: #12, #13" lines from an issue body; prints numbers.
blocked_by() {
  gh_app issue view "$1" --json body --jq '.body' \
    | grep -iE '^\s*[-*]?\s*\**blocked by:?\**' \
    | grep -oE '#[0-9]+' | tr -d '#' || true
}

# Prints blocker numbers that are still open. Empty output = unblocked.
open_blockers() {
  local b
  for b in $(blocked_by "$1"); do
    [[ $(gh_app issue view "$b" --json state --jq .state) == CLOSED ]] || echo "$b"
  done
}

# spawn_agent <name> <agent-definition> <cwd> <prompt> [KEY=VALUE ...]
# Creates a herdr workspace at <cwd>, starts the agent, and submits <prompt>.
# Prints the pane id. Returns 3 if an agent with that name is already live.
spawn_agent() {
  local name=$1 agent=$2 cwd=$3 prompt=$4; shift 4
  require herdr jq
  valid_agent_name "$name" || die "invalid herdr agent name '$name' (want [a-z][a-z0-9_-]{0,31})"
  [[ -d $cwd ]] || die "cwd does not exist: $cwd"
  if herdr agent get "$name" >/dev/null 2>&1; then
    log "agent '$name' is already running; not spawning a second one"
    return 3
  fi

  local env_args=(--env "AGENT_SCRIPTS=$AGENT_SCRIPTS" --env "APP_REPO=$APP_REPO"
    --env "AGENT_NAME=$name") kv
  case $cwd in
    "$WORKTREE_ROOT"/*) env_args+=(--env "WORKTREE_DB_SUFFIX=$(db_suffix "$(basename "$cwd")")") ;;
  esac
  for kv in "$@"; do env_args+=(--env "$kv"); done

  local ws pane
  ws=$(herdr workspace create --cwd "$cwd" --label "$name" --no-focus "${env_args[@]}")
  pane=$(jq -r '.result.root_pane.pane_id' <<<"$ws")
  [[ -n $pane && $pane != null ]] || die "herdr workspace create returned no pane: $ws"

  # shellcheck disable=SC2086  # CLAUDE_ARGS is intentionally word-split
  herdr agent start "$name" --kind "$AGENT_KIND" --pane "$pane" --timeout 120000 \
    -- --agent "$agent" $CLAUDE_ARGS >/dev/null
  herdr agent prompt "$name" "$prompt" >/dev/null
  log "spawned $name ($agent) in pane $pane"
  printf '%s\n' "$pane"
}

# close_agent <name>: close the herdr workspace hosting a live agent.
close_agent() {
  local pane
  pane=$(herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.pane_id // .result.pane_id // empty') || true
  [[ -z $pane ]] && return 0
  herdr workspace close "${pane%%:*}" >/dev/null && log "closed agent $1 (${pane%%:*})"
}
