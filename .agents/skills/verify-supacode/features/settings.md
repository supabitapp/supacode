# Settings

The Settings window has sections for general behavior, notifications, worktrees, developer options, shortcuts, global scripts, updates, and git forges, plus per-repository settings. Changes persist to `config.json` (global) and to `supacode.json` or `repos.json` (per repository).

## Sub-features

- `settings-open` opens the Settings window at a section.
- `settings-repo` opens repository-specific settings and scripts.
- `settings-persist` writes changed values to the isolated config.

## How to get to it (user POV)

- Choose `Settings…` (`⌘,`) from the app menu.
- Choose `Review in Settings` on the sidebar onboarding card.
- Run `supacode settings [general|notifications|worktrees|developer|shortcuts|scripts|updates|github|forges]` or `supacode settings repo -r <repo id> [scripts]`.

## Driving it with supacode-verify

Preconditions:

- Doctor passes.
- `R="$($S cli <run> -- repo list | head -1)"` holds the seed repository id.

- **Open a section.** Run `$S cli <run> -- settings worktrees`. Exit `0`. `agent-desktop list-windows` filtered to the run's pid shows a second window titled after the section label, `Worktrees`, in `$S windows <run>`.
- **Inspect.** Run `SW="$($S windows <run> | awk -F'\t' '$2=="Worktrees"{print $1}')"`, then `$S ax <run> settings "$SW"` and `$S shot <run> settings "$SW"`.
- **Persist.** Toggle a control through accessibility, for example `agent-desktop toggle <ref>`. `jq` on `/tmp/sv-<run>/xdg/supacode/config.json` shows the new value.
- **Repo settings.** Run `$S cli <run> -- settings repo -r "$R"`. The Settings window switches to the repository section.

## Gotchas

- `$S shot` and `$S ax` capture the main window unless you pass the Settings window id.
- `config.json` requires `appearanceMode`, `updatesAutomaticallyCheckForUpdates`, and `updatesAutomaticallyDownloadUpdates`. A file without them is renamed to `config.json.corrupt-<ts>` and replaced with defaults. Never hand-write a partial config.
- The Settings window title is the current section label, not `Settings`. Re-resolve the window id after switching sections.
- Opening a section and its window title were observed on a run. Toggling and persistence have not been driven yet.
