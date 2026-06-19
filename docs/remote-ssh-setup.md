# Remote SSH Host: Build & Bootstrap

This document captures the verified steps to get this fork building green from a
clean checkout, plus the design notes for the remote-SSH-host feature
(`feat/remote-ssh-host`).

## 1. Toolchain bootstrap

The build is driven by **Tuist** (project generation) + **mise** (tool version
pinning) + **zig** (builds GhosttyKit and the bundled `zmx` binary from source).
Pinned versions live in `mise.toml`:

| tool      | version  |
|-----------|----------|
| tuist     | 4.180.0  |
| zig       | 0.15.2   |
| swiftlint | latest   |
| xcsift    | latest   |

Verified on macOS 26 (Tahoe), Xcode 26.2, Apple Silicon.

### Steps (clean checkout → green build)

```bash
# 1. Install mise (tool manager). Not pre-installed; required by the Makefile,
#    which shells every tool through `mise exec -- <tool>`.
brew install mise

# 2. Trust the repo config and install the pinned toolchain.
mise trust
mise install
# Gotcha: the zmx submodule ships its OWN mise.toml that must also be trusted,
# otherwise `make build-zmx` fails with "Config files ... are not trusted":
mise trust ThirdParty/zmx/mise.toml

# 3. Initialize submodules (the build scripts auto-init ghostty/zmx on demand,
#    but doing it up front is explicit and also pulls Resources/git-wt):
git submodule update --init --recursive

# 4. Install xcbeautify (log formatter the Makefile pipes xcodebuild through).
#    It is NOT listed in mise.toml, so on a clean machine `make build-app`
#    fails with: mise ERROR "xcbeautify" couldn't exec process.
brew install xcbeautify

# 5. Build native dependencies, generate the project, build the app.
make build-ghostty-xcframework   # zig → .build/ghostty/GhosttyKit.xcframework (slow, cached by fingerprint)
make build-zmx                    # zig → .build/zmx/bin/zmx (universal: x86_64 + arm64)
make generate-project             # tuist generate → supacode.xcworkspace
make build-app                    # xcodebuild Debug → "Build Succeeded"
make run-app                      # launch the Debug build
```

`make build-app` already depends on the generation stamp, and the Tuist project
has build phases that invoke `build-ghostty.sh` / `build-zmx.sh`, so once the
native deps are cached a plain `make build-app` is enough on subsequent runs.

### Reusing an existing zig 0.15.2

If `~/.ttf-toolchain/zig-aarch64-macos-0.15.2/zig` already exists you can reuse
it, but note that this fork's GhosttyKit build fingerprints on the **pinned
submodule commit** (`ThirdParty/ghostty`), so a prebuilt xcframework from a
*different* ghostty checkout is not reused: `mise install`'s own zig 0.15.2 is
the simplest path.

### Known gotchas (summary)

- `mise` is not pre-installed; the Makefile assumes it.
- The `ThirdParty/zmx` submodule has a nested `mise.toml` that needs a separate
  `mise trust`.
- `xcbeautify` is referenced by the Makefile but absent from `mise.toml`;
  install it via brew.
- GitHub API rate limits (HTTP 403) during `mise install` only affect optional
  build-time deps (`zls`, `bats`) pulled in by the zmx build; they retry/resolve
  and don't block the app build.

## 2. Remote SSH host: design (Phase A)

Goal: a worktree can live on a **remote host**; its git/worktree operations and
its terminal (zmx) run remotely over SSH, while libghostty renders locally. No
file sync, just terminal + git. The single chokepoint is the transport: make
`ShellClient` host-aware, and the rest of `GitClient` follows.

### Pieces

1. **`RemoteHost`** (`SupacodeSettingsShared/Models/RemoteHost.swift`): value
   type describing an SSH destination: `alias`, optional `username`, `port`, and
   a remote `worktreeBasePath`. `nil` host everywhere means "local" (unchanged
   behavior).

2. **`SSHCommand`** (`SupacodeSettingsShared/Support/SSHCommand.swift`): pure,
   stateless builders:
   - `controlOptions`: SSH `ControlMaster=auto` multiplexing so N git calls +
     the terminal share one connection (one auth / FIDO touch, no per-call RTT
     storm).
   - `remoteCommand(executable:arguments:workingDirectory:)`: the string the
     remote shell runs; working directory becomes `cd -- <dir> && exec ...`.
   - `invocation(...)`: full local `ssh` argv for `Process`/`ShellClient`.
   - `commandLine(...)`: full `ssh` line as a single string for a parent
     `/bin/sh -c` (Ghostty's surface command), TTY allocated.

3. **`ShellClient.ssh(host:base:)`**: wraps an inner `ShellClient` so every
   `run` / `runStream` / `runLogin*` transforms `(exe, args, cwd)` into an
   `ssh <host> <remoteCommand>` invocation. This is the load-bearing chokepoint:
   `GitClient(shell: .ssh(host:))` makes all git/`wt` paths run remotely.

4. **`GitClientDependency.ssh(host:)`**: same closures as `liveValue` but every
   `GitClient` is constructed with the ssh-flavored shell.

5. **Terminal launch**: `ZmxAttach.buildRemoteCommand(host:sessionID:userCommand:)`
   produces `ssh -tt <host> zmx attach supa-<uuid> [/bin/sh -c '<cmd>']`. When a
   worktree carries a `host`, `WorktreeTerminalState.createSurface` passes this
   as the surface command and `workingDirectory: nil` (the path is remote).

### Out of scope for Phase A (follow-ups)

- Real-host SSH connectivity + libghostty rendering verification (needs a FIDO
  touch and human eyes, validated manually, not in CI/tests).
- Host selection UI + persistence; `RemoteHost` plumbing through `Repository` /
  persisted layouts.
- `Worktree.id` is `workingDirectory.path`; across hosts paths can collide, so
  ids must be host-keyed (`<host>:<path>`) with a persistence migration before
  remote and local worktrees coexist.
- The bundled `wt` binary path is local; remote worktree creation assumes `git`
  (and the `wt` shim) are available on the remote `$PATH`.
- File watching: the local kqueue HEAD watcher can't cross SSH; replace with a
  debounced `git rev-parse HEAD` poll for remote worktrees.

## 3. Remote SSH host: sidebar UI (Phase B, first slice)

Phase B makes remote worktrees usable from the GUI: you can add an SSH host
through the sidebar, and remote repos are visually separated from local ones.

### Pieces

1. **`RemoteRepositoryConfig`** (`SupacodeSettingsShared/Models`): a persisted
   `(host, remotePath, displayName)`. Stored in
   **`GlobalSettings.remoteRepositories`** (mirrors `globalScripts`), so it
   survives relaunch and never touches the local `repositoryRoots` list.

2. **`Repository.host`**: non-nil marks a remote repository. Each remote config
   is materialized at load (`RepositoriesFeature.synthesizeRemoteRepositories`)
   into a **folder-kind** `Repository` whose single synthetic worktree carries
   the host. Folder-kind = no git shell-outs against the (locally unreachable)
   remote path; selection + terminal reuse the folder machinery, and the
   terminal goes SSH because `Worktree.host != nil` (Phase A). Remote repo /
   worktree ids are **host-keyed** (`remote:<dest>:<path>`) so they never
   collide with a local path, and the local-only `buildRepositorySections` loop
   (keyed off `rootURL.path`) never accidentally renders them.

3. **Load merge**: `loadRepositoriesData` appends the synthesized remote repos
   on *every* load path (initial, reload, open, removal), reading the configs
   through `@Shared(.settingsFile)`. `state.repositoryRoots` stays local-only, so
   reload never tries to stat a remote path; `reconcileSidebarItems` /
   `reconcileSidebarState` iterate `state.repositories` (which includes remote),
   so remote rows + seeded sidebar sections come for free.

4. **Sidebar partition**: `SidebarStructure` gains `RepositoryLocality` and a
   `.partitionHeader(kind:)` section. `buildRepositorySections` emits local repo
   sections, then (only when remote repos exist) a `Local` header, the locals,
   a `Remote` header, and the remote folder sections. A purely-local sidebar is
   visually unchanged.

5. **Add entry**: the sidebar's `Add…` toolbar button is now a menu:
   *Repository or Folder…* (the existing local `NSOpenPanel`) and
   *Remote Repository…* → `AddRemoteRepositorySheet` (ssh host / user / port /
   remote path / name). Submit dispatches `.addRemoteRepository(config)`, which
   appends to `GlobalSettings.remoteRepositories` and reloads.

6. **Remote terminal cwd**: for a remote worktree, the surface command defaults
   to `cd <remotePath> 2>/dev/null; exec "$SHELL" -l` so a freshly created zmx
   session lands in the project directory.

### How to verify in the GUI

1. Make sure the remote host has `zmx` on its `$PATH` (see §2 layer 2).
2. In Supacode: sidebar toolbar **Add… → Remote Repository…**, enter an ssh
   host (e.g. `devbox`) and an absolute remote path, Add.
3. The repo appears under a **Remote** section header. Select it → a terminal
   opens over `ssh -tt <host> zmx attach …`, lands in the remote dir, and
   renders locally. (First connection may require a FIDO touch.)

### Phase B known limitations / follow-ups

- Remote repo/worktree ids embed `host:path` but the path is not otherwise
  host-namespaced in `folderWorktreeID`; two hosts at the same path, or a remote
  path equal to a local repo path, are not supported (documented edge).
- A `~`-relative remote path round-trips through `URL(fileURLWithPath:)`, so the
  `cd` may miss (the `2>/dev/null` fallback keeps the shell usable). Prefer an
  absolute remote path for now.
- No remote-repo removal UI yet (the `.removeRemoteRepository` action exists);
  no per-remote customization, no remote git worktree discovery/creation.
- `isGitRepository` / `rootDirectoryExists` still probe the local filesystem;
  remote repos are folder-kind so they don't hit that path.

## 4. Unified add-repo entry + remote agent-hook channel

### Unified "add repository" entry points

Adding a remote repo used to be reachable only from the sidebar toolbar menu.
It now mirrors the local "Open Repository or Folder" flow across all three entry
points, all routed through reducer state so they can be presented from anywhere:

- New action `RepositoriesFeature.setAddRemoteRepositoryPresented(Bool)` drives
  `State.isAddRemoteRepositoryPresented`; `SidebarView` binds the
  `AddRemoteRepositorySheet` to it.
- **Command palette**: `Add Remote Repository`
  (`CommandPaletteItem.Kind.addRemoteRepository` →
  `Delegate.addRemoteRepository`), routed in `AppFeature` to
  `setAddRemoteRepositoryPresented(true)`.
- **Empty state**: a secondary `Add Remote Repository…` link next to
  `Open Repository or Folder…`.
- **Sidebar toolbar**: the existing `Add… → Remote Repository…` button now
  dispatches the action instead of toggling a local `@State`.

### Remote agent presence via in-band OSC (awaiting-input badge over SSH)

The orange "awaiting input" badge is driven by a coding agent's hook. Locally it
writes a JSON envelope to the **local** Unix socket `$SUPACODE_SOCKET_PATH`
(`AgentHookSocketServer`), keyed by `$SUPACODE_SURFACE_ID`. A Unix socket isn't
reachable across SSH, so for a remote surface the badge never lit.

Rather than tunnel the socket (the earlier, ControlMaster-fragile `ssh -R`
attempt), presence now also rides the terminal data stream as an **OSC 9**
sequence, the same channel that already carries everything else over
`zmx → ssh -tt → libghostty`. zmx forwards OSC verbatim (it only rewrites OSC
133;A), and an OSC arrives on a specific surface's stream, so it needs no
out-of-band socket and no `surface_id` plumbing. Flow:

1. The hook command (`AgentHookSettingsCommand.compositeCommand`) emits, per
   event, `printf '\033]9;supacode-presence;v1;<agent>;<event>\a' >/dev/tty`
   in addition to the local socket envelope. It's guarded by
   `SUPACODE_SURFACE_ID` alone (independent of the socket guard, so it fires on a
   remote host with no `SUPACODE_SOCKET_PATH`), and writes to `/dev/tty`: the
   zmx PTY slave (zmx uses `forkpty`), bypassing the hook's `>/dev/null` stdout
   (which Codex parses as JSON). The shared definition lives in
   `AgentPresenceOSC` (sentinel + parser).
2. libghostty surfaces the OSC as a desktop notification;
   `GhosttySurfaceBridge` intercepts the sentinel (`parsePresenceSignal`), routes
   it to `onPresenceSignal` (suppressing the user-facing notification), and
   `WorktreeTerminalState` synthesizes an `AgentHookEvent` (`pid: nil`, surface
   from the receiving `view.id`) through the same debounced
   `WorktreeTerminalManager.dispatchHookEvent` path as the socket.
3. `AgentPresenceFeature` lazily creates a pid-less record for OSC-origin events
   (the liveness sweep skips empty-pid records; they clear on pid-less
   `session_end` or surface close), so local pid-bearing behavior is unchanged.

The remote attach command (`ZmxAttach.buildRemoteCommand`) only needs to export
`SUPACODE_SURFACE_ID` so the OSC fires; no reverse socket, no remote
`SUPACODE_SOCKET_PATH`.

**Prerequisites / notes (verify on a real host):**

- **Both machines run Supacode**, so the agent hook (now OSC-emitting) is
  installed on the remote via its own `ClaudeSettingsInstaller`/Codex config.
  Updating Supacode on the remote rewrites its hook (`.outdated` → reinstall).
- Real-host SSH + libghostty OSC rendering are verified manually (FIDO touch),
  not in CI. Unit tests cover the command construction (`AgentHookCommandTests`),
  OSC parse/routing (`GhosttySurfaceBridgeTests`), and the pid-less presence path
  (`AgentPresenceFeatureTests`).
- If a hook ever runs without a controlling tty, the `/dev/tty` write fails
  harmlessly (`|| true`); locally the socket still delivers presence.
