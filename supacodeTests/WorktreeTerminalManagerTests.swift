import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeTerminalManagerTests {
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

  @Test func notificationIndicatorUsesCurrentCountOnStreamStart() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(),
        title: "Unread",
        body: "body",
        isRead: false
      ),
    ]
    state.onNotificationIndicatorChanged?()
    state.notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(),
        title: "Read",
        body: "body",
        isRead: true
      ),
    ]

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    let first = await iterator.next()
    state.onSetupScriptConsumed?()
    let second = await iterator.next()

    #expect(first == .notificationIndicatorChanged(count: 0))
    #expect(second == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func taskStatusReflectsAnyRunningTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(manager.taskStatus(for: worktree.id) == .idle)

    let tab1 = TerminalTabID()
    let tab2 = TerminalTabID()
    state.tabIsRunningById[tab1] = false
    state.tabIsRunningById[tab2] = false
    #expect(manager.taskStatus(for: worktree.id) == .idle)

    state.tabIsRunningById[tab2] = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab1] = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab2] = false
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab1] = false
    #expect(manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func hasUnseenNotificationsReflectsUnreadEntries() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: true),
      makeNotification(isRead: true),
    ]

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)

    state.notifications.append(makeNotification(isRead: false))

    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)
  }

  @Test func markAllNotificationsReadEmitsUpdatedIndicatorCount() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ]

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    let first = await iterator.next()
    state.markAllNotificationsRead()
    let second = await iterator.next()

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

    state.notifications = [
      makeNotification(surfaceId: surfaceA, isRead: false),
      makeNotification(surfaceId: surfaceB, isRead: false),
      makeNotification(surfaceId: surfaceB, isRead: true),
    ]

    state.markNotificationsRead(forSurfaceID: surfaceB)

    let aNotifications = state.notifications.filter { $0.surfaceId == surfaceA }
    let bNotifications = state.notifications.filter { $0.surfaceId == surfaceB }

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

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: false),
    ]

    state.setNotificationsEnabled(false)

    #expect(state.notifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func dismissAllNotificationsClearsState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ]

    state.dismissAllNotifications()

    #expect(state.notifications.isEmpty)
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func blockingScriptCompletionPrefersCommandFinishedExitCode() async {
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
    surface.bridge.onChildExited?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 1))
  }

  @Test func blockingScriptCompletionUsesLatestCommandFinishedExitCode() async {
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
    surface.bridge.onCommandFinished?(1)
    surface.bridge.onChildExited?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 1))
  }

  @Test func blockingScriptCompletionFallsBackToChildExitCodeWhenCommandFinishedNil() async {
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
    surface.bridge.onChildExited?(23)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 23))
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

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil))
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

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 130))
  }

  @Test func blockingScriptRerunClosesOldTabWithoutFiringCompletion() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
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
    surface.bridge.onChildExited?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0))
  }

  @Test func blockingScriptTabClosedManuallyReportsCancellation() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
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

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil))
  }

  @Test func closeAllSurfacesCancelsPendingBlockingScripts() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
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

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil))
  }

  @Test func blockingScriptSuccessAutoClosesTab() async {
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
    surface.bridge.onChildExited?(0)

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0))
    // Successful script should auto-close the tab.
    #expect(!state.tabManager.tabs.map(\.id).contains(tabId))
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
    surfaceId: UUID = UUID(),
    isRead: Bool
  ) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(
      surfaceId: surfaceId,
      title: "Title",
      body: "Body",
      isRead: isRead
    )
  }
}
