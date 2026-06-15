# Local dev environment (Xcode 26.5, Apple Silicon)

Notes + helpers for building and running this checkout locally on a machine with
**Xcode 26.5 (Swift 6.3.2)**, which is newer than what CI (`macos-26` runner)
validates against. Two classes of work were needed: making the zig-based
artifacts build, and running a dev build isolated from the installed app.

## TL;DR

```bash
# Normal day-to-day (GhosttyKit + zmx are cached, so these zig steps are skipped):
make build-app
./scripts/run-dev.sh          # launch an isolated dev build alongside the main app

# Only when GhosttyKit / zmx actually need rebuilding (submodule / script change):
source scripts/setup-local-build-env.sh
./scripts/build-ghostty.sh
./scripts/build-zmx.sh
env -u DEVELOPER_DIR make build-app
```

## Source changes in this checkout

| File | Change | Reason |
|------|--------|--------|
| `Tuist/Package.swift` + `Package.resolved` | swift-composable-architecture `1.23.1` → **`1.23.2`** | 1.23.1's `BindableAction.~=` uses a non-Sendable `WritableKeyPath`; Swift 6.3.2 rejects it. 1.23.2 is the minimal patch (uses `_SendableWritableKeyPath`); all sibling pointfree pins already satisfy its ranges. |
| `Project.swift` (Debug config) | dev build id → `app.supabit.tty7.dev`, name → `tty7 Dev` | run a dev build alongside the installed app under a distinct LaunchServices identity. |
| `Tty7SettingsShared/Support/Tty7Paths.swift` | `baseDirectory` honors `TTY7_HOME` env | `~/.tty7` (layouts/settings/sidebar/repos) was shared by every build; the override gives a dev build an isolated state dir. Unset for release/CLI/tests. |
| `tty7/Features/Terminal/Models/WorktreeTerminalState.swift` | propagate `TTY7_HOME` into the shell env | so the bundled `tty7` CLI inside terminals resolves the same isolated state dir. |

## Building GhosttyKit / zmx under Xcode 26.5

`scripts/setup-local-build-env.sh` (source it) sets up everything below. Root
causes:

1. **arm64 linker failure.** Xcode 26.5's macOS SDK ships system `.tbd` files
   with only an `arm64e-macos` slice (no plain `arm64-macos`). zig 0.15.2's
   self-hosted MachO linker doesn't fall back arm64→arm64e, so linking the zig
   build runner fails with `undefined symbol: _<libSystem symbol>`.
   **Fix:** point zig at the Command Line Tools SDK, which still has the arm64
   slice, via `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.

2. **Missing `metal` / `metallib` / `xcodebuild` in CLT.** Under CLT those tools
   don't exist. **Fix:** thin wrappers in `/tmp/metalwrap` (on `PATH`) redirect
   them back to Xcode. Also requires the Metal Toolchain component:
   `xcodebuild -downloadComponent MetalToolchain` (one-time; already installed).

3. **Proxy breaks zig fetches.** zig's HTTP/git fetcher fails through the local
   `127.0.0.1` proxy (`400` / `HttpConnectionClosing`); direct works.
   **Fix:** the setup script unsets the proxy vars.

4. **GhosttyXCFramework builds an iOS slice eagerly**, whose Apple-SDK lookup
   crashes under CLT (no iOS SDK). For a local macOS-only build this is worked
   around by building the `native` xcframework target; the iOS slice is not
   needed to link the macOS app. (Done transiently during the ghostty build; the
   committed submodule + `scripts/build-ghostty.sh` are left untouched. The
   resulting `GhosttyKit.xcframework` + fingerprint are cached under
   `.build/ghostty/`, so subsequent `make build-app` runs skip the zig step.)

### zmx

`zmx` pulls `ghostty` as a `git+https` zig dependency. github git fetches fail
in this environment, so the dep was primed into the zig cache from the local
ghostty checkout:

```bash
git -C ThirdParty/ghostty fetch --depth 1 origin <sha-from ThirdParty/zmx/build.zig.zon>
git -C ThirdParty/ghostty archive <sha> | tar -x -C /tmp/ghostty-zmxdep
mise exec -- zig fetch --global-cache-dir "$PWD/.build/zmx/.zig-global-cache" /tmp/ghostty-zmxdep
```

This is only needed if `.build/zmx/.zig-global-cache` is wiped; the built
universal `zmx` binary + fingerprint are cached under `.build/zmx/`.

## Running isolated (`scripts/run-dev.sh`)

The installed/main app and a dev build collide on three shared resources unless
isolated:

| Resource | Default (shared) | Isolated dev build |
|----------|------------------|--------------------|
| LaunchServices id | `app.supabit.tty7` | `app.supabit.tty7.dev` |
| zmx socket dir | `$TMPDIR/zmx-<uid>` | `/tmp/zmx-dev` (`ZMX_DIR`) |
| app state dir | `~/.tty7` | `~/.tty7-dev` (`TTY7_HOME`) |

Without zmx-dir isolation, a starting build's `reapOrphanSessions` kills the
other instance's `supa-*` sessions. Without state-dir isolation, the build
restores the other's persisted layout and tries to attach sessions that don't
exist in its own zmx dir (`error: session "supa-…" does not exist`).

`run-dev.sh` also **scrubs inherited `ZMX_*` / `TTY7_*` / `GHOSTTY_*` env**.
This only matters when launching from a shell that is itself inside a tty7
terminal (e.g. an agent shell): otherwise the new build inherits a stale
`ZMX_SESSION` and its terminals fail to attach. Launching from Finder is clean
already, but won't set `TTY7_HOME`/`ZMX_DIR` — use the script for isolation.
