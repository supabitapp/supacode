import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsFeature
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
  private func makeHarness() -> Harness {
    let worktree = makeWorktree()
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { false },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
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
