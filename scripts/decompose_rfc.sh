#!/bin/bash
# Hand a merged RFC to the (single) Agile PM agent for Epic/Story decomposition.
#
# Usage: decompose_rfc.sh <path/to/rfc.md>   (path relative to the app repo root)
source "$(dirname "$0")/lib/common.sh"

[[ $# -eq 1 ]] || die "usage: $(basename "$0") docs/rfcs/<NNNN>-<slug>.md"
rfc=$1

wt=$("$AGENT_SCRIPTS/prepare_worktree.sh" main agile-pm --no-setup)
[[ -f $wt/$rfc ]] || die "RFC not found on origin/main: $rfc"

prompt="Read $rfc, decompose it into an Epic and linked GitHub Stories using docs/templates, and label every story status:backlog. Then request publish approval via the HITL hook."

if info=$(herdr agent get agile-pm 2>/dev/null); then
  # Single instance: hand the work to the running agent once it's free.
  status=$(jq -r '.result.agent.agent_status // .result.agent_status' <<<"$info")
  [[ $status == idle || $status == done ]] || die "agile-pm is $status; retry when it is idle"
  herdr agent prompt agile-pm "$prompt" >/dev/null
  log "sent $rfc to running agile-pm"
else
  spawn_agent agile-pm agile-pm "$wt" "$prompt"
fi
