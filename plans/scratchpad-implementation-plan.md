# Scratch Pad Implementation Plan (Supacode)

## Goal
Implement a modular Scratch Pad feature in Supacode with a developer-focused Markdown editing experience, multi-tab buffers, autosave, file integration, and keyboard shortcuts.

## Scope
Support both:
- **Global Scratch Pad**
- **Per-worktree Scratch Pad**

Use a unified scope model so both behaviors are first-class without duplicate code paths.

---

## Architecture

### 1) Feature module (isolated)
Create and keep most code inside:

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

### 2) Scope model
```swift
enum ScratchPadScope: Hashable, Codable, Sendable {
  case global
  case worktree(Worktree.ID)
}
```

### 3) State shape
- `notesByID`
- `tabsByScope`
- `activeTabByScope`
- `modeByScope` (or one global mode)
- `currentScope`

---

## Core capabilities

### Editor and views
- Plain text markdown editor (start with existing `PlainTextEditor`)
- 3 modes: `edit`, `split`, `preview`
- Mode persistence key: `echo-scratch-mode`

### Multi-tab buffers
- New tab, select tab, close tab, middle-click close
- Reuse existing blank untitled tab
- Keep at least one tab open at all times
- Tab title priority:
  1. file basename (if linked to file)
  2. first markdown line
  3. `untitled`
- Persist tabs and active tab:
  - `echo-scratch-tabs`
  - `echo-scratch-active-tab`

### Persistence/autosave
- Local-first persistence
- Debounced autosave: **400ms**
- Flush pending edits on tab switch
- Migrate legacy data:
  - `echo-scratch-content`
  - legacy note ID `scratch`

### File integration (wiki bridge)
- Open/save `.md` files from configurable root
- If file already open in another tab, switch to that tab
- Save flow:
  1. Save note locally
  2. If file path exists, sync to disk
- Track `syncedAt` and sync errors

### Path validation
- Relative paths only
- Reject `.` / `..`
- Reject null chars
- Must end with `.md`

### Shortcuts
- Cmd/Ctrl+B: bold wrap `**`
- Cmd/Ctrl+I: italic wrap `*`
- Cmd/Ctrl+K: code wrap `` ` ``
- Cmd/Ctrl+/: cycle mode
- Cmd/Ctrl+O: toggle file browser
- Cmd/Ctrl+N or Cmd/Ctrl+T: new tab
- Cmd/Ctrl+W: close tab
- Cmd/Ctrl+Shift+S: Save As
- Cmd/Ctrl+S: save now (or Save As when no file path)

### UX/status
- Statusline with line/word/char counts, file path, tab count, labels
- Sync chip states: saved / saving / syncing / synced / failed
- Dirty indicators on tabs
- Confirm close for untitled draft with content

---

## Integration points (minimal)
Only touch these existing areas:
1. `supacode/Features/Repositories/Views/WorktreeDetailView.swift`
   - show Scratch Pad view in detail area (with scope selector)
2. `supacode/Features/App/Reducer/AppFeature.swift`
   - add Scratch Pad state/action scope
3. `supacode/Commands/*`
   - focused shortcuts/actions for Scratch Pad

Keep upstream conflict surface small.

---

## Delivery slices

### Slice 1: Foundation
- Models + reducer skeleton + storage client
- Tests for tab invariants + mode persistence

### Slice 2: Core editing
- Editor + tabs + autosave debounce
- Tests for autosave and flush-on-switch

### Slice 3: Dual-scope UX
- Global/worktree scope selector
- Per-scope active tab persistence

### Slice 4: File bridge
- Open/save/save-as, validation, sync status

### Slice 5: Polish
- Shortcuts, statusline, dirty/sync indicators, edge cases

---

## Testing requirements
- Use `TestClock` (no `Task.sleep`)
- Add reducer tests for all new logic
- Cover:
  - never-zero-tabs invariant
  - blank-tab reuse
  - autosave debounce
  - flush on switch
  - migration correctness
  - path validation cases
  - dedupe when opening file already in tabs
  - save/sync state transitions and errors

---

## Rebase-safe workflow
- Use dedicated feature branch
- Rebase often with upstream:
```bash
git fetch upstream
git rebase upstream/main
```
- Keep commits/PRs small and focused by slice
- Avoid unrelated formatting churn

---

## Validation gates
Before finishing a slice:
```bash
make build-app
make test
```
(Use targeted tests during iteration; full checks before handoff/PR.)
