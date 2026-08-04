import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Files inspector pane: a lazy, per-directory file tree of the selected
/// worktree. Listings are cached per worktree so switching back is instant;
/// a visible-pane sweep re-lists directories whose mtime moved or vanished.
@Reducer
struct FileExplorerFeature {
  nonisolated static let initialListingLimit = 10_000
  nonisolated static let listingLimitStep = 25_000
  nonisolated static let sweepInterval: Duration = .seconds(5)
  /// Most-recently-used worktree trees kept in memory.
  nonisolated static let cachedTreeLimit = 8

  private nonisolated static let logger = SupaLogger("FileExplorer")

  /// What the explorer is pointed at, derived by the parent after every action.
  nonisolated struct Context: Equatable, Sendable {
    var worktree: Worktree

    nonisolated enum Availability: Equatable, Sendable {
      case available(root: URL)
      case unavailable(UnavailabilityReason)
    }

    /// Single total derivation so "no root, no reason" is unrepresentable.
    var availability: Availability {
      guard worktree.host == nil else { return .unavailable(.remote) }
      guard !worktree.isMissing, let root = worktree.localWorkingDirectory else {
        return .unavailable(.missing)
      }
      return .available(root: root)
    }

    /// FileManager-safe root; `nil` for remote or missing worktrees.
    var root: URL? {
      guard case .available(let root) = availability else { return nil }
      return root
    }

    var unavailabilityReason: UnavailabilityReason? {
      guard case .unavailable(let reason) = availability else { return nil }
      return reason
    }
  }

  nonisolated enum UnavailabilityReason: Equatable, Sendable {
    case remote
    case missing
  }

  /// A pending move or paste of one or more files into a directory, carried on
  /// the conflict alert so a resolution can complete it. Bound to its worktree
  /// so switching worktrees mid-alert aborts rather than writing elsewhere.
  /// `sources` are absolute (they may come from the Finder); `destinationDirectory`
  /// is root-relative and re-resolved against the live root under `worktreeID`.
  nonisolated struct FileTransferPlan: Equatable, Sendable {
    var worktreeID: Worktree.ID
    var sources: [URL]
    var destinationDirectory: String
    var operation: FileTransferOperation
  }

  /// Why a filesystem move, paste, or rename failed. Carries only the message
  /// the alert shows; the full error is logged.
  nonisolated struct FileMutationError: Error, Equatable, Sendable {
    let message: String
  }

  nonisolated struct TreeState: Equatable, Sendable {
    /// Key of the root directory in `directories`.
    nonisolated static let rootPath = ""

    var root: URL
    /// Keyed by root-relative path, `Self.rootPath` for the root itself.
    var directories: [String: DirectoryNode] = [:]
    var expanded: Set<String> = []
    /// Root-relative path of the selected entry.
    var selectedPath: String?
    /// Uncommitted git state for the whole worktree, from one status call.
    /// Empty until the first probe lands, and for folder-kind worktrees.
    var gitStatus: GitStatusSnapshot = .empty
    /// A freshly created entry awaiting its inline rename, cleared once the view
    /// starts editing it (Finder-style new-folder naming).
    var pendingRename: String?
  }

  nonisolated struct DirectoryNode: Equatable, Sendable {
    /// A brand-new directory awaiting its first read.
    static let initialLoading = DirectoryNode(
      status: .loading(previous: nil),
      requestedLimit: FileExplorerFeature.initialListingLimit
    )

    var status: Status
    /// Cap requested from the client; grows by `listingLimitStep` on demand.
    var requestedLimit: Int

    enum Status: Equatable, Sendable {
      /// `previous` keeps rows on screen during a refresh re-list.
      case loading(previous: FileExplorerListing?)
      case loaded(FileExplorerListing)
      /// Terminal until explicitly retried, so one unreadable directory does
      /// not re-list on every rebuild. Deliberately drops previously rendered
      /// children: a directory that stopped reading fails visibly instead of
      /// showing rows that may no longer exist.
      case failed(FileExplorerListingError)
    }

    var listing: FileExplorerListing? {
      switch status {
      case .loading(let previous): previous
      case .loaded(let listing): listing
      case .failed: nil
      }
    }

    var failure: FileExplorerListingError? {
      guard case .failed(let error) = status else { return nil }
      return error
    }

    var isLoading: Bool {
      guard case .loading = status else { return false }
      return true
    }
  }

  @ObservableState
  struct State: Equatable {
    var isVisible = false
    var context: Context?
    var trees: [Worktree.ID: TreeState] = [:]
    /// MRU order for `trees` eviction; last element is the current worktree.
    var recentWorktreeIDs: [Worktree.ID] = []
    /// Destructive-discard confirmation and git-operation failures. Singular and
    /// app-modal, so it lives on `State`, not per-tree.
    @Presents var alert: AlertState<Action.Alert>?

    var activeTree: TreeState? {
      guard let id = activeWorktreeID else { return nil }
      return trees[id]
    }

    var activeWorktreeID: Worktree.ID? { context?.worktree.id }

    var selectedPath: String? {
      activeTree?.selectedPath
    }

    /// Root listing failure, driving the pane-level unavailable state.
    var rootFailure: FileExplorerListingError? {
      activeTree?.directories[TreeState.rootPath]?.failure
    }

    /// The renderable root listing, current or held over during a re-list.
    var rootListing: FileExplorerListing? {
      activeTree?.directories[TreeState.rootPath]?.listing
    }
  }

  enum Action {
    /// Parent-driven reconciliation of the selected worktree and visibility.
    case contextChanged(Context?, isVisible: Bool)
    case directoryToggled(String)
    case showMoreTapped(directory: String)
    case refreshRequested
    case rowSelected(String?)
    case applicationBecameActive
    case listingLoaded(
      worktreeID: Worktree.ID,
      root: URL,
      directory: String,
      limit: Int,
      result: Result<FileExplorerListing, FileExplorerListingError>
    )
    case sweepTicked
    case sweepCompleted(worktreeID: Worktree.ID, changedDirectories: [String])
    case gitStatusLoaded(worktreeID: Worktree.ID, root: URL, GitStatusSnapshot)
    case stageToggled(path: String)
    case discardRequested(path: String)
    /// Move any file or folder to the system Trash, regardless of git state.
    case trashRequested(path: String)
    case gitOperationCompleted(worktreeID: Worktree.ID, Result<Void, GitOperationError>)
    /// A drag-drop move (`.move`) or a paste (`.copy`) of files into a directory.
    case filesTransferRequested(sources: [URL], destinationDirectory: String, operation: FileTransferOperation)
    case transferConflictChecked(FileTransferPlan, collisions: [String], mergeable: Bool)
    case renameRequested(path: String, newName: String)
    /// Create an empty file or folder in the directory, then start its rename.
    case createItemRequested(directory: String, isDirectory: Bool)
    case itemCreated(worktreeID: Worktree.ID, directory: String, Result<String, FileMutationError>)
    /// The view began the inline rename, so the one-shot request can clear.
    case pendingRenameConsumed
    case fileMutationCompleted(worktreeID: Worktree.ID, refresh: [String], Result<Void, FileMutationError>)
    case alert(PresentationAction<Alert>)

    enum Alert: Equatable {
      case confirmDiscard(worktreeID: Worktree.ID, path: String, tracked: Bool)
      case confirmTrash(worktreeID: Worktree.ID, path: String)
      /// Resolve a name collision with the chosen conflict policy.
      case resolveTransfer(FileTransferPlan, policy: FileConflictPolicy)
    }
  }

  private enum CancelID {
    static let sweep = "fileExplorer.sweep"

    static func listings(_ worktreeID: Worktree.ID) -> String {
      "fileExplorer.listings.\(worktreeID.rawValue)"
    }

    static func gitStatus(_ worktreeID: Worktree.ID) -> String {
      "fileExplorer.gitStatus.\(worktreeID.rawValue)"
    }
  }

  /// One expanded directory's mtime reference for the staleness sweep.
  private nonisolated struct SweepBaseline: Sendable {
    let directory: String
    let url: URL
    let date: Date?
  }

  // Resolved by type rather than key path: the module defaults to MainActor
  // isolation, which makes `\.fileExplorerClient` a non-Sendable key path.
  @Dependency(FileExplorerClient.self) var fileExplorerClient
  // Resolved by type for the same MainActor-isolation reason as the file client.
  @Dependency(GitClientDependency.self) var gitClient
  @Dependency(\.continuousClock) var clock

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .contextChanged(let context, let isVisible):
        return handleContextChanged(&state, context: context, isVisible: isVisible)

      case .directoryToggled(let path):
        return handleDirectoryToggled(&state, path: path)

      case .showMoreTapped(let directory):
        guard
          let id = state.activeWorktreeID,
          var tree = state.trees[id],
          var node = tree.directories[directory],
          !node.isLoading
        else { return .none }
        node.requestedLimit += Self.listingLimitStep
        node.status = .loading(previous: node.listing)
        tree.directories[directory] = node
        state.trees[id] = tree
        return listEffect(worktreeID: id, root: tree.root, directory: directory, limit: node.requestedLimit)

      case .refreshRequested:
        // Reload re-reads unconditionally; the sweep's mtime gate is for
        // background freshness, not for an explicit retry.
        guard
          let id = state.activeWorktreeID,
          let tree = state.trees[id]
        else { return .none }
        let eligible = tree.directories.keys.filter {
          $0 == TreeState.rootPath || tree.expanded.contains($0)
        }
        return .merge(relist(&state, worktreeID: id, directories: eligible), gitStatusEffect(state))

      case .applicationBecameActive:
        return .merge(sweepEffect(state), gitStatusEffect(state))

      case .rowSelected(let path):
        guard let id = state.activeWorktreeID else { return .none }
        state.trees[id]?.selectedPath = path
        return .none

      case .listingLoaded(let worktreeID, let root, let directory, let limit, let result):
        // Keyed by the worktree the effect was issued for, so a listing that
        // lands after a switch updates that cache and never the visible tree.
        // The root and limit echoes drop responses that no longer match the
        // node: a re-rooted tree, or an out-of-order show-more chunk.
        guard var tree = state.trees[worktreeID], tree.root == root else { return .none }
        guard var node = tree.directories[directory], node.requestedLimit == limit else { return .none }
        switch result {
        case .success(let listing):
          node.status = .loaded(listing)
          // A selection whose entry vanished from its parent listing would
          // otherwise haunt the tree and re-select on reappearance.
          func isMissing(_ path: String) -> Bool {
            Self.parentDirectory(of: path) == directory
              && !listing.entries.contains { Self.childPath(of: directory, name: $0.name) == path }
          }
          if let selected = tree.selectedPath, isMissing(selected) {
            tree.selectedPath = nil
          }
          // A create whose new row fell beyond a truncated listing must not keep
          // its pending rename, or it would fire unprompted after a later reload.
          if let pending = tree.pendingRename, isMissing(pending) {
            tree.pendingRename = nil
          }
        case .failure(let error):
          node.status = .failed(error)
          // Auto-collapse so the warning row's "expand again to retry"
          // affordance is one gesture, not collapse-then-expand.
          tree.expanded.remove(directory)
        }
        tree.directories[directory] = node
        state.trees[worktreeID] = tree
        return .none

      case .sweepTicked:
        return .merge(sweepEffect(state), gitStatusEffect(state))

      case .sweepCompleted(let worktreeID, let changedDirectories):
        // The visibility check drops a stat pass that was in flight when the
        // pane hid; the timer is cancelled but its last tick may still land.
        guard state.isVisible, worktreeID == state.activeWorktreeID else { return .none }
        return relist(&state, worktreeID: worktreeID, directories: changedDirectories)

      case .gitStatusLoaded(let worktreeID, let root, let snapshot):
        // Root echo drops a probe that lands after the tree was re-rooted or
        // switched, like `listingLoaded`. Diff-and-skip so an unchanged tick
        // (the steady state) mutates nothing and invalidates no rows.
        guard var tree = state.trees[worktreeID], tree.root == root, tree.gitStatus != snapshot
        else { return .none }
        tree.gitStatus = snapshot
        state.trees[worktreeID] = tree
        return .none

      case .stageToggled(let path):
        return handleStageToggled(&state, path: path)

      case .discardRequested(let path):
        return handleDiscardRequested(&state, path: path)

      case .trashRequested(let path):
        return handleTrashRequested(&state, path: path)

      case .filesTransferRequested(let sources, let destinationDirectory, let operation):
        return handleTransferRequested(
          &state, sources: sources, destinationDirectory: destinationDirectory, operation: operation
        )

      case .transferConflictChecked(let plan, let collisions, let mergeable):
        return handleTransferConflictChecked(&state, plan: plan, collisions: collisions, mergeable: mergeable)

      case .renameRequested(let path, let newName):
        return handleRenameRequested(&state, path: path, newName: newName)

      case .createItemRequested(let directory, let isDirectory):
        return handleCreateItemRequested(&state, directory: directory, isDirectory: isDirectory)

      case .itemCreated(let worktreeID, let directory, let result):
        return handleItemCreated(&state, worktreeID: worktreeID, directory: directory, result: result)

      case .pendingRenameConsumed:
        if let id = state.activeWorktreeID { state.trees[id]?.pendingRename = nil }
        return .none

      case .fileMutationCompleted(let worktreeID, let refresh, let result):
        return handleFileMutationCompleted(&state, worktreeID: worktreeID, refresh: refresh, result: result)

      case .alert(.presented(.confirmDiscard(let worktreeID, let path, let tracked))):
        return handleDiscardConfirmed(&state, worktreeID: worktreeID, path: path, tracked: tracked)

      case .alert(.presented(.confirmTrash(let worktreeID, let path))):
        return handleTrashConfirmed(&state, worktreeID: worktreeID, path: path)

      case .alert(.presented(.resolveTransfer(let plan, let policy))):
        state.alert = nil
        return performTransfer(&state, plan: plan, policy: policy)

      case .alert:
        return .none

      case .gitOperationCompleted(let worktreeID, let result):
        return handleGitOperationCompleted(&state, worktreeID: worktreeID, result: result)
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }

  private func handleContextChanged(
    _ state: inout State,
    context: Context?,
    isVisible: Bool
  ) -> Effect<Action> {
    let previousWorktreeID = state.activeWorktreeID
    let wasRunningSweep = state.isVisible && state.context?.root != nil
    state.context = context
    state.isVisible = isVisible

    guard isVisible, let context, let root = context.root else {
      return wasRunningSweep ? .cancel(id: CancelID.sweep) : .none
    }

    let worktreeID = context.worktree.id
    var effects: [Effect<Action>] = []
    if state.trees[worktreeID]?.root != root {
      // New tree, or the worktree moved on disk: start from a fresh root.
      var tree = TreeState(root: root)
      tree.directories[TreeState.rootPath] = .initialLoading
      state.trees[worktreeID] = tree
      effects.append(
        listEffect(worktreeID: worktreeID, root: root, directory: TreeState.rootPath, limit: Self.initialListingLimit)
      )
    } else if worktreeID != previousWorktreeID {
      // Cached tree re-activated: freshen it instead of trusting stale listings.
      effects.append(sweepEffect(state))
    }
    effects.append(touchRecentWorktree(&state, worktreeID: worktreeID))
    effects.append(gitStatusEffect(state))
    effects.append(sweepTimerEffect())
    return .merge(effects)
  }

  private func handleDirectoryToggled(_ state: inout State, path: String) -> Effect<Action> {
    guard
      let id = state.activeWorktreeID,
      var tree = state.trees[id]
    else { return .none }
    if tree.expanded.contains(path) {
      tree.expanded.remove(path)
      state.trees[id] = tree
      return .none
    }
    tree.expanded.insert(path)
    var effect: Effect<Action> = .none
    switch tree.directories[path]?.status {
    case .loaded, .loading:
      break
    case .failed, .none:
      // First expansion, or an explicit retry of a failed read.
      tree.directories[path] = .initialLoading
      effect = listEffect(worktreeID: id, root: tree.root, directory: path, limit: Self.initialListingLimit)
    }
    state.trees[id] = tree
    return effect
  }

  /// Flips each not-already-loading directory to `.loading(previous:)` and
  /// issues its re-list effect.
  private func relist(
    _ state: inout State,
    worktreeID: Worktree.ID,
    directories: some Sequence<String>
  ) -> Effect<Action> {
    guard var tree = state.trees[worktreeID] else { return .none }
    var effects: [Effect<Action>] = []
    for directory in directories {
      guard var node = tree.directories[directory], !node.isLoading else { continue }
      node.status = .loading(previous: node.listing)
      tree.directories[directory] = node
      effects.append(
        listEffect(worktreeID: worktreeID, root: tree.root, directory: directory, limit: node.requestedLimit)
      )
    }
    guard !effects.isEmpty else { return .none }
    state.trees[worktreeID] = tree
    return .merge(effects)
  }

  private func touchRecentWorktree(_ state: inout State, worktreeID: Worktree.ID) -> Effect<Action> {
    state.recentWorktreeIDs.removeAll { $0 == worktreeID }
    state.recentWorktreeIDs.append(worktreeID)
    var cancellations: [Effect<Action>] = []
    while state.recentWorktreeIDs.count > Self.cachedTreeLimit {
      let evicted = state.recentWorktreeIDs.removeFirst()
      state.trees[evicted] = nil
      // In-flight listings die with the tree; a late response would otherwise
      // repopulate a recreated tree with stale entries through matching echoes.
      cancellations.append(.cancel(id: CancelID.listings(evicted)))
      cancellations.append(.cancel(id: CancelID.gitStatus(evicted)))
    }
    return .merge(cancellations)
  }

  private func listEffect(
    worktreeID: Worktree.ID,
    root: URL,
    directory: String,
    limit: Int
  ) -> Effect<Action> {
    let url = Self.url(for: directory, root: root)
    return .run { send in
      let result: Result<FileExplorerListing, FileExplorerListingError>
      do {
        result = .success(try await fileExplorerClient.list(url, limit))
      } catch {
        // The client's typed throws makes any other error unrepresentable.
        result = .failure(error as? FileExplorerListingError ?? .unreadable)
      }
      await send(
        .listingLoaded(worktreeID: worktreeID, root: root, directory: directory, limit: limit, result: result)
      )
    }
    .cancellable(id: CancelID.listings(worktreeID))
  }

  /// Stats the root and expanded directories, then re-lists the changed or
  /// unstattable ones.
  private func sweepEffect(_ state: State) -> Effect<Action> {
    guard
      state.isVisible,
      let context = state.context,
      let root = context.root,
      let tree = state.trees[context.worktree.id]
    else { return .none }
    let worktreeID = context.worktree.id
    var baselines: [SweepBaseline] = []
    for (path, node) in tree.directories {
      guard let listing = node.listing, !node.isLoading else { continue }
      guard path == TreeState.rootPath || tree.expanded.contains(path) else { continue }
      baselines.append(
        SweepBaseline(directory: path, url: Self.url(for: path, root: root), date: listing.modificationDate)
      )
    }
    guard !baselines.isEmpty else { return .none }
    let capturedBaselines = baselines
    return .run { send in
      let dates = await fileExplorerClient.modificationDates(capturedBaselines.map(\.url))
      // Inequality, not newer-than: restores and checkouts move mtimes
      // backward. Nil-safe on both sides: a deleted directory (date, then
      // nil) re-lists so it fails visibly, a late-appearing date re-lists
      // once and converges, and nil on both sides never re-lists, so a
      // filesystem that can't stat mtimes doesn't loop every tick.
      let changed = capturedBaselines.filter { dates[$0.url] != $0.date }
      guard !changed.isEmpty else { return }
      await send(.sweepCompleted(worktreeID: worktreeID, changedDirectories: changed.map(\.directory)))
    }
  }

  private func handleStageToggled(_ state: inout State, path: String) -> Effect<Action> {
    guard
      let id = state.activeWorktreeID,
      let status = state.trees[id]?.gitStatus.statuses[path],
      let root = state.trees[id]?.root,
      !status.isConflicted
    else { return .none }
    // Stage when there's an unstaged change to fold in, otherwise unstage.
    let shouldStage = status.hasUnstagedChange
    return .run { send in
      let result: Result<Void, GitOperationError>
      do {
        if shouldStage {
          try await gitClient.stageFile(path, root)
        } else {
          try await gitClient.unstageFile(path, root)
        }
        result = .success(())
      } catch {
        result = .failure(Self.operationError(error, path: path))
      }
      await send(.gitOperationCompleted(worktreeID: id, result))
    }
  }

  private func handleDiscardRequested(_ state: inout State, path: String) -> Effect<Action> {
    guard
      let id = state.activeWorktreeID,
      let status = state.trees[id]?.gitStatus.statuses[path],
      let kind = status.discardKind
    else { return .none }
    state.alert = Self.discardAlert(worktreeID: id, path: path, tracked: kind == .restore)
    return .none
  }

  private func handleDiscardConfirmed(
    _ state: inout State,
    worktreeID: Worktree.ID,
    path: String,
    tracked: Bool
  ) -> Effect<Action> {
    // Nil it explicitly: `.ifLet` only clears on `.dismiss`, and this is a
    // presented-button action.
    state.alert = nil
    // Bind the discard to the worktree its confirmation was raised for: if the
    // user switched worktrees while the alert was up, abort rather than discard
    // the same path in a different worktree.
    guard worktreeID == state.activeWorktreeID, let root = state.trees[worktreeID]?.root else { return .none }
    return .run { send in
      let result: Result<Void, GitOperationError>
      do {
        try await gitClient.discardFile(path, root, tracked)
        result = .success(())
      } catch {
        result = .failure(Self.operationError(error, path: path))
      }
      await send(.gitOperationCompleted(worktreeID: worktreeID, result))
    }
  }

  private func handleTrashRequested(_ state: inout State, path: String) -> Effect<Action> {
    guard let id = state.activeWorktreeID else { return .none }
    state.alert = Self.trashAlert(worktreeID: id, path: path)
    return .none
  }

  private func handleTrashConfirmed(
    _ state: inout State,
    worktreeID: Worktree.ID,
    path: String
  ) -> Effect<Action> {
    state.alert = nil
    // Bind to the originating worktree so a mid-alert switch can't trash a path
    // in a different tree.
    guard worktreeID == state.activeWorktreeID, let root = state.trees[worktreeID]?.root else { return .none }
    let url = Self.url(for: path, root: root)
    let parent = Self.parentDirectory(of: path)
    return .run { send in
      let result: Result<Void, FileMutationError>
      do {
        try await fileExplorerClient.moveToTrash(url)
        result = .success(())
      } catch {
        result = .failure(Self.mutationError(error, action: "trash"))
      }
      await send(.fileMutationCompleted(worktreeID: worktreeID, refresh: [parent], result))
    }
  }

  private func handleGitOperationCompleted(
    _ state: inout State,
    worktreeID: Worktree.ID,
    result: Result<Void, GitOperationError>
  ) -> Effect<Action> {
    switch result {
    case .success:
      // Re-read the mutated worktree's state, chained on completion so it can't
      // race the 5s sweep. Skip when the user already moved on; that tree
      // refreshes on its next visit.
      guard worktreeID == state.activeWorktreeID else { return .none }
      return gitStatusEffect(state)
    case .failure(let error):
      state.alert = Self.operationFailureAlert(error)
      return .none
    }
  }

  /// Checks the destination for name collisions off the main actor, then routes
  /// to a direct transfer or a conflict prompt.
  private func handleTransferRequested(
    _ state: inout State,
    sources: [URL],
    destinationDirectory: String,
    operation: FileTransferOperation
  ) -> Effect<Action> {
    guard
      let id = state.activeWorktreeID,
      let root = state.trees[id]?.root
    else { return .none }
    let destination = Self.url(for: destinationDirectory, root: root)
    // Drop any source that contains the destination: paste has no drag-time
    // ancestry check, so copying a folder into itself would recurse forever.
    let sources = sources.filter { !Self.directory(destination, isAtOrUnder: $0) }
    guard !sources.isEmpty else { return .none }
    let plan = FileTransferPlan(
      worktreeID: id, sources: sources, destinationDirectory: destinationDirectory, operation: operation
    )
    let names = sources.map(\.lastPathComponent)
    // Two sources sharing a name collide with each other even when the
    // destination is clear, so a duplicate within the batch also needs the
    // prompt. Compare case-insensitively to match the default macOS volume.
    var seen: Set<String> = []
    let duplicates = Set(names.filter { !seen.insert($0.lowercased()).inserted })
    return .run { send in
      async let existingTask = fileExplorerClient.existingNames(destination, names)
      async let mergeableTask = fileExplorerClient.mergeableNames(destination, sources)
      let mergeableSet = await mergeableTask
      let collisions = await existingTask.union(duplicates)
      // Offer Merge only when every colliding item is a directory folding into a
      // same-named one, so choosing Merge can't silently replace a file too.
      let mergeable = !collisions.isEmpty && collisions.isSubset(of: mergeableSet)
      await send(.transferConflictChecked(plan, collisions: Array(collisions), mergeable: mergeable))
    }
  }

  private func handleTransferConflictChecked(
    _ state: inout State,
    plan: FileTransferPlan,
    collisions: [String],
    mergeable: Bool
  ) -> Effect<Action> {
    guard plan.worktreeID == state.activeWorktreeID else { return .none }
    guard collisions.isEmpty else {
      state.alert = Self.transferConflictAlert(plan: plan, collisions: collisions, mergeable: mergeable)
      return .none
    }
    return performTransfer(&state, plan: plan, policy: .abort)
  }

  /// Runs the pending transfer for every source under one policy (a non-colliding
  /// source is unaffected by keep-both or overwrite), then refreshes the touched
  /// directories. Bound to the plan's worktree so a mid-alert switch aborts.
  private func performTransfer(
    _ state: inout State,
    plan: FileTransferPlan,
    policy: FileConflictPolicy
  ) -> Effect<Action> {
    guard plan.worktreeID == state.activeWorktreeID, let root = state.trees[plan.worktreeID]?.root else { return .none }
    let destination = Self.url(for: plan.destinationDirectory, root: root)
    // A move empties each source's parent too; a copy only fills the destination.
    var refresh: Set<String> = [plan.destinationDirectory]
    if plan.operation == .move {
      for source in plan.sources {
        if let parent = Self.relativePath(of: source.deletingLastPathComponent(), under: root) {
          refresh.insert(parent)
        }
      }
    }
    let worktreeID = plan.worktreeID
    let sources = plan.sources
    let operation = plan.operation
    let refreshDirectories = Array(refresh)
    return .run { send in
      // Keep going after a failure: earlier sources may have already moved, so
      // aborting the batch would leave the tree stale on their old rows.
      var firstError: Error?
      for source in sources {
        do {
          try await fileExplorerClient.transfer(source, destination, source.lastPathComponent, operation, policy)
        } catch {
          if firstError == nil { firstError = error }
        }
      }
      let result: Result<Void, FileMutationError> =
        firstError.map { .failure(Self.mutationError($0, action: operation == .move ? "move" : "paste")) }
        ?? .success(())
      await send(.fileMutationCompleted(worktreeID: worktreeID, refresh: refreshDirectories, result))
    }
  }

  private func handleRenameRequested(_ state: inout State, path: String, newName: String) -> Effect<Action> {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let id = state.activeWorktreeID,
      let root = state.trees[id]?.root,
      !trimmed.isEmpty,
      !trimmed.contains("/"),
      trimmed != (path as NSString).lastPathComponent
    else { return .none }
    let source = Self.url(for: path, root: root)
    let parent = Self.parentDirectory(of: path)
    return .run { send in
      let result: Result<Void, FileMutationError>
      do {
        try await fileExplorerClient.rename(source, trimmed)
        result = .success(())
      } catch {
        result = .failure(Self.mutationError(error, action: "rename"))
      }
      await send(.fileMutationCompleted(worktreeID: id, refresh: [parent], result))
    }
  }

  private func handleCreateItemRequested(
    _ state: inout State,
    directory: String,
    isDirectory: Bool
  ) -> Effect<Action> {
    guard let id = state.activeWorktreeID, let root = state.trees[id]?.root else { return .none }
    // Expand the target folder so the new row is visible for its rename.
    if directory != TreeState.rootPath { state.trees[id]?.expanded.insert(directory) }
    let parent = Self.url(for: directory, root: root)
    let name = isDirectory ? "Untitled Folder" : "Untitled"
    return .run { send in
      let result: Result<String, FileMutationError>
      do {
        result = .success(try await fileExplorerClient.createItem(parent, name, isDirectory))
      } catch {
        result = .failure(Self.mutationError(error, action: "create"))
      }
      await send(.itemCreated(worktreeID: id, directory: directory, result))
    }
  }

  private func handleItemCreated(
    _ state: inout State,
    worktreeID: Worktree.ID,
    directory: String,
    result: Result<String, FileMutationError>
  ) -> Effect<Action> {
    guard worktreeID == state.activeWorktreeID, var tree = state.trees[worktreeID] else { return .none }
    switch result {
    case .success(let name):
      let path = Self.childPath(of: directory, name: name)
      tree.selectedPath = path
      // Picked up by the view once the fresh listing brings the new row in.
      tree.pendingRename = path
      // Force a listing of the target directory even if it was never opened, so
      // the new row (and its rename) actually appears; `relist` skips a node
      // that doesn't exist yet.
      let limit = tree.directories[directory]?.requestedLimit ?? Self.initialListingLimit
      tree.directories[directory] = DirectoryNode(
        status: .loading(previous: tree.directories[directory]?.listing),
        requestedLimit: limit
      )
      state.trees[worktreeID] = tree
      return .merge(
        listEffect(worktreeID: worktreeID, root: tree.root, directory: directory, limit: limit),
        gitStatusEffect(state)
      )
    case .failure(let error):
      state.alert = Self.mutationFailureAlert(error)
      return .none
    }
  }

  private func handleFileMutationCompleted(
    _ state: inout State,
    worktreeID: Worktree.ID,
    refresh: [String],
    result: Result<Void, FileMutationError>
  ) -> Effect<Action> {
    // Ignore a completion for a worktree the user already left: it must not
    // raise an alert or relist over the now-active one.
    guard worktreeID == state.activeWorktreeID else { return .none }
    // A failure alert still refreshes: a partial batch may have moved some files
    // before it threw, so the touched directories must re-list either way.
    if case .failure(let error) = result {
      state.alert = Self.mutationFailureAlert(error)
    }
    return .merge(relist(&state, worktreeID: worktreeID, directories: refresh), gitStatusEffect(state))
  }

  private nonisolated static func mutationError(_ error: Error, action: String) -> FileMutationError {
    logger.error("File \(action) failed: \(error.localizedDescription)")
    return FileMutationError(message: error.localizedDescription)
  }

  private static func transferConflictAlert(
    plan: FileTransferPlan,
    collisions: [String],
    mergeable: Bool
  ) -> AlertState<Action.Alert> {
    AlertState {
      TextState(
        collisions.count == 1 ? "\"\(collisions[0])\" already exists" : "\(collisions.count) items already exist"
      )
    } actions: {
      ButtonState(action: .resolveTransfer(plan, policy: .keepBoth)) { TextState("Keep Both") }
      // Merge only makes sense for a directory folded into a same-named one.
      if mergeable {
        ButtonState(action: .resolveTransfer(plan, policy: .merge)) { TextState("Merge") }
      }
      ButtonState(role: .destructive, action: .resolveTransfer(plan, policy: .overwrite)) { TextState("Replace") }
      ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
      TextState(
        mergeable
          ? "An item with the same name already exists. Merge combines the folders; Replace overwrites."
          : "An item with the same name already exists in this location."
      )
    }
  }

  private static func mutationFailureAlert(_ error: FileMutationError) -> AlertState<Action.Alert> {
    AlertState {
      TextState("The operation couldn't be completed")
    } actions: {
      ButtonState(role: .cancel) { TextState("OK") }
    } message: {
      TextState(error.message)
    }
  }

  private nonisolated static func operationError(_ error: Error, path: String) -> GitOperationError {
    // Log the full reason (git stderr survives on `GitClientError`) since the
    // user-facing alert only conveys the category.
    let text = (error as? GitClientError)?.errorDescription ?? error.localizedDescription
    logger.error("Git file operation failed for \(path): \(text)")
    let lowered = text.lowercased()
    let locked = lowered.contains("index.lock") || lowered.contains("another git process")
    return GitOperationError(path: path, kind: locked ? .locked : .failed)
  }

  private static func discardAlert(worktreeID: Worktree.ID, path: String, tracked: Bool) -> AlertState<Action.Alert> {
    let name = (path as NSString).lastPathComponent
    return AlertState {
      TextState(tracked ? "Discard changes to \"\(name)\"?" : "Move \"\(name)\" to the Trash?")
    } actions: {
      // Destructive button first so Return confirms it, matching the app's other
      // alerts; Cancel stays on Escape.
      ButtonState(role: .destructive, action: .confirmDiscard(worktreeID: worktreeID, path: path, tracked: tracked)) {
        TextState(tracked ? "Discard" : "Move to Trash")
      }
      ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
      TextState(
        tracked
          ? "This will permanently discard your uncommitted changes. This action cannot be undone."
          : "This file has no committed version, so it will be moved to the Trash."
      )
    }
  }

  private static func trashAlert(worktreeID: Worktree.ID, path: String) -> AlertState<Action.Alert> {
    let name = (path as NSString).lastPathComponent
    return AlertState {
      TextState("Move \"\(name)\" to the Trash?")
    } actions: {
      ButtonState(role: .destructive, action: .confirmTrash(worktreeID: worktreeID, path: path)) {
        TextState("Move to Trash")
      }
      ButtonState(role: .cancel) { TextState("Cancel") }
    } message: {
      TextState("You can restore it from the Trash later.")
    }
  }

  private static func operationFailureAlert(_ error: GitOperationError) -> AlertState<Action.Alert> {
    let name = (error.path as NSString).lastPathComponent
    return AlertState {
      TextState("Couldn't update \"\(name)\"")
    } actions: {
      ButtonState(role: .cancel) { TextState("OK") }
    } message: {
      TextState(
        error.kind == .locked
          ? "Another git process is running. Try again in a moment."
          : "The operation couldn't be completed."
      )
    }
  }

  /// One `git status` probe of the active local git worktree, gated to the
  /// visible pane. Sends nothing when the probe fails or the worktree can't
  /// carry git status (folder-kind or remote), so a transient failure keeps the
  /// last-good snapshot rather than flashing every decoration off.
  private func gitStatusEffect(_ state: State) -> Effect<Action> {
    guard
      state.isVisible,
      let context = state.context,
      !context.worktree.isFolder,
      let root = context.root,
      state.trees[context.worktree.id]?.root == root
    else { return .none }
    let worktreeID = context.worktree.id
    return .run { send in
      guard let snapshot = await gitClient.fileStatus(root) else { return }
      await send(.gitStatusLoaded(worktreeID: worktreeID, root: root, snapshot))
    }
    .cancellable(id: CancelID.gitStatus(worktreeID), cancelInFlight: true)
  }

  private func sweepTimerEffect() -> Effect<Action> {
    .run { send in
      while !Task.isCancelled {
        try await clock.sleep(for: Self.sweepInterval)
        await send(.sweepTicked)
      }
    }
    .cancellable(id: CancelID.sweep, cancelInFlight: true)
  }

  nonisolated static func url(for directory: String, root: URL) -> URL {
    guard directory != TreeState.rootPath else { return root }
    return root.appending(path: directory, directoryHint: .isDirectory)
  }

  nonisolated static func parentDirectory(of path: String) -> String {
    guard let separatorIndex = path.lastIndex(of: "/") else { return TreeState.rootPath }
    return String(path[..<separatorIndex])
  }

  nonisolated static func childPath(of directory: String, name: String) -> String {
    directory == TreeState.rootPath ? name : directory + "/" + name
  }

  /// The root-relative path of `url`, or `nil` when it sits outside `root`.
  /// Used to refresh a moved file's origin only when it lives in the tree.
  nonisolated static func relativePath(of url: URL, under root: URL) -> String? {
    let rootPath = Self.slashFreePath(root)
    let target = Self.slashFreePath(url)
    if target == rootPath { return TreeState.rootPath }
    guard target.hasPrefix(rootPath + "/") else { return nil }
    return String(target.dropFirst(rootPath.count + 1))
  }

  /// Whether `directory` is `ancestor` itself or nested inside it, so a copy
  /// into its own subtree can be refused.
  nonisolated static func directory(_ directory: URL, isAtOrUnder ancestor: URL) -> Bool {
    let ancestorPath = Self.slashFreePath(ancestor)
    let target = Self.slashFreePath(directory)
    return target == ancestorPath || target.hasPrefix(ancestorPath + "/")
  }

  /// A standardized path with any trailing slash dropped, so a directory URL
  /// matches the tree's slash-free keys.
  private nonisolated static func slashFreePath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    if path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
