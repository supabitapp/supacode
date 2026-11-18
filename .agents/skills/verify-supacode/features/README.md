# Supacode verification map

This directory is the maintained source for verifying Supacode's user-facing behavior. Read the index, then use the matching feature file as the recipe. `S` below means `.agents/skills/verify-supacode/scripts/supacode-verify`, run from the repo root.

## Baseline preconditions

- A Debug build of this checkout exists. `make build-app` produces it.
- `$S launch` printed a `RUN_ID`, and `$S doctor <run>` passes every check.
- The sidebar shows repository `seed-repo` with one worktree `main`. The seed repo lives at `/tmp/sv-<run>/seed-repo` and has one commit on `main`.
- New worktrees land under `/tmp/sv-<run>/worktrees/seed-repo/`.
- Never drive an instance this run did not launch. Doctor's "only this Supacode running" check must pass.

## Driving conventions

- Run app commands through `$S cli <run> -- <args>`, never a bare `supacode`.
- Read ids from CLI output (`worktree list`, `tab list`, `pane list`). Do not construct ids except the documented seed worktree id.
- Run accessibility actions with `--window-id "$($S window <run>)"`, never with `--app Supacode`.
- Keyboard shortcuts and physical clicks need agent-desktop `--headed`. That steals the user's focus and cursor, so use it only when the user allows physical input. Otherwise report the shortcut path as not driven.
- A mutation is proven only when a second view agrees. For example, check `tab list` after `tab new`, or `git worktree list` after `repo worktree-new`.

## Proof and skip reporting

- Capture state before and after: a screenshot or AX dump, plus `cli.log`.
- Record the feature ID and the entry point you used next to each artifact name.
- Report an unreachable entry point with the attempted command and the unmet precondition. Never report it as verified through a different path.
- Evidence stays in `.build/verify-supacode/<run>/` after teardown.

## Feature entry contract

Each feature file starts with an H1 and a one-paragraph description. It then has four H2s in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with supacode-verify`, and `Gotchas`.

## Features

- [Terminal tabs](./terminal-tabs.md) covers creating, typing into, renaming, and closing tabs. Proven end to end.
- [Panes and splits](./panes.md) covers splitting, focusing, zooming, and closing panes.
- [Worktrees](./worktrees.md) covers creating, pinning, archiving, and deleting worktrees, and their sidebar appearance.
- [Repositories](./repositories.md) covers adding a local repository and listing repositories.
- [Settings](./settings.md) covers opening the Settings window at each section.
