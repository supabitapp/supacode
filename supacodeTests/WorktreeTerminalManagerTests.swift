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

  @Test func worktreeIDsWithUnseenNotificationsReturnsSortedByOldest() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let wt1 = makeWorktree(id: "/tmp/repo/wt-1", name: "wt-1")
    let wt2 = makeWorktree(id: "/tmp/repo/wt-2", name: "wt-2")
    let wt3 = makeWorktree(id: "/tmp/repo/wt-3", name: "wt-3")
    let state1 = manager.state(for: wt1)
    let state2 = manager.state(for: wt2)
    let state3 = manager.state(for: wt3)

    // Notifications are inserted at index 0 (newest first).
    // wt1: oldest unread at t=3000
    state1.notifications = [
      makeNotification(createdAt: Date(timeIntervalSince1970: 3000), isRead: false),
    ]
    // wt2: oldest unread at t=1000 (should come first)
    state2.notifications = [
      makeNotification(createdAt: Date(timeIntervalSince1970: 2000), isRead: false),
      makeNotification(createdAt: Date(timeIntervalSince1970: 1000), isRead: false),
    ]
    // wt3: oldest unread at t=2500
    state3.notifications = [
      makeNotification(createdAt: Date(timeIntervalSince1970: 2500), isRead: false),
    ]

    let result = manager.worktreeIDsWithUnseenNotifications()
    #expect(result.map(\.worktreeID) == [wt2.id, wt3.id, wt1.id])
    #expect(result[0].oldestUnreadDate == Date(timeIntervalSince1970: 1000))
    #expect(result[1].oldestUnreadDate == Date(timeIntervalSince1970: 2500))
    #expect(result[2].oldestUnreadDate == Date(timeIntervalSince1970: 3000))
  }

  @Test func worktreeIDsWithUnseenNotificationsReturnsEmptyWhenAllRead() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: true),
      makeNotification(isRead: true),
    ]

    let result = manager.worktreeIDsWithUnseenNotifications()
    #expect(result.isEmpty)
  }

  @Test func markAllNotificationsReadCommandMarksTargetWorktreeOnly() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let wt1 = makeWorktree(id: "/tmp/repo/wt-1", name: "wt-1")
    let wt2 = makeWorktree(id: "/tmp/repo/wt-2", name: "wt-2")
    let state1 = manager.state(for: wt1)
    let state2 = manager.state(for: wt2)

    state1.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: false),
    ]
    state2.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: false),
    ]

    manager.handleCommand(.markAllNotificationsRead(wt1.id))

    #expect(state1.notifications.map(\.isRead) == [true, true])
    #expect(state2.notifications.map(\.isRead) == [false, false])
    #expect(manager.hasUnseenNotifications(for: wt1.id) == false)
    #expect(manager.hasUnseenNotifications(for: wt2.id) == true)
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1", name: String = "wt-1") -> Worktree {
    Worktree(
      id: id,
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
    surfaceId: UUID = UUID(),
    createdAt: Date = .now,
    isRead: Bool
  ) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(
      surfaceId: surfaceId,
      title: "Title",
      body: "Body",
      createdAt: createdAt,
      isRead: isRead
    )
  }
}
