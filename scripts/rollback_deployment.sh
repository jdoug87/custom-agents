#!/bin/bash
# Roll a Kamal deployment back to an earlier version and re-run smoke checks.
# Kamal versions are git SHAs, so with no version given this rolls back to the
# commit of the previous release tag (v*).
#
# Usage: rollback_deployment.sh <staging|production> [version-sha]
# Env:   STAGING_URL, PRODUCTION_URL
source "$(dirname "$0")/lib/common.sh"
require git

env=${1:-} version=${2:-}
case $env in
  staging) dest_args=(-d staging) url=${STAGING_URL:-} ;;
  production) dest_args=() url=${PRODUCTION_URL:-} ;;
  *) die "usage: $(basename "$0") <staging|production> [version-sha]" ;;
esac

if [[ -z $version ]]; then
  git fetch -q --tags origin
  prev_tag=$(git tag --list 'v*' --sort=-creatordate | sed -n 2p)
  if [[ -z $prev_tag ]]; then
    log "no previous release tag; pick a version from the containers Kamal kept:"
    bin/kamal app containers ${dest_args[@]+"${dest_args[@]}"} >&2 || true
    die "pass the version explicitly"
  fi
  version=$(git rev-list -n 1 "$prev_tag")
  log "rolling back to $prev_tag ($version)"
fi

log "CRITICAL: rolling back $env to $version"
bin/kamal rollback "$version" ${dest_args[@]+"${dest_args[@]}"}

if [[ -n $url ]]; then
  "$AGENT_SCRIPTS/smoke_check.sh" "$url" ${dest_args[@]+"${dest_args[@]}"} || die "smoke checks still failing after rollback; escalate now"
fi
log "rollback of $env to $version complete"
