import AppKit
import CoreGraphics
import Dependencies
import Foundation
import GhosttyKit
import Observation
import Sharing
import SupacodeSettingsShared

private let blockingScriptLogger = SupaLogger("BlockingScript")
private let layoutLogger = SupaLogger("Layout")
private let terminalStateLogger = SupaLogger("Terminal")

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
  private var trees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
  private var surfaces: [UUID: GhosttySurfaceView] = [:]
  private var focusedSurfaceIdByTab: [TerminalTabID: UUID] = [:]
  private var tabIsRunningById: [TerminalTabID: Bool] = [:]
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
  var notifications: [WorktreeTerminalNotification] = []
  var notificationsEnabled = true
  @ObservationIgnored @Dependency(\.date.now) private var now
  private var recentHookBySurfaceID: [UUID: (text: String, recordedAt: Date)] = [:]
  var hasUnseenNotification: Bool {
    notifications.contains { !$0.isRead }
  }

  func hasUnseenNotification(forSurfaceID surfaceID: UUID) -> Bool {
    notifications.contains { !$0.isRead && $0.surfaceId == surfaceID }
  }

  func hasUnseenNotification(forTabID tabID: TerminalTabID) -> Bool {
    guard let tree = trees[tabID] else { return false }
    let surfaceIDs = Set(tree.leaves().map(\.id))
    return notifications.contains { !$0.isRead && surfaceIDs.contains($0.surfaceId) }
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
    return tree.leaves().contains { surface in
      isRunningProgressState(surface.bridge.state.progressState)
        || surface.bridge.state.agentBusy
    }
  }

  func isBlockingScriptRunning(kind: BlockingScriptKind) -> Bool {
    blockingScripts.values.contains(kind)
  }

  private func updateShouldHideTabBar() {
    @Shared(.settingsFile) var settingsFile
    shouldHideTabBar =
      settingsFile.global.hideSingleTabBar
      && tabManager.tabs.count == 1
  }

  func refreshTabBarVisibility() {
    updateShouldHideTabBar()
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
    let commandInput = initialInput.flatMap { formatCommandInput($0) }
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
    let launch: BlockingScriptLaunch
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
    var tintColor: TerminalTabTintColor?
    let command: String?
    let initialInput: String?
    let focusing: Bool
    let inheritingFromSurfaceId: UUID?
    let context: ghostty_surface_context_e
    let tabID: UUID?
  }

  private func createTab(_ creation: TabCreation) -> TerminalTabID? {
    let tabId = tabManager.createTab(
      title: creation.title,
      icon: creation.icon,
      isTitleLocked: creation.isTitleLocked,
      tintColor: creation.tintColor,
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
    tabIsRunningById[tabId] = false
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

  func hasSurface(_ surfaceId: UUID, in tabId: TerminalTabID) -> Bool {
    guard let tree = trees[tabId] else { return false }
    return tree.find(id: surfaceId) != nil
  }

  /// Checks whether a surface UUID exists anywhere in the worktree (across all tabs).
  func hasSurfaceAnywhere(_ surfaceId: UUID) -> Bool {
    surfaces[surfaceId] != nil
  }

  func selectTab(_ tabId: TerminalTabID) {
    guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
      terminalStateLogger.warning("selectTab: tab \(tabId.rawValue) not found in worktree \(worktree.id).")
      return
    }
    tabManager.selectTab(tabId)
    focusSurface(in: tabId)
    emitTaskStatusIfChanged()
  }

  /// Sets or clears the agent busy flag on a specific surface.
  func setAgentBusy(surfaceID: UUID, tabID: TerminalTabID, active: Bool) {
    guard let surface = surfaces[surfaceID] else {
      terminalStateLogger.debug("Dropped busy update for unknown surface \(surfaceID) in worktree \(worktree.id)")
      return
    }
    surface.bridge.state.agentBusy = active
    tabManager.updateDirty(tabID, isDirty: isTabBusy(tabID))
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
    trees[tabId] = tree
    focusedSurfaceIdByTab[tabId] = surface.id
    return tree
  }

  func performSplitAction(
    _ action: GhosttySplitAction,
    for surfaceId: UUID,
    newSurfaceID: UUID? = nil,
    initialInput: String? = nil
  ) -> Bool {
    guard let tabId = tabID(containing: surfaceId), var tree = trees[tabId] else {
      return false
    }
    guard let targetNode = tree.find(id: surfaceId) else { return false }
    guard let targetSurface = surfaces[surfaceId] else { return false }

    switch action {
    case .newSplit(let direction):
      let newSurface = createSurface(
        tabId: tabId,
        initialInput: initialInput,
        inheritingFromSurfaceId: surfaceId,
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
          "performSplitAction: failed to insert split for surface \(surfaceId) in tab \(tabId.rawValue): \(error)")
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
    for surface in surfaces.values {
      surface.closeSurface()
    }
    cleanupBlockingScriptLaunchDirectories()
    surfaces.removeAll()
    trees.removeAll()
    focusedSurfaceIdByTab.removeAll()
    tabIsRunningById.removeAll()
    // Agent busy state lives on GhosttySurfaceState and is cleaned up
    // when surfaces are removed.
    let pendingKinds = Set(blockingScripts.values)
    blockingScripts.removeAll()
    lastBlockingScriptTabByKind.removeAll()

    for kind in pendingKinds {
      onBlockingScriptCompleted?(kind, nil, nil)
    }
    tabManager.closeAll()
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
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func markNotificationsRead(forSurfaceID surfaceID: UUID) {
    let previousHasUnseen = hasUnseenNotification
    for index in notifications.indices where notifications[index].surfaceId == surfaceID {
      notifications[index].isRead = true
    }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  /// Marks a single notification as read, leaving others untouched.
  func markNotificationRead(id: WorktreeTerminalNotification.ID) {
    let previousHasUnseen = hasUnseenNotification
    guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
    guard !notifications[index].isRead else { return }
    notifications[index].isRead = true
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func dismissNotification(_ notificationID: WorktreeTerminalNotification.ID) {
    let previousHasUnseen = hasUnseenNotification
    notifications.removeAll { $0.id == notificationID }
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  func dismissAllNotifications() {
    let previousHasUnseen = hasUnseenNotification
    notifications.removeAll()
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
  }

  // MARK: - Layout Snapshot

  func captureLayoutSnapshot() -> TerminalLayoutSnapshot? {
    guard !tabManager.tabs.isEmpty else { return nil }
    var tabSnapshots: [TerminalLayoutSnapshot.TabSnapshot] = []
    for tab in tabManager.tabs {
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
      // Detect blocking-script tabs by their locked title or tint color and normalize to default state.
      let isBlockingScriptTab = tab.isTitleLocked || tab.tintColor != nil
      tabSnapshots.append(
        TerminalLayoutSnapshot.TabSnapshot(
          id: tab.id.rawValue,
          title: tab.title,
          icon: isBlockingScriptTab ? nil : tab.icon,
          tintColor: isBlockingScriptTab ? nil : tab.tintColor,
          layout: layout,
          focusedLeafIndex: focusedLeafIndex,
        )
      )
    }
    guard !tabSnapshots.isEmpty else { return nil }
    let selectedIndex =
      tabManager.selectedTabId.flatMap { id in
        tabManager.tabs.firstIndex(where: { $0.id == id })
      } ?? 0
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
      let surface = createSurface(
        tabId: tabId,
        initialInput: nil,
        workingDirectoryOverride: workingDir,
        inheritingFromSurfaceId: nil,
        context: context,
        surfaceID: tabSnapshot.layout.firstLeaf.id,
      )
      let tree = SplitTree(view: surface)
      trees[tabId] = tree
      focusedSurfaceIdByTab[tabId] = surface.id
      tabIsRunningById[tabId] = false

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
        focusedSurfaceIdByTab[tabId] = leaves[focusedIndex].id
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
      trees[tabId] = tree
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
    return formatCommandInput(script)
  }

  private func formatCommandInput(_ script: String) -> String? {
    makeCommandInput(script: script)
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
  private func blockingScriptLaunch(_ script: String) throws -> BlockingScriptLaunch? {
    try makeBlockingScriptLaunch(
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

  // Unlocks the tab and asynchronously fires the completion callback,
  // unless a new script of the same kind has already started.
  private func completeBlockingScript(
    _ kind: BlockingScriptKind,
    tabId: TerminalTabID,
    exitCode: Int?,
    reportedTabId: TerminalTabID?
  ) {
    tabManager.unlockAndUpdateTitle(tabId, title: "\(worktree.name) \(nextTabIndex())")
    tabManager.updateDirty(tabId, isDirty: isTabBusy(tabId))
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
      self.appendNotification(title: title, body: body, surfaceId: view.id)
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
    return view
  }

  private struct InheritedSurfaceConfig: Equatable {
    let workingDirectory: URL?
    let fontSize: Float32?
  }

  private func inheritedSurfaceConfig(
    fromSurfaceId surfaceId: UUID?,
    context: ghostty_surface_context_e
  ) -> InheritedSurfaceConfig {
    guard let surfaceId,
      let view = surfaces[surfaceId],
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
    focusedSurfaceIdByTab[tabId] = surface.id
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
    appendNotification(title: title, body: body, surfaceId: surfaceID, fromHook: true)
  }

  private func appendNotification(
    title: String,
    body: String,
    surfaceId: UUID,
    fromHook: Bool = false
  ) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(trimmedTitle.isEmpty && trimmedBody.isEmpty) else { return }
    if notificationsEnabled {
      let previousHasUnseen = hasUnseenNotification
      let isRead = isSelected() && isFocusedSurface(surfaceId)
      notifications.insert(
        WorktreeTerminalNotification(
          surfaceId: surfaceId,
          title: trimmedTitle,
          body: trimmedBody,
          createdAt: now,
          isRead: isRead
        ),
        at: 0
      )
      emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
    }
    // Suppress OSC 9 system notifications that duplicate a recent hook notification.
    if !fromHook, shouldSuppressDesktopNotification(title: trimmedTitle, body: trimmedBody, surfaceId: surfaceId) {
      return
    }
    onNotificationReceived?(surfaceId, trimmedTitle, trimmedBody)
  }

  // MARK: - Notification deduplication (matches supaterm's approach).

  private static let notificationCoalescingWindow: TimeInterval = 2

  private static let genericCompletionTexts: Set<String> = [
    "agent turn complete",
    "task complete",
    "turn complete",
  ]

  private func shouldSuppressDesktopNotification(title: String, body: String, surfaceId: UUID) -> Bool {
    guard
      let terminalText = Self.normalizedText("\(title) \(body)"),
      let recent = recentHookBySurfaceID[surfaceId],
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
  }

  private func removeTree(for tabId: TerminalTabID) {
    guard let tree = trees.removeValue(forKey: tabId) else { return }
    for surface in tree.leaves() {
      surface.closeSurface()
      cleanupSurfaceState(for: surface.id)
    }
    focusedSurfaceIdByTab.removeValue(forKey: tabId)
    tabIsRunningById.removeValue(forKey: tabId)
  }

  func tabID(containing surfaceId: UUID) -> TerminalTabID? {
    for (tabId, tree) in trees where tree.find(id: surfaceId) != nil {
      return tabId
    }
    return nil
  }

  private func isFocusedSurface(_ surfaceId: UUID) -> Bool {
    guard let selectedTabId = tabManager.selectedTabId else {
      return false
    }
    return focusedSurfaceIdByTab[selectedTabId] == surfaceId
  }

  private func updateRunningState(for tabId: TerminalTabID) {
    guard let tree = trees[tabId] else { return }
    let isRunningNow = tree.leaves().contains { surface in
      isRunningProgressState(surface.bridge.state.progressState)
    }
    tabIsRunningById[tabId] = isRunningNow
    tabManager.updateDirty(tabId, isDirty: isTabBusy(tabId))
    emitTaskStatusIfChanged()
  }

  private func emitTaskStatusIfChanged() {
    let newStatus = taskStatus
    if newStatus != lastReportedTaskStatus {
      lastReportedTaskStatus = newStatus
      onTaskStatusChanged?(newStatus)
    }
  }

  private func emitFocusChangedIfNeeded(_ surfaceId: UUID) {
    guard surfaceId != lastEmittedFocusSurfaceId else { return }
    lastEmittedFocusSurfaceId = surfaceId
    onFocusChanged?(surfaceId)
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
    trees[tabId] = tree
    syncFocusIfNeeded()
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
      tabIsRunningById.removeValue(forKey: tabId)
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
}

nonisolated func makeCommandInput(
  script: String
) -> String? {
  let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  return trimmed + "\n"
}

nonisolated struct BlockingScriptLaunch {
  let directoryURL: URL
  let runnerURL: URL
  let scriptURL: URL
  let shellPathURL: URL
  let commandInput: String
}

nonisolated func makeBlockingScriptLaunch(
  script: String,
  shellPath: String,
  baseDirectoryURL: URL = FileManager.default.temporaryDirectory
) throws -> BlockingScriptLaunch? {
  let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  let fileManager = FileManager.default
  let directoryURL = baseDirectoryURL.appending(
    path: "supacode-blocking-script-\(UUID().uuidString.lowercased())",
    directoryHint: .isDirectory
  )
  let runnerURL = directoryURL.appending(path: "run", directoryHint: .notDirectory)
  let scriptURL = directoryURL.appending(path: "script", directoryHint: .notDirectory)
  let shellPathURL = directoryURL.appending(path: "shell-path", directoryHint: .notDirectory)

  do {
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try Data((trimmed + "\n").utf8).write(to: scriptURL, options: [.atomic])
    try Data((shellPath + "\n").utf8).write(to: shellPathURL, options: [.atomic])
    try Data(
      blockingScriptRunnerContents(
        scriptURL: scriptURL,
        shellPathURL: shellPathURL
      ).utf8
    ).write(to: runnerURL, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: runnerURL.path(percentEncoded: false)
    )
  } catch {
    try? fileManager.removeItem(at: directoryURL)
    throw error
  }

  return BlockingScriptLaunch(
    directoryURL: directoryURL,
    runnerURL: runnerURL,
    scriptURL: scriptURL,
    shellPathURL: shellPathURL,
    commandInput: shellSingleQuoted(runnerURL.path(percentEncoded: false)) + "\n"
  )
}

nonisolated func blockingScriptRunnerContents(
  scriptURL: URL,
  shellPathURL: URL
) -> String {
  let quotedShellPath = shellSingleQuoted(shellPathURL.path(percentEncoded: false))
  let quotedScriptPath = shellSingleQuoted(scriptURL.path(percentEncoded: false))

  return """
    #!/bin/sh
    set -eu
    IFS= read -r SUPACODE_SHELL_PATH < \(quotedShellPath)
    "$SUPACODE_SHELL_PATH" -l \(quotedScriptPath)
    """
}

nonisolated func shellSingleQuoted(_ value: String) -> String {
  "'\(value.replacing("'", with: "'\"'\"'"))'"
}
