# Ubiquitous Language — Srota

## Structure

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Workspace** | A named, independently selectable terminal session group shown in the sidebar | Project, session, window |
| **Folder** | A collapsible sidebar grouping that contains one or more **Workspaces** | Group, category |
| **Tab** | A single terminal context within a **Workspace**, shown in the tab bar | Screen, panel |
| **Pane** | One terminal process surface within a **Tab**, produced by splitting | Split, tile, cell |
| **Primary Pane** | The first **Pane** in a **Tab**, present before any split occurs | Root pane, main pane |
| **Secondary Pane** | Any **Pane** added by splitting; identified by UUID | Child pane, split pane |
| **Split** | The act of dividing a **Pane** into two — either horizontally (bottom) or vertically (right) | Fork, divide |

## Layout

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Sidebar** | The left panel listing **Folders** and unfiled **Workspaces** | Drawer, nav, panel |
| **Tab Bar** | The horizontal bar at the top of the content area showing **Tabs** for the active **Workspace** | Toolbar, header |
| **Pane Header** | The drag-handle bar above each **Pane** showing its name | Title bar |
| **Sidebar Divider** | The draggable 1px border between the **Sidebar** and content area | Resize handle |

## Naming

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Custom Name** | A user-set name that overrides all computed names; cleared by emptying the field | Manual name, label |
| **Smart Title** | An auto-computed name derived from CWD: shows `repo/branch` for git repos, `…/parent/dir` otherwise | Auto title, dynamic title |
| **Tab Display Name** | The resolved name shown on a **Tab** chip: **Custom Name** → focused **Pane**'s name → **Smart Title** | Tab title |
| **Pane Name** | A **Custom Name** set on a specific **Pane**; feeds into **Tab Display Name** when no tab-level name is set | Split label |

## Shell integration

| Term | Definition | Aliases to avoid |
|------|-----------|-----------------|
| **Shell Integration** | The setup that injects OSC 7 CWD reporting into new shells via ZDOTDIR | Shell hook |
| **OSC 7** | The terminal escape sequence (`\033]7;file://…\007`) a shell emits to report its current directory | CWD escape, directory report |
| **CWD** | The current working directory reported by the shell via OSC 7; used to compute **Smart Title** and to seed new **Panes** | Working directory, pwd |
| **ZDOTDIR Launcher** | The `~/.srota/zsh-launcher.sh` script that sets `ZDOTDIR` before exec-ing zsh, enabling **Shell Integration** without modifying user dotfiles | Shell wrapper |

## Relationships

- A **Folder** contains zero or more **Workspaces**; unfiled **Workspaces** belong to no **Folder**
- A **Workspace** contains one or more **Tabs**; closing the last **Tab** leaves the **Workspace** empty (not deleted)
- A **Tab** always has exactly one **Primary Pane** and zero or more **Secondary Panes**
- A **Pane** inherits the **CWD** of the **Pane** that spawned it at creation time
- **Tab Display Name** resolution order: tab **Custom Name** → focused **Pane Name** → **Smart Title**

## Example dialogue

> **Dev:** "When the user splits right, which directory does the new **Pane** open in?"
>
> **Domain expert:** "It inherits the **CWD** of the **Pane** that was focused at split time — not the **Tab**'s CWD."
>
> **Dev:** "And the **Tab Display Name** — does it update when focus moves to the new **Pane**?"
>
> **Domain expert:** "Yes, unless the **Tab** has a **Custom Name**. If it does, the name is frozen until the user clears it. Otherwise it pulls the focused **Pane Name**, or falls back to the **Smart Title** from the new **Pane**'s **CWD**."
>
> **Dev:** "If I drag a **Workspace** from a **Folder** to the WORKSPACES header, where does it go?"
>
> **Domain expert:** "It becomes unfiled — no **Folder** at all. The **Folder** only gets deleted if the user explicitly removes it and it's already empty."

## Flagged ambiguities

- **"split"** was used as both a noun (*"close this split"*) and a verb (*"split right"*) — prefer **Pane** as the noun and **split** only as the verb action.
- **"tab"** was occasionally used to mean the whole terminal area — always means the **Tab** chip/context, never the **Workspace**.
- **"rename"** applies to **Workspaces**, **Folders**, **Tabs** (sets **Custom Name**), and **Panes** (sets **Pane Name**) — these are distinct operations on distinct objects; qualify with the target entity.
