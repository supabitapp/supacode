import ComposableArchitecture
import Foundation

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
          if let selected = tree.selectedPath,
            Self.parentDirectory(of: selected) == directory,
            !listing.entries.contains(where: { Self.childPath(of: directory, name: $0.name) == selected })
          {
            tree.selectedPath = nil
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
      }
    }
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
}
