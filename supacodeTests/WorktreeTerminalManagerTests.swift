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

  @Test func setAgentHookIntegrationsCallsSynchronizer() {
    var calls: [(Bool, Bool)] = []
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      synchronizeAgentHooks: { claudeEnabled, codexEnabled in
        calls.append((claudeEnabled, codexEnabled))
      },
      agentHooksInstalled: { true },
      agentHooksBinPathProvider: { "/tmp/.supacode/hooks/bin" }
    )

    manager.handleCommand(.setAgentHookIntegrations(claudeEnabled: true, codexEnabled: false))
    manager.handleCommand(.setAgentHookIntegrations(claudeEnabled: false, codexEnabled: true))
    manager.handleCommand(.setAgentHookIntegrations(claudeEnabled: false, codexEnabled: false))

    #expect(calls.map(\.0) == [true, false, false])
    #expect(calls.map(\.1) == [false, true, false])
  }

  @Test func worktreeStatusIsRunningWhenAnyTabIsRunning() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let stream = manager.eventStream()

    _ = state.createTab()
    let firstSurfaceID = await nextFocusChangedSurfaceID(stream, worktreeID: worktree.id)
    _ = state.createTab()
    _ = await nextFocusChangedSurfaceID(stream, worktreeID: worktree.id)

    #expect(manager.focusedTaskStatus(for: worktree.id) == .idle)
    #expect(firstSurfaceID != nil)
    guard let firstSurfaceID else {
      return
    }

    #expect(state.setAgentWorkingStatus(surfaceID: firstSurfaceID, isWorking: true))
    #expect(manager.focusedTaskStatus(for: worktree.id) == .running)

    #expect(state.setAgentWorkingStatus(surfaceID: firstSurfaceID, isWorking: false))
    #expect(manager.focusedTaskStatus(for: worktree.id) == .idle)
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

  private func nextFocusChangedSurfaceID(
    _ stream: AsyncStream<TerminalClient.Event>,
    worktreeID: Worktree.ID
  ) async -> UUID? {
    let event = await nextEvent(stream) { event in
      if case .focusChanged(let eventWorktreeID, _) = event {
        return eventWorktreeID == worktreeID
      }
      return false
    }
    if case .focusChanged(_, let surfaceID)? = event {
      return surfaceID
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
