# Worktrees

Each sidebar row under a repository is a git worktree. Users create worktrees on new branches, pin them, customize their sidebar title and tint, archive them, and delete them, and each change shows in the sidebar and on disk.

## Sub-features

- `wt-new` creates a worktree on a new branch from a base ref.
- `wt-focus` selects a worktree in the sidebar.
- `wt-pin` pins and unpins a worktree.
- `wt-appearance` sets a sidebar title or tint override.
- `wt-archive` archives and unarchives a worktree.
- `wt-delete` deletes the worktree folder (and its branch when `deleteBranchOnDeleteWorktree` is set).

## How to get to it (user POV)

- Choose `New Worktree…` (`⌘N`) from the `Worktrees` menu.
- Choose `Archive Worktree…` (`⌘⌫`), `Delete Worktree…`, or `Customize Appearance…` from the menu bar or the sidebar row's context menu.
- Choose `Archived Worktrees` (`⌘⌃A`) to see archived rows.
- Run `supacode repo worktree-new` or `supacode worktree focus|pin|unpin|appearance|archive|unarchive|delete|status|list`.

## Driving it with supacode-verify

Preconditions:

- Doctor passes. The seed config sets `promptForWorktreeCreation` and `fetchOriginBeforeWorktreeCreation` to false, so creation needs no dialog and no network.
- `R="$($S cli <run> -- repo list | head -1)"` holds the seed repository id.

- **Create.** Run `NW="$($S cli <run> -- repo worktree-new -r "$R" --branch verify-wt)"`. Stdout is the new worktree id. Running `git -C /tmp/sv-<run>/seed-repo worktree list` shows `/private/tmp/sv-<run>/worktrees/seed-repo/verify-wt <sha> [verify-wt] locked`. The new worktree takes focus, so the AX `window` name becomes `seed-repo · /t/s/w/s/verify-wt`, and `$S ax <run> wt-created` has a `treeitem` named `verify-wt`.
- **Status.** Run `$S cli <run> -- worktree status -w "$NW"`. It prints `status=`, `archived=false`, and `focused=` lines.
- **Pin.** Run `$S cli <run> -- worktree pin -w "$NW"`. `worktree list --status pinned` includes `$NW`.
- **Appearance.** Run `$S cli <run> -- worktree appearance -w "$NW" --title "Verify Row" --tint teal`. The AX `treeitem` reads `Verify Row`, and the screenshot shows a teal row. Running `appearance -w "$NW"` with no flags prints the stored overrides.
- **Archive.** Run `$S cli <run> -- worktree archive -w "$NW"`. `worktree list --not-archived` no longer includes it, and `worktree status` prints `archived=true`.
- **Delete.** Run `$S cli <run> -- worktree delete -w "$NW"`. `git worktree list` no longer shows `verify-wt`, and its folder is gone.

## Gotchas

- Worktree ids are percent-encoded absolute paths with a trailing `%2F`. Copy them from CLI output.
- `--status` takes `main|pinned|unpinned|archived`, comma separated. Bare `--status` is an error.
- Archive and delete may present a confirmation sheet depending on settings. If the CLI times out, snapshot `--surface sheet` on the run's window and report it.
- Git reports paths under `/private/tmp`, the resolved form of `/tmp`. Match on the suffix.
- Supacode locks the worktrees it creates (`locked` in `git worktree list`). Plain `git worktree remove` refuses them. Delete through the app.
- Creation output and the git side effect were observed on a run. Pin, appearance, archive, and delete have not been driven yet. Fix this file if they differ.
