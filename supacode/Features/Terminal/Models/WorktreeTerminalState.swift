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

  init(
    tabID: TerminalTabID,
    surfaceIDs: [UUID],
    activeSurfaceID: UUID?,
    unseenNotificationCount: Int,
    isSplitZoomed: Bool = false,
    surfaceGeneration: Int = 0,
  ) {
    self.tabID = tabID
    self.surfaceIDs = surfaceIDs
    self.activeSurfaceID = activeSurfaceID
    self.unseenNotificationCount = unseenNotificationCount
    self.isSplitZoomed = isSplitZoomed
    self.surfaceGeneration = surfaceGeneration
  }
}

@MainActor
@Observable
final class WorktreeTerminalState {
  struct SurfaceActivity: Equatable {
    let isVisible: Bool
    let isFocused: Bool
  }

  private struct SurfaceLaunchMetadata {
    let usesZmx: Bool
    let context: ghostty_surface_context_e
  }

  let tabManager: TerminalTabManager
  private let runtime: GhosttyRuntime
  @ObservationIgnored private let splitPreserveZoomOnNavigation: () -> Bool
  private let worktree: Worktree
  @ObservationIgnored
  @SharedReader private var repositorySettings: RepositorySettings
  // Observed: any mutation re-renders `WorktreeTerminalTabsView`. Mutate only
  // from user-initiated structural changes; per-surface churn must stay on
  // `surfaceStates` / `WorktreeTabProjection` to keep agent storms cold.
  private var trees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
  @ObservationIgnored private var surfaces: [UUID: GhosttySurfaceView] = [:]
  // `usesZmx` + `context` retained per surface so an unexpected zmx exit can recreate it on reattach.
  @ObservationIgnored private var surfaceLaunchMetadata: [UUID: SurfaceLaunchMetadata] = [:]
  // Surfaces the user explicitly closed, so an unexpected zmx exit isn't mistaken for one and reattached.
  @ObservationIgnored private var pendingExplicitSurfaceCloseIDs: Set<UUID> = []
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
  private var blockingScripts: [TerminalTabID: BlockingScriptKind] = [:]
  private var blockingScriptLaunchDirectories: [TerminalTabID: URL] = [:]
  private var lastBlockingScriptTabByKind: [BlockingScriptKind: TerminalTabID] = [:]
  private var pendingSetupScript: Bool
  /// Sticky after first attempt so a reselect after `closeAllTabs` doesn't auto-recreate.
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
  var hasUnseenNotification: Bool {
    notifications.contains { !$0.isRead }
  }

  func hasUnseenNotification(forSurfaceID surfaceID: UUID) -> Bool {
    notifications.contains { !$0.isRead && $0.surfaceID == surfaceID }
  }

  func hasUnseenNotification(forTabID tabID: TerminalTabID) -> Bool {
    guard let tree = trees[tabID] else { return false }
    let surfaceIDs = Set(tree.leaves().map(\.id))
    return notifications.contains { !$0.isRead && surfaceIDs.contains($0.surfaceID) }
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
  var onCommandPaletteToggle: (() -> Void)?
  var onSetupScriptConsumed: (() -> Void)?
  /// Forwarded to the manager so it can emit a `surfacesClosed` event into TCA.
  var onSurfacesClosed: ((Set<UUID>) -> Void)?
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
    splitPreserveZoomOnNavigation: (() -> Bool)? = nil
  ) {
    self.runtime = runtime
    self.splitPreserveZoomOnNavigation = splitPreserveZoomOnNavigation ?? { runtime.splitPreserveZoomOnNavigation() }
    self.worktree = worktree
    self.pendingSetupScript = runSetupScript
    self.tabManager = TerminalTabManager()
    _repositorySettings = SharedReader(
      wrappedValue: RepositorySettings.default,
      .repositorySettings(worktree.repositoryRootURL, host: worktree.host)
    )
    // Pre-hide the tab bar before the first tab is created to
    // avoid a visible flash. updateShouldHideTabBar() handles
    // the steady state once tabs exist.
    @Shared(.settingsFile) var settingsFile
    self.shouldHideTabBar = settingsFile.global.hideSingleTabBar
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
    )
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
    tabID: UUID? = nil
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
      else { return nil }
      command = remote
      initialInput = nil
      launchDirectory = nil
    } else {
      let launch: BlockingScriptRunner.LaunchArtifacts
      do {
        guard let prepared = try blockingScriptLaunch(script) else { return nil }
        launch = prepared
      } catch {
        blockingScriptLogger.warning("Failed to prepare \(kind.tabTitle) for worktree \(worktree.id): \(error)")
        onBlockingScriptCompleted?(kind, 1, nil)
        return nil
      }
      command = defaultShellPath()
      initialInput = launch.commandInput
      launchDirectory = launch.directoryURL
    }
    // Close any previous tab of the same kind (active or lingering
    // from a completed/cancelled run). Clear tracking state first
    // so closeTab doesn't fire a premature completion callback.
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
      blockingScriptLogger.warning("Failed to create \(kind.tabTitle) tab for worktree \(worktree.id)")
      onBlockingScriptCompleted?(kind, 1, nil)
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

  private struct TabCreation: Equatable {
    let title: String
    let icon: String?
    let isTitleLocked: Bool
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

  /// Surface IDs in a single tab (one entry per leaf of the tab's split tree).
  /// Empty if the tab does not exist.
  func surfaceIDs(inTab tabId: TerminalTabID) -> [UUID] {
    trees[tabId]?.leaves().map(\.id) ?? []
  }

  /// All surface IDs across every tab in this worktree state.
  var allSurfaceIDs: [UUID] {
    trees.values.flatMap { $0.leaves().map(\.id) }
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
  var hasAnySurface: Bool { !surfaces.isEmpty }

  func hasSurface(_ surfaceID: UUID, in tabId: TerminalTabID) -> Bool {
    guard let tree = trees[tabId] else { return false }
    return tree.find(id: surfaceID) != nil
  }

  /// Checks whether a surface UUID exists anywhere in the worktree (across all tabs).
  func hasSurfaceAnywhere(_ surfaceID: UUID) -> Bool {
    surfaces[surfaceID] != nil
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
    guard let tabId = tabID(containing: id),
      let surface = surfaces[id]
    else {
      terminalStateLogger.warning("focusSurface: surface \(id) not found in worktree \(worktree.id).")
      return false
    }
    tabManager.selectTab(tabId)
    focusSurface(surface, in: tabId)
    return true
  }

  @discardableResult
  func closeFocusedTab() -> Bool {
    guard let tabId = tabManager.selectedTabId else { return false }
    closeTab(tabId)
    return true
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
    requestExplicitSurfaceClose(surface)
    return true
  }

  private func requestExplicitSurfaceClose(_ surface: GhosttySurfaceView) {
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

  private func performBindingAction(_ action: String, on surface: GhosttySurfaceView) {
    if action == "close_surface" {
      pendingExplicitSurfaceCloseIDs.insert(surface.id)
    }
    surface.performBindingAction(action)
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

  func closeTab(_ tabId: TerminalTabID) {
    let closedBlockingKind = blockingScripts.removeValue(forKey: tabId)
    cleanupBlockingScriptLaunchDirectory(for: tabId)
    // Clear lingering tab tracking for completed or non-blocking tabs.
    for (kind, tracked) in lastBlockingScriptTabByKind where tracked == tabId {
      lastBlockingScriptTabByKind.removeValue(forKey: kind)
    }
    removeTree(for: tabId)
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

  /// User-initiated rename. Routes through the manager so the new title (or its
  /// removal on an empty commit) persists incrementally, unlike the restore path
  /// which seeds `setCustomTitle` directly from a snapshot.
  func renameTab(_ tabId: TerminalTabID, title: String) {
    tabManager.setCustomTitle(tabId, title: title)
    onTabRenamed?()
  }

  func closeOtherTabs(keeping tabId: TerminalTabID) {
    let ids = tabManager.tabs.map(\.id).filter { $0 != tabId }
    for id in ids {
      closeTab(id)
    }
  }

  func closeTabsToRight(of tabId: TerminalTabID) {
    guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
    let ids = tabManager.tabs.dropFirst(index + 1).map(\.id)
    for id in ids {
      closeTab(id)
    }
  }

  func closeAllTabs() {
    let ids = tabManager.tabs.map(\.id)
    for id in ids {
      closeTab(id)
    }
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

  func closeAllSurfaces() {
    let closingSurfaces = Array(surfaces.values)
    let closingSurfaceIDs = closingSurfaces.map(\.id)
    for surface in closingSurfaces {
      surface.closeSurface()
    }
    for surfaceID in closingSurfaceIDs {
      discardSurfaceBookkeeping(for: surfaceID)
    }
    cleanupBlockingScriptLaunchDirectories()
    trees.removeAll()
    surfaceGenerationByTab.removeAll()
    focusedSurfaceIdByTab.removeAll()
    onSurfacesClosed?(Set(closingSurfaceIDs))
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
    clearAllSurfaceUnseenFlags()
    emitAllTabProjections()
    emitNotificationStateChanged()
  }

  func markNotificationsRead(forSurfaceID surfaceID: UUID) {
    for index in notifications.indices where notifications[index].surfaceID == surfaceID {
      notifications[index].isRead = true
    }
    setSurfaceUnseenFlag(surfaceID, to: false)
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
    refreshSurfaceUnseenFlag(surfaceID)
    if let tabId = tabID(containing: surfaceID) {
      emitTabProjection(for: tabId)
    }
    emitNotificationStateChanged()
  }

  func dismissNotification(_ notificationID: WorktreeTerminalNotification.ID) {
    let affectedSurface = notifications.first(where: { $0.id == notificationID })?.surfaceID
    notifications.removeAll { $0.id == notificationID }
    if let affectedSurface {
      refreshSurfaceUnseenFlag(affectedSurface)
      if let tabId = tabID(containing: affectedSurface) {
        emitTabProjection(for: tabId)
      }
    }
    emitNotificationStateChanged()
  }

  func dismissAllNotifications() {
    notifications.removeAll()
    clearAllSurfaceUnseenFlags()
    emitAllTabProjections()
    emitNotificationStateChanged()
  }

  /// Recomputes the surface's unseen flag through the canonical predicate so a
  /// future tweak to `hasUnseenNotification(forSurfaceID:)` is picked up here
  /// without a parallel branch silently drifting.
  private func refreshSurfaceUnseenFlag(_ surfaceID: UUID) {
    setSurfaceUnseenFlag(surfaceID, to: hasUnseenNotification(forSurfaceID: surfaceID))
  }

  private func setSurfaceUnseenFlag(_ surfaceID: UUID, to value: Bool) {
    guard let state = surfaceStates[surfaceID] else { return }
    guard state.hasUnseenNotification != value else { return }
    state.hasUnseenNotification = value
  }

  private func clearAllSurfaceUnseenFlags() {
    for state in surfaceStates.values where state.hasUnseenNotification {
      state.hasUnseenNotification = false
    }
  }

  // MARK: - Layout Snapshot

  /// Capture a layout snapshot, optionally embedding per-surface agent
  /// presence records. The caller (AppDelegate's `applicationWillTerminate`
  /// path) reads `AppFeature.State.agentPresence.records` and converts it
  /// into the per-surface dict before invoking this so agents persist
  /// atomically with their owning surface and vanish on prune.
  func captureLayoutSnapshot(
    agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]] = [:]
  ) -> TerminalLayoutSnapshot? {
    guard !tabManager.tabs.isEmpty else { return nil }
    var tabSnapshots: [TerminalLayoutSnapshot.TabSnapshot] = []
    for tab in tabManager.tabs {
      // Blocking-script tabs die with the app; persisting them would resurrect a dead session.
      if tab.isBlockingScript { continue }
      guard let tree = trees[tab.id], let root = tree.root else {
        layoutLogger.warning("Skipping tab \(tab.id.rawValue) during snapshot capture (no tree)")
        continue
      }
      let layout = captureLayoutNode(root, agentsBySurface: agentsBySurface)
      let leaves = root.leaves()
      let focusedId = focusedSurfaceIdByTab[tab.id]
      let focusedLeafIndex =
        focusedId.flatMap { id in
          leaves.firstIndex(where: { $0.id == id })
        } ?? 0
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

  private func restoreFromSnapshot(_ snapshot: TerminalLayoutSnapshot, focusing: Bool) {
    guard !snapshot.tabs.isEmpty else {
      layoutLogger.warning("Attempted to restore empty layout snapshot, skipping restoration.")
      return
    }

    // Skip setup script when restoring a saved layout.
    pendingSetupScript = false

    for (index, tabSnapshot) in snapshot.tabs.enumerated() {
      let firstLeafPwd = tabSnapshot.layout.firstLeaf.workingDirectory
      let workingDir = firstLeafPwd.flatMap { URL(filePath: $0, directoryHint: .isDirectory) }
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
      let surface = createSurface(
        tabId: tabId,
        initialInput: nil,
        workingDirectoryOverride: workingDir,
        inheritingFromSurfaceId: nil,
        context: context,
        surfaceID: tabSnapshot.layout.firstLeaf.id,
      )
      let tree = SplitTree(view: surface)
      setTree(tree, for: tabId)
      setFocusedSurface(surface.id, for: tabId)

      // Recursively restore splits.
      restoreLayoutNode(tabSnapshot.layout, anchor: surface, tabId: tabId)

      // Log if partial restoration produced fewer panes than expected.
      let leaves = trees[tabId]?.root?.leaves() ?? []
      let expectedLeaves = tabSnapshot.layout.leafCount
      if leaves.count != expectedLeaves {
        layoutLogger.warning(
          "Partial restore for tab '\(tabSnapshot.title)': expected \(expectedLeaves) panes, got \(leaves.count)"
        )
      }

      // Focus the correct leaf.
      let focusedIndex = max(0, min(tabSnapshot.focusedLeafIndex, leaves.count - 1))
      if focusedIndex < leaves.count {
        setFocusedSurface(leaves[focusedIndex].id, for: tabId)
      }

      onTabCreated?()
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

    // Notifications outlive surfaces, so re-derive the freshly minted
    // `WorktreeSurfaceState` flags or the per-surface dot stays dark after restore.
    for surfaceID in Set(notifications.map(\.surfaceID)) {
      refreshSurfaceUnseenFlag(surfaceID)
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

  // Fires when the shell process exits on its own (e.g. user types
  // exit or presses Ctrl+D). If the command already finished, this
  // is a no-op because `blockingScripts[tabId]` was cleared in
  // `handleBlockingScriptCommandFinished`. Otherwise the script was
  // interrupted before completing, so we treat it as cancellation.
  private func handleBlockingScriptChildExited(tabId: TerminalTabID, exitCode: UInt32) {
    guard let kind = blockingScripts.removeValue(forKey: tabId) else { return }
    blockingScriptLogger.info("\(kind.tabTitle) cancelled (shell exited before command finished)")
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
    surfaceStates[view.id] = WorktreeSurfaceState()
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
    view.bridge.onCloseTab = { [weak self, weak view] _ in
      guard let self, let view, self.isLiveSurface(view) else { return false }
      self.closeTab(tabId)
      return true
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
    view.bridge.onCloseRequest = { [weak self, weak view] processAlive in
      guard let self, let view else { return }
      self.handleCloseRequest(for: view, processAlive: processAlive)
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
      surfaceExists: surfaces[surfaceID] != nil
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

  /// Parse an OSC 3008 notify signal for the receiving surface, then sanitize and
  /// display it. Gated by the rich-notifications setting.
  private func handleNotifySignal(surfaceID: UUID, id: String, metadata: String) {
    switch Self.notification(
      id: id,
      metadata: metadata,
      surfaceExists: surfaces[surfaceID] != nil
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
    guard surfaces[surfaceID] != nil else {
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
      guard self.surfaces[surfaceID] != nil else { return }
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
      refreshSurfaceUnseenFlag(surfaceID)
      if let tabId = tabID(containing: surfaceID) {
        emitTabProjection(for: tabId)
      }
      emitNotificationStateChanged()
    }
    onNotificationReceived?(surfaceID, trimmedTitle, trimmedBody, isViewed)
  }

  /// Detaches one surface from the local bookkeeping. The zmx session is NOT
  /// killed here; callers route the kill through `killZmxSessions(forSurfaceIDs:)`
  /// so a single multi-pane close emits one `count=N` analytics event + one
  /// `withTaskGroup` instead of N events and N detached Tasks.
  /// Also cancels any held agent OSC 9 and forgets the last-custom-notification
  /// instant so a future surface ID can't reuse stale dedupe state.
  private func discardSurfaceBookkeeping(for surfaceID: UUID) {
    pendingAgentOSCNotifications.removeValue(forKey: surfaceID)?.cancel()
    lastCustomNotificationAt.removeValue(forKey: surfaceID)
    surfaces.removeValue(forKey: surfaceID)
    surfaceLaunchMetadata.removeValue(forKey: surfaceID)
    pendingExplicitSurfaceCloseIDs.remove(surfaceID)
    surfaceStates.removeValue(forKey: surfaceID)
  }

  private func cleanupSurfaceState(for surfaceID: UUID) {
    discardSurfaceBookkeeping(for: surfaceID)
    onSurfacesClosed?([surfaceID])
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
          if killLocal {
            group.addTask { await client.killSession(id) }
          }
          if let host {
            group.addTask { await client.killRemoteSession(host, id) }
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
      surfaceGenerationByTab.removeValue(forKey: tabId)
      if lastTabProjections.removeValue(forKey: tabId) != nil {
        onTabRemoved?(tabId)
      }
      return
    }
    let surfaceIDs = tree.leaves().map(\.id)
    let surfaceIDSet = Set(surfaceIDs)
    let unseenCount = notifications.reduce(into: 0) { partial, notification in
      if !notification.isRead, surfaceIDSet.contains(notification.surfaceID) {
        partial += 1
      }
    }
    let projection = WorktreeTabProjection(
      tabID: tabId,
      surfaceIDs: surfaceIDs,
      activeSurfaceID: focusedSurfaceIdByTab[tabId],
      unseenNotificationCount: unseenCount,
      isSplitZoomed: tree.zoomed != nil,
      surfaceGeneration: surfaceGenerationByTab[tabId, default: 0],
    )
    guard lastTabProjections[tabId] != projection else { return }
    lastTabProjections[tabId] = projection
    onTabProjectionChanged?(projection)
  }

  /// Recompute every tab's projection. Used after notification-list mutations
  /// that may span multiple tabs (mark-all-read, dismiss-all).
  private func emitAllTabProjections() {
    for tabId in trees.keys {
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

  private func handleCloseRequest(for view: GhosttySurfaceView, processAlive _: Bool) {
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

  #if DEBUG
    /// Test-only seam for bulk-assigning the notifications log. Fans
    /// `emitAllTabProjections()` so `lastTabProjections` stays in sync with
    /// the raw log; production code must go through the per-event helpers
    /// (`appendHookNotification`, `markNotificationsRead`, etc.) which already
    /// emit. Gated `#if DEBUG` so release builds genuinely can't reach the
    /// projection-bypass path.
    func setNotificationsForTesting(_ list: [WorktreeTerminalNotification]) {
      notifications = list
      clearAllSurfaceUnseenFlags()
      for surfaceID in Set(list.map(\.surfaceID)) {
        refreshSurfaceUnseenFlag(surfaceID)
      }
      emitAllTabProjections()
    }

    /// Test-only seam for installing a synthetic `WorktreeSurfaceState` without
    /// minting a real Ghostty surface. Production writes are gated to
    /// `createSurface` / `cleanupSurfaceState`.
    func installSurfaceStateForTesting(_ state: WorktreeSurfaceState, forSurfaceID surfaceID: UUID) {
      surfaceStates[surfaceID] = state
    }

  #endif
}
