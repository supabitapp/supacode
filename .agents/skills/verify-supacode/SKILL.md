---
name: verify-supacode
description: Launch an isolated Debug build of the Supacode macOS app, drive it through its bundled `supacode` CLI socket and the accessibility tree (agent-desktop), and capture screenshots, CLI transcripts, and file side effects as proof. Use when you need to prove a Supacode change works in the real app (sidebar, worktrees, terminal tabs, panes, settings), not just in unit tests.
---

# Verify Supacode

Supacode is a SwiftUI/TCA macOS app. A user touches one main window: a sidebar of repositories and worktrees, and a terminal area of panes and tabs backed by Ghostty and zmx sessions. Every user path in the window also has a CLI twin (`supacode <noun> <verb>`) that the app serves over a per-process Unix socket at `/tmp/supacode-<uid>/pid-<pid>`. The CLI is the drive harness. agent-desktop handles screenshots and accessibility reads.

Everything goes through one helper. Run it from the repo root:

```bash
S=.agents/skills/verify-supacode/scripts/supacode-verify
$S            # prints usage
```

## Isolation (read before launching)

A Debug build shares bundle id `app.supabit.supacode` with any installed release Supacode. These are the effects and how the helper contains each one:

- `XDG_CONFIG_HOME` is pointed at a scratch dir, so `config.json`, `routes.json`, `repos.json`, and `agents.json` are private to the run.
- `ZMX_DIR` is pointed at a scratch dir, so terminal sessions are private and teardown can kill them.
- UserDefaults (sidebar order, layouts, onboarding flags) cannot be redirected. `HOME` overrides do not reach `FileManager.homeDirectoryForCurrentUser` or cfprefsd. The helper exports the domain to `defaults-before.plist` at launch and imports it back at teardown.
- A fresh config dir triggers the legacy relocation migrator, which moves files out of `~/.supacode`. Launch refuses when `~/.supacode/{settings,sidebar,layouts}.json` or `ghostty.config` exists. The check uses the account home from `dscl`, the same home the app resolves, not `$HOME`.
- On startup the app re-installs any agent integration it finds outdated (skills and hooks under `~/.claude`, `~/.codex`, `~/.gemini`, and the other agent config dirs). It writes the account's real home, and no setting turns this off. Launch copies every small file in those dirs that mentions Supacode to `agent-files-before/`. Teardown restores changed files under `skills/supacode*`. A changed shared config file (`settings.json`, `config.toml`, and so on) may also hold edits another tool made during the run, so teardown does not auto-restore it. Instead it writes the diff and a `cp` restore command to `agent-files-report.txt`, warns, and exits non-zero. It also reports new Supacode-bearing files. On a non-zero teardown, relay that report to the user.
- Launch refuses when any `supacode.app/Contents/MacOS/supacode` process is running. That includes the user's own Supacode and another verify run. Only one verify run can exist per user, because the UserDefaults snapshot and restore would race. A lock at `/tmp/supacode-verify-<uid>.lock` enforces this, and teardown releases it. Never quit the user's app to make room. Report the refusal instead.
- Debug builds skip PostHog and Sentry. The seeded config also disables update checks, GitHub integration, system notifications, and the quit confirmation.

## Launch

Prerequisite: a Debug build of this checkout. `make build-app` writes it to `.build/DerivedData/Build/Products/Debug/supacode.app`. The first build takes several minutes.

```bash
$S launch
# RUN_ID=5a1680
# EVIDENCE=<repo>/.build/verify-supacode/5a1680
```

Launch does the following:

1. Snapshots the defaults domain.
2. Creates `/tmp/sv-<run>/seed-repo`, a git repo on `main` with one commit.
3. Seeds `config.json` with worktrees placed under `/tmp/sv-<run>/worktrees`.
4. Starts the app binary with `-ApplePersistenceIgnoreState YES`, so the main window always opens.
5. Waits for the socket to answer, then retries `repo open` until the app stops replying "Supacode is still loading".
6. Returns once `worktree list` shows the seed repo.

At that point the window shows `seed-repo › main` in the sidebar. Launch exits non-zero with the reason on any failure. A failed launch tears itself down, so nothing is left running and the evidence dir keeps `app.log`. Launch also records the main window id for `shot` and `ax`.

Run state lives in `/tmp/sv-<run>/`. Print it as quoted shell assignments with `$S env <run>`. The keys are `RUN_ID`, `PID`, `SOCKET`, `WINDOW`, `STATE`, `EVIDENCE`, `SEED_REPO`, `XDG`, and `ZMX`.

The seed repo's main worktree id is its percent-encoded path with a trailing slash: `%2Ftmp%2Fsv-<run>%2Fseed-repo%2F`. Prefer reading ids from `$S cli <run> -- worktree list` over constructing them.

## Doctor

Run this first, and again whenever anything looks off. It is read-only.

```bash
$S doctor <run>
```

It checks these things:

- The pid is alive and is this checkout's binary.
- The socket exists and answers. Doctor skips socket probes when the pid check fails, because the CLI then falls back to any other live Supacode.
- Config is isolated.
- The seed repo is listed.
- The recorded main window still belongs to the pid.
- This run holds the lock.
- No other Supacode is running.

It also prints the build mtime and `HEAD`. If the build predates your change, run `make build-app`, tear down, and relaunch.

## Drive

**CLI.** `$S cli <run> -- <supacode args>` runs the bundled CLI from this build with `SUPACODE_SOCKET_PATH` pinned to this run's socket. Always use it. A bare `supacode` resolves whichever single socket it finds, and that can be the user's app. The helper refuses when the pid is no longer this checkout's app. The CLI itself still falls back to another live socket if the app dies mid-command, so run doctor after any unexpected CLI error. Every call is appended to `EVIDENCE/cli.log` with the command, stdout, stderr, and exit code. Commands that create things print the new UUID on stdout.

```bash
W="$($S cli <run> -- worktree list | head -1 | cut -f1)"
$S cli <run> -- tab new -w "$W" --title verify-tab          # prints tab UUID
$S cli <run> -- tab send -w "$W" -t <tab> -i 'echo hi > /tmp/sv-<run>/seed-repo/hi.txt'
$S cli <run> -- pane split -w "$W" -d v                     # prints new tab UUID
$S cli <run> -- repo worktree-new -r <repo-id> --branch feat-x
$S cli <run> -- settings worktrees
```

Run `$S cli <run> -- <noun> --help` for every flag. The nouns are `open`, `repo`, `worktree`, `tab`, `pane`, `settings`, and `socket`. `surface` is deprecated, so do not use it.

**Accessibility.** The app sets no accessibility identifiers. Use roles and names. The stable handles below were observed on a launched run:

| Role | Name | Meaning |
|------|------|---------|
| `window` | `<repo> · <tab title>` | Window title. It carries the focused tab's title. |
| `outline` | `Sidebar` | The repository and worktree tree. |
| `heading` | `<repo name>` | One per repository. |
| `treeitem` | `<branch>` | One per worktree row. |
| `group` | `Terminal split: N pane(s)` | Pane count of the focused worktree. |
| `button` | `Hide Sidebar`, `Back`, `Forward` | Toolbar buttons. |
| `switch` | `Files`, `Pull Request`, `Notifications` | Inspector toggles. |

Read them with these commands:

```bash
$S ax <run> <name>        # interactive AX tree -> EVIDENCE/<name>.ax.json
jq -r '.. | objects | select(.name? != null) | "\(.role)\t\(.name)"' "$EVIDENCE/<name>.ax.json"
$S windows <run>          # "<id><TAB><title>" for every window this run's pid owns
$S shot <run> <name> <id> # capture a non-main window, such as Settings
WID="$($S env <run> | sed -n 's/^WINDOW=//p')"
agent-desktop click/find/... --window-id "$WID"   # never --app Supacode, which can match the user's app
```

Tab strip items do not expose names. Read the focused tab's title from the `window` name, and the tab set from `tab list`.

## Evidence

Artifacts go to `<repo>/.build/verify-supacode/<run>/`. The directory is gitignored and survives teardown.

- `$S shot <run> <name> [window]` writes `<name>.png`. It captures the main window by default, and any window id you pass must belong to the run's pid.
- `cli.log` holds every CLI call with its output and exit code.
- `app.log` holds app stdout and stderr. It is usually empty, because SupaLogger output is buffered.
- `launch-repo-open.txt`, `defaults-before.plist`, `zmx-sessions-killed.txt`, and `worktrees-at-teardown.txt` are written by the helper.

These are the proof standards:

- Drive the user path. That is a CLI command or an accessibility action, never a test-only hook or a hand-edited `config.json`.
- Capture before and after. Take a screenshot or AX dump before the action and another after it, plus the CLI transcript of the action itself.
- Verify side effects off-screen too. A command typed into a tab must leave a file on disk that you `cat`. A created worktree must show in `git -C "$SEED_REPO" worktree list`. A closed tab's zmx session must be gone from `ZMX_DIR=<zmx> <app>/Contents/Resources/zmx/zmx list --short`.
- A feature with several entry points (menu, shortcut, CLI) is proven only for the paths you drove. Name those paths in your report.

## Cleanup

```bash
$S teardown <run>
```

Teardown works in this order:

1. Checks that the pid still runs this checkout's binary, then sends SIGTERM, and SIGKILL after 10 seconds.
2. Kills each zmx session listed in this run's `ZMX_DIR` and waits for its `zmx attach` process to exit.
3. Removes the socket.
4. Restores the defaults domain from `defaults-before.plist`, or deletes the domain if it did not exist before. When another Supacode is running at that point, it leaves the domain alone and prints the backup path.
5. Checks agent integration files against the launch snapshot, as described under Isolation.
6. Deletes `/tmp/sv-<run>` and releases the lock.

Teardown exits non-zero when it could not restore something. The stderr message names the file to review.

It never kills by process name. The evidence dir stays. Run teardown after every failed attempt too. To confirm the restore, run `defaults export app.supabit.supacode - | diff - <(plutil -convert xml1 -o - $EVIDENCE/defaults-before.plist)`.

## Feature map

`features/README.md` indexes one recipe per user-facing feature. Read the matching file before driving. Report every entry point the map lists. Mark each one as driven or not driven, and say why for each one not driven. A feature is fully proven only when every entry point was driven.

## Helper reference

`scripts/supacode-verify` is executable and has these commands: `launch`, `doctor <run>`, `cli <run> -- <args>`, `shot <run> <name> [window]`, `ax <run> <name> [window]`, `windows <run>`, `env <run>`, and `teardown <run>`. Each exits non-zero with a `supacode-verify:` message when its precondition fails, such as a dead pid or a missing socket.
