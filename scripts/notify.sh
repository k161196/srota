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
import sys
import time

raw = sys.argv[1]
fallback_cwd = sys.argv[2]
agent = sys.argv[3]

try:
    payload = json.loads(raw)
except Exception:
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

if not event:
    sys.exit(0)

def extract_summary(payload):
    transcript_path = payload.get("transcript_path")
    if transcript_path and os.path.exists(transcript_path):
        try:
            with open(transcript_path, "r", encoding="utf-8") as f:
                lines = [line.strip() for line in f if line.strip()]
            for line in reversed(lines):
                item = json.loads(line)
                msg_payload = item.get("payload", {})
                if item.get("type") == "event_msg" and msg_payload.get("type") == "user_message":
                    text = (msg_payload.get("message") or "").strip()
                    if text:
                        return text
                if item.get("type") == "response_item" and msg_payload.get("type") == "message" and msg_payload.get("role") == "user":
                    for content in msg_payload.get("content", []):
                        text = (content.get("text") or "").strip()
                        if text:
                            return text
        except Exception:
            pass
    for key in ("last_assistant_message", "message"):
        text = (payload.get(key) or "").strip()
        if text:
            return text
    return ""

cwd = os.environ.get("SROTA_TAB_CWD") or payload.get("cwd") or payload.get("working_directory") or fallback_cwd
tab_id = os.environ.get("SROTA_TAB_ID")
pane_id = os.environ.get("SROTA_PANE_ID")
summary = extract_summary(payload)

log_dir = os.path.expanduser("~/.srota")
os.makedirs(log_dir, exist_ok=True)

with open(os.path.join(log_dir, "agent-events.jsonl"), "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "event": event,
        "cwd": cwd,
        "agent": agent,
        "tabID": tab_id,
        "paneID": pane_id,
        "summary": summary,
        "timestamp": time.time(),
    }) + "\n")

with open(os.path.join(log_dir, "last-agent-hook.json"), "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)

print(event)
PY
)"

[[ -z "$PARSED" ]] && exit 0

case "$AGENT" in
  claude) LABEL="Claude" ;;
  codex) LABEL="Codex" ;;
  *) LABEL="$AGENT" ;;
esac

if [[ "$PARSED" != "PermissionRequest" ]]; then
  exit 0
fi

osascript -e "display notification \"Waiting for response\" with title \"$LABEL needs approval\""
