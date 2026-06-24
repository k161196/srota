# Issues Agent Terminal — Design Spec

**Date:** 2026-06-24  
**Status:** Approved

## Overview

Refactor `IssuesPanel` to mirror `FeaturesPanel`: a 3-column layout with a persistent tabbed terminal center scoped to individual issues. Each issue can be opened into its own agent terminal session with injected context (CLAUDE.md / AGENTS.md) and MCP server config.

---

## Architecture & State

Two new types mirroring `FeatureAgentFocus` / `FeatureAgentTab`:

```swift
struct IssueAgentTab: Identifiable {
    let id: String        // "global" or issue.id
    let issueID: String?  // nil = global tab
    let tab: TerminalTab
}

@Observable @MainActor
final class IssueAgentFocus {
    var activeViewState: TerminalViewState?
    var agentTabs: [IssueAgentTab] = []
    var activeTabID: String = "global"
}
```

`IssueAgentFocus` is added to the SwiftUI environment in `srotaApp.swift`, same as `FeatureAgentFocus`.

### ManagementPanel persistence

`IssuesPanel` must be kept alive in the ZStack hierarchy (same trick as `FeaturesPanel`) so `TerminalSurfaceView` instances are never destroyed during tab switches:

```swift
ZStack {
    FeaturesPanel()
        .opacity(tab == .features ? 1 : 0)
        .allowsHitTesting(tab == .features)
    IssuesPanel()
        .opacity(tab == .issues ? 1 : 0)
        .allowsHitTesting(tab == .issues)
    if tab != .features && tab != .issues {
        switch tab {
        case .workspaces:    EmptyView()
        case .organizations: OrganizationsPanel()
        case .projects:      ProjectsPanel()
        case .repos:         ReposPanel()
        default:             EmptyView()
        }
    }
}
```

---

## Layout & Components

3-column `HSplitView`:

```
[ Issue List 200-260pt ] | [ Agent Terminal Center (flex) ] | [ IssueInfoSidebar 300-480pt ]
```

The sidebar is only shown when `activeTabID != "global"`.

### Left — Issue list panel

- Header: "Issues" label + count badge + `+` button (opens existing add-issue sheet)
- `SelectableRow` per issue:
  - Primary: `issue.title`
  - Secondary: context label (org · feature, same as current `IssuesPanel`)
  - Trailing: `StatusBadge`
- Tap → `openTab(for: issue)` — creates tab if not present, switches to it if already open
- Delete on hover (trash icon)

### Center — Agent terminal center

Identical structure to `featureAgentCenter` in `FeaturesPanel`:

- Horizontal scrolling tab chips (`FeatureTabChip` reused):
  - "Issues" — global tab, non-closeable, always first
  - One chip per open issue — closeable
- `FeatureTerminalStack` reused directly, fed `IssueAgentTab` tabs

### Right — `IssueInfoSidebar`

Shown only when an issue tab is active. Contains:

- **Header:** editable `TextField` for issue title + refresh button
- **Status:** segmented `Picker` (open / in_progress / closed)
- **Body:** `TextEditor` (monospaced, min 120pt)
- **Linked feature:** read-only label (feature name, or "—" if none)
- **Linked org:** read-only label
- **Save button** (bottom bar) → `db.updateIssue()`

No issue creation from sidebar — the list panel `+` handles that.

---

## Context Injection

When `openTab(for: issue)` is called, inject into CLAUDE.md and AGENTS.md in every repo path associated with the issue's linked feature (via `db.featureRepos` → `db.repos`). If no feature is linked, the terminal opens with no CWD and no file injection.

### Injected block

```
<!-- srota:start -->
## Issue Context (srota)
**Issue:** [title]
**ID:** `[issue.id]`
**Status:** [status]
**Feature:** [feature.name or "none"]
**Org:** [org.name or "none"]

**Body:**
[body or "_(none yet)_"]

## srota MCP Tools
MCP server `srota` is available:
- `srota:update_issue(id, title?, body?, status?)` — update this issue
- `srota:list_issues(feature_id?)` — list issues
- `srota:list_features()` — list features
- `srota:link_issue_to_feature(issue_id, feature_id)` — link to feature

Current issue ID for MCP calls: `[issue.id]`
<!-- srota:end -->
```

### MCP config

`injectMCPConfig` / `removeMCPConfig` reused from `FeaturesPanel` (Claude `.claude/settings.json` + Codex `.codex/config.toml`).

### Cleanup

On `closeTab(_:)` → `removeContext(from:)` strips the srota block from CLAUDE.md / AGENTS.md and removes MCP config. Uses the same `replaceBlock` / `replaceTomlBlock` helpers.

### Re-injection on DB change

`.onChange(of: db.issues)` triggers `reinjectOpenTabs()` — same pattern as features, keeps context current if issue title/status/body changes while tab is open.

---

## Files Affected

| File | Change |
|------|--------|
| `ManagementView.swift` | Refactor `IssuesPanel` into 3-column layout; add `IssueAgentFocus`/`IssueAgentTab`; update `ManagementPanel` ZStack |
| `srotaApp.swift` | Add `IssueAgentFocus` to environment |

No new files. All new code goes into `ManagementView.swift` alongside the existing Features implementation.

---

## Out of Scope

- Persistence of open issue tabs across app restarts (features don't persist tabs either)
- Issue creation from the sidebar
- Cross-issue terminal sharing
