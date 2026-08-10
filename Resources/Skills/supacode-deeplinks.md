---
name: supacode-deeplinks
description: Control Supacode with supacode:// URLs. Always prefer the supacode CLI when it is available; use deeplinks only from scripts, other apps, or terminals where the supacode CLI is not installed.
---

# Supacode Deeplinks

Use the `supacode://` URL scheme to control Supacode from the terminal, scripts, or other apps. Dispatch a deeplink with `open`:

```sh
open "supacode://worktree/$SUPACODE_WORKTREE_ID/run"
```

Always prefer the `supacode` CLI when it is available (it is in every Supacode terminal session). Reach for deeplinks only where the CLI is not installed, such as scripts and other apps running outside Supacode.

## CRITICAL: Archiving or Deleting the Current Worktree

`supacode://worktree/<worktree_id>/archive` and `supacode://worktree/<worktree_id>/delete`
remove the worktree from Supacode's active terminals. Run against the worktree you are
working in, they close your own surface: commands after the call do not run. Worktrees
removed directly through Git disappear the same way once Supacode refreshes.
`background=true` does not change this; it only leaves focus untouched.

Make archiving or deleting your own worktree your FINAL operation. Finish all edits,
checks, commits, integration, and reporting first, and do not chain or schedule
follow-up commands after it.

## Environment

Each Supacode terminal session still exposes `SUPACODE_REPO_ID`, `SUPACODE_WORKTREE_ID`, `SUPACODE_TAB_ID`, and `SUPACODE_SURFACE_ID`, but these id variables are **deprecated and will be removed in the next release** (only `SUPACODE_SOCKET_PATH` is not). Prefer the `supacode` CLI, whose pane/tab commands resolve the focused target for you.

Worktree and repository IDs must be percent-encoded (e.g. `/tmp/repo` becomes `%2Ftmp%2Frepo`); `SUPACODE_REPO_ID` and `SUPACODE_WORKTREE_ID` already are.

Deeplinks that run commands or perform destructive actions require confirmation unless "Allow dangerous actions" permits them in Developer settings.

Any worktree action, and `repo/<repo_id>/worktree/new`, accepts `background=true` to leave the sidebar selection and keyboard focus untouched. New tabs and splits then stay in the background instead of becoming active.

## General

```
supacode://                                   # Bring app to front.
supacode://help                               # Open the deeplink reference window.
```

## Worktree

```
supacode://worktree/<worktree_id>             # Select worktree.
supacode://worktree/<worktree_id>/run         # Run the primary run-kind script.
supacode://worktree/<worktree_id>/stop        # Stop all run-kind scripts.
supacode://worktree/<worktree_id>/script/<script_id>/run    # Run a specific script by UUID.
supacode://worktree/<worktree_id>/script/<script_id>/stop   # Stop a specific script by UUID.
supacode://worktree/<worktree_id>/archive     # Archive the worktree.
supacode://worktree/<worktree_id>/unarchive   # Unarchive the worktree.
supacode://worktree/<worktree_id>/delete      # Delete the worktree.
supacode://worktree/<worktree_id>/pin         # Pin the worktree.
supacode://worktree/<worktree_id>/unpin       # Unpin the worktree.
supacode://worktree/<worktree_id>/appearance?title=<title>&color=<value>
    # Update title/tint overrides. Omitted fields are preserved; empty title clears;
    # color accepts red|orange|yellow|green|teal|blue|purple|%23RRGGBB[AA]|none.
```

## Tab

```
supacode://worktree/<worktree_id>/tab/<tab_id>                     # Focus a tab.
supacode://worktree/<worktree_id>/tab/new?input=<cmd>&id=<uuid>&title=<title>&pane=<pane_token>   # Create a tab; pane= anchors it in a pane (a pane, tab, or content id).
supacode://worktree/<worktree_id>/tab/<tab_id>/rename?title=<title>             # Set the title override; empty clears.
supacode://worktree/<worktree_id>/tab/<tab_id>/move?direction=left|right|up|down   # Move a tab into a new split.
supacode://worktree/<worktree_id>/tab/<tab_id>/destroy                          # Close a tab.
```

## Pane

A pane is a split-tree leaf holding a strip of tabs. `token` is a pane id, or
the id of a tab or content the pane hosts.

```
supacode://worktree/<worktree_id>/pane/<pane_id>                   # Focus a pane by id.
supacode://worktree/<worktree_id>/pane/focus?direction=left|right|up|down   # Focus a neighboring pane.
supacode://worktree/<worktree_id>/pane/<token>/split?direction=horizontal|vertical&input=<cmd>&id=<uuid>   # Split a pane.
supacode://worktree/<worktree_id>/pane/<token>/destroy            # Close a pane and all its tabs.
supacode://worktree/<worktree_id>/pane/<token>/zoom               # Toggle a pane's zoom.
supacode://worktree/<worktree_id>/pane/<token>/window             # Toggle a pane's window mode.
supacode://worktree/<worktree_id>/pane/equalize                   # Equalize every split ratio.
```

## Surface (deprecated)

A surface is now a tab's content. These routes are deprecated and **will be
removed in the next release**; prefer `pane split` and the `tab` routes.

```
supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>?input=<cmd> # Deprecated: use the tab focus route.
supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>/split?direction=horizontal|vertical&input=<cmd>&id=<uuid>   # Deprecated: use pane split.
supacode://worktree/<worktree_id>/tab/<tab_id>/surface/<surface_id>/destroy     # Deprecated: use the tab destroy route.
```

Surface routes resolve `surface_id` first within the worktree; `tab_id` is only
a disambiguation hint, so a surface that moved to another tab still resolves.

## Repository

```
supacode://repo/open?path=<absolute-path>     # Open a repository.
supacode://repo/<repo_id>/worktree/new?branch=<name>&base=<ref>&upstream=<ref>&fetch=true&name=<folder>&location=<dir>&pin=true   # Create a worktree (upstream=<ref> sets the new branch's tracking branch, an empty upstream= clears it; pin=true pins it as soon as creation starts, local repositories only).
```

## Settings

```
supacode://settings                           # Open settings.
supacode://settings/<section>                 # general|accessibility|notifications|worktrees|developer|shortcuts|scripts|updates|github.
supacode://settings/repo/<repo_id>            # Open repository settings.
supacode://settings/repo/<repo_id>/scripts    # Open repository Scripts settings.
```
