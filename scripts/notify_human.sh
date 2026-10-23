#!/bin/bash
# Send a human-in-the-loop alert to Telegram with tap-to-answer buttons.
# Replies and button taps are routed back to the agent by hitl_webhook.py.
# Falls back to a herdr desktop notification when Telegram isn't configured.
#
# Usage:
#   notify_human.sh --reason "<why>" [--agent-role <herdr-agent-name>] [--ticket-id <n>]
#                   [--title "<ticket title>"] [--context "<log/plan snippet>"]
#                   [--options "Approve,Retry,Abort"] [--url <link>] [--attach <file>]
#
# Env: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
source "$(dirname "$0")/lib/common.sh"
require curl jq

agent="${AGENT_NAME:-}" ticket="" title="" reason="" context="" options="Approve,Retry,Abort" url="" attach=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent-role|--pane-id) agent=$2; shift 2 ;;
    --ticket-id) ticket=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --reason) reason=$2; shift 2 ;;
    --context) context=$2; shift 2 ;;
    --options) options=$2; shift 2 ;;
    --url) url=$2; shift 2 ;;
    --attach) attach=$2; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n $reason ]] || die "--reason is required"

if [[ -z ${TELEGRAM_BOT_TOKEN:-} || -z ${TELEGRAM_CHAT_ID:-} ]]; then
  log "Telegram not configured; showing a local herdr notification instead"
  herdr notification show "Agent ${agent:-?} needs input${ticket:+ (#$ticket)}" \
    --body "$reason" --sound request >/dev/null 2>&1 || true
  exit 0
fi

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# The "Agent:" line is how hitl_webhook.py knows where to route replies. Keep its format.
text="🚨 <b>Agent needs input</b>"
[[ -n $ticket ]] && text+=$'\n'"<b>#$ticket</b> $(printf '%s' "$title" | html_escape)"
text+=$'\n'"<b>Reason:</b> $(printf '%s' "$reason" | html_escape)"
if [[ -n $context ]]; then
  text+=$'\n'"<pre>$(printf '%s' "$context" | tail -c 1500 | html_escape)</pre>"
fi
[[ -n $url ]] && text+=$'\n'"$(printf '%s' "$url" | html_escape)"
[[ -n $agent ]] && text+=$'\n'"Agent: <code>$agent</code>"$'\n'"<i>Reply to this message to send the agent free-text guidance.</i>"

# One button per option. callback_data = "<agent>|<index>" (Telegram caps it at 64 bytes);
# the webhook reads the button text back from the message to know what was chosen.
keyboard='[]'
if [[ -n $agent && -n $options ]]; then
  keyboard=$(jq -cn --arg agent "$agent" --arg opts "$options" '
    [$opts | split(",") | to_entries[]
      | {text: (.value | gsub("^\\s+|\\s+$"; "")), callback_data: "\($agent)|\(.key)"}]
    | [_nwise(3)]')
fi

api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
payload=$(jq -n --arg chat "$TELEGRAM_CHAT_ID" --arg text "$text" --argjson kb "$keyboard" \
  '{chat_id: $chat, text: $text, parse_mode: "HTML", disable_web_page_preview: true}
   + (if ($kb | length) > 0 then {reply_markup: {inline_keyboard: $kb}} else {} end)')

resp=$(curl -sS -X POST "$api/sendMessage" -H 'Content-Type: application/json' -d "$payload")
[[ $(jq -r .ok <<<"$resp") == true ]] || die "Telegram sendMessage failed: $(jq -r .description <<<"$resp")"
msg_id=$(jq -r .result.message_id <<<"$resp")

if [[ -n $attach && -f $attach ]]; then
  case $(printf '%s' "$attach" | tr '[:upper:]' '[:lower:]') in
    *.png|*.jpg|*.jpeg|*.webp) method=sendPhoto field=photo ;;
    *.mp4|*.mov) method=sendVideo field=video ;;
    *) method=sendDocument field=document ;;
  esac
  curl -sS -X POST "$api/$method" -F "chat_id=$TELEGRAM_CHAT_ID" \
    -F "reply_to_message_id=$msg_id" -F "$field=@$attach" >/dev/null \
    || log "warning: failed to upload attachment $attach"
fi
log "notified human (telegram message $msg_id)"
