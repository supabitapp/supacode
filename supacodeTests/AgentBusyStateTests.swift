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

  @Test(.dependencies) func oscNotificationSuppressedWithinWindow() {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    } operation: {
      let fixture = makeStateWithSurface()
      var systemNotificationCount = 0
      fixture.state.onNotificationReceived = { _, _, _ in
        systemNotificationCount += 1
      }

      // Hook notification fires system notification.
      fixture.state.appendHookNotification(
        title: "Done",
        body: "Task complete",
        surfaceID: fixture.surface.id,
      )
      #expect(systemNotificationCount == 1)

      // OSC 9 with identical text within the 2s window (via bridge callback).
      fixture.surface.bridge.onDesktopNotification?("Done", "Task complete")

      // The system notification should be suppressed (still 1).
      #expect(systemNotificationCount == 1)
      // But the in-app notification is still recorded.
      #expect(fixture.state.notifications.count == 2)
    }
  }

  @Test(.dependencies) func oscNotificationNotSuppressedAfterWindow() {
    let baseDate = Date(timeIntervalSince1970: 1000)
    let currentDate = LockIsolated(baseDate)

    withDependencies {
      $0.date = .init { currentDate.value }
    } operation: {
      let fixture = makeStateWithSurface()
      var systemNotificationCount = 0
      fixture.state.onNotificationReceived = { _, _, _ in
        systemNotificationCount += 1
      }

      // Hook notification at t=1000.
      fixture.state.appendHookNotification(
        title: "Done",
        body: "All complete",
        surfaceID: fixture.surface.id,
      )
      #expect(systemNotificationCount == 1)

      // OSC 9 at t=1003 (beyond the 2s window).
      currentDate.setValue(baseDate.addingTimeInterval(3))
      fixture.surface.bridge.onDesktopNotification?("Done", "All complete")

      // Not suppressed — fires system notification.
      #expect(systemNotificationCount == 2)
    }
  }

  @Test(.dependencies) func genericCompletionTextSuppressedWithinWindow() {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    } operation: {
      let fixture = makeStateWithSurface()
      var systemNotificationCount = 0
      fixture.state.onNotificationReceived = { _, _, _ in
        systemNotificationCount += 1
      }

      // Hook notification with specific text.
      fixture.state.appendHookNotification(
        title: "Claude",
        body: "Refactored the module",
        surfaceID: fixture.surface.id,
      )
      #expect(systemNotificationCount == 1)

      // OSC 9 with generic "Task Complete" text.
      fixture.surface.bridge.onDesktopNotification?("Task Complete", "")

      // Generic completion text is suppressed.
      #expect(systemNotificationCount == 1)
    }
  }

  @Test(.dependencies) func closingTabCleansRecentHookEntries() {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    } operation: {
      let fixture = makeStateWithSurface()

      fixture.state.appendHookNotification(
        title: "Done",
        body: "All complete",
        surfaceID: fixture.surface.id,
      )
      #expect(fixture.state.debugRecentHookCount == 1)

      fixture.state.closeTab(fixture.tabId)

      #expect(fixture.state.debugRecentHookCount == 0)
    }
  }

  @Test(.dependencies) func closingSurfaceCleansRecentHookEntries() {
    withDependencies {
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
    } operation: {
      let fixture = makeStateWithSurface()
      #expect(fixture.state.performSplitAction(.newSplit(direction: .right), for: fixture.surface.id))

      let leaves = fixture.state.splitTree(for: fixture.tabId).leaves()
      guard let splitSurface = leaves.first(where: { $0.id != fixture.surface.id }) else {
        Issue.record("Expected split surface")
        return
      }

      fixture.state.appendHookNotification(
        title: "Done",
        body: "All complete",
        surfaceID: splitSurface.id,
      )
      #expect(fixture.state.debugRecentHookCount == 1)

      splitSurface.bridge.onCloseRequest?(false)

      #expect(fixture.state.debugRecentHookCount == 0)
    }
  }

  // MARK: - Helpers.

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
    guard case .event(let event) = AgentHookSocketServer.parse(data: Data(json.utf8)) else {
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

    manager.handleCommand(.runBlockingScript(resolvedWorktree, kind: .archive, script: "echo ok"))

    let state = manager.stateIfExists(for: resolvedWorktree.id)!
    let tabId = state.tabManager.selectedTabId!
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
