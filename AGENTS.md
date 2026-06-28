## Build Commands

```bash
make # this show available commands
```

Requires [mise](https://mise.jdx.dev/) for zig, swiftlint, swift-format, xcbeautify, and xcsift tooling. Run `mise install` once to fetch the pinned versions.

## Isolated dev build (`make run-app-dev`)

`make run-app-dev` builds and launches **Supacode Dev** — an independent copy (bundle id `app.supabit.supacode.dev`, name/icon "Supacode Dev", `supacode-dev://` scheme) that stores all state under `~/.supacode-dev` and never auto-updates, so you can test without touching a real install. `make build-app-dev` builds without launching; `make dev` watches sources and rebuilds + relaunches on change; `make log-stream-dev` tails its logs.

- **Dedicated Xcode target (`supacode-dev`) on the standard `Debug` configuration — not a build configuration, not command-line overrides.** A custom configuration breaks the `supacode-cli` target (Tuist generates the external SPM projects with only `Debug`/`Release`, so the statically-linked CLI can't resolve package `.swiftmodule`s under a third configuration), and a command-line `PRODUCT_NAME` override applies to every target and collides the shared frameworks on output paths. Both app targets come from the `supacodeAppTarget(name:bundleId:extraBaseSettings:)` factory in `Project.swift`; `Info.plist` reads display name, icon, and URL scheme via `$(VAR:default=…)` so the prod target is unchanged. Frameworks, GhosttyKit, and the CLI are shared targets built once.
- **Runtime dev-detection, no compile flag.** `SupacodePaths.isDevelopmentBuild` (bundle id ends in `.dev`) gates the data directory (`~/.supacode-dev`), the disabled Sparkle updater, the emitted deeplink scheme (`Deeplink.scheme`), and the CLI socket directory (`/tmp/supacode-dev-<uid>` vs `/tmp/supacode-<uid>`). `Bundle.main` resolves to the host app even from shared frameworks, so no per-target `SWIFT_ACTIVE_COMPILATION_CONDITIONS` is needed.
- **CLI isolation.** The `supacode` CLI binary is shared between the targets, so it derives dev-ness at runtime from its own executable path (is it inside a `.dev` bundle?): each build's embedded CLI resolves only its own socket directory, and the cold-launch fallback (`Dispatcher.launchApp`) opens the app bundle the CLI is embedded in, so the dev CLI cold-launches the dev app. Inside a Supacode terminal, `SUPACODE_SOCKET_PATH` pins routing regardless.
- **Dual-scheme acceptance.** The dev app registers `supacode-dev://` for OS routing but `Deeplink.acceptedSchemes` accepts both, so the CLI's `supacode://` payloads work against either build.
- **The dev icon is a pre-rendered `.appiconset`** (`AppIconDev`), the prod icon's pixels recolored to a blueprint-blue grid — Icon Composer's glass material renders the SC glyph grey over a bright field, so PNGs are used instead; regenerate by recoloring the prod PNGs if the icon changes.

## Architecture

Supacode is a macOS terminal emulator that for running multiple coding agents in parallel in Git worktrees, using GhosttyKit as the underlying terminal.

### Key Dependencies

- **TCA (swift-composable-architecture)**: App state, reducers, side effects
- **GhosttyKit**: Terminal emulator (built from Zig source in ThirdParty/ghostty)
- **Sparkle**: Auto-update framework
- **swift-dependencies**: Dependency injection for TCA clients
- **PostHog**: Analytics
- **Sentry**: Error tracking

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
- Sidebar rows must not fan out invalidation. Per-row state lives in `RepositoriesFeature.State.sidebarItems` so a per-leaf mutation (notification tick, agent activity, running-script update) invalidates only that leaf, not every sibling. The view renders the cached `state.sidebarStructure` (computed in the reducer's post-reduce hook), never reading `sidebarItems[id:]` from a view body; derive per-leaf data in `computeSidebarStructure(...)`, not in the view.

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
- Do not open a pull request unless the user explicitly asks for one. Commit to the working branch and let the user decide when to push and open a PR.
- When the user does ask you to open an issue or pull request, follow the templates in `.github`: fill the bug or feature issue form, and use the pull request template (link the issue with `Closes #<number>`, complete the checklist, and disclose any AI tools you used). A human is the author of record: never set an AI agent as a commit author or co-author.
