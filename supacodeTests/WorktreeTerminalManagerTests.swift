import Clocks
import Dependencies
import Foundation
import GhosttyKit
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
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
    state.closeAllTabs()

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
    let server = AgentHookSocketServer()
    server.shutdown()

    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), socketServer: server)
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(manager.socketServer == nil)
    #expect(state.socketPath == nil)
  }

  @Test func oscHookActivityEventRoutesToWorktreeState() async {
    let server = AgentHookSocketServer()
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
    let server = AgentHookSocketServer()
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
    await clock.advance(by: .milliseconds(100))
    await presence.drain()
    #expect(presence.state.hasActivity(in: [surface.id]))

    state.onAgentHookEvent?(makeHookEvent(.busy, surfaceID: surface.id))
    await clock.advance(by: .milliseconds(500))
    await presence.drain()
    #expect(presence.state.hasActivity(in: [surface.id]))
  }

  @Test func oscIdleCommitsAfterDebounceWindow() async {
    let clock = TestClock()
    let server = AgentHookSocketServer()
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

    await clock.advance(by: .milliseconds(399))
    await presence.drain()
    #expect(presence.state.hasActivity(in: [surface.id]))

    await clock.advance(by: .milliseconds(1))
    await presence.drain()
    #expect(!presence.state.hasActivity(in: [surface.id]))
  }

  @Test func oscIdleDebouncesPerAgentIndependently() async {
    let clock = TestClock()
    let server = AgentHookSocketServer()
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
    await clock.advance(by: .milliseconds(400))

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
    let server = AgentHookSocketServer()
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

    await clock.advance(by: .milliseconds(500))
    await presence.drain()

    #expect(presence.state.agents(forSurface: surface.id, badgesEnabled: true).isEmpty)
    #expect(!presence.state.hasActivity(in: [surface.id]))
  }

  @Test func oscSurfaceClosedWhileIdlePendingIsHarmless() async {
    let clock = TestClock()
    let server = AgentHookSocketServer()
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
    await clock.advance(by: .milliseconds(500))
    await presence.drain()

    #expect(!presence.state.hasActivity(in: [surface.id]))
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

    state.setNotificationsForTesting([
      makeNotification(isRead: true),
      makeNotification(isRead: true),
    ])

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)

    state.setNotificationsForTesting(state.notifications + [makeNotification(isRead: false)])

    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)
  }

  @Test func markAllNotificationsReadEmitsUpdatedIndicatorCount() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.setNotificationsForTesting([
      makeNotification(isRead: false),
      makeNotification(isRead: true),
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

  @Test func markNotificationsReadOnlyAffectsMatchingSurface() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceA = UUID()
    let surfaceB = UUID()

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
    // Seed a notification for the not-yet-restored surface; the flag install
    // is silently dropped because `surfaceStates[knownSurfaceID]` is absent.
    state.setNotificationsForTesting([
      makeNotification(surfaceID: knownSurfaceID, isRead: false)
    ])
    #expect(state.surfaceStates[knownSurfaceID] == nil)

    state.ensureInitialTab(focusing: false)

    #expect(state.surfaceStates[knownSurfaceID]?.hasUnseenNotification == true)
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
    #expect(updatedTab?.isDirty == false)
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
    #expect(updatedTab?.isDirty == false)
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
    #expect(state.tabManager.tabs.first { $0.id == tabId }?.isDirty == false)

    // Simulate the stale watch re-firing a fresh in-flight progress
    // report just before its REMOVE. Without the gate in `updateRunningState`,
    // `isTabBusy` would see the running state and flip dirty back to true.
    surface.bridge.state.progressState = GHOSTTY_PROGRESS_STATE_INDETERMINATE
    surface.bridge.onProgressReport?(GHOSTTY_PROGRESS_STATE_INDETERMINATE)

    #expect(state.tabManager.tabs.first { $0.id == tabId }?.isDirty == false)
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
    let overflow = WorktreeTerminalManager.eventBufferCap + 50
    for _ in 0..<overflow {
      state.onSetupScriptConsumed?()
    }

    _ = manager.eventStream()

    var count = 0
    for await event in stream {
      if case .setupScriptConsumed = event { count += 1 }
    }

    #expect(count == WorktreeTerminalManager.eventBufferCap)
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
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
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
}
