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
    // Write `$sidebar` last. Without it, a store's first exhaustive send reports a
    // mismatch with an empty `(…)` diff unless that step itself writes `$sidebar`.
    state.$sidebar.withLock { _ in }
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
              group: nil,
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
              group: nil,
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

  // MARK: - Groups

  @Test func requestCustomizeWorktreeSeedsGroupFromStoredItem() async {
    var initial = makeInitialState()
    initial.sidebarFoldersEnabled = true
    initial.$sidebar.withLock { sidebar in
      sidebar.setGroup("Project 1", worktree: self.worktreeID, in: self.repoID)
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.requestCustomizeWorktree(worktreeID, repoID)) {
      $0.worktreeCustomization = WorktreeCustomizationFeature.State(
        worktreeID: self.worktreeID,
        repositoryID: self.repoID,
        defaultName: "feature/x",
        title: "",
        color: nil,
        group: "Project 1",
        showsGroup: true,
      )
    }
  }

  @Test func setSidebarFoldersEnabledUpdatesState() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }

    await store.send(.setSidebarFoldersEnabled(true)) {
      $0.sidebarFoldersEnabled = true
    }
  }

  @Test func saveDelegatePersistsGroupToBucketedItem() async {
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
            .save(worktreeID: worktreeID, repositoryID: repoID, title: nil, color: nil, group: "Project 1")
          )))
    ) {
      $0.worktreeCustomization = nil
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.group = "Project 1"
      }
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func setWorktreeGroupNormalizesThenClears() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }

    await store.send(.setWorktreeGroup(worktreeID, repoID, group: " Project 1 / Backend ")) {
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.group = "Project 1/Backend"
      }
      $0.applyPostReduceCacheRecomputes()
    }
    await store.send(.setWorktreeGroup(worktreeID, repoID, group: nil)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.group = nil
      }
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func setWorktreeGroupIgnoresGitMainWorktree() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }

    // The git main worktree is repository-level, like Customize Appearance.
    await store.send(.setWorktreeGroup(WorktreeID("\(repoID)/main"), repoID, group: "Project 1"))

    let groups = store.state.sidebar.sections.values.flatMap { section in
      section.buckets.values.flatMap { $0.items.values.compactMap(\.group) }
    }
    #expect(groups.isEmpty)
  }

  private func openNewGroupPrompt(
    _ store: TestStoreOf<RepositoriesFeature>,
    rows: [Worktree.ID: Repository.ID]
  ) async {
    await store.send(.requestNewGroup(rows)) {
      $0.newGroupPromptRows = rows
    }
  }

  @Test func newGroupPromptMovesEligibleRowsIntoTheNormalizedGroup() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }
    await openNewGroupPrompt(store, rows: [worktreeID: repoID, WorktreeID("\(repoID)/main"): repoID])

    // The git main worktree is skipped; the feature row moves.
    await store.send(.newGroupPromptSubmitted(name: " Project 1 / Backend ")) {
      $0.newGroupPromptRows = [:]
      $0.$sidebar.withLock { sidebar in
        sidebar.sections[self.repoID]?.buckets[.unpinned]?.items[self.worktreeID]?.group = "Project 1/Backend"
      }
      $0.applyPostReduceCacheRecomputes()
    }
  }

  @Test func blankNewGroupNameClosesThePromptWithoutChanges() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }
    await openNewGroupPrompt(store, rows: [worktreeID: repoID])

    await store.send(.newGroupPromptSubmitted(name: " / ")) {
      $0.newGroupPromptRows = [:]
    }
  }

  @Test func dismissingNewGroupPromptForgetsItsRows() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }
    await openNewGroupPrompt(store, rows: [worktreeID: repoID])

    await store.send(.setNewGroupPromptPresented(false)) {
      $0.newGroupPromptRows = [:]
    }
  }

  @Test func sidebarGroupExpansionChangedTogglesCollapsedGroups() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }

    await store.send(.sidebarGroupExpansionChanged(path: "Project 1", isExpanded: false)) {
      $0.$sidebar.withLock { $0.collapsedGroups = ["Project 1"] }
    }
    await store.send(.sidebarGroupExpansionChanged(path: "Project 1", isExpanded: true)) {
      $0.$sidebar.withLock { $0.collapsedGroups = [] }
    }
  }

  @Test func expandAllOpensCollapsedGroupFolders() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock { $0.collapsedGroups = ["Project 1"] }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.setAllSidebarGroupsExpanded(true)) {
      $0.$sidebar.withLock { $0.collapsedGroups = [] }
    }
  }

  // MARK: - Pinned / Active repository groups

  @Test func highlightGroupExpansionChangedTogglesTheRepositoryHeader() async {
    let store = TestStore(initialState: makeInitialState()) {
      RepositoriesFeature()
    }
    let header = SidebarState.HighlightGroup(kind: .active, branchPrefix: nil)

    await store.send(
      .highlightGroupExpansionChanged(kind: .active, repositoryID: repoID, prefix: nil, isExpanded: false)
    ) {
      $0.$sidebar.withLock { $0.sections[self.repoID]?.collapsedHighlightGroups = [header] }
    }
    await store.send(
      .highlightGroupExpansionChanged(kind: .active, repositoryID: repoID, prefix: nil, isExpanded: true)
    ) {
      $0.$sidebar.withLock { $0.sections[self.repoID]?.collapsedHighlightGroups = [] }
    }
  }

  @Test func expandAllOpensCollapsedRepositoryGroups() async {
    var initial = makeInitialState()
    initial.$sidebar.withLock {
      $0.sections[self.repoID]?.collapsedHighlightGroups = [.init(kind: .pinned, branchPrefix: "feature")]
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.setAllSidebarGroupsExpanded(true)) {
      $0.$sidebar.withLock { $0.sections[self.repoID]?.collapsedHighlightGroups = [] }
    }
  }

  @Test func revealOpensTheHoistedRowsGroupsInItsSectionOnly() async {
    var initial = makeInitialState()
    initial.sidebarItems[id: worktreeID]?.runningScripts.append(.init(id: UUID(), tint: .blue))
    initial.$sidebar.withLock { sidebar in
      sidebar.sections[self.repoID]?.collapsedHighlightGroups = [
        .init(kind: .active, branchPrefix: nil),
        .init(kind: .active, branchPrefix: "feature"),
        .init(kind: .pinned, branchPrefix: nil),
      ]
    }
    initial.applyPostReduceCacheRecomputes()
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    // `feature/x` is in Active, so only Active's repository header and `feature` prefix open.
    await store.send(.revealHoistedWorktreeInSidebar(worktreeID)) {
      $0.$sidebar.withLock {
        $0.sections[self.repoID]?.collapsedHighlightGroups = [.init(kind: .pinned, branchPrefix: nil)]
      }
      $0.nextPendingSidebarRevealID = 1
      $0.pendingSidebarReveal = .init(id: 1, worktreeID: self.worktreeID)
      $0.applyPostReduceCacheRecomputes()
    }
  }
}
