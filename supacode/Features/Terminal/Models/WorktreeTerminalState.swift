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

  init(
    tabID: TerminalTabID,
    surfaceIDs: [UUID],
    activeSurfaceID: UUID?,
    unseenNotificationCount: Int,
    isSplitZoomed: Bool = false
  ) {
    self.tabID = tabID
    self.surfaceIDs = surfaceIDs
    self.activeSurfaceID = activeSurfaceID
    self.unseenNotificationCount = unseenNotificationCount
    self.isSplitZoomed = isSplitZoomed
  }
}

@MainActor
@Observable
final class WorktreeTerminalState {
  struct SurfaceActivity: Equatable {
    let isVisible: Bool
    let isFocused: Bool
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
  private var isEnsuringInitialTab = false
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
  private var recentHookBySurfaceID: [UUID: (text: String, recordedAt: Date)] = [:]
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

  #if DEBUG
    var debugRecentHookCount: Int {
      recentHookBySurfaceID.count
    }
  #endif
  var isSelected: () -> Bool = { false }
  var onNotificationReceived: ((UUID, String, String) -> Void)?
  var onNotificationIndicatorChanged: (() -> Void)?
  var onTabCreated: (() -> Void)?
  var onTabClosed: (() -> Void)?
  var onFocusChanged: ((UUID) -> Void)?
  var onTaskStatusChanged: ((WorktreeTaskStatus) -> Void)?
  var onBlockingScriptCompleted: ((BlockingScriptKind, Int?, TerminalTabID?) -> Void)?
  var onCommandPaletteToggle: (() -> Void)?
  var onSetupScriptConsumed: (() -> Void)?
  /// Forwarded to the manager so it can emit a `surfacesClosed` event into TCA.
  var onSurfacesClosed: ((Set<UUID>) -> Void)?
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
      .repositorySettings(worktree.repositoryRootURL)
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
    guard tabManager.tabs.isEmpty else { return }
    guard !isEnsuringInitialTab else { return }
    isEnsuringInitialTab = true

    if let snapshot = pendingLayoutSnapshot {
      pendingLayoutSnapshot = nil
      restoreFromSnapshot(snapshot, focusing: focusing)
      isEnsuringInitialTab = false
      return
    }

    Task {
      let setupScript: String?
      if pendingSetupScript {
        setupScript = repositorySettings.setupScript
      } else {
        setupScript = nil
      }
      await MainActor.run {
        if tabManager.tabs.isEmpty {
          _ = createTab(focusing: focusing, setupScript: setupScript)
        }
        isEnsuringInitialTab = false
      }
    }
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
    let launch: BlockingScriptRunner.LaunchArtifacts
    do {
      guard let prepared = try blockingScriptLaunch(script) else { return nil }
      launch = prepared
    } catch {
      blockingScriptLogger.warning("Failed to prepare \(kind.tabTitle) for worktree \(worktree.id): \(error)")
      onBlockingScriptCompleted?(kind, 1, nil)
      return nil
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
        command: defaultShellPath(),
        initialInput: launch.commandInput,
        focusing: true,
        inheritingFromSurfaceId: currentFocusedSurfaceId(),
        context: GHOSTTY_SURFACE_CONTEXT_TAB,
        tabID: nil,
        isBlockingScript: true,
      )
    )
    guard let tabId else {
      cleanupBlockingScriptLaunchDirectory(at: launch.directoryURL)
      blockingScriptLogger.warning("Failed to create \(kind.tabTitle) tab for worktree \(worktree.id)")
      onBlockingScriptCompleted?(kind, 1, nil)
      return nil
    }
    blockingScripts[tabId] = kind
    blockingScriptLaunchDirectories[tabId] = launch.directoryURL
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
    // When a tab ID is explicitly provided, use it as the initial surface ID
    // so the CLI can reference the surface immediately after creation.
    let tree = splitTree(
      for: tabId,
      inheritingFromSurfaceId: creation.inheritingFromSurfaceId,
      command: creation.command,
      initialInput: creation.initialInput,
      context: creation.context,
      surfaceID: creation.tabID != nil ? tabId.rawValue : nil
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
    surface.performBindingAction("close_surface")
    return true
  }

  @discardableResult
  func closeSurface(id surfaceID: UUID) -> Bool {
    guard let surface = surfaces[surfaceID] else {
      terminalStateLogger.warning(
        "closeSurface: surface \(surfaceID) not found. Known: \(surfaces.keys.map(\.uuidString))")
      return false
    }
    surface.performBindingAction("close_surface")
    return true
  }

  @discardableResult
  func performBindingActionOnFocusedSurface(_ action: String) -> Bool {
    guard let tabId = tabManager.selectedTabId,
      let focusedId = focusedSurfaceIdByTab[tabId],
      let surface = surfaces[focusedId]
    else {
      return false
    }
    surface.performBindingAction(action)
    return true
  }

  @discardableResult
  func performBindingAction(_ action: String, onSurfaceID surfaceID: UUID) -> Bool {
    guard let surface = surfaces[surfaceID] else { return false }
    surface.performBindingAction(action)
    return true
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
    surfaceID: UUID? = nil
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
      surfaceID: surfaceID
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
        surfaces.removeValue(forKey: newSurface.id)
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
    let closingSurfaceIDs = Array(surfaces.keys)
    for surface in surfaces.values {
      surface.closeSurface()
    }
    cleanupBlockingScriptLaunchDirectories()
    surfaces.removeAll()
    trees.removeAll()
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
    let previousHasUnseen = hasUnseenNotification
    for index in notifications.indices {
      notifications[index].isRead = true
    }
    clearAllSurfaceUnseenFlags()
    emitAllTabProjections()
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func markNotificationsRead(forSurfaceID surfaceID: UUID) {
    let previousHasUnseen = hasUnseenNotification
    for index in notifications.indices where notifications[index].surfaceID == surfaceID {
      notifications[index].isRead = true
    }
    setSurfaceUnseenFlag(surfaceID, to: false)
    if let tabId = tabID(containing: surfaceID) {
      emitTabProjection(for: tabId)
    }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  /// Marks a single notification as read, leaving others untouched.
  func markNotificationRead(id: WorktreeTerminalNotification.ID) {
    let previousHasUnseen = hasUnseenNotification
    guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
    guard !notifications[index].isRead else { return }
    let surfaceID = notifications[index].surfaceID
    notifications[index].isRead = true
    refreshSurfaceUnseenFlag(surfaceID)
    if let tabId = tabID(containing: surfaceID) {
      emitTabProjection(for: tabId)
    }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func dismissNotification(_ notificationID: WorktreeTerminalNotification.ID) {
    let previousHasUnseen = hasUnseenNotification
    let affectedSurface = notifications.first(where: { $0.id == notificationID })?.surfaceID
    notifications.removeAll { $0.id == notificationID }
    if let affectedSurface {
      refreshSurfaceUnseenFlag(affectedSurface)
      if let tabId = tabID(containing: affectedSurface) {
        emitTabProjection(for: tabId)
      }
    }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func dismissAllNotifications() {
    let previousHasUnseen = hasUnseenNotification
    notifications.removeAll()
    clearAllSurfaceUnseenFlags()
    emitAllTabProjections()
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
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

  func captureLayoutSnapshot() -> TerminalLayoutSnapshot? {
    guard !tabManager.tabs.isEmpty else { return nil }
    var tabSnapshots: [TerminalLayoutSnapshot.TabSnapshot] = []
    for tab in tabManager.tabs {
      // Blocking-script tabs die with the app; persisting them would resurrect a dead session.
      if tab.isBlockingScript { continue }
      guard let tree = trees[tab.id], let root = tree.root else {
        layoutLogger.warning("Skipping tab \(tab.id.rawValue) during snapshot capture (no tree)")
        continue
      }
      let layout = captureLayoutNode(root)
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
    _ node: SplitTree<GhosttySurfaceView>.Node
  ) -> TerminalLayoutSnapshot.LayoutNode {
    switch node {
    case .leaf(let view):
      return .leaf(
        TerminalLayoutSnapshot.SurfaceSnapshot(id: view.id, workingDirectory: view.bridge.state.pwd)
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
          left: captureLayoutNode(split.left),
          right: captureLayoutNode(split.right)
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
      surfaces.removeValue(forKey: newSurface.id)
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
      worktree.id, allowedCharacters: percentEncodingSet, label: "SUPACODE_WORKTREE_ID")
    env["SUPACODE_TAB_ID"] = tabId.rawValue.uuidString
    env["SUPACODE_SURFACE_ID"] = surfaceID.uuidString
    if let socketPath {
      env["SUPACODE_SOCKET_PATH"] = socketPath
    }
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
    surfaceID: UUID? = nil
  ) -> GhosttySurfaceView {
    let resolvedID: UUID
    if let requested = surfaceID {
      if surfaces[requested] != nil {
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
    let view = GhosttySurfaceView(
      id: surfaceID,
      runtime: runtime,
      workingDirectory: workingDirectoryOverride ?? inherited.workingDirectory ?? worktree.workingDirectory,
      command: command,
      initialInput: initialInput,
      environmentVariables: surfaceEnvironment(tabId: tabId, surfaceID: surfaceID),
      fontSize: inherited.fontSize,
      context: context
    )
    view.bridge.onTitleChange = { [weak self, weak view] title in
      guard let self, let view else { return }
      if self.focusedSurfaceIdByTab[tabId] == view.id {
        self.tabManager.updateTitle(tabId, title: title)
      }
    }
    view.bridge.onPromptTitle = { [weak self] in
      self?.tabManager.beginTabRename(tabId)
    }
    view.bridge.onSplitAction = { [weak self, weak view] action in
      guard let self, let view else { return false }
      return self.performSplitAction(action, for: view.id)
    }
    view.bridge.onNewTab = { [weak self, weak view] in
      guard let self, let view else { return false }
      return self.createTab(inheritingFromSurfaceId: view.id) != nil
    }
    view.bridge.onCloseTab = { [weak self] _ in
      guard let self else { return false }
      self.closeTab(tabId)
      return true
    }
    view.bridge.onGotoTab = { [weak self] target in
      guard let self else { return false }
      return self.handleGotoTabRequest(target)
    }
    view.bridge.onCommandPaletteToggle = { [weak self] in
      guard let self else { return false }
      self.onCommandPaletteToggle?()
      return true
    }
    view.bridge.onProgressReport = { [weak self] _ in
      guard let self else { return }
      self.updateRunningState(for: tabId)
    }
    view.bridge.onCommandFinished = { [weak self] exitCode in
      guard let self else { return }
      self.handleBlockingScriptCommandFinished(tabId: tabId, exitCode: exitCode)
    }
    view.bridge.onChildExited = { [weak self] exitCode in
      guard let self else { return }
      self.handleBlockingScriptChildExited(tabId: tabId, exitCode: exitCode)
    }
    view.bridge.onDesktopNotification = { [weak self, weak view] title, body in
      guard let self, let view else { return }
      self.appendNotification(title: title, body: body, surfaceID: view.id)
    }
    view.bridge.onCloseRequest = { [weak self, weak view] processAlive in
      guard let self, let view else { return }
      self.handleCloseRequest(for: view, processAlive: processAlive)
    }
    view.onFocusChange = { [weak self, weak view] focused in
      guard let self, let view, focused else { return }
      self.recordActiveSurface(view, in: tabId)
      self.emitTaskStatusIfChanged()
    }
    surfaces[view.id] = view
    surfaceStates[view.id] = WorktreeSurfaceState()
    return view
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
  // can't drift across surfaces.
  func activeSurfaceID(for tabId: TerminalTabID) -> UUID? {
    focusedSurfaceIdByTab[tabId]
  }

  /// Appends a notification from an agent hook on a specific surface.
  func appendHookNotification(title: String, body: String, surfaceID: UUID) {
    guard surfaces[surfaceID] != nil else {
      terminalStateLogger.debug("Dropped hook notification for unknown surface \(surfaceID) in worktree \(worktree.id)")
      return
    }
    // Record for deduplication against later OSC 9 notifications.
    if let normalized = Self.normalizedText("\(title) \(body)") {
      recentHookBySurfaceID[surfaceID] = (text: normalized, recordedAt: now)
    }
    appendNotification(title: title, body: body, surfaceID: surfaceID, fromHook: true)
  }

  private func appendNotification(
    title: String,
    body: String,
    surfaceID: UUID,
    fromHook: Bool = false
  ) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(trimmedTitle.isEmpty && trimmedBody.isEmpty) else { return }
    if notificationsEnabled {
      let previousHasUnseen = hasUnseenNotification
      let isRead = isSelected() && isFocusedSurface(surfaceID)
      notifications.insert(
        WorktreeTerminalNotification(
          surfaceID: surfaceID,
          title: trimmedTitle,
          body: trimmedBody,
          createdAt: now,
          isRead: isRead
        ),
        at: 0
      )
      refreshSurfaceUnseenFlag(surfaceID)
      if let tabId = tabID(containing: surfaceID) {
        emitTabProjection(for: tabId)
      }
      emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
    }
    // Suppress OSC 9 system notifications that duplicate a recent hook notification.
    if !fromHook, shouldSuppressDesktopNotification(title: trimmedTitle, body: trimmedBody, surfaceID: surfaceID) {
      return
    }
    onNotificationReceived?(surfaceID, trimmedTitle, trimmedBody)
  }

  // MARK: - Notification deduplication (matches supaterm's approach).

  private static let notificationCoalescingWindow: TimeInterval = 2

  private static let genericCompletionTexts: Set<String> = [
    "agent turn complete",
    "task complete",
    "turn complete",
  ]

  private func shouldSuppressDesktopNotification(title: String, body: String, surfaceID: UUID) -> Bool {
    guard
      let terminalText = Self.normalizedText("\(title) \(body)"),
      let recent = recentHookBySurfaceID[surfaceID],
      now.timeIntervalSince(recent.recordedAt) <= Self.notificationCoalescingWindow
    else {
      return false
    }
    if terminalText == recent.text { return true }
    if recent.text.hasPrefix(terminalText) { return true }
    if Self.genericCompletionTexts.contains(terminalText) { return true }
    return false
  }

  private static func normalizedText(_ value: String) -> String? {
    let collapsed =
      value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .lowercased()
      .trimmingCharacters(in: .punctuationCharacters)
    return collapsed.isEmpty ? nil : collapsed
  }

  private func cleanupSurfaceState(for surfaceID: UUID) {
    recentHookBySurfaceID.removeValue(forKey: surfaceID)
    surfaces.removeValue(forKey: surfaceID)
    surfaceStates.removeValue(forKey: surfaceID)
    onSurfacesClosed?([surfaceID])
  }

  private func removeTree(for tabId: TerminalTabID) {
    guard let tree = trees.removeValue(forKey: tabId) else { return }
    for surface in tree.leaves() {
      surface.closeSurface()
      cleanupSurfaceState(for: surface.id)
    }
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

  /// True for a blocking-script tab whose script has already finished.
  func isBlockingScriptCompleted(_ tabId: TerminalTabID) -> Bool {
    tabManager.tabs.first(where: { $0.id == tabId })?.isBlockingScriptCompleted == true
  }

  private func updateRunningState(for tabId: TerminalTabID) {
    guard trees[tabId] != nil else { return }
    // Frozen tabs stay sticky: the 15s `progressResetTask` re-fires
    // `onProgressReport` after `command_finished` and would otherwise
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

  private func emitNotificationIndicatorIfNeeded(previousHasUnseen: Bool) {
    if previousHasUnseen != hasUnseenNotification {
      onNotificationIndicatorChanged?()
    }
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
      isSplitZoomed: tree.zoomed != nil
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
    guard surfaces[view.id] != nil else { return }
    guard let tabId = tabID(containing: view.id), let tree = trees[tabId] else {
      view.closeSurface()
      cleanupSurfaceState(for: view.id)
      return
    }
    guard let node = tree.find(id: view.id) else {
      view.closeSurface()
      cleanupSurfaceState(for: view.id)
      return
    }
    let nextSurface =
      focusedSurfaceIdByTab[tabId] == view.id
      ? tree.focusTargetAfterClosing(node)
      : nil
    let newTree = tree.removing(node)
    view.closeSurface()
    cleanupSurfaceState(for: view.id)
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
    /// (`appendNotification`, `markNotificationsRead`, etc.) which already
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
