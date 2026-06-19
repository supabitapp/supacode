import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct RepositoriesFeatureSidebarTests {
  @Test func reconcileClearsPullRequestWatermarkOnBranchRename() {
    let worktreeID: Worktree.ID = "/tmp/repo/wt-feature"
    let repoID: Repository.ID = "/tmp/repo/"
    let original = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
    )
    var state = makeState(
      repository: Repository(
        id: repoID,
        rootURL: URL(fileURLWithPath: repoID.rawValue),
        name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [original])
      ))
    RepositoriesFeature.syncSidebar(&state)
    state.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = "feature"

    let renamed = Worktree(
      id: worktreeID,
      name: "feature-renamed",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
    )
    state.repositories[id: repoID] = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [renamed])
    )
    RepositoriesFeature.syncSidebar(&state)

    #expect(state.sidebarItems[id: worktreeID]?.branchName == "feature-renamed")
    #expect(state.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime == nil)
  }

  @Test func runningScriptsSurviveReconcile() {
    let worktreeID: Worktree.ID = "/tmp/repo/wt-feature"
    let repoID: Repository.ID = "/tmp/repo/"
    let worktree = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
    )
    var state = makeState(
      repository: Repository(
        id: repoID,
        rootURL: URL(fileURLWithPath: repoID.rawValue),
        name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [worktree])
      ))
    RepositoriesFeature.syncSidebar(&state)
    let scriptA = UUID()
    let scriptB = UUID()
    state.sidebarItems[id: worktreeID]?.runningScripts[id: scriptA] = .init(id: scriptA, tint: .blue)
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == [scriptA])
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts[id: scriptA]?.tint == .blue)

    state.sidebarItems[id: worktreeID]?.runningScripts[id: scriptB] = .init(id: scriptB, tint: .orange)
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == [scriptA, scriptB])

    state.sidebarItems[id: worktreeID]?.runningScripts.remove(id: scriptA)
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.map(\.id) == [scriptB])

    state.sidebarItems[id: worktreeID]?.runningScripts.removeAll()
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: worktreeID]?.runningScripts.isEmpty == true)
  }

  @Test func inFlightRowSurvivesTransientRosterDrop() {
    let worktreeID: Worktree.ID = "/tmp/repo/wt-feature"
    let repoID: Repository.ID = "/tmp/repo/"
    let worktree = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
    )
    var state = makeState(
      repository: Repository(
        id: repoID,
        rootURL: URL(fileURLWithPath: repoID.rawValue),
        name: "repo",
        worktrees: IdentifiedArray(uniqueElements: [worktree])
      ))
    RepositoriesFeature.syncSidebar(&state)
    state.sidebarItems[id: worktreeID]?.lifecycle = .archiving
    XCTAssertSidebarConsistent(state)

    // Simulate transient roster drop (e.g. archive script clearing the
    // worktree from the live roster mid-flight).
    state.repositories[id: repoID] = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "repo",
      worktrees: []
    )
    RepositoriesFeature.syncSidebar(&state)

    // The row is carried forward because lifecycle != .idle.
    #expect(state.sidebarItems[id: worktreeID]?.lifecycle == .archiving)
    XCTAssertSidebarConsistent(state)

    // Roster restores the worktree.
    state.repositories[id: repoID] = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    RepositoriesFeature.syncSidebar(&state)

    // Lifecycle is preserved across the round-trip.
    #expect(state.sidebarItems[id: worktreeID]?.lifecycle == .archiving)
    XCTAssertSidebarConsistent(state)
  }

  @Test func pullRequestsLoadedClearsWatermarkOnIdenticalPullRequest() async {
    let repoID: Repository.ID = "/tmp/repo"
    let worktreeID: Worktree.ID = "/tmp/repo/wt-feature"
    let worktree = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    let pullRequest = GithubPullRequest(
      number: 7,
      title: "Live",
      state: "OPEN",
      additions: 1,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/7",
      headRefName: "feature",
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "tester",
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.sidebarItems[id: worktreeID]?.pullRequest = pullRequest
    state.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = "feature"
    state.inFlightPullRequestBranchSnapshotsByRepositoryID[repoID] = [worktreeID: "feature"]

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repoID,
        pullRequestsByWorktreeID: [worktreeID: pullRequest]
      )
    )
    await store.receive(\.sidebarItems[id: worktreeID].pullRequestChanged) {
      $0.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = nil
    }
    await store.finish()
    #expect(store.state.sidebarItems[id: worktreeID]?.pullRequest == pullRequest)
  }

  @Test func pullRequestsLoadedClearsWatermarkForQueriedButMissingWorktree() async {
    // Worktree was included in the request snapshot but absent from the response
    // (e.g. branch deleted upstream); the row must still receive
    // `pullRequestChanged` so its watermark clears and the next refresh is eligible.
    let repoID: Repository.ID = "/tmp/repo"
    let worktreeID: Worktree.ID = "/tmp/repo/wt-feature"
    let worktree = Worktree(
      id: worktreeID,
      name: "feature",
      detail: "",
      workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [worktree])
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = "feature"
    state.inFlightPullRequestBranchSnapshotsByRepositoryID[repoID] = [worktreeID: "feature"]

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryPullRequestsLoaded(repositoryID: repoID, pullRequestsByWorktreeID: [:])
    )
    await store.receive(\.sidebarItems[id: worktreeID].pullRequestChanged) {
      $0.sidebarItems[id: worktreeID]?.pullRequestBranchAtQueryTime = nil
    }
    await store.finish()
    #expect(store.state.sidebarItems[id: worktreeID]?.pullRequest == nil)
  }

  @Test(.dependencies) func reconcileSeedsSurfaceIDsFromPersistedLayout() throws {
    let worktreeID: Worktree.ID = "/tmp/repo/wt-feature"
    let repoID: Repository.ID = "/tmp/repo/"
    let surfaceA = UUID()
    let surfaceB = UUID()
    let layout = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .split(
            TerminalLayoutSnapshot.SplitSnapshot(
              direction: .horizontal,
              ratio: 0.5,
              left: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: surfaceA, workingDirectory: nil)),
              right: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: surfaceB, workingDirectory: nil))
            )
          ),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    let storage = InMemorySettingsFileStorage()
    let payload = try JSONEncoder().encode([worktreeID.rawValue: layout])
    try storage.save(payload, SupacodePaths.layoutsURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
    } operation: {
      let worktree = Worktree(
        id: worktreeID,
        name: "feature",
        detail: "",
        workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
        repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
      )
      var state = RepositoriesFeature.State()
      state.repositories = IdentifiedArray(
        uniqueElements: [
          Repository(
            id: repoID,
            rootURL: URL(fileURLWithPath: repoID.rawValue),
            name: "repo",
            worktrees: IdentifiedArray(uniqueElements: [worktree])
          )
        ]
      )
      RepositoriesFeature.syncSidebar(&state)

      let seeded = try #require(state.sidebarItems[id: worktreeID])
      #expect(Set(seeded.surfaceIDs) == Set([surfaceA, surfaceB]))
      #expect(state.surfaceToItemID[surfaceA] == worktreeID)
      #expect(state.surfaceToItemID[surfaceB] == worktreeID)
      #expect(state.pendingAgentRehydrateSurfaces == Set([surfaceA, surfaceB]))
    }
  }

  @Test(.dependencies) func reconcileSeedsSurfaceIDsForFolderRepository() throws {
    let rootURL = URL(fileURLWithPath: "/tmp/folder")
    let folderID = Repository.folderWorktreeID(for: rootURL)
    let surfaceA = UUID()
    let layout = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: surfaceA, workingDirectory: nil)),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    let storage = InMemorySettingsFileStorage()
    let payload = try JSONEncoder().encode([folderID.rawValue: layout])
    try storage.save(payload, SupacodePaths.layoutsURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
    } operation: {
      let folderRepository = Repository(
        id: RepositoryID(rootURL.path(percentEncoded: false) + "/"),
        rootURL: rootURL,
        name: "folder",
        worktrees: IdentifiedArray(
          uniqueElements: [
            Worktree(
              id: folderID,
              name: "folder",
              detail: "",
              workingDirectory: rootURL,
              repositoryRootURL: rootURL
            )
          ]
        ),
        isGitRepository: false
      )
      var state = RepositoriesFeature.State()
      state.repositories = IdentifiedArray(uniqueElements: [folderRepository])
      RepositoriesFeature.syncSidebar(&state)
      #expect(state.sidebarItems[id: folderID]?.surfaceIDs == [surfaceA])
      #expect(state.pendingAgentRehydrateSurfaces.contains(surfaceA))
      #expect(state.surfaceToItemID[surfaceA] == folderID)
    }
  }

  @Test(.dependencies) func reconcileDoesNotOverwriteExistingSurfaceIDsWithStaleLayout() throws {
    let worktreeID: Worktree.ID = "/tmp/repo/wt-feature"
    let repoID: Repository.ID = "/tmp/repo/"
    let liveSurface = UUID()
    let staleSurface = UUID()
    let staleLayout = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: staleSurface, workingDirectory: nil)),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    let storage = InMemorySettingsFileStorage()
    try storage.save(try JSONEncoder().encode([worktreeID.rawValue: staleLayout]), SupacodePaths.layoutsURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
    } operation: {
      let worktree = Worktree(
        id: worktreeID,
        name: "feature",
        detail: "",
        workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
        repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
      )
      var state = RepositoriesFeature.State()
      state.repositories = IdentifiedArray(
        uniqueElements: [
          Repository(
            id: repoID,
            rootURL: URL(fileURLWithPath: repoID.rawValue),
            name: "repo",
            worktrees: IdentifiedArray(uniqueElements: [worktree])
          )
        ]
      )
      RepositoriesFeature.syncSidebar(&state)
      // The live projection arrives and replaces the seeded surfaces.
      state.sidebarItems[id: worktreeID]?.surfaceIDs = [liveSurface]
      state.sidebarItems[id: worktreeID]?.hasTerminalProjection = true
      state.pendingAgentRehydrateSurfaces.removeAll()
      RepositoriesFeature.syncSidebar(&state)
      // The carry-forward path must not re-seed from the (now stale) layout.
      #expect(state.sidebarItems[id: worktreeID]?.surfaceIDs == [liveSurface])
      #expect(state.pendingAgentRehydrateSurfaces.isEmpty)
      #expect(state.surfaceToItemID[staleSurface] == nil)
    }
  }

  @Test(.dependencies) func reconcileDoesNotReSeedAfterUserClosedEveryTab() throws {
    let worktreeID: Worktree.ID = "/tmp/repo/wt-feature"
    let repoID: Repository.ID = "/tmp/repo/"
    let staleSurface = UUID()
    let staleLayout = TerminalLayoutSnapshot(
      tabs: [
        TerminalLayoutSnapshot.TabSnapshot(
          id: UUID(),
          title: "tab",
          customTitle: nil,
          icon: nil,
          tintColor: nil,
          layout: .leaf(TerminalLayoutSnapshot.SurfaceSnapshot(id: staleSurface, workingDirectory: nil)),
          focusedLeafIndex: 0
        )
      ],
      selectedTabIndex: 0
    )
    let storage = InMemorySettingsFileStorage()
    try storage.save(try JSONEncoder().encode([worktreeID.rawValue: staleLayout]), SupacodePaths.layoutsURL)

    try withDependencies {
      $0.settingsFileStorage = SettingsFileStorage(
        load: { try storage.load($0) },
        save: { try storage.save($0, $1) }
      )
      $0.defaultAppStorage = .inMemory
    } operation: {
      let worktree = Worktree(
        id: worktreeID,
        name: "feature",
        detail: "",
        workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
        repositoryRootURL: URL(fileURLWithPath: repoID.rawValue)
      )
      var state = RepositoriesFeature.State()
      state.repositories = IdentifiedArray(
        uniqueElements: [
          Repository(
            id: repoID,
            rootURL: URL(fileURLWithPath: repoID.rawValue),
            name: "repo",
            worktrees: IdentifiedArray(uniqueElements: [worktree])
          )
        ]
      )
      RepositoriesFeature.syncSidebar(&state)
      // Simulate the empty projection that arrives when the user closes every
      // tab: surfaceIDs goes to [] but the row has now been claimed by the live
      // `WorktreeTerminalState` (`hasTerminalProjection == true`).
      state.sidebarItems[id: worktreeID]?.surfaceIDs = []
      state.sidebarItems[id: worktreeID]?.hasTerminalProjection = true
      state.pendingAgentRehydrateSurfaces.removeAll()
      RepositoriesFeature.syncSidebar(&state)
      #expect(state.sidebarItems[id: worktreeID]?.surfaceIDs.isEmpty == true)
      #expect(state.pendingAgentRehydrateSurfaces.isEmpty)
      #expect(state.surfaceToItemID[staleSurface] == nil)
    }
  }

  private func makeState(repository: Repository) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    // Seed an empty sidebar section so reducer actions that gate on
    // section presence (e.g. `branchNestExpansionChanged`) behave the
    // same way they would after the production reconcile pass.
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init()
    }
    return state
  }

  // MARK: - branchNestExpansionChanged

  @Test func branchNestExpansionChangedInsertsPrefix() async {
    let repoID: Repository.ID = "/tmp/repo/"
    let store = TestStore(
      initialState: makeState(
        repository: Repository(
          id: repoID,
          rootURL: URL(fileURLWithPath: repoID.rawValue),
          name: "repo",
          worktrees: []
        )
      ),
      reducer: { RepositoriesFeature() }
    )
    store.exhaustivity = .off

    await store.send(
      .branchNestExpansionChanged(
        repositoryID: repoID,
        bucketID: .unpinned,
        prefix: "feature",
        isExpanded: false
      )
    )
    #expect(
      store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.collapsedBranchPrefixes
        == ["feature"]
    )
  }

  @Test func branchNestExpansionChangedRemovesPrefix() async {
    let repoID: Repository.ID = "/tmp/repo/"
    var initialState = makeState(
      repository: Repository(
        id: repoID,
        rootURL: URL(fileURLWithPath: repoID.rawValue),
        name: "repo",
        worktrees: []
      )
    )
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[repoID] = .init(
        buckets: [.unpinned: .init(collapsedBranchPrefixes: ["feature"])]
      )
    }

    let store = TestStore(initialState: initialState, reducer: { RepositoriesFeature() })
    store.exhaustivity = .off

    await store.send(
      .branchNestExpansionChanged(
        repositoryID: repoID,
        bucketID: .unpinned,
        prefix: "feature",
        isExpanded: true
      )
    )
    #expect(
      store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.collapsedBranchPrefixes.isEmpty
        == true
    )
  }

  @Test func collapsedPrefixesAreNeverClearedByBranchNestExpansionAction() async {
    // Toggling the AppStorage grouping switch must not clear `collapsedBranchPrefixes`.
    // The toggle is read-only AppStorage outside the reducer; this test guards the
    // related invariant that the only sidebar mutation that exists touches the field
    // additively, never clearing the set on unrelated transitions.
    let repoID: Repository.ID = "/tmp/repo/"
    var initialState = makeState(
      repository: Repository(
        id: repoID,
        rootURL: URL(fileURLWithPath: repoID.rawValue),
        name: "repo",
        worktrees: []
      )
    )
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[repoID] = .init(
        buckets: [
          .pinned: .init(collapsedBranchPrefixes: ["feature", "feature/tools"]),
          .unpinned: .init(collapsedBranchPrefixes: ["chore"]),
        ]
      )
    }

    let store = TestStore(initialState: initialState, reducer: { RepositoriesFeature() })
    store.exhaustivity = .off

    // Collapse a different prefix; the unrelated entries must stay intact.
    await store.send(
      .branchNestExpansionChanged(
        repositoryID: repoID,
        bucketID: .pinned,
        prefix: "release",
        isExpanded: false
      )
    )
    #expect(
      store.state.sidebar.sections[repoID]?.buckets[.pinned]?.collapsedBranchPrefixes
        == ["feature", "feature/tools", "release"]
    )
    #expect(
      store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.collapsedBranchPrefixes
        == ["chore"]
    )
  }

  @Test func branchNestExpansionChangedRejectsArchivedBucket() async {
    // `.archived` never renders nested rows; the action must refuse to write
    // collapse state into a bucket that has no chevron to drive it.
    let repoID: Repository.ID = "/tmp/repo/"
    let store = TestStore(
      initialState: makeState(
        repository: Repository(
          id: repoID,
          rootURL: URL(fileURLWithPath: repoID.rawValue),
          name: "repo",
          worktrees: []
        )
      ),
      reducer: { RepositoriesFeature() }
    )
    store.exhaustivity = .off

    await store.send(
      .branchNestExpansionChanged(
        repositoryID: repoID,
        bucketID: .archived,
        prefix: "feature",
        isExpanded: false
      )
    )
    #expect(store.state.sidebar.sections[repoID]?.buckets[.archived] == nil)
  }

  @Test func branchNestExpansionChangedIgnoresUnknownRepository() async {
    // The chevron is unreachable without an existing section, so any action
    // hitting this path for an unknown repo is stale UI / deeplink noise.
    // Writing through anyway would materialize a phantom section in
    // `sidebar.json` that nothing else cleans up.
    let knownRepoID: Repository.ID = "/tmp/repo/"
    let unknownRepoID: Repository.ID = "/tmp/other/"
    let store = TestStore(
      initialState: makeState(
        repository: Repository(
          id: knownRepoID,
          rootURL: URL(fileURLWithPath: knownRepoID.rawValue),
          name: "repo",
          worktrees: []
        )
      ),
      reducer: { RepositoriesFeature() }
    )
    store.exhaustivity = .off

    await store.send(
      .branchNestExpansionChanged(
        repositoryID: unknownRepoID,
        bucketID: .unpinned,
        prefix: "feature",
        isExpanded: false
      )
    )
    #expect(store.state.sidebar.sections[unknownRepoID] == nil)
  }

  @Test func branchNestExpansionPinnedAndUnpinnedAreIndependent() async {
    let repoID: Repository.ID = "/tmp/repo/"
    let store = TestStore(
      initialState: makeState(
        repository: Repository(
          id: repoID,
          rootURL: URL(fileURLWithPath: repoID.rawValue),
          name: "repo",
          worktrees: []
        )
      ),
      reducer: { RepositoriesFeature() }
    )
    store.exhaustivity = .off

    await store.send(
      .branchNestExpansionChanged(
        repositoryID: repoID,
        bucketID: .pinned,
        prefix: "feature",
        isExpanded: false
      )
    )
    #expect(
      store.state.sidebar.sections[repoID]?.buckets[.pinned]?.collapsedBranchPrefixes
        == ["feature"]
    )
    #expect(
      store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.collapsedBranchPrefixes ?? []
        == []
    )
  }
}
