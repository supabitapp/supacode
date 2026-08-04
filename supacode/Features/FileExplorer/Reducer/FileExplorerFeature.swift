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
    var selectedRowID: FileExplorerRowID?
  }

  nonisolated struct DirectoryNode: Equatable, Sendable {
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
    /// Flattened rows the view renders; rebuilt in the post-reduce hook so no
    /// arm can forget it, and never derived in a view body.
    var rows: [FileExplorerRow] = []

    var activeTree: TreeState? {
      guard let id = activeWorktreeID else { return nil }
      return trees[id]
    }

    var activeWorktreeID: Worktree.ID? { context?.worktree.id }

    var selectedRowID: FileExplorerRowID? {
      guard let id = activeWorktreeID else { return nil }
      return trees[id]?.selectedRowID
    }

    /// Root listing failure, driving the pane-level unavailable state.
    var rootFailure: FileExplorerListingError? {
      activeTree?.directories[TreeState.rootPath]?.failure
    }

    var isLoadingRoot: Bool {
      activeTree?.directories[TreeState.rootPath]?.isLoading ?? false
    }

    /// The rendered entry at `path`, if currently visible.
    func entry(at path: String) -> FileExplorerRow.Entry? {
      guard
        let row = rows.first(where: { $0.id == .entry(path: path) }),
        case .entry(let entry) = row.kind
      else { return nil }
      return entry
    }
  }

  enum Action {
    /// Parent-driven reconciliation of the selected worktree and visibility.
    case contextChanged(Context?, isVisible: Bool)
    case directoryToggled(String)
    case showMoreTapped(directory: String)
    case refreshButtonTapped
    case rowSelected(FileExplorerRowID?)
    case expandSelectedDirectory
    case collapseSelectedDirectory
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
  }

  private enum CancelID {
    static let sweep = "fileExplorer.sweep"
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

      case .refreshButtonTapped:
        // Manual refresh re-reads unconditionally; the sweep's mtime gate is
        // for background freshness, not for a user asking to reload.
        guard
          let id = state.activeWorktreeID,
          var tree = state.trees[id]
        else { return .none }
        var effects: [Effect<Action>] = []
        for (path, node) in tree.directories {
          guard !node.isLoading else { continue }
          guard path == TreeState.rootPath || tree.expanded.contains(path) else { continue }
          var updated = node
          updated.status = .loading(previous: node.listing)
          tree.directories[path] = updated
          effects.append(
            listEffect(worktreeID: id, root: tree.root, directory: path, limit: node.requestedLimit)
          )
        }
        guard !effects.isEmpty else { return .none }
        state.trees[id] = tree
        return .merge(effects)

      case .applicationBecameActive:
        return sweepEffect(state)

      case .rowSelected(let rowID):
        guard let id = state.activeWorktreeID else { return .none }
        state.trees[id]?.selectedRowID = rowID
        return .none

      case .expandSelectedDirectory:
        guard
          let path = state.selectedRowID?.entryPath,
          let entry = state.entry(at: path),
          entry.isDirectory,
          !entry.isExpanded
        else { return .none }
        return handleDirectoryToggled(&state, path: path)

      case .collapseSelectedDirectory:
        guard let path = state.selectedRowID?.entryPath else { return .none }
        if let entry = state.entry(at: path), entry.isDirectory, entry.isExpanded {
          return handleDirectoryToggled(&state, path: path)
        }
        // Collapsed row or plain file: hop to the parent directory, Finder-style.
        guard
          let id = state.activeWorktreeID,
          let separatorIndex = path.lastIndex(of: "/")
        else { return .none }
        state.trees[id]?.selectedRowID = .entry(path: String(path[..<separatorIndex]))
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
        case .failure(let error):
          node.status = .failed(error)
        }
        tree.directories[directory] = node
        state.trees[worktreeID] = tree
        return .none

      case .sweepTicked:
        return sweepEffect(state)

      case .sweepCompleted(let worktreeID, let changedDirectories):
        guard
          worktreeID == state.activeWorktreeID,
          var tree = state.trees[worktreeID]
        else { return .none }
        var effects: [Effect<Action>] = []
        for directory in changedDirectories {
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
    }
    // Post-reduce rebuild so the rows cache can never drift from the trees;
    // the equality guard inside keeps no-op rebuilds from invalidating SwiftUI.
    Reduce { state, _ in
      rebuildRows(&state)
      return .none
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
      tree.directories[TreeState.rootPath] = DirectoryNode(
        status: .loading(previous: nil),
        requestedLimit: Self.initialListingLimit
      )
      state.trees[worktreeID] = tree
      effects.append(
        listEffect(worktreeID: worktreeID, root: root, directory: TreeState.rootPath, limit: Self.initialListingLimit)
      )
    } else if worktreeID != previousWorktreeID {
      // Cached tree re-activated: freshen it instead of trusting stale listings.
      effects.append(sweepEffect(state))
    }
    touchRecentWorktree(&state, worktreeID: worktreeID)
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
      tree.directories[path] = DirectoryNode(
        status: .loading(previous: nil),
        requestedLimit: Self.initialListingLimit
      )
      effect = listEffect(worktreeID: id, root: tree.root, directory: path, limit: Self.initialListingLimit)
    }
    state.trees[id] = tree
    return effect
  }

  private func touchRecentWorktree(_ state: inout State, worktreeID: Worktree.ID) {
    state.recentWorktreeIDs.removeAll { $0 == worktreeID }
    state.recentWorktreeIDs.append(worktreeID)
    while state.recentWorktreeIDs.count > Self.cachedTreeLimit {
      let evicted = state.recentWorktreeIDs.removeFirst()
      state.trees[evicted] = nil
    }
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

  /// Flattens the active tree into the row array the view renders.
  private func rebuildRows(_ state: inout State) {
    var rows: [FileExplorerRow] = []
    if let tree = state.activeTree {
      appendRows(into: &rows, tree: tree, directory: TreeState.rootPath, depth: 0)
    }
    guard rows != state.rows else { return }
    state.rows = rows
  }

  private func appendRows(
    into rows: inout [FileExplorerRow],
    tree: TreeState,
    directory: String,
    depth: Int
  ) {
    guard let listing = tree.directories[directory]?.listing else { return }
    for entry in listing.entries {
      let path = directory == TreeState.rootPath ? entry.name : directory + "/" + entry.name
      let childNode = entry.isDirectory ? tree.directories[path] : nil
      let isExpanded = entry.isDirectory && tree.expanded.contains(path)
      rows.append(
        FileExplorerRow(
          path: path,
          depth: depth,
          kind: .entry(
            FileExplorerRow.Entry(
              name: entry.name,
              isDirectory: entry.isDirectory,
              isSymbolicLink: entry.isSymbolicLink,
              isExpanded: isExpanded,
              isLoading: childNode?.isLoading ?? false,
              failure: childNode?.failure
            )
          )
        )
      )
      if isExpanded {
        appendRows(into: &rows, tree: tree, directory: path, depth: depth + 1)
      }
    }
    if listing.isTruncated {
      rows.append(
        FileExplorerRow(
          path: directory,
          depth: depth,
          kind: .showMore(
            remaining: listing.totalCount - listing.entries.count,
            isLoading: tree.directories[directory]?.isLoading ?? false
          )
        )
      )
    }
  }
}
