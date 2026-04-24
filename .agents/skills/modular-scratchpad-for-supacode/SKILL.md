---
name: modular-scratchpad-for-supacode
description: Implements the Scratch Pad feature in Supacode as a modular, rebase-friendly TCA feature supporting both global and per-worktree scopes. Use when building Scratch Pad UI, reducer/state, persistence, file integration, shortcuts, and tests.
---

# Modular Scratch Pad for Supacode

Use this skill to implement Scratch Pad in small, merge-safe slices that are easy to rebase on upstream `main`.

## Goals

- Add a developer-style Markdown scratch editor with tabs.
- Support both scopes:
  - `global`
  - `worktree(worktreeID)`
- Keep implementation modular and isolated under `supacode/Features/ScratchPad`.
- Minimize conflict risk with upstream by making small, focused integration edits.

## Constraints (project-specific)

- Target macOS 26+, Swift 6.
- TCA state uses `@ObservableState`.
- Non-TCA stores use `@Observable @MainActor` (avoid `ObservableObject`).
- Use `SupaLogger` for logs.
- Add reducer tests for logic changes.
- Use `TestClock` in tests (never `Task.sleep`).
- Build before finishing: `make build-app`.

## Branch and rebase workflow

- Work from a dedicated feature branch (not `main`), e.g. `feature/scratch-pad`.
- Rebase frequently:

```bash
git fetch upstream
git rebase upstream/main
```

- Keep PRs small by slice.

## Fresh-context bootstrap (run this at the start of each new agent window)

1. Confirm branch and status:

```bash
git branch --show-current
git status --short
```

2. Refresh code map for integration points:

```bash
rg -n "WorktreeDetailView|AppFeature|TerminalCommands|FocusedValueKey|Markdown|TextEditor" supacode
```

3. Re-read the primary files before editing:
- `supacode/Features/Repositories/Views/WorktreeDetailView.swift`
- `supacode/Features/App/Reducer/AppFeature.swift`
- `supacode/Commands/TerminalCommands.swift`
- `supacode/Support/PlainTextEditor.swift`

4. Re-state current slice and acceptance criteria in 3-5 bullets before coding.

## File/module layout

Create and keep most changes inside:

- `supacode/Features/ScratchPad/Reducer/ScratchPadFeature.swift`
- `supacode/Features/ScratchPad/Views/ScratchPadView.swift`
- `supacode/Features/ScratchPad/Views/ScratchPadTabStripView.swift`
- `supacode/Features/ScratchPad/Views/ScratchPadStatusBarView.swift`
- `supacode/Features/ScratchPad/Models/ScratchPadScope.swift`
- `supacode/Features/ScratchPad/Models/ScratchPadNote.swift`
- `supacode/Features/ScratchPad/Clients/ScratchPadStorageClient.swift`
- `supacode/Features/ScratchPad/Clients/ScratchPadFileClient.swift`
- `supacode/Features/ScratchPad/BusinessLogic/ScratchPadPathValidation.swift`
- `supacodeTests/ScratchPad/*`

## Architecture plan

### 1) Scope model (supports both global + per-worktree)

```swift
enum ScratchPadScope: Hashable, Codable, Sendable {
  case global
  case worktree(Worktree.ID)
}
```

State shape (example):

- `notesByID: IdentifiedArrayOf<ScratchPadNote>` or `[Note.ID: ScratchPadNote]`
- `tabsByScope: [ScratchPadScope: [ScratchPadNote.ID]]`
- `activeTabByScope: [ScratchPadScope: ScratchPadNote.ID]`
- `modeByScope: [ScratchPadScope: ScratchPadViewMode]` (or single global mode)
- `currentScope: ScratchPadScope`

### 2) Editor capabilities

- Plain text editor (use existing `PlainTextEditor` for MVP).
- 3 modes: `edit`, `split`, `preview`.
- Markdown preview can start simple (SwiftUI text rendering) and be upgraded later.
- Persist mode key using app storage (compatible naming):
  - `echo-scratch-mode`

### 3) Multi-tab behavior

- New tab, close tab, middle-click close.
- Reuse existing empty untitled tab when creating a new blank tab.
- Keep at least one tab always open.
- Tab title resolution:
  - file basename when linked file exists
  - else first markdown line
  - else `untitled`

### 4) Persistence and autosave

- Implement local-first persistence in a dedicated storage client.
- Debounced autosave: 400ms.
- On tab switch, flush pending edit first.
- Persist tabs and active tab keys:
  - `echo-scratch-tabs`
  - `echo-scratch-active-tab`
- Include migration support:
  - `echo-scratch-content`
  - legacy note id `scratch`

### 5) File integration (wiki bridge)

Add `ScratchPadFileClient` to handle open/save Markdown files from a configurable root.

Validation rules:
- relative path only
- reject `.` and `..` path components
- reject null chars
- require `.md` suffix

Behavior:
- Open file -> if already open in another tab, switch to that tab.
- Save flow:
  1. persist note locally
  2. if `filePath` exists, sync to disk
- track `syncedAt` and sync error state.

### 6) Shortcuts

Editor-scoped commands:
- Cmd/Ctrl + B: wrap with `**`
- Cmd/Ctrl + I: wrap with `*`
- Cmd/Ctrl + K: wrap with `` ` ``
- Cmd/Ctrl + /: cycle view mode
- Cmd/Ctrl + O: toggle file browser
- Cmd/Ctrl + N or Cmd/Ctrl + T: new tab
- Cmd/Ctrl + W: close active tab
- Cmd/Ctrl + Shift + S: Save As
- Cmd/Ctrl + S: save/sync now (or open Save As if no file path)

Use focused values + command wiring like existing terminal/worktree command patterns.

### 7) UX/status features

- Status line includes:
  - line/word/char counts
  - current file path
  - tab count
  - encoding/lang labels
- Sync chip states:
  - saved, saving/editing, syncing, synced, failed
- Dirty indicators on tabs.
- Confirm close for untitled draft with content.

## Minimal integration points (keep diffs small)

1. `WorktreeDetailView.swift`
- Add view switch to display Scratch Pad in detail pane.

2. `AppFeature.swift`
- Add child state/action scope for Scratch Pad.

3. `Commands/*`
- Add focused actions for Scratch Pad shortcuts only.

Avoid broad refactors outside these files.

## Delivery slices (preferred PR sequence)

### Slice 1: Core models + reducer skeleton + storage client
- Add basic scope model and note/tab state.
- Add tests for tab invariants and mode persistence.

### Slice 2: Editor + tabs + autosave
- Add edit/split/preview shell.
- Debounced autosave with `TestClock` tests.

### Slice 3: Dual scope UX
- Add Global/Worktree scope selector.
- Persist active tab per scope.

### Slice 4: File bridge
- Open/save/save-as + path validation + sync states.

### Slice 5: Shortcuts + statusline + polish
- Focused command wiring and UX completion.

## Testing checklist per slice

- Tab lifecycle invariants (never zero tabs).
- Empty-tab reuse logic.
- Autosave debounce behavior.
- Flush-on-switch behavior.
- Migration correctness.
- Path validation acceptance/rejection cases.
- Existing-open-file tab dedup behavior.
- Save/sync state transitions and failures.

## Done criteria

- Builds successfully: `make build-app`
- Relevant tests pass: `make test` (or targeted `xcodebuild test -only-testing:...` while iterating)
- Diff remains modular and rebase-friendly
- Changes are split into focused commits for clean PR review
