import AppKit
import Dependencies
import Foundation
import GhosttyKit
import IdentifiedCollections
import Sharing
import SupacodeSettingsShared

/// Per-worktree cross-feature host on the layout engine: notifications, agent
/// presence, task status, focus and occlusion, window-tint reads, blocking
/// scripts, and dormant-session plumbing. Topology lives in `LayoutFeature`;
/// the host reads it through the injected closure and requests mutations
/// through layout actions, never directly.
@MainActor
@Observable
final class WorktreeContentHost {
  let worktree: Worktree

  // MARK: - Wiring.

  @ObservationIgnored var isSelected: () -> Bool = { false }
  /// The worktree's current pane topology; nil before hydration.
  @ObservationIgnored var layout: () -> PaneLayout? = { nil }
  /// Panes rendering in their own windows; their surfaces' activity keys off
  /// those windows, not the main one.
  @ObservationIgnored var windowedPaneIDs: () -> Set<PaneID> = { [] }
  /// Routes a topology mutation into the worktree's `LayoutFeature`.
  @ObservationIgnored var sendLayoutAction: (LayoutFeature.Action) -> Void = { _ in }
  @ObservationIgnored var onNotificationReceived: ((UUID, String, String, Bool) -> Void)?
  @ObservationIgnored var onNotificationIndicatorChanged: (() -> Void)?
  @ObservationIgnored var onFocusChanged: ((UUID) -> Void)?
  @ObservationIgnored var onFocusedSurfaceColorChanged: (() -> Void)?
  @ObservationIgnored var onTaskStatusChanged: ((WorktreeTaskStatus) -> Void)?
  @ObservationIgnored var onBlockingScriptCompleted: ((BlockingScriptKind, Int?, TabID?) -> Void)?
  @ObservationIgnored var onRunningScriptsChanged: (() -> Void)?
  @ObservationIgnored var onCommandPaletteToggle: (() -> Void)?
  @ObservationIgnored var onSetupScriptConsumed: (() -> Void)?
  @ObservationIgnored var onSurfacesClosed: ((Set<UUID>) -> Void)?
  @ObservationIgnored var onSurfacesHibernated: ((Set<UUID>) -> Void)?
  @ObservationIgnored var onDormancyChanged: (() -> Void)?
  @ObservationIgnored var onAgentHookEvent: ((AgentHookEvent) -> Void)?

  var socketPath: String?
  var notificationsEnabled = true

  // MARK: - Private state.

  @ObservationIgnored private let runtime: ContentRuntime
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private(set) var notifications: [WorktreeTerminalNotification] = []
  /// Per-content unseen counters; the per-instance counter is the observed
  /// leaf signal, the dictionary itself must not fan out invalidation.
  @ObservationIgnored private(set) var surfaceStates: [UUID: WorktreeSurfaceState] = [:]
  @ObservationIgnored private var lastCustomNotificationAt: [UUID: any InstantProtocol<Duration>] = [:]
  @ObservationIgnored private var pendingAgentOSCNotifications: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var lastEmittedFocusSurfaceId: UUID?
  @ObservationIgnored private(set) var isWorktreeSelected = false
  private var lastWindowIsKey: Bool?
  private var lastWindowIsVisible: Bool?
  @ObservationIgnored private var lastReportedTaskStatus: WorktreeTaskStatus?
  @ObservationIgnored private var lastTabProgressDisplays: [TabID: TerminalTabProgressDisplay?] = [:]
  /// Contents the user explicitly closed; consumed when the close completes so
  /// an unexpected zmx exit is never misread as explicit.
  @ObservationIgnored private(set) var pendingExplicitSurfaceCloseIDs: Set<UUID> = []
  /// Programmatic destroys (deeplink / CLI) that skip the alert.
  @ObservationIgnored private var bypassCloseConfirmationSurfaceIDs: Set<UUID> = []
  @ObservationIgnored private let dormantSessionWatchers = ZmxSessionWatcherRegistry()
  @ObservationIgnored private var pendingRunningScriptsProjectionEmit = false
  /// Layout-diff bookkeeping for `reconcileContentLifecycle`: the content set
  /// and its dormant subset as of the last sweep.
  @ObservationIgnored private var lastSweptContentIDs: Set<UUID> = []
  @ObservationIgnored private var lastDormantContentIDs: Set<UUID> = []
  @ObservationIgnored var hibernationAgentsBySurface: (() -> [UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]])?

  /// Tabs running (or having run) a blocking script; every mutation schedules
  /// a coalesced running-scripts emit so mid-operation states never reach TCA.
  private var blockingScripts: [TabID: BlockingScriptKind] = [:] {
    didSet { scheduleRunningScriptsProjectionEmit() }
  }
  @ObservationIgnored private var blockingScriptLaunchDirectories: [TabID: URL] = [:]
  @ObservationIgnored private var lastBlockingScriptTabByKind: [BlockingScriptKind: TabID] = [:]
  /// Blocking tabs whose script already finished; their parked shell must not
  /// count as busy nor confirm on close.
  @ObservationIgnored private(set) var completedBlockingScriptTabs: Set<TabID> = [] {
    didSet {
      for tabID in oldValue.symmetricDifference(completedBlockingScriptTabs) {
        terminalChrome(for: tabID)?.isLocked = completedBlockingScriptTabs.contains(tabID)
      }
    }
  }
  @ObservationIgnored private var pendingSetupScript: Bool

  private static let logger = SupaLogger("WorktreeContentHost")

  init(
    worktree: Worktree,
    runtime: ContentRuntime,
    clock: any Clock<Duration>,
    runSetupScript: Bool
  ) {
    self.worktree = worktree
    self.runtime = runtime
    self.clock = clock
    self.pendingSetupScript = runSetupScript
    dormantSessionWatchers.onOSCSequence = { [weak self] surfaceID, sequence in
      self?.handleDormantOSCSequence(surfaceID: surfaceID, sequence: sequence)
    }
  }

  // Standardized to match `loadFailuresByID` keys (built from
  // `standardizedFileURL.path`) so prune protection lines up.
  var repositoryID: Repository.ID {
    switch worktree.location.repositoryLocation {
    case .local(let url):
      RepositoryID(url.standardizedFileURL.path(percentEncoded: false))
    case .remote:
      worktree.location.repositoryLocation.id
    }
  }

  /// Tracked blocking tabs whose kind matches.
  func blockingScriptTabs(matching predicate: (BlockingScriptKind) -> Bool) -> [TabID] {
    blockingScripts.filter { predicate($0.value) }.map(\.key)
  }

  // MARK: - Topology reads.

  /// The focused pane's selected tab, the worktree's "current" tab.
  var focusedTab: TabItem? {
    guard let layout = layout(), let focused = layout.focusedPaneID else { return nil }
    return layout.panes[id: focused]?.selectedTab
  }

  /// The focused pane's selected tab's content id, the worktree's focused
  /// surface.
  var focusedContentID: UUID? {
    focusedTab?.content.id.rawValue
  }

  func tab(withID tabID: TabID) -> TabItem? {
    layout()?.pane(containingTab: tabID)?.tabs[id: tabID]
  }

  func tabID(containing surfaceID: UUID) -> TabID? {
    layout()?.tab(containingContent: ContentID(rawValue: surfaceID))?.tab.id
  }

  /// Every content id in the layout, live or hibernated.
  var allSurfaceIDs: [UUID] {
    layout()?.allContentIDs.map(\.rawValue) ?? []
  }

  var hasAnySurface: Bool {
    !(layout()?.panes.isEmpty ?? true)
  }

  /// A content is known while its tab exists, live or hibernated.
  func isKnownSurface(_ surfaceID: UUID) -> Bool {
    layout()?.tab(containingContent: ContentID(rawValue: surfaceID)) != nil
  }

  func hasSurfaceAnywhere(_ surfaceID: UUID) -> Bool {
    isKnownSurface(surfaceID)
  }

  /// The live surface view behind a content, nil when hibernated or unknown.
  func liveSurface(_ surfaceID: UUID) -> GhosttySurfaceView? {
    runtime.renderer(for: ContentID(rawValue: surfaceID)) as? GhosttySurfaceView
  }

  /// A content is hibernated when its tab exists but no live renderer does.
  /// Renderer existence, not the terminal cast: a non-terminal renderer is
  /// still live.
  func isDormantSurface(_ surfaceID: UUID) -> Bool {
    isKnownSurface(surfaceID) && runtime.renderer(for: ContentID(rawValue: surfaceID)) == nil
  }

  var allTabsDormant: Bool {
    guard let layout = layout(), !layout.panes.isEmpty else { return false }
    return layout.panes.allSatisfy { pane in
      pane.tabs.allSatisfy { liveSurface($0.content.id.rawValue) == nil }
    }
  }

  /// Whether a content's tab is a rendering pane's selected tab. Zoom-aware:
  /// while a pane is zoomed, every other pane is hidden.
  private func isVisibleSurface(_ surfaceID: UUID) -> Bool {
    guard let layout = layout() else { return false }
    let visiblePanes = Set(layout.tree.visibleLeaves())
    return layout.panes.contains { pane in
      visiblePanes.contains(pane.id) && pane.selectedTab?.content.id.rawValue == surfaceID
    }
  }

  private func isFocusedSurface(_ surfaceID: UUID) -> Bool {
    focusedContentID == surfaceID
  }

  /// All five must hold for an arriving notification to be born read. A
  /// windowed pane's surface keys off its own window, not the main one.
  private func isViewedSurface(_ surfaceID: UUID) -> Bool {
    guard isFocusedSurface(surfaceID) else { return false }
    if let pane = layout()?.panes.first(where: { $0.selectedTab?.content.id.rawValue == surfaceID }),
      windowedPaneIDs().contains(pane.id)
    {
      guard let window = liveSurface(surfaceID)?.window else { return false }
      return window.isKeyWindow && window.occlusionState.contains(.visible)
    }
    return isSelected()
      && isVisibleSurface(surfaceID)
      && lastWindowIsKey == true
      && lastWindowIsVisible == true
  }

  /// Mints the per-content unseen counter exactly once, so a woken content
  /// re-adopts its preserved counter.
  func registerSurfaceState(for surfaceID: UUID) {
    guard surfaceStates[surfaceID] == nil else { return }
    surfaceStates[surfaceID] = WorktreeSurfaceState()
  }

  // MARK: - Notifications: derived accessors.

  var hasUnseenNotification: Bool {
    surfaceStates.values.contains { $0.unseenNotificationCount > 0 }
  }

  var totalUnseenNotificationCount: Int {
    surfaceStates.values.reduce(0) { $0 + $1.unseenNotificationCount }
  }

  func hasUnseenNotification(forSurfaceID surfaceID: UUID) -> Bool {
    (surfaceStates[surfaceID]?.unseenNotificationCount ?? 0) > 0
  }

  func unseenNotificationCount(forTabID tabID: TabID) -> Int {
    guard let contentID = tab(withID: tabID)?.content.id.rawValue else { return 0 }
    return surfaceStates[contentID]?.unseenNotificationCount ?? 0
  }

  func latestUnreadNotification() -> WorktreeTerminalNotification? {
    unreadNotifications().first
  }

  func unreadNotifications() -> [WorktreeTerminalNotification] {
    notifications.filter { !$0.isRead }.sorted { $0.createdAt > $1.createdAt }
  }

  // MARK: - Notifications: commit point.

  /// The single commit point: mutate log and counter first, then emit. The
  /// received callback fires even when notifications are disabled.
  func appendNotification(title: String, body: String, surfaceID: UUID) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !(trimmedTitle.isEmpty && trimmedBody.isEmpty) else { return }
    let isViewed = isViewedSurface(surfaceID)
    if notificationsEnabled {
      @Dependency(\.date.now) var now
      notifications.insert(
        WorktreeTerminalNotification(
          surfaceID: surfaceID,
          title: trimmedTitle,
          body: trimmedBody,
          createdAt: now,
          isRead: isViewed
        ),
        at: 0
      )
      if !isViewed {
        incrementUnseenCount(surfaceID)
      }
      _ = trimNotificationsToRetentionLimit()
      emitNotificationStateChanged()
    }
    onNotificationReceived?(surfaceID, trimmedTitle, trimmedBody, isViewed)
  }

  /// Custom (hook / OSC 3008 notify) source; supersedes any held OSC 9.
  func appendHookNotification(title: String, body: String, surfaceID: UUID) {
    guard isKnownSurface(surfaceID) else {
      Self.logger.debug("Dropped hook notification for unknown surface \(surfaceID) in worktree \(worktree.id)")
      return
    }
    lastCustomNotificationAt[surfaceID] = clock.now
    if let held = pendingAgentOSCNotifications.removeValue(forKey: surfaceID) {
      held.cancel()
      Self.logger.debug("Custom notification superseded a held OSC 9 for surface \(surfaceID)")
    }
    appendNotification(title: title, body: body, surfaceID: surfaceID)
  }

  /// The agent's own OSC 9: dropped inside the post-custom suppression window,
  /// otherwise held briefly so a richer custom notify can supersede it.
  func handleAgentOSCNotification(title: String, body: String, surfaceID: UUID) {
    if let lastCustom = lastCustomNotificationAt[surfaceID],
      AgentSignal.elapsed(from: lastCustom, to: clock.now)
        <= .seconds(AgentSignal.oscSuppressionAfterCustom)
    {
      Self.logger.debug("Dropped OSC 9 within the custom-notification window for surface \(surfaceID)")
      return
    }
    pendingAgentOSCNotifications[surfaceID]?.cancel()
    pendingAgentOSCNotifications[surfaceID] = Task { [weak self, clock] in
      do {
        try await clock.sleep(for: .seconds(AgentSignal.oscHoldWindow))
      } catch is CancellationError {
        return
      } catch {
        Self.logger.error("OSC 9 hold sleep failed: \(error)")
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.pendingAgentOSCNotifications.removeValue(forKey: surfaceID)
      guard self.isKnownSurface(surfaceID) else { return }
      self.appendNotification(title: title, body: body, surfaceID: surfaceID)
    }
  }

  // MARK: - Notifications: read and dismiss.

  func markAllNotificationsRead() {
    for index in notifications.indices {
      notifications[index].isRead = true
    }
    clearAllUnseenCounters()
    emitNotificationStateChanged()
  }

  func clearNotificationIndicator() {
    markAllNotificationsRead()
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    notificationsEnabled = enabled
    if !enabled {
      markAllNotificationsRead()
    }
  }

  func markNotificationsRead(forSurfaceID surfaceID: UUID) {
    for index in notifications.indices where notifications[index].surfaceID == surfaceID {
      notifications[index].isRead = true
    }
    setUnseenCount(surfaceID, to: 0)
    emitNotificationStateChanged()
  }

  func markNotificationRead(id notificationID: WorktreeTerminalNotification.ID) {
    guard let index = notifications.firstIndex(where: { $0.id == notificationID }),
      !notifications[index].isRead
    else { return }
    notifications[index].isRead = true
    decrementUnseenCount(notifications[index].surfaceID)
    emitNotificationStateChanged()
  }

  func dismissNotification(_ notificationID: WorktreeTerminalNotification.ID) {
    guard let index = notifications.firstIndex(where: { $0.id == notificationID }) else { return }
    let removed = notifications.remove(at: index)
    if !removed.isRead {
      decrementUnseenCount(removed.surfaceID)
    }
    emitNotificationStateChanged()
  }

  func dismissAllNotifications() {
    notifications.removeAll()
    clearAllUnseenCounters()
    emitNotificationStateChanged()
  }

  func enforceNotificationRetentionLimit() {
    guard trimNotificationsToRetentionLimit() else { return }
    emitNotificationStateChanged()
  }

  /// Evicts read entries before unread regardless of age, oldest first within
  /// each class. Never touches unseen counters.
  private func trimNotificationsToRetentionLimit() -> Bool {
    @Shared(.settingsFile) var settingsFile: SettingsFile
    let limit = settingsFile.global.notificationRetentionLimit.limit
    guard notifications.count > limit else { return false }
    var excess = notifications.count - limit
    var kept: [WorktreeTerminalNotification] = []
    // The log is newest-first; walk oldest-first so age order decides ties.
    for entry in notifications.reversed() {
      if excess > 0, entry.isRead {
        excess -= 1
      } else {
        kept.append(entry)
      }
    }
    if excess > 0 {
      // Still over the limit means every survivor is unread; drop the oldest.
      kept.removeFirst(min(excess, kept.count))
    }
    notifications = kept.reversed()
    return true
  }

  private func incrementUnseenCount(_ surfaceID: UUID) {
    surfaceStates[surfaceID]?.unseenNotificationCount += 1
  }

  private func decrementUnseenCount(_ surfaceID: UUID) {
    guard let state = surfaceStates[surfaceID] else { return }
    state.unseenNotificationCount = max(0, state.unseenNotificationCount - 1)
  }

  private func setUnseenCount(_ surfaceID: UUID, to value: Int) {
    guard let state = surfaceStates[surfaceID], state.unseenNotificationCount != value else { return }
    state.unseenNotificationCount = value
  }

  private func clearAllUnseenCounters() {
    for state in surfaceStates.values {
      state.unseenNotificationCount = 0
    }
  }

  /// Deliberately ungated: the projection carries per-item read state, and
  /// gating broke dismiss and mark-read of already-read items.
  private func emitNotificationStateChanged() {
    onNotificationIndicatorChanged?()
  }

  // MARK: - Agent presence + context signals.

  func handleContextSignal(surfaceID: UUID, id: String, metadata: String) {
    if AgentPresenceOSC.isNotifyMetadata(metadata) {
      handleNotifySignal(surfaceID: surfaceID, id: id, metadata: metadata)
    } else {
      handlePresenceSignal(surfaceID: surfaceID, id: id, metadata: metadata)
    }
  }

  private func handlePresenceSignal(surfaceID: UUID, id: String, metadata: String) {
    switch AgentSignal.presenceEvent(
      id: id,
      metadata: metadata,
      surfaceID: surfaceID,
      surfaceExists: isKnownSurface(surfaceID)
    ) {
    case .success(let event):
      onAgentHookEvent?(event)
    case .failure(.unknownSurface):
      Self.logger.debug("Dropped presence signal for unknown surface \(surfaceID)")
    case .failure(.parseFailed):
      Self.logger.warning("Dropped malformed presence signal (\(metadata.utf8.count) metadata bytes)")
    }
  }

  private func handleNotifySignal(surfaceID: UUID, id: String, metadata: String) {
    switch AgentSignal.notification(
      id: id,
      metadata: metadata,
      surfaceExists: isKnownSurface(surfaceID)
    ) {
    case .success(let resolved):
      @Shared(.settingsFile) var settingsFile: SettingsFile
      guard settingsFile.global.richAgentNotificationsEnabled else { return }
      if resolved.body.isEmpty, resolved.wireBodyByteCount > 0 {
        Self.logger.warning("Notify body decoded empty from \(resolved.wireBodyByteCount) wire bytes")
      }
      appendHookNotification(title: resolved.title, body: resolved.body, surfaceID: surfaceID)
    case .failure(.parseFailed):
      Self.logger.warning("Dropped malformed notify signal (\(metadata.utf8.count) metadata bytes)")
    case .failure(.unknownSurface), .failure(.empty):
      Self.logger.debug("Dropped notify signal for surface \(surfaceID)")
    }
  }

  // MARK: - Task status + progress.

  var taskStatus: WorktreeTaskStatus {
    guard let layout = layout() else { return .idle }
    let busy = layout.panes.contains { pane in
      pane.tabs.contains { isTabActivityBusy($0) }
    }
    return busy ? .running : .idle
  }

  private func isTabActivityBusy(_ tab: TabItem) -> Bool {
    guard liveSurface(tab.content.id.rawValue) != nil else { return false }
    guard !completedBlockingScriptTabs.contains(tab.id) else { return false }
    if blockingScripts[tab.id] != nil { return true }
    return hasRunningProgress(in: tab)
  }

  private func hasRunningProgress(in tab: TabItem) -> Bool {
    guard let surface = liveSurface(tab.content.id.rawValue) else { return false }
    return Self.isRunningProgressState(surface.bridge.state.progressState)
  }

  private static func isRunningProgressState(_ state: ghostty_action_progress_report_state_e?) -> Bool {
    switch state {
    case GHOSTTY_PROGRESS_STATE_SET, GHOSTTY_PROGRESS_STATE_INDETERMINATE,
      GHOSTTY_PROGRESS_STATE_PAUSE, GHOSTTY_PROGRESS_STATE_ERROR:
      true
    default:
      false
    }
  }

  /// Progress or busy state moved for a tab's content.
  func updateRunningState(for tabID: TabID) {
    guard tab(withID: tabID) != nil else { return }
    emitTabProgressDisplay(for: tabID)
    emitTaskStatusIfChanged()
  }

  private func computeTabProgressDisplay(for tabID: TabID) -> TerminalTabProgressDisplay? {
    guard let tab = tab(withID: tabID), let surface = liveSurface(tab.content.id.rawValue) else { return nil }
    return TerminalTabProgressDisplay.make(
      progressState: surface.bridge.state.progressState,
      progressValue: surface.bridge.state.progressValue
    )
  }

  func emitTabProgressDisplay(for tabID: TabID) {
    let display = computeTabProgressDisplay(for: tabID)
    guard lastTabProgressDisplays[tabID] != display else { return }
    lastTabProgressDisplays[tabID] = display
    terminalChrome(for: tabID)?.progress = display
  }

  /// The tab's content-owned strip chrome, nil for non-terminal contents.
  private func terminalChrome(for tabID: TabID) -> TerminalTabChrome? {
    guard let contentID = tab(withID: tabID)?.content.id else { return nil }
    return runtime.content(for: contentID)?.chrome as? TerminalTabChrome
  }

  func emitTaskStatusIfChanged() {
    let status = taskStatus
    guard status != lastReportedTaskStatus else { return }
    lastReportedTaskStatus = status
    onTaskStatusChanged?(status)
  }

  // MARK: - Sidebar projection.

  func currentProjection() -> WorktreeRowProjection {
    WorktreeRowProjection(
      surfaceIDs: allSurfaceIDs,
      isProgressBusy: taskStatus == .running,
      hasUnseenNotifications: hasUnseenNotification,
      notifications: IdentifiedArray(uniqueElements: notifications),
      unseenSurfaces: unseenSurfacesProjection(),
      runningScripts: runningScriptsProjection(),
      allTabsDormant: allTabsDormant
    )
  }

  private func unseenSurfacesProjection() -> [WorktreeUnseenSurface] {
    surfaceStates
      .compactMap { id, state in
        state.unseenNotificationCount > 0
          ? WorktreeUnseenSurface(id: id, count: state.unseenNotificationCount)
          : nil
      }
      .sorted { $0.id.uuidString < $1.id.uuidString }
  }

  private func runningScriptsProjection() -> IdentifiedArrayOf<SidebarItemFeature.State.RunningScript> {
    let scripts = blockingScripts.values
      .compactMap { kind -> ScriptDefinition? in
        guard case .script(let definition) = kind else { return nil }
        return definition
      }
      .sorted { $0.id.uuidString < $1.id.uuidString }
      .map { SidebarItemFeature.State.RunningScript(id: $0.id, tint: $0.resolvedTintColor) }
    return IdentifiedArray(uniqueElements: scripts)
  }

  /// Coalesces every blocking-script mutation into one next-tick emit so
  /// mid-operation states never reach TCA.
  private func scheduleRunningScriptsProjectionEmit() {
    guard !pendingRunningScriptsProjectionEmit else { return }
    pendingRunningScriptsProjectionEmit = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.pendingRunningScriptsProjectionEmit = false
      self.onRunningScriptsChanged?()
    }
  }

  // MARK: - Focus + occlusion.

  func syncFocus(windowIsKey: Bool, windowIsVisible: Bool) {
    if lastWindowIsKey != windowIsKey || lastWindowIsVisible != windowIsVisible {
      Self.logger.debug("Window activity: key=\(windowIsKey) visible=\(windowIsVisible)")
    }
    lastWindowIsKey = windowIsKey
    lastWindowIsVisible = windowIsVisible
    applySurfaceActivity()
  }

  /// Re-derives per-content occlusion and focus from the main-window
  /// observer, or from a windowed pane's own window. Unknown visibility FAILS
  /// OPEN: occluding a visible surface freezes it, rendering a briefly
  /// occluded one only costs frames.
  func applySurfaceActivity() {
    guard let layout = layout() else { return }
    let selected = isWorktreeSelected
    let visiblePanes = Set(layout.tree.visibleLeaves())
    let windowedPanes = windowedPaneIDs()
    var focusTarget: GhosttySurfaceView?
    for pane in layout.panes {
      for tab in pane.tabs {
        guard let surface = liveSurface(tab.content.id.rawValue) else { continue }
        let isSelectedTab = pane.selectedTabID == tab.id
        let isVisible: Bool
        let isKeyed: Bool
        if windowedPanes.contains(pane.id) {
          // A windowed pane floats over any worktree; its own window drives
          // visibility and key state, not the main-window observer. A surface
          // not yet mounted fails open; the occlusion notification corrects
          // the first-display transient.
          let windowShowsContent = surface.window.map {
            $0.isVisible && $0.occlusionState.contains(.visible)
          }
          isVisible = isSelectedTab && windowShowsContent != false
          isKeyed = surface.window?.isKeyWindow == true
        } else {
          isVisible =
            selected && visiblePanes.contains(pane.id) && isSelectedTab
            && lastWindowIsVisible != false
          isKeyed = lastWindowIsKey == true
        }
        let isFocused = isVisible && isKeyed && focusedContentID == tab.content.id.rawValue
        surface.setOcclusion(isVisible)
        surface.focusDidChange(isFocused)
        if isFocused {
          focusTarget = surface
        }
      }
    }
    // Re-assert AppKit focus only when a terminal already held it.
    if let focusTarget, let window = focusTarget.window, window.firstResponder is GhosttySurfaceView {
      window.makeFirstResponder(focusTarget)
    }
  }

  func reassertSurfaceActivity() {
    applySurfaceActivity()
  }

  func setAllSurfacesOccluded() {
    guard let layout = layout() else { return }
    let windowedPanes = windowedPaneIDs()
    for pane in layout.panes {
      // A windowed pane keeps rendering across worktree switches.
      guard !windowedPanes.contains(pane.id) else { continue }
      for tab in pane.tabs {
        guard let surface = liveSurface(tab.content.id.rawValue) else { continue }
        surface.setOcclusion(false)
        surface.focusDidChange(false)
      }
    }
  }

  func setWorktreeSelected(_ selected: Bool) {
    guard isWorktreeSelected != selected else { return }
    isWorktreeSelected = selected
    reassertSurfaceActivity()
  }

  /// A content took focus: clear its unread, refresh the tab title, and emit.
  func recordActiveSurface(_ surfaceID: UUID) {
    markNotificationsRead(forSurfaceID: surfaceID)
    // The tab lookup gates on membership: a mid-close focus flap must not
    // retitle a tab the content no longer belongs to.
    if tabID(containing: surfaceID) != nil,
      let title = liveSurface(surfaceID)?.bridge.state.title, !title.isEmpty
    {
      sendLayoutAction(.runtime(.titleChanged(id: ContentID(rawValue: surfaceID), title: title)))
    }
    emitFocusChangedIfNeeded(surfaceID)
  }

  private func emitFocusChangedIfNeeded(_ surfaceID: UUID) {
    guard lastEmittedFocusSurfaceId != surfaceID else { return }
    lastEmittedFocusSurfaceId = surfaceID
    onFocusChanged?(surfaceID)
  }

  /// Clears the focus dedupe so returning to this worktree re-emits.
  func forgetLastEmittedFocus() {
    lastEmittedFocusSurfaceId = nil
  }

  func focusSelectedTab() {
    guard let contentID = focusedContentID, let surface = liveSurface(contentID) else { return }
    surface.requestFocus()
  }

  func focusAndInsertText(_ text: String) {
    guard let contentID = focusedContentID, let surface = liveSurface(contentID) else {
      Self.logger.warning("focusAndInsertText: no focused surface")
      return
    }
    Self.logger.info("focusAndInsertText: inserting \(text.count) characters")
    surface.requestFocus()
    surface.sendText(text)
  }

  /// Whether a content may claim AppKit first responder.
  func shouldClaimFocus(_ surfaceID: UUID) -> Bool {
    focusedContentID == surfaceID
  }

  /// Cross-tab focus by content id (deeplinks, unread jumps): wake and select
  /// the owning tab, then hand the surface AppKit focus.
  @discardableResult
  func focusSurface(id surfaceID: UUID) -> Bool {
    guard let tabID = tabID(containing: surfaceID) else {
      Self.logger.warning("focusSurface: surface \(surfaceID) has no owning tab.")
      return false
    }
    sendLayoutAction(.wakeTab(id: tabID))
    sendLayoutAction(.selectTab(id: tabID))
    guard let surface = liveSurface(surfaceID) else { return false }
    surface.requestFocus()
    return true
  }

  // MARK: - Window tint.

  /// The focused content's bridge state, driving the window tint.
  func focusedSurfaceState() -> GhosttySurfaceState? {
    guard let contentID = focusedContentID else { return nil }
    return liveSurface(contentID)?.bridge.state
  }

  /// Only the focused content drives the window tint.
  func handleSurfaceColorChanged(_ surfaceID: UUID) {
    guard focusedContentID == surfaceID else { return }
    onFocusedSurfaceColorChanged?()
  }

  // MARK: - Binding actions + search.

  @discardableResult
  func performBindingActionOnFocusedSurface(_ action: String) -> Bool {
    guard let contentID = focusedContentID, let surface = liveSurface(contentID) else { return false }
    performBindingAction(action, on: surface)
    return true
  }

  @discardableResult
  func performBindingAction(_ action: String, onSurfaceID surfaceID: UUID) -> Bool {
    guard let surface = liveSurface(surfaceID) else { return false }
    performBindingAction(action, on: surface)
    return true
  }

  private func performBindingAction(_ action: String, on surface: GhosttySurfaceView) {
    // Tag explicit closes so an unexpected zmx exit is never misread.
    if action == "close_surface" {
      pendingExplicitSurfaceCloseIDs.insert(surface.id)
    }
    surface.performBindingAction(action)
  }

  @discardableResult
  func navigateSearchOnFocusedSurface(_ direction: GhosttySearchDirection) -> Bool {
    guard let contentID = focusedContentID, let surface = liveSurface(contentID) else { return false }
    surface.navigateSearch(direction)
    return true
  }

  @discardableResult
  func setImagePasteAgents(_ agents: Set<SkillAgent>, onSurfaceID surfaceID: UUID) -> Bool {
    guard let surface = liveSurface(surfaceID) else { return false }
    surface.imagePasteAgents = agents
    return true
  }

  // MARK: - Setup script.

  func needsSetupScript() -> Bool {
    pendingSetupScript
  }

  /// Re-arm only when the layout is empty, idempotent when already pending.
  func enableSetupScriptIfNeeded() {
    guard !pendingSetupScript, layout()?.panes.isEmpty != false else { return }
    pendingSetupScript = true
  }

  /// Consumes the pending setup flag; the caller runs the script.
  func consumeSetupScript() -> Bool {
    guard pendingSetupScript else { return false }
    pendingSetupScript = false
    onSetupScriptConsumed?()
    return true
  }

  func markSetupScriptSkipped() {
    pendingSetupScript = false
  }

  // MARK: - Blocking scripts.

  func isBlockingScriptRunning(kind: BlockingScriptKind) -> Bool {
    blockingScripts.values.contains(kind)
  }

  var hasInflightBlockingScripts: Bool {
    !blockingScripts.isEmpty
  }

  func runningScriptDefinitionIDs() -> Set<UUID> {
    Set(
      blockingScripts.values.compactMap { kind -> UUID? in
        guard case .script(let definition) = kind else { return nil }
        return definition.id
      }
    )
  }

  func isScriptRunning(definitionID: UUID) -> Bool {
    runningScriptDefinitionIDs().contains(definitionID)
  }

  func isBlockingScript(_ tabID: TabID) -> Bool {
    blockingScripts[tabID] != nil || completedBlockingScriptTabs.contains(tabID)
  }

  func isBlockingScriptCompleted(_ tabID: TabID) -> Bool {
    completedBlockingScriptTabs.contains(tabID)
  }

  func blockingScriptKind(for tabID: TabID) -> BlockingScriptKind? {
    blockingScripts[tabID]
  }

  func trackedBlockingScriptTab(for kind: BlockingScriptKind) -> TabID? {
    blockingScripts.first { $0.value == kind }?.key
  }

  func lingeringBlockingScriptTab(for kind: BlockingScriptKind) -> TabID? {
    lastBlockingScriptTabByKind[kind]
  }

  /// Whether the content belongs to a completed blocking tab, whose parked
  /// runner keeps reporting a close-confirmation no live work justifies.
  func isFrozenBlockingScriptSurface(_ surfaceID: UUID) -> Bool {
    guard let tabID = tabID(containing: surfaceID) else { return false }
    return completedBlockingScriptTabs.contains(tabID)
  }

  /// Records a launched blocking tab; the tracking must exist BEFORE the
  /// surface builds so the environment markers resolve.
  func trackBlockingScript(
    kind: BlockingScriptKind,
    tabID: TabID,
    launchDirectory: URL?
  ) {
    blockingScripts[tabID] = kind
    lastBlockingScriptTabByKind[kind] = tabID
    if let launchDirectory {
      blockingScriptLaunchDirectories[tabID] = launchDirectory
    }
    completedBlockingScriptTabs.remove(tabID)
    emitTaskStatusIfChanged()
  }

  func blockingScriptEnvironment(for tabID: TabID) -> [String: String] {
    guard let kind = blockingScripts[tabID] else { return [:] }
    let scope: ScriptScope? =
      if case .script(let definition) = kind {
        scriptScope(forDefinitionID: definition.id)
      } else {
        nil
      }
    return kind.surfaceEnvironmentVariables(scope: scope)
  }

  private func scriptScope(forDefinitionID id: UUID) -> ScriptScope? {
    @Shared(.repositorySettings(worktree.repositoryRootURL, host: worktree.host)) var settings
    if settings.scripts.contains(where: { $0.id == id }) { return .repo }
    @Shared(.settingsFile) var settingsFile: SettingsFile
    if settingsFile.global.globalScripts.contains(where: { $0.id == id }) { return .global }
    return nil
  }

  /// The command finished; the shell stays alive for output inspection.
  func handleBlockingScriptCommandFinished(tabID: TabID, exitCode: Int?) {
    guard let kind = blockingScripts.removeValue(forKey: tabID) else { return }
    Self.logger.info("Blocking script \(kind.tabTitle) finished with exit \(exitCode.map(String.init) ?? "nil")")
    completeBlockingScript(kind, tabID: tabID, exitCode: exitCode, reportedTabID: tabID)
  }

  /// The shell itself exited before the command finished (cancellation), or
  /// the remote connection dropped, where exit codes are unreliable.
  func handleBlockingScriptChildExited(tabID: TabID, exitCode: UInt32) {
    guard let kind = blockingScripts.removeValue(forKey: tabID) else { return }
    if worktree.host != nil {
      Self.logger.warning("Remote blocking script \(kind.tabTitle) shell exited (\(exitCode)); forcing failure.")
      completeBlockingScript(kind, tabID: tabID, exitCode: 1, reportedTabID: nil)
    } else {
      Self.logger.info("Blocking script \(kind.tabTitle) cancelled by shell exit.")
      completeBlockingScript(kind, tabID: tabID, exitCode: nil, reportedTabID: nil)
    }
  }

  /// A tracked blocking tab is closing; treat as cancellation.
  func handleBlockingScriptTabClosed(tabID: TabID) {
    cleanupBlockingScriptLaunchDirectory(for: tabID)
    completedBlockingScriptTabs.remove(tabID)
    for (kind, tracked) in lastBlockingScriptTabByKind where tracked == tabID {
      lastBlockingScriptTabByKind.removeValue(forKey: kind)
    }
    guard let kind = blockingScripts.removeValue(forKey: tabID) else { return }
    emitTaskStatusIfChanged()
    onBlockingScriptCompleted?(kind, nil, nil)
  }

  /// Clears tracking without firing the completion callback, for supersede
  /// paths that close the previous tab before launching anew.
  func untrackBlockingScript(tabID: TabID) {
    blockingScripts.removeValue(forKey: tabID)
    completedBlockingScriptTabs.remove(tabID)
    for (kind, tracked) in lastBlockingScriptTabByKind where tracked == tabID {
      lastBlockingScriptTabByKind.removeValue(forKey: kind)
    }
    cleanupBlockingScriptLaunchDirectory(for: tabID)
  }

  private func completeBlockingScript(
    _ kind: BlockingScriptKind,
    tabID: TabID,
    exitCode: Int?,
    reportedTabID: TabID?
  ) {
    completedBlockingScriptTabs.insert(tabID)
    // Freeze the parked runner BEFORE the async completion callback.
    if let contentID = tab(withID: tabID)?.content.id.rawValue {
      liveSurface(contentID)?.enableReadOnly()
    }
    emitTaskStatusIfChanged()
    Task { @MainActor [weak self] in
      guard let self else {
        SupaLogger("WorktreeContentHost").debug("Blocking script completion dropped: host gone.")
        return
      }
      guard self.trackedBlockingScriptTab(for: kind) == nil else {
        Self.logger.info("Blocking script \(kind.tabTitle) completion superseded by a newer run.")
        return
      }
      self.onBlockingScriptCompleted?(kind, exitCode, reportedTabID)
    }
  }

  func reportBlockingScriptLaunchFailure(_ kind: BlockingScriptKind, _ message: String) {
    Self.logger.warning("Blocking script \(kind.tabTitle) failed to launch: \(message)")
    onBlockingScriptCompleted?(kind, 1, nil)
  }

  private func cleanupBlockingScriptLaunchDirectory(for tabID: TabID) {
    guard let directory = blockingScriptLaunchDirectories.removeValue(forKey: tabID) else { return }
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      Self.logger.warning("Failed to remove blocking-script launch directory: \(error)")
    }
  }

  func cleanupAllBlockingScriptLaunchDirectories() {
    for tabID in Array(blockingScriptLaunchDirectories.keys) {
      cleanupBlockingScriptLaunchDirectory(for: tabID)
    }
  }

  // MARK: - Close bookkeeping.

  /// Marks a programmatic destroy that skips the close-confirmation alert.
  func bypassCloseConfirmation(for surfaceID: UUID) {
    bypassCloseConfirmationSurfaceIDs.insert(surfaceID)
  }

  func consumeBypassCloseConfirmation(for surfaceID: UUID) -> Bool {
    bypassCloseConfirmationSurfaceIDs.remove(surfaceID) != nil
  }

  func consumeExplicitClose(for surfaceID: UUID) -> Bool {
    pendingExplicitSurfaceCloseIDs.remove(surfaceID) != nil
  }

  func cancelExplicitClose(for surfaceID: UUID) {
    pendingExplicitSurfaceCloseIDs.remove(surfaceID)
  }

  /// A live content is going away: cancel its OSC bookkeeping, notify presence
  /// teardown, and keep the notification inspector from dead-ending.
  /// Reconciles per-content side effects after any layout change: closed
  /// contents release their bookkeeping (never-woken ones included, so their
  /// close still emits), closed blocking-script tabs release their tracking,
  /// and dormancy transitions fire the hibernate / wake handlers.
  func reconcileContentLifecycle() {
    guard let layout = layout() else { return }
    let current = Set(layout.allContentIDs.map(\.rawValue))
    let removed = lastSweptContentIDs.subtracting(current)
    lastSweptContentIDs = current
    for surfaceID in removed {
      cleanupSurfaceState(for: surfaceID)
    }
    // A closed script tab must release its tracking, or the script can never
    // rerun and quit keeps confirming forever.
    for tabID in blockingScripts.keys where tab(withID: tabID) == nil {
      handleBlockingScriptTabClosed(tabID: tabID)
    }
    let dormant = Set(current.filter { isDormantSurface($0) })
    let hibernated = dormant.subtracting(lastDormantContentIDs)
    let woken = lastDormantContentIDs.subtracting(dormant).intersection(current)
    lastDormantContentIDs = dormant
    if !hibernated.isEmpty {
      handleSurfacesHibernated(hibernated)
    }
    for surfaceID in woken {
      handleSurfaceWoken(surfaceID)
    }
    reconcileDormantWatchers()
  }

  func cleanupSurfaceState(for surfaceID: UUID) {
    let hadUnseen = hasUnseenNotification(forSurfaceID: surfaceID)
    discardSurfaceBookkeeping(for: surfaceID)
    surfaceStates.removeValue(forKey: surfaceID)
    // The layout already dropped the tab; prune its cached progress display.
    lastTabProgressDisplays = lastTabProgressDisplays.filter { tab(withID: $0.key) != nil }
    // Watchers must stop BEFORE the session dies, or a watcher poll races the
    // kill and logs a spurious dead-session error.
    reconcileDormantWatchers()
    onSurfacesClosed?([surfaceID])
    guard hadUnseen else { return }
    for index in notifications.indices where notifications[index].surfaceID == surfaceID {
      notifications[index].isRead = true
    }
    onNotificationIndicatorChanged?()
  }

  /// Cancels held OSC state so a reused UUID never inherits stale dedupe.
  private func discardSurfaceBookkeeping(for surfaceID: UUID) {
    pendingAgentOSCNotifications.removeValue(forKey: surfaceID)?.cancel()
    lastCustomNotificationAt.removeValue(forKey: surfaceID)
    pendingExplicitSurfaceCloseIDs.remove(surfaceID)
    bypassCloseConfirmationSurfaceIDs.remove(surfaceID)
  }

  /// A content hibernated: keep its counter and dedupe state, cancel nothing
  /// but the held OSC (the dormant watcher re-ingests).
  func handleSurfacesHibernated(_ surfaceIDs: Set<UUID>) {
    onSurfacesHibernated?(surfaceIDs)
    reconcileDormantWatchers()
    for tabID in Array(lastTabProgressDisplays.keys) {
      emitTabProgressDisplay(for: tabID)
    }
    emitTaskStatusIfChanged()
    onDormancyChanged?()
  }

  /// A content woke: the live surface's own pipeline takes over.
  func handleSurfaceWoken(_ surfaceID: UUID) {
    registerSurfaceState(for: surfaceID)
    reconcileDormantWatchers()
    onDormancyChanged?()
  }

  // MARK: - Dormant sessions.

  /// Keeps the dormant OSC watchers in lock-step with hibernated contents.
  /// Stopping a watcher closes its socket, so call this BEFORE killing a
  /// session on explicit close.
  /// Test seam for the `watched == dormant zmx contents` invariant.
  var watchedDormantSurfaceIDsForTesting: Set<UUID> {
    dormantSessionWatchers.watchedSurfaceIDs
  }

  func reconcileDormantWatchers() {
    let dormant = Set(
      (layout()?.allContentIDs ?? [])
        .map(\.rawValue)
        .filter { isDormantSurface($0) && contentUsesZmx($0) }
    )
    dormantSessionWatchers.reconcile(dormantSurfaceIDs: dormant)
  }

  /// Only zmx-backed sessions have a socket to watch or a replay to protect.
  private func contentUsesZmx(_ surfaceID: UUID) -> Bool {
    guard let tab = layout()?.tab(containingContent: ContentID(rawValue: surfaceID))?.tab else { return false }
    guard case .terminal(let state) = tab.content.state else { return false }
    return state.launch?.bypassZmx != true
  }

  private func handleDormantOSCSequence(surfaceID: UUID, sequence: ZmxOSCSequence) {
    guard isKnownSurface(surfaceID) else { return }
    switch sequence.code {
    case 9:
      guard let payload = sequence.payloadString else {
        Self.logger.debug("Dropped non-UTF8 dormant OSC 9 for surface \(surfaceID)")
        return
      }
      guard !AgentSignal.isConEmuOSC9Payload(payload) else {
        Self.logger.debug("Dropped ConEmu-shaped dormant OSC 9 for surface \(surfaceID)")
        return
      }
      handleAgentOSCNotification(title: "", body: payload, surfaceID: surfaceID)
    case 3008:
      guard let payload = sequence.payloadString,
        let fields = AgentSignal.contextSignalFields(payload: payload)
      else { return }
      handleContextSignal(surfaceID: surfaceID, id: fields.id, metadata: fields.metadata)
    case 0, 2:
      guard let payload = sequence.payloadString else { return }
      updateDormantTabTitle(surfaceID: surfaceID, title: payload)
    default:
      break
    }
  }

  /// OSC 0/2 from a dormant session updates the tab row title, only while the
  /// content is still dormant; a live surface's pipeline is authoritative.
  private func updateDormantTabTitle(surfaceID: UUID, title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, isDormantSurface(surfaceID) else { return }
    sendLayoutAction(.runtime(.titleChanged(id: ContentID(rawValue: surfaceID), title: trimmed)))
  }

  /// Full teardown on prune or quit: watchers stop, bookkeeping clears.
  func tearDown() {
    dormantSessionWatchers.reconcile(dormantSurfaceIDs: [])
    for task in pendingAgentOSCNotifications.values {
      task.cancel()
    }
    pendingAgentOSCNotifications.removeAll()
    cleanupAllBlockingScriptLaunchDirectories()
  }
}
