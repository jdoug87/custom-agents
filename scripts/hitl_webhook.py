#!/usr/bin/env python3
"""Route Telegram replies and button taps back into herdr agent panes.

Two modes:
  poll     (default) long-polls Telegram's getUpdates. No public URL or tunnel needed.
  webhook  serves POST /telegram-webhook on --port. Needs a public HTTPS URL
           (e.g. a Cloudflare tunnel) registered with setWebhook and
           TELEGRAM_WEBHOOK_SECRET set as the secret_token.

Routing:
  * Tapping a button on an alert sends "Human decision: <button text>" to the agent.
  * Replying to an alert sends your text to the agent named in its "Agent:" line.
  * /status lists live agents and their states.

Only messages from TELEGRAM_CHAT_ID (and, if set, TELEGRAM_ALLOWED_USER_IDS,
comma-separated) are accepted. Python 3.9+, standard library only.

Usage: hitl_webhook.py [--mode poll|webhook] [--port 5001]
Env:   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_ALLOWED_USER_IDS, TELEGRAM_WEBHOOK_SECRET
"""
import argparse
import hmac
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
ALLOWED_USERS = {u.strip() for u in os.environ.get("TELEGRAM_ALLOWED_USER_IDS", "").split(",") if u.strip()}
WEBHOOK_SECRET = os.environ.get("TELEGRAM_WEBHOOK_SECRET", "")

AGENT_LINE = re.compile(r"^Agent:\s*(\S+)\s*$", re.MULTILINE)
AGENT_NAME = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def telegram(method, **params):
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TOKEN}/{method}",
        data=json.dumps(params).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=70) as resp:
            return json.load(resp)
    except urllib.error.URLError as e:
        log(f"telegram {method} failed: {e}")
        return {"ok": False}


def reply(text, to_message_id=None):
    params = {"chat_id": CHAT_ID, "text": text}
    if to_message_id:
        params["reply_to_message_id"] = to_message_id
    telegram("sendMessage", **params)


def herdr(*args):
    """Run herdr without a shell. Returns (ok, parsed-json-or-text)."""
    proc = subprocess.run(["herdr", *args], capture_output=True, text=True)
    out = proc.stdout if proc.returncode == 0 else proc.stderr
    try:
        return proc.returncode == 0, json.loads(out)
    except ValueError:
        return proc.returncode == 0, out.strip()


def prompt_agent(name, text):
    if not AGENT_NAME.match(name):
        return f"Refusing to route: '{name}' is not a valid agent name."
    ok, result = herdr("agent", "prompt", name, text)
    if ok:
        return f"✅ Sent to {name}."
    code = result.get("error", {}).get("code") if isinstance(result, dict) else ""
    if code == "agent_blocked":
        return (f"⚠️ {name} is sitting at an approval/question dialog, so input was not sent. "
                "Open herdr to answer it, or tap the option again once it's idle.")
    return f"❌ Could not reach {name}: {result}"


def authorized(chat, user):
    if str(chat.get("id")) != str(CHAT_ID):
        return False
    return not ALLOWED_USERS or str(user.get("id")) in ALLOWED_USERS


def status_text():
    ok, result = herdr("agent", "list")
    if not ok or not isinstance(result, dict):
        return f"herdr unavailable: {result}"
    agents = result.get("result", {}).get("agents", [])
    if not agents:
        return "No live agents."
    return "\n".join(f"{a.get('name') or a.get('pane_id')}: {a.get('agent_status')}" for a in agents)


def handle_callback(cq):
    msg = cq.get("message", {})
    if not authorized(msg.get("chat", {}), cq.get("from", {})):
        log("ignored callback from unauthorized chat/user")
        return
    agent, _, idx = cq.get("data", "").partition("|")
    choice = None
    for row in msg.get("reply_markup", {}).get("inline_keyboard", []):
        for button in row:
            if button.get("callback_data") == cq.get("data"):
                choice = button.get("text")
    if choice is None:
        telegram("answerCallbackQuery", callback_query_id=cq["id"], text="Unknown option")
        return
    result = prompt_agent(agent, f"Human decision: {choice}")
    telegram("answerCallbackQuery", callback_query_id=cq["id"], text=result[:190])
    reply(f"{choice} → {result}", msg.get("message_id"))
    log(f"button '{choice}' (#{idx}) → {agent}: {result}")


def handle_message(msg):
    if not authorized(msg.get("chat", {}), msg.get("from", {})):
        log("ignored message from unauthorized chat/user")
        return
    text = (msg.get("text") or "").strip()
    if text.startswith("/status"):
        reply(status_text(), msg.get("message_id"))
        return
    original = msg.get("reply_to_message") or {}
    match = AGENT_LINE.search(original.get("text") or "")
    if not match:
        if text:
            reply("Reply to an agent alert to route guidance, or send /status.", msg.get("message_id"))
        return
    result = prompt_agent(match.group(1), text)
    reply(result, msg.get("message_id"))
    log(f"reply → {match.group(1)}: {result}")


def handle_update(update):
    if "callback_query" in update:
        handle_callback(update["callback_query"])
    elif "message" in update:
        handle_message(update["message"])


def run_poll():
    telegram("deleteWebhook")  # getUpdates doesn't work while a webhook is set
    offset = None
    log("polling Telegram for updates")
    while True:
        params = {"timeout": 60, "allowed_updates": ["message", "callback_query"]}
        if offset is not None:
            params["offset"] = offset
        resp = telegram("getUpdates", **params)
        if not resp.get("ok"):
            time.sleep(5)
            continue
        for update in resp.get("result", []):
            offset = update["update_id"] + 1
            try:
                handle_update(update)
            except Exception as e:  # keep the bot alive on a bad update
                log(f"error handling update {update.get('update_id')}: {e}")


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/telegram-webhook":
            self.send_error(404)
            return
        secret = self.headers.get("X-Telegram-Bot-Api-Secret-Token", "")
        if not hmac.compare_digest(secret, WEBHOOK_SECRET):
            self.send_error(403)
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            handle_update(json.loads(self.rfile.read(length)))
        except Exception as e:
            log(f"error handling webhook: {e}")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=["poll", "webhook"], default="poll")
    parser.add_argument("--port", type=int, default=5001)
    args = parser.parse_args()

    if not TOKEN or not CHAT_ID:
        sys.exit("TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set")
    if args.mode == "webhook":
        if not WEBHOOK_SECRET:
            sys.exit("TELEGRAM_WEBHOOK_SECRET must be set in webhook mode")
        log(f"listening on 127.0.0.1:{args.port}/telegram-webhook")
        HTTPServer(("127.0.0.1", args.port), WebhookHandler).serve_forever()
    else:
        run_poll()


if __name__ == "__main__":
    main()
