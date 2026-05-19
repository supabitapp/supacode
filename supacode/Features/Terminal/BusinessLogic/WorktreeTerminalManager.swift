import ComposableArchitecture
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
  @ObservationIgnored
  @Shared(.settingsFile) private var settingsFile: SettingsFile
  private var notificationsEnabled = true
  private var lastNotificationIndicatorCount: Int?
  /// Per-worktree dedup of `worktreeProjectionChanged`; identical projections
  /// (common on hook storms) are dropped before they hit the AsyncStream.
  private var lastEmittedProjections: [Worktree.ID: WorktreeRowProjection] = [:]
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  @ObservationIgnored
  private var pendingIdleHookEvents: [IdleDebounceKey: Task<Void, Never>] = [:]
  @ObservationIgnored
  private let hookEventSleep: @Sendable (Duration) async throws -> Void
  /// Holds `.idle` long enough to collapse PostToolUse/PreToolUse busy/idle alternation
  /// into a sustained busy; stays sub-perceptible for the badge clearing at end-of-session.
  private static let idleHookDebounceDuration: Duration = .milliseconds(400)

  private struct IdleDebounceKey: Hashable {
    let surfaceID: UUID
    let agent: SkillAgent
  }

  var selectedWorktreeID: Worktree.ID?
  var saveLayoutSnapshot: ((Worktree.ID, TerminalLayoutSnapshot?) -> Void)?
  var loadLayoutSnapshot: ((Worktree.ID) -> TerminalLayoutSnapshot?)?
  /// Deeplink URL received from the CLI via socket. Second parameter is the client FD for response.
  var onDeeplinkCommand: ((URL, Int32) -> Void)?
  /// Query received from the CLI via socket. Parameters: resource name, params, client FD.
  var onQuery: ((String, [String: String], Int32) -> Void)?

  init<C: Clock<Duration>>(
    runtime: GhosttyRuntime,
    socketServer: AgentHookSocketServer? = nil,
    clock: C = ContinuousClock(),
  ) {
    self.runtime = runtime
    self.hookEventSleep = { duration in try await clock.sleep(for: duration) }
    let resolvedServer = socketServer ?? AgentHookSocketServer()
    guard resolvedServer.socketPath != nil else {
      self.socketServer = nil
      terminalLogger.warning("Agent hook socket server unavailable")
      return
    }
    self.socketServer = resolvedServer
    configureSocketServer(resolvedServer)
  }

  isolated deinit {
    for task in pendingIdleHookEvents.values { task.cancel() }
  }

  private func configureSocketServer(_ server: AgentHookSocketServer) {
    server.onNotification = { [weak self] worktreeID, _, surfaceID, notification in
      guard let self else { return }
      guard self.settingsFile.global.richAgentNotificationsEnabled else { return }
      let decoded = worktreeID.removingPercentEncoding ?? worktreeID
      guard let state = self.states[decoded] else {
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
    // Always record; the badges toggle gates DISPLAY in
    // `AgentPresenceFeature.State.agents(forSurface:badgesEnabled:)`.
    // Gating recording too would drop session_start events fired while
    // the toggle was off, so flipping it back on later wouldn't restore
    // badges for already-running agents.
    server.onEvent = { [weak self] event in
      self?.dispatchHookEvent(event)
    }
  }

  /// Holds `.idle` for a debounce window so PostToolUse / PreToolUse storms don't flap downstream UI.
  /// Lives at the socket boundary so the debounce applies before the event lands in TCA.
  private func dispatchHookEvent(_ event: AgentHookEvent) {
    guard let agent = SkillAgent(rawValue: event.agent) else {
      applyHookEvent(event)
      return
    }
    let key = IdleDebounceKey(surfaceID: event.surfaceID, agent: agent)
    pendingIdleHookEvents.removeValue(forKey: key)?.cancel()
    guard event.eventName == .idle else {
      applyHookEvent(event)
      return
    }
    let sleep = hookEventSleep
    pendingIdleHookEvents[key] = Task { [weak self] in
      try? await sleep(Self.idleHookDebounceDuration)
      // MainActor serializes the resume; this task can't race with another
      // dispatch on the same key (cancel-on-new-event is the only way to
      // interleave, and it sets isCancelled before we get here).
      guard !Task.isCancelled, let self else { return }
      self.applyHookEvent(event)
      self.pendingIdleHookEvents.removeValue(forKey: key)
    }
  }

  private func cancelPendingIdleHooks(forSurfaceIDs surfaceIDs: Set<UUID>) {
    let stale = pendingIdleHookEvents.keys.filter { surfaceIDs.contains($0.surfaceID) }
    for key in stale {
      pendingIdleHookEvents.removeValue(forKey: key)?.cancel()
    }
  }

  private func applyHookEvent(_ event: AgentHookEvent) {
    emit(.agentHookEventReceived(event))
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
    case .beginTabRename(let worktree, let explicitTabID):
      let terminal = state(for: worktree)
      guard let tabID = explicitTabID ?? terminal.tabManager.selectedTabId else { break }
      terminal.tabManager.beginTabRename(tabID)
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
      let resolvedInput = BlockingScriptRunner.makeCommandInput(script: input ?? "")
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
      .performBindingActionOnSurface, .selectTab, .focusSurface, .splitSurface, .destroyTab,
      .destroySurface, .prune, .setNotificationsEnabled, .setSelectedWorktreeID,
      .refreshTabBarVisibility, .beginTabRename:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      state(for: worktree).performBindingActionOnFocusedSurface(action)
    case .performBindingActionOnSurface(let worktree, let surfaceID, let action):
      state(for: worktree).performBindingAction(action, onSurfaceID: surfaceID)
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .startSearch, .searchSelection,
      .navigateSearchNext, .navigateSearchPrevious, .endSearch, .selectTab, .focusSurface,
      .splitSurface, .destroyTab, .destroySurface, .prune, .setNotificationsEnabled,
      .setSelectedWorktreeID, .refreshTabBarVisibility, .beginTabRename:
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
      .performBindingActionOnSurface, .startSearch, .searchSelection, .navigateSearchNext,
      .navigateSearchPrevious, .endSearch, .selectTab, .focusSurface, .splitSurface, .destroyTab,
      .destroySurface, .beginTabRename:
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
    // Seed each worktree's projection so rows attached after the stream start
    // pick up the current snapshot (otherwise they'd stay default until the
    // next mutation).
    lastEmittedProjections.removeAll()
    for id in states.keys { emitProjection(for: id) }
    // Replay per-tab projections / stripe-progress displays for the same reason:
    // a new subscriber needs the existing `terminalTabs[id:]` rows seeded so
    // tab-bar leaves don't render empty until the next per-tab mutation.
    for (worktreeID, state) in states {
      for projection in state.currentTabProjections() {
        continuation.yield(.tabProjectionChanged(worktreeID: worktreeID, projection))
      }
      for (tabID, display) in state.currentTabProgressDisplays() {
        continuation.yield(
          .tabProgressDisplayChanged(worktreeID: worktreeID, tabID: tabID, display: display)
        )
      }
    }
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
    state.onSurfacesClosed = { [weak self] ids in
      self?.emit(.surfacesClosed(ids))
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
      self?.emitProjection(for: worktree.id)
    }
    state.onNotificationIndicatorChanged = { [weak self] in
      self?.emitNotificationIndicatorCountIfNeeded()
      self?.emitProjection(for: worktree.id)
    }
    state.onTabCreated = { [weak self] in
      self?.emit(.tabCreated(worktreeID: worktree.id))
      self?.emitProjection(for: worktree.id)
    }
    state.onTabClosed = { [weak self] in
      self?.emit(.tabClosed(worktreeID: worktree.id))
      self?.emitProjection(for: worktree.id)
    }
    state.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
    }
    state.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
      self?.emitProjection(for: worktree.id)
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
    state.onTabProjectionChanged = { [weak self] projection in
      self?.emit(.tabProjectionChanged(worktreeID: worktree.id, projection))
    }
    state.onTabRemoved = { [weak self] tabID in
      self?.emit(.tabRemoved(worktreeID: worktree.id, tabID: tabID))
    }
    state.onTabProgressDisplayChanged = { [weak self] tabID, display in
      self?.emit(.tabProgressDisplayChanged(worktreeID: worktree.id, tabID: tabID, display: display))
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
    let prunedSurfaceIDs = Set(removed.flatMap { _, state in state.allSurfaceIDs })
    for (id, state) in removed {
      saveLayoutSnapshot?(id, state.captureLayoutSnapshot())
      state.closeAllSurfaces()
      // Signals the reducer to drop any orphan `terminalTabs` entries and
      // recently-removed-tab records for this worktree so a same-session
      // restore (snapshot reuses persisted tab UUIDs) starts clean.
      emit(.worktreeStateTornDown(worktreeID: id))
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    cancelPendingIdleHooks(forSurfaceIDs: prunedSurfaceIDs)
    for (id, _) in removed { lastEmittedProjections.removeValue(forKey: id) }
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

  /// Surface IDs that live in this tab.
  func surfaceIDs(forTabID tabID: TerminalTabID) -> [UUID] {
    for state in states.values {
      let ids = state.surfaceIDs(inTab: tabID)
      if !ids.isEmpty { return ids }
    }
    return []
  }

  /// Surface IDs across every tab in this worktree.
  func surfaceIDs(forWorktreeID worktreeID: Worktree.ID) -> [UUID] {
    states[worktreeID]?.allSurfaceIDs ?? []
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
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
        guard let tabID = state.tabID(containing: notification.surfaceID) else {
          skippedClosedSurface = true
          terminalLogger.debug(
            "latestUnreadNotificationLocation: skipping closed surface \(notification.surfaceID) "
              + "in \(worktreeID); trying older unread."
          )
          continue
        }
        best = NotificationLocation(
          worktreeID: worktreeID,
          tabID: tabID,
          surfaceID: notification.surfaceID,
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
    emitProjection(for: worktreeID)
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

  func surfaceBackgroundColorScheme() -> ColorScheme {
    runtime.backgroundColorScheme()
  }

  var ghosttyRuntime: GhosttyRuntime { runtime }

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

  /// Builds the row projection and emits only when it diverges from the last
  /// emitted snapshot. Suppresses the no-op storms that PreToolUse / PostToolUse
  /// hook bursts produce after the per-row equality short-circuit lands.
  /// Skipped while no subscriber is attached so projections never accumulate in
  /// `pendingEvents` (the row reads its initial snapshot from the next live emit).
  private func emitProjection(for worktreeID: Worktree.ID) {
    guard eventContinuation != nil else { return }
    guard let state = states[worktreeID] else { return }
    let projection = state.currentProjection()
    if lastEmittedProjections[worktreeID] == projection { return }
    lastEmittedProjections[worktreeID] = projection
    emit(.worktreeProjectionChanged(worktreeID, projection))
  }
}
