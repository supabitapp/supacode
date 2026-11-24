# Panes and splits

The terminal area of a worktree is a split tree of panes, and each pane holds tabs. Users split panes, move focus between them, zoom one, resize dividers, equalize, move a pane into its own window, and close panes.

## Sub-features

- `pane-split` splits the focused or given pane horizontally or vertically.
- `pane-focus` focuses a pane by id or by direction.
- `pane-zoom` toggles zoom on a pane.
- `pane-resize` moves a pane's divider by a number of points (default 10), or with `--ratio` sets the pane's share (0.1 to 0.9) of the nearest split along the direction's axis.
- `pane-equalize` resets every split ratio.
- `pane-close` closes a pane and all its tabs.
- `pane-window` toggles a pane's window mode (`⌘⇧M`).

## How to get to it (user POV)

- Press `⌘D` to split right or `⌘⇧D` to split down.
- Choose `Split Terminal Left`, `Split Terminal Up`, `Toggle Split Zoom`, `Equalize Splits`, or `Toggle Window Mode` from the File menu.
- Run `supacode pane split|focus|zoom|equalize|resize|close|list|window`.

## Driving it with supacode-verify

Preconditions:

- Doctor passes.
- `W="$($S cli <run> -- worktree list | head -1 | cut -f1)"` holds the seed worktree id, and `$S cli <run> -- worktree focus -w "$W"` has run.

- **Baseline.** Run `P1="$($S cli <run> -- pane list -w "$W")"` and `$S ax <run> panes-before`. There is one pane UUID, and the AX tree has `group` `Terminal split: 1 pane`.
- **Split.** Run `NT="$($S cli <run> -- pane split -w "$W" -d h)"`. `h` splits right and `v` splits down. Stdout is the new tab UUID. `pane list` prints two UUIDs, `pane list -f` prints the new pane, and a fresh AX dump shows `Terminal split: 2 panes`.
- **Prove the new pane is live.** Run `$S cli <run> -- tab send -w "$W" -t "$NT" -i 'pwd > /tmp/sv-<run>/pane-pwd.txt'`. The file contains `/tmp/sv-<run>/seed-repo` (possibly `/private/tmp/...`).
- **Focus.** Run `$S cli <run> -- pane focus -w "$W" -d left`. `pane list -w "$W" --focused` prints `$P1`. After a `-d v` split, use `-d up` instead. `pane focus -w "$W" -p "$NT"` focuses the new pane by its tab id.
- **Zoom.** Run `$S cli <run> -- pane zoom -w "$W"` and capture `$S shot <run> pane-zoomed` and `$S ax <run> pane-zoomed`. Only one pane is visible, and the AX `group` reads `Terminal split: 1 pane`. Running zoom again restores `2 panes`.
- **Resize and equalize.** Take `$S shot <run> pane-resize-before`, run `$S cli <run> -- pane resize -w "$W" -p "$P1" -d right --amount 200`, and take `$S shot <run> pane-resize-after`. The divider moves right. `$S cli <run> -- pane equalize -w "$W"` puts it back at 50/50 (`$S shot <run> pane-equalize-after`).
- **Window mode.** Run `$S cli <run> -- pane window -w "$W" -p "$NT"`. `$S windows <run>` lists one more window, titled after the pane's tab, and the main window's AX `group` reads `Terminal split: 1 pane`. Running the same command again closes that window and restores `2 panes`.
- **Close.** Run `$S cli <run> -- pane close -w "$W" -p "$NT"`. `pane list` is back to `$P1`, `tab list` no longer has `$NT`, and polling the run's zmx list (see `SKILL.md` under Evidence) shows `supa-<$NT lowercased>` gone. The session ends after `pane close` returns.

## Gotchas

- `pane split` prints the new tab's UUID, not the pane's UUID. Every `-p` also accepts a tab id, so you rarely need `pane list` for ids.
- `pane split -d` takes only `h`/`horizontal` or `v`/`vertical`, so it splits right or down. `-d left` fails in the CLI. Splitting left or up needs the File menu or the tab strip's `Splits and Window Mode` menu, which need headed input.
- `pane focus -d` and `pane resize -d` take `left|right|up|down` or `l|r|u|d`.
- While a pane is zoomed or windowed, `pane list` still prints every pane. Read the visible count from the AX `group` name.
- `pane resize` on a windowed pane fails with exit `1` (`It is in window mode, so it has no divider to move.`) and leaves an alert in the main window. Dismiss it as described in `SKILL.md` under Alerts. `--amount 0`, `--ratio` outside 0.1 to 0.9, and `--amount` with `--ratio` fail in the CLI with exit `64`.
- An unknown pane id fails with `The pane could not be found. It may have been closed.` and leaves an alert in the main window. Dismiss it as described in `SKILL.md` under Alerts.
