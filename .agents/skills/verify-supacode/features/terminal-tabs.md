# Terminal tabs

A worktree's terminal area holds tabs. Each tab is a Ghostty surface attached to a zmx session that runs the user's login shell in the worktree directory. Users create tabs, type into them, rename them, and close them, and the strip and window title follow.

## Sub-features

- `tab-new` creates a tab, optionally with a title or a startup command.
- `tab-send` types text into a tab and presses Return.
- `tab-rename` sets or clears a tab's persistent title.
- `tab-close` closes a tab and ends its zmx session.
- `tab-focus` focuses a tab by id.

## How to get to it (user POV)

- Choose the `+` button at the right end of the tab strip.
- Choose the `New Terminal Tab` menu item, or press `⌘T`.
- Choose `Rename Tab` (`⌃⇧R`) or `Close Tab` (`⌘W`).
- Run `supacode tab new|send|rename|close|focus|list` in a terminal.

## Driving it with supacode-verify

Preconditions:

- Doctor passes and the seed `main` worktree is listed.
- `W="$($S cli <run> -- worktree list | head -1 | cut -f1)"` holds the seed worktree id.

- **Focus worktree.** Run `$S cli <run> -- worktree focus -w "$W"`. `tab list -w "$W"` prints one UUID, the default tab. The window shows a tab titled with the abbreviated path, such as `/t/s/seed-repo`. Capture the baseline with `$S shot <run> tabs-before`.
- **New tab.** Run `T="$($S cli <run> -- tab new -w "$W" --title verify-tab)"`. Stdout is one UUID, and `tab list` now prints two. The AX `window` name becomes `seed-repo · verify-tab`.
- **Type into it.** Run `$S cli <run> -- tab send -w "$W" -t "$T" -i 'echo tab-proof > /tmp/sv-<run>/seed-repo/tab-proof.txt'`. Exit `0`. Poll for the file and `cat` it. It contains `tab-proof`. A screenshot (`$S shot <run> tab-after-send`) shows the command echoed at the shell prompt.
- **Rename.** Run `$S cli <run> -- tab rename -w "$W" -t "$T" --title renamed-tab`, then `$S ax <run> tab-renamed`. The `window` name is `seed-repo · renamed-tab`. `--title ""` clears the override.
- **Close.** Run `$S cli <run> -- tab close -w "$W" -t "$T"`. `tab list` prints only the default tab UUID. `ZMX_DIR=/tmp/sv-<run>/zmx .build/DerivedData/Build/Products/Debug/supacode.app/Contents/Resources/zmx/zmx list --short` lists only `supa-<default tab uuid, lowercased>`.
- **Proof.** Keep `tabs-before.png`, `tab-after-send.png`, `tab-renamed.ax.json`, `cli.log`, and the `cat` output of `tab-proof.txt`.

## Gotchas

- The tab strip does not expose tab names to accessibility. Read the focused title from the AX `window` name.
- `tab send` returns before the shell runs the line. Poll for the side effect instead of using a fixed sleep.
- The shell is the user's real login shell (fish on some machines), so prompt text varies. Assert on files, not on the prompt.
- zmx session names are `supa-` plus the lowercased tab UUID.
- `tab new --background` leaves focus where it was, so the window title does not change. Use it only when the journey is about background creation.
