import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureMenuBarNotificationsTests {
  @Test(.dependencies) func menuBarWorktreeSelectedSelectsWorktreeAndSurfacesTheWindow() async {
    let worktree = makeWorktree()
    let surfaced = LockIsolated(0)
    let store = makeStore(worktree: worktree) {
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.withValue { $0 += 1 }
        return true
      }
    }

    await store.send(.menuBarWorktreeSelected(worktreeID: worktree.id))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
    #expect(surfaced.value == 1)
  }

  @Test(.dependencies) func menuBarWorktreeSelectedStillSurfacesTheWindowWhenTheWorktreeIsGone() async {
    let worktree = makeWorktree()
    let surfaced = LockIsolated(0)
    let store = makeStore(worktree: worktree) {
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.withValue { $0 += 1 }
        return true
      }
    }

    // A stale click must never be a no-op: in menu bar mode that is
    // indistinguishable from a hung app.
    await store.send(.menuBarWorktreeSelected(worktreeID: Worktree.ID("/tmp/repo/vanished")))
    await store.finish()

    #expect(surfaced.value == 1)
  }

  @Test(.dependencies) func markAllNotificationsReadForwardsToTerminalClient() async {
    let worktree = makeWorktree()
    let calls = LockIsolated(0)
    let store = makeStore(worktree: worktree) {
      $0.terminalClient.markAllNotificationsRead = {
        calls.withValue { $0 += 1 }
      }
    }

    await store.send(.markAllNotificationsRead)
    await store.finish()

    #expect(calls.value == 1)
  }

  // MARK: - Activation policy.

  @Test(.dependencies) func switchingToMenuBarOnlyAppliesTheAccessoryPolicy() async {
    let applied = LockIsolated<[AppVisibility]>([])
    let surfaced = LockIsolated(0)
    let store = makeStore(worktree: makeWorktree()) {
      $0.appLifecycleClient.applyVisibility = { visibility in
        applied.withValue { $0.append(visibility) }
        return true
      }
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.withValue { $0 += 1 }
        return true
      }
    }

    var settings = GlobalSettings.default
    settings.appVisibility = .menuBar
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()

    #expect(applied.value == [.menuBar])
    // Nothing to surface: the Dock icon is going away, not coming back.
    #expect(surfaced.value == 0)
  }

  @Test(.dependencies) func leavingMenuBarOnlyRestoresTheDockIconAndSurfacesTheWindow() async {
    let applied = LockIsolated<[AppVisibility]>([])
    let surfaced = LockIsolated(0)
    var initialSettings = GlobalSettings.default
    initialSettings.appVisibility = .menuBar
    let store = makeStore(worktree: makeWorktree(), settings: initialSettings) {
      $0.appLifecycleClient.applyVisibility = { visibility in
        applied.withValue { $0.append(visibility) }
        return true
      }
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.withValue { $0 += 1 }
        return true
      }
    }

    var settings = GlobalSettings.default
    settings.appVisibility = .dock
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()

    #expect(applied.value == [.dock])
    // Without this the user leaves menu bar mode with a Dock icon and no window.
    #expect(surfaced.value == 1)
  }

  @Test(.dependencies) func leavingMenuBarOnlyForBothAlsoSurfacesTheWindow() async {
    let applied = LockIsolated<[AppVisibility]>([])
    let surfaced = LockIsolated(0)
    var initialSettings = GlobalSettings.default
    initialSettings.appVisibility = .menuBar
    let store = makeStore(worktree: makeWorktree(), settings: initialSettings) {
      $0.appLifecycleClient.applyVisibility = { visibility in
        applied.withValue { $0.append(visibility) }
        return true
      }
      $0.appLifecycleClient.surfaceMainWindow = {
        surfaced.withValue { $0 += 1 }
        return true
      }
    }

    var settings = GlobalSettings.default
    settings.appVisibility = .dockAndMenuBar
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()

    #expect(applied.value == [.dockAndMenuBar])
    // The Dock icon comes back here too, so the window must follow.
    #expect(surfaced.value == 1)
  }

  @Test(.dependencies) func aRefusedPolicySwitchFallsBackToTheModeThatStillHasASurface() async {
    var initialSettings = GlobalSettings.default
    initialSettings.appVisibility = .menuBar
    let store = makeStore(worktree: makeWorktree(), settings: initialSettings) {
      // AppKit refuses `.accessory` -> `.regular`: without a fallback the status
      // item is already gone and no Dock icon arrives, leaving no surface at all.
      $0.appLifecycleClient.applyVisibility = { _ in false }
      $0.appLifecycleClient.surfaceMainWindow = { true }
    }

    var settings = GlobalSettings.default
    settings.appVisibility = .dock
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    // The fallback must carry `.menuBar` specifically: a wrong direction here
    // (e.g. re-sending `.dock`) would strand the user with no surface.
    await store.receive(\.settings.setAppVisibility, .menuBar)
    await store.finish()

    #expect(store.state.settings.appVisibility == .menuBar)
  }

  @Test(.dependencies) func repeatedSettingsChangesDoNotReapplyTheSameVisibility() async {
    let applied = LockIsolated<[AppVisibility]>([])
    let store = makeStore(worktree: makeWorktree()) {
      $0.appLifecycleClient.applyVisibility = { visibility in
        applied.withValue { $0.append(visibility) }
        return true
      }
      $0.appLifecycleClient.surfaceMainWindow = { true }
    }

    var settings = GlobalSettings.default
    settings.appVisibility = .menuBar
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    // A second, identical delegate must not re-apply the policy: `activate()` on
    // the retry path would steal focus on every unrelated settings edit.
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()

    #expect(applied.value == [.menuBar])
    #expect(store.state.lastKnownAppVisibility == .menuBar)
  }

  @Test(.dependencies) func unchangedVisibilityTouchesTheActivationPolicyNotAtAll() async {
    let applied = LockIsolated<[AppVisibility]>([])
    let store = makeStore(worktree: makeWorktree()) {
      $0.appLifecycleClient.applyVisibility = { visibility in
        applied.withValue { $0.append(visibility) }
        return true
      }
    }

    var settings = GlobalSettings.default
    settings.appVisibility = .dock
    settings.agentPresenceBadgesEnabled.toggle()
    await store.send(.settings(.delegate(.settingsChanged(settings))))
    await store.finish()

    #expect(applied.value.isEmpty)
  }

  // MARK: - Helpers.

  private func makeWorktree(
    id: String = "/tmp/repo/wt-1",
    name: String = "wt-1"
  ) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  private func makeStore(
    worktree: Worktree,
    settings: GlobalSettings = .default,
    withAdditionalDependencies: (inout DependencyValues) -> Void
  ) -> TestStoreOf<AppFeature> {
    var repositoriesState = RepositoriesFeature.State()
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree],
    )
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.isInitialLoadComplete = true

    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State(settings: settings)
      )
    ) {
      AppFeature()
    } withDependencies: { values in
      values.terminalClient.tabExists = { _, _ in true }
      values.terminalClient.surfaceExists = { _, _, _ in true }
      withAdditionalDependencies(&values)
    }
    store.exhaustivity = .off
    return store
  }
}
