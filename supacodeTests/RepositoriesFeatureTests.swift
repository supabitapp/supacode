import Clocks
import ComposableArchitecture
import CustomDump
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct RepositoriesFeatureTests {
  @Test func refreshWorktreesSetsRefreshingStateUntilLoadCompletes() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [worktree] }
    }

    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
    }
  }

  @Test func refreshWorktreesWithoutRootsStopsRefreshingImmediately() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories) {
      $0.isRefreshingWorktrees = false
    }
  }

  @Test func repositoriesLoadedClearsRefreshingState() async {
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.isRefreshingWorktrees = true
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [repository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
    }
  }

  @Test func firstRepositoriesLoadedPreservesMigratedPinnedEntryMissingFromRoster() async {
    // T5 — first-load reconcile must not clobber migrated data.
    // The migrator writes pinned worktree IDs into `sidebar.json`
    // before the first git-roster hydration. If the first
    // `.repositoriesLoaded` tick sees a partial roster (e.g. the
    // `feature` worktree is still loading), the liveness prune
    // would silently drop the migrated pin and the user would
    // lose curation on launch. The reducer guards this by gating
    // the destructive prune on `state.isInitialLoadComplete`:
    // the seed + orphan-preservation passes still run, but the
    // curated `.pinned` items are copied forward verbatim. On
    // the SECOND tick (`isInitialLoadComplete == true`) the
    // prune resumes normally and a still-missing worktree is
    // finally dropped.
    let repoRoot = "/tmp/repo"
    let mainWorktree = Worktree(
      id: repoRoot,
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: repoRoot),
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
    )
    let featureWorktree = makeWorktree(
      id: "/tmp/repo/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    // Initial repository list contains only the main worktree —
    // simulating the transient roster race on first boot where
    // the `feature` worktree hasn't hydrated yet.
    let mainOnlyRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])

    var initialState = RepositoriesFeature.State()
    initialState.repositories = [mainOnlyRepository]
    initialState.repositoryRoots = [mainOnlyRepository.rootURL]
    initialState.isInitialLoadComplete = false
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[repoRoot] = .init(
        buckets: [.pinned: .init(items: [featureWorktree.id: .init()])]
      )
    }

    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // First tick: migrated pin MUST survive the transient roster.
    await store.send(
      .repositoriesLoaded(
        [mainOnlyRepository],
        failures: [],
        roots: [mainOnlyRepository.rootURL],
        animated: false,
      )
    ) {
      $0.isInitialLoadComplete = true
    }
    #expect(
      store.state.sidebar.sections[repoRoot]?.buckets[.pinned]?.items[featureWorktree.id] != nil
    )

    // Second tick with `isInitialLoadComplete == true`: the
    // stale pinned entry is now eligible for the destructive
    // drop because the reducer trusts the roster from load #2
    // onward. The drop happens inside the `$sidebar.withLock`
    // closure so the shared state is mutated in-place.
    await store.send(
      .repositoriesLoaded(
        [mainOnlyRepository],
        failures: [],
        roots: [mainOnlyRepository.rootURL],
        animated: false,
      )
    ) {
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[repoRoot] = .init(buckets: [.pinned: .init(items: [:])])
      }
    }
    #expect(
      store.state.sidebar.sections[repoRoot]?.buckets[.pinned]?.items[featureWorktree.id] == nil
    )
  }

  @Test func selectWorktreeSendsDelegate() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "fox")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(worktree.id)) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectWorktreeCollapsesSidebarSelectedWorktreeIDs() async {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let wt3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(wt1.id)
    initialState.sidebarSelectedWorktreeIDs = [wt1.id, wt2.id, wt3.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(wt2.id)) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func setSidebarSelectedWorktreeIDsKeepsSelectedAndPrunesUnknown() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree1.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .setSidebarSelectedWorktreeIDs(
        [worktree2.id, "/tmp/repo/unknown"]
      )
    ) {
      $0.sidebarSelectedWorktreeIDs = [worktree1.id, worktree2.id]
    }
  }

  @Test func selectArchivedWorktreesClearsSidebarSelectedWorktreeIDs() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree1.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree1.id, worktree2.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectArchivedWorktrees) {
      $0.selection = .archivedWorktrees
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func sidebarSelectionChangedChoosesFirstVisibleWorktreeAndFocusesTerminal() async {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let wt3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(wt1.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .selectionChanged(
        [.worktree(wt3.id), .worktree(wt2.id)],
        focusTerminal: true
      )
    ) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id, wt3.id]
      $0.pendingTerminalFocusWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func sidebarSelectionChangedClearsSelectionWhenEmpty() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectionChanged([])) {
      $0.selection = nil
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func sidebarSelectionChangedArchivesAndClearsSidebarSelection() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree1.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree1.id, worktree2.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectionChanged([.archivedWorktrees])) {
      $0.selection = .archivedWorktrees
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func sidebarRepositoryExpansionChangedUpdatesCollapsedRepositoryIDs() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.repositoryExpansionChanged(repository.id, isExpanded: false)) {
      $0.$sidebar.withLock { $0.sections[repository.id, default: .init()].collapsed = true }
    }

    await store.send(.repositoryExpansionChanged(repository.id, isExpanded: true)) {
      $0.$sidebar.withLock { $0.sections[repository.id, default: .init()].collapsed = false }
    }
  }

  @Test func repositoryExpansionChangedIsIdempotent() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.repositoryExpansionChanged(repository.id, isExpanded: false)) {
      $0.$sidebar.withLock { $0.sections[repository.id, default: .init()].collapsed = true }
    }

    // Collapsing again should be a no-op.
    await store.send(.repositoryExpansionChanged(repository.id, isExpanded: false))
  }

  @Test func sidebarSelectionChangedWithoutFocusTerminalDoesNotInsertPendingFocus() async {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(wt1.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectionChanged([.worktree(wt2.id)])) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    #expect(store.state.pendingTerminalFocusWorktreeIDs.isEmpty)
  }

  @Test func sidebarSelectionChangedKeepsCurrentSelectionDuringMultiSelect() async {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(wt1.id)
    initialState.sidebarSelectedWorktreeIDs = [wt1.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .selectionChanged([.worktree(wt1.id), .worktree(wt2.id)], focusTerminal: true)
    ) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id, wt2.id]
    }
    #expect(store.state.pendingTerminalFocusWorktreeIDs.isEmpty)
  }

  @Test func repositoriesLoadedPrunesCollapsedRepositoryIDs() async {
    let repoAID = "/tmp/repo-a"
    let repoBID = "/tmp/repo-b"
    let repoA = makeRepository(
      id: repoAID,
      worktrees: [makeWorktree(id: "\(repoAID)/wt1", name: "wt1", repoRoot: repoAID)]
    )
    let repoB = makeRepository(
      id: repoBID,
      worktrees: [makeWorktree(id: "\(repoBID)/wt1", name: "wt1", repoRoot: repoBID)]
    )
    let initialState = makeState(repositories: [repoA, repoB])
    initialState.$sidebar.withLock { sidebar in
      for id in [repoA.id, repoB.id, "/tmp/missing"] {
        sidebar.sections[id, default: .init()].collapsed = true
      }
    }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [repoA],
        failures: [],
        roots: [repoA.rootURL],
        animated: false
      )
    ) {
      $0.repositories = [repoA]
      $0.repositoryRoots = [repoA.rootURL]
      $0.$sidebar.withLock { sidebar in
        var rebuilt: OrderedDictionary<Repository.ID, SidebarState.Section> = [:]
        rebuilt[repoA.id] = sidebar.sections[repoA.id] ?? .init()
        sidebar.sections = rebuilt
      }
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func sidebarSelectionChangedWithAllUnknownWorktreeIDsClearsSelection() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectionChanged([.worktree("/tmp/unknown")])) {
      $0.selection = nil
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func sidebarSelectionChangedWithMixedArchivedAndWorktreeSelectsArchived() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectionChanged([.archivedWorktrees, .worktree(worktree.id)])) {
      $0.selection = .archivedWorktrees
      $0.sidebarSelectedWorktreeIDs = []
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func repositoryExpansionChangedMultipleRepositoriesKeepsSortedOrder() async {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a")],
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [makeWorktree(id: "/tmp/repo-b/wt1", name: "wt1", repoRoot: "/tmp/repo-b")],
    )
    let store = TestStore(initialState: makeState(repositories: [repoA, repoB])) {
      RepositoriesFeature()
    }

    // Collapse B first, then A. With the bucketed sidebar there
    // is no "sorted order" of collapsed IDs — collapse state lives
    // per-section, so the assertion is just that the .collapsed
    // bit flips on the targeted section.
    await store.send(.repositoryExpansionChanged(repoB.id, isExpanded: false)) {
      $0.$sidebar.withLock { $0.sections[repoB.id, default: .init()].collapsed = true }
    }
    await store.send(.repositoryExpansionChanged(repoA.id, isExpanded: false)) {
      $0.$sidebar.withLock { $0.sections[repoA.id, default: .init()].collapsed = true }
    }
  }

  @Test func sidebarSelectionChangedSameWorktreeSuppressesDelegateAndFocus() async {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(wt1.id)
    initialState.sidebarSelectedWorktreeIDs = [wt1.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // Re-selecting the same worktree should not fire delegate or insert pending focus.
    await store.send(.selectionChanged([.worktree(wt1.id)], focusTerminal: true))
    #expect(store.state.pendingTerminalFocusWorktreeIDs.isEmpty)
  }

  @Test func repositoriesLoadedFiresDelegateWhenWorktreePropertiesChange() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // Same worktree ID but different workingDirectory triggers delegate.
    let movedWorktree = Worktree(
      id: worktree.id,
      name: worktree.name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/moved-wt1"),
      repositoryRootURL: worktree.repositoryRootURL,
    )
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [movedWorktree])
    await store.send(
      .repositoriesLoaded(
        [updatedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false,
      )
    ) {
      $0.repositories = [updatedRepository]
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func sidebarSelectionChangedWithMixedValidAndInvalidIDsKeepsValidOnly() async {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(wt1.id)
    initialState.sidebarSelectedWorktreeIDs = [wt1.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // Valid ID kept, unknown ID silently dropped.
    await store.send(.selectionChanged([.worktree(wt1.id), .worktree("/tmp/unknown")]))
    #expect(store.state.sidebarSelectedWorktreeIDs == [wt1.id])
  }

  @Test func sidebarSelectionsComputedPropertyReflectsState() {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])

    // No selection.
    #expect(state.sidebarSelections.isEmpty)

    // Single selection.
    state.selection = .worktree(wt1.id)
    #expect(state.sidebarSelections == [.worktree(wt1.id)])

    // Multi-selection includes selectedWorktreeID.
    state.sidebarSelectedWorktreeIDs = [wt2.id]
    #expect(state.sidebarSelections == [.worktree(wt1.id), .worktree(wt2.id)])

    // Archived overrides everything.
    state.selection = .archivedWorktrees
    #expect(state.sidebarSelections == [.archivedWorktrees])
  }

  @Test func effectiveSidebarSelectedRowsFallsBackToSelectedWorktreeID() {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = []

    // Falls back to selectedWorktreeID.
    let fallbackRows = state.effectiveSidebarSelectedRows
    #expect(fallbackRows.count == 1)
    #expect(fallbackRows.first?.id == wt1.id)

    // Primary path: sidebarSelectedWorktreeIDs non-empty.
    state.sidebarSelectedWorktreeIDs = [wt1.id, wt2.id]
    let primaryRows = state.effectiveSidebarSelectedRows
    #expect(primaryRows.count == 2)
  }

  @Test func revealInSidebarExpandsCollapsedRepository() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree.id]
    initialState.$sidebar.withLock { $0.sections[repository.id, default: .init()].collapsed = true }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.revealSelectedWorktreeInSidebar) {
      $0.$sidebar.withLock { $0.sections[repository.id, default: .init()].collapsed = false }
      $0.nextPendingSidebarRevealID = 1
      $0.pendingSidebarReveal = .init(id: 1, worktreeID: worktree.id)
    }
  }

  @Test func revealInSidebarWithNoSelectionIsNoOp() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let initialState = makeState(repositories: [repository])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.revealSelectedWorktreeInSidebar)
  }

  @Test func revealInSidebarKeepsOtherRepositoriesCollapsed() async {
    let worktree1 = makeWorktree(id: "/tmp/repo-a/wt", name: "wt", repoRoot: "/tmp/repo-a")
    let worktree2 = makeWorktree(id: "/tmp/repo-b/wt", name: "wt", repoRoot: "/tmp/repo-b")
    let repoA = makeRepository(id: "/tmp/repo-a", worktrees: [worktree1])
    let repoB = makeRepository(id: "/tmp/repo-b", worktrees: [worktree2])
    var initialState = makeState(repositories: [repoA, repoB])
    initialState.selection = .worktree(worktree1.id)
    initialState.sidebarSelectedWorktreeIDs = [worktree1.id]
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[repoA.id, default: .init()].collapsed = true
      sidebar.sections[repoB.id, default: .init()].collapsed = true
    }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.revealSelectedWorktreeInSidebar) {
      $0.$sidebar.withLock { $0.sections[repoA.id, default: .init()].collapsed = false }
      $0.nextPendingSidebarRevealID = 1
      $0.pendingSidebarReveal = .init(id: 1, worktreeID: worktree1.id)
    }
  }

  @Test func consumePendingSidebarRevealClearsMatchingRequest() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.nextPendingSidebarRevealID = 1
    initialState.pendingSidebarReveal = .init(id: 1, worktreeID: worktree.id)
    let pendingSidebarReveal = initialState.pendingSidebarReveal
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.consumePendingSidebarReveal(pendingSidebarReveal!.id)) {
      $0.pendingSidebarReveal = nil
    }
  }

  @Test func createRandomWorktreeWithoutRepositoriesShowsAlert() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Open a repository to create a worktree.")
    }

    await store.send(.createRandomWorktree) {
      $0.alert = expectedAlert
    }
  }

  @Test func createRandomWorktreeInRepositoryWithPromptEnabledPresentsPrompt() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.branchRefs = { _ in ["origin/main", "origin/dev"] }
    }

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.promptedWorktreeCreationDataLoaded) {
      $0.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repository.id,
        repositoryName: repository.name,
        automaticBaseRef: "origin/main",
        baseRefOptions: ["origin/dev", "origin/main"],
        branchName: "",
        selectedBaseRef: nil,
        fetchOrigin: true,
        validationMessage: nil
      )
    }
  }

  @Test func promptedWorktreeCreationCancelDismissesPrompt() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      baseRefOptions: ["origin/main"],
      branchName: "feature/new-branch",
      selectedBaseRef: nil,
      fetchOrigin: true,
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeCreationPrompt(.presented(.delegate(.cancel)))) {
      $0.worktreeCreationPrompt = nil
    }
  }

  @Test(.dependencies) func promptedWorktreeCreationSubmitThreadsFetchOrigin() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/feature-new",
      name: "feature/new",
      repoRoot: repoRoot,
    )
    let fetchedRemote = LockIsolated<String?>(nil)
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      baseRefOptions: ["origin/main"],
      branchName: "feature/new",
      selectedBaseRef: nil,
      fetchOrigin: true,
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { remote, _ in
        fetchedRemote.withValue { $0 = remote }
      }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeCreationPrompt(
        .presented(
          .delegate(
            .submit(
              repositoryID: repository.id,
              branchName: "feature/new",
              baseRef: nil,
              fetchOrigin: true
            )
          )
        )
      )
    )
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(fetchedRemote.value == "origin")
  }

  @Test func startPromptedWorktreeCreationWithDuplicateLocalBranchShowsValidation() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      baseRefOptions: ["origin/main"],
      branchName: "feature/existing",
      selectedBaseRef: nil,
      fetchOrigin: true,
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.localBranchNames = { _ in ["feature/existing"] }
    }

    await store.send(
      .startPromptedWorktreeCreation(
        repositoryID: repository.id,
        branchName: "feature/existing",
        baseRef: nil,
        fetchOrigin: true
      )
    ) {
      $0.worktreeCreationPrompt?.validationMessage = nil
      $0.worktreeCreationPrompt?.isValidating = true
    }
    await store.receive(\.promptedWorktreeCreationChecked) {
      $0.worktreeCreationPrompt?.validationMessage = "Branch name already exists."
      $0.worktreeCreationPrompt?.isValidating = false
    }
  }

  @Test func createRandomWorktreeInRepositoryLatestPromptRequestWins() async {
    actor PromptLoadGate {
      var continuation: CheckedContinuation<Void, Never>?

      func wait() async {
        await withCheckedContinuation { continuation in
          self.continuation = continuation
        }
      }

      func waitUntilArmed() async {
        while continuation == nil {
          await Task.yield()
        }
      }

      func resume() {
        continuation?.resume()
        continuation = nil
      }
    }

    let repoRootA = "/tmp/repo-a"
    let repoRootB = "/tmp/repo-b"
    let promptLoadGate = PromptLoadGate()
    let repoA = makeRepository(
      id: repoRootA,
      worktrees: [makeWorktree(id: repoRootA, name: "main", repoRoot: repoRootA)]
    )
    let repoB = makeRepository(
      id: repoRootB,
      worktrees: [makeWorktree(id: repoRootB, name: "main", repoRoot: repoRootB)]
    )
    let store = TestStore(initialState: makeState(repositories: [repoA, repoB])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.automaticWorktreeBaseRef = { root in
        if root.path(percentEncoded: false) == repoRootA {
          await promptLoadGate.wait()
        }
        return "origin/main"
      }
      $0.gitClient.branchRefs = { _ in ["origin/main"] }
    }

    await store.send(.createRandomWorktreeInRepository(repoA.id))
    await promptLoadGate.waitUntilArmed()
    await store.send(.createRandomWorktreeInRepository(repoB.id))
    await promptLoadGate.resume()
    await store.receive(\.promptedWorktreeCreationDataLoaded) {
      $0.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repoB.id,
        repositoryName: repoB.name,
        automaticBaseRef: "origin/main",
        baseRefOptions: ["origin/main"],
        branchName: "",
        selectedBaseRef: nil,
        fetchOrigin: true,
        validationMessage: nil
      )
    }
    await store.finish()
  }

  @Test func promptedWorktreeCreationCancelDuringValidationStopsCreation() async {
    let validationClock = TestClock()
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      baseRefOptions: ["origin/main"],
      branchName: "feature/new-branch",
      selectedBaseRef: nil,
      fetchOrigin: true,
      validationMessage: nil
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.localBranchNames = { _ in
        try? await validationClock.sleep(for: .seconds(1))
        return []
      }
    }

    await store.send(
      .startPromptedWorktreeCreation(
        repositoryID: repository.id,
        branchName: "feature/new-branch",
        baseRef: nil,
        fetchOrigin: true
      )
    ) {
      $0.worktreeCreationPrompt?.validationMessage = nil
      $0.worktreeCreationPrompt?.isValidating = true
    }
    await store.send(.worktreeCreationPrompt(.presented(.delegate(.cancel)))) {
      $0.worktreeCreationPrompt = nil
    }
    await validationClock.advance(by: .seconds(1))
    await store.finish()
  }

  @Test func createWorktreeInRepositoryWithInvalidBranchNameFails() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.isValidBranchName = { _, _ in false }
      $0.gitClient.localBranchNames = { _ in [] }
    }
    store.exhaustivity = .off

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name invalid")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Enter a valid git branch name and try again.")
    }

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repository.id,
        nameSource: .explicit("../../Desktop"),
        baseRefSource: .repositorySetting,
        fetchOrigin: false
      )
    )
    await store.receive(\.createRandomWorktreeFailed) {
      $0.alert = expectedAlert
    }
    #expect(store.state.pendingWorktrees.isEmpty)
    await store.finish()
  }

  @Test func createWorktreeInRepositoryPreservesExplicitNameDuringInitialProgressUpdate() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let pendingID = "pending:00000000-0000-0000-0000-000000000001"
    let validationClock = TestClock()
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .constant(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
      $0.gitClient.localBranchNames = { _ in
        try await validationClock.sleep(for: .seconds(1))
        return []
      }
      $0.gitClient.isValidBranchName = { _, _ in false }
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name invalid")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Enter a valid git branch name and try again.")
    }

    await store.send(
      RepositoriesFeature.Action.createWorktreeInRepository(
        repositoryID: repository.id,
        nameSource: .explicit("feature/new-branch"),
        baseRefSource: .repositorySetting,
        fetchOrigin: false
      )
    ) {
      $0.pendingWorktrees = [
        PendingWorktree(
          id: pendingID,
          repositoryID: repository.id,
          progress: WorktreeCreationProgress(
            stage: .loadingLocalBranches,
            worktreeName: "feature/new-branch"
          )
        )
      ]
      $0.selection = SidebarSelection.worktree(pendingID)
      $0.sidebarSelectedWorktreeIDs = [pendingID]
    }

    await store.receive(\.pendingWorktreeProgressUpdated)
    #expect(
      store.state.pendingWorktrees[0].progress
        == WorktreeCreationProgress(
          stage: .loadingLocalBranches,
          worktreeName: "feature/new-branch"
        ))

    await validationClock.advance(by: .seconds(1))

    await store.receive(\.createRandomWorktreeFailed) {
      $0.pendingWorktrees = []
      $0.selection = nil
      $0.sidebarSelectedWorktreeIDs = []
      $0.alert = expectedAlert
    }
    await store.finish()
  }

  @Test func createRandomWorktreeFailedWithTraversalNameSkipsCleanup() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let removed = LockIsolated(false)
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in
        removed.withValue { $0 = true }
        return URL(fileURLWithPath: "/tmp/removed")
      }
      $0.gitClient.pruneWorktrees = { _ in }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .createRandomWorktreeFailed(
        title: "Unable to create worktree",
        message: "boom",
        pendingID: "pending:1",
        previousSelection: nil,
        repositoryID: repository.id,
        name: "../../Desktop",
        baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees")
      )
    ) {
      $0.alert = expectedAlert
    }
    await store.finish()
    #expect(removed.value == false)
  }

  @Test(.dependencies) func createRandomWorktreeInRepositoryStreamsOutputLines() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.promptForWorktreeCreation = false }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 2 }
      $0.gitClient.untrackedFileCount = { _ in 1 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[1/2] copy .env")))
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[2/2] copy .cache")))
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(store.state.selection == .worktree(createdWorktree.id))
    #expect(store.state.sidebarSelectedWorktreeIDs == [createdWorktree.id])
    #expect(store.state.pendingSetupScriptWorktreeIDs.contains(createdWorktree.id))
    #expect(store.state.pendingTerminalFocusWorktreeIDs.contains(createdWorktree.id))
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: createdWorktree.id] != nil)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func createWorktreeFetchesRemoteWhenEnabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot,
    )
    let fetchedRemote = LockIsolated<String?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = true
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { remote, _ in
        fetchedRemote.withValue { $0 = remote }
      }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(fetchedRemote.value == "origin")
  }

  @Test(.dependencies) func createWorktreeSkipsFetchWhenDisabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot,
    )
    let fetchCalled = LockIsolated(false)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = false
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { _, _ in
        fetchCalled.withValue { $0 = true }
      }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(fetchCalled.value == false)
  }

  @Test(.dependencies) func createWorktreeProceedsWhenFetchFails() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot,
    )
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = true
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { _, _ in
        throw GitClientError.commandFailed(command: "git fetch", message: "network error")
      }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func createWorktreeSkipsFetchForLocalRef() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot,
    )
    let fetchCalled = LockIsolated(false)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = true
    }
    @Shared(.repositorySettings(URL(fileURLWithPath: repoRoot))) var repoSettings
    $repoSettings.withLock { $0.worktreeBaseRef = "main" }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.fetchRemote = { _, _ in
        fetchCalled.withValue { $0 = true }
      }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(fetchCalled.value == false)
  }

  @Test(.dependencies) func createWorktreeFetchesCorrectRemoteWithAmbiguousPrefixes() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot,
    )
    let fetchedRemote = LockIsolated<String?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = true
    }
    @Shared(.repositorySettings(URL(fileURLWithPath: repoRoot))) var repoSettings
    $repoSettings.withLock { $0.worktreeBaseRef = "origin-fork/main" }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.remoteNames = { _ in ["origin", "origin-fork"] }
      $0.gitClient.fetchRemote = { remote, _ in
        fetchedRemote.withValue { $0 = remote }
      }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(fetchedRemote.value == "origin-fork")
  }

  @Test(.dependencies) func createWorktreeSkipsFetchWhenRemoteNamesThrows() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot,
    )
    let fetchCalled = LockIsolated(false)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.fetchOriginBeforeWorktreeCreation = true
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.remoteNames = { _ in
        throw GitClientError.commandFailed(command: "git remote", message: "not a git repo")
      }
      $0.gitClient.fetchRemote = { _, _ in
        fetchCalled.withValue { $0 = true }
      }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    #expect(fetchCalled.value == false)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func createRandomWorktreeUsesRepositoryWorktreeBaseDirectoryOverride() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let observedBaseDirectory = LockIsolated<URL?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/global-worktrees"
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.worktreeBaseDirectoryPath = "/tmp/repo-override"
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _, _, baseDirectory, _, _, _ in
        observedBaseDirectory.withValue { $0 = baseDirectory }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    let expectedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/global-worktrees",
      repositoryOverridePath: "/tmp/repo-override"
    )
    #expect(observedBaseDirectory.value == expectedBaseDirectory)
  }

  @Test(.dependencies) func createRandomWorktreeUsesGlobalWorktreeBaseDirectoryWhenRepositoryOverrideMissing() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/repo/swift-otter",
      name: "swift-otter",
      repoRoot: repoRoot
    )
    let observedBaseDirectory = LockIsolated<URL?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.promptForWorktreeCreation = false
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/global-worktrees"
    }
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.worktreeBaseDirectoryPath = nil
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _, _, baseDirectory, _, _, _ in
        observedBaseDirectory.withValue { $0 = baseDirectory }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    let expectedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/global-worktrees",
      repositoryOverridePath: nil
    )
    #expect(observedBaseDirectory.value == expectedBaseDirectory)
  }

  @Test(.dependencies) func createRandomWorktreeInRepositoryStreamFailureRemovesPendingWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.promptForWorktreeCreation = false }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 2 }
      $0.gitClient.untrackedFileCount = { _ in 1 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.outputLine(ShellStreamLine(source: .stderr, text: "[1/2] copy .env")))
          continuation.finish(throwing: GitClientError.commandFailed(command: "wt sw", message: "boom"))
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.createRandomWorktreeFailed)
    await store.finish()

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Git command failed: wt sw\nboom")
    }

    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(store.state.selection == nil)
    #expect(store.state.alert == expectedAlert)
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: mainWorktree.id] != nil)
  }

  @Test(.dependencies) func createRandomWorktreeFailureUsesProvidedBaseDirectoryForCleanup() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createTimeBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/worktrees-original",
      repositoryOverridePath: nil
    )
    let changedBaseDirectory = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: "/tmp/worktrees-changed",
      repositoryOverridePath: nil
    )
    let removedWorktreePath = LockIsolated<String?>(nil)
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock {
      $0.global.defaultWorktreeBaseDirectoryPath = "/tmp/worktrees-changed"
    }
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in
        let workingDirectory = await MainActor.run { worktree.workingDirectory }
        removedWorktreePath.withValue { $0 = workingDirectory.path(percentEncoded: false) }
        return workingDirectory
      }
      $0.gitClient.pruneWorktrees = { _ in }
    }
    store.exhaustivity = .off

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .createRandomWorktreeFailed(
        title: "Unable to create worktree",
        message: "boom",
        pendingID: "pending:test",
        previousSelection: nil,
        repositoryID: repository.id,
        name: "new-branch",
        baseDirectory: createTimeBaseDirectory
      )
    ) {
      $0.alert = expectedAlert
    }
    await store.finish()

    #expect(changedBaseDirectory != createTimeBaseDirectory)
    #expect(removedWorktreePath.value != nil)
    #expect(
      removedWorktreePath.value
        == createTimeBaseDirectory
        .appending(path: "new-branch", directoryHint: .isDirectory)
        .path(percentEncoded: false)
    )
    #expect(
      removedWorktreePath.value
        != changedBaseDirectory
        .appending(path: "new-branch", directoryHint: .isDirectory)
        .path(percentEncoded: false)
    )
  }

  @Test func pendingProgressUpdateUpdatesPendingWorktreeState() async {
    let repoRoot = "/tmp/repo"
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)]
    )
    let pendingID = "pending:test"
    var state = makeState(repositories: [repository])
    state.selection = .worktree(pendingID)
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches)
      )
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let nextProgress = WorktreeCreationProgress(
      stage: .creatingWorktree,
      worktreeName: "swift-otter",
      baseRef: "origin/main",
      copyIgnored: false,
      copyUntracked: true
    )
    await store.send(
      .pendingWorktreeProgressUpdated(
        id: pendingID,
        progress: nextProgress
      )
    ) {
      $0.pendingWorktrees[0].progress = nextProgress
    }
  }

  @Test func pendingProgressUpdateIsIgnoredAfterCreateFailureRemovesPendingWorktree() async {
    let repoRoot = "/tmp/repo"
    let repository = makeRepository(id: repoRoot, worktrees: [makeWorktree(id: repoRoot, name: "main")])
    let pendingID = "pending:test"
    var state = makeState(repositories: [repository])
    state.selection = .worktree(pendingID)
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(
          stage: .checkingRepositoryMode,
          worktreeName: "swift-otter"
        )
      )
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Unable to create worktree")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("boom")
    }

    await store.send(
      .createRandomWorktreeFailed(
        title: "Unable to create worktree",
        message: "boom",
        pendingID: pendingID,
        previousSelection: nil,
        repositoryID: repository.id,
        name: nil,
        baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees")
      )
    ) {
      $0.pendingWorktrees = []
      $0.selection = nil
      $0.alert = expectedAlert
    }

    await store.send(
      .pendingWorktreeProgressUpdated(
        id: pendingID,
        progress: WorktreeCreationProgress(stage: .creatingWorktree)
      )
    )
    #expect(store.state.pendingWorktrees.isEmpty)
  }

  @Test func requestDeleteSidebarItemShowsConfirmation() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let target = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: worktree.id, repositoryID: repository.id)
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("🚨 Delete worktree?")
    } actions: {
      ButtonState(
        role: .destructive,
        action: .confirmDeleteSidebarItems([target], disposition: .gitWorktreeDelete)
      ) {
        TextState("Delete (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Delete \(worktree.name)? This deletes the worktree directory and its local branch.")
    }

    await store.send(.requestDeleteSidebarItems([target])) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestDeleteMainWorktreeShowsNotAllowedAlertForSingleTarget() async {
    // Single-target main git worktree delete (palette / hotkey /
    // context-menu) surfaces the same "Delete not allowed" alert the
    // deeplink path shows, so every entry point has consistent
    // feedback instead of silently no-opping.
    let mainWorktree = makeWorktree(id: "/tmp/repo", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [mainWorktree])

    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let target = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: mainWorktree.id, repositoryID: repository.id)
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Delete not allowed")
    } actions: {
      ButtonState(role: .cancel) { TextState("OK") }
    } message: {
      TextState("Deleting the main worktree is not allowed.")
    }
    await store.send(.requestDeleteSidebarItems([target])) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestDeleteMainWorktreeInBulkRemainsSilentlyFiltered() async {
    // Bulk selection that mixes the main worktree with an actual
    // deletable target must keep the main filter silent so the rest
    // of the batch proceeds; only single-target rejections surface
    // feedback.
    let mainWorktree = makeWorktree(id: "/tmp/repo", name: "main")
    let feature = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [mainWorktree, feature])

    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let targets = [
      RepositoriesFeature.DeleteWorktreeTarget(
        worktreeID: mainWorktree.id, repositoryID: repository.id),
      RepositoriesFeature.DeleteWorktreeTarget(
        worktreeID: feature.id, repositoryID: repository.id),
    ]
    await store.send(.requestDeleteSidebarItems(targets)) {
      $0.alert = AlertState {
        TextState("🚨 Delete worktree?")
      } actions: {
        ButtonState(
          role: .destructive,
          action: .confirmDeleteSidebarItems([targets[1]], disposition: .gitWorktreeDelete)
        ) {
          TextState("Delete (⌘↩)")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "Delete \(feature.name)? This deletes the worktree directory and its local branch."
        )
      }
    }
  }
  @Test func requestDeleteSidebarItemsShowsBatchConfirmation() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "owl", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "hawk", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    let targets = [
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree1.id, repositoryID: repository.id),
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktree2.id, repositoryID: repository.id),
    ]
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("🚨 Delete 2 worktrees?")
    } actions: {
      ButtonState(
        role: .destructive,
        action: .confirmDeleteSidebarItems(targets, disposition: .gitWorktreeDelete)
      ) {
        TextState("Delete 2 (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Delete 2 worktrees? This deletes the worktree directories and their local branches.")
    }

    await store.send(.requestDeleteSidebarItems(targets)) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestArchiveWorktreeShowsConfirmation() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let archivedDisplay = AppShortcuts.archivedWorktrees.display
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive worktree?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchiveWorktree(worktree.id, repository.id)) {
        TextState("Archive (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "You can find \(worktree.name) later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay))."
      )
    }

    await store.send(.requestArchiveWorktree(worktree.id, repository.id)) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestArchiveWorktreeForFolderShowsActionNotAvailable() async {
    // S1: the deeplink layer rejects archive/pin/unpin on folders,
    // but the hotkey / context-menu path used to silently no-op
    // because the synthetic main-worktree satisfies `isMainWorktree`
    // geometrically. Surface the same "Action not available" alert
    // the deeplink shows.
    let folderRoot = "/tmp/folder-archive-\(UUID().uuidString)"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL), detail: "",
      workingDirectory: folderURL, repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot, rootURL: folderURL, name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )
    let store = TestStore(initialState: makeState(repositories: [folderRepo])) {
      RepositoriesFeature()
    }

    // The helper produces a per-action title + body so users know
    // which action they just tried. Keep each expected alert
    // narrow to the one being exercised.
    func expectedAlert(name: String) -> AlertState<RepositoriesFeature.Alert> {
      AlertState {
        TextState("\(name) not available")
      } actions: {
        ButtonState(role: .cancel) { TextState("OK") }
      } message: {
        TextState("\(name) only applies to git repositories.")
      }
    }
    await store.send(.requestArchiveWorktree(folderWorktree.id, folderRepo.id)) {
      $0.alert = expectedAlert(name: "Archive")
    }
    await store.send(.alert(.dismiss)) { $0.alert = nil }
    await store.send(.pinWorktree(folderWorktree.id)) {
      $0.alert = expectedAlert(name: "Pin")
    }
    await store.send(.alert(.dismiss)) { $0.alert = nil }
    await store.send(.unpinWorktree(folderWorktree.id)) {
      $0.alert = expectedAlert(name: "Unpin")
    }
  }

  @Test func requestArchiveWorktreesShowsBatchConfirmation() async {
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "owl", repoRoot: "/tmp/repo")
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "hawk", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree1, worktree2])
    let targets = [
      RepositoriesFeature.ArchiveWorktreeTarget(worktreeID: worktree1.id, repositoryID: repository.id),
      RepositoriesFeature.ArchiveWorktreeTarget(worktreeID: worktree2.id, repositoryID: repository.id),
    ]
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let archivedDisplay = AppShortcuts.archivedWorktrees.display
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive 2 worktrees?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmArchiveWorktrees(targets)) {
        TextState("Archive 2 (⌘↩)")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        "You can find them later in Menu Bar > Worktrees > Archived Worktrees (\(archivedDisplay))."
      )
    }

    await store.send(.requestArchiveWorktrees(targets)) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestArchiveWorktreeMergedArchivesImmediately() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(featureWorktree.id)
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [.pinned: .init(items: [featureWorktree.id: .init()])]
      )
    }
    state.worktreeInfoByID = [
      featureWorktree.id: WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: makePullRequest(state: "MERGED")
      )
    ]
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    // Exhaustive receive closures on the archive chain are too
    // noisy to assert line-by-line — TCA processes synchronous
    // `.send` follow-ups inside the original `send`, so
    // `archivingWorktreeIDs` + selection + sidebar transitions
    // land in one tick and the diff drowns out the actual
    // coverage we care about. Relax exhaustivity and pin the
    // meaningful end state via `#expect` below.
    store.exhaustivity = .off

    await store.send(.requestArchiveWorktree(featureWorktree.id, repository.id))
    await store.receive(\.archiveWorktreeApply)
    #expect(
      store.state.sidebar.sections[repository.id]?
        .buckets[.archived]?.items[featureWorktree.id]?.archivedAt == fixedDate
    )
    #expect(store.state.sidebar.sections[repository.id]?.buckets[.pinned]?.items[featureWorktree.id] == nil)
    #expect(store.state.selection == .worktree(mainWorktree.id))
  }

  @Test(.dependencies) func archiveWorktreeConfirmedDelegatesArchiveScript() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(mainWorktree.id)
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.archiveScript = "echo syncing\necho done"
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveWorktreeConfirmed(featureWorktree.id, repository.id)) {
      $0.archivingWorktreeIDs = [featureWorktree.id]
    }
    await store.receive(\.delegate.runBlockingScript)
  }

  @Test(.dependencies) func scriptCompletedWithFailureShowsAlert() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let definition = ScriptDefinition(kind: .run, name: "Run", command: "npm start")
    var state = makeState(repositories: [repository])
    state.runningScriptsByWorktreeID = [worktree.id: [definition.id]]

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        scriptID: definition.id,
        kind: .script(definition),
        exitCode: 1,
        tabId: nil
      )
    ) {
      $0.runningScriptsByWorktreeID = [:]

      $0.alert = expectedScriptFailureAlert(
        kind: .script(definition),
        exitMessage: "Script failed (exit code 1).",
        worktreeID: worktree.id,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
  }

  @Test(.dependencies) func scriptCompletedWithSuccessDoesNotShowAlert() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let definition = ScriptDefinition(kind: .run, name: "Run", command: "npm start")
    var state = makeState(repositories: [repository])
    state.runningScriptsByWorktreeID = [worktree.id: [definition.id]]

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        scriptID: definition.id,
        kind: .script(definition),
        exitCode: 0,
        tabId: nil
      )
    ) {
      $0.runningScriptsByWorktreeID = [:]

    }
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func scriptCompletedWithNilExitCodeDoesNotShowAlert() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let definition = ScriptDefinition(kind: .run, name: "Run", command: "npm start")
    var state = makeState(repositories: [repository])
    state.runningScriptsByWorktreeID = [worktree.id: [definition.id]]

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        scriptID: definition.id,
        kind: .script(definition),
        exitCode: nil,
        tabId: nil
      )
    ) {
      $0.runningScriptsByWorktreeID = [:]

    }
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func viewTerminalTabSelectsWorktreeAndDelegatesTabSelection() async {
    let testID = UUID().uuidString
    let repoRoot = "/tmp/\(testID)-repo"
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let tabId = TerminalTabID()
    let definition = ScriptDefinition(kind: .run, name: "Run", command: "npm start")
    var state = makeState(repositories: [repository])
    state.runningScriptsByWorktreeID = [worktree.id: [definition.id]]

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    // Trigger the failure alert through the normal flow.
    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        scriptID: definition.id,
        kind: .script(definition),
        exitCode: 1,
        tabId: tabId
      )
    ) {
      $0.runningScriptsByWorktreeID = [:]

      $0.alert = expectedScriptFailureAlert(
        kind: .script(definition),
        exitMessage: "Script failed (exit code 1).",
        worktreeID: worktree.id,
        tabId: tabId,
        repoName: repository.name,
        worktreeName: "feature"
      )
    }

    // Tap "View Terminal".
    await store.send(.alert(.presented(.viewTerminalTab(worktree.id, tabId: tabId))))
    await store.receive(\.selectWorktree)
    await store.receive(\.delegate.selectTerminalTab)
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test(.dependencies) func archiveScriptFailureWithTabIdShowsViewTerminalButton() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let tabId = TerminalTabID()
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: tabId)) {
      $0.archivingWorktreeIDs = []
      $0.alert = expectedScriptFailureAlert(
        kind: .archive,
        exitMessage: "Script failed (exit code 1).",
        worktreeID: featureWorktree.id,
        tabId: tabId,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
  }

  @Test(.dependencies) func deleteScriptFailureWithTabIdShowsViewTerminalButton() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let tabId = TerminalTabID()
    var state = makeState(repositories: [repository])
    state.deleteScriptWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: tabId)) {
      $0.deleteScriptWorktreeIDs = []
      $0.alert = expectedScriptFailureAlert(
        kind: .delete,
        exitMessage: "Script failed (exit code 1).",
        worktreeID: featureWorktree.id,
        tabId: tabId,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
  }

  @Test(.dependencies) func archiveScriptCompletedSuccessArchivesWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    // Exhaustive receive closures on the archive chain are too
    // noisy to assert line-by-line — TCA processes synchronous
    // `.send` follow-ups inside the original `send`. Relax
    // exhaustivity and pin the meaningful end state via `#expect`.
    store.exhaustivity = .off

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil))
    await store.receive(\.archiveWorktreeApply)
    #expect(
      store.state.sidebar.sections[repository.id]?
        .buckets[.archived]?.items[featureWorktree.id]?.archivedAt == fixedDate
    )
    #expect(store.state.archivingWorktreeIDs.isEmpty)
  }

  @Test(.dependencies) func archiveScriptCompletedFailureShowsAlert() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 7, tabId: nil)) {
      $0.archivingWorktreeIDs = []
      $0.alert = expectedScriptFailureAlert(
        kind: .archive,
        exitMessage: "Script exited with code 7.",
        worktreeID: featureWorktree.id,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
    #expect(store.state.archivedWorktreeIDs.isEmpty)
  }

  @Test func archiveScriptCompletedCancellationClearsState() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: nil, tabId: nil)) {
      $0.archivingWorktreeIDs = []
    }
    #expect(store.state.alert == nil)
    #expect(store.state.archivedWorktreeIDs.isEmpty)
  }

  @Test func archiveScriptCompletedIgnoredWhenNotArchiving() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil))
    #expect(store.state.archivedWorktreeIDs.isEmpty)
  }

  @Test func repositoriesLoadedKeepsArchiveInFlightUntilSuccessCompletion() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let reloadedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    #expect(store.state.archivingWorktreeIDs.contains(featureWorktree.id))

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil))
    #expect(store.state.archivingWorktreeIDs.isEmpty)
  }

  @Test func repositoriesLoadedKeepsArchiveInFlightUntilFailureCompletion() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let reloadedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    #expect(store.state.archivingWorktreeIDs.contains(featureWorktree.id))

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: nil))
    #expect(store.state.archivingWorktreeIDs.isEmpty)
    #expect(store.state.alert != nil)
  }

  // MARK: - Archive script exit code coverage

  nonisolated static let archiveExitCodeCases: [(Int, String)] = [
    (1, "Script failed (exit code 1)."),
    (126, "Permission denied (exit code 126)."),
    (127, "Command not found (exit code 127)."),
    (130, "Script killed by signal 2 (exit code 130)."),
    (137, "Script killed by signal 9 (exit code 137)."),
  ]

  @Test(arguments: archiveExitCodeCases)
  func archiveScriptCompletedShowsExpectedMessage(exitCode: Int, expectedMessage: String) async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: exitCode, tabId: nil)) {
      $0.archivingWorktreeIDs = []
      $0.alert = expectedScriptFailureAlert(
        kind: .archive,
        exitMessage: expectedMessage,
        worktreeID: featureWorktree.id,
        repoName: "repo",
        worktreeName: "feature",
      )
    }
    #expect(store.state.archivedWorktreeIDs.isEmpty)
  }

  @Test(.dependencies) func archiveWorktreeConfirmedEmptyScriptSkipsToApply() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.archiveScript = "   \n  "
    }
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    // Exhaustive receive closures on the archive chain are too
    // noisy to assert line-by-line. Relax exhaustivity and pin
    // the meaningful end state via `#expect`.
    store.exhaustivity = .off

    await store.send(.archiveWorktreeConfirmed(featureWorktree.id, repository.id))
    await store.receive(\.archiveWorktreeApply)
    #expect(
      store.state.sidebar.sections[repository.id]?
        .buckets[.archived]?.items[featureWorktree.id]?.archivedAt == fixedDate
    )
  }

  @Test func archiveScriptCompletedDoesNotArchiveOnNonZeroExit() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Exit code 1 must NOT trigger archiveWorktreeApply.
    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: nil)) {
      $0.archivingWorktreeIDs = []
      $0.alert = expectedScriptFailureAlert(
        kind: .archive,
        exitMessage: "Script failed (exit code 1).",
        worktreeID: featureWorktree.id,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
    #expect(store.state.archivedWorktreeIDs.isEmpty)
  }

  @Test func archiveScriptCancellationDoesNotArchive() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Nil exit code (Ctrl+D, tab close) must NOT trigger archiveWorktreeApply.
    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: nil, tabId: nil)) {
      $0.archivingWorktreeIDs = []
    }
    #expect(store.state.archivedWorktreeIDs.isEmpty)
    #expect(store.state.alert == nil)
  }

  @Test func archiveScriptCompletedSuccessOnlyWhenExitCodeZero() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])

    // Test that ONLY exit code 0 leads to archival.
    for exitCode in [1, 2, 126, 127, 128, 130, 137, 255] {
      var state = makeState(repositories: [repository])
      state.archivingWorktreeIDs = [featureWorktree.id]
      let store = TestStore(initialState: state) {
        RepositoriesFeature()
      }
      store.exhaustivity = .off

      await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: exitCode, tabId: nil))
      #expect(
        store.state.archivedWorktreeIDs.isEmpty,
        "Exit code \(exitCode) should NOT archive the worktree"
      )
      #expect(
        store.state.alert != nil,
        "Exit code \(exitCode) should show an alert"
      )
    }
  }

  // MARK: - Delete Script

  @Test(.dependencies) func deleteSidebarItemConfirmedDelegatesDeleteScript() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(mainWorktree.id)
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.deleteScript = "echo cleaning\necho done"
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteSidebarItemConfirmed(featureWorktree.id, repository.id)) {
      $0.deleteScriptWorktreeIDs = [featureWorktree.id]
    }
    await store.receive(\.delegate.runBlockingScript)
  }

  @Test(.dependencies) func deleteScriptCompletedSuccessProceeds() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(mainWorktree.id)
    state.deleteScriptWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in await MainActor.run { worktree.workingDirectory } }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil)) {
      $0.deleteScriptWorktreeIDs = []
    }
    await store.receive(\.deleteWorktreeApply) {
      $0.deletingWorktreeIDs = [featureWorktree.id]
    }
    await store.receive(\.worktreeDeleted) {
      $0.deletingWorktreeIDs = []
      $0.repositories = [makeRepository(id: repoRoot, worktrees: [mainWorktree])]
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
    }
  }

  @Test(.dependencies) func deleteScriptCompletedFailureShowsAlert() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.deleteScriptWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 7, tabId: nil)) {
      $0.deleteScriptWorktreeIDs = []
      $0.alert = expectedScriptFailureAlert(
        kind: .delete,
        exitMessage: "Script exited with code 7.",
        worktreeID: featureWorktree.id,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
  }

  @Test func deleteScriptCompletedCancellationClearsState() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.deleteScriptWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: nil, tabId: nil)) {
      $0.deleteScriptWorktreeIDs = []
    }
    #expect(store.state.alert == nil)
  }

  @Test func deleteScriptCompletedIgnoredWhenNotDeleting() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil))
  }

  @Test(.dependencies) func deleteSidebarItemConfirmedSkipsScriptWhenEmpty() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(mainWorktree.id)
    @Shared(.repositorySettings(repository.rootURL)) var repositorySettings
    $repositorySettings.withLock {
      $0.deleteScript = "   \n  "
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in await MainActor.run { worktree.workingDirectory } }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(.deleteSidebarItemConfirmed(featureWorktree.id, repository.id))
    await store.receive(\.deleteWorktreeApply) {
      $0.deletingWorktreeIDs = [featureWorktree.id]
    }
    await store.receive(\.worktreeDeleted) {
      $0.deletingWorktreeIDs = []
      $0.repositories = [makeRepository(id: repoRoot, worktrees: [mainWorktree])]
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
    }
  }

  @Test(.dependencies) func deleteScriptCompletedSuccessButWorktreeGoneShowsAlert() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.deleteScriptWorktreeIDs = ["/tmp/repo/gone"]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Delete failed")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState(
        "The delete script completed successfully, but the worktree could not be found."
          + " It may have been removed."
      )
    }

    await store.send(.deleteScriptCompleted(worktreeID: "/tmp/repo/gone", exitCode: 0, tabId: nil)) {
      $0.deleteScriptWorktreeIDs = []
      $0.alert = expectedAlert
    }
  }

  @Test func deleteSidebarItemConfirmedNoopsWhenAlreadyArchiving() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteSidebarItemConfirmed(featureWorktree.id, repository.id))
  }

  @Test func repositoriesLoadedKeepsDeleteScriptInFlightUntilSuccessCompletion() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let reloadedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.deleteScriptWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    #expect(store.state.deleteScriptWorktreeIDs.contains(featureWorktree.id))

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil))
    #expect(store.state.deleteScriptWorktreeIDs.isEmpty)
  }

  @Test func repositoriesLoadedKeepsDeleteScriptInFlightUntilFailureCompletion() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let reloadedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.deleteScriptWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [reloadedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    #expect(store.state.deleteScriptWorktreeIDs.contains(featureWorktree.id))

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: nil))
    #expect(store.state.deleteScriptWorktreeIDs.isEmpty)
    #expect(store.state.alert != nil)
  }

  @Test func requestRenameBranchWithEmptyNameShowsAlert() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name required")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Enter a branch name to rename.")
    }

    await store.send(.requestRenameBranch(worktree.id, " ")) {
      $0.alert = expectedAlert
    }
  }

  @Test func requestRenameBranchWithWhitespaceShowsAlert() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Branch name invalid")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Branch names can't contain spaces.")
    }

    await store.send(.requestRenameBranch(worktree.id, "feature branch")) {
      $0.alert = expectedAlert
    }
  }

  @Test func worktreeNotificationReceivedDoesNotShowStatusToast() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [.unpinned: .init(items: [featureWorktree.id: .init()])]
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeNotificationReceived(featureWorktree.id))
    #expect(store.state.statusToast == nil)
  }

  @Test func worktreeNotificationReceivedReordersUnpinnedWorktrees() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB])
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [
          .unpinned: .init(
            items: [featureA.id: .init(), featureB.id: .init()]
          )
        ]
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeNotificationReceived(featureB.id)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.reorder(bucket: .unpinned, in: repository.id, to: [featureB.id, featureA.id])
      }
    }
    #expect(store.state.statusToast == nil)
  }

  @Test func worktreeNotificationReceivedDoesNotReorderWhenMoveToTopDisabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/a", name: "a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/b", name: "b", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureA, featureB])
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [
          .unpinned: .init(
            items: [featureA.id: .init(), featureB.id: .init()]
          )
        ]
      )
    }
    state.moveNotifiedWorktreeToTop = false
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeNotificationReceived(featureB.id))
    #expect(
      Array(
        store.state.sidebar.sections[repository.id]?.buckets[.unpinned]?.items.keys ?? []
      ) == [featureA.id, featureB.id]
    )
    #expect(store.state.statusToast == nil)
  }

  @Test func setMoveNotifiedWorktreeToTopUpdatesState() async {
    var state = makeState(repositories: [])
    state.moveNotifiedWorktreeToTop = true
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.setMoveNotifiedWorktreeToTop(false)) {
      $0.moveNotifiedWorktreeToTop = false
    }
  }

  @Test func worktreeBranchNameLoadedPreservesCreatedAt() async {
    let createdAt = Date(timeIntervalSince1970: 1_737_303_600)
    let worktree = makeWorktree(id: "/tmp/wt", name: "eagle", createdAt: createdAt)
    let renamedWorktree = makeWorktree(id: "/tmp/wt", name: "falcon", createdAt: createdAt)
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.worktreeBranchNameLoaded(worktreeID: worktree.id, name: "falcon")) {
      var repository = $0.repositories[id: repository.id]!
      var worktrees = repository.worktrees
      worktrees[id: worktree.id] = renamedWorktree
      repository = Repository(
        id: repository.id,
        rootURL: repository.rootURL,
        name: repository.name,
        worktrees: worktrees
      )
      $0.repositories[id: repository.id] = repository
    }
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: worktree.id]?.name == "falcon")
    #expect(store.state.repositories[id: repository.id]?.worktrees[id: worktree.id]?.createdAt == createdAt)
  }

  @Test func orderedSidebarItemsAreGlobal() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a"),
        makeWorktree(id: "/tmp/repo-a/wt2", name: "wt2", repoRoot: "/tmp/repo-a"),
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt3", name: "wt3", repoRoot: "/tmp/repo-b")
      ]
    )
    let state = makeState(repositories: [repoA, repoB])

    expectNoDifference(
      state.orderedSidebarItems().map(\.id),
      [
        "/tmp/repo-a/wt1",
        "/tmp/repo-a/wt2",
        "/tmp/repo-b/wt3",
      ]
    )
  }

  @Test func orderedSidebarItemsRespectRepositoryOrderIDs() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a")
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt2", name: "wt2", repoRoot: "/tmp/repo-b")
      ]
    )
    var state = makeState(repositories: [repoA, repoB])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoB.id] = .init()
      sidebar.sections[repoA.id] = .init()
    }

    expectNoDifference(
      state.orderedSidebarItems().map(\.id),
      [
        "/tmp/repo-b/wt2",
        "/tmp/repo-a/wt1",
      ]
    )
  }

  @Test func orderedSidebarItemsCanFilterCollapsedRepositoriesForHotkeys() {
    let repoA = makeRepository(
      id: "/tmp/repo-a",
      worktrees: [
        makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: "/tmp/repo-a")
      ]
    )
    let repoB = makeRepository(
      id: "/tmp/repo-b",
      worktrees: [
        makeWorktree(id: "/tmp/repo-b/wt2", name: "wt2", repoRoot: "/tmp/repo-b")
      ]
    )
    var state = makeState(repositories: [repoA, repoB])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoA.id] = .init()
      sidebar.sections[repoB.id] = .init()
    }

    expectNoDifference(
      state.orderedSidebarItems(includingRepositoryIDs: [repoB.id]).map(\.id),
      [
        "/tmp/repo-b/wt2"
      ]
    )
  }

  @Test func orderedRepositoryRootsAppendMissing() {
    let repoA = makeRepository(id: "/tmp/repo-a", worktrees: [])
    let repoB = makeRepository(id: "/tmp/repo-b", worktrees: [])
    var state = makeState(repositories: [repoA, repoB])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoB.id] = .init()
    }

    expectNoDifference(
      state.orderedRepositoryRoots().map { $0.path(percentEncoded: false) },
      [
        repoB.id,
        repoA.id,
      ]
    )
  }

  @Test func orderedUnpinnedWorktreesPutMissingFirst() {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let worktree3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: repoRoot)
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [worktree1, worktree2, worktree3]
    )
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [.unpinned: .init(items: [worktree2.id: .init()])]
      )
    }

    expectNoDifference(
      state.orderedUnpinnedWorktreeIDs(in: repository),
      [
        worktree1.id,
        worktree3.id,
        worktree2.id,
      ]
    )
  }

  @Test func unpinnedWorktreeMoveUpdatesOrder() async {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let worktree3 = makeWorktree(id: "/tmp/repo/wt3", name: "wt3", repoRoot: repoRoot)
    let repository = makeRepository(
      id: repoRoot,
      worktrees: [worktree1, worktree2, worktree3]
    )
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoRoot] = .init(
        buckets: [
          .unpinned: .init(
            items: [worktree1.id: .init(), worktree2.id: .init(), worktree3.id: .init()]
          )
        ]
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.unpinnedWorktreesMoved(repositoryID: repoRoot, IndexSet(integer: 0), 3)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.reorder(
          bucket: .unpinned,
          in: repoRoot,
          to: [worktree2.id, worktree3.id, worktree1.id]
        )
      }
    }
  }

  @Test func pinnedWorktreeMoveUpdatesSubsetOrder() async {
    let repoA = "/tmp/repo-a"
    let repoB = "/tmp/repo-b"
    let worktreeA1 = makeWorktree(id: "/tmp/repo-a/wt1", name: "wt1", repoRoot: repoA)
    let worktreeA2 = makeWorktree(id: "/tmp/repo-a/wt2", name: "wt2", repoRoot: repoA)
    let worktreeB1 = makeWorktree(id: "/tmp/repo-b/wt1", name: "wt1", repoRoot: repoB)
    let repositoryA = makeRepository(id: repoA, worktrees: [worktreeA1, worktreeA2])
    let repositoryB = makeRepository(id: repoB, worktrees: [worktreeB1])
    var state = makeState(repositories: [repositoryA, repositoryB])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repoA] = .init(
        buckets: [
          .pinned: .init(items: [worktreeA1.id: .init(), worktreeA2.id: .init()])
        ]
      )
      sidebar.sections[repoB] = .init(
        buckets: [.pinned: .init(items: [worktreeB1.id: .init()])]
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.pinnedWorktreesMoved(repositoryID: repoA, IndexSet(integer: 1), 0)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.reorder(bucket: .pinned, in: repoA, to: [worktreeA2.id, worktreeA1.id])
      }
    }
  }

  @Test func loadRepositoriesFailureKeepsPreviousState() async {
    let repository = makeRepository(id: "/tmp/repo", worktrees: [])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
  }

  @Test func worktreeOrderPreservedWhenRepositoryLoadFails() async {
    let repoRoot = "/tmp/repo"
    let worktree1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let worktree2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree1, worktree2])
    var initialState = makeState(repositories: [repository])
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[repoRoot] = .init(
        buckets: [
          .unpinned: .init(items: [worktree1.id: .init(), worktree2.id: .init()])
        ]
      )
    }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
    expectNoDifference(
      Array(
        store.state.sidebar.sections[repoRoot]?.buckets[.unpinned]?.items.keys ?? []
      ),
      [worktree1.id, worktree2.id]
    )
  }

  @Test func archivedWorktreeIDsPreservedWhenRepositoryLoadFails() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: worktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
      )
    }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [],
        failures: [RepositoriesFeature.LoadFailure(rootID: repository.id, message: "boom")],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.loadFailuresByID = [repository.id: "boom"]
      $0.repositories = []
      $0.isInitialLoadComplete = true
    }

    await store.receive(\.delegate.repositoriesChanged)
    #expect(store.state.archivedWorktreeIDs == [worktree.id])
  }

  @Test func repositoriesLoadedSkipsSelectionChangeWhenOnlyDisplayDataChanges() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let updatedWorktree = makeWorktree(id: "/tmp/repo/main", name: "main-updated", repoRoot: repoRoot)
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [updatedWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(worktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [updatedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.repositories = [updatedRepository]
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func repositoriesLoadedUpdatesSelectedWorktreeDelegateOnSelectionChange() async {
    let repoRoot = "/tmp/repo"
    let selectedWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let remainingWorktree = makeWorktree(id: "/tmp/repo/next", name: "next", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [selectedWorktree, remainingWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [remainingWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(selectedWorktree.id)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoriesLoaded(
        [updatedRepository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    ) {
      $0.repositories = [updatedRepository]
      $0.selection = nil
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func worktreeDeletedPrunesStateAndSendsDelegates() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let removedWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, removedWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(mainWorktree.id)
    initialState.deletingWorktreeIDs = [removedWorktree.id]
    initialState.pendingSetupScriptWorktreeIDs = [removedWorktree.id]
    initialState.pendingTerminalFocusWorktreeIDs = [removedWorktree.id]
    initialState.pendingWorktrees = [
      PendingWorktree(
        id: removedWorktree.id,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName)
      )
    ]
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [.pinned: .init(items: [removedWorktree.id: .init()])]
      )
    }
    initialState.worktreeInfoByID = [
      removedWorktree.id: WorktreeInfoEntry(addedLines: 1, removedLines: 2, pullRequest: nil)
    ]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(
      .worktreeDeleted(
        removedWorktree.id,
        repositoryID: repository.id,
        selectionWasRemoved: false,
        nextSelection: nil
      )
    ) {
      $0.deletingWorktreeIDs = []
      $0.pendingSetupScriptWorktreeIDs = []
      $0.pendingTerminalFocusWorktreeIDs = []
      $0.pendingWorktrees = []
      $0.worktreeInfoByID = [:]
      $0.repositories = [updatedRepository]
      $0.$sidebar.withLock { sidebar in
        sidebar.removeAnywhere(worktree: removedWorktree.id, in: repository.id)
      }
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
    }
  }

  @Test func worktreeDeletedResetsSelectionWhenDriftedToDeletingWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let removedWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, removedWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(removedWorktree.id)
    initialState.deletingWorktreeIDs = [removedWorktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(
      .worktreeDeleted(
        removedWorktree.id,
        repositoryID: repository.id,
        selectionWasRemoved: false,
        nextSelection: nil
      )
    ) {
      $0.deletingWorktreeIDs = []
      $0.repositories = [updatedRepository]
      $0.selection = .worktree(mainWorktree.id)
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
    }
  }

  @Test func createRandomWorktreeSucceededSendsRepositoriesChanged() async {
    let repoRoot = "/tmp/repo"
    let existingWorktree = makeWorktree(id: "/tmp/repo/wt-main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [existingWorktree])
    let newWorktree = makeWorktree(id: "/tmp/repo/wt-new", name: "new", repoRoot: repoRoot)
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [newWorktree, existingWorktree])
    let pendingID = "pending:\(UUID().uuidString)"
    var initialState = makeState(repositories: [repository])
    initialState.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches)
      )
    ]
    initialState.selection = .worktree(pendingID)
    initialState.sidebarSelectedWorktreeIDs = [existingWorktree.id, pendingID]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [newWorktree, existingWorktree] }
    }

    await store.send(
      .createRandomWorktreeSucceeded(
        newWorktree,
        repositoryID: repository.id,
        pendingID: pendingID
      )
    ) {
      $0.pendingSetupScriptWorktreeIDs.insert(newWorktree.id)
      $0.pendingTerminalFocusWorktreeIDs.insert(newWorktree.id)
      $0.pendingWorktrees = []
      $0.selection = .worktree(newWorktree.id)
      $0.sidebarSelectedWorktreeIDs = [newWorktree.id]
      $0.repositories = [updatedRepository]
    }

    await store.receive(\.reloadRepositories)
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.delegate.worktreeCreated)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
    }
  }

  @Test func repositoryPullRequestsLoadedAutoArchivesWhenEnabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .archive
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    // Exhaustive receive closures on the archive chain are too
    // noisy to assert line-by-line. Relax exhaustivity and pin
    // the meaningful end state via `#expect`.
    store.exhaustivity = .off
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    )
    await store.receive(\.archiveWorktreeApply)
    #expect(
      store.state.sidebar.sections[repository.id]?
        .buckets[.archived]?.items[featureWorktree.id]?.archivedAt == fixedDate
    )
    #expect(
      store.state.worktreeInfoByID[featureWorktree.id]?.pullRequest == mergedPullRequest
    )
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoArchiveForMainWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .archive
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: mainWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [mainWorktree.id: mergedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[mainWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedAutoDeletesWhenEnabled() async {
    let repoRoot = "/tmp/auto-delete-repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .delete
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    // Exhaustivity is off because `deleteSidebarItemConfirmed` triggers
    // async git operations that require extensive dependency mocking.
    store.exhaustivity = .off
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.receive(\.deleteSidebarItemConfirmed)
  }

  @Test func repositoryPullRequestsLoadedDoesNothingWhenMergedWorktreeActionNil() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = nil
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoActionForArchivedWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .delete
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: Date(timeIntervalSince1970: 1_000_000))
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoActionForDeletingWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .archive
    state.deletingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoActionForDeleteScriptWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .delete
    state.deleteScriptWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: mergedPullRequest
      )
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoActionWhenAlreadyMerged() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .delete
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: mergedPullRequest
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    // Re-receive a MERGED PR that differs in a field (updatedAt) so it passes
    // the `previousPullRequest != pullRequest` check, but should still be
    // skipped by the `!previousMerged` guard.
    let refreshedPullRequest = GithubPullRequest(
      number: mergedPullRequest.number,
      title: "PR",
      state: "MERGED",
      additions: 0,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: Date(),
      url: mergedPullRequest.url,
      headRefName: featureWorktree.name,
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: refreshedPullRequest]
      )
    ) {
      $0.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
        addedLines: nil,
        removedLines: nil,
        pullRequest: refreshedPullRequest
      )
    }
    await store.finish()
  }

  @Test func pullRequestActionMergeRefreshesImmediatelyWithoutSyntheticMergedState() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.mergedWorktreeAction = .archive
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let mergedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.mergePullRequest = { _, _, number, _ in
        mergedNumbers.withValue { $0.append(number) }
      }
    }
    store.exhaustivity = .off

    await store.send(.pullRequestAction(featureWorktree.id, .merge))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Merging pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request merged")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(store.state.worktreeInfoByID[featureWorktree.id]?.pullRequest?.state == "OPEN")
    #expect(store.state.archivedWorktreeIDs.isEmpty)
    #expect(mergedNumbers.value == [12])
    await store.finish()
  }

  @Test func pullRequestActionCloseRefreshesImmediately() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 12)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let closedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.closePullRequest = { _, _, number in
        closedNumbers.withValue { $0.append(number) }
      }
    }
    store.exhaustivity = .off

    await store.send(.pullRequestAction(featureWorktree.id, .close))
    await store.receive(\.showToast) {
      $0.statusToast = .inProgress("Closing pull request…")
    }
    await store.receive(\.showToast) {
      $0.statusToast = .success("Pull request closed")
    }
    await store.receive(\.worktreeInfoEvent)
    #expect(closedNumbers.value == [12])
    await store.finish()
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshPrefersGhResolvedRemote() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    let batchCalls = LockIsolated<[GithubRemoteInfo]>([])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubCLI.resolveRemoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "upstream", repo: "project")
      }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("gitClient.remoteInfo should be the fallback, not the first choice")
        return GithubRemoteInfo(host: "github.com", owner: "fork", repo: "project")
      }
      $0.githubCLI.batchPullRequests = { host, owner, repo, _ in
        batchCalls.withValue { $0.append(GithubRemoteInfo(host: host, owner: owner, repo: repo)) }
        return [:]
      }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    )
    await store.receive(\.repositoryPullRequestRefreshCompleted)
    await store.finish()

    #expect(batchCalls.value == [GithubRemoteInfo(host: "github.com", owner: "upstream", repo: "project")])
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshFallsBackToGitRemote() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    let batchCalls = LockIsolated<[GithubRemoteInfo]>([])
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubCLI.resolveRemoteInfo = { _ in nil }
      $0.gitClient.remoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "fork", repo: "project")
      }
      $0.githubCLI.batchPullRequests = { host, owner, repo, _ in
        batchCalls.withValue { $0.append(GithubRemoteInfo(host: host, owner: owner, repo: repo)) }
        return [:]
      }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    )
    await store.receive(\.repositoryPullRequestRefreshCompleted)
    await store.finish()

    #expect(batchCalls.value == [GithubRemoteInfo(host: "github.com", owner: "fork", repo: "project")])
  }

  @Test func pullRequestActionMergePassesResolvedRemoteToGh() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 88)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let recordedRemote = LockIsolated<GithubRemoteInfo?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.resolveRemoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "upstream", repo: "project")
      }
      $0.githubCLI.mergePullRequest = { _, remote, _, _ in
        recordedRemote.withValue { $0 = remote }
      }
    }
    store.exhaustivity = .off

    await store.send(.pullRequestAction(featureWorktree.id, .merge))
    await store.receive(\.showToast)
    await store.receive(\.showToast)
    await store.receive(\.worktreeInfoEvent)
    await store.finish()

    #expect(recordedRemote.value == GithubRemoteInfo(host: "github.com", owner: "upstream", repo: "project"))
  }

  @Test func pullRequestActionMergeFallsBackToGitRemoteWhenGhResolverReturnsNil() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let openPullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name, number: 88)
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: openPullRequest
    )
    let recordedRemote = LockIsolated<GithubRemoteInfo?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { true }
      $0.githubCLI.resolveRemoteInfo = { _ in nil }
      $0.gitClient.remoteInfo = { _ in
        GithubRemoteInfo(host: "github.com", owner: "fork", repo: "project")
      }
      $0.githubCLI.mergePullRequest = { _, remote, _, _ in
        recordedRemote.withValue { $0 = remote }
      }
    }
    store.exhaustivity = .off

    await store.send(.pullRequestAction(featureWorktree.id, .merge))
    await store.receive(\.showToast)
    await store.receive(\.showToast)
    await store.receive(\.worktreeInfoEvent)
    await store.finish()

    #expect(recordedRemote.value == GithubRemoteInfo(host: "github.com", owner: "fork", repo: "project"))
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshMarksInFlightThenCompletes() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    ) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshQueuesWhileAvailabilityUnknown() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.githubIntegration.isAvailable = { false }
      $0.gitClient.remoteInfo = { _ in
        Issue.record("remoteInfo should not be requested when GitHub integration is unavailable")
        return nil
      }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when GitHub integration is unavailable")
        return [:]
      }
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    ) {
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    }
    await store.receive(\.refreshGithubIntegrationAvailability) {
      $0.githubIntegrationAvailability = .checking
    }
    await store.receive(\.githubIntegrationAvailabilityUpdated) {
      $0.githubIntegrationAvailability = .unavailable
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.send(.setGithubIntegrationEnabled(false)) {
      $0.githubIntegrationAvailability = .disabled
      $0.pendingPullRequestRefreshByRepositoryID = [:]
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshQueuesWhileAvailabilityUnavailable() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .unavailable
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryPullRequestRefresh(
          repositoryRootURL: URL(fileURLWithPath: repoRoot),
          worktreeIDs: [mainWorktree.id, featureWorktree.id]
        )
      )
    ) {
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityRecoveryReplaysPendingRefreshes() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .unavailable
    initialState.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      worktreeIDs: [mainWorktree.id, featureWorktree.id]
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(.githubIntegrationAvailabilityUpdated(true)) {
      $0.githubIntegrationAvailability = .available
      $0.pendingPullRequestRefreshByRepositoryID = [:]
    }
    await store.receive(\.worktreeInfoEvent) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityUnavailablePromotesQueuedRefreshesToPending() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .available
    initialState.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    initialState.queuedPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      worktreeIDs: [mainWorktree.id, featureWorktree.id]
    )
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.githubIntegrationAvailabilityUpdated(false)) {
      $0.githubIntegrationAvailability = .unavailable
      $0.pendingPullRequestRefreshByRepositoryID[repository.id] = RepositoriesFeature.PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.send(.setGithubIntegrationEnabled(false)) {
      $0.githubIntegrationAvailability = .disabled
      $0.pendingPullRequestRefreshByRepositoryID = [:]
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func githubIntegrationAvailabilityUpdatedWhileDisabledIsIgnored() async {
    var state = makeState(repositories: [])
    state.githubIntegrationAvailability = .disabled
    state.pendingPullRequestRefreshByRepositoryID["repo"] = RepositoriesFeature.PendingPullRequestRefresh(
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
      worktreeIDs: []
    )
    let expectedState = state
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.githubIntegrationAvailabilityUpdated(false))
    await store.send(.githubIntegrationAvailabilityUpdated(true))
    #expect(store.state == expectedState)
    await store.finish()
  }

  @Test func repositoryPullRequestRefreshCompletedReplaysQueuedRefresh() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .available
    state.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    state.queuedPullRequestRefreshByRepositoryID[repository.id] =
      RepositoriesFeature
      .PendingPullRequestRefresh(
        repositoryRootURL: URL(fileURLWithPath: repoRoot),
        worktreeIDs: [mainWorktree.id, featureWorktree.id]
      )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in nil }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests should not run when remoteInfo is unavailable")
        return [:]
      }
    }

    await store.send(
      .repositoryPullRequestRefreshCompleted(repository.id)
    ) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.queuedPullRequestRefreshByRepositoryID = [:]
    }
    await store.receive(\.worktreeInfoEvent) {
      $0.inFlightPullRequestRefreshRepositoryIDs = [repository.id]
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedSkipsNoopPayload() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let pullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name)
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: pullRequest
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: pullRequest]
      )
    )
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedClearsStalePullRequestWhenNil() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeInfoByID[featureWorktree.id] = WorktreeInfoEntry(
      addedLines: nil,
      removedLines: nil,
      pullRequest: makePullRequest(state: "OPEN", headRefName: featureWorktree.name)
    )
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let pullRequestsByWorktreeID: [Worktree.ID: GithubPullRequest?] = [featureWorktree.id: nil]

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: pullRequestsByWorktreeID
      )
    ) {
      $0.worktreeInfoByID.removeValue(forKey: featureWorktree.id)
    }
  }

  @Test func unarchiveWorktreeNoopsWhenNotArchived() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.unarchiveWorktree(worktree.id))
    expectNoDifference(store.state.archivedWorktreeIDs, [])
  }

  // MARK: - Auto-Delete Expired Archived Worktrees

  @Test func autoDeleteExpiredArchivedWorktreesDeletesExpiredWorktrees() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.exhaustivity = .off

    await store.send(.autoDeleteExpiredArchivedWorktrees)
    await store.receive(\.deleteSidebarItemConfirmed)
  }

  @Test func autoDeleteExpiredArchivedWorktreesSkipsNonExpired() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let threeDaysAgo = fixedDate.addingTimeInterval(-3 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: threeDaysAgo)
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)

    await store.send(.autoDeleteExpiredArchivedWorktrees)
  }

  @Test func autoDeleteExpiredArchivedWorktreesSkipsMainWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: mainWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)

    await store.send(.autoDeleteExpiredArchivedWorktrees)
  }

  @Test func autoDeleteExpiredArchivedWorktreesSkipsAlreadyDeleting() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    state.deletingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)

    await store.send(.autoDeleteExpiredArchivedWorktrees)
  }

  @Test func autoDeleteExpiredArchivedWorktreesNoopsWhenDisabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)

    await store.send(.autoDeleteExpiredArchivedWorktrees)
  }

  @Test func setAutoDeleteDaysTriggersAutoDelete() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.exhaustivity = .off

    await store.send(.setAutoDeleteArchivedWorktreesAfterDays(.sevenDays)) {
      $0.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    }
    await store.receive(\.autoDeleteExpiredArchivedWorktrees)
    await store.receive(\.deleteSidebarItemConfirmed)
  }

  @Test func autoDeleteExpiredArchivedWorktreesSkipsDeleteScriptInProgress() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    state.deleteScriptWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)

    await store.send(.autoDeleteExpiredArchivedWorktrees)
  }

  @Test func autoDeleteExpiredArchivedWorktreesSkipsArchivingInProgress() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    state.archivingWorktreeIDs = [featureWorktree.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)

    await store.send(.autoDeleteExpiredArchivedWorktrees)
  }

  @Test func autoDeleteExpiredArchivedWorktreesDeletesAtExactCutoff() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let exactlySevenDaysAgo = fixedDate.addingTimeInterval(-7 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: exactlySevenDaysAgo)
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.exhaustivity = .off

    await store.send(.autoDeleteExpiredArchivedWorktrees)
    await store.receive(\.deleteSidebarItemConfirmed)
  }

  @Test func repositoriesLoadedTriggersAutoDeleteWhenEnabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.exhaustivity = .off

    await store.send(
      .repositoriesLoaded(
        [repository],
        failures: [],
        roots: [repository.rootURL],
        animated: false
      )
    )
    await store.receive(\.autoDeleteExpiredArchivedWorktrees)
    await store.receive(\.deleteSidebarItemConfirmed)
  }

  @Test func setAutoDeleteDaysNilDoesNotTriggerAutoDelete() async {
    let store = TestStore(initialState: makeState(repositories: [])) {
      RepositoriesFeature()
    }

    await store.send(.setAutoDeleteArchivedWorktreesAfterDays(nil))
  }

  @Test func openRepositoriesFinishedTriggersAutoDeleteWhenEnabled() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    let fixedDate = Date(timeIntervalSince1970: 1_000_000)
    let eightDaysAgo = fixedDate.addingTimeInterval(-8 * 86400)
    var state = makeState(repositories: [repository])
    state.autoDeleteArchivedWorktreesAfterDays = .sevenDays
    state.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: featureWorktree.id,
        in: repository.id,
        bucket: .archived,
        item: .init(archivedAt: eightDaysAgo)
      )
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(fixedDate)
    store.exhaustivity = .off

    await store.send(
      .openRepositoriesFinished(
        [repository],
        failures: [],
        invalidRoots: [],
        roots: [repository.rootURL]
      )
    )
    await store.receive(\.autoDeleteExpiredArchivedWorktrees)
    await store.receive(\.deleteSidebarItemConfirmed)
  }

  // MARK: - Select Next/Previous Worktree

  @Test func selectNextWorktreeWrapsForward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt2.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeWrapsBackward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeWithNoSelectionSelectsFirst() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeCollapsesSidebarSelectionToSingleWorktree() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let wt3 = makeWorktree(id: "/tmp/wt3", name: "gamma")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = [wt1.id, wt3.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeWithNoSelectionSelectsLast() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeWithEmptyRowsIsNoOp() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
  }

  @Test func selectNextWorktreeSingleWorktreeReturnsSame() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "solo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(worktree.id)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeSkipsCollapsedRepository() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt1.id)
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repo2.id, default: .init()].collapsed = true
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt3.id)
      $0.sidebarSelectedWorktreeIDs = [wt3.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectPreviousWorktreeSkipsCollapsedRepository() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt3.id)
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repo2.id, default: .init()].collapsed = true
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func selectNextWorktreeAllCollapsedIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    var state = makeState(repositories: [repo1])
    state.selection = .worktree(wt1.id)
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repo1.id, default: .init()].collapsed = true
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
  }

  @Test func selectPreviousWorktreeAllCollapsedIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    var state = makeState(repositories: [repo1])
    state.selection = .worktree(wt1.id)
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repo1.id, default: .init()].collapsed = true
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
  }

  @Test func selectNextWorktreeWrapsAroundSkippingCollapsedRepo() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let wt2 = makeWorktree(id: "/tmp/repo2/wt2", name: "beta", repoRoot: "/tmp/repo2")
    let wt3 = makeWorktree(id: "/tmp/repo3/wt3", name: "gamma", repoRoot: "/tmp/repo3")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    let repo2 = makeRepository(id: "/tmp/repo2", worktrees: [wt2])
    let repo3 = makeRepository(id: "/tmp/repo3", worktrees: [wt3])
    var state = makeState(repositories: [repo1, repo2, repo3])
    state.selection = .worktree(wt3.id)
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repo2.id, default: .init()].collapsed = true
    }
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  private func makeWorktree(
    id: String,
    name: String,
    repoRoot: String = "/tmp/repo",
    createdAt: Date? = nil
  ) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot),
      createdAt: createdAt
    )
  }

  private func makePullRequest(
    state: String,
    headRefName: String? = nil,
    number: Int = 1
  ) -> GithubPullRequest {
    GithubPullRequest(
      number: number,
      title: "PR",
      state: state,
      additions: 0,
      deletions: 0,
      isDraft: false,
      reviewDecision: nil,
      mergeable: nil,
      mergeStateStatus: nil,
      updatedAt: nil,
      url: "https://example.com/pull/\(number)",
      headRefName: headRefName,
      baseRefName: "main",
      commitsCount: 1,
      authorLogin: "khoi",
      statusCheckRollup: nil
    )
  }

  private func makeRepository(
    id: String,
    name: String = "repo",
    worktrees: [Worktree]
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  private func expectedScriptFailureAlert(
    kind: BlockingScriptKind,
    exitMessage: String,
    worktreeID: Worktree.ID,
    tabId: TerminalTabID? = nil,
    repoName: String,
    worktreeName: String
  ) -> AlertState<RepositoriesFeature.Alert> {
    AlertState {
      TextState("\(kind.tabTitle) failed")
    } actions: {
      if let tabId {
        ButtonState(action: .viewTerminalTab(worktreeID, tabId: tabId)) {
          TextState("View Terminal")
        }
      }
      ButtonState(role: .cancel) {
        TextState("Dismiss")
      }
    } message: {
      TextState("\(repoName) — \(worktreeName)\n\n\(exitMessage)")
    }
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.rootURL)
    return state
  }

  @Test func loadPersistedRepositoriesStartsFetchesConcurrentlyAndPreservesRootOrder() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: "\(repoRootA)/main", name: "main", repoRoot: repoRootA)
    let worktreeB = makeWorktree(id: "\(repoRootB)/main", name: "main", repoRoot: repoRootB)
    let repoA = makeRepository(
      id: repoRootA,
      name: URL(fileURLWithPath: repoRootA).lastPathComponent,
      worktrees: [worktreeA]
    )
    let repoB = makeRepository(
      id: repoRootB,
      name: URL(fileURLWithPath: repoRootB).lastPathComponent,
      worktrees: [worktreeB]
    )
    let gate = AsyncGate()
    let startedRoots = LockIsolated<Set<String>>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRootA, repoRootB] }
      $0.gitClient.worktrees = { root in
        let path = root.path(percentEncoded: false)
        _ = startedRoots.withValue { $0.insert(path) }
        if path == repoRootA {
          await gate.wait()
          return [worktreeA]
        }
        if path == repoRootB {
          return [worktreeB]
        }
        Issue.record("Unexpected root: \(path)")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)

    var secondFetchStarted = false
    for _ in 0..<100 {
      if startedRoots.value.contains(repoRootB) {
        secondFetchStarted = true
        break
      }
      await Task.yield()
    }
    #expect(secondFetchStarted)

    await gate.resume()

    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func loadPersistedRepositoriesRestoresLastFocusedSelectionAfterFullLoad() async {
    let testID = UUID().uuidString
    let repoRootA = "/tmp/\(testID)-repo-a"
    let repoRootB = "/tmp/\(testID)-repo-b"
    let worktreeA = makeWorktree(id: "\(repoRootA)/main", name: "main", repoRoot: repoRootA)
    let worktreeB = makeWorktree(id: "\(repoRootB)/main", name: "main", repoRoot: repoRootB)
    let repoA = makeRepository(
      id: repoRootA,
      name: URL(fileURLWithPath: repoRootA).lastPathComponent,
      worktrees: [worktreeA]
    )
    let repoB = makeRepository(
      id: repoRootB,
      name: URL(fileURLWithPath: repoRootB).lastPathComponent,
      worktrees: [worktreeB]
    )

    var state = RepositoriesFeature.State()
    state.$sidebar.withLock { $0.focusedWorktreeID = worktreeB.id }
    state.shouldRestoreLastFocusedWorktree = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRootA, repoRootB] }
      $0.gitClient.worktrees = { root in
        switch root.path(percentEncoded: false) {
        case repoRootA:
          return [worktreeA]
        case repoRootB:
          return [worktreeB]
        default:
          Issue.record("Unexpected root: \(root.path(percentEncoded: false))")
          return []
        }
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.selection = .worktree(worktreeB.id)
      $0.shouldRestoreLastFocusedWorktree = false
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.finish()
  }

  // MARK: - Folder (non-git) repositories.

  @Test func isGitRepositoryDetectsDotGitDirectory() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "supa-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let dotGit = tempDir.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)

    #expect(Repository.isGitRepository(at: tempDir))
  }

  @Test func isGitRepositoryRecognizesDotGitWorktreePointerFile() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "supa-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    // Linked worktrees have a `.git` file (not directory) pointing
    // at the parent's gitdir — the classifier must honor both.
    let pointer = tempDir.appending(path: ".git", directoryHint: .notDirectory)
    try "gitdir: /somewhere/.git/worktrees/foo\n".write(to: pointer, atomically: true, encoding: .utf8)

    #expect(Repository.isGitRepository(at: tempDir))
  }

  @Test func isGitRepositoryReturnsFalseForPlainDirectory() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "supa-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    #expect(!Repository.isGitRepository(at: tempDir))
  }

  @Test func isGitRepositoryRecognizesBareAndDotGitRootNames() {
    #expect(Repository.isGitRepository(at: URL(fileURLWithPath: "/tmp/repo/.bare")))
    #expect(Repository.isGitRepository(at: URL(fileURLWithPath: "/tmp/repo/.git")))
  }

  @Test func isGitRepositoryRecognizesBareCloneConvention() throws {
    // `git clone --bare` produces `<name>.git/` with HEAD + objects/ +
    // refs/ at the root (no `.git` metadata file, no `.bare` rename).
    let bareRoot = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-myrepo.git")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: bareRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: bareRoot.appending(path: "objects"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: bareRoot.appending(path: "refs"), withIntermediateDirectories: true)
    try Data("ref: refs/heads/main\n".utf8).write(to: bareRoot.appending(path: "HEAD"))
    defer { try? fileManager.removeItem(at: bareRoot) }

    #expect(Repository.isGitRepository(at: bareRoot))

    // A plain directory whose name happens to end in `.git` is not a bare repo.
    let fakeRoot = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-notbare.git")
    try fileManager.createDirectory(at: fakeRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: fakeRoot) }

    #expect(Repository.isGitRepository(at: fakeRoot) == false)
  }

  @Test func isGitRepositoryRecognizesBareRepositoryRegardlessOfName() throws {
    // A bare repo does not have to be named `*.git` — classification
    // should match git's own `is_git_directory()` heuristic (HEAD +
    // objects + refs) regardless of the directory name. Covers bare
    // clones the user renamed away from the `*.git` convention,
    // which previously misclassified as folders.
    let bareRoot = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-renamed-bare")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: bareRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: bareRoot.appending(path: "objects"), withIntermediateDirectories: true)
    try fileManager.createDirectory(at: bareRoot.appending(path: "refs"), withIntermediateDirectories: true)
    try Data("ref: refs/heads/main\n".utf8).write(to: bareRoot.appending(path: "HEAD"))
    defer { try? fileManager.removeItem(at: bareRoot) }

    #expect(Repository.isGitRepository(at: bareRoot))
  }

  @Test func isGitRepositoryRejectsDirectoryMissingGitStructure() throws {
    // A directory with only some of the HEAD/objects/refs trio is
    // not a git dir — git itself would reject it, and so must we.
    // Prevents false positives from directories that coincidentally
    // contain one or two of those names.
    let partialRoot = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-partial")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: partialRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: partialRoot.appending(path: "objects"),
      withIntermediateDirectories: true
    )
    try Data("ref: refs/heads/main\n".utf8).write(to: partialRoot.appending(path: "HEAD"))
    defer { try? fileManager.removeItem(at: partialRoot) }

    #expect(Repository.isGitRepository(at: partialRoot) == false)
  }

  @Test func isGitRepositoryRejectsHeadDirectoryLookalike() throws {
    // In a real git dir `HEAD` is a regular file holding a symbolic
    // ref. A directory that happens to contain `HEAD/`, `objects/`,
    // and `refs/` as directories is not a git dir — git itself
    // rejects it. Guards against false positives on unrelated
    // directories that coincidentally share those three names.
    let lookalikeRoot = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-head-dir")
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: lookalikeRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: lookalikeRoot.appending(path: "HEAD"),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: lookalikeRoot.appending(path: "objects"),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: lookalikeRoot.appending(path: "refs"),
      withIntermediateDirectories: true
    )
    defer { try? fileManager.removeItem(at: lookalikeRoot) }

    #expect(Repository.isGitRepository(at: lookalikeRoot) == false)
  }

  @Test func isGitRepositoryReturnsFalseForNonexistentPath() {
    // The caller (`applyRepositories` in `RepositoriesFeature`)
    // gates on `rootDirectoryExists` before classifying, but the
    // classifier itself is a pure helper and must still return a
    // clean `false` for a missing path — no crash, no fallback
    // to `true` — in case the existence gate is bypassed or a
    // race deletes the directory between the two calls.
    let missing = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-never-existed")
    #expect(Repository.isGitRepository(at: missing) == false)
  }

  @Test func loadPersistedRepositoriesClassifiesNonGitPathAsFolder() async {
    let repoRoot = "/tmp/\(UUID().uuidString)-folder"
    let rootURL = URL(fileURLWithPath: repoRoot)

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRoot] }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in
        Issue.record("worktrees() must not be called for folder repositories")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: rootURL),
      name: Repository.name(for: rootURL),
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL
    )
    let folderRepo = Repository(
      id: repoRoot,
      rootURL: rootURL,
      name: Repository.name(for: rootURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [folderRepo]
      $0.repositoryRoots = [rootURL]
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func loadPersistedRepositoriesSurfacesMissingFolderAsFailureRow() async {
    // Regression: folder-kind roots silently became empty folder
    // repositories when the directory no longer existed on disk.
    // Users who deleted a tracked folder from Finder saw a row
    // with no indication that the path was gone. The loader now
    // routes missing roots through `loadFailuresByID` so the
    // sidebar renders the error row the way git failures do.
    let repoRoot = "/tmp/\(UUID().uuidString)-missing-folder"

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRoot] }
      $0.gitClient.rootDirectoryExists = { _ in false }
      $0.gitClient.isGitRepository = { _ in
        Issue.record("isGitRepository() must not be called once the root is known to be missing")
        return false
      }
      $0.gitClient.worktrees = { _ in
        Issue.record("worktrees() must not be called for a missing root")
        return []
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = []
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.isInitialLoadComplete = true
      $0.loadFailuresByID = [
        repoRoot: "Directory not found at \(repoRoot). It may have been moved or deleted."
      ]
    }
    await store.finish()
  }

  @Test func loadPersistedRepositoriesClassifiesMixedGitAndFolderRoots() async {
    let gitRoot = "/tmp/\(UUID().uuidString)-git"
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let gitWorktree = makeWorktree(id: "\(gitRoot)/main", name: "main", repoRoot: gitRoot)

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [gitRoot, folderRoot] }
      $0.gitClient.isGitRepository = { $0.path(percentEncoded: false) == gitRoot }
      $0.gitClient.worktrees = { root in
        #expect(root.path(percentEncoded: false) == gitRoot)
        return [gitWorktree]
      }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [
        Repository(
          id: gitRoot,
          rootURL: URL(fileURLWithPath: gitRoot),
          name: URL(fileURLWithPath: gitRoot).lastPathComponent,
          worktrees: [gitWorktree],
          isGitRepository: true
        ),
        {
          let url = URL(fileURLWithPath: folderRoot)
          let synthetic = Worktree(
            id: Repository.folderWorktreeID(for: url),
            name: Repository.name(for: url),
            detail: "",
            workingDirectory: url,
            repositoryRootURL: url
          )
          return Repository(
            id: folderRoot,
            rootURL: url,
            name: Repository.name(for: url),
            worktrees: [synthetic],
            isGitRepository: false
          )
        }(),
      ]
      $0.repositoryRoots = [gitRoot, folderRoot].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func openRepositoriesWithNonGitDirectoryAppearsImmediately() async throws {
    // Reproduces the "folders don't appear immediately after being
    // added" bug: dropping a non-git directory should flow through
    // `.openRepositoriesFinished` and show up in `state.repositories`
    // plus `state.repositoryRoots` on the next render tick.
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "supa-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let standardizedURL = tempDir.standardizedFileURL
    let rootID = standardizedURL.path(percentEncoded: false)

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.repoRoot = { _ in
        throw GitClientError.commandFailed(command: "wt root", message: "not a git repository")
      }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in
        Issue.record("worktrees() must not be called for folder repositories")
        return []
      }
      $0.analyticsClient.capture = { _, _ in }
    }

    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: standardizedURL),
      name: Repository.name(for: standardizedURL),
      detail: "",
      workingDirectory: standardizedURL,
      repositoryRootURL: standardizedURL
    )
    let folderRepo = Repository(
      id: rootID,
      rootURL: standardizedURL,
      name: Repository.name(for: standardizedURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    await store.send(.openRepositories([tempDir]))
    await store.receive(\.openRepositoriesFinished) {
      $0.repositories = [folderRepo]
      $0.repositoryRoots = [standardizedURL]
      $0.isInitialLoadComplete = true
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.finish()
  }

  @Test func worktreesForInfoWatcherSkipsFolderRepositories() {
    let gitWorktree = makeWorktree(id: "/tmp/git/main", name: "main", repoRoot: "/tmp/git")
    let gitRepo = Repository(
      id: "/tmp/git",
      rootURL: URL(fileURLWithPath: "/tmp/git"),
      name: "git",
      worktrees: [gitWorktree],
      isGitRepository: true
    )
    let folderURL = URL(fileURLWithPath: "/tmp/folder")
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: "folder",
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: "/tmp/folder",
      rootURL: folderURL,
      name: "folder",
      worktrees: [folderWorktree],
      isGitRepository: false
    )
    var state = RepositoriesFeature.State()
    state.repositories = [gitRepo, folderRepo]

    #expect(state.worktreesForInfoWatcher() == [gitWorktree])
  }

  @Test func requestDeleteSidebarItemForFolderSkipsMainWorktreeLockAndRoutesToRepositoryRemoved() async {
    // Folders pipe their "Delete Folder…" context-menu action
    // through `.requestDeleteSidebarItems` using the synthetic main
    // worktree. The usual main-worktree lock would normally refuse
    // it, but the reducer is expected to recognize folder repos and
    // proceed, show a folder-flavored alert, and on confirm route
    // into `.deleteSidebarItemConfirmed` → `.repositoryRemovalCompleted`
    // → `.repositoriesRemoved` (no git `removeWorktree` since there
    // is none).
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [folderRoot] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }

    let folderTarget = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: folderWorktree.id, repositoryID: folderRepo.id)
    await store.send(.requestDeleteSidebarItems([folderTarget])) {
      $0.alert = AlertState {
        TextState("Remove folder?")
      } actions: {
        ButtonState(
          action: .confirmDeleteSidebarItems([folderTarget], disposition: .folderUnlink)
        ) {
          TextState("Remove from Supacode")
        }
        ButtonState(
          role: .destructive,
          action: .confirmDeleteSidebarItems([folderTarget], disposition: .folderTrash)
        ) {
          TextState("Delete from disk")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "Remove \(folderWorktree.name)? Choose \"Remove from Supacode\" to stop "
            + "managing the folder (it stays on disk)"
            + ", or \"Delete from disk\" to move the folder to the Trash."
        )
      }
    }

    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(
      .alert(.presented(.confirmDeleteSidebarItems([folderTarget], disposition: .folderUnlink)))
    )
    // The plural confirm handler sets up the batch, fans into
    // `.deleteSidebarItemConfirmed`, the per-target completion
    // drains into `.repositoryRemovalCompleted`, and the batch
    // terminal `.repositoriesRemoved([id])` does the one-shot
    // cleanup. Assert the key delegate hops so future regressions
    // that skip them don't silently pass, then drain the rest.
    await store.receive(\.repositoriesRemoved)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.skipReceivedActions()
    #expect(store.state.repositories.isEmpty)
    #expect(store.state.removingRepositoryIDs[folderRepo.id] == nil)
  }

  @Test func requestDeleteRepositoryForFolderConfirmsAndRemovesRoot() async {
    // Legacy path: `.requestDeleteRepository` also works for folders
    // (it just skips the blocking-script branch; no worktrees to
    // archive either), but the primary UI surface uses the
    // `.requestDeleteSidebarItems` path tested above.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [folderRoot] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.requestDeleteRepository(folderRepo.id))
    #expect(store.state.alert != nil)
    await store.send(.alert(.presented(.confirmDeleteRepository(folderRepo.id))))
    // Section-level remove flows through batch-of-1:
    // .confirmDeleteRepository → .repositoryRemovalCompleted (success)
    // → .repositoriesRemoved([id]) → reconciliation. Assert the
    // terminal + delegate fan-out so drops don't go unnoticed.
    await store.receive(\.repositoryRemovalCompleted)
    await store.receive(\.repositoriesRemoved)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.skipReceivedActions()
    #expect(store.state.repositories.isEmpty)
    #expect(store.state.removingRepositoryIDs[folderRepo.id] == nil)
  }

  @Test func deleteSidebarItemConfirmedRunsBlockingDeleteScriptForFolder() async {
    // When a delete script is defined, folder deletion piggy-backs on
    // the worktree-delete blocking-script pipeline: the reducer marks
    // the folder as "removing", delegates the script run, and only
    // signals `.repositoryRemovalCompleted` (drained by the batch
    // aggregator into a single `.repositoriesRemoved`) after
    // `.deleteScriptCompleted` reports exit 0 — so the folder stays
    // visible with a progress indicator while the script runs and
    // `gitClient.removeWorktree` is never called.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    @Shared(.repositorySettings(folderURL)) var repositorySettings
    $repositorySettings.withLock { $0.deleteScript = "echo goodbye" }
    defer { $repositorySettings.withLock { $0.deleteScript = "" } }

    // Intent + batch are normally recorded by the alert handler
    // before `.deleteSidebarItemConfirmed` runs — seed them here
    // since the test dispatches the action directly.
    state.seedRemovalBatch(pending: [folderRepo.id: .folderUnlink])

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [folderRoot] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.gitClient.removeWorktree = { _, _ in
        Issue.record("removeWorktree must not be called for a folder repository")
        return folderURL
      }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.deleteSidebarItemConfirmed(folderWorktree.id, folderRepo.id))
    await store.skipReceivedActions()
    await store.send(
      .deleteScriptCompleted(worktreeID: folderWorktree.id, exitCode: 0, tabId: nil)
    )
    await store.skipReceivedActions()
    #expect(store.state.repositories.isEmpty)
    #expect(store.state.removingRepositoryIDs[folderRepo.id] == nil)
  }

  @Test func folderDeleteScriptRunningKeepsRowClickableWithTerminalIndicator() {
    // While a folder's delete script is running, the sidebar row
    // must stay clickable (so the user can view the script output)
    // and show the terminal-backed deleting status — matching the
    // regular worktree delete flow. `removingRepositoryIDs` is set
    // upfront to carry folder intent, so the status + removing
    // checks must give the terminal indicator priority.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    state.seedRemovalBatch(pending: [folderRepo.id: .folderUnlink])
    state.deleteScriptWorktreeIDs.insert(folderWorktree.id)

    #expect(state.isRemovingRepository(folderRepo) == false)
    let rows = state.sidebarItems(in: folderRepo)
    #expect(rows.first?.status == .deleting(inTerminal: true))
    #expect(rows.first?.kind == .folder)
  }

  @Test func deleteWorktreeScriptFailureForFolderClearsRemovingState() async {
    // Script failure during folder deletion surfaces the standard
    // alert AND rolls back `removingRepositoryIDs` so the sidebar
    // row returns to its normal enabled state. The folder must stay
    // in `state.repositories` — nothing is removed.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    state.deleteScriptWorktreeIDs.insert(folderWorktree.id)
    state.seedRemovalBatch(pending: [folderRepo.id: .folderUnlink])

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .deleteScriptCompleted(worktreeID: folderWorktree.id, exitCode: 2, tabId: nil)
    )
    await store.skipReceivedActions()
    // Alert is shown for the failure; batch drains without firing a
    // `.repositoriesRemoved` because there were no successes.
    #expect(store.state.alert != nil)
    #expect(store.state.removingRepositoryIDs[folderRepo.id] == nil)
    #expect(store.state.deleteScriptWorktreeIDs.isEmpty)
    #expect(store.state.repositories.count == 1)
    #expect(store.state.activeRemovalBatches.isEmpty)
  }

  @Test func deleteScriptCompletedForFolderKindFlipShowsErrorAndStops() async {
    // If a `git init` flips the classification between the alert
    // confirmation and the delete-script completion, the handler
    // surfaces an explicit error and aborts — safer than silently
    // trashing the directory or running `gitClient.removeWorktree`.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let flippedRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: true
    )

    var state = RepositoriesFeature.State()
    state.repositories = [flippedRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    state.deleteScriptWorktreeIDs.insert(folderWorktree.id)
    state.seedRemovalBatch(pending: [flippedRepo.id: .folderTrash])

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { _, _ in
        Issue.record("removeWorktree must not run on kind-flip abort")
        return folderURL
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .deleteScriptCompleted(worktreeID: folderWorktree.id, exitCode: 0, tabId: nil)
    )
    await store.skipReceivedActions()
    // Kind flip aborts the removal; the folder stays in state and
    // the alert explains the decision.
    #expect(store.state.alert != nil)
    #expect(store.state.removingRepositoryIDs[flippedRepo.id] == nil)
    #expect(store.state.repositories.count == 1)
  }

  @Test func createRandomWorktreeInRepositoryRejectsFolderRepositories() async {
    // Hotkey / palette / deeplink can all target a folder; the
    // reducer must stop the action up front with an alert rather
    // than sending it into `gitClient.createWorktreeStream`.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          Issue.record("createWorktreeStream must not run for folder repositories")
          continuation.finish()
        }
      }
    }

    await store.send(.createRandomWorktreeInRepository(folderRepo.id)) {
      $0.alert = AlertState {
        TextState("Unable to create worktree")
      } actions: {
        ButtonState(role: .cancel) {
          TextState("OK")
        }
      } message: {
        TextState("Worktrees are only supported for git repositories.")
      }
    }
  }

  @Test func deleteScriptCancellationForFolderClearsRemovingState() async {
    // Cancelling the delete-script tab (exitCode: nil) must also
    // release `removingRepositoryIDs` — otherwise the folder row
    // stays visually "removing" forever.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    state.deleteScriptWorktreeIDs.insert(folderWorktree.id)
    state.seedRemovalBatch(pending: [folderRepo.id: .folderUnlink])

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .deleteScriptCompleted(worktreeID: folderWorktree.id, exitCode: nil, tabId: nil)
    )
    await store.skipReceivedActions()
    #expect(store.state.deleteScriptWorktreeIDs.isEmpty)
    #expect(store.state.removingRepositoryIDs[folderRepo.id] == nil)
    #expect(store.state.repositories.count == 1)
  }

  @Test func confirmDeleteSidebarItemDeleteActionTrashesFolderAfterRemoval() async throws {
    // `.confirmDeleteSidebarItems([folder target], disposition: .folderTrash)`
    // records the `.folderTrash` intent and forwards to
    // `.deleteSidebarItemConfirmed`. On an empty delete script the
    // flow finishes by moving the directory to the Trash (via
    // `FileManager.trashItem`) and then signaling
    // `.repositoryRemovalCompleted`, which the batch aggregator
    // drains into `.repositoriesRemoved`.
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "supa-\(UUID().uuidString)-folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let standardized = tempDir.standardizedFileURL
    let rootID = standardized.path(percentEncoded: false)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: standardized),
      name: Repository.name(for: standardized),
      detail: "",
      workingDirectory: standardized,
      repositoryRootURL: standardized
    )
    let folderRepo = Repository(
      id: rootID,
      rootURL: standardized,
      name: Repository.name(for: standardized),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [standardized]
    state.isInitialLoadComplete = true
    let folderTarget = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: folderWorktree.id, repositoryID: folderRepo.id)
    state.alert = AlertState {
      TextState("Remove folder?")
    } actions: {
      ButtonState(
        action: .confirmDeleteSidebarItems([folderTarget], disposition: .folderUnlink)
      ) {
        TextState("Remove from Supacode")
      }
      ButtonState(
        role: .destructive,
        action: .confirmDeleteSidebarItems([folderTarget], disposition: .folderTrash)
      ) {
        TextState("Delete from disk")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Remove \(folderWorktree.name)?")
    }

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .alert(.presented(.confirmDeleteSidebarItems([folderTarget], disposition: .folderTrash)))
    )
    await store.skipReceivedActions()

    // The trash effect ran and moved the directory away (or logged
    // a warning if trashItem refused). Either way the folder must no
    // longer live at its original path.
    #expect(!FileManager.default.fileExists(atPath: standardized.path(percentEncoded: false)))
  }

  @Test func folderTrashFailureSurfacesAlertAndKeepsRepo() async {
    // F2: `folderRemovalEffect` used to always dispatch
    // `succeeded: true` on `FileManager.trashItem` failure, silently
    // making the folder disappear from Supacode even though its
    // on-disk contents stayed put. Fix dispatches `succeeded: false`
    // AND surfaces a "Delete from disk failed" alert so the user
    // knows what happened.
    let missingRoot = "/tmp/supacode-missing-\(UUID().uuidString)"
    let missingURL = URL(fileURLWithPath: missingRoot)
    let rootID = missingURL.standardizedFileURL.path(percentEncoded: false)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: missingURL),
      name: Repository.name(for: missingURL), detail: "",
      workingDirectory: missingURL, repositoryRootURL: missingURL
    )
    let folderRepo = Repository(
      id: rootID, rootURL: missingURL, name: Repository.name(for: missingURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [missingURL]
    state.isInitialLoadComplete = true
    let folderTarget = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: folderWorktree.id, repositoryID: folderRepo.id)

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .alert(.presented(.confirmDeleteSidebarItems([folderTarget], disposition: .folderTrash)))
    )
    await store.skipReceivedActions()

    #expect(store.state.alert != nil, "trash failure must surface an alert")
    #expect(
      store.state.repositories.contains(where: { $0.id == folderRepo.id }),
      "folder must remain in state when trash fails"
    )
    #expect(
      store.state.removingRepositoryIDs[folderRepo.id] == nil,
      "removing indicator must clear on failure"
    )
    // Regression: trash failure used to leave `deletingWorktreeIDs`
    // populated (seeded by the empty-script folder branch), so the
    // sidebar row rendered `.deleting(inTerminal: false)` forever.
    // The failure path now clears per-worktree trackers too.
    #expect(
      !store.state.deletingWorktreeIDs.contains(folderWorktree.id),
      "deletingWorktreeIDs must clear on trash failure"
    )
    #expect(
      !store.state.deleteScriptWorktreeIDs.contains(folderWorktree.id),
      "deleteScriptWorktreeIDs must clear on trash failure"
    )
    #expect(store.state.activeRemovalBatches.isEmpty)
  }

  @Test func bulkFolderTrashFailuresCoalesceIntoSingleAlert() async {
    // C3 regression: parallel per-target `FileManager.trashItem`
    // failures used to each fire `.presentAlert` and clobber
    // `state.alert` in a last-write-wins race. The batch aggregator
    // now collects per-target `failureMessage`s and surfaces one
    // consolidated alert naming every failed folder when the batch
    // drains.
    let rootA = "/tmp/missing-trash-\(UUID().uuidString)-a"
    let rootB = "/tmp/missing-trash-\(UUID().uuidString)-b"
    let urlA = URL(fileURLWithPath: rootA)
    let urlB = URL(fileURLWithPath: rootB)
    func makeFolderRepo(url: URL, id: String) -> (Worktree, Repository) {
      let worktree = Worktree(
        id: Repository.folderWorktreeID(for: url),
        name: Repository.name(for: url), detail: "",
        workingDirectory: url, repositoryRootURL: url
      )
      let repo = Repository(
        id: id, rootURL: url, name: Repository.name(for: url),
        worktrees: IdentifiedArray(uniqueElements: [worktree]),
        isGitRepository: false
      )
      return (worktree, repo)
    }
    let (worktreeA, folderA) = makeFolderRepo(url: urlA, id: rootA)
    let (worktreeB, folderB) = makeFolderRepo(url: urlB, id: rootB)

    var state = RepositoriesFeature.State()
    state.repositories = [folderA, folderB]
    state.repositoryRoots = [urlA, urlB]
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.repositoryPersistence.pruneRepositoryConfigs = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    let targets = [
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktreeA.id, repositoryID: folderA.id),
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktreeB.id, repositoryID: folderB.id),
    ]
    await store.send(
      .alert(.presented(.confirmDeleteSidebarItems(targets, disposition: .folderTrash)))
    )
    await store.skipReceivedActions()

    // Both folders stay (trash failed), and the alert mentions BOTH
    // folder names — not just the last one.
    #expect(store.state.repositories.count == 2)
    #expect(store.state.activeRemovalBatches.isEmpty)
    #expect(store.state.removingRepositoryIDs.isEmpty)
    guard let alert = store.state.alert else {
      Issue.record("Expected consolidated trash-failure alert")
      return
    }
    let titleText = String(describing: alert.title)
    let messageText = String(describing: alert.message ?? TextState(""))
    #expect(titleText.contains("Delete from disk failed"))
    #expect(
      messageText.contains(folderA.name) && messageText.contains(folderB.name),
      "consolidated alert must name every failed folder (both \(folderA.name) and \(folderB.name))"
    )
  }

  @Test func deleteSidebarItemConfirmedDoesNotClobberTerminalAlert() async {
    // Pass-3 F1 regression: `.deleteSidebarItemConfirmed` used to
    // unconditionally clear `state.alert`. The alert-confirm path
    // already clears the alert at `.confirmDeleteSidebarItems`
    // entry, so the only effect of the second clear was to wipe
    // unrelated alerts dispatched programmatically (e.g., the
    // consolidated trash-failure alert set by the batch aggregator
    // just before the auto-delete sweep fires
    // `.deleteSidebarItemConfirmed` for an expired archived git
    // worktree).
    let gitRoot = "/tmp/alert-clobber-\(UUID().uuidString)-repo"
    let gitURL = URL(fileURLWithPath: gitRoot)
    let worktree = Worktree(
      id: "\(gitRoot)/wt-1",
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "\(gitRoot)/wt-1"),
      repositoryRootURL: gitURL
    )
    let mainWorktree = Worktree(
      id: gitRoot,
      name: "repo",
      detail: "",
      workingDirectory: gitURL,
      repositoryRootURL: gitURL
    )
    let gitRepo = Repository(
      id: gitRoot, rootURL: gitURL, name: "repo",
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree, worktree]),
      isGitRepository: true
    )

    let sentinelAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Do not wipe me")
    } actions: {
      ButtonState(role: .cancel) { TextState("OK") }
    } message: {
      TextState("Terminal failure alert from the aggregator.")
    }
    var state = RepositoriesFeature.State()
    state.repositories = [gitRepo]
    state.repositoryRoots = [gitURL]
    state.isInitialLoadComplete = true
    state.alert = sentinelAlert

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [gitRoot] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.repositoryPersistence.pruneRepositoryConfigs = { _ in }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in [] }
      $0.gitClient.removeWorktree = { _, _ in
        URL(fileURLWithPath: "\(gitRoot)/wt-1")
      }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Programmatic `.deleteSidebarItemConfirmed` — the code path
    // that `.autoDeleteExpiredArchivedWorktrees` uses.
    await store.send(.deleteSidebarItemConfirmed(worktree.id, gitRepo.id))
    await store.skipReceivedActions()

    #expect(
      store.state.alert == sentinelAlert,
      "terminal alerts must survive a programmatic .deleteSidebarItemConfirmed"
    )
  }

  @Test func deleteScriptCompletedDrainsBatchWhenOwningRepoVanished() async {
    // C4 regression: if the owning repo got pruned from
    // `state.repositories` between confirmation and script
    // completion (concurrent reload, `.removeFailedRepository`,
    // file-system observer race, etc.), the exit=0 branch used to
    // fall into the generic "Delete failed / not found" alert and
    // return `.none` — leaving the `removingRepositoryIDs` record
    // and `activeRemovalBatches` entry orphaned, so sibling folders
    // in the same batch hung forever.
    //
    // Reproduces by seeding the batch + record but NOT adding the
    // repo to `state.repositories`, then firing exit=0.
    let folderRoot = "/tmp/vanished-\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktreeID = Repository.folderWorktreeID(for: folderURL)

    var state = RepositoriesFeature.State()
    // Intentionally empty — simulating the repo vanishing mid-script.
    state.repositories = []
    state.repositoryRoots = []
    state.isInitialLoadComplete = true
    state.deleteScriptWorktreeIDs.insert(folderWorktreeID)
    let batchID = state.seedRemovalBatch(pending: [folderRoot: .folderUnlink])

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.repositoryPersistence.pruneRepositoryConfigs = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .deleteScriptCompleted(worktreeID: folderWorktreeID, exitCode: 0, tabId: nil)
    )
    await store.skipReceivedActions()

    #expect(
      store.state.removingRepositoryIDs[folderRoot] == nil,
      "record must drain even when owning repo vanished mid-script"
    )
    #expect(
      store.state.activeRemovalBatches[batchID] == nil,
      "batch must drain (succeeded:false) so sibling targets don't hang"
    )
    #expect(!store.state.deleteScriptWorktreeIDs.contains(folderWorktreeID))
  }

  @Test func bulkFolderUnlinkTerminatesWithEmptyState() async {
    // Regression: per-target `.repositoryRemoved` chaining used to
    // race `cancelInFlight: true` on the persistence save, leaving
    // only the first folder actually removed. The batch aggregator
    // now fires one terminal `.repositoriesRemoved([ids])` after
    // every target signals completion — bulk unlink must end with
    // `state.repositories.isEmpty` and the batch drained.
    let rootA = "/tmp/\(UUID().uuidString)-folder-a"
    let rootB = "/tmp/\(UUID().uuidString)-folder-b"
    let rootC = "/tmp/\(UUID().uuidString)-folder-c"
    let urlA = URL(fileURLWithPath: rootA)
    let urlB = URL(fileURLWithPath: rootB)
    let urlC = URL(fileURLWithPath: rootC)
    func makeFolderRepo(url: URL, id: String) -> (Worktree, Repository) {
      let worktree = Worktree(
        id: Repository.folderWorktreeID(for: url),
        name: Repository.name(for: url),
        detail: "",
        workingDirectory: url,
        repositoryRootURL: url
      )
      let repo = Repository(
        id: id, rootURL: url, name: Repository.name(for: url),
        worktrees: IdentifiedArray(uniqueElements: [worktree]), isGitRepository: false)
      return (worktree, repo)
    }
    let (worktreeA, folderA) = makeFolderRepo(url: urlA, id: rootA)
    let (worktreeB, folderB) = makeFolderRepo(url: urlB, id: rootB)
    let (worktreeC, folderC) = makeFolderRepo(url: urlC, id: rootC)

    var state = RepositoriesFeature.State()
    state.repositories = [folderA, folderB, folderC]
    state.repositoryRoots = [urlA, urlB, urlC]
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    let targets = [
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktreeA.id, repositoryID: folderA.id),
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktreeB.id, repositoryID: folderB.id),
      RepositoriesFeature.DeleteWorktreeTarget(worktreeID: worktreeC.id, repositoryID: folderC.id),
    ]
    await store.send(
      .alert(.presented(.confirmDeleteSidebarItems(targets, disposition: .folderUnlink)))
    )
    await store.skipReceivedActions()

    #expect(store.state.repositories.isEmpty)
    #expect(store.state.repositoryRoots.isEmpty)
    #expect(store.state.removingRepositoryIDs.isEmpty)
    #expect(store.state.activeRemovalBatches.isEmpty)
  }

  @Test func folderRemovalPrunesRootsAndConfigsFromSettings() async {
    // Regression: the `.repositoriesRemoved` terminal must write the
    // pruned list to `settings.json` AND drop the per-repo config
    // entry from `settingsFile.repositories`. The latter half used
    // to leak forever — users who added and removed folders for
    // testing saw stale entries pile up in the JSON.
    let rootA = "/tmp/\(UUID().uuidString)-folder-a"
    let rootB = "/tmp/\(UUID().uuidString)-folder-b"
    let urlA = URL(fileURLWithPath: rootA).standardizedFileURL
    let urlB = URL(fileURLWithPath: rootB).standardizedFileURL
    let idA = urlA.path(percentEncoded: false)
    let idB = urlB.path(percentEncoded: false)
    let worktreeA = Worktree(
      id: Repository.folderWorktreeID(for: urlA),
      name: Repository.name(for: urlA), detail: "",
      workingDirectory: urlA, repositoryRootURL: urlA
    )
    let folderA = Repository(
      id: idA, rootURL: urlA, name: Repository.name(for: urlA),
      worktrees: IdentifiedArray(uniqueElements: [worktreeA]),
      isGitRepository: false
    )
    let worktreeB = Worktree(
      id: Repository.folderWorktreeID(for: urlB),
      name: Repository.name(for: urlB), detail: "",
      workingDirectory: urlB, repositoryRootURL: urlB
    )
    let folderB = Repository(
      id: idB, rootURL: urlB, name: Repository.name(for: urlB),
      worktrees: IdentifiedArray(uniqueElements: [worktreeB]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderA, folderB]
    state.repositoryRoots = [urlA, urlB]
    state.isInitialLoadComplete = true

    let savedPaths = LockIsolated<[[String]]>([])
    let prunedIDs = LockIsolated<[[String]]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [idA, idB] }
      $0.repositoryPersistence.saveRoots = { paths in
        savedPaths.withValue { $0.append(paths) }
      }
      $0.repositoryPersistence.pruneRepositoryConfigs = { ids in
        prunedIDs.withValue { $0.append(ids) }
      }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    let targetA = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: worktreeA.id, repositoryID: folderA.id)
    await store.send(
      .alert(.presented(.confirmDeleteSidebarItems([targetA], disposition: .folderUnlink)))
    )
    await store.skipReceivedActions()

    #expect(savedPaths.value.last == [idB], "saveRoots must persist the pruned root list")
    #expect(
      prunedIDs.value.flatMap { $0 } == [idA],
      "pruneRepositoryConfigs must drop the removed repo's config entry"
    )
    #expect(store.state.repositories.map(\.id) == [idB])
    #expect(store.state.repositoryRoots.map { $0.path(percentEncoded: false) } == [idB])
  }

  @Test func requestDeleteSidebarItemsShowsFolderAlertAndFanOutsForAllFolderBulk() async {
    // `.requestDeleteSidebarItems` is the single entry point for bulk
    // remove — it uses the target repos' kind as a discriminator to
    // decide whether to show the worktree-style alert or the
    // folder-style 3-button alert. All-folder bulk confirms fan out
    // through `.deleteSidebarItemConfirmed` so each folder reuses the
    // single-folder delete-script pipeline.
    let rootA = "/tmp/\(UUID().uuidString)-folder-a"
    let rootB = "/tmp/\(UUID().uuidString)-folder-b"
    let urlA = URL(fileURLWithPath: rootA)
    let urlB = URL(fileURLWithPath: rootB)
    let worktreeA = Worktree(
      id: Repository.folderWorktreeID(for: urlA),
      name: Repository.name(for: urlA),
      detail: "",
      workingDirectory: urlA,
      repositoryRootURL: urlA
    )
    let worktreeB = Worktree(
      id: Repository.folderWorktreeID(for: urlB),
      name: Repository.name(for: urlB),
      detail: "",
      workingDirectory: urlB,
      repositoryRootURL: urlB
    )
    let folderA = Repository(
      id: rootA,
      rootURL: urlA,
      name: Repository.name(for: urlA),
      worktrees: IdentifiedArray(uniqueElements: [worktreeA]),
      isGitRepository: false
    )
    let folderB = Repository(
      id: rootB,
      rootURL: urlB,
      name: Repository.name(for: urlB),
      worktrees: IdentifiedArray(uniqueElements: [worktreeB]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderA, folderB]
    state.repositoryRoots = [urlA, urlB]
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    let targets = [
      RepositoriesFeature.DeleteWorktreeTarget(
        worktreeID: worktreeA.id, repositoryID: folderA.id),
      RepositoriesFeature.DeleteWorktreeTarget(
        worktreeID: worktreeB.id, repositoryID: folderB.id),
    ]

    await store.send(.requestDeleteSidebarItems(targets)) {
      #expect($0.alert != nil)
    }

    await store.send(
      .alert(.presented(.confirmDeleteSidebarItems(targets, disposition: .folderUnlink)))
    )
    // `.confirmDeleteSidebarItems` fans into the per-target
    // `.confirmDeleteSidebarItem(target, action:)` which maps the
    // folder intent before sending `.deleteSidebarItemConfirmed`.
    await store.skipReceivedActions()

    #expect(store.state.repositories.isEmpty)
  }

  @Test func requestDeleteSidebarItemsRejectsMixedKindSelection() async {
    // Safety net: if a keyboard shortcut or programmatic path
    // forwards a mixed folder + git selection to
    // `.requestDeleteSidebarItems`, the reducer refuses rather than
    // showing an ambiguous alert. The UI context menu blocks mixed
    // bulk upstream so this only fires under hotkey edge cases.
    let gitRoot = "/tmp/\(UUID().uuidString)-git"
    let gitURL = URL(fileURLWithPath: gitRoot)
    let gitMain = Worktree(
      id: "\(gitRoot)/main",
      name: "main",
      detail: "",
      workingDirectory: gitURL,
      repositoryRootURL: gitURL
    )
    let gitFeature = Worktree(
      id: "\(gitRoot)/feature",
      name: "feature",
      detail: "",
      workingDirectory: gitURL.appending(path: "feature"),
      repositoryRootURL: gitURL
    )
    let gitRepo = Repository(
      id: gitRoot,
      rootURL: gitURL,
      name: "git-repo",
      worktrees: IdentifiedArray(uniqueElements: [gitMain, gitFeature]),
      isGitRepository: true
    )
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderMain = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderMain]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [gitRepo, folderRepo]
    state.repositoryRoots = [gitURL, folderURL]
    state.isInitialLoadComplete = true

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .requestDeleteSidebarItems([
        RepositoriesFeature.DeleteWorktreeTarget(
          worktreeID: gitFeature.id, repositoryID: gitRepo.id),
        RepositoriesFeature.DeleteWorktreeTarget(
          worktreeID: folderMain.id, repositoryID: folderRepo.id),
      ]))
    #expect(store.state.alert == nil)
  }

  @Test func deleteScriptCompletedDoesNotMisrouteWhenGitRepoIsRemovingConcurrently() async {
    // Regression: when a git repo's worktree has a delete script
    // in flight AND the user confirmed repo-level removal on the
    // same git repo, `removingRepositoryIDs` carries a `.git`
    // intent. `.deleteScriptCompleted` must still route to the git
    // `.deleteWorktreeApply` path (so `gitClient.removeWorktree`
    // deletes the worktree on disk) and not mistake the entry for
    // folder intent.
    let repoRoot = "/tmp/\(UUID().uuidString)-git"
    let repoURL = URL(fileURLWithPath: repoRoot)
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let gitRepo = Repository(
      id: repoRoot,
      rootURL: repoURL,
      name: URL(fileURLWithPath: repoRoot).lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree, featureWorktree]),
      isGitRepository: true
    )

    var state = RepositoriesFeature.State()
    state.repositories = [gitRepo]
    state.repositoryRoots = [repoURL]
    state.isInitialLoadComplete = true
    state.deleteScriptWorktreeIDs.insert(featureWorktree.id)
    state.seedRemovalBatch(pending: [gitRepo.id: .gitRepositoryUnlink])

    let removeCalled = LockIsolated(false)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in
        removeCalled.setValue(true)
        return await MainActor.run { worktree.workingDirectory }
      }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil)
    )
    await store.receive(\.deleteWorktreeApply)
    await store.skipReceivedActions()

    #expect(removeCalled.value == true)
  }

  @Test func deleteSidebarItemConfirmedIsIdempotentForFolderWithEmptyScript() async {
    // Regression for the double-tap bug: the empty-script folder
    // branch of `.deleteSidebarItemConfirmed` used to re-fire the
    // repo-removal terminal (and duplicate analytics) on every repeat
    // of the confirm action because it had no re-entrancy guard.
    // The first invocation sets `removingRepositoryIDs` and drains
    // through the batch aggregator; the second must now be a no-op.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot,
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    // Already-set: matches the state after the first
    // `.deleteSidebarItemConfirmed` has enqueued
    // `.repositoryRemovalCompleted`.
    state.seedRemovalBatch(pending: [folderRepo.id: .folderUnlink])
    state.deletingWorktreeIDs.insert(folderWorktree.id)

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Second rapid tap: reducer must short-circuit before the
    // empty-script branch to avoid firing the repo-removal terminal
    // again.
    await store.send(.deleteSidebarItemConfirmed(folderWorktree.id, folderRepo.id))
  }

  @Test func concurrentFolderAndSectionBatchesEachCompleteIndependently() async {
    // Regression: the old single-optional `activeRemovalBatch` would
    // clobber a mid-flight folder batch as soon as a git-section
    // remove confirmed, orphaning the folder completions into a
    // fan-out of solo terminals. Keying batches by id means a folder
    // trash in-flight and a section unlink can coexist; each batch
    // fires its own `.repositoriesRemoved` when its pending set
    // drains.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: folderRoot, rootURL: folderURL, name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )
    let gitRoot = "/tmp/\(UUID().uuidString)-repo"
    let gitURL = URL(fileURLWithPath: gitRoot)
    let gitMain = Worktree(
      id: gitRoot, name: Repository.name(for: gitURL), detail: "",
      workingDirectory: gitURL, repositoryRootURL: gitURL
    )
    let gitRepo = Repository(
      id: gitRoot, rootURL: gitURL, name: Repository.name(for: gitURL),
      worktrees: IdentifiedArray(uniqueElements: [gitMain]),
      isGitRepository: true
    )

    // Seed state with a folder batch already mid-flight — mimics the
    // window where the folder's delete script / trash is still
    // running after the user confirmed.
    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo, gitRepo]
    state.repositoryRoots = [folderURL, gitURL]
    state.isInitialLoadComplete = true
    let folderBatchID = state.seedRemovalBatch(pending: [folderRepo.id: .folderUnlink])

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in [] }
      $0.analyticsClient.capture = { _, _ in }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // User confirms the git-section remove while the folder batch is
    // still pending. The section-remove must mint its own batch id
    // and leave the folder batch untouched.
    await store.send(.alert(.presented(.confirmDeleteRepository(gitRepo.id))))
    #expect(store.state.activeRemovalBatches[folderBatchID] != nil)
    #expect(store.state.activeRemovalBatches.count == 2)

    // Folder completion arrives: drains its own batch, fires its own
    // terminal, leaves the git batch alone.
    await store.send(
      .repositoryRemovalCompleted(folderRepo.id, outcome: .success, selectionWasRemoved: false))
    await store.skipReceivedActions()
    #expect(store.state.activeRemovalBatches[folderBatchID] == nil)
    #expect(store.state.repositories.contains(where: { $0.id == gitRepo.id }) == false)
    #expect(!store.state.repositories.contains(where: { $0.id == folderRepo.id }))
    #expect(store.state.removingRepositoryIDs.isEmpty)
    #expect(store.state.activeRemovalBatches.isEmpty)
  }

  @Test func orphanCompletionReportsIssueAndFiresSoloTerminal() async {
    // Every sender seeds the batch before signalling, so an orphan
    // completion means a bug. `reportIssue` fails tests and warns
    // release. For `succeeded=true` the solo terminal still runs so
    // the repo eventually leaves state; for `succeeded=false` any
    // worktree-scoped trackers get defensively cleared so state
    // can't leak beyond the failed attempt.
    await withKnownIssue {
      let folderRoot = "/tmp/\(UUID().uuidString)-folder"
      let folderURL = URL(fileURLWithPath: folderRoot)
      let folderWorktree = Worktree(
        id: Repository.folderWorktreeID(for: folderURL),
        name: Repository.name(for: folderURL), detail: "",
        workingDirectory: folderURL, repositoryRootURL: folderURL
      )
      let folderRepo = Repository(
        id: folderRoot, rootURL: folderURL, name: Repository.name(for: folderURL),
        worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
        isGitRepository: false
      )

      var state = RepositoriesFeature.State()
      state.repositories = [folderRepo]
      state.repositoryRoots = [folderURL]
      state.isInitialLoadComplete = true
      // Record without a matching batch in `activeRemovalBatches`
      // reproduces the orphan-completion scenario.
      state.removingRepositoryIDs[folderRepo.id] = RepositoriesFeature.RepositoryRemovalRecord(
        disposition: .folderUnlink, batchID: UUID()
      )
      state.deletingWorktreeIDs.insert(folderWorktree.id)
      state.deleteScriptWorktreeIDs.insert(folderWorktree.id)

      let store = TestStore(initialState: state) {
        RepositoriesFeature()
      } withDependencies: {
        $0.repositoryPersistence.loadRoots = { [] }
        $0.repositoryPersistence.saveRoots = { _ in }
        $0.gitClient.isGitRepository = { _ in false }
        $0.gitClient.worktrees = { _ in [] }
        $0.analyticsClient.capture = { _, _ in }
      }
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(
        .repositoryRemovalCompleted(
          folderRepo.id, outcome: .failureSilent, selectionWasRemoved: false))
      await store.skipReceivedActions()
      #expect(store.state.removingRepositoryIDs[folderRepo.id] == nil)
      #expect(!store.state.deletingWorktreeIDs.contains(folderWorktree.id))
      #expect(!store.state.deleteScriptWorktreeIDs.contains(folderWorktree.id))
      #expect(store.state.repositories.contains(where: { $0.id == folderRepo.id }))
    }
  }

  @Test func orphanCompletionSucceededFiresSoloTerminalAndRemovesRepo() async {
    // S4 companion: the `succeeded: true` branch of the orphan
    // fallback should still fire a solo `.repositoriesRemoved` so
    // the repo leaves state, even though the invariant is
    // technically broken. `reportIssue` surfaces the bug; the
    // reducer still cleans up.
    await withKnownIssue {
      let folderRoot = "/tmp/\(UUID().uuidString)-folder"
      let folderURL = URL(fileURLWithPath: folderRoot)
      let folderWorktree = Worktree(
        id: Repository.folderWorktreeID(for: folderURL),
        name: Repository.name(for: folderURL), detail: "",
        workingDirectory: folderURL, repositoryRootURL: folderURL
      )
      let folderRepo = Repository(
        id: folderRoot, rootURL: folderURL, name: Repository.name(for: folderURL),
        worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
        isGitRepository: false
      )

      var state = RepositoriesFeature.State()
      state.repositories = [folderRepo]
      state.repositoryRoots = [folderURL]
      state.isInitialLoadComplete = true
      state.removingRepositoryIDs[folderRepo.id] = RepositoriesFeature.RepositoryRemovalRecord(
        disposition: .folderUnlink, batchID: UUID()
      )

      let store = TestStore(initialState: state) {
        RepositoriesFeature()
      } withDependencies: {
        $0.repositoryPersistence.loadRoots = { [] }
        $0.repositoryPersistence.saveRoots = { _ in }
        $0.repositoryPersistence.pruneRepositoryConfigs = { _ in }
        $0.gitClient.isGitRepository = { _ in false }
        $0.gitClient.worktrees = { _ in [] }
        $0.analyticsClient.capture = { _, _ in }
      }
      store.exhaustivity = .off(showSkippedAssertions: false)

      await store.send(
        .repositoryRemovalCompleted(folderRepo.id, outcome: .success, selectionWasRemoved: false))
      await store.skipReceivedActions()
      #expect(store.state.removingRepositoryIDs[folderRepo.id] == nil)
      #expect(!store.state.repositories.contains(where: { $0.id == folderRepo.id }))
    }
  }

  private actor AsyncGate {
    var continuation: CheckedContinuation<Void, Never>?
    var isOpen = false

    func wait() async {
      guard !isOpen else { return }
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    }

    func resume() {
      if let continuation {
        continuation.resume()
        self.continuation = nil
      } else {
        isOpen = true
      }
    }
  }
}
