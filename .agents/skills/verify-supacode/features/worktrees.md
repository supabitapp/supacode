# Worktrees

Each sidebar row under a repository is a git worktree. Users create worktrees on new branches, pin them, customize their sidebar title and tint, archive them, and delete them, and each change shows in the sidebar and on disk.

## Sub-features

- `wt-new` creates a worktree on a new branch from a base ref.
- `wt-focus` selects a worktree in the sidebar.
- `wt-pin` pins and unpins a worktree.
- `wt-appearance` sets a sidebar title or tint override.
- `wt-archive` archives and unarchives a worktree.
- `wt-delete` deletes the worktree folder and its local branch. `Delete local branch with worktree` (`deleteBranchOnDeleteWorktree`) is on by default.

## How to get to it (user POV)

- Choose `New Worktree…` (`⌘N`) from the `Worktrees` menu.
- Choose `Archive Worktree…` (`⌘⌫`), `Delete Worktree…`, or `Customize Appearance…` from the menu bar or the sidebar row's context menu.
- Choose `Archived Worktrees` (`⌘⌃A`) to see archived rows.
- Run `supacode repo worktree-new` or `supacode worktree focus|pin|unpin|appearance|archive|unarchive|delete|status|list`.

## Driving it with supacode-verify

Preconditions:

- Doctor passes. The seed config sets `promptForWorktreeCreation` and `fetchOriginBeforeWorktreeCreation` to false, so creation needs no dialog and no network.
- `R="$($S cli <run> -- repo list | head -1)"` holds the seed repository id, and `M="$($S cli <run> -- worktree list --status main | head -1)"` holds the main worktree id.

- **Create.** Run `NW="$($S cli <run> -- repo worktree-new -r "$R" --branch verify-wt)"`. Stdout is the new worktree id. Running `git -C /tmp/sv-<run>/seed-repo worktree list` shows `/private/tmp/sv-<run>/worktrees/seed-repo/verify-wt <sha> [verify-wt] locked`. The new worktree takes focus, so the AX `window` name becomes `seed-repo · /t/s/w/s/verify-wt`, and `$S ax <run> wt-created` has a `treeitem` named `verify-wt`.
- **Status.** Run `$S cli <run> -- worktree status -w "$NW"`. It prints `status=unpinned`, `archived=false`, and `focused=true`.
- **Focus.** Run `$S cli <run> -- worktree focus -w "$M"`. `worktree list -f` prints `$M`.
- **Pin.** Run `$S cli <run> -- worktree pin -w "$NW"`. `worktree list --status pinned` includes `$NW`, and `worktree status` prints `status=pinned`. With View › `Group Pinned Rows` on (the default; the run keeps the user's `sidebarGroupPinnedRows` UserDefault), a pinned row moves to a `Pinned` section (an AX `heading`) at the top of the sidebar. Trust the CLI status either way. Run `$S cli <run> -- worktree unpin -w "$NW"`, and `worktree status` prints `status=unpinned` again.
- **Appearance.** Run `$S cli <run> -- worktree appearance -w "$NW" --title "Verify Row" --color teal`. Running `appearance -w "$NW"` with no flags prints `title=Verify Row`, `color=teal`, and `displayTitle=Verify Row`. Focus `$M` first so the row is not drawn selected, then `$S ax <run> wt-appearance` has a `treeitem` named `Verify Row verify-wt`, and `$S shot <run> wt-appearance` shows the title text in teal.
- **Archive.** Run `$S cli <run> -- worktree pin -w "$NW"` again and confirm `status=pinned`, so unarchive can prove the pin is dropped. Then run `$S cli <run> -- worktree archive -w "$NW"`. No sheet appears. `worktree list --not-archived` no longer includes it, `worktree status` prints `status=archived`, `archived=true`, and `focused=false`, and the sidebar AX tree drops the row. `git worktree list` still lists it, and its folder stays on disk.
- **Unarchive.** Run `$S cli <run> -- worktree unarchive -w "$NW"`. `worktree status` prints `status=unpinned` and `archived=false`, even if the row was pinned before archiving.
- **Delete.** Confirm `git -C "$SEED_REPO" branch --list verify-wt` prints the branch, then run `$S cli <run> -- worktree delete -w "$NW"`. `git -C "$SEED_REPO" worktree list` no longer shows `verify-wt`, its folder is gone, the same `branch --list` prints nothing, and `worktree status -w "$NW"` fails with `Worktree not found: <id>`.

## Gotchas

- Worktree ids are percent-encoded absolute paths with a trailing `%2F`. Copy them from CLI output.
- `--status` takes `main|pinned|unpinned|archived`, comma separated. Bare `--status` is an error, and so is combining `--status` with `--not-archived`. `--with-status` prints `<id><TAB><status>`.
- The option is `--color`, not `--tint`. It takes `red|orange|yellow|green|teal|blue|purple`, `#RRGGBB[AA]`, or `none`. An unknown value fails in the CLI with exit `64`.
- Sidebar `treeitem` names join the title and subtitle. While a second worktree sits unpinned in the same section, the main row reads `main Default`. A row in the `Pinned` section also names its repo in the subtitle, such as `Verify Row seed-repo, verify-wt`.
- Under the seed config, `Allow dangerous actions` is `CLI only`, so CLI archive and delete run without a confirmation sheet. If the CLI times out, snapshot `--surface sheet` on the run's window and report it.
- `worktree pin` on the main worktree exits `0` and leaves `status=main`. Archiving the main worktree fails with exit `1` (`Archiving the main worktree is not allowed.`) and leaves an alert in the main window. Dismiss it as described in `SKILL.md` under Alerts.
- Git reports paths under `/private/tmp`, the resolved form of `/tmp`. Match on the suffix.
- Supacode locks the worktrees it creates (`locked` in `git worktree list`). Plain `git worktree remove` refuses them. Delete through the app.
