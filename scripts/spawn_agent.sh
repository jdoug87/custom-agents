#!/bin/bash
# Launch an agent in its own herdr workspace and hand it a prompt.
#
# Usage: spawn_agent.sh <herdr-name> <agent-definition> <cwd> <prompt> [KEY=VALUE ...]
# Example:
#   spawn_agent.sh qa-pr-42 qa-tester "$WORKTREE_ROOT/pr-42-qa" "Run QA verification on PR #42"
source "$(dirname "$0")/lib/common.sh"

[[ $# -ge 4 ]] || die "usage: $(basename "$0") <herdr-name> <agent-definition> <cwd> <prompt> [KEY=VALUE ...]"
spawn_agent "$@"
