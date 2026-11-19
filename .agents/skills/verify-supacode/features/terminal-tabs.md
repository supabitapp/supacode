# Terminal tabs

A worktree's terminal area holds tabs. Each tab is a Ghostty surface attached to a zmx session that runs the user's login shell in the worktree directory. Users create tabs, type into them, rename them, move them between panes, and close them, and the strip and window title follow.

## Sub-features

- `tab-new` creates a tab, optionally with a title or a startup command. `--background` creates it without moving focus.
- `tab-send` types text into a tab and presses Return.
- `tab-rename` sets or clears a tab's persistent title.
- `tab-move` moves a tab into a new split beside its pane (`-d left|right|up|down`).
- `tab-close` closes a tab and ends its zmx session.
- `tab-focus` focuses a tab by id.

## How to get to it (user POV)

- Choose the `+` button at the right end of the tab strip.
- Choose the `New Terminal Tab` menu item, or press `⌘T`.
- Choose `Rename Tab` (`⌃⇧R`) or `Close Tab` (`⌘W`).
- Run `supacode tab new|send|rename|move|close|focus|list` in a terminal.

## Driving it with supacode-verify

Preconditions:

- Doctor passes and the seed `main` worktree is listed.
- `W="$($S cli <run> -- worktree list | head -1 | cut -f1)"` holds the seed worktree id.

- **Focus worktree.** Run `$S cli <run> -- worktree focus -w "$W"`. `tab list -w "$W"` prints one UUID, the default tab. The window shows a tab titled with the abbreviated path, such as `/t/s/seed-repo`. Capture the baseline with `$S shot <run> tabs-before`.
- **New tab.** Run `T="$($S cli <run> -- tab new -w "$W" --title verify-tab)"`. Stdout is one UUID, `tab list` now prints two, and `tab list -w "$W" -f` prints `$T`. The AX `window` name becomes `seed-repo · verify-tab`.
- **Type into it.** Run `$S cli <run> -- tab send -w "$W" -t "$T" -i 'echo tab-proof > /tmp/sv-<run>/seed-repo/tab-proof.txt'`. Exit `0`. Poll for the file and `cat` it. It contains `tab-proof`. A screenshot (`$S shot <run> tab-after-send`) shows the command echoed at the shell prompt.
- **Rename.** Run `$S cli <run> -- tab rename -w "$W" -t "$T" --title renamed-tab`, then `$S ax <run> tab-renamed`. The `window` name is `seed-repo · renamed-tab`. `--title ""` clears the override, and the `window` name returns to the shell's title.
- **Background and move.** Run `B="$($S cli <run> -- tab new -w "$W" --background)"`. `tab list -f` still prints `$T`. Then `$S cli <run> -- tab move -w "$W" -t "$B" -d right`, and `pane list -w "$W"` prints two pane UUIDs.
- **Close.** Run `$S cli <run> -- tab close -w "$W" -t "$T"` and the same for `$B`. Closing a pane's last tab also closes that pane. `tab list` prints only the default tab UUID. Poll `ZMX_DIR=/tmp/sv-<run>/zmx .build/DerivedData/Build/Products/Debug/supacode.app/Contents/Resources/zmx/zmx list --short` until it lists only `supa-<default tab uuid, lowercased>`. The session ends after `tab close` returns.
- **Closed tab.** Run `$S cli <run> -- tab focus -w "$W" -t "$T"`. Exit `1` with `Error: The tab could not be found. It may have been closed.` The main window also shows a `Tab not found` alert. Dismiss it as described in `SKILL.md` under Alerts.
- **Proof.** Keep `tabs-before.png`, `tab-after-send.png`, `tab-renamed.ax.json`, `cli.log`, and the `cat` output of `tab-proof.txt`.

## Gotchas

- The tab strip does not expose tab names to accessibility. Read the focused title from the AX `window` name.
- `tab send` returns before the shell runs the line. Poll for the side effect instead of using a fixed sleep.
- The shell is the user's real login shell (fish on some machines), so prompt text varies. Assert on files, not on the prompt.
- zmx session names are `supa-` plus the lowercased tab UUID.
- `tab new --background` leaves focus where it was, so the window title does not change. Use it only when the journey is about background creation.
- `tab new --title " "` fails in the CLI with exit `64`: `--title cannot be blank. Omit it to keep the terminal title.`
