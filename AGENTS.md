## Build Commands

```bash
make doctor                      # Diagnose build prerequisites (run this first on a new machine)
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

Requires [mise](https://mise.jdx.dev/) for zig, swiftlint, swift-format, xcbeautify, and xcsift tooling. Run `mise install` once to fetch the pinned versions.

## Building on macOS 26.4+ (Tahoe)

On macOS 26.4+ the GhosttyKit build fails to link with a wall of `undefined symbol: _malloc, _free, _sigaction, …` in `build_zcu.o`. **The fix is to build against Xcode 26.3, not the toolchain version.**

**Run `make doctor` first** — it verifies every prerequisite below (mise on PATH, submodules, a Zig-linkable Xcode, license/first-launch, Metal Toolchain, pinned mise tools) and prints the exact command to fix each failure. The build targets also run it automatically as a quiet preflight (skipped on CI, or set `SUPACODE_SKIP_PREFLIGHT=1` to skip it locally). First-time setup, in order:

1. **mise on PATH.** `make` targets call `mise exec`, but mise installs at `~/.local/bin/mise`, which non-login shells don't pick up. Activate it: `echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc` (or add `~/.local/bin` to `PATH`), then `mise install`.
2. **Submodules.** `git submodule update --init --recursive` (ghostty, zmx, git-wt).
3. **Xcode 26.3.** The pinned Zig (`0.15.2`, required exactly by ghostty's `build.zig` `requireZig`, and it uses 0.15.2-only stdlib APIs, so bumping Zig is not an option) cannot link the macOS 26.4+ SDK: that SDK's `usr/lib/libSystem.tbd` dropped the plain `arm64-macos` target (keeping only `arm64e-macos`), and Zig 0.15.2's linker won't match — [ziglang/zig#31658](https://github.com/ziglang/zig/issues/31658), fixed only in Zig 0.16+. Install [Xcode 26.3](https://developer.apple.com/download/all/?q=Xcode%2026.3), which ships the macOS 26.2 SDK whose `.tbd` still has `arm64-macos`. **You do not need to `sudo xcode-select -s` it globally** — keep your newer Xcode as the default for other projects. The build auto-detects a Zig-linkable Xcode via `scripts/select-developer-dir.sh` and pins `DEVELOPER_DIR` for just that build (override with `DEVELOPER_DIR=… make build-app` if you want a specific one).
4. **License + first launch.** A freshly installed Xcode 26.3 must complete these before `DEVELOPER_DIR` works (we observed `DEVELOPER_DIR` alone is insufficient until then): `sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -license accept` and `… -runFirstLaunch`.
5. **Metal Toolchain.** A fresh Xcode 26.3 ships it uninstalled, and ghostty compiles Metal shaders → `cannot execute tool 'metal' due to missing Metal Toolchain`. Install it into that Xcode (target it explicitly so it lands in 26.3, not whatever is globally selected): `sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain`.

**Verification quirk:** check the SDK *version*, not just the `arm64-macos` slice. macOS 26.4+ SDKs still list `arm64-macos` in `libSystem.tbd` yet Zig 0.15.2 cannot link them, so grepping that string gives false positives (it accepts Xcode 26.5). `scripts/select-developer-dir.sh` gates on `xcrun --sdk macosx --show-sdk-version` being `<= 26.3` instead. Use the `--sdk macosx` form, not bare `xcrun --show-sdk-version`, which can resolve to the CommandLineTools SDK and mislead you.

**Why no `patches/` entry:** the link failure is in Zig's own self-hosted linker (`build_zcu.o`, the build runner itself), not in ghostty source, so the `patches/*.patch` mechanism — which only patches the ghostty submodule working tree — cannot fix it; and ghostty pins Zig to exactly 0.15.2, so bumping Zig is out. The older-SDK + auto-`DEVELOPER_DIR` approach is the long-term fix until ghostty supports Zig 0.16+.

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
- Avoid top-level free functions. Default to `static` methods, computed properties, or instance methods on a relevant type (enum/struct/extension). Free functions pollute the module namespace, are harder to discover, and easily drift from the inline implementation a consumer ends up writing instead. If the operation is pure and stateless, make it a `static` on a caseless `enum` or the most relevant type, not a top-level `func`.
- Closure-typed focused values invalidate the AppKit menu on every body run (closures have no Equatable conformance, so SwiftUI re-publishes every time). Always wrap menu-bar action closures with `FocusedAction<Input>` and publish via `.focusedSceneAction(_:enabled:token:perform:)` / `.focusedAction(_:enabled:token:perform:)`. The wrapper dedupes on `(isEnabled, token)`, so AppKit only rebuilds the menu when something the menu actually displays changes. Token rules in `App/Models/FocusedAction.swift`: set `token` to a hashable projection of any captured state that affects behavior; leave it `nil` when the closure captures only the store / `@State` bindings. Consumers should read the action with `@FocusedValue(\.x)` and gate with `action?.isEnabled != true`, not `action == nil`.

### Formatting & Linting

- 2-space indentation, 120 character line length (enforced by `.swift-format.json`)
- `make format` runs the mise-pinned `swift-format` (`spm:swiftlang/swift-format` in `mise.toml`), NOT the Xcode toolchain's built-in `swift format`. The pin keeps formatting reproducible across contributors' Xcodes — an unpinned toolchain formatter rewrites the whole tree (e.g. Swift call-site trailing commas) and produces spurious churn. Bump the pin in lockstep with the Swift toolchain (tag `60X.x` ↔ Swift 6.X).
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

## Sidebar performance

- Per-row `SidebarItemFeature` state lives in `RepositoriesFeature.State.sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>` (see commit `0a1ed578`, "Improve sidebar performance and refresh reliability"). The whole point is that a per-leaf mutation (notification tick, agent tool storm, running-script update) invalidates only that leaf's view, not every sibling.
- The sidebar view is a dumb renderer over `state.sidebarStructure` (see `Features/Repositories/BusinessLogic/SidebarStructure.swift`). The structure is computed inside the reducer's post-reduce hook so per-leaf reads stay in reducer context. `SidebarListView.body` reads only the cached `state.sidebarStructure`, never `sidebarItems[id:]` directly. If you find yourself iterating leaves from a view body to derive something, move that derivation into `computeSidebarStructure(...)` and let the cache flow back through.
- The post-reduce hook is gated by `\.sidebarStructureAutoRecompute` (default `true` in live + preview + test) so production and tests see the same fresh cache. TestStore expectations that mirror a structure-affecting action should call `$0.recomputeSidebarStructureIfChanged()` (post-reduce hook mirror) or `$0.reconcileSidebarForTesting()` (when the reducer body also calls `syncSidebar`). Legacy tests that don't care about the cache can opt out via `withDependencies { $0.sidebarStructureAutoRecompute = false }`. The set of actions that trigger recompute is enumerated in `RepositoriesFeature.Action.affectsSidebarStructure`; the `.sidebarItems` arm delegates to `SidebarItemFeature.Action.affectsSidebarStructure` so display-only per-leaf actions (diff stats, PR refresh, drag/focus/hint) skip the recompute entirely. Add new structure-affecting cases on whichever side is appropriate.
- The recompute helper uses an Equatable diff against the cached value, so a no-op rebuild (e.g. an action that touched per-leaf state in a way that didn't change classification) does NOT invalidate SwiftUI observation.
- When you need a row-level aggregator that ISN'T part of the global structure (per-group indicators inside a nested branch path, for example), extract a dedicated subview taking `parentStore: StoreOf<RepositoriesFeature>` + `leafIDs: [SidebarItemID]` and per-leaf-scope inside its own body. See `SidebarPathGroupAggregatedIndicators` in `Features/Repositories/Views/SidebarItemsView.swift`.

## Highlight Relevant Sidebar Items

- Two View-menu toggles under the "Group Relevant Sidebar Rows" submenu (see `Commands/SidebarCommands.swift`): `@Shared(.sidebarGroupPinnedRows)` and `@Shared(.sidebarGroupActiveRows)`, both default `true` so the feature is discoverable on first launch. Each is independent: turning one off hides only its hoisted section; the rows fall back into their per-repo position.
- The sections are NOT collapsible (no `Section(isExpanded:)`). Visibility is purely the toggle state plus "are there qualifying rows".
- `SidebarStructure.sections` is the single ordered list the view renders. Cases: `.highlight(kind, rowIDs)` for Pinned / Active hoists, `.repository(id, groups)` for git repos (groups are precomputed `[SidebarItemGroup]` slot payloads), `.folder(id, rowID)` for folder repos, `.failedRepository(id, rootURL, message)`, `.placeholder` for the first-launch shimmer. `SidebarListView` does one `ForEach(structure.sections)` and dispatches via a single switch in `SidebarSectionDispatcher`. Non-repo cases set `.moveDisabled(true)` so the outer `.onMove` only reorders repository sections.
- `SidebarActiveClassification` (`BusinessLogic/SidebarStructure.swift`) is a 10-bucket priority enum keyed off four leaf-local flags (`hasUnseenNotifications`, `hasAgentAwaitingInput`, `!state.agents.isEmpty`, `!runningScripts.isEmpty`). The `hasAgent` flag matches visible agent-badge presence (any tracked instance, including `.idle`) so a row with an agent badge surfaces in Active even when the agent isn't actively working. Rows that don't classify are dropped from Active and (when the Pinned section is in play) fall to the bottom of Pinned alphabetically. `SidebarHighlightOrdering` is the pure helper that owns the priority + alphabetical sort; both have direct unit coverage in `SidebarActiveClassificationTests.swift` / `SidebarHighlightOrderingTests.swift`. Terminating-lifecycle rows (`SidebarItemFeature.State.Lifecycle.isTerminating`: `.archiving`, `.deletingScript`, `.deleting`) are excluded from the Active candidate set so a row mid-wind-down doesn't surface in the rail. `.pending` stays eligible because a pending row running a setup script is exactly what Active is meant to surface.
- `SidebarStructure.hoistedRowIDs` is the union of every hoisted row across both highlight sections. `SidebarItemGroup.computeSlots(...)` filters every per-repo slot (main / pinnedTail / pending / unpinnedTail) against this set, so a hoisted row never double-renders. A `seen: Set` dedupe inside `computeSlots` also catches a pre-existing double-bucket pre-state (same id in `.pinned` and `.unpinned`) so the row appears in at most one slot regardless of bucket state.
- Highlight rows get a colored `repo · trail` subtitle. The subtitle composes inside an `HStack` with `.layoutPriority(1)` on the repo so the colored repo tag doesn't get truncated first under a narrow sidebar; the trail yields first instead. The repo color and name come from `SidebarStructure.repositoryHighlightByID`, built once per recompute, and the repo name resolves through `Repository.sidebarDisplayName(custom:fallback:)` so the highlight tag and `RepoSectionHeaderView` stay in lockstep on a customized title. `.repositoryCustomization(.presented(.delegate(.save)))` is wired into `affectsSidebarStructure` so the cache flushes immediately on save.
- Hotkey numbering (⌃1..⌃0) reads `SidebarStructure.slotByID`; the view does one trivial join with `commandKeyObserver.isPressed` + shortcut overrides to convert slot index to display string. `SidebarStructure.hotkeySlots` is the projected `[HotkeyWorktreeSlot]` published to `focusedSceneValue(\.visibleHotkeyWorktreeRows, ...)` for the menu bar.
- When `@Shared(.sidebarNestWorktreesByBranch)` is on, the view's branch-tree builder re-sorts each git bucket alphabetically before nesting. `SidebarItemGroup.computeSlots(...)` mirrors that sort (case-insensitive `localizedCaseInsensitiveCompare` on `branchName`, matching `SidebarBranchNesting.buildRows`) so `slotByID` / `hotkeySlots` line up with the visible order. Toggling the option dispatches `.sidebarNestByBranchChanged` from `SidebarListView.onChange`, which `affectsSidebarStructure` flags so the cache rebuilds.
- Folders are pinnable through the same `pinWorktree` / `unpinWorktree` actions as git worktrees. The pin / unpin flow uses `SidebarState.removeAnywhere` + `insert` to enforce the "exactly one bucket" invariant against any pre-state (hand-edit, migrator race) where a row lives in two buckets simultaneously. A hoisted folder is omitted from its `.folder` section entirely; `SidebarStructure` knows not to emit it.
- Auto-dismiss of the highlight onboarding card fires from two places that cover the realistic entry points. (1) The reducer handler for `.sidebarGroupingTogglesChanged` bumps `@Shared(.appStorage("highlightRelevantOnboardingDismissedAt"))` when both grouping toggles end up off; this covers any path that flips a toggle while `SidebarListView` is mounted (the `.onChange` watcher dispatches the action). (2) The menu bindings in `SidebarCommands.groupPinnedRowsToggle` / `groupActiveRowsToggle` fire the same dismiss inside their setter, mirroring `nestWorktreesToggle`, so toggling from the menu bar while the sidebar column is collapsed still dismisses the card.

## Folder (non-git) repositories

- `Repository.isGitRepository` classifies each root at load time via `Repository.isGitRepository(at:)`, which approximates git's own `is_git_directory()` check: `.bare` / `.git` root-name shortcut, then `rootURL/.git` existence (worktree root, covers primary / linked / submodule / `--separate-git-dir` layouts), then the `HEAD` + `objects` + `refs` trio at the root — with `HEAD` required to be a regular file (git rejects a `HEAD` directory) — so any git dir is recognized regardless of naming, including bare clones whose directory name does not end in `.git`. Classification runs through the injected `GitClientDependency.isGitRepository` closure so tests can override it without touching the filesystem.
- A folder-kind repository has exactly one synthesized "main" `Worktree` with `id = "folder:" + path` (see `Repository.folderWorktreeID(for:)`), `workingDirectory == rootURL`. Selection and terminal binding reuse the standard `SidebarSelection.worktree(id)` machinery — nothing git-specific runs for folders.
- The sidebar renders each folder as its own `Section` with an empty header (`header: { EmptyView() }`, kept so `.listStyle(.sidebar)` keeps a visible section break between consecutive folder repos) and a single selectable row. The context menu offers the same entries as a git worktree row, minus archive / "Copy as Branch Name", plus "Folder Settings…" (the section has no header so there is no ellipsis menu). Folders ARE pinnable: a folder synthetic worktree seeds into the `.unpinned` bucket by default and the user can pin / unpin it through the same `pinWorktree` / `unpinWorktree` actions that govern git worktrees. `reconcileSidebarState` skips the `mainID == worktreeID` prune for folder repos so a folder pin survives `.repositoriesLoaded`. The folder row's view path resolves via `Repository.folderWorktreeID(for:)` rather than the `.pinned` bucket so it stays visible across pin / unpin transitions.
- The Delete Script for a folder runs through the existing `.requestDeleteSidebarItems` → `.confirmDeleteSidebarItems` → `.deleteSidebarItemConfirmed` → `.deleteScriptCompleted` pipeline; the handlers branch inside so `gitClient.removeWorktree` is never called for a folder and the success path emits `.repositoryRemovalCompleted`, which the batch aggregator drains into a single `.repositoriesRemoved` terminal. `removingRepositoryIDs` is the source of truth for "this is a folder delete" so the intent survives a `git init` happening between confirmation and completion.
- Settings hides the Setup and Archive Script sections for folders; Delete Script and user-defined scripts stay. `openRepositorySettings` (context menu + deeplink) routes folders to `.repositoryScripts` because there is no general pane for them.
- `worktreesForInfoWatcher()` filters out folder repositories so the HEAD watcher never probes a non-git path. The command palette renders folder rows as the repo name alone instead of `Foo / Foo`, and worktree deeplinks for `.archive` and `.unarchive` reject folder targets with an explanatory alert. `.pin` and `.unpin` flow through the shared bucket machinery and are valid for folders.
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

- `ThirdParty/ghostty` (`https://github.com/ghostty-org/ghostty`): Source dependency used to build `Frameworks/GhosttyKit.xcframework` and terminal resources. The pin tracks upstream; local changes live as out-of-tree patches in `patches/*.patch`, applied to the working tree by `scripts/build-ghostty.sh` before `zig build` and reverted on exit (the pin is never moved, no fork). On a ghostty bump a patch may stop applying and the build fails loudly: refresh the patch, and prefer upstreaming it to retire the carry cost. Run one ghostty build at a time (the apply/revert shares the submodule working tree).
- `Resources/git-wt` (`https://github.com/khoi/git-wt.git`): Bundled `wt` CLI used by Supacode Git worktree flows at runtime.
