import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsFeature
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Pins the manager's creation-ack contract: every `createTab` command emits
/// either the success pair (`tabCreated` + `surfaceCreated`) or a
/// `surfaceCreationFailed`, so a CLI or deeplink client can never strand on
/// the watchdog.
@MainActor
struct WorktreeTerminalManagerAckTests {
  private struct Harness {
    let manager: WorktreeTerminalManager
    let store: Store<AppFeature.State, AppFeature.Action>
    let worktree: Worktree
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-ack") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  /// Manager wired to a live store whose factory provisions inert content, so
  /// creation flows run end to end without spawning surfaces.
  private func makeHarness(
    storage: SettingsFileStorage = .inMemory(),
    killRemoteSession: @escaping @Sendable (RemoteHost, String) -> Void = { _, _ in }
  ) -> Harness {
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.settingsFileStorage = storage
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { false },
        killSession: { _ in },
        killRemoteSession: { host, session in killRemoteSession(host, session) },
        listSessionsWithClients: { nil }
      )
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let store = Store(
      initialState: AppFeature.State(
        repositories: RepositoriesFeature.State(),
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      // One shared registry: the per-access `testValue` would otherwise hand
      // provision and lookup different runtimes.
      $0.contentRuntime = ContentRuntime()
      $0[LayoutContentFactory.self] = LayoutContentFactory { request in
        InertTabContent(id: request.contentID, state: request.content)
      }
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    manager.appStore = store
    return Harness(manager: manager, store: store, worktree: worktree)
  }

  /// One long-lived subscription per test: resubscribing between commands
  /// would strand one-shot events in the abandoned stream. Pulls creation
  /// events only; state replays (indicator counts, projections) pass through.
  private final class CreationEvents {
    // Tests pull sequentially on one task; the iterator only needs to escape
    // the actor so its mutating async `next` can run across suspensions.
    nonisolated(unsafe) private var iterator: AsyncStream<TerminalClient.Event>.AsyncIterator

    init(_ manager: WorktreeTerminalManager) {
      iterator = manager.eventStream().makeAsyncIterator()
    }

    func next(_ count: Int) async -> [TerminalClient.Event] {
      var events: [TerminalClient.Event] = []
      while events.count < count, let event = await iterator.next() {
        switch event {
        case .tabCreated, .surfaceCreated, .surfaceCreationFailed:
          events.append(event)
        default:
          continue
        }
      }
      return events
    }
  }

  @Test(.dependencies) func explicitIDCreateEmitsTheSuccessPair() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let id = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: id, focusing: false))

    let events = await pump.next(2)
    #expect(events.contains(.tabCreated(worktreeID: harness.worktree.id)))
    #expect(events.contains(.surfaceCreated(worktreeID: harness.worktree.id, id: id)))
    // The documented invariant: the initial surface ID equals the tab ID.
    let layout = harness.store.withState { $0.terminals.layouts[id: harness.worktree.id]?.layout }
    #expect(layout?.pane(containingTab: TabID(rawValue: id))?.tabs[id: TabID(rawValue: id)]?.content.id.rawValue == id)
  }

  @Test(.dependencies) func createWithoutAStoreDrainsTheAckAsFailure() async {
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.zmxClient = .noop
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    let pump = CreationEvents(manager)
    let id = UUID()
    manager.handleCommand(.createTab(worktree, runSetupScriptIfNew: false, id: id, focusing: false))

    let events = await pump.next(1)
    guard case .surfaceCreationFailed(let worktreeID, let attemptedID, _) = events.first else {
      Issue.record("Expected surfaceCreationFailed, got \(events)")
      return
    }
    #expect(worktreeID == worktree.id)
    #expect(attemptedID == id)
  }

  @Test(.dependencies) func collidingContentIDCreateFailsInsteadOfFalselyAcking() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let first = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: first, focusing: false))
    _ = await pump.next(2)

    // Reusing the surface id of the EXISTING tab must refuse and say so, not
    // match the old content and ack a creation that never happened.
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: first, focusing: false))
    let events = await pump.next(1)
    guard case .surfaceCreationFailed = events.first else {
      Issue.record("Expected surfaceCreationFailed, got \(events)")
      return
    }
  }

  @Test(.dependencies) func ensureInitialTabOnAPopulatedLayoutStillAcks() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: UUID(), focusing: false))
    _ = await pump.next(2)

    // A hydrated or already-bootstrapped layout resolves a waiting
    // worktree-new ack instead of stranding it until the watchdog.
    harness.manager.handleCommand(
      .ensureInitialTab(harness.worktree, runSetupScriptIfNew: false, focusing: false))
    let events = await pump.next(1)
    #expect(events.first == .tabCreated(worktreeID: harness.worktree.id))
  }

  private func singleTabLayout(contentID: UUID) -> PaneLayout {
    let paneID = PaneID()
    let tabID = TabID(rawValue: contentID)
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: tabID,
              title: "Restored",
              content: ContentSnapshot(
                id: ContentID(rawValue: contentID),
                state: .terminal(TerminalContentState(workingDirectory: nil))
              )
            )
          ],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
  }

  @Test(.dependencies) func removingADeletedWorktreesLayoutWorksWithoutAHost() async throws {
    let inner = SettingsFileStorage.inMemory()
    let (fileWrites, writeSignal) = AsyncStream<LayoutsFile>.makeStream()
    let storage = SettingsFileStorage(
      load: { try inner.load($0) },
      save: { data, url in
        try inner.save(data, url)
        if let file = try? JSONDecoder().decode(LayoutsFile.self, from: data) {
          writeSignal.yield(file)
        }
      }
    )
    let harness = makeHarness(storage: storage)
    let contentID = UUID()
    let layout = singleTabLayout(contentID: contentID)
    let record = LayoutRecord(layout: layout)
    try inner.save(
      JSONEncoder().encode(LayoutsFile(worktrees: [harness.worktree.id.rawValue: record])),
      SupacodePaths.layoutsURL
    )
    // Hydrated but never selected: no host exists for this worktree.
    harness.store.send(
      .terminals(
        .layoutsHydrated(LayoutsFile(worktrees: [harness.worktree.id.rawValue: record]))
      )
    )
    #expect(harness.store.withState { $0.terminals.layouts[id: harness.worktree.id] } != nil)

    harness.manager.handleCommand(
      .removeWorktreeLayout(worktreeID: harness.worktree.id, remoteHost: nil))

    // The in-memory layout detaches AND the persisted record goes with it;
    // this hostless-hydrated case is exactly the one roster prune cannot reach.
    #expect(harness.store.withState { $0.terminals.layouts[id: harness.worktree.id] } == nil)
    var writes = fileWrites.makeAsyncIterator()
    let written = await writes.next()
    #expect(written?.worktrees.isEmpty == true)
  }

  @Test(.dependencies) func removingADeletedRemoteWorktreesLayoutKillsItsHostSessions() async {
    let (remoteKills, killSignal) = AsyncStream<(String, String)>.makeStream()
    let harness = makeHarness(killRemoteSession: { host, session in
      killSignal.yield((host.alias, session))
    })
    let contentID = UUID()
    harness.store.send(
      .terminals(
        .layoutsHydrated(
          LayoutsFile(
            worktrees: [
              harness.worktree.id.rawValue: LayoutRecord(layout: singleTabLayout(contentID: contentID))
            ]
          )
        )
      )
    )

    harness.manager.handleCommand(
      .removeWorktreeLayout(
        worktreeID: harness.worktree.id, remoteHost: RemoteHost(alias: "build-box")))

    var kills = remoteKills.makeAsyncIterator()
    let kill = await kills.next()
    #expect(kill?.0 == "build-box")
    #expect(kill?.1 == ZmxSessionID.make(surfaceID: contentID))
  }

  @Test(.dependencies) func anchoredCreateLandsInTheAnchorsPane() async {
    let harness = makeHarness()
    let pump = CreationEvents(harness.manager)
    let anchor = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: anchor, focusing: false))
    _ = await pump.next(2)

    let added = UUID()
    harness.manager.handleCommand(
      .createTab(
        harness.worktree, runSetupScriptIfNew: false, id: added, focusing: false, anchor: anchor))
    _ = await pump.next(2)

    let layout = harness.store.withState { $0.terminals.layouts[id: harness.worktree.id]?.layout }
    let anchorPane = layout?.tab(containingContent: ContentID(rawValue: anchor))?.pane
    #expect(anchorPane?.tabs[id: TabID(rawValue: added)] != nil)
  }
}
