#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
content="$root/srota/srota/ContentView.swift"
db="$root/srota/srota/WorkspaceDB.swift"

grep -q 'deleteTabs(workspaceID: id)' "$db"
grep -q 'onClose: { tab.closePrimaryPane(); onPaneResizeFinished() }' "$content"
grep -q 'onClose: { tab.removePane(id: entry.id); onPaneResizeFinished() }' "$content"
grep -q 'tab.primaryExited = primary.lw == 0 || primary.lh == 0' "$content"
