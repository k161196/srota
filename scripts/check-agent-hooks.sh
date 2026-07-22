#!/bin/bash
# Checks whether Srota's notify hook is wired into Claude and Codex configs.

set -euo pipefail

CONFIGURE=0
NOTIFY_SCRIPT="$(cd "$(dirname "$0")" && pwd)/notify.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configure)
      CONFIGURE=1
      shift
      ;;
    --notify-script)
      NOTIFY_SCRIPT="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CODEX_HOMES=("$HOME/.codex")
for codex_home in "$HOME"/.codex-*; do
  [[ -d "$codex_home" ]] && CODEX_HOMES+=("$codex_home")
done

claude_installed() { command -v claude >/dev/null 2>&1; }
codex_installed() { command -v codex >/dev/null 2>&1; }

hooks_ready() {
  local config_path="$1"
  local agent_id="$2"
  node - "$config_path" "$NOTIFY_SCRIPT" "$agent_id" <<'JS' >/dev/null
const fs = require('fs');
const [,, configPath, notifyScript, agentId] = process.argv;
const required = agentId === "claude"
  ? [
      { event: "SessionStart" },
      { event: "UserPromptSubmit" },
      { event: "Stop" },
      { event: "SessionEnd" },
      { event: "Notification", matcher: "permission_prompt" },
      { event: "PreToolUse", matcher: "AskUserQuestion" },
      { event: "PostToolUse", matcher: "AskUserQuestion" },
    ]
  : [
      { event: "SessionStart" },
      { event: "Stop" },
      { event: "UserPromptSubmit" },
      { event: "PermissionRequest" },
    ];

let data = {};
try {
  data = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch {
  process.exit(1);
}

const hooks = data.hooks ?? {};
const command = `[ -x "${notifyScript}" ] && SORA_AGENT_ID=${agentId} "${notifyScript}" || true`;

function wantedFor(matcher) {
  const entry = { hooks: [{ type: 'command', command }] };
  if (matcher) entry.matcher = matcher;
  return JSON.stringify(entry);
}

function isSrotaHook(entry, matcher) {
  if (!entry || typeof entry !== 'object') return false;
  if ((entry.matcher ?? undefined) !== (matcher ?? undefined)) return false;
  if (!Array.isArray(entry.hooks)) return false;
  return entry.hooks.some((hook) => {
    if (!hook || hook.type !== 'command' || typeof hook.command !== 'string') return false;
    return (
      hook.command === command ||
      (hook.command.includes(`SORA_AGENT_ID=${agentId}`) && hook.command.includes('notify.sh'))
    );
  });
}

const ok = required.every(({ event, matcher }) =>
  Array.isArray(hooks[event]) && hooks[event].some((entry) => isSrotaHook(entry, matcher))
);

process.exit(ok ? 0 : 1);
JS
}

configure_hooks() {
  local config_path="$1"
  local agent_id="$2"
  node - "$config_path" "$NOTIFY_SCRIPT" "$agent_id" <<'JS'
const fs = require('fs');
const path = require('path');
const [,, configPath, notifyScript, agentId] = process.argv;
const required = agentId === "claude"
  ? [
      { event: "SessionStart" },
      { event: "UserPromptSubmit" },
      { event: "Stop" },
      { event: "SessionEnd" },
      { event: "Notification", matcher: "permission_prompt" },
      { event: "PreToolUse", matcher: "AskUserQuestion" },
      { event: "PostToolUse", matcher: "AskUserQuestion" },
    ]
  : [
      { event: "SessionStart" },
      { event: "Stop" },
      { event: "UserPromptSubmit" },
      { event: "PermissionRequest" },
    ];

let data = { hooks: {} };
try {
  data = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch {}

data.hooks ??= {};
const command = `[ -x "${notifyScript}" ] && SORA_AGENT_ID=${agentId} "${notifyScript}" || true`;

function wantedFor(matcher) {
  const entry = { hooks: [{ type: 'command', command }] };
  if (matcher) entry.matcher = matcher;
  return JSON.stringify(entry);
}

for (const { event, matcher } of required) {
  const arr = Array.isArray(data.hooks[event]) ? data.hooks[event] : [];
  const wanted = wantedFor(matcher);
  const kept = [];
  let found = false;

  for (const entry of arr) {
    const isSame = JSON.stringify(entry) === wanted;
    if (isSame) {
      if (!found) {
        kept.push(entry);
        found = true;
      }
      continue;
    }
    kept.push(entry);
  }

  if (!found) {
    kept.push(JSON.parse(wanted));
  }

  data.hooks[event] = kept;
}

fs.mkdirSync(path.dirname(configPath), { recursive: true });
fs.writeFileSync(configPath, JSON.stringify(data, null, 2));
process.stdout.write('ok');
JS
}

CLAUDE_STATUS="not_installed"
CODEX_STATUS="not_installed"
EXIT=0

if claude_installed; then
  if hooks_ready "$CLAUDE_SETTINGS" claude; then
    CLAUDE_STATUS="configured"
  else
    if [[ $CONFIGURE -eq 1 ]]; then
      if configure_hooks "$CLAUDE_SETTINGS" claude >/dev/null; then
        CLAUDE_STATUS="configured"
      else
        CLAUDE_STATUS="configure_failed"
        EXIT=1
      fi
    else
      CLAUDE_STATUS="missing"
      EXIT=1
    fi
  fi
fi

if codex_installed; then
  CODEX_READY=1
  for codex_home in "${CODEX_HOMES[@]}"; do
    hooks_ready "$codex_home/hooks.json" codex || CODEX_READY=0
  done
  if [[ $CODEX_READY -eq 1 ]]; then
    CODEX_STATUS="configured"
  else
    if [[ $CONFIGURE -eq 1 ]]; then
      CODEX_STATUS="configured"
      for codex_home in "${CODEX_HOMES[@]}"; do
        if ! configure_hooks "$codex_home/hooks.json" codex >/dev/null; then
          CODEX_STATUS="configure_failed"
          EXIT=1
        fi
      done
    else
      CODEX_STATUS="missing"
      EXIT=1
    fi
  fi
fi

printf '{"claude":"%s","codex":"%s","notifyScript":"%s"}\n' \
  "$CLAUDE_STATUS" "$CODEX_STATUS" "$NOTIFY_SCRIPT"
exit $EXIT
