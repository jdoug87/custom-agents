#!/bin/bash
# Gather everything the SRE agent needs to triage an incident into one file:
# deployed version, recent commits/PRs on main, and recent error log lines.
#
# Usage: incident_context.sh [--since "2 hours ago"] [-d <kamal-destination>]
# Prints the path of the generated report (tmp/incidents/<timestamp>.md).
source "$(dirname "$0")/lib/common.sh"
require git gh

since="2 hours ago" dest_args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --since) since=$2; shift 2 ;;
    -d) dest_args=(-d "$2"); shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

mkdir -p tmp/incidents
out="tmp/incidents/$(date +%Y%m%d-%H%M%S).md"
git fetch -q origin main

{
  echo "# Incident context — $(date '+%F %T')"
  echo
  echo "## Deployed version"
  echo '```'
  bin/kamal app version ${dest_args[@]+"${dest_args[@]}"} 2>&1 | tail -n 5 || echo "(kamal app version failed)"
  echo '```'
  echo
  echo "## Commits on main since $since"
  git log origin/main --since="$since" --format='- `%h` %s (%an, %ar)'
  echo
  echo "## Recently merged PRs"
  gh pr list --state merged --limit 10 --json number,title,mergedAt,labels \
    --jq '.[] | "- #\(.number) \(.title) — merged \(.mergedAt) [\(.labels | map(.name) | join(", "))]"'
  echo
  echo "## Recent errors (last 500 log lines, filtered)"
  echo '```'
  bin/kamal app logs ${dest_args[@]+"${dest_args[@]}"} --lines 500 --grep 'ERROR|FATAL|Exception| 500 ' 2>&1 | tail -n 150 \
    || echo "(kamal app logs failed)"
  echo '```'
} >"$out"

log "wrote $out"
echo "$out"
