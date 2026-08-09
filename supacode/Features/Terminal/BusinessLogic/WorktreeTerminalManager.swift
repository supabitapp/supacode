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
  /// The windowed-pane windows, reconciled after every layout change.
  @ObservationIgnored let paneWindows = PaneWindowManager()
  /// The app store; topology commands route into `TerminalsFeature` through it.
  /// Set once from the app shell right after store creation.
  weak var appStore: Store<AppFeature.State, AppFeature.Action>?
  /// Sessions an unexpected-close probe decided to spare; the session killer
  /// consumes an entry to skip the zmx kill for that content.
  private var sessionsToSpare: Set<UUID> = []
  /// Sessions closing without an explicit user action; the session killer
  /// consumes an entry to spare the remote host-side session.
  private var sessionsToKillLocalOnly: Set<UUID> = []
  /// Worktrees with a deferred activity re-assert already queued, so a burst
  /// of layout actions (a divider drag) coalesces into one pass per tick.
  private var pendingActivityReasserts: Set<Worktree.ID> = []
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
  /// Injected clock, handed to each content host so its OSC hold and dedupe
  /// windows run on the same time source as the manager.
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
  @ObservationIgnored private var layoutFlushTasks: [Worktree.ID: (generation: UInt64, task: Task<Void, Never>)] = [:]
  /// Monotonic stamp for `layoutFlushTasks` so an older task's completion can
  /// never erase a newer registration for the same key.
  @ObservationIgnored private var layoutFlushGeneration: UInt64 = 0
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
    paneWindows.terminalManager = self
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
    for entry in layoutFlushTasks.values { entry.task.cancel() }
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
  private func scheduleTabCreation(  // swiftlint:disable:this function_parameter_count
    in worktree: Worktree,
    runSetupScriptIfNew: Bool,
    input: String?,
    tabID: UUID?,
    customTitle: String?,
    focusing: Bool,
    anchor: UUID? = nil
  ) {
    Task {
      createTabAsync(
        in: worktree,
        runSetupScriptIfNew: runSetupScriptIfNew,
        initialInput: input,
        tabID: tabID,
        customTitle: customTitle,
        focusing: focusing,
        anchor: anchor
      )
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func handleTabCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .createTab(let worktree, let runSetupScriptIfNew, let id, let title, let focusing, let anchor):
      scheduleTabCreation(
        in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, input: nil,
        tabID: id, customTitle: title, focusing: focusing, anchor: anchor)
    case .createTabWithInput(
      let worktree, let input, let runSetupScriptIfNew, let id, let title, let focusing, let anchor
    ):
      scheduleTabCreation(
        in: worktree, runSetupScriptIfNew: runSetupScriptIfNew, input: input,
        tabID: id, customTitle: title, focusing: focusing, anchor: anchor)
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
    case .beginTabRename(let worktree, let tabID):
      guard let target = tabID ?? host(for: worktree).focusedTab?.id else { break }
      sendLayout(worktree.id, .beginTabRename(id: target))
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
      .destroyTab, .destroySurface, .renameTab, .setImagePasteAgents, .prune, .removeWorktreeLayout,
      .setNotificationsEnabled, .enforceNotificationRetentionLimit, .setSelectedWorktreeID, .beginTabRename,
      .setTerminalHibernationEnabled, .toggleWindowModeForFocusedPane,
      .splitFocusedPane, .focusSplit, .toggleSplitZoom, .equalizeSplits,
      .splitPane, .focusPane, .closePane, .toggleZoomPane, .toggleWindowModeForPane, .moveTabToSplit:
      return false
    }
    return true
  }

  private func handleBindingActionCommand(_ command: TerminalClient.Command) -> Bool {
    switch command {
    case .splitFocusedPane(let worktree, let direction):
      sendFocusedContentLayoutAction(worktree.id) {
        .contentRequestedSplit(content: $0, direction: direction.newSplitDirection)
      }
    case .focusSplit(let worktree, let direction):
      sendFocusedContentLayoutAction(worktree.id) {
        .contentRequestedFocusSplit(content: $0, direction: direction.focusSplitDirection)
      }
    case .toggleSplitZoom(let worktree):
      sendFocusedContentLayoutAction(worktree.id) { .contentRequestedToggleZoom(content: $0) }
    case .equalizeSplits(let worktree):
      sendLayout(worktree.id, .equalizePanes)
    case .splitPane(let worktree, let token, let direction, let input, let id, let focusing):
      splitPane(in: worktree, paneToken: token, direction: direction, input: input, id: id, focusing: focusing)
    case .focusPane(let worktree, let paneToken):
      focusPane(in: worktree, paneToken: paneToken)
    case .closePane(let worktree, let token):
      closePane(in: worktree, paneToken: token)
    case .toggleZoomPane(let worktree, let token):
      toggleZoomPane(in: worktree, paneToken: token)
    case .toggleWindowModeForPane(let worktree, let token):
      toggleWindowModeForPane(in: worktree, paneToken: token)
    case .moveTabToSplit(let worktree, let tabID, let direction, let focusing):
      moveTabToSplit(in: worktree, tabID: tabID, direction: direction, focusing: focusing)
    case .performBindingAction(let worktree, let action):
      host(for: worktree).performBindingActionOnFocusedSurface(action)
    case .performBindingActionOnSurface(let worktree, let surfaceID, let action):
      host(for: worktree).performBindingAction(action, onSurfaceID: surfaceID)
    case .setImagePasteAgents(let surfaceID, let agents):
      setImagePasteAgents(agents, onSurfaceID: surfaceID)
    case .createTab, .createTabWithInput, .ensureInitialTab, .stopRunScript, .stopScript,
      .runBlockingScript, .closeFocusedTab, .closeFocusedSurface, .startSearch, .searchSelection,
      .navigateSearchNext, .navigateSearchPrevious, .endSearch, .selectTab, .selectTabAtIndex,
      .focusSurface, .splitSurface, .destroyTab, .destroySurface, .renameTab, .prune, .removeWorktreeLayout,
      .setNotificationsEnabled, .enforceNotificationRetentionLimit, .setSelectedWorktreeID, .beginTabRename,
      .setTerminalHibernationEnabled, .toggleWindowModeForFocusedPane,
      .splitFocusedPane, .focusSplit, .toggleSplitZoom, .equalizeSplits:
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
    case .removeWorktreeLayout(let worktreeID, let remoteHost):
      removeWorktreeLayout(for: worktreeID, remoteHost: remoteHost)
    case .setNotificationsEnabled(let enabled):
      setNotificationsEnabled(enabled)
    case .enforceNotificationRetentionLimit:
      enforceNotificationRetentionLimit()
    case .setTerminalHibernationEnabled:
      sendTerminals(.hibernationPolicyChanged)
    case .toggleWindowModeForFocusedPane(let worktree):
      toggleWindowModeForFocusedPane(of: worktree)
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
      .splitSurface, .destroyTab, .destroySurface, .renameTab, .beginTabRename,
      .splitFocusedPane, .focusSplit, .toggleSplitZoom, .equalizeSplits,
      .splitPane, .focusPane, .closePane, .toggleZoomPane, .toggleWindowModeForPane, .moveTabToSplit:
      assertionFailure("Unhandled terminal command reached management handler: \(command)")
    }
  }

  /// Toggles window mode for the worktree's focused pane. A key pane window
  /// (or its palette child) wins over the selected worktree, so the command
  /// returns THAT pane inline.
  private func toggleWindowModeForFocusedPane(of worktree: Worktree) {
    let keyPaneWindow = (NSApp.keyWindow as? PaneWindow) ?? (NSApp.keyWindow?.parent as? PaneWindow)
    if let keyPaneWindow, let worktreeID = keyPaneWindow.hostedWorktreeID,
      let paneID = keyPaneWindow.hostedPaneID
    {
      sendLayout(worktreeID, .exitWindowMode(paneID: paneID))
      return
    }
    guard let layout = layoutState(for: worktree.id) else {
      terminalLogger.warning("toggleWindowMode: no layout state for \(worktree.id).")
      return
    }
    guard let paneID = layout.layout.focusedPaneID else {
      terminalLogger.debug("toggleWindowMode: no focused pane in \(worktree.id).")
      return
    }
    let action: LayoutFeature.Action =
      layout.windowedPaneIDs.contains(paneID)
      ? .exitWindowMode(paneID: paneID)
      : .enterWindowMode(paneID: paneID)
    sendLayout(worktree.id, action)
  }

  /// The content's OSC 11 background, nil when unset or unmounted.
  func surfaceBackground(forContent contentID: ContentID) -> NSColor? {
    guard let surface = ContentRuntime.liveValue.renderer(for: contentID) as? GhosttySurfaceView else {
      return nil
    }
    let state = surface.bridge.state
    return Self.osc11BackgroundColor(
      kind: state.colorChangeKind,
      red: state.colorChangeR,
      green: state.colorChangeG,
      blue: state.colorChangeB
    )
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

  /// Routes a layout action targeting the focused pane's selected content.
  private func sendFocusedContentLayoutAction(
    _ worktreeID: Worktree.ID,
    _ action: (ContentID) -> LayoutFeature.Action
  ) {
    guard
      let layout = layoutState(for: worktreeID)?.layout,
      let contentID = layout.focusedPaneID
        .flatMap({ layout.panes[id: $0]?.selectedTab?.content.id })
    else { return }
    sendLayout(worktreeID, action(contentID))
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
    // Unconditional: attach is idempotent and a hydrated layout still needs
    // its minted-title prefix stamped.
    sendTerminals(.attachLayout(worktreeID: worktree.id, titlePrefix: worktree.name))
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
    host.windowedPaneIDs = { [weak self] in self?.layoutState(for: worktree.id)?.windowedPaneIDs ?? [] }
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
    hosts[worktree.id] = host
    // Seed the lifecycle baseline from the hydrated layout, or the first
    // close would diff against an empty set and skip its cleanup; this also
    // starts the dormant watchers for restored contents.
    host.reconcileContentLifecycle()
    terminalLogger.info("Created content host for worktree \(worktree.id)")
    return host
  }

  /// Fires the layout-changed side effects the reducer cannot: persistence,
  /// content lifecycle, surface activity, the pane windows, and the sidebar
  /// projection. Called for every layout action, not only topology changes.
  func handleLayoutChanged(for worktreeID: Worktree.ID) {
    markLayoutDirty(worktreeID: worktreeID)
    hosts[worktreeID]?.reconcileContentLifecycle()
    // Zoom and selection changes flip which surfaces render; re-derive
    // occlusion and focus so hidden panes stop drawing.
    hosts[worktreeID]?.reassertSurfaceActivity()
    scheduleDeferredActivityReassert(for: worktreeID)
    paneWindows.reconcile(worktreeID: worktreeID)
    emitProjection(for: worktreeID)
    emitHasAnyTerminalSurfaceIfNeeded()
  }

  /// Re-derives surface activity once more on the next tick: a structural
  /// rebuild detaches and re-mounts the surviving surfaces, whose detach
  /// clears their local focus, so activity derived against the old hierarchy
  /// must not be the last word.
  private func scheduleDeferredActivityReassert(for worktreeID: Worktree.ID) {
    guard pendingActivityReasserts.insert(worktreeID).inserted else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.pendingActivityReasserts.remove(worktreeID)
      self.hosts[worktreeID]?.reassertSurfaceActivity()
    }
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
    focusing: Bool = true,
    anchor: UUID? = nil
  ) {
    let host = host(for: worktree) { runSetupScriptIfNew }
    // Mint upfront so a title-only request still has a rename target, keeping
    // the documented initial-surface-equals-tab-ID invariant either way.
    let mintedID = tabID ?? UUID()
    guard let layout = layoutState(for: worktree.id)?.layout else {
      // Drain a waiting CLI ack now instead of stranding it until the timeout.
      emit(
        .surfaceCreationFailed(
          worktreeID: worktree.id, attemptedID: mintedID, message: "Could not create the tab."))
      return
    }
    let setupInput = consumeSetupScriptInput(for: worktree, host: host)
    let combinedInput = [setupInput, initialInput].compactMap { $0 }.joined()
    let launch: LaunchOverride? =
      combinedInput.isEmpty ? nil : LaunchOverride(initialInput: combinedInput)
    // A pane-addressed create anchors on the resolved pane (a pane id, or a tab
    // or content it hosts) and inherits its selected content; otherwise the
    // focused pane and surface anchor as before.
    let anchorPane = anchor.flatMap { layout.pane(forToken: $0) }
    let anchorContent = anchorPane.flatMap { pane in
      pane.selectedTabID.flatMap { pane.tabs[id: $0]?.content.id }
    }
    let inheritedFrom = anchorContent ?? host.focusedTab?.content.id
    let paneID = anchorPane?.id ?? layout.focusedPaneID ?? layout.panes.first?.id ?? PaneID()
    let spec = NewTabSpec(
      tabID: TabID(rawValue: mintedID),
      contentID: ContentID(rawValue: mintedID),
      title: "\(worktree.name) \(nextTabIndex(in: layout, prefix: worktree.name))",
      content: .terminal(TerminalContentState(workingDirectory: nil, launch: launch)),
      geometry: ContentRuntime.liveValue.spawnGeometry(near: inheritedFrom, fallback: inheritedFrom),
      select: focusing,
      inheritedFrom: inheritedFrom
    )
    sendLayout(worktree.id, .newTab(inPane: paneID, spec: spec))
    if let customTitle {
      sendLayout(worktree.id, .renameTab(id: TabID(rawValue: mintedID), title: customTitle))
    }
    // A grown strip AND a tab-addressed match: an explicit id colliding with
    // an EXISTING tab or content would otherwise match the old tab and ack a
    // creation that was refused.
    let after = layoutState(for: worktree.id)?.layout
    let created =
      Self.tabCount(in: after) == Self.tabCount(in: layout) + 1
      && after?.panes
        .first { $0.tabs[id: TabID(rawValue: mintedID)] != nil }?
        .tabs[id: TabID(rawValue: mintedID)]?.content.id.rawValue == mintedID
    guard created else {
      // Drain a waiting CLI ack now instead of stranding it until the timeout.
      emit(
        .surfaceCreationFailed(
          worktreeID: worktree.id, attemptedID: mintedID, message: "Could not create the tab."))
      return
    }
    emit(.tabCreated(worktreeID: worktree.id))
    if tabID != nil {
      emit(.surfaceCreated(worktreeID: worktree.id, id: mintedID))
    }
  }

  private static func tabCount(in layout: PaneLayout?) -> Int {
    layout?.panes.reduce(0) { $0 + $1.tabs.count } ?? 0
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
    guard layoutState(for: worktree.id)?.layout.panes.isEmpty != false else {
      // A hydrated layout already has its tabs; a waiting worktree-new ack
      // still needs the signal or it strands until the watchdog.
      emit(.tabCreated(worktreeID: worktree.id))
      return
    }
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
    else {
      if let id {
        emit(
          .surfaceCreationFailed(
            worktreeID: worktree.id, attemptedID: id,
            message: "Could not create the split surface."))
      }
      return
    }
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
    guard let id else { return }
    guard layoutState(for: worktree.id)?.layout.tab(containingContent: ContentID(rawValue: id)) != nil else {
      terminalLogger.warning("splitSurface: failed for surface \(surfaceID) in worktree \(worktree.id).")
      emit(
        .surfaceCreationFailed(
          worktreeID: worktree.id, attemptedID: id,
          message: "Could not create the split surface."))
      return
    }
    emit(.surfaceCreated(worktreeID: worktree.id, id: id))
  }

  // MARK: - Pane-addressed layout ops.

  /// Resolves a CLI / deeplink pane token: a pane's own id, or the id of a
  /// tab or content the pane hosts.
  private func resolvePane(_ token: UUID, in worktreeID: Worktree.ID) -> PaneID? {
    layoutState(for: worktreeID)?.layout.pane(forToken: token)?.id
  }

  /// Whether a pane token (a pane, tab, or content id) resolves to a pane.
  func paneExists(worktreeID: Worktree.ID, token: UUID) -> Bool {
    resolvePane(token, in: worktreeID) != nil
  }

  /// Whether `tab move` is permitted: the tab's pane holds more than one tab
  /// and is not windowed, matching the reducer's `moveTabToSplit` guard.
  func canMoveTabToNewSplit(worktreeID: Worktree.ID, tabID: UUID) -> Bool {
    guard let layoutState = layoutState(for: worktreeID),
      let pane = layoutState.layout.pane(containingTab: TabID(rawValue: tabID))
    else { return false }
    return pane.tabs.count > 1 && !layoutState.windowedPaneIDs.contains(pane.id)
  }

  private func splitPane(  // swiftlint:disable:this function_parameter_count
    in worktree: Worktree,
    paneToken: UUID,
    direction: SplitDirection,
    input: String?,
    id: UUID?,
    focusing: Bool
  ) {
    _ = host(for: worktree)
    func fail() {
      guard let id else { return }
      emit(
        .surfaceCreationFailed(
          worktreeID: worktree.id, attemptedID: id, message: "Could not split the pane."))
    }
    // Panes are never empty, so a resolved pane always has a selected content.
    guard let paneID = resolvePane(paneToken, in: worktree.id),
      let layout = layoutState(for: worktree.id)?.layout,
      let anchorPane = layout.panes[id: paneID],
      let selectedTab = anchorPane.selectedTabID,
      let anchorContent = anchorPane.tabs[id: selectedTab]?.content.id
    else {
      terminalLogger.warning("splitPane: pane token \(paneToken) not found in worktree \(worktree.id).")
      fail()
      return
    }
    // The wake runs even when not focusing: splitting a dormant pane would
    // otherwise land in a frozen layout.
    sendLayout(worktree.id, .wakeTab(id: selectedTab))
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
      .splitPane(id: paneID, direction: direction == .vertical ? .down : .right, spec: spec)
    )
    guard let id else { return }
    guard layoutState(for: worktree.id)?.layout.tab(containingContent: ContentID(rawValue: id)) != nil else {
      terminalLogger.warning("splitPane: failed for pane \(paneID) in worktree \(worktree.id).")
      fail()
      return
    }
    emit(.surfaceCreated(worktreeID: worktree.id, id: id))
  }

  private func focusPane(in worktree: Worktree, paneToken: UUID) {
    guard let paneID = resolvePane(paneToken, in: worktree.id),
      let pane = layoutState(for: worktree.id)?.layout.panes[id: paneID]
    else {
      terminalLogger.warning("focusPane: pane token \(paneToken) not found in worktree \(worktree.id).")
      return
    }
    if let selectedTab = pane.selectedTabID {
      sendLayout(worktree.id, .wakeTab(id: selectedTab))
    }
    sendLayout(worktree.id, .focusPane(.pane(paneID)))
  }

  private func closePane(in worktree: Worktree, paneToken: UUID) {
    guard let paneID = resolvePane(paneToken, in: worktree.id) else {
      terminalLogger.warning("closePane: pane token \(paneToken) not found in worktree \(worktree.id).")
      return
    }
    sendLayout(worktree.id, .closePane(id: paneID))
  }

  private func toggleZoomPane(in worktree: Worktree, paneToken: UUID) {
    guard let paneID = resolvePane(paneToken, in: worktree.id) else {
      terminalLogger.warning("toggleZoomPane: pane token \(paneToken) not found in worktree \(worktree.id).")
      return
    }
    sendLayout(worktree.id, .toggleZoom(paneID: paneID))
  }

  private func toggleWindowModeForPane(in worktree: Worktree, paneToken: UUID) {
    guard let layout = layoutState(for: worktree.id),
      let paneID = resolvePane(paneToken, in: worktree.id)
    else {
      terminalLogger.warning("toggleWindowMode: pane token \(paneToken) not found in worktree \(worktree.id).")
      return
    }
    let action: LayoutFeature.Action =
      layout.windowedPaneIDs.contains(paneID)
      ? .exitWindowMode(paneID: paneID)
      : .enterWindowMode(paneID: paneID)
    sendLayout(worktree.id, action)
  }

  private func moveTabToSplit(
    in worktree: Worktree, tabID: UUID, direction: TerminalSplitMenuDirection, focusing: Bool
  ) {
    let tab = TabID(rawValue: tabID)
    guard let anchorPane = layoutState(for: worktree.id)?.layout.pane(containingTab: tab) else {
      terminalLogger.warning("moveTab: tab \(tabID) not found in worktree \(worktree.id).")
      return
    }
    sendLayout(worktree.id, .wakeTab(id: tab))
    sendLayout(
      worktree.id,
      .moveTabToSplit(id: tab, anchor: anchorPane.id, direction: direction.newSplitDirection, select: focusing)
    )
  }

  /// Pane UUIDs in the worktree, flagging the focused one.
  func listPanes(worktreeID: String) -> [[String: String]]? {
    let decoded = worktreeID.removingPercentEncoding ?? worktreeID
    guard let layoutState = layoutState(for: WorktreeID(decoded)) else { return nil }
    let layout = layoutState.layout
    return layout.panes.map { pane in
      var entry = ["id": pane.id.rawValue.uuidString]
      if pane.id == layout.focusedPaneID { entry["focused"] = "1" }
      return entry
    }
  }

  /// Explicit worktree deletion: drop its layout and sessions whether or not
  /// a host exists (a hydrated worktree the user never selected has none).
  /// Roster prune cannot do this, since a hostless layout could also belong
  /// to a repository that merely failed to load.
  func removeWorktreeLayout(for worktreeID: Worktree.ID, remoteHost: RemoteHost?) {
    let surfaceIDs =
      hosts[worktreeID]?.allSurfaceIDs
      ?? layoutState(for: worktreeID)?.layout.allContentIDs.map(\.rawValue) ?? []
    paneWindows.closeAll(for: worktreeID)
    deleteLayoutSnapshot(worktreeID: worktreeID)
    if let host = hosts.removeValue(forKey: worktreeID) {
      // Watchers stop before the kill.
      host.tearDown()
    }
    for surfaceID in surfaceIDs {
      ContentRuntime.liveValue.remove(ContentID(rawValue: surfaceID), tombstone: false)
    }
    // Global agent presence is keyed by surface id; retract these or the
    // removed worktree's agents linger in the presence UI.
    let closedSurfaceIDs = Set(surfaceIDs)
    if !closedSurfaceIDs.isEmpty {
      emit(.surfacesClosed(worktreeID: worktreeID, closedSurfaceIDs))
    }
    sendTerminals(.detachLayout(worktreeID: worktreeID))
    emit(.worktreeStateTornDown(worktreeID: worktreeID))
    cancelPendingIdleHooks(forSurfaceIDs: closedSurfaceIDs)
    invalidateCaches(forPrunedWorktree: worktreeID)
    emitNotificationIndicatorCountIfNeeded()
    emitHasAnyTerminalSurfaceIfNeeded()
    refreshFocusedSurfaceBackground()
    let remoteSessions = remoteHost.map { host in
      surfaceIDs.map { (host: host, sessionID: ZmxSessionID.make(surfaceID: $0)) }
    }
    killZmxSessions(surfaceIDs.map(ZmxSessionID.make(surfaceID:)), remoteSessions: remoteSessions ?? [])
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
      paneWindows.closeAll(for: id)
      deleteLayoutSnapshot(worktreeID: id)
      let closedSurfaceIDs = Set(host.allSurfaceIDs)
      // Watchers stop before the kill; the contents drop from the runtime.
      host.tearDown()
      for surfaceID in closedSurfaceIDs {
        ContentRuntime.liveValue.remove(ContentID(rawValue: surfaceID), tombstone: false)
      }
      // Global agent presence is keyed by surface id; retract the pruned
      // surfaces or archived / deleted agents linger in the presence UI.
      if !closedSurfaceIDs.isEmpty {
        emit(.surfacesClosed(worktreeID: id, closedSurfaceIDs))
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
    layoutFlushGeneration += 1
    let generation = layoutFlushGeneration
    let task = Task { [weak self] in
      await writer.flush(records: [worktreeID.rawValue: change])
      // Generation-gated: an older task's completion must not erase a newer
      // registration, or a delete could stop awaiting the in-flight record.
      guard let self, self.layoutFlushTasks[worktreeID]?.generation == generation else { return }
      self.layoutFlushTasks[worktreeID] = nil
    }
    layoutFlushTasks[worktreeID] = (generation, task)
  }

  /// Removes `worktreeID` from disk immediately, bypassing the debounce and
  /// cancelling any queued positive save so a stale snapshot can't resurrect a
  /// removed worktree. Awaits any in-flight positive flush for the key first so
  /// the `.delete` always reaches the writer after the record.
  private func deleteLayoutSnapshot(worktreeID: Worktree.ID) {
    layoutDirtyTasks[worktreeID]?.cancel()
    layoutDirtyTasks[worktreeID] = nil
    let inflightFlush = layoutFlushTasks[worktreeID]?.task
    let writer = layoutsWriter
    layoutFlushGeneration += 1
    let generation = layoutFlushGeneration
    let task = Task { [weak self] in
      await inflightFlush?.value
      await writer.flush(records: [worktreeID.rawValue: .delete])
      guard let self, self.layoutFlushTasks[worktreeID]?.generation == generation else { return }
      self.layoutFlushTasks[worktreeID] = nil
    }
    layoutFlushTasks[worktreeID] = (generation, task)
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
    for entry in layoutFlushTasks.values { entry.task.cancel() }
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
