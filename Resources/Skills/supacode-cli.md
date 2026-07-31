---
name: supacode-cli
description: Control Supacode from the terminal. Use when running Supacode CLI commands, managing worktrees, tabs, and surfaces programmatically, or when inside a Supacode terminal session.
---

# Supacode CLI

Control Supacode from the terminal. The `supacode` command is available in all Supacode terminal sessions.

## CRITICAL: ID Tracking

**NEVER call `supacode tab new` or `supacode surface split` without capturing
the output.** These commands print the new resource UUID to stdout. You MUST
capture it into a variable — without it you cannot target the resource afterward.

**NEVER omit `-t` and `-s` flags when targeting a resource you created.**
The environment variables `$SUPACODE_TAB_ID` and `$SUPACODE_SURFACE_ID` refer
to the shell session you are running in, NOT to any tab or surface you created.
If you omit `-t`/`-s`, the command targets your own shell — not the new resource.

For new tabs, the initial surface ID equals the tab ID.

### Correct pattern — ALWAYS follow this:

**Run all related commands in a SINGLE Bash call** so captured variables
are available to subsequent commands. If you split across tool calls,
variables like `$TAB_ID` will be lost.

```sh
# 1. ALWAYS capture the UUID from tab new / surface split.
TAB_ID=$(supacode tab new -i "npm start")

# 2. ALWAYS pass -t and -s explicitly when targeting created resources.
#    For new tabs: surface ID = tab ID.
SPLIT_ID=$(supacode surface split -t "$TAB_ID" -s "$TAB_ID" -d v -i "npm test")

# 3. ALWAYS use captured IDs for subsequent operations.
supacode surface focus -t "$TAB_ID" -s "$SPLIT_ID" -i "echo hello"
supacode surface close -t "$TAB_ID" -s "$SPLIT_ID"
supacode tab close -t "$TAB_ID"
```

### WRONG — never do this:

```sh
# BAD: not capturing the UUID — you lose the reference.
supacode tab new -i "npm start"

# BAD: missing -t/-s — this targets your own shell, not the new tab.
supacode surface split -d v -i "npm test"

# BAD: splitting commands across separate Bash calls — variables are lost.
# Call 1: TAB_ID=$(supacode tab new)
# Call 2: supacode surface split -t "$TAB_ID" ...  ← $TAB_ID is empty!
```

## CRITICAL: Archiving or Deleting the Current Worktree

`supacode worktree archive` and `supacode worktree delete` remove the worktree
from Supacode's active terminals. Run against the worktree you are working in,
they close your own surface: commands after the call do not run. Worktrees
removed directly through Git disappear the same way once Supacode refreshes.
`--background` does not change this; it only leaves focus untouched.

Make archiving or deleting your own worktree your FINAL operation. Finish all
edits, checks, commits, integration, and reporting first, and do not chain or
schedule follow-up commands after it.

## Environment

Inside Supacode terminals, these environment variables are set automatically:

| Variable | Description |
|----------|-------------|
| `SUPACODE_WORKTREE_ID` | Current worktree (percent-encoded path). |
| `SUPACODE_TAB_ID` | Current tab UUID (your shell's tab, not created ones). |
| `SUPACODE_SURFACE_ID` | Current surface UUID (your shell's surface, not created ones). |
| `SUPACODE_REPO_ID` | Current repository (percent-encoded path). |
| `SUPACODE_SOCKET_PATH` | Socket for app communication. |

`-w`, `-t`, `-s`, `-r` default to these when omitted. This is only useful for
targeting **your own** session. For anything you create, pass explicit IDs.

## Commands

### App

```
supacode                          # Bring Supacode to front.
supacode open                     # Same as above.
```

### Worktree

```
supacode worktree list [-f] [--status <status>] [--not-archived] [--with-status]  # List worktree IDs (-f = focused only).
supacode worktree status [-w <id>]                  # Read status/archived/focused for one worktree.
supacode worktree focus [-w <id>]                   # Focus worktree.
supacode worktree run [-w <id>] [-c <uuid>] [--background]         # Run script (default: primary run-kind; -c for a specific UUID).
supacode worktree stop [-w <id>] [-c <uuid>] [--background]        # Stop script (default: all run-kind; -c for a specific UUID).
supacode worktree script list [-w <id>]             # List configured scripts (id / kind / name).
supacode worktree archive [-w <id>] [--background]                 # Archive worktree.
supacode worktree unarchive [-w <id>] [--background]               # Unarchive worktree.
supacode worktree delete [-w <id>] [--background]                  # Delete worktree.
supacode worktree pin [-w <id>] [--background]                     # Pin worktree.
supacode worktree unpin [-w <id>] [--background]                   # Unpin worktree.
supacode worktree appearance [-w <id>] [--title <title>] [--color <value>]  # Read stored title/tint overrides; flags update them (empty title or color none clears).
```

### Tab

```
supacode tab list [-w <id>] [-f]                                     # List tab UUIDs in worktree (-f = focused only).
supacode tab focus [-w <id>] [-t <id>]                               # Focus tab.
supacode tab new [-w <id>] [-i <cmd>] [-n <uuid>] [--title <title>] [--background]  # Create tab (prints UUID to stdout).
supacode tab rename [-w <id>] [-t <id>] --title <title>              # Rename tab (empty title clears override; script tabs are locked).
supacode tab close [-w <id>] [-t <id>] [--background]                # Close tab.
```

### Surface

```
supacode surface list [-w <id>] [-t <id>] [-f]                                              # List surface UUIDs in tab (-f = focused only).
supacode surface focus [-w <id>] [-t <id>] [-s <id>] [-i <cmd>]                         # Focus surface.
supacode surface split [-w <id>] [-t <id>] [-s <id>] [-i <cmd>] [-d h|v] [-n <uuid>] [--background]  # Split (prints UUID to stdout).
supacode surface close [-w <id>] [-t <id>] [-s <id>] [--background]                      # Close surface.
```

### Repository

```
supacode repo list                                                     # List repository IDs.
supacode repo open <path>                                              # Open repository.
supacode repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] [--fetch] [--name <folder>] [--location <dir>] [--pin] [--background]  # Create worktree (prints the new worktree ID to stdout; --pin pins it as soon as creation starts, local repositories only).
```

### Settings

```
supacode settings [<section>]        # Open settings (general|notifications|worktrees|developer|shortcuts|scripts|updates|github).
supacode settings repo [-r <id>]     # Open repository settings.
supacode settings repo scripts [-r <id>]  # Open repository Scripts settings.
```

### Socket

```
supacode socket                      # List active socket paths.
```

## Output Formats

`list` commands output one ID per line: percent-encoded paths for worktrees and
repositories, UUIDs for tabs and surfaces. Use these IDs directly as `-w`, `-t`,
`-s`, `-r`, `-c` flag values.

`worktree list` filters with `--status main|pinned|unpinned|archived`
(comma-separated) or `--not-archived` (not both); `--with-status` appends a
tab-separated status column.

`worktree status` outputs `status=<value>`, `archived=<true|false>`, and
`focused=<true|false>` for a single worktree.

`worktree script list` outputs tab-separated `<uuid>\t<kind>\t<displayName>`
rows. When stdout is a TTY, running scripts are ANSI-underlined; captured or
piped output carries no running indicator.

`worktree appearance` with no flags outputs `title=<stored override>`,
`color=<stored override or none>`, and `displayTitle=<effective title>`.
With `--title` / `--color`, omitted update flags preserve existing values;
`--title ""` clears the title override and `--color none` clears the tint.

## Background Mode

Pass `--background` when acting on behalf of a user working elsewhere: it
leaves the sidebar selection and keyboard focus untouched, and new tabs and
splits stay in the background instead of becoming active. It is accepted by
every action that would otherwise focus its target (`tab new`, `surface split`,
`repo worktree-new`, `worktree run`/`stop`/`archive`/`unarchive`/`delete`/
`pin`/`unpin`, and the `close` commands); the `focus` commands do not accept it.

## Flag Reference

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--worktree` | `-w` | `$SUPACODE_WORKTREE_ID` | Worktree ID. |
| `--tab` | `-t` | `$SUPACODE_TAB_ID` | Tab UUID. |
| `--surface` | `-s` | `$SUPACODE_SURFACE_ID` | Surface UUID. |
| `--script` | `-c` | - | Script UUID (for `worktree run`/`stop`). |
| `--title` | - | - | Tab title for `tab new`/`rename`, or sidebar title for `worktree appearance`; an empty string clears it for `rename` and `appearance` (rejected by `tab new`). |
| `--color` | - | - | Sidebar tint override; pass `none` to clear. |
| `--repo` | `-r` | `$SUPACODE_REPO_ID` | Repository ID. |
| `--input` | `-i` | - | Command to run in the terminal. |
| `--direction` | `-d` | `horizontal` | Split direction (`horizontal`/`h` or `vertical`/`v`). |
| `--id` | `-n` | random | UUID for new tab/surface. |
| `--focused` | `-f` | - | Print only the focused item in `list` commands. |
| `--background` | - | - | Do not move the selection or focus; see Background Mode. |
| `--timeout` | - | app default | Seconds to wait for the app's response; `0` waits indefinitely. |
