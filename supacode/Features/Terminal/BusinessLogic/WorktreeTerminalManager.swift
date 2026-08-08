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
  @ObservationIgnored private let surfaceBindingActionPerformer: ((GhosttySurfaceView, String) -> Void)?
  private(set) var socketServer: AgentHookSocketServer?
  private var hosts: [Worktree.ID: WorktreeContentHost] = [:]
  /// The app store; topology commands route into `TerminalsFeature` through it.
  /// Set once from the app shell right after store creation.
  weak var appStore: Store<AppFeature.State, AppFeature.Action>?
  /// Sessions an unexpected-close probe decided to spare; the session killer
  /// consumes an entry to skip the zmx kill for that content.
  private var sessionsToSpare: Set<UUID> = []
  /// Sessions closing without an explicit user action; the session killer
  /// consumes an entry to spare the remote host-side session.
  private var sessionsToKillLocalOnly: Set<UUID> = []
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
  /// Injected clock, handed to each `WorktreeTerminalState` so its hibernation
  /// grace timers run on the same time source as the manager.
  @ObservationIgnored private let clock: any Clock<Duration>
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
    case tabProjection(TabID)
    case tabProgress(TabID)
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
  /// Bumped on every Ghostty config reload. Views that read config-derived
  /// colors (split divider, unfocused-split overlay) observe this so they
  /// re-render even when the focused background is unchanged and its dedup
  /// suppresses a background post.
  private(set) var configGeneration = 0
  @ObservationIgnored
  private nonisolated(unsafe) var runtimeObservers: [NSObjectProtocol] = []
  /// Deeplink URL received from the CLI via socket. Second parameter is the client FD for response.
  var onDeeplinkCommand: ((URL, Int32) -> Void)?
  /// Query received from the CLI via socket. Parameters: resource name, params, client FD.
  var onQuery: ((String, [String: String], Int32) -> Void)?

  init<C: Clock<Duration>>(
    runtime: GhosttyRuntime,
    socketServer: AgentHookSocketServer? = nil,
    clock: C = ContinuousClock(),
    eventBufferCap: Int = WorktreeTerminalManager.defaultEventBufferCap,
    surfaceBindingActionPerformer: ((GhosttySurfaceView, String) -> Void)? = nil
  ) {
    self.eventBufferCap = eventBufferCap
    self.runtime = runtime
    self.surfaceBindingActionPerformer = surfaceBindingActionPerformer
    self.focusedSurfaceBackground = runtime.backgroundColor()
    self.hookEventSleep = { duration in try await clock.sleep(for: duration) }
    self.layoutDebounceSleep = { duration in try await clock.sleep(for: duration) }
    self.clock = clock
    @Dependency(\.settingsFileStorage) var settingsFileStorage
    self.layoutsWriter = LayoutsIncrementalWriter(storage: settingsFileStorage)
    // A theme reload changes the fallback and every non-OSC surface background.
    runtimeObservers.append(
      NotificationCenter.default.addObserver(
        forName: .ghosttyRuntimeConfigDidChange,
        object: runtime,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.configGeneration &+= 1
          self.refreshFocusedSurfaceBackground()
        }
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
    guard let layoutState = layoutState(for: WorktreeID(decoded)) else { return nil }
    let layout = layoutState.layout
    let focusedTabID = layout.focusedPaneID.flatMap { layout.panes[id: $0]?.selectedTabID }
    return layout.panes.flatMap { pane in
      pane.tabs.map { tab in
        var entry = ["id": tab.id.rawValue.uuidString]
        if tab.id == focusedTabID { entry["focused"] = "1" }
        return entry
      }
    }
  }

  func listSurfaces(worktreeID: String, tabID: String) -> [[String: String]]? {
    let decoded = worktreeID.removingPercentEncoding ?? worktreeID
    guard let layoutState = layoutState(for: WorktreeID(decoded)),
      let tabUUID = UUID(uuidString: tabID),
      let tab = layoutState.layout.pane(containingTab: TabID(rawValue: tabUUID))?
        .tabs[id: TabID(rawValue: tabUUID)]
    else { return nil }
    // One content per tab; it is always the focused one.
    return [["id": tab.content.id.rawValue.uuidString, "focused": "1"]]
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

  // swiftlint:disable:next function_parameter_count
  private func scheduleTabCreation(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    input: String?,
    tabID: UUID?,
    customTitle: String?,
    focusing: Bool
  ) {
    Task {
      createTabAsync(
        in: worktree,
        runSetupScriptIfNew: runSetupScriptIfNew,
        initialInput: input,
        tabID: tabID,
        customTitle: customTitle,
        focusing: focusing
      )
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew, let id, let title, let focusing):
      scheduleTabCreation(
        in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, input: nil,
        tabID: id, customTitle: title, focusing: focusing)
    case .createTabWithInput(
      let worktree, let input, let runSetupScriptIfNew, let id, let title, let focusing
    ):
      scheduleTabCreation(
        in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, input: input,
        tabID: id, customTitle: title, focusing: focusing)
    case .ensureInitialTab(let worktree, let runSetupScriptIfNew, let focusing):
      ensureInitialTab(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, focusing: focusing)
    case .stopRunScript(let worktree, let focusing):
      stopBlockingScripts(in: worktree) { host in
        self.closeBlockingTabs(in: worktree, host: host, focusing: focusing) { $0.isRunKind }
      }
    case .stopScript(let worktree, let definitionID, let focusing):
      stopBlockingScripts(in: worktree) { host in
        self.closeBlockingTabs(in: worktree, host: host, focusing: focusing) { kind in
          guard case .script(let definition) = kind else { return false }
          return definition.id == definitionID
        }
      }
    case .runBlockingScript(let worktree, let kind, let script, let focusing):
      runBlockingScript(in: worktree, kind: kind, script: script, focusing: focusing)
    case .closeFocusedTab(let worktree):
      guard let tab = host(for: worktree).focusedTab else { break }
      sendLayout(worktree.id, .contentRequestedClose(content: tab.content.id, scope: .tab))
    case .closeFocusedSurface(let worktree):
      // One content per tab: closing the focused surface closes its tab.
      guard let tab = host(for: worktree).focusedTab else { break }
      sendLayout(worktree.id, .contentRequestedClose(content: tab.content.id, scope: .tab))
    case .beginTabRename(let worktree, _):
      // The pane strips have no inline rename affordance yet.
      terminalLogger.info("beginTabRename is not available on the pane strip yet (worktree \(worktree.id)).")
    case .renameTab(let worktree, let tabID, let title):
      let tab = layoutState(for: worktree.id)?.layout.pane(containingTab: tabID)?.tabs[id: tabID]
      let applied = tab != nil && tab?.isTitleLocked != true
      if applied {
        sendLayout(worktree.id, .renameTab(id: tabID, title: title))
      }
      emit(.tabRenamed(worktreeID: worktree.id, tabID: tabID, applied: applied))
    case .selectTab(let worktree, let tabID):
      sendLayout(worktree.id, .wakeTab(id: tabID))
      sendLayout(worktree.id, .selectTab(id: tabID))
      host(for: worktree).focusSelectedTab()
    case .selectTabAtIndex(let worktree, let index):
      guard let layout = layoutState(for: worktree.id)?.layout,
        let focusedPane = layout.focusedPaneID.flatMap({ layout.panes[id: $0] }),
        !focusedPane.tabs.isEmpty
      else { break }
      // 1-based, clamped to the strip, matching Ghostty goto_tab semantics.
      let target = focusedPane.tabs[min(max(index, 1), focusedPane.tabs.count) - 1]
      sendLayout(worktree.id, .wakeTab(id: target.id))
      sendLayout(worktree.id, .selectTab(id: target.id))
    case .focusSurface(let worktree, let tabID, let surfaceID, let input):
      let host = host(for: worktree)
      // Surface-first: the tab ID is a hint; the surface's actual owner wins.
      guard let owningTab = host.tabID(containing: surfaceID) ?? presentTab(tabID, in: worktree.id) else {
        terminalLogger.warning("focusSurface: surface \(surfaceID) not found in worktree \(worktree.id).")
        break
      }
      sendLayout(worktree.id, .wakeTab(id: owningTab))
      sendLayout(worktree.id, .selectTab(id: owningTab))
      host.liveSurface(surfaceID)?.requestFocus()
      if let input, !input.isEmpty {
        host.focusAndInsertText(input + "\r")
      }
    case .splitSurface(
      let worktree, let tabID, let surfaceID, let direction, let input, let id, let focusing
    ):
      splitSurface(
        in: worktree, tabID: tabID, surfaceID: surfaceID, direction: direction,
        input: input, id: id, focusing: focusing)
    case .destroyTab(let worktree, let tabID, let focusing):
      guard layoutState(for: worktree.id)?.layout.pane(containingTab: tabID) != nil else {
        terminalLogger.warning("destroyTab: tab \(tabID.rawValue) not found in worktree \(worktree.id).")
        // Already gone, so the close goal is met: resolve the ack instead of timing out.
        emit(.tabRemoved(worktreeID: worktree.id, tabID: tabID))
        break
      }
      _ = focusing
      sendLayout(worktree.id, .closeTab(id: tabID))
      emit(.tabRemoved(worktreeID: worktree.id, tabID: tabID))
    case .destroySurface(let worktree, let tabID, let surfaceID, let focusing):
      let host = host(for: worktree)
      // Surface-first: the surface's actual owner wins over the tab hint.
      guard let owningTab = host.tabID(containing: surfaceID) ?? presentTab(tabID, in: worktree.id) else {
        terminalLogger.warning("destroySurface: surface \(surfaceID) not found in worktree \(worktree.id).")
        // Don't synthesize a `surfacesClosed` here: it drives global presence
        // cleanup keyed by surface id, which would drop a duplicate id live in
        // another worktree. The rare validated-then-vanished race falls to the
        // ack watchdog instead.
        break
      }
      sendLayout(worktree.id, .wakeTab(id: owningTab))
      if focusing {
        sendLayout(worktree.id, .selectTab(id: owningTab))
      }
      sendLayout(worktree.id, .closeTab(id: owningTab))
      emit(.tabRemoved(worktreeID: worktree.id, tabID: owningTab))
    default:
      return false
    }
    return true
  }

  /// The tab ID when it exists in the worktree's layout, else nil.
  private func presentTab(_ tabID: TabID, in worktreeID: Worktree.ID) -> TabID? {
    layoutState(for: worktreeID)?.layout.pane(containingTab: tabID) != nil ? tabID : nil
  }

  private func handleSearchCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .startSearch(let worktree):
      host(for: worktree).performBindingActionOnFocusedSurface("start_search")
    case .searchSelection(let worktree):
      host(for: worktree).performBindingActionOnFocusedSurface("search_selection")
    case .navigateSearchNext(let worktree):
      host(for: worktree).navigateSearchOnFocusedSurface(.next)
    case .navigateSearchPrevious(let worktree):
      host(for: worktree).navigateSearchOnFocusedSurface(.previous)
    case .endSearch(let worktree):
      host(for: worktree).performBindingActionOnFocusedSurface("end_search")
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .performBindingAction,
      .performBindingActionOnSurface, .selectTab, .selectTabAtIndex, .focusSurface, .splitSurface,
      .destroyTab, .destroySurface, .renameTab, .setImagePasteAgents, .prune, .setNotificationsEnabled,
      .enforceNotificationRetentionLimit, .setSelectedWorktreeID, .beginTabRename,
      .setTerminalHibernationEnabled:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .performBindingAction(let worktree, let action):
      host(for: worktree).performBindingActionOnFocusedSurface(action)
    case .performBindingActionOnSurface(let worktree, let surfaceID, let action):
      host(for: worktree).performBindingAction(action, onSurfaceID: surfaceID)
    case .setImagePasteAgents(let surfaceID, let agents):
      setImagePasteAgents(agents, onSurfaceID: surfaceID)
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .startSearch, .searchSelection,
      .navigateSearchNext, .navigateSearchPrevious, .endSearch, .selectTab, .selectTabAtIndex,
      .focusSurface, .splitSurface, .destroyTab, .destroySurface, .renameTab, .prune, .setNotificationsEnabled,
      .enforceNotificationRetentionLimit, .setSelectedWorktreeID, .beginTabRename,
      .setTerminalHibernationEnabled:
      return false
    }
    return true
  }

  private func setImagePasteAgents(_ agents: Set<SkillAgent>, onSurfaceID surfaceID: UUID) {
    for host in hosts.values where host.setImagePasteAgents(agents, onSurfaceID: surfaceID) {
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
    case .setTerminalHibernationEnabled:
      sendTerminals(.hibernationPolicyChanged)
    case .setSelectedWorktreeID(let id):
      guard id != selectedWorktreeID else { return }
      if let previousID = selectedWorktreeID, let previousHost = hosts[previousID] {
        rememberFocusedZoom(of: previousHost)
        previousHost.setAllSurfacesOccluded()
        previousHost.forgetLastEmittedFocus()
        previousHost.setWorktreeSelected(false)
        lastEmittedCoalescable.removeValue(forKey: .focus(previousID))
        markLayoutDirty(worktreeID: previousID)
      }
      selectedWorktreeID = id
      hosts[id ?? WorktreeID("")]?.setWorktreeSelected(true)
      // Deselecting arms grace timers, selecting wakes the visible tabs; the
      // reducer owns both through the selection action.
      sendTerminals(.selectedWorktreeChanged(id))
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
    for id in hosts.keys { emitProjection(for: id) }
    // Replay stripe-progress displays so rows attached after the stream start
    // pick up the current values.
    for (worktreeID, host) in hosts {
      for (tabID, display) in host.currentTabProgressDisplays() {
        emit(.tabProgressDisplayChanged(worktreeID: worktreeID, tabID: tabID, display: display))
      }
    }
    return stream
  }

  /// The worktree's layout state in the store, nil before hydration/attach.
  func layoutState(for worktreeID: Worktree.ID) -> LayoutFeature.State? {
    appStore?.withState { $0.terminals.layouts[id: worktreeID] }
  }

  /// Routes an action into the worktree's `LayoutFeature`.
  func sendLayout(_ worktreeID: Worktree.ID, _ action: LayoutFeature.Action) {
    appStore?.send(.terminals(.layouts(.element(id: worktreeID, action: action))))
  }

  private func sendTerminals(_ action: TerminalsFeature.Action) {
    appStore?.send(.terminals(action))
  }

  func hostIfExists(for worktreeID: Worktree.ID) -> WorktreeContentHost? {
    hosts[worktreeID]
  }

  /// The worktree's cross-feature host, created and wired on first use. Also
  /// ensures the layout exists in the store so commands have a target.
  func host(
    for worktree: Worktree,
    runSetupScriptIfNew: () -> Bool = { false }
  ) -> WorktreeContentHost {
    if layoutState(for: worktree.id) == nil {
      sendTerminals(.attachLayout(worktreeID: worktree.id, titlePrefix: worktree.name))
    }
    if let existing = hosts[worktree.id] {
      if runSetupScriptIfNew() {
        existing.enableSetupScriptIfNeeded()
      }
      return existing
    }
    let host = WorktreeContentHost(
      worktree: worktree,
      runtime: ContentRuntime.liveValue,
      clock: clock,
      runSetupScript: runSetupScriptIfNew()
    )
    host.socketPath = socketServer?.socketPath
    host.notificationsEnabled = notificationsEnabled
    host.layout = { [weak self] in self?.layoutState(for: worktree.id)?.layout }
    host.sendLayoutAction = { [weak self] action in self?.sendLayout(worktree.id, action) }
    host.setWorktreeSelected(selectedWorktreeID == worktree.id)
    host.hibernationAgentsBySurface = { [weak self] in self?.currentAgentsBySurface?() ?? [:] }
    host.isSelected = { [weak self] in
      self?.selectedWorktreeID == worktree.id
    }
    host.onSurfacesClosed = { [weak self] ids in
      self?.emit(.surfacesClosed(worktreeID: worktree.id, ids))
      // The last surface closing leaves no focus target, so no focus event
      // follows; fall back to the theme background here.
      self?.refreshFocusedSurfaceBackground()
    }
    // Hibernation keeps the zmx sessions and presence records; only the pending
    // idle-debounce tasks for the torn-down surfaces need cancelling.
    host.onSurfacesHibernated = { [weak self] ids in self?.cancelPendingIdleHooks(forSurfaceIDs: ids) }
    // A hibernate / wake leaves the surface set unchanged, so re-emit the row
    // projection here or the sidebar sleep marker never tracks dormancy.
    host.onDormancyChanged = { [weak self] in self?.emitProjection(for: worktree.id) }
    // OSC-sourced presence events go through the existing idle-debounce funnel.
    host.onAgentHookEvent = { [weak self] event in
      self?.dispatchHookEvent(event)
    }
    host.onNotificationReceived = { [weak self] surfaceID, title, body, isViewed in
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
    host.onNotificationIndicatorChanged = { [weak self] in
      self?.emitNotificationIndicatorCountIfNeeded()
      self?.emitProjection(for: worktree.id)
    }
    host.onFocusChanged = { [weak self] surfaceID in
      self?.emit(.focusChanged(worktreeID: worktree.id, surfaceID: surfaceID))
      self?.refreshFocusedSurfaceBackground()
    }
    host.onFocusedSurfaceColorChanged = { [weak self] in
      self?.refreshFocusedSurfaceBackground()
    }
    host.onTaskStatusChanged = { [weak self] status in
      self?.emit(.taskStatusChanged(worktreeID: worktree.id, status: status))
      self?.emitProjection(for: worktree.id)
    }
    host.onBlockingScriptCompleted = { [weak self] kind, exitCode, tabId in
      self?.emit(.blockingScriptCompleted(worktreeID: worktree.id, kind: kind, exitCode: exitCode, tabId: tabId))
    }
    host.onRunningScriptsChanged = { [weak self] in
      // Force past the projection dedupe: an archived-strip can clear the row while
      // the cache still holds running, so a plain emit would dedupe and strand it (#573).
      self?.forceEmitProjection(for: worktree.id)
    }
    host.onCommandPaletteToggle = { [weak self] in
      self?.emit(.commandPaletteToggleRequested(worktreeID: worktree.id))
    }
    host.onSetupScriptConsumed = { [weak self] in
      self?.emit(.setupScriptConsumed(worktreeID: worktree.id))
    }
    host.onTabProgressDisplayChanged = { [weak self] tabID, display in
      self?.emit(.tabProgressDisplayChanged(worktreeID: worktree.id, tabID: tabID, display: display))
    }
    hosts[worktree.id] = host
    terminalLogger.info("Created content host for worktree \(worktree.id)")
    return host
  }

  /// Fires the layout-changed side effects the reducer cannot: persistence
  /// debounce and the sidebar projection. Called by the app shell whenever a
  /// worktree's layout value changes.
  func handleLayoutChanged(for worktreeID: Worktree.ID) {
    markLayoutDirty(worktreeID: worktreeID)
    emitProjection(for: worktreeID)
    hosts[worktreeID]?.reconcileDormantWatchers()
  }

  /// Consumes a spare decision for an unexpected-close content; the session
  /// killer skips the zmx kill when this returns true.
  func consumeSpareSession(for contentID: ContentID) -> Bool {
    sessionsToSpare.remove(contentID.rawValue) != nil
  }

  /// Tears down the zmx sessions behind a closed content unless a prior
  /// unexpected-close probe decided to spare them. `isBundled` (not
  /// `executableURL`) gates the local kill so sessions from a previous
  /// under-budget launch still tear down.
  func killSession(for contentID: ContentID, worktreeID: Worktree.ID) async {
    guard !consumeSpareSession(for: contentID) else { return }
    let killLocal = zmxClient.isBundled()
    // A non-explicit end (clean remote exit, deliberate host-side detach)
    // spares the host session; only explicit closes tear it down.
    let localOnly = sessionsToKillLocalOnly.remove(contentID.rawValue) != nil
    let remoteHost =
      localOnly
      ? nil
      : hosts[worktreeID]?.worktree.host
        ?? appStore?.withState { $0.repositories.worktree(for: worktreeID)?.host }
    guard killLocal || remoteHost != nil else { return }
    analyticsClient.capture(
      "terminal_persistence_session_killed",
      [
        "reason": "user_close", "count": killLocal ? 1 : 0,
        "remote_count": remoteHost == nil ? 0 : 1,
      ]
    )
    await zmxClient.killSurfaceSessions(
      sessionID: ZmxSessionID.make(surfaceID: contentID.rawValue),
      remoteHost: remoteHost,
      killLocal: killLocal
    )
  }

  /// An unexpected zmx exit: probe the session, then spare, kill, or reattach.
  func handleUnexpectedZmxClose(_ view: GhosttySurfaceView, worktreeID: Worktree.ID) {
    let surfaceID = view.id
    Task { @MainActor [weak self] in
      let probe = await self?.zmxClient.listSessionsWithClients()
      guard let self, let host = self.hosts[worktreeID], host.liveSurface(surfaceID) === view else { return }
      guard let tabID = host.tabID(containing: surfaceID) else { return }
      let sessionID = ZmxSessionID.make(surfaceID: surfaceID)
      let session = probe?.first { $0.name == sessionID }
      guard let probe else {
        // Failed probe: never destroy on no signal; close but spare the session.
        self.sessionsToSpare.insert(surfaceID)
        self.sendLayout(worktreeID, .closeTab(id: tabID))
        return
      }
      _ = probe
      guard let session else {
        // Session already dead; the close's kill is local cleanup. The end
        // was not user-initiated, so a remote host-side session survives.
        self.sessionsToKillLocalOnly.insert(surfaceID)
        self.sendLayout(worktreeID, .closeTab(id: tabID))
        return
      }
      if session.clients == 0 {
        // Reattachable: rebuild the same content at its persisted geometry.
        ContentRuntime.liveValue.remove(ContentID(rawValue: surfaceID), tombstone: false)
        self.sendLayout(worktreeID, .wakeTab(id: tabID))
        return
      }
      // Another client attached (or unknown count): close without killing.
      self.sessionsToSpare.insert(surfaceID)
      self.sendLayout(worktreeID, .closeTab(id: tabID))
    }
  }

  private func createTabAsync(
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    initialInput: String? = nil,
    tabID: UUID? = nil,
    customTitle: String? = nil,
    focusing: Bool = true
  ) {
    let host = host(for: worktree) { runSetupScriptIfNew }
    guard let layout = layoutState(for: worktree.id)?.layout else { return }
    let setupInput = consumeSetupScriptInput(for: worktree, host: host)
    let combinedInput = [setupInput, initialInput].compactMap { $0 }.joined()
    let launch: LaunchOverride? =
      combinedInput.isEmpty ? nil : LaunchOverride(initialInput: combinedInput)
    let inheritedFrom = host.focusedTab?.content.id
    let paneID = layout.focusedPaneID ?? layout.panes.first?.id ?? PaneID()
    let spec = NewTabSpec(
      tabID: tabID.map(TabID.init(rawValue:)),
      contentID: tabID.map(ContentID.init(rawValue:)),
      title: "\(worktree.name) \(nextTabIndex(in: layout, prefix: worktree.name))",
      content: .terminal(TerminalContentState(workingDirectory: nil, launch: launch)),
      geometry: ContentRuntime.liveValue.spawnGeometry(near: inheritedFrom, fallback: inheritedFrom),
      select: focusing,
      inheritedFrom: inheritedFrom
    )
    sendLayout(worktree.id, .newTab(inPane: paneID, spec: spec))
    if let customTitle, let newTabID = spec.tabID {
      sendLayout(worktree.id, .renameTab(id: newTabID, title: customTitle))
    }
    if let tabID, layoutState(for: worktree.id)?.layout.tab(containingContent: ContentID(rawValue: tabID)) == nil {
      // Drain a waiting CLI ack now instead of stranding it until the timeout.
      emit(
        .surfaceCreationFailed(
          worktreeID: worktree.id, attemptedID: tabID, message: "Could not create the tab."))
    }
  }

  /// The next "<prefix> N" suffix, scanning every strip like the tab manager did.
  private func nextTabIndex(in layout: PaneLayout, prefix: String) -> Int {
    var maxIndex = 0
    for pane in layout.panes {
      for tab in pane.tabs {
        guard tab.title.hasPrefix("\(prefix) "), let value = Int(tab.title.dropFirst(prefix.count + 1)) else {
          continue
        }
        maxIndex = max(maxIndex, value)
      }
    }
    return maxIndex + 1
  }

  /// Resolves and consumes the pending setup script, if any.
  private func consumeSetupScriptInput(for worktree: Worktree, host: WorktreeContentHost) -> String? {
    guard host.needsSetupScript() else { return nil }
    @SharedReader(.repositorySettings(worktree.repositoryRootURL, host: worktree.host))
    var settings = RepositorySettings.default
    let script = settings.setupScript
    guard !script.isEmpty else {
      host.markSetupScriptSkipped()
      return nil
    }
    guard host.consumeSetupScript() else { return nil }
    return BlockingScriptRunner.makeCommandInput(script: script)
  }

  /// Creates the first tab when the layout is empty, matching the legacy
  /// ensure-initial-tab semantics; restored layouts already have tabs.
  private func ensureInitialTab(in worktree: Worktree, runSetupScriptIfNew: Bool, focusing: Bool) {
    let host = host(for: worktree) { runSetupScriptIfNew }
    _ = host
    guard layoutState(for: worktree.id)?.layout.panes.isEmpty != false else { return }
    createTabAsync(in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, focusing: focusing)
  }

  /// Launches a blocking script in a locked, ephemeral tab.
  private func runBlockingScript(
    in worktree: Worktree,
    kind: BlockingScriptKind,
    script: String,
    focusing: Bool
  ) {
    let host = host(for: worktree)
    // User-script dedup: a still-running script keeps its tab.
    if case .script = kind, let active = host.trackedBlockingScriptTab(for: kind) {
      _ = active
      sendLayout(worktree.id, .selectTab(id: active))
      return
    }
    let command: String?
    let initialInput: String?
    let launchDirectory: URL?
    if let remoteHost = worktree.host {
      guard
        let remote = BlockingScriptRunner.remoteCommand(
          host: remoteHost,
          script: script,
          remoteWorktreePath: worktree.workingDirectory.path(percentEncoded: false),
          environment: [:]
        )
      else {
        host.reportBlockingScriptLaunchFailure(kind, "Could not build the remote script command.")
        return
      }
      command = remote
      initialInput = nil
      launchDirectory = nil
    } else {
      let prepared: BlockingScriptRunner.LaunchArtifacts?
      do {
        prepared = try BlockingScriptRunner.makeLaunch(script: script, shellPath: Self.defaultShellPath())
      } catch {
        host.reportBlockingScriptLaunchFailure(kind, "\(error)")
        return
      }
      guard let prepared else {
        host.reportBlockingScriptLaunchFailure(kind, "The script is empty.")
        return
      }
      command = Self.defaultShellPath()
      initialInput = prepared.commandInput
      launchDirectory = prepared.directoryURL
    }
    // Replace a lingering completed/cancelled tab of this kind.
    if let lingering = host.lingeringBlockingScriptTab(for: kind) {
      host.untrackBlockingScript(tabID: lingering)
      sendLayout(worktree.id, .closeTab(id: lingering))
    }
    let layout = layoutState(for: worktree.id)?.layout
    let paneID = layout?.focusedPaneID ?? layout?.panes.first?.id ?? PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    // Tracking must exist BEFORE the surface builds so the env markers resolve.
    host.trackBlockingScript(kind: kind, tabID: tabID, launchDirectory: launchDirectory)
    let spec = NewTabSpec(
      tabID: tabID,
      contentID: contentID,
      title: kind.tabTitle,
      icon: kind.tabIcon,
      tintColor: kind.tabColor,
      isTitleLocked: true,
      content: .terminal(
        TerminalContentState(
          workingDirectory: nil,
          launch: LaunchOverride(command: command, initialInput: initialInput, bypassZmx: true)
        )
      ),
      geometry: ContentRuntime.liveValue.spawnGeometry(near: host.focusedTab?.content.id),
      select: focusing
    )
    sendLayout(worktree.id, .newTab(inPane: paneID, spec: spec))
    guard layoutState(for: worktree.id)?.layout.pane(containingTab: tabID) != nil else {
      host.untrackBlockingScript(tabID: tabID)
      host.reportBlockingScriptLaunchFailure(kind, "Could not create the script tab.")
      return
    }
    host.emitTaskStatusIfChanged()
    terminalLogger.info("Started \(kind.tabTitle) for worktree \(worktree.id)")
  }

  /// Closes every tracked blocking tab matching `predicate`; false when none.
  private func closeBlockingTabs(
    in worktree: Worktree,
    host: WorktreeContentHost,
    focusing: Bool,
    matching predicate: (BlockingScriptKind) -> Bool
  ) -> Bool {
    _ = focusing
    var closed = false
    for tabID in host.blockingScriptTabs(matching: predicate) {
      host.handleBlockingScriptTabClosed(tabID: tabID)
      sendLayout(worktree.id, .closeTab(id: tabID))
      closed = true
    }
    return closed
  }

  private static func defaultShellPath() -> String {
    ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  }

  /// CLI / deeplink split: opens a fresh pane next to the surface's pane.
  private func splitSurface(  // swiftlint:disable:this function_parameter_count
    in worktree: Worktree,
    tabID: TabID,
    surfaceID: UUID,
    direction: SplitDirection,
    input: String?,
    id: UUID?,
    focusing: Bool
  ) {
    let host = host(for: worktree)
    // Surface-first: the surface's actual owner wins over the tab hint.
    guard let owningTab = host.tabID(containing: surfaceID) ?? presentTab(tabID, in: worktree.id) else {
      terminalLogger.warning("splitSurface: surface \(surfaceID) not found in worktree \(worktree.id).")
      if let id {
        emit(
          .surfaceCreationFailed(
            worktreeID: worktree.id, attemptedID: id,
            message: "Could not create the split surface."))
      }
      return
    }
    // The wake runs even when not focusing: splitting a dormant tab would
    // otherwise land in a frozen layout.
    sendLayout(worktree.id, .wakeTab(id: owningTab))
    if focusing {
      sendLayout(worktree.id, .selectTab(id: owningTab))
    }
    guard let layout = layoutState(for: worktree.id)?.layout,
      let anchorPane = layout.pane(containingTab: owningTab),
      let anchorContent = anchorPane.tabs[id: owningTab]?.content.id
    else { return }
    let resolvedInput = BlockingScriptRunner.makeCommandInput(script: input ?? "")
    let launch: LaunchOverride? = resolvedInput.map { LaunchOverride(initialInput: $0) }
    let spec = NewTabSpec(
      tabID: id.map(TabID.init(rawValue:)),
      contentID: id.map(ContentID.init(rawValue:)),
      title: "\(worktree.name) \(nextTabIndex(in: layout, prefix: worktree.name))",
      content: .terminal(TerminalContentState(workingDirectory: nil, launch: launch)),
      geometry: ContentRuntime.liveValue.spawnGeometry(near: anchorContent),
      select: focusing,
      inheritedFrom: anchorContent
    )
    sendLayout(
      worktree.id,
      .splitPane(id: anchorPane.id, direction: direction == .vertical ? .down : .right, spec: spec)
    )
    if let id, layoutState(for: worktree.id)?.layout.tab(containingContent: ContentID(rawValue: id)) == nil {
      terminalLogger.warning("splitSurface: failed for surface \(surfaceID) in worktree \(worktree.id).")
      emit(
        .surfaceCreationFailed(
          worktreeID: worktree.id, attemptedID: id,
          message: "Could not create the split surface."))
    }
  }

  func prune(
    keeping worktreeIDs: Set<Worktree.ID>,
    protectingRepositoryIDs protectedRepositoryIDs: Set<Repository.ID> = []
  ) {
    let shouldKeep: (Worktree.ID, WorktreeContentHost) -> Bool = { id, host in
      worktreeIDs.contains(id) || protectedRepositoryIDs.contains(host.repositoryID)
    }
    var removed: [(Worktree.ID, WorktreeContentHost)] = []
    for (id, host) in hosts where !shouldKeep(id, host) {
      removed.append((id, host))
    }
    let prunedSurfaceIDs = Set(removed.flatMap { _, host in host.allSurfaceIDs })
    let prunedSessionIDs = removed.flatMap { _, host in
      host.allSurfaceIDs.map { ZmxSessionID.make(surfaceID: $0) }
    }
    let prunedRemoteSessions = Self.remoteSessions(in: removed.map(\.1))
    for (id, host) in removed {
      // Clear instead of resaving: archived / deleted worktrees should leave
      // no trace in `layouts.json`. The explicit delete bypasses the debounce
      // and cancels any queued positive save so a pruned worktree can't be
      // resurrected by an in-flight snapshot.
      deleteLayoutSnapshot(worktreeID: id)
      // Watchers stop before the kill; the contents drop from the runtime.
      host.tearDown()
      for surfaceID in host.allSurfaceIDs {
        ContentRuntime.liveValue.remove(ContentID(rawValue: surfaceID), tombstone: false)
      }
      // Signals the reducer to drop the pruned layout and bookkeeping.
      sendTerminals(.detachLayout(worktreeID: id))
      emit(.worktreeStateTornDown(worktreeID: id))
    }
    if !removed.isEmpty {
      terminalLogger.info("Pruned \(removed.count) terminal host(s)")
    }
    hosts = hosts.filter { shouldKeep($0.key, $0.value) }
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
    in hosts: [WorktreeContentHost]
  ) -> [(host: RemoteHost, sessionID: String)] {
    hosts.flatMap { host -> [(host: RemoteHost, sessionID: String)] in
      guard let remoteHost = host.worktree.host else { return [] }
      return host.allSurfaceIDs.map { (remoteHost, ZmxSessionID.make(surfaceID: $0)) }
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

  /// Fires after the debounce window: builds the freshest record for
  /// `worktreeID` (live-grid + agent overlay), then queues the off-main
  /// per-key merge. Its only caller is `markLayoutDirty`.
  private func flushLayoutSnapshot(worktreeID: Worktree.ID) {
    layoutDirtyTasks[worktreeID] = nil
    guard let layoutState = layoutState(for: worktreeID) else { return }
    // A file written by a newer schema is served read-only; never write back.
    guard appStore?.withState({ $0.terminals.layoutsAreReadOnly }) != true else { return }
    let record = LayoutPersistence.record(
      for: layoutState.layout,
      runtime: ContentRuntime.liveValue,
      agentsBySurface: currentAgentsBySurface?() ?? [:]
    )
    // An empty layout clears the key rather than persisting an empty record,
    // matching the on-disk "no trace" semantics for emptiness.
    let change: LayoutsIncrementalWriter.RecordChange =
      record.layout.panes.isEmpty ? .delete : .record(record)
    let writer = layoutsWriter
    let task = Task { [weak self] in
      await writer.flush(records: [worktreeID.rawValue: change])
      self?.layoutFlushTasks[worktreeID] = nil
    }
    layoutFlushTasks[worktreeID] = task
  }

  /// Removes `worktreeID` from disk immediately, bypassing the debounce and
  /// cancelling any queued positive save so a stale snapshot can't resurrect a
  /// removed worktree. Awaits any in-flight positive flush for the key first so
  /// the `.delete` always reaches the writer after the record.
  private func deleteLayoutSnapshot(worktreeID: Worktree.ID) {
    layoutDirtyTasks[worktreeID]?.cancel()
    layoutDirtyTasks[worktreeID] = nil
    let inflightFlush = layoutFlushTasks[worktreeID]
    let writer = layoutsWriter
    let task = Task { [weak self] in
      await inflightFlush?.value
      await writer.flush(records: [worktreeID.rawValue: .delete])
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

  func tabExists(worktreeID: Worktree.ID, tabID: TabID) -> Bool {
    layoutState(for: worktreeID)?.layout.pane(containingTab: tabID) != nil
  }

  func tabCanRename(worktreeID: Worktree.ID, tabID: TabID) -> Bool {
    layoutState(for: worktreeID)?.layout.pane(containingTab: tabID)?.tabs[id: tabID]?.isTitleLocked == false
  }

  func surfaceExists(worktreeID: Worktree.ID, tabID: TabID, surfaceID: UUID) -> Bool {
    // Tab-hint tolerant: the surface's actual owner wins, matching the
    // surface-first resolution contract.
    layoutState(for: worktreeID)?.layout.tab(containingContent: ContentID(rawValue: surfaceID)) != nil
  }

  /// Checks whether a surface UUID exists anywhere in the worktree (across all tabs).
  func surfaceExistsInWorktree(worktreeID: Worktree.ID, surfaceID: UUID) -> Bool {
    layoutState(for: worktreeID)?.layout.tab(containingContent: ContentID(rawValue: surfaceID)) != nil
  }

  /// Surface IDs that live in this tab.
  func surfaceIDs(forTabID tabID: TabID) -> [UUID] {
    guard let store = appStore else { return [] }
    return store.withState { state in
      for layout in state.terminals.layouts {
        if let tab = layout.layout.pane(containingTab: tabID)?.tabs[id: tabID] {
          return [tab.content.id.rawValue]
        }
      }
      return []
    }
  }

  /// Surface IDs across every tab in this worktree.
  func surfaceIDs(forWorktreeID worktreeID: Worktree.ID) -> [UUID] {
    layoutState(for: worktreeID)?.layout.allContentIDs.map(\.rawValue) ?? []
  }

  func isBlockingScriptRunning(kind: BlockingScriptKind, for worktreeID: Worktree.ID) -> Bool {
    hosts[worktreeID]?.isBlockingScriptRunning(kind: kind) == true
  }

  var hasInflightBlockingScripts: Bool {
    hosts.values.contains(where: \.hasInflightBlockingScripts)
  }

  /// Tear down every tracked surface AND reap any orphans the daemon still
  /// hosts. zmx is a long-lived per-user daemon that outlives our app quit,
  /// so "Quit and Terminate" must explicitly sweep orphan sessions or they
  /// would survive forever.
  func terminateAllSessions(killBudget: Duration = WorktreeTerminalManager.quitKillBudget) async {
    let trackedSurfaceIDs = hosts.values.flatMap(\.allSurfaceIDs)
    let trackedSessionIDs = Set(trackedSurfaceIDs.map(ZmxSessionID.make(surfaceID:)))
    // "Quit and Terminate" promises nothing keeps running, so the host-side
    // sessions of remote worktrees are swept too (best-effort over SSH).
    let trackedRemoteSessions = Self.remoteSessions(in: Array(hosts.values))
    for host in hosts.values {
      host.tearDown()
    }
    for surfaceID in trackedSurfaceIDs {
      guard let content = ContentRuntime.liveValue.content(for: ContentID(rawValue: surfaceID)) else { continue }
      content.hibernate()
      ContentRuntime.liveValue.remove(content.id, tombstone: false)
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
    for host in hosts.values {
      host.setNotificationsEnabled(enabled)
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  /// Re-applies the retention limit to every worktree, e.g. after the user lowers
  /// it in settings so an existing backlog is trimmed without waiting for the next
  /// notification.
  func enforceNotificationRetentionLimit() {
    for host in hosts.values {
      host.enforceNotificationRetentionLimit()
    }
    emitNotificationIndicatorCountIfNeeded()
  }

  func hasUnseenNotifications(for worktreeID: Worktree.ID) -> Bool {
    hosts[worktreeID]?.hasUnseenNotification == true
  }

  /// Locates the most recent unread notification across all managed
  /// worktrees whose surface still exists. Notifications whose surface has
  /// been closed are skipped in favour of the next-newest focusable unread.
  func latestUnreadNotificationLocation() -> NotificationLocation? {
    var best: NotificationLocation?
    var bestCreatedAt: Date?
    var skippedClosedSurface = false
    for (worktreeID, host) in hosts {
      for notification in host.unreadNotifications() {
        if let bestCreatedAt, bestCreatedAt >= notification.createdAt { break }
        guard let tabID = host.tabID(containing: notification.surfaceID) else {
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
  func tabID(forWorktreeID worktreeID: Worktree.ID, surfaceID: UUID) -> TabID? {
    hosts[worktreeID]?.tabID(containing: surfaceID)
  }

  func markNotificationRead(worktreeID: Worktree.ID, notificationID: UUID) {
    hosts[worktreeID]?.markNotificationRead(id: notificationID)
    emitProjection(for: worktreeID)
  }

  /// Indicator and projection updates propagate via each state's notification
  /// callbacks. Every state is swept, not just the unread ones, so a surface
  /// whose unseen mirror drifted out of sync with its notifications is repaired.
  func markAllNotificationsRead() {
    let unread = hosts.values.count(where: \.hasUnseenNotification)
    terminalLogger.info("markAllNotificationsRead: clearing unread in \(unread) worktree(s).")
    for host in hosts.values {
      host.markAllNotificationsRead()
    }
  }

  /// Embed `agentsBySurface` in each record so badges survive relaunch.
  func saveAllLayoutSnapshots(
    agentsBySurface: [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]? = nil
  ) {
    guard appStore?.withState({ $0.terminals.layoutsAreReadOnly }) != true else { return }
    var changes: [String: LayoutsIncrementalWriter.RecordChange] = [:]
    for (id, _) in hosts {
      guard let layoutState = layoutState(for: id) else { continue }
      let record = LayoutPersistence.record(
        for: layoutState.layout,
        runtime: ContentRuntime.liveValue,
        agentsBySurface: agentsBySurface ?? [:]
      )
      changes[id.rawValue] = record.layout.panes.isEmpty ? .delete : .record(record)
    }
    layoutsWriter.flushSync(records: changes)
  }

  /// Capture the selected worktree's zoom at quit (no switch fires then).
  func rememberSelectedWorktreeZoomOnQuit() {
    guard let selectedWorktreeID, let host = hosts[selectedWorktreeID] else { return }
    rememberFocusedZoom(of: host)
  }

  /// Sample and persist the focused surface's zoomed font (worktree switch,
  /// quit); 0 clears a prior zoom, matching Ghostty dropping the override.
  private func rememberFocusedZoom(of host: WorktreeContentHost) {
    guard runtime.windowInheritsFontSize() else { return }
    guard let contentID = host.focusedContentID,
      let surface = host.liveSurface(contentID)?.surface
    else { return }
    @Shared(.appStorage(TerminalSurfaceRecipe.rememberedZoomFontSizeKey)) var stored: Double = 0
    $stored.withLock { $0 = Double(max(ghostty_surface_font_size(surface), 0)) }
  }

  private func resolveFocusedSurfaceBackground() -> NSColor {
    guard let selectedWorktreeID,
      let host = hosts[selectedWorktreeID],
      let surfaceState = host.focusedSurfaceState()
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

  // The user's `split-divider-color`, or the opaque asset fallback when unset.
  // Opaque, not a system separator: the terminal body is cut out of the window
  // tint, so a translucent divider would let the window blur show through the gap.
  func splitDividerColor() -> Color {
    runtime.splitDividerColor() ?? Color(.splitDivider)
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
    let count = hosts.values.reduce(0) { $0 + $1.totalUnseenNotificationCount }
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
    let hasAny = hosts.values.contains(where: \.hasAnySurface)
    let previous = lastEmittedHasAnyTerminalSurface ?? false
    guard hasAny != previous else { return }
    lastEmittedHasAnyTerminalSurface = hasAny
    emit(.terminalHasAnySurfaceChanged(hasAny: hasAny))
  }

  /// Runs `stop` on the worktree's existing terminal state, never minting one.
  /// A miss with a live state means the caller acted on a stale mirror, so force
  /// a fresh projection emit past the dedupe cache to reconcile it (#573).
  private func stopBlockingScripts(in worktree: Worktree, using stop: (WorktreeContentHost) -> Bool) {
    guard let host = hostIfExists(for: worktree.id) else {
      terminalLogger.warning("Stop requested for \(worktree.id) with no terminal host")
      return
    }
    guard !stop(host) else { return }
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
    guard let host = hosts[worktreeID] else { return }
    let projection = host.currentProjection()
    guard lastEmittedProjections[worktreeID] != projection else { return }
    lastEmittedProjections[worktreeID] = projection
    emit(.worktreeProjectionChanged(worktreeID, projection))
    // hasAny can only flip when this worktree's surface set actually changed,
    // which `projectionChanged` already implies.
    emitHasAnyTerminalSurfaceIfNeeded()
  }
}
