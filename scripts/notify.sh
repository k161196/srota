#!/bin/bash
# Agent lifecycle -> in-app status + optional macOS notification.
# Claude pipes JSON via stdin; Codex passes JSON as $1.

set -euo pipefail

if [[ -n "${1:-}" ]]; then
  INPUT="$1"
else
  INPUT="$(cat)"
fi

AGENT="${SORA_AGENT_ID:-agent}"

PARSED="$(
python3 - "$INPUT" "$PWD" "$AGENT" <<'PY'
import json
import os
import socket
import sys
import time

raw = sys.argv[1]
fallback_cwd = sys.argv[2]
agent = sys.argv[3]

try:
    payload = json.loads(raw)
except Exception:
    sys.exit(0)
if not isinstance(payload, dict):
    sys.exit(0)

event = payload.get("hook_event_name", "")
if not event:
    event_type = payload.get("type", "")
    event = {
        "agent-turn-complete": "Stop",
        "task_complete": "Stop",
        "task_started": "Start",
        "exec_approval_request": "PermissionRequest",
        "apply_patch_approval_request": "PermissionRequest",
        "request_user_input": "PermissionRequest",
    }.get(event_type, "")

if event == "UserPromptSubmit":
    event = "Start"

# Notification(permission_prompt) and PreToolUse(AskUserQuestion) are the only
# variants of these two hooks Srota registers (see check-agent-hooks.sh), so
# either one reaching here always means "blocked".
if event in {"Notification", "PreToolUse"}:
    event = "PermissionRequest"

# PostToolUse(AskUserQuestion) is the only PostToolUse hook registered, so it
# always means the question was just answered — back to "working".
if event == "PostToolUse":
    event = "Start"

if event not in {"SessionStart", "Start", "Stop", "SessionEnd", "PermissionRequest"}:
    sys.exit(0)

def extract_summary(payload):
    for key in ("last_assistant_message", "message"):
        text = payload.get(key)
        if isinstance(text, str):
            text = text.strip()
            if text:
                return text
    transcript_path = payload.get("transcript_path")
    if transcript_path and os.path.exists(transcript_path):
        try:
            with open(transcript_path, "r", encoding="utf-8") as f:
                last_match = ""
                for raw_line in f:
                    line = raw_line.strip()
                    if not line:
                        continue
                    item = json.loads(line)
                    msg_payload = item.get("payload", {})
                    if item.get("type") == "event_msg" and msg_payload.get("type") == "user_message":
                        text = (msg_payload.get("message") or "").strip()
                        if text:
                            last_match = text
                    if item.get("type") == "response_item" and msg_payload.get("type") == "message" and msg_payload.get("role") == "user":
                        for content in msg_payload.get("content", []):
                            text = (content.get("text") or "").strip()
                            if text:
                                last_match = text
                if last_match:
                    return last_match
        except Exception:
            pass
    return ""

cwd = os.environ.get("SROTA_TAB_CWD") or payload.get("cwd") or payload.get("working_directory") or fallback_cwd
tab_id = os.environ.get("SROTA_TAB_ID")
pane_id = os.environ.get("SROTA_PANE_ID")
summary = extract_summary(payload)

if pane_id:
    try:
        sock_path = os.environ.get("SROTA_SOCKET_PATH") or os.path.expanduser("~/.srota/daemon.sock")
        msg = json.dumps({
            "type": "agent_event",
            "stableID": pane_id,
            "event": event,
            "agent": agent,
            "summary": summary,
            "timestamp": time.time(),
        }).encode("utf-8") + b"\n"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(sock_path)
            sock.sendall(msg)
    except Exception:
        pass

print(event)
PY
)"

[[ -z "$PARSED" ]] && exit 0

case "$AGENT" in
  claude) LABEL="Claude" ;;
  codex) LABEL="Codex" ;;
  *) LABEL="$AGENT" ;;
esac

case "$PARSED" in
  Start)              exit 0 ;;  # status still logged above; no notification banner for prompt submission
  Stop)               exit 0 ;;  # ponytail: status still logged above; no macOS banner on turn-end, per user preference
  SessionEnd)         TITLE="$LABEL done";          BODY="Session ended" ;;
  PermissionRequest)  TITLE="$LABEL needs approval"; BODY="Waiting for response" ;;
  *) exit 0 ;;
esac

NOTIFY_KEY="$AGENT|${SROTA_TAB_ID:-}|${SROTA_PANE_ID:-}|${SROTA_TAB_CWD:-$PWD}|$PARSED"
NOTIFY_STATE_DIR="$HOME/.srota"
NOTIFY_STATE_FILE="$NOTIFY_STATE_DIR/last-notification.json"
mkdir -p "$NOTIFY_STATE_DIR"
if ! python3 - "$NOTIFY_STATE_FILE" "$NOTIFY_KEY" <<'PY'
import json
import os
import sys
import time

path, key = sys.argv[1], sys.argv[2]
window_seconds = 30
now = time.time()
data = {}
if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}

last = data.get(key, 0)
data[key] = now

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f)

if now - float(last or 0) < window_seconds:
    sys.exit(1)
PY
then
  exit 0
fi

osascript -e "display notification \"$BODY\" with title \"$TITLE\""
