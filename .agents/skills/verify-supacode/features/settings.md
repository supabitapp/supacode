# Settings

The Settings window has sections for general behavior, the terminal, notifications, worktrees, developer options, git forges, shortcuts, global scripts, the license, and updates, plus per-repository settings. Changes persist to `config.json` (global) and to `supacode.json` or `repos.json` (per repository).

## Sub-features

- `settings-open` opens the Settings window at a section.
- `settings-repo` opens repository-specific settings and scripts.
- `settings-persist` writes changed values to the isolated config.

## How to get to it (user POV)

- Choose `Settings...` (`⌘,`) from the app menu.
- Choose `Review in Settings` on the sidebar's `Advanced agent integration` card. It opens the Developer section.
- Run `supacode settings [general|notifications|worktrees|developer|shortcuts|scripts|updates|forges]` or `supacode settings repo [scripts] -r <repo id>`. `github` is a hidden alias for `forges`.

## Driving it with supacode-verify

Preconditions:

- Doctor passes.
- `R="$($S cli <run> -- repo list | head -1)"` holds the seed repository id.

- **Open a section.** Run `$S cli <run> -- settings worktrees`. Exit `0`. `$S windows <run>` shows a second window titled after the section label, `Worktrees`. Each verb sets the title to its sidebar label: `scripts` is `Global Scripts`, and `forges` and `github` are `Git Forges`.
- **Inspect.** Run `SW="$($S windows <run> | awk -F'\t' '$2=="Worktrees"{print $1}')"`, then `$S ax <run> settings "$SW"` and `$S shot <run> settings "$SW"`. The sidebar `cell` items are `General`, `Terminal`, `Notifications`, `Worktrees`, `Developer`, `Git Forges`, `Shortcuts`, `Global Scripts`, `License`, and `Updates`, followed by a `Local` heading.
- **Persist.** In the Worktrees section, find the switch with `agent-desktop find --window-id "$SW" --role switch --name 'Prompt for branch name on creation'` and run `agent-desktop toggle <ref>`. `jq .promptForWorktreeCreation /tmp/sv-<run>/xdg/supacode/config.json` goes from `false` to `true`. Toggle it back.
- **Repo settings.** Run `$S cli <run> -- settings repo -r "$R"`. The Settings window title becomes `seed-repo`. `settings repo scripts -r "$R"` makes it `seed-repo — Scripts`.
- **Unknown repo.** `$S cli <run> -- settings repo -r /tmp/nope` fails with exit `1` and `Error: The repository could not be found.`, and the main window shows a `Repository not found` alert. Dismiss it as described in `SKILL.md` under Alerts.

## Gotchas

- `$S shot` and `$S ax` capture the main window unless you pass the Settings window id.
- `config.json` requires `appearanceMode`, `updatesAutomaticallyCheckForUpdates`, and `updatesAutomaticallyDownloadUpdates`. A file without them is renamed to `config.json.corrupt-<ts>` and replaced with defaults. Never hand-write a partial config.
- The Settings window title is the current section label, not `Settings`. The window id stays the same while you switch sections, so re-read the title rather than the id.
- `Terminal` and `License` have no CLI verb. Reach them through the sidebar `cell` items.
- `settings repo` without `-r` fails in the CLI unless `$SUPACODE_REPO_ID` is set.
