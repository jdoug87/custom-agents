#!/bin/bash
# Deploy origin/main with Kamal, then smoke-check it. Refuses to deploy a commit
# whose GitHub CI run isn't green. Run from the release-engineer worktree.
#
# Usage: deploy.sh <staging|production>
# Env:   STAGING_URL, PRODUCTION_URL   base URLs for smoke checks
#
# Staging needs config/deploy.staging.yml (Kamal destination "staging").
source "$(dirname "$0")/lib/common.sh"
require git gh jq

env=${1:-}
case $env in
  staging) dest_args=(-d staging) url=${STAGING_URL:-}
           [[ -f config/deploy.staging.yml ]] || die "config/deploy.staging.yml not found; set up a Kamal staging destination first" ;;
  production) dest_args=() url=${PRODUCTION_URL:-} ;;
  *) die "usage: $(basename "$0") <staging|production>" ;;
esac
[[ -n $url ]] || die "set $(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')_URL for smoke checks"

git fetch -q origin main
git checkout -q --detach origin/main
sha=$(git rev-parse HEAD)

run=$(gh run list --branch main --commit "$sha" --limit 1 --json conclusion,status,url --jq '.[0] // empty')
[[ -n $run ]] || die "no CI run found for $sha"
[[ $(jq -r .conclusion <<<"$run") == success ]] || die "CI for $sha is not green: $(jq -r '.status + " " + .conclusion + " " + .url' <<<"$run")"

log "deploying $sha to $env"
bin/kamal deploy ${dest_args[@]+"${dest_args[@]}"}

log "smoke checking $url"
if ! "$AGENT_SCRIPTS/smoke_check.sh" "$url" --jobs ${dest_args[@]+"${dest_args[@]}"}; then
  log "smoke checks failed on $env. Roll back with: $AGENT_SCRIPTS/rollback_deployment.sh $env"
  exit 1
fi
log "$env is running $sha"
echo "$sha"
