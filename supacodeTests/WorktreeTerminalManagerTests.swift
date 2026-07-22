import AppKit
import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

// Serialized: these tests spin real GhosttyRuntime surfaces and fake zmx
// processes whose event-driven waits flake when interleaved with each other.
@MainActor
@Suite(.serialized)
struct WorktreeTerminalManagerTests {
  @Test func reusesExistingStateAndReloadsSnapshotAfterRestoreIsEnabled() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let snapshot = makeLayoutSnapshot()
    var restoreEnabled = false

    manager.loadLayoutSnapshot = { _ in
      guard restoreEnabled else { return nil }
      return snapshot
    }

    let initialState = manager.state(for: worktree)
    #expect(initialState.pendingLayoutSnapshot == nil)

    restoreEnabled = true

    let reusedState = manager.state(for: worktree)
    #expect(reusedState === initialState)
    #expect(reusedState.pendingLayoutSnapshot == snapshot)
  }

  @Test func reusingExistingStateDoesNotReloadSnapshotWhenSetupScriptBecomesPending() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let snapshot = makeLayoutSnapshot()
    var restoreEnabled = false

    manager.loadLayoutSnapshot = { _ in
      guard restoreEnabled else { return nil }
      return snapshot
    }

    let initialState = manager.state(for: worktree)
    #expect(initialState.pendingLayoutSnapshot == nil)

    restoreEnabled = true

    let reusedState = manager.state(for: worktree) { true }
    #expect(reusedState === initialState)
    #expect(reusedState.needsSetupScript())
    #expect(reusedState.pendingLayoutSnapshot == nil)
  }

  @Test func ensureInitialTabCreatesTabSynchronously() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.ensureInitialTab(focusing: false)

    #expect(state.hasAttemptedInitialTab)
    #expect(state.tabManager.tabs.count == 1)
    #expect(state.tabManager.selectedTabId != nil)
  }

  @Test func ensureInitialTabAfterCloseAllDoesNotAutoRecreate() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.ensureInitialTab(focusing: false)
    for tab in state.tabManager.tabs {
      state.closeTab(tab.id)
    }

    state.ensureInitialTab(focusing: false)

    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.tabManager.selectedTabId == nil)
  }

  @Test func ensureInitialTabConsumesPendingSnapshotAndStickies() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    state.pendingLayoutSnapshot = makeLayoutSnapshot()

    state.ensureInitialTab(focusing: false)

    #expect(state.pendingLayoutSnapshot == nil)
    #expect(state.hasAttemptedInitialTab)
    #expect(state.tabManager.tabs.count == 1)
  }

  @Test func buffersEventsUntilStreamCreated() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.onSetupScriptConsumed?()

    let stream = manager.eventStream()
    let event = await nextEvent(stream) { event in
      if case .setupScriptConsumed = event {
        return true
      }
      return false
    }

    #expect(event == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func emitsEventsAfterStreamCreated() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let stream = manager.eventStream()
    let eventTask = Task {
      await nextEvent(stream) { event in
        if case .setupScriptConsumed = event {
          return true
        }
        return false
      }
    }

    state.onSetupScriptConsumed?()

    let event = await eventTask.value
    #expect(event == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func unavailableSocketServerIsDiscarded() {
    let server = AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
    server.shutdown()

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), socketServer: server)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(manager.socketServer == nil)
    #expect(state.socketPath == nil)
  }

  @Test func oscHookActivityEventRoutesToWorktreeState() async {
    let server = AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness(socketServer: server)
    let worktree = makeWorktree(id: "/tmp/repo/wt with spaces")

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and socket server")
      return
    }

    state.onAgentHookEvent?(makeHookEvent(.sessionStart, surfaceID: surface.id, pid: getpid()))
    state.onAgentHookEvent?(makeHookEvent(.busy, surfaceID: surface.id))
    await presence.drain()

    #expect(presence.state.hasActivity(in: [surface.id]))
  }

  @Test func oscIdleEventIsDebouncedAcrossToolStorm() async {
    let clock = TestClock()
    let server = AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness(socketServer: server, clock: clock)
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    state.onAgentHookEvent?(makeHookEvent(.sessionStart, surfaceID: surface.id, pid: getpid()))
    state.onAgentHookEvent?(makeHookEvent(.busy, surfaceID: surface.id))
    await presence.drain()
    #expect(presence.state.hasActivity(in: [surface.id]))

    state.onAgentHookEvent?(makeHookEvent(.idle, surfaceID: surface.id))
    await presence.advance(clock, by: .milliseconds(100))
    await presence.drain()
    #expect(presence.state.hasActivity(in: [surface.id]))

    state.onAgentHookEvent?(makeHookEvent(.busy, surfaceID: surface.id))
    await presence.advance(clock, by: .milliseconds(500))
    await presence.drain()
    #expect(presence.state.hasActivity(in: [surface.id]))
  }

  @Test func oscIdleCommitsAfterDebounceWindow() async {
    let clock = TestClock()
    let server = AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness(socketServer: server, clock: clock)
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    state.onAgentHookEvent?(makeHookEvent(.sessionStart, surfaceID: surface.id, pid: getpid()))
    state.onAgentHookEvent?(makeHookEvent(.busy, surfaceID: surface.id))
    state.onAgentHookEvent?(makeHookEvent(.idle, surfaceID: surface.id))

    await presence.advance(clock, by: .milliseconds(399))
    await presence.drain()
    #expect(presence.state.hasActivity(in: [surface.id]))

    await presence.advance(clock, by: .milliseconds(1))
    await presence.drain()
    #expect(!presence.state.hasActivity(in: [surface.id]))
  }

  @Test func oscIdleDebouncesPerAgentIndependently() async {
    let clock = TestClock()
    let server = AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness(socketServer: server, clock: clock)
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    state.onAgentHookEvent?(makeHookEvent(.sessionStart, agent: .claude, surfaceID: surface.id, pid: getpid()))
    state.onAgentHookEvent?(makeHookEvent(.sessionStart, agent: .codex, surfaceID: surface.id, pid: getpid()))
    state.onAgentHookEvent?(makeHookEvent(.busy, agent: .claude, surfaceID: surface.id))
    state.onAgentHookEvent?(makeHookEvent(.busy, agent: .codex, surfaceID: surface.id))

    // Codex idles; Claude stays busy. After window, only Codex should commit idle.
    state.onAgentHookEvent?(makeHookEvent(.idle, agent: .codex, surfaceID: surface.id))
    await presence.advance(clock, by: .milliseconds(400))

    await presence.drain()
    let agents = presence.state.agents(across: [surface.id], badgesEnabled: true)
    let claude = agents.first { $0.agent == .claude }
    let codex = agents.first { $0.agent == .codex }
    #expect(claude?.activity == .busy)
    #expect(codex?.activity == .idle)
    #expect(presence.state.hasActivity(in: [surface.id]))
  }

  @Test func oscSessionEndCancelsPendingIdle() async {
    let clock = TestClock()
    let server = AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness(socketServer: server, clock: clock)
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    let pid = getpid()
    state.onAgentHookEvent?(makeHookEvent(.sessionStart, surfaceID: surface.id, pid: pid))
    state.onAgentHookEvent?(makeHookEvent(.busy, surfaceID: surface.id))
    state.onAgentHookEvent?(makeHookEvent(.idle, surfaceID: surface.id))
    state.onAgentHookEvent?(makeHookEvent(.sessionEnd, surfaceID: surface.id, pid: pid))

    await presence.advance(clock, by: .milliseconds(500))
    await presence.drain()

    #expect(presence.state.agents(forSurface: surface.id, badgesEnabled: true).isEmpty)
    #expect(!presence.state.hasActivity(in: [surface.id]))
  }

  @Test func oscSurfaceClosedWhileIdlePendingIsHarmless() async {
    let clock = TestClock()
    let server = AgentHookSocketServer(socketPathOverride: "/tmp/supacode-tests/\(UUID().uuidString)")
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness(socketServer: server, clock: clock)
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    state.onAgentHookEvent?(makeHookEvent(.sessionStart, surfaceID: surface.id, pid: getpid()))
    state.onAgentHookEvent?(makeHookEvent(.busy, surfaceID: surface.id))
    state.onAgentHookEvent?(makeHookEvent(.idle, surfaceID: surface.id))

    // Settle the stream-delivered events before the direct close so a buffered
    // busy can't resurrect activity after the surface is gone.
    await presence.drain()
    presence.send(.surfaceClosed(surface.id))
    await presence.advance(clock, by: .milliseconds(500))
    await presence.drain()

    #expect(!presence.state.hasActivity(in: [surface.id]))
  }

  @Test func rowProjectionCarriesRunningScriptsFromBlockingScripts() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "echo ok")

    manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "echo ok"))
    guard let state = manager.stateIfExists(for: worktree.id) else {
      Issue.record("Expected terminal state for worktree")
      return
    }
    #expect(
      state.currentProjection().runningScripts == [
        .init(id: definition.id, tint: definition.resolvedTintColor)
      ]
    )

    // Lifecycle kinds carry no definition ID and never surface as running scripts.
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    #expect(state.currentProjection().runningScripts.map(\.id) == [definition.id])

    // Stopping the script reconciles the projection back to empty (#573).
    manager.handleCommand(.stopScript(worktree, definitionID: definition.id))
    #expect(state.currentProjection().runningScripts.isEmpty)
  }

  @Test func runningScriptsMutationsCoalesceIntoOneCallbackPerTurn() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let first = ScriptDefinition(kind: .run, name: "Dev", command: "echo ok")
    let second = ScriptDefinition(kind: .test, name: "Test", command: "echo ok")
    let state = manager.state(for: worktree)

    // A double resume would trap, so each leg also pins "one callback per turn".
    await withCheckedContinuation { continuation in
      state.onRunningScriptsChanged = { continuation.resume() }
      manager.handleCommand(.runBlockingScript(worktree, kind: .script(first), script: "echo ok"))
    }
    await withCheckedContinuation { continuation in
      state.onRunningScriptsChanged = { continuation.resume() }
      manager.handleCommand(.runBlockingScript(worktree, kind: .script(second), script: "echo ok"))
    }
    #expect(Set(state.currentProjection().runningScripts.map(\.id)) == [first.id, second.id])

    // Closing every tab removes both tracked scripts in one turn; the emit
    // coalesces to a single callback observing only the final empty state.
    await withCheckedContinuation { continuation in
      state.onRunningScriptsChanged = {
        #expect(state.currentProjection().runningScripts.isEmpty)
        continuation.resume()
      }
      for tab in state.tabManager.tabs {
        state.closeTab(tab.id)
      }
    }
  }

  @Test func runBlockingScriptIgnoresDuplicateOfActiveScript() async {
    // A second run racing the projection reconcile must keep the running
    // instance, not close and relaunch its tab (#573).
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "echo ok")
    let state = manager.state(for: worktree)

    await withCheckedContinuation { continuation in
      state.onRunningScriptsChanged = { continuation.resume() }
      manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "echo ok"))
    }
    let tabsBefore = state.tabManager.tabs.map(\.id)

    manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "echo ok"))

    #expect(state.tabManager.tabs.map(\.id) == tabsBefore)
    #expect(state.currentProjection().runningScripts.map(\.id) == [definition.id])
  }

  @Test func duplicateRunReEmitsProjectionToHealStaleDropdown() async {
    // The ignored-duplicate path must still reconcile the row: if the original
    // running projection was shed, only a fresh emit un-sticks the dropdown from
    // Run. Without the emit the second continuation would never resume (#573).
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "echo ok")
    let state = manager.state(for: worktree)

    await withCheckedContinuation { continuation in
      state.onRunningScriptsChanged = { continuation.resume() }
      _ = state.runBlockingScript(kind: .script(definition), "echo ok")
    }
    let tabsBefore = state.tabManager.tabs.map(\.id)

    await withCheckedContinuation { continuation in
      state.onRunningScriptsChanged = { continuation.resume() }
      _ = state.runBlockingScript(kind: .script(definition), "echo ok")
    }
    #expect(state.tabManager.tabs.map(\.id) == tabsBefore)
  }

  @Test func duplicateRunReAssertsProjectionPastDedupe() async {
    // Once the running projection is cached, an archived-strip can leave the
    // manager asserting running while the row shows empty. A duplicate run must
    // re-deliver the running projection past the dedupe so the row heals; a
    // plain deduped emit would suppress the identical value and the second
    // await would hang (#573).
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "echo ok")
    _ = manager.state(for: worktree)
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "echo ok"))
    var running = await nextRunningScripts(stream)
    while running?.isEmpty == true { running = await nextRunningScripts(stream) }
    #expect(running?.map(\.id) == [definition.id])

    // Duplicate run: the running set is unchanged, so a plain emit would dedupe.
    manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "echo ok"))
    var reAsserted = await nextRunningScripts(stream)
    while reAsserted?.isEmpty == true { reAsserted = await nextRunningScripts(stream) }
    #expect(reAsserted?.map(\.id) == [definition.id])
  }

  @Test func lifecycleScriptRerunReplacesTab() {
    // The duplicate guard is scoped to user scripts; lifecycle kinds keep their
    // replace-on-rerun semantics, so a second archive run opens a fresh tab.
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let first = state.runBlockingScript(kind: .archive, "echo ok")
    let second = state.runBlockingScript(kind: .archive, "echo ok")
    #expect(first != nil)
    #expect(second != nil)
    #expect(first != second)
  }

  @Test func runningScriptsFlowThroughRowProjectionEvents() async {
    // Pins the wiring the dropdown fix hangs on: `blockingScripts` mutations
    // reach TCA as `worktreeProjectionChanged` events carrying the set (#573).
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "echo ok")
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "echo ok"))
    var started = await nextRunningScripts(stream)
    while started?.isEmpty == true { started = await nextRunningScripts(stream) }
    #expect(started?.map(\.id) == [definition.id])

    manager.handleCommand(.stopScript(worktree, definitionID: definition.id))
    var stopped = await nextRunningScripts(stream)
    while stopped?.isEmpty == false { stopped = await nextRunningScripts(stream) }
    #expect(stopped?.isEmpty == true)
  }

  @Test func stopWithoutTrackedScriptForcesProjectionReEmit() async {
    // A stop that matches nothing means the caller acted on a stale mirror;
    // the forced re-emit is what lets a phantom Stop click self-heal (#573).
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    _ = manager.state(for: worktree)
    let stream = manager.eventStream()
    // Drain the subscribe-time seed so the next projection can only be the
    // forced re-emit (without it, this await hangs).
    _ = await nextRunningScripts(stream)

    manager.handleCommand(.stopScript(worktree, definitionID: UUID()))
    let reEmitted = await nextRunningScripts(stream)
    #expect(reEmitted?.isEmpty == true)
  }

  @Test func shedProjectionInvalidatesDedupeSoNextEmitLands() async {
    // A shed projection was never delivered, so its dedupe entries must not
    // suppress the next identical emit or the row strands desynced (#573).
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), eventBufferCap: 1)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    // Relies on the projection being the last subscribe-time seed, so it is
    // the resident event the overflow below sheds.
    let stream = manager.eventStream()

    // Overflow the single-slot buffer so the seeded projection is shed unseen.
    state.onSetupScriptConsumed?()
    // Identical re-emit: only the shed-time dedupe invalidation lets it
    // through (without it, this await hangs).
    state.onRunningScriptsChanged?()

    let projection = await nextRunningScripts(stream)
    #expect(projection?.isEmpty == true)
  }

  @Test func shedProjectionReplaysWithoutASubsequentEmit() async {
    // A shed projection with no later terminal mutation must still redeliver, or
    // a completed script's clear transition strands the Run/Stop dropdown (#573).
    // Without the replay this await hangs: nothing else emits the row.
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), eventBufferCap: 1)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let stream = manager.eventStream()

    // Shed the subscribe-time projection with a filler and emit nothing
    // further, so only the shed-driven replay can deliver the row. This is
    // `shedProjectionInvalidatesDedupeSoNextEmitLands` minus its manual re-emit.
    state.onSetupScriptConsumed?()

    let projection = await nextRunningScripts(stream)
    #expect(projection?.isEmpty == true)
  }

  @Test func shedNotificationIndicatorInvalidatesItsCountGate() async {
    // The indicator has its own check-before-emit cache; a shed event must
    // reset it or the dock count strands until the count actually changes.
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), eventBufferCap: 2)
    let worktree = makeWorktree()
    // Subscribe before any state exists so the buffer holds only the
    // subscribe-time indicator event.
    let stream = manager.eventStream()
    let state = manager.state(for: worktree)

    // Two fillers overflow the two-slot buffer and shed the indicator event.
    state.onSetupScriptConsumed?()
    state.onSetupScriptConsumed?()
    // Identical recount: only the shed-time gate reset lets it re-emit
    // (without it, this await hangs).
    state.onNotificationIndicatorChanged?()

    var count: Int?
    for await event in stream {
      if case .notificationIndicatorChanged(let emitted) = event {
        count = emitted
        break
      }
    }
    #expect(count == 0)
  }

  @Test func runBlockingScriptReportsFailureWhenLaunchCannotBeBuilt() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let definition = ScriptDefinition(kind: .run, name: "Dev", command: "   ")

    // Local: an unbuildable launch reports completion instead of a silent nil,
    // with no tab (there is no surface, so a View Terminal button would be dead).
    let local = manager.state(for: makeWorktree())
    var localCompletions: [(Int?, TerminalTabID?)] = []
    local.onBlockingScriptCompleted = { _, exitCode, tabId in localCompletions.append((exitCode, tabId)) }
    #expect(local.runBlockingScript(kind: .script(definition), "   ") == nil)
    #expect(localCompletions.map(\.0) == [1])
    #expect(localCompletions.map(\.1) == [TerminalTabID?.none])
    #expect(local.currentProjection().runningScripts.isEmpty)

    // Remote: an unbuildable ssh command reports the same completion.
    let remote = manager.state(for: makeRemoteWorktree())
    var remoteCompletions: [(Int?, TerminalTabID?)] = []
    remote.onBlockingScriptCompleted = { _, exitCode, tabId in remoteCompletions.append((exitCode, tabId)) }
    #expect(remote.runBlockingScript(kind: .script(definition), "   ") == nil)
    #expect(remoteCompletions.map(\.0) == [1])
    #expect(remoteCompletions.map(\.1) == [TerminalTabID?.none])
    #expect(remote.currentProjection().runningScripts.isEmpty)
  }

  private func nextRunningScripts(
    _ stream: AsyncStream<TerminalClient.Event>
  ) async -> IdentifiedArrayOf<SidebarItemFeature.State.RunningScript>? {
    for await event in stream {
      if case .worktreeProjectionChanged(_, let projection) = event {
        return projection.runningScripts
      }
    }
    return nil
  }

  @Test func stopScriptWithoutTerminalStateDoesNotMintOne() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    manager.handleCommand(.stopScript(worktree, definitionID: UUID()))
    manager.handleCommand(.stopRunScript(worktree))

    #expect(manager.stateIfExists(for: worktree.id) == nil)
  }

  @Test func oscHookNotificationLandsInWorktreeState() {
    withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_234)
      $0.continuousClock = ImmediateClock()
    } operation: {
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
      let worktree = makeWorktree(id: "/tmp/repo/wt with spaces")

      manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

      guard let state = manager.stateIfExists(for: worktree.id),
        let tabId = state.tabManager.selectedTabId,
        let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
      else {
        Issue.record("Expected blocking script tab")
        return
      }

      // The OSC notify path decodes + sanitizes app-side, then appends to the
      // surface's worktree state via this same entry point.
      state.appendHookNotification(title: "Done", body: "All complete", surfaceID: surface.id)

      #expect(
        state.notifications.contains {
          $0.title == "Done" && $0.body == "All complete"
        }
      )
    }
  }

  @Test func notificationIndicatorUsesCurrentCountOnStreamStart() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.setNotificationsForTesting([
      WorktreeTerminalNotification(
        surfaceID: UUID(),
        title: "Unread",
        body: "body",
        createdAt: .distantPast,
        isRead: false
      )
    ])
    state.onNotificationIndicatorChanged?()
    state.setNotificationsForTesting([
      WorktreeTerminalNotification(
        surfaceID: UUID(),
        title: "Read",
        body: "body",
        createdAt: .distantPast,
        isRead: true
      )
    ])

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    var first = await iterator.next()
    while case .worktreeProjectionChanged = first { first = await iterator.next() }
    state.onSetupScriptConsumed?()
    var second = await iterator.next()
    while case .worktreeProjectionChanged = second { second = await iterator.next() }

    #expect(first == .notificationIndicatorChanged(count: 0))
    #expect(second == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func presenceHasActivityReflectsAnyBusySurface() {
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness()
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    guard
      let tab1 = state.createTab(),
      let tab2 = state.createTab(focusing: false),
      let surface1 = state.splitTree(for: tab1).root?.leftmostLeaf(),
      let surface2 = state.splitTree(for: tab2).root?.leftmostLeaf()
    else {
      Issue.record("Expected tabs and surfaces")
      return
    }
    let surfaces = [surface1.id, surface2.id]

    func emit(_ event: AgentHookEvent.EventName, surfaceID: UUID, pid: pid_t? = nil) {
      presence.send(.hookEventReceived(makeHookEvent(event, surfaceID: surfaceID, pid: pid)))
    }

    #expect(!presence.state.hasActivity(in: surfaces))

    emit(.sessionStart, surfaceID: surface2.id, pid: getpid())
    emit(.busy, surfaceID: surface2.id)
    #expect(presence.state.hasActivity(in: surfaces))

    emit(.sessionStart, surfaceID: surface1.id, pid: getpid())
    emit(.busy, surfaceID: surface1.id)
    #expect(presence.state.hasActivity(in: surfaces))

    emit(.idle, surfaceID: surface2.id)
    #expect(presence.state.hasActivity(in: surfaces))

    emit(.idle, surfaceID: surface1.id)
    #expect(!presence.state.hasActivity(in: surfaces))
  }

  @Test func hasUnseenNotificationsReflectsUnreadEntries() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceID = UUID()
    _ = installSurfaceState(on: state, forSurfaceID: surfaceID)

    state.setNotificationsForTesting([
      makeNotification(surfaceID: surfaceID, isRead: true),
      makeNotification(surfaceID: surfaceID, isRead: true),
    ])

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)

    state.setNotificationsForTesting(state.notifications + [makeNotification(surfaceID: surfaceID, isRead: false)])

    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)
  }

  @Test func markAllNotificationsReadEmitsUpdatedIndicatorCount() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceID = UUID()
    _ = installSurfaceState(on: state, forSurfaceID: surfaceID)

    state.setNotificationsForTesting([
      makeNotification(surfaceID: surfaceID, isRead: false),
      makeNotification(surfaceID: surfaceID, isRead: true),
    ])

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    var first = await iterator.next()
    while case .worktreeProjectionChanged = first { first = await iterator.next() }
    state.markAllNotificationsRead()
    var second = await iterator.next()
    while case .worktreeProjectionChanged = second { second = await iterator.next() }

    #expect(first == .notificationIndicatorChanged(count: 1))
    #expect(second == .notificationIndicatorChanged(count: 0))
    #expect(state.notifications.map(\.isRead) == [true, true])
  }

  @Test func notificationIndicatorCountSumsEveryUnreadNotification() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceA = UUID()
    let surfaceB = UUID()
    _ = installSurfaceState(on: state, forSurfaceID: surfaceA)
    _ = installSurfaceState(on: state, forSurfaceID: surfaceB)

    // Three unread across two surfaces: the indicator is the notification total,
    // not the count of worktrees (or surfaces) carrying unread.
    state.setNotificationsForTesting([
      makeNotification(surfaceID: surfaceA, isRead: false),
      makeNotification(surfaceID: surfaceB, isRead: false),
      makeNotification(surfaceID: surfaceB, isRead: false),
    ])

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()
    var event = await iterator.next()
    while case .worktreeProjectionChanged = event { event = await iterator.next() }

    #expect(event == .notificationIndicatorChanged(count: 3))
  }

  @Test func totalUnseenCountDecrementsOnEachReadAndDismiss() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceID = UUID()
    _ = installSurfaceState(on: state, forSurfaceID: surfaceID)
    let first = makeNotification(surfaceID: surfaceID, isRead: false)
    let second = makeNotification(surfaceID: surfaceID, isRead: false)
    let third = makeNotification(surfaceID: surfaceID, isRead: false)
    state.setNotificationsForTesting([first, second, third])
    #expect(state.totalUnseenNotificationCount == 3)

    // Each single read/dismiss lowers the total the indicator and dock badge sum,
    // and dismissing the last outstanding unread clears it.
    state.markNotificationRead(id: first.id)
    #expect(state.totalUnseenNotificationCount == 2)
    state.dismissNotification(second.id)
    #expect(state.totalUnseenNotificationCount == 1)
    state.dismissNotification(third.id)
    #expect(state.totalUnseenNotificationCount == 0)
  }

  @Test func dismissingReadNotificationLeavesSiblingUnreadCount() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceID = UUID()
    _ = installSurfaceState(on: state, forSurfaceID: surfaceID)
    let unread = makeNotification(surfaceID: surfaceID, isRead: false)
    let read = makeNotification(surfaceID: surfaceID, isRead: true)
    state.setNotificationsForTesting([unread, read])
    #expect(state.surfaceStates[surfaceID]?.unseenNotificationCount == 1)

    state.dismissNotification(read.id)

    // Dismissing a read entry must not decrement the still-outstanding unread.
    #expect(state.surfaceStates[surfaceID]?.unseenNotificationCount == 1)
    #expect(state.notifications.map(\.id) == [unread.id])
  }

  @Test func markNotificationsReadOnlyAffectsMatchingSurface() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceA = UUID()
    let surfaceB = UUID()
    _ = installSurfaceState(on: state, forSurfaceID: surfaceA)
    _ = installSurfaceState(on: state, forSurfaceID: surfaceB)

    state.setNotificationsForTesting([
      makeNotification(surfaceID: surfaceA, isRead: false),
      makeNotification(surfaceID: surfaceB, isRead: false),
      makeNotification(surfaceID: surfaceB, isRead: true),
    ])

    state.markNotificationsRead(forSurfaceID: surfaceB)

    let aNotifications = state.notifications.filter { $0.surfaceID == surfaceA }
    let bNotifications = state.notifications.filter { $0.surfaceID == surfaceB }

    #expect(aNotifications.map(\.isRead) == [false])
    #expect(bNotifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)

    state.markNotificationsRead(forSurfaceID: surfaceA)

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func setNotificationsDisabledMarksAllRead() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.setNotificationsForTesting([
      makeNotification(isRead: false),
      makeNotification(isRead: false),
    ])

    state.setNotificationsEnabled(false)

    #expect(state.notifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func dismissAllNotificationsClearsState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.setNotificationsForTesting([
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ])

    state.dismissAllNotifications()

    #expect(state.notifications.isEmpty)
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func dismissAllNotificationsRefreshesRowWhenAllAlreadyRead() {
    // Repro of the stuck-toolbar-bell bug: dismissing already-read notifications
    // flips no unseen flag, so the gated indicator emit used to skip the row
    // projection refresh and the bell stayed showing them. Dismiss must signal
    // unconditionally so the sidebar row's `notifications` array (which the bell
    // group-existence check reads) clears.
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())
    state.setNotificationsForTesting([makeNotification(isRead: true), makeNotification(isRead: true)])
    var indicatorEmits = 0
    state.onNotificationIndicatorChanged = { indicatorEmits += 1 }

    state.dismissAllNotifications()

    #expect(state.notifications.isEmpty)
    #expect(indicatorEmits == 1)
  }

  @Test func dismissReadNotificationRefreshesRow() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let state = manager.state(for: makeWorktree())
    let read = makeNotification(isRead: true)
    state.setNotificationsForTesting([read])
    var indicatorEmits = 0
    state.onNotificationIndicatorChanged = { indicatorEmits += 1 }

    state.dismissNotification(read.id)

    #expect(state.notifications.isEmpty)
    #expect(indicatorEmits == 1)
  }

  // MARK: - Per-surface unseen flag

  @Test func setNotificationsForTestingHydratesPerSurfaceFlag() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceA = UUID()
    let surfaceB = UUID()
    let stateA = installSurfaceState(on: state, forSurfaceID: surfaceA)
    let stateB = installSurfaceState(on: state, forSurfaceID: surfaceB)

    state.setNotificationsForTesting([
      makeNotification(surfaceID: surfaceA, isRead: false),
      makeNotification(surfaceID: surfaceB, isRead: true),
    ])

    #expect(stateA.hasUnseenNotification == true)
    #expect(stateB.hasUnseenNotification == false)
  }

  @Test func markNotificationsReadFlipsOnlyMatchingSurfaceFlag() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceA = UUID()
    let surfaceB = UUID()
    let stateA = installSurfaceState(on: state, forSurfaceID: surfaceA)
    let stateB = installSurfaceState(on: state, forSurfaceID: surfaceB)
    state.setNotificationsForTesting([
      makeNotification(surfaceID: surfaceA, isRead: false),
      makeNotification(surfaceID: surfaceB, isRead: false),
    ])

    state.markNotificationsRead(forSurfaceID: surfaceB)

    #expect(stateA.hasUnseenNotification == true)
    #expect(stateB.hasUnseenNotification == false)
  }

  @Test func markSingleNotificationReadKeepsFlagWhenOlderUnreadRemains() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceID = UUID()
    let surfaceState = installSurfaceState(on: state, forSurfaceID: surfaceID)
    let first = makeNotification(surfaceID: surfaceID, isRead: false)
    let second = makeNotification(surfaceID: surfaceID, isRead: false)
    state.setNotificationsForTesting([first, second])

    state.markNotificationRead(id: first.id)

    #expect(surfaceState.hasUnseenNotification == true)

    state.markNotificationRead(id: second.id)

    #expect(surfaceState.hasUnseenNotification == false)
  }

  @Test func dismissAllNotificationsClearsPerSurfaceFlag() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceID = UUID()
    let surfaceState = installSurfaceState(on: state, forSurfaceID: surfaceID)
    state.setNotificationsForTesting([
      makeNotification(surfaceID: surfaceID, isRead: false)
    ])
    #expect(surfaceState.hasUnseenNotification == true)

    state.dismissAllNotifications()

    #expect(surfaceState.hasUnseenNotification == false)
  }

  @Test func dismissSingleNotificationRefreshesPerSurfaceFlag() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceID = UUID()
    let surfaceState = installSurfaceState(on: state, forSurfaceID: surfaceID)
    let stale = makeNotification(surfaceID: surfaceID, isRead: false)
    let fresh = makeNotification(surfaceID: surfaceID, isRead: false)
    state.setNotificationsForTesting([stale, fresh])

    state.dismissNotification(stale.id)
    #expect(surfaceState.hasUnseenNotification == true)

    state.dismissNotification(fresh.id)
    #expect(surfaceState.hasUnseenNotification == false)
  }

  @Test func appendNotificationFlipsPerSurfaceFlagOnArrival() {
    withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_234)
      $0.continuousClock = ImmediateClock()
    } operation: {
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
      let worktree = makeWorktree()
      let state = manager.state(for: worktree)
      guard let tabId = state.createTab(focusing: false),
        let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
      else {
        Issue.record("Expected a tab and surface")
        return
      }

      state.appendHookNotification(title: "done", body: "exit 0", surfaceID: surface.id)

      #expect(state.surfaceStates[surface.id]?.hasUnseenNotification == true)
    }
  }

  @Test func appendNotificationDoesNotFlipFlagWhenFocusedAndSelected() {
    withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_234)
      $0.continuousClock = ImmediateClock()
    } operation: {
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
      let worktree = makeWorktree()
      let state = manager.state(for: worktree)
      state.isSelected = { true }
      state.syncFocus(windowIsKey: true, windowIsVisible: true)
      guard let tabId = state.createTab(focusing: true),
        let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
      else {
        Issue.record("Expected a tab and surface")
        return
      }

      state.appendHookNotification(title: "done", body: "exit 0", surfaceID: surface.id)

      #expect(state.surfaceStates[surface.id]?.hasUnseenNotification == false)
    }
  }

  @Test func createSurfaceInstallsSurfaceStateEntry() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    guard let tabId = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }

    #expect(state.surfaceStates[surface.id] != nil)
  }

  @Test func restoreSeedsImagePasteAgentsForLiveAgentRecord() {
    let surface = restoreSurface(
      agents: [TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [getpid()], activity: "busy")]
    )
    #expect(surface?.imagePasteAgents == [.claude])
  }

  @Test func restoreSkipsImagePasteAgentsForStaleAgentRecord() {
    // A pid-less (or dead-pid) record is dropped by the presence restore and never gets a
    // corrective empty fan-out, so seeding it would strand Cmd+V routing into a stale shell.
    let surface = restoreSurface(
      agents: [TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [], activity: "busy")]
    )
    #expect(surface?.imagePasteAgents.isEmpty == true)
  }

  private func restoreSurface(agents: [TerminalLayoutSnapshot.SurfaceAgentRecord]) -> GhosttySurfaceView? {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceID = UUID()
    state.pendingLayoutSnapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "Terminal 1",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(
              id: surfaceID,
              workingDirectory: "/tmp/repo/wt-1",
              agents: agents
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )

    state.ensureInitialTab(focusing: false)

    guard let tabID = state.tabManager.tabs.first?.id,
      let surface = state.splitTree(for: tabID).root?.leftmostLeaf()
    else {
      Issue.record("Expected a restored tab and surface")
      return nil
    }
    #expect(surface.id == surfaceID)
    return surface
  }

  @Test func cleanupSurfaceStateRemovesSurfaceStateEntry() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    guard let tabId = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id
    #expect(state.surfaceStates[surfaceID] != nil)

    state.closeTab(tabId)

    #expect(state.surfaceStates[surfaceID] == nil)
  }

  @Test(.dependencies) func explicitSurfaceCloseConfirmsWhenProcessNeedsConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: true)
    let pending = state.pendingCloseConfirmation
    #expect(pending == .surface(surface.id))
    #expect(WorktreeTerminalState.PendingCloseConfirmation.title == "Close Terminal?")
    #expect(WorktreeTerminalState.PendingCloseConfirmation.actionTitle == "Close Terminal")
    #expect(state.hasTab(tabId))

    state.cancelPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(state.hasTab(tabId))

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: true)
    state.confirmPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tabId))
  }

  @Test(.dependencies) func confirmedSplitSurfaceCloseRemovesOnlyTargetPane() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let initialSurface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    #expect(state.performSplitAction(.newSplit(direction: .right), for: initialSurface.id))
    let leaves = state.splitTree(for: tabId).leaves()
    guard leaves.count == 2 else {
      Issue.record("Expected a split tab")
      return
    }
    let target = leaves[1]

    #expect(state.performBindingAction("close_surface", onSurfaceID: target.id))
    target.bridge.closeSurface(processAlive: true)
    #expect(state.pendingCloseConfirmation == .surface(target.id))

    state.confirmPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(state.hasTab(tabId))
    #expect(state.splitTree(for: tabId).leaves().map(\.id) == [initialSurface.id])
  }

  @Test(.dependencies) func secondSurfaceCloseDoesNotRetargetPendingConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let initialSurface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    #expect(state.performSplitAction(.newSplit(direction: .right), for: initialSurface.id))
    let leaves = state.splitTree(for: tabId).leaves()
    guard leaves.count == 2 else {
      Issue.record("Expected a split tab")
      return
    }
    let secondSurface = leaves[1]

    #expect(state.performBindingAction("close_surface", onSurfaceID: secondSurface.id))
    secondSurface.bridge.closeSurface(processAlive: true)
    #expect(state.pendingCloseConfirmation == .surface(secondSurface.id))

    #expect(state.performBindingAction("close_surface", onSurfaceID: initialSurface.id))
    initialSurface.bridge.closeSurface(processAlive: true)
    #expect(state.pendingCloseConfirmation == .surface(secondSurface.id))

    state.confirmPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(state.hasTab(tabId))
    #expect(state.splitTree(for: tabId).leaves().map(\.id) == [initialSurface.id])

    #expect(state.performBindingAction("close_surface", onSurfaceID: initialSurface.id))
    initialSurface.bridge.closeSurface(processAlive: true)
    #expect(state.pendingCloseConfirmation == .surface(initialSurface.id))
    state.cancelPendingClose()
  }

  @Test(.dependencies) func explicitIdleSurfaceCloseSkipsConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: false)
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tabId))
  }

  @Test(.dependencies) func disabledSettingClosesRunningSurfaceWithoutConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = false }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: true)
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tabId))
  }
  @Test(.dependencies) func requestCloseTabConfirmsWhenAnySplitSurfaceHasRunningProcess() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    var runningSurfaceIDs: Set<UUID> = []
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { runningSurfaceIDs.contains($0.id) }
    )
    guard let tabId = state.createTab(focusing: true),
      let initialSurface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    #expect(state.performSplitAction(.newSplit(direction: .right), for: initialSurface.id))
    let leaves = state.splitTree(for: tabId).leaves()
    guard leaves.count == 2 else {
      Issue.record("Expected a split tab")
      return
    }
    runningSurfaceIDs.insert(leaves[1].id)

    #expect(state.requestCloseTab(tabId))
    #expect(state.pendingCloseConfirmation == .tabs([tabId]))
    #expect(state.tabManager.tabs.contains(where: { $0.id == tabId }))

    state.cancelPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(state.tabManager.tabs.contains(where: { $0.id == tabId }))

    #expect(state.requestCloseTab(tabId))
    state.confirmPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
  }

  @Test(.dependencies) func requestCloseTabClosesIdleTabWithoutConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { _ in false }
    )
    guard let tabId = state.createTab(focusing: true) else {
      Issue.record("Expected a tab")
      return
    }

    #expect(state.requestCloseTab(tabId))
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
  }

  @Test(.dependencies) func requestCloseTabSkipsConfirmationOnceBlockingScriptCompletes() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    // Ghostty keeps reporting the frozen surface as needing confirmation.
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { _ in true }
    )
    guard let tabId = state.createTab(focusing: true) else {
      Issue.record("Expected a tab")
      return
    }

    #expect(state.requestCloseTab(tabId))
    #expect(state.pendingCloseConfirmation == .tabs([tabId]))
    state.cancelPendingClose()

    state.tabManager.markBlockingScriptCompleted(tabId)
    #expect(state.requestCloseTab(tabId))
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tabId))
  }

  @Test(.dependencies) func surfaceCloseSkipsConfirmationOnceBlockingScriptCompletes() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    state.tabManager.markBlockingScriptCompleted(tabId)

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: true)

    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tabId))
  }

  @Test(.dependencies) func disabledSettingClosesRunningTabWithoutConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = false }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { _ in true }
    )
    guard let tabId = state.createTab(focusing: true) else {
      Issue.record("Expected a tab")
      return
    }

    #expect(state.requestCloseTab(tabId))
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
  }

  @Test(.dependencies) func programmaticSurfaceDestroyBypassesConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }

    #expect(state.closeSurface(id: surface.id))
    surface.bridge.closeSurface(processAlive: true)
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tabId))
  }

  @Test(.dependencies) func confirmingCapturedTargetClosesEvenAfterDismissalClearedState() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: true)
    guard let pending = state.pendingCloseConfirmation else {
      Issue.record("Expected a pending confirmation")
      return
    }

    // Simulate SwiftUI writing the dismissal back through the alert binding
    // before the confirm button's action runs on the same tap.
    state.dismissPendingCloseConfirmation()
    #expect(state.pendingCloseConfirmation == nil)
    state.confirmPendingClose(pending)
    #expect(!state.hasTab(tabId))
  }

  @Test(.dependencies) func requestCloseOtherTabsConfirmsThenClosesExactlyOthers() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    var runningSurfaceIDs: Set<UUID> = []
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { runningSurfaceIDs.contains($0.id) }
    )
    guard let first = state.createTab(focusing: true),
      let second = state.createTab(focusing: true),
      let third = state.createTab(focusing: true),
      let secondSurface = state.splitTree(for: second).root?.leftmostLeaf()
    else {
      Issue.record("Expected three tabs")
      return
    }
    runningSurfaceIDs.insert(secondSurface.id)

    #expect(state.requestCloseOtherTabs(keeping: first))
    #expect(state.pendingCloseConfirmation == .tabs([second, third]))

    state.confirmPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(state.tabManager.tabs.map(\.id) == [first])
  }

  @Test(.dependencies) func requestCloseTabsToRightTargetsOnlyRightwardTabs() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    var runningSurfaceIDs: Set<UUID> = []
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { runningSurfaceIDs.contains($0.id) }
    )
    guard let first = state.createTab(focusing: true),
      let second = state.createTab(focusing: true),
      let third = state.createTab(focusing: true),
      let thirdSurface = state.splitTree(for: third).root?.leftmostLeaf()
    else {
      Issue.record("Expected three tabs")
      return
    }
    runningSurfaceIDs.insert(thirdSurface.id)

    #expect(state.requestCloseTabsToRight(of: first))
    #expect(state.pendingCloseConfirmation == .tabs([second, third]))

    state.confirmPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(state.tabManager.tabs.map(\.id) == [first])
  }

  @Test(.dependencies) func requestCloseAllTabsConfirmsThenClosesEveryTab() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    var runningSurfaceIDs: Set<UUID> = []
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { runningSurfaceIDs.contains($0.id) }
    )
    guard let first = state.createTab(focusing: true),
      let second = state.createTab(focusing: true),
      let third = state.createTab(focusing: true),
      let secondSurface = state.splitTree(for: second).root?.leftmostLeaf()
    else {
      Issue.record("Expected three tabs")
      return
    }
    runningSurfaceIDs.insert(secondSurface.id)

    #expect(state.requestCloseAllTabs())
    #expect(state.pendingCloseConfirmation == .tabs([first, second, third]))

    state.confirmPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(state.tabManager.tabs.isEmpty)
  }

  @Test(.dependencies) func ghosttyCloseTabModesRouteThroughConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    var runningSurfaceIDs: Set<UUID> = []
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { runningSurfaceIDs.contains($0.id) }
    )
    guard let first = state.createTab(focusing: true),
      let second = state.createTab(focusing: true),
      let third = state.createTab(focusing: true),
      let firstSurface = state.splitTree(for: first).root?.leftmostLeaf(),
      let secondSurface = state.splitTree(for: second).root?.leftmostLeaf()
    else {
      Issue.record("Expected three tabs")
      return
    }
    runningSurfaceIDs.insert(secondSurface.id)

    // "Close Other Tabs" from the first tab confirms because a sibling is busy.
    #expect(firstSurface.bridge.onCloseTab?(GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER) == true)
    #expect(state.pendingCloseConfirmation == .tabs([second, third]))
    state.cancelPendingClose()

    // "Close Tabs to the Right" of the first tab targets the same siblings.
    #expect(firstSurface.bridge.onCloseTab?(GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT) == true)
    #expect(state.pendingCloseConfirmation == .tabs([second, third]))
    state.cancelPendingClose()

    // "Close Tab" scopes to the invoking (idle) tab and closes immediately.
    #expect(firstSurface.bridge.onCloseTab?(GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS) == true)
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(first))
  }

  @Test(.dependencies) func closingTabIndependentlyNarrowsPendingTabPayload() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    var runningSurfaceIDs: Set<UUID> = []
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceNeedsCloseConfirmation: { runningSurfaceIDs.contains($0.id) }
    )
    guard let first = state.createTab(focusing: true),
      let second = state.createTab(focusing: true),
      let third = state.createTab(focusing: true),
      let secondSurface = state.splitTree(for: second).root?.leftmostLeaf()
    else {
      Issue.record("Expected three tabs")
      return
    }
    runningSurfaceIDs.insert(secondSurface.id)

    #expect(state.requestCloseAllTabs())
    #expect(state.pendingCloseConfirmation == .tabs([first, second, third]))

    state.closeTab(first)
    #expect(state.pendingCloseConfirmation == .tabs([second, third]))
    #expect(!state.hasTab(first))

    state.closeTab(second)
    state.closeTab(third)
    #expect(state.pendingCloseConfirmation == nil)
  }

  @Test(.dependencies) func tearingDownPendingSurfaceTabClearsConfirmation() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      surfaceBindingActionPerformer: { _, _ in }
    )
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: true)
    #expect(state.pendingCloseConfirmation == .surface(surface.id))

    state.closeTab(tabId)
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tabId))
  }

  @Test func closeAllSurfacesClearsPerSurfaceBookkeeping() {
    withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_234)
      $0.continuousClock = ImmediateClock()
    } operation: {
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
      let worktree = makeWorktree()
      let state = manager.state(for: worktree)
      guard let tabId = state.createTab(focusing: false),
        let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
      else {
        Issue.record("Expected a tab and surface")
        return
      }
      let surfaceID = surface.id
      state.appendHookNotification(title: "done", body: "exit 0", surfaceID: surfaceID)
      #expect(state.surfaceStates[surfaceID] != nil)
      #expect(state.debugCustomNotificationTimestampCount == 1)

      state.closeAllSurfaces()

      #expect(state.allSurfaceIDs.isEmpty)
      #expect(state.surfaceStates[surfaceID] == nil)
      #expect(state.debugCustomNotificationTimestampCount == 0)
    }
  }

  @Test func pruneKeepsStatesAndSessionsOwnedByProtectedRepositoryIDs() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let activeWorktree = Worktree(
      id: WorktreeID("/tmp/active-repo/wt-1"),
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/active-repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/active-repo"),
    )
    let failedRepoWorktree = Worktree(
      id: WorktreeID("/tmp/failed-repo/wt-1"),
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/failed-repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/failed-repo"),
    )
    let removedWorktree = Worktree(
      id: WorktreeID("/tmp/removed-repo/wt-1"),
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/removed-repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/removed-repo"),
    )
    _ = manager.state(for: activeWorktree).createTab()
    let failedState = manager.state(for: failedRepoWorktree)
    let removedState = manager.state(for: removedWorktree)
    guard let failedTabID = failedState.createTab(),
      let failedSurfaceID = failedState.splitTree(for: failedTabID).root?.leftmostLeaf().id,
      let removedTabID = removedState.createTab(),
      let removedSurfaceID = removedState.splitTree(for: removedTabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected protected and removed surfaces")
      return
    }
    let failedRepositoryID = RepositoryID(
      failedRepoWorktree.repositoryRootURL.standardizedFileURL.path(percentEncoded: false)
    )

    manager.prune(
      keeping: [activeWorktree.id],
      protectingRepositoryIDs: [failedRepositoryID]
    )

    #expect(manager.stateIfExists(for: activeWorktree.id) != nil)
    #expect(manager.stateIfExists(for: failedRepoWorktree.id) != nil)
    #expect(manager.stateIfExists(for: removedWorktree.id) == nil)
    #expect(failedState.hasSurface(failedSurfaceID, in: failedTabID))
    let removedSession = session(for: removedSurfaceID)
    await probe.waitForKill { $0.contains(removedSession) }
    let killed = await probe.killedSessions()
    #expect(killed.contains(session(for: removedSurfaceID)))
    #expect(!killed.contains(session(for: failedSurfaceID)))
  }

  private func makeRemoteWorktree(alias: String = "devbox") -> Worktree {
    Worktree(
      id: WorktreeID("\(alias)/home/dev/repo/wt-1"),
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/home/dev/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/home/dev/repo"),
      host: RemoteHost(alias: alias)
    )
  }

  @Test func pruneKillsHostSessionsForRemoteWorktrees() async {
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(probe: probe, worktree: worktree)
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false),
      let surfaceID = state.splitTree(for: tabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surfaceID)

    manager.prune(keeping: [])

    await probe.waitForRemoteKill { $0.contains(where: { $0.sessionID == sessionID }) }
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
    // The local kill runs only after the remote one completes, so wait for it
    // instead of sampling `killedSessions` immediately.
    await probe.waitForKill { $0.contains(sessionID) }
    #expect(await probe.killedSessions().contains(sessionID))
  }

  @Test func closeTabKillsHostSessionForRemoteWorktree() async {
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(probe: probe, worktree: worktree)
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: true),
      let surfaceID = state.splitTree(for: tabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surfaceID)

    state.closeTab(tabID)

    await probe.waitForRemoteKill { $0.contains(where: { $0.sessionID == sessionID }) }
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
  }

  @Test func unexpectedRemoteSurfaceExitSparesHostSession() async {
    // A non-explicit close (clean remote exit or a deliberate host-side
    // detach) must not tear down the host session.
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(probe: probe, worktree: worktree)
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabID).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surface.id)
    // Session already gone locally: close + local kill, remote spared.
    await probe.setListing([])

    surface.bridge.closeSurface(processAlive: false)

    await probe.waitForKill { $0.contains(sessionID) }
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.isEmpty)
  }

  @Test func explicitSurfaceCloseKillsHostSessionForRemoteWorktree() async {
    // Cmd-W path: performBindingAction marks the close explicit, so the
    // host-side session dies alongside the local one.
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(
      probe: probe,
      worktree: worktree,
      surfaceBindingActionPerformer: { _, _ in }
    )
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabID).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surface.id)

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: false)

    await probe.waitForRemoteKill { $0.contains(where: { $0.sessionID == sessionID }) }
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
  }

  @Test(.dependencies) func closedTabStaleRenderDoesNotResurrectSurface() {
    // A SwiftUI pane can re-render its tab during the tab-close transition;
    // the lazy splitTree(for:) create must not mint a replacement surface for
    // the dead tab, or an invisible surface leaks a local+host session pair.
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(
      probe: probe,
      worktree: worktree,
      surfaceBindingActionPerformer: { _, _ in }
    )
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabID).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }

    #expect(state.performBindingAction("close_surface", onSurfaceID: surface.id))
    surface.bridge.closeSurface(processAlive: true)
    state.confirmPendingClose()

    #expect(state.hasTab(tabID) == false)
    #expect(state.splitTree(for: tabID).isEmpty)
    #expect(state.allSurfaceIDs.isEmpty)
  }

  @Test func closeKillsHostSessionBeforeLocalSession() async {
    // The host-side kill's SSH reuses the ControlMaster held open by the local
    // zmx session, so the local kill must not run until the remote kill has
    // finished; killing local first tears that master down and leaks the host session.
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(probe: probe, worktree: worktree)
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: true),
      let surfaceID = state.splitTree(for: tabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surfaceID)

    // Hold the remote kill mid-flight so a racing local kill would be observable.
    await probe.armRemoteKillGate()
    state.closeTab(tabID)
    await probe.waitForRemoteKillPending(atLeast: 1)
    // Give any concurrently-dispatched local kill ample scheduling to land.
    for _ in 0..<50 { await Task.yield() }
    await probe.releaseRemoteKillGate()

    await probe.waitForKill { $0.contains(sessionID) }
    #expect(await probe.localKilledWhileGated() == false)
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
  }

  @Test func remoteKillFiresEvenWhenLocalZmxIsUnbundled() async {
    // Over-budget / unbundled local zmx must not gate host-side teardown.
    // `executableURL` still serves the inert fake binary so the surface never
    // spawns a real ssh; `isBundled: false` is the guard under test.
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let killed = LockIsolated<[String]>([])
    let zmxURL = makeFakeZmxBinary()
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { zmxURL },
        isBundled: { false },
        killSession: { id in killed.withValue { $0.append(id) } },
        killRemoteSession: { host, id in await probe.killRemoteSession(host: host, sessionID: id) },
        listSessionsWithClients: { [] }
      )
    } operation: {
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
      _ = manager.state(for: worktree)
      return manager
    }
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false),
      let surfaceID = state.splitTree(for: tabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surfaceID)

    state.closeTab(tabID)

    await probe.waitForRemoteKill { $0.contains(where: { $0.sessionID == sessionID }) }
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
    #expect(killed.value.isEmpty)
  }

  @Test func terminateAllSessionsKillsHostSessionsForRemoteWorktrees() async {
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(probe: probe, worktree: worktree)
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false),
      let surfaceID = state.splitTree(for: tabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surfaceID)

    await manager.terminateAllSessions()

    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
    // The merged plan must kill the local session too, not just the host side.
    #expect(await probe.killedSessions().contains(sessionID))
  }

  @Test func killPlanMergesLocalAndRemoteKillsPerSession() {
    let devbox = RemoteHost(alias: "devbox")
    let other = RemoteHost(alias: "other")

    let plan = WorktreeTerminalManager.killPlan(
      localSessionIDs: ["local-only", "both", "local-only"],
      remoteSessions: [
        (host: devbox, sessionID: "both"),
        (host: devbox, sessionID: "remote-only"),
        (host: other, sessionID: "remote-only"),
      ]
    )

    #expect(plan.map(\.sessionID) == ["local-only", "both", "remote-only"])
    let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.sessionID, $0) })
    #expect(byID["local-only"]?.killLocal == true)
    #expect(byID["local-only"]?.host == nil)
    #expect(byID["both"]?.killLocal == true)
    #expect(byID["both"]?.host == devbox)
    #expect(byID["remote-only"]?.killLocal == false)
    // First host wins a (never-expected) collision.
    #expect(byID["remote-only"]?.host == devbox)
  }

  @Test func pruneKillsHostSessionBeforeLocalSession() async {
    // Same ControlMaster ordering contract as surface close, on the prune path.
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(probe: probe, worktree: worktree)
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false),
      let surfaceID = state.splitTree(for: tabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surfaceID)

    await probe.armRemoteKillGate()
    manager.prune(keeping: [])
    await probe.waitForRemoteKillPending(atLeast: 1)
    // Give any concurrently-dispatched local kill ample scheduling to land.
    for _ in 0..<50 { await Task.yield() }
    await probe.releaseRemoteKillGate()

    await probe.waitForKill { $0.contains(sessionID) }
    #expect(await probe.localKilledWhileGated() == false)
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
  }

  @Test func quitKillsHostSessionBeforeLocalSession() async {
    // Same ControlMaster ordering contract as surface close, on the quit path.
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(probe: probe, worktree: worktree)
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false),
      let surfaceID = state.splitTree(for: tabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surfaceID)

    await probe.armRemoteKillGate()
    let terminate = Task { await manager.terminateAllSessions() }
    await probe.waitForRemoteKillPending(atLeast: 1)
    // Give any concurrently-dispatched local kill ample scheduling to land.
    for _ in 0..<50 { await Task.yield() }
    await probe.releaseRemoteKillGate()
    await terminate.value

    #expect(await probe.localKilledWhileGated() == false)
    #expect(await probe.killedSessions().contains(sessionID))
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
  }

  @Test func quitBudgetExpiryStillKillsLocalSessionViaFallback() async {
    // An unreachable host outlives the quit budget; the gated local kill is
    // cancelled with it, so the post-budget fallback must still kill the local
    // session or its ssh reconnect loop survives quit.
    let probe = ZmxTestProbe(listing: [])
    let worktree = makeRemoteWorktree()
    let manager = makeZmxBackedManager(probe: probe, worktree: worktree)
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab(focusing: false),
      let surfaceID = state.splitTree(for: tabID).root?.leftmostLeaf().id
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let sessionID = session(for: surfaceID)

    await probe.armRemoteKillGate()
    let terminate = Task { await manager.terminateAllSessions(killBudget: .zero) }
    await probe.waitForRemoteKillPending(atLeast: 1)
    // Give the zero budget ample scheduling to expire and cancel the sweep.
    for _ in 0..<50 { await Task.yield() }
    await probe.releaseRemoteKillGate()
    await terminate.value

    #expect(await probe.killedSessions().contains(sessionID))
    let remoteKills = await probe.remoteKilledSessions()
    #expect(remoteKills.contains(.init(authority: "devbox", sessionID: sessionID)))
  }

  @Test func unexpectedExitedZmxSurfaceWithLiveSessionReattachesAndKeepsTab() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id
    let originalSurfaceState = state.surfaceStates[surfaceID]
    let projections = LockIsolated<[WorktreeTabProjection]>([])
    state.onTabProjectionChanged = { projection in
      projections.withValue { $0.append(projection) }
    }
    await probe.setListing([.init(name: session(for: surfaceID), clients: 0)])

    surface.bridge.closeSurface(processAlive: false)
    await probe.waitForListCalls(atLeast: 1)
    await waitUntil("zmx surface replacement") {
      guard let replacement = state.splitTree(for: tabId).root?.leftmostLeaf() else { return false }
      return replacement.id == surfaceID && replacement !== surface
    }

    #expect(state.tabManager.tabs.contains(where: { $0.id == tabId }))
    guard let replacement = state.splitTree(for: tabId).root?.leftmostLeaf() else {
      Issue.record("Expected a replacement surface")
      return
    }
    #expect(replacement.id == surfaceID)
    #expect(replacement !== surface)
    #expect(replacement.shouldClaimFocus?() == true)
    #expect(surface.shouldClaimFocus?() == false)
    #expect(state.surfaceStates[surfaceID] === originalSurfaceState)
    #expect(projections.value.last?.surfaceGeneration == 1)
    #expect(await probe.killedSessions() == [])
  }

  @Test(.dependencies) func canceledSurfaceCloseClearsExplicitFlagSoUnexpectedExitReattaches() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = true }
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(
      probe: probe,
      surfaceBindingActionPerformer: { _, _ in }
    )
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id
    await probe.setListing([.init(name: session(for: surfaceID), clients: 0)])

    // Park a surface-close confirmation, then cancel it the way the alert does:
    // the item binding nils the published value before the Cancel action runs.
    #expect(state.performBindingAction("close_surface", onSurfaceID: surfaceID))
    surface.bridge.closeSurface(processAlive: true)
    guard let pending = state.pendingCloseConfirmation else {
      Issue.record("Expected a pending confirmation")
      return
    }
    state.dismissPendingCloseConfirmation()
    state.cancelPendingClose(pending)

    // The explicit-close flag must have been cleared, so a later unexpected exit
    // reattaches the live session instead of tearing it down.
    surface.bridge.closeSurface(processAlive: false)
    await probe.waitForListCalls(atLeast: 1)
    await waitUntil("zmx surface replacement") {
      guard let replacement = state.splitTree(for: tabId).root?.leftmostLeaf() else { return false }
      return replacement.id == surfaceID && replacement !== surface
    }
    #expect(state.tabManager.tabs.contains(where: { $0.id == tabId }))
    #expect(await probe.killedSessions() == [])
  }

  @Test func unexpectedDetachedZmxSurfaceWithLiveSessionReattachesAndKeepsTab() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id
    await probe.setListing([.init(name: session(for: surfaceID), clients: 0)])

    surface.bridge.closeSurface(processAlive: true)
    await probe.waitForListCalls(atLeast: 1)
    await waitUntil("detached zmx surface replacement") {
      guard let replacement = state.splitTree(for: tabId).root?.leftmostLeaf() else { return false }
      return replacement.id == surfaceID && replacement !== surface
    }

    #expect(state.tabManager.tabs.contains(where: { $0.id == tabId }))
    guard let replacement = state.splitTree(for: tabId).root?.leftmostLeaf() else {
      Issue.record("Expected a replacement surface")
      return
    }
    #expect(replacement.id == surfaceID)
    #expect(replacement !== surface)
    #expect(await probe.killedSessions() == [])
  }

  @Test func unexpectedDetachedZmxSurfaceInSplitReattachesOnlyThatPane() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: true),
      let initialSurface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    #expect(state.performSplitAction(.newSplit(direction: .right), for: initialSurface.id))
    let originalLeaves = state.splitTree(for: tabId).leaves()
    guard originalLeaves.count == 2 else {
      Issue.record("Expected a split tab")
      return
    }
    let target = originalLeaves[0]
    let sibling = originalLeaves[1]
    let targetID = target.id
    let siblingID = sibling.id
    await probe.setListing([.init(name: session(for: targetID), clients: 0)])

    target.bridge.closeSurface(processAlive: true)
    await probe.waitForListCalls(atLeast: 1)
    await waitUntil("split zmx surface replacement") {
      let leaves = state.splitTree(for: tabId).leaves()
      guard leaves.count == 2 else { return false }
      let replacement = leaves.first { $0.id == targetID }
      return replacement != nil
        && replacement !== target
        && leaves.contains { $0 === sibling }
    }

    #expect(state.tabManager.tabs.contains(where: { $0.id == tabId }))
    let leaves = state.splitTree(for: tabId).leaves()
    #expect(leaves.count == 2)
    #expect(Set(leaves.map(\.id)) == [targetID, siblingID])
    #expect(leaves.contains { $0 === sibling })
    #expect(await probe.killedSessions() == [])
  }

  @Test func ghosttyOriginatedCloseSurfaceInSplitWithAttachedClientClosesPaneSparingSession() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: true),
      let initialSurface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    #expect(state.performSplitAction(.newSplit(direction: .right), for: initialSurface.id))
    let originalLeaves = state.splitTree(for: tabId).leaves()
    guard originalLeaves.count == 2 else {
      Issue.record("Expected a split tab")
      return
    }
    let target = originalLeaves[0]
    let sibling = originalLeaves[1]
    let targetID = target.id
    let siblingID = sibling.id
    await probe.setListing([.init(name: session(for: targetID), clients: 1)])

    target.bridge.closeSurface(processAlive: true)
    await probe.waitForListCalls(atLeast: 1)
    await waitUntil("split pane closes") {
      let leaves = state.splitTree(for: tabId).leaves()
      return leaves.count == 1 && leaves.first.map { $0 === sibling } == true
    }

    #expect(state.tabManager.tabs.contains(where: { $0.id == tabId }))
    let leaves = state.splitTree(for: tabId).leaves()
    #expect(leaves.map(\.id) == [siblingID])
    #expect(leaves.first.map { $0 === sibling } == true)
    // Another client is attached (clients == 1), so the shared session must survive.
    #expect(await probe.killedSessions() == [])
  }

  @Test func staleOldSurfaceCallbacksAreIgnoredAfterZmxReattach() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let state = manager.state(for: makeWorktree())
    let toggled = LockIsolated(false)
    state.onCommandPaletteToggle = {
      toggled.setValue(true)
    }
    guard let tabId = state.createTab(focusing: true),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id
    await probe.setListing([.init(name: session(for: surfaceID), clients: 0)])

    surface.bridge.closeSurface(processAlive: false)
    await probe.waitForListCalls(atLeast: 1)
    await waitUntil("zmx surface replacement") {
      guard let replacement = state.splitTree(for: tabId).root?.leftmostLeaf() else { return false }
      return replacement !== surface
    }

    #expect(surface.bridge.onCommandPaletteToggle?() == false)
    #expect(toggled.value == false)
  }

  @Test func unexpectedExitedZmxSurfaceWithoutLiveSessionClosesAndKillsSession() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id

    let expectedKill = session(for: surfaceID)
    surface.bridge.closeSurface(processAlive: false)
    await probe.waitForListCalls(atLeast: 1)
    await probe.waitForKill { $0.contains(expectedKill) }
    let killed = await probe.killedSessions()
    await waitUntil("zmx surface tab closes") {
      !state.tabManager.tabs.contains(where: { $0.id == tabId })
    }

    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
    #expect(state.surfaceStates[surfaceID] == nil)
    #expect(killed == [session(for: surfaceID)])
  }

  @Test func unexpectedExitedZmxSurfaceWithUnavailableProbeClosesWithoutKillingSession() async {
    let probe = ZmxTestProbe(listing: nil)
    let manager = makeZmxBackedManager(probe: probe)
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id

    surface.bridge.closeSurface(processAlive: false)
    await probe.waitForListCalls(atLeast: 1)
    await waitUntil("zmx surface tab closes") {
      !state.tabManager.tabs.contains(where: { $0.id == tabId })
    }

    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
    #expect(state.surfaceStates[surfaceID] == nil)
    #expect(await probe.killedSessions() == [])
  }

  @Test func unexpectedExitedZmxSurfaceWithUnknownClientCountClosesWithoutKillingSession() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id
    await probe.setListing([.init(name: session(for: surfaceID), clients: nil)])

    surface.bridge.closeSurface(processAlive: false)
    await probe.waitForListCalls(atLeast: 1)
    await waitUntil("zmx surface tab closes") {
      !state.tabManager.tabs.contains(where: { $0.id == tabId })
    }

    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
    #expect(state.surfaceStates[surfaceID] == nil)
    #expect(await probe.killedSessions() == [])
  }

  @Test func explicitExitedZmxSurfaceCloseDoesNotRecoverLiveSession() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(
      probe: probe,
      surfaceBindingActionPerformer: { _, _ in }
    )
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id
    await probe.setListing([.init(name: session(for: surfaceID), clients: 1)])

    let expectedKill = session(for: surfaceID)
    #expect(state.closeSurface(id: surfaceID))
    surface.bridge.closeSurface(processAlive: false)
    await probe.waitForKill { $0.contains(expectedKill) }
    let killed = await probe.killedSessions()
    await waitUntil("explicit zmx surface tab closes") {
      !state.tabManager.tabs.contains(where: { $0.id == tabId })
    }

    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
    #expect(state.surfaceStates[surfaceID] == nil)
    #expect(killed == [session(for: surfaceID)])
    #expect(await probe.listCallCount() == 0)
  }

  @Test func closeSurfaceBindingActionDoesNotRecoverLiveSession() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(
      probe: probe,
      surfaceBindingActionPerformer: { _, _ in }
    )
    let state = manager.state(for: makeWorktree())
    guard let tabId = state.createTab(focusing: false),
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a tab and surface")
      return
    }
    let surfaceID = surface.id
    await probe.setListing([.init(name: session(for: surfaceID), clients: 1)])

    let expectedKill = session(for: surfaceID)
    #expect(state.performBindingAction("close_surface", onSurfaceID: surfaceID))
    surface.bridge.closeSurface(processAlive: false)
    await probe.waitForKill { $0.contains(expectedKill) }
    let killed = await probe.killedSessions()
    await waitUntil("binding-closed zmx surface tab closes") {
      !state.tabManager.tabs.contains(where: { $0.id == tabId })
    }

    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
    #expect(state.surfaceStates[surfaceID] == nil)
    #expect(killed == [session(for: surfaceID)])
    #expect(await probe.listCallCount() == 0)
  }

  @Test func bypassZmxSurfaceExitKeepsCloseOnExitBehavior() async {
    let probe = ZmxTestProbe(listing: [])
    let manager = makeZmxBackedManager(probe: probe)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    guard let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected a blocking-script tab and surface")
      return
    }
    let surfaceID = surface.id
    await probe.setListing([.init(name: session(for: surfaceID), clients: 1)])

    surface.bridge.closeSurface(processAlive: false)
    await waitUntil("bypass-zmx tab closes") {
      !state.tabManager.tabs.contains(where: { $0.id == tabId })
    }

    #expect(!state.tabManager.tabs.contains(where: { $0.id == tabId }))
    #expect(state.surfaceStates[surfaceID] == nil)
    #expect(await probe.listCallCount() == 0)
  }

  @Test func restoreLayoutSnapshotReDerivesPerSurfaceFlags() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let knownSurfaceID = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "Terminal 1",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(
              id: knownSurfaceID,
              workingDirectory: "/tmp/repo/wt-1"
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    manager.loadLayoutSnapshot = { _ in snapshot }
    let state = manager.state(for: worktree)
    // Seed two unread for the not-yet-restored surface; the flag install is
    // silently dropped because `surfaceStates[knownSurfaceID]` is absent.
    state.setNotificationsForTesting([
      makeNotification(surfaceID: knownSurfaceID, isRead: false),
      makeNotification(surfaceID: knownSurfaceID, isRead: false),
    ])
    #expect(state.surfaceStates[knownSurfaceID] == nil)

    state.ensureInitialTab(focusing: false)

    // The rebuild counts each surviving unread once, not just sets the flag.
    #expect(state.surfaceStates[knownSurfaceID]?.unseenNotificationCount == 2)
  }

  @Test func notificationsDisabledSkipsPerSurfaceFlag() {
    withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_234)
      $0.continuousClock = ImmediateClock()
    } operation: {
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
      let worktree = makeWorktree()
      let state = manager.state(for: worktree)
      state.notificationsEnabled = false
      guard let tabId = state.createTab(focusing: false),
        let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
      else {
        Issue.record("Expected a tab and surface")
        return
      }

      state.appendHookNotification(title: "done", body: "exit 0", surfaceID: surface.id)

      #expect(state.surfaceStates[surface.id]?.hasUnseenNotification == false)
    }
  }

  /// Installs a fresh `WorktreeSurfaceState` via the DEBUG-gated test seam.
  @discardableResult
  private func installSurfaceState(
    on state: WorktreeTerminalState,
    forSurfaceID surfaceID: UUID
  ) -> WorktreeSurfaceState {
    let surfaceState = WorktreeSurfaceState()
    state.installSurfaceStateForTesting(surfaceState, forSurfaceID: surfaceID)
    return surfaceState
  }

  @Test func blockingScriptCompletionReportsExitCodeFromCommandFinished() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "exit 1"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    surface.bridge.onCommandFinished?(1)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 1, tabId: tabId))
  }

  @Test func blockingScriptCompletionPassesNilExitCodeWhenCommandFinishedReportsNil() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    surface.bridge.onCommandFinished?(nil)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: tabId))
  }

  @Test func blockingScriptCommandFinishedFollowedByChildExitDoesNotDoubleFire() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    // Normal flow: command finishes, then shell exits later.
    surface.bridge.onCommandFinished?(0)
    surface.bridge.onChildExited?(0)

    // First completion event should arrive.
    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }
    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0, tabId: tabId))

    // The child exit should NOT produce a second completion.
    #expect(!manager.isBlockingScriptRunning(kind: .archive, for: worktree.id))
  }

  @Test func blockingScriptChildExitWithoutCommandFinishedIsCancellation() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    surface.bridge.onChildExited?(1)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: nil))
  }

  @Test func remoteBlockingScriptChildExitReportsFailure() async {
    // A remote surface's child is ssh itself; its death before the exit
    // frame is a failed run, not a cancellation (#573). Injecting a raw 0
    // pins the clamp: it must never reach the lifecycle success paths.
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeRemoteWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    surface.bridge.onChildExited?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 1, tabId: nil))
  }

  @Test func blockingScriptSignalBasedTerminationReportsImmediately() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    // Ctrl+C sends exit code 130 (128 + SIGINT=2) via COMMAND_FINISHED.
    // Completion should fire immediately without waiting for onChildExited.
    surface.bridge.onCommandFinished?(130)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 130, tabId: tabId))
  }

  @Test func blockingScriptRerunClosesOldTabWithoutFiringCompletion() async {
    let (manager, _) = WorktreeTerminalManager.withPresenceHarness()
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let firstTabId = state.tabManager.selectedTabId
    else {
      Issue.record("Expected first blocking script tab")
      return
    }

    // Re-run the same kind — old tab should close silently.
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let secondTabId = state.tabManager.selectedTabId else {
      Issue.record("Expected second blocking script tab")
      return
    }

    #expect(firstTabId != secondTabId)
    #expect(!state.tabManager.tabs.map(\.id).contains(firstTabId))

    // Complete the second script — only this one should fire.
    guard let surface = state.splitTree(for: secondTabId).root?.leftmostLeaf() else {
      Issue.record("Expected surface for second tab")
      return
    }
    surface.bridge.onCommandFinished?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0, tabId: secondTabId))
  }

  @Test func blockingScriptTabClosedManuallyReportsCancellation() async {
    let (manager, _) = WorktreeTerminalManager.withPresenceHarness()
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId
    else {
      Issue.record("Expected blocking script tab")
      return
    }

    // Simulate user closing the tab.
    state.closeTab(tabId)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: nil))
  }

  @Test func closeAllSurfacesCancelsPendingBlockingScripts() async {
    let (manager, _) = WorktreeTerminalManager.withPresenceHarness()
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id) else {
      Issue.record("Expected worktree state")
      return
    }

    state.closeAllSurfaces()

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: nil))
  }

  @Test func blockingScriptSuccessKeepsTabOpen() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    #expect(state.tabManager.tabs.map(\.id).contains(tabId))

    surface.bridge.onCommandFinished?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0, tabId: tabId))
    // Tab stays open so the user can inspect output.
    #expect(state.tabManager.tabs.map(\.id).contains(tabId))
  }

  @Test func runScriptBlockingScriptTracksRunningState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, command: "echo hi")

    #expect(manager.isBlockingScriptRunning(kind: .script(definition), for: worktree.id) == false)

    manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "echo hi"))

    #expect(manager.isBlockingScriptRunning(kind: .script(definition), for: worktree.id) == true)
  }

  @Test func stopRunScriptClosesRunTab() {
    let (manager, _) = WorktreeTerminalManager.withPresenceHarness()
    let worktree = makeWorktree()
    let definition = ScriptDefinition(kind: .run, command: "sleep 10")

    manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "sleep 10"))
    #expect(manager.isBlockingScriptRunning(kind: .script(definition), for: worktree.id) == true)

    manager.handleCommand(.stopRunScript(worktree))
    #expect(manager.isBlockingScriptRunning(kind: .script(definition), for: worktree.id) == false)
  }

  @Test func runScriptTabTitleResetsAfterSignalInterruption() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()
    let definition = ScriptDefinition(kind: .run, command: "sleep 10")

    manager.handleCommand(.runBlockingScript(worktree, kind: .script(definition), script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected run script tab and surface")
      return
    }

    let tab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(tab?.title == "Run")
    #expect(tab?.isTitleLocked == true)
    #expect(tab?.tintColor == .green)
    #expect(tab?.isBlockingScript == true)
    #expect(tab?.isBlockingScriptCompleted == false)

    // Simulate Ctrl+C (SIGINT = exit code 130).
    surface.bridge.onCommandFinished?(130)

    // Wait for completion event.
    _ = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event { return true }
      return false
    }

    let updatedTab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(updatedTab?.title == "Run")
    #expect(updatedTab?.icon == "play")
    #expect(updatedTab?.isTitleLocked == true)
    #expect(updatedTab?.isBlockingScript == true)
    #expect(updatedTab?.isBlockingScriptCompleted == true)
    #expect(updatedTab?.tintColor == nil)
    #expect(state.currentTabProjections().first { $0.tabID == tabId }?.hasTerminalActivity == false)
    // Both the mirror update and the binding dispatch must land; without the
    // recorded-bindings check a regression that drops the toggle but keeps
    // the optimistic mirror would still pass.
    #expect(surface.bridge.state.readOnly == GHOSTTY_READONLY_ON)
    #expect(surface.recordedBindingActions.contains("toggle_readonly"))
  }

  @Test func blockingScriptTabTitleResetsAfterFailure() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "exit 1"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    let tab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(tab?.title == "Archive Script")
    #expect(tab?.tintColor == .orange)

    // Tab appearance reset happens synchronously in completeBlockingScript.
    surface.bridge.onCommandFinished?(1)

    let updatedTab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(updatedTab?.title == "Archive Script")
    #expect(updatedTab?.icon == "archivebox.fill")
    #expect(updatedTab?.isTitleLocked == true)
    #expect(updatedTab?.isBlockingScript == true)
    #expect(updatedTab?.tintColor == nil)
    #expect(state.currentTabProjections().first { $0.tabID == tabId }?.hasTerminalActivity == false)
  }

  @Test func runBlockingScriptClosesLingeringFrozenTabOfSameKind() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    // First archive run, complete it, and confirm the tab is frozen.
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo first"))
    guard let state = manager.stateIfExists(for: worktree.id),
      let firstTabId = state.tabManager.selectedTabId,
      let firstSurface = state.splitTree(for: firstTabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected first blocking-script tab and surface")
      return
    }
    firstSurface.bridge.onCommandFinished?(0)
    #expect(state.isBlockingScriptCompleted(firstTabId))
    #expect(state.tabManager.tabs.count == 1)

    // Re-run archive: the lingering frozen tab must be closed and a fresh tab
    // minted. Without the cleanup the old tab would still be selected and the
    // user would never see the new run.
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo second"))
    let secondTabId = state.tabManager.selectedTabId
    #expect(secondTabId != nil)
    #expect(secondTabId != firstTabId)
    #expect(!state.tabManager.tabs.contains(where: { $0.id == firstTabId }))
    #expect(state.tabManager.tabs.count == 1)
  }

  @Test func residualProgressReportDoesNotResurrectDirtyOnFrozenTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking-script tab and surface")
      return
    }
    surface.bridge.onCommandFinished?(0)
    #expect(state.currentTabProjections().first { $0.tabID == tabId }?.hasTerminalActivity == false)

    // Simulate the stale watch re-firing a fresh in-flight progress
    // report just before its REMOVE. Without the completed guard in
    // `isTabActivityBusy`, the running state would flip activity back to true.
    surface.bridge.state.progressState = GHOSTTY_PROGRESS_STATE_INDETERMINATE
    surface.bridge.onProgressReport?(GHOSTTY_PROGRESS_STATE_INDETERMINATE)

    #expect(state.currentTabProjections().first { $0.tabID == tabId }?.hasTerminalActivity == false)
    #expect(state.isBlockingScriptCompleted(tabId))
  }

  @Test func selectTabWithValidIdChangesSelection() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    // Create two blocking script tabs so we have two tabs to switch between.
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo archive"))
    manager.handleCommand(.runBlockingScript(worktree, kind: .delete, script: "echo delete"))

    guard let state = manager.stateIfExists(for: worktree.id) else {
      Issue.record("Expected worktree state")
      return
    }

    let tabIds = state.tabManager.tabs.map(\.id)
    guard tabIds.count >= 2 else {
      Issue.record("Expected at least two tabs")
      return
    }
    let firstTabId = tabIds[0]
    let secondTabId = tabIds[1]

    // Select the second tab first.
    manager.handleCommand(.selectTab(worktree, tabID: secondTabId))
    #expect(state.tabManager.selectedTabId == secondTabId)

    // Select the first tab.
    manager.handleCommand(.selectTab(worktree, tabID: firstTabId))
    #expect(state.tabManager.selectedTabId == firstTabId)
  }

  @Test func selectTabWithStaleIdIsNoOp() {
    let (manager, _) = WorktreeTerminalManager.withPresenceHarness()
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId
    else {
      Issue.record("Expected blocking script tab")
      return
    }

    // Close the tab, then try to select it by its stale ID.
    state.closeTab(tabId)
    let selectedBefore = state.tabManager.selectedTabId

    manager.handleCommand(.selectTab(worktree, tabID: tabId))

    // Selection should not change.
    #expect(state.tabManager.selectedTabId == selectedBefore)
  }

  // MARK: - CLI query methods.

  @Test func listTabsReturnsTabIDs() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    guard let tab1 = state.createTab(),
      let tab2 = state.createTab(focusing: false)
    else {
      Issue.record("Expected tabs to be created")
      return
    }

    guard let tabs = manager.listTabs(worktreeID: worktree.id.rawValue) else {
      Issue.record("Expected non-nil tabs result")
      return
    }

    #expect(tabs.count == 2)
    let focusedTabs = tabs.filter { $0["focused"] == "1" }
    #expect(focusedTabs.count == 1)
    // createTab() selects the new tab, so tab1 (created last with focus) is selected.
    let selectedTabID = state.tabManager.selectedTabId
    #expect(focusedTabs.first?["id"] == selectedTabID?.rawValue.uuidString)
    let ids = Set(tabs.compactMap { $0["id"] })
    #expect(ids == [tab1.rawValue.uuidString, tab2.rawValue.uuidString])
  }

  @Test func listTabsReturnsNilForUnknownWorktree() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(manager.listTabs(worktreeID: "/nonexistent") == nil)
  }

  @Test func listSurfacesReturnsSortedSurfaceIDs() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    guard let tabID = state.createTab() else {
      Issue.record("Expected tab to be created")
      return
    }

    guard let surfaces = manager.listSurfaces(worktreeID: worktree.id.rawValue, tabID: tabID.rawValue.uuidString) else {
      Issue.record("Expected non-nil surfaces result")
      return
    }

    // Should have at least one surface (the initial one).
    #expect(!surfaces.isEmpty)
    // Results should be sorted by UUID string.
    let ids = surfaces.compactMap { $0["id"] }
    #expect(ids == ids.sorted())
    // One surface should be focused.
    let focusedSurfaces = surfaces.filter { $0["focused"] == "1" }
    #expect(focusedSurfaces.count == 1)
  }

  @Test func listSurfacesReturnsNilForUnknownWorktree() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    #expect(manager.listSurfaces(worktreeID: "/nonexistent", tabID: UUID().uuidString) == nil)
  }

  @Test func listSurfacesReturnsNilForInvalidTabID() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    _ = manager.state(for: worktree)
    #expect(manager.listSurfaces(worktreeID: worktree.id.rawValue, tabID: "not-a-uuid") == nil)
  }

  @Test func latestUnreadNotificationPicksNewestAcrossWorktrees() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktreeA = makeWorktree(id: "/tmp/repo/wt-a")
    let worktreeB = makeWorktree(id: "/tmp/repo/wt-b")
    let stateA = manager.state(for: worktreeA)
    let stateB = manager.state(for: worktreeB)
    guard
      let tabA = stateA.createTab(),
      let surfaceA = stateA.splitTree(for: tabA).root?.leftmostLeaf(),
      let tabB = stateB.createTab(),
      let surfaceB = stateB.splitTree(for: tabB).root?.leftmostLeaf()
    else {
      Issue.record("Expected tabs and surfaces")
      return
    }

    let older = Date(timeIntervalSince1970: 1_000)
    let newer = Date(timeIntervalSince1970: 2_000)
    stateA.setNotificationsForTesting([makeNotification(surfaceID: surfaceA.id, isRead: false, createdAt: older)])
    stateB.setNotificationsForTesting([makeNotification(surfaceID: surfaceB.id, isRead: false, createdAt: newer)])

    let location = manager.latestUnreadNotificationLocation()
    #expect(location?.worktreeID == worktreeB.id)
    #expect(location?.tabID == tabB)
    #expect(location?.surfaceID == surfaceB.id)
  }

  @Test func latestUnreadNotificationSkipsNotificationsWithClosedSurfaces() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    guard
      let tab = state.createTab(),
      let surface = state.splitTree(for: tab).root?.leftmostLeaf()
    else {
      Issue.record("Expected tab and surface")
      return
    }

    let alive = makeNotification(surfaceID: surface.id, isRead: false, createdAt: Date(timeIntervalSince1970: 1_000))
    let orphan = makeNotification(surfaceID: UUID(), isRead: false, createdAt: Date(timeIntervalSince1970: 2_000))
    // The orphan is newer but its surface no longer exists in any tab, so
    // it must be skipped and the alive notification wins.
    state.setNotificationsForTesting([orphan, alive])

    let location = manager.latestUnreadNotificationLocation()
    #expect(location?.surfaceID == surface.id)
    #expect(location?.tabID == tab)
  }

  @Test func latestUnreadNotificationComparesFocusableAcrossWorktreesAfterFallback() {
    // Worktree A: newest unread is orphaned, but an older unread targets
    // a live surface at t=1.
    // Worktree B: only has a focusable unread at t=2, which is newer than
    // A's focusable fallback but older than A's orphaned newest.
    // Expected winner: B.
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktreeA = makeWorktree(id: "/tmp/repo/wt-a")
    let worktreeB = makeWorktree(id: "/tmp/repo/wt-b")
    let stateA = manager.state(for: worktreeA)
    let stateB = manager.state(for: worktreeB)
    guard
      let tabA = stateA.createTab(),
      let surfaceA = stateA.splitTree(for: tabA).root?.leftmostLeaf(),
      let tabB = stateB.createTab(),
      let surfaceB = stateB.splitTree(for: tabB).root?.leftmostLeaf()
    else {
      Issue.record("Expected tabs and surfaces")
      return
    }

    let orphanSurface = UUID()
    stateA.setNotificationsForTesting([
      makeNotification(surfaceID: orphanSurface, isRead: false, createdAt: Date(timeIntervalSince1970: 3)),
      makeNotification(surfaceID: surfaceA.id, isRead: false, createdAt: Date(timeIntervalSince1970: 1)),
    ])
    stateB.setNotificationsForTesting([
      makeNotification(surfaceID: surfaceB.id, isRead: false, createdAt: Date(timeIntervalSince1970: 2))
    ])

    let location = manager.latestUnreadNotificationLocation()
    #expect(location?.worktreeID == worktreeB.id)
    #expect(location?.surfaceID == surfaceB.id)
    #expect(location?.tabID == tabB)
  }

  @Test func latestUnreadNotificationReturnsNilWhenAllUnreadTargetClosedSurfaces() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    state.setNotificationsForTesting([
      makeNotification(surfaceID: UUID(), isRead: false, createdAt: .distantPast)
    ])
    #expect(manager.latestUnreadNotificationLocation() == nil)
  }

  @Test func hasUnseenNotificationForTabIDWalksSplitTree() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    guard
      let tab = state.createTab(),
      let surface = state.splitTree(for: tab).root?.leftmostLeaf()
    else {
      Issue.record("Expected tab and surface")
      return
    }
    // Split so the tab owns two surfaces.
    _ = state.performSplitAction(.newSplit(direction: .right), for: surface.id)
    let leaves = state.splitTree(for: tab).leaves()
    #expect(leaves.count == 2)

    // No notifications yet.
    #expect(state.hasUnseenNotification(forTabID: tab) == false)

    // Notification on the first leaf lights up the tab.
    state.setNotificationsForTesting([makeNotification(surfaceID: leaves[0].id, isRead: false, createdAt: .distantPast)]
    )
    #expect(state.hasUnseenNotification(forTabID: tab) == true)
    state.markAllNotificationsRead()

    // Notification on the second leaf also lights up the tab.
    state.setNotificationsForTesting([makeNotification(surfaceID: leaves[1].id, isRead: false, createdAt: .distantPast)]
    )
    #expect(state.hasUnseenNotification(forTabID: tab) == true)

    // Once read, the tab is clean again.
    state.markAllNotificationsRead()
    #expect(state.hasUnseenNotification(forTabID: tab) == false)

    // A notification tied to a surface outside this tab does NOT light it up.
    state.setNotificationsForTesting([makeNotification(surfaceID: UUID(), isRead: false, createdAt: .distantPast)])
    #expect(state.hasUnseenNotification(forTabID: tab) == false)
  }

  @Test func markNotificationReadOnlyTouchesMatchingId() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let first = makeNotification(surfaceID: UUID(), isRead: false, createdAt: .distantPast)
    let second = makeNotification(surfaceID: UUID(), isRead: false, createdAt: .distantPast)
    state.setNotificationsForTesting([first, second])

    manager.markNotificationRead(worktreeID: worktree.id, notificationID: first.id)

    #expect(state.notifications.first(where: { $0.id == first.id })?.isRead == true)
    #expect(state.notifications.first(where: { $0.id == second.id })?.isRead == false)
  }

  private func makeHookEvent(
    _ name: AgentHookEvent.EventName,
    agent: SkillAgent = .claude,
    surfaceID: UUID,
    pid: pid_t? = nil
  ) -> AgentHookEvent {
    let pidLine = pid.map { ",\n        \"pid\": \($0)" } ?? ""
    let json = """
      {
        "event": "\(name.rawValue)",
        "agent": "\(agent.rawValue)",
        "surface_id": "\(surfaceID.uuidString)"\(pidLine)
      }
      """
    guard let event = try? JSONDecoder().decode(AgentHookEvent.self, from: Data(json.utf8)) else {
      preconditionFailure("Failed to parse test event")
    }
    return event
  }

  @Test func coalescesConsecutiveIdenticalTaskStatusEvents() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let stream = manager.eventStream()

    state.onTaskStatusChanged?(.running)
    state.onTaskStatusChanged?(.running)
    state.onTaskStatusChanged?(.idle)
    state.onTaskStatusChanged?(.idle)
    state.onTaskStatusChanged?(.running)

    // Resubscribing finishes `stream` so the drain below terminates.
    _ = manager.eventStream()

    var statuses: [WorktreeTaskStatus] = []
    for await event in stream {
      guard case .taskStatusChanged(_, let status) = event else { continue }
      statuses.append(status)
    }

    #expect(statuses == [.running, .idle, .running])
  }

  @Test func coalescesConsecutiveIdenticalFocusEvents() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let stream = manager.eventStream()
    let first = UUID()
    let second = UUID()

    state.onFocusChanged?(first)
    state.onFocusChanged?(first)
    state.onFocusChanged?(second)
    state.onFocusChanged?(first)

    _ = manager.eventStream()

    var focused: [UUID] = []
    for await event in stream {
      guard case .focusChanged(_, let surfaceID) = event else { continue }
      focused.append(surfaceID)
    }

    #expect(focused == [first, second, first])
  }

  @Test func capsTheLiveEventBufferUnderBackpressure() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let stream = manager.eventStream()

    // Lifecycle events are never coalesced, so each one occupies a buffer slot.
    // Emitting past the cap with nothing draining must shed the oldest, not grow.
    let overflow = manager.eventBufferCap + 50
    for _ in 0..<overflow {
      state.onSetupScriptConsumed?()
    }

    _ = manager.eventStream()

    var count = 0
    for await event in stream {
      if case .setupScriptConsumed = event { count += 1 }
    }

    #expect(count == manager.eventBufferCap)
  }

  @Test func purgesCoalesceKeyOnTabTeardownSoIdenticalEventRedelivers() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let stream = manager.eventStream()
    let tabID = TerminalTabID()
    let projection = WorktreeTabProjection(
      tabID: tabID,
      surfaceIDs: [UUID()],
      activeSurfaceID: nil,
      unseenNotificationCount: 0
    )

    state.onTabProjectionChanged?(projection)
    state.onTabRemoved?(tabID)
    // The teardown purged the stale key, so an identical projection for the same
    // tab id (e.g. a snapshot restore reusing the UUID) must be delivered again.
    state.onTabProjectionChanged?(projection)

    _ = manager.eventStream()

    var delivered = 0
    for await event in stream {
      if case .tabProjectionChanged(_, let value) = event, value.tabID == tabID {
        delivered += 1
      }
    }

    #expect(delivered == 2)
  }

  @Test func neverCoalescesConsecutiveLifecycleEvents() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let stream = manager.eventStream()

    state.onTabCreated?()
    state.onTabCreated?()

    _ = manager.eventStream()

    var created = 0
    for await event in stream {
      if case .tabCreated = event { created += 1 }
    }

    #expect(created == 2)
  }

  @Test func coalescesPendingEventsBeforeSubscription() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    // No subscriber attached yet, so these buffer into pendingEvents; identical
    // keys must collapse to the latest value before the first subscriber drains.
    state.onTaskStatusChanged?(.running)
    state.onTaskStatusChanged?(.idle)
    state.onTaskStatusChanged?(.running)

    let stream = manager.eventStream()
    _ = manager.eventStream()

    var statuses: [WorktreeTaskStatus] = []
    for await event in stream {
      guard case .taskStatusChanged(_, let status) = event else { continue }
      statuses.append(status)
    }

    #expect(statuses == [.running])
  }

  @Test func capsPendingLifecycleEventsBeforeSubscription() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    // No subscriber attached: lifecycle events fill pendingEvents and must cap.
    let overflow = WorktreeTerminalManager.pendingEventCap + 50
    for _ in 0..<overflow {
      state.onSetupScriptConsumed?()
    }

    let stream = manager.eventStream()
    _ = manager.eventStream()

    var count = 0
    for await event in stream {
      if case .setupScriptConsumed = event { count += 1 }
    }

    #expect(count == WorktreeTerminalManager.pendingEventCap)
  }

  @Test func seedsCoalesceCacheFromPendingReplaySoLiveDuplicateDedups() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    // Buffered before any subscriber attaches, then replayed on subscribe.
    state.onTaskStatusChanged?(.running)
    let stream = manager.eventStream()
    // The replay seeded the cache, so this identical live value must dedup.
    state.onTaskStatusChanged?(.running)

    _ = manager.eventStream()

    var statuses: [WorktreeTaskStatus] = []
    for await event in stream {
      guard case .taskStatusChanged(_, let status) = event else { continue }
      statuses.append(status)
    }

    #expect(statuses == [.running])
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1") -> Worktree {
    let name = URL(fileURLWithPath: id).lastPathComponent
    return Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  /// Writes an inert fake zmx (`exec /bin/cat`) so wrapped surface commands
  /// never spawn anything real.
  private func makeFakeZmxBinary() -> URL {
    let zmxURL = FileManager.default.temporaryDirectory.appendingPathComponent("supacode-test-zmx-\(UUID().uuidString)")
    let script = "#!/bin/sh\nexec /bin/cat\n"
    do {
      try script.write(to: zmxURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmxURL.path)
    } catch {
      Issue.record("Failed to set up fake zmx binary: \(error)")
    }
    return zmxURL
  }

  /// `worktree` seeds the pre-created state INSIDE the dependency scope, so
  /// its `@Dependency(\.zmxClient)` captures the probe-backed client. Tests
  /// must fetch the state with the same worktree id.
  private func makeZmxBackedManager(
    probe: ZmxTestProbe,
    worktree: Worktree? = nil,
    surfaceBindingActionPerformer: ((GhosttySurfaceView, String) -> Void)? = nil
  ) -> WorktreeTerminalManager {
    let zmxURL = makeFakeZmxBinary()

    return withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { zmxURL },
        isBundled: { true },
        killSession: { id in await probe.killSession(id) },
        killRemoteSession: { host, id in await probe.killRemoteSession(host: host, sessionID: id) },
        listSessionsWithClients: { await probe.listSessionsWithClients() },
      )
    } operation: {
      let manager = WorktreeTerminalManager(
        runtime: GhosttyRuntime(),
        surfaceBindingActionPerformer: surfaceBindingActionPerformer
      )
      _ = manager.state(for: worktree ?? makeWorktree())
      return manager
    }
  }

  nonisolated private func session(for surfaceID: UUID) -> String {
    ZmxSessionID.make(surfaceID: surfaceID)
  }

  // MainActor work schedules cooperatively, so yield-poll it; the deadline guards CI load.
  private func waitUntil(
    _ description: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @MainActor () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: ZmxTestProbe.waitTimeout)
    while !condition() && clock.now < deadline {
      await Task.yield()
    }
    if !condition() {
      Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
    }
  }

  private actor ZmxTestProbe {
    // Backstop so a never-firing kill or probe fails fast instead of hanging.
    static let waitTimeout: Duration = .seconds(10)

    private enum Trigger {
      case kill(@Sendable ([String]) -> Bool)
      case remoteKill(@Sendable ([RemoteKill]) -> Bool)
      case remoteKillPending(threshold: Int)
      case list(threshold: Int)
    }

    struct RemoteKill: Equatable, Sendable {
      var authority: String
      var sessionID: String
    }

    // Resumed exactly once: by the event or the timeout.
    private struct Waiter {
      let id: UUID
      let trigger: Trigger
      let continuation: CheckedContinuation<Bool, Never>
      let timeout: Task<Void, Never>
    }

    private var listing: [ZmxSessionListParser.Entry]?
    private var killed: [String] = []
    private var remoteKills: [RemoteKill] = []
    private var listCalls = 0
    private var waiters: [Waiter] = []
    /// When armed, `killRemoteSession` suspends mid-flight so a test can observe
    /// whether a local kill races it (the ordering bug).
    private var remoteKillGateArmed = false
    private var pendingRemoteKillContinuations: [CheckedContinuation<Void, Never>] = []
    private var remoteKillPendingCount = 0
    private var localKilledWhileRemoteGated = false

    init(listing: [ZmxSessionListParser.Entry]?) {
      self.listing = listing
    }

    func setListing(_ listing: [ZmxSessionListParser.Entry]?) {
      self.listing = listing
    }

    func listSessionsWithClients() -> [ZmxSessionListParser.Entry]? {
      listCalls += 1
      resumeWaiters()
      return listing
    }

    func killSession(_ sessionID: String) {
      if remoteKillGateArmed { localKilledWhileRemoteGated = true }
      killed.append(sessionID)
      resumeWaiters()
    }

    func killedSessions() -> [String] {
      killed
    }

    func killRemoteSession(host: RemoteHost, sessionID: String) async {
      if remoteKillGateArmed {
        remoteKillPendingCount += 1
        resumeWaiters()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          pendingRemoteKillContinuations.append(continuation)
        }
      }
      remoteKills.append(RemoteKill(authority: host.authority, sessionID: sessionID))
      resumeWaiters()
    }

    /// Holds every subsequent `killRemoteSession` suspended until released.
    func armRemoteKillGate() { remoteKillGateArmed = true }

    func releaseRemoteKillGate() {
      remoteKillGateArmed = false
      let held = pendingRemoteKillContinuations
      pendingRemoteKillContinuations.removeAll()
      for continuation in held { continuation.resume() }
    }

    /// True if a local kill ran while a remote kill was gated (remote-before-local violated).
    func localKilledWhileGated() -> Bool { localKilledWhileRemoteGated }

    func remoteKilledSessions() -> [RemoteKill] {
      remoteKills
    }

    func listCallCount() -> Int {
      listCalls
    }

    @discardableResult
    func waitForKill(
      where predicate: @escaping @Sendable ([String]) -> Bool,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await wait(for: .kill(predicate), description: "zmx session kill", sourceLocation: sourceLocation)
    }

    @discardableResult
    func waitForRemoteKill(
      where predicate: @escaping @Sendable ([RemoteKill]) -> Bool,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await wait(for: .remoteKill(predicate), description: "remote zmx session kill", sourceLocation: sourceLocation)
    }

    @discardableResult
    func waitForRemoteKillPending(
      atLeast threshold: Int,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await wait(
        for: .remoteKillPending(threshold: threshold),
        description: "gated remote zmx kill",
        sourceLocation: sourceLocation)
    }

    @discardableResult
    func waitForListCalls(
      atLeast threshold: Int,
      sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
      await wait(for: .list(threshold: threshold), description: "zmx list probe call", sourceLocation: sourceLocation)
    }

    // The event resumes the waiter; the timeout only guards a regression.
    private func wait(
      for trigger: Trigger,
      description: String,
      sourceLocation: SourceLocation
    ) async -> Bool {
      if isSatisfied(trigger) { return true }
      let id = UUID()
      let satisfied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        // Strong capture: bounded and cancelled on the event path, so the continuation always resumes.
        let timeout = Task { [self] in
          try? await Task.sleep(for: Self.waitTimeout)
          await expireWaiter(id)
        }
        waiters.append(Waiter(id: id, trigger: trigger, continuation: continuation, timeout: timeout))
      }
      if !satisfied {
        Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
      }
      return satisfied
    }

    private func isSatisfied(_ trigger: Trigger) -> Bool {
      switch trigger {
      case .kill(let predicate): predicate(killed)
      case .remoteKill(let predicate): predicate(remoteKills)
      case .remoteKillPending(let threshold): remoteKillPendingCount >= threshold
      case .list(let threshold): listCalls >= threshold
      }
    }

    private func resumeWaiters() {
      waiters.removeAll { waiter in
        guard isSatisfied(waiter.trigger) else { return false }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: true)
        return true
      }
    }

    private func expireWaiter(_ id: UUID) {
      guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
      waiters.remove(at: index).continuation.resume(returning: false)
    }
  }

  private func nextEvent(
    _ stream: AsyncStream<TerminalClient.Event>,
    matching predicate: (TerminalClient.Event) -> Bool
  ) async -> TerminalClient.Event? {
    for await event in stream where predicate(event) {
      return event
    }
    return nil
  }

  private func makeNotification(
    surfaceID: UUID = UUID(),
    isRead: Bool,
    createdAt: Date = .distantPast
  ) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(
      surfaceID: surfaceID,
      title: "Title",
      body: "Body",
      createdAt: createdAt,
      isRead: isRead
    )
  }

  @Test func beginTabRenameCommandUsesSelectedTabWhenNoExplicitID() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    guard let tabId = state.createTab() else {
      Issue.record("Expected tab to be created")
      return
    }

    manager.handleCommand(.beginTabRename(worktree))

    #expect(state.tabManager.editingTabID == tabId)
  }

  @Test func beginTabRenameCommandUsesExplicitTabID() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    guard let firstTabId = state.createTab(),
      let secondTabId = state.createTab(focusing: true)
    else {
      Issue.record("Expected two tabs to be created")
      return
    }
    #expect(state.tabManager.selectedTabId == secondTabId)

    manager.handleCommand(.beginTabRename(worktree, tabID: firstTabId))

    #expect(state.tabManager.editingTabID == firstTabId)
  }

  @Test func beginTabRenameCommandIgnoresUnknownExplicitTabID() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    _ = state.createTab()

    manager.handleCommand(.beginTabRename(worktree, tabID: TerminalTabID()))

    #expect(state.tabManager.editingTabID == nil)
  }

  @Test func beginTabRenameCommandIsNoOpWhenWorktreeHasNoTabs() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    manager.handleCommand(.beginTabRename(worktree))

    #expect(state.tabManager.editingTabID == nil)
  }

  @Test func captureLayoutSnapshotExcludesBlockingScriptTabs() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    _ = state.createTab()
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))

    #expect(state.tabManager.tabs.count == 2)

    guard let snapshot = state.captureLayoutSnapshot() else {
      Issue.record("Expected non-nil snapshot")
      return
    }
    // The blocking-script tab dies with the app (bypasses zmx, freezes
    // readonly on completion), so it must not be persisted into the layout.
    #expect(snapshot.tabs.count == 1)
    #expect(snapshot.tabs.first?.title != "Archive Script")
  }

  @Test func captureLayoutSnapshotExcludesCompletedBlockingScriptTabs() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking script tab and surface")
      return
    }

    surface.bridge.onCommandFinished?(0)
    _ = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event { return true }
      return false
    }
    // After completion the tab keeps its title / icon / lock and stays
    // flagged as blocking-script; snapshot exclusion survives completion.
    #expect(state.tabManager.tabs.first { $0.id == tabId }?.isBlockingScript == true)
    #expect(state.captureLayoutSnapshot() == nil)
  }

  @Test func captureLayoutSnapshotSelectsLeftNeighborWhenSelectedTabIsExcluded() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    guard let tabA = state.createTab() else {
      Issue.record("Expected first regular tab")
      return
    }
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))
    guard let tabB = state.tabManager.selectedTabId else {
      Issue.record("Expected blocking-script tab selected after runBlockingScript")
      return
    }
    guard let tabC = state.createTab() else {
      Issue.record("Expected trailing regular tab")
      return
    }
    state.tabManager.selectTab(tabB)
    #expect(state.tabManager.tabs.map(\.id) == [tabA, tabB, tabC])
    #expect(state.tabManager.tabs[1].isBlockingScript == true)

    guard let snapshot = state.captureLayoutSnapshot() else {
      Issue.record("Expected non-nil snapshot")
      return
    }
    // The walk in `captureLayoutSnapshot` must pick the left surviving
    // neighbor (tabA at filtered index 0), not fall through to tabC. The
    // pre-fix code computed `selectedIndex` against the unfiltered list
    // and would have landed on tabC after `restoreFromSnapshot` clamping.
    #expect(snapshot.tabs.count == 2)
    #expect(snapshot.tabs[snapshot.selectedTabIndex].id == tabA.rawValue)
  }

  @Test func performSplitActionRefusesNewSplitOnBlockingScriptTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))
    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking-script tab and surface")
      return
    }

    let succeeded = state.performSplitAction(.newSplit(direction: .right), for: surface.id)

    #expect(succeeded == false)
    #expect(state.splitTree(for: tabId).leaves().count == 1)
  }

  @Test func performSplitOperationRefusesDropOntoBlockingScriptTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    guard let regularTab = state.createTab(),
      let regularSurface = state.splitTree(for: regularTab).root?.leftmostLeaf()
    else {
      Issue.record("Expected regular tab and surface")
      return
    }
    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "sleep 10"))
    guard let blockingTab = state.tabManager.selectedTabId,
      let blockingSurface = state.splitTree(for: blockingTab).root?.leftmostLeaf()
    else {
      Issue.record("Expected blocking-script tab and surface")
      return
    }
    let blockingLeavesBefore = state.splitTree(for: blockingTab).leaves().count

    state.performSplitOperation(
      .drop(payloadId: regularSurface.id, destinationId: blockingSurface.id, zone: .right),
      in: blockingTab,
    )

    #expect(state.splitTree(for: blockingTab).leaves().count == blockingLeavesBefore)
    #expect(state.splitTree(for: regularTab).leaves().count == 1)
  }

  @Test func renameTabCommandAppliesTitleAndEmitsRenamedEvent() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    guard let tabID = state.createTab() else {
      Issue.record("Expected a tab")
      return
    }
    let stream = manager.eventStream()

    manager.handleCommand(.renameTab(worktree, tabID: tabID, title: "implement"))

    let event = await nextEvent(stream) { event in
      if case .tabRenamed = event { return true }
      return false
    }
    #expect(event == .tabRenamed(worktreeID: worktree.id, tabID: tabID, applied: true))
    #expect(state.tabManager.tabs.first { $0.id == tabID }?.customTitle == "implement")
  }

  @Test func renameTabCommandOnLockedTabEmitsNotApplied() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = state.tabManager.createTab(title: "Run Script", icon: nil, isTitleLocked: true)
    let stream = manager.eventStream()

    manager.handleCommand(.renameTab(worktree, tabID: tabID, title: "implement"))

    let event = await nextEvent(stream) { event in
      if case .tabRenamed = event { return true }
      return false
    }
    #expect(event == .tabRenamed(worktreeID: worktree.id, tabID: tabID, applied: false))
    #expect(state.tabManager.tabs.first { $0.id == tabID }?.customTitle == nil)
  }

  @Test func renameTabCommandOnUnknownWorktreeEmitsNotAppliedWithoutResurrectingState() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let tabID = TerminalTabID()
    let stream = manager.eventStream()

    manager.handleCommand(.renameTab(worktree, tabID: tabID, title: "implement"))

    let event = await nextEvent(stream) { event in
      if case .tabRenamed = event { return true }
      return false
    }
    #expect(event == .tabRenamed(worktreeID: worktree.id, tabID: tabID, applied: false))
    #expect(manager.stateIfExists(for: worktree.id) == nil)
  }

  @Test func restoreFromSnapshotIgnoresWhitespaceOnlyCustomTitle() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "Terminal 1",
          customTitle: "   ",
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/tmp/repo/wt-1")),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    state.pendingLayoutSnapshot = snapshot
    state.ensureInitialTab(focusing: false)

    let tab = state.tabManager.tabs.first
    #expect(tab?.customTitle == nil)
    #expect(tab?.displayTitle == "Terminal 1")
  }

  @Test func restoreFromSnapshotPreservesCustomTitle() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "Terminal 1",
          customTitle: "foo",
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: nil, workingDirectory: "/tmp/repo/wt-1")),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    state.pendingLayoutSnapshot = snapshot
    state.ensureInitialTab(focusing: false)

    #expect(state.tabManager.tabs.first?.displayTitle == "foo")
  }

  private func makeLayoutSnapshot() -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "Terminal 1",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(
              id: nil,
              workingDirectory: "/tmp/repo/wt-1"
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
  }

  // MARK: - Per-tab input stability (C4).
  //
  // These pin the projection inputs the per-tab leaf views read so a future
  // refactor that broadens the read surface can't silently re-introduce the
  // `6590fdaf` cross-tab fan-out regression. They don't measure SwiftUI
  // invalidation, they assert the underlying algebra stays per-tab pure.

  @Test func notificationOnTabBLeavesTabAUnseenCountUnchanged() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    guard
      let tabA = state.createTab(),
      let tabB = state.createTab(focusing: false),
      let surfaceA = state.splitTree(for: tabA).root?.leftmostLeaf(),
      let surfaceB = state.splitTree(for: tabB).root?.leftmostLeaf()
    else {
      Issue.record("Expected two tabs and two surfaces")
      return
    }

    #expect(state.hasUnseenNotification(forTabID: tabA) == false)
    #expect(state.hasUnseenNotification(forTabID: tabB) == false)

    state.setNotificationsForTesting(
      state.notifications + [makeNotification(surfaceID: surfaceB.id, isRead: false)]
    )

    #expect(state.hasUnseenNotification(forTabID: tabA) == false)
    #expect(state.hasUnseenNotification(forTabID: tabB) == true)
    // surfaceIDs(inTab:) does not drift from a notifications mutation.
    #expect(state.surfaceIDs(inTab: tabA) == [surfaceA.id])
    #expect(state.surfaceIDs(inTab: tabB) == [surfaceB.id])
  }

  @Test func agentPresenceOnTabBLeavesTabAAgentsUnchanged() {
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness()
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    guard
      let tabA = state.createTab(),
      let tabB = state.createTab(focusing: false),
      let surfaceA = state.splitTree(for: tabA).root?.leftmostLeaf(),
      let surfaceB = state.splitTree(for: tabB).root?.leftmostLeaf()
    else {
      Issue.record("Expected two tabs and two surfaces")
      return
    }
    let tabASurfaces = state.surfaceIDs(inTab: tabA)
    let tabBSurfaces = state.surfaceIDs(inTab: tabB)

    func agents(for surfaceIDs: [UUID]) -> [AgentPresenceFeature.AgentInstance] {
      presence.state.agents(across: surfaceIDs, badgesEnabled: true)
    }
    #expect(agents(for: tabASurfaces).isEmpty)
    #expect(agents(for: tabBSurfaces).isEmpty)

    presence.send(.hookEventReceived(makeHookEvent(.sessionStart, surfaceID: surfaceB.id, pid: getpid())))
    presence.send(.hookEventReceived(makeHookEvent(.busy, surfaceID: surfaceB.id)))

    #expect(agents(for: tabASurfaces).isEmpty)
    #expect(!agents(for: tabBSurfaces).isEmpty)
    // Sanity: a sibling mutation also doesn't drift A's surface set.
    _ = surfaceA
    #expect(state.surfaceIDs(inTab: tabA) == tabASurfaces)
  }

  @Test func osc11BackgroundColorResolvesBackgroundKindToSRGB() {
    let color = WorktreeTerminalManager.osc11BackgroundColor(
      kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND,
      red: 26,
      green: 42,
      blue: 58
    )
    let srgb = color?.usingColorSpace(.sRGB)
    #expect(srgb != nil)
    #expect(abs((srgb?.redComponent ?? 0) - CGFloat(26) / 255) < 0.001)
    #expect(abs((srgb?.greenComponent ?? 0) - CGFloat(42) / 255) < 0.001)
    #expect(abs((srgb?.blueComponent ?? 0) - CGFloat(58) / 255) < 0.001)
  }

  @Test func osc11BackgroundColorIgnoresNonBackgroundKinds() {
    #expect(
      WorktreeTerminalManager.osc11BackgroundColor(
        kind: GHOSTTY_ACTION_COLOR_KIND_FOREGROUND, red: 1, green: 2, blue: 3) == nil)
    #expect(
      WorktreeTerminalManager.osc11BackgroundColor(
        kind: GHOSTTY_ACTION_COLOR_KIND_CURSOR, red: 1, green: 2, blue: 3) == nil)
    #expect(
      WorktreeTerminalManager.osc11BackgroundColor(kind: nil, red: 1, green: 2, blue: 3) == nil)
  }

  @Test func osc11BackgroundColorRequiresAllComponents() {
    #expect(
      WorktreeTerminalManager.osc11BackgroundColor(
        kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, red: nil, green: 2, blue: 3) == nil)
    #expect(
      WorktreeTerminalManager.osc11BackgroundColor(
        kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, red: 1, green: nil, blue: 3) == nil)
    #expect(
      WorktreeTerminalManager.osc11BackgroundColor(
        kind: GHOSTTY_ACTION_COLOR_KIND_BACKGROUND, red: 1, green: 2, blue: nil) == nil)
  }

  @Test func focusedSurfaceBackgroundInitializesToThemeFallback() {
    let runtime = GhosttyRuntime()
    let manager = WorktreeTerminalManager(runtime: runtime)
    #expect(manager.focusedSurfaceBackground.matchesTint(runtime.backgroundColor()))
  }

  @Test func refreshFocusedSurfaceBackgroundDedupesUnchangedColor() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let notificationCount = LockIsolated(0)
    let observer = NotificationCenter.default.addObserver(
      forName: .ghosttyFocusedSurfaceBackgroundDidChange,
      object: manager,
      queue: nil
    ) { _ in
      notificationCount.withValue { $0 += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    // The resolved color (theme fallback, no focused surface) matches the
    // stored value, so neither a manual refresh nor a selection change posts.
    manager.refreshFocusedSurfaceBackground()
    manager.handleCommand(.setSelectedWorktreeID(makeWorktree().id))

    #expect(notificationCount.value == 0)
    #expect(manager.selectedWorktreeID == makeWorktree().id)
  }

  @Test func switchingBetweenSelectionsDoesNotSpuriouslyPost() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let notificationCount = LockIsolated(0)
    let observer = NotificationCenter.default.addObserver(
      forName: .ghosttyFocusedSurfaceBackgroundDidChange,
      object: manager,
      queue: nil
    ) { _ in
      notificationCount.withValue { $0 += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    let first = makeWorktree(id: "/tmp/repo/wt-a").id
    let second = makeWorktree(id: "/tmp/repo/wt-b").id
    manager.handleCommand(.setSelectedWorktreeID(first))
    manager.handleCommand(.setSelectedWorktreeID(second))
    manager.handleCommand(.setSelectedWorktreeID(first))

    #expect(notificationCount.value == 0)
    #expect(manager.selectedWorktreeID == first)
  }
}
