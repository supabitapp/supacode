import Clocks
import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct FileExplorerFeatureTests {
  private nonisolated static func worktree(path: String) -> Worktree {
    Worktree(
      location: .local(
        workingDirectory: URL(filePath: path, directoryHint: .isDirectory),
        repositoryRoot: URL(filePath: path, directoryHint: .isDirectory)
      ),
      kind: .git,
      name: (path as NSString).lastPathComponent,
      detail: "main"
    )
  }

  private nonisolated static func remoteWorktree() -> Worktree {
    Worktree(
      location: .remote(
        RemoteHost(alias: "example.com", username: "dev"),
        workingDirectory: "/srv/repo",
        repositoryRoot: "/srv/repo"
      ),
      kind: .git,
      name: "repo",
      detail: "main"
    )
  }

  private nonisolated static func listing(
    _ names: [(String, isDirectory: Bool)],
    totalCount: Int? = nil,
    modificationDate: Date? = nil
  ) -> FileExplorerListing {
    FileExplorerListing(
      entries: names.map {
        FileExplorerEntry(name: $0.0, isDirectory: $0.isDirectory, isSymbolicLink: false)
      },
      totalCount: totalCount ?? names.count,
      modificationDate: modificationDate
    )
  }

  @Test func openingPaneListsRoot() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let rootListing = Self.listing([("src", isDirectory: true), ("readme.md", isDirectory: false)])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in rootListing }
    }

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    ) {
      $0.isVisible = true
      $0.context = FileExplorerFeature.Context(worktree: worktree)
      $0.trees[worktree.id] = FileExplorerFeature.TreeState(
        root: worktree.localWorkingDirectory!,
        directories: [
          "": FileExplorerFeature.DirectoryNode(
            status: .loading(previous: nil),
            requestedLimit: FileExplorerFeature.initialListingLimit
          )
        ]
      )
      $0.recentWorktreeIDs = [worktree.id]
    }
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories[""]?.status = .loaded(rootListing)
    }
    #expect(store.state.rootListing == rootListing)

    await store.send(.contextChanged(nil, isVisible: false)) {
      $0.isVisible = false
      $0.context = nil
    }
  }

  @Test func expandingLoadsChildrenOnceAndCollapseKeepsCache() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let rootListing = Self.listing([("src", isDirectory: true)])
    let childListing = Self.listing([("main.swift", isDirectory: false)])
    let listCalls = LockIsolated(0)
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { url, _ in
        listCalls.withValue { $0 += 1 }
        return url.lastPathComponent == "src" ? childListing : rootListing
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)

    await store.send(.directoryToggled("src")) {
      $0.trees[worktree.id]?.expanded = ["src"]
    }
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories["src"]?.status = .loaded(childListing)
    }

    await store.send(.directoryToggled("src")) {
      $0.trees[worktree.id]?.expanded = []
    }

    // Re-expanding reuses the cached listing: no third list call.
    await store.send(.directoryToggled("src")) {
      $0.trees[worktree.id]?.expanded = ["src"]
    }
    #expect(listCalls.value == 2)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func failedDirectoryShowsFailureAndRetriesOnNextToggle() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let rootListing = Self.listing([("locked", isDirectory: true)])
    let shouldFail = LockIsolated(true)
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { url, _ throws(FileExplorerListingError) in
        guard url.lastPathComponent == "locked" else { return rootListing }
        if shouldFail.value {
          throw FileExplorerListingError.permissionDenied
        }
        return Self.listing([("inside.txt", isDirectory: false)])
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)

    await store.send(.directoryToggled("locked"))
    // Failure auto-collapses, so the very next expand is the retry gesture.
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories["locked"]?.status = .failed(.permissionDenied)
      $0.trees[worktree.id]?.expanded = []
    }

    shouldFail.setValue(false)
    await store.send(.directoryToggled("locked")) {
      $0.trees[worktree.id]?.expanded = ["locked"]
      $0.trees[worktree.id]?.directories["locked"] = FileExplorerFeature.DirectoryNode(
        status: .loading(previous: nil),
        requestedLimit: FileExplorerFeature.initialListingLimit
      )
    }
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories["locked"]?.status = .loaded(
        Self.listing([("inside.txt", isDirectory: false)])
      )
    }

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func listingLandingAfterWorktreeSwitchUpdatesCacheNotActiveTree() async {
    let worktreeA = Self.worktree(path: "/tmp/wt-a")
    let worktreeB = Self.worktree(path: "/tmp/wt-b")
    let slowListing = Self.listing([("from-a.txt", isDirectory: false)])
    let fastListing = Self.listing([("from-b.txt", isDirectory: false)])
    let gate = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { url, _ in
        guard url.path(percentEncoded: false).contains("wt-a") else { return fastListing }
        for await _ in gate.stream {}
        return slowListing
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktreeA), isVisible: true)
    )
    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktreeB), isVisible: true)
    )
    await store.receive(\.listingLoaded) {
      $0.trees[worktreeB.id]?.directories[""]?.status = .loaded(fastListing)
    }

    // A's slow root listing lands after the switch: cache updates, the active
    // tree stays B's.
    gate.continuation.finish()
    await store.receive(\.listingLoaded) {
      $0.trees[worktreeA.id]?.directories[""]?.status = .loaded(slowListing)
    }
    #expect(store.state.rootListing == fastListing)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func showMoreGrowsTheLimitAndReplacesTheListing() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let cappedListing = Self.listing([("a.txt", isDirectory: false)], totalCount: 3)
    let fullListing = Self.listing(
      [("a.txt", isDirectory: false), ("b.txt", isDirectory: false), ("c.txt", isDirectory: false)]
    )
    let requestedLimits = LockIsolated<[Int]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, limit in
        requestedLimits.withValue { $0.append(limit) }
        return limit > FileExplorerFeature.initialListingLimit ? fullListing : cappedListing
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories[""]?.status = .loaded(cappedListing)
    }

    await store.send(.showMoreTapped(directory: "")) {
      $0.trees[worktree.id]?.directories[""] = FileExplorerFeature.DirectoryNode(
        status: .loading(previous: cappedListing),
        requestedLimit: FileExplorerFeature.initialListingLimit + FileExplorerFeature.listingLimitStep
      )
    }
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories[""]?.status = .loaded(fullListing)
    }
    #expect(
      requestedLimits.value == [
        FileExplorerFeature.initialListingLimit,
        FileExplorerFeature.initialListingLimit + FileExplorerFeature.listingLimitStep,
      ]
    )

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func staleLimitListingIsDroppedAfterShowMore() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let cappedListing = Self.listing([("a.txt", isDirectory: false)], totalCount: 3)
    let fullListing = Self.listing(
      [("a.txt", isDirectory: false), ("b.txt", isDirectory: false), ("c.txt", isDirectory: false)],
      totalCount: 3
    )
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, limit in
        limit > FileExplorerFeature.initialListingLimit ? fullListing : cappedListing
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)
    await store.send(.showMoreTapped(directory: ""))
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories[""]?.status = .loaded(fullListing)
    }

    // A stale response carrying the pre-show-more limit must be dropped.
    await store.send(
      .listingLoaded(
        worktreeID: worktree.id,
        root: worktree.localWorkingDirectory!,
        directory: "",
        limit: FileExplorerFeature.initialListingLimit,
        result: .success(cappedListing)
      )
    )
    #expect(store.state.trees[worktree.id]?.directories[""]?.listing == fullListing)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func sweepRelistsOnlyDirectoriesWhoseMtimeMoved() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let baseline = Date(timeIntervalSince1970: 100)
    let rootListing = Self.listing(
      [("src", isDirectory: true), ("docs", isDirectory: true)],
      modificationDate: baseline
    )
    let srcListing = Self.listing([("old.swift", isDirectory: false)], modificationDate: baseline)
    let docsListing = Self.listing([("doc.md", isDirectory: false)], modificationDate: baseline)
    let srcListingAfter = Self.listing(
      [("old.swift", isDirectory: false), ("new.swift", isDirectory: false)],
      modificationDate: baseline.addingTimeInterval(60)
    )
    let clock = TestClock()
    let srcChanged = LockIsolated(false)
    let relistedNames = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileExplorerClient.list = { url, _ in
        relistedNames.withValue { $0.append(url.lastPathComponent) }
        switch url.lastPathComponent {
        case "src": return srcChanged.value ? srcListingAfter : srcListing
        case "docs": return docsListing
        default: return rootListing
        }
      }
      $0.fileExplorerClient.modificationDates = { urls in
        Dictionary(
          uniqueKeysWithValues: urls.map { url in
            let changed = srcChanged.value && url.lastPathComponent == "src"
            return (url, changed ? baseline.addingTimeInterval(60) : baseline)
          }
        )
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)
    await store.send(.directoryToggled("src"))
    await store.receive(\.listingLoaded)
    await store.send(.directoryToggled("docs"))
    await store.receive(\.listingLoaded)

    // Quiet tick: mtimes unchanged, nothing re-lists.
    await clock.advance(by: FileExplorerFeature.sweepInterval)
    await store.receive(\.sweepTicked)

    srcChanged.setValue(true)
    await clock.advance(by: FileExplorerFeature.sweepInterval)
    await store.receive(\.sweepTicked)
    await store.receive(\.sweepCompleted) {
      $0.trees[worktree.id]?.directories["src"]?.status = .loading(previous: srcListing)
    }
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories["src"]?.status = .loaded(srcListingAfter)
    }
    #expect(relistedNames.value.filter { $0 == "docs" }.count == 1)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func sweepDetectsBackwardMtimeChange() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let baseline = Date(timeIntervalSince1970: 100)
    let rootListing = Self.listing([("a.txt", isDirectory: false)], modificationDate: baseline)
    let restoredListing = Self.listing(
      [("old.txt", isDirectory: false)],
      modificationDate: baseline.addingTimeInterval(-60)
    )
    let restored = LockIsolated(false)
    let clock = TestClock()
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileExplorerClient.list = { _, _ in restored.value ? restoredListing : rootListing }
      $0.fileExplorerClient.modificationDates = { urls in
        Dictionary(
          uniqueKeysWithValues: urls.map {
            ($0, restored.value ? baseline.addingTimeInterval(-60) : baseline)
          }
        )
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)

    // A restore moves the mtime backward; the sweep must still re-list.
    restored.setValue(true)
    await clock.advance(by: FileExplorerFeature.sweepInterval)
    await store.receive(\.sweepTicked)
    await store.receive(\.sweepCompleted)
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories[""]?.status = .loaded(restoredListing)
    }

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func sweepCompletionForInactiveWorktreeIsDropped() async {
    let worktreeA = Self.worktree(path: "/tmp/wt-a")
    let worktreeB = Self.worktree(path: "/tmp/wt-b")
    let baseline = Date(timeIntervalSince1970: 100)
    let listing = Self.listing([("a.txt", isDirectory: false)], modificationDate: baseline)
    let gate = AsyncStream<Void>.makeStream()
    let clock = TestClock()
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.fileExplorerClient.modificationDates = { urls in
        for await _ in gate.stream {}
        return Dictionary(
          uniqueKeysWithValues: urls.map { ($0, baseline.addingTimeInterval(60)) }
        )
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktreeA), isVisible: true)
    )
    await store.receive(\.listingLoaded)
    await clock.advance(by: FileExplorerFeature.sweepInterval)
    await store.receive(\.sweepTicked)

    // Switch away while A's sweep stat is still in flight, then release it.
    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktreeB), isVisible: true)
    )
    await store.receive(\.listingLoaded)
    gate.continuation.finish()
    await store.receive(\.sweepCompleted)
    #expect(store.state.trees[worktreeA.id]?.directories[""]?.isLoading == false)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func sweepCompletionAfterHidingThePaneIsDropped() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let baseline = Date(timeIntervalSince1970: 100)
    let listing = Self.listing([("a.txt", isDirectory: false)], modificationDate: baseline)
    let gate = AsyncStream<Void>.makeStream()
    let clock = TestClock()
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.fileExplorerClient.modificationDates = { urls in
        for await _ in gate.stream {}
        return Dictionary(
          uniqueKeysWithValues: urls.map { ($0, baseline.addingTimeInterval(60)) }
        )
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)
    await clock.advance(by: FileExplorerFeature.sweepInterval)
    await store.receive(\.sweepTicked)

    // Hide while the stat pass is suspended, then release it.
    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: false)
    )
    gate.continuation.finish()
    await store.receive(\.sweepCompleted)
    #expect(store.state.trees[worktree.id]?.directories[""]?.isLoading == false)
  }

  @Test func evictedTreeInFlightListingCannotRepopulateARecreatedTree() async {
    let staleListing = Self.listing([("stale.txt", isDirectory: false)])
    let freshListing = Self.listing([("fresh.txt", isDirectory: false)])
    let gate = AsyncStream<Void>.makeStream()
    let firstEvictedCall = LockIsolated(true)
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { url, _ in
        guard url.path(percentEncoded: false).contains("wt-0") else { return Self.listing([]) }
        guard firstEvictedCall.value else { return freshListing }
        firstEvictedCall.setValue(false)
        for await _ in gate.stream {}
        return staleListing
      }
    }
    store.exhaustivity = .off

    let target = Self.worktree(path: "/tmp/wt-0")
    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: target), isVisible: true)
    )
    // Churn through enough worktrees to evict wt-0 while its listing hangs.
    for index in 1...FileExplorerFeature.cachedTreeLimit {
      await store.send(
        .contextChanged(
          FileExplorerFeature.Context(worktree: Self.worktree(path: "/tmp/wt-\(index)")),
          isVisible: true
        )
      )
    }
    #expect(store.state.trees[target.id] == nil)

    // Revisit: the recreated tree loads fresh; the released stale response
    // must not overwrite it, its effect died with the eviction.
    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: target), isVisible: true)
    )
    await store.receive(\.listingLoaded) {
      $0.trees[target.id]?.directories[""]?.status = .loaded(freshListing)
    }
    // The cancelled effect's send is a no-op, so nothing arrives to skip.
    gate.continuation.finish()
    #expect(store.state.trees[target.id]?.directories[""]?.listing == freshListing)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func refreshRelistsRootAndExpandedUnconditionally() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let baseline = Date(timeIntervalSince1970: 100)
    let rootListing = Self.listing(
      [("src", isDirectory: true), ("docs", isDirectory: true)],
      modificationDate: baseline
    )
    let srcListing = Self.listing([("main.swift", isDirectory: false)], modificationDate: baseline)
    let relistedNames = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { url, _ in
        relistedNames.withValue { $0.append(url.lastPathComponent) }
        return url.lastPathComponent == "src" ? srcListing : rootListing
      }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)
    // Expand src, then collapse it again: its cached listing must not refresh.
    await store.send(.directoryToggled("src"))
    await store.receive(\.listingLoaded)
    await store.send(.directoryToggled("src"))
    relistedNames.setValue([])

    // Unchanged mtimes; an explicit reload must re-list regardless.
    await store.send(.refreshRequested) {
      $0.trees[worktree.id]?.directories[""]?.status = .loading(previous: rootListing)
    }
    await store.receive(\.listingLoaded)
    #expect(relistedNames.value == ["wt-a"])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func remoteWorktreeGetsNoTreeAndNoEffects() async {
    let remote = Self.remoteWorktree()
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in
        Issue.record("listing must never run for a remote worktree")
        return FileExplorerListing(entries: [], totalCount: 0, modificationDate: nil)
      }
    }

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: remote), isVisible: true)
    ) {
      $0.isVisible = true
      $0.context = FileExplorerFeature.Context(worktree: remote)
    }
    #expect(store.state.context?.unavailabilityReason == .remote)
    #expect(store.state.trees.isEmpty)
  }

  @Test func hidingThePaneStopsTheSweepTimer() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let clock = TestClock()
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileExplorerClient.list = { _, _ in Self.listing([("a.txt", isDirectory: false)]) }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: false)
    )
    store.exhaustivity = .on
    // No sweep ticks arrive after hiding; an alive timer would surface as an
    // unexpected received action under exhaustive mode.
    await clock.advance(by: FileExplorerFeature.sweepInterval * 3)
  }

  @Test func cacheEvictsLeastRecentlyUsedTreeBeyondTheLimit() async {
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in Self.listing([]) }
    }
    store.exhaustivity = .off

    let worktrees = (0...FileExplorerFeature.cachedTreeLimit).map {
      Self.worktree(path: "/tmp/wt-\($0)")
    }
    for worktree in worktrees {
      await store.send(
        .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
      )
    }
    await store.skipReceivedActions()

    #expect(store.state.trees.count == FileExplorerFeature.cachedTreeLimit)
    #expect(store.state.trees[worktrees[0].id] == nil)
    #expect(store.state.trees[worktrees.last!.id] != nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func selectionClearsWhenTheSelectedEntryVanishes() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let before = Self.listing([("a.txt", isDirectory: false), ("b.txt", isDirectory: false)])
    let after = Self.listing([("b.txt", isDirectory: false)])
    let deleted = LockIsolated(false)
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in deleted.value ? after : before }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.receive(\.listingLoaded)
    await store.send(.rowSelected("a.txt"))

    deleted.setValue(true)
    await store.send(.refreshRequested)
    await store.receive(\.listingLoaded) {
      $0.trees[worktree.id]?.directories[""]?.status = .loaded(after)
      $0.trees[worktree.id]?.selectedPath = nil
    }

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func selectionIsRememberedPerWorktree() async {
    let worktreeA = Self.worktree(path: "/tmp/wt-a")
    let worktreeB = Self.worktree(path: "/tmp/wt-b")
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in Self.listing([("a.txt", isDirectory: false)]) }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktreeA), isVisible: true)
    )
    await store.send(.rowSelected("a.txt"))
    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktreeB), isVisible: true)
    )
    await store.skipReceivedActions()
    #expect(store.state.selectedPath == nil)

    // Re-activation of the cached tree emits nothing: nil-baseline listings
    // are exempt from the freshening sweep.
    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktreeA), isVisible: true)
    )
    #expect(store.state.selectedPath == "a.txt")

    await store.send(.contextChanged(nil, isVisible: false))
  }
}
