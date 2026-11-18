# Supacode

**A native macOS command center for running coding agents in parallel.**

Run several coding agents side by side from one window: each task gets its own git worktree and
its own real terminal. Sessions persist in the background, so quitting the app or dropping an SSH
connection loses nothing.

[supacode.sh](https://supacode.sh)

<img width="3180" height="1788" alt="Supacode screenshot" src="https://github.com/user-attachments/assets/72a8dc95-020a-4dc2-9010-ba1adc9518ba" />

## Features

### Worktree-first workflow

Each task gets its own git worktree and terminal, so agents run in parallel without colliding.
Create one from the sidebar, a hotkey, the command palette, the CLI, or a deeplink. The sidebar
refreshes branch, file, and pull request state live, nests rows by branch, and hoists the
worktrees that need you (an agent awaiting input, a running script) to the top. Pin, archive,
auto-delete after N days, and jump to any with ⌃1 to ⌃9.

### Background session persistence

Sessions run inside [zmx](https://zmx.sh), a lightweight session daemon, not as children of the
app. Quit and relaunch, and every session reattaches exactly where you left it, scrollback
included. On by default; a quit option tears everything down when you want a clean start.

### Remote SSH repositories (Beta)

Point Supacode at a repository on a remote host over SSH and it manages that repo's worktrees
like a local one. Every git probe and the terminal share one multiplexed SSH connection, so you
authenticate (or touch your security key) once. When the host has zmx, remote sessions survive
dropped connections and laptop sleep: the connection retries and reattaches instead of
restarting. Beta, with some local-only features reduced.

### Folders and repositories

Git repositories and plain folders are both first-class in the sidebar. A folder gets a real
persistent terminal rooted there, with the same tabs, scripts, pinning, and appearance as a repo,
minus the git-only tools. You can also clone a remote URL straight into a folder.

### Coding agent presence

Supacode detects the agent in each pane and shows a live badge: busy, awaiting input, or idle. It
supports the common agents (Claude, Codex, Copilot) through hooks it installs, works locally and
over SSH, and drives notifications so you know the moment an agent needs you.

### The CLI and deeplinks

Drive the app from any terminal, script, or other tool. The `supacode` CLI manages worktrees,
tabs, splits, and repos, and every session exports its repo, worktree, tab, and surface IDs, so
commands default to the session you run them in. Deeplinks (`supacode://...`) mirror the CLI, so
you can bind an action to a hotkey or fire it from another app.

### More

- **A real terminal.** libghostty renders every session, with tabs, horizontal and vertical
  splits, per-surface backgrounds, and theme sync with the app's appearance.
- **Command palette.** Fuzzy-search and run any action without the mouse: jump to a worktree, open
  or clone a repo, manage worktrees, run scripts, and drive the full set of pull request actions.
- **Pull request tracking.** With GitHub integration on, each worktree's PR state, checks, and
  merge readiness show in the sidebar and refresh live, with configurable merge strategy.
- **Notifications and bells.** In-app and optional system notifications, a selectable sound,
  per-surface muting, and an option to float a notified worktree to the top.
- **Custom scripts.** Named commands with an icon and tint, per repository or global, that run in
  their own tab and appear in the Script Menu, the palette, and as deeplinks. Repositories also
  get setup and archive scripts.
- **Auto-updates** through Sparkle, with a selectable update channel.

## Requirements

- macOS 26.0+
- [mise](https://mise.jdx.dev/) for the pinned toolchain. Add `~/.local/bin` to your `PATH`.
- git submodules: `git submodule update --init --recursive`
- Xcode, with its license accepted and first launch complete.

## Quick start

```bash
git clone --recursive git@github.com:supabitapp/supacode.git
cd supacode
mise install
make doctor    # check every build prerequisite and print fixes for anything missing
make run-app   # build and launch the Debug app
```

`make doctor` verifies mise, submodules, Xcode, the Metal Toolchain, and the
pinned tools, and prints the exact command to fix anything that is missing. The build targets
run it automatically as a quiet preflight.

## Building

```bash
make build-ghostty-xcframework   # build GhosttyKit from Zig source (slow, cached)
make build-app                   # build the macOS app (Debug)
make run-app                     # build and launch
```

On a fresh Xcode, finish its setup once:

```bash
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -downloadComponent MetalToolchain
```

See [AGENTS.md](AGENTS.md) for the rest of the architecture.

## Development

```bash
make check   # swift-format + swiftlint
make test    # run the tests
make format  # swift-format only
```

## Website

[`apps/supacode.sh`](apps/supacode.sh) contains the landing page and the Cloudflare
Pages Worker that serves `/download/*` from this repository's GitHub Releases.
Install the Bun version in [`package.json`](package.json) and the Node version in
[`apps/supacode.sh/.node-version`](apps/supacode.sh/.node-version). Run from the
repository root:

```bash
bun install --frozen-lockfile --ignore-scripts
bun run --filter supacode.sh dev          # http://localhost:3002
bun run --filter supacode.sh check-types
bun run --filter supacode.sh test
bun run --filter supacode.sh build        # apps/supacode.sh/out/
```

To run the static export and the download Worker together, start a local Pages
preview after building:

```bash
bunx wrangler@4.164.0 pages dev apps/supacode.sh/out
```

The [website workflow](.github/workflows/website.yml) builds the export on
website changes. For deployments, set `CLOUDFLARE_ACCOUNT_ID` and
`CLOUDFLARE_API_TOKEN` in the `supacode-pages-preview` and
`supacode-pages-production` GitHub environments. Restrict the production
environment to `main` and confirm that `main` is the production branch of the
existing `supacode` Pages project. Set the repository variable
`SUPACODE_PAGES_PREVIEW_ENABLED` to `true` to deploy previews for PRs from this
repository. Set `SUPACODE_PAGES_PRODUCTION_ENABLED` to `true` to enable production
deploys. With that variable enabled, website changes on `main` deploy
automatically and dispatching the workflow from `main` deploys manually.
Pages deploy tokens have account-wide Pages access. Enable PR previews only
when everyone with write access to this repository is trusted to deploy the site.

On a preview deployment, request `/download/latest/appcast.xml` on the preview
host to exercise its Worker. The homepage's Download button points to
`supacode.sh`, and purchase links use the production license service.

If a production deployment fails its checks, disable
`SUPACODE_PAGES_PRODUCTION_ENABLED` and select the previous production
deployment in the [Cloudflare Pages deployment history](https://developers.cloudflare.com/pages/configuration/rollbacks/).

## Technical stack

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [libghostty](https://github.com/ghostty-org/ghostty)
- [zmx](https://zmx.sh) for session persistence

## Contributing

Contributions are reviewed personally, line by line, and a clear issue is worth more than a
large pull request. Start by opening an issue, wait for the `ready` label, then open a focused
pull request that links it. The full process, including the rule that a human (never an AI
agent) is the accountable author, is in the [Contributing guide](CONTRIBUTING.md).

- [Contributing guide](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)

## License

See [LICENSE](LICENSE).
