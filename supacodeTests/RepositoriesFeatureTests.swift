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
  @Test func toggleInspectorPaneOpensSwapsAndCloses() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }

    // Opens on the target pane (which defaults to `.git`).
    await store.send(.toggleInspectorPane(.git)) {
      $0.inspectorPresented = true
    }
    // A different pane swaps the inspector content while staying open.
    await store.send(.toggleInspectorPane(.notifications)) {
      $0.inspectorPane = .notifications
    }
    // Re-toggling the active pane closes the inspector but keeps the pane.
    await store.send(.toggleInspectorPane(.notifications)) {
      $0.inspectorPresented = false
    }
    // Toggling the retained pane while closed reopens it (the guard leans on
    // `inspectorPresented`, not the pane, to decide open vs close).
    await store.send(.toggleInspectorPane(.notifications)) {
      $0.inspectorPresented = true
    }
  }

  @Test func setInspectorPresentedKeepsSelectedPane() async {
    var initialState = RepositoriesFeature.State()
    initialState.inspectorPane = .notifications
    initialState.inspectorPresented = true
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }

    // A drag-to-collapse only flips presentation; the pane must survive so a
    // drag back open doesn't render an empty inspector.
    await store.send(.setInspectorPresented(false)) {
      $0.inspectorPresented = false
    }
    await store.send(.setInspectorPresented(true)) {
      $0.inspectorPresented = true
    }
  }

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
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    // The roster landed, so the open-action map resolves off the reducer.
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
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
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
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
      id: WorktreeID(repoRoot),
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
      sidebar.sections[RepositoryID(repoRoot)] = .init(
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
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [mainOnlyRepository.id: .finder]
    }
    #expect(
      store.state.sidebar.sections[RepositoryID(repoRoot)]?.buckets[.pinned]?.items[featureWorktree.id] != nil
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
        sidebar.sections[RepositoryID(repoRoot)] = .init(buckets: [.pinned: .init(items: [:])])
      }
      $0.reconcileSidebarForTesting()
    }
    // Every roster load re-reads the open actions. Nothing changed, so it writes nothing.
    await store.receive(\.openActionsResolved)
    #expect(
      store.state.sidebar.sections[RepositoryID(repoRoot)]?.buckets[.pinned]?.items[featureWorktree.id] == nil
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
      $0.worktreeMRU = [worktree.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
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
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeMRU = [wt2.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
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
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeMRU = [wt2.id]
      $0.sidebarItems[id: wt2.id]?.shouldFocusTerminal = true
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
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
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
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func sidebarRepositoryExpansionChangedUpdatesCollapsedRepositoryIDs() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.repositoryExpansionChanged(repository.id, isExpanded: false)) {
      $0.$sidebar.withLock { $0.sections[repository.id, default: .init()].collapsed = true }
      $0.applyPostReduceCacheRecomputes()
    }

    await store.send(.repositoryExpansionChanged(repository.id, isExpanded: true)) {
      $0.$sidebar.withLock { $0.sections[repository.id, default: .init()].collapsed = false }
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func repositoryExpansionChangedIsIdempotent() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.repositoryExpansionChanged(repository.id, isExpanded: false)) {
      $0.$sidebar.withLock { $0.sections[repository.id, default: .init()].collapsed = true }
      $0.applyPostReduceCacheRecomputes()
    }

    // Collapsing again should be a no-op.
    await store.send(.repositoryExpansionChanged(repository.id, isExpanded: false))
  }

  @Test func setAllSidebarGroupsExpandedCollapsesEveryRepositorySection() async {
    let worktreeA = makeWorktree(id: "/tmp/repoA/wt1", name: "wt1", repoRoot: "/tmp/repoA")
    let worktreeB = makeWorktree(id: "/tmp/repoB/wt1", name: "wt1", repoRoot: "/tmp/repoB")
    let repoA = makeRepository(id: "/tmp/repoA", name: "repoA", worktrees: [worktreeA])
    let repoB = makeRepository(id: "/tmp/repoB", name: "repoB", worktrees: [worktreeB])
    var initialState = makeState(repositories: [repoA, repoB])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // No repo has a persisted section yet, so collapse-all must materialize one
    // for every repo in the roster.
    await store.send(.setAllSidebarGroupsExpanded(false)) {
      $0.$sidebar.withLock { sidebar in
        for repositoryID in [repoA.id, repoB.id] {
          sidebar.sections[repositoryID, default: .init()].collapsed = true
        }
      }
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }

    #expect(store.state.sidebar.sections[repoA.id]?.collapsed == true)
    #expect(store.state.sidebar.sections[repoB.id]?.collapsed == true)
  }

  @Test func setAllSidebarGroupsExpandedCollapsePreservesBranchPrefixes() async {
    let worktreeA = makeWorktree(id: "/tmp/repoA/wt1", name: "feature/x", repoRoot: "/tmp/repoA")
    let repoA = makeRepository(id: "/tmp/repoA", name: "repoA", worktrees: [worktreeA])
    var initialState = makeState(repositories: [repoA])
    initialState.reconcileSidebarForTesting()
    // Seed an expanded section with a collapsed branch group so collapse-all has
    // a prefix that must survive.
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[repoA.id, default: .init()].collapsed = false
      sidebar.sections[repoA.id, default: .init()].buckets[.unpinned] = .init(collapsedBranchPrefixes: [
        "feature"
      ])
    }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.setAllSidebarGroupsExpanded(false)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[repoA.id, default: .init()].collapsed = true
      }
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }

    #expect(store.state.sidebar.sections[repoA.id]?.collapsed == true)
    #expect(
      store.state.sidebar.sections[repoA.id]?.buckets[.unpinned]?.collapsedBranchPrefixes == ["feature"]
    )
  }

  @Test func setAllSidebarGroupsExpandedExpandsSectionsAndClearsEveryBucketsBranchPrefixes() async {
    let worktreeA = makeWorktree(id: "/tmp/repoA/wt1", name: "feature/x", repoRoot: "/tmp/repoA")
    let worktreeB = makeWorktree(id: "/tmp/repoB/wt1", name: "hotfix/y", repoRoot: "/tmp/repoB")
    let repoA = makeRepository(id: "/tmp/repoA", name: "repoA", worktrees: [worktreeA])
    let repoB = makeRepository(id: "/tmp/repoB", name: "repoB", worktrees: [worktreeB])
    var initialState = makeState(repositories: [repoA, repoB])
    initialState.reconcileSidebarForTesting()
    // Collapse every section and seed collapsed branch groups across multiple
    // buckets and repos, so expand-all has to clear more than one bucket.
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[repoA.id, default: .init()].collapsed = true
      sidebar.sections[repoB.id, default: .init()].collapsed = true
      sidebar.sections[repoA.id, default: .init()].buckets[.pinned] = .init(collapsedBranchPrefixes: [
        "release"
      ])
      sidebar.sections[repoA.id, default: .init()].buckets[.unpinned] = .init(collapsedBranchPrefixes: [
        "feature"
      ])
      sidebar.sections[repoB.id, default: .init()].buckets[.unpinned] = .init(collapsedBranchPrefixes: [
        "hotfix"
      ])
    }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.setAllSidebarGroupsExpanded(true)) {
      $0.$sidebar.withLock { sidebar in
        for repositoryID in [repoA.id, repoB.id] {
          guard var section = sidebar.sections[repositoryID] else { continue }
          section.collapsed = false
          for bucketID in Array(section.buckets.keys) {
            section.buckets[bucketID]?.collapsedBranchPrefixes.removeAll()
          }
          sidebar.sections[repositoryID] = section
        }
      }
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }

    #expect(store.state.sidebar.sections[repoA.id]?.collapsed == false)
    #expect(store.state.sidebar.sections[repoB.id]?.collapsed == false)
    #expect(
      store.state.sidebar.sections[repoA.id]?.buckets[.pinned]?.collapsedBranchPrefixes.isEmpty == true
    )
    #expect(
      store.state.sidebar.sections[repoA.id]?.buckets[.unpinned]?.collapsedBranchPrefixes.isEmpty == true
    )
    #expect(
      store.state.sidebar.sections[repoB.id]?.buckets[.unpinned]?.collapsedBranchPrefixes.isEmpty == true
    )
  }

  @Test func setAllSidebarGroupsExpandedIsNoOpWhenAlreadyExpanded() async {
    let worktreeA = makeWorktree(id: "/tmp/repoA/wt1", name: "wt1", repoRoot: "/tmp/repoA")
    let repoA = makeRepository(id: "/tmp/repoA", name: "repoA", worktrees: [worktreeA])
    var initialState = makeState(repositories: [repoA])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // Already expanded with no persisted section, so expand-all writes nothing.
    await store.send(.setAllSidebarGroupsExpanded(true))

    #expect(store.state.isRepositoryExpanded(repoA.id))
    #expect(store.state.sidebar.sections[repoA.id] == nil)
  }

  @Test func setAllSidebarGroupsExpandedExpandsFolderRepositorySection() async {
    let folderURL = URL(fileURLWithPath: "/tmp/folderRepo")
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID("/tmp/folderRepo"),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )
    var initialState = makeState(repositories: [folderRepo])
    initialState.reconcileSidebarForTesting()
    initialState.$sidebar.withLock { sidebar in
      sidebar.sections[folderRepo.id, default: .init()].collapsed = true
    }
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.setAllSidebarGroupsExpanded(true)) {
      $0.$sidebar.withLock { sidebar in
        guard var section = sidebar.sections[folderRepo.id] else { return }
        section.collapsed = false
        for bucketID in Array(section.buckets.keys) {
          section.buckets[bucketID]?.collapsedBranchPrefixes.removeAll()
        }
        sidebar.sections[folderRepo.id] = section
      }
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }

    #expect(store.state.sidebar.sections[folderRepo.id]?.collapsed == false)
  }

  @Test func setAllSidebarGroupsExpandedOnEmptySidebarIsNoOp() async {
    var initialState = makeState(repositories: [])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.setAllSidebarGroupsExpanded(true))
    await store.send(.setAllSidebarGroupsExpanded(false))
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
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeMRU = [wt2.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    #expect(store.state.sidebarItems.allSatisfy { !$0.shouldFocusTerminal })
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
      $0.worktreeMRU = [wt1.id]
    }
    #expect(store.state.sidebarItems.allSatisfy { !$0.shouldFocusTerminal })
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
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repoA.id: .finder]
    }
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
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
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
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
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
    var initialState = makeState(repositories: [repoA, repoB])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    // Collapse B first, then A. With the bucketed sidebar there
    // is no "sorted order" of collapsed IDs — collapse state lives
    // per-section, so the assertion is just that the .collapsed
    // bit flips on the targeted section.
    await store.send(.repositoryExpansionChanged(repoB.id, isExpanded: false)) {
      $0.$sidebar.withLock { $0.sections[repoB.id, default: .init()].collapsed = true }
      $0.applyPostReduceCacheRecomputes()
    }
    await store.send(.repositoryExpansionChanged(repoA.id, isExpanded: false)) {
      $0.$sidebar.withLock { $0.sections[repoA.id, default: .init()].collapsed = true }
      $0.applyPostReduceCacheRecomputes()
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
    // The selection itself is unchanged, but it still records as most-recently-used.
    await store.send(.selectionChanged([.worktree(wt1.id)], focusTerminal: true)) {
      $0.worktreeMRU = [wt1.id]
    }
    #expect(store.state.sidebarItems.allSatisfy { !$0.shouldFocusTerminal })
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
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
    }
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
    await store.send(.selectionChanged([.worktree(wt1.id), .worktree("/tmp/unknown")])) {
      $0.worktreeMRU = [wt1.id]
    }
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

  @Test func sidebarSelectionSliceFallsBackToSelectedWorktreeID() {
    let wt1 = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let wt2 = makeWorktree(id: "/tmp/repo/wt2", name: "wt2", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.reconcileSidebarForTesting()
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = []

    // Falls back to selectedWorktreeID.
    let fallbackRows = state.computeSidebarSelectionSlice().rows
    #expect(fallbackRows.count == 1)
    #expect(fallbackRows.first?.id == wt1.id)

    // Primary path: sidebarSelectedWorktreeIDs non-empty.
    state.sidebarSelectedWorktreeIDs = [wt1.id, wt2.id]
    let primaryRows = state.computeSidebarSelectionSlice().rows
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

  @Test func revealHoistedWorktreeInSidebarRevealsTheGivenWorktree() async {
    let worktree = makeWorktree(id: "/tmp/repo/wt", name: "wt")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    }

    // No selection and no uncollapse: the target lives in a highlight section,
    // and the action reveals the id it is handed directly.
    await store.send(.revealHoistedWorktreeInSidebar(worktree.id)) {
      $0.nextPendingSidebarRevealID = 1
      $0.pendingSidebarReveal = .init(id: 1, worktreeID: worktree.id)
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
    var initialState = makeState(repositories: [repository])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.branchInventory = { _, _ in
        GitBranchInventory(
          localBranches: ["dev", "main"],
          remotes: [GitRemoteBranchGroup(name: "origin", branches: ["dev", "main"])]
        )
      }
    }

    let expectedDefaultBase = expectedDefaultWorktreeBaseDirectory(for: repository.rootURL)
    await store.send(.createRandomWorktreeInRepository(repository.id))
    await store.receive(\.promptedWorktreeCreationDataLoaded) {
      $0.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repository.id,
        repositoryRootURL: repository.rootURL,
        repositoryName: repository.name,
        automaticBaseRef: "origin/main",
        defaultBranch: "main",
        remoteNames: ["origin"],
        branchMenu: nil,
        branchName: "",
        selectedBaseRef: nil,
        fetchOrigin: true,
        defaultWorktreeBaseDirectory: expectedDefaultBase,
        validationMessage: nil
      )
    }
    await store.receive(\.promptedWorktreeBranchesLoaded) {
      $0.worktreeCreationPrompt?.branchMenu = BaseRefBranchMenu(
        inventory: GitBranchInventory(
          localBranches: ["dev", "main"],
          remotes: [GitRemoteBranchGroup(name: "origin", branches: ["dev", "main"])]
        ),
        hoistedLocalBranch: "main"
      )
    }
  }

  @Test func promptedWorktreeBranchesLoadedResetsStalePersistedBaseRef() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      defaultBranch: "main",
      remoteNames: ["origin"],
      branchMenu: nil,
      branchName: "feature/new",
      selectedBaseRef: "origin/deleted-branch",
      fetchOrigin: true,
      defaultWorktreeBaseDirectory: "/tmp/repo/.worktrees",
      validationMessage: nil
    )
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let inventory = GitBranchInventory(
      localBranches: ["main"],
      remotes: [GitRemoteBranchGroup(name: "origin", branches: ["main"])]
    )
    await store.send(.promptedWorktreeBranchesLoaded(repositoryID: repository.id, inventory: inventory)) {
      $0.worktreeCreationPrompt?.branchMenu = BaseRefBranchMenu(
        inventory: inventory,
        hoistedLocalBranch: "main"
      )
      $0.worktreeCreationPrompt?.selectedBaseRef = nil
    }
  }

  @Test func promptedWorktreeBranchesLoadedKeepsPersistedBaseRefPresentInInventory() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      defaultBranch: "main",
      remoteNames: ["origin"],
      branchMenu: nil,
      branchName: "feature/new",
      selectedBaseRef: "origin/dev",
      fetchOrigin: true,
      defaultWorktreeBaseDirectory: "/tmp/repo/.worktrees",
      validationMessage: nil
    )
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let inventory = GitBranchInventory(
      localBranches: ["main"],
      remotes: [GitRemoteBranchGroup(name: "origin", branches: ["dev", "main"])]
    )
    await store.send(.promptedWorktreeBranchesLoaded(repositoryID: repository.id, inventory: inventory)) {
      $0.worktreeCreationPrompt?.branchMenu = BaseRefBranchMenu(
        inventory: inventory,
        hoistedLocalBranch: "main"
      )
    }
  }

  @Test func promptedWorktreeBranchesLoadedKeepsBaseRefWhenInventoryEmpty() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      defaultBranch: "main",
      remoteNames: ["origin"],
      branchMenu: nil,
      branchName: "feature/new",
      selectedBaseRef: "origin/dev",
      fetchOrigin: true,
      defaultWorktreeBaseDirectory: "/tmp/repo/.worktrees",
      validationMessage: nil
    )
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // A failed inventory load surfaces as empty; it must not wipe a valid ref.
    await store.send(
      .promptedWorktreeBranchesLoaded(repositoryID: repository.id, inventory: GitBranchInventory())
    ) {
      $0.worktreeCreationPrompt?.branchMenu = BaseRefBranchMenu(
        inventory: GitBranchInventory(), hoistedLocalBranch: "main")
    }
  }

  @Test func promptedWorktreeBranchesLoadedClearsDefaultBranchWhenLocalBranchMissing() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
      repositoryID: repository.id,
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      defaultBranch: "main",
      remoteNames: ["origin"],
      branchMenu: nil,
      branchName: "feature/new",
      selectedBaseRef: nil,
      fetchOrigin: true,
      defaultWorktreeBaseDirectory: "/tmp/repo/.worktrees",
      validationMessage: nil
    )
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Only `origin/main` exists remotely; there is no local `main` to base off.
    let inventory = GitBranchInventory(
      localBranches: [],
      remotes: [GitRemoteBranchGroup(name: "origin", branches: ["main"])]
    )
    await store.send(.promptedWorktreeBranchesLoaded(repositoryID: repository.id, inventory: inventory)) {
      $0.worktreeCreationPrompt?.defaultBranch = nil
      $0.worktreeCreationPrompt?.branchMenu = BaseRefBranchMenu(
        inventory: inventory,
        hoistedLocalBranch: nil
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
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      defaultBranch: "main",
      remoteNames: ["origin"],
      branchMenu: nil,
      branchName: "feature/new-branch",
      selectedBaseRef: nil,
      fetchOrigin: true,
      defaultWorktreeBaseDirectory: "/tmp/repo/.worktrees",
      validationMessage: nil
    )
    state.reconcileSidebarForTesting()
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
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      defaultBranch: "main",
      remoteNames: ["origin"],
      branchMenu: nil,
      branchName: "feature/new",
      selectedBaseRef: nil,
      fetchOrigin: true,
      defaultWorktreeBaseDirectory: "/tmp/repo/.worktrees",
      validationMessage: nil
    )
    state.reconcileSidebarForTesting()
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
              fetchOrigin: true,
              placement: WorktreePlacementOverride(name: nil, path: nil),
              title: nil,
              color: nil
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
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      defaultBranch: "main",
      remoteNames: ["origin"],
      branchMenu: nil,
      branchName: "feature/existing",
      selectedBaseRef: nil,
      fetchOrigin: true,
      defaultWorktreeBaseDirectory: "/tmp/repo/.worktrees",
      validationMessage: nil
    )
    state.reconcileSidebarForTesting()
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
        fetchOrigin: true,
        placement: WorktreePlacementOverride(name: nil, path: nil)
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
    var initialState = makeState(repositories: [repoA, repoB])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.automaticWorktreeBaseRef = { root in
        if root.path(percentEncoded: false) == repoRootA {
          await promptLoadGate.wait()
        }
        return "origin/main"
      }
      $0.gitClient.remoteNames = { _ in ["origin"] }
      $0.gitClient.branchInventory = { _, _ in
        GitBranchInventory(
          localBranches: ["main"],
          remotes: [GitRemoteBranchGroup(name: "origin", branches: ["main"])]
        )
      }
    }

    await store.send(.createRandomWorktreeInRepository(repoA.id))
    await promptLoadGate.waitUntilArmed()
    await store.send(.createRandomWorktreeInRepository(repoB.id))
    await promptLoadGate.resume()
    await store.receive(\.promptedWorktreeCreationDataLoaded) {
      $0.worktreeCreationPrompt = WorktreeCreationPromptFeature.State(
        repositoryID: repoB.id,
        repositoryRootURL: repoB.rootURL,
        repositoryName: repoB.name,
        automaticBaseRef: "origin/main",
        defaultBranch: "main",
        remoteNames: ["origin"],
        branchMenu: nil,
        branchName: "",
        selectedBaseRef: nil,
        fetchOrigin: true,
        defaultWorktreeBaseDirectory: expectedDefaultWorktreeBaseDirectory(for: repoB.rootURL),
        validationMessage: nil
      )
    }
    await store.receive(\.promptedWorktreeBranchesLoaded) {
      $0.worktreeCreationPrompt?.branchMenu = BaseRefBranchMenu(
        inventory: GitBranchInventory(
          localBranches: ["main"],
          remotes: [GitRemoteBranchGroup(name: "origin", branches: ["main"])]
        ),
        hoistedLocalBranch: "main"
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
      repositoryRootURL: repository.rootURL,
      repositoryName: repository.name,
      automaticBaseRef: "origin/main",
      defaultBranch: "main",
      remoteNames: ["origin"],
      branchMenu: nil,
      branchName: "feature/new-branch",
      selectedBaseRef: nil,
      fetchOrigin: true,
      defaultWorktreeBaseDirectory: "/tmp/repo/.worktrees",
      validationMessage: nil
    )
    state.reconcileSidebarForTesting()
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
        fetchOrigin: true,
        placement: WorktreePlacementOverride(name: nil, path: nil)
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
    let pendingID: Worktree.ID = "pending:00000000-0000-0000-0000-000000000001"
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
      $0.reconcileSidebarForTesting()
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
      $0.reconcileSidebarForTesting()
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
      $0.applyPostReduceCacheRecomputes()
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: createdWorktree.id]?.shouldFocusTerminal = true
    }
    await store.finish()

    #expect(store.state.pendingWorktrees.isEmpty)
    #expect(store.state.selection == .worktree(createdWorktree.id))
    #expect(store.state.sidebarSelectedWorktreeIDs == [createdWorktree.id])
    #expect(store.state.sidebarItems[id: createdWorktree.id]?.lifecycle == .pending)
    #expect(store.state.sidebarItems[id: createdWorktree.id]?.shouldFocusTerminal == true)
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
      $0.gitClient.createWorktreeStream = { _, _, baseDirectory, _, _, _, _ in
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

  @Test(.dependencies) func createWorktreeForwardsResolvedPlacementOverrideToStream() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let createdWorktree = makeWorktree(
      id: "/tmp/elsewhere/feature_foo",
      name: "feature/foo",
      repoRoot: repoRoot
    )
    let observedDirectoryOverride = LockIsolated<URL?>(nil)
    let store = TestStore(initialState: makeState(repositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.localBranchNames = { _ in [] }
      $0.gitClient.isValidBranchName = { _, _ in true }
      $0.gitClient.isBareRepository = { _ in false }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
      $0.gitClient.ignoredFileCount = { _ in 0 }
      $0.gitClient.untrackedFileCount = { _ in 0 }
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, directoryOverride in
        observedDirectoryOverride.withValue { $0 = directoryOverride }
        return AsyncThrowingStream { continuation in
          continuation.yield(.finished(createdWorktree))
          continuation.finish()
        }
      }
      $0.gitClient.worktrees = { _ in [createdWorktree, mainWorktree] }
    }
    store.exhaustivity = .off

    await store.send(
      .createWorktreeInRepository(
        repositoryID: repository.id,
        nameSource: .explicit("feature/foo"),
        baseRefSource: .repositorySetting,
        fetchOrigin: false,
        placement: WorktreePlacementOverride(name: "feature_foo", path: "/tmp/elsewhere")
      )
    )
    await store.receive(\.createRandomWorktreeSucceeded)
    await store.finish()

    let defaultBase = SupacodePaths.worktreeBaseDirectory(
      for: repository.rootURL,
      globalDefaultPath: nil,
      repositoryOverridePath: nil
    )
    let expectedDirectory = SupacodePaths.resolvedWorktreeDirectory(
      defaultBaseDirectory: defaultBase,
      repositoryRootURL: repository.rootURL,
      nameOverride: "feature_foo",
      pathOverride: "/tmp/elsewhere",
      branchName: "feature/foo"
    )
    #expect(observedDirectoryOverride.value == expectedDirectory)
    #expect(
      observedDirectoryOverride.value
        == URL(filePath: "/tmp/elsewhere/feature_foo", directoryHint: .isDirectory).standardizedFileURL)
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
      $0.gitClient.createWorktreeStream = { _, _, baseDirectory, _, _, _, _ in
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
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
    let pendingID: Worktree.ID = "pending:test"
    var state = makeState(repositories: [repository])
    state.selection = .worktree(pendingID)
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches)
      )
    ]
    state.reconcileSidebarForTesting()
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
      $0.reconcileSidebarForTesting()
    }
  }

  @Test func selectionChangedKeepsPendingWorktreeSelected() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let pendingID: Worktree.ID = "pending:test"
    var state = makeState(repositories: [repository])
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .creatingWorktree, worktreeName: "swift-otter")
      )
    ]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectionChanged([.worktree(pendingID)])) {
      $0.selection = .worktree(pendingID)
      $0.sidebarSelectedWorktreeIDs = [pendingID]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    // `worktree(for:)` doesn't surface pending entries; the delegate fires nil
    // for a pending selection. The detail body still renders the loading view
    // off the slice's `.pending` lifecycle, so the user sees progress.
    await store.receive(\.delegate.selectedWorktreeChanged)
    #expect(store.state.selection == .worktree(pendingID))
    #expect(store.state.sidebarSelectedWorktreeIDs == [pendingID])
  }

  @Test func setSidebarSelectedWorktreeIDsKeepsPendingWorktreeInSet() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    let pendingID: Worktree.ID = "pending:test"
    var state = makeState(repositories: [repository])
    state.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .creatingWorktree, worktreeName: "swift-otter")
      )
    ]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.setSidebarSelectedWorktreeIDs([mainWorktree.id, pendingID])) {
      $0.sidebarSelectedWorktreeIDs = [mainWorktree.id, pendingID]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
  }

  @Test func pendingProgressUpdateIsIgnoredAfterCreateFailureRemovesPendingWorktree() async {
    let repoRoot = "/tmp/repo"
    let repository = makeRepository(id: repoRoot, worktrees: [makeWorktree(id: repoRoot, name: "main")])
    let pendingID: Worktree.ID = "pending:test"
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
    state.reconcileSidebarForTesting()
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
      $0.reconcileSidebarForTesting()
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
      TextState("Delete worktree?")
    } actions: {
      ButtonState(
        role: .destructive,
        action: .confirmDeleteSidebarItems([target], disposition: .gitWorktreeDelete)
      ) {
        TextState("Delete worktree")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("This deletes the worktree directory and its local branch.")
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
        TextState("Delete worktree?")
      } actions: {
        ButtonState(
          role: .destructive,
          action: .confirmDeleteSidebarItems([targets[1]], disposition: .gitWorktreeDelete)
        ) {
          TextState("Delete worktree")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState("This deletes the worktree directory and its local branch.")
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
      TextState("Delete 2 worktrees?")
    } actions: {
      ButtonState(
        role: .destructive,
        action: .confirmDeleteSidebarItems(targets, disposition: .gitWorktreeDelete)
      ) {
        TextState("Delete 2 worktrees")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("This deletes 2 worktree directories and their local branches.")
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
        TextState("Archive worktree")
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

  @Test func folderPinUnpinFlowsThroughBucketMachinery() async {
    // Folders use the same `pinWorktree` / `unpinWorktree` actions as git
    // worktrees. The two invariants this test locks:
    //  1. A pin reaches the `.pinned` bucket even though the folder's
    //     synthetic worktree wasn't pre-seeded into any bucket.
    //  2. A subsequent `.repositoriesLoaded` round-trip does not scrub the
    //     pin. `reconcileSidebarState` previously dropped any bucket entry
    //     whose id matched a main worktree, and folder synthetics satisfy
    //     `isMainWorktree` by geometry, so without the fix the pin
    //     vanished on every reload.
    let folderRoot = "/tmp/folder-pin-\(UUID().uuidString)"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      kind: .folder,
      name: Repository.name(for: folderURL), detail: "",
      workingDirectory: folderURL, repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot), rootURL: folderURL, name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )
    let store = TestStore(initialState: makeState(repositories: [folderRepo])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.pinWorktree(folderWorktree.id))
    #expect(store.state.sidebar.sections[folderRepo.id]?.buckets[.pinned]?.items[folderWorktree.id] != nil)
    #expect(store.state.sidebar.sections[folderRepo.id]?.buckets[.unpinned]?.items[folderWorktree.id] == nil)
    #expect(store.state.sidebarItems[id: folderWorktree.id]?.isPinned == true)

    await store.send(
      .repositoriesLoaded(
        [folderRepo],
        failures: [],
        roots: [folderRepo.rootURL],
        animated: false,
      )
    )
    #expect(store.state.sidebar.sections[folderRepo.id]?.buckets[.pinned]?.items[folderWorktree.id] != nil)
    #expect(store.state.sidebarItems[id: folderWorktree.id]?.isPinned == true)

    await store.send(.unpinWorktree(folderWorktree.id))
    #expect(store.state.sidebar.sections[folderRepo.id]?.buckets[.pinned]?.items[folderWorktree.id] == nil)
    #expect(store.state.sidebar.sections[folderRepo.id]?.buckets[.unpinned]?.items[folderWorktree.id] != nil)
    #expect(store.state.sidebarItems[id: folderWorktree.id]?.isPinned == false)

    await store.send(
      .repositoriesLoaded(
        [folderRepo],
        failures: [],
        roots: [folderRepo.rootURL],
        animated: false,
      )
    )
    #expect(store.state.sidebar.sections[folderRepo.id]?.buckets[.unpinned]?.items[folderWorktree.id] != nil)
    #expect(store.state.sidebarItems[id: folderWorktree.id]?.isPinned == false)
  }

  @Test func pinWorktreeCollapsesPreExistingDoubleBucketState() async {
    // `removeAnywhere` + `insert` is supposed to enforce the
    // "exactly one bucket" invariant against pre-states (hand-edit,
    // migrator race) where the same id lives in `.pinned` and
    // `.unpinned` simultaneously. Seed that pre-state explicitly and
    // confirm `pinWorktree` collapses it to a single `.pinned` entry.
    let worktree = makeWorktree(id: "/tmp/dbl-bucket/wt", name: "duck", repoRoot: "/tmp/dbl-bucket")
    let repository = makeRepository(id: "/tmp/dbl-bucket", worktrees: [worktree])
    var initial = makeState(repositories: [repository])
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [
          .pinned: .init(items: [worktree.id: .init()]),
          .unpinned: .init(items: [worktree.id: .init()]),
        ]
      )
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.pinWorktree(worktree.id))
    let section = store.state.sidebar.sections[repository.id]
    #expect(section?.buckets[.pinned]?.items[worktree.id] != nil)
    #expect(section?.buckets[.unpinned]?.items[worktree.id] == nil)
  }

  @Test func unpinWorktreeCollapsesPreExistingDoubleBucketState() async {
    // Symmetric to `pinWorktreeCollapsesPreExistingDoubleBucketState`: an
    // unpin against a row that lives in both `.pinned` and `.unpinned`
    // must end with the row in `.unpinned` only.
    let worktree = makeWorktree(id: "/tmp/dbl-bucket-u/wt", name: "duck", repoRoot: "/tmp/dbl-bucket-u")
    let repository = makeRepository(id: "/tmp/dbl-bucket-u", worktrees: [worktree])
    var initial = makeState(repositories: [repository])
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [
          .pinned: .init(items: [worktree.id: .init()]),
          .unpinned: .init(items: [worktree.id: .init()]),
        ]
      )
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.unpinWorktree(worktree.id))
    let section = store.state.sidebar.sections[repository.id]
    #expect(section?.buckets[.pinned]?.items[worktree.id] == nil)
    #expect(section?.buckets[.unpinned]?.items[worktree.id] != nil)
  }

  @Test func pinWorktreeIsNoOpOnArchivedRow() async {
    // Bucket relocation uses `removeAnywhere` which strips `archivedAt`
    // as a side effect. The archive guard refuses to relocate archived
    // rows so the timestamp survives a stray deeplink / hotkey dispatch.
    let worktree = makeWorktree(id: "/tmp/arch-pin/wt", name: "duck", repoRoot: "/tmp/arch-pin")
    let repository = makeRepository(id: "/tmp/arch-pin", worktrees: [worktree])
    var initial = makeState(repositories: [repository])
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [.archived: .init(items: [worktree.id: .init(archivedAt: .now)])]
      )
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.pinWorktree(worktree.id))
    let archived = store.state.sidebar.sections[repository.id]?.buckets[.archived]
    #expect(archived?.items[worktree.id] != nil)
    #expect(archived?.items[worktree.id]?.archivedAt != nil)
    #expect(store.state.sidebar.sections[repository.id]?.buckets[.pinned]?.items[worktree.id] == nil)

    await store.send(.unpinWorktree(worktree.id))
    let archivedAfterUnpin = store.state.sidebar.sections[repository.id]?.buckets[.archived]
    #expect(archivedAfterUnpin?.items[worktree.id] != nil)
    #expect(archivedAfterUnpin?.items[worktree.id]?.archivedAt != nil)
  }

  @Test func orderedHighlightPinnedIDsFiltersArchived() {
    // The Active candidate set already filters `.deletingScript` rows
    // out; the pinned list does the same so a row in the middle of an
    // archive delete can't double up across both highlight sections.
    let pinnedWorktree = makeWorktree(id: "/tmp/filter/wt-pin", name: "pin", repoRoot: "/tmp/filter")
    let archivedWorktree = makeWorktree(id: "/tmp/filter/wt-arch", name: "arch", repoRoot: "/tmp/filter")
    let repository = makeRepository(id: "/tmp/filter", worktrees: [pinnedWorktree, archivedWorktree])
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [
          .pinned: .init(items: [pinnedWorktree.id: .init()]),
          .archived: .init(items: [archivedWorktree.id: .init(archivedAt: .now)]),
        ]
      )
    }
    // Re-seed the pinned bucket with an archived id so the filter has
    // something to drop (a hand-edit / migrator pre-state).
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id]?.buckets[.pinned]?.items[archivedWorktree.id] = .init()
    }
    let ids = state.orderedHighlightPinnedIDs()
    #expect(ids == [pinnedWorktree.id])
  }

  @Test func selectedRowReturnsArchivedWorktreeOnlyWhileDeleteScriptRuns() {
    // Archived rows resolve a detail row only while their delete script runs,
    // so the re-surfaced row's terminal stays reachable.
    let worktree = makeWorktree(id: "/tmp/arch-del/wt", name: "duck", repoRoot: "/tmp/arch-del")
    let repository = makeRepository(id: "/tmp/arch-del", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      section.buckets[.unpinned]?.items.removeValue(forKey: worktree.id)
      var archivedBucket = section.buckets[.archived] ?? .init()
      archivedBucket.items[worktree.id] = .init(archivedAt: .now)
      section.buckets[.archived] = archivedBucket
      sidebar.sections[repository.id] = section
    }

    #expect(state.selectedRow(for: worktree.id) == nil)

    state.sidebarItems[id: worktree.id]?.lifecycle = .deletingScript
    #expect(state.selectedRow(for: worktree.id)?.id == worktree.id)

    state.sidebarItems[id: worktree.id]?.lifecycle = .idle
    #expect(state.selectedRow(for: worktree.id) == nil)
  }

  @Test func deleteScriptArchivedRowStaysSelectableAcrossReload() {
    // The `applyRepositories` reload guard nils the selection when
    // `isSelectionValid` is false; the surfaced delete-script row must stay
    // valid so a routine reload can't evict the user off its live terminal.
    let worktree = makeWorktree(id: "/tmp/arch-sel/wt", name: "duck", repoRoot: "/tmp/arch-sel")
    let repository = makeRepository(id: "/tmp/arch-sel", worktrees: [worktree])
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[repository.id] ?? .init()
      section.buckets[.unpinned]?.items.removeValue(forKey: worktree.id)
      var archivedBucket = section.buckets[.archived] ?? .init()
      archivedBucket.items[worktree.id] = .init(archivedAt: .now)
      section.buckets[.archived] = archivedBucket
      sidebar.sections[repository.id] = section
    }

    #expect(!state.worktreeExists(worktree.id))
    #expect(!state.isSelectionValid(worktree.id))

    state.sidebarItems[id: worktree.id]?.lifecycle = .deletingScript
    #expect(state.worktreeExists(worktree.id))
    #expect(state.isSelectionValid(worktree.id))

    state.sidebarItems[id: worktree.id]?.lifecycle = .idle
    #expect(!state.isSelectionValid(worktree.id))
  }

  @Test func requestArchiveWorktreeForFolderShowsActionNotAvailable() async {
    // Archive still rejects on folders (no archived bucket for them); pin
    // and unpin now flow through the standard bucket machinery so they
    // produce no alert. See `folderPinUnpinFlowsThroughBucketMachinery`.
    let folderRoot = "/tmp/folder-archive-\(UUID().uuidString)"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      kind: .folder,
      name: Repository.name(for: folderURL), detail: "",
      workingDirectory: folderURL, repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot), rootURL: folderURL, name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )
    let store = TestStore(initialState: makeState(repositories: [folderRepo])) {
      RepositoriesFeature()
    }

    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Archive not available")
    } actions: {
      ButtonState(role: .cancel) { TextState("OK") }
    } message: {
      TextState("Archive only applies to git repositories.")
    }
    await store.send(.requestArchiveWorktree(folderWorktree.id, folderRepo.id)) {
      $0.alert = expectedAlert
    }
    await store.send(.alert(.dismiss)) { $0.alert = nil }
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
        TextState("Archive 2 worktrees")
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
    state.reconcileSidebarForTesting()
    state.setWorktreeInfoForTesting(id: featureWorktree.id, pullRequest: makePullRequest(state: "MERGED"))
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveWorktreeConfirmed(featureWorktree.id, repository.id))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
    }
    await store.receive(\.delegate.runBlockingScript)
  }

  @Test(.dependencies) func scriptCompletedWithFailureShowsAlert() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let definition = ScriptDefinition(kind: .run, name: "Run", command: "npm start")
    var state = makeState(repositories: [repository])
    state.reconcileSidebarForTesting()

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // No seeded `runningScripts`: the alert must fire even when the row
    // mirror already reconciled the removal (#573).
    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        kind: .script(definition),
        exitCode: 1,
        tabId: nil
      )
    ) {
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
      .init(id: definition.id, tint: definition.resolvedTintColor)
    state.applyPostReduceCacheRecomputes()

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        kind: .script(definition),
        exitCode: 0,
        tabId: nil
      )
    )
    // The row keeps its entry: removal arrives via the terminal projection.
    #expect(store.state.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] != nil)
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func scriptCompletedWithNilExitCodeDoesNotShowAlert() async {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let definition = ScriptDefinition(kind: .run, name: "Run", command: "npm start")
    var state = makeState(repositories: [repository])
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
      .init(id: definition.id, tint: definition.resolvedTintColor)
    state.applyPostReduceCacheRecomputes()

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        kind: .script(definition),
        exitCode: nil,
        tabId: nil
      )
    )
    #expect(store.state.alert == nil)
  }

  @Test func runningScriptColorsReturnsTintForWorktreeOutsideSelectedRepo() {
    // Regression: running-script tint for a worktree in a repository
    // other than the selected one used to fall back to `.green`
    // because the view-side `scriptsByID` lookup only carried the
    // selected repo's scripts. The tint now travels with the running
    // entry, so this asserts the cross-repo resolution.
    let repoA = "/tmp/repo-a"
    let repoB = "/tmp/repo-b"
    let worktreeA = makeWorktree(id: "\(repoA)/main", name: "main", repoRoot: repoA)
    let worktreeB = makeWorktree(id: "\(repoB)/main", name: "main", repoRoot: repoB)
    let repositoryA = makeRepository(id: repoA, worktrees: [worktreeA])
    let repositoryB = makeRepository(id: repoB, worktrees: [worktreeB])
    var state = makeState(repositories: [repositoryA, repositoryB])
    state.selection = .worktree(worktreeA.id)
    state.reconcileSidebarForTesting()
    let scriptID = UUID()
    state.sidebarItems[id: worktreeB.id]?.runningScripts[id: scriptID] = .init(id: scriptID, tint: .purple)

    #expect(state.runningScriptColors(for: worktreeB.id) == [.purple])
  }

  @Test func runningScriptColorsOrdersMultipleScriptsBySortedID() {
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.reconcileSidebarForTesting()
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    state.sidebarItems[id: worktree.id]?.runningScripts[id: secondID] = .init(id: secondID, tint: .orange)
    state.sidebarItems[id: worktree.id]?.runningScripts[id: firstID] = .init(id: firstID, tint: .purple)

    #expect(state.runningScriptColors(for: worktree.id) == [.purple, .orange])
  }

  @Test(.dependencies) func scriptCompletedLeavesRunningScriptsUntouched() async {
    // `runningScripts` reconciles from the terminal projection (single
    // writer); completion must not mutate the row mirror.
    let repoRoot = "/tmp/repo"
    let worktree = makeWorktree(id: "\(repoRoot)/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [worktree])
    let completing = ScriptDefinition(kind: .run, name: "Run", command: "npm start")
    let surviving = ScriptDefinition(kind: .test, name: "Test", command: "npm test")
    var state = makeState(repositories: [repository])
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: worktree.id]?.runningScripts[id: completing.id] =
      .init(id: completing.id, tint: completing.resolvedTintColor)
    state.sidebarItems[id: worktree.id]?.runningScripts[id: surviving.id] =
      .init(id: surviving.id, tint: surviving.resolvedTintColor)
    state.applyPostReduceCacheRecomputes()

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        kind: .script(completing),
        exitCode: 0,
        tabId: nil
      )
    )
    #expect(store.state.sidebarItems[id: worktree.id]?.runningScripts.count == 2)
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: worktree.id]?.runningScripts[id: definition.id] =
      .init(id: definition.id, tint: definition.resolvedTintColor)

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    // Trigger the failure alert through the normal flow.
    await store.send(
      .scriptCompleted(
        worktreeID: worktree.id,
        kind: .script(definition),
        exitCode: 1,
        tabId: tabId
      )
    ) {
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: tabId)) {
      $0.alert = expectedScriptFailureAlert(
        kind: .archive,
        exitMessage: "Script failed (exit code 1).",
        worktreeID: featureWorktree.id,
        tabId: tabId,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: tabId)) {
      $0.alert = expectedScriptFailureAlert(
        kind: .delete,
        exitMessage: "Script failed (exit code 1).",
        worktreeID: featureWorktree.id,
        tabId: tabId,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
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
    #expect((store.state.sidebarItems[id: featureWorktree.id]?.lifecycle ?? .idle) == .idle)
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 7, tabId: nil)) {
      $0.alert = expectedScriptFailureAlert(
        kind: .archive,
        exitMessage: "Script exited with code 7.",
        worktreeID: featureWorktree.id,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: nil, tabId: nil))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
    var initialState = makeState(repositories: [repository])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
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
    #expect(store.state.sidebarItems[id: featureWorktree.id]?.lifecycle == .archiving)

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
    }
    await store.finish()
    #expect((store.state.sidebarItems[id: featureWorktree.id]?.lifecycle ?? .idle) == .idle)
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
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
    #expect(store.state.sidebarItems[id: featureWorktree.id]?.lifecycle == .archiving)

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: nil))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
    }
    await store.finish()
    #expect((store.state.sidebarItems[id: featureWorktree.id]?.lifecycle ?? .idle) == .idle)
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

  @Test(.dependencies, arguments: archiveExitCodeCases)
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: exitCode, tabId: nil)) {
      $0.alert = expectedScriptFailureAlert(
        kind: .archive,
        exitMessage: expectedMessage,
        worktreeID: featureWorktree.id,
        repoName: "repo",
        worktreeName: "feature",
      )
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Exit code 1 must NOT trigger archiveWorktreeApply.
    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: nil)) {
      $0.alert = expectedScriptFailureAlert(
        kind: .archive,
        exitMessage: "Script failed (exit code 1).",
        worktreeID: featureWorktree.id,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    // Nil exit code (Ctrl+D, tab close) must NOT trigger archiveWorktreeApply.
    await store.send(.archiveScriptCompleted(worktreeID: featureWorktree.id, exitCode: nil, tabId: nil))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
      state.reconcileSidebarForTesting()
      state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteSidebarItemConfirmed(featureWorktree.id, repository.id))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
      $0.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in await MainActor.run { worktree.workingDirectory } }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
    }
    await store.receive(\.deleteWorktreeApply)
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .deleting
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.worktreeDeleted) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
      $0.repositories = [makeRepository(id: repoRoot, worktrees: [mainWorktree])]
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 7, tabId: nil)) {
      $0.alert = expectedScriptFailureAlert(
        kind: .delete,
        exitMessage: "Script exited with code 7.",
        worktreeID: featureWorktree.id,
        repoName: "repo",
        worktreeName: "feature"
      )
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: nil, tabId: nil))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
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
    var initialState = makeState(repositories: [repository])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.removeWorktree = { worktree, _ in await MainActor.run { worktree.workingDirectory } }
      $0.gitClient.worktrees = { _ in [mainWorktree] }
    }

    await store.send(.deleteSidebarItemConfirmed(featureWorktree.id, repository.id))
    await store.receive(\.deleteWorktreeApply)
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .deleting
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.worktreeDeleted) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
      $0.repositories = [makeRepository(id: repoRoot, worktrees: [mainWorktree])]
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
    }
  }

  @Test(.dependencies) func deleteScriptCompletedSuccessButWorktreeGoneShowsAlert() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.reconcileSidebarForTesting()
    // The worktree is gone from the roster but the row stayed alive at
    // `.deletingScript` because the script was already in flight.
    state.sidebarItems.append(
      SidebarItemFeature.State(
        id: "/tmp/repo/gone",
        repositoryID: RepositoryID(repoRoot),
        kind: .gitWorktree,
        name: "gone",
        branchName: "gone",
        subtitle: nil,
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/gone"),
        repositoryAccent: nil,
        isMainWorktree: false,
        isPinned: false,
        hasMergedBadge: false
      )
    )
    state.sidebarItems[id: "/tmp/repo/gone"]?.lifecycle = .deletingScript
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
      $0.alert = expectedAlert
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: "/tmp/repo/gone"]?.lifecycle = .idle
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
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
    #expect(store.state.sidebarItems[id: featureWorktree.id]?.lifecycle == .deletingScript)

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 0, tabId: nil))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
    }
    await store.finish()
    #expect((store.state.sidebarItems[id: featureWorktree.id]?.lifecycle ?? .idle) == .idle)
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
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
    #expect(store.state.sidebarItems[id: featureWorktree.id]?.lifecycle == .deletingScript)

    await store.send(.deleteScriptCompleted(worktreeID: featureWorktree.id, exitCode: 1, tabId: nil))
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.lifecycle = .idle
    }
    await store.finish()
    #expect((store.state.sidebarItems[id: featureWorktree.id]?.lifecycle ?? .idle) == .idle)
    #expect(store.state.alert != nil)
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
      $0.reconcileSidebarForTesting()
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
    var state = makeState(repositories: [repoA, repoB])
    state.reconcileSidebarForTesting()

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
    state.reconcileSidebarForTesting()

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
    state.reconcileSidebarForTesting()

    expectNoDifference(
      state.orderedSidebarItems(includingRepositoryIDs: [repoB.id]).map(\.id),
      [
        "/tmp/repo-b/wt2"
      ]
    )
  }

  @Test func orderedSidebarItemIDsMatchHeavyFlavorAndPlacePendingFirst() {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let feature = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let other = makeRepository(id: "/tmp/repo-other", worktrees: [])
    var state = makeState(repositories: [makeRepository(id: repoRoot, worktrees: [main, feature]), other])
    state.pendingWorktrees = [
      PendingWorktree(
        id: "/tmp/repo/wip",
        repositoryID: RepositoryID(repoRoot),
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName)
      )
    ]
    state.reconcileSidebarForTesting()

    // Pending row renders before non-pending unpinned, so the bucket must too. Otherwise
    // Cmd+N hint and target diverge while a worktree is creating.
    expectNoDifference(
      state.orderedSidebarItemIDs(includingRepositoryIDs: [RepositoryID(repoRoot)]),
      [WorktreeID(repoRoot), "/tmp/repo/wip", "/tmp/repo/feature"]
    )

    // ID flavor and heavy flavor must agree for every filter the render path can pass.
    for filter: Set<Repository.ID> in [[RepositoryID(repoRoot)], [other.id], [RepositoryID(repoRoot), other.id], []] {
      expectNoDifference(
        state.orderedSidebarItemIDs(includingRepositoryIDs: filter),
        state.orderedSidebarItems(includingRepositoryIDs: filter).map(\.id)
      )
    }
  }

  private func makeAlphabeticNestingState() -> RepositoriesFeature.State {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/feature-a", name: "feature/a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/feature-b", name: "feature/b", repoRoot: repoRoot)
    let zulu = makeWorktree(id: "/tmp/repo/zulu", name: "zulu", repoRoot: repoRoot)
    var state = makeState(
      repositories: [makeRepository(id: repoRoot, worktrees: [main, zulu, featureB, featureA, alpha])]
    )
    state.$sidebarNestWorktreesByBranch.withLock { $0 = true }
    state.reconcileSidebarForTesting()
    return state
  }

  @Test func orderedSidebarItemIDsAlphabetizesWhenNestingIsOn() {
    let state = makeAlphabeticNestingState()
    // Main first, then unpinned tail in alphabetical order (alpha, feature/a,
    // feature/b, zulu). feature/a + feature/b group under a `feature` header.
    expectNoDifference(
      state.orderedSidebarItemIDs(includingRepositoryIDs: ["/tmp/repo"]),
      [
        "/tmp/repo", "/tmp/repo/alpha", "/tmp/repo/feature-a", "/tmp/repo/feature-b", "/tmp/repo/zulu",
      ]
    )
  }

  @Test func orderedSidebarItemIDsSkipsCollapsedGroupsWhenNestingIsOn() {
    var state = makeAlphabeticNestingState()
    state.$sidebar.withLock { sidebar in
      sidebar.sections["/tmp/repo", default: .init()].buckets[.unpinned, default: .init()]
        .collapsedBranchPrefixes = ["feature"]
    }
    expectNoDifference(
      state.orderedSidebarItemIDs(includingRepositoryIDs: ["/tmp/repo"]),
      ["/tmp/repo", "/tmp/repo/alpha", "/tmp/repo/zulu"]
    )
  }

  @Test func orderedSidebarItemIDsRestoresCustomOrderWhenNestingIsOff() {
    var state = makeAlphabeticNestingState()
    state.$sidebarNestWorktreesByBranch.withLock { $0 = false }
    expectNoDifference(
      state.orderedSidebarItemIDs(includingRepositoryIDs: ["/tmp/repo"]),
      [
        "/tmp/repo", "/tmp/repo/zulu", "/tmp/repo/feature-b", "/tmp/repo/feature-a", "/tmp/repo/alpha",
      ]
    )
  }

  @Test func orderedSidebarItemIDsKeepsPendingBeforeUnpinnedWithNestingOn() {
    // Pending worktrees render between pinned-tail and unpinned-tail in the
    // sidebar, regardless of nesting. The hotkey order must agree.
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureA = makeWorktree(id: "/tmp/repo/feature-a", name: "feature/a", repoRoot: repoRoot)
    let featureB = makeWorktree(id: "/tmp/repo/feature-b", name: "feature/b", repoRoot: repoRoot)
    var state = makeState(repositories: [makeRepository(id: repoRoot, worktrees: [main, featureA, featureB])])
    state.$sidebarNestWorktreesByBranch.withLock { $0 = true }
    state.pendingWorktrees = [
      PendingWorktree(
        id: "/tmp/repo/wip",
        repositoryID: RepositoryID(repoRoot),
        progress: WorktreeCreationProgress(stage: .choosingWorktreeName)
      )
    ]
    state.reconcileSidebarForTesting()

    expectNoDifference(
      state.orderedSidebarItemIDs(includingRepositoryIDs: [RepositoryID(repoRoot)]),
      ["/tmp/repo", "/tmp/repo/wip", "/tmp/repo/feature-a", "/tmp/repo/feature-b"]
    )
  }

  @Test func worktreeIDByOffsetLandsOnNearestVisibleNeighborWhenSelectionIsHidden() {
    // When the current selection sits inside a collapsed group, arrow nav
    // should land on the nearest visible neighbor in the direction of travel
    // rather than jumping to the top or bottom of the list.
    var state = makeAlphabeticNestingState()
    state.$sidebar.withLock { sidebar in
      sidebar.sections["/tmp/repo", default: .init()].buckets[.unpinned, default: .init()]
        .collapsedBranchPrefixes = ["feature"]
    }
    state.reconcileSidebarForTesting()
    // feature/a is now hidden behind the collapsed `feature` group; visible
    // hotkey list is [main, alpha, zulu]. Anchor index of feature/a in the
    // unfiltered list sits between alpha and zulu.
    state.setSingleWorktreeSelection("/tmp/repo/feature-a")
    #expect(state.worktreeID(byOffset: 1) == "/tmp/repo/zulu")
    #expect(state.worktreeID(byOffset: -1) == "/tmp/repo/alpha")
  }

  @Test func worktreeIDByOffsetWalksHoistedRowsBeforePerRepoRows() {
    // When a worktree is hoisted into the Pinned section, arrow nav must walk
    // the hoisted row (visible at the top) before falling into the per-repo
    // rows, matching what the user actually sees in the sidebar.
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let alpha = makeWorktree(id: "/tmp/repo/alpha", name: "alpha", repoRoot: repoRoot)
    let bravo = makeWorktree(id: "/tmp/repo/bravo", name: "bravo", repoRoot: repoRoot)
    var state = makeState(repositories: [makeRepository(id: repoRoot, worktrees: [main, alpha, bravo])])
    // Pin bravo so it hoists to the Pinned section at the top.
    state.$sidebar.withLock { sidebar in
      var section = sidebar.sections[RepositoryID(repoRoot)] ?? .init()
      var pinnedBucket = section.buckets[.pinned] ?? .init()
      pinnedBucket.items[bravo.id] = .init()
      section.buckets[.pinned] = pinnedBucket
      var unpinnedBucket = section.buckets[.unpinned] ?? .init()
      unpinnedBucket.items.removeValue(forKey: bravo.id)
      section.buckets[.unpinned] = unpinnedBucket
      sidebar.sections[RepositoryID(repoRoot)] = section
    }
    state.reconcileSidebarForTesting()

    // Visible order: [bravo (Pinned hoist), main, alpha].
    state.setSingleWorktreeSelection(bravo.id)
    #expect(state.worktreeID(byOffset: 1) == main.id)
    state.setSingleWorktreeSelection(main.id)
    #expect(state.worktreeID(byOffset: -1) == bravo.id)
    state.setSingleWorktreeSelection(alpha.id)
    // Wrap-around from last → first lands on the hoisted row, not the
    // per-repo position bravo would have had in bucket order.
    #expect(state.worktreeID(byOffset: 1) == bravo.id)
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
        repoB.id.rawValue,
        repoA.id.rawValue,
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
      sidebar.sections[RepositoryID(repoRoot)] = .init(
        buckets: [
          .unpinned: .init(
            items: [worktree1.id: .init(), worktree2.id: .init(), worktree3.id: .init()]
          )
        ]
      )
    }
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.unpinnedWorktreesMoved(repositoryID: RepositoryID(repoRoot), IndexSet(integer: 0), 3)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.reorder(
          bucket: .unpinned,
          in: RepositoryID(repoRoot),
          to: [worktree2.id, worktree3.id, worktree1.id]
        )
      }
      RepositoriesFeature.syncSidebar(&$0)
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
      sidebar.sections[RepositoryID(repoA)] = .init(
        buckets: [
          .pinned: .init(items: [worktreeA1.id: .init(), worktreeA2.id: .init()])
        ]
      )
      sidebar.sections[RepositoryID(repoB)] = .init(
        buckets: [.pinned: .init(items: [worktreeB1.id: .init()])]
      )
    }
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.pinnedWorktreesMoved(repositoryID: RepositoryID(repoA), IndexSet(integer: 1), 0)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.reorder(bucket: .pinned, in: RepositoryID(repoA), to: [worktreeA2.id, worktreeA1.id])
      }
      RepositoriesFeature.syncSidebar(&$0)
    }
  }

  @Test func loadRepositoriesFailureKeepsPreviousState() async {
    let repository = makeRepository(id: "/tmp/repo", worktrees: [])
    var initialState = makeState(repositories: [repository])
    initialState.reconcileSidebarForTesting()
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
      $0.reconcileSidebarForTesting()
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
      sidebar.sections[RepositoryID(repoRoot)] = .init(
        buckets: [
          .unpinned: .init(items: [worktree1.id: .init(), worktree2.id: .init()])
        ]
      )
    }
    initialState.reconcileSidebarForTesting()
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
      $0.reconcileSidebarForTesting()
    }

    await store.receive(\.delegate.repositoriesChanged)
    expectNoDifference(
      Array(
        store.state.sidebar.sections[RepositoryID(repoRoot)]?.buckets[.unpinned]?.items.keys ?? []
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
    initialState.reconcileSidebarForTesting()
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
      $0.reconcileSidebarForTesting()
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
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
    }
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
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
    }
  }

  @Test func worktreeDeletedPrunesStateAndSendsDelegates() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: "/tmp/repo/main", name: "main", repoRoot: repoRoot)
    let removedWorktree = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, removedWorktree])
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.selection = .worktree(mainWorktree.id)
    initialState.reconcileSidebarForTesting()

    initialState.sidebarItems[id: removedWorktree.id]?.lifecycle = .deleting
    initialState.sidebarItems[id: removedWorktree.id]?.lifecycle = .pending
    initialState.sidebarItems[id: removedWorktree.id]?.shouldFocusTerminal = true
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
    initialState.setWorktreeInfoForTesting(id: removedWorktree.id, addedLines: 1, removedLines: 2, pullRequest: nil)
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
      $0.sidebarItems[id: removedWorktree.id]?.lifecycle = .idle
      $0.pendingWorktrees = []
      $0.repositories = [updatedRepository]
      $0.$sidebar.withLock { sidebar in
        sidebar.removeAnywhere(worktree: removedWorktree.id, in: repository.id)
      }
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
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
    initialState.reconcileSidebarForTesting()

    initialState.sidebarItems[id: removedWorktree.id]?.lifecycle = .deleting
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
      $0.sidebarItems[id: removedWorktree.id]?.lifecycle = .idle
      $0.repositories = [updatedRepository]
      $0.selection = .worktree(mainWorktree.id)
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.reloadRepositories)
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
    }
  }

  @Test func createRandomWorktreeSucceededSendsRepositoriesChanged() async {
    let repoRoot = "/tmp/repo"
    let existingWorktree = makeWorktree(id: "/tmp/repo/wt-main", name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [existingWorktree])
    let newWorktree = makeWorktree(id: "/tmp/repo/wt-new", name: "new", repoRoot: repoRoot)
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [newWorktree, existingWorktree])
    let pendingID = WorktreeID("pending:\(UUID().uuidString)")
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
      $0.pendingWorktrees = []
      $0.selection = .worktree(newWorktree.id)
      $0.sidebarSelectedWorktreeIDs = [newWorktree.id]
      $0.worktreeMRU = [newWorktree.id]
      $0.repositories = [updatedRepository]
      RepositoriesFeature.syncSidebar(&$0)
      $0.sidebarItems[id: newWorktree.id]?.lifecycle = .pending
      $0.applyPostReduceCacheRecomputes([.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: newWorktree.id]?.shouldFocusTerminal = true
    }

    await store.receive(\.reloadRepositories)
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.delegate.worktreeCreated)
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
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
    state.reconcileSidebarForTesting()
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
      store.state.sidebarItems[id: featureWorktree.id]?.pullRequest == mergedPullRequest
    )
  }

  @Test func repositoryPullRequestsLoadedSkipsAutoArchiveForMainWorktree() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var state = makeState(repositories: [repository])
    state.mergedWorktreeAction = .archive
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: mainWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [mainWorktree.id: mergedPullRequest]
      )
    )
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: mainWorktree.id]?.pullRequest = mergedPullRequest
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
    state.reconcileSidebarForTesting()
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
    )
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    )
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequest = mergedPullRequest
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    )
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequest = mergedPullRequest
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deleting
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    )
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequest = mergedPullRequest
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let mergedPullRequest = makePullRequest(state: "MERGED", headRefName: featureWorktree.name)

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: mergedPullRequest]
      )
    )
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequest = mergedPullRequest
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
    state.reconcileSidebarForTesting()
    state.setWorktreeInfoForTesting(
      id: featureWorktree.id, addedLines: nil, removedLines: nil, pullRequest: mergedPullRequest)
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
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: refreshedPullRequest]
      )
    )
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequest = refreshedPullRequest
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
    state.reconcileSidebarForTesting()
    state.setWorktreeInfoForTesting(
      id: featureWorktree.id, addedLines: nil, removedLines: nil, pullRequest: openPullRequest)
    let mergedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
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
    #expect(store.state.sidebarItems[id: featureWorktree.id]?.pullRequest?.state == "OPEN")
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
    state.reconcileSidebarForTesting()
    state.setWorktreeInfoForTesting(
      id: featureWorktree.id, addedLines: nil, removedLines: nil, pullRequest: openPullRequest)
    let closedNumbers = LockIsolated<[Int]>([])
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
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
    state.reconcileSidebarForTesting()
    state.setWorktreeInfoForTesting(
      id: featureWorktree.id, addedLines: nil, removedLines: nil, pullRequest: openPullRequest)
    let recordedRemote = LockIsolated<GithubRemoteInfo?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
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
    state.reconcileSidebarForTesting()
    state.setWorktreeInfoForTesting(
      id: featureWorktree.id, addedLines: nil, removedLines: nil, pullRequest: openPullRequest)
    let recordedRemote = LockIsolated<GithubRemoteInfo?>(nil)
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
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
      // This test intentionally skips sidebar reconciliation; the PR refresh
      // bookkeeping under test (`inFlightPullRequestRefreshRepositoryIDs`,
      // `inFlightPullRequestBranchSnapshotsByRepositoryID`) doesn't read from
      // `sidebarItems`. Opt out of the structure-cache recompute so the hook
      // doesn't surface a placeholder → real mutation against the empty
      // sidebar.
      $0.sidebarStructureAutoRecompute = false
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
      $0.inFlightPullRequestBranchSnapshotsByRepositoryID[repository.id] = [:]
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.inFlightPullRequestBranchSnapshotsByRepositoryID = [:]
    }
    await store.finish()
  }

  @Test func successToastAutoDismissesAfterTheDelay() async {
    var state = makeState(repositories: [])
    state.reconcileSidebarForTesting()
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.showToast(.success("Pull request merged"))) {
      $0.statusToast = .success("Pull request merged")
    }
    await clock.advance(by: .milliseconds(2400))
    #expect(store.state.statusToast == .success("Pull request merged"))

    await clock.advance(by: .milliseconds(100))
    await store.receive(\.dismissToast) {
      $0.statusToast = nil
    }
    await store.finish()
  }

  @Test func replacingASuccessToastDoesNotInheritTheCancelledAutoDismiss() async {
    var state = makeState(repositories: [])
    state.reconcileSidebarForTesting()
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.showToast(.success("Pull request merged"))) {
      $0.statusToast = .success("Pull request merged")
    }
    await store.send(.showToast(.success("Pull request closed"))) {
      $0.statusToast = .success("Pull request closed")
    }
    // `cancelInFlight` re-arms a single fresh 2.5s timer for the replacement toast rather than stacking a
    // second dismissal: the toast survives the first timer's original deadline and dismisses once, later.
    await clock.advance(by: .milliseconds(2400))
    #expect(store.state.statusToast == .success("Pull request closed"))

    await clock.advance(by: .milliseconds(100))
    await store.receive(\.dismissToast) {
      $0.statusToast = nil
    }
    await store.finish()
  }

  @Test func inProgressToastCancelsAPendingSuccessAutoDismiss() async {
    var state = makeState(repositories: [])
    state.reconcileSidebarForTesting()
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.showToast(.success("Pull request merged"))) {
      $0.statusToast = .success("Pull request merged")
    }
    await store.send(.showToast(.inProgress("Closing pull request…"))) {
      $0.statusToast = .inProgress("Closing pull request…")
    }
    // An in-progress toast schedules no auto-dismiss and cancels the success timer, so it never self-dismisses.
    await clock.advance(by: .seconds(5))
    #expect(store.state.statusToast == .inProgress("Closing pull request…"))
    await store.finish()
  }

  @Test func delayedPullRequestRefreshFiresAfterTheDelay() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.githubIntegrationAvailability = .disabled
    state.reconcileSidebarForTesting()
    let clock = TestClock()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    // Two rapid requests must collapse to a single fire (cancelInFlight), not stack two refreshes.
    await store.send(.delayedPullRequestRefresh(featureWorktree.id))
    await store.send(.delayedPullRequestRefresh(featureWorktree.id))
    await clock.advance(by: .seconds(2))
    // GitHub integration is disabled, so the refresh lands as a no-op. A second event would trip `finish()`, so
    // matching exactly one here proves the two requests coalesced into a single refresh.
    await store.receive(\.worktreeInfoEvent)
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
    var initialState = makeState(repositories: [repository])
    initialState.reconcileSidebarForTesting()
    let clock = TestClock()
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.continuousClock = clock
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

    // The recovery loop re-checks availability on every interval, and the pending refresh survives each failed check.
    await clock.advance(by: .seconds(15))
    await store.receive(\.refreshGithubIntegrationAvailability) {
      $0.githubIntegrationAvailability = .checking
    }
    await store.receive(\.githubIntegrationAvailabilityUpdated) {
      $0.githubIntegrationAvailability = .unavailable
    }

    await store.send(.setGithubIntegrationEnabled(false)) {
      $0.githubIntegrationAvailability = .disabled
      $0.pendingPullRequestRefreshByRepositoryID = [:]
      $0.queuedPullRequestRefreshByRepositoryID = [:]
      $0.inFlightPullRequestRefreshRepositoryIDs = []
    }
    await store.finish()
  }

  @Test func githubIntegrationRecoveryStopsRecheckingOnceAvailable() async {
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.githubIntegrationAvailability = .checking
    initialState.reconcileSidebarForTesting()
    let clock = TestClock()
    let isAvailable = LockIsolated(false)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
      $0.continuousClock = clock
      $0.githubIntegration.isAvailable = { isAvailable.value }
    }

    await store.send(.githubIntegrationAvailabilityUpdated(false)) {
      $0.githubIntegrationAvailability = .unavailable
    }

    // Still unavailable after the first interval: the loop re-arms and checks again on the next one.
    await clock.advance(by: .seconds(15))
    await store.receive(\.refreshGithubIntegrationAvailability) {
      $0.githubIntegrationAvailability = .checking
    }
    await store.receive(\.githubIntegrationAvailabilityUpdated) {
      $0.githubIntegrationAvailability = .unavailable
    }

    isAvailable.setValue(true)
    await clock.advance(by: .seconds(15))
    await store.receive(\.refreshGithubIntegrationAvailability) {
      $0.githubIntegrationAvailability = .checking
    }
    await store.receive(\.githubIntegrationAvailabilityUpdated) {
      $0.githubIntegrationAvailability = .available
    }

    // Recovering cancels the loop: further intervals must not re-check.
    await clock.advance(by: .seconds(60))
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
    initialState.reconcileSidebarForTesting()
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
      // Mirror the sibling worktreeInfoEvent tests: opt out of the structure
      // cache recompute so the empty-sidebar starting state doesn't surface a
      // placeholder → real mutation on the replayed refresh.
      $0.sidebarStructureAutoRecompute = false
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
      $0.inFlightPullRequestBranchSnapshotsByRepositoryID[repository.id] = [:]
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.inFlightPullRequestBranchSnapshotsByRepositoryID = [:]
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
    } withDependencies: {
      $0.continuousClock = TestClock()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
      $0.inFlightPullRequestBranchSnapshotsByRepositoryID[repository.id] = [
        mainWorktree.id: mainWorktree.name,
        featureWorktree.id: featureWorktree.name,
      ]
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: mainWorktree.id]?.pullRequestBranchAtQueryTime = mainWorktree.name
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequestBranchAtQueryTime = featureWorktree.name
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.inFlightPullRequestBranchSnapshotsByRepositoryID = [:]
    }
    await store.finish()
  }

  @Test func repositoryPullRequestsLoadedDispatchesUnchangedPullRequestToClearWatermark() async {
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
    state.reconcileSidebarForTesting()
    state.setWorktreeInfoForTesting(
      id: featureWorktree.id, addedLines: nil, removedLines: nil, pullRequest: pullRequest)
    // Watermark armed by a prior `pullRequestQueryStarted`; the identical-PR
    // completion must clear it so the row can re-arm a future query.
    state.sidebarItems[id: featureWorktree.id]?.pullRequestBranchAtQueryTime = featureWorktree.name
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .repositoryPullRequestsLoaded(
        repositoryID: repository.id,
        pullRequestsByWorktreeID: [featureWorktree.id: pullRequest]
      )
    )
    await store.receive(\.sidebarItems[id: featureWorktree.id].pullRequestChanged) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequestBranchAtQueryTime = nil
    }
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
    state.reconcileSidebarForTesting()
    state.setWorktreeInfoForTesting(
      id: featureWorktree.id, addedLines: nil, removedLines: nil, pullRequest: makePullRequest(state: "OPEN")
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
    )
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequest = nil
    }
  }

  @Test func worktreeInfoEventRepositoryPullRequestRefreshArmsAndClearsWatermark() async {
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
    state.reconcileSidebarForTesting()
    let pullRequest = makePullRequest(state: "OPEN", headRefName: featureWorktree.name)
    let featureName = featureWorktree.name
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.remoteInfo = { _ in GithubRemoteInfo(host: "github.com", owner: "o", repo: "r") }
      $0.githubCLI.batchPullRequests = { _, _, _, _ in [featureName: pullRequest] }
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
      $0.inFlightPullRequestBranchSnapshotsByRepositoryID[repository.id] = [
        mainWorktree.id: mainWorktree.name,
        featureWorktree.id: featureWorktree.name,
      ]
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: mainWorktree.id]?.pullRequestBranchAtQueryTime = mainWorktree.name
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequestBranchAtQueryTime = featureWorktree.name
    }
    await store.receive(\.repositoryPullRequestsLoaded)
    // Main carries `pullRequest == nil` and the completion result is `nil`; the row reducer
    // skips the PR-value mutation but still clears the watermark armed above.
    await store.receive(\.sidebarItems[id: mainWorktree.id].pullRequestChanged) {
      $0.sidebarItems[id: mainWorktree.id]?.pullRequestBranchAtQueryTime = nil
    }
    await store.receive(\.sidebarItems[id: featureWorktree.id].pullRequestChanged) {
      $0.sidebarItems[id: featureWorktree.id]?.pullRequest = pullRequest
      $0.sidebarItems[id: featureWorktree.id]?.pullRequestBranchAtQueryTime = nil
    }
    await store.receive(\.repositoryPullRequestRefreshCompleted) {
      $0.inFlightPullRequestRefreshRepositoryIDs = []
      $0.inFlightPullRequestBranchSnapshotsByRepositoryID = [:]
    }
    await store.finish()
  }

  @Test func unarchiveWorktreeNoopsWhenNotArchived() async {
    let worktree = makeWorktree(id: "/tmp/wt", name: "owl")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.reconcileSidebarForTesting()
    let store = TestStore(initialState: initialState) {
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deleting
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
    // Refresh caches so the surfaced delete-script row is in the initial
    // structure; otherwise the action's post-reduce recompute reads as a change.
    state.applyPostReduceCacheRecomputes()
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .archiving
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = [wt2.id]
      $0.worktreeMRU = [wt1.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt1.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt1.id]?.shouldFocusTerminal = true
    }
  }

  @Test func selectPreviousWorktreeWrapsBackward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeMRU = [wt2.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt2.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt2.id]?.shouldFocusTerminal = true
    }
  }

  @Test func selectNextWorktreeWithNoSelectionSelectsFirst() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.worktreeMRU = [wt1.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt1.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt1.id]?.shouldFocusTerminal = true
    }
  }

  @Test func selectNextWorktreeCollapsesSidebarSelectionToSingleWorktree() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let wt3 = makeWorktree(id: "/tmp/wt3", name: "gamma")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2, wt3])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = [wt1.id, wt3.id]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeMRU = [wt2.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt2.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt2.id]?.shouldFocusTerminal = true
    }
  }

  @Test func selectPreviousWorktreeWithNoSelectionSelectsLast() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.worktreeMRU = [wt2.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt2.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt2.id]?.shouldFocusTerminal = true
    }
  }

  @Test func selectNextWorktreeFollowsSidebarOrderNotRawWorktreeList() async {
    let repoRoot = "/tmp/repo"
    let main = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let feature = makeWorktree(id: "/tmp/repo/feature", name: "feature", repoRoot: repoRoot)
    let bugfix = makeWorktree(id: "/tmp/repo/bugfix", name: "bugfix", repoRoot: repoRoot)
    let repository = makeRepository(id: repoRoot, worktrees: [main, feature, bugfix])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(main.id)
    // Pin bugfix so it hoists into the Pinned highlight section; visible order
    // becomes [bugfix (hoist), main, feature]. Arrow nav from main lands on
    // feature, not on bugfix's per-repo bucket position.
    state.$sidebar.withLock { sidebar in
      sidebar.sections[RepositoryID(repoRoot)] = .init(buckets: [.pinned: .init(items: [bugfix.id: .init()])])
    }
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(feature.id)
      $0.sidebarSelectedWorktreeIDs = [feature.id]
      $0.worktreeHistoryBackStack = [main.id]
      $0.worktreeMRU = [feature.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: feature.id].focusTerminalRequested) {
      $0.sidebarItems[id: feature.id]?.shouldFocusTerminal = true
    }
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(worktree.id)
      $0.sidebarSelectedWorktreeIDs = [worktree.id]
      $0.worktreeMRU = [worktree.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: worktree.id].focusTerminalRequested) {
      $0.sidebarItems[id: worktree.id]?.shouldFocusTerminal = true
    }
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt3.id)
      $0.sidebarSelectedWorktreeIDs = [wt3.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeMRU = [wt3.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt3.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt3.id]?.shouldFocusTerminal = true
    }
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectPreviousWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = [wt3.id]
      $0.worktreeMRU = [wt1.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt1.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt1.id]?.shouldFocusTerminal = true
    }
  }

  @Test func selectNextWorktreeAllCollapsedIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/repo1/wt1", name: "alpha", repoRoot: "/tmp/repo1")
    let repo1 = makeRepository(id: "/tmp/repo1", worktrees: [wt1])
    var state = makeState(repositories: [repo1])
    state.selection = .worktree(wt1.id)
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repo1.id, default: .init()].collapsed = true
    }
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
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
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectNextWorktree)
    await store.receive(\.selectWorktree) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = [wt3.id]
      $0.worktreeMRU = [wt1.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt1.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt1.id]?.shouldFocusTerminal = true
    }
  }

  // MARK: - Worktree History Back/Forward.

  @Test func selectingDifferentWorktreePushesPreviousOntoBackStack() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.worktreeHistoryForwardStack = [wt2.id]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(wt2.id)) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeHistoryForwardStack = []
      $0.worktreeMRU = [wt2.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func reselectingSameWorktreeLeavesHistoryUntouched() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.sidebarSelectedWorktreeIDs = [wt1.id]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectWorktree(wt1.id)) {
      $0.worktreeMRU = [wt1.id]
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  @Test func worktreeHistoryBackPopsPreviousAndPushesCurrentToForward() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt2.id)
    state.worktreeHistoryBackStack = [wt1.id]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryBack) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = []
      $0.worktreeHistoryForwardStack = [wt2.id]
      $0.worktreeMRU = [wt1.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt1.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt1.id]?.shouldFocusTerminal = true
    }
  }

  @Test func worktreeHistoryForwardPopsNextAndPushesCurrentToBack() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.worktreeHistoryForwardStack = [wt2.id]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryForward) {
      $0.selection = .worktree(wt2.id)
      $0.sidebarSelectedWorktreeIDs = [wt2.id]
      $0.worktreeHistoryBackStack = [wt1.id]
      $0.worktreeHistoryForwardStack = []
      $0.worktreeMRU = [wt2.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt2.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt2.id]?.shouldFocusTerminal = true
    }
  }

  @Test func worktreeHistoryBackWithEmptyStackIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryBack)
  }

  @Test func worktreeHistoryForwardWithEmptyStackIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryForward)
  }

  @Test func worktreeHistoryBackSkipsStaleEntriesUntilValidIDFound() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let wt3 = makeWorktree(id: "/tmp/wt3", name: "gamma")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1, wt3])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt3.id)
    // wt2 was deleted between visits — its id is still in the
    // back stack but no longer resolves; the navigator should skip
    // it and land on wt1.
    state.worktreeHistoryBackStack = [wt1.id, "/tmp/wt2-deleted"]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryBack) {
      $0.selection = .worktree(wt1.id)
      $0.sidebarSelectedWorktreeIDs = [wt1.id]
      $0.worktreeHistoryBackStack = []
      $0.worktreeHistoryForwardStack = [wt3.id]
      $0.worktreeMRU = [wt1.id]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.sidebarItems[id: wt1.id].focusTerminalRequested) {
      $0.sidebarItems[id: wt1.id]?.shouldFocusTerminal = true
    }
  }

  @Test func worktreeHistoryBackWithOnlyStaleEntriesIsNoOp() async {
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)
    state.worktreeHistoryBackStack = ["/tmp/gone-a", "/tmp/gone-b"]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.worktreeHistoryBack) {
      $0.worktreeHistoryBackStack = []
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
  }

  @Test func pendingCreateSuccessLeavesBackStackWithRealPreviousOnly() async {
    // Walks the full pending → real navigation: starting from wt1,
    // creating a worktree pushes the pending row through line 962
    // (which records wt1 → pendingID), then succeeds and swaps to
    // the real id with `recordHistory: false`. The user's mental
    // model is "I navigated wt1 → newWorktree", so the back stack
    // must contain exactly [wt1] — not [wt1, pendingID] (the
    // bookkeeping intermediate) or [] (lost the navigation).
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: "/tmp/repo/wt-main", name: "main", repoRoot: repoRoot)
    let newWorktree = makeWorktree(id: "/tmp/repo/wt-new", name: "new", repoRoot: repoRoot)
    let updatedRepository = makeRepository(id: repoRoot, worktrees: [newWorktree, mainWorktree])
    let pendingID = WorktreeID("pending:\(UUID().uuidString)")
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches),
      )
    ]
    initialState.selection = .worktree(pendingID)
    initialState.sidebarSelectedWorktreeIDs = [pendingID]
    // Mirrors the post-line-962 state: wt1 was pushed when the
    // pending row was selected.
    initialState.worktreeHistoryBackStack = [mainWorktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [newWorktree, mainWorktree] }
    }

    await store.send(
      .createRandomWorktreeSucceeded(
        newWorktree,
        repositoryID: repository.id,
        pendingID: pendingID,
      )
    ) {
      $0.pendingWorktrees = []
      $0.selection = .worktree(newWorktree.id)
      $0.sidebarSelectedWorktreeIDs = [newWorktree.id]
      $0.worktreeMRU = [newWorktree.id]
      $0.repositories = [updatedRepository]
      RepositoriesFeature.syncSidebar(&$0)
      $0.sidebarItems[id: newWorktree.id]?.lifecycle = .pending
      $0.applyPostReduceCacheRecomputes([.sidebarStructure, .selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.sidebarItems) {
      $0.sidebarItems[id: newWorktree.id]?.shouldFocusTerminal = true
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.delegate.worktreeCreated)
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
    }
    #expect(store.state.worktreeHistoryBackStack == [mainWorktree.id])
    #expect(store.state.worktreeHistoryForwardStack.isEmpty)
  }

  @Test func pendingCreateFailureLeavesBackStackEmptyNotSelfReferential() async {
    // Regression for the "ghost back press" surfaced in review:
    // before `restoreSelection` sanitized the back stack, the
    // failure path left [wt1] on the back stack with selection==wt1.
    // Pressing ⌘⌃← would short-circuit and silently drain. Now
    // restoreSelection strips its own match so the stack matches
    // the user's expectation that the failed create was a no-op.
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let pendingID = WorktreeID("pending:\(UUID().uuidString)")
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree])
    var initialState = makeState(repositories: [repository])
    initialState.pendingWorktrees = [
      PendingWorktree(
        id: pendingID,
        repositoryID: repository.id,
        progress: WorktreeCreationProgress(stage: .loadingLocalBranches),
      )
    ]
    initialState.selection = .worktree(pendingID)
    initialState.sidebarSelectedWorktreeIDs = [pendingID]
    initialState.worktreeHistoryBackStack = [mainWorktree.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .createRandomWorktreeFailed(
        title: "Unable to create worktree",
        message: "boom",
        pendingID: pendingID,
        previousSelection: mainWorktree.id,
        repositoryID: repository.id,
        name: nil,
        baseDirectory: URL(fileURLWithPath: "/tmp/repo/.worktrees"),
      )
    )
    #expect(store.state.selection == .worktree(mainWorktree.id))
    #expect(store.state.worktreeHistoryBackStack.isEmpty)
    #expect(store.state.worktreeHistoryForwardStack.isEmpty)
  }

  @Test func archiveAutoPromotionDoesNotRecordHistory() async {
    // Archive of the currently-selected worktree mutates
    // `state.selection` directly (line 1570) rather than going
    // through `setSingleWorktreeSelection`, so the auto-promoted
    // next selection is intentionally NOT recorded into history.
    // A future refactor that routes auto-promotion through the
    // helper would silently start polluting the back stack —
    // this test pins the contract.
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(featureWorktree.id)
    state.sidebarSelectedWorktreeIDs = [featureWorktree.id]
    state.worktreeHistoryBackStack = [mainWorktree.id]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.dependencies.date = .constant(Date(timeIntervalSince1970: 1_000_000))
    store.exhaustivity = .off

    await store.send(.archiveWorktreeApply(featureWorktree.id, repository.id))
    #expect(store.state.worktreeHistoryBackStack == [mainWorktree.id])
    #expect(store.state.worktreeHistoryForwardStack.isEmpty)
  }

  @Test func deleteAutoPromotionDoesNotRecordHistory() async {
    // Mirror of the archive contract for delete:
    // `worktreeDeleted` reassigns `state.selection` directly
    // (around line 2016), bypassing history.
    let repoRoot = "/tmp/repo"
    let mainWorktree = makeWorktree(id: repoRoot, name: "main", repoRoot: repoRoot)
    let featureWorktree = makeWorktree(
      id: "\(repoRoot)/feature",
      name: "feature",
      repoRoot: repoRoot,
    )
    let repository = makeRepository(id: repoRoot, worktrees: [mainWorktree, featureWorktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(featureWorktree.id)
    state.sidebarSelectedWorktreeIDs = [featureWorktree.id]
    state.worktreeHistoryBackStack = [mainWorktree.id]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeDeleted(
        featureWorktree.id,
        repositoryID: repository.id,
        selectionWasRemoved: true,
        nextSelection: mainWorktree.id,
      )
    )
    #expect(store.state.worktreeHistoryBackStack == [mainWorktree.id])
    #expect(store.state.worktreeHistoryForwardStack.isEmpty)
  }

  @Test func emptySidebarSelectionDoesNotRecordIntoHistory() async {
    // Empty / archive-view / unknown-id selections are not
    // navigations the user can step forward out of, so they must
    // NOT push the previous worktree onto the back stack. The
    // tightened guard in `recordWorktreeHistoryTransition` enforces
    // this; this test pins the contract from the public action.
    let worktree = makeWorktree(id: "/tmp/repo/wt1", name: "wt1", repoRoot: "/tmp/repo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(worktree.id)
    state.sidebarSelectedWorktreeIDs = [worktree.id]
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(.selectionChanged([])) {
      $0.selection = nil
      $0.sidebarSelectedWorktreeIDs = []
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    #expect(store.state.worktreeHistoryBackStack.isEmpty)
    #expect(store.state.worktreeHistoryForwardStack.isEmpty)
  }

  @Test func canNavigateBackwardFiltersStaleAndSelfReferentialEntries() {
    // Menu enablement reads `canNavigateWorktreeHistoryBackward` —
    // it must report false for stacks that contain only stale ids
    // (worktrees deleted between visits) or a self-referential
    // entry equal to the current selection. Otherwise the menu
    // shows enabled but ⌘⌃← is a no-op.
    let wt1 = makeWorktree(id: "/tmp/wt1", name: "alpha")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [wt1])
    var state = makeState(repositories: [repository])
    state.selection = .worktree(wt1.id)

    state.worktreeHistoryBackStack = []
    #expect(!state.canNavigateWorktreeHistoryBackward)

    state.worktreeHistoryBackStack = ["/tmp/gone-a", "/tmp/gone-b"]
    #expect(!state.canNavigateWorktreeHistoryBackward)

    state.worktreeHistoryBackStack = [wt1.id]
    #expect(!state.canNavigateWorktreeHistoryBackward)

    let wt2 = makeWorktree(id: "/tmp/wt2", name: "beta")
    state.repositories = [makeRepository(id: "/tmp/repo", worktrees: [wt1, wt2])]
    state.worktreeHistoryBackStack = [wt2.id, "/tmp/gone"]
    #expect(state.canNavigateWorktreeHistoryBackward)
  }

  @Test func backStackIsCappedAtFiftyEntries() async {
    let worktrees = (0..<60).map { index in
      makeWorktree(id: "/tmp/wt\(index)", name: "wt\(index)")
    }
    let repository = makeRepository(id: "/tmp/repo", worktrees: worktrees)
    var state = makeState(repositories: [repository])
    state.selection = .worktree(worktrees[0].id)
    state.worktreeHistoryBackStack = (1..<51).map { worktrees[$0].id }
    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    let target = worktrees[55].id
    await store.send(.selectWorktree(target)) {
      $0.selection = .worktree(target)
      $0.sidebarSelectedWorktreeIDs = [target]
      // Oldest entry is dropped when we exceed the 50-item cap.
      $0.worktreeHistoryBackStack = (2..<51).map { worktrees[$0].id } + [worktrees[0].id]
      $0.worktreeMRU = [target]
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
  }

  // MARK: - Failed-repo removal.

  @Test func requestRemoveFailedRepositoryShowsConfirmationAlert() async {
    let repoID = "/tmp/missing-repo"
    var state = RepositoriesFeature.State()
    state.repositoryRoots = [URL(fileURLWithPath: repoID)]
    state.loadFailuresByID = [RepositoryID(repoID): "Not found"]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    let expectedAlert = AlertState<RepositoriesFeature.Alert> {
      TextState("Remove missing-repo?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmRemoveFailedRepository(RepositoryID(repoID))) {
        TextState("Remove Repository")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Removes the repository from Supacode. Nothing on disk is changed.")
    }
    await store.send(.requestRemoveFailedRepository(RepositoryID(repoID))) {
      $0.alert = expectedAlert
    }
  }

  @Test func dropStaleFailedRepositorySelectionClearsWhenFailureGone() {
    var state = RepositoriesFeature.State()
    state.selection = .failedRepository("/tmp/foo")
    state.loadFailuresByID = [:]
    state.dropStaleFailedRepositorySelection()
    #expect(state.selection == nil)
  }

  @Test func dropStaleFailedRepositorySelectionPreservesWhenFailureStillPresent() {
    var state = RepositoriesFeature.State()
    state.selection = .failedRepository("/tmp/foo")
    state.loadFailuresByID = ["/tmp/foo": "boom"]
    state.dropStaleFailedRepositorySelection()
    #expect(state.selection == .failedRepository("/tmp/foo"))
  }

  @Test func dropStaleFailedRepositorySelectionPreservesNonFailedSelection() {
    var state = RepositoriesFeature.State()
    state.selection = .archivedWorktrees
    state.dropStaleFailedRepositorySelection()
    #expect(state.selection == .archivedWorktrees)
  }

  private func makeWorktree(
    id: String,
    name: String,
    repoRoot: String = "/tmp/repo",
    createdAt: Date? = nil
  ) -> Worktree {
    Worktree(
      id: WorktreeID(id),
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
      statusCheckRollup: nil,
      mergeQueueEntry: nil
    )
  }

  private func makeRepository(
    id: String,
    name: String = "repo",
    worktrees: [Worktree]
  ) -> Repository {
    Repository(
      id: RepositoryID(id),
      rootURL: URL(fileURLWithPath: id),
      name: name,
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  /// Mirrors the base-directory resolution the reducer bakes into the prompt
  /// state, reading the same shared settings so the expectation stays accurate
  /// regardless of the host's home directory.
  private func expectedDefaultWorktreeBaseDirectory(for repositoryRootURL: URL) -> String {
    @Shared(.settingsFile) var settingsFile
    @Shared(.repositorySettings(repositoryRootURL)) var repositorySettings
    return SupacodePaths.worktreeBaseDirectory(
      for: repositoryRootURL,
      globalDefaultPath: settingsFile.global.defaultWorktreeBaseDirectoryPath,
      repositoryOverridePath: repositorySettings.worktreeBaseDirectoryPath
    )
    .path(percentEncoded: false)
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
    // Production seeds every cache on the roster load; without this the state
    // under test starts stale (an empty open-action map, a placeholder structure)
    // for a non-empty roster.
    state.applyCacheRecomputes(.all)
    return state
  }

  private func makeSidebarItem(
    id: String,
    name: String,
    repositoryID: Repository.ID = "/tmp/repo",
    kind: SidebarItemFeature.State.Kind = .gitWorktree,
    detail: String = "detail",
    isPinned: Bool = false,
    isMainWorktree: Bool = false
  ) -> SidebarItemFeature.State {
    SidebarItemFeature.State(
      id: WorktreeID(id),
      repositoryID: repositoryID,
      kind: kind,
      name: name,
      branchName: name,
      subtitle: detail.isEmpty ? nil : detail,
      workingDirectory: URL(fileURLWithPath: id),
      repositoryAccent: nil,
      isMainWorktree: isMainWorktree,
      isPinned: isPinned,
      hasMergedBadge: false
    )
  }

  @Test func sidebarDisplayNameReturnsNilForMainWorktree() {
    let row = makeSidebarItem(id: "/tmp/repo/main", name: "main", isMainWorktree: true)
    #expect(row.sidebarDisplayName == nil)
  }

  @Test func sidebarDisplayNameUsesIdLastPathComponent() {
    let row = makeSidebarItem(id: "/tmp/repo/feature-branch", name: "feature/branch")
    #expect(row.sidebarDisplayName == "feature-branch")
  }

  @Test func sidebarDisplayNameFallsBackToSubtitleLastComponentWhenIdHasNoSlash() {
    let row = makeSidebarItem(id: "row-no-slash", name: "feature/branch", detail: "/tmp/repo/wt-folder")
    #expect(row.sidebarDisplayName == "wt-folder")
  }

  @Test func sidebarDisplayNameFallsBackToBranchNameWhenIdAndSubtitleEmpty() {
    let row = makeSidebarItem(id: "row-no-slash", name: "feature/branch", detail: "")
    #expect(row.sidebarDisplayName == "feature/branch")
  }

  @Test func accentMapsMainPinnedAndDefault() {
    let main = makeSidebarItem(id: "/tmp/repo/main", name: "main", isMainWorktree: true)
    let pinned = makeSidebarItem(id: "/tmp/repo/p", name: "p", isPinned: true)
    let regular = makeSidebarItem(id: "/tmp/repo/r", name: "r")
    #expect(main.accent == .main)
    #expect(pinned.accent == .pinned)
    #expect(regular.accent == .default)
  }

  @Test func makeToolbarTitleContentForFolderUsesFolderName() {
    let folderID = "/tmp/Documents"
    let folderRow = makeSidebarItem(
      id: folderID,
      name: "Documents",
      repositoryID: "/tmp/Documents",
      kind: .folder,
      isMainWorktree: true
    )
    let worktree = makeWorktree(id: folderID, name: "Documents", repoRoot: "/tmp/Documents")
    let repository = makeRepository(id: "/tmp/Documents", name: "Documents", worktrees: [worktree])
    let state = makeState(repositories: [repository])

    let content = WorktreeDetailView.makeToolbarTitleContent(
      selectedWorktree: worktree,
      selectedRow: SelectedWorktreeSlice(folderRow),
      repositories: state,
      hideSubtitleOnMatch: true
    )

    guard case .folder(let name, _, _) = content else {
      Issue.record("Expected .folder content, got \(content)")
      return
    }
    #expect(name == "Documents")
  }

  @Test func makeToolbarTitleContentSuppressesSubtitleForSoleDefaultWorktree() {
    let mainID = "/tmp/repo/main"
    let mainRow = makeSidebarItem(id: mainID, name: "main", isMainWorktree: true)
    let worktree = makeWorktree(id: mainID, name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    let state = makeState(repositories: [repository])

    let content = WorktreeDetailView.makeToolbarTitleContent(
      selectedWorktree: worktree,
      selectedRow: SelectedWorktreeSlice(mainRow),
      repositories: state,
      hideSubtitleOnMatch: true
    )

    guard case .git(let payload) = content else {
      Issue.record("Expected .git content, got \(content)")
      return
    }
    #expect(payload.worktreeSubtitle == nil)
    #expect(payload.accent == .main)
  }

  @Test func makeToolbarTitleContentKeepsSubtitleWhenSiblingWorktreeExists() {
    let mainID = "/tmp/repo/main"
    let featureID = "/tmp/repo/feature"
    let mainRow = makeSidebarItem(id: mainID, name: "main", isMainWorktree: true)
    let main = makeWorktree(id: mainID, name: "main")
    let feature = makeWorktree(id: featureID, name: "feature")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [main, feature])
    let state = makeState(repositories: [repository])

    let content = WorktreeDetailView.makeToolbarTitleContent(
      selectedWorktree: main,
      selectedRow: SelectedWorktreeSlice(mainRow),
      repositories: state,
      hideSubtitleOnMatch: true
    )

    guard case .git(let payload) = content else {
      Issue.record("Expected .git content, got \(content)")
      return
    }
    // "Default" view-side fallback for main when a sibling exists.
    #expect(payload.worktreeSubtitle == "Default")
  }

  @Test func makeToolbarTitleContentHidesMatchingSubtitleWhenFlagOn() {
    let featureID = "/tmp/repo/foo"
    let mainID = "/tmp/repo/main"
    let main = makeWorktree(id: mainID, name: "main")
    let feature = makeWorktree(id: featureID, name: "feature/foo")
    let featureRow = makeSidebarItem(id: featureID, name: "feature/foo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [main, feature])
    let state = makeState(repositories: [repository])

    let content = WorktreeDetailView.makeToolbarTitleContent(
      selectedWorktree: feature,
      selectedRow: SelectedWorktreeSlice(featureRow),
      repositories: state,
      hideSubtitleOnMatch: true
    )

    guard case .git(let payload) = content else {
      Issue.record("Expected .git content, got \(content)")
      return
    }
    #expect(payload.worktreeSubtitle == nil)
  }

  @Test func makeToolbarTitleContentKeepsMatchingSubtitleWhenFlagOff() {
    let featureID = "/tmp/repo/foo"
    let mainID = "/tmp/repo/main"
    let main = makeWorktree(id: mainID, name: "main")
    let feature = makeWorktree(id: featureID, name: "feature/foo")
    let featureRow = makeSidebarItem(id: featureID, name: "feature/foo")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [main, feature])
    let state = makeState(repositories: [repository])

    let content = WorktreeDetailView.makeToolbarTitleContent(
      selectedWorktree: feature,
      selectedRow: SelectedWorktreeSlice(featureRow),
      repositories: state,
      hideSubtitleOnMatch: false
    )

    guard case .git(let payload) = content else {
      Issue.record("Expected .git content, got \(content)")
      return
    }
    #expect(payload.worktreeSubtitle == "foo")
  }

  @Test func makeToolbarTitleContentUsesSidebarCustomTitleOverride() {
    let mainID = "/tmp/repo/main"
    let worktree = makeWorktree(id: mainID, name: "main")
    let repository = makeRepository(id: "/tmp/repo", name: "repo", worktrees: [worktree])
    let mainRow = makeSidebarItem(id: mainID, name: "main", isMainWorktree: true)
    var state = makeState(repositories: [repository])
    state.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(title: "My Pretty Name")
    }

    let content = WorktreeDetailView.makeToolbarTitleContent(
      selectedWorktree: worktree,
      selectedRow: SelectedWorktreeSlice(mainRow),
      repositories: state,
      hideSubtitleOnMatch: true
    )

    guard case .git(let payload) = content else {
      Issue.record("Expected .git content, got \(content)")
      return
    }
    #expect(payload.repositoryName == "My Pretty Name")
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

    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repoA.id: .finder, repoB.id: .finder]
    }
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

    state.reconcileSidebarForTesting()
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
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [repoA, repoB]
      $0.repositoryRoots = [repoRootA, repoRootB].map { URL(fileURLWithPath: $0) }
      $0.selection = .worktree(worktreeB.id)
      $0.shouldRestoreLastFocusedWorktree = false
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.delegate.selectedWorktreeChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repoA.id: .finder, repoB.id: .finder]
    }
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
      kind: .folder,
      name: Repository.name(for: rootURL),
      detail: "",
      workingDirectory: rootURL,
      repositoryRootURL: rootURL,
      isAttached: false
    )
    let folderRepo = Repository(
      id: RepositoryID(repoRoot),
      rootURL: rootURL,
      name: Repository.name(for: rootURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [folderRepo]
      $0.repositoryRoots = [rootURL]
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [folderRepo.id: .finder]
    }
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
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = []
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.isInitialLoadComplete = true
      $0.loadFailuresByID = [
        RepositoryID(repoRoot): "Directory not found at \(repoRoot). It may have been moved or deleted."
      ]
      $0.reconcileSidebarForTesting()
    }
    await store.finish()
  }

  @Test func firstDuplicateWorktreeIDFindsRepeatedPath() {
    let main = makeWorktree(id: "/r/main", name: "main", repoRoot: "/r")
    let feature = makeWorktree(id: "/r/feature", name: "feature", repoRoot: "/r")
    let collision = makeWorktree(id: "/r/feature", name: "other", repoRoot: "/r")

    #expect(RepositoriesFeature.firstDuplicateWorktreeID(in: []) == nil)
    #expect(RepositoriesFeature.firstDuplicateWorktreeID(in: [main]) == nil)
    #expect(RepositoriesFeature.firstDuplicateWorktreeID(in: [main, feature]) == nil)
    #expect(RepositoriesFeature.firstDuplicateWorktreeID(in: [main, feature, collision]) == WorktreeID("/r/feature"))
    // The first-seen entry is not itself the duplicate; the repeat is.
    #expect(RepositoriesFeature.firstDuplicateWorktreeID(in: [feature, collision]) == WorktreeID("/r/feature"))
  }

  @Test func loadPersistedRepositoriesRefusesRepoWithDuplicateWorktreePaths() async {
    // A corrupt repo (e.g. a stale `core.worktree` redirect) can make the
    // worktree listing report the same path twice. Rather than crash building an
    // `IdentifiedArray` of duplicate ids (or silently guess which entry is real),
    // the loader refuses the repo and routes it through the failure row.
    let repoRoot = "/tmp/\(UUID().uuidString)-corrupt-git"
    let duplicatePath = "\(repoRoot)/feature"
    let first = makeWorktree(id: duplicatePath, name: "main", repoRoot: repoRoot)
    let second = makeWorktree(id: duplicatePath, name: "feature", repoRoot: repoRoot)

    // Pin the user-facing copy and that it threads the colliding path.
    let message = RepositoriesFeature.duplicateWorktreePathMessage(path: duplicatePath)
    #expect(message.contains("more than one worktree at the same path"))
    #expect(message.contains(duplicatePath))

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRoot] }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in [first, second] }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = []
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.isInitialLoadComplete = true
      $0.loadFailuresByID = [
        RepositoryID(repoRoot): RepositoriesFeature.duplicateWorktreePathMessage(path: duplicatePath)
      ]
      $0.reconcileSidebarForTesting()
    }
    await store.finish()
  }

  @Test func loadUnderXcodeLicenseGateShowsBannerNotBrokenRows() async {
    // The listing shells out to git; an unaccepted Xcode license makes every
    // git call fail. The loader must surface the banner and emit no failure
    // rows, so intact repos never look corrupt.
    let repoRoot = "/tmp/\(UUID().uuidString)-git"
    let licenseError = ShellClientError(
      command: "wt ls --json",
      stdout: "",
      stderr: "You have not agreed to the Xcode license agreements. "
        + "Please run 'sudo xcodebuild -license'.",
      exitCode: 69
    )
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [repoRoot] }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in throw licenseError }
      // A real block fails `git --version` too, so the authoritative probe confirms it.
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.gitEnvironmentChanged) {
      $0.gitEnvironmentError = .xcodeLicenseNotAccepted
    }
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = []
      $0.repositoryRoots = [URL(fileURLWithPath: repoRoot)]
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.finish()
    #expect(store.state.loadFailuresByID.isEmpty)
  }

  @Test func loadUnderGateKeepsFolderReposAndSuppressesGitFailures() async {
    // Regression guard: the environment gate only blocks git. Folder repos are
    // pure filesystem, so they must keep loading while the git roots are
    // suppressed under the banner.
    let gitRoot = "/tmp/\(UUID().uuidString)-git"
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let licenseError = ShellClientError(
      command: "wt ls --json",
      stdout: "",
      stderr: "Please run 'sudo xcodebuild -license' from within a Terminal.",
      exitCode: 69
    )
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [gitRoot, folderRoot] }
      $0.gitClient.isGitRepository = { $0.path(percentEncoded: false) == gitRoot }
      $0.gitClient.worktrees = { _ in throw licenseError }
      // A real block fails `git --version` too, so the authoritative probe confirms it.
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
    }

    let folderURL = URL(fileURLWithPath: folderRoot)
    let synthetic = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL,
      isAttached: false
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: [synthetic],
      isGitRepository: false
    )

    // Non-exhaustive: the derived sidebar-structure cache mirror isn't
    // reproducible for the "folder kept, git suppressed" mix, so assert the
    // meaningful outcome directly.
    store.exhaustivity = .off
    await store.send(.loadPersistedRepositories)
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == .xcodeLicenseNotAccepted)
    #expect(Array(store.state.repositories) == [folderRepo])
    #expect(store.state.repositoryRoots == [gitRoot, folderRoot].map { URL(fileURLWithPath: $0) })
    #expect(store.state.isInitialLoadComplete)
    #expect(store.state.loadFailuresByID.isEmpty)
  }

  @Test func loadWithNoGitRootsProbesGitEnvironmentForBanner() async {
    // With zero git roots nothing exercises git, so a standalone `git --version`
    // probe is the only way a fresh install surfaces the banner.
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.gitClient.checkGitEnvironment = { .developerToolsUnavailable }
    }

    await store.send(.loadPersistedRepositories)
    await store.receive(\.gitEnvironmentChanged) {
      $0.gitEnvironmentError = .developerToolsUnavailable
    }
    await store.receive(\.repositoriesLoaded) {
      $0.repositoryRoots = []
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.finish()
  }

  @Test func refreshAfterLicenseAcceptedClearsBannerAndReloads() async {
    // Once the user accepts the license, the periodic refresh re-probes, clears
    // the banner, and the repos reappear without a relaunch.
    let worktree = makeWorktree(id: "/tmp/repo/main", name: "main")
    let repository = makeRepository(id: "/tmp/repo", worktrees: [worktree])
    var initialState = makeState(repositories: [repository])
    initialState.gitEnvironmentError = .xcodeLicenseNotAccepted
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.worktrees = { _ in [worktree] }
    }

    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.gitEnvironmentChanged) {
      $0.gitEnvironmentError = nil
    }
    await store.receive(\.repositoriesLoaded) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [repository.id: .finder]
    }
    await store.finish()
  }

  @Test func refreshStaysActiveWhileBlockedEvenWithNoRoots() async {
    // The zero-root refresh normally early-returns; while blocked it must still
    // run so an accepted license can clear the banner.
    var initialState = RepositoriesFeature.State()
    initialState.gitEnvironmentError = .xcodeLicenseNotAccepted
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.checkGitEnvironment = { nil }
    }

    await store.send(.refreshWorktrees) {
      $0.isRefreshingWorktrees = true
    }
    await store.receive(\.reloadRepositories)
    await store.receive(\.gitEnvironmentChanged) {
      $0.gitEnvironmentError = nil
    }
    await store.receive(\.repositoriesLoaded) {
      $0.isRefreshingWorktrees = false
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.finish()
  }

  @Test func openRepositoriesUnderGateShowsBannerNotInvalidAlertForGitRepo() async throws {
    // Adding a real git repo while blocked must surface the banner and keep the
    // repo (as a blocked warning row), not the misleading "couldn't read this
    // folder" alert.
    let licenseError = ShellClientError(
      command: "wt root", stdout: "", stderr: "sudo xcodebuild -license", exitCode: 69)
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "supa-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let standardizedURL = tempDir.standardizedFileURL

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.repoRoot = { _ in throw licenseError }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in throw licenseError }
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.openRepositories([tempDir]))
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == .xcodeLicenseNotAccepted)
    #expect(store.state.repositoryRoots == [standardizedURL])
    #expect(store.state.alert == nil)
  }

  @Test func openRepositoriesAddsPlainFolderEvenWhileGitBlocked() async throws {
    // A plain folder needs no git, so the gate must not stop it from being
    // added, even though the banner also shows.
    let licenseError = ShellClientError(
      command: "wt root", stdout: "", stderr: "sudo xcodebuild -license", exitCode: 69)
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "supa-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let standardizedURL = tempDir.standardizedFileURL

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.repoRoot = { _ in throw licenseError }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
      $0.analyticsClient.capture = { _, _ in }
    }

    let folderWorktree = Worktree(
      id: Repository.folderWorktreeID(for: standardizedURL),
      kind: .folder,
      name: Repository.name(for: standardizedURL),
      detail: "",
      workingDirectory: standardizedURL,
      repositoryRootURL: standardizedURL,
      isAttached: false
    )
    let folderRepo = Repository(
      id: RepositoryID(standardizedURL.path(percentEncoded: false)),
      rootURL: standardizedURL,
      name: Repository.name(for: standardizedURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    // Non-exhaustive: the derived sidebar-structure cache mirror isn't
    // reproducible for the "folder kept, git suppressed" mix, so assert the
    // meaningful outcome directly.
    store.exhaustivity = .off
    await store.send(.openRepositories([tempDir]))
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == .xcodeLicenseNotAccepted)
    #expect(Array(store.state.repositories) == [folderRepo])
    #expect(store.state.repositoryRoots == [standardizedURL])
    #expect(store.state.isInitialLoadComplete)
    #expect(store.state.alert == nil)
  }

  @Test func archivedWorktreeSurvivesBlockedGitLoad() async {
    // Regression: suppressing env-caused failures must not let the archived
    // prune drop curation for the temporarily-hidden repos.
    let worktree = makeWorktree(id: "/tmp/blocked/wt", name: "duck", repoRoot: "/tmp/blocked")
    let repository = makeRepository(id: "/tmp/blocked", worktrees: [worktree])
    var initial = makeState(repositories: [repository])
    initial.repositoryRoots = [repository.rootURL]
    initial.isInitialLoadComplete = true
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[repository.id] = .init(
        buckets: [.archived: .init(items: [worktree.id: .init(archivedAt: .now)])]
      )
    }
    let licenseError = ShellClientError(
      command: "wt ls", stdout: "", stderr: "sudo xcodebuild -license", exitCode: 69)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in throw licenseError }
      // A real block fails `git --version` too, so the authoritative probe confirms it.
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.reloadRepositories(animated: false))
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == .xcodeLicenseNotAccepted)
    #expect(
      store.state.sidebar.sections[repository.id]?.buckets[.archived]?.items[worktree.id] != nil
    )
  }

  @Test func gitErrorEchoingGatePhraseWhileGitWorksSurfacesFailureNotBanner() async {
    // A repo-specific error that merely echoes a gate phrase must not raise the
    // app-wide banner when another git repo demonstrably works.
    let goodRoot = "/tmp/\(UUID().uuidString)-good"
    let weirdRoot = "/tmp/\(UUID().uuidString)-weird"
    let goodWorktree = makeWorktree(id: "\(goodRoot)/main", name: "main", repoRoot: goodRoot)
    let phraseError = ShellClientError(
      command: "wt ls", stdout: "", stderr: "hook failed: this tool requires Xcode 15", exitCode: 1)
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [goodRoot, weirdRoot] }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { url in
        if url.path(percentEncoded: false) == goodRoot { return [goodWorktree] }
        throw phraseError
      }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.loadPersistedRepositories)
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == nil)
    #expect(store.state.repositories[id: RepositoryID(goodRoot)] != nil)
    #expect(store.state.loadFailuresByID[RepositoryID(weirdRoot)] != nil)
  }

  @Test func blockedRepoBecomesRealRepoWhenLicenseAccepted() async {
    // The core transition: a blocked warning row becomes a real repo row once
    // git recovers, with the banner cleared.
    let gitRoot = "/tmp/\(UUID().uuidString)-git"
    let gitID = RepositoryID(gitRoot)
    let worktree = makeWorktree(id: "\(gitRoot)/main", name: "main", repoRoot: gitRoot)
    var initial = RepositoriesFeature.State()
    initial.repositoryRoots = [URL(fileURLWithPath: gitRoot)]
    initial.gitEnvironmentError = .xcodeLicenseNotAccepted
    initial.isInitialLoadComplete = true
    // The starting state really does render a blocked warning row.
    #expect(
      initial.computeSidebarStructure(groupPinned: false, groupActive: false).sections.contains {
        if case .environmentBlockedRepository(let id, _, _, _) = $0 { return id == gitID }
        return false
      })

    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in [worktree] }
      $0.gitClient.checkGitEnvironment = { nil }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.reloadRepositories(animated: false))
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == nil)
    #expect(store.state.repositories[id: gitID] != nil)
    let structure = store.state.sidebarStructure
    #expect(
      structure.sections.contains {
        if case .repository(let id, _) = $0 { return id == gitID }
        return false
      })
    #expect(
      !structure.sections.contains {
        if case .environmentBlockedRepository = $0 { return true }
        return false
      })
  }

  @Test func mixedRosterRoutesFolderBlockedGitAndMissingDirIndependently() async {
    // One load must route a folder to a kept repo, a blocked git root to a
    // suppressed warning row, and a missing directory to an actionable failure.
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let gitRoot = "/tmp/\(UUID().uuidString)-git"
    let missingRoot = "/tmp/\(UUID().uuidString)-missing"
    let licenseError = ShellClientError(
      command: "wt ls", stdout: "", stderr: "sudo xcodebuild -license", exitCode: 69)
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [folderRoot, gitRoot, missingRoot] }
      $0.gitClient.rootDirectoryExists = { $0.path(percentEncoded: false) != missingRoot }
      $0.gitClient.isGitRepository = { $0.path(percentEncoded: false) == gitRoot }
      $0.gitClient.worktrees = { _ in throw licenseError }
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.loadPersistedRepositories)
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == .xcodeLicenseNotAccepted)
    #expect(Array(store.state.repositories.ids) == [RepositoryID(folderRoot)])
    #expect(Set(store.state.loadFailuresByID.keys) == [RepositoryID(missingRoot)])
  }

  @Test func addingGitRepoWhileBlockedPersistsItAsBlockedRow() async throws {
    // Git is blocked, not the repo: a real git repo the user adds must be
    // persisted (survive to recovery) and shown as a blocked row, not dropped.
    let licenseError = ShellClientError(
      command: "wt root", stdout: "", stderr: "sudo xcodebuild -license", exitCode: 69)
    let tempDir = FileManager.default.temporaryDirectory
      .appending(path: "supa-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let standardizedURL = tempDir.standardizedFileURL
    let gitID = RepositoryID(standardizedURL.path(percentEncoded: false))
    let savedRoots = LockIsolated<[String]>([])

    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { savedRoots.setValue($0) }
      $0.gitClient.repoRoot = { _ in throw licenseError }
      $0.gitClient.rootDirectoryExists = { _ in true }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in throw licenseError }
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.openRepositories([tempDir]))
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == .xcodeLicenseNotAccepted)
    #expect(
      store.state.repositoryRoots.map { $0.path(percentEncoded: false) }
        .contains(standardizedURL.path(percentEncoded: false)))
    #expect(savedRoots.value.contains(standardizedURL.path(percentEncoded: false)))
    #expect(
      store.state.sidebarStructure.sections.contains {
        if case .environmentBlockedRepository(let id, _, _, _) = $0 { return id == gitID }
        return false
      })
  }

  @Test func blockedRepoIsRemovable() async {
    // A repo added while blocked shows a warning row, but must still be
    // removable (path-based) so a mistaken add isn't a dead-end until recovery.
    let gitRoot = "/tmp/\(UUID().uuidString)-git"
    let gitID = RepositoryID(gitRoot)
    var initial = RepositoriesFeature.State()
    initial.repositoryRoots = [URL(fileURLWithPath: gitRoot)]
    initial.gitEnvironmentError = .xcodeLicenseNotAccepted
    initial.isInitialLoadComplete = true
    let savedRoots = LockIsolated<[String]>(["unset"])
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [gitRoot] }
      $0.repositoryPersistence.saveRoots = { savedRoots.setValue($0) }
      $0.repositoryPersistence.pruneRepositoryConfigs = { _ in }
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.removeFailedRepository(gitID))
    await store.skipReceivedActions()
    #expect(
      !store.state.repositoryRoots.contains {
        RepositoryID($0.standardizedFileURL.path(percentEncoded: false)) == gitID
      })
    #expect(!savedRoots.value.contains(gitRoot))
  }

  @Test func soleGitRepoEchoingGatePhraseProbesBeforeBannering() async {
    // The only git root echoes a gate phrase but git is actually healthy. With
    // nothing to disconfirm against, the `git --version` probe is the ground
    // truth: it clears the false positive, so the real error surfaces as a
    // failure row rather than a bogus app-wide banner.
    let gitRoot = "/tmp/\(UUID().uuidString)-git"
    let phraseError = ShellClientError(
      command: "wt ls", stdout: "", stderr: "post-checkout hook: this step requires Xcode", exitCode: 1)
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [gitRoot] }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in throw phraseError }
      // `git --version` succeeds: git is not actually blocked.
      $0.gitClient.checkGitEnvironment = { nil }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.loadPersistedRepositories)
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == nil)
    #expect(store.state.loadFailuresByID[RepositoryID(gitRoot)] != nil)
  }

  @Test func blockWithUnmatchedRepoErrorStillBannersViaProbe() async {
    // Locale robustness: even when the per-repo error text matches no gate
    // phrase (e.g. a localized message), the `git --version` probe is the
    // authority, so the banner shows and the repo is suppressed as a warning
    // row rather than marked broken.
    let gitRoot = "/tmp/\(UUID().uuidString)-git"
    let opaqueError = ShellClientError(
      command: "wt ls", stdout: "", stderr: "erreur: impossible de lire", exitCode: 1)
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [gitRoot] }
      $0.gitClient.isGitRepository = { _ in true }
      $0.gitClient.worktrees = { _ in throw opaqueError }
      // The locale-independent probe is what confirms the block.
      $0.gitClient.checkGitEnvironment = { .xcodeLicenseNotAccepted }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.loadPersistedRepositories)
    await store.skipReceivedActions()
    #expect(store.state.gitEnvironmentError == .xcodeLicenseNotAccepted)
    #expect(store.state.loadFailuresByID[RepositoryID(gitRoot)] == nil)
    #expect(store.state.repositories[id: RepositoryID(gitRoot)] == nil)
  }

  @Test func gitEnvironmentChangedIgnoresUnchangedValue() async {
    var initialState = RepositoriesFeature.State()
    initialState.gitEnvironmentError = .xcodeLicenseNotAccepted
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }

    // Re-publishing the same value on the periodic refresh must not mutate state.
    await store.send(.gitEnvironmentChanged(.xcodeLicenseNotAccepted))
    // A real transition still applies.
    await store.send(.gitEnvironmentChanged(nil)) {
      $0.gitEnvironmentError = nil
    }
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
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.repositoriesLoaded) {
      $0.repositories = [
        Repository(
          id: RepositoryID(gitRoot),
          rootURL: URL(fileURLWithPath: gitRoot),
          name: URL(fileURLWithPath: gitRoot).lastPathComponent,
          worktrees: [gitWorktree],
          isGitRepository: true
        ),
        {
          let url = URL(fileURLWithPath: folderRoot)
          let synthetic = Worktree(
            id: Repository.folderWorktreeID(for: url),
            kind: .folder,
            name: Repository.name(for: url),
            detail: "",
            workingDirectory: url,
            repositoryRootURL: url,
            isAttached: false
          )
          return Repository(
            id: RepositoryID(folderRoot),
            rootURL: url,
            name: Repository.name(for: url),
            worktrees: [synthetic],
            isGitRepository: false
          )
        }(),
      ]
      $0.repositoryRoots = [gitRoot, folderRoot].map { URL(fileURLWithPath: $0) }
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [
        RepositoryID(gitRoot): .finder,
        RepositoryID(folderRoot): .finder,
      ]
    }
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
      kind: .folder,
      name: Repository.name(for: standardizedURL),
      detail: "",
      workingDirectory: standardizedURL,
      repositoryRootURL: standardizedURL,
      isAttached: false
    )
    let folderRepo = Repository(
      id: RepositoryID(rootID),
      rootURL: standardizedURL,
      name: Repository.name(for: standardizedURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    await store.send(.openRepositories([tempDir]))
    await store.receive(\.gitEnvironmentChanged)
    await store.receive(\.openRepositoriesFinished) {
      $0.repositories = [folderRepo]
      $0.repositoryRoots = [standardizedURL]
      $0.isInitialLoadComplete = true
      $0.reconcileSidebarForTesting()
    }
    await store.receive(\.delegate.repositoriesChanged)
    await store.receive(\.openActionsResolved) {
      $0.openActionByRepositoryID = [folderRepo.id: .finder]
    }
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
      kind: .folder,
      name: "folder",
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL, isAttached: false
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true

    state.reconcileSidebarForTesting()
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true

    state.reconcileSidebarForTesting()
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
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

    state.reconcileSidebarForTesting()
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: folderWorktree.id]?.lifecycle = .deletingScript

    #expect(state.isRemovingRepository(folderRepo) == false)
    let row = state.sidebarItems[id: folderWorktree.id]
    #expect(row?.lifecycle == .deletingScript)
    #expect(row?.kind == .folder)
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: folderWorktree.id]?.lifecycle = .deletingScript
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
    #expect((store.state.sidebarItems[id: folderWorktree.id]?.lifecycle ?? .idle) == .idle)
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let flippedRepo = Repository(
      id: RepositoryID(folderRoot),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: true
    )

    var state = RepositoriesFeature.State()
    state.repositories = [flippedRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: folderWorktree.id]?.lifecycle = .deletingScript
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true

    state.reconcileSidebarForTesting()
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.createWorktreeStream = { _, _, _, _, _, _, _ in
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [folderURL]
    state.isInitialLoadComplete = true
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: folderWorktree.id]?.lifecycle = .deletingScript
    state.seedRemovalBatch(pending: [folderRepo.id: .folderUnlink])

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(
      .deleteScriptCompleted(worktreeID: folderWorktree.id, exitCode: nil, tabId: nil)
    )
    await store.skipReceivedActions()
    #expect((store.state.sidebarItems[id: folderWorktree.id]?.lifecycle ?? .idle) == .idle)
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
      kind: .folder,
      name: Repository.name(for: standardized),
      detail: "",
      workingDirectory: standardized,
      repositoryRootURL: standardized
    )
    let folderRepo = Repository(
      id: RepositoryID(rootID),
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

    state.reconcileSidebarForTesting()
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
      kind: .folder,
      name: Repository.name(for: missingURL), detail: "",
      workingDirectory: missingURL, repositoryRootURL: missingURL
    )
    let folderRepo = Repository(
      id: RepositoryID(rootID), rootURL: missingURL, name: Repository.name(for: missingURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderRepo]
    state.repositoryRoots = [missingURL]
    state.isInitialLoadComplete = true
    let folderTarget = RepositoriesFeature.DeleteWorktreeTarget(
      worktreeID: folderWorktree.id, repositoryID: folderRepo.id)

    state.reconcileSidebarForTesting()
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
      store.state.sidebarItems[id: folderWorktree.id]?.lifecycle != .deleting,
      "deletingWorktreeIDs must clear on trash failure"
    )
    #expect(
      store.state.sidebarItems[id: folderWorktree.id]?.lifecycle != .deletingScript,
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
        kind: .folder,
        name: Repository.name(for: url), detail: "",
        workingDirectory: url, repositoryRootURL: url
      )
      let repo = Repository(
        id: RepositoryID(id), rootURL: url, name: Repository.name(for: url),
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

    state.reconcileSidebarForTesting()
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
      id: WorktreeID("\(gitRoot)/wt-1"),
      name: "wt-1",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "\(gitRoot)/wt-1"),
      repositoryRootURL: gitURL
    )
    let mainWorktree = Worktree(
      id: WorktreeID(gitRoot),
      name: "repo",
      detail: "",
      workingDirectory: gitURL,
      repositoryRootURL: gitURL
    )
    let gitRepo = Repository(
      id: RepositoryID(gitRoot), rootURL: gitURL, name: "repo",
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

    state.reconcileSidebarForTesting()
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
    // The row is orphaned (no live repository), but still alive at
    // `.deletingScript` because the script was already in flight before the
    // repo vanished. Construct it directly so the guard in the action handler
    // sees an in-flight row to drain.
    state.sidebarItems.append(
      SidebarItemFeature.State(
        id: folderWorktreeID,
        repositoryID: RepositoryID(folderRoot),
        kind: .folder,
        name: "vanished",
        branchName: "vanished",
        subtitle: nil,
        workingDirectory: folderURL,
        repositoryAccent: nil,
        isMainWorktree: true,
        isPinned: false,
        hasMergedBadge: false
      )
    )
    state.sidebarItems[id: folderWorktreeID]?.lifecycle = .deletingScript
    let batchID = state.seedRemovalBatch(pending: [RepositoryID(folderRoot): .folderUnlink])

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
      store.state.removingRepositoryIDs[RepositoryID(folderRoot)] == nil,
      "record must drain even when owning repo vanished mid-script"
    )
    #expect(
      store.state.activeRemovalBatches[batchID] == nil,
      "batch must drain (succeeded:false) so sibling targets don't hang"
    )
    #expect(store.state.sidebarItems[id: folderWorktreeID]?.lifecycle != .deletingScript)
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
        kind: .folder,
        name: Repository.name(for: url),
        detail: "",
        workingDirectory: url,
        repositoryRootURL: url
      )
      let repo = Repository(
        id: RepositoryID(id), rootURL: url, name: Repository.name(for: url),
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

    state.reconcileSidebarForTesting()
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
      kind: .folder,
      name: Repository.name(for: urlA), detail: "",
      workingDirectory: urlA, repositoryRootURL: urlA
    )
    let folderA = Repository(
      id: RepositoryID(idA), rootURL: urlA, name: Repository.name(for: urlA),
      worktrees: IdentifiedArray(uniqueElements: [worktreeA]),
      isGitRepository: false
    )
    let worktreeB = Worktree(
      id: Repository.folderWorktreeID(for: urlB),
      kind: .folder,
      name: Repository.name(for: urlB), detail: "",
      workingDirectory: urlB, repositoryRootURL: urlB
    )
    let folderB = Repository(
      id: RepositoryID(idB), rootURL: urlB, name: Repository.name(for: urlB),
      worktrees: IdentifiedArray(uniqueElements: [worktreeB]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderA, folderB]
    state.repositoryRoots = [urlA, urlB]
    state.isInitialLoadComplete = true

    let savedPaths = LockIsolated<[[String]]>([])
    let prunedIDs = LockIsolated<[[String]]>([])
    state.reconcileSidebarForTesting()
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
    #expect(store.state.repositories.map(\.id) == [RepositoryID(idB)])
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
      kind: .folder,
      name: Repository.name(for: urlA),
      detail: "",
      workingDirectory: urlA,
      repositoryRootURL: urlA
    )
    let worktreeB = Worktree(
      id: Repository.folderWorktreeID(for: urlB),
      kind: .folder,
      name: Repository.name(for: urlB),
      detail: "",
      workingDirectory: urlB,
      repositoryRootURL: urlB
    )
    let folderA = Repository(
      id: RepositoryID(rootA),
      rootURL: urlA,
      name: Repository.name(for: urlA),
      worktrees: IdentifiedArray(uniqueElements: [worktreeA]),
      isGitRepository: false
    )
    let folderB = Repository(
      id: RepositoryID(rootB),
      rootURL: urlB,
      name: Repository.name(for: urlB),
      worktrees: IdentifiedArray(uniqueElements: [worktreeB]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [folderA, folderB]
    state.repositoryRoots = [urlA, urlB]
    state.isInitialLoadComplete = true

    state.reconcileSidebarForTesting()
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
      id: WorktreeID("\(gitRoot)/main"),
      name: "main",
      detail: "",
      workingDirectory: gitURL,
      repositoryRootURL: gitURL
    )
    let gitFeature = Worktree(
      id: WorktreeID("\(gitRoot)/feature"),
      name: "feature",
      detail: "",
      workingDirectory: gitURL.appending(path: "feature"),
      repositoryRootURL: gitURL
    )
    let gitRepo = Repository(
      id: RepositoryID(gitRoot),
      rootURL: gitURL,
      name: "git-repo",
      worktrees: IdentifiedArray(uniqueElements: [gitMain, gitFeature]),
      isGitRepository: true
    )
    let folderRoot = "/tmp/\(UUID().uuidString)-folder"
    let folderURL = URL(fileURLWithPath: folderRoot)
    let folderMain = Worktree(
      id: Repository.folderWorktreeID(for: folderURL),
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
      rootURL: folderURL,
      name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderMain]),
      isGitRepository: false
    )

    var state = RepositoriesFeature.State()
    state.repositories = [gitRepo, folderRepo]
    state.repositoryRoots = [gitURL, folderURL]
    state.isInitialLoadComplete = true

    state.reconcileSidebarForTesting()
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
      id: RepositoryID(repoRoot),
      rootURL: repoURL,
      name: URL(fileURLWithPath: repoRoot).lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree, featureWorktree]),
      isGitRepository: true
    )

    var state = RepositoriesFeature.State()
    state.repositories = [gitRepo]
    state.repositoryRoots = [repoURL]
    state.isInitialLoadComplete = true
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: featureWorktree.id]?.lifecycle = .deletingScript
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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot),
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
    state.reconcileSidebarForTesting()
    state.sidebarItems[id: folderWorktree.id]?.lifecycle = .deleting

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
      kind: .folder,
      name: Repository.name(for: folderURL),
      detail: "",
      workingDirectory: folderURL,
      repositoryRootURL: folderURL
    )
    let folderRepo = Repository(
      id: RepositoryID(folderRoot), rootURL: folderURL, name: Repository.name(for: folderURL),
      worktrees: IdentifiedArray(uniqueElements: [folderWorktree]),
      isGitRepository: false
    )
    let gitRoot = "/tmp/\(UUID().uuidString)-repo"
    let gitURL = URL(fileURLWithPath: gitRoot)
    let gitMain = Worktree(
      id: WorktreeID(gitRoot), name: Repository.name(for: gitURL), detail: "",
      workingDirectory: gitURL, repositoryRootURL: gitURL
    )
    let gitRepo = Repository(
      id: RepositoryID(gitRoot), rootURL: gitURL, name: Repository.name(for: gitURL),
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

    state.reconcileSidebarForTesting()
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
        kind: .folder,
        name: Repository.name(for: folderURL), detail: "",
        workingDirectory: folderURL, repositoryRootURL: folderURL
      )
      let folderRepo = Repository(
        id: RepositoryID(folderRoot), rootURL: folderURL, name: Repository.name(for: folderURL),
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
      state.reconcileSidebarForTesting()
      state.sidebarItems[id: folderWorktree.id]?.lifecycle = .deleting
      state.sidebarItems[id: folderWorktree.id]?.lifecycle = .deletingScript

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
      #expect(store.state.sidebarItems[id: folderWorktree.id]?.lifecycle != .deleting)
      #expect(store.state.sidebarItems[id: folderWorktree.id]?.lifecycle != .deletingScript)
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
        kind: .folder,
        name: Repository.name(for: folderURL), detail: "",
        workingDirectory: folderURL, repositoryRootURL: folderURL
      )
      let folderRepo = Repository(
        id: RepositoryID(folderRoot), rootURL: folderURL, name: Repository.name(for: folderURL),
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

      state.reconcileSidebarForTesting()
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
