## Build Commands

```bash
make # this show available commands
```

Requires [mise](https://mise.jdx.dev/) for zig, swiftlint, swift-format, xcbeautify, and xcsift tooling. Run `mise install` once to fetch the pinned versions.

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
