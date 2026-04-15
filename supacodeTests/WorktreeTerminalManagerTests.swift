import Dependencies
import Foundation
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

  @Test func socketBusyRoutesToDecodedWorktreeState() {
    let server = AgentHookSocketServer()
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), socketServer: server)
    let worktree = makeWorktree(id: "/tmp/repo/wt with spaces")

    manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf(),
      let encodedID = worktree.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else {
      Issue.record("Expected blocking script tab and socket server")
      return
    }

    server.onBusy?(encodedID, tabId.rawValue, surface.id, true)

    #expect(manager.taskStatus(for: worktree.id) == .running)
  }

  @Test func socketNotificationRoutesToDecodedWorktreeState() {
    withDependencies {
      $0.date.now = Date(timeIntervalSince1970: 1_234)
    } operation: {
      let server = AgentHookSocketServer()
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime(), socketServer: server)
      let worktree = makeWorktree(id: "/tmp/repo/wt with spaces")

      manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))

      guard let state = manager.stateIfExists(for: worktree.id),
        let tabId = state.tabManager.selectedTabId,
        let surface = state.splitTree(for: tabId).root?.leftmostLeaf(),
        let encodedID = worktree.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
      else {
        Issue.record("Expected blocking script tab and socket server")
        return
      }

      server.onNotification?(
        encodedID,
        tabId.rawValue,
        surface.id,
        AgentHookNotification(agent: "codex", event: "Stop", title: "Done", body: "All complete")
      )

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

    guard
      let tab1 = state.createTab(),
      let tab2 = state.createTab(focusing: false),
      let surface1 = state.splitTree(for: tab1).root?.leftmostLeaf(),
      let surface2 = state.splitTree(for: tab2).root?.leftmostLeaf()
    else {
      Issue.record("Expected tabs and surfaces")
      return
    }

    #expect(manager.taskStatus(for: worktree.id) == .idle)

    surface2.bridge.state.agentBusy = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    surface1.bridge.state.agentBusy = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    surface2.bridge.state.agentBusy = false
    #expect(manager.taskStatus(for: worktree.id) == .running)

    surface1.bridge.state.agentBusy = false
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

    let event = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event {
        return true
      }
      return false
    }

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: 0, tabId: secondTabId))
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

    #expect(event == .blockingScriptCompleted(worktreeID: worktree.id, kind: .archive, exitCode: nil, tabId: nil))
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

    #expect(manager.isBlockingScriptRunning(kind: .run, for: worktree.id) == false)

    manager.handleCommand(.runBlockingScript(worktree, kind: .run, script: "echo hi"))

    #expect(manager.isBlockingScriptRunning(kind: .run, for: worktree.id) == true)
  }

  @Test func stopRunScriptClosesRunTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()

    manager.handleCommand(.runBlockingScript(worktree, kind: .run, script: "sleep 10"))
    #expect(manager.isBlockingScriptRunning(kind: .run, for: worktree.id) == true)

    manager.handleCommand(.stopRunScript(worktree))
    #expect(manager.isBlockingScriptRunning(kind: .run, for: worktree.id) == false)
  }

  @Test func runScriptTabTitleResetsAfterSignalInterruption() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let stream = manager.eventStream()

    manager.handleCommand(.runBlockingScript(worktree, kind: .run, script: "sleep 10"))

    guard let state = manager.stateIfExists(for: worktree.id),
      let tabId = state.tabManager.selectedTabId,
      let surface = state.splitTree(for: tabId).root?.leftmostLeaf()
    else {
      Issue.record("Expected run script tab and surface")
      return
    }

    let tab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(tab?.title == "Run Script")
    #expect(tab?.isTitleLocked == true)
    #expect(tab?.tintColor == .green)

    // Simulate Ctrl+C (SIGINT = exit code 130).
    surface.bridge.onCommandFinished?(130)

    // Wait for completion event.
    _ = await nextEvent(stream) { event in
      if case .blockingScriptCompleted = event { return true }
      return false
    }

    let updatedTab = state.tabManager.tabs.first { $0.id == tabId }
    #expect(updatedTab?.isTitleLocked == false)
    #expect(updatedTab?.icon == nil)
    #expect(updatedTab?.tintColor == nil)
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
    #expect(updatedTab?.isTitleLocked == false)
    #expect(updatedTab?.icon == nil)
    #expect(updatedTab?.tintColor == nil)
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
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
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

    guard let tabs = manager.listTabs(worktreeID: worktree.id) else {
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

    guard let surfaces = manager.listSurfaces(worktreeID: worktree.id, tabID: tabID.rawValue.uuidString) else {
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
    #expect(manager.listSurfaces(worktreeID: worktree.id, tabID: "not-a-uuid") == nil)
  }

  private func makeWorktree(id: String = "/tmp/repo/wt-1") -> Worktree {
    let name = URL(fileURLWithPath: id).lastPathComponent
    return Worktree(
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
    isRead: Bool
  ) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(
      surfaceId: surfaceId,
      title: "Title",
      body: "Body",
      isRead: isRead
    )
  }

  private func makeLayoutSnapshot() -> TerminalLayoutSnapshot {
    TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: nil,
          title: "Terminal 1",
          icon: nil,
          tintColor: nil,
          layout: .leaf(
            TerminalLayoutSnapshot.SurfaceSnapshot(
              id: nil,
              workingDirectory: "/tmp/repo/wt-1"
            )
          ),
          focusedLeafIndex: 0
        ),
      ],
      selectedTabIndex: 0
    )
  }
}
