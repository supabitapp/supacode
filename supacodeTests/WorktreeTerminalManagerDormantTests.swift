import Clocks
import Dependencies
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Shared seeding for the hibernation suites. Pins the flag explicitly in the
/// ambient shared settings the state reads, so dormant coverage never depends on
/// the shipped default.
@MainActor
enum HibernationTestSupport {
  static func enableHibernation() {
    setHibernation(true)
  }

  static func setHibernation(_ enabled: Bool) {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = enabled }
  }

  static func setConfirmCloseSurface(_ enabled: Bool) {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseSurface = enabled }
  }
}

/// Dormant-storage coverage: seeded dormant entries must keep every bookkeeping
/// site (layout capture, surface enumeration, projections, kill lists,
/// quit-confirm signal) truthful about a hibernated tab.
@MainActor
@Suite(.serialized, .dependencies)
struct DormantTerminalTests {
  // MARK: - Fixtures

  private func makeWorktree(id: String = "/tmp/repo/wt-dormant") -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRemoteWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("devbox:/tmp/repo/wt-dormant-remote"),
      name: "wt-dormant-remote",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-dormant-remote"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      host: RemoteHost(alias: "devbox")
    )
  }

  private func makeState() -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    return WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: makeWorktree(),
      splitPreserveZoomOnNavigation: { false }
    )
  }

  private func session(for surfaceID: UUID) -> String {
    ZmxSessionID.make(surfaceID: surfaceID)
  }

  private func firstSurfaceID(_ state: WorktreeTerminalState, tab: TerminalTabID) -> UUID {
    state.splitTree(for: tab).root!.leftmostLeaf().id
  }

  /// Manager wired with an in-memory settings file and a zmx client that records
  /// every local kill, so quit / prune kill lists can be asserted on-disk.
  private struct Harness {
    let manager: WorktreeTerminalManager
    let killed: LockIsolated<[String]>
    let storage: SettingsFileStorage
    let url: URL
  }

  private func makeHarness() -> Harness {
    let killed = LockIsolated<[String]>([])
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { id in killed.withValue { $0.append(id) } },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
      $0.settingsFileStorage = storage
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    manager.saveLayoutSnapshot = { _, _ in }
    return Harness(manager: manager, killed: killed, storage: storage, url: url)
  }

  private func readLayouts(_ harness: Harness) -> [String: TerminalLayoutSnapshot] {
    guard let data = try? harness.storage.load(harness.url) else { return [:] }
    return (try? JSONDecoder().decode([String: TerminalLayoutSnapshot].self, from: data)) ?? [:]
  }

  /// Bounded pump so a detached kill Task can land without `Task.sleep`.
  private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<200 {
      if predicate() { return }
      await Task.megaYield()
    }
  }

  // MARK: - State-level accessors

  @Test func captureLayoutSnapshotIncludesDormantTab() {
    let state = makeState()
    let liveTab = state.createTab(focusing: false)!
    let dormantTab = state.createTab(focusing: false)!
    let dormantSurface = firstSurfaceID(state, tab: dormantTab)

    state.hibernateTabForTesting(dormantTab)

    let snapshot = state.captureLayoutSnapshot()
    let ids = snapshot?.tabs.compactMap(\.id) ?? []
    #expect(ids.contains(liveTab.rawValue))
    #expect(ids.contains(dormantTab.rawValue))
    #expect(snapshot?.allSurfaceIDs.contains(dormantSurface) == true)
    // Single-leaf dormant tab freezes focus on its only leaf.
    let dormantSnapshot = snapshot?.tabs.first { $0.id == dormantTab.rawValue }
    #expect(dormantSnapshot?.focusedLeafIndex == 0)
  }

  @Test func allSurfaceIDsIncludesDormantLeaves() {
    let state = makeState()
    let liveTab = state.createTab(focusing: false)!
    let liveSurface = firstSurfaceID(state, tab: liveTab)
    let dormantTab = state.createTab(focusing: false)!
    let dormantSurface = firstSurfaceID(state, tab: dormantTab)

    state.hibernateTabForTesting(dormantTab)

    let all = Set(state.allSurfaceIDs)
    #expect(all.contains(liveSurface))
    #expect(all.contains(dormantSurface))
  }

  @Test func tabIDContainingResolvesDormantSurface() {
    let state = makeState()
    let dormantTab = state.createTab(focusing: false)!
    let dormantSurface = firstSurfaceID(state, tab: dormantTab)

    state.hibernateTabForTesting(dormantTab)

    #expect(state.tabID(containing: dormantSurface) == dormantTab)
  }

  @Test func hasAnySurfaceTrueWhenOnlyDormantEntriesRemain() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: tab)

    state.hibernateTabForTesting(tab)

    #expect(state.dormantTabLayouts.count == 1)
    #expect(state.hasAnySurface)
  }

  @Test func dormantKeysAreSubsetOfTabManagerTabs() {
    let state = makeState()
    let hibernated = state.createTab(focusing: false)!
    let live = state.createTab(focusing: false)!

    state.hibernateTabForTesting(hibernated)

    let tabIDs = Set(state.tabManager.tabs.map(\.id))
    #expect(Set(state.dormantTabLayouts.keys).isSubset(of: tabIDs))
    #expect(state.dormantTabLayouts.keys.contains(hibernated))
    #expect(tabIDs.contains(live))
  }

  @Test func hasUnseenNotificationForDormantTabRoutesThroughFrozenLeaves() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTabForTesting(tab)
    state.setNotificationsForTesting([
      WorktreeTerminalNotification(
        surfaceID: surface,
        title: "Unread",
        body: "body",
        createdAt: .distantPast,
        isRead: false
      )
    ])

    #expect(state.hasUnseenNotification(forTabID: tab))
  }

  @Test func hibernateTabIsNoOpWhenIneligible() {
    // The default noop zmx client makes the leaf non-`usesZmx`, so hibernation is
    // refused and the tab stays live.
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    #expect(!state.canHibernate(tabId: tab))
    state.hibernateTab(tab)

    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(state.surfaceIDs(inTab: tab) == [surface])
    #expect(state.hasSurfaceAnywhere(surface))
  }

  @Test func fireWithIneligibleLeafReArmsTimer() {
    // A non-zmx leaf can't hibernate; re-arming avoids wedging on a later flip.
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: tab)
    #expect(!state.canHibernate(tabId: tab))

    state.fireHibernationTimerForTesting(tab)

    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))
  }

  @Test func hibernationFreezesAgentRecordsIntoLayout() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    let agentRecord = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [42], activity: "busy")
    state.hibernationAgentsBySurface = { [surface: [agentRecord]] }

    state.hibernateTabForTesting(tab)

    // The captured snapshot embeds the agent record frozen at hibernate time, so a
    // dormant-persisted layout keeps presence + image-paste routing across relaunch.
    let records = state.captureLayoutSnapshot()?.allAgentRecords() ?? []
    #expect(
      records.contains { entry in
        entry.surfaceID == surface
          && entry.records.contains { $0.agent == "claude" && $0.pids == [42] && $0.activity == "busy" }
      }
    )
  }

  @Test func dormantSnapshotRefreshesAgentRecordsFromLiveMap() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    let busy = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [42], activity: "busy")
    state.hibernationAgentsBySurface = { [surface: [busy]] }

    state.hibernateTabForTesting(tab)

    // The session watcher moved presence busy->idle while dormant; a snapshot
    // saved now must carry the fresh idle record, not the frozen busy one.
    let idle = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [42], activity: "idle")
    let refreshed = state.captureLayoutSnapshot(agentsBySurface: [surface: [idle]])?.allAgentRecords() ?? []
    #expect(
      refreshed.contains { entry in
        entry.surfaceID == surface && entry.records.contains { $0.activity == "idle" }
      }
    )

    // A nil map (no authoritative source wired) keeps the frozen record unchanged.
    let frozen = state.captureLayoutSnapshot(agentsBySurface: nil)?.allAgentRecords() ?? []
    #expect(
      frozen.contains { entry in
        entry.surfaceID == surface && entry.records.contains { $0.activity == "busy" }
      }
    )
  }

  @Test func dormantSnapshotClearsAgentRecordsWhenAuthoritativeMapOmitsLeaf() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    let busy = TerminalLayoutSnapshot.SurfaceAgentRecord(agent: "claude", pids: [42], activity: "busy")
    state.hibernationAgentsBySurface = { [surface: [busy]] }

    state.hibernateTabForTesting(tab)

    // The dormant agent emitted session_end while dark, so the authoritative map
    // no longer carries the surface: its frozen records must be cleared, not
    // resurrected onto disk.
    let records = state.captureLayoutSnapshot(agentsBySurface: [UUID(): []])?.allAgentRecords() ?? []
    #expect(!records.contains { $0.surfaceID == surface })
  }

  @Test func hibernationClearsCachedTabProgress() {
    let state = makeState()
    let captured = LockIsolated<[TerminalTabID: TerminalTabProgressDisplay?]>([:])
    state.onTabProgressDisplayChanged = { tabId, display in
      captured.withValue { $0[tabId] = display }
    }
    let tab = state.createTab(focusing: false)!
    let surface = state.splitTree(for: tab).root!.leftmostLeaf()

    // Drive a running stripe through the live pipeline so the tab caches it.
    surface.bridge.state.progressState = GHOSTTY_PROGRESS_STATE_INDETERMINATE
    surface.bridge.onProgressReport?(GHOSTTY_PROGRESS_STATE_INDETERMINATE)
    #expect((state.currentTabProgressDisplays()[tab] ?? nil) != nil)

    state.hibernateTabForTesting(tab)

    // Teardown emits the now-nil display: dormant OSC progress is ConEmu-dropped,
    // so a running stripe must not linger for the whole dormant period.
    #expect((state.currentTabProgressDisplays()[tab] ?? nil) == nil)
    #expect((captured.value[tab] ?? nil) == nil)
  }

  @Test func wakeReDerivesFirstTabContextAfterEarlierTabCloses() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let firstTab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: firstTab)
    let laterTab = state.createTab(focusing: false)!
    let laterSurface = firstSurfaceID(state, tab: laterTab)

    // Hibernate the later (TAB-context) tab, then close the original first tab so
    // the later one becomes first.
    state.hibernateTab(laterTab)
    state.closeTab(firstTab)

    state.wakeTab(laterTab)

    // Wake re-derives the anchor context from the live order: now-first => WINDOW,
    // not the stale TAB context frozen at hibernate.
    #expect(state.surfaceContextForTesting(laterSurface) == GHOSTTY_SURFACE_CONTEXT_WINDOW)
  }

  @Test func orphanedWakeLeafIDsReturnsUnrebuiltLeaves() {
    let rebuilt = UUID()
    let orphanA = UUID()
    let orphanB = UUID()

    let orphaned = WorktreeTerminalState.orphanedWakeLeafIDs(
      expected: [rebuilt, orphanA, orphanB], rebuilt: [rebuilt])

    // A fully-rebuilt tree strands nothing; a partial rebuild reports the missing
    // frozen leaves (whose sessions the wake path then kills).
    #expect(orphaned == [orphanA, orphanB])
    #expect(
      WorktreeTerminalState.orphanedWakeLeafIDs(expected: [rebuilt], rebuilt: [rebuilt]).isEmpty)
  }

  // MARK: - Projection defect fix

  @Test func emitTabProjectionForDormantTabProjectsIsDormantWithoutRemoval() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    var removed: [TerminalTabID] = []
    var projections: [WorktreeTabProjection] = []
    state.onTabRemoved = { removed.append($0) }
    state.onTabProjectionChanged = { projections.append($0) }

    state.hibernateTabForTesting(tab)

    // A dormant tab is still in `tabManager`: no removal, and the projection
    // carries the frozen leaves plus the dormancy flag.
    #expect(removed.isEmpty)
    let dormantProjection = projections.last { $0.tabID == tab }
    #expect(dormantProjection?.isDormant == true)
    #expect(dormantProjection?.surfaceIDs == [surface])
    #expect(dormantProjection?.activeSurfaceID == surface)
  }

  @Test func hibernatingAProgressBusyTabClearsTerminalActivity() {
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    let surface = state.splitTree(for: tab).root!.leftmostLeaf()

    var projections: [WorktreeTabProjection] = []
    state.onTabProjectionChanged = { projections.append($0) }

    // Live Ghostty progress: the tab reports terminal activity and shimmers.
    surface.bridge.state.progressState = GHOSTTY_PROGRESS_STATE_INDETERMINATE
    surface.bridge.onProgressReport?(GHOSTTY_PROGRESS_STATE_INDETERMINATE)
    #expect(projections.last { $0.tabID == tab }?.hasTerminalActivity == true)

    // Hibernation tears the surfaces down, so the dormant projection drops the
    // terminal-activity signal even though the tab is not removed.
    state.hibernateTabForTesting(tab)
    let dormant = projections.last { $0.tabID == tab }
    #expect(dormant?.isDormant == true)
    #expect(dormant?.hasTerminalActivity == false)
  }

  @Test func allTabsDormantOnlyWhenEveryTabHibernated() {
    let state = makeState()
    #expect(!state.allTabsDormant)

    let liveTab = state.createTab(focusing: false)!
    let dormantTab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: dormantTab)

    // Mixed live + dormant: the row must not read as fully asleep.
    state.hibernateTabForTesting(dormantTab)
    #expect(!state.allTabsDormant)

    // Every tab hibernated: now the whole worktree is dormant.
    state.hibernateTabForTesting(liveTab)
    #expect(state.allTabsDormant)
  }

  @Test func wakeClearsDormantProjectionFlag() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: tab)

    var projections: [WorktreeTabProjection] = []
    state.onTabProjectionChanged = { projections.append($0) }

    state.hibernateTab(tab)
    #expect(projections.last { $0.tabID == tab }?.isDormant == true)

    state.wakeTab(tab)
    #expect(projections.last { $0.tabID == tab }?.isDormant == false)
  }

  // MARK: - Manager kill lists

  @Test func terminateAllSessionsKillsDormantSessions() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    let tab = state.createTab(focusing: false)!
    let surface = state.splitTree(for: tab).root!.leftmostLeaf().id

    state.hibernateTabForTesting(tab)
    await harness.manager.terminateAllSessions()

    #expect(harness.killed.value.contains(session(for: surface)))
  }

  @Test func pruneKillsDormantSessions() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    let tab = state.createTab(focusing: false)!
    let surface = state.splitTree(for: tab).root!.leftmostLeaf().id

    state.hibernateTabForTesting(tab)
    harness.manager.prune(keeping: [])
    await waitUntil { harness.killed.value.contains(session(for: surface)) }

    #expect(harness.killed.value.contains(session(for: surface)))
  }

  @Test func saveAllLayoutSnapshotsPersistsDormantSurfaceIDs() {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    let tab = state.createTab(focusing: false)!
    let surface = state.splitTree(for: tab).root!.leftmostLeaf().id

    state.hibernateTabForTesting(tab)
    harness.manager.saveAllLayoutSnapshots()

    let persisted = readLayouts(harness)[worktree.id.rawValue]
    #expect(persisted?.allSurfaceIDs.contains(surface) == true)
  }

  // MARK: - Manager wiring

  @Test func hibernatingEveryTabEmitsAllTabsDormantProjection() async {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    let tab = state.createTab(focusing: false)!
    _ = state.splitTree(for: tab).root!.leftmostLeaf().id

    let projections = LockIsolated<[WorktreeRowProjection]>([])
    let stream = harness.manager.eventStream()
    let collector = Task {
      for await event in stream {
        if case .worktreeProjectionChanged(let id, let projection) = event, id == worktree.id {
          projections.withValue { $0.append(projection) }
        }
      }
    }

    state.hibernateTabForTesting(tab)
    await waitUntil { projections.value.contains { $0.allTabsDormant } }
    collector.cancel()

    // The manager forwards the row projection so the sidebar sleep marker tracks
    // `allTabsDormant`; deleting that wiring would fail this.
    #expect(projections.value.contains { $0.allTabsDormant })
  }

  @Test func hibernationCancelsPendingIdleHooksWithoutDroppingPresence() {
    let harness = makeHarness()
    let worktree = makeWorktree()
    let state = harness.manager.state(for: worktree)
    let tab = state.createTab(focusing: false)!
    let surface = state.splitTree(for: tab).root!.leftmostLeaf().id
    let closed = LockIsolated<Set<UUID>>([])
    state.onSurfacesClosed = { ids in closed.withValue { $0.formUnion(ids) } }

    // An OSC 3008 idle presence signal seeds a pending idle-debounce task.
    state.deliverDormantOSCForTesting(
      surfaceID: surface,
      sequence: ZmxOSCSequence(code: 3008, payload: Array("start=claude;event=idle".utf8))
    )
    #expect(harness.manager.pendingIdleHookCountForTesting == 1)

    state.hibernateTabForTesting(tab)

    // `onSurfacesHibernated` cancels the idle hook but never kills the session or
    // fires `onSurfacesClosed` (presence survives hibernation).
    #expect(harness.manager.pendingIdleHookCountForTesting == 0)
    #expect(harness.killed.value.isEmpty)
    #expect(closed.value.isEmpty)
  }

  @Test func pruneKillsDormantRemoteHostSessions() async {
    let killedRemote = LockIsolated<[String]>([])
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, id in killedRemote.withValue { $0.append(id) } },
        listSessionsWithClients: { [] }
      )
      $0.settingsFileStorage = .inMemory()
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime())
    }
    manager.saveLayoutSnapshot = { _, _ in }
    let worktree = makeRemoteWorktree()
    let state = manager.state(for: worktree)
    let tab = state.createTab(focusing: false)!
    let surface = state.splitTree(for: tab).root!.leftmostLeaf().id
    state.hibernateTabForTesting(tab)

    manager.prune(keeping: [])
    await waitUntil { killedRemote.value.contains(session(for: surface)) }

    // A dormant remote leaf's host-side session is torn down over SSH on prune.
    #expect(killedRemote.value.contains(session(for: surface)))
  }

  // MARK: - Real hibernate / wake

  /// State bound to a zmx client that reports an executable (so every surface is
  /// `usesZmx` and thus hibernation-eligible) and records each local kill.
  private func makeZmxState(
    killed: LockIsolated<[String]> = LockIsolated([]),
    surfaceNeedsCloseConfirmation: @escaping (GhosttySurfaceView) -> Bool = { _ in false }
  ) -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    return withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { id in killed.withValue { $0.append(id) } },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
    } operation: {
      WorktreeTerminalState(
        runtime: GhosttyRuntime(),
        worktree: makeWorktree(),
        splitPreserveZoomOnNavigation: { false },
        surfaceNeedsCloseConfirmation: surfaceNeedsCloseConfirmation
      )
    }
  }

  private func layout(_ state: WorktreeTerminalState, tab: TerminalTabID)
    -> TerminalLayoutSnapshot.LayoutNode?
  {
    state.captureLayoutSnapshot()?.tabs.first { $0.id == tab.rawValue }?.layout
  }

  /// Preorder split ratios of a layout subtree, so a shape/ratio comparison
  /// survives hibernate/wake without depending on pwd fields.
  private func splitRatios(_ node: TerminalLayoutSnapshot.LayoutNode) -> [Double] {
    switch node {
    case .leaf:
      return []
    case .split(let split):
      return [split.ratio] + splitRatios(split.left) + splitRatios(split.right)
    }
  }

  @Test func hibernateWakeCycleKeepsSurfaceIDsAndSkipsKill() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    let originalID = firstSurfaceID(state, tab: tab)

    for _ in 0..<3 {
      #expect(state.canHibernate(tabId: tab))
      state.hibernateTab(tab)
      #expect(state.dormantTabLayouts[tab] != nil)
      // Dormant-aware queries still resolve the frozen leaf so validation accepts it.
      #expect(state.surfaceIDs(inTab: tab) == [originalID])
      #expect(state.hasSurfaceAnywhere(originalID))
      // The live surface is torn down, but its per-surface state is preserved
      // through hibernation (holding the unseen counter, here zero).
      #expect(state.surfaceStates[originalID]?.unseenNotificationCount == 0)

      state.wakeTab(tab)
      #expect(state.dormantTabLayouts[tab] == nil)
      #expect(state.surfaceIDs(inTab: tab) == [originalID])
      #expect(state.hasSurfaceAnywhere(originalID))
      #expect(state.surfaceStates[originalID] != nil)
    }
    // Reattach never kills: the zmx sessions must outlive every cycle.
    #expect(killed.value.isEmpty)
  }

  @Test func focusSurfaceWakesDormantTabAndSelectsIt() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let dormantTab = state.createTab(focusing: false)!
    let dormantID = firstSurfaceID(state, tab: dormantTab)
    let otherTab = state.createTab(focusing: true)!
    _ = firstSurfaceID(state, tab: otherTab)

    state.hibernateTab(dormantTab)
    #expect(state.dormantTabLayouts[dormantTab] != nil)

    #expect(state.focusSurface(id: dormantID))
    #expect(state.dormantTabLayouts[dormantTab] == nil)
    #expect(state.tabManager.selectedTabId == dormantTab)
    #expect(state.surfaceIDs(inTab: dormantTab) == [dormantID])
    #expect(killed.value.isEmpty)
  }

  @Test func closingDormantTabAlwaysConfirms() async {
    HibernationTestSupport.setConfirmCloseSurface(true)
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    let surfaceID = firstSurfaceID(state, tab: tab)
    // Control: no live leaf reports a running process, so dormancy is the only
    // thing that can raise the prompt below.
    let idleTab = state.createTab(focusing: true)!
    _ = firstSurfaceID(state, tab: idleTab)
    #expect(state.requestCloseTab(idleTab))
    #expect(state.pendingCloseConfirmation == nil)

    state.hibernateTab(tab)
    #expect(state.requestCloseTab(tab))
    #expect(state.pendingCloseConfirmation == .tabs([tab], reason: .dormant))
    #expect(state.hasTab(tab))

    state.confirmPendingClose()
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tab))
    // Confirming must run the full dormant teardown, not just drop the row.
    await waitUntil { killed.value.contains(session(for: surfaceID)) }
    #expect(killed.value.contains(session(for: surfaceID)))
    #expect(state.watchedDormantSurfaceIDsForTesting.isEmpty)
    #expect(state.surfaceStates[surfaceID] == nil)
  }

  @Test func closeAllTabsConfirmsOnceAndDrainsLiveAndDormantTabs() async {
    HibernationTestSupport.setConfirmCloseSurface(true)
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let liveTab = state.createTab(focusing: true)!
    let liveSurface = firstSurfaceID(state, tab: liveTab)
    let dormantTab = state.createTab(focusing: false)!
    let dormantSurface = firstSurfaceID(state, tab: dormantTab)
    state.hibernateTab(dormantTab)

    #expect(state.requestCloseAllTabs())
    // The live tab is idle, so dormancy alone raised the prompt.
    #expect(state.pendingCloseConfirmation == .tabs([liveTab, dormantTab], reason: .dormant))

    state.confirmPendingClose()
    await waitUntil { killed.value.contains(session(for: dormantSurface)) }
    #expect(!state.hasTab(liveTab))
    #expect(!state.hasTab(dormantTab))
    #expect(state.dormantTabLayouts.isEmpty)
    #expect(!state.hasSurfaceAnywhere(liveSurface))
  }

  @Test func liveRunningTabInBatchKeepsTheRunningProcessCopy() {
    HibernationTestSupport.setConfirmCloseSurface(true)
    let running = LockIsolated<Set<UUID>>([])
    let state = makeZmxState(surfaceNeedsCloseConfirmation: { view in running.value.contains(view.id) })
    let liveTab = state.createTab(focusing: true)!
    let liveSurface = firstSurfaceID(state, tab: liveTab)
    running.withValue { $0.insert(liveSurface) }
    let dormantTab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: dormantTab)
    state.hibernateTab(dormantTab)

    // A live leaf really is running, so that outranks the dormant tab.
    #expect(state.requestCloseAllTabs())
    #expect(state.pendingCloseConfirmation == .tabs([liveTab, dormantTab], reason: .runningProcess))

    // The reason rides on the payload: the process reaching its prompt while the
    // alert is up must not flip the copy to the dormant wording.
    running.withValue { $0.removeAll() }
    #expect(
      state.pendingCloseConfirmation?.message == WorktreeTerminalState.CloseConfirmationReason.runningProcess.message)
  }

  @Test func wokenTabNoLongerForcesConfirmation() {
    HibernationTestSupport.setConfirmCloseSurface(true)
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    state.wakeTab(tab)

    // Dormancy was the only reason this tab confirmed; awake and idle, it must not.
    #expect(state.requestCloseTab(tab))
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tab))
  }

  @Test func tabWithPendingCloseConfirmationDoesNotHibernate() {
    HibernationTestSupport.setConfirmCloseSurface(true)
    let state = makeZmxState(surfaceNeedsCloseConfirmation: { _ in true })
    let tab = state.createTab(focusing: true)!
    let surfaceID = firstSurfaceID(state, tab: tab)

    #expect(state.requestCloseTab(tab))
    #expect(state.pendingCloseConfirmation == .tabs([tab], reason: .runningProcess))

    // Hibernating here would tear the alert's target down and drop the request.
    #expect(!state.canHibernate(tabId: tab))
    state.hibernateTab(tab)
    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(state.pendingCloseConfirmation == .tabs([tab], reason: .runningProcess))

    state.confirmPendingClose()
    #expect(!state.hasTab(tab))
    #expect(!state.hasSurfaceAnywhere(surfaceID))
  }

  @Test func closingDormantTabSkipsConfirmationWhenSettingIsOff() {
    HibernationTestSupport.setConfirmCloseSurface(false)
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    #expect(state.requestCloseTab(tab))
    #expect(state.pendingCloseConfirmation == nil)
    #expect(!state.hasTab(tab))
  }

  @Test func hibernateWakeRestoresSplitShapeAndZoom() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    let firstID = firstSurfaceID(state, tab: tab)
    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    let idsBefore = state.surfaceIDs(inTab: tab)
    #expect(idsBefore.count == 2)
    #expect(state.performSplitAction(.toggleSplitZoom, for: idsBefore[1]))
    #expect(state.isSplitZoomed(forTabID: tab))
    let layoutBefore = layout(state, tab: tab)

    state.hibernateTab(tab)
    state.wakeTab(tab)

    #expect(state.surfaceIDs(inTab: tab) == idsBefore)
    #expect(state.isSplitZoomed(forTabID: tab))
    let layoutAfter = layout(state, tab: tab)
    #expect(layoutBefore.map(splitRatios) == layoutAfter.map(splitRatios))
    #expect(layoutBefore?.leafSurfaceIDs == layoutAfter?.leafSurfaceIDs)
    #expect(killed.value.isEmpty)
  }

  @Test func multiLeafDormantTabRoundTripsThroughSnapshotCodable() throws {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    let firstID = firstSurfaceID(state, tab: tab)
    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    #expect(state.renameTab(tab, title: "Custom Name"))
    let idsBefore = state.surfaceIDs(inTab: tab)
    #expect(idsBefore.count == 2)

    state.hibernateTab(tab)
    let snapshot = state.captureLayoutSnapshot()!
    let originalLayout = snapshot.tabs.first { $0.id == tab.rawValue }?.layout

    // The persisted boundary is JSON: round-trip through the Codable snapshot.
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(TerminalLayoutSnapshot.self, from: data)

    // Restore into a fresh state and compare shape / title / leaf ids.
    let restored = makeZmxState(killed: killed)
    restored.pendingLayoutSnapshot = decoded
    restored.ensureInitialTab(focusing: false)

    let restoredTab = restored.tabManager.tabs.first { $0.id == tab }
    #expect(restoredTab?.customTitle == "Custom Name")
    let restoredLayout = layout(restored, tab: tab)
    #expect(restoredLayout.map(splitRatios) == originalLayout.map(splitRatios))
    #expect(restoredLayout?.leafSurfaceIDs == idsBefore)
  }

  @Test func staleRenderOfClosedDormantTabMintsNothing() async {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    state.closeTab(tab)
    await waitUntil { killed.value.contains(session(for: surface)) }

    // The closed tab is gone; a stale render must find nothing and mint nothing.
    #expect(state.splitTree(for: tab).isEmpty)
    #expect(!state.hasSurfaceAnywhere(surface))
    #expect(state.dormantTabLayouts[tab] == nil)
  }

  @Test func midHibernationCloseRequestIsInert() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    let view = state.splitTree(for: tab).root!.leftmostLeaf()
    let surface = view.id

    state.hibernateTab(tab)
    // The live surface is torn down, but its per-surface state is preserved
    // through hibernation (counter zero), and the dormant-aware queries still
    // know the frozen leaf.
    #expect(state.surfaceStates[surface]?.unseenNotificationCount == 0)
    #expect(state.hasSurfaceAnywhere(surface))

    // A late close callback from the torn-down view hits the `surfaces[id] ===
    // view` guard: nothing is killed, replaced, or resurrected.
    view.bridge.onCloseRequest?(false)

    #expect(killed.value.isEmpty)
    #expect(state.surfaceStates[surface]?.unseenNotificationCount == 0)
    #expect(state.dormantTabLayouts[tab] != nil)
  }

  @Test func unseenDotsSurviveHibernateAndWake() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    state.appendHookNotification(title: "Done", body: "body", surfaceID: surface)
    #expect(state.hasUnseenNotification)
    #expect(state.surfaceStates[surface]?.hasUnseenNotification == true)

    state.hibernateTab(tab)
    // Hibernation preserves the per-surface state so its unseen counter (which
    // the worktree dot and per-tab count read) survives the dark period.
    #expect(state.hasUnseenNotification)
    #expect(state.hasUnseenNotification(forTabID: tab))
    #expect(state.surfaceStates[surface]?.hasUnseenNotification == true)

    state.wakeTab(tab)
    // The preserved counter is re-adopted under the original UUID; wake neither
    // re-derives nor clears it.
    #expect(state.surfaceStates[surface]?.hasUnseenNotification == true)
    #expect(state.hasUnseenNotification(forTabID: tab))
  }

  @Test func closingDormantTabKillsSessionsAndPurges() async {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    var closed: Set<UUID> = []
    var removed: [TerminalTabID] = []
    state.onSurfacesClosed = { closed.formUnion($0) }
    state.onTabRemoved = { removed.append($0) }

    state.hibernateTab(tab)
    #expect(state.watchedDormantSurfaceIDsForTesting == [surface])
    state.closeTab(tab)
    await waitUntil { killed.value.contains(session(for: surface)) }

    #expect(killed.value.contains(session(for: surface)))
    #expect(closed.contains(surface))
    #expect(removed.contains(tab))
    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(!state.hasTab(tab))
    // The `dormantTabLayouts` didSet stopped the watcher (before the kill above).
    #expect(state.watchedDormantSurfaceIDsForTesting.isEmpty)
  }

  @Test func closeAllSurfacesDrainsDormantAndDropsPresence() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let liveTab = state.createTab(focusing: false)!
    let liveSurface = firstSurfaceID(state, tab: liveTab)
    let dormantTab = state.createTab(focusing: false)!
    let dormantSurface = firstSurfaceID(state, tab: dormantTab)
    var closed: Set<UUID> = []
    state.onSurfacesClosed = { closed.formUnion($0) }

    state.hibernateTab(dormantTab)
    state.closeAllSurfaces()

    #expect(closed.contains(liveSurface))
    #expect(closed.contains(dormantSurface))
    #expect(state.dormantTabLayouts.isEmpty)
    // `closeAllSurfaces` never kills; the quit / prune callers do, off the
    // dormant-inclusive `allSurfaceIDs` snapshot.
    #expect(killed.value.isEmpty)
  }

  @Test func canHibernateTrueForZmxTab() {
    let killed = LockIsolated<[String]>([])
    let state = makeZmxState(killed: killed)
    let tab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: tab)
    #expect(state.canHibernate(tabId: tab))
  }

  @Test func canHibernateFalseForNonZmxLeaf() {
    // The default noop zmx client reports no executable, so the surface is not
    // `usesZmx` and tearing it down would kill an unrecoverable shell.
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    _ = firstSurfaceID(state, tab: tab)
    #expect(!state.canHibernate(tabId: tab))
  }

  @Test func canHibernateFalseForBlockingScriptTab() {
    let harness = makeHarness()
    let worktree = makeWorktree()
    harness.manager.handleCommand(.runBlockingScript(worktree, kind: .archive, script: "echo ok"))
    guard let state = harness.manager.stateIfExists(for: worktree.id),
      let tab = state.tabManager.selectedTabId
    else {
      Issue.record("Expected a blocking-script tab")
      return
    }
    #expect(!state.canHibernate(tabId: tab))
  }

  // MARK: - CLI destroy into a dormant tab

  /// Manager plus a terminal state for `worktree`, both built inside one
  /// dependency scope so the state's close path kills through the recording zmx
  /// client (a state built later would capture the ambient default and record no
  /// kills).
  private func makeManagerAndState(
    for worktree: Worktree
  ) -> (harness: Harness, state: WorktreeTerminalState) {
    let killed = LockIsolated<[String]>([])
    let storage = SettingsFileStorage.inMemory()
    let url = SupacodePaths.layoutsURL
    let (manager, state) = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { nil },
        isBundled: { true },
        killSession: { id in killed.withValue { $0.append(id) } },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
      $0.settingsFileStorage = storage
    } operation: {
      let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
      manager.saveLayoutSnapshot = { _, _ in }
      return (manager, manager.state(for: worktree))
    }
    return (Harness(manager: manager, killed: killed, storage: storage, url: url), state)
  }

  /// Chains a capture over the manager's own `onSurfacesClosed` sink so the test
  /// observes the presence drop the CLI ack keys on without unwiring the manager.
  private func captureSurfacesClosed(
    _ state: WorktreeTerminalState,
    into sink: LockIsolated<Set<UUID>>
  ) {
    let managerSink = state.onSurfacesClosed
    state.onSurfacesClosed = { ids in
      sink.withValue { $0.formUnion(ids) }
      managerSink?(ids)
    }
  }

  @Test func destroySurfaceWakesDormantTabAndClosesFrozenLeaf() async {
    let worktree = makeWorktree()
    let (harness, state) = makeManagerAndState(for: worktree)
    let closed = LockIsolated<Set<UUID>>([])
    captureSurfacesClosed(state, into: closed)

    let tab = state.createTab(focusing: false)!
    let firstID = firstSurfaceID(state, tab: tab)
    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    let idsBefore = state.surfaceIDs(inTab: tab)
    #expect(idsBefore.count == 2)
    let target = idsBefore[0]
    let survivor = idsBefore[1]

    // Hibernate a background (deselected) tab, then drive the CLI destroy at a
    // frozen leaf: the tab must wake so the close reaches a live surface.
    state.hibernateTabForTesting(tab)
    #expect(state.dormantTabLayouts[tab] != nil)

    harness.manager.handleCommand(.destroySurface(worktree, tabID: tab, surfaceID: target))

    // The tab woke, so the target is a live surface again. The explicit-close
    // binding tears it down; when ghostty defers its close callback, drive it the
    // way ghostty would so the teardown completes.
    if let targetView = state.splitTree(for: tab).leaves().first(where: { $0.id == target }) {
      targetView.bridge.closeSurface(processAlive: false)
    }
    await waitUntil { harness.killed.value.contains(session(for: target)) }

    // The command completed: the frozen leaf's presence dropped and its session died.
    #expect(closed.value.contains(target))
    #expect(harness.killed.value.contains(session(for: target)))
    // The remaining pane survived the implicit wake with its original UUID.
    #expect(state.surfaceIDs(inTab: tab) == [survivor])
    #expect(state.hasSurfaceAnywhere(survivor))
    #expect(!state.hasSurfaceAnywhere(target))
    #expect(state.hasTab(tab))
    #expect(state.dormantTabLayouts[tab] == nil)
    // No duplicate teardown: the target session died exactly once, the survivor never.
    #expect(harness.killed.value.filter { $0 == session(for: target) }.count == 1)
    #expect(!harness.killed.value.contains(session(for: survivor)))
  }

  @Test func destroySurfaceWakesDormantTabAndClosesLastLeaf() async {
    let worktree = makeWorktree()
    let (harness, state) = makeManagerAndState(for: worktree)
    let closed = LockIsolated<Set<UUID>>([])
    captureSurfacesClosed(state, into: closed)

    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTabForTesting(tab)
    #expect(state.dormantTabLayouts[tab] != nil)

    harness.manager.handleCommand(.destroySurface(worktree, tabID: tab, surfaceID: surface))

    // The tab woke; drive ghostty's close callback when it is deferred so the
    // last leaf's teardown completes.
    if let view = state.splitTree(for: tab).leaves().first(where: { $0.id == surface }) {
      view.bridge.closeSurface(processAlive: false)
    }
    await waitUntil { harness.killed.value.contains(session(for: surface)) }

    // Destroying the only leaf collapses the tab, matching the live close path.
    #expect(closed.value.contains(surface))
    #expect(harness.killed.value.contains(session(for: surface)))
    #expect(!state.hasTab(tab))
    #expect(!state.hasSurfaceAnywhere(surface))
    #expect(state.dormantTabLayouts[tab] == nil)
  }
}

/// Visibility tracking and grace timers. A TestClock drives every grace window.
@MainActor
@Suite(.serialized, .dependencies)
struct HibernationTimerTests {
  private func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt-hib-timer"),
      name: "wt-hib-timer",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-hib-timer"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private struct Harness {
    let manager: WorktreeTerminalManager
    let clock: TestClock<Duration>
    let killed: LockIsolated<[String]>
    let agents: LockIsolated<[UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]>
    let worktree: Worktree
  }

  private func makeHarness() -> Harness {
    let clock = TestClock()
    let killed = LockIsolated<[String]>([])
    let agents = LockIsolated<[UUID: [TerminalLayoutSnapshot.SurfaceAgentRecord]]>([:])
    let manager = withDependencies {
      $0.zmxClient = Self.zmxClient(killed: killed)
      $0.settingsFileStorage = .inMemory()
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: clock)
    }
    manager.saveLayoutSnapshot = { _, _ in }
    manager.currentAgentsBySurface = { agents.value }
    return Harness(manager: manager, clock: clock, killed: killed, agents: agents, worktree: makeWorktree())
  }

  private static func zmxClient(killed: LockIsolated<[String]>) -> ZmxClient {
    ZmxClient(
      executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
      isBundled: { true },
      killSession: { id in killed.withValue { $0.append(id) } },
      killRemoteSession: { _, _ in },
      listSessionsWithClients: { [] }
    )
  }

  /// Creates the worktree state inside the harness dependency scope so its zmx
  /// surfaces are `usesZmx` (hibernation-eligible) and its kills are recorded.
  private func registerState(_ harness: Harness) -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    return withDependencies {
      $0.zmxClient = Self.zmxClient(killed: harness.killed)
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
    } operation: {
      harness.manager.state(for: harness.worktree)
    }
  }

  private func firstSurfaceID(_ state: WorktreeTerminalState, tab: TerminalTabID) -> UUID {
    state.splitTree(for: tab).root!.leftmostLeaf().id
  }

  private nonisolated func record(_ activity: String, pids: [Int32]) -> TerminalLayoutSnapshot.SurfaceAgentRecord {
    .init(agent: "claude", pids: pids, activity: activity)
  }

  private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<400 {
      if predicate() { return }
      await Task.megaYield()
    }
  }

  private func pump() async {
    for _ in 0..<40 { await Task.megaYield() }
  }

  /// Lets a just-scheduled (or re-armed) grace-timer Task register its sleep with
  /// the TestClock before advancing, then lets the fired continuation run. The
  /// bounded settle mirrors the presence / bridge de-flake: a single megaYield
  /// can advance past a re-armed sleep that hasn't registered yet, so a
  /// defer-then-re-arm gate flakes; `count: 1000` closes that window.
  private func advance(_ harness: Harness, by duration: Duration) async {
    await Task.megaYield(count: 1000)
    await harness.clock.advance(by: duration)
    await pump()
  }

  // MARK: - Visibility

  @Test func hiddenTabHibernatesAfterGraceWindow() async {
    let harness = makeHarness()
    let state = registerState(harness)
    let tab = state.createTab(focusing: false)!
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))

    await advance(harness, by: .seconds(5 * 60))
    await waitUntil { state.dormantTabLayouts[tab] != nil }

    #expect(state.dormantTabLayouts[tab] != nil)
    #expect(!state.scheduledHibernationTabsForTesting.contains(tab))
  }

  @Test func selectingTabCancelsItsTimer() {
    let harness = makeHarness()
    let state = registerState(harness)
    let tabA = state.createTab(focusing: false)!
    let tabB = state.createTab(focusing: false)!
    state.setWorktreeSelected(true)
    // B is the selected tab, so only A stays scheduled.
    #expect(state.scheduledHibernationTabsForTesting == [tabA])

    state.selectTab(tabA)
    // A is now visible (cancelled); B became hidden (scheduled).
    #expect(state.scheduledHibernationTabsForTesting == [tabB])
  }

  @Test func selectingWorktreeCancelsOnlySelectedTabTimer() {
    let harness = makeHarness()
    let state = registerState(harness)
    let tabA = state.createTab(focusing: false)!
    let tabB = state.createTab(focusing: false)!
    // Deselected worktree: both scheduled.
    #expect(state.scheduledHibernationTabsForTesting == [tabA, tabB])

    state.setWorktreeSelected(true)
    // Only the selected tab's timer cancels; the other stays.
    #expect(state.scheduledHibernationTabsForTesting == [tabA])
  }

  @Test func deselectingWorktreeSchedulesAllTabs() {
    let harness = makeHarness()
    let state = registerState(harness)
    let tabA = state.createTab(focusing: false)!
    let tabB = state.createTab(focusing: false)!
    state.setWorktreeSelected(true)
    #expect(state.scheduledHibernationTabsForTesting == [tabA])

    state.setWorktreeSelected(false)
    #expect(state.scheduledHibernationTabsForTesting == [tabA, tabB])
  }

  @Test func managerSelectionInputDrivesVisibility() {
    let harness = makeHarness()
    let state = registerState(harness)
    let tab = state.createTab(focusing: false)!
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))

    harness.manager.handleCommand(.setSelectedWorktreeID(harness.worktree.id))
    #expect(!state.scheduledHibernationTabsForTesting.contains(tab))

    harness.manager.handleCommand(.setSelectedWorktreeID(nil))
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))
  }

  // MARK: - Working agents

  @Test func workingAgentTabHibernatesOnScheduleFreezingRecords() async {
    let harness = makeHarness()
    let state = registerState(harness)
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    // An actively-working agent must not block hibernation: the zmx session keeps
    // the process alive and the dormant watcher keeps notifications lossless.
    harness.agents.setValue([surface: [record("busy", pids: [123])]])

    await advance(harness, by: .seconds(5 * 60))
    await waitUntil { state.dormantTabLayouts[tab] != nil }
    #expect(state.dormantTabLayouts[tab] != nil)
    #expect(!state.scheduledHibernationTabsForTesting.contains(tab))

    // The busy record freezes into the dormant layout so presence + image-paste
    // routing survive a snapshot persisted while dark.
    let records = state.captureLayoutSnapshot()?.allAgentRecords() ?? []
    #expect(
      records.contains { entry in
        entry.surfaceID == surface
          && entry.records.contains { $0.agent == "claude" && $0.pids == [123] && $0.activity == "busy" }
      }
    )
  }

  // MARK: - Fire-time backstops

  @Test func closedTabFireIsInert() async {
    let harness = makeHarness()
    let state = registerState(harness)
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.closeTab(tab)
    await waitUntil { harness.killed.value.contains(ZmxSessionID.make(surfaceID: surface)) }

    // A late fire for a gone tab hibernates nothing and does not resurrect it.
    state.fireHibernationTimerForTesting(tab)
    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(!state.hasTab(tab))
  }

  @Test func visibleTabFireDoesNotHibernate() {
    let harness = makeHarness()
    let state = registerState(harness)
    let tab = state.createTab(focusing: false)!
    // The tab is now the selected, visible tab.
    state.setWorktreeSelected(true)

    // A stale fire re-checks visibility and refuses to hibernate.
    state.fireHibernationTimerForTesting(tab)
    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(state.surfaceIDs(inTab: tab).count == 1)
  }
}

/// CLI / deeplink paths wake a dormant tab before mutating its surfaces,
/// unread-jump reaches a dormant tab, and a CLI `tab new` consumes a staged
/// layout before adding its tab.
@MainActor
@Suite(.serialized, .dependencies)
struct DormantCLIWakeTests {
  private func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt-hib-cli"),
      name: "wt-hib-cli",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-hib-cli"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private struct Harness {
    let manager: WorktreeTerminalManager
    let killed: LockIsolated<[String]>
    let worktree: Worktree
  }

  private func makeHarness() -> Harness {
    let killed = LockIsolated<[String]>([])
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { id in killed.withValue { $0.append(id) } },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
      $0.settingsFileStorage = .inMemory()
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: TestClock())
    }
    manager.saveLayoutSnapshot = { _, _ in }
    return Harness(manager: manager, killed: killed, worktree: makeWorktree())
  }

  private func registerState(_ harness: Harness) -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    return withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { id in harness.killed.withValue { $0.append(id) } },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
    } operation: {
      harness.manager.state(for: harness.worktree)
    }
  }

  private func firstSurfaceID(_ state: WorktreeTerminalState, tab: TerminalTabID) -> UUID {
    state.splitTree(for: tab).root!.leftmostLeaf().id
  }

  private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<400 {
      if predicate() { return }
      await Task.megaYield()
    }
  }

  @Test func splitSurfaceOnDormantTabWakesAndReArms() {
    let harness = makeHarness()
    let state = registerState(harness)
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    #expect(state.dormantTabLayouts[tab] != nil)

    harness.manager.handleCommand(
      .splitSurface(
        harness.worktree, tabID: tab, surfaceID: surface, direction: .vertical, input: nil, id: UUID()
      )
    )

    // Woke with the SAME anchor UUID (no mint), added the split, re-armed the timer.
    #expect(state.dormantTabLayouts[tab] == nil)
    let ids = state.surfaceIDs(inTab: tab)
    #expect(ids.contains(surface))
    #expect(ids.count == 2)
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))
    #expect(harness.killed.value.isEmpty)
  }

  @Test func focusSurfaceOnDormantTabWakesToSameSurface() {
    let harness = makeHarness()
    let state = registerState(harness)
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    harness.manager.handleCommand(
      .focusSurface(harness.worktree, tabID: tab, surfaceID: surface, input: nil)
    )

    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(state.surfaceIDs(inTab: tab) == [surface])
    #expect(harness.killed.value.isEmpty)
  }

  @Test func jumpToUnreadReachesDormantTab() {
    let harness = makeHarness()
    let state = registerState(harness)
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    state.appendHookNotification(title: "Done", body: "body", surfaceID: surface)

    state.hibernateTab(tab)

    // The dormant-aware lookup still resolves the notification's tab.
    let location = harness.manager.latestUnreadNotificationLocation()
    #expect(location?.tabID == tab)
    #expect(location?.surfaceID == surface)

    // The jump's focus command wakes it onto the same surface.
    harness.manager.handleCommand(
      .focusSurface(harness.worktree, tabID: tab, surfaceID: surface, input: nil)
    )
    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(state.surfaceIDs(inTab: tab).contains(surface))
  }

  @Test func cliCreateTabConsumesStagedSnapshotFirst() async {
    let harness = makeHarness()
    let snapTabID = UUID()
    let snapSurfaceID = UUID()
    let snapshot = TerminalLayoutSnapshot(
      tabs: [
        .init(
          id: snapTabID,
          title: "Restored",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(.init(id: snapSurfaceID, workingDirectory: nil)),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    harness.manager.loadLayoutSnapshot = { $0 == harness.worktree.id ? snapshot : nil }

    let newTabID = UUID()
    harness.manager.handleCommand(
      .createTab(harness.worktree, runSetupScriptIfNew: false, id: newTabID, title: nil)
    )

    await waitUntil { (harness.manager.stateIfExists(for: harness.worktree.id)?.tabManager.tabs.count ?? 0) >= 2 }
    guard let state = harness.manager.stateIfExists(for: harness.worktree.id) else {
      Issue.record("Expected a worktree state")
      return
    }
    let ids = Set(state.tabManager.tabs.map { $0.id.rawValue })
    // The persisted tab survived, and the CLI tab was added on top of it.
    #expect(ids.contains(snapTabID))
    #expect(ids.contains(newTabID))
    #expect(state.hasAttemptedInitialTab)
  }
}

/// OSC signals recovered off a dormant session's socket route into the same
/// notification / presence / title handlers a live surface uses, and the wake /
/// close overlap is tolerated (accept live-or-dormant, drop unknown).
@MainActor
@Suite(.serialized, .dependencies)
struct DormantOSCIngestTests {
  private func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt-hib-osc"),
      name: "wt-hib-osc",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-hib-osc"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  /// State bound to a zmx client that reports an executable (so every surface is
  /// `usesZmx` and hibernation-eligible) on an immediate clock, so the OSC 9
  /// hold-window Task resolves within a pump.
  private func makeZmxState() -> WorktreeTerminalState {
    HibernationTestSupport.enableHibernation()
    return withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
    } operation: {
      WorktreeTerminalState(
        runtime: GhosttyRuntime(),
        worktree: makeWorktree(),
        splitPreserveZoomOnNavigation: { false }
      )
    }
  }

  private func firstSurfaceID(_ state: WorktreeTerminalState, tab: TerminalTabID) -> UUID {
    state.splitTree(for: tab).root!.leftmostLeaf().id
  }

  private func osc(_ code: Int, _ payload: String) -> ZmxOSCSequence {
    ZmxOSCSequence(code: code, payload: Array(payload.utf8))
  }

  private func pump() async {
    for _ in 0..<40 { await Task.megaYield() }
  }

  private func waitUntil(_ predicate: () -> Bool) async {
    for _ in 0..<200 {
      if predicate() { return }
      await Task.megaYield()
    }
  }

  // MARK: - OSC 9 notifications

  @Test func osc9ForDormantLeafRecordsNotificationAndFlipsDot() async {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    #expect(state.dormantTabLayouts[tab] != nil)

    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(9, "Build finished"))
    await waitUntil { state.hasUnseenNotification }

    #expect(state.hasUnseenNotification)
    #expect(state.hasUnseenNotification(forTabID: tab))
    #expect(state.unreadNotifications().contains { $0.surfaceID == surface && $0.body == "Build finished" })
    // No live surface was minted: the tab is still dormant. The frozen leaf's
    // preserved surface state carried the OSC-bumped unseen counter, and the
    // dormant-aware query still resolves the frozen leaf.
    #expect(state.dormantTabLayouts[tab] != nil)
    #expect(state.surfaceStates[surface]?.hasUnseenNotification == true)
    #expect(state.surfaceIDs(inTab: tab) == [surface])
  }

  @Test func osc9DormantLeafIncrementsTabUnseenCount() {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    #expect(state.dormantTabLayouts[tab] != nil)

    // Two custom (hook) notifications on the dormant leaf bump the preserved
    // surface state's counter, so the tab's unseen count reflects both under the
    // counter model (the capped log alone could undercount).
    state.appendHookNotification(title: "One", body: "first", surfaceID: surface)
    state.appendHookNotification(title: "Two", body: "second", surfaceID: surface)

    #expect(state.unseenNotificationCount(forTabID: tab) == 2)
    #expect(state.hasUnseenNotification(forTabID: tab))
    #expect(state.surfaceStates[surface]?.unseenNotificationCount == 2)
  }

  @Test func closingDormantTabWithUnreadClearsPreservedStateAndIndicator() {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    #expect(state.dormantTabLayouts[tab] != nil)

    // A hook notification on the frozen leaf bumps its preserved unseen counter.
    state.appendHookNotification(title: "Done", body: "body", surfaceID: surface)
    #expect(state.hasUnseenNotification)

    var indicatorFires = 0
    state.onNotificationIndicatorChanged = { indicatorFires += 1 }
    state.closeTab(tab)

    // Closing the dormant tab drops the state hibernation preserved for its unseen
    // counter and refreshes the indicator, so the worktree dot / total can't strand.
    #expect(!state.hasUnseenNotification)
    #expect(state.surfaceStates[surface] == nil)
    #expect(indicatorFires == 1)
  }

  @Test func closeAllSurfacesWithDormantUnreadClearsPreservedStateAndIndicator() {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    #expect(state.dormantTabLayouts[tab] != nil)

    state.appendHookNotification(title: "Done", body: "body", surfaceID: surface)
    #expect(state.hasUnseenNotification)

    var indicatorFires = 0
    state.onNotificationIndicatorChanged = { indicatorFires += 1 }
    state.closeAllSurfaces()

    // The dormant drain loop marks the lingering unread read and drops the state
    // hibernation preserved for its unseen counter, so nothing strands the dot.
    #expect(!state.hasUnseenNotification)
    #expect(state.surfaceStates[surface] == nil)
    // A full teardown skips the per-state indicator callback; the manager
    // reconciles the aggregate count once after tearing every state down.
    #expect(indicatorFires == 0)
  }

  @Test func osc9ForUnknownSurfaceIsDropped() async {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    state.hibernateTab(tab)

    state.deliverDormantOSCForTesting(surfaceID: UUID(), sequence: osc(9, "Ghost"))
    await pump()

    #expect(!state.hasUnseenNotification)
    #expect(state.unreadNotifications().isEmpty)
  }

  @Test func conEmuShapedOSC9IsDroppedNotNotified() async {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    state.hibernateTab(tab)

    // A ConEmu progress-shaped payload (leading small-integer subcommand) is not a
    // notification body; it must be dropped, not toasted.
    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(9, "4;50"))
    await pump()
    #expect(!state.hasUnseenNotification)
    #expect(state.unreadNotifications().isEmpty)

    // A real notification body still delivers.
    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(9, "Build finished"))
    await waitUntil { state.hasUnseenNotification }
    #expect(state.unreadNotifications().contains { $0.surfaceID == surface && $0.body == "Build finished" })
  }

  @Test func isConEmuOSC9PayloadClassifiesSubcommandsVsBodies() {
    #expect(WorktreeTerminalState.isConEmuOSC9Payload("4;50"))
    #expect(WorktreeTerminalState.isConEmuOSC9Payload("1;420"))
    #expect(WorktreeTerminalState.isConEmuOSC9Payload("12"))
    // Out of the 1...12 subcommand range, or plainly a body: delivered.
    #expect(!WorktreeTerminalState.isConEmuOSC9Payload("13;done"))
    #expect(!WorktreeTerminalState.isConEmuOSC9Payload("Build finished"))
    #expect(!WorktreeTerminalState.isConEmuOSC9Payload("Done"))
    #expect(!WorktreeTerminalState.isConEmuOSC9Payload(""))
  }

  // MARK: - OSC 3008 presence

  @Test func osc3008PresenceForDormantLeafReachesHookFunnel() {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)
    var events: [AgentHookEvent] = []
    state.onAgentHookEvent = { events.append($0) }

    state.hibernateTab(tab)
    // A busy -> idle transition: both reach the same funnel a live surface feeds.
    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(3008, "start=claude;event=busy"))
    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(3008, "start=claude;event=idle"))

    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.surfaceID == surface && $0.agent == "claude" })
    #expect(events.map(\.event) == ["busy", "idle"])
  }

  @Test func osc3008ForUnknownSurfaceIsDropped() {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    var events: [AgentHookEvent] = []
    state.onAgentHookEvent = { events.append($0) }

    state.hibernateTab(tab)
    state.deliverDormantOSCForTesting(surfaceID: UUID(), sequence: osc(3008, "start=claude;event=busy"))

    #expect(events.isEmpty)
  }

  // MARK: - Title

  @Test func titleOSCForDormantLeafUpdatesTabRow() {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(2, "dormant-title"))

    #expect(state.tabManager.tabs.first { $0.id == tab }?.title == "dormant-title")
  }

  @Test func titleOSCForNonFocusedDormantLeafIsIgnored() {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let firstID = firstSurfaceID(state, tab: tab)
    #expect(state.performSplitAction(.newSplit(direction: .right), for: firstID))
    #expect(state.surfaceIDs(inTab: tab).count == 2)

    state.hibernateTab(tab)

    // Resolve the frozen focused vs non-focused leaf from the dormant snapshot.
    let dormantTab = state.captureLayoutSnapshot()?.tabs.first { $0.id == tab.rawValue }
    let leaves = dormantTab?.layout.leafSurfaceIDs ?? []
    #expect(leaves.count == 2)
    let focused = leaves[dormantTab?.focusedLeafIndex ?? 0]
    guard let nonFocused = leaves.first(where: { $0 != focused }) else {
      Issue.record("Expected a non-focused leaf")
      return
    }
    let titleBefore = state.tabManager.tabs.first { $0.id == tab }?.title

    // Only the focused leaf drives the row title; a non-focused leaf's OSC is ignored.
    state.deliverDormantOSCForTesting(surfaceID: nonFocused, sequence: osc(2, "non-focused-title"))

    #expect(state.tabManager.tabs.first { $0.id == tab }?.title == titleBefore)
  }

  @Test func emptyTitleOSCForDormantFocusedLeafIsIgnored() {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    let titleBefore = state.tabManager.tabs.first { $0.id == tab }?.title

    // A whitespace-only title is skipped so the row keeps its prior title.
    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(2, "   "))

    #expect(state.tabManager.tabs.first { $0.id == tab }?.title == titleBefore)
  }

  // MARK: - Wake / close overlap

  @Test func oscForNowLiveSurfaceProcessesOnceWithoutDuplication() async {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    state.wakeTab(tab)
    // The surface is live again; a late watcher delivery is the only source of
    // this OSC (zmx replays screen state, not the raw sequence), so it lands once.
    #expect(state.surfaceIDs(inTab: tab) == [surface])
    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(9, "late"))
    await waitUntil { state.hasUnseenNotification }

    #expect(state.unreadNotifications().filter { $0.surfaceID == surface }.count == 1)
    #expect(state.surfaceIDs(inTab: tab) == [surface])
  }

  @Test func oscForJustClosedSurfaceIsCleanlyDropped() async {
    let state = makeZmxState()
    let tab = state.createTab(focusing: false)!
    let surface = firstSurfaceID(state, tab: tab)

    state.hibernateTab(tab)
    state.closeTab(tab)

    state.deliverDormantOSCForTesting(surfaceID: surface, sequence: osc(9, "gone"))
    await pump()

    #expect(!state.hasTab(tab))
    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(state.unreadNotifications().isEmpty)
  }

  @Test func hibernationDuringUnexpectedCloseProbeIsInert() async {
    let killed = LockIsolated<[String]>([])
    let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
    let state = withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { id in killed.withValue { $0.append(id) } },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: {
          await withCheckedContinuation { gate.setValue($0) }
          return []
        }
      )
    } operation: {
      WorktreeTerminalState(
        runtime: GhosttyRuntime(),
        worktree: makeWorktree(),
        splitPreserveZoomOnNavigation: { false }
      )
    }
    let tab = state.createTab(focusing: false)!
    let view = state.splitTree(for: tab).root!.leftmostLeaf()
    let surface = view.id

    // An unexpected close dispatches the ownership probe, suspended on the gate.
    view.bridge.onCloseRequest?(false)
    await waitUntil { gate.value != nil }

    // The tab hibernates while the probe is in flight, tearing the surface down.
    state.hibernateTab(tab)
    #expect(state.dormantTabLayouts[tab] != nil)

    // The probe resolves for a surface that is no longer live: the
    // `surfaces[id] === view` guard makes it fully inert (no kill, no replace,
    // no resurrection).
    gate.value?.resume()
    await pump()

    #expect(killed.value.isEmpty)
    #expect(state.dormantTabLayouts[tab] != nil)
    // The state is preserved through hibernation with a zero counter; the inert
    // probe neither resurrects a live surface nor mutates it.
    #expect(state.surfaceStates[surface]?.unseenNotificationCount == 0)
    #expect(state.surfaceIDs(inTab: tab) == [surface])
  }

  // MARK: - OSC 3008 payload split

  @Test func contextSignalFieldsSplitsIDAndMetadata() {
    let parsed = WorktreeTerminalState.contextSignalFields(payload: "start=claude;event=busy;pid=42")
    #expect(parsed?.id == "claude")
    #expect(parsed?.metadata == "event=busy;pid=42")

    let idOnly = WorktreeTerminalState.contextSignalFields(payload: "end=claude")
    #expect(idOnly?.id == "claude")
    #expect(idOnly?.metadata == "")

    // No start=/end= prefix, empty id, and over-length id are rejected.
    #expect(WorktreeTerminalState.contextSignalFields(payload: "bogus=claude") == nil)
    #expect(WorktreeTerminalState.contextSignalFields(payload: "start=") == nil)
    #expect(WorktreeTerminalState.contextSignalFields(payload: "start=\(String(repeating: "a", count: 65))") == nil)
  }
}

/// The hibernation Beta gate: the scheduling and fire paths must stay inert while
/// the opt-in flag is off, and a flip must re-arm or cancel accordingly. Isolated
/// via `.dependencies` so this suite's `false` writes to the shared settings never
/// race the parallel suites that seed the flag on.
@MainActor
@Suite(.serialized, .dependencies)
struct HibernationBetaGateTests {
  private func makeWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt-hib-gate"),
      name: "wt-hib-gate",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-hib-gate"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  /// A zmx-eligible state on a real hibernation clock, so a scheduled grace timer
  /// stays pending (never fires) and the scheduled set is assertable.
  private func makeState() -> WorktreeTerminalState {
    withDependencies {
      $0.continuousClock = ImmediateClock()
      $0.date.now = Date(timeIntervalSince1970: 0)
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
    } operation: {
      WorktreeTerminalState(
        runtime: GhosttyRuntime(),
        worktree: makeWorktree(),
        splitPreserveZoomOnNavigation: { false }
      )
    }
  }

  @Test func hiddenTabDoesNotScheduleWhenDisabled() {
    HibernationTestSupport.setHibernation(false)
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    #expect(!state.scheduledHibernationTabsForTesting.contains(tab))
  }

  @Test func hiddenTabSchedulesWhenEnabled() {
    HibernationTestSupport.setHibernation(true)
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))
  }

  @Test func disablingCancelsPendingTimers() {
    HibernationTestSupport.setHibernation(true)
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))

    state.applyHibernationEnabled(false)
    #expect(state.scheduledHibernationTabsForTesting.isEmpty)
  }

  @Test func enablingSchedulesHiddenTabs() {
    HibernationTestSupport.setHibernation(false)
    let state = makeState()
    let tab = state.createTab(focusing: false)!
    #expect(state.scheduledHibernationTabsForTesting.isEmpty)

    state.applyHibernationEnabled(true)
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))
  }

  @Test func firingWhileDisabledDoesNotHibernate() {
    HibernationTestSupport.setHibernation(true)
    let state = makeState()
    let tab = state.createTab(focusing: false)!

    // Flip off mid-window: the fire-time re-check must skip hibernation without re-arming.
    state.applyHibernationEnabled(false)
    state.fireHibernationTimerForTesting(tab)

    #expect(state.dormantTabLayouts[tab] == nil)
    #expect(!state.scheduledHibernationTabsForTesting.contains(tab))
  }

  @Test func managerFanOutTogglesTimersAcrossStates() {
    let manager = withDependencies {
      $0.zmxClient = ZmxClient(
        executableURL: { URL(fileURLWithPath: "/usr/bin/true") },
        isBundled: { true },
        killSession: { _ in },
        killRemoteSession: { _, _ in },
        listSessionsWithClients: { [] }
      )
      $0.settingsFileStorage = .inMemory()
    } operation: {
      WorktreeTerminalManager(runtime: GhosttyRuntime(), clock: TestClock())
    }
    manager.saveLayoutSnapshot = { _, _ in }
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    // Drive the flag purely through the fan-out command (the production path).
    manager.handleCommand(.setTerminalHibernationEnabled(true))
    let tab = state.createTab(focusing: false)!
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))

    // Flag off fans out a cancel to every state.
    manager.handleCommand(.setTerminalHibernationEnabled(false))
    #expect(state.scheduledHibernationTabsForTesting.isEmpty)

    // Flag on re-arms grace timers for the still-hidden tab.
    manager.handleCommand(.setTerminalHibernationEnabled(true))
    #expect(state.scheduledHibernationTabsForTesting.contains(tab))
  }
}
