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

  @Test func busyEventMakesTaskStatusRunning() {
    let worktree = makeWorktree()
    let fixture = makeStateWithSurface(worktree: worktree)
    defer { AgentPresenceManager.shared.surfaceClosed(fixture.surface.id) }
    #expect(fixture.manager.taskStatus(for: worktree.id) == .idle)

    fixture.startSession()
    fixture.emit(.busy)

    #expect(fixture.manager.taskStatus(for: worktree.id) == .running)
  }

  @Test func clearBusyReturnsToIdle() {
    let worktree = makeWorktree()
    let fixture = makeStateWithSurface(worktree: worktree)
    defer { AgentPresenceManager.shared.surfaceClosed(fixture.surface.id) }

    fixture.startSession()
    fixture.emit(.busy)
    #expect(fixture.manager.taskStatus(for: worktree.id) == .running)

    fixture.emit(.idle)
    #expect(fixture.manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func busyEventMarksTabDirty() {
    let fixture = makeStateWithSurface()
    defer { AgentPresenceManager.shared.surfaceClosed(fixture.surface.id) }

    // Complete the blocking script to clear initial dirty state.
    fixture.surface.bridge.onCommandFinished?(0)
    let tabBefore = fixture.state.tabManager.tabs.first { $0.id == fixture.tabId }
    #expect(tabBefore?.isDirty == false)

    fixture.startSession()
    fixture.emit(.busy)

    let tabAfter = fixture.state.tabManager.tabs.first { $0.id == fixture.tabId }
    #expect(tabAfter?.isDirty == true)
  }

  @Test func clearBusyClearsTabDirty() {
    let fixture = makeStateWithSurface()
    defer { AgentPresenceManager.shared.surfaceClosed(fixture.surface.id) }

    fixture.surface.bridge.onCommandFinished?(0)
    fixture.startSession()
    fixture.emit(.busy)
    fixture.emit(.idle)

    let tab = fixture.state.tabManager.tabs.first { $0.id == fixture.tabId }
    #expect(tab?.isDirty == false)
  }

  @Test func activityEventForUnknownSurfaceIsNoOp() {
    let worktree = makeWorktree()
    let fixture = makeStateWithSurface(worktree: worktree)
    defer { AgentPresenceManager.shared.surfaceClosed(fixture.surface.id) }

    let strangerSurface = UUID()
    AgentPresenceManager.shared.record(
      event: makeHookEvent(.sessionStart, surfaceID: strangerSurface, pid: getpid())
    )
    AgentPresenceManager.shared.record(event: makeHookEvent(.busy, surfaceID: strangerSurface))
    _ = fixture.state.surfaceActivityChanged(surfaceID: strangerSurface)
    AgentPresenceManager.shared.surfaceClosed(strangerSurface)

    #expect(fixture.manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func closingBusySurfaceClearsTaskStatus() {
    let worktree = makeWorktree()
    let fixture = makeStateWithSurface(worktree: worktree)
    defer { AgentPresenceManager.shared.surfaceClosed(fixture.surface.id) }

    fixture.startSession()
    fixture.emit(.busy)
    #expect(fixture.manager.taskStatus(for: worktree.id) == .running)

    fixture.state.closeTab(fixture.tabId)
    AgentPresenceManager.shared.surfaceClosed(fixture.surface.id)
    #expect(fixture.manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func multipleSurfacesBusyInDifferentTabs() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
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
    defer {
      AgentPresenceManager.shared.surfaceClosed(surfaceA.id)
      AgentPresenceManager.shared.surfaceClosed(surfaceB.id)
    }

    let presence = AgentPresenceManager.shared
    func emit(_ name: AgentHookEvent.EventName, surfaceID: UUID, pid: pid_t? = nil) {
      presence.record(event: makeHookEvent(name, surfaceID: surfaceID, pid: pid))
      _ = state.surfaceActivityChanged(surfaceID: surfaceID)
    }

    emit(.sessionStart, surfaceID: surfaceA.id, pid: getpid())
    emit(.sessionStart, surfaceID: surfaceB.id, pid: getpid())
    emit(.busy, surfaceID: surfaceA.id)
    emit(.busy, surfaceID: surfaceB.id)
    #expect(manager.taskStatus(for: worktree.id) == .running)

    // Clear one — still running because the other is busy.
    emit(.idle, surfaceID: surfaceA.id)
    #expect(manager.taskStatus(for: worktree.id) == .running)

    // Clear the other — now idle.
    emit(.idle, surfaceID: surfaceB.id)
    #expect(manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func taskStatusChangedEmittedOnBusyToggle() async {
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
    defer { AgentPresenceManager.shared.surfaceClosed(surface.id) }

    AgentPresenceManager.shared.record(
      event: makeHookEvent(.sessionStart, surfaceID: surface.id, pid: getpid())
    )
    AgentPresenceManager.shared.record(event: makeHookEvent(.busy, surfaceID: surface.id))
    _ = state.surfaceActivityChanged(surfaceID: surface.id)
    _ = tabId  // silence unused warning

    let event = await nextEvent(stream) { event in
      if case .taskStatusChanged(_, let status) = event, status == .running {
        return true
      }
      return false
    }
    #expect(event != nil)
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
    let state: WorktreeTerminalState
    let tabId: TerminalTabID
    let surface: GhosttySurfaceView

    func startSession(agent: SkillAgent = .claude, pid: pid_t = getpid()) {
      AgentPresenceManager.shared.record(
        event: AgentBusyStateTests.makeHookEvent(.sessionStart, agent: agent, surfaceID: surface.id, pid: pid)
      )
      _ = state.surfaceActivityChanged(surfaceID: surface.id)
    }

    func emit(_ name: AgentHookEvent.EventName, agent: SkillAgent = .claude) {
      AgentPresenceManager.shared.record(
        event: AgentBusyStateTests.makeHookEvent(name, agent: agent, surfaceID: surface.id)
      )
      _ = state.surfaceActivityChanged(surfaceID: surface.id)
    }
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
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let resolvedWorktree = worktree ?? makeWorktree()

    manager.handleCommand(.runBlockingScript(resolvedWorktree, kind: .archive, script: "echo ok"))

    let state = manager.stateIfExists(for: resolvedWorktree.id)!
    let tabId = state.tabManager.selectedTabId!
    let surface = state.splitTree(for: tabId).root!.leftmostLeaf()
    return SurfaceFixture(manager: manager, state: state, tabId: tabId, surface: surface)
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
