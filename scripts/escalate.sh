#!/bin/bash
# Escalate an issue or PR to the human: label it blocked, leave a comment with
# context, and send a HITL notification that routes replies back to this agent.
#
# Usage: escalate.sh <issue|pr> <number> "<reason>" [--log <file>] [--options "A,B,C"] [--attach <file>]
# Example:
#   escalate.sh issue 102 "bin/ci failed 3 times on system tests" --log tmp/ci.log --options "Retry,Skip test,Abort"
source "$(dirname "$0")/lib/common.sh"

[[ $# -ge 3 && $1 =~ ^(issue|pr)$ ]] || die "usage: $(basename "$0") <issue|pr> <number> \"<reason>\" [--log file] [--options A,B] [--attach file]"
kind=$1 num=$2 reason=$3; shift 3
logfile="" options="Approve,Retry,Abort" attach=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --log) logfile=$2; shift 2 ;;
    --options) options=$2; shift 2 ;;
    --attach) attach=$2; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

agent="${AGENT_NAME:-unknown}"
title=$(gh_app "$kind" view "$num" --json title --jq .title)

body=$(mktemp)
trap 'rm -f "$body"' EXIT
{
  echo "### 🚧 Blocked: needs human review"
  echo
  echo "**Agent:** \`$agent\`"
  echo "**Reason:** $reason"
  if [[ -n $logfile && -f $logfile ]]; then
    echo
    echo "<details><summary>Last 60 lines of $(basename "$logfile")</summary>"
    echo
    echo '```'
    tail -n 60 "$logfile"
    echo '```'
    echo "</details>"
  fi
} >"$body"
gh_app "$kind" comment "$num" --body-file "$body" >/dev/null

set_label "$kind" "$num" status:blocked
gh_app "$kind" edit "$num" --add-label needs-human-review --add-label hitl:notified >/dev/null

notify_args=(--agent-role "$agent" --ticket-id "$num" --title "$title" --reason "$reason" --options "$options")
[[ -n $logfile && -f $logfile ]] && notify_args+=(--context "$(tail -n 15 "$logfile")")
[[ -n $attach ]] && notify_args+=(--attach "$attach")
"$AGENT_SCRIPTS/notify_human.sh" "${notify_args[@]}"
