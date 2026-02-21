import Foundation
import Observation
import Sharing

private let terminalLogger = SupaLogger("Terminal")

@MainActor
@Observable
final class WorktreeTerminalManager {
  private let runtime: GhosttyRuntime
  private let agentEventsLogURL: URL
  private let agentEventPollIntervalNanoseconds: UInt64
  private var states: [Worktree.ID: WorktreeTerminalState] = [:]
  private var notificationsEnabled = true
  private var lastNotificationIndicatorCount: Int?
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  private var agentEventPollTask: Task<Void, Never>?
  var selectedWorktreeID: Worktree.ID?

  init(
    runtime: GhosttyRuntime,
    agentEventsLogURL: URL = SupacodePaths.agentEventsLogURL,
    agentEventPollIntervalNanoseconds: UInt64 = 300_000_000
  ) {
    self.runtime = runtime
    self.agentEventsLogURL = agentEventsLogURL
    self.agentEventPollIntervalNanoseconds = agentEventPollIntervalNanoseconds
    startAgentEventPolling()
  }

  isolated deinit {
    agentEventPollTask?.cancel()
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
      state(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious(let worktree):
      state(for: worktree).navigateSearchOnFocusedSurface(.previous)
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
      terminalLogger.info("Selected worktree \(id ?? "nil")")
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
    terminalLogger.info("Created terminal state for worktree \(worktree.id)")
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
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { worktreeIDs.contains($0.key) }
    emitNotificationIndicatorCountIfNeeded()
  }

  func stateIfExists(for worktreeID: Worktree.ID) -> WorktreeTerminalState? {
    states[worktreeID]
  }

  func taskStatus(for worktreeID: Worktree.ID) -> WorktreeTaskStatus? {
    states[worktreeID]?.taskStatus
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

  private func startAgentEventPolling() {
    let logURL = agentEventsLogURL
    let pollInterval = agentEventPollIntervalNanoseconds
    agentEventPollTask?.cancel()
    agentEventPollTask = Task.detached(priority: .utility) { [weak self] in
      var offset = Self.initialAgentEventOffset(at: logURL)
      var buffer = Data()
      while !Task.isCancelled {
        let (chunk, newOffset) = Self.readAgentEventChunk(at: logURL, offset: offset)
        offset = newOffset
        if !chunk.isEmpty {
          buffer.append(chunk)
          let events = Self.parseAgentEvents(from: &buffer)
          if !events.isEmpty {
            await self?.applyAgentEvents(events)
          }
        }
        try? await Task.sleep(nanoseconds: pollInterval)
      }
    }
  }

  private func applyAgentEvents(_ events: [AgentHookEvent]) {
    for event in events {
      states[event.worktreeID]?.handleAgentLifecycleEvent(event.eventType)
    }
  }

  nonisolated private static func initialAgentEventOffset(at url: URL) -> UInt64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
      let fileSize = attributes[.size] as? NSNumber
    else {
      return 0
    }
    return fileSize.uint64Value
  }

  nonisolated private static func readAgentEventChunk(at url: URL, offset: UInt64) -> (Data, UInt64) {
    let path = url.path(percentEncoded: false)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let fileSize = attributes[.size] as? NSNumber
    else {
      return (Data(), 0)
    }

    let totalBytes = fileSize.uint64Value
    let safeOffset = min(offset, totalBytes)
    guard totalBytes > safeOffset else {
      return (Data(), safeOffset)
    }

    guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
      return (Data(), safeOffset)
    }
    defer { try? fileHandle.close() }

    do {
      try fileHandle.seek(toOffset: safeOffset)
      let data = try fileHandle.readToEnd() ?? Data()
      return (data, safeOffset + UInt64(data.count))
    } catch {
      return (Data(), safeOffset)
    }
  }

  nonisolated private static func parseAgentEvents(from buffer: inout Data) -> [AgentHookEvent] {
    var events: [AgentHookEvent] = []
    while let newlineRange = buffer.range(of: Data([0x0a])) {
      let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
      buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
      guard !lineData.isEmpty else { continue }
      if let event = parseAgentEvent(lineData) {
        events.append(event)
      }
    }
    return events
  }

  nonisolated private static func parseAgentEvent(_ lineData: Data) -> AgentHookEvent? {
    guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
      let eventType = object["eventType"] as? String
    else {
      return nil
    }
    let worktreeID = (object["worktreeID"] as? String) ?? (object["worktreeId"] as? String)
    guard let worktreeID, !worktreeID.isEmpty else {
      return nil
    }
    return AgentHookEvent(worktreeID: worktreeID, eventType: eventType)
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

private struct AgentHookEvent: Sendable {
  let worktreeID: Worktree.ID
  let eventType: String
}
