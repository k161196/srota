#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
content="$root/srota/srota/ContentView.swift"
db="$root/srota/srota/WorkspaceDB.swift"

grep -q 'deleteTabs(workspaceID: id)' "$db"
grep -q 'onClose: { tab.closePrimaryPane(); onPaneResizeFinished() }' "$content"
grep -q 'onClose: { tab.removePane(id: entry.id); onPaneResizeFinished() }' "$content"
grep -q 'tab.primaryExited = primary.lw == 0 || primary.lh == 0' "$content"
grep -q 'is_pinned INTEGER NOT NULL DEFAULT 0' "$db"
grep -q 'showWorkspaceSwitcher || showLazygit' "$root/srota/srota/KeyboardShortcuts.swift"
grep -q 'showAll.toggle(); level = .workspaces; highlighted = 0' "$root/srota/srota/KeyboardShortcuts.swift"
grep -q 'func selectWorkspace(id: UUID)' "$content"
