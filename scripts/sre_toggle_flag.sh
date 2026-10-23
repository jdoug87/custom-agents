#!/bin/bash
# Turn a PostHog feature flag on or off (SRE containment).
# Works once the app's flags live in PostHog; swap the API calls for another provider.
#
# Usage: sre_toggle_flag.sh <flag-key> <on|off>
# Env:   POSTHOG_PERSONAL_API_KEY, POSTHOG_PROJECT_ID, POSTHOG_HOST (default https://us.posthog.com)
source "$(dirname "$0")/lib/common.sh"
require curl jq

[[ $# -eq 2 && $2 =~ ^(on|off)$ ]] || die "usage: $(basename "$0") <flag-key> <on|off>"
key=$1 active=$([[ $2 == on ]] && echo true || echo false)
: "${POSTHOG_PERSONAL_API_KEY:?set POSTHOG_PERSONAL_API_KEY}" "${POSTHOG_PROJECT_ID:?set POSTHOG_PROJECT_ID}"
api="${POSTHOG_HOST:-https://us.posthog.com}/api/projects/$POSTHOG_PROJECT_ID/feature_flags"
auth=(-H "Authorization: Bearer $POSTHOG_PERSONAL_API_KEY")

# The API addresses flags by numeric id, so look it up from the key.
id=$(curl -sS "${auth[@]}" --get --data-urlencode "search=$key" "$api/" \
  | jq -r --arg k "$key" '.results[]? | select(.key == $k) | .id' | head -n 1)
[[ -n $id ]] || die "flag '$key' not found in PostHog project $POSTHOG_PROJECT_ID"

resp=$(curl -sS -X PATCH "${auth[@]}" -H 'Content-Type: application/json' \
  -d "{\"active\": $active}" "$api/$id/")
[[ $(jq -r .active <<<"$resp") == "$active" ]] || die "PostHog did not apply the change: $resp"
log "flag $key is now $2"
