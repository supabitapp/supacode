import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct SurfaceClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>
  var tabExists: @MainActor @Sendable (Worktree.ID, TerminalTabID) -> Bool
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
    case createTab(Worktree, spec: SurfaceSpec, id: UUID? = nil)
    case ensureInitialTab(Worktree, runSetupScriptIfNew: Bool, focusing: Bool)
    case closeFocusedTab(Worktree)
    case closeFocusedSurface(Worktree)
    case setImagePasteAgents(surfaceID: UUID, agents: Set<SkillAgent>)
    case selectTab(Worktree, tabID: TerminalTabID)
    case selectTabAtIndex(Worktree, index: Int)
    case focusSurface(Worktree, tabID: TerminalTabID, surfaceID: UUID, input: String? = nil)
    case splitSurface(
      Worktree, tabID: TerminalTabID, surfaceID: UUID, direction: SplitDirection,
      spec: SurfaceSpec, id: UUID? = nil)
    case destroyTab(Worktree, tabID: TerminalTabID)
    case destroySurface(Worktree, tabID: TerminalTabID, surfaceID: UUID)
    case beginTabRename(Worktree, tabID: TerminalTabID? = nil)
    case prune(keeping: Set<Worktree.ID>, protectingRepositoryIDs: Set<Repository.ID>)
    case setNotificationsEnabled(Bool)
    case setSelectedWorktreeID(Worktree.ID?)
    case refreshTabBarVisibility
    /// Terminal-kind commands. Exactly one arm per surface kind; the payload is
    /// a kind-scoped enum so the neutral surface never grows kind-specific verbs.
    case terminal(Worktree, TerminalSurfaceCommand)
  }

  enum Event: Equatable {
    case notificationReceived(
      worktreeID: Worktree.ID, surfaceID: UUID, title: String, body: String, isViewed: Bool)
    case notificationIndicatorChanged(count: Int)
    case tabCreated(worktreeID: Worktree.ID)
    case tabClosed(worktreeID: Worktree.ID)
    case focusChanged(worktreeID: Worktree.ID, surfaceID: UUID)
    case commandPaletteToggleRequested(worktreeID: Worktree.ID)
    /// Per-worktree projection emitted when surfaces / task-running / unseen / notifications drift.
    /// Routed by the parent into the matching `SidebarItemFeature` via the row's id.
    case worktreeProjectionChanged(Worktree.ID, WorktreeRowProjection)
    /// Per-tab projection emitted when a tab's surfaces, focused pane, or unread
    /// count drifts. Routed into the matching `TerminalTabFeature.State` via tab id.
    case tabProjectionChanged(worktreeID: Worktree.ID, WorktreeTabProjection)
    /// A tab was destroyed in the worktree state. Parent removes the matching
    /// `TerminalTabFeature.State` from `terminalTabs`.
    case tabRemoved(worktreeID: Worktree.ID, tabID: TerminalTabID)
    /// The entire `WorktreeSurfaceState` was torn down (worktree pruned).
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
    /// A surface split failed to materialize (target raced away, target was a
    /// blocking-script tab, or the layout insert threw). Lets a CLI completion
    /// ack report the failure instead of waiting for its timeout.
    case surfaceCreationFailed(worktreeID: Worktree.ID, attemptedID: UUID, message: String)
    /// Terminal-kind events. Mirror of `Command.terminal`: one arm per kind,
    /// kind-scoped payload.
    case terminal(TerminalSurfaceEvent)
  }
}

extension SurfaceClient: DependencyKey {
  static let liveValue = SurfaceClient(
    send: { _ in fatalError("SurfaceClient.send not configured") },
    events: { fatalError("SurfaceClient.events not configured") },
    tabExists: { _, _ in fatalError("SurfaceClient.tabExists not configured") },
    surfaceExists: { _, _, _ in fatalError("SurfaceClient.surfaceExists not configured") },
    surfaceExistsInWorktree: { _, _ in fatalError("SurfaceClient.surfaceExistsInWorktree not configured") },
    tabID: { _, _ in fatalError("SurfaceClient.tabID not configured") },
    selectedTabID: { _ in fatalError("SurfaceClient.selectedTabID not configured") },
    selectedSurfaceID: { _ in fatalError("SurfaceClient.selectedSurfaceID not configured") },
    latestUnreadNotification: { fatalError("SurfaceClient.latestUnreadNotification not configured") },
    markNotificationRead: { _, _ in fatalError("SurfaceClient.markNotificationRead not configured") },
    hasInflightBlockingScripts: { fatalError("SurfaceClient.hasInflightBlockingScripts not configured") },
    terminateAllSessions: { fatalError("SurfaceClient.terminateAllSessions not configured") },
    reapOrphanSessions: { _ in fatalError("SurfaceClient.reapOrphanSessions not configured") },
    saveLayoutsWithAgents: { _ in fatalError("SurfaceClient.saveLayoutsWithAgents not configured") }
  )

  static let testValue = SurfaceClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } },
    tabExists: unimplemented("SurfaceClient.tabExists", placeholder: true),
    surfaceExists: unimplemented("SurfaceClient.surfaceExists", placeholder: true),
    surfaceExistsInWorktree: unimplemented("SurfaceClient.surfaceExistsInWorktree", placeholder: true),
    tabID: unimplemented("SurfaceClient.tabID", placeholder: nil),
    selectedTabID: unimplemented("SurfaceClient.selectedTabID", placeholder: nil),
    selectedSurfaceID: unimplemented("SurfaceClient.selectedSurfaceID", placeholder: nil),
    latestUnreadNotification: unimplemented("SurfaceClient.latestUnreadNotification", placeholder: nil),
    markNotificationRead: unimplemented("SurfaceClient.markNotificationRead"),
    hasInflightBlockingScripts: unimplemented("SurfaceClient.hasInflightBlockingScripts", placeholder: false),
    terminateAllSessions: unimplemented("SurfaceClient.terminateAllSessions"),
    reapOrphanSessions: unimplemented("SurfaceClient.reapOrphanSessions"),
    saveLayoutsWithAgents: unimplemented("SurfaceClient.saveLayoutsWithAgents")
  )
}

extension DependencyValues {
  var surfaceClient: SurfaceClient {
    get { self[SurfaceClient.self] }
    set { self[SurfaceClient.self] = newValue }
  }
}
