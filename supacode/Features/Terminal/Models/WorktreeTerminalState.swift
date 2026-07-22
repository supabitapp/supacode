import AppKit
import CoreGraphics
import Dependencies
import Foundation
import GhosttyKit
import IdentifiedCollections
import Observation
import Sharing
import SupacodeSettingsShared

private let blockingScriptLogger = SupaLogger("BlockingScript")
private let layoutLogger = SupaLogger("Layout")
private let terminalStateLogger = SupaLogger("Terminal")

/// Per-tab projection emitted by `WorktreeTerminalState` whenever a tab's
/// surfaces, focus, unread count, or progress display drifts. The parent
/// reducer applies this to the matching `TerminalTabFeature.State` so the
/// tab-bar leaf observes a per-tab store instead of worktree-wide state.
struct WorktreeTabProjection: Equatable, Sendable {
  let tabID: TerminalTabID
  let surfaceIDs: [UUID]
  let activeSurfaceID: UUID?
  let unseenNotificationCount: Int
  let isSplitZoomed: Bool
  /// Per-tab repaint epoch, bumped on same-UUID surface replacement so the view rebuilds.
  let surfaceGeneration: Int
  /// True while the tab's surfaces are hibernated (torn down, zmx sessions kept).
  let isDormant: Bool

  init(
    tabID: TerminalTabID,
    surfaceIDs: [UUID],
    activeSurfaceID: UUID?,
    unseenNotificationCount: Int,
    isSplitZoomed: Bool = false,
    surfaceGeneration: Int = 0,
    isDormant: Bool = false,
  ) {
    self.tabID = tabID
    self.surfaceIDs = surfaceIDs
    self.activeSurfaceID = activeSurfaceID
    self.unseenNotificationCount = unseenNotificationCount
    self.isSplitZoomed = isSplitZoomed
    self.surfaceGeneration = surfaceGeneration
    self.isDormant = isDormant
  }
}

@MainActor
@Observable
final class WorktreeTerminalState {
  struct SurfaceActivity: Equatable {
    let isVisible: Bool
    let isFocused: Bool
  }
  /// Why a close needs confirming. Nil where the close needs none.
  enum CloseConfirmationReason: Equatable {
    case runningProcess
    /// A hibernated tab has no live surface to ask, so nothing was checked.
    case dormant

    var message: String {
      switch self {
      case .runningProcess: "One or more terminal processes are still running. Closing will terminate them."
      case .dormant: "This terminal is asleep. Closing will end its background session."
      }
    }
  }

  struct PendingCloseConfirmation: Equatable {
    enum Target: Equatable {
      case surface(UUID)
      case tabs([TerminalTabID])
    }

    let target: Target
    /// Carried from the raise site: re-deriving it at render time would flip the
    /// copy if a process reaches its prompt while the alert is up.
    let reason: CloseConfirmationReason

    // Copy is identical for surface and tab closes, so it lives on the type.
    static let title = "Close Terminal?"
    static let actionTitle = "Close Terminal"

    var message: String { reason.message }

    static func surface(_ surfaceID: UUID, reason: CloseConfirmationReason = .runningProcess) -> Self {
      Self(target: .surface(surfaceID), reason: reason)
    }

    static func tabs(_ tabIDs: [TerminalTabID], reason: CloseConfirmationReason = .runningProcess) -> Self {
      Self(target: .tabs(tabIDs), reason: reason)
    }
  }

  private struct SurfaceLaunchMetadata {
    let usesZmx: Bool
    let context: ghostty_surface_context_e
  }

  /// Frozen state of a hibernated tab: layout snapshot (pwd + agent records
  /// freeze at teardown), focused leaf, and zoom. In-memory only; the dormant
  /// surface UUIDs still reach layouts.json via `captureLayoutSnapshot`.
  struct DormantTabLayout {
    let layout: TerminalLayoutSnapshot.LayoutNode
    /// Indexes `layout.leafSurfaceIDs`; consumers must bounds-check.
    let focusedLeafIndex: Int?
    let zoomedSurfaceID: UUID?
  }

  let tabManager: TerminalTabManager
  private let runtime: GhosttyRuntime
  @ObservationIgnored private let splitPreserveZoomOnNavigation: () -> Bool
  @ObservationIgnored private let surfaceNeedsCloseConfirmation: (GhosttySurfaceView) -> Bool
  @ObservationIgnored private let surfaceBindingActionPerformer: (GhosttySurfaceView, String) -> Void
  private let worktree: Worktree
  @ObservationIgnored
  @SharedReader private var repositorySettings: RepositorySettings
  // Observed: any mutation re-renders `WorktreeTerminalTabsView`. Mutate only
  // from user-initiated structural changes; per-surface churn must stay on
  // `surfaceStates` / `WorktreeTabProjection` to keep agent storms cold.
  private var trees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
  /// Hibernated tabs keyed by tab id. Invariant: keys ⊆ `tabManager` tab ids.
  /// `@ObservationIgnored` since the tab bar reads dormancy via
  /// `WorktreeTabProjection`, not this dict. The `didSet` keeps the session
  /// watchers in lock-step with the dormant leaf set.
  @ObservationIgnored private(set) var dormantTabLayouts: [TerminalTabID: DormantTabLayout] = [:] {
    didSet { syncDormantSessionWatchers() }
  }
  /// Passive tail readers over dormant sessions' zmx sockets, one per dormant
  /// leaf. While a tab is dark no surface parses its pty stream, so these recover
  /// OSC-borne signals (notifications, presence, titles).
  @ObservationIgnored private let dormantSessionWatchers = ZmxSessionWatcherRegistry()
  /// True while this state's worktree is the selected one. Only the selected tab
  /// of the selected worktree renders, so a tab is "hidden" (hibernation
  /// candidate) unless it is that one tab. Fed by `setWorktreeSelected`.
  @ObservationIgnored private var isWorktreeSelected = false
  /// Beta opt-in gate, cached so the hot schedule / fire paths don't re-read the
  /// shared file. Seeded at init, kept in sync by `applyHibernationEnabled`.
  @ObservationIgnored private var isHibernationEnabled = false
  /// Per-tab grace timers. A hidden tab hibernates once its timer fires; the
  /// timer is a plain `Task` owned here so teardown drains the dict.
  @ObservationIgnored private var hibernationTimers: [TerminalTabID: Task<Void, Never>] = [:]
  /// Tabs whose ineligible-deferral was already logged, so a permanently
  /// ineligible hidden tab re-firing every grace window doesn't spam the log.
  /// Cleared when the tab becomes eligible, visible, hibernates, or closes.
  @ObservationIgnored private var loggedIneligibleDeferralTabs: Set<TerminalTabID> = []
  /// Drives the grace timers. Injected from the manager's clock so a TestClock
  /// advances everything in tests.
  @ObservationIgnored private let hibernationClock: any Clock<Duration>
  /// Frozen agent records per surface, read at teardown to freeze presence badges
  /// into the dormant layout. Wired by the manager to its `currentAgentsBySurface`
  /// source.
  @ObservationIgnored var hibernationAgentsBySurface: (() -> [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]])?
  /// Logged once per state instance if the agent-records closure is unwired.
  /// Production always wires it, so a nil means broken wiring, not "no agents".
  @ObservationIgnored private var hasLoggedMissingAgentsClosure = false
  @ObservationIgnored private var surfaces: [UUID: GhosttySurfaceView] = [:]
  // `usesZmx` + `context` retained per surface so an unexpected zmx exit can recreate it on reattach.
  @ObservationIgnored private var surfaceLaunchMetadata: [UUID: SurfaceLaunchMetadata] = [:]
  // Surfaces the user explicitly closed, so an unexpected zmx exit isn't mistaken for one and reattached.
  @ObservationIgnored private var pendingExplicitSurfaceCloseIDs: Set<UUID> = []
  // Explicit closes that skip the confirmation alert (programmatic destroys already gated upstream).
  @ObservationIgnored private var bypassCloseConfirmationSurfaceIDs: Set<UUID> = []
  @ObservationIgnored private var surfaceGenerationByTab: [TerminalTabID: Int] = [:]
  @ObservationIgnored private var focusedSurfaceIdByTab: [TerminalTabID: UUID] = [:]
  /// Per-tab projection cache. `WorktreeTerminalState` recomputes from `trees`
  /// / `notifications` / `focusedSurfaceIdByTab`, compares to the cached value,
  /// and fires `onTabProjectionChanged` only on diff. The manager forwards the
  /// projection upstream so `TerminalTabFeature.State` mirrors it.
  @ObservationIgnored private var lastTabProjections: [TerminalTabID: WorktreeTabProjection] = [:]
  /// Per-tab progress-display cache. Tracks the focused-surface or worst-of
  /// aggregate so `onTabProgressDisplayChanged` only fires on diff.
  @ObservationIgnored private var lastTabProgressDisplays: [TerminalTabID: TerminalTabProgressDisplay?] = [:]
  var socketPath: String?
  private(set) var shouldHideTabBar = false
  private(set) var pendingCloseConfirmation: PendingCloseConfirmation?
  // Every mutation schedules a coalesced row-projection emit so the TCA
  // mirror of running scripts reconciles from this single source of truth (#573).
  private var blockingScripts: [TerminalTabID: BlockingScriptKind] = [:] {
    didSet { scheduleRunningScriptsProjectionEmit() }
  }
  /// Coalesces the per-mutation `didSet` into one next-tick emit so
  /// mid-operation states (e.g. the supersede clear-then-record in
  /// `runBlockingScript`) never reach TCA.
  @ObservationIgnored private var pendingRunningScriptsProjectionEmit = false
  private var blockingScriptLaunchDirectories: [TerminalTabID: URL] = [:]
  private var lastBlockingScriptTabByKind: [BlockingScriptKind: TerminalTabID] = [:]
  private var pendingSetupScript: Bool
  /// Sticky after first attempt so a reselect after closing every tab doesn't auto-recreate.
  /// Intentionally never reset; resetting would re-arm the bug.
  @ObservationIgnored private(set) var hasAttemptedInitialTab = false
  @ObservationIgnored var pendingLayoutSnapshot: TerminalLayoutSnapshot?
  private var lastReportedTaskStatus: WorktreeTaskStatus?
  private var lastEmittedFocusSurfaceId: UUID?
  private var lastWindowIsKey: Bool?
  private var lastWindowIsVisible: Bool?
  /// Raw notification log. `@ObservationIgnored` so per-tab notification ticks
  /// flow through `TerminalTabState.unseenNotificationCount` projections instead
  /// of invalidating every leaf in the worktree.
  @ObservationIgnored private(set) var notifications: [WorktreeTerminalNotification] = []
  /// Per-surface Supacode observables. `@ObservationIgnored` so dict churn
  /// doesn't invalidate every leaf; the per-instance `hasUnseenNotification` is
  /// the observed signal.
  @ObservationIgnored private(set) var surfaceStates: [UUID: WorktreeSurfaceState] = [:]
  var notificationsEnabled = true
  @ObservationIgnored @Dependency(\.date.now) private var now
  @ObservationIgnored @Dependency(\.zmxClient) private var zmxClient
  @ObservationIgnored @Dependency(\.analyticsClient) private var analyticsClient
  @ObservationIgnored @Dependency(\.continuousClock) private var clock
  /// When a custom (hook / OSC 3008) notification last committed per surface.
  /// Stored as a monotonic instant so the suppression window and the OSC-9 hold
  /// share one clock source and can't desync on an NTP step / manual clock change.
  private var lastCustomNotificationAt: [UUID: any InstantProtocol<Duration>] = [:]
  /// Agent OSC 9 notifications held to see if a custom notification supersedes them.
  private var pendingAgentOSCNotifications: [UUID: Task<Void, Never>] = [:]
  /// How long after a custom notification the agent's own OSC 9 is suppressed.
  /// Split from `oscHoldWindow` so tuning the suppression side cannot silently
  /// change the hold side.
  private static let oscSuppressionAfterCustom: TimeInterval = 0.5
  /// How long the agent's own OSC 9 is held before firing, waiting for a custom
  /// notification to supersede it. Covers the socket-vs-inline-stream arrival skew.
  private static let oscHoldWindow: TimeInterval = 0.5
  /// Monotonic gap between two instants from the same clock. Opens the existentials
  /// so the suppression window can compare instants of the type-erased clock.
  private static func elapsed(
    from start: any InstantProtocol<Duration>,
    to end: any InstantProtocol<Duration>
  ) -> Duration {
    func gap<I: InstantProtocol>(_ start: I, _ end: any InstantProtocol<Duration>) -> Duration
    where I.Duration == Duration {
      guard let end = end as? I else {
        // Fail OPEN: a type mismatch must not pin the dedupe window true forever.
        assertionFailure("clock instant type mismatch")
        return .seconds(Self.oscSuppressionAfterCustom + 1)
      }
      return start.duration(to: end)
    }
    return gap(start, end)
  }
  #if DEBUG
    var debugCustomNotificationTimestampCount: Int { lastCustomNotificationAt.count }
    var debugPendingOSCCount: Int { pendingAgentOSCNotifications.count }
  #endif
  /// Unread state reads the per-surface counters, not the capped log, so cap
  /// trimming never clears an indicator; only reading or dismissing does.
  var hasUnseenNotification: Bool {
    surfaceStates.values.contains { $0.unseenNotificationCount > 0 }
  }

  /// Total outstanding unread notifications across every surface in the worktree.
  var totalUnseenNotificationCount: Int {
    surfaceStates.values.reduce(0) { $0 + $1.unseenNotificationCount }
  }

  func hasUnseenNotification(forSurfaceID surfaceID: UUID) -> Bool {
    (surfaceStates[surfaceID]?.unseenNotificationCount ?? 0) > 0
  }

  func hasUnseenNotification(forTabID tabID: TerminalTabID) -> Bool {
    unseenNotificationCount(forTabID: tabID) > 0
  }

  /// Sum of the tab's surfaces' outstanding unread counters. Dormant-aware:
  /// `surfaceIDs(inTab:)` unions a hibernated tab's frozen leaves, whose
  /// `surfaceStates` counters survive hibernation, so a dark tab keeps its count.
  func unseenNotificationCount(forTabID tabID: TerminalTabID) -> Int {
    unseenNotificationCount(inSurfaces: surfaceIDs(inTab: tabID))
  }

  /// Returns the most recent unread notification in this worktree, or nil.
  func latestUnreadNotification() -> WorktreeTerminalNotification? {
    unreadNotifications().first
  }

  /// Returns all unread notifications in this worktree sorted newest first.
  func unreadNotifications() -> [WorktreeTerminalNotification] {
    notifications.filter { !$0.isRead }.sorted { $0.createdAt > $1.createdAt }
  }

  var isSelected: () -> Bool = { false }
  var onNotificationReceived: ((UUID, String, String, Bool) -> Void)?
  var onNotificationIndicatorChanged: (() -> Void)?
  var onTabCreated: (() -> Void)?
  var onTabClosed: (() -> Void)?
  /// Fires when the user renames a tab. Manager forwards to the layout-persist
  /// sink so a custom title survives relaunch without waiting for quit.
  var onTabRenamed: (() -> Void)?
  var onFocusChanged: ((UUID) -> Void)?
  // Fired when the currently focused surface's background color changes (OSC 11).
  var onFocusedSurfaceColorChanged: (() -> Void)?
  var onTaskStatusChanged: ((WorktreeTaskStatus) -> Void)?
  var onBlockingScriptCompleted: ((BlockingScriptKind, Int?, TerminalTabID?) -> Void)?
  /// Fires (coalesced, next tick) on any `blockingScripts` mutation; the
  /// manager re-emits the Equatable-diffed row projection so TCA reconciles
  /// to terminal truth.
  var onRunningScriptsChanged: (() -> Void)?
  var onCommandPaletteToggle: (() -> Void)?
  var onSetupScriptConsumed: (() -> Void)?
  /// Forwarded to the manager so it can emit a `surfacesClosed` event into TCA.
  var onSurfacesClosed: ((Set<UUID>) -> Void)?
  /// Fires when a tab hibernates. Manager cancels the debounced idle hooks for
  /// those surfaces WITHOUT the presence drop `onSurfacesClosed` would trigger.
  var onSurfacesHibernated: ((Set<UUID>) -> Void)?
  /// Fires when the worktree's dormant composition changes (a tab hibernates or
  /// wakes). Manager re-emits the row projection so the sidebar sleep marker
  /// tracks `allTabsDormant`; nothing else re-emits on these transitions.
  var onDormancyChanged: (() -> Void)?
  /// Forwarded to the manager's `dispatchHookEvent` so an OSC-sourced presence
  /// event joins the same funnel as the socket path (idle-debounce, badge).
  var onAgentHookEvent: ((AgentHookEvent) -> Void)?
  /// Fires when a tab's per-tab projection (surfaces / focus / unseen count)
  /// drifts. Manager forwards into `TerminalTabFeature.State` via
  /// `tabProjectionChanged` so the leaf observes a per-tab store.
  var onTabProjectionChanged: ((WorktreeTabProjection) -> Void)?
  /// Fires when a tab is fully removed (closeTab, closeAll). Manager forwards
  /// so the parent reducer drops the corresponding `TerminalTabFeature.State`.
  var onTabRemoved: ((TerminalTabID) -> Void)?
  /// Fires when a tab's stripe-progress display drifts. Computed off the
  /// active surface (selected tab) or worst-of-all (unselected tabs) so the
  /// stripe stays in lock-step with focus and OSC-9 progress mutations.
  var onTabProgressDisplayChanged: ((TerminalTabID, TerminalTabProgressDisplay?) -> Void)?

  init(
    runtime: GhosttyRuntime,
    worktree: Worktree,
    runSetupScript: Bool = false,
    splitPreserveZoomOnNavigation: (() -> Bool)? = nil,
    hibernationClock: (any Clock<Duration>)? = nil,
    surfaceNeedsCloseConfirmation: ((GhosttySurfaceView) -> Bool)? = nil,
    surfaceBindingActionPerformer: ((GhosttySurfaceView, String) -> Void)? = nil
  ) {
    self.runtime = runtime
    self.splitPreserveZoomOnNavigation = splitPreserveZoomOnNavigation ?? { runtime.splitPreserveZoomOnNavigation() }
    self.surfaceNeedsCloseConfirmation = surfaceNeedsCloseConfirmation ?? { $0.needsCloseConfirmation }
    self.surfaceBindingActionPerformer = surfaceBindingActionPerformer ?? { $0.performBindingAction($1) }
    self.worktree = worktree
    self.pendingSetupScript = runSetupScript
    self.hibernationClock = hibernationClock ?? ContinuousClock()
    self.tabManager = TerminalTabManager()
    _repositorySettings = SharedReader(
      wrappedValue: RepositorySettings.default,
      .repositorySettings(worktree.repositoryRootURL, host: worktree.host)
    )
    // Route every selection write through the single visibility choke point.
    tabManager.onSelectedTabChanged = { [weak self] in self?.refreshTabVisibility() }
    // Route dormant-session OSC signals into the notification / presence handlers.
    dormantSessionWatchers.onOSCSequence = { [weak self] surfaceID, sequence in
      self?.handleDormantOSCSequence(surfaceID: surfaceID, sequence: sequence)
    }
    // Pre-hide the tab bar before the first tab is created to
    // avoid a visible flash. updateShouldHideTabBar() handles
    // the steady state once tabs exist.
    @Shared(.settingsFile) var settingsFile
    self.shouldHideTabBar = settingsFile.global.hideSingleTabBar
    self.isHibernationEnabled = settingsFile.global.terminalHibernationEnabled
  }

  var taskStatus: WorktreeTaskStatus {
    trees.keys.contains(where: { isTabBusy($0) }) ? .running : .idle
  }

  private func isTabBusy(_ tabId: TerminalTabID) -> Bool {
    guard let tree = trees[tabId] else { return false }
    return tree.leaves().contains { isRunningProgressState($0.bridge.state.progressState) }
  }

  /// Per-row projection consumed by `SidebarItemFeature.terminalProjectionChanged`.
  /// `isProgressBusy` reflects Ghostty progress state only; AppFeature merges
  /// agent activity downstream of this event.
  func currentProjection() -> WorktreeRowProjection {
    WorktreeRowProjection(
      surfaceIDs: allSurfaceIDs,
      isProgressBusy: taskStatus == .running,
      hasUnseenNotifications: hasUnseenNotification,
      notifications: IdentifiedArray(uniqueElements: notifications),
      unseenSurfaces: unseenSurfacesProjection(),
      runningScripts: runningScriptsProjection(),
      allTabsDormant: allTabsDormant,
    )
  }

  /// Per-surface outstanding unread counters (count > 0). Feeds the inspector's
  /// synthesized "go to the surface" rows for unread the cap pruned. Sorted so
  /// non-deterministic `trees` iteration order can't churn the projection.
  private func unseenSurfacesProjection() -> [WorktreeUnseenSurface] {
    allSurfaceIDs.compactMap { surfaceID in
      let count = surfaceStates[surfaceID]?.unseenNotificationCount ?? 0
      guard count > 0 else { return nil }
      return WorktreeUnseenSurface(id: surfaceID, count: count)
    }
    .sorted { $0.id.uuidString < $1.id.uuidString }
  }

  /// Order-stable snapshot of the user scripts currently tracked in
  /// `blockingScripts`; lifecycle kinds (archive / delete) carry no
  /// definition ID and are excluded by construction.
  private func runningScriptsProjection() -> IdentifiedArrayOf<SidebarItemFeature.State.RunningScript> {
    var scripts: IdentifiedArrayOf<SidebarItemFeature.State.RunningScript> = []
    let definitions = blockingScripts.values
      .compactMap { kind -> ScriptDefinition? in
        guard case .script(let definition) = kind else { return nil }
        return definition
      }
      .sorted { $0.id.uuidString < $1.id.uuidString }
    for definition in definitions {
      scripts.updateOrAppend(.init(id: definition.id, tint: definition.resolvedTintColor))
    }
    return scripts
  }

  private func scheduleRunningScriptsProjectionEmit() {
    guard !pendingRunningScriptsProjectionEmit else { return }
    pendingRunningScriptsProjectionEmit = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.pendingRunningScriptsProjectionEmit = false
      self.onRunningScriptsChanged?()
    }
  }

  func isBlockingScriptRunning(kind: BlockingScriptKind) -> Bool {
    blockingScripts.values.contains(kind)
  }

  var hasInflightBlockingScripts: Bool {
    !blockingScripts.isEmpty
  }

  private func updateShouldHideTabBar() {
    @Shared(.settingsFile) var settingsFile
    // Force the bar visible on a split-zoomed single tab so the dismiss-zoom indicator has somewhere to live.
    let wouldHide = settingsFile.global.hideSingleTabBar && tabManager.tabs.count == 1
    let newValue = wouldHide && !trees.values.contains { $0.zoomed != nil }
    guard shouldHideTabBar != newValue else { return }
    shouldHideTabBar = newValue
  }

  func refreshTabBarVisibility() {
    updateShouldHideTabBar()
  }

  func isSplitZoomed(forTabID tabID: TerminalTabID) -> Bool {
    trees[tabID]?.zoomed != nil
  }

  func dismissSplitZoom(for tabID: TerminalTabID) {
    guard let tree = trees[tabID], let zoomed = tree.zoomed else { return }
    let previouslyZoomedSurface = zoomed.leftmostLeaf()
    updateTree(tree.settingZoomed(nil), for: tabID)
    focusSurface(previouslyZoomedSurface, in: tabID)
  }

  func ensureInitialTab(focusing: Bool) {
    guard !hasAttemptedInitialTab else { return }
    hasAttemptedInitialTab = true
    guard tabManager.tabs.isEmpty else { return }

    if let snapshot = pendingLayoutSnapshot {
      pendingLayoutSnapshot = nil
      restoreFromSnapshot(snapshot, focusing: focusing)
      return
    }
    let setupScript = pendingSetupScript ? repositorySettings.setupScript : nil
    _ = createTab(focusing: focusing, setupScript: setupScript)
  }

  @discardableResult
  func createTab(
    focusing: Bool = true,
    setupScript: String? = nil,
    initialInput: String? = nil,
    inheritingFromSurfaceId: UUID? = nil,
    tabID: UUID? = nil,
    customTitle: String? = nil
  ) -> TerminalTabID? {
    let context: ghostty_surface_context_e =
      tabManager.tabs.isEmpty
      ? GHOSTTY_SURFACE_CONTEXT_WINDOW
      : GHOSTTY_SURFACE_CONTEXT_TAB
    let resolvedInheritanceSurfaceId = inheritingFromSurfaceId ?? currentFocusedSurfaceId()
    let title = "\(worktree.name) \(nextTabIndex())"
    let setupInput = setupScriptInput(setupScript: setupScript)
    let commandInput = initialInput.flatMap { BlockingScriptRunner.makeCommandInput(script: $0) }
    let resolvedInput: String?
    switch (setupInput, commandInput) {
    case (nil, nil):
      resolvedInput = nil
    case (let setupInput?, nil):
      resolvedInput = setupInput
    case (nil, let commandInput?):
      resolvedInput = commandInput
    case (let setupInput?, let commandInput?):
      resolvedInput = setupInput + commandInput
    }
    let shouldConsumeSetupScript = pendingSetupScript && setupScript != nil
    if shouldConsumeSetupScript {
      pendingSetupScript = false
    }
    let tabId = createTab(
      TabCreation(
        title: title,
        icon: nil,
        isTitleLocked: false,
        customTitle: customTitle,
        command: nil,
        initialInput: resolvedInput,
        focusing: focusing,
        inheritingFromSurfaceId: resolvedInheritanceSurfaceId,
        context: context,
        tabID: tabID,
      )
    )
    if shouldConsumeSetupScript, tabId != nil {
      onSetupScriptConsumed?()
    }
    return tabId
  }

  /// Stops a single user-defined script identified by its definition ID.
  @discardableResult
  func stopScript(definitionID: UUID) -> Bool {
    guard
      let tabId = blockingScripts.first(where: { $0.value.scriptDefinitionID == definitionID })?.key
    else { return false }
    closeTab(tabId)
    return true
  }

  /// Stops all running `.run`-kind scripts. Intentionally excludes
  /// non-run scripts (test, deploy, etc.) because the Stop action
  /// (Cmd+.) is the semantic counterpart of Run, not a "stop
  /// everything" command. Other kinds are stopped individually
  /// via the script menu or command palette.
  @discardableResult
  func stopRunScripts() -> Bool {
    let runTabIds = blockingScripts.filter { $0.value.isRunKind }.map(\.key)
    guard !runTabIds.isEmpty else { return false }
    for tabId in runTabIds {
      closeTab(tabId)
    }
    return true
  }

  /// Returns the set of script definition IDs currently running.
  func runningScriptDefinitionIDs() -> Set<UUID> {
    Set(blockingScripts.values.compactMap(\.scriptDefinitionID))
  }

  /// Checks whether a user-defined script with the given definition ID is running.
  func isScriptRunning(definitionID: UUID) -> Bool {
    blockingScripts.values.contains(where: { $0.scriptDefinitionID == definitionID })
  }

  @discardableResult
  func runBlockingScript(kind: BlockingScriptKind, _ script: String) -> TerminalTabID? {
    // A re-run of an already-tracked user script is a duplicate request, not a
    // restart: keep the running instance (#573). Lifecycle kinds (archive /
    // delete) keep their replace-on-rerun semantics.
    if case .script = kind,
      let active = blockingScripts.first(where: { $0.value == kind })?.key
    {
      // The early return skips the `blockingScripts` didSet, so emit explicitly
      // to unstick a row whose projection was shed or stripped.
      scheduleRunningScriptsProjectionEmit()
      return active
    }
    // Resolve the surface command per host. A remote worktree runs the same
    // OSC 133 framing on the host over ssh (no local temp files, no zmx wrap),
    // so the script executes on the remote and not on a same-path local dir.
    let command: String
    let initialInput: String?
    let launchDirectory: URL?
    if let host = worktree.host {
      guard
        let remote = BlockingScriptRunner.remoteCommand(
          host: host,
          script: script,
          remoteWorktreePath: worktree.workingDirectory.path(percentEncoded: false),
          environment: blockingScriptEnvironment(for: kind)
        )
      else {
        reportBlockingScriptLaunchFailure(kind, "Failed to build remote \(kind.tabTitle) for worktree \(worktree.id)")
        return nil
      }
      command = remote
      initialInput = nil
      launchDirectory = nil
    } else {
      let launch: BlockingScriptRunner.LaunchArtifacts
      do {
        guard let prepared = try blockingScriptLaunch(script) else {
          reportBlockingScriptLaunchFailure(
            kind, "Failed to prepare \(kind.tabTitle) for worktree \(worktree.id): empty script")
          return nil
        }
        launch = prepared
      } catch {
        reportBlockingScriptLaunchFailure(
          kind, "Failed to prepare \(kind.tabTitle) for worktree \(worktree.id): \(error)")
        return nil
      }
      command = defaultShellPath()
      initialInput = launch.commandInput
      launchDirectory = launch.directoryURL
    }
    // Close any previous tab of the same kind: lingering from a completed or
    // cancelled run, or (lifecycle kinds only) still active. Clear tracking
    // state first so closeTab doesn't fire a premature completion callback.
    if let active = blockingScripts.first(where: { $0.value == kind })?.key {
      blockingScripts.removeValue(forKey: active)
      lastBlockingScriptTabByKind.removeValue(forKey: kind)
      closeTab(active)
    } else if let lingering = lastBlockingScriptTabByKind.removeValue(forKey: kind) {
      closeTab(lingering)
    }
    let tabId = createTab(
      TabCreation(
        title: kind.tabTitle,
        icon: kind.tabIcon,
        isTitleLocked: true,
        tintColor: kind.tabColor,
        command: command,
        initialInput: initialInput,
        focusing: true,
        inheritingFromSurfaceId: currentFocusedSurfaceId(),
        context: GHOSTTY_SURFACE_CONTEXT_TAB,
        tabID: nil,
        isBlockingScript: true,
        blockingScriptKind: kind,
        bypassZmx: true,
      )
    )
    guard let tabId else {
      if let launchDirectory {
        cleanupBlockingScriptLaunchDirectory(at: launchDirectory)
      }
      reportBlockingScriptLaunchFailure(kind, "Failed to create \(kind.tabTitle) tab for worktree \(worktree.id)")
      return nil
    }
    if let launchDirectory {
      blockingScriptLaunchDirectories[tabId] = launchDirectory
    }
    lastBlockingScriptTabByKind[kind] = tabId
    tabManager.updateDirty(tabId, isDirty: true)
    emitTaskStatusIfChanged()

    blockingScriptLogger.info("Started \(kind.tabTitle) for worktree \(worktree.id)")
    return tabId
  }

  /// Report a launch that never produced a tab: exit 1 and no tab id, so the
  /// caller gets an alert and a completion instead of a silent nil (#573).
  private func reportBlockingScriptLaunchFailure(_ kind: BlockingScriptKind, _ message: String) {
    blockingScriptLogger.warning(message)
    onBlockingScriptCompleted?(kind, 1, nil)
  }

  private struct TabCreation: Equatable {
    let title: String
    let icon: String?
    let isTitleLocked: Bool
    var customTitle: String?
    var tintColor: RepositoryColor?
    let command: String?
    let initialInput: String?
    let focusing: Bool
    let inheritingFromSurfaceId: UUID?
    let context: ghostty_surface_context_e
    let tabID: UUID?
    /// Marks the tab as a blocking-script tab so the no-split / no-rename
    /// / readonly-after-completion guardrails apply.
    var isBlockingScript: Bool = false
    /// The blocking-script kind, recorded into `blockingScripts` before the
    /// surface is built so `surfaceEnvironment` can emit its env markers.
    var blockingScriptKind: BlockingScriptKind?
    /// Skip zmx session wrapping for transactional surfaces (blocking setup/archive/delete scripts)
    /// that must die with the app rather than survive.
    var bypassZmx: Bool = false
  }

  private func createTab(_ creation: TabCreation) -> TerminalTabID? {
    let tabId = tabManager.createTab(
      title: creation.title,
      customTitle: creation.customTitle,
      icon: creation.icon,
      isTitleLocked: creation.isTitleLocked,
      tintColor: creation.tintColor,
      isBlockingScript: creation.isBlockingScript,
      id: creation.tabID,
    )
    // Record the kind before the surface is built so `surfaceEnvironment`
    // can read it when emitting the blocking-script env markers.
    if let blockingScriptKind = creation.blockingScriptKind {
      blockingScripts[tabId] = blockingScriptKind
    }
    // When a tab ID is explicitly provided, use it as the initial surface ID
    // so the CLI can reference the surface immediately after creation.
    let tree = splitTree(
      for: tabId,
      inheritingFromSurfaceId: creation.inheritingFromSurfaceId,
      command: creation.command,
      initialInput: creation.initialInput,
      context: creation.context,
      surfaceID: creation.tabID != nil ? tabId.rawValue : nil,
      bypassZmx: creation.bypassZmx
    )
    updateShouldHideTabBar()
    if creation.focusing, let surface = tree.root?.leftmostLeaf() {
      focusSurface(surface, in: tabId)
    }
    onTabCreated?()
    return tabId
  }

  func listSurfaces(tabID: TerminalTabID) -> [[String: String]] {
    let focusedID = focusedSurfaceIdByTab[tabID]
    return surfaces.compactMap { surfaceID, _ in
      guard self.tabID(containing: surfaceID) == tabID else { return nil }
      var entry = ["id": surfaceID.uuidString]
      if surfaceID == focusedID { entry["focused"] = "1" }
      return entry
    }.sorted { ($0["id"] ?? "") < ($1["id"] ?? "") }
  }

  func hasTab(_ tabId: TerminalTabID) -> Bool {
    tabManager.tabs.contains(where: { $0.id == tabId })
  }

  /// Surface IDs in a single tab, resolving through the live tree or, when the
  /// tab is hibernated, its frozen dormant leaves so validation / focus / split
  /// paths still address a dark pane. Empty if the tab does not exist.
  func surfaceIDs(inTab tabId: TerminalTabID) -> [UUID] {
    if let tree = trees[tabId] {
      return tree.leaves().map(\.id)
    }
    if let dormant = dormantTabLayouts[tabId] {
      return dormant.layout.leafSurfaceIDs
    }
    return []
  }

  /// All surface IDs across every tab in this worktree state, including the
  /// frozen leaves of hibernated tabs so teardown / reaper / prune stay total.
  var allSurfaceIDs: [UUID] {
    trees.values.flatMap { $0.leaves().map(\.id) } + dormantLeafSurfaceIDs
  }

  /// Frozen leaves across every hibernated tab in this worktree state.
  private var dormantLeafSurfaceIDs: [UUID] {
    dormantTabLayouts.values.flatMap { $0.layout.leafSurfaceIDs }
  }

  /// Host of a remote worktree, nil for local. Every surface in this state
  /// shares it, so teardown paths can target the host-side zmx sessions.
  var remoteHost: RemoteHost? {
    worktree.host
  }

  // Standardized to match `loadFailuresByID` keys (built from `standardizedFileURL.path`)
  // so prune protection lines up.
  var repositoryID: Repository.ID {
    switch worktree.location.repositoryLocation {
    case .local(let url):
      RepositoryID(url.standardizedFileURL.path(percentEncoded: false))
    case .remote:
      worktree.location.repositoryLocation.id
    }
  }

  /// O(1) emptiness check that skips the split-tree walk in `allSurfaceIDs`.
  /// Counts hibernated tabs so a fully-dormant app still shows the
  /// quit-and-terminate confirmation and tears their sessions down.
  var hasAnySurface: Bool { !surfaces.isEmpty || !dormantTabLayouts.isEmpty }

  /// True when the worktree has at least one tab and every tab is hibernated.
  /// Drives the sidebar row's sleep marker; a single live tab keeps it false.
  var allTabsDormant: Bool {
    guard !tabManager.tabs.isEmpty else { return false }
    return tabManager.tabs.allSatisfy { dormantTabLayouts[$0.id] != nil }
  }

  /// Whether a surface lives in this tab, live or frozen in its dormant leaves,
  /// so validation accepts a dormant pane before the wake-first command runs.
  func hasSurface(_ surfaceID: UUID, in tabId: TerminalTabID) -> Bool {
    if trees[tabId]?.find(id: surfaceID) != nil { return true }
    return dormantTabLayouts[tabId]?.layout.leafSurfaceIDs.contains(surfaceID) == true
  }

  /// Checks whether a surface UUID exists anywhere in the worktree (across all
  /// tabs), including the frozen leaves of hibernated tabs so validation accepts
  /// a dormant pane and duplicate-id checks catch it.
  func hasSurfaceAnywhere(_ surfaceID: UUID) -> Bool {
    isKnownSurface(surfaceID)
  }

  func selectTab(_ tabId: TerminalTabID) {
    guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
      terminalStateLogger.warning("selectTab: tab \(tabId.rawValue) not found in worktree \(worktree.id).")
      return
    }
    let previousSelectedTabId = tabManager.selectedTabId
    tabManager.selectTab(tabId)
    focusSurface(in: tabId)
    // Re-emit the stripe progress for both old and new selected tabs: their
    // "focused vs aggregate" branch just flipped.
    if let previousSelectedTabId, previousSelectedTabId != tabId {
      emitTabProgressDisplay(for: previousSelectedTabId)
    }
    emitTabProgressDisplay(for: tabId)
    emitTaskStatusIfChanged()
  }

  func focusSelectedTab() {
    guard let tabId = tabManager.selectedTabId else { return }
    focusSurface(in: tabId)
  }

  func focusAndInsertText(_ text: String) {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else {
      terminalStateLogger.warning("focusAndInsertText: no focused surface")
      return
    }
    terminalStateLogger.info("focusAndInsertText: sending \(text.count) chars to surface \(focusedId)")
    surface.requestFocus()
    surface.sendText(text)
  }

  func syncFocus(windowIsKey: Bool, windowIsVisible: Bool) {
    lastWindowIsKey = windowIsKey
    lastWindowIsVisible = windowIsVisible
    applySurfaceActivity()
  }

  private func applySurfaceActivity() {
    let selectedTabId = tabManager.selectedTabId
    var surfaceToFocus: GhosttySurfaceView?
    for (tabId, tree) in trees {
      let focusedId = focusedSurfaceIdByTab[tabId]
      let isSelectedTab = (tabId == selectedTabId)
      let visibleSurfaceIDs = Set(tree.visibleLeaves().map(\.id))
      for surface in tree.leaves() {
        let activity = Self.surfaceActivity(
          isSurfaceVisibleInTree: visibleSurfaceIDs.contains(surface.id),
          isSelectedTab: isSelectedTab,
          windowIsVisible: lastWindowIsVisible == true,
          windowIsKey: lastWindowIsKey == true,
          focusedSurfaceID: focusedId,
          surfaceID: surface.id
        )
        surface.setOcclusion(activity.isVisible)
        surface.focusDidChange(activity.isFocused)
        if activity.isFocused {
          surfaceToFocus = surface
        }
      }
    }
    if let surfaceToFocus, surfaceToFocus.window?.firstResponder is GhosttySurfaceView {
      surfaceToFocus.window?.makeFirstResponder(surfaceToFocus)
    }
  }

  static func surfaceActivity(
    isSurfaceVisibleInTree: Bool = true,
    isSelectedTab: Bool,
    windowIsVisible: Bool,
    windowIsKey: Bool,
    focusedSurfaceID: UUID?,
    surfaceID: UUID
  ) -> SurfaceActivity {
    let isVisible = isSurfaceVisibleInTree && isSelectedTab && windowIsVisible
    let isFocused = isVisible && windowIsKey && focusedSurfaceID == surfaceID
    return SurfaceActivity(isVisible: isVisible, isFocused: isFocused)
  }

  @discardableResult
  func focusSurface(id: UUID) -> Bool {
    guard let tabId = tabID(containing: id) else {
      terminalStateLogger.warning("focusSurface: surface \(id) not found in worktree \(worktree.id).")
      return false
    }
    // Wake first: a dormant leaf has no entry in `surfaces` to focus.
    wakeTab(tabId)
    tabManager.selectTab(tabId)
    guard let surface = surfaces[id] else {
      // A partial wake reaped this leaf, so land on whatever the tab rebuilt.
      terminalStateLogger.error("focusSurface: surface \(id) missing after waking tab \(tabId.rawValue).")
      focusSurface(in: tabId)
      return false
    }
    focusSurface(surface, in: tabId)
    return true
  }

  @discardableResult
  func closeFocusedTab() -> Bool {
    guard let tabId = tabManager.selectedTabId else { return false }
    return requestCloseTab(tabId)
  }

  @discardableResult
  func closeFocusedSurface() -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else {
      return false
    }
    requestExplicitSurfaceClose(surface)
    return true
  }

  @discardableResult
  func closeSurface(id surfaceID: UUID) -> Bool {
    guard let surface = surfaces[surfaceID] else {
      terminalStateLogger.warning(
        "closeSurface: surface \(surfaceID) not found. Known: \(surfaces.keys.map(\.uuidString))")
      return false
    }
    // Programmatic destroys (deeplink/CLI) resolve confirmation upstream, so skip the alert here.
    requestExplicitSurfaceClose(surface, confirm: false)
    return true
  }

  private func requestExplicitSurfaceClose(_ surface: GhosttySurfaceView, confirm: Bool = true) {
    if !confirm {
      bypassCloseConfirmationSurfaceIDs.insert(surface.id)
    }
    performBindingAction("close_surface", on: surface)
  }

  @discardableResult
  func performBindingActionOnFocusedSurface(_ action: String) -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else {
      return false
    }
    performBindingAction(action, on: surface)
    return true
  }

  @discardableResult
  func performBindingAction(_ action: String, onSurfaceID surfaceID: UUID) -> Bool {
    guard let surface = surfaces[surfaceID] else { return false }
    performBindingAction(action, on: surface)
    return true
  }

  @discardableResult
  func setImagePasteAgents(_ agents: Set<SkillAgent>, onSurfaceID surfaceID: UUID) -> Bool {
    guard let surface = surfaces[surfaceID] else { return false }
    surface.imagePasteAgents = agents
    return true
  }

  private func performBindingAction(_ action: String, on surface: GhosttySurfaceView) {
    if action == "close_surface" {
      pendingExplicitSurfaceCloseIDs.insert(surface.id)
    }
    surfaceBindingActionPerformer(surface, action)
  }

  @discardableResult
  func navigateSearchOnFocusedSurface(_ direction: GhosttySearchDirection) -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else {
      return false
    }
    surface.navigateSearch(direction)
    return true
  }

  @discardableResult
  func requestCloseTab(_ tabId: TerminalTabID) -> Bool {
    requestCloseTabs([tabId])
  }

  @discardableResult
  func requestCloseOtherTabs(keeping tabId: TerminalTabID) -> Bool {
    requestCloseTabs(tabManager.tabs.map(\.id).filter { $0 != tabId })
  }

  @discardableResult
  func requestCloseTabsToRight(of tabId: TerminalTabID) -> Bool {
    guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return false }
    return requestCloseTabs(Array(tabManager.tabs.dropFirst(index + 1).map(\.id)))
  }

  @discardableResult
  func requestCloseAllTabs() -> Bool {
    requestCloseTabs(tabManager.tabs.map(\.id))
  }

  func confirmPendingClose() {
    guard let pending = pendingCloseConfirmation else { return }
    confirmPendingClose(pending)
  }

  // Takes the target explicitly so the alert confirms against the captured
  // payload, never a published value a concurrent dismissal may have cleared.
  func confirmPendingClose(_ pending: PendingCloseConfirmation) {
    pendingCloseConfirmation = nil
    switch pending.target {
    case .surface(let surfaceID):
      guard let surface = surfaces[surfaceID] else {
        terminalStateLogger.debug("confirmPendingClose: surface \(surfaceID) already gone.")
        return
      }
      completeCloseRequest(for: surface)
    case .tabs(let tabIDs):
      for tabId in tabIDs {
        closeTab(tabId)
      }
    }
  }

  func cancelPendingClose() {
    guard let pending = pendingCloseConfirmation else { return }
    cancelPendingClose(pending)
  }

  // Takes the target explicitly so a dismissal that clears the published value
  // first can't strip the surface's explicit-close flag out from under cancel.
  func cancelPendingClose(_ pending: PendingCloseConfirmation) {
    if case .surface(let surfaceID) = pending.target {
      pendingExplicitSurfaceCloseIDs.remove(surfaceID)
    }
    pendingCloseConfirmation = nil
  }

  // The alert binding writes nil back on dismissal; the buttons own the real
  // transitions, so this only clears without any cancel side effects.
  func dismissPendingCloseConfirmation() {
    pendingCloseConfirmation = nil
  }

  private func requestCloseTabs(_ requestedTabIDs: [TerminalTabID]) -> Bool {
    let existingTabIDs = requestedTabIDs.filter { requested in
      tabManager.tabs.contains(where: { $0.id == requested })
    }
    guard !existingTabIDs.isEmpty else { return false }
    guard pendingCloseConfirmation == nil else { return true }

    @Shared(.settingsFile) var settingsFile
    let reasons = existingTabIDs.compactMap(closeConfirmationReason)
    guard settingsFile.global.confirmCloseSurface, !reasons.isEmpty else {
      for tabId in existingTabIDs {
        closeTab(tabId)
      }
      return true
    }
    // A live process outranks dormancy, so the copy names what was actually found.
    pendingCloseConfirmation = .tabs(
      existingTabIDs, reason: reasons.contains(.runningProcess) ? .runningProcess : .dormant)
    return true
  }

  /// Nil when the tab closes without asking.
  private func closeConfirmationReason(_ tabId: TerminalTabID) -> CloseConfirmationReason? {
    guard !isBlockingScriptCompleted(tabId) else { return nil }
    // A woken surface reports "not at a prompt" until the zmx replay lands, so a
    // dormant tab always confirms.
    guard dormantTabLayouts[tabId] == nil else { return .dormant }
    guard let tree = trees[tabId], tree.leaves().contains(where: surfaceNeedsCloseConfirmation) else {
      return nil
    }
    return .runningProcess
  }

  private func removeFromPendingClose(tabId: TerminalTabID) {
    guard case .tabs(let tabIDs) = pendingCloseConfirmation?.target,
      let reason = pendingCloseConfirmation?.reason
    else { return }
    let remaining = tabIDs.filter { $0 != tabId }
    pendingCloseConfirmation = remaining.isEmpty ? nil : .tabs(remaining, reason: reason)
  }

  func closeTab(_ tabId: TerminalTabID) {
    cancelHibernationTimer(for: tabId)
    removeFromPendingClose(tabId: tabId)
    let closedBlockingKind = blockingScripts.removeValue(forKey: tabId)
    cleanupBlockingScriptLaunchDirectory(for: tabId)
    // Clear lingering tab tracking for completed or non-blocking tabs.
    for (kind, tracked) in lastBlockingScriptTabByKind where tracked == tabId {
      lastBlockingScriptTabByKind.removeValue(forKey: kind)
    }
    removeTree(for: tabId)
    removeDormantTab(tabId)
    tabManager.closeTab(tabId)
    updateShouldHideTabBar()
    if let selected = tabManager.selectedTabId {
      focusSurface(in: selected)
    } else {
      lastEmittedFocusSurfaceId = nil
    }
    emitTaskStatusIfChanged()

    if let closedBlockingKind {
      blockingScriptLogger.info("\(closedBlockingKind.tabTitle) cancelled (tab closed)")
      onBlockingScriptCompleted?(closedBlockingKind, nil, nil)
    }
    onTabClosed?()
  }

  /// Persists the new title (or its removal on an empty commit) incrementally.
  /// Returns false when the rename did not apply, which also skips the write.
  @discardableResult
  func renameTab(_ tabId: TerminalTabID, title: String) -> Bool {
    guard tabManager.setCustomTitle(tabId, title: title) else { return false }
    onTabRenamed?()
    return true
  }

  func splitTree(
    for tabId: TerminalTabID,
    inheritingFromSurfaceId: UUID? = nil,
    command: String? = nil,
    initialInput: String? = nil,
    context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_TAB,
    surfaceID: UUID? = nil,
    bypassZmx: Bool = false
  ) -> SplitTree<GhosttySurfaceView> {
    if let existing = trees[tabId] {
      return existing
    }
    // A stale render of a just-closed tab (removal transition) must not lazily
    // resurrect it: the replacement surface would be invisible, unclosable, and
    // hold its local and host zmx sessions alive.
    guard hasTab(tabId) else { return SplitTree() }
    // Wake a hibernated tab before minting a fresh surface: rebuild from the
    // frozen layout with the ORIGINAL UUIDs so `zmx attach` reattaches.
    if let dormant = dormantTabLayouts.removeValue(forKey: tabId) {
      // `removeValue` fires the didSet, stopping the woken leaves' watchers; a
      // live surface now parses their streams.
      let expectedLeafIDs = dormant.layout.leafSurfaceIDs
      let tree = wakeDormantTab(tabId, dormant: dormant)
      // A partial rebuild (an `inserting` throw in `createRestorationSplit`) can
      // strand frozen leaves that end up neither live nor dormant; kill their
      // orphaned zmx sessions so they don't linger until the next-launch reap.
      let orphanedLeafIDs = Self.orphanedWakeLeafIDs(
        expected: expectedLeafIDs, rebuilt: Set(tree.leaves().map(\.id)))
      if !orphanedLeafIDs.isEmpty {
        let count = orphanedLeafIDs.count
        terminalStateLogger.error(
          "Partial wake for tab \(tabId.rawValue): \(count) leaf/leaves failed to rebuild; requesting session kill."
        )
        killZmxSessions(forSurfaceIDs: orphanedLeafIDs, includeRemote: true)
      }
      // A wake from a non-selection mutation leaves the tab hidden; re-arm here
      // since the selection choke point never fired.
      refreshTabVisibility()
      onDormancyChanged?()
      return tree
    }
    let surface = createSurface(
      tabId: tabId,
      command: command,
      initialInput: initialInput,
      inheritingFromSurfaceId: inheritingFromSurfaceId,
      context: context,
      surfaceID: surfaceID,
      bypassZmx: bypassZmx
    )
    let tree = SplitTree(view: surface)
    setTree(tree, for: tabId)
    setFocusedSurface(surface.id, for: tabId)
    // A tab created while hidden (e.g. background worktree) has its tree only
    // now, after the selection choke point already ran; schedule its timer.
    refreshTabVisibility()
    return tree
  }

  func performSplitAction(
    _ action: GhosttySplitAction,
    for surfaceID: UUID,
    newSurfaceID: UUID? = nil,
    initialInput: String? = nil
  ) -> Bool {
    guard let tabId = tabID(containing: surfaceID), var tree = trees[tabId] else {
      return false
    }
    guard let targetNode = tree.find(id: surfaceID) else { return false }
    guard let targetSurface = surfaces[surfaceID] else { return false }

    switch action {
    case .newSplit(let direction):
      // Splits would leak a zmx-wrapped sibling into a transactional tab.
      // Refuse before allocating a surface so the tab stays single-pane.
      if tabManager.isBlockingScript(tabId) {
        return false
      }
      let newSurface = createSurface(
        tabId: tabId,
        initialInput: initialInput,
        inheritingFromSurfaceId: surfaceID,
        context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
        surfaceID: newSurfaceID,
      )
      do {
        let newTree = try tree.inserting(
          view: newSurface,
          at: targetSurface,
          direction: mapSplitDirection(direction)
        )
        updateTree(newTree, for: tabId)
        focusSurface(newSurface, in: tabId)
        return true
      } catch {
        terminalStateLogger.warning(
          "performSplitAction: failed to insert split for surface \(surfaceID) in tab \(tabId.rawValue): \(error)")
        newSurface.closeSurface()
        discardSurfaceBookkeeping(for: newSurface.id)
        return false
      }

    case .gotoSplit(let direction):
      let focusDirection = mapFocusDirection(direction)
      guard let nextSurface = tree.focusTarget(for: focusDirection, from: targetNode) else {
        return false
      }
      if tree.zoomed != nil {
        if splitPreserveZoomOnNavigation() {
          let nextNode = tree.root?.node(view: nextSurface)
          tree = tree.settingZoomed(nextNode)
        } else {
          tree = tree.settingZoomed(nil)
        }
        updateTree(tree, for: tabId)
      }
      focusSurface(nextSurface, in: tabId)
      syncFocusIfNeeded()
      return true

    case .resizeSplit(let direction, let amount):
      let spatialDirection = mapResizeDirection(direction)
      do {
        let newTree = try tree.resizing(
          node: targetNode,
          by: amount,
          in: spatialDirection,
          with: CGRect(origin: .zero, size: tree.viewBounds())
        )
        updateTree(newTree, for: tabId)
        return true
      } catch {
        return false
      }

    case .equalizeSplits:
      updateTree(tree.equalized(), for: tabId)
      return true

    case .toggleSplitZoom:
      guard tree.isSplit else { return false }
      let newZoomed = (tree.zoomed == targetNode) ? nil : targetNode
      updateTree(tree.settingZoomed(newZoomed), for: tabId)
      focusSurface(targetSurface, in: tabId)
      return true
    }
  }

  func performSplitOperation(_ operation: TerminalSplitTreeView.Operation, in tabId: TerminalTabID) {
    guard var tree = trees[tabId] else { return }
    // Drag-to-drop surfaces from other tabs into a blocking-script tab would
    // introduce a zmx-wrapped sibling. Same rationale as the `newSplit` guard.
    if case .drop = operation, tabManager.isBlockingScript(tabId) { return }

    switch operation {
    case .resize(let node, let ratio):
      let resizedNode = node.resizing(to: ratio)
      do {
        tree = try tree.replacing(node: node, with: resizedNode)
        updateTree(tree, for: tabId)
      } catch {
        return
      }

    case .drop(let payloadId, let destinationId, let zone):
      guard let payload = surfaces[payloadId] else { return }
      guard let destination = surfaces[destinationId] else { return }
      if payload === destination { return }
      guard let sourceNode = tree.root?.node(view: payload) else { return }
      let treeWithoutSource = tree.removing(sourceNode)
      if treeWithoutSource.isEmpty { return }
      do {
        let newTree = try treeWithoutSource.inserting(
          view: payload,
          at: destination,
          direction: mapDropZone(zone)
        )
        updateTree(newTree, for: tabId)
        focusSurface(payload, in: tabId)
      } catch {
        return
      }

    case .equalize:
      updateTree(tree.equalized(), for: tabId)
    }
  }

  func setAllSurfacesOccluded() {
    for surface in surfaces.values {
      surface.setOcclusion(false)
      surface.focusDidChange(false)
    }
  }

  /// Drops the focus-emit dedupe so coming back to this worktree re-emits even
  /// though the focused surface never changed. The manager pairs this with its
  /// own coalescing entry; both have to forget, or the states parked on that
  /// surface never clear.
  func forgetLastEmittedFocus() {
    lastEmittedFocusSurfaceId = nil
  }

  func closeAllSurfaces() {
    // Drain the grace timers first so nothing fires into a torn-down state.
    cancelAllHibernationTimers()
    cancelPendingClose()
    let closingSurfaces = Array(surfaces.values)
    let closingSurfaceIDs = closingSurfaces.map(\.id)
    for surface in closingSurfaces {
      surface.closeSurface()
    }
    for surfaceID in closingSurfaceIDs {
      discardSurfaceBookkeeping(for: surfaceID)
    }
    cleanupBlockingScriptLaunchDirectories()
    // Drain hibernated tabs: the presence drop must include their frozen leaves
    // so prune / quit clear the badges. Callers already kill these sessions off
    // the dormant-inclusive `allSurfaceIDs` snapshot, so no kill happens here.
    let dormantSurfaceIDs = dormantLeafSurfaceIDs
    // Drop the surface states hibernation preserved for their unseen counters so
    // a full teardown doesn't strand the worktree dot / total.
    for surfaceID in dormantSurfaceIDs {
      discardDormantLeafSurfaceState(for: surfaceID)
    }
    // `removeAll` fires the `dormantTabLayouts` didSet, reconciling the watchers
    // to an empty set (stopping every one).
    dormantTabLayouts.removeAll()
    trees.removeAll()
    surfaceGenerationByTab.removeAll()
    focusedSurfaceIdByTab.removeAll()
    onSurfacesClosed?(Set(closingSurfaceIDs).union(dormantSurfaceIDs))
    let pendingKinds = Set(blockingScripts.values)
    blockingScripts.removeAll()
    lastBlockingScriptTabByKind.removeAll()

    for kind in pendingKinds {
      onBlockingScriptCompleted?(kind, nil, nil)
    }
    tabManager.closeAll()
    // Drain per-tab caches and notify so `TerminalsFeature.State.terminalTabs`
    // entries don't leak for tabs in a torn-down worktree (#289 follow-up).
    let removedTabIDs = Array(lastTabProjections.keys)
    lastTabProjections.removeAll()
    lastTabProgressDisplays.removeAll()
    for tabID in removedTabIDs {
      onTabRemoved?(tabID)
    }
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    if !enabled {
      markAllNotificationsRead()
    }
  }

  func clearNotificationIndicator() {
    markAllNotificationsRead()
  }

  func markAllNotificationsRead() {
    for index in notifications.indices {
      notifications[index].isRead = true
    }
    clearAllUnseenCounters()
    emitAllTabProjections()
    emitNotificationStateChanged()
  }

  func markNotificationsRead(forSurfaceID surfaceID: UUID) {
    for index in notifications.indices where notifications[index].surfaceID == surfaceID {
      notifications[index].isRead = true
    }
    // Focusing the surface clears its outstanding unread, including any that the
    // cap already trimmed out of the visible log.
    setUnseenCount(surfaceID, to: 0)
    if let tabId = tabID(containing: surfaceID) {
      emitTabProjection(for: tabId)
    }
    emitNotificationStateChanged()
  }

  /// Marks a single notification as read, leaving others untouched.
  func markNotificationRead(id: WorktreeTerminalNotification.ID) {
    guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
    guard !notifications[index].isRead else { return }
    let surfaceID = notifications[index].surfaceID
    notifications[index].isRead = true
    decrementUnseenCount(surfaceID)
    if let tabId = tabID(containing: surfaceID) {
      emitTabProjection(for: tabId)
    }
    emitNotificationStateChanged()
  }

  func dismissNotification(_ notificationID: WorktreeTerminalNotification.ID) {
    guard let dismissed = notifications.first(where: { $0.id == notificationID }) else { return }
    notifications.removeAll { $0.id == notificationID }
    if !dismissed.isRead {
      decrementUnseenCount(dismissed.surfaceID)
    }
    if let tabId = tabID(containing: dismissed.surfaceID) {
      emitTabProjection(for: tabId)
    }
    emitNotificationStateChanged()
  }

  func dismissAllNotifications() {
    notifications.removeAll()
    clearAllUnseenCounters()
    emitAllTabProjections()
    emitNotificationStateChanged()
  }

  private func incrementUnseenCount(_ surfaceID: UUID) {
    guard let state = surfaceStates[surfaceID] else { return }
    state.unseenNotificationCount += 1
  }

  private func decrementUnseenCount(_ surfaceID: UUID) {
    guard let state = surfaceStates[surfaceID], state.unseenNotificationCount > 0 else { return }
    state.unseenNotificationCount -= 1
  }

  private func setUnseenCount(_ surfaceID: UUID, to value: Int) {
    guard let state = surfaceStates[surfaceID] else { return }
    guard state.unseenNotificationCount != value else { return }
    state.unseenNotificationCount = value
  }

  private func clearAllUnseenCounters() {
    for state in surfaceStates.values where state.unseenNotificationCount != 0 {
      state.unseenNotificationCount = 0
    }
  }

  /// Rebuilds every surface's unseen counter from the surviving unread log.
  private func rebuildUnseenCounters() {
    clearAllUnseenCounters()
    for notification in notifications where !notification.isRead {
      incrementUnseenCount(notification.surfaceID)
    }
  }

  // MARK: - Layout Snapshot

  /// Capture a layout snapshot, optionally embedding per-surface agent
  /// presence records. The caller (AppDelegate's `applicationWillTerminate`
  /// path) reads `AppFeature.State.agentPresence.records` and converts it
  /// into the per-surface dict before invoking this so agents persist
  /// atomically with their owning surface and vanish on prune.
  func captureLayoutSnapshot(
    agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]? = nil
  ) -> TerminalLayoutSnapshot? {
    guard !tabManager.tabs.isEmpty else { return nil }
    var tabSnapshots: [TerminalLayoutSnapshot.TabSnapshot] = []
    for tab in tabManager.tabs {
      // Blocking-script tabs die with the app; persisting them would resurrect a dead session.
      if tab.isBlockingScript { continue }
      let layout: TerminalLayoutSnapshot.LayoutNode
      let focusedLeafIndex: Int
      if let tree = trees[tab.id], let root = tree.root {
        layout = captureLayoutNode(root, agentsBySurface: agentsBySurface ?? [:])
        let leaves = root.leaves()
        let focusedId = focusedSurfaceIdByTab[tab.id]
        focusedLeafIndex =
          focusedId.flatMap { id in
            leaves.firstIndex(where: { $0.id == id })
          } ?? 0
      } else if let dormant = dormantTabLayouts[tab.id] {
        // A hibernated tab has no tree; refresh its frozen leaf agents from the
        // live map so a busy->idle drift during dormancy still reaches disk.
        layout = refreshDormantAgents(dormant.layout, agentsBySurface: agentsBySurface)
        focusedLeafIndex = dormant.focusedLeafIndex ?? 0
      } else {
        layoutLogger.warning("Skipping tab \(tab.id.rawValue) during snapshot capture (no tree)")
        continue
      }
      tabSnapshots.append(
        TerminalLayoutSnapshot.TabSnapshot(
          id: tab.id.rawValue,
          title: tab.title,
          customTitle: tab.customTitle,
          icon: tab.icon,
          tintColor: tab.tintColor,
          layout: layout,
          focusedLeafIndex: focusedLeafIndex,
        )
      )
    }
    guard !tabSnapshots.isEmpty else { return nil }
    // Walk against the surviving tabs (post-filter), preferring the nearest
    // left neighbor when the originally-selected tab was excluded. If every
    // left neighbor is also excluded, fall through to the leftmost surviving
    // tab. Computing against `tabManager.tabs` would land on the wrong
    // neighbor for `[A, B(blocking, selected), C]`.
    let selectedIndex: Int = {
      guard let selectedID = tabManager.selectedTabId else { return 0 }
      if let direct = tabSnapshots.firstIndex(where: { $0.id == selectedID.rawValue }) {
        return direct
      }
      guard let originalIndex = tabManager.tabs.firstIndex(where: { $0.id == selectedID }) else {
        return 0
      }
      for index in stride(from: originalIndex - 1, through: 0, by: -1) {
        let candidate = tabManager.tabs[index]
        if let surviving = tabSnapshots.firstIndex(where: { $0.id == candidate.id.rawValue }) {
          return surviving
        }
      }
      return 0
    }()
    return TerminalLayoutSnapshot(tabs: tabSnapshots, selectedTabIndex: selectedIndex)
  }

  private func captureLayoutNode(
    _ node: SplitTree<GhosttySurfaceView>.Node,
    agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]
  ) -> TerminalLayoutSnapshot.LayoutNode {
    switch node {
    case .leaf(let view):
      return .leaf(
        TerminalLayoutSnapshot.SurfaceSnapshot(
          id: view.id,
          workingDirectory: view.bridge.state.pwd,
          agents: agentsBySurface[view.id]
        )
      )
    case .split(let split):
      let direction: SplitDirection =
        switch split.direction {
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
      return .split(
        TerminalLayoutSnapshot.SplitSnapshot(
          direction: direction,
          ratio: split.ratio,
          left: captureLayoutNode(split.left, agentsBySurface: agentsBySurface),
          right: captureLayoutNode(split.right, agentsBySurface: agentsBySurface)
        )
      )
    }
  }

  /// Rebuild a dormant layout's leaf agent records against `agentsBySurface`.
  /// A nil map (no source wired) keeps frozen records unchanged. A non-nil map is
  /// authoritative: a present leaf takes the refreshed records, an absent leaf is
  /// cleared (its agent ended while dormant).
  private func refreshDormantAgents(
    _ node: TerminalLayoutSnapshot.LayoutNode,
    agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]?
  ) -> TerminalLayoutSnapshot.LayoutNode {
    guard let agentsBySurface else { return node }
    switch node {
    case .leaf(let surface):
      guard let id = surface.id else { return node }
      return .leaf(
        TerminalLayoutSnapshot.SurfaceSnapshot(
          id: id,
          workingDirectory: surface.workingDirectory,
          agents: agentsBySurface[id] ?? []
        )
      )
    case .split(let split):
      return .split(
        TerminalLayoutSnapshot.SplitSnapshot(
          direction: split.direction,
          ratio: split.ratio,
          left: refreshDormantAgents(split.left, agentsBySurface: agentsBySurface),
          right: refreshDormantAgents(split.right, agentsBySurface: agentsBySurface)
        )
      )
    }
  }

  private func restoreFromSnapshot(_ snapshot: TerminalLayoutSnapshot, focusing: Bool) {
    guard !snapshot.tabs.isEmpty else {
      layoutLogger.warning("Attempted to restore empty layout snapshot, skipping restoration.")
      return
    }

    // Skip setup script when restoring a saved layout.
    pendingSetupScript = false

    for (index, tabSnapshot) in snapshot.tabs.enumerated() {
      let context: ghostty_surface_context_e =
        index == 0 ? GHOSTTY_SURFACE_CONTEXT_WINDOW : GHOSTTY_SURFACE_CONTEXT_TAB
      let tabId = tabManager.createTab(
        title: tabSnapshot.title,
        icon: tabSnapshot.icon,
        isTitleLocked: false,
        tintColor: tabSnapshot.tintColor,
        id: tabSnapshot.id,
      )
      if let customTitle = tabSnapshot.customTitle {
        tabManager.setCustomTitle(tabId, title: customTitle)
      }
      restoreTabLayout(
        tabId: tabId,
        layout: tabSnapshot.layout,
        focusedLeafIndex: tabSnapshot.focusedLeafIndex,
        context: context
      )
      onTabCreated?()
    }

    // Seed image-paste routing from the snapshot's per-surface agent records, matching
    // the presence restore's liveness filter: an unopened worktree drains its rehydrate
    // fan-out before the surface exists, and a dead-pid record never gets a corrective
    // empty fan-out, so seeding only live agents keeps Cmd+V from routing into a stale shell.
    for record in snapshot.allAgentRecords() {
      let liveAgents = record.records.compactMap {
        $0.pids.contains(where: AgentPresenceFeature.isAlive) ? SkillAgent(rawValue: $0.agent) : nil
      }
      guard !liveAgents.isEmpty else { continue }
      surfaces[record.surfaceID]?.imagePasteAgents = Set(liveAgents)
    }

    // Select the correct tab.
    let selectedIndex = max(0, min(snapshot.selectedTabIndex, tabManager.tabs.count - 1))
    if selectedIndex < tabManager.tabs.count {
      let selectedTab = tabManager.tabs[selectedIndex]
      tabManager.selectTab(selectedTab.id)
      if focusing {
        focusSurface(in: selectedTab.id)
      }
    }

    // Notifications outlive surfaces, so rebuild the freshly minted
    // `WorktreeSurfaceState` unread counters from the surviving log or the
    // per-surface dot stays dark after restore.
    rebuildUnseenCounters()
  }

  /// Rebuilds a tab's split tree from a snapshot layout using the ORIGINAL
  /// surface UUIDs (so `zmx attach` reattaches), restores the split structure,
  /// and clamps focus to `focusedLeafIndex`.
  private func restoreTabLayout(
    tabId: TerminalTabID,
    layout: TerminalLayoutSnapshot.LayoutNode,
    focusedLeafIndex: Int,
    context: ghostty_surface_context_e
  ) {
    let firstLeafPwd = layout.firstLeaf.workingDirectory
    let workingDir = firstLeafPwd.flatMap { URL(filePath: $0, directoryHint: .isDirectory) }
    let surface = createSurface(
      tabId: tabId,
      initialInput: nil,
      workingDirectoryOverride: workingDir,
      inheritingFromSurfaceId: nil,
      context: context,
      surfaceID: layout.firstLeaf.id,
    )
    let tree = SplitTree(view: surface)
    setTree(tree, for: tabId)
    setFocusedSurface(surface.id, for: tabId)

    restoreLayoutNode(layout, anchor: surface, tabId: tabId)

    let leaves = trees[tabId]?.root?.leaves() ?? []
    let expectedLeaves = layout.leafCount
    if leaves.count != expectedLeaves {
      layoutLogger.warning(
        "Partial restore for tab \(tabId.rawValue): expected \(expectedLeaves) panes, got \(leaves.count)"
      )
    }

    let focusedIndex = max(0, min(focusedLeafIndex, leaves.count - 1))
    if focusedIndex < leaves.count {
      setFocusedSurface(leaves[focusedIndex].id, for: tabId)
    }
  }

  private func restoreLayoutNode(
    _ node: TerminalLayoutSnapshot.LayoutNode,
    anchor: GhosttySurfaceView,
    tabId: TerminalTabID
  ) {
    guard case .split(let split) = node else { return }

    // Create the right child by splitting the anchor.
    let rightPwd = split.right.firstLeaf.workingDirectory
    let rightWorkingDir = rightPwd.flatMap { URL(filePath: $0, directoryHint: .isDirectory) }
    let direction: SplitTree<GhosttySurfaceView>.NewDirection =
      split.direction == .horizontal ? .right : .down

    guard
      let newSurface = createRestorationSplit(
        at: anchor,
        direction: direction,
        ratio: split.ratio,
        workingDirectory: rightWorkingDir,
        tabId: tabId,
        surfaceID: split.right.firstLeaf.id,
      )
    else {
      layoutLogger.warning("Skipping subtree restoration for tab \(tabId.rawValue)")
      return
    }

    // Recurse into left and right subtrees.
    restoreLayoutNode(split.left, anchor: anchor, tabId: tabId)
    restoreLayoutNode(split.right, anchor: newSurface, tabId: tabId)
  }

  private func createRestorationSplit(
    at anchor: GhosttySurfaceView,
    direction: SplitTree<GhosttySurfaceView>.NewDirection,
    ratio: Double,
    workingDirectory: URL?,
    tabId: TerminalTabID,
    surfaceID: UUID? = nil
  ) -> GhosttySurfaceView? {
    guard var tree = trees[tabId] else { return nil }
    let newSurface = createSurface(
      tabId: tabId,
      initialInput: nil,
      workingDirectoryOverride: workingDirectory,
      inheritingFromSurfaceId: anchor.id,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
      surfaceID: surfaceID,
    )
    do {
      tree = try tree.inserting(view: newSurface, at: anchor, direction: direction, ratio: ratio)
      setTree(tree, for: tabId)
      return newSurface
    } catch {
      layoutLogger.warning("Failed to restore split for tab \(tabId.rawValue): \(error)")
      newSurface.closeSurface()
      discardSurfaceBookkeeping(for: newSurface.id)
      return nil
    }
  }

  func needsSetupScript() -> Bool {
    pendingSetupScript
  }

  func enableSetupScriptIfNeeded() {
    if pendingSetupScript {
      return
    }
    if tabManager.tabs.isEmpty {
      pendingSetupScript = true
    }
  }

  private func setupScriptInput(setupScript: String?) -> String? {
    guard pendingSetupScript, let script = setupScript else { return nil }
    return BlockingScriptRunner.makeCommandInput(script: script)
  }

  private func cleanupBlockingScriptLaunchDirectory(for tabId: TerminalTabID) {
    guard let directoryURL = blockingScriptLaunchDirectories.removeValue(forKey: tabId) else { return }
    cleanupBlockingScriptLaunchDirectory(at: directoryURL)
  }

  private func cleanupBlockingScriptLaunchDirectories() {
    let directoryURLs = blockingScriptLaunchDirectories.values
    blockingScriptLaunchDirectories.removeAll()
    for directoryURL in directoryURLs {
      cleanupBlockingScriptLaunchDirectory(at: directoryURL)
    }
  }

  private func cleanupBlockingScriptLaunchDirectory(at directoryURL: URL) {
    do {
      try FileManager.default.removeItem(at: directoryURL)
    } catch {
      blockingScriptLogger.warning(
        "Failed to remove blocking script launch directory \(directoryURL.path(percentEncoded: false)): \(error)"
      )
    }
  }

  // The typed command stays shell-portable by invoking a generated wrapper file
  // that reads the shell path from a sibling file and launches the user script,
  // rather than serializing it into a shell-escaped `-c` string.
  private func blockingScriptLaunch(_ script: String) throws -> BlockingScriptRunner.LaunchArtifacts? {
    try BlockingScriptRunner.makeLaunch(
      script: script,
      shellPath: defaultShellPath()
    )
  }

  // Fires when the blocking command finishes. The shell stays alive
  // so the user can inspect output. Completion is reported here for
  // all exit codes. `handleBlockingScriptChildExited` covers the
  // separate case where the shell exits before the command finishes.
  private func handleBlockingScriptCommandFinished(tabId: TerminalTabID, exitCode: Int?) {
    guard let kind = blockingScripts.removeValue(forKey: tabId) else { return }
    blockingScriptLogger.info("\(kind.tabTitle) finished with exit code \(exitCode.map(String.init) ?? "nil")")
    completeBlockingScript(kind, tabId: tabId, exitCode: exitCode, reportedTabId: tabId)
  }

  // Shell self-exit. A finished command already cleared tracking in
  // `handleBlockingScriptCommandFinished`, so this no-ops. Local: user quit
  // (exit / Ctrl+D), a cancellation. Remote: the child is ssh, so a failed run.
  private func handleBlockingScriptChildExited(tabId: TerminalTabID, exitCode: UInt32) {
    guard let kind = blockingScripts.removeValue(forKey: tabId) else { return }
    // Remote ssh exit codes are unreliable (login wrapper); force failure so a
    // raw 0 can't hit a lifecycle success path, and report no tab (ghostty
    // already closed the surface).
    guard worktree.host == nil else {
      blockingScriptLogger.warning("\(kind.tabTitle) ssh exited before completion (raw exit code \(exitCode))")
      completeBlockingScript(kind, tabId: tabId, exitCode: 1, reportedTabId: nil)
      return
    }
    blockingScriptLogger.info(
      "\(kind.tabTitle) cancelled (shell exited before command finished, raw exit code \(exitCode))"
    )
    completeBlockingScript(kind, tabId: tabId, exitCode: nil, reportedTabId: nil)
  }

  // Marks the blocking-script tab as completed and flips every surface in
  // it to Ghostty's readonly mode so the user can't keep typing into a
  // shell that won't survive app quit. Fires the completion callback
  // asynchronously unless a new script of the same kind already started.
  private func completeBlockingScript(
    _ kind: BlockingScriptKind,
    tabId: TerminalTabID,
    exitCode: Int?,
    reportedTabId: TerminalTabID?
  ) {
    tabManager.markBlockingScriptCompleted(tabId)
    freezeBlockingScriptSurfaces(in: tabId)
    emitTaskStatusIfChanged()

    Task { @MainActor [weak self] in
      guard let self else {
        blockingScriptLogger.debug("\(kind.tabTitle) completion dropped (state deallocated)")
        return
      }
      guard !self.blockingScripts.values.contains(kind) else {
        blockingScriptLogger.info("\(kind.tabTitle) completion superseded by new script of same kind")
        return
      }
      self.onBlockingScriptCompleted?(kind, exitCode, reportedTabId)
    }
  }

  private func freezeBlockingScriptSurfaces(in tabId: TerminalTabID) {
    for surfaceID in surfaceIDs(inTab: tabId) {
      surfaces[surfaceID]?.enableReadOnly()
    }
  }

  private func surfaceEnvironment(tabId: TerminalTabID, surfaceID: UUID) -> [String: String] {
    var env = worktree.scriptEnvironment
    let percentEncodingSet = CharacterSet.urlPathAllowed.subtracting(.init(charactersIn: "/"))
    let repoPath = worktree.repositoryRootURL.path(percentEncoded: false)
    env["SUPACODE_REPO_ID"] = percentEncode(repoPath, allowedCharacters: percentEncodingSet, label: "SUPACODE_REPO_ID")
    env["SUPACODE_WORKTREE_ID"] = percentEncode(
      worktree.id.rawValue, allowedCharacters: percentEncodingSet, label: "SUPACODE_WORKTREE_ID")
    env["SUPACODE_TAB_ID"] = tabId.rawValue.uuidString
    env["SUPACODE_SURFACE_ID"] = surfaceID.uuidString
    if let socketPath {
      env["SUPACODE_SOCKET_PATH"] = socketPath
    }
    // Mark blocking-script surfaces so the user's shell profile can skip its
    // interactive init (prompt, plugins, banners) for these transient tabs.
    if let blockingScriptKind = blockingScripts[tabId] {
      env.merge(blockingScriptEnvironment(for: blockingScriptKind)) { _, new in new }
    }
    // Lock ZMX_DIR to the value the app's probe used so the shell can't
    // re-export a different value from .zshrc / .zprofile and silently
    // overflow `sockaddr_un.sun_path` past the probe's check.
    env["ZMX_DIR"] = ZmxSocketBudget.socketDir()
    // Prepend the bundled CLI binary directory to PATH so that `supacode`
    // resolves to the CLI tool, not the app binary added by Ghostty.
    if let cliBinDir = Bundle.main.resourceURL?
      .appending(path: "bin", directoryHint: .isDirectory)
      .path(percentEncoded: false)
    {
      let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
      env["PATH"] = currentPath.isEmpty ? cliBinDir : "\(cliBinDir):\(currentPath)"
    }
    return env
  }

  /// Blocking-script marker env vars for a kind, with scope resolved against
  /// this worktree's settings. Shared by the local surface environment and the
  /// remote runner export so both hosts expose the same signal.
  private func blockingScriptEnvironment(for kind: BlockingScriptKind) -> [String: String] {
    let scope = kind.scriptDefinitionID.flatMap(scriptScope(forDefinitionID:))
    return kind.surfaceEnvironmentVariables(scope: scope)
  }

  /// Resolves whether a user-defined script is repo- or global-owned, mirroring
  /// the repo-wins merge: an ID present in repo settings is `.repo`, otherwise
  /// `.global`. Returns `nil` for a script that resolves to neither (e.g. a
  /// since-deleted deeplink target).
  private func scriptScope(forDefinitionID id: UUID) -> ScriptScope? {
    if repositorySettings.scripts.contains(where: { $0.id == id }) { return .repo }
    @Shared(.settingsFile) var settingsFile
    if settingsFile.global.globalScripts.contains(where: { $0.id == id }) { return .global }
    return nil
  }

  private func percentEncode(_ value: String, allowedCharacters: CharacterSet, label: String) -> String {
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
      terminalStateLogger.warning(
        "Failed to percent-encode \(label): \(value). Downstream deeplinks using this value may be malformed.")
      return value
    }
    return encoded
  }

  private func createSurface(
    tabId: TerminalTabID,
    command: String? = nil,
    initialInput: String?,
    workingDirectoryOverride: URL? = nil,
    inheritingFromSurfaceId: UUID?,
    context: ghostty_surface_context_e,
    surfaceID: UUID? = nil,
    bypassZmx: Bool = false,
    replacingExistingSurfaceID: Bool = false,
  ) -> GhosttySurfaceView {
    let resolvedID: UUID
    if let requested = surfaceID {
      if surfaces[requested] != nil, !replacingExistingSurfaceID {
        terminalStateLogger.warning("Duplicate surface ID \(requested), generating a new one.")
        resolvedID = UUID()
      } else {
        resolvedID = requested
      }
    } else {
      resolvedID = UUID()
    }
    let surfaceID = resolvedID
    terminalStateLogger.info("createSurface: resolved=\(surfaceID)")
    let inherited = inheritedSurfaceConfig(fromSurfaceId: inheritingFromSurfaceId, context: context)
    let launch = resolveLaunch(
      surfaceID: surfaceID,
      command: command,
      initialInput: initialInput,
      bypassZmx: bypassZmx,
    )
    // Remote worktrees have no local working directory: the surface command is
    // an `ssh …` line (see `resolveLaunch`) and the cwd lives on the
    // remote, so leave `working_directory` nil and let the remote shell `cd`.
    let resolvedWorkingDirectory: URL? =
      worktree.host == nil
      ? (workingDirectoryOverride ?? inherited.workingDirectory ?? worktree.workingDirectory)
      : nil
    let view = GhosttySurfaceView(
      id: surfaceID,
      runtime: runtime,
      workingDirectory: resolvedWorkingDirectory,
      command: launch.command,
      initialInput: launch.initialInput,
      environmentVariables: surfaceEnvironment(tabId: tabId, surfaceID: surfaceID),
      commandWrapper: launch.commandWrapper,
      // Blocking-script runners (bypassZmx) emit their own OSC 133/7 and must
      // not get Ghostty's shell integration injected into the host shell.
      disableShellIntegration: bypassZmx,
      fontSize: inherited.fontSize ?? rememberedZoomFontSize,
      context: context
    )
    wireSurfaceCallbacks(view: view, tabId: tabId)
    surfaces[view.id] = view
    surfaceLaunchMetadata[view.id] = SurfaceLaunchMetadata(usesZmx: launch.usesZmx, context: context)
    // Preserve an existing surface state (a woken dormant leaf re-adopts its
    // unseen counter under the original UUID); mint fresh only for a new surface.
    if surfaceStates[view.id] == nil {
      surfaceStates[view.id] = WorktreeSurfaceState()
    }
    return view
  }

  /// Extracted from `createSurface` so the latter stays under swiftlint's
  /// cyclomatic-complexity cap. The closures all branch on `[weak self,
  /// weak view]` so the count adds up fast.
  private func wireSurfaceCallbacks(
    view: GhosttySurfaceView,
    tabId: TerminalTabID
  ) {
    wireSurfaceTabCallbacks(view: view, tabId: tabId)
    wireSurfaceLifecycleCallbacks(view: view, tabId: tabId)
  }

  /// Tab / title / split callbacks. Split from `wireSurfaceLifecycleCallbacks`
  /// so each stays under swiftlint's cyclomatic-complexity cap.
  private func wireSurfaceTabCallbacks(
    view: GhosttySurfaceView,
    tabId: TerminalTabID
  ) {
    view.bridge.onTitleChange = { [weak self, weak view] title in
      guard let self, let view else { return }
      guard self.isLiveSurface(view) else { return }
      if self.focusedSurfaceIdByTab[tabId] == view.id {
        self.tabManager.updateTitle(tabId, title: title)
      }
    }
    view.bridge.onPromptTitle = { [weak self, weak view] in
      guard let self, let view, self.isLiveSurface(view) else { return }
      self.tabManager.beginTabRename(tabId)
    }
    view.bridge.onSplitAction = { [weak self, weak view] action in
      guard let self, let view else { return false }
      guard self.isLiveSurface(view) else { return false }
      return self.performSplitAction(action, for: view.id)
    }
    view.bridge.onNewTab = { [weak self, weak view] in
      guard let self, let view else { return false }
      guard self.isLiveSurface(view) else { return false }
      return self.createTab(inheritingFromSurfaceId: view.id) != nil
    }
    view.bridge.onCloseTab = { [weak self, weak view] mode in
      guard let self, let view, self.isLiveSurface(view) else { return false }
      // Ghostty's palette/keybind close-tab carries the scope; honor each so
      // "close others" / "close to the right" route through confirmation too.
      switch mode {
      case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
        return self.requestCloseOtherTabs(keeping: tabId)
      case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
        return self.requestCloseTabsToRight(of: tabId)
      default:
        return self.requestCloseTab(tabId)
      }
    }
    view.bridge.onGotoTab = { [weak self, weak view] target in
      guard let self, let view, self.isLiveSurface(view) else { return false }
      return self.handleGotoTabRequest(target)
    }
    view.bridge.onCommandPaletteToggle = { [weak self, weak view] in
      guard let self, let view, self.isLiveSurface(view) else { return false }
      self.onCommandPaletteToggle?()
      return true
    }
  }

  /// Progress / exit / notification / focus callbacks.
  private func wireSurfaceLifecycleCallbacks(
    view: GhosttySurfaceView,
    tabId: TerminalTabID
  ) {
    view.bridge.onProgressReport = { [weak self, weak view] _ in
      guard let self, let view, self.isLiveSurface(view) else { return }
      self.updateRunningState(for: tabId)
    }
    view.bridge.onCommandFinished = { [weak self, weak view] exitCode in
      guard let self, let view, self.isLiveSurface(view) else { return }
      self.handleBlockingScriptCommandFinished(tabId: tabId, exitCode: exitCode)
    }
    view.bridge.onChildExited = { [weak self, weak view] exitCode in
      guard let self, let view, self.isLiveSurface(view) else { return }
      self.handleBlockingScriptChildExited(tabId: tabId, exitCode: exitCode)
    }
    view.bridge.onDesktopNotification = { [weak self, weak view] title, body in
      guard let self, let view else { return }
      guard self.isLiveSurface(view) else { return }
      self.handleAgentOSCNotification(title: title, body: body, surfaceID: view.id)
    }
    view.bridge.onContextSignal = { [weak self, weak view] _, id, metadata in
      guard let self, let view else { return }
      guard self.isLiveSurface(view) else { return }
      self.handleContextSignal(surfaceID: view.id, id: id, metadata: metadata)
    }
    view.bridge.onCloseRequest = { [weak self, weak view] needsConfirmation in
      guard let self, let view else { return }
      self.handleCloseRequest(for: view, needsConfirmation: needsConfirmation)
    }
    view.onFocusChange = { [weak self, weak view] focused in
      guard let self, let view, focused else { return }
      guard self.isLiveSurface(view) else { return }
      self.recordActiveSurface(view, in: tabId)
      self.emitTaskStatusIfChanged()
    }
    view.bridge.onColorChanged = { [weak self, weak view] in
      guard let self, let view, self.isLiveSurface(view) else { return }
      // Only the focused surface drives the window tint.
      guard self.focusedSurfaceIdByTab[tabId] == view.id else { return }
      self.onFocusedSurfaceColorChanged?()
    }
    view.shouldClaimFocus = { [weak self, weak view] in
      guard let self, let view, self.isLiveSurface(view) else { return false }
      return self.focusedSurfaceIdByTab[tabId] == view.id
    }
  }

  // Identity, not key presence: a reattached surface keeps its UUID, so stale closures from the old view must no-op.
  private func isLiveSurface(_ view: GhosttySurfaceView) -> Bool {
    surfaces[view.id] === view
  }

  // A surface this worktree owns: a live view or a dormant leaf whose session the
  // watcher tails. OSC ingest guards accept both so a dark tab's recovered signals
  // land, while a truly unknown id (e.g. a just-closed surface) is still dropped.
  private func isKnownSurface(_ surfaceID: UUID) -> Bool {
    surfaces[surfaceID] != nil || isDormantSurface(surfaceID)
  }

  private func isDormantSurface(_ surfaceID: UUID) -> Bool {
    dormantTabLayouts.values.contains { $0.layout.leafSurfaceIDs.contains(surfaceID) }
  }

  // The bridge state of the focused surface in the selected tab, if any. Used to
  // resolve the window tint from the focused surface's OSC 11 background.
  func focusedSurfaceState() -> GhosttySurfaceState? {
    guard let tabID = tabManager.selectedTabId,
      let surfaceID = focusedSurfaceIdByTab[tabID],
      let surface = surfaces[surfaceID]
    else { return nil }
    return surface.bridge.state
  }

  /// Routes an OSC 3008 context signal to the presence or notify handler.
  private func handleContextSignal(surfaceID: UUID, id: String, metadata: String) {
    // Route by notify INTENT, not by parse success, so a malformed notify logs as
    // a notify drop rather than silently falling through to the presence handler.
    if AgentPresenceOSC.isNotifyMetadata(metadata) {
      handleNotifySignal(surfaceID: surfaceID, id: id, metadata: metadata)
    } else {
      handlePresenceSignal(surfaceID: surfaceID, id: id, metadata: metadata)
    }
  }

  /// Verify an OSC 3008 presence signal against the receiving surface's nonce,
  /// then synthesize an `AgentHookEvent` and forward it to the manager. Attribution
  /// is by the receiving surface, so the wire never carries a surface id that could
  /// spoof another worktree's badge; a pid rides along only for local hooks.
  private func handlePresenceSignal(surfaceID: UUID, id: String, metadata: String) {
    switch Self.presenceEvent(
      id: id,
      metadata: metadata,
      surfaceID: surfaceID,
      surfaceExists: isKnownSurface(surfaceID)
    ) {
    case .success(let event):
      onAgentHookEvent?(event)
    case .failure(.parseFailed):
      // Malformed metadata on a live surface is probe-shaped; warn (mirrors notify).
      terminalStateLogger.warning("Dropped malformed OSC presence signal for surface \(surfaceID).")
    case .failure(.unknownSurface):
      terminalStateLogger.debug("Dropped OSC presence signal for surface \(surfaceID).")
    }
  }

  /// Typed reasons a presence signal was dropped, so the single call site can pick a
  /// log severity per cause (warn for malformed, debug otherwise).
  enum PresenceDrop: Error, Equatable {
    case unknownSurface
    case parseFailed
  }

  /// Pure decision for an OSC presence signal: returns an `AgentHookEvent`
  /// attributed to the RECEIVING surface when the surface is known and the metadata
  /// is well-formed; otherwise a typed `PresenceDrop` so the caller can log per
  /// cause. The wire never carries a surface id (so a payload can't spoof another
  /// worktree). The parser rejects a non-positive pid before it could reach the
  /// liveness sweep; a forged positive pid at worst pins a live-looking badge.
  nonisolated static func presenceEvent(
    id: String,
    metadata: String,
    surfaceID: UUID,
    surfaceExists: Bool
  ) -> Result<AgentHookEvent, PresenceDrop> {
    guard surfaceExists else { return .failure(.unknownSurface) }
    guard let signal = AgentPresenceOSC.parse(id: id, metadata: metadata) else {
      return .failure(.parseFailed)
    }
    return .success(
      AgentHookEvent(
        agent: signal.agent, event: signal.eventRawValue, surfaceID: surfaceID, pid: signal.pid))
  }

  /// Splits a raw OSC 3008 payload (`<action>=<id>[;<metadata>]`) into context id
  /// and raw metadata, mirroring libghostty's context-signal parser for the
  /// dormant channel that bypasses it. Returns nil without a `start=` / `end=`
  /// prefix or a spec-valid id (1-64 printable ASCII bytes).
  nonisolated static func contextSignalFields(payload: String) -> (id: String, metadata: String)? {
    let rest: Substring
    if payload.hasPrefix("start=") {
      rest = payload.dropFirst("start=".count)
    } else if payload.hasPrefix("end=") {
      rest = payload.dropFirst("end=".count)
    } else {
      return nil
    }
    guard !rest.isEmpty else { return nil }
    let idEnd = rest.firstIndex(of: ";") ?? rest.endIndex
    let id = rest[..<idEnd]
    guard (1...64).contains(id.count),
      id.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) })
    else { return nil }
    let metadata = idEnd < rest.endIndex ? rest[rest.index(after: idEnd)...] : ""
    return (String(id), String(metadata))
  }

  /// Parse an OSC 3008 notify signal for the receiving surface, then sanitize and
  /// display it. Gated by the rich-notifications setting.
  private func handleNotifySignal(surfaceID: UUID, id: String, metadata: String) {
    switch Self.notification(
      id: id,
      metadata: metadata,
      surfaceExists: isKnownSurface(surfaceID)
    ) {
    case .success(let resolved):
      // Gate AFTER parse so the setting can't be probed via drop-rate signals.
      @Shared(.settingsFile) var settingsFile
      guard settingsFile.global.richAgentNotificationsEnabled else {
        terminalStateLogger.debug("Dropped OSC notify; rich notifications disabled.")
        return
      }
      // A body present on the wire but decoded empty means a truncation, an
      // escape-cut the shed loop couldn't recover, or a non-base64 (probe / forged)
      // field: keep it out of silent-failure territory by logging, even though we
      // still show the title-only toast.
      if resolved.body.isEmpty, resolved.wireBodyByteCount > 0 {
        let wireBytes = resolved.wireBodyByteCount
        terminalStateLogger.warning(
          "OSC notify body present on wire (\(wireBytes) b64 bytes) but decoded empty, dropped: surface \(surfaceID)."
        )
      }
      appendHookNotification(title: resolved.title, body: resolved.body, surfaceID: surfaceID)
    case .failure(.parseFailed):
      // parseNotify only fails on a non-notify / empty id (not a truncated body,
      // which decodes to an empty field, logged in the success arm above).
      terminalStateLogger.warning(
        "Dropped malformed OSC notify (metadata bytes: \(metadata.utf8.count)) for surface \(surfaceID).")
    case .failure(.unknownSurface), .failure(.empty):
      terminalStateLogger.debug("Dropped OSC notify signal for surface \(surfaceID).")
    }
  }

  /// Typed reasons a notify signal was dropped, so the single call site can pick a
  /// log severity per cause (warn for malformed, debug otherwise).
  enum NotifyDrop: Error {
    case unknownSurface
    case parseFailed
    case empty
  }

  /// A parsed + sanitized notify ready for display, plus the raw wire body byte
  /// count so the call site can log a truncated-to-empty body.
  struct ResolvedNotification: Equatable {
    let title: String
    let body: String
    let wireBodyByteCount: Int
  }

  /// Pure parse decision for an OSC notify signal. Title/body are bounded and
  /// stripped of control characters since anything on the terminal can emit one.
  /// Title falls back to the agent name; body may be empty.
  nonisolated static func notification(
    id: String,
    metadata: String,
    surfaceExists: Bool
  ) -> Result<ResolvedNotification, NotifyDrop> {
    guard surfaceExists else { return .failure(.unknownSurface) }
    guard let notify = AgentPresenceOSC.parseNotify(id: id, metadata: metadata) else {
      return .failure(.parseFailed)
    }
    // Second-line defense behind the emit-side caps (notifyTitleByteBudget /
    // notifyBodyByteBudget): these are scalar counts, not bytes, and the wire is
    // already bounded, so they only bite on a hand-crafted oversized payload.
    let title = sanitizeNotificationText(notify.title ?? notify.agent, max: 200)
    let body = sanitizeNotificationText(notify.body ?? "", max: 1000)
    guard !(title.isEmpty && body.isEmpty) else { return .failure(.empty) }
    return .success(ResolvedNotification(title: title, body: body, wireBodyByteCount: notify.wireBodyByteCount))
  }

  /// Bound length and neutralize control characters in attacker-influenceable
  /// notification text. Newline / tab / carriage return collapse to a space;
  /// other C0 controls and DEL are dropped (defends against escape-sequence
  /// injection into the toast). Length is capped in unicode scalars.
  nonisolated static func sanitizeNotificationText(_ text: String, max: Int) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if scalars.count >= max { break }
      switch scalar.value {
      case 0x0A, 0x09, 0x0D:
        scalars.append(" ")
      case 0x00...0x1F, 0x7F:
        continue
      default:
        scalars.append(scalar)
      }
    }
    return String(scalars).trimmingCharacters(in: .whitespaces)
  }

  struct ResolvedLaunch {
    var command: String?
    var initialInput: String?
    var commandWrapper: [String]
    var usesZmx: Bool
  }

  /// Routes a surface through zmx so the underlying shell survives app quit.
  ///
  /// Interactive surfaces (no explicit `command`) keep `command` nil and inject
  /// `zmx attach <id>` as a Ghostty `command-wrapper`, so Ghostty resolves and
  /// integrates the user's real shell exactly as it would without zmx, with zmx
  /// wrapping the whole resolved (login + integrated) argv.
  ///
  /// Explicit commands (scripts) instead wrap the command string itself, since
  /// they don't want shell resolution / integration. `initialInput` is always
  /// passed through; zmx is authoritative for attach-vs-create.
  private func resolveLaunch(
    surfaceID: UUID,
    command: String?,
    initialInput: String?,
    bypassZmx: Bool
  ) -> ResolvedLaunch {
    if bypassZmx {
      return ResolvedLaunch(command: command, initialInput: initialInput, commandWrapper: [], usesZmx: false)
    }
    let zmxExecutablePath = zmxClient.executableURL()?.path(percentEncoded: false)
    // Remote worktree: a *local* zmx session wraps a reconnect loop around the
    // SSH connection, and the remote reattaches its own zmx session when the
    // host has zmx (host persistence). The surface command is always the
    // reconnect-loop script (no command-wrapper, since Ghostty wraps the
    // local argv, not the loop). When the caller has no explicit command,
    // default to cd-into-the-remote-dir so a freshly created session lands in
    // the project.
    if let host = worktree.host {
      @Shared(.settingsFile) var settingsFile
      let hostPersistence = settingsFile.global.remoteSessionPersistenceEnabled
      let launch = ZmxAttach.RemoteSurfaceLaunch(
        host: host,
        surfaceID: surfaceID,
        userCommand: command,
        defaultCommand: Self.remoteDefaultShellCommand(
          remotePath: worktree.workingDirectory.path(percentEncoded: false)),
        hostPersistenceEnabled: hostPersistence,
      )
      return ResolvedLaunch(
        command: ZmxAttach.buildRemoteCommand(launch, localZmxExecutablePath: zmxExecutablePath),
        initialInput: initialInput,
        commandWrapper: [],
        usesZmx: zmxExecutablePath != nil,
      )
    }
    let resolved = ZmxAttach.resolveLaunch(
      executablePath: zmxExecutablePath,
      sessionID: ZmxSessionID.make(surfaceID: surfaceID),
      command: command,
    )
    return ResolvedLaunch(
      command: resolved.command,
      initialInput: initialInput,
      commandWrapper: resolved.commandWrapper,
      usesZmx: zmxExecutablePath != nil,
    )
  }

  /// Connect default and reconnect fallback for a remote surface: `cd` into
  /// the remote project dir, then exec a login shell. The `cd` failure is
  /// swallowed so a stale path still drops the user into a usable shell. Nil
  /// for an empty/root path falls back to a bare login shell. The path is
  /// single-quoted for the login shell that re-parses the session command.
  static func remoteDefaultShellCommand(remotePath: String) -> String? {
    let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "/" else { return nil }
    let quoted = "'" + trimmed.replacing("'", with: "'\\''") + "'"
    return "cd \(quoted) 2>/dev/null; exec \"$SHELL\" -l"
  }

  private struct InheritedSurfaceConfig: Equatable {
    let workingDirectory: URL?
    let fontSize: Float32?
  }

  private func inheritedSurfaceConfig(
    fromSurfaceId surfaceID: UUID?,
    context: ghostty_surface_context_e
  ) -> InheritedSurfaceConfig {
    guard let surfaceID,
      let view = surfaces[surfaceID],
      let sourceSurface = view.surface
    else {
      return InheritedSurfaceConfig(workingDirectory: nil, fontSize: nil)
    }

    let inherited = ghostty_surface_inherited_config(sourceSurface, context)
    let fontSize = inherited.font_size == 0 ? nil : inherited.font_size
    let workingDirectory = inherited.working_directory.flatMap { ptr -> URL? in
      let path = String(cString: ptr)
      if path.isEmpty {
        return nil
      }
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return InheritedSurfaceConfig(workingDirectory: workingDirectory, fontSize: fontSize)
  }

  private static let rememberedZoomFontSizeKey = "terminalRememberedFontSize"

  /// Seed for a sourceless surface, gated on `window-inherit-font-size`.
  private var rememberedZoomFontSize: Float32? {
    guard runtime.windowInheritsFontSize() else { return nil }
    @Shared(.appStorage(Self.rememberedZoomFontSizeKey)) var stored: Double = 0
    return stored > 0 ? Float32(stored) : nil
  }

  /// Sample and persist the focused surface's zoom (worktree switch, quit).
  func rememberFocusedZoom() {
    guard let id = currentFocusedSurfaceId(), let surface = surfaces[id]?.surface else { return }
    persistZoomFontSize(ghostty_surface_font_size(surface))
  }

  /// 0 clears a prior zoom, matching Ghostty dropping the override on reset.
  private func persistZoomFontSize(_ size: Float32) {
    guard runtime.windowInheritsFontSize() else { return }
    @Shared(.appStorage(Self.rememberedZoomFontSizeKey)) var stored: Double = 0
    $stored.withLock { $0 = Double(max(size, 0)) }
  }

  private func currentFocusedSurfaceId() -> UUID? {
    guard let selectedTabId = tabManager.selectedTabId else { return nil }
    return focusedSurfaceIdByTab[selectedTabId]
  }

  private func updateTabTitle(for tabId: TerminalTabID) {
    guard let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId],
      let title = surface.bridge.state.title
    else { return }
    tabManager.updateTitle(tabId, title: title)
  }

  private func focusSurface(in tabId: TerminalTabID) {
    if let focusedId = focusedSurfaceIdByTab[tabId], let surface = surfaces[focusedId] {
      focusSurface(surface, in: tabId)
      return
    }
    let tree = splitTree(for: tabId)
    if let surface = tree.visibleLeaves().first {
      focusSurface(surface, in: tabId)
    }
  }

  private func focusSurface(_ surface: GhosttySurfaceView, in tabId: TerminalTabID) {
    let previousSurface = focusedSurfaceIdByTab[tabId].flatMap { surfaces[$0] }
    recordActiveSurface(surface, in: tabId)
    guard tabId == tabManager.selectedTabId else { return }
    let fromSurface = (previousSurface === surface) ? nil : previousSurface
    GhosttySurfaceView.moveFocus(to: surface, from: fromSurface)
  }

  // Single choke point for mutating the "active pane" of a tab. Reached both
  // from explicit focus paths (programmatic focus, split navigation, zoom)
  // and from AppKit responder changes when the user clicks a pane.
  private func recordActiveSurface(_ surface: GhosttySurfaceView, in tabId: TerminalTabID) {
    setFocusedSurface(surface.id, for: tabId)
    markNotificationsRead(forSurfaceID: surface.id)
    updateTabTitle(for: tabId)
    emitFocusChangedIfNeeded(surface.id)
  }

  // Single source of truth for the tab's active pane so the overlay renderer
  // can't drift across surfaces. Self-corrects when the stored id points at a
  // since-closed surface (or is nil while leaves still exist): a tab with any
  // visible leaves must report exactly one of them as active, otherwise the
  // dim-overlay reads either "no surface selected" (no leaf matches) or "all
  // surfaces selected" (no id → guard short-circuits the dim check for every
  // leaf).
  func activeSurfaceID(for tabId: TerminalTabID) -> UUID? {
    if let stored = focusedSurfaceIdByTab[tabId], surfaces[stored] != nil {
      return stored
    }
    return trees[tabId]?.visibleLeaves().first?.id
  }

  /// Appends a notification from a custom (hook / OSC 3008) source. Records the
  /// time so the agent's own OSC 9 for the same event is deduped, and cancels any
  /// OSC 9 currently held for this surface (the expanded one supersedes it).
  func appendHookNotification(title: String, body: String, surfaceID: UUID) {
    guard isKnownSurface(surfaceID) else {
      terminalStateLogger.debug("Dropped hook notification for unknown surface \(surfaceID) in worktree \(worktree.id)")
      return
    }
    lastCustomNotificationAt[surfaceID] = clock.now
    if let superseded = pendingAgentOSCNotifications.removeValue(forKey: surfaceID) {
      superseded.cancel()
      terminalStateLogger.debug(
        "Dropped held agent OSC 9 for surface \(surfaceID) in worktree \(worktree.id): superseded by hook notification"
      )
    }
    appendNotification(title: title, body: body, surfaceID: surfaceID)
  }

  /// The agent's own OSC 9 desktop notification, a summary of the expanded custom
  /// notification we ship. Deduped: dropped if a custom notification just
  /// committed for this surface (hook-first); otherwise held briefly and dropped
  /// if a custom one supersedes it during the hold (OSC-9-first), else shown.
  private func handleAgentOSCNotification(title: String, body: String, surfaceID: UUID) {
    if let last = lastCustomNotificationAt[surfaceID],
      Self.elapsed(from: last, to: clock.now) <= .seconds(Self.oscSuppressionAfterCustom)
    {
      terminalStateLogger.debug(
        "Dropped agent OSC 9 for surface \(surfaceID) in \(worktree.id): custom notification within dedupe window"
      )
      return
    }
    let clock = clock
    pendingAgentOSCNotifications.removeValue(forKey: surfaceID)?.cancel()
    pendingAgentOSCNotifications[surfaceID] = Task { [weak self] in
      do {
        try await clock.sleep(for: .seconds(Self.oscHoldWindow))
      } catch is CancellationError {
        return
      } catch {
        terminalStateLogger.error("OSC 9 hold sleep failed: \(error)")
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.pendingAgentOSCNotifications.removeValue(forKey: surfaceID)
      guard self.isKnownSurface(surfaceID) else { return }
      self.appendNotification(title: title, body: body, surfaceID: surfaceID)
    }
  }

  private func appendNotification(title: String, body: String, surfaceID: UUID) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(trimmedTitle.isEmpty && trimmedBody.isEmpty) else { return }
    let isViewed = isViewedSurface(surfaceID)
    if notificationsEnabled {
      notifications.insert(
        WorktreeTerminalNotification(
          surfaceID: surfaceID,
          title: trimmedTitle,
          body: trimmedBody,
          createdAt: now,
          isRead: isViewed
        ),
        at: 0
      )
      if !isViewed { incrementUnseenCount(surfaceID) }
      // Trimming only prunes the visible log; the unseen counter is untouched.
      trimNotificationsToRetentionLimit()
      if let tabId = tabID(containing: surfaceID) {
        emitTabProjection(for: tabId)
      }
      emitNotificationStateChanged()
    }
    onNotificationReceived?(surfaceID, trimmedTitle, trimmedBody, isViewed)
  }

  /// Re-applies the retention limit to the existing backlog, e.g. after the user
  /// lowers it in settings. A no-op when nothing exceeds the limit. Unseen
  /// counters are never touched: trimming the log must not clear an indicator.
  func enforceNotificationRetentionLimit() {
    guard trimNotificationsToRetentionLimit() else { return }
    emitNotificationStateChanged()
  }

  /// Enforces the per-worktree retention limit, evicting read notifications
  /// before unread ones regardless of age. Unread survive unless they alone
  /// exceed the limit, in which case the oldest unread are dropped down to it.
  /// Returns whether anything was removed. Never mutates unseen counters.
  @discardableResult
  private func trimNotificationsToRetentionLimit() -> Bool {
    @Shared(.settingsFile) var settingsFile
    let limit = settingsFile.global.notificationRetentionLimit.limit
    let overflow = notifications.count - limit
    guard overflow > 0 else { return false }
    let readCount = notifications.reduce(0) { $0 + ($1.isRead ? 1 : 0) }
    var readBudget = min(overflow, readCount)
    var unreadBudget = overflow - readBudget
    // `notifications` is newest-first, so iterating reversed drops the oldest
    // read first, then the oldest unread; the newest of each group survives.
    var kept: [WorktreeTerminalNotification] = []
    kept.reserveCapacity(limit)
    for notification in notifications.reversed() {
      if notification.isRead, readBudget > 0 {
        readBudget -= 1
      } else if !notification.isRead, unreadBudget > 0 {
        unreadBudget -= 1
      } else {
        kept.append(notification)
      }
    }
    notifications = Array(kept.reversed())
    return true
  }

  /// Detaches one surface from the local bookkeeping. The zmx session is NOT
  /// killed here; callers route the kill through `killZmxSessions(forSurfaceIDs:)`
  /// so a single multi-pane close emits one `count=N` analytics event + one
  /// `withTaskGroup` instead of N events and N detached Tasks.
  /// Also drops any close confirmation aimed at this surface, cancels its held
  /// agent OSC 9, and forgets the last-custom-notification instant so a future
  /// surface ID can't reuse stale dedupe state.
  private func discardSurfaceBookkeeping(for surfaceID: UUID, preserveSurfaceState: Bool = false) {
    if case .surface(let pendingSurfaceID) = pendingCloseConfirmation?.target,
      pendingSurfaceID == surfaceID
    {
      pendingCloseConfirmation = nil
    }
    pendingAgentOSCNotifications.removeValue(forKey: surfaceID)?.cancel()
    lastCustomNotificationAt.removeValue(forKey: surfaceID)
    surfaces.removeValue(forKey: surfaceID)
    surfaceLaunchMetadata.removeValue(forKey: surfaceID)
    pendingExplicitSurfaceCloseIDs.remove(surfaceID)
    bypassCloseConfirmationSurfaceIDs.remove(surfaceID)
    // Hibernation keeps the surface state so its unseen counter survives the dark
    // period; the reused UUID re-adopts it on wake.
    guard !preserveSurfaceState else { return }
    surfaceStates.removeValue(forKey: surfaceID)
  }

  private func cleanupSurfaceState(for surfaceID: UUID) {
    // Closing a surface drops its unseen counter; refresh the indicators when it
    // carried any so the sidebar dot, toolbar count, and projection don't strand
    // a stale count.
    let hadUnseen = (surfaceStates[surfaceID]?.unseenNotificationCount ?? 0) > 0
    discardSurfaceBookkeeping(for: surfaceID)
    onSurfacesClosed?([surfaceID])
    guard hadUnseen else { return }
    // The counter left with the surface, so mark its lingering log entries read;
    // otherwise the inspector keeps drawing orange unread rows the cleared count
    // contradicts, and their rows dead-end on a surface that no longer exists.
    for index in notifications.indices where notifications[index].surfaceID == surfaceID {
      notifications[index].isRead = true
    }
    onNotificationIndicatorChanged?()
  }

  /// Permanently drops a dormant leaf's preserved surface state (hibernation kept
  /// it alive for its unseen counter) and marks its lingering unread read, so
  /// closing a hibernated tab strands neither the worktree dot / total nor an
  /// inspector row. Returns whether it cleared an outstanding count.
  @discardableResult
  private func discardDormantLeafSurfaceState(for surfaceID: UUID) -> Bool {
    let hadUnseen = (surfaceStates[surfaceID]?.unseenNotificationCount ?? 0) > 0
    surfaceStates.removeValue(forKey: surfaceID)
    guard hadUnseen else { return false }
    for index in notifications.indices where notifications[index].surfaceID == surfaceID {
      notifications[index].isRead = true
    }
    return true
  }

  /// Tears down persistent zmx sessions for surfaces the user just closed.
  /// `isBundled` (not `executableURL`) is the gate so sessions created on a
  /// previous under-budget launch still tear down when this launch exceeds the
  /// socket budget. One analytics event + one `withTaskGroup` per call.
  /// `includeRemote` also tears down the host-side sessions of a remote
  /// worktree; only explicit close paths set it, so a non-explicit end (clean
  /// remote exit, deliberate host-side detach, or a reconnect abort) spares
  /// the host session. The remote kill is unconditional on explicit close (no
  /// per-surface persistence gate): a host session may exist from an earlier
  /// launch regardless of the current toggle, and the kill invocation is a
  /// silent no-op when nothing exists.
  private func killZmxSessions(forSurfaceIDs surfaceIDs: [UUID], includeRemote: Bool = false) {
    guard !surfaceIDs.isEmpty else { return }
    let killLocal = zmxClient.isBundled()
    let host = includeRemote ? worktree.host : nil
    guard killLocal || host != nil else { return }
    let sessionIDs = surfaceIDs.map(ZmxSessionID.make(surfaceID:))
    let client = zmxClient
    analyticsClient.capture(
      "terminal_persistence_session_killed",
      [
        "reason": "user_close", "count": killLocal ? sessionIDs.count : 0,
        "remote_count": host == nil ? 0 : sessionIDs.count,
      ]
    )
    Task.detached {
      await withTaskGroup(of: Void.self) { group in
        for id in sessionIDs {
          group.addTask {
            await client.killSurfaceSessions(sessionID: id, remoteHost: host, killLocal: killLocal)
          }
        }
      }
    }
  }

  private func removeTree(for tabId: TerminalTabID) {
    guard let tree = trees.removeValue(forKey: tabId) else { return }
    surfaceGenerationByTab.removeValue(forKey: tabId)
    let leafIDs = tree.leaves().map(\.id)
    for surface in tree.leaves() {
      surface.closeSurface()
      cleanupSurfaceState(for: surface.id)
    }
    killZmxSessions(forSurfaceIDs: leafIDs, includeRemote: true)
    focusedSurfaceIdByTab.removeValue(forKey: tabId)
    if lastTabProjections.removeValue(forKey: tabId) != nil {
      onTabRemoved?(tabId)
    }
  }

  func tabID(containing surfaceID: UUID) -> TerminalTabID? {
    for (tabId, tree) in trees where tree.find(id: surfaceID) != nil {
      return tabId
    }
    for (tabId, dormant) in dormantTabLayouts where dormant.layout.leafSurfaceIDs.contains(surfaceID) {
      return tabId
    }
    return nil
  }

  private func isFocusedSurface(_ surfaceID: UUID) -> Bool {
    guard let selectedTabId = tabManager.selectedTabId else {
      return false
    }
    return focusedSurfaceIdByTab[selectedTabId] == surfaceID
  }

  private func isViewedSurface(_ surfaceID: UUID) -> Bool {
    isSelected() && isFocusedSurface(surfaceID) && isVisibleSurface(surfaceID)
      && lastWindowIsKey == true && lastWindowIsVisible == true
  }

  // A split-zoomed tab hides every pane outside the zoomed subtree, so a focused
  // pane can still be off screen; gate on the zoom-aware visible leaves.
  private func isVisibleSurface(_ surfaceID: UUID) -> Bool {
    guard let selectedTabId = tabManager.selectedTabId else { return false }
    return trees[selectedTabId]?.visibleLeaves().contains { $0.id == surfaceID } == true
  }

  /// True for a blocking-script tab whose script has already finished.
  func isBlockingScriptCompleted(_ tabId: TerminalTabID) -> Bool {
    tabManager.tabs.first(where: { $0.id == tabId })?.isBlockingScriptCompleted == true
  }

  /// Ghostty keeps reporting a finished blocking-script surface as needing
  /// confirmation (it is read-only, and the runner parks on `tail` so the
  /// cursor never returns to a prompt), but the script is done and the surface
  /// is frozen, so there is nothing live left to lose.
  private func isFrozenBlockingScriptSurface(_ surfaceID: UUID) -> Bool {
    guard let tabId = tabID(containing: surfaceID) else { return false }
    return isBlockingScriptCompleted(tabId)
  }

  private func updateRunningState(for tabId: TerminalTabID) {
    guard trees[tabId] != nil else { return }
    // Frozen tabs stay sticky: the bridge's stale watch re-fires
    // `onProgressReport(REMOVE)` after `command_finished` and would otherwise
    // resurrect the dirty shimmer on a tab the user reads as done.
    let isFrozen = isBlockingScriptCompleted(tabId)
    tabManager.updateDirty(tabId, isDirty: isFrozen ? false : isTabBusy(tabId))
    emitTabProgressDisplay(for: tabId)
    emitTaskStatusIfChanged()
  }

  /// Compute the per-tab stripe progress payload off `trees[tabId]`'s surfaces.
  /// Selected tab → focused-surface state; unselected tab → worst-of-all
  /// (ERROR > PAUSE > determinate > indeterminate > none).
  private func computeTabProgressDisplay(for tabId: TerminalTabID) -> TerminalTabProgressDisplay? {
    guard let tree = trees[tabId] else { return nil }
    let leaves = tree.leaves()
    if tabManager.selectedTabId == tabId,
      let focusedID = focusedSurfaceIdByTab[tabId],
      let focused = leaves.first(where: { $0.id == focusedID })
    {
      return TerminalTabProgressDisplay.make(
        progressState: focused.bridge.state.progressState,
        progressValue: focused.bridge.state.progressValue
      )
    }
    var worst: TerminalTabProgressDisplay?
    for surface in leaves {
      guard
        let candidate = TerminalTabProgressDisplay.make(
          progressState: surface.bridge.state.progressState,
          progressValue: surface.bridge.state.progressValue
        )
      else { continue }
      if worst == nil || candidate.severity > worst!.severity {
        worst = candidate
      }
    }
    return worst
  }

  /// Recompute and emit the tab's progress display when it differs from the
  /// cached value. Idempotent so OSC-9 ticks that don't move the stripe state
  /// don't fire the callback.
  private func emitTabProgressDisplay(for tabId: TerminalTabID) {
    let newDisplay = computeTabProgressDisplay(for: tabId)
    if lastTabProgressDisplays[tabId] != newDisplay {
      lastTabProgressDisplays[tabId] = newDisplay
      onTabProgressDisplayChanged?(tabId, newDisplay)
    }
  }

  private func emitTaskStatusIfChanged() {
    let newStatus = taskStatus
    if newStatus != lastReportedTaskStatus {
      lastReportedTaskStatus = newStatus
      onTaskStatusChanged?(newStatus)
    }
  }

  private func emitFocusChangedIfNeeded(_ surfaceID: UUID) {
    guard surfaceID != lastEmittedFocusSurfaceId else { return }
    lastEmittedFocusSurfaceId = surfaceID
    onFocusChanged?(surfaceID)
  }

  /// `currentProjection()` already includes the full list and per-item `isRead`,
  /// so the sidebar/popover must re-sync on every mutation, not just when
  /// `hasUnseenNotification` flips. Gating here broke dismiss / mark-read of
  /// already-read notifications (#385). Downstream emits self-dedupe, so keep
  /// this ungated.
  private func emitNotificationStateChanged() {
    onNotificationIndicatorChanged?()
  }

  private func syncFocusIfNeeded() {
    guard lastWindowIsKey != nil, lastWindowIsVisible != nil else { return }
    applySurfaceActivity()
  }

  private func updateTree(_ tree: SplitTree<GhosttySurfaceView>, for tabId: TerminalTabID) {
    setTree(tree, for: tabId)
    syncFocusIfNeeded()
  }

  /// Single mutation point for `trees[tabId]`. Recomputes and emits the per-tab
  /// projection so `TerminalTabFeature.State` mirrors `trees[tabId]`'s leaves
  /// + the tab's unread count + focus without observing worktree-wide state.
  private func setTree(_ tree: SplitTree<GhosttySurfaceView>, for tabId: TerminalTabID) {
    trees[tabId] = tree
    // Zoom transitions flip the hide-single-tab-bar gate.
    updateShouldHideTabBar()
    emitTabProjection(for: tabId)
  }

  /// Single mutation point for `focusedSurfaceIdByTab[tabId]`. Mirrors into the
  /// per-tab projection so the stripe-progress leaf observes the focus change
  /// per-tab instead of through the worktree-wide dictionary.
  private func setFocusedSurface(_ surfaceID: UUID?, for tabId: TerminalTabID) {
    if let surfaceID {
      focusedSurfaceIdByTab[tabId] = surfaceID
    } else {
      focusedSurfaceIdByTab.removeValue(forKey: tabId)
    }
    emitTabProjection(for: tabId)
  }

  /// Recompute the per-tab projection and emit `onTabProjectionChanged` when
  /// the value differs from the cached one. Idempotent: a no-op rebuild
  /// (e.g. a notification arrived on a surface that's already counted) does
  /// not fire the callback.
  private func emitTabProjection(for tabId: TerminalTabID) {
    guard let tree = trees[tabId] else {
      // A hibernated tab is still in `tabManager`; project from its frozen
      // leaves rather than signalling removal.
      if let dormant = dormantTabLayouts[tabId] {
        emitDormantTabProjection(for: tabId, dormant: dormant)
        return
      }
      // Removal fires only for a tab genuinely gone from `tabManager`; a tab
      // still present with no tree is mid-creation and settles once the tree lands.
      guard !hasTab(tabId) else { return }
      surfaceGenerationByTab.removeValue(forKey: tabId)
      if lastTabProjections.removeValue(forKey: tabId) != nil {
        onTabRemoved?(tabId)
      }
      return
    }
    let surfaceIDs = tree.leaves().map(\.id)
    let projection = WorktreeTabProjection(
      tabID: tabId,
      surfaceIDs: surfaceIDs,
      activeSurfaceID: focusedSurfaceIdByTab[tabId],
      unseenNotificationCount: unseenNotificationCount(inSurfaces: surfaceIDs),
      isSplitZoomed: tree.zoomed != nil,
      surfaceGeneration: surfaceGenerationByTab[tabId, default: 0],
    )
    commitTabProjection(projection)
  }

  /// Projection for a hibernated tab: surfaces and unseen count come from the
  /// frozen leaves, zoom and focus from the stashed indices, and `isDormant` is
  /// set so the tab bar can render the dormancy accessory.
  private func emitDormantTabProjection(for tabId: TerminalTabID, dormant: DormantTabLayout) {
    let surfaceIDs = dormant.layout.leafSurfaceIDs
    let activeSurfaceID = dormant.focusedLeafIndex.flatMap { index in
      surfaceIDs.indices.contains(index) ? surfaceIDs[index] : nil
    }
    let projection = WorktreeTabProjection(
      tabID: tabId,
      surfaceIDs: surfaceIDs,
      activeSurfaceID: activeSurfaceID,
      unseenNotificationCount: unseenNotificationCount(inSurfaces: surfaceIDs),
      isSplitZoomed: dormant.zoomedSurfaceID != nil,
      surfaceGeneration: surfaceGenerationByTab[tabId, default: 0],
      isDormant: true,
    )
    commitTabProjection(projection)
  }

  /// Sum of the surfaces' outstanding unread counters, for the projection badge.
  /// Counter-based, not a log scan: the capped notification log would undercount.
  /// Dormant-safe while hibernated leaves keep their `surfaceStates` entry.
  private func unseenNotificationCount(inSurfaces surfaceIDs: [UUID]) -> Int {
    surfaceIDs.reduce(0) { $0 + (surfaceStates[$1]?.unseenNotificationCount ?? 0) }
  }

  /// Stores the projection and fires `onTabProjectionChanged` only when it drifts
  /// from the cached value, keeping a no-op rebuild idempotent.
  private func commitTabProjection(_ projection: WorktreeTabProjection) {
    guard lastTabProjections[projection.tabID] != projection else { return }
    lastTabProjections[projection.tabID] = projection
    onTabProjectionChanged?(projection)
  }

  /// Recompute every tab's projection. Used after notification-list mutations
  /// that may span multiple tabs (mark-all-read, dismiss-all).
  private func emitAllTabProjections() {
    for tabId in Set(trees.keys).union(dormantTabLayouts.keys) {
      emitTabProjection(for: tabId)
    }
  }

  /// Snapshot all current tab projections. Manager replays this on every fresh
  /// event-stream subscriber so `terminalTabs[id:]` reconstructs without
  /// waiting for the next per-tab mutation.
  func currentTabProjections() -> [WorktreeTabProjection] {
    Array(lastTabProjections.values)
  }

  /// Snapshot all current per-tab stripe-progress displays. Replayed alongside
  /// `currentTabProjections()` so the stripe paints the right state on the
  /// first frame after re-subscribe.
  func currentTabProgressDisplays() -> [TerminalTabID: TerminalTabProgressDisplay?] {
    lastTabProgressDisplays
  }

  private func isRunningProgressState(_ state: ghostty_action_progress_report_state_e?) -> Bool {
    switch state {
    case .some(GHOSTTY_PROGRESS_STATE_SET),
      .some(GHOSTTY_PROGRESS_STATE_INDETERMINATE),
      .some(GHOSTTY_PROGRESS_STATE_PAUSE),
      .some(GHOSTTY_PROGRESS_STATE_ERROR):
      return true
    default:
      return false
    }
  }

  private func mapSplitDirection(_ direction: GhosttySplitAction.NewDirection)
    -> SplitTree<GhosttySurfaceView>.NewDirection
  {
    switch direction {
    case .left:
      return .left
    case .right:
      return .right
    case .top:
      return .top
    case .down:
      return .down
    }
  }

  private func mapFocusDirection(_ direction: GhosttySplitAction.FocusDirection)
    -> SplitTree<GhosttySurfaceView>.FocusDirection
  {
    switch direction {
    case .previous:
      return .previous
    case .next:
      return .next
    case .left:
      return .spatial(.left)
    case .right:
      return .spatial(.right)
    case .top:
      return .spatial(.top)
    case .down:
      return .spatial(.down)
    }
  }

  private func mapResizeDirection(_ direction: GhosttySplitAction.ResizeDirection)
    -> SplitTree<GhosttySurfaceView>.SpatialDirection
  {
    switch direction {
    case .left:
      return .left
    case .right:
      return .right
    case .top:
      return .top
    case .down:
      return .down
    }
  }

  private func handleCloseRequest(for view: GhosttySurfaceView, needsConfirmation: Bool) {
    guard surfaces[view.id] === view else { return }
    if bypassCloseConfirmationSurfaceIDs.remove(view.id) != nil {
      terminalStateLogger.debug("handleCloseRequest: bypassing confirmation for \(view.id).")
      completeCloseRequest(for: view)
      return
    }
    let isExplicitClose = pendingExplicitSurfaceCloseIDs.contains(view.id)
    if isExplicitClose, pendingCloseConfirmation != nil {
      if pendingCloseConfirmation?.target != .surface(view.id) {
        pendingExplicitSurfaceCloseIDs.remove(view.id)
      }
      return
    }

    @Shared(.settingsFile) var settingsFile
    if needsConfirmation,
      isExplicitClose,
      settingsFile.global.confirmCloseSurface,
      !isFrozenBlockingScriptSurface(view.id)
    {
      pendingCloseConfirmation = .surface(view.id)
      return
    }
    completeCloseRequest(for: view)
  }

  private func completeCloseRequest(for view: GhosttySurfaceView) {
    guard surfaces[view.id] === view else { return }
    let isExplicitClose = pendingExplicitSurfaceCloseIDs.remove(view.id) != nil
    if shouldHandleAsUnexpectedZmxClose(
      surfaceID: view.id,
      isExplicitClose: isExplicitClose
    ) {
      handleUnexpectedZmxClose(for: view)
      return
    }
    // The host-side session dies only on explicit close: a non-explicit exit
    // (e.g. a clean remote exit with the session already gone, a deliberate
    // host-side detach, or a reconnect abort) spares it.
    closeSurfaceAndUpdateTabs(view, killZmxSession: true, includeRemoteSession: isExplicitClose)
  }

  private func shouldHandleAsUnexpectedZmxClose(
    surfaceID: UUID,
    isExplicitClose: Bool
  ) -> Bool {
    guard !isExplicitClose else { return false }
    return surfaceLaunchMetadata[surfaceID]?.usesZmx == true
  }

  private func handleUnexpectedZmxClose(for view: GhosttySurfaceView) {
    let surfaceID = view.id
    let sessionID = ZmxSessionID.make(surfaceID: surfaceID)
    let client = zmxClient
    Task { @MainActor [weak self, weak view] in
      let sessions = await client.listSessionsWithClients()
      guard let self, let view, self.surfaces[surfaceID] === view else { return }
      guard let sessions else {
        terminalStateLogger.info(
          "Closing unexpectedly exited zmx surface \(surfaceID) without killing session: probe failed."
        )
        self.closeSurfaceAndUpdateTabs(view, killZmxSession: false)
        return
      }
      guard let session = sessions.first(where: { $0.name == sessionID }) else {
        self.closeSurfaceAndUpdateTabs(view, killZmxSession: true)
        return
      }
      // Reattach only an idle session we positively own (0 clients). A session
      // with another attached client (clients > 0) or an unknown count (nil) must
      // never be destroyed, matching the orphan reaper's spare-on-in-use rule.
      guard let clients = session.clients, clients == 0 else {
        self.closeSurfaceAndUpdateTabs(view, killZmxSession: false)
        return
      }
      if !self.replaceUnexpectedZmxSurface(view) {
        self.closeSurfaceAndUpdateTabs(view, killZmxSession: false)
      }
    }
  }

  @discardableResult
  private func replaceUnexpectedZmxSurface(_ view: GhosttySurfaceView) -> Bool {
    guard let metadata = surfaceLaunchMetadata[view.id], metadata.usesZmx else { return false }
    guard zmxClient.executableURL() != nil else {
      terminalStateLogger.info(
        "Cannot replace unexpectedly exited zmx surface \(view.id): zmx executable unavailable."
      )
      return false
    }
    guard let tabId = tabID(containing: view.id), let tree = trees[tabId], let node = tree.find(id: view.id) else {
      return false
    }
    let previousState = surfaceStates[view.id]
    let replacement = createSurface(
      tabId: tabId,
      initialInput: nil,
      inheritingFromSurfaceId: view.id,
      context: metadata.context,
      surfaceID: view.id,
      bypassZmx: false,
      replacingExistingSurfaceID: true,
    )
    if let previousState {
      surfaceStates[view.id] = previousState
    }
    surfaceLaunchMetadata[view.id] = metadata
    do {
      let newTree = try tree.replacing(node: node, with: .leaf(view: replacement))
      view.closeSurface()
      bumpSurfaceGeneration(for: tabId)
      updateTree(newTree, for: tabId)
      updateRunningState(for: tabId)
      if focusedSurfaceIdByTab[tabId] == view.id {
        focusSurface(replacement, in: tabId)
      }
      terminalStateLogger.info("Reattached unexpectedly exited zmx surface \(view.id).")
      return true
    } catch {
      terminalStateLogger.warning("Failed to replace unexpectedly exited zmx surface \(view.id): \(error).")
      replacement.closeSurface()
      discardSurfaceBookkeeping(for: replacement.id)
      surfaces[view.id] = view
      if let previousState {
        surfaceStates[view.id] = previousState
      }
      surfaceLaunchMetadata[view.id] = metadata
      return false
    }
  }

  private func bumpSurfaceGeneration(for tabId: TerminalTabID) {
    surfaceGenerationByTab[tabId, default: 0] += 1
  }

  private func closeSurfaceAndUpdateTabs(
    _ view: GhosttySurfaceView,
    killZmxSession: Bool,
    includeRemoteSession: Bool = false
  ) {
    guard let tabId = tabID(containing: view.id), let tree = trees[tabId] else {
      view.closeSurface()
      cleanupSurfaceState(for: view.id)
      if killZmxSession {
        killZmxSessions(forSurfaceIDs: [view.id], includeRemote: includeRemoteSession)
      }
      return
    }
    guard let node = tree.find(id: view.id) else {
      view.closeSurface()
      cleanupSurfaceState(for: view.id)
      if killZmxSession {
        killZmxSessions(forSurfaceIDs: [view.id], includeRemote: includeRemoteSession)
      }
      return
    }
    let nextSurface =
      focusedSurfaceIdByTab[tabId] == view.id
      ? tree.focusTargetAfterClosing(node)
      : nil
    let newTree = tree.removing(node)
    view.closeSurface()
    cleanupSurfaceState(for: view.id)
    if killZmxSession {
      killZmxSessions(forSurfaceIDs: [view.id], includeRemote: includeRemoteSession)
    }
    if newTree.isEmpty {
      cancelHibernationTimer(for: tabId)
      removeFromPendingClose(tabId: tabId)
      trees.removeValue(forKey: tabId)
      focusedSurfaceIdByTab.removeValue(forKey: tabId)
      cleanupBlockingScriptLaunchDirectory(for: tabId)
      tabManager.closeTab(tabId)
      updateShouldHideTabBar()
      if let kind = blockingScripts.removeValue(forKey: tabId) {
        lastBlockingScriptTabByKind.removeValue(forKey: kind)

        onBlockingScriptCompleted?(kind, nil, nil)
      } else {
        for (kind, tracked) in lastBlockingScriptTabByKind where tracked == tabId {
          lastBlockingScriptTabByKind.removeValue(forKey: kind)
        }
      }
      emitTaskStatusIfChanged()
      // Closing the last surface via `close_surface` removes the tab here but
      // skips the `closeTab` projection path; emit one so `onTabRemoved` fires
      // and the layout persistence sink observes the tab going away.
      emitTabProjection(for: tabId)
      return
    }
    updateTree(newTree, for: tabId)
    updateRunningState(for: tabId)
    if focusedSurfaceIdByTab[tabId] == view.id {
      if let nextSurface {
        focusSurface(nextSurface, in: tabId)
      } else {
        focusedSurfaceIdByTab.removeValue(forKey: tabId)
      }
    }
    // Invariant: a tab with visible leaves must have a live, focused surface so
    // AppKit's firstResponder lands on something the user can type into. The
    // transfer above only fires when the closed surface was the recorded
    // focused one; re-check afterwards and push focus to the first visible
    // leaf when the recorded id still doesn't resolve to a live surface.
    if focusedSurfaceIdByTab[tabId].flatMap({ surfaces[$0] }) == nil,
      let fallback = newTree.visibleLeaves().first
    {
      focusSurface(fallback, in: tabId)
    }
  }

  // Selects the 1-based Nth tab, clamped to the last tab, matching Ghostty's `goto_tab:N`.
  func selectTabAtIndex(_ index: Int) {
    let tabs = tabManager.tabs
    guard index >= 1, !tabs.isEmpty else { return }
    selectTab(tabs[min(index - 1, tabs.count - 1)].id)
  }

  private func handleGotoTabRequest(_ target: ghostty_action_goto_tab_e) -> Bool {
    let tabs = tabManager.tabs
    guard !tabs.isEmpty else { return false }
    let raw = Int(target.rawValue)
    let selectedIndex = tabManager.selectedTabId.flatMap { selected in
      tabs.firstIndex { $0.id == selected }
    }
    let targetIndex: Int
    if raw <= 0 {
      switch raw {
      case Int(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue):
        let current = selectedIndex ?? 0
        targetIndex = (current - 1 + tabs.count) % tabs.count
      case Int(GHOSTTY_GOTO_TAB_NEXT.rawValue):
        let current = selectedIndex ?? 0
        targetIndex = (current + 1) % tabs.count
      case Int(GHOSTTY_GOTO_TAB_LAST.rawValue):
        targetIndex = tabs.count - 1
      default:
        return false
      }
    } else {
      targetIndex = min(raw - 1, tabs.count - 1)
    }
    selectTab(tabs[targetIndex].id)
    return true
  }

  private func mapDropZone(_ zone: TerminalSplitTreeView.DropZone)
    -> SplitTree<GhosttySurfaceView>.NewDirection
  {
    switch zone {
    case .top:
      return .top
    case .bottom:
      return .down
    case .left:
      return .left
    case .right:
      return .right
    }
  }

  private func nextTabIndex() -> Int {
    let prefix = "\(worktree.name) "
    var maxIndex = 0
    for tab in tabManager.tabs {
      guard tab.title.hasPrefix(prefix) else { continue }
      let suffix = tab.title.dropFirst(prefix.count)
      guard let value = Int(suffix) else { continue }
      maxIndex = max(maxIndex, value)
    }
    return maxIndex + 1
  }

  // MARK: - Hibernation

  /// Grace window a tab must stay hidden before it hibernates.
  private static let hibernationGraceWindow: Duration = .seconds(5 * 60)

  /// Marks whether this state's worktree is selected and re-diffs visibility.
  func setWorktreeSelected(_ selected: Bool) {
    guard isWorktreeSelected != selected else { return }
    isWorktreeSelected = selected
    refreshTabVisibility()
  }

  /// A tab is hidden unless it is the selected tab of the selected worktree.
  private func isTabHidden(_ tabId: TerminalTabID) -> Bool {
    !(isWorktreeSelected && tabManager.selectedTabId == tabId)
  }

  /// Diffs the hidden set against the scheduled timers: cancel for tabs that
  /// became visible or vanished, schedule for newly hidden live tabs. A treeless
  /// live tab (mid-creation) is scheduled once its tree lands via `splitTree`.
  func refreshTabVisibility() {
    let liveTabIDs = Set(tabManager.tabs.map(\.id))
    for scheduledTabId in Array(hibernationTimers.keys)
    where !liveTabIDs.contains(scheduledTabId) || !isTabHidden(scheduledTabId) {
      cancelHibernationTimer(for: scheduledTabId)
    }
    for tab in tabManager.tabs {
      guard isTabHidden(tab.id), trees[tab.id] != nil else { continue }
      guard hibernationTimers[tab.id] == nil else { continue }
      scheduleHibernationTimer(for: tab.id)
    }
  }

  /// Applies a flip of the hibernation Beta flag. Enabling re-arms grace timers
  /// for every currently hidden live tab; disabling cancels all pending timers so
  /// a mid-window flip never hibernates. Already-dormant tabs stay dormant.
  func applyHibernationEnabled(_ enabled: Bool) {
    isHibernationEnabled = enabled
    if enabled {
      refreshTabVisibility()
    } else {
      cancelAllHibernationTimers()
    }
  }

  private func scheduleHibernationTimer(for tabId: TerminalTabID) {
    // Inert while the Beta feature is off; a later opt-in re-arms via the
    // visibility funnel, so no timer is silently stranded.
    guard isHibernationEnabled else { return }
    let clock = hibernationClock
    hibernationTimers[tabId] = Task { [weak self] in
      do {
        try await clock.sleep(for: Self.hibernationGraceWindow)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.handleHibernationTimerFired(for: tabId)
    }
  }

  /// Cancels a tab's timer (the tab is now visible, gone, or hibernated).
  private func cancelHibernationTimer(for tabId: TerminalTabID) {
    hibernationTimers.removeValue(forKey: tabId)?.cancel()
    loggedIneligibleDeferralTabs.remove(tabId)
  }

  private func cancelAllHibernationTimers() {
    for task in hibernationTimers.values { task.cancel() }
    hibernationTimers.removeAll()
    loggedIneligibleDeferralTabs.removeAll()
  }

  /// The fire path runs in ONE synchronous main-actor turn: re-check the tab is
  /// still hidden and eligible, then hibernate or re-arm. No awaits between the
  /// check and teardown, so a concurrent selection can't slip a visible tab into
  /// hibernation. An actively-working agent does not block: its zmx session keeps
  /// the process alive and the dormant watcher keeps notifications lossless.
  private func handleHibernationTimerFired(for tabId: TerminalTabID) {
    hibernationTimers.removeValue(forKey: tabId)
    // Re-check at fire time so a flip to off mid-window never hibernates.
    guard isHibernationEnabled else { return }
    guard hasTab(tabId), isTabHidden(tabId) else {
      // Tab gone or now visible: nothing re-arms it (becoming hidden reschedules
      // via the visibility funnel).
      return
    }
    guard canHibernate(tabId: tabId) else {
      // Still hidden but momentarily ineligible (e.g. a non-zmx leaf); re-arm so
      // a later eligibility flip still hibernates instead of wedging forever.
      // Log once until the tab becomes eligible or visible again, so a permanently
      // ineligible hidden tab doesn't spam every grace-window re-fire.
      if loggedIneligibleDeferralTabs.insert(tabId).inserted {
        terminalStateLogger.debug("Hibernation for tab \(tabId.rawValue) deferred: not currently eligible; re-armed.")
      }
      scheduleHibernationTimer(for: tabId)
      return
    }
    loggedIneligibleDeferralTabs.remove(tabId)
    performHibernation(tabId)
  }

  /// Resolves the frozen agent records, warning once and returning nil when the
  /// closure is unwired so callers distinguish "no agents" from "no wiring".
  private func resolvedAgentsBySurface() -> [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]? {
    guard let agents = hibernationAgentsBySurface?() else {
      warnMissingAgentsClosureOnce()
      return nil
    }
    return agents
  }

  /// Warns once per state instance when the agent-records closure is unwired, so
  /// broken wiring is not silently read as "no agents".
  private func warnMissingAgentsClosureOnce() {
    guard !hasLoggedMissingAgentsClosure else { return }
    hasLoggedMissingAgentsClosure = true
    terminalStateLogger.warning(
      "hibernationAgentsBySurface closure is unwired for worktree \(worktree.id); treating as no agents.")
  }

  /// Frozen leaves that failed to rebuild on wake: present in the stashed layout
  /// but absent from the rebuilt tree, so their zmx sessions are orphaned.
  nonisolated static func orphanedWakeLeafIDs(expected: [UUID], rebuilt: Set<UUID>) -> [UUID] {
    expected.filter { !rebuilt.contains($0) }
  }

  /// True when an OSC 9 payload is a ConEmu subcommand (its first `;`-separated
  /// field is an integer 1...12), not an iTerm2 notification body. Mirrors
  /// libghostty's OSC-9 ConEmu-vs-notification split.
  nonisolated static func isConEmuOSC9Payload(_ payload: String) -> Bool {
    guard let subcommand = Int(payload.prefix { $0 != ";" }) else { return false }
    return (1...12).contains(subcommand)
  }

  /// Whether a tab may hibernate. A blocking-script tab is excluded (it dies with
  /// the app), and every leaf must be zmx-wrapped or teardown would kill a shell
  /// that can't reattach.
  func canHibernate(tabId: TerminalTabID) -> Bool {
    guard let tree = trees[tabId], tree.root != nil else { return false }
    guard !tabManager.isBlockingScript(tabId) else { return false }
    // An alert is waiting on this tab; hibernating would tear its target down
    // and drop the user's close request without a trace.
    guard !hasPendingCloseConfirmation(forTabID: tabId) else { return false }
    return tree.leaves().allSatisfy { surfaceLaunchMetadata[$0.id]?.usesZmx == true }
  }

  private func hasPendingCloseConfirmation(forTabID tabId: TerminalTabID) -> Bool {
    switch pendingCloseConfirmation?.target {
    case .surface(let surfaceID): tabID(containing: surfaceID) == tabId
    case .tabs(let tabIDs): tabIDs.contains(tabId)
    case nil: false
    }
  }

  /// Hibernates a tab: freeze the layout, tear down the leaf surfaces WITHOUT
  /// killing their zmx sessions or dropping presence, and keep the tab in
  /// `tabManager` so its row, title, and unseen count survive. Surfaces return
  /// with the same UUIDs on wake so `zmx attach` reattaches.
  func hibernateTab(_ tabId: TerminalTabID) {
    guard canHibernate(tabId: tabId) else { return }
    performHibernation(tabId)
  }

  /// Explicit wake for CLI / deeplink / unread-jump call sites. Routes through
  /// the single `splitTree` wake funnel.
  func wakeTab(_ tabId: TerminalTabID) {
    _ = splitTree(for: tabId)
  }

  /// Shared teardown for `hibernateTab` and the DEBUG bypass seam. Captures the
  /// dormant layout, drops the tree plus per-tab focus / generation and surface
  /// bookkeeping, and cancels the manager's idle hooks without a presence drop.
  private func performHibernation(_ tabId: TerminalTabID) {
    guard let tree = trees[tabId], let root = tree.root else { return }
    // The tab is going dormant; a leftover timer (manual hibernate path) must not
    // survive to fire into the dormant entry.
    cancelHibernationTimer(for: tabId)
    let leaves = root.leaves()
    let leafIDs = leaves.map(\.id)
    // Freeze the live agent records into the layout so a snapshot persisted while
    // dormant keeps its presence badges and image-paste routing across relaunch.
    let layout = captureLayoutNode(root, agentsBySurface: resolvedAgentsBySurface() ?? [:])
    let focusedId = focusedSurfaceIdByTab[tabId]
    let focusedLeafIndex = focusedId.flatMap { id in leaves.firstIndex(where: { $0.id == id }) }
    // The assignment fires the didSet, starting the dormant-session watchers.
    dormantTabLayouts[tabId] = DormantTabLayout(
      layout: layout,
      focusedLeafIndex: focusedLeafIndex,
      zoomedSurfaceID: tree.zoomed?.leftmostLeaf().id
    )
    // Teardown in one turn: the `surfaces[id] === view` guards in the close /
    // unexpected-close handlers make any late callback or in-flight probe inert.
    trees.removeValue(forKey: tabId)
    surfaceGenerationByTab.removeValue(forKey: tabId)
    focusedSurfaceIdByTab.removeValue(forKey: tabId)
    for leaf in leaves {
      leaf.closeSurface()
      discardSurfaceBookkeeping(for: leaf.id, preserveSurfaceState: true)
    }
    onSurfacesHibernated?(Set(leafIDs))
    emitTabProjection(for: tabId)
    // The torn-down tree emits no more OSC progress, so clear the stripe and
    // re-derive task status without this tab (dormant progress is ConEmu-dropped).
    emitTabProgressDisplay(for: tabId)
    emitTaskStatusIfChanged()
    onDormancyChanged?()
  }

  /// Reconciles the passive session watchers against the current dormant leaf
  /// set. Stopping a watcher closes its socket, so on an explicit close this runs
  /// before the session kill.
  private func syncDormantSessionWatchers() {
    let dormantSurfaceIDs = Set(dormantLeafSurfaceIDs)
    dormantSessionWatchers.reconcile(dormantSurfaceIDs: dormantSurfaceIDs)
  }

  /// Single ingress for a dormant session's OSC signal, routed into the same
  /// notification / presence / title handlers a live surface uses. Accepts a
  /// live-or-dormant surface (wake/close overlap), drops unknown; delivered once.
  private func handleDormantOSCSequence(surfaceID: UUID, sequence: ZmxOSCSequence) {
    guard isKnownSurface(surfaceID) else { return }
    switch sequence.code {
    case 9:
      // OSC 9 is shared by iTerm2 notifications and ConEmu subcommands (progress,
      // sleep, ...); a leading small-integer field marks a ConEmu form, not a body.
      guard let body = sequence.payloadString else {
        logDroppedNonUTF8DormantOSC(surfaceID: surfaceID, code: sequence.code)
        return
      }
      guard !Self.isConEmuOSC9Payload(body) else {
        terminalStateLogger.debug("Dropped ConEmu-shaped OSC 9 for dormant surface \(surfaceID).")
        return
      }
      handleAgentOSCNotification(title: "", body: body, surfaceID: surfaceID)
    case 3008:
      guard let payload = sequence.payloadString else {
        logDroppedNonUTF8DormantOSC(surfaceID: surfaceID, code: sequence.code)
        return
      }
      guard let fields = Self.contextSignalFields(payload: payload) else { return }
      handleContextSignal(surfaceID: surfaceID, id: fields.id, metadata: fields.metadata)
    case 0, 2:
      guard let title = sequence.payloadString else {
        logDroppedNonUTF8DormantOSC(surfaceID: surfaceID, code: sequence.code)
        return
      }
      updateDormantTabTitle(surfaceID: surfaceID, title: title)
    default:
      break
    }
  }

  private func logDroppedNonUTF8DormantOSC(surfaceID: UUID, code: Int) {
    terminalStateLogger.debug("Dropped dormant OSC \(code) with non-UTF-8 payload for surface \(surfaceID).")
  }

  /// Updates a dormant tab's row title from an OSC 0/2 on its focused leaf,
  /// mirroring the live `updateTabTitle` where only the focused surface drives
  /// the row. A now-live surface is skipped: its own title pipeline is authoritative.
  private func updateDormantTabTitle(surfaceID: UUID, title: String) {
    guard let tabId = tabID(containing: surfaceID),
      let dormant = dormantTabLayouts[tabId]
    else { return }
    let focusedLeaf = dormant.focusedLeafIndex.flatMap { index in
      dormant.layout.leafSurfaceIDs.indices.contains(index) ? dormant.layout.leafSurfaceIDs[index] : nil
    }
    guard focusedLeaf == surfaceID else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    tabManager.updateTitle(tabId, title: trimmed)
  }

  /// Rebuilds a hibernated tab's tree from its frozen layout via the shared
  /// restore core and re-applies zoom. No generation bump (the nil->tree
  /// transition invalidates by itself) and no AppKit first-responder calls, since
  /// this may run from a view-body evaluation.
  private func wakeDormantTab(
    _ tabId: TerminalTabID,
    dormant: DormantTabLayout
  ) -> SplitTree<GhosttySurfaceView> {
    // Re-derive the anchor context from the live tab order (mirrors
    // `restoreFromSnapshot`), so a since-closed first tab wakes the now-first tab
    // as WINDOW instead of replaying a context frozen at hibernate.
    let isFirstTab = tabManager.tabs.first?.id == tabId
    let context: ghostty_surface_context_e =
      isFirstTab ? GHOSTTY_SURFACE_CONTEXT_WINDOW : GHOSTTY_SURFACE_CONTEXT_TAB
    restoreTabLayout(
      tabId: tabId,
      layout: dormant.layout,
      focusedLeafIndex: dormant.focusedLeafIndex ?? 0,
      context: context
    )
    guard let tree = trees[tabId] else { return SplitTree() }
    if let zoomedID = dormant.zoomedSurfaceID,
      let zoomedSurface = surfaces[zoomedID],
      let node = tree.root?.node(view: zoomedSurface)
    {
      setTree(tree.settingZoomed(node), for: tabId)
    }
    // The unseen counters rode through hibernation on the preserved
    // `surfaceStates`, re-adopted here under the original UUIDs; wake neither
    // re-derives nor clears them.
    return trees[tabId] ?? SplitTree()
  }

  /// Explicit close of a hibernated tab: kill its frozen zmx sessions, drop the
  /// presence records, and purge the dormant entry synchronously so an orphan
  /// can't feed the next-launch reaper. No live surfaces exist to close.
  private func removeDormantTab(_ tabId: TerminalTabID) {
    // `removeValue` fires the didSet, stopping the leaf watchers (closing their
    // sockets) before the session kill below.
    guard let dormant = dormantTabLayouts.removeValue(forKey: tabId) else { return }
    let leafIDs = dormant.layout.leafSurfaceIDs
    surfaceGenerationByTab.removeValue(forKey: tabId)
    var clearedUnseen = false
    for leafID in leafIDs {
      clearedUnseen = discardDormantLeafSurfaceState(for: leafID) || clearedUnseen
    }
    killZmxSessions(forSurfaceIDs: leafIDs, includeRemote: true)
    onSurfacesClosed?(Set(leafIDs))
    if clearedUnseen { onNotificationIndicatorChanged?() }
    if lastTabProjections.removeValue(forKey: tabId) != nil {
      onTabRemoved?(tabId)
    }
  }

  #if DEBUG
    /// Test-only seam for bulk-assigning the notifications log, fanning
    /// `emitAllTabProjections()` so `lastTabProjections` stays in sync with the
    /// raw log. Production writes go through the per-event helpers, which emit.
    func setNotificationsForTesting(_ list: [WorktreeTerminalNotification]) {
      notifications = list
      rebuildUnseenCounters()
      emitAllTabProjections()
    }

    /// Test-only seam for installing a synthetic `WorktreeSurfaceState` without
    /// minting a real Ghostty surface. Production writes are gated to
    /// `createSurface` / `cleanupSurfaceState`.
    func installSurfaceStateForTesting(_ state: WorktreeSurfaceState, forSurfaceID surfaceID: UUID) {
      surfaceStates[surfaceID] = state
    }

    /// Test-only seam that hibernates a tab while bypassing `canHibernate`, so
    /// tests can exercise the dormant path without a live zmx executable making
    /// every surface eligible. Shares `performHibernation` with production.
    func hibernateTabForTesting(_ tabId: TerminalTabID) {
      performHibernation(tabId)
    }

    /// Tabs with a live grace timer, so visibility / cancel behavior is
    /// assertable without reaching into the private dict.
    var scheduledHibernationTabsForTesting: Set<TerminalTabID> { Set(hibernationTimers.keys) }

    /// Surface ids currently tailed by a dormant-session watcher, so the
    /// `watched == dormant leaves` invariant is assertable without a live socket.
    var watchedDormantSurfaceIDsForTesting: Set<UUID> { dormantSessionWatchers.watchedSurfaceIDs }

    /// Resolved surface context (WINDOW vs TAB) for a live surface, so the
    /// wake-time context re-derivation is assertable.
    func surfaceContextForTesting(_ surfaceID: UUID) -> ghostty_surface_context_e? {
      surfaceLaunchMetadata[surfaceID]?.context
    }

    /// Drives the fire path directly so the fire-time re-check backstops (tab
    /// gone, tab visible) are assertable without a real grace-window elapse.
    func fireHibernationTimerForTesting(_ tabId: TerminalTabID) {
      handleHibernationTimerFired(for: tabId)
    }

    /// Drives a dormant-session OSC straight into the ingest, so the watcher's
    /// delivery path (notifications / presence / titles, and the wake-overlap
    /// acceptance rule) is assertable without a live socket.
    func deliverDormantOSCForTesting(surfaceID: UUID, sequence: ZmxOSCSequence) {
      handleDormantOSCSequence(surfaceID: surfaceID, sequence: sequence)
    }

  #endif
}
