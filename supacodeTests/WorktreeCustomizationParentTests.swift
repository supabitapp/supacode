import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct WorktreeCustomizationParentTests {
  private let repoID: RepositoryID = "/tmp/customize-wt-repo"
  private let worktreeID: WorktreeID = "/tmp/customize-wt-repo/feature-x"

  private func makeInitialState(
    isGitRepository: Bool = true,
    seedSidebarBucket: Bool = true,
  ) -> RepositoriesFeature.State {
    let mainWorktree = Worktree(
      id: WorktreeID("\(repoID)/main"),
      name: "main",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: repoID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
    )
    let featureWorktree = Worktree(
      id: worktreeID,
      name: "feature/x",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: worktreeID.rawValue),
      repositoryRootURL: URL(fileURLWithPath: repoID.rawValue),
    )
    let repository = Repository(
      id: repoID,
      rootURL: URL(fileURLWithPath: repoID.rawValue),
      name: "customize-wt-repo",
      worktrees: IdentifiedArray(uniqueElements: [mainWorktree, featureWorktree]),
      isGitRepository: isGitRepository,
    )
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: [repository])
    state.repositoryRoots = [repository.rootURL]
    if seedSidebarBucket {
      state.$sidebar.withLock { sidebar in
        sidebar.insert(worktree: self.worktreeID, in: self.repoID, bucket: .unpinned)
      }
    }
    // Pre-build `sidebarItems` so save / cancel tests can assert against an
    // existing per-row state instead of forcing the reducer's `syncSidebar`
    // to materialise rows mid-action and flag the test on unrelated diffs.
    RepositoriesFeature.syncSidebar(&state)
    // Pre-warm the post-reduce caches so the in-reducer recompute is a delta
    // from a populated baseline (matches what every action would see in a
    // real run) rather than a build-from-nil that registers as state churn.
    state.applyPostReduceCacheRecomputes()
    return state
  }

  @Test func requestCustomizeWorktreeSeedsPromptFromStoredItem() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.title = "Spicy"
      sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.color = .blue
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(worktreeID, repoID)) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.worktreeID,
        repositoryID: self.repoID,
        defaultName: "feature/x",
        title: "Spicy",
        color: .blue,
      )
    }
  }

  @Test func requestCustomizeWorktreeSeedsEmptyPromptWhenNoStoredItem() async {
    let store = TestStore(initialState: makeInitialState(seedSidebarBucket: false)) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(worktreeID, repoID)) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.worktreeID,
        repositoryID: self.repoID,
        defaultName: "feature/x",
        title: "",
        color: nil,
      )
    }
  }

  @Test func requestCustomizeWorktreeOpensSheetForFolderSyntheticRow() async {
    // Folder synthetic rows ARE the row the user customizes; they share the worktree path so the
    // per-row title / color the picker writes lands on the visible folder row.
    let store = TestStore(
      initialState: makeInitialState(isGitRepository: false, seedSidebarBucket: false)
    ) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(worktreeID, repoID)) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.worktreeID,
        repositoryID: self.repoID,
        defaultName: "customize-wt-repo",
        title: "",
        color: nil,
      )
    }
  }

  @Test func requestCustomizeWorktreeNoOpsForMainWorktrees() async {
    // The context menu hides the entry for the main worktree row, but a future palette /
    // deeplink could still route here. The reducer guard is the backstop.
    let store = TestStore(initialState: makeInitialState(seedSidebarBucket: false)) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(WorktreeID("\(repoID)/main"), repoID))
    #expect(store.state.worktreeCustomization == nil)
  }

  // MARK: - Customize Appearance shortcut (`requestCustomizeSelectedAppearance`).

  private let folderURL = URL(fileURLWithPath: "/tmp/customize-folder")
  private var folderRepoID: RepositoryID { RepositoryID(folderURL.path(percentEncoded: false)) }
  private var folderRowID: WorktreeID { Repository.folderWorktreeID(for: folderURL) }

  private func makeFolderState() -> RepositoriesFeature.State {
    let folderRepo = Repository(
      id: folderRepoID,
      rootURL: folderURL,
      name: "customize-folder",
      worktrees: IdentifiedArray(uniqueElements: [
        Worktree(
          id: folderRowID,
          name: "customize-folder",
          detail: "",
          workingDirectory: folderURL,
          repositoryRootURL: folderURL
        )
      ]),
      isGitRepository: false
    )
    var state = RepositoriesFeature.State(reconciledRepositories: [folderRepo])
    state.selection = .worktree(folderRowID)
    state.applyPostReduceCacheRecomputes()
    return state
  }

  @Test func shortcutCustomizesSelectedNonMainWorktreeRow() async {
    var initial = makeInitialState()
    initial.selection = .worktree(worktreeID)
    initial.applyPostReduceCacheRecomputes()
    #expect(initial.customizeAppearanceShortcutTarget == .worktree(worktreeID, repoID))
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeSelectedAppearance)
    await store.receive(\.requestCustomizeWorktree) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.worktreeID,
        repositoryID: self.repoID,
        defaultName: "feature/x",
        title: "",
        color: nil,
      )
    }
  }

  @Test func shortcutOnMainWorktreeCustomizesRepository() async {
    // The main worktree has no per-row appearance; the shortcut lands on the
    // repository sheet, matching the palette's repository-only entry.
    let mainID = WorktreeID("\(repoID)/main")
    var initial = makeInitialState(seedSidebarBucket: false)
    initial.selection = .worktree(mainID)
    initial.applyPostReduceCacheRecomputes()
    #expect(initial.customizeAppearanceShortcutTarget == .repository(repoID))
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeSelectedAppearance)
    await store.receive(\.requestCustomizeRepository) {
      $0.repositoryCustomization = RepositoryCustomizationFeature.State(
        repositoryID: self.repoID,
        defaultName: "customize-wt-repo",
        title: "",
        color: nil,
      )
    }
  }

  @Test func shortcutOnFolderRowCustomizesTheRow() async {
    let initial = makeFolderState()
    #expect(initial.customizeAppearanceShortcutTarget == .worktree(folderRowID, folderRepoID))
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeSelectedAppearance)
    await store.receive(\.requestCustomizeWorktree) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.folderRowID,
        repositoryID: self.folderRepoID,
        defaultName: "customize-folder",
        title: "",
        color: nil,
      )
    }
  }

  @Test func shortcutNoOpsWithoutASelection() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeSelectedAppearance)
    #expect(store.state.worktreeCustomization == nil)
    #expect(store.state.repositoryCustomization == nil)
  }

  @Test func shortcutNoOpsForArchivedListSelection() async {
    var initial = makeInitialState()
    initial.selection = .archivedWorktrees
    initial.applyPostReduceCacheRecomputes()
    #expect(initial.customizeAppearanceShortcutTarget == nil)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeSelectedAppearance)
    #expect(store.state.worktreeCustomization == nil)
    #expect(store.state.repositoryCustomization == nil)
  }

  @Test func shortcutNoOpsForPendingWorktreeRow() async {
    // A creating row has no stable target yet and, unlike the palette's
    // repository-level entry, the shortcut does not fall through to the
    // repository for a non-main row.
    var initial = makeInitialState()
    initial.selection = .worktree(worktreeID)
    initial.sidebarItems[id: worktreeID]?.lifecycle = .pending
    initial.applyPostReduceCacheRecomputes()
    #expect(initial.customizeAppearanceRowTarget == nil)
    #expect(initial.customizeAppearanceShortcutTarget == nil)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeSelectedAppearance)
    #expect(store.state.worktreeCustomization == nil)
    #expect(store.state.repositoryCustomization == nil)
  }

  @Test func shortcutTargetHidesRepositoryMidRemoval() {
    // Mirrors the sidebar's disabled section entry: a main worktree of a repo
    // being removed has nothing to customize.
    let mainID = WorktreeID("\(repoID)/main")
    var state = makeInitialState(seedSidebarBucket: false)
    state.selection = .worktree(mainID)
    state.seedRemovalBatch(pending: [repoID: .gitRepositoryUnlink])
    state.applyPostReduceCacheRecomputes()
    #expect(state.customizeAppearanceRepositoryTarget == nil)
    #expect(state.customizeAppearanceShortcutTarget == nil)
  }

  @Test func mainWorktreeAppearanceSurvivesSidebarReconcile() {
    let mainID = WorktreeID("\(repoID)/main")
    var state = makeInitialState(seedSidebarBucket: false)
    state.$sidebar.withLock { sidebar in
      sidebar.setCustomization(title: "Root", color: .blue, worktree: mainID, in: repoID)
    }
    RepositoriesFeature.syncSidebar(&state)
    #expect(state.sidebarItems[id: mainID]?.customTitle == "Root")
    #expect(state.sidebarItems[id: mainID]?.customTint == .blue)

    state.reconcileSidebarState(
      roots: [URL(fileURLWithPath: repoID.rawValue)],
      pruneLivenessAgainstRoster: true
    )
    RepositoriesFeature.syncSidebar(&state)

    let item = state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[mainID]
    #expect(item?.title == "Root")
    #expect(item?.color == .blue)
    #expect(state.sidebar.sections[repoID]?.buckets[.pinned]?.items[mainID] == nil)
    #expect(state.sidebarItems[id: mainID]?.customTitle == "Root")
    #expect(state.sidebarItems[id: mainID]?.customTint == .blue)
  }

  @Test func mainWorktreeWithoutOverrideIsNotInjectedOnReconcile() {
    let mainID = WorktreeID("\(repoID)/main")
    var state = makeInitialState(seedSidebarBucket: false)

    state.reconcileSidebarState(
      roots: [URL(fileURLWithPath: repoID.rawValue)],
      pruneLivenessAgainstRoster: true
    )

    // A main worktree carrying no override must not be projected into any bucket,
    // otherwise it would surface as a spurious pinnable / duplicate row.
    #expect(state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[mainID] == nil)
    #expect(state.sidebar.sections[repoID]?.buckets[.pinned]?.items[mainID] == nil)
  }

  @Test func saveDelegatePersistsTitleAndColorToBucketedItem() async {
    var initial = makeInitialState()
    initial.worktreeCustomization = WorktreeCustomizationFeature.State(
      worktreeID: worktreeID,
      repositoryID: repoID,
      defaultName: "feature/x",
      title: "",
      color: nil,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeCustomization(
        .presented(
          .delegate(
            .save(
              worktreeID: worktreeID,
              repositoryID: repoID,
              title: "Renamed",
              color: .red,
            )
          )))
    ) {
      $0.worktreeCustomization = nil
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.title =
          "Renamed"
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.color = .red
      }
      // syncSidebar fans the bucketed Item write into the per-row mirror.
      $0.sidebarItems[id: self.worktreeID]?.customTitle = "Renamed"
      $0.sidebarItems[id: self.worktreeID]?.customTint = .red
      // The save action invalidates every cache; mirror the post-reduce hook
      // so the test diff only contains intentional state changes.
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func saveDelegateRefreshesSelectedWorktreeSlice() async {
    var initial = makeInitialState()
    initial.setSingleWorktreeSelection(worktreeID)
    initial.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    initial.worktreeCustomization = WorktreeCustomizationFeature.State(
      worktreeID: worktreeID,
      repositoryID: repoID,
      defaultName: "feature/x",
      title: "",
      color: nil,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeCustomization(
        .presented(
          .delegate(
            .save(
              worktreeID: worktreeID,
              repositoryID: repoID,
              title: "Renamed",
              color: .red,
            )
          )))
    ) {
      $0.worktreeCustomization = nil
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.title =
          "Renamed"
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.color = .red
      }
      $0.sidebarItems[id: self.worktreeID]?.customTitle = "Renamed"
      $0.sidebarItems[id: self.worktreeID]?.customTint = .red
      $0.applyPostReduceCacheRecomputes()
    }
    #expect(store.state.selectedWorktreeSlice?.resolvedSidebarTitle == "Renamed")
    #expect(store.state.selectedWorktreeSlice?.customTint == .red)
  }

  @Test func pinWorktreePreservesCustomTitleAndColor() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.title =
        "Renamed"
      sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.color = .red
    }
    RepositoriesFeature.syncSidebar(&initial)
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.pinWorktree(worktreeID))

    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID] == nil)
    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID]?.title == "Renamed")
    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID]?.color == .red)
    #expect(store.state.sidebarItems[id: worktreeID]?.customTitle == "Renamed")
    #expect(store.state.sidebarItems[id: worktreeID]?.customTint == .red)
  }

  @Test func unpinWorktreePreservesCustomTitleAndColor() async {
    var initial = makeInitialState(seedSidebarBucket: false)
    initial.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .pinned,
        item: .init(title: "Renamed", color: .red)
      )
    }
    RepositoriesFeature.syncSidebar(&initial)
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.unpinWorktree(worktreeID))

    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID] == nil)
    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID]?.title == "Renamed")
    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID]?.color == .red)
    #expect(store.state.sidebarItems[id: worktreeID]?.customTitle == "Renamed")
    #expect(store.state.sidebarItems[id: worktreeID]?.customTint == .red)
  }

  @Test func unpinWorktreePrefersPinnedPayloadOverStaleUnpinnedSibling() async {
    // Defensive coverage for a corrupted double-bucket pre-state (hand-edit,
    // migrator race) where the same row exists in both `.pinned` and
    // `.unpinned` with different payloads. The pinned entry is the live
    // row the user sees; unpin must carry its `title` / `color` forward,
    // not the stale unpinned sibling's.
    var initial = makeInitialState(seedSidebarBucket: false)
    initial.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .pinned,
        item: .init(title: "Live", color: .red)
      )
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .unpinned,
        item: .init(title: "Stale", color: .blue)
      )
    }
    RepositoriesFeature.syncSidebar(&initial)
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.unpinWorktree(worktreeID))

    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID] == nil)
    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID]?.title == "Live")
    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID]?.color == .red)
  }

  @Test func pinWorktreePrefersUnpinnedPayloadOverStalePinnedSibling() async {
    // Symmetric to the unpin case: when the same row appears in both buckets, `.unpinned` is the
    // logical source for a pin, so its payload (not a stale `.pinned` sibling's) must round-trip.
    var initial = makeInitialState(seedSidebarBucket: false)
    initial.$sidebar.withLock { sidebar in
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .unpinned,
        item: .init(title: "Live", color: .red)
      )
      sidebar.insert(
        worktree: self.worktreeID,
        in: self.repoID,
        bucket: .pinned,
        item: .init(title: "Stale", color: .blue)
      )
    }
    RepositoriesFeature.syncSidebar(&initial)
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.pinWorktree(worktreeID))

    #expect(store.state.sidebar.sections[repoID]?.buckets[.unpinned]?.items[worktreeID] == nil)
    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID]?.title == "Live")
    #expect(store.state.sidebar.sections[repoID]?.buckets[.pinned]?.items[worktreeID]?.color == .red)
  }

  @Test func cancelDelegateClearsPresentedState() async {
    var initial = makeInitialState()
    initial.worktreeCustomization = WorktreeCustomizationFeature.State(
      worktreeID: worktreeID,
      repositoryID: repoID,
      defaultName: "feature/x",
      title: "",
      color: nil,
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeCustomization(.presented(.delegate(.cancel)))
    ) {
      $0.worktreeCustomization = nil
    }
  }
}
