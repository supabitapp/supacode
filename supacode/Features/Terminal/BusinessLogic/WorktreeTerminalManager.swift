import AppKit
import ComposableArchitecture
import Foundation
import GhosttyKit
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
  // Cached so views read one Bool instead of iterating sidebarItems.
  private var lastEmittedHasAnyTerminalSurface: Bool?
  /// Per-worktree dedup of `worktreeProjectionChanged`; identical projections
  /// (common on hook storms) are dropped before they hit the AsyncStream.
  private var lastEmittedProjections: [Worktree.ID: WorktreeRowProjection] = [:]
  private var eventContinuation: AsyncStream<TerminalClient.Event>.Continuation?
  private var pendingEvents: [TerminalClient.Event] = []
  /// Latest-wins events deduped by identity: drops a value equal to the
  /// immediately-previous one per key (a burst of distinct values still passes),
  /// so per-tab projection / progress / task-status / focus repeats don't flood
  /// the stream. Cleared on resubscribe and purged on tab / worktree teardown.
  private var lastEmittedCoalescable: [CoalesceKey: TerminalClient.Event] = [:]
  /// Worktrees whose projection was shed under backpressure, awaiting next-tick
  /// redelivery. Coalesced so a shed storm replays each id at most once per tick.
  private var pendingShedProjectionReplays: Set<Worktree.ID> = []
  /// True while a replay drain is emitting, so a replay that itself sheds can't
  /// schedule another and spin the buffer.
  private var isDrainingShedProjectionReplays = false
  /// Hard cap on the live event buffer. Source coalescing keeps it near-empty in
  /// practice; this backstops a wedged consumer so memory stays bounded instead
  /// of growing without limit.
  static let defaultEventBufferCap = 2048
  /// Injectable so tests can force buffer shedding without 2k+ events.
  let eventBufferCap: Int
  /// Cap for lifecycle events buffered before the first subscriber attaches.
  /// Coalescable state collapses per key and doesn't count, so this only bounds
  /// one-shot events; the sole consumer attaches at launch, well under the cap.
  static let pendingEventCap = 1024
  @ObservationIgnored
  private var pendingIdleHookEvents: [IdleDebounceKey: Task<Void, Never>] = [:]
  @ObservationIgnored
  private let hookEventSleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored @Dependency(\.zmxClient) private var zmxClient
  @ObservationIgnored @Dependency(\.analyticsClient) private var analyticsClient
  /// Serialized off-main writer that merges per-worktree layout changes into
  /// `layouts.json` without clobbering keys it isn't carrying. Built from the
  /// dependency context at init so async flushes use the same storage the test
  /// or app configured, not whatever context happens to be current at flush.
  @ObservationIgnored private let layoutsWriter: LayoutsIncrementalWriter
  /// Per-worktree debounce timers for incremental layout saves.
  @ObservationIgnored private var layoutDirtyTasks: [Worktree.ID: Task<Void, Never>] = [:]
  /// Per-worktree in-flight positive flush Tasks. A delete awaits the live one
  /// for its key so `.delete` always lands on the writer after the `.snapshot`,
  /// preventing a stale positive flush from resurrecting a pruned worktree.
  @ObservationIgnored private var layoutFlushTasks: [Worktree.ID: Task<Void, Never>] = [:]
  /// Sleeps the incremental-save debounce window; injected so tests drive it.
  @ObservationIgnored private let layoutDebounceSleep: @Sendable (Duration) async throws -> Void
  /// Debounce window before an incremental layout snapshot is flushed.
  private static let layoutDebounceDuration: Duration = .seconds(1)
  /// Reads the freshest `agentsBySurface` at flush time so incremental captures
  /// embed live badge records instead of the empty default.
  var currentAgentsBySurface: (() -> [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]])?
  /// Holds `.idle` long enough to collapse PostToolUse/PreToolUse busy/idle alternation
  /// into a sustained busy; stays sub-perceptible for the badge clearing at end-of-session.
  private static let idleHookDebounceDuration: Duration = .milliseconds(400)

  private struct IdleDebounceKey: Hashable {
    let surfaceID: UUID
    let agent: SkillAgent
  }

  /// Identity for a latest-wins event. Two events sharing a key carry the same
  /// piece of state, so an identical repeat is a no-op and is dropped.
  private enum CoalesceKey: Hashable {
    case worktreeProjection(Worktree.ID)
    case tabProjection(TerminalTabID)
    case tabProgress(TerminalTabID)
    case taskStatus(Worktree.ID)
    case focus(Worktree.ID)
    case notificationIndicator
    case hasAnySurface
  }

  /// Non-nil for state events that are safe to coalesce by identity. Lifecycle /
  /// one-shot events (tab create / close / remove, notifications, script
  /// completion, command-palette, teardown) return nil and are never dropped.
  private static func coalesceKey(for event: TerminalClient.Event) -> CoalesceKey? {
    switch event {
    case .worktreeProjectionChanged(let worktreeID, _): .worktreeProjection(worktreeID)
    case .tabProjectionChanged(_, let projection): .tabProjection(projection.tabID)
    case .tabProgressDisplayChanged(_, let tabID, _): .tabProgress(tabID)
    case .taskStatusChanged(let worktreeID, _): .taskStatus(worktreeID)
    case .focusChanged(let worktreeID, _): .focus(worktreeID)
    case .notificationIndicatorChanged: .notificationIndicator
    case .terminalHasAnySurfaceChanged: .hasAnySurface
    default: nil
    }
  }

  /// Compact identity for a backpressure-drop log. Strips the payload-heavy
  /// cases (projections / notification bodies) to their key ids so a drop storm
  /// can't flood the log; the rest carry small payloads and describe themselves.
  private static func label(for event: TerminalClient.Event) -> String {
    switch event {
    case .worktreeProjectionChanged(let worktreeID, _): "worktreeProjectionChanged(\(worktreeID))"
    case .tabProjectionChanged(let worktreeID, let projection):
      "tabProjectionChanged(\(worktreeID), tab: \(projection.tabID))"
    case .tabProgressDisplayChanged(let worktreeID, let tabID, _):
      "tabProgressDisplayChanged(\(worktreeID), tab: \(tabID))"
    case .notificationReceived(let worktreeID, let surfaceID, _, _, _):
      "notificationReceived(\(worktreeID), surface: \(surfaceID))"
    default: String(describing: event)
    }
  }

  var selectedWorktreeID: Worktree.ID?
  /// The resolved background of the focused surface in the selected worktree
  /// (OSC 11 override or theme fallback). Single source for the window tint,
  /// `window.appearance`, and the toolbar title's color scheme.
  private(set) var focusedSurfaceBackground: NSColor
  @ObservationIgnored
  private nonisolated(unsafe) var runtimeObservers: [NSObjectProtocol] = []
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
    eventBufferCap: Int = WorktreeTerminalManager.defaultEventBufferCap,
  ) {
    self.eventBufferCap = eventBufferCap
    self.runtime = runtime
    self.focusedSurfaceBackground = runtime.backgroundColor()
    self.hookEventSleep = { duration in try await clock.sleep(for: duration) }
    self.layoutDebounceSleep = { duration in try await clock.sleep(for: duration) }
    @Dependency(\.settingsFileStorage) var settingsFileStorage
    self.layoutsWriter = LayoutsIncrementalWriter(storage: settingsFileStorage)
    // A theme reload changes the fallback and every non-OSC surface background.
    runtimeObservers.append(
      NotificationCenter.default.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: runtime,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshFocusedSurfaceBackground() }
      }
    )
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
    for task in layoutDirtyTasks.values { task.cancel() }
    for task in layoutFlushTasks.values { task.cancel() }
    for observer in runtimeObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func configureSocketServer(_ server: AgentHookSocketServer) {
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

  /// Holds `.idle` for a debounce window so PostToolUse / PreToolUse storms don't flap downstream UI.
  /// Applies the idle debounce before the OSC-sourced event lands in TCA.
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

  #if DEBUG
    /// Count of idle-hook debounce tasks still scheduled (test-only). A clock-awoken
    /// resume removes its key only after it emits, so a non-zero count means a
    /// pending idle event has not yet landed in the stream.
    var pendingIdleHookCountForTesting: Int { pendingIdleHookEvents.count }
  #endif

  // MARK: - CLI queries.

  func listTabs(worktreeID: String) -> [[String: String]]? {
    let decoded = worktreeID.removingPercentEncoding ?? worktreeID
    guard let state = states[WorktreeID(decoded)] else { return nil }
    let selectedTabID = state.tabManager.selectedTabId
    return state.tabManager.tabs.map { tab in
      var entry = ["id": tab.id.rawValue.uuidString]
      if tab.id == selectedTabID { entry["focused"] = "1" }
      return entry
    }
  }

  func listSurfaces(worktreeID: String, tabID: String) -> [[String: String]]? {
    let decoded = worktreeID.removingPercentEncoding ?? worktreeID
    guard let state = states[WorktreeID(decoded)],
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
    case .createTab(let worktree, let runSetupScriptIfNew, let id, let title):
      Task {
        createTabAsync(
          in: worktree,
          runSetupScriptIfNew: runSetupScriptIfNew,
          tabID: id,
          customTitle: title
        )
      }
    case .createTabWithInput(let worktree, let input, let runSetupScriptIfNew, let id, let title):
      Task {
        createTabAsync(
          in: worktree,
          runSetupScriptIfNew: runSetupScriptIfNew,
          initialInput: input,
          tabID: id,
          customTitle: title
        )
      }
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      let state = state(for: worktree) { runSetupScriptIfNew }
      state.ensureInitialTab(focusing: focusing)
    case .stopRunScript(let worktree):
      stopBlockingScripts(in: worktree) { $0.stopRunScripts() }
    case .stopScript(let worktree, let definitionID):
      stopBlockingScripts(in: worktree) { $0.stopScript(definitionID: definitionID) }
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
    case .renameTab(let worktree, let tabID, let title):
      let applied = stateIfExists(for: worktree.id)?.renameTab(tabID, title: title) ?? false
      emit(.tabRenamed(worktreeID: worktree.id, tabID: tabID, applied: applied))
    case .selectTab(let worktree, let tabID):
      state(for: worktree).selectTab(tabID)
    case .selectTabAtIndex(let worktree, let index):
      stateIfExists(for: worktree.id)?.selectTabAtIndex(index)
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
        if let id {
          emit(
            .surfaceCreationFailed(
              worktreeID: worktree.id, attemptedID: id,
              message: "Could not create the split surface."))
        }
        break
      }
    case .destroyTab(let worktree, let tabID):
      let terminal = state(for: worktree)
      guard terminal.tabManager.tabs.contains(where: { $0.id == tabID }) else {
        terminalLogger.warning("destroyTab: tab \(tabID.rawValue) not found in worktree \(worktree.id).")
        // Already gone, so the close goal is met: resolve the ack instead of timing out.
        emit(.tabRemoved(worktreeID: worktree.id, tabID: tabID))
        break
      }
      terminal.closeTab(tabID)
    case .destroySurface(let worktree, let tabID, let surfaceID):
      let terminal = state(for: worktree)
      terminal.selectTab(tabID)
      if !terminal.closeSurface(id: surfaceID) {
        terminalLogger.warning("destroySurface: surface \(surfaceID) not found in worktree \(worktree.id).")
        // Don't synthesize a `surfacesClosed` here: it drives global presence
        // cleanup keyed by surface id, which would drop a duplicate id live in
        // another worktree. The rare validated-then-vanished race falls to the
        // ack watchdog instead.
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
      .performBindingActionOnSurface, .selectTab, .selectTabAtIndex, .focusSurface, .splitSurface,
      .destroyTab, .destroySurface, .renameTab, .setImagePasteAgents, .prune, .setNotificationsEnabled,
      .enforceNotificationRetentionLimit, .setSelectedWorktreeID, .refreshTabBarVisibility, .beginTabRename:
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
    case .setImagePasteAgents(let surfaceID, let agents):
      setImagePasteAgents(agents, onSurfaceID: surfaceID)
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .startSearch, .searchSelection,
      .navigateSearchNext, .navigateSearchPrevious, .endSearch, .selectTab, .selectTabAtIndex,
      .focusSurface, .splitSurface, .destroyTab, .destroySurface, .renameTab, .prune, .setNotificationsEnabled,
      .enforceNotificationRetentionLimit, .setSelectedWorktreeID, .refreshTabBarVisibility, .beginTabRename:
      return false
    }
    return true
  }

  private func setImagePasteAgents(_ agents: Set<SkillAgent>, onSurfaceID surfaceID: UUID) {
    for state in states.values where state.setImagePasteAgents(agents, onSurfaceID: surfaceID) {
      return
    }
  }

  private func handleManagementCommand(_ command: TerminalClient.Command) {
    switch command {
    case .prune(let ids, let protectedRepositoryIDs):
      prune(keeping: ids, protectingRepositoryIDs: protectedRepositoryIDs)
    case .setNotificationsEnabled(let enabled):
      setNotificationsEnabled(enabled)
    case .enforceNotificationRetentionLimit:
      enforceNotificationRetentionLimit()
    case .refreshTabBarVisibility:
      for state in states.values {
        state.refreshTabBarVisibility()
      }
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      if let previousID = selectedWorktreeID, let previousState = states[previousID] {
        previousState.rememberFocusedZoom()
        previousState.setAllSurfacesOccluded()
        previousState.forgetLastEmittedFocus()
        lastEmittedCoalescable.removeValue(forKey: .focus(previousID))
        markLayoutDirty(worktreeID: previousID)
      }
      selectedWorktreeID = id
      // A sidebar click never hands AppKit focus to the terminal, so no focus
      // event fires; refresh here or the window keeps the previous tint.
      refreshFocusedSurfaceBackground()
      terminalLogger.info("Selected worktree \(id?.rawValue ?? "nil")")
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .performBindingAction,
      .performBindingActionOnSurface, .setImagePasteAgents, .startSearch, .searchSelection, .navigateSearchNext,
      .navigateSearchPrevious, .endSearch, .selectTab, .selectTabAtIndex, .focusSurface,
      .splitSurface, .destroyTab, .destroySurface, .renameTab, .beginTabRename:
      assertionFailure("Unhandled terminal command reached management handler: \(command)")
    }
  }

  func eventStream() -> AsyncStream<TerminalClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(
      of: TerminalClient.Event.self,
      bufferingPolicy: .bufferingNewest(eventBufferCap)
    )
    eventContinuation = continuation
    lastNotificationIndicatorCount = nil
    // Reset dedup state before replaying so the replay re-seeds both caches; a
    // fresh subscriber then has the latest value recorded for every key.
    lastEmittedProjections.removeAll()
    lastEmittedCoalescable.removeAll()
    pendingShedProjectionReplays.removeAll()
    if !pendingEvents.isEmpty {
      let bufferedEvents = pendingEvents
      pendingEvents.removeAll()
      for event in bufferedEvents {
        // Re-emitted fresh below, so drop the buffered copy.
        if case .notificationIndicatorChanged = event {
          continue
        }
        // Route through emit() (not a raw yield) so a coalescable buffered event
        // seeds lastEmittedCoalescable and the first identical live event dedups.
        emit(event)
      }
    }
    emitNotificationIndicatorCountIfNeeded()
    // Seed hasAny so a new subscriber starts at the correct value.
    lastEmittedHasAnyTerminalSurface = false
    emitHasAnyTerminalSurfaceIfNeeded()
    // Seed each worktree's projection so rows attached after the stream start
    // pick up the current snapshot (otherwise they'd stay default until the
    // next mutation).
    for id in states.keys { emitProjection(for: id) }
    // Replay per-tab projections / stripe-progress displays for the same reason:
    // a new subscriber needs the existing `terminalTabs[id:]` rows seeded so
    // tab-bar leaves don't render empty until the next per-tab mutation.
    for (worktreeID, state) in states {
      for projection in state.currentTabProjections() {
        emit(.tabProjectionChanged(worktreeID: worktreeID, projection))
      }
      for (tabID, display) in state.currentTabProgressDisplays() {
        emit(.tabProgressDisplayChanged(worktreeID: worktreeID, tabID: tabID, display: display))
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
      // If `hasAttemptedInitialTab` is sticky-true (closeAllTabs path), the snapshot
      // stays staged but ensureInitialTab won't consume it; that's intentional.
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
      self?.emit(.surfacesClosed(worktreeID: worktree.id, ids))
      // The last surface closing leaves no focus target, so no focus event
      // follows; fall back to the theme background here.
      self?.refreshFocusedSurfaceBackground()
    }
    // OSC-sourced presence events go through the existing idle-debounce funnel.
    state.onAgentHookEvent = { [weak self] event in
      self?.dispatchHookEvent(event)
    }
    state.onNotificationReceived = { [weak self] surfaceID, title, body, isViewed in
      self?.emit(
        .notificationReceived(
          worktreeID: worktree.id,
          surfaceID: surfaceID,
          title: title,
          body: body,
          isViewed: isViewed
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
      self?.markLayoutDirty(worktreeID: worktree.id)
    }
    state.onTabClosed = { [weak self] in
      self?.emit(.tabClosed(worktreeID: worktree.id))
      self?.emitProjection(for: worktree.id)
      self?.markLayoutDirty(worktreeID: worktree.id)
    }
    state.onTabRenamed = { [weak self] in
      self?.markLayoutDirty(worktreeID: worktree.id)
    }
    state.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
      self?.refreshFocusedSurfaceBackground()
    }
    state.onFocusedSurfaceColorChanged = { [weak self] in
      self?.refreshFocusedSurfaceBackground()
    }
    state.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
      self?.emitProjection(for: worktree.id)
    }
    state.onBlockingScriptCompleted = { [weak self] kind, exitCode, tabId in
      self?.emit(.blockingScriptCompleted(worktreeID: worktree.id, kind: kind, exitCode: exitCode, tabId: tabId))
    }
    state.onRunningScriptsChanged = { [weak self] in
      // Force past the projection dedupe: an archived-strip can clear the row while
      // the cache still holds running, so a plain emit would dedupe and strand it (#573).
      self?.forceEmitProjection(for: worktree.id)
    }
    state.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    state.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    state.onTabProjectionChanged = { [weak self] projection in
      self?.emit(.tabProjectionChanged(worktreeID: worktree.id, projection))
      self?.markLayoutDirty(worktreeID: worktree.id)
    }
    state.onTabRemoved = { [weak self] tabID in
      self?.emit(.tabRemoved(worktreeID: worktree.id, tabID: tabID))
      self?.markLayoutDirty(worktreeID: worktree.id)
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
    tabID: UUID? = nil,
    customTitle: String? = nil
  ) {
    let state = state(for: worktree) { runSetupScriptIfNew }
    let setupScript: String?
    if state.needsSetupScript() {
      @SharedReader(.repositorySettings(worktree.repositoryRootURL, host: worktree.host))
      var settings = RepositorySettings.default
      setupScript = settings.setupScript
    } else {
      setupScript = nil
    }
    let created = state.createTab(
      setupScript: setupScript,
      initialInput: initialInput,
      tabID: tabID,
      customTitle: customTitle
    )
    guard created == nil, let tabID else { return }
    // Drain a waiting CLI ack now instead of stranding it until the timeout.
    emit(
      .surfaceCreationFailed(
        worktreeID: worktree.id, attemptedID: tabID, message: "Could not create the tab."))
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

  func prune(
    keeping worktreeIDs: Set<Worktree.ID>,
    protectingRepositoryIDs protectedRepositoryIDs: Set<Repository.ID> = []
  ) {
    let shouldKeep: (Worktree.ID, WorktreeTerminalState) -> Bool = { id, state in
      worktreeIDs.contains(id) || protectedRepositoryIDs.contains(state.repositoryID)
    }
    var removed: [(Worktree.ID, WorktreeTerminalState)] = []
    for (id, state) in states where !shouldKeep(id, state) {
      removed.append((id, state))
    }
    let prunedSurfaceIDs = Set(removed.flatMap { _, state in state.allSurfaceIDs })
    let prunedSessionIDs = removed.flatMap { _, state in
      state.allSurfaceIDs.map { ZmxSessionID.make(surfaceID: $0) }
    }
    let prunedRemoteSessions = Self.remoteSessions(in: removed.map(\.1))
    for (id, state) in removed {
      // Clear instead of resaving: archived / deleted worktrees should leave
      // no trace in `layouts.json`. The explicit delete bypasses the debounce
      // and cancels any queued positive save so a pruned worktree can't be
      // resurrected by an in-flight snapshot.
      deleteLayoutSnapshot(worktreeID: id)
      state.closeAllSurfaces()
      // Signals the reducer to drop any orphan `terminalTabs` entries and
      // recently-removed-tab records for this worktree so a same-session
      // restore (snapshot reuses persisted tab UUIDs) starts clean.
      emit(.worktreeStateTornDown(worktreeID: id))
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal state(s)")
    }
    states = states.filter { shouldKeep($0.key, $0.value) }
    cancelPendingIdleHooks(forSurfaceIDs: prunedSurfaceIDs)
    for (id, _) in removed { invalidateCaches(forPrunedWorktree: id) }
    emitNotificationIndicatorCountIfNeeded()
    emitHasAnyTerminalSurfaceIfNeeded()
    refreshFocusedSurfaceBackground()
    killZmxSessions(prunedSessionIDs, remoteSessions: prunedRemoteSessions)
  }

  /// Host-side zmx sessions owned by the given states, one entry per surface
  /// of each remote worktree. Unconditional on the persistence toggle: a host
  /// session may exist from an earlier launch, and the kill invocation is a
  /// silent no-op when nothing exists.
  private static func remoteSessions(
    in states: [WorktreeTerminalState]
  ) -> [(host: RemoteHost, sessionID: String)] {
    states.flatMap { state -> [(host: RemoteHost, sessionID: String)] in
      guard let host = state.remoteHost else { return [] }
      return state.allSurfaceIDs.map { (host, ZmxSessionID.make(surfaceID: $0)) }
    }
  }

  /// Schedules a debounced incremental layout save for `worktreeID`. Coalesces
  /// a burst of mutations into one write; the snapshot is captured at fire time
  /// (freshest tree + agent records), mutated into the in-memory `@Shared` dict
  /// on main, then merged into `layouts.json` off main.
  func markLayoutDirty(worktreeID: Worktree.ID) {
    layoutDirtyTasks[worktreeID]?.cancel()
    layoutDirtyTasks[worktreeID] = Task { [weak self, layoutDebounceSleep] in
      try? await layoutDebounceSleep(Self.layoutDebounceDuration)
      guard !Task.isCancelled else { return }
      self?.flushLayoutSnapshot(worktreeID: worktreeID)
    }
  }

  /// Fires after the debounce window: captures the freshest snapshot for
  /// `worktreeID`, updates the in-memory `@Shared` dict on main, then queues the
  /// off-main per-key merge. Its only caller is `markLayoutDirty`.
  private func flushLayoutSnapshot(worktreeID: Worktree.ID) {
    layoutDirtyTasks[worktreeID] = nil
    guard let state = states[worktreeID] else { return }
    let agents = currentAgentsBySurface?() ?? [:]
    // A nil snapshot (no remaining tabs) clears the key rather than persisting
    // an empty layout, matching the on-disk "no trace" semantics for emptiness.
    let snapshot = state.captureLayoutSnapshot(agentsBySurface: agents)
    saveLayoutSnapshot?(worktreeID, snapshot)
    let change: LayoutsIncrementalWriter.Change = snapshot.map { .snapshot($0) } ?? .delete
    let writer = layoutsWriter
    let task = Task { [weak self] in
      await writer.flush([worktreeID.rawValue: change])
      self?.layoutFlushTasks[worktreeID] = nil
    }
    layoutFlushTasks[worktreeID] = task
  }

  /// Removes `worktreeID` from disk immediately, bypassing the debounce and
  /// cancelling any queued positive save so a stale snapshot can't resurrect a
  /// removed worktree. Awaits any in-flight positive flush for the key first so
  /// the `.delete` always reaches the writer after the `.snapshot`.
  private func deleteLayoutSnapshot(worktreeID: Worktree.ID) {
    layoutDirtyTasks[worktreeID]?.cancel()
    layoutDirtyTasks[worktreeID] = nil
    saveLayoutSnapshot?(worktreeID, nil)
    let inflightFlush = layoutFlushTasks[worktreeID]
    let writer = layoutsWriter
    // We await inflightFlush so the .delete lands after any in-flight positive
    // flush; prune also drops the id from states synchronously before any later
    // saveAllLayoutSnapshots, so no positive snapshot is re-emitted.
    let task = Task { [weak self] in
      await inflightFlush?.value
      await writer.flush([worktreeID.rawValue: .delete])
      self?.layoutFlushTasks[worktreeID] = nil
    }
    layoutFlushTasks[worktreeID] = task
  }

  /// Cancels every queued incremental save. Called before the on-quit
  /// synchronous flush becomes the terminal write.
  func cancelPendingLayoutSaves() {
    for task in layoutDirtyTasks.values { task.cancel() }
    layoutDirtyTasks.removeAll()
    // Best-effort cancel: an already-started flush has no cancellation
    // checkpoint in `applyAndWrite`, so it runs to completion. The writer's lock
    // plus the atomic temp+rename keep the on-quit write from tearing; the worst
    // case is a stale-but-valid key set on the next launch, never a corrupt file.
    for task in layoutFlushTasks.values { task.cancel() }
    layoutFlushTasks.removeAll()
  }

  /// Tears down persistent zmx sessions for worktrees that just left the keep
  /// set. Parallel across surfaces; within one surface the remote kill precedes
  /// the local one (see `ZmxClient.killSurfaceSessions`), so the bound is one
  /// remote (15s) plus one local (5s) timeout regardless of N. Detached and
  /// unbudgeted; a quit inside that window leaves local survivors to the
  /// next-launch orphan reap (a host-side survivor has no reaper).
  private func killZmxSessions(
    _ sessionIDs: [String],
    remoteSessions: [(host: RemoteHost, sessionID: String)] = []
  ) {
    guard !sessionIDs.isEmpty || !remoteSessions.isEmpty else { return }
    let client = zmxClient
    analyticsClient.capture(
      "terminal_persistence_session_killed",
      ["reason": "worktree_pruned", "count": sessionIDs.count, "remote_count": remoteSessions.count]
    )
    let plan = Self.killPlan(localSessionIDs: sessionIDs, remoteSessions: remoteSessions)
    Task.detached {
      await withTaskGroup(of: Void.self) { group in
        for entry in plan {
          group.addTask {
            await client.killSurfaceSessions(
              sessionID: entry.sessionID, remoteHost: entry.host, killLocal: entry.killLocal)
          }
        }
      }
    }
  }

  /// One surface's session teardown: the host-side session (when remote) and the
  /// local session, run remote-first via `ZmxClient.killSurfaceSessions`.
  struct SurfaceSessionKill: Sendable {
    let sessionID: String
    let host: RemoteHost?
    let killLocal: Bool
  }

  /// Merges the local and remote kill lists into one entry per session so each
  /// surface's remote+local teardown runs in the safe order (see
  /// `ZmxClient.killSurfaceSessions`). A session present in only one list keeps
  /// that side; a session in both is torn down remote-first then local.
  static func killPlan(
    localSessionIDs: [String],
    remoteSessions: [(host: RemoteHost, sessionID: String)]
  ) -> [SurfaceSessionKill] {
    let localSet = Set(localSessionIDs)
    let remoteByID = Dictionary(remoteSessions.map { ($0.sessionID, $0.host) }) { first, second in
      // One host per session ID by construction; a collision leaks the dropped
      // host's session, so make it visible.
      terminalLogger.warning(
        "killPlan: one session on two hosts; keeping \(first.alias), dropping \(second.alias)")
      return first
    }
    let orderedIDs = localSessionIDs + remoteSessions.map(\.sessionID).filter { !localSet.contains($0) }
    var seen: Set<String> = []
    return orderedIDs.compactMap { id in
      guard seen.insert(id).inserted else { return nil }
      return SurfaceSessionKill(sessionID: id, host: remoteByID[id], killLocal: localSet.contains(id))
    }
  }

  func tabExists(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.hasTab(tabID) ?? false
  }

  func tabCanRename(worktreeID: Worktree.ID, tabID: TerminalTabID) -> Bool {
    states[worktreeID]?.tabManager.canRename(tabID) ?? false
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

  var hasInflightBlockingScripts: Bool {
    states.values.contains(where: \.hasInflightBlockingScripts)
  }

  /// Tear down every tracked surface AND reap any orphans the daemon still
  /// hosts. zmx is a long-lived per-user daemon that outlives our app quit,
  /// so "Quit and Terminate" must explicitly sweep orphan sessions or they
  /// would survive forever.
  func terminateAllSessions(killBudget: Duration = WorktreeTerminalManager.quitKillBudget) async {
    let trackedSurfaceIDs = states.values.flatMap(\.allSurfaceIDs)
    let trackedSessionIDs = Set(trackedSurfaceIDs.map(ZmxSessionID.make(surfaceID:)))
    // "Quit and Terminate" promises nothing keeps running, so the host-side
    // sessions of remote worktrees are swept too (best-effort over SSH).
    let trackedRemoteSessions = Self.remoteSessions(in: Array(states.values))
    for state in states.values {
      state.closeAllSurfaces()
    }
    emitHasAnyTerminalSurfaceIfNeeded()
    // This instance's tracked local sessions are killed. A remote surface's
    // local kill is gated behind its budgeted remote kill (see
    // `ZmxClient.killSurfaceSessions`); when the budget expires first, the
    // post-budget fallback retries it uncancelled. A kill that fails without
    // cancellation (stuck daemon) is not retried; either way what remains
    // locally is left to the next-launch orphan reap. The orphan subset (live and
    // untracked) is attach-aware: spared when a client is attached or the count
    // is unknown, so a concurrently-running instance keeps its sessions. Orphan
    // reaping is therefore eventually consistent: the last instance to quit
    // with no live clients sweeps what remains.
    let liveSessions = await zmxClient.listSessionsWithClients()
    let orphanSessions: [String]
    if let liveSessions {
      orphanSessions = liveSessions.filter { entry in
        !trackedSessionIDs.contains(entry.name) && entry.clients == 0
      }
      .map(\.name)
    } else {
      // nil = UNKNOWN probe; still force-kill tracked, but skip the orphan sweep.
      terminalLogger.info("Skipping quit-time orphan sweep: zmx session probe unavailable")
      orphanSessions = []
    }
    let allSessions = Array(trackedSessionIDs.union(orphanSessions))
    guard !allSessions.isEmpty || !trackedRemoteSessions.isEmpty else { return }
    analyticsClient.capture(
      "terminal_persistence_session_killed",
      [
        "reason": "user_quit",
        "count": allSessions.count,
        "orphan_count": orphanSessions.count,
        "remote_count": trackedRemoteSessions.count,
      ]
    )
    let client = zmxClient
    if !trackedRemoteSessions.isEmpty {
      terminalLogger.info(
        "Quit: tearing down \(trackedRemoteSessions.count) host-side zmx session(s), bounded by \(killBudget)"
      )
    }
    // Raced against a budget so an unreachable host cannot hold the quit path
    // for the full remote ssh timeout; stragglers are cancelled (best-effort).
    let plan = Self.killPlan(localSessionIDs: allSessions, remoteSessions: trackedRemoteSessions)
    let attemptedLocalKills = LockIsolated<Set<String>>([])
    await Self.raceKillBudget(killBudget) {
      await withTaskGroup(of: Void.self) { kills in
        for entry in plan {
          kills.addTask {
            await client.killSurfaceSessions(
              sessionID: entry.sessionID, remoteHost: entry.host, killLocal: entry.killLocal)
            guard entry.killLocal, !Task.isCancelled else { return }
            attemptedLocalKills.withValue { _ = $0.insert(entry.sessionID) }
          }
        }
      }
    }
    await killSurvivingLocalSessions(plan: plan, attempted: attemptedLocalKills.value)
  }

  /// Post-budget fallback: a local session whose gated kill lost the quit
  /// budget would otherwise keep its ssh reconnect loop hammering the host
  /// until the next-launch orphan reap. Ordering is moot by now (the paired
  /// remote kill already ran or was cancelled), so kill the survivors directly,
  /// bounded so a stuck daemon cannot re-hang quit.
  private func killSurvivingLocalSessions(
    plan: [SurfaceSessionKill],
    attempted: Set<String>
  ) async {
    let survivors = plan.filter { $0.killLocal && !attempted.contains($0.sessionID) }.map(\.sessionID)
    guard !survivors.isEmpty else { return }
    terminalLogger.warning(
      "Quit kill budget expired; retrying local kill for: \(survivors.joined(separator: ", "))")
    let client = zmxClient
    await Self.raceKillBudget(Self.quitLocalFallbackBudget) {
      await withTaskGroup(of: Void.self) { kills in
        for id in survivors {
          kills.addTask { await client.killSession(id) }
        }
      }
    }
  }

  /// Runs `work` racing a `budget` timeout; whichever finishes first cancels
  /// the other, so a stuck kill cannot outlast the budget.
  private static func raceKillBudget(
    _ budget: Duration, _ work: @escaping @Sendable () async -> Void
  ) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await work() }
      group.addTask { try? await Task.sleep(for: budget) }
      defer { group.cancelAll() }
      await group.next()
    }
  }

  /// Cap on the quit-time kill sweep: comfortably above the local zmx cap (5s)
  /// so a local-only teardown is never truncated, well under the remote ssh cap
  /// (15s) so an unreachable host cannot make quit feel hung. A remote surface's
  /// local kill is gated behind its remote kill; when the budget cuts it off,
  /// `killSurvivingLocalSessions` retries it on its own short budget.
  static let quitKillBudget: Duration = .seconds(6)

  /// Bound on the post-budget local retry: local kills land in well under the
  /// local zmx cap (5s); 2s keeps worst-case quit around 8s, still under the
  /// remote ssh cap (15s).
  static let quitLocalFallbackBudget: Duration = .seconds(2)

  /// Reaps `supa-*` sessions zmx hosts that no persisted layout claims;
  /// catches orphans from crashes / force-quits. Attach-aware: a session with
  /// a live client (another Supacode instance or a manual `zmx attach`) is
  /// spared, and a failed probe reaps nothing.
  func reapOrphanSessions(knownSurfaceIDs: Set<UUID>) async {
    guard let liveSessions = await zmxClient.listSessionsWithClients() else {
      // nil = UNKNOWN (probe failed / timed out); never reap on no signal.
      terminalLogger.info("Skipping orphan reap: zmx session probe unavailable")
      return
    }
    let knownSessionIDs = Set(knownSurfaceIDs.map(ZmxSessionID.make(surfaceID:)))
    // Only reap orphans we positively know have zero attached clients; spare
    // clients>0 (in use) and clients==nil (unknown count).
    let orphans = liveSessions.filter { entry in
      !knownSessionIDs.contains(entry.name) && entry.clients == 0
    }
    .map(\.name)
    guard !orphans.isEmpty else { return }
    terminalLogger.info("Reaping \(orphans.count) orphan zmx session(s)")
    analyticsClient.capture(
      "terminal_persistence_session_killed",
      ["reason": "orphan_reaped", "count": orphans.count]
    )
    let client = zmxClient
    await withTaskGroup(of: Void.self) { group in
      for id in orphans {
        group.addTask { await client.killSession(id) }
      }
    }
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    for state in states.values {
      state.setNotificationsEnabled(enabled)
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  /// Re-applies the retention limit to every worktree, e.g. after the user lowers
  /// it in settings so an existing backlog is trimmed without waiting for the next
  /// notification.
  func enforceNotificationRetentionLimit() {
    for state in states.values {
      state.enforceNotificationRetentionLimit()
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

  /// Indicator and projection updates propagate via each state's notification
  /// callbacks. Every state is swept, not just the unread ones, so a surface
  /// whose unseen mirror drifted out of sync with its notifications is repaired.
  func markAllNotificationsRead() {
    let unread = states.values.count(where: \.hasUnseenNotification)
    terminalLogger.info("markAllNotificationsRead: clearing unread in \(unread) worktree(s).")
    for state in states.values {
      state.markAllNotificationsRead()
    }
  }

  /// Embed `agentsBySurface` in each surface so badges survive relaunch.
  func saveAllLayoutSnapshots(
    agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]] = [:]
  ) {
    guard let saveLayoutSnapshot else {
      assertionFailure("saveLayoutSnapshot closure not configured.")
      return
    }
    // The actor is the sole disk writer (`LayoutsKey.save` is a no-op), so the
    // on-quit terminal write goes through `flushSync` while still updating the
    // in-memory `@Shared` dict via `saveLayoutSnapshot` for any live readers.
    var changes: [String: LayoutsIncrementalWriter.Change] = [:]
    for (id, state) in states {
      let snapshot = state.captureLayoutSnapshot(agentsBySurface: agentsBySurface)
      saveLayoutSnapshot(id, snapshot)
      changes[id.rawValue] = snapshot.map { .snapshot($0) } ?? .delete
    }
    layoutsWriter.flushSync(changes)
  }

  /// Capture the selected worktree's zoom at quit (no switch fires then).
  func rememberSelectedWorktreeZoomOnQuit() {
    guard let selectedWorktreeID, let state = states[selectedWorktreeID] else { return }
    state.rememberFocusedZoom()
  }

  private func resolveFocusedSurfaceBackground() -> NSColor {
    guard let selectedWorktreeID,
      let state = states[selectedWorktreeID],
      let surfaceState = state.focusedSurfaceState()
    else { return runtime.backgroundColor() }
    return Self.osc11BackgroundColor(
      kind: surfaceState.colorChangeKind,
      red: surfaceState.colorChangeR,
      green: surfaceState.colorChangeG,
      blue: surfaceState.colorChangeB
    ) ?? runtime.backgroundColor()
  }

  // OSC 11 sets the background; OSC 10/12 (foreground/cursor) and palette kinds
  // do not affect the window tint, so only the background kind resolves a color.
  static func osc11BackgroundColor(
    kind: ghostty_action_color_kind_e?,
    red: UInt8?,
    green: UInt8?,
    blue: UInt8?
  ) -> NSColor? {
    guard kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND,
      let red, let green, let blue
    else { return nil }
    return NSColor(
      srgbRed: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: 1
    )
  }

  // The single funnel for focused-background changes: dedupes on the resolved
  // color so identical focus moves post nothing, then updates the stored source
  // and notifies the AppKit consumers (window appearance, tint backdrop).
  func refreshFocusedSurfaceBackground() {
    let color = resolveFocusedSurfaceBackground()
    guard !color.matchesTint(focusedSurfaceBackground) else { return }
    focusedSurfaceBackground = color
    NotificationCenter.default.post(name: .ghosttyFocusedSurfaceBackgroundDidChange, object: self)
  }

  // Chrome tint derived off the terminal background instead of the system accent:
  // whiteish on a dark terminal, blackish on light.
  func chromeOverlayTint() -> Color {
    focusedSurfaceBackground.isLightColor ? .black : .white
  }

  // The focused terminal background's luminance as a scheme (dark terminal → .dark).
  func surfaceBackgroundColorScheme() -> ColorScheme {
    focusedSurfaceBackground.isLightColor ? .light : .dark
  }

  var ghosttyRuntime: GhosttyRuntime { runtime }

  func unfocusedSplitOverlay() -> (fill: Color?, opacity: Double) {
    (runtime.unfocusedSplitFill(), runtime.unfocusedSplitOverlayOpacity())
  }

  private func emit(_ event: TerminalClient.Event) {
    guard let eventContinuation else {
      bufferPendingEvent(event)
      return
    }
    if let key = Self.coalesceKey(for: event) {
      guard lastEmittedCoalescable[key] != event else { return }
      lastEmittedCoalescable[key] = event
    }
    // During prune this fires first and clears the coalesce keys; invalidateCaches
    // then runs second only to clear the worktree-keyed lastEmittedProjections.
    for key in Self.invalidatedCoalesceKeys(by: event) {
      lastEmittedCoalescable.removeValue(forKey: key)
    }
    let result = eventContinuation.yield(event)
    if case .dropped(let shed) = result {
      terminalLogger.error(
        "Terminal event buffer full (cap \(eventBufferCap)); shed oldest buffered event: \(Self.label(for: shed))."
      )
      invalidateDedupe(for: shed)
      scheduleShedProjectionReplay(for: shed)
    }
  }

  /// Redeliver a shed projection next tick; shedding cleared its dedupe entry
  /// without reaching TCA, so the row would otherwise stay stale (#573).
  private func scheduleShedProjectionReplay(for shed: TerminalClient.Event) {
    guard case .worktreeProjectionChanged(let worktreeID, _) = shed else { return }
    // A replay that itself sheds must not chain another, or a persistently full
    // buffer would loop and evict live events every tick (#573).
    guard !isDrainingShedProjectionReplays else { return }
    let wasIdle = pendingShedProjectionReplays.isEmpty
    pendingShedProjectionReplays.insert(worktreeID)
    guard wasIdle else { return }
    Task { @MainActor [weak self] in self?.drainShedProjectionReplays() }
  }

  private func drainShedProjectionReplays() {
    let ids = pendingShedProjectionReplays
    pendingShedProjectionReplays.removeAll()
    isDrainingShedProjectionReplays = true
    defer { isDrainingShedProjectionReplays = false }
    for id in ids {
      emitProjection(for: id)
    }
  }

  /// A shed event never reached the consumer, so its dedupe entries must not
  /// suppress the next identical emit (#573).
  private func invalidateDedupe(for shed: TerminalClient.Event) {
    guard let key = Self.coalesceKey(for: shed) else { return }
    lastEmittedCoalescable.removeValue(forKey: key)
    switch shed {
    case .worktreeProjectionChanged(let worktreeID, _):
      lastEmittedProjections.removeValue(forKey: worktreeID)
    case .notificationIndicatorChanged:
      lastNotificationIndicatorCount = nil
    case .terminalHasAnySurfaceChanged(let hasAny):
      // Invert instead of nil: the gate defaults nil to false, which would
      // mask a shed `false` and strand a consumer at `true`.
      lastEmittedHasAnyTerminalSurface = !hasAny
    default:
      break
    }
  }

  /// Buffers an event emitted before a subscriber attaches. Coalescable state
  /// keeps only its latest value per key; lifecycle events accumulate up to a
  /// cap, dropping the oldest so the pre-subscription buffer stays bounded.
  private func bufferPendingEvent(_ event: TerminalClient.Event) {
    if let key = Self.coalesceKey(for: event) {
      pendingEvents.removeAll { Self.coalesceKey(for: $0) == key }
      pendingEvents.append(event)
      return
    }
    // Mirror the live-path teardown purge so a buffered projection for a
    // torn-down id can't replay ahead of its teardown on resubscribe.
    let invalidated = Set(Self.invalidatedCoalesceKeys(by: event))
    if !invalidated.isEmpty {
      pendingEvents.removeAll { Self.coalesceKey(for: $0).map(invalidated.contains) ?? false }
    }
    if pendingEvents.count >= Self.pendingEventCap {
      let dropped = pendingEvents.removeFirst()
      terminalLogger.error(
        "Pending terminal event buffer full (cap \(Self.pendingEventCap)); dropped oldest: \(Self.label(for: dropped))."
      )
    }
    pendingEvents.append(event)
  }

  /// Coalesce keys a teardown event invalidates. A coalesced value for a removed
  /// tab / worktree must not linger: a same-id reuse (snapshot restore reuses
  /// persisted tab UUIDs) would otherwise be wrongly deduped and dropped.
  private static func invalidatedCoalesceKeys(by event: TerminalClient.Event) -> [CoalesceKey] {
    switch event {
    case .tabRemoved(_, let tabID): [.tabProjection(tabID), .tabProgress(tabID)]
    case .worktreeStateTornDown(let worktreeID):
      [.worktreeProjection(worktreeID), .taskStatus(worktreeID), .focus(worktreeID)]
    default: []
    }
  }

  /// Clears the worktree-keyed lastEmittedProjections during prune; emit's purge has
  /// already cleared the coalesce keys, which this re-clears as a guard against drift.
  private func invalidateCaches(forPrunedWorktree id: Worktree.ID) {
    lastEmittedProjections.removeValue(forKey: id)
    pendingShedProjectionReplays.remove(id)
    for key in Self.invalidatedCoalesceKeys(by: .worktreeStateTornDown(worktreeID: id)) {
      lastEmittedCoalescable.removeValue(forKey: key)
    }
  }

  private func emitNotificationIndicatorCountIfNeeded() {
    let count = states.values.reduce(0) { $0 + $1.totalUnseenNotificationCount }
    if count != lastNotificationIndicatorCount {
      lastNotificationIndicatorCount = count
      emit(.notificationIndicatorChanged(count: count))
    }
  }

  /// Emits only on flip; nil previous treated as false to match the reducer's
  /// default and avoid a stream-start `hasAny: false` echo. Uses
  /// `hasAnySurface` (O(1) on `surfaces.isEmpty`) so the per-projection check
  /// doesn't walk every split tree.
  private func emitHasAnyTerminalSurfaceIfNeeded() {
    let hasAny = states.values.contains(where: \.hasAnySurface)
    let previous = lastEmittedHasAnyTerminalSurface ?? false
    guard hasAny != previous else { return }
    lastEmittedHasAnyTerminalSurface = hasAny
    emit(.terminalHasAnySurfaceChanged(hasAny: hasAny))
  }

  /// Runs `stop` on the worktree's existing terminal state, never minting one.
  /// A miss with a live state means the caller acted on a stale mirror, so force
  /// a fresh projection emit past the dedupe cache to reconcile it (#573).
  private func stopBlockingScripts(in worktree: Worktree, using stop: (WorktreeTerminalState) -> Bool) {
    guard let state = stateIfExists(for: worktree.id) else {
      terminalLogger.warning("Stop requested for \(worktree.id) with no terminal state")
      return
    }
    guard !stop(state) else { return }
    terminalLogger.warning("Stop requested for \(worktree.id) with no matching script; re-emitting projection")
    forceEmitProjection(for: worktree.id)
  }

  /// Re-delivers a worktree's projection past both dedupe layers, so a row that
  /// diverged from the cache (a reducer-side archived-strip) is reconciled even
  /// when the projection value is unchanged (#573).
  private func forceEmitProjection(for id: Worktree.ID) {
    lastEmittedProjections.removeValue(forKey: id)
    lastEmittedCoalescable.removeValue(forKey: .worktreeProjection(id))
    emitProjection(for: id)
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
    guard lastEmittedProjections[worktreeID] != projection else { return }
    lastEmittedProjections[worktreeID] = projection
    emit(.worktreeProjectionChanged(worktreeID, projection))
    // hasAny can only flip when this worktree's surface set actually changed,
    // which `projectionChanged` already implies.
    emitHasAnyTerminalSurfaceIfNeeded()
  }
}
