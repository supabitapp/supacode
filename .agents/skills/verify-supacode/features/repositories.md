# Repositories

Users add local git repositories (or plain folders) to the sidebar, and each one shows as a heading with its worktrees beneath. Remote (SSH) repositories are a separate entry point.

## Sub-features

- `repo-open` adds a local repository by path.
- `repo-list` lists added repositories.
- `repo-sidebar` shows the repository heading and its `main` worktree row.

## How to get to it (user POV)

- Choose `Open Repository or Folder...` on the empty state, or `Add Local Repository or Folder...` (`⌘⇧O`). Both open an NSOpenPanel.
- Choose `Add Remote Repository or Folder...` (`⌘⇧K`).
- Choose `Clone Repository...`.
- Run `supacode repo open <abs path>` or `supacode repo list`.

## Driving it with supacode-verify

Preconditions:

- Doctor passes. Launch already opened the seed repo.

- **Second repo.** Create `/tmp/sv-<run>/second-repo` with `git init -b main` and one commit. Run `$S cli <run> -- repo open /tmp/sv-<run>/second-repo`. Exit `0`.
- **List.** Run `$S cli <run> -- repo list`. It prints two ids, `%2Ftmp%2Fsv-<run>%2Fseed-repo%2F` and `%2Ftmp%2Fsv-<run>%2Fsecond-repo%2F`.
- **Sidebar.** Run `$S ax <run> repos`. There are `heading` items `seed-repo` and `second-repo`, each followed by a `treeitem` `main`. Take a screenshot.
- **Persistence.** `/tmp/sv-<run>/xdg/supacode/routes.json` lists both roots.

## Gotchas

- `repo open` replies "Supacode is still loading" during the first seconds after launch. Launch already waits for that, but a fresh relaunch needs the same retry.
- The menu and empty-state paths open a file panel. Driving it needs agent-desktop `--surface sheet` or a dialog, plus permission for physical input. Without that, report those paths as not driven.
- Remote repositories and cloning need network or SSH hosts. Leave them out unless the change touches them.
