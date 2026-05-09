## Build Commands

```bash
make build-ghostty-xcframework  # Rebuild GhosttyKit from Zig source (requires mise)
make build-app                   # Build macOS app (Debug) via xcodebuild
make run-app                     # Build and launch Debug app
make install-dev-build           # Build and copy to /Applications
make format                      # Run swift-format only
make lint                        # Run swiftlint only (fix + lint)
make check                       # Run both format and lint
make test                        # Run all tests
make log-stream                  # Stream app logs (subsystem: app.supabit.supacode)
make bump-version                # Bump patch version and create git tag
make bump-and-release            # Bump version and push to trigger release
```

Run a single test class or method:
```bash
xcodebuild test -project supacode.xcodeproj -scheme supacode -destination "platform=macOS" \
  -only-testing:supacodeTests/TerminalTabManagerTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```

Requires [mise](https://mise.jdx.dev/) for zig, swiftlint, and xcsift tooling.

## Architecture

Supacode is a macOS orchestrator for running multiple coding agents in parallel, using GhosttyKit as the underlying terminal.

### Core Data Flow

```
AppFeature (root TCA store)
├─ RepositoriesFeature (repos + folders, worktrees, PR state, archive/delete flows)
├─ CommandPaletteFeature
├─ SettingsFeature (general, notifications, coding agents, shortcuts, github, worktree, repo settings)
└─ UpdatesFeature (Sparkle auto-updates)

WorktreeTerminalManager (global @Observable terminal state)
├─ selectedWorktreeID (tracks current selection for bell logic)
└─ WorktreeTerminalState (per worktree)
    └─ TerminalTabManager (tab/split management)
        └─ GhosttySurfaceState[] (one per terminal surface)

WorktreeInfoWatcherManager (global worktree watcher state)
├─ HEAD watchers per worktree
└─ debounced branch / file / pull request refresh events

GhosttyRuntime (shared runtime)
└─ ghostty_app_t (single C instance)
    └─ ghostty_surface_t[] (independent terminal sessions)
```

### TCA ↔ Terminal Communication

The terminal layer (`WorktreeTerminalManager`) is `@Observable` but outside TCA. Communication uses `TerminalClient`:

```
Reducer → terminalClient.send(Command) → WorktreeTerminalManager
                                                    ↓
Reducer ← .terminalEvent(Event) ← AsyncStream<Event>
```

- **Commands**: tab creation, initial-tab setup, blocking scripts, search, Ghostty binding actions, tab/surface closing, notification toggles, and lifecycle management
- **Events**: notifications, dock indicator count changes, tab/focus changes, task status changes, blocking-script completion, command palette requests, and setup-script consumption
- Wired in `supacodeApp.swift`, subscribed in `AppFeature.appLaunched`

Worktree metadata refresh uses `WorktreeInfoWatcherClient` in parallel:

```
Reducer → worktreeInfoWatcher.send(Command) → WorktreeInfoWatcherManager
                                                           ↓
Reducer ← .repositories(.worktreeInfoEvent(Event)) ← AsyncStream<Event>
```

- **Commands**: `setWorktrees`, `setSelectedWorktreeID`, `setPullRequestTrackingEnabled`, `stop`
- **Events**: `branchChanged`, `filesChanged`, `repositoryPullRequestRefresh`
- Wired in `supacodeApp.swift`, subscribed in `AppFeature.appLaunched`

### Key Dependencies

- **TCA (swift-composable-architecture)**: App state, reducers, side effects
- **GhosttyKit**: Terminal emulator (built from Zig source in ThirdParty/ghostty)
- **Sparkle**: Auto-update framework
- **swift-dependencies**: Dependency injection for TCA clients
- **PostHog**: Analytics
- **Sentry**: Error tracking

## Ghostty Keybindings Handling

- Ghostty keybindings are handled via runtime action callbacks in `GhosttySurfaceBridge`, not by app menu shortcuts.
- App-level tab actions should be triggered by Ghostty actions (`GHOSTTY_ACTION_NEW_TAB` / `GHOSTTY_ACTION_CLOSE_TAB`) to honor user custom bindings.
- `GhosttySurfaceView.performKeyEquivalent` routes bound keys to Ghostty first; only unbound keys fall through to the app.

## Code Guidelines

- Target macOS 26.0+, Swift 6.0
- Before doing a big feature or when planning, consult with pfw (pointfree) skills on TCA, Observable best practices first.
- Use `@ObservableState` for TCA feature state; use `@Observable` for non-TCA shared stores; never `ObservableObject`
- Always mark `@Observable` classes with `@MainActor`
- Modern SwiftUI only: `foregroundStyle()`, `NavigationStack`, `Button` over `onTapGesture()`
- When a new logic changes in the Reducer, always add tests
- In unit tests, never use `Task.sleep`; use `TestClock` (or an injected clock) and drive time with `advance`.
- Prefer Swift-native APIs over Foundation where they exist (e.g., `replacing()` not `replacingOccurrences()`)
- Avoid `GeometryReader` when `containerRelativeFrame()` or `visualEffect()` would work
- Do not use NSNotification to communicate between reducers.
- Prefer `@Shared` directly in reducers for app storage and shared settings; do not introduce new dependency clients solely to wrap `@Shared`.
- Use `SupaLogger` for all logging. Never use `print()` or `os.Logger` directly. `SupaLogger` prints in DEBUG and uses `os.Logger` in release.

### Formatting & Linting

- 2-space indentation, 120 character line length (enforced by `.swift-format.json`)
- Trailing commas are mandatory (enforced by `.swiftlint.yml`)
- SwiftLint runs in strict mode; never disable lint rules without permission
- Custom SwiftLint rule: `store_state_mutation_in_views` — do not mutate `store.*` directly in view files; send actions instead

## UX Standards

- Buttons must have tooltips explaining the action and associated hotkey
- Use Dynamic Type, avoid hardcoded font sizes
- Components should be layout-agnostic (parents control layout, children control appearance)
- Never use custom colors, always use system provided ones.
- We use `.monospaced()` modifier on fonts when appropriate

## Rules

- After a task, ensure the app builds: `make build-app`
- Automatically commit your changes and your changes only. Do not use `git add .`
- Before you go on your task, check the current git branch name, if it's something generic like an animal name, name it accordingly. Do not do this for main branch
- After implementing an execplan, always submit a PR if you're not in the main branch

## Folder (non-git) repositories

- `Repository.isGitRepository` classifies each root at load time via `Repository.isGitRepository(at:)`, which approximates git's own `is_git_directory()` check: `.bare` / `.git` root-name shortcut, then `rootURL/.git` existence (worktree root, covers primary / linked / submodule / `--separate-git-dir` layouts), then the `HEAD` + `objects` + `refs` trio at the root — with `HEAD` required to be a regular file (git rejects a `HEAD` directory) — so any git dir is recognized regardless of naming, including bare clones whose directory name does not end in `.git`. Classification runs through the injected `GitClientDependency.isGitRepository` closure so tests can override it without touching the filesystem.
- A folder-kind repository has exactly one synthesized "main" `Worktree` with `id = "folder:" + path` (see `Repository.folderWorktreeID(for:)`), `workingDirectory == rootURL`. Selection and terminal binding reuse the standard `SidebarSelection.worktree(id)` machinery — nothing git-specific runs for folders.
- The sidebar renders each folder as its own `Section` with an empty header and a single selectable row. The context menu offers the same entries as a git worktree row, minus pin / archive / "Copy as Branch Name", plus "Folder Settings…" (the section has no header so there is no ellipsis menu).
- The Delete Script for a folder runs through the existing `.requestDeleteSidebarItems` → `.confirmDeleteSidebarItems` → `.deleteSidebarItemConfirmed` → `.deleteScriptCompleted` pipeline; the handlers branch inside so `gitClient.removeWorktree` is never called for a folder and the success path emits `.repositoryRemovalCompleted`, which the batch aggregator drains into a single `.repositoriesRemoved` terminal. `removingRepositoryIDs` is the source of truth for "this is a folder delete" so the intent survives a `git init` happening between confirmation and completion.
- Settings hides the Setup and Archive Script sections for folders; Delete Script and user-defined scripts stay. `openRepositorySettings` (context menu + deeplink) routes folders to `.repositoryScripts` because there is no general pane for them.
- `worktreesForInfoWatcher()` filters out folder repositories so the HEAD watcher never probes a non-git path. The command palette renders folder rows as the repo name alone instead of `Foo / Foo`, and worktree deeplinks (`.archive`, `.unarchive`, `.pin`, `.unpin`) reject folder targets with an explanatory alert.
- Creating new worktrees on a folder is rejected up front in `createRandomWorktreeInRepository` / `createWorktreeInRepository` and in the `.repoWorktreeNew` deeplink handler — the menu / hotkey / palette never reaches `gitClient.createWorktreeStream` for a folder target.

## Scripts (repo + global)

- A `ScriptDefinition` (`SupacodeSettingsShared/Models/ScriptDefinition.swift`) is the user-facing run target for the toolbar Script Menu, command palette, and `runScript` deeplinks. Repo scripts persist in `RepositorySettings.scripts`; user-global scripts persist in `GlobalSettings.globalScripts`.
- Globals are always `ScriptKind.custom` — enforced by `SettingsFeature.addGlobalScript` (constructor) and `GlobalSettings.init(from:)`'s decode normalization. These are the load-bearing pair against a forged `"kind": "run"` global hijacking the primary toolbar slot. `merged`'s "repo first" ordering is a semantic UX choice, not a security guard — a future reorder for UX (alphabetical, recency) must not be relied on for invariant enforcement.
- `[ScriptDefinition].merged(repo:global:)` is the canonical merge: repo first, then globals, deduped by ID with repo winning collisions. Four call sites with deliberately different inputs — `AppFeature.State.allScripts` (TCA state), `AppFeature`'s deeplink `resolveScript(scriptID:in:)` (reads `@SharedReader` pre-state-load), `WorktreeToolbarState.allScripts` (toolbar VM), and `supacodeApp.swift`'s socket query (persisted snapshot for arbitrary worktree). Don't unify them.
- `AppFeature.State.resolveScript(id:)` is the single canonical lookup helper for state-resident scripts; `runNamedScript` re-resolves through it so a stale view binding can't bypass repo-wins or run a since-deleted script.
- The toolbar `ScriptMenu` filters globals through `WorktreeToolbarState.visibleGlobalScripts` — drops globals shadowed by a repo ID and globals with empty commands, so half-configured entries don't surface in N repo toolbars.
- Removing a script does not stop running instances — the alert copy warns the user. The terminal tab cleans up on natural completion or manual close.
- Decode resilience: `KeyedDecodingContainer.decodeLossyArrayIfPresent(forKey:)` (in `Lossy.swift`) is the API — it returns `nil` on missing key (caller may run a legacy migration), `[]` on a malformed array, and `[T]` with bad elements logged and dropped. `ScriptDefinition.init(from:)` uses `try?` on `tintColor` / `systemImage` so a malformed override drops the field, not the whole entry.
- Settings deeplink: `supacode://settings/scripts` opens the Global Scripts pane. CLI: `supacode settings scripts`.

## Colors

- `RepositoryColor` (`SupacodeSettingsShared/Models/RepositoryColor.swift`) is the canonical user-customizable tint enum, used by sidebar repo headers, script icons, terminal tab tints, sidebar running-script dots, layout snapshots, and `runningScriptsByWorktreeID`. Predefined cases: `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `purple`. The `.custom(hex)` case carries `#RRGGBB[AA]`.
- `ColorSwatchRow` (`SupacodeSettingsFeature/Views/ColorSwatchRow.swift`) is the shared swatch picker used by repository customization (`RepositoryCustomizationView`) and per-script color overrides. The picker binds through a `Binding<Color>(get/set)` so predefined / Default clicks set the color directly without the panel demoting them to `.custom(hex)` — only view-driven panel drags reach `set` and capture as `.custom(hex)` (intentional intent capture).
- Forward compat: `RepositoryColor.custom(_:)` encodes as `"#RRGGBB[AA]"`. Older builds (pre-`.custom`) decode tints via a String-rawValue enum and reject hex values. `TerminalLayoutSnapshot.TabSnapshot.tintColor` and `ScriptDefinition.tintColor` both lossy-decode the field on the current build, but this only protects forward (old data on new build) — a custom-hex tint persisted on this build is silently dropped on downgrade. Don't ship a downgrade-via-Sparkle path for users who may have set custom tints.

## Submodules

- `ThirdParty/ghostty` (`https://github.com/ghostty-org/ghostty`): Source dependency used to build `Frameworks/GhosttyKit.xcframework` and terminal resources.
- `Resources/git-wt` (`https://github.com/khoi/git-wt.git`): Bundled `wt` CLI used by Supacode Git worktree flows at runtime.
