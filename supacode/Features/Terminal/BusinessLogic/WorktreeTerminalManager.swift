import Foundation
import Observation
import Sharing

@MainActor
@Observable
final class WorktreeTerminalManager {
  private let runtime: GhosttyRuntime
  private let agentHookSignalMonitor: AgentHookSignalMonitor
  private let synchronizeAgentHooks: (Bool, Bool) throws -> Void
  private let agentHooksInstalled: () -> Bool
  private let agentHooksBinPathProvider: () -> String
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  private var notificationsEnabled = true
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  private var agentHooksBinPath: String?
  var selectedWorktreeID: Worktree.ID?

  init(
    runtime: GhosttyRuntime,
    agentHookSignalMonitor: AgentHookSignalMonitor? = nil,
    synchronizeAgentHooks: @escaping (Bool, Bool) throws -> Void = { claudeEnabled, codexEnabled in
      try AgentHooksInstaller.synchronize(
        claudeEnabled: claudeEnabled,
        codexEnabled: codexEnabled
      )
    },
    agentHooksInstalled: @escaping () -> Bool = { AgentHooksInstaller.isInstalled },
    agentHooksBinPathProvider: @escaping () -> String = {
      AgentHooksInstaller.binDirectory.path(percentEncoded: false)
    }
  ) {
    self.runtime = runtime
    self.agentHookSignalMonitor = agentHookSignalMonitor ?? AgentHookSignalMonitor()
    self.synchronizeAgentHooks = synchronizeAgentHooks
    self.agentHooksInstalled = agentHooksInstalled
    self.agentHooksBinPathProvider = agentHooksBinPathProvider
    self.agentHookSignalMonitor.onStatusChanged = { [weak self] surfaceID, isWorking in
      self?.handleAgentHookSignal(surfaceID: surfaceID, isWorking: isWorking)
    }
  }

  func handleCommand(_ command: TerminalClient.Command) {
    if handleTabCommand(command) {
      return
    }
    if handleSearchCommand(command) {
      return
    }
    handleManagementCommand(command)
  }

  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew):
      Task { createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew) }
    case .createTabWithInput(let worktree, let input, let runSetupScriptIfNew):
      Task {
        createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, initialInput: input)
      }
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .runScript(let worktree, let script):
      _ = state(for: worktree).runScript(script)
    case .stopRunScript(let worktree):
      _ = state(for: worktree).stopRunScript()
    case .closeFocusedTab(let worktree):
      _ = closeFocusedTab(in: worktree)
    case .closeFocusedSurface(let worktree):
      _ = closeFocusedSurface(in: worktree)
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
      state(for: worktree).performBindingActionOnFocusedSurface("navigate_search:next")
    case .navigateSearchPrevious(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("navigate_search:previous")
    case .endSearch(let worktree):
      state(for: worktree).performBindingActionOnFocusedSurface("end_search")
    default:
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
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      if let previousID = selectedWorktreeID, let previousState = states[previousID] {
        previousState.setAllSurfacesOccluded()
      }
      selectedWorktreeID = id
    case .setAgentHookIntegrations(let claudeEnabled, let codexEnabled):
      setAgentHookIntegrations(claudeEnabled: claudeEnabled, codexEnabled: codexEnabled)
    default:
      return
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
      return existing
    }
    let runSetupScript = runSetupScriptIfNew()
    let state = WorktreeTerminalState(
      runtime: runtime,
      worktree: worktree,
      runSetupScript: runSetupScript
    )
    state.setAgentHooksBinPath(agentHooksBinPath)
    state.setNotificationsEnabled(notificationsEnabled)
    state.isSelected = { [weak self] in
      self?.selectedWorktreeID == worktree.id
    }
    state.onNotificationReceived = { [weak self] title, body in
      self?.emit(.notificationReceived(worktreeID: worktree.id, title: title, body: body))
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
    state.onRunScriptStatusChanged = { [weak self] isRunning in
      self?.emit(.runScriptStatusChanged(worktreeID: worktree.id, isRunning: isRunning))
    }
    state.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    state.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    states[worktree.id] = state
    return state
  }

  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil
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
    _ = state.createTab(setupScript: setupScript, initialInput: initialInput)
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
    var removed: [WorktreeTerminalState] = []
    for (id, state) in states where !worktreeIDs.contains(id) {
      removed.append(state)
    }
    for state in removed {
      state.closeAllSurfaces()
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    emitNotificationIndicatorCountIfNeeded()
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  func focusedTaskStatus(for worktreeID: Worktree.ID) -> WorktreeTaskStatus? {
    states[worktreeID]?.focusedTaskStatus
  }

  func isRunScriptRunning(for worktreeID: Worktree.ID) -> Bool {
    states[worktreeID]?.isRunScriptRunning == true
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

  private func setAgentHookIntegrations(claudeEnabled: Bool, codexEnabled: Bool) {
    do {
      try synchronizeAgentHooks(claudeEnabled, codexEnabled)
    } catch {
      for state in states.values {
        state.clearAgentWorkingStatus()
        state.setAgentHooksBinPath(nil)
      }
      agentHooksBinPath = nil
      agentHookSignalMonitor.stopPolling()
      return
    }

    let hasIntegrationEnabled = claudeEnabled || codexEnabled
    if hasIntegrationEnabled && agentHooksInstalled() {
      agentHooksBinPath = agentHooksBinPathProvider()
      for state in states.values {
        state.setAgentHooksBinPath(agentHooksBinPath)
      }
      agentHookSignalMonitor.startPolling()
      return
    }

    agentHooksBinPath = nil
    for state in states.values {
      state.clearAgentWorkingStatus()
      state.setAgentHooksBinPath(nil)
    }
    agentHookSignalMonitor.stopPolling()
  }

  private func handleAgentHookSignal(surfaceID: UUID, isWorking: Bool) {
    for state in states.values where state.setAgentWorkingStatus(surfaceID: surfaceID, isWorking: isWorking) {
      return
    }
  }
}
