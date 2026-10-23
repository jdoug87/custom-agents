#!/bin/bash
# Create (or update) every GitHub label the agent pipeline uses. Safe to re-run.
#
# Usage: setup_labels.sh
source "$(dirname "$0")/lib/common.sh"
require gh

# name|color|description
LABELS=(
  "status:backlog|cfd3d7|Not yet ready for an agent"
  "status:ready-for-agent|0e8a16|Unblocked and ready to be claimed"
  "in-progress|fbca04|Claimed by a Feature Developer agent"
  "status:pr-review|1d76db|PR open and in verification"
  "status:blocked|b60205|Needs a human decision"
  "waiting-for-deploy|5319e7|Merged, waiting for release"
  "deployed|0052cc|Deployed, pending final validation"
  "status:done|0e8a16|Deployed and validated"
  "needs-human-review|d93f0b|Escalated to the human"
  "hitl:notified|c5def5|Human has been notified"
  "integration-failed|b60205|bin/ci failed on the integration branch"
  "qa:in-progress|fef2c0|QA agent running"
  "qa:passed|0e8a16|QA verified the PR"
  "qa:failed|b60205|QA found failures"
  "security:in-progress|fef2c0|Security scan running"
  "security:passed|0e8a16|No security findings"
  "security:failed|b60205|Blocking security findings"
  "visual:in-progress|fef2c0|Visual regression running"
  "visual:passed|0e8a16|No unintended visual changes"
  "visual:needs-approval|fbca04|Intended visual change awaiting approval"
  "visual:failed|b60205|Unintended visual regression"
  "design:in-progress|fef2c0|Design review running"
  "design:passed|0e8a16|Design tokens respected"
  "design:changes-requested|d93f0b|Design system violations"
  "reworked:1|f9d0c4|PR has been through 1 rework cycle"
  "reworked:2|f9d0c4|PR has been through 2 rework cycles"
  "reworked:3|f9d0c4|PR has been through 3 rework cycles"
  "rework:in-progress|fef2c0|Developer is reworking the PR"
  "rfc|5319e7|Architecture RFC"
  "rfc:in-review|c5def5|Design Review Committee running"
  "rfc:queued|c5def5|Merged RFC handed to the Roadmap agent"
  "priority:high|b60205|"
  "priority:medium|fbca04|"
  "priority:low|c2e0c6|"
  "tier:1|0e8a16|No open blockers"
  "tier:2|fbca04|Blocked only by tier 1"
  "tier:3|d4c5f9|Blocked by tier 2"
  "bug:production|b60205|Production incident follow-up"
  "dependencies|0366d6|Dependency update"
  "documentation|0075ca|Docs only"
  "security|b60205|Security audit finding"
)

for entry in "${LABELS[@]}"; do
  IFS='|' read -r name color desc <<<"$entry"
  gh_app label create "$name" --color "$color" --description "$desc" --force >/dev/null
  log "label $name"
done
