import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

// MARK: - AppFeature action.

@MainActor
struct AppFeatureNewScratchpadTests {
  @Test(.dependencies) func newScratchpadSendsCreateScratchpadTabCommand() async {
    let worktree = makeWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: makeRepositoriesState(worktree: worktree),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in
        sent.withValue { $0.append(command) }
      }
    }

    await store.send(.newScratchpad)
    await store.finish()
    #expect(sent.value == [.createScratchpadTab(worktree)])
  }

  @Test(.dependencies) func newScratchpadWithoutSelectionIsNoop() async {
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in
        Issue.record("terminalClient.send should not be called without a selected worktree")
      }
    }

    await store.send(.newScratchpad)
    await store.finish()
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
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.selection = .worktree(worktree.id)
    return state
  }
}

// MARK: - Snapshot schema.

struct ScratchpadTabSnapshotTests {
  @Test func scratchpadTabSnapshotRoundTrips() throws {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "Scratchpad",
          customTitle: "Notes",
          icon: "note.text",
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil)),
          focusedLeafIndex: 0,
          kind: .scratchpad,
          scratchpadText: "paste buffer\nline two"
        )
      ],
      selectedTabIndex: 0
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)
    #expect(decoded == snapshot)
    #expect(decoded.tabs.first?.kind == .scratchpad)
    #expect(decoded.tabs.first?.scratchpadText == "paste buffer\nline two")
  }

  @Test func legacyTabSnapshotDecodesWithNilKind() throws {
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": null,
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": null}}},
            "focusedLeafIndex": 0
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let snapshot = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs.first?.kind == nil)
    #expect(snapshot.tabs.first?.scratchpadText == nil)
  }

  @Test func unknownFutureKindDegradesToNil() throws {
    let json = #"""
      {
        "tabs": [
          {
            "id": null,
            "title": "tab",
            "customTitle": null,
            "icon": null,
            "tintColor": null,
            "layout": {"leaf": {"_0": {"id": null, "workingDirectory": null}}},
            "focusedLeafIndex": 0,
            "kind": "hologram"
          }
        ],
        "selectedTabIndex": 0
      }
      """#
    let snapshot = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.tabs.first?.kind == nil)
  }

  @Test func scratchpadSentinelLeafClaimsNoSurfaceIDs() {
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "Scratchpad",
          customTitle: nil,
          icon: "note.text",
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil)),
          focusedLeafIndex: 0,
          kind: .scratchpad,
          scratchpadText: ""
        )
      ],
      selectedTabIndex: 0
    )
    // The orphan-session reaper must not see any zmx claim from a scratchpad.
    #expect(snapshot.allSurfaceIDs.isEmpty)
  }
}

// MARK: - Terminal state behavior.

// Serialized alongside the manager suites: mixed-tab tests spin real
// GhosttyRuntime surfaces whose teardown flakes when interleaved.
@MainActor
@Suite(.serialized)
struct ScratchpadTerminalStateTests {
  @Test func createScratchpadTabCreatesSelectedSurfacelessTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())

    let tabId = state.createScratchpadTab()

    #expect(state.tabManager.selectedTabId == tabId)
    #expect(state.tabManager.isScratchpad(tabId))
    #expect(state.tabManager.tabs.first?.title == "Scratchpad")
    #expect(state.surfaceIDs(inTab: tabId).isEmpty)
    #expect(state.activeSurfaceID(for: tabId) == nil)
    #expect(state.scratchpadText(for: tabId).isEmpty)
  }

  @Test func scratchpadTitlesNumberPastLiveMaximum() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())

    _ = state.createScratchpadTab()
    let second = state.createScratchpadTab()
    let third = state.createScratchpadTab()

    #expect(state.tabManager.tabs.first(where: { $0.id == second })?.title == "Scratchpad 2")
    #expect(state.tabManager.tabs.first(where: { $0.id == third })?.title == "Scratchpad 3")
  }

  @Test func selectingScratchpadTabMintsNoSurface() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())

    let tabId = state.createScratchpadTab()
    state.selectTab(tabId)
    state.focusSelectedTab()

    #expect(state.surfaceIDs(inTab: tabId).isEmpty)
    #expect(!state.hasAnySurface)
  }

  @Test func scratchpadProjectionEmitsSurfacelessRow() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())
    var projections: [WorktreeTabProjection] = []
    state.onTabProjectionChanged = { projections.append($0) }

    let tabId = state.createScratchpadTab()

    let projection = projections.last(where: { $0.tabID == tabId })
    #expect(projection != nil)
    #expect(projection?.surfaceIDs.isEmpty == true)
    #expect(projection?.activeSurfaceID == nil)
  }

  @Test func closeScratchpadTabRemovesProjectionAndContent() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())
    var removedTabIDs: [TerminalTabID] = []
    state.onTabRemoved = { removedTabIDs.append($0) }

    let tabId = state.createScratchpadTab()
    state.setScratchpadText("scratch", for: tabId)
    state.closeTab(tabId)

    #expect(removedTabIDs == [tabId])
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.scratchpadText(for: tabId).isEmpty)
  }

  @Test func setScratchpadTextNotifiesPersistenceSinkOnceGated() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())
    var changeCount = 0
    state.onScratchpadContentChanged = { changeCount += 1 }

    let tabId = state.createScratchpadTab()
    state.setScratchpadText("a", for: tabId)
    // Identical write dedupes; no redundant persist scheduling.
    state.setScratchpadText("a", for: tabId)
    // Writes against a non-scratchpad id are refused.
    state.setScratchpadText("b", for: TerminalTabID())

    #expect(changeCount == 1)
    #expect(state.scratchpadText(for: tabId) == "a")
  }

  @Test func captureLayoutSnapshotPersistsScratchpadText() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())

    let tabId = state.createScratchpadTab()
    state.setScratchpadText("keep me", for: tabId)

    let snapshot = state.captureLayoutSnapshot()
    let tab = snapshot?.tabs.first(where: { $0.id == tabId.rawValue })
    #expect(tab?.kind == .scratchpad)
    #expect(tab?.scratchpadText == "keep me")
    #expect(snapshot?.allSurfaceIDs.isEmpty == true)
  }

  @Test func restoreFromSnapshotRestoresScratchpadTabAndText() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let scratchpadTabID = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: scratchpadTabID,
          title: "Scratchpad",
          customTitle: "Notes",
          icon: "note.text",
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: nil)),
          focusedLeafIndex: 0,
          kind: .scratchpad,
          scratchpadText: "restored text"
        )
      ],
      selectedTabIndex: 0
    )
    manager.loadLayoutSnapshot = { _ in snapshot }
    let state = manager.state(for: worktree)

    state.ensureInitialTab(focusing: false)

    let tabId = TerminalTabID(rawValue: scratchpadTabID)
    #expect(state.tabManager.isScratchpad(tabId))
    #expect(state.tabManager.tabs.first?.displayTitle == "Notes")
    #expect(state.scratchpadText(for: tabId) == "restored text")
    #expect(state.surfaceIDs(inTab: tabId).isEmpty)
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-scratch") -> Worktree {
    let name = URL(fileURLWithPath: id).lastPathComponent
    return Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }
}
