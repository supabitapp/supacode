# Repositories

Users add local git repositories (or plain folders) to the sidebar, and each one shows as a heading with its worktrees beneath. Remote (SSH) repositories are a separate entry point.

## Sub-features

- `repo-open` adds a local repository by path.
- `repo-list` lists added repositories.
- `repo-sidebar` shows the repository heading and its `main` worktree row.

## How to get to it (user POV)

- Choose `Open Repository or Folder...` on the empty state, or File › `Add Repository or Folder` › `Add Local Repository or Folder...` (`⌘⇧O`). Both open a file panel.
- Choose `Add Remote Repository or Folder...` (`⌘⇧K`).
- Choose `Clone Repository...`.
- Run `supacode repo open <abs path>` or `supacode repo list`.
- Remove a repository with `Remove Repository…` from its section header's `Options` menu or context menu. There is no CLI verb for it.

## Driving it with supacode-verify

Preconditions:

- Doctor passes. Launch already opened the seed repo.

- **Second repo.** Create `/tmp/sv-<run>/second-repo` with `git init -b main` and one commit. Run `$S cli <run> -- repo open /tmp/sv-<run>/second-repo`. Exit `0`.
- **List.** Poll `$S cli <run> -- repo list` until it prints two ids, `%2Ftmp%2Fsv-<run>%2Fseed-repo%2F` and `%2Ftmp%2Fsv-<run>%2Fsecond-repo%2F`. `worktree list` then has the second repo's main worktree too.
- **Sidebar.** Run `$S ax <run> repos`. There are `heading` items `seed-repo` and `second-repo`, each followed by a `treeitem` `main`. Take a screenshot.
- **Persistence.** `jq .local /tmp/sv-<run>/xdg/supacode/routes.json` lists both roots.
- **Bad paths.** `repo open sv-relative` fails in the CLI with exit `1` and `Error: Invalid deeplink: …`. `repo open /tmp/sv-<run>/missing` exits `0`, and the main window shows a `Some items couldn't be opened` alert. Dismiss it as described in `SKILL.md` under Alerts.

## Gotchas

- `repo open` exits `0` as soon as the app accepts the request, before the repository loads. A `repo list` straight after can still print one id. Poll for the second id.
- `repo open` replies "Supacode is still loading" during the first seconds after launch. Launch already waits for that, but a fresh relaunch needs the same retry.
- The menu and empty-state paths open a file panel. Driving it needs agent-desktop `--surface sheet` or a dialog, plus permission for physical input. Without that, report those paths as not driven.
- Removing a repository is not drivable headlessly. The header's `Options` button is not in the AX tree (`agent-desktop find --name Options` finds nothing), and a headless `agent-desktop right-click` on the `heading` is refused (`POLICY_DENIED`). Report both entry points as not driven unless physical input is allowed.
- Remote repositories and cloning need network or SSH hosts. Leave them out unless the change touches them.
