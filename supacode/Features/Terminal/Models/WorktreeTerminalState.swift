import AppKit
import CoreGraphics
import Foundation
import GhosttyKit
import Observation
import Sharing

@MainActor
@Observable
final class WorktreeTerminalState {
  let tabManager: TerminalTabManager
  private let runtime: GhosttyRuntime
  private let worktree: Worktree
  @ObservationIgnored
  @SharedReader private var repositorySettings: RepositorySettings
  private var trees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
  private var surfaces: [UUID: GhosttySurfaceView] = [:]
  private var focusedSurfaceIdByTab: [TerminalTabID: UUID] = [:]
  private var tabIsRunningById: [TerminalTabID: Bool] = [:]
  private var runScriptTabId: TerminalTabID?
  private var pendingSetupScript: Bool
  private var isEnsuringInitialTab = false
  private var lastReportedTaskStatus: WorktreeTaskStatus?
  private var lastEmittedFocusSurfaceId: UUID?
  var notifications: [WorktreeTerminalNotification] = []
  var notificationsEnabled = true
  var hasUnseenNotification: Bool {
    notifications.contains { !$0.isRead }
  }
  var isSelected: () -> Bool = { false }
  var onNotificationReceived: ((String, String) -> Void)?
  var onNotificationIndicatorChanged: (() -> Void)?
  var onTabCreated: (() -> Void)?
  var onTabClosed: (() -> Void)?
  var onFocusChanged: ((UUID) -> Void)?
  var onTaskStatusChanged: ((WorktreeTaskStatus) -> Void)?
  var onRunScriptStatusChanged: ((Bool) -> Void)?
  var onCommandPaletteToggle: (() -> Void)?
  var onSetupScriptConsumed: (() -> Void)?

  init(runtime: GhosttyRuntime, worktree: Worktree, runSetupScript: Bool = false) {
    self.runtime = runtime
    self.worktree = worktree
    self.pendingSetupScript = runSetupScript
    self.tabManager = TerminalTabManager()
    _repositorySettings = SharedReader(
      wrappedValue: RepositorySettings.default,
      .repositorySettings(worktree.repositoryRootURL)
    )
  }

  var focusedTaskStatus: WorktreeTaskStatus {
    guard let tabId = tabManager.selectedTabId else { return .idle }
    if tabIsRunningById[tabId] == true {
      return .running
    }
    return .idle
  }

  var isRunScriptRunning: Bool {
    runScriptTabId != nil
  }

  func ensureInitialTab(focusing: Bool) {
    guard tabManager.tabs.isEmpty else { return }
    guard !isEnsuringInitialTab else { return }
    isEnsuringInitialTab = true
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
    inheritingFromSurfaceId: UUID? = nil
  ) -> TerminalTabID? {
    let context: ghostty_surface_context_e =
      tabManager.tabs.isEmpty
      ? GHOSTTY_SURFACE_CONTEXT_WINDOW
      : GHOSTTY_SURFACE_CONTEXT_TAB
    let resolvedInheritanceSurfaceId = inheritingFromSurfaceId ?? currentFocusedSurfaceId()
    let title = "\(worktree.name) \(nextTabIndex())"
    let setupInput = setupScriptInput(setupScript: setupScript)
    let commandInput = initialInput.flatMap { runScriptInput($0) }
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
        icon: "terminal",
        isTitleLocked: false,
        initialInput: resolvedInput,
        focusing: focusing,
        inheritingFromSurfaceId: resolvedInheritanceSurfaceId,
        context: context
      )
    )
    if shouldConsumeSetupScript, tabId != nil {
      onSetupScriptConsumed?()
    }
    return tabId
  }

  @discardableResult
  func runScript(_ script: String) -> TerminalTabID? {
    guard let input = runScriptInput(script) else { return nil }
    if let existing = runScriptTabId {
      closeTab(existing)
    }
    let tabId = createTab(
      TabCreation(
        title: "RUN SCRIPT",
        icon: "play.fill",
        isTitleLocked: true,
        initialInput: input,
        focusing: true,
        inheritingFromSurfaceId: currentFocusedSurfaceId(),
        context: GHOSTTY_SURFACE_CONTEXT_TAB
      )
    )
    setRunScriptTabId(tabId)
    return tabId
  }

  @discardableResult
  func stopRunScript() -> Bool {
    guard let runScriptTabId else { return false }
    closeTab(runScriptTabId)
    return true
  }

  private struct TabCreation: Equatable {
    let title: String
    let icon: String?
    let isTitleLocked: Bool
    let initialInput: String?
    let focusing: Bool
    let inheritingFromSurfaceId: UUID?
    let context: ghostty_surface_context_e
  }

  private func createTab(_ creation: TabCreation) -> TerminalTabID? {
    let tabId = tabManager.createTab(
      title: creation.title,
      icon: creation.icon,
      isTitleLocked: creation.isTitleLocked
    )
    let tree = splitTree(
      for: tabId,
      inheritingFromSurfaceId: creation.inheritingFromSurfaceId,
      initialInput: creation.initialInput,
      context: creation.context
    )
    tabIsRunningById[tabId] = false
    if creation.focusing, let surface = tree.root?.leftmostLeaf() {
      focusSurface(surface, in: tabId)
    }
    onTabCreated?()
    return tabId
  }

  func selectTab(_ tabId: TerminalTabID) {
    tabManager.selectTab(tabId)
    focusSurface(in: tabId)
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
    else { return }
    surface.requestFocus()
    surface.insertText(text, replacementRange: NSRange(location: 0, length: 0))
  }

  func syncFocus(windowIsKey: Bool) {
    let selectedTabId = tabManager.selectedTabId
    var surfaceToFocus: GhosttySurfaceView?
    for (tabId, tree) in trees {
      let focusedId = focusedSurfaceIdByTab[tabId]
      // Occlusion: only selected tab is visible, regardless of window focus
      let isSelectedTab = (tabId == selectedTabId)
      for surface in tree.leaves() {
        surface.setOcclusion(isSelectedTab)
        // Focus: requires both selected tab AND window key
        let isFocused = windowIsKey && isSelectedTab && surface.id == focusedId
        surface.focusDidChange(isFocused)
        if isFocused {
          surfaceToFocus = surface
        }
      }
    }
    if let surfaceToFocus, surfaceToFocus.window?.firstResponder is GhosttySurfaceView {
      surfaceToFocus.window?.makeFirstResponder(surfaceToFocus)
    }
  }

  @discardableResult
  func focusSurface(id: UUID) -> Bool {
    guard let tabId = tabId(containing: id),
      let surface = surfaces[id]
    else {
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

  func closeTab(_ tabId: TerminalTabID) {
    let wasRunScriptTab = tabId == runScriptTabId
    removeTree(for: tabId)
    tabManager.closeTab(tabId)
    if let selected = tabManager.selectedTabId {
      focusSurface(in: selected)
    } else {
      lastEmittedFocusSurfaceId = nil
    }
    emitTaskStatusIfChanged()
    if wasRunScriptTab {
      setRunScriptTabId(nil)
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
    initialInput: String? = nil,
    context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_TAB
  ) -> SplitTree<GhosttySurfaceView> {
    if let existing = trees[tabId] {
      return existing
    }
    let surface = createSurface(
      tabId: tabId,
      initialInput: initialInput,
      inheritingFromSurfaceId: inheritingFromSurfaceId,
      context: context
    )
    let tree = SplitTree(view: surface)
    trees[tabId] = tree
    focusedSurfaceIdByTab[tabId] = surface.id
    return tree
  }

  func performSplitAction(_ action: GhosttySplitAction, for surfaceId: UUID) -> Bool {
    guard let tabId = tabId(containing: surfaceId), var tree = trees[tabId] else {
      return false
    }
    guard let targetNode = tree.find(id: surfaceId) else { return false }
    guard let targetSurface = surfaces[surfaceId] else { return false }

    switch action {
    case .newSplit(let direction):
      let newSurface = createSurface(
        tabId: tabId,
        initialInput: nil,
        inheritingFromSurfaceId: surfaceId,
        context: GHOSTTY_SURFACE_CONTEXT_SPLIT
      )
      do {
        let newTree = try tree.inserting(
          view: newSurface,
          at: targetSurface,
          direction: mapSplitDirection(direction)
        )
        trees[tabId] = newTree
        focusSurface(newSurface, in: tabId)
        return true
      } catch {
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
        tree = tree.settingZoomed(nil)
        trees[tabId] = tree
      }
      focusSurface(nextSurface, in: tabId)
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
        trees[tabId] = newTree
        return true
      } catch {
        return false
      }

    case .equalizeSplits:
      trees[tabId] = tree.equalized()
      return true

    case .toggleSplitZoom:
      guard tree.isSplit else { return false }
      let newZoomed = (tree.zoomed == targetNode) ? nil : targetNode
      trees[tabId] = tree.settingZoomed(newZoomed)
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
        trees[tabId] = tree
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
        trees[tabId] = newTree
        focusSurface(payload, in: tabId)
      } catch {
        return
      }

    case .equalize:
      trees[tabId] = tree.equalized()
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
    surfaces.removeAll()
    trees.removeAll()
    focusedSurfaceIdByTab.removeAll()
    tabIsRunningById.removeAll()
    setRunScriptTabId(nil)
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
    let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return nil
    }
    if script.hasSuffix("\n") {
      return script
    }
    return "\(script)\n"
  }

  private func runScriptInput(_ script: String) -> String? {
    let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return nil
    }
    if script.hasSuffix("\n") {
      return script
    }
    return "\(script)\n"
  }

  private func setRunScriptTabId(_ tabId: TerminalTabID?) {
    let wasRunning = runScriptTabId != nil
    runScriptTabId = tabId
    let isRunning = tabId != nil
    if wasRunning != isRunning {
      onRunScriptStatusChanged?(isRunning)
    }
  }

  private func createSurface(
    tabId: TerminalTabID,
    initialInput: String?,
    inheritingFromSurfaceId: UUID?,
    context: ghostty_surface_context_e
  ) -> GhosttySurfaceView {
    let inherited = inheritedSurfaceConfig(fromSurfaceId: inheritingFromSurfaceId, context: context)
    let view = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: inherited.workingDirectory ?? worktree.workingDirectory,
      initialInput: initialInput,
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
      self.focusedSurfaceIdByTab[tabId] = view.id
      self.markNotificationsRead(forSurfaceID: view.id)
      self.updateTabTitle(for: tabId)
      self.emitFocusChangedIfNeeded(view.id)
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
    if let surface = tree.root?.leftmostLeaf() {
      focusSurface(surface, in: tabId)
    }
  }

  private func focusSurface(_ surface: GhosttySurfaceView, in tabId: TerminalTabID) {
    let previousSurface = focusedSurfaceIdByTab[tabId].flatMap { surfaces[$0] }
    focusedSurfaceIdByTab[tabId] = surface.id
    markNotificationsRead(forSurfaceID: surface.id)
    updateTabTitle(for: tabId)
    guard tabId == tabManager.selectedTabId else { return }
    let fromSurface = (previousSurface === surface) ? nil : previousSurface
    GhosttySurfaceView.moveFocus(to: surface, from: fromSurface)
    emitFocusChangedIfNeeded(surface.id)
  }

  private func appendNotification(title: String, body: String, surfaceId: UUID) {
    guard notificationsEnabled else { return }
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(trimmedTitle.isEmpty && trimmedBody.isEmpty) else { return }
    let previousHasUnseen = hasUnseenNotification
    let isRead = isSelected() && isFocusedSurface(surfaceId)
    notifications.insert(
      WorktreeTerminalNotification(
        surfaceId: surfaceId,
        title: trimmedTitle,
        body: trimmedBody,
        isRead: isRead
      ),
      at: 0
    )
    emitNotificationIndicatorIfNeeded(previousHasUnseen: previousHasUnseen)
    onNotificationReceived?(trimmedTitle, trimmedBody)
  }

  private func removeTree(for tabId: TerminalTabID) {
    guard let tree = trees.removeValue(forKey: tabId) else { return }
    for surface in tree.leaves() {
      surface.closeSurface()
      surfaces.removeValue(forKey: surface.id)
    }
    focusedSurfaceIdByTab.removeValue(forKey: tabId)
    tabIsRunningById.removeValue(forKey: tabId)
  }

  private func tabId(containing surfaceId: UUID) -> TerminalTabID? {
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
    tabManager.updateDirty(tabId, isDirty: isRunningNow)
    emitTaskStatusIfChanged()
  }

  private func emitTaskStatusIfChanged() {
    let newStatus = focusedTaskStatus
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
    guard let tabId = tabId(containing: view.id), let tree = trees[tabId] else {
      view.closeSurface()
      surfaces.removeValue(forKey: view.id)
      return
    }
    guard let node = tree.find(id: view.id) else {
      view.closeSurface()
      surfaces.removeValue(forKey: view.id)
      return
    }
    let newTree = tree.removing(node)
    view.closeSurface()
    surfaces.removeValue(forKey: view.id)
    if newTree.isEmpty {
      trees.removeValue(forKey: tabId)
      focusedSurfaceIdByTab.removeValue(forKey: tabId)
      tabManager.closeTab(tabId)
      if tabId == runScriptTabId {
        setRunScriptTabId(nil)
      }
      return
    }
    trees[tabId] = newTree
    updateRunningState(for: tabId)
    if focusedSurfaceIdByTab[tabId] == view.id {
      if let nextSurface = newTree.root?.leftmostLeaf() {
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
