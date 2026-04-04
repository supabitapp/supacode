import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@MainActor
struct AgentBusyStateTests {
  // MARK: - Surface → tab → worktree bubbling.

  @Test func setAgentBusyMakesTaskStatusRunning() {
    let worktree = makeWorktree()
    let fixture = makeStateWithSurface(worktree: worktree)
    #expect(fixture.manager.taskStatus(for: worktree.id) == .idle)

    fixture.state.setAgentBusy(surfaceID: fixture.surface.id, tabID: fixture.tabId, active: true)

    #expect(fixture.manager.taskStatus(for: worktree.id) == .running)
  }

  @Test func clearAgentBusyReturnsToIdle() {
    let worktree = makeWorktree()
    let fixture = makeStateWithSurface(worktree: worktree)

    fixture.state.setAgentBusy(surfaceID: fixture.surface.id, tabID: fixture.tabId, active: true)
    #expect(fixture.manager.taskStatus(for: worktree.id) == .running)

    fixture.state.setAgentBusy(surfaceID: fixture.surface.id, tabID: fixture.tabId, active: false)
    #expect(fixture.manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func setAgentBusyMarksTabDirty() {
    let fixture = makeStateWithSurface()

    // Complete the blocking script to clear initial dirty state.
    fixture.surface.bridge.onCommandFinished?(0)
    let tabBefore = fixture.state.tabManager.tabs.first { $0.id == fixture.tabId }
    #expect(tabBefore?.isDirty == false)

    fixture.state.setAgentBusy(surfaceID: fixture.surface.id, tabID: fixture.tabId, active: true)

    let tabAfter = fixture.state.tabManager.tabs.first { $0.id == fixture.tabId }
    #expect(tabAfter?.isDirty == true)
  }

  @Test func clearAgentBusyClearsTabDirty() {
    let fixture = makeStateWithSurface()

    // Complete the blocking script first.
    fixture.surface.bridge.onCommandFinished?(0)
    fixture.state.setAgentBusy(surfaceID: fixture.surface.id, tabID: fixture.tabId, active: true)
    fixture.state.setAgentBusy(surfaceID: fixture.surface.id, tabID: fixture.tabId, active: false)

    let tab = fixture.state.tabManager.tabs.first { $0.id == fixture.tabId }
    #expect(tab?.isDirty == false)
  }

  @Test func setAgentBusyOnUnknownSurfaceIsNoOp() {
    let worktree = makeWorktree()
    let fixture = makeStateWithSurface(worktree: worktree)

    fixture.state.setAgentBusy(surfaceID: UUID(), tabID: fixture.tabId, active: true)

    #expect(fixture.manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func closingBusySurfaceClearsTaskStatus() {
    let worktree = makeWorktree()
    let fixture = makeStateWithSurface(worktree: worktree)

    fixture.state.setAgentBusy(surfaceID: fixture.surface.id, tabID: fixture.tabId, active: true)
    #expect(fixture.manager.taskStatus(for: worktree.id) == .running)

    fixture.state.closeTab(fixture.tabId)
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

    state.setAgentBusy(surfaceID: surfaceA.id, tabID: tabs[0], active: true)
    state.setAgentBusy(surfaceID: surfaceB.id, tabID: tabs[1], active: true)
    #expect(manager.taskStatus(for: worktree.id) == .running)

    // Clear one — still running because the other is busy.
    state.setAgentBusy(surfaceID: surfaceA.id, tabID: tabs[0], active: false)
    #expect(manager.taskStatus(for: worktree.id) == .running)

    // Clear the other — now idle.
    state.setAgentBusy(surfaceID: surfaceB.id, tabID: tabs[1], active: false)
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

    state.setAgentBusy(surfaceID: surface.id, tabID: tabId, active: true)

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
      fixture.state.onNotificationReceived = { _, _ in
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
      fixture.state.onNotificationReceived = { _, _ in
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
      fixture.state.onNotificationReceived = { _, _ in
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

  private struct SurfaceFixture {
    let manager: WorktreeTerminalManager
    let state: WorktreeTerminalState
    let tabId: TerminalTabID
    let surface: GhosttySurfaceView
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
