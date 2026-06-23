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
CODEX_HOOKS="$HOME/.codex/hooks.json"
REQUIRED_EVENTS=("SessionStart" "Stop" "UserPromptSubmit" "PermissionRequest")

claude_installed() { command -v claude >/dev/null 2>&1; }
codex_installed() { command -v codex >/dev/null 2>&1; }

hooks_ready() {
  local config_path="$1"
  local root_expr="$2"
  node - "$config_path" "$NOTIFY_SCRIPT" "$root_expr" <<'JS' >/dev/null
const fs = require('fs');
const [,, configPath, notifyScript, rootExpr] = process.argv;
const required = ['SessionStart', 'Stop', 'UserPromptSubmit', 'PermissionRequest'];

let data = {};
try {
  data = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch {
  process.exit(1);
}

const hooks = rootExpr === 'hooks' ? (data.hooks ?? {}) : {};
const wanted = notifyScript;

function isSrotaHook(entry) {
  return JSON.stringify(entry).includes(wanted);
}

const ok = required.every((event) =>
  Array.isArray(hooks[event]) && hooks[event].some(isSrotaHook)
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
const required = ['SessionStart', 'Stop', 'UserPromptSubmit', 'PermissionRequest'];

let data = { hooks: {} };
try {
  data = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch {}

data.hooks ??= {};

const command = `[ -x "${notifyScript}" ] && SORA_AGENT_ID=${agentId} "${notifyScript}" || true`;
const wanted = JSON.stringify({ hooks: [{ type: 'command', command }] });

for (const event of required) {
  const arr = Array.isArray(data.hooks[event]) ? data.hooks[event] : [];
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
    kept.push({ hooks: [{ type: 'command', command }] });
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
  if hooks_ready "$CLAUDE_SETTINGS" hooks; then
    CLAUDE_STATUS="configured"
  elif [[ $CONFIGURE -eq 1 ]] && [[ "$(configure_hooks "$CLAUDE_SETTINGS" claude 2>&1)" == "ok" ]]; then
    CLAUDE_STATUS="configured"
  elif [[ $CONFIGURE -eq 1 ]]; then
    CLAUDE_STATUS="configure_failed"
    EXIT=1
  else
    CLAUDE_STATUS="missing"
    EXIT=1
  fi
fi

if codex_installed; then
  if hooks_ready "$CODEX_HOOKS" hooks; then
    CODEX_STATUS="configured"
  elif [[ $CONFIGURE -eq 1 ]] && [[ "$(configure_hooks "$CODEX_HOOKS" codex 2>&1)" == "ok" ]]; then
    CODEX_STATUS="configured"
  elif [[ $CONFIGURE -eq 1 ]]; then
    CODEX_STATUS="configure_failed"
    EXIT=1
  else
    CODEX_STATUS="missing"
    EXIT=1
  fi
fi

printf '{"claude":"%s","codex":"%s","notifyScript":"%s"}\n' \
  "$CLAUDE_STATUS" "$CODEX_STATUS" "$NOTIFY_SCRIPT"

exit $EXIT
