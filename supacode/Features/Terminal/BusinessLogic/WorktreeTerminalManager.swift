import Foundation
import Observation
import Sharing
import SupacodeSettingsShared
import SwiftUI

private let terminalLogger = SupaLogger("Terminal")

@MainActor
@Observable
final class WorktreeTerminalManager {
  private let runtime: GhosttyRuntime
  private(set) var socketServer: AgentHookSocketServer?
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  private var notificationsEnabled = true
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  var selectedWorktreeID: Worktree.ID?
  var saveLayoutSnapshot: ((Worktree.ID, TerminalLayoutSnapshot?) -> Void)?
  var loadLayoutSnapshot: ((Worktree.ID) -> TerminalLayoutSnapshot?)?
  /// Deeplink URL received from the CLI via socket. Second parameter is the client FD for response.
  var onDeeplinkCommand: ((URL, Int32) -> Void)?
  /// Query received from the CLI via socket. Parameters: resource name, params, client FD.
  var onQuery: ((String, [String: String], Int32) -> Void)?

  init(runtime: GhosttyRuntime, socketServer: AgentHookSocketServer? = nil) {
    self.runtime = runtime
    let resolvedServer = socketServer ?? AgentHookSocketServer()
    guard resolvedServer.socketPath != nil else {
      self.socketServer = nil
      terminalLogger.warning("Agent hook socket server unavailable")
      return
    }
    self.socketServer = resolvedServer
    configureSocketServer(resolvedServer)
  }

  private func configureSocketServer(_ server: AgentHookSocketServer) {
    server.onBusy = { [weak self] worktreeID, tabID, surfaceID, active in
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      guard let state = self?.states[decoded] else {
        terminalLogger.debug("Dropped busy update for unknown worktree \(decoded)")
        return
      }
      state.setAgentBusy(
        surfaceID: surfaceID,
        tabID: TerminalTabID(rawValue: tabID),
        active: active
      )
    }
    server.onNotification = { [weak self] worktreeID, _, surfaceID, notification in
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      guard let state = self?.states[decoded] else {
        terminalLogger.debug("Dropped hook notification for unknown worktree \(decoded)")
        return
      }
      let title = notification.title ?? notification.agent
      let body = notification.body ?? ""
      state.appendHookNotification(title: title, body: body, surfaceID: surfaceID)
    }
    server.onCommand = { [weak self] deeplinkURL, clientFD in
      guard let handler = self?.onDeeplinkCommand else {
        AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: false, error: "Not ready.")
        return
      }
      handler(deeplinkURL, clientFD)
    }
    server.onQuery = { [weak self] resource, params, clientFD in
      guard let handler = self?.onQuery else {
        AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: false, error: "Not ready.")
        return
      }
      handler(resource, params, clientFD)
    }
  }

  // MARK: - CLI queries.

  func listTabs(worktreeID: String) -> [[String: String]]? {
    let decoded = worktreeID.removingPercentEncoding ?? worktreeID
    guard let state = states[decoded] else { return nil }
    let selectedTabID = state.tabManager.selectedTabId
    return state.tabManager.tabs.map { tab in
      var entry = ["id": tab.id.rawValue.uuidString]
      if tab.id == selectedTabID { entry["focused"] = "1" }
      return entry
    }
  }

  func listSurfaces(worktreeID: String, tabID: String) -> [[String: String]]? {
    let decoded = worktreeID.removingPercentEncoding ?? worktreeID
    guard let state = states[decoded],
      let tabUUID = UUID(uuidString: tabID)
    else { return nil }
    let terminalTabID = TerminalTabID(rawValue: tabUUID)
    return state.listSurfaces(tabID: terminalTabID)
  }

  func handleCommand(_ command: TerminalClient.Command) {
    if handleTabCommand(command) {
      return
    }
    if handleBindingActionCommand(command) {
      return
    }
    if handleSearchCommand(command) {
      return
    }
    handleManagementCommand(command)
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew, let id):
      Task { createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, tabID: id) }
    case .createTabWithInput(let worktree, let input, let runSetupScriptIfNew, let id):
      Task {
        createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, initialInput: input, tabID: id)
      }
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .stopRunScript(let worktree):
      _ = state(for: worktree).stopRunScripts()
    case .stopScript(let worktree, let definitionID):
      _ = state(for: worktree).stopScript(definitionID: definitionID)
    case .runBlockingScript(let worktree, let kind, let script):
      _ = state(for: worktree).runBlockingScript(kind: kind, script)
    case .closeFocusedTab(let worktree):
      _ = closeFocusedTab(in: worktree)
    case .closeFocusedSurface(let worktree):
      _ = closeFocusedSurface(in: worktree)
    case .selectTab(let worktree, let tabID):
      state(for: worktree).selectTab(tabID)
    case .focusSurface(let worktree, let tabID, let surfaceID, let input):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      guard terminal.focusSurface(id: surfaceID) else {
        terminalLogger.warning("focusSurface: surface \(surfaceID) not found in worktree \(worktree.id).")
        break
      }
      if let input, !input.isEmpty {
        terminal.focusAndInsertText(input + "\r")
      }
    case .splitSurface(let worktree, let tabID, let surfaceID, let direction, let input, let id):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      let ghosttyDirection: GhosttySplitAction.NewDirection = direction == .vertical ? .down : .right
      let resolvedInput = makeCommandInput(script: input ?? "")
      let splitSucceeded = terminal.performSplitAction(
        .newSplit(direction: ghosttyDirection),
        for: surfaceID,
        newSurfaceID: id,
        initialInput: resolvedInput
      )
      guard splitSucceeded else {
        terminalLogger.warning("splitSurface: failed for surface \(surfaceID) in worktree \(worktree.id).")
        break
      }
    case .destroyTab(let worktree, let tabID):
      let terminal = state(for: worktree)
      guard terminal.tabManager.tabs.contains(where: { $0.id == tabID }) else {
        terminalLogger.warning("destroyTab: tab \(tabID.rawValue) not found in worktree \(worktree.id).")
        break
      }
      terminal.closeTab(tabID)
    case .destroySurface(let worktree, let tabID, let surfaceID):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      if !terminal.closeSurface(id: surfaceID) {
        terminalLogger.warning("destroySurface: surface \(surfaceID) not found in worktree \(worktree.id).")
      }
    default:
      return false
    }
    return true
  }

  private func handleSearchCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .startSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("start_search")
    case .searchSelection(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("search_selection")
    case .navigateSearchNext(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.previous)
    case .endSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("end_search")
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .performBindingAction,
      .selectTab, .focusSurface, .splitSurface, .destroyTab, .destroySurface, .prune,
      .setNotificationsEnabled, .setSelectedWorktreeID, .refreshTabBarVisibility:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      state(for: worktree).performBindingActionOnFocusedSurface(action)
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .startSearch, .searchSelection,
      .navigateSearchNext, .navigateSearchPrevious, .endSearch, .selectTab, .focusSurface,
      .splitSurface, .destroyTab, .destroySurface, .prune, .setNotificationsEnabled,
      .setSelectedWorktreeID, .refreshTabBarVisibility:
      return false
    }
    return true
  }

  private func handleManagementCommand(_ command: TerminalClient.Command) {
    switch command {
    case .prune(let ids):
      prune(keeping: ids)
    case .setNotificationsEnabled(let enabled):
      setNotificationsEnabled(enabled)
    case .refreshTabBarVisibility:
      for state in states.values {
        state.refreshTabBarVisibility()
      }
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      if let previousID = selectedWorktreeID, let previousState = states[previousID] {
        previousState.setAllSurfacesOccluded()
        saveLayoutSnapshot?(previousID, previousState.captureLayoutSnapshot())
      }
      selectedWorktreeID = id
      terminalLogger.info("Selected worktree \(id ?? "nil")")
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .performBindingAction,
      .startSearch, .searchSelection, .navigateSearchNext, .navigateSearchPrevious, .endSearch,
      .selectTab, .focusSurface, .splitSurface, .destroyTab, .destroySurface:
      assertionFailure("Unhandled terminal command reached management handler: \(command)")
    }
  }

  func eventStream() -> AsyncStream<TerminalClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: TerminalClient.Event.self)
    eventContinuation = continuation
    lastNotificationIndicatorCount = nil
    if !pendingEvents.isEmpty {
      let bufferedEvents = pendingEvents
      pendingEvents.removeAll()
      for event in bufferedEvents {
        if case .notificationIndicatorChanged = event {
          continue
        }
        continuation.yield(event)
      }
    }
    emitNotificationIndicatorCountIfNeeded()
    return stream
  }

  func state(
    for worktree: Worktree,
    runSetupScriptIfNew: () -> Bool = { false }
  ) -> WorktreeTerminalState {
    if let existing = states[worktree.id] {
      if runSetupScriptIfNew() {
        existing.enableSetupScriptIfNeeded()
      }
      // Reload snapshot if the state has no tabs (e.g., setting was just enabled).
      if existing.tabManager.tabs.isEmpty,
        existing.pendingLayoutSnapshot == nil,
        !existing.needsSetupScript()
      {
        existing.pendingLayoutSnapshot = loadLayoutSnapshot?(worktree.id)
      }
      return existing
    }
    let runSetupScript = runSetupScriptIfNew()
    let state = WorktreeTerminalState(
      runtime: runtime,
      worktree: worktree,
      runSetupScript: runSetupScript
    )
    state.socketPath = socketServer?.socketPath
    // Load saved layout snapshot for restoration (skip when a setup script is pending).
    if !runSetupScript {
      state.pendingLayoutSnapshot = loadLayoutSnapshot?(worktree.id)
    }
    state.setNotificationsEnabled(notificationsEnabled)
    state.isSelected = { [weak self] in
      self?.selectedWorktreeID == worktree.id
    }
    state.onNotificationReceived = { [weak self] surfaceID, title, body in
      self?.emit(
        .notificationReceived(
          worktreeID: worktree.id,
          surfaceID: surfaceID,
          title: title,
          body: body
        )
      )
    }
    state.onNotificationIndicatorChanged = { [weak self] in
      self?.emitNotificationIndicatorCountIfNeeded()
    }
    state.onTabCreated = { [weak self] in
      self?.emit(.tabCreated(worktreeID: worktree.id))
    }
    state.onTabClosed = { [weak self] in
      self?.emit(.tabClosed(worktreeID: worktree.id))
    }
    state.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
    }
    state.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
    }
    state.onBlockingScriptCompleted = { [weak self] kind, exitCode, tabId in
      self?.emit(.blockingScriptCompleted(worktreeID: worktree.id, kind: kind, exitCode: exitCode, tabId: tabId))
    }
    state.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    state.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    states[worktree.id] = state
    terminalLogger.info("Created terminal state for worktree \(worktree.id)")
    return state
  }

  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil,
    tabID: UUID? = nil
  ) {
    let state = state(for: worktree) { runSetupScriptIfNew }
    let setupScript: String?
    if state.needsSetupScript() {
      @SharedReader(.repositorySettings(worktree.repositoryRootURL))
      var settings = RepositorySettings.default
      setupScript = settings.setupScript
    } else {
      setupScript = nil
    }
    _ = state.createTab(setupScript: setupScript, initialInput: initialInput, tabID: tabID)
  }

  @discardableResult
  func closeFocusedTab(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedTab()
  }

  @discardableResult
  func closeFocusedSurface(in worktree: Worktree) -> Bool {
    let state = state(for: worktree)
    return state.closeFocusedSurface()
  }

  func prune(keeping worktreeIDs: Set<Worktree.ID>) {
    var removed: [(Worktree.ID, WorktreeTerminalState)] = []
    for (id, state) in states where !worktreeIDs.contains(id) {
      removed.append((id, state))
    }
    for (id, state) in removed {
      saveLayoutSnapshot?(id, state.captureLayoutSnapshot())
      state.closeAllSurfaces()
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    emitNotificationIndicatorCountIfNeeded()
  }

  func tabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.hasTab(tabID) ?? false
  }

  func surfaceExists(worktreeID: Worktree.ID, tabID: TerminalTabID, surfaceID: UUID) -> Bool {
    states[worktreeID]?.hasSurface(surfaceID, in: tabID) ?? false
  }

  /// Checks whether a surface UUID exists anywhere in the worktree (across all tabs).
  func surfaceExistsInWorktree(worktreeID: Worktree.ID, surfaceID: UUID) -> Bool {
    states[worktreeID]?.hasSurfaceAnywhere(surfaceID) ?? false
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  func taskStatus(for worktreeID: Worktree.ID) -> WorktreeTaskStatus? {
    states[worktreeID]?.taskStatus
  }

  func isBlockingScriptRunning(kind: BlockingScriptKind, for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.isBlockingScriptRunning(kind: kind) == true
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    for state in states.values {
      state.setNotificationsEnabled(enabled)
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  func hasUnseenNotifications(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.hasUnseenNotification == true
  }

  /// Locates the most recent unread notification across all managed
  /// worktrees whose surface still exists. Notifications whose surface has
  /// been closed are skipped in favour of the next-newest focusable unread.
  func latestUnreadNotificationLocation() -> NotificationLocation? {
    var best: NotificationLocation?
    var bestCreatedAt: Date?
    var skippedClosedSurface = false
    for (worktreeID, state) in states {
      for notification in state.unreadNotifications() {
        if let bestCreatedAt, bestCreatedAt >= notification.createdAt { break }
        guard let tabID = state.tabID(containing: notification.surfaceId) else {
          skippedClosedSurface = true
          terminalLogger.debug(
            "latestUnreadNotificationLocation: skipping closed surface \(notification.surfaceId) "
              + "in \(worktreeID); trying older unread."
          )
          continue
        }
        best = NotificationLocation(
          worktreeID: worktreeID,
          tabID: tabID,
          surfaceID: notification.surfaceId,
          notificationID: notification.id,
        )
        bestCreatedAt = notification.createdAt
        break
      }
    }
    if best == nil, skippedClosedSurface {
      terminalLogger.debug("latestUnreadNotificationLocation: all unread notifications point at closed surfaces.")
    }
    return best
  }

  /// Resolves the tab containing the given surface, if any.
  func tabID(forWorktreeID worktreeID: Worktree.ID, surfaceID: UUID) -> TerminalTabID? {
    states[worktreeID]?.tabID(containing: surfaceID)
  }

  func markNotificationRead(worktreeID: Worktree.ID, notificationID: UUID) {
    states[worktreeID]?.markNotificationRead(id: notificationID)
  }

  func saveAllLayoutSnapshots() {
    guard let saveLayoutSnapshot else {
      assertionFailure("saveLayoutSnapshot closure not configured.")
      return
    }
    for (id, state) in states {
      saveLayoutSnapshot(id, state.captureLayoutSnapshot())
    }
  }

  func surfaceBackgroundOpacity() -> Double {
    runtime.backgroundOpacity()
  }

  func unfocusedSplitOverlay() -> (fill: Color?, opacity: Double) {
    (runtime.unfocusedSplitFill(), runtime.unfocusedSplitOverlayOpacity())
  }

  private func emit(_ event: TerminalClient.Event) {
    guard let eventContinuation else {
      pendingEvents.append(event)
      return
    }
    eventContinuation.yield(event)
  }

  private func emitNotificationIndicatorCountIfNeeded() {
    let count = states.values.reduce(0) { count, state in
      count + (state.hasUnseenNotification ? 1 : 0)
    }
    if count != lastNotificationIndicatorCount {
      lastNotificationIndicatorCount = count
      emit(.notificationIndicatorChanged(count: count))
    }
  }
}
