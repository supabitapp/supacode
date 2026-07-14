import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct TerminalClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>
  var tabExists: @MainActor @Sendable (Worktree.ID, TerminalTabID) -> Bool
  var tabCanRename: @MainActor @Sendable (Worktree.ID, TerminalTabID) -> Bool
  var surfaceExists: @MainActor @Sendable (Worktree.ID, TerminalTabID, UUID) -> Bool
  var surfaceExistsInWorktree: @MainActor @Sendable (Worktree.ID, UUID) -> Bool
  var tabID: @MainActor @Sendable (Worktree.ID, UUID) -> TerminalTabID?
  var selectedTabID: @MainActor @Sendable (Worktree.ID) -> TerminalTabID?
  /// Active surface in the selected tab. Lets the reducer capture the target
  /// synchronously before an async dispatch races against AppKit focus reshuffle
  /// (e.g. when a palette dismisses and the leftmost pane reclaims first responder).
  var selectedSurfaceID: @MainActor @Sendable (Worktree.ID) -> UUID?
  var latestUnreadNotification: @MainActor @Sendable () -> NotificationLocation?
  var markNotificationRead: @MainActor @Sendable (Worktree.ID, UUID) -> Void
  /// Blocking scripts (setup / archive / delete / run) bypass zmx and die
  /// with the app, so the auto-mode quit confirmation needs to know.
  var hasInflightBlockingScripts: @MainActor @Sendable () -> Bool
  /// Close every tracked surface and kill its zmx session in parallel.
  /// Awaited from the quit path so teardown completes before process exit.
  var terminateAllSessions: @MainActor @Sendable () async -> Void
  /// Kill `supa-*` sessions hosted by the daemon that no persisted layout
  /// references. Called at launch to clean up crash / force-quit orphans.
  var reapOrphanSessions: @MainActor @Sendable (_ knownSurfaceIDs: Set<UUID>) async -> Void
  /// Persist layouts with embedded per-surface agent records. Called on
  /// background and on quit so a force-quit between them caps staleness.
  var saveLayoutsWithAgents:
    @MainActor @Sendable (
      _ agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]
    ) -> Void

  enum Command: Equatable {
    case createTab(Worktree, runSetupScriptIfNew: Bool, id: UUID? = nil, title: String? = nil)
    case createTabWithInput(
      Worktree,
      input: String,
      runSetupScriptIfNew: Bool,
      id: UUID? = nil,
      title: String? = nil
    )
    case ensureInitialTab(Worktree, runSetupScriptIfNew: Bool, focusing: Bool)
    case stopRunScript(Worktree)
    case stopScript(Worktree, definitionID: UUID)
    case runBlockingScript(Worktree, kind: BlockingScriptKind, script: String)
    case closeFocusedTab(Worktree)
    case closeFocusedSurface(Worktree)
    case performBindingAction(Worktree, action: String)
    case performBindingActionOnSurface(Worktree, surfaceID: UUID, action: String)
    case setImagePasteAgents(surfaceID: UUID, agents: Set<SkillAgent>)
    case startSearch(Worktree)
    case searchSelection(Worktree)
    case navigateSearchNext(Worktree)
    case navigateSearchPrevious(Worktree)
    case endSearch(Worktree)
    case selectTab(Worktree, tabID: TerminalTabID)
    case selectTabAtIndex(Worktree, index: Int)
    case focusSurface(Worktree, tabID: TerminalTabID, surfaceID: UUID, input: String? = nil)
    case splitSurface(
      Worktree, tabID: TerminalTabID, surfaceID: UUID, direction: SplitDirection,
      input: String?, id: UUID? = nil)
    case destroyTab(Worktree, tabID: TerminalTabID)
    case destroySurface(Worktree, tabID: TerminalTabID, surfaceID: UUID)
    case beginTabRename(Worktree, tabID: TerminalTabID? = nil)
    case renameTab(Worktree, tabID: TerminalTabID, title: String)
    case prune(keeping: Set<Worktree.ID>, protectingRepositoryIDs: Set<Repository.ID>)
    case setNotificationsEnabled(Bool)
    case setSelectedWorktreeID(Worktree.ID?)
    case refreshTabBarVisibility
  }

  enum Event: Equatable {
    case notificationReceived(
      worktreeID: Worktree.ID, surfaceID: UUID, title: String, body: String, isViewed: Bool)
    case notificationIndicatorChanged(count: Int)
    case tabCreated(worktreeID: Worktree.ID)
    case tabClosed(worktreeID: Worktree.ID)
    case focusChanged(worktreeID: Worktree.ID, surfaceID: UUID)
    case taskStatusChanged(worktreeID: Worktree.ID, status: WorktreeTaskStatus)
    case blockingScriptCompleted(
      worktreeID: Worktree.ID, kind: BlockingScriptKind, exitCode: Int?, tabId: TerminalTabID?)
    case commandPaletteToggleRequested(worktreeID: Worktree.ID)
    case setupScriptConsumed(worktreeID: Worktree.ID)
    /// Per-worktree projection emitted when surfaces / task-running / unseen / notifications drift.
    /// Routed by the parent into the matching `SidebarItemFeature` via the row's id.
    case worktreeProjectionChanged(Worktree.ID, WorktreeRowProjection)
    /// Per-tab projection emitted when a tab's surfaces, focused pane, or unread
    /// count drifts. Routed into the matching `TerminalTabFeature.State` via tab id.
    case tabProjectionChanged(worktreeID: Worktree.ID, WorktreeTabProjection)
    /// A tab was destroyed in the worktree state. Parent removes the matching
    /// `TerminalTabFeature.State` from `terminalTabs`.
    case tabRemoved(worktreeID: Worktree.ID, tabID: TerminalTabID)
    /// A rename command settled. `applied` is false when the tab vanished or its
    /// title was locked, so the CLI ack reports the failure instead of ok.
    case tabRenamed(worktreeID: Worktree.ID, tabID: TerminalTabID, applied: Bool)
    /// The entire `WorktreeTerminalState` was torn down (worktree pruned).
    /// Parent drops any orphan `terminalTabs` entries and removed-tab FIFO
    /// records owned by this worktree so a fresh re-attach starts clean.
    case worktreeStateTornDown(worktreeID: Worktree.ID)
    /// A tab's stripe-progress display flipped. Routed into the matching
    /// `TerminalTabFeature.State.progressDisplay` so the stripe recolors.
    case tabProgressDisplayChanged(
      worktreeID: Worktree.ID, tabID: TerminalTabID, display: TerminalTabProgressDisplay?)
    /// Forwarded from the terminal manager when surfaces close (single or bulk).
    /// `AppFeature` translates this into `agentPresence(.surfaceClosed/surfacesClosed)`.
    /// `worktreeID` scopes the CLI close ack so a duplicate id elsewhere can't cross-resolve.
    case surfacesClosed(worktreeID: Worktree.ID, Set<UUID>)
    /// Forwarded from the terminal manager for hook events received over the socket.
    /// `AppFeature` translates this into `agentPresence(.hookEventReceived)`.
    case agentHookEventReceived(AgentHookEvent)
    /// Flips when the "any live surface anywhere" aggregate changes. Lets
    /// menu / focused-action gates read one Bool instead of iterating
    /// `sidebarItems` from a view body.
    case terminalHasAnySurfaceChanged(hasAny: Bool)
    /// A surface split failed to materialize (target raced away, target was a
    /// blocking-script tab, or the layout insert threw). Lets a CLI completion
    /// ack report the failure instead of waiting for its timeout.
    case surfaceCreationFailed(worktreeID: Worktree.ID, attemptedID: UUID, message: String)
  }
}

extension TerminalClient: DependencyKey {
  static let liveValue = TerminalClient(
    send: { _ in fatalError("TerminalClient.send not configured") },
    events: { fatalError("TerminalClient.events not configured") },
    tabExists: { _, _ in fatalError("TerminalClient.tabExists not configured") },
    tabCanRename: { _, _ in fatalError("TerminalClient.tabCanRename not configured") },
    surfaceExists: { _, _, _ in fatalError("TerminalClient.surfaceExists not configured") },
    surfaceExistsInWorktree: { _, _ in fatalError("TerminalClient.surfaceExistsInWorktree not configured") },
    tabID: { _, _ in fatalError("TerminalClient.tabID not configured") },
    selectedTabID: { _ in fatalError("TerminalClient.selectedTabID not configured") },
    selectedSurfaceID: { _ in fatalError("TerminalClient.selectedSurfaceID not configured") },
    latestUnreadNotification: { fatalError("TerminalClient.latestUnreadNotification not configured") },
    markNotificationRead: { _, _ in fatalError("TerminalClient.markNotificationRead not configured") },
    hasInflightBlockingScripts: { fatalError("TerminalClient.hasInflightBlockingScripts not configured") },
    terminateAllSessions: { fatalError("TerminalClient.terminateAllSessions not configured") },
    reapOrphanSessions: { _ in fatalError("TerminalClient.reapOrphanSessions not configured") },
    saveLayoutsWithAgents: { _ in fatalError("TerminalClient.saveLayoutsWithAgents not configured") }
  )

  static let testValue = TerminalClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } },
    tabExists: unimplemented("TerminalClient.tabExists", placeholder: true),
    tabCanRename: unimplemented("TerminalClient.tabCanRename", placeholder: true),
    surfaceExists: unimplemented("TerminalClient.surfaceExists", placeholder: true),
    surfaceExistsInWorktree: unimplemented("TerminalClient.surfaceExistsInWorktree", placeholder: true),
    tabID: unimplemented("TerminalClient.tabID", placeholder: nil),
    selectedTabID: unimplemented("TerminalClient.selectedTabID", placeholder: nil),
    selectedSurfaceID: unimplemented("TerminalClient.selectedSurfaceID", placeholder: nil),
    latestUnreadNotification: unimplemented("TerminalClient.latestUnreadNotification", placeholder: nil),
    markNotificationRead: unimplemented("TerminalClient.markNotificationRead"),
    hasInflightBlockingScripts: unimplemented("TerminalClient.hasInflightBlockingScripts", placeholder: false),
    terminateAllSessions: unimplemented("TerminalClient.terminateAllSessions"),
    reapOrphanSessions: unimplemented("TerminalClient.reapOrphanSessions"),
    saveLayoutsWithAgents: unimplemented("TerminalClient.saveLayoutsWithAgents")
  )
}

extension DependencyValues {
  var terminalClient: TerminalClient {
    get { self[TerminalClient.self] }
    set { self[TerminalClient.self] = newValue }
  }
}
