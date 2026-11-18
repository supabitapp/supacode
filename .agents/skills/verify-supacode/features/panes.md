# Panes and splits

The terminal area of a worktree is a split tree of panes, and each pane holds tabs. Users split panes, move focus between them, zoom one, resize dividers, equalize, and close panes.

## Sub-features

- `pane-split` splits the focused or given pane horizontally or vertically.
- `pane-focus` focuses a pane by id or by direction.
- `pane-zoom` toggles zoom on a pane.
- `pane-equalize` resets every split ratio.
- `pane-close` closes a pane and all its tabs.
- `pane-window` toggles a pane's window mode (`⌘⇧M`).

## How to get to it (user POV)

- Press `⌘D` to split right or `⌘⇧D` to split down.
- Choose `Toggle Split Zoom`, `Equalize Splits`, or `Toggle Window Mode` from the menu bar.
- Run `supacode pane split|focus|zoom|equalize|resize|close|list|window`.

## Driving it with supacode-verify

Preconditions:

- Doctor passes.
- `W="$($S cli <run> -- worktree list | head -1 | cut -f1)"` holds the seed worktree id, and `$S cli <run> -- worktree focus -w "$W"` has run.

- **Baseline.** Run `$S cli <run> -- pane list -w "$W"` and `$S ax <run> panes-before`. There is one pane UUID, and the AX tree has `group` `Terminal split: 1 pane`.
- **Split.** Run `NT="$($S cli <run> -- pane split -w "$W" -d h)"`. `h` splits right and `v` splits down. Stdout is the new tab UUID. `pane list` prints two UUIDs, and a fresh AX dump shows `Terminal split: 2 panes`.
- **Prove the new pane is live.** Run `$S cli <run> -- tab send -w "$W" -t "$NT" -i 'pwd > /tmp/sv-<run>/pane-pwd.txt'`. The file contains `/tmp/sv-<run>/seed-repo` (possibly `/private/tmp/...`).
- **Focus by direction.** Run `$S cli <run> -- pane focus -w "$W" -d left`. `pane list -w "$W" --focused` prints the first pane UUID. After a `-d v` split, use `-d up` instead.
- **Zoom.** Run `$S cli <run> -- pane zoom -w "$W"` and capture `$S shot <run> pane-zoomed`. Only one pane is visible. Running zoom again restores both.
- **Close.** Run `$S cli <run> -- pane close -w "$W" -p <second pane uuid>`. `pane list` is back to one UUID.

## Gotchas

- `pane split` prints the new tab's UUID, not the pane's UUID. Use `pane list` to get pane ids.
- The direction flag takes `h`/`horizontal` or `v`/`vertical`. `pane focus -d` takes `left|right|up|down`.
- `splitLeft` and `splitUp` shortcuts are disabled by default. Only the CLI reaches those directions without customizing shortcuts.
- Split output and the `Terminal split: 2 panes` AX name were observed on a run. Focus, zoom, and close have not been driven yet. Fix this file if they differ.
