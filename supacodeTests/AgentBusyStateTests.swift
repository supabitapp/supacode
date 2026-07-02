import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct AgentBusyStateTests {
  // MARK: - Surface → tab → worktree bubbling.

  @Test func busyEventMakesActivityTrue() {
    let fixture = makeStateWithSurface()
    #expect(!fixture.isBusy)

    fixture.startSession()
    fixture.emit(.busy)

    #expect(fixture.isBusy)
  }

  @Test func clearBusyReturnsToIdle() {
    let fixture = makeStateWithSurface()

    fixture.startSession()
    fixture.emit(.busy)
    #expect(fixture.isBusy)

    fixture.emit(.idle)
    #expect(!fixture.isBusy)
  }

  @Test func activityEventForUnknownSurfaceIsNoOp() {
    let fixture = makeStateWithSurface()

    let strangerSurface = UUID()
    fixture.presence.send(
      .hookEventReceived(makeHookEvent(.sessionStart, surfaceID: strangerSurface, pid: getpid())))
    fixture.presence.send(.hookEventReceived(makeHookEvent(.busy, surfaceID: strangerSurface)))
    fixture.presence.send(.surfaceClosed(strangerSurface))

    #expect(!fixture.isBusy)
  }

  @Test func closingBusySurfaceClearsActivity() {
    let fixture = makeStateWithSurface()

    fixture.startSession()
    fixture.emit(.busy)
    #expect(fixture.isBusy)

    fixture.state.closeTab(fixture.tabId)
    fixture.presence.send(.surfaceClosed(fixture.surface.id))
    #expect(!fixture.isBusy)
  }

  @Test func multipleSurfacesBusyInDifferentTabs() {
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness()
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo a"))
    manager.handleCommand(.runBlockingScript(worktree, kind: .delete, script: "echo b"))

    guard let state = manager.stateIfExists(for: worktree.id) else {
      Issue.record("Expected worktree state")
      return
    }
    let tabs = state.tabManager.tabs.map(\.id)
    guard tabs.count >= 2 else {
      Issue.record("Expected at least two tabs")
      return
    }

    guard
      let surfaceA = state.splitTree(for: tabs[0]).root?.leftmostLeaf(),
      let surfaceB = state.splitTree(for: tabs[1]).root?.leftmostLeaf()
    else {
      Issue.record("Expected surfaces in both tabs")
      return
    }
    let surfaces = [surfaceA.id, surfaceB.id]

    func emit(_ name: AgentHookEvent.EventName, surfaceID: UUID, pid: pid_t? = nil) {
      presence.send(.hookEventReceived(makeHookEvent(name, surfaceID: surfaceID, pid: pid)))
    }

    emit(.sessionStart, surfaceID: surfaceA.id, pid: getpid())
    emit(.sessionStart, surfaceID: surfaceB.id, pid: getpid())
    emit(.busy, surfaceID: surfaceA.id)
    emit(.busy, surfaceID: surfaceB.id)
    #expect(presence.state.hasActivity(in: surfaces))

    // Clear one: still busy because the other is busy.
    emit(.idle, surfaceID: surfaceA.id)
    #expect(presence.state.hasActivity(in: surfaces))

    // Clear the other: now idle.
    emit(.idle, surfaceID: surfaceB.id)
    #expect(!presence.state.hasActivity(in: surfaces))
  }

  // MARK: - Notification deduplication.

  @Test(.dependencies) func hookNotificationRecordedForDedup() {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0.continuousClock = ImmediateClock()
    } operation: {
      let fixture = makeStateWithSurface()

      fixture.state.appendHookNotification(
        title: "Done",
        body: "All complete",
        surfaceID: fixture.surface.id,
      )

      #expect(fixture.state.notifications.count == 1)
      #expect(fixture.state.notifications[0].title == "Done")
    }
  }

  @Test(.dependencies) func agentOSCSuppressedWhenCustomFiredFirst() {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0.continuousClock = ImmediateClock()
    } operation: {
      let fixture = makeStateWithSurface()
      var systemCount = 0
      fixture.state.onNotificationReceived = { _, _, _, _ in systemCount += 1 }

      // Hook-first: our expanded custom notification fires.
      fixture.state.appendHookNotification(title: "Done", body: "Expanded detail", surfaceID: fixture.surface.id)
      #expect(systemCount == 1)

      // The agent's own OSC 9 summary for the same surface is dropped immediately.
      fixture.surface.bridge.onDesktopNotification?("Done", "summary")
      #expect(systemCount == 1)
      #expect(fixture.state.notifications.count == 1)
      #expect(fixture.state.debugPendingOSCCount == 0)
    }
  }

  @Test(.dependencies) func agentOSCNotSuppressedAfterWindow() async {
    let clock = TestClock()
    await withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0.continuousClock = clock
    } operation: {
      let fixture = makeStateWithSurface()
      var systemCount = 0
      fixture.state.onNotificationReceived = { _, _, _, _ in systemCount += 1 }

      // Custom notification fires, then the suppression window fully elapses.
      fixture.state.appendHookNotification(title: "Done", body: "Expanded detail", surfaceID: fixture.surface.id)
      #expect(systemCount == 1)
      await clock.advance(by: .seconds(0.6))

      // The OSC 9 now lands outside the window, so it is held instead of dropped.
      fixture.surface.bridge.onDesktopNotification?("Done", "summary")
      await Task.megaYield()
      #expect(systemCount == 1)
      #expect(fixture.state.debugPendingOSCCount == 1)

      // After its own hold it shows.
      await clock.advance(by: .seconds(0.5))
      await Task.megaYield()
      #expect(systemCount == 2)
    }
  }

  @Test(.dependencies) func agentOSCDroppedWhenCustomSupersedesDuringHold() async {
    let clock = TestClock()
    await withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0.continuousClock = clock
    } operation: {
      let fixture = makeStateWithSurface()
      var systemCount = 0
      fixture.state.onNotificationReceived = { _, _, _, _ in systemCount += 1 }

      // OSC-9-first: the agent's summary arrives and is held.
      fixture.surface.bridge.onDesktopNotification?("Done", "summary")
      await Task.megaYield()
      #expect(systemCount == 0)
      #expect(fixture.state.debugPendingOSCCount == 1)

      // Our expanded custom notification lands during the hold: it shows and the
      // held OSC 9 is dropped.
      fixture.state.appendHookNotification(title: "Done", body: "Expanded detail", surfaceID: fixture.surface.id)
      #expect(systemCount == 1)
      #expect(fixture.state.debugPendingOSCCount == 0)

      await clock.advance(by: .seconds(0.5))
      await Task.megaYield()
      #expect(systemCount == 1)
    }
  }

  @Test(.dependencies) func agentOSCShownAfterHoldWithoutCustom() async {
    let clock = TestClock()
    await withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0.continuousClock = clock
    } operation: {
      let fixture = makeStateWithSurface()
      var systemCount = 0
      fixture.state.onNotificationReceived = { _, _, _, _ in systemCount += 1 }

      fixture.surface.bridge.onDesktopNotification?("Agent", "standalone")
      await Task.megaYield()
      #expect(systemCount == 0)

      // No custom notification superseded it, so after the hold it shows.
      await clock.advance(by: .seconds(0.5))
      await Task.megaYield()
      #expect(systemCount == 1)
    }
  }

  @Test(.dependencies) func closingSurfaceCancelsHeldOSC() async {
    let clock = TestClock()
    await withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0.continuousClock = clock
    } operation: {
      let fixture = makeStateWithSurface()
      var systemCount = 0
      fixture.state.onNotificationReceived = { _, _, _, _ in systemCount += 1 }
      // No prior custom notification, so the OSC 9 is held (not suppressed).
      fixture.surface.bridge.onDesktopNotification?("Agent", "held")
      await Task.megaYield()
      #expect(fixture.state.debugPendingOSCCount == 1)

      fixture.state.closeTab(fixture.tabId)
      #expect(fixture.state.debugPendingOSCCount == 0)

      // Advancing past the hold window proves the cancelled OSC never fires late.
      await clock.advance(by: .seconds(0.5))
      await Task.megaYield()
      #expect(systemCount == 0)
      #expect(fixture.state.notifications.count == 0)
    }
  }

  @Test(.dependencies) func closingSurfaceClearsCustomNotificationTimestamp() {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0.continuousClock = ImmediateClock()
    } operation: {
      let fixture = makeStateWithSurface()
      fixture.state.appendHookNotification(title: "Done", body: "x", surfaceID: fixture.surface.id)
      #expect(fixture.state.debugCustomNotificationTimestampCount == 1)

      fixture.state.closeTab(fixture.tabId)
      #expect(fixture.state.debugCustomNotificationTimestampCount == 0)
    }
  }

  // MARK: - isViewedSurface composite (mute-notifications gating).

  @Test(.dependencies) func selectedFocusedVisibleSurfaceIsViewed() {
    withViewedSurfaceDependencies {
      let fixture = makeStateWithSurface()
      fixture.state.isSelected = { true }
      fixture.state.syncFocus(windowIsKey: true, windowIsVisible: true)

      #expect(viewedFlag(for: fixture, surfaceID: fixture.surface.id) == true)
      #expect(fixture.state.notifications.first?.isRead == true)
    }
  }

  @Test(.dependencies) func unselectedWorktreeSurfaceIsNotViewed() {
    withViewedSurfaceDependencies {
      let fixture = makeStateWithSurface()
      fixture.state.isSelected = { false }
      fixture.state.syncFocus(windowIsKey: true, windowIsVisible: true)

      #expect(viewedFlag(for: fixture, surfaceID: fixture.surface.id) == false)
      #expect(fixture.state.notifications.first?.isRead == false)
    }
  }

  @Test(.dependencies) func inactiveWindowSurfaceIsNotViewed() {
    withViewedSurfaceDependencies {
      let fixture = makeStateWithSurface()
      fixture.state.isSelected = { true }
      fixture.state.syncFocus(windowIsKey: false, windowIsVisible: true)

      #expect(viewedFlag(for: fixture, surfaceID: fixture.surface.id) == false)
    }
  }

  @Test(.dependencies) func hiddenWindowSurfaceIsNotViewed() {
    withViewedSurfaceDependencies {
      let fixture = makeStateWithSurface()
      fixture.state.isSelected = { true }
      fixture.state.syncFocus(windowIsKey: true, windowIsVisible: false)

      #expect(viewedFlag(for: fixture, surfaceID: fixture.surface.id) == false)
    }
  }

  @Test(.dependencies) func unsyncedWindowStateSurfaceIsNotViewed() {
    withViewedSurfaceDependencies {
      let fixture = makeStateWithSurface()
      fixture.state.isSelected = { true }
      // No syncFocus: window flags stay nil, so the surface reads as not viewed.

      #expect(viewedFlag(for: fixture, surfaceID: fixture.surface.id) == false)
    }
  }

  @Test(.dependencies) func unfocusedSiblingSurfaceIsNotViewed() {
    withViewedSurfaceDependencies {
      let fixture = makeStateWithSurface()
      fixture.state.isSelected = { true }
      fixture.state.syncFocus(windowIsKey: true, windowIsVisible: true)
      // The split focuses the new sibling, leaving the original pane unfocused.
      #expect(
        fixture.state.performSplitAction(.newSplit(direction: .right), for: fixture.surface.id, newSurfaceID: UUID()))

      #expect(viewedFlag(for: fixture, surfaceID: fixture.surface.id) == false)
    }
  }

  @Test(.dependencies) func zoomHiddenFocusedSurfaceIsNotViewed() {
    withViewedSurfaceDependencies {
      let fixture = makeStateWithSurface()
      fixture.state.isSelected = { true }
      fixture.state.syncFocus(windowIsKey: true, windowIsVisible: true)
      let sibling = UUID()
      #expect(
        fixture.state.performSplitAction(.newSplit(direction: .right), for: fixture.surface.id, newSurfaceID: sibling))
      // Zoom the sibling, then move focus back to the original pane while it
      // stays behind the zoom: focused but off screen.
      #expect(fixture.state.performSplitAction(.toggleSplitZoom, for: sibling))
      #expect(fixture.state.focusSurface(id: fixture.surface.id))
      let visible = fixture.state.splitTree(for: fixture.tabId).visibleLeaves()
      #expect(!visible.contains { $0.id == fixture.surface.id })

      #expect(viewedFlag(for: fixture, surfaceID: fixture.surface.id) == false)
    }
  }

  // MARK: - Helpers.

  private func withViewedSurfaceDependencies(_ operation: () -> Void) {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0.continuousClock = ImmediateClock()
    } operation: {
      operation()
    }
  }

  // Drives a hook notification and returns the `isViewed` flag forwarded to the
  // event, isolating the private `isViewedSurface` composite.
  private func viewedFlag(for fixture: SurfaceFixture, surfaceID: UUID) -> Bool? {
    var received: Bool?
    fixture.state.onNotificationReceived = { id, _, _, isViewed in
      if id == surfaceID { received = isViewed }
    }
    fixture.state.appendHookNotification(title: "Done", body: "ok", surfaceID: surfaceID)
    return received
  }

  private func makeWorktree() -> Worktree {
    Worktree(
      id: "/tmp/repo/wt-1",
      name: "wt-1",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
  }

  @MainActor
  private struct SurfaceFixture {
    let manager: WorktreeTerminalManager
    let presence: PresenceTestHarness
    let state: WorktreeTerminalState
    let tabId: TerminalTabID
    let surface: GhosttySurfaceView

    func startSession(agent: SkillAgent = .claude, pid: pid_t = getpid()) {
      presence.send(
        .hookEventReceived(
          AgentBusyStateTests.makeHookEvent(.sessionStart, agent: agent, surfaceID: surface.id, pid: pid)),
      )
    }

    func emit(_ name: AgentHookEvent.EventName, agent: SkillAgent = .claude) {
      presence.send(
        .hookEventReceived(
          AgentBusyStateTests.makeHookEvent(name, agent: agent, surfaceID: surface.id)),
      )
    }

    var isBusy: Bool { presence.state.hasActivity(in: [surface.id]) }
  }

  private static func makeHookEvent(
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

  private func makeHookEvent(
    _ name: AgentHookEvent.EventName,
    agent: SkillAgent = .claude,
    surfaceID: UUID,
    pid: pid_t? = nil
  ) -> AgentHookEvent {
    Self.makeHookEvent(name, agent: agent, surfaceID: surfaceID, pid: pid)
  }

  private func makeStateWithSurface(worktree: Worktree? = nil) -> SurfaceFixture {
    let (manager, presence) = WorktreeTerminalManager.withPresenceHarness()
    let resolvedWorktree = worktree ?? makeWorktree()

    let state = manager.state(for: resolvedWorktree) { false }
    let tabId = state.createTab()!
    let surface = state.splitTree(for: tabId).root!.leftmostLeaf()
    return SurfaceFixture(manager: manager, presence: presence, state: state, tabId: tabId, surface: surface)
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
}
