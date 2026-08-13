import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct AppFeatureOpenFileTests {
  @Test func openFileCommandInputExportsQuotedPath() {
    let input = AppFeature.openFileCommandInput(
      script: "nvim \"$SUPACODE_FILE_PATH\"",
      fileURL: URL(fileURLWithPath: "/tmp/repo/My File.swift")
    )
    #expect(input == "export SUPACODE_FILE_PATH='/tmp/repo/My File.swift'; nvim \"$SUPACODE_FILE_PATH\"")
  }

  @Test func openFileCommandInputQuotesSingleQuotesInPath() {
    // POSIX single-quote escaping keeps a literal quote in the path safe.
    let input = AppFeature.openFileCommandInput(
      script: "code",
      fileURL: URL(fileURLWithPath: "/tmp/o'brien.txt")
    )
    #expect(input == "export SUPACODE_FILE_PATH='/tmp/o'\"'\"'brien.txt'; code")
  }

  @Test(.dependencies) func openFileWithoutScriptOpensSystemDefaultApp() async {
    let worktree = makeWorktree()
    let openedWith = LockIsolated<[OpenWorktreeAction?]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.openFile = { _, action in
        openedWith.withValue { $0.append(action) }
        return nil
      }
    }
    store.exhaustivity = .off

    await store.send(.openFileFromExplorer(URL(fileURLWithPath: "/tmp/repo/wt-1/main.swift")))
    await store.finish()

    // A nil action tells the workspace client to use the system default app.
    #expect(openedWith.value == [nil])
  }

  @Test(.dependencies) func openFileWithGlobalScriptRunsItInTerminal() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    } operation: {
      var settings = GlobalSettings.default
      settings.openFileScript = "code \"$SUPACODE_FILE_PATH\""
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global = settings }
      return TestStore(
        initialState: AppFeature.State(
          repositories: makeRepositoriesState(worktree: worktree),
          settings: SettingsFeature.State(settings: settings)
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.terminalClient.send = { command in
          sent.withValue { $0.append(command) }
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.openFileFromExplorer(URL(fileURLWithPath: "/tmp/repo/wt-1/main.swift")))
    await store.finish()

    #expect(sent.value.count == 1)
    guard case .openFileWithScript(let sentWorktree, let input) = sent.value.first else {
      Issue.record("Expected openFileWithScript command")
      return
    }
    #expect(sentWorktree == worktree)
    #expect(
      input == "export SUPACODE_FILE_PATH='/tmp/repo/wt-1/main.swift'; code \"$SUPACODE_FILE_PATH\""
    )
  }

  @Test(.dependencies) func openFileRepositoryScriptWinsOverGlobal() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let storage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let repositoryID = worktree.repositoryRootURL.standardizedFileURL.path(percentEncoded: false)
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      var repoSettings = RepositorySettings.default
      repoSettings.openFileScript = "repo-editor \"$SUPACODE_FILE_PATH\""
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock {
        $0.global.openFileScript = "global-editor \"$SUPACODE_FILE_PATH\""
        $0.repositories[repositoryID] = repoSettings
      }
      return TestStore(
        initialState: AppFeature.State(
          repositories: makeRepositoriesState(worktree: worktree),
          settings: SettingsFeature.State()
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.settingsFileStorage = storage.storage
        $0.settingsFileURL = settingsFileURL
        $0.repositoryLocalSettingsStorage = localStorage.storage
        $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      }
    }
    store.exhaustivity = .off

    await store.send(.openFileFromExplorer(URL(fileURLWithPath: "/tmp/repo/wt-1/main.swift")))
    await store.finish()

    guard case .openFileWithScript(_, let input) = sent.value.first else {
      Issue.record("Expected openFileWithScript command")
      return
    }
    #expect(input.contains("repo-editor"))
    #expect(!input.contains("global-editor"))
  }

  @Test(.dependencies) func openFileWithWhitespaceOnlyScriptUsesSystemDefaultApp() async {
    let worktree = makeWorktree()
    let openedWith = LockIsolated<[OpenWorktreeAction?]>([])
    let sentTerminal = LockIsolated(false)
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    } operation: {
      var settings = GlobalSettings.default
      settings.openFileScript = "   \n  "
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global = settings }
      return TestStore(
        initialState: AppFeature.State(
          repositories: makeRepositoriesState(worktree: worktree),
          settings: SettingsFeature.State(settings: settings)
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.workspaceClient.openFile = { _, action in
          openedWith.withValue { $0.append(action) }
          return nil
        }
        $0.terminalClient.send = { _ in sentTerminal.setValue(true) }
      }
    }
    store.exhaustivity = .off

    await store.send(.openFileFromExplorer(URL(fileURLWithPath: "/tmp/repo/wt-1/main.swift")))
    await store.finish()

    // A blank hook is treated as unset, so no terminal runs and the OS opener is used.
    #expect(openedWith.value == [nil])
    #expect(sentTerminal.value == false)
  }

  @Test(.dependencies) func openFileOnRemoteWorktreeUsesSystemDefaultApp() async {
    let worktree = Worktree(
      id: "devbox:/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/repo"),
      host: RemoteHost(alias: "devbox")
    )
    let openedWith = LockIsolated<[OpenWorktreeAction?]>([])
    let sentTerminal = LockIsolated(false)
    let storage = SettingsTestStorage()
    let settingsFileURL = URL(fileURLWithPath: "/tmp/supacode-settings-\(UUID().uuidString).json")
    let store = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.settingsFileURL = settingsFileURL
    } operation: {
      var settings = GlobalSettings.default
      settings.openFileScript = "code \"$SUPACODE_FILE_PATH\""
      @Shared(.settingsFile) var settingsFile
      $settingsFile.withLock { $0.global = settings }
      return TestStore(
        initialState: AppFeature.State(
          repositories: makeRepositoriesState(worktree: worktree),
          settings: SettingsFeature.State(settings: settings)
        )
      ) {
        AppFeature()
      } withDependencies: {
        $0.workspaceClient.openFile = { _, action in
          openedWith.withValue { $0.append(action) }
          return nil
        }
        $0.terminalClient.send = { _ in sentTerminal.setValue(true) }
      }
    }
    store.exhaustivity = .off

    await store.send(.openFileFromExplorer(URL(fileURLWithPath: "/repo/wt-1/main.swift")))
    await store.finish()

    // The open-file script never runs against a remote path: the OS opener is used instead.
    #expect(openedWith.value == [nil])
    #expect(sentTerminal.value == false)
  }

  @Test func placementZoomedPaneGetsTabInThatPane() {
    let zoomed = PaneID()
    let placement = WorktreeTerminalManager.openFilePlacement(
      zoomedLeaf: zoomed, leafCount: 3, topRightLeaf: PaneID(), focusedPane: PaneID(),
      hasRoomForSplit: true)
    #expect(placement == .tab(paneToken: zoomed.rawValue))
  }

  @Test func placementMultiPaneGetsTabInTopRight() {
    let topRight = PaneID()
    let placement = WorktreeTerminalManager.openFilePlacement(
      zoomedLeaf: nil, leafCount: 2, topRightLeaf: topRight, focusedPane: PaneID(),
      hasRoomForSplit: false)
    #expect(placement == .tab(paneToken: topRight.rawValue))
  }

  @Test func placementMultiPaneFallsBackToFocusedWhenNoTopRight() {
    let focused = PaneID()
    let placement = WorktreeTerminalManager.openFilePlacement(
      zoomedLeaf: nil, leafCount: 2, topRightLeaf: nil, focusedPane: focused, hasRoomForSplit: false)
    #expect(placement == .tab(paneToken: focused.rawValue))
  }

  @Test func placementLonePaneSplitsWhenRoom() {
    let only = PaneID()
    let placement = WorktreeTerminalManager.openFilePlacement(
      zoomedLeaf: nil, leafCount: 1, topRightLeaf: only, focusedPane: nil, hasRoomForSplit: true)
    #expect(placement == .splitRight(paneToken: only.rawValue))
  }

  @Test func placementLonePaneGetsTabWhenNoRoom() {
    let only = PaneID()
    let placement = WorktreeTerminalManager.openFilePlacement(
      zoomedLeaf: nil, leafCount: 1, topRightLeaf: only, focusedPane: nil, hasRoomForSplit: false)
    #expect(placement == .tab(paneToken: only.rawValue))
  }

  @Test func placementIsNilWhenNoPaneResolves() {
    #expect(
      WorktreeTerminalManager.openFilePlacement(
        zoomedLeaf: nil, leafCount: 0, topRightLeaf: nil, focusedPane: nil, hasRoomForSplit: false)
        == nil)
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepositoriesState(worktree: Worktree) -> RepositoriesFeature.State {
    let repository = Repository(
      id: "/tmp/repo",
      rootURL: URL(fileURLWithPath: "/tmp/repo"),
      name: "repo",
      worktrees: [worktree]
    )
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    repositoriesState.selection = .worktree(worktree.id)
    repositoriesState.reconcileSidebarForTesting()
    return repositoriesState
  }
}
