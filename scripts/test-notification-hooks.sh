#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTIFY_SCRIPT="$ROOT/scripts/notify.sh"
CHECK_SCRIPT="$ROOT/scripts/check-agent-hooks.sh"

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/srota-notify-tests.XXXXXX")"

SOCKET_PATH="$TMPDIR/daemon.sock"
EVENTS_LOG="$TMPDIR/agent-events.log"
: >"$EVENTS_LOG"

python3 - "$SOCKET_PATH" "$EVENTS_LOG" <<'PY' &
import os
import socket
import sys

sock_path, log_path = sys.argv[1], sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(64)

with open(log_path, "a", encoding="utf-8") as log:
    while True:
        try:
            conn, _ = srv.accept()
        except OSError:
            break
        data = b""
        while b"\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        conn.close()
        if data:
            log.write(data.decode("utf-8", "replace"))
            log.flush()
PY
SOCKET_SERVER_PID=$!

cleanup() {
  kill "$SOCKET_SERVER_PID" 2>/dev/null || true
  wait "$SOCKET_SERVER_PID" 2>/dev/null || true
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

# Give the fake socket server a moment to bind before the first notify.sh call.
for _ in $(seq 1 50); do
  [[ -S "$SOCKET_PATH" ]] && break
  sleep 0.1
done

HOME_DIR="$TMPDIR/home"
BIN_DIR="$TMPDIR/bin"
mkdir -p "$HOME_DIR" "$BIN_DIR"

export HOME="$HOME_DIR"
export PATH="$BIN_DIR:${PATH}"
export SROTA_SOCKET_PATH="$SOCKET_PATH"
# This test may itself be running inside a srota-managed pane, which would otherwise leak
# SROTA_PANE_ID/SROTA_TAB_ID/SROTA_TAB_CWD into every notify.sh invocation below.
unset SROTA_PANE_ID SROTA_TAB_ID SROTA_TAB_CWD SORA_AGENT_ID

cat >"$BIN_DIR/osascript" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$TMPDIR/osascript.log"
EOF
chmod +x "$BIN_DIR/osascript"

cat >"$BIN_DIR/claude" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN_DIR/claude"

cat >"$BIN_DIR/codex" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN_DIR/codex"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"
  [[ "$actual" == "$expected" ]] || fail "$message (expected '$expected', got '$actual')"
}

assert_file_contains() {
  local path="$1"
  local pattern="$2"
  local message="$3"
  rg -q --fixed-strings "$pattern" "$path" || fail "$message"
}

# Socket pushes race the test process slightly; give one a moment to land.
wait_for_event_count() {
  local expected="$1"
  for _ in $(seq 1 50); do
    [[ "$(event_count)" == "$expected" ]] && return 0
    sleep 0.05
  done
}

event_count() {
  wc -l <"$EVENTS_LOG" | tr -d ' '
}

last_event_field() {
  local field="$1"
  python3 - "$EVENTS_LOG" "$field" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    last = [line for line in f if line.strip()][-1]
print(json.loads(last).get(field, ""))
PY
}

run_notify_stdin() {
  local payload="$1"
  shift || true
  printf '%s' "$payload" | env "$@" "$NOTIFY_SCRIPT"
}

run_notify_arg() {
  local payload="$1"
  shift || true
  env "$@" "$NOTIFY_SCRIPT" "$payload"
}

notification_count() {
  local path="$TMPDIR/osascript.log"
  [[ -f "$path" ]] || { echo 0; return; }
  wc -l <"$path" | tr -d ' '
}

count_matches() {
  local path="$1"
  local pattern="$2"
  python3 - "$path" "$pattern" <<'PY'
import pathlib
import sys

path, pattern = sys.argv[1], sys.argv[2]
print(pathlib.Path(path).read_text(encoding="utf-8").count(pattern))
PY
}

printf '1..16\n'

before="$(event_count)"
if ! run_notify_arg '"json string"' >/dev/null 2>"$TMPDIR/non-object.err"; then
  cat "$TMPDIR/non-object.err" >&2
  fail "notify.sh should ignore non-object JSON instead of crashing"
fi
assert_eq "$(event_count)" "$before" "non-object JSON should not push a socket event"
printf 'ok 1 - non-object JSON is ignored\n'

before="$(event_count)"
run_notify_arg '{"hook_event_name":"UnknownEvent","cwd":"/tmp/project"}' SROTA_PANE_ID=pane-unknown >/dev/null
assert_eq "$(event_count)" "$before" "unknown events should be ignored"
printf 'ok 2 - unknown events are ignored\n'

run_notify_arg '{"hook_event_name":"PermissionRequest","cwd":"/tmp/project","message":"approve me"}' \
  SORA_AGENT_ID=codex SROTA_TAB_ID=tab-1 SROTA_PANE_ID=pane-1 >/dev/null
wait_for_event_count 1
assert_eq "$(event_count)" "1" "permission request with a pane id should push one socket event"
assert_eq "$(last_event_field event)" "PermissionRequest" "permission request should push the mapped event"
assert_eq "$(last_event_field agent)" "codex" "permission request should keep the agent id"
assert_eq "$(last_event_field stableID)" "pane-1" "permission request should push the pane id as stableID"
assert_file_contains "$TMPDIR/osascript.log" 'Codex needs approval' "permission request should trigger a macOS notification"
printf 'ok 3 - permission request pushes to the daemon socket and notifies\n'

run_notify_arg '{"hook_event_name":"PermissionRequest","cwd":"/tmp/project","message":"approve me"}' \
  SORA_AGENT_ID=codex SROTA_TAB_ID=tab-1 SROTA_PANE_ID=pane-1 >/dev/null
wait_for_event_count 2
assert_eq "$(event_count)" "2" "duplicate permission request should still push a socket event"
assert_eq "$(notification_count)" "1" "duplicate permission request should not re-notify within the dedupe window"
printf 'ok 4 - duplicate permission request pushes again but does not re-notify\n'

TRANSCRIPT_PATH="$TMPDIR/transcript.jsonl"
cat >"$TRANSCRIPT_PATH" <<'EOF'
{"type":"event_msg","payload":{"type":"user_message","message":"first prompt"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"text":"latest prompt"}]}}
EOF
run_notify_arg '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/project","message":" ","transcript_path":"'"$TRANSCRIPT_PATH"'"}' \
  SROTA_PANE_ID=pane-1 >/dev/null
wait_for_event_count 3
assert_eq "$(event_count)" "3" "user prompt submit with a pane id should push a socket event"
assert_eq "$(last_event_field event)" "Start" "user prompt submit should map to Start"
assert_eq "$(last_event_field summary)" "latest prompt" "transcript should provide the latest user summary"
assert_eq "$(notification_count)" "1" "Start should not trigger a notification"
printf 'ok 5 - transcript summary is captured and Start does not notify\n'

before="$(event_count)"
run_notify_arg '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/project"}' >/dev/null
assert_eq "$(event_count)" "$before" "an event with no SROTA_PANE_ID should not push to the socket"
printf 'ok 6 - events without a pane id never reach the daemon socket\n'

run_notify_stdin '{"type":"task_complete","working_directory":"/tmp/work","last_assistant_message":"done"}' \
  SROTA_PANE_ID=pane-1 >/dev/null
wait_for_event_count 4
assert_eq "$(event_count)" "4" "task_complete should push a fourth socket event"
assert_eq "$(last_event_field event)" "Stop" "task_complete should map to Stop"
assert_eq "$(notification_count)" "2" "Stop should trigger an idle notification"
assert_file_contains "$TMPDIR/osascript.log" 'idle' "Stop should notify with an idle title"
printf 'ok 7 - task_complete maps to Stop, pushes, and notifies idle\n'

NO_AGENT_DIR="$TMPDIR/no-agent-bin"
mkdir -p "$NO_AGENT_DIR"
ln -s "$(command -v node)" "$NO_AGENT_DIR/node"
not_installed_output="$(env PATH="$NO_AGENT_DIR:/usr/bin:/bin" HOME="$HOME_DIR" "$CHECK_SCRIPT" --notify-script /tmp/fake-notify.sh)"
assert_file_contains <(printf '%s\n' "$not_installed_output") '"claude":"not_installed"' "missing Claude binary should report not_installed"
assert_file_contains <(printf '%s\n' "$not_installed_output") '"codex":"not_installed"' "missing Codex binary should report not_installed"
printf 'ok 8 - hook check reports not installed agents\n'

check_missing_status=0
check_missing_output="$("$CHECK_SCRIPT" --notify-script /tmp/fake-notify.sh 2>"$TMPDIR/check-missing.err")" || check_missing_status=$?
assert_eq "$check_missing_status" "1" "missing hook config should exit 1"
assert_file_contains <(printf '%s\n' "$check_missing_output") '"claude":"missing"' "missing hook config should report missing Claude hooks"
assert_file_contains <(printf '%s\n' "$check_missing_output") '"codex":"missing"' "missing hook config should report missing Codex hooks"
printf 'ok 9 - hook check reports missing config\n'

"$CHECK_SCRIPT" --configure --notify-script /tmp/fake-notify.sh >/dev/null
"$CHECK_SCRIPT" --configure --notify-script /tmp/fake-notify.sh >/dev/null
configured_output="$("$CHECK_SCRIPT" --notify-script /tmp/fake-notify.sh)"
assert_file_contains <(printf '%s\n' "$configured_output") '"claude":"configured"' "configure should wire Claude hooks"
assert_file_contains <(printf '%s\n' "$configured_output") '"codex":"configured"' "configure should wire Codex hooks"
assert_file_contains "$HOME_DIR/.claude/settings.json" 'SORA_AGENT_ID=claude' "Claude config should include the Claude agent id"
assert_file_contains "$HOME_DIR/.claude/settings.json" '/tmp/fake-notify.sh' "Claude config should include the notify script path"
assert_file_contains "$HOME_DIR/.codex/hooks.json" 'SORA_AGENT_ID=codex' "Codex config should include the Codex agent id"
assert_file_contains "$HOME_DIR/.codex/hooks.json" '/tmp/fake-notify.sh' "Codex config should include the notify script path"
# Claude: SessionStart, UserPromptSubmit, Stop, SessionEnd, Notification, PreToolUse, PostToolUse.
assert_eq "$(count_matches "$HOME_DIR/.claude/settings.json" 'SORA_AGENT_ID=claude')" "7" "Claude config should keep one hook per required event"
# Codex keeps its original flat event list: SessionStart, Stop, UserPromptSubmit, PermissionRequest.
assert_eq "$(count_matches "$HOME_DIR/.codex/hooks.json" 'SORA_AGENT_ID=codex')" "4" "Codex config should keep one hook per required event"
assert_file_contains "$HOME_DIR/.claude/settings.json" '"matcher": "permission_prompt"' "Claude Notification hook should carry the permission_prompt matcher"
assert_file_contains "$HOME_DIR/.claude/settings.json" '"matcher": "AskUserQuestion"' "Claude PreToolUse/PostToolUse hooks should carry the AskUserQuestion matcher"
printf 'ok 10 - hook configuration is applied once per event with the right matchers\n'

cat >"$HOME_DIR/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "[ -x \"/tmp/fake-notify.sh\" ] && SORA_AGENT_ID=codex \"/tmp/fake-notify.sh\" || true" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "[ -x \"/tmp/fake-notify.sh\" ] && SORA_AGENT_ID=codex \"/tmp/fake-notify.sh\" || true" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "[ -x \"/tmp/fake-notify.sh\" ] && SORA_AGENT_ID=codex \"/tmp/fake-notify.sh\" || true" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "[ -x \"/tmp/fake-notify.sh\" ] && SORA_AGENT_ID=codex \"/tmp/fake-notify.sh\" || true" }] }]
  }
}
EOF
cat >"$HOME_DIR/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "[ -x \"/tmp/fake-notify.sh\" ] && SORA_AGENT_ID=claude \"/tmp/fake-notify.sh\" || true" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "[ -x \"/tmp/fake-notify.sh\" ] && SORA_AGENT_ID=claude \"/tmp/fake-notify.sh\" || true" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "[ -x \"/tmp/fake-notify.sh\" ] && SORA_AGENT_ID=claude \"/tmp/fake-notify.sh\" || true" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "[ -x \"/tmp/fake-notify.sh\" ] && SORA_AGENT_ID=claude \"/tmp/fake-notify.sh\" || true" }] }]
  }
}
EOF
wrong_agent_status=0
wrong_agent_output="$("$CHECK_SCRIPT" --notify-script /tmp/fake-notify.sh 2>"$TMPDIR/check-wrong-agent.err")" || wrong_agent_status=$?
assert_eq "$wrong_agent_status" "1" "wrong-agent hook config should not be treated as configured"
assert_file_contains <(printf '%s\n' "$wrong_agent_output") '"claude":"missing"' "wrong Claude hook should stay missing"
assert_file_contains <(printf '%s\n' "$wrong_agent_output") '"codex":"missing"' "wrong Codex hook should stay missing"
printf 'ok 11 - wrong-agent hooks are rejected\n'

"$CHECK_SCRIPT" --configure --notify-script /tmp/fake-notify.sh >/dev/null
run_notify_arg '{"type":"exec_approval_request","cwd":"/tmp/second","message":"need approval"}' \
  SORA_AGENT_ID=codex SROTA_TAB_ID=tab-1 SROTA_PANE_ID=pane-2 >/dev/null
wait_for_event_count 5
assert_eq "$(event_count)" "5" "new pane permission request should push a fifth socket event"
assert_eq "$(notification_count)" "3" "new pane permission request should notify again"
printf 'ok 12 - permission requests in a new pane notify again\n'

perf_iters="${PERF_ITERS:-100}"
perf_max_ms="${PERF_MAX_MS:-5000}"
start_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
for _ in $(seq 1 "$perf_iters"); do
  run_notify_arg '{"hook_event_name":"PermissionRequest","cwd":"/tmp/perf","message":"x"}' >/dev/null
done
end_ms="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
elapsed_ms="$((end_ms - start_ms))"
(( elapsed_ms <= perf_max_ms )) || fail "performance regression: ${perf_iters} runs took ${elapsed_ms}ms (budget ${perf_max_ms}ms)"
printf 'ok 13 - performance budget holds (%sms for %s runs)\n' "$elapsed_ms" "$perf_iters"

before="$(event_count)"
run_notify_arg '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/project","session_id":"sess-abc-123"}' \
  SROTA_PANE_ID=pane-session-1 >/dev/null
wait_for_event_count "$((before + 1))"
assert_eq "$(event_count)" "$((before + 1))" "session_id-bearing prompt submit should push a socket event"
assert_eq "$(last_event_field sessionID)" "sess-abc-123" "session_id from the hook payload should forward as sessionID"
printf 'ok 14 - session_id forwards as sessionID when present in the hook payload\n'

before="$(event_count)"
run_notify_arg '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/project"}' \
  SROTA_PANE_ID=pane-session-2 >/dev/null
wait_for_event_count "$((before + 1))"
assert_eq "$(event_count)" "$((before + 1))" "session_id-less prompt submit should still push a socket event"
assert_eq "$(last_event_field sessionID)" "None" "sessionID should be null, not a failure, when the hook payload omits session_id"
printf 'ok 15 - sessionID is null, not a failure, when the hook payload omits session_id\n'

before="$(event_count)"
run_notify_arg '{"hook_event_name":"UserPromptSubmit","cwd":"/tmp/project","prompt":"fix the login bug"}' \
  SROTA_PANE_ID=pane-session-3 >/dev/null
wait_for_event_count "$((before + 1))"
assert_eq "$(event_count)" "$((before + 1))" "prompt-bearing UserPromptSubmit should push a socket event"
assert_eq "$(last_event_field summary)" "fix the login bug" "the prompt field should surface as summary for UserPromptSubmit"
printf 'ok 16 - Claude UserPromptSubmit prompt field is captured as summary\n'
