import AppKit
import Clocks
import ComposableArchitecture
import Foundation
import SwiftUI
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

  private nonisolated static func folderWorktree(path: String) -> Worktree {
    Worktree(
      location: .local(
        workingDirectory: URL(filePath: path, directoryHint: .isDirectory),
        repositoryRoot: URL(filePath: path, directoryHint: .isDirectory)
      ),
      kind: .folder,
      name: (path as NSString).lastPathComponent,
      detail: ""
    )
  }

  /// A porcelain-v2 ordinary record for an unstaged modification of `path`.
  private nonisolated static func modified(_ path: String) -> String {
    "1 .M N... 100644 100644 100644 1111111 2222222 \(path)"
  }

  /// A staged (index-side) modification of `path`.
  private nonisolated static func stagedModified(_ path: String) -> String {
    "1 M. N... 100644 100644 100644 1111111 2222222 \(path)"
  }

  /// A staged addition of `path` (new file, no HEAD version).
  private nonisolated static func stagedAdded(_ path: String) -> String {
    "1 A. N... 100644 100644 100644 1111111 2222222 \(path)"
  }

  private nonisolated static func conflicted(_ path: String) -> String {
    "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 \(path)"
  }

  private nonisolated static func stagedDeleted(_ path: String) -> String {
    "1 D. N... 100644 000000 000000 1111111 0000000 \(path)"
  }

  private nonisolated static func untracked(_ path: String) -> String { "? \(path)" }

  private nonisolated static func gitSnapshot(_ records: [String]) -> GitStatusSnapshot {
    GitStatusSnapshot.parse(porcelainV2: records.map { $0 + "\0" }.joined())
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

  // MARK: - Git status

  @Test func gitStatusLoadsWhenOpeningAGitWorktree() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let rootListing = Self.listing([("a.txt", isDirectory: false)])
    let snapshot = Self.gitSnapshot([Self.modified("a.txt")])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in rootListing }
      $0.gitClient.fileStatus = { _ in snapshot }
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
    await store.receive(\.gitStatusLoaded) {
      $0.trees[worktree.id]?.gitStatus = snapshot
    }

    await store.send(.contextChanged(nil, isVisible: false)) {
      $0.isVisible = false
      $0.context = nil
    }
  }

  @Test func gitStatusLoadedIsSkippedWhenUnchanged() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let rootListing = Self.listing([("a.txt", isDirectory: false)])
    let snapshot = Self.gitSnapshot([Self.modified("a.txt")])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in rootListing }
      $0.gitClient.fileStatus = { _ in snapshot }
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
    await store.receive(\.gitStatusLoaded) {
      $0.trees[worktree.id]?.gitStatus = snapshot
    }

    // Re-delivering the identical snapshot mutates nothing (diff-and-skip): the
    // exhaustive store fails here if the assignment isn't guarded.
    await store.send(
      .gitStatusLoaded(worktreeID: worktree.id, root: worktree.localWorkingDirectory!, snapshot)
    )

    await store.send(.contextChanged(nil, isVisible: false)) {
      $0.isVisible = false
      $0.context = nil
    }
  }

  @Test func gitStatusRefreshesOnSweepTick() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing(
      [("a.txt", isDirectory: false), ("b.txt", isDirectory: false)],
      modificationDate: Date(timeIntervalSince1970: 0)
    )
    let first = Self.gitSnapshot([Self.modified("a.txt")])
    let second = Self.gitSnapshot([Self.modified("a.txt"), Self.modified("b.txt")])
    let current = LockIsolated(first)
    let clock = TestClock()
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileExplorerClient.list = { _, _ in listing }
      // Stable mtime so the sweep re-list stays quiet and only status refreshes.
      $0.fileExplorerClient.modificationDates = { urls in
        Dictionary(uniqueKeysWithValues: urls.map { ($0, Date(timeIntervalSince1970: 0)) })
      }
      $0.gitClient.fileStatus = { _ in current.value }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.skipReceivedActions()
    #expect(store.state.trees[worktree.id]?.gitStatus == first)

    current.setValue(second)
    await clock.advance(by: .seconds(5))
    await store.skipReceivedActions()
    #expect(store.state.trees[worktree.id]?.gitStatus == second)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func gitStatusProbeFailureKeepsLastGoodSnapshot() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing(
      [("a.txt", isDirectory: false)],
      modificationDate: Date(timeIntervalSince1970: 0)
    )
    let good = Self.gitSnapshot([Self.modified("a.txt")])
    let probe = LockIsolated<GitStatusSnapshot?>(good)
    let clock = TestClock()
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.fileExplorerClient.modificationDates = { urls in
        Dictionary(uniqueKeysWithValues: urls.map { ($0, Date(timeIntervalSince1970: 0)) })
      }
      $0.gitClient.fileStatus = { _ in probe.value }
    }
    store.exhaustivity = .off

    await store.send(
      .contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true)
    )
    await store.skipReceivedActions()
    #expect(store.state.trees[worktree.id]?.gitStatus == good)

    // A failing probe returns nil, which sends no action, so the last-good
    // snapshot survives rather than the tree flashing clean.
    probe.setValue(nil)
    await clock.advance(by: .seconds(5))
    await store.skipReceivedActions()
    #expect(store.state.trees[worktree.id]?.gitStatus == good)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func folderWorktreeGetsNoGitStatus() async {
    let worktree = Self.folderWorktree(path: "/tmp/folder")
    let rootListing = Self.listing([("a.txt", isDirectory: false)])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in rootListing }
      // Configured to decorate, so a missing gate (not the nil default) is what
      // keeps a folder-kind worktree undecorated.
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.modified("a.txt")]) }
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
    // No `gitStatusLoaded` follows: the exhaustive store would fail teardown if
    // the folder-kind gate hadn't skipped the probe.
    #expect(store.state.trees[worktree.id]?.gitStatus == .empty)

    await store.send(.contextChanged(nil, isVisible: false)) {
      $0.isVisible = false
      $0.context = nil
    }
  }

  // MARK: - Git mutations

  @Test func stagingAModifiedFileRunsStageThenRefreshes() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let unstaged = Self.gitSnapshot([Self.modified("a.txt")])
    let staged = Self.gitSnapshot([Self.stagedModified("a.txt")])
    let current = LockIsolated(unstaged)
    let stageCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in current.value }
      $0.gitClient.stageFile = { path, _ in
        stageCalls.withValue { $0.append(path) }
        current.setValue(staged)
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()
    #expect(store.state.trees[worktree.id]?.gitStatus == unstaged)

    await store.send(.stageToggled(path: "a.txt"))
    await store.skipReceivedActions()
    #expect(stageCalls.value == ["a.txt"])
    // The post-mutation re-status reflects the now-staged file.
    #expect(store.state.trees[worktree.id]?.gitStatus == staged)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func stageToggleUnstagesAnAlreadyStagedFile() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let staged = Self.gitSnapshot([Self.stagedModified("a.txt")])
    let unstageCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in staged }
      $0.gitClient.unstageFile = { path, _ in unstageCalls.withValue { $0.append(path) } }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.stageToggled(path: "a.txt"))
    await store.skipReceivedActions()
    #expect(unstageCalls.value == ["a.txt"])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func discardingATrackedFileConfirmsThenRestores() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let discardCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.modified("a.txt")]) }
      $0.gitClient.discardFile = { path, _, tracked in
        discardCalls.withValue { $0.append("\(path):\(tracked)") }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.discardRequested(path: "a.txt"))
    #expect(store.state.alert?.title == TextState("Discard changes to \"a.txt\"?"))

    await store.send(.alert(.presented(.confirmDiscard(worktreeID: worktree.id, path: "a.txt", tracked: true))))
    await store.skipReceivedActions()
    #expect(discardCalls.value == ["a.txt:true"])
    #expect(store.state.alert == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func discardingAnUntrackedFileOffersMoveToTrash() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let discardCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.untracked("a.txt")]) }
      $0.gitClient.discardFile = { path, _, tracked in
        discardCalls.withValue { $0.append("\(path):\(tracked)") }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.discardRequested(path: "a.txt"))
    // Untracked discard is a Trash move, and the confirm routes tracked: false.
    #expect(store.state.alert?.title == TextState("Move \"a.txt\" to the Trash?"))

    await store.send(.alert(.presented(.confirmDiscard(worktreeID: worktree.id, path: "a.txt", tracked: false))))
    await store.skipReceivedActions()
    #expect(discardCalls.value == ["a.txt:false"])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func discardingAGitRmCachedFileRestoresRatherThanTrashing() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("f.txt", isDirectory: false)])
    let discardCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      // `git rm --cached f.txt`: staged deletion plus an untracked working copy.
      $0.gitClient.fileStatus = { _ in
        Self.gitSnapshot([Self.stagedDeleted("f.txt"), Self.untracked("f.txt")])
      }
      $0.gitClient.discardFile = { path, _, tracked in
        discardCalls.withValue { $0.append("\(path):\(tracked)") }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    // It still has a committed version, so discard restores it rather than
    // trashing the working copy.
    await store.send(.discardRequested(path: "f.txt"))
    #expect(store.state.alert?.title == TextState("Discard changes to \"f.txt\"?"))

    await store.send(.alert(.presented(.confirmDiscard(worktreeID: worktree.id, path: "f.txt", tracked: true))))
    await store.skipReceivedActions()
    #expect(discardCalls.value == ["f.txt:true"])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func cancellingDiscardRunsNothing() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let discardCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.modified("a.txt")]) }
      $0.gitClient.discardFile = { path, _, tracked in
        discardCalls.withValue { $0.append("\(path):\(tracked)") }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.discardRequested(path: "a.txt"))
    #expect(store.state.alert != nil)
    await store.send(.alert(.dismiss))
    #expect(store.state.alert == nil)
    #expect(discardCalls.value.isEmpty)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func aLockedMutationSurfacesAnAlert() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.modified("a.txt")]) }
      $0.gitClient.stageFile = { _, _ in
        throw GitClientError.commandFailed(
          command: "git add",
          message: "fatal: Unable to create '.git/index.lock': File exists"
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.stageToggled(path: "a.txt"))
    await store.skipReceivedActions()
    #expect(store.state.alert?.title == TextState("Couldn't update \"a.txt\""))

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func nonLockFailureSurfacesTheGenericAlert() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.modified("a.txt")]) }
      $0.gitClient.stageFile = { _, _ in
        throw GitClientError.commandFailed(command: "git add", message: "fatal: pathspec did not match")
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.stageToggled(path: "a.txt"))
    await store.skipReceivedActions()
    #expect(store.state.alert?.title == TextState("Couldn't update \"a.txt\""))
    #expect(store.state.alert?.message == TextState("The operation couldn't be completed."))

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func conflictedFileBlocksStageAndDiscard() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let mutations = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.conflicted("a.txt")]) }
      $0.gitClient.stageFile = { path, _ in mutations.withValue { $0.append("stage:\(path)") } }
      $0.gitClient.unstageFile = { path, _ in mutations.withValue { $0.append("unstage:\(path)") } }
      $0.gitClient.discardFile = { path, _, _ in mutations.withValue { $0.append("discard:\(path)") } }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    // A conflicted file must not stage (which would silently bake in the
    // conflict markers) or discard: both guard out with no effect.
    await store.send(.stageToggled(path: "a.txt"))
    await store.send(.discardRequested(path: "a.txt"))
    #expect(mutations.value.isEmpty)
    #expect(store.state.alert == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func stagingAnUntrackedFileStagesRatherThanUnstages() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let stageCalls = LockIsolated<[String]>([])
    let unstageCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.untracked("a.txt")]) }
      $0.gitClient.stageFile = { path, _ in stageCalls.withValue { $0.append(path) } }
      $0.gitClient.unstageFile = { path, _ in unstageCalls.withValue { $0.append(path) } }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.stageToggled(path: "a.txt"))
    await store.skipReceivedActions()
    #expect(stageCalls.value == ["a.txt"])
    #expect(unstageCalls.value.isEmpty)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func discardingAStagedAdditionOffersMoveToTrash() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let discardCalls = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([Self.stagedAdded("a.txt")]) }
      $0.gitClient.discardFile = { path, _, tracked in
        discardCalls.withValue { $0.append("\(path):\(tracked)") }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    // A staged addition has no HEAD version, so discarding it is a Trash move,
    // not a restore.
    await store.send(.discardRequested(path: "a.txt"))
    #expect(store.state.alert?.title == TextState("Move \"a.txt\" to the Trash?"))

    await store.send(.alert(.presented(.confirmDiscard(worktreeID: worktree.id, path: "a.txt", tracked: false))))
    await store.skipReceivedActions()
    #expect(discardCalls.value == ["a.txt:false"])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func staleGitFailureFromAnotherWorktreeDoesNotAlert() async {
    let worktreeA = Self.worktree(path: "/tmp/wt-a")
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in Self.listing([("a.txt", isDirectory: false)]) }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
    }
    store.exhaustivity = .off
    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktreeA), isVisible: true))
    await store.skipReceivedActions()

    let error = GitOperationError(path: "a.txt", kind: .failed)
    // A failure from a worktree the user already left must not alert over the
    // now-active inspector.
    await store.send(.gitOperationCompleted(worktreeID: Worktree.ID("/tmp/wt-b"), .failure(error)))
    #expect(store.state.alert == nil)

    // The active worktree's failure still alerts.
    await store.send(.gitOperationCompleted(worktreeID: worktreeA.id, .failure(error)))
    #expect(store.state.alert != nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func movingFilesWithoutCollisionTransfersThenRefreshes() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let transfers = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in [] }
      $0.fileExplorerClient.transfer = { _, _, name, operation, policy in
        transfers.withValue { $0.append("\(name):\(operation):\(policy)") }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/new.txt")], destinationDirectory: "", operation: .move))
    await store.skipReceivedActions()
    // No collision, so it transfers straight through with the abort backstop.
    #expect(transfers.value == ["new.txt:move:abort"])
    #expect(store.state.alert == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func movingOntoACollisionPromptsThenKeepBoth() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let policies = LockIsolated<[FileConflictPolicy]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in ["a.txt"] }
      $0.fileExplorerClient.transfer = { _, _, _, _, policy in
        policies.withValue { $0.append(policy) }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/a.txt")], destinationDirectory: "", operation: .move))
    await store.skipReceivedActions()
    // The collision surfaces a prompt rather than transferring.
    #expect(store.state.alert?.title == TextState("\"a.txt\" already exists"))
    #expect(policies.value.isEmpty)

    let plan = FileExplorerFeature.FileTransferPlan(
      worktreeID: worktree.id, sources: [URL(filePath: "/tmp/drop/a.txt")], destinationDirectory: "", operation: .move
    )
    await store.send(.alert(.presented(.resolveTransfer(plan, policy: .keepBoth))))
    await store.skipReceivedActions()
    #expect(policies.value == [.keepBoth])
    #expect(store.state.alert == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func replacingOnCollisionOverwrites() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let policies = LockIsolated<[FileConflictPolicy]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in ["a.txt"] }
      $0.fileExplorerClient.transfer = { _, _, _, _, policy in
        policies.withValue { $0.append(policy) }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    // Present the collision prompt, then replace.
    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/a.txt")], destinationDirectory: "", operation: .move))
    await store.skipReceivedActions()
    #expect(store.state.alert != nil)

    let plan = FileExplorerFeature.FileTransferPlan(
      worktreeID: worktree.id, sources: [URL(filePath: "/tmp/drop/a.txt")], destinationDirectory: "", operation: .move
    )
    await store.send(.alert(.presented(.resolveTransfer(plan, policy: .overwrite))))
    await store.skipReceivedActions()
    #expect(policies.value == [.overwrite])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func switchingWorktreeAbortsAPendingTransferResolution() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let other = Self.worktree(path: "/tmp/wt-b")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let transferRan = LockIsolated(false)
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in ["a.txt"] }
      $0.fileExplorerClient.transfer = { _, _, _, _, _ in
        transferRan.setValue(true)
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()
    // Raise the collision prompt on wt-a, then switch worktrees under it.
    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/a.txt")], destinationDirectory: "", operation: .move))
    await store.skipReceivedActions()
    #expect(store.state.alert != nil)
    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: other), isVisible: true))
    await store.skipReceivedActions()

    // Resolving the stale plan bound to wt-a must not write into the new worktree.
    let stalePlan = FileExplorerFeature.FileTransferPlan(
      worktreeID: worktree.id, sources: [URL(filePath: "/tmp/drop/a.txt")], destinationDirectory: "", operation: .move
    )
    // The guard aborts with no effect, so nothing is received to skip.
    await store.send(.alert(.presented(.resolveTransfer(stalePlan, policy: .overwrite))))
    #expect(transferRan.value == false)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func renamingAFileMovesItThenRefreshes() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let renames = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.rename = { source, newName in
        renames.withValue { $0.append("\(source.lastPathComponent)->\(newName)") }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.renameRequested(path: "a.txt", newName: "  b.txt  "))
    await store.skipReceivedActions()
    // The new name is trimmed before the rename lands.
    #expect(renames.value == ["a.txt->b.txt"])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func renamingToTheSameOrEmptyNameRunsNothing() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let renames = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.rename = { _, newName in renames.withValue { $0.append(newName) } }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    // Each is a no-op that issues no effect, so there is nothing to skip.
    await store.send(.renameRequested(path: "a.txt", newName: "a.txt"))
    await store.send(.renameRequested(path: "a.txt", newName: "   "))
    await store.send(.renameRequested(path: "a.txt", newName: "bad/name.txt"))
    #expect(renames.value.isEmpty)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func uniqueNameAppendsCopyThenCounts() {
    var taken: Set<String> = ["a.txt"]
    #expect(FileExplorerClient.uniqueName(for: "a.txt", isTaken: { taken.contains($0) }) == "a copy.txt")
    taken.insert("a copy.txt")
    #expect(FileExplorerClient.uniqueName(for: "a.txt", isTaken: { taken.contains($0) }) == "a copy 2.txt")
    #expect(FileExplorerClient.uniqueName(for: "fresh.txt", isTaken: { taken.contains($0) }) == "fresh.txt")
    // An extension-less name (folder or dotfile) keeps the suffix at the end.
    #expect(FileExplorerClient.uniqueName(for: "folder", isTaken: { $0 == "folder" }) == "folder copy")
    #expect(FileExplorerClient.uniqueName(for: ".env", isTaken: { $0 == ".env" }) == ".env copy")
  }

  @Test func relativePathResolvesUnderRootAndNilsOutside() {
    let root = URL(filePath: "/tmp/wt-a", directoryHint: .isDirectory)
    #expect(FileExplorerFeature.relativePath(of: root, under: root) == "")
    #expect(FileExplorerFeature.relativePath(of: URL(filePath: "/tmp/wt-a/src/a.txt"), under: root) == "src/a.txt")
    // A directory URL (trailing slash) resolves to the same slash-free key.
    let srcDir = URL(filePath: "/tmp/wt-a/src", directoryHint: .isDirectory)
    #expect(FileExplorerFeature.relativePath(of: srcDir, under: root) == "src")
    #expect(FileExplorerFeature.relativePath(of: URL(filePath: "/tmp/other/x.txt"), under: root) == nil)
    // A sibling sharing a name prefix is not under the root.
    #expect(FileExplorerFeature.relativePath(of: URL(filePath: "/tmp/wt-a-backup/x"), under: root) == nil)
  }

  @Test func duplicateNamesWithinABatchPromptForConflict() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      // The destination is clear; the clash is between the two sources.
      $0.fileExplorerClient.existingNames = { _, _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/x/a.txt"), URL(filePath: "/tmp/y/a.txt")],
        destinationDirectory: "", operation: .copy
      )
    )
    await store.skipReceivedActions()
    #expect(store.state.alert?.title == TextState("\"a.txt\" already exists"))

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func pastingThreadsCopyThroughTheTransfer() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([])
    let operations = LockIsolated<[FileTransferOperation]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in [] }
      $0.fileExplorerClient.transfer = { _, _, _, operation, _ in
        operations.withValue { $0.append(operation) }
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/x.txt")], destinationDirectory: "", operation: .copy))
    await store.skipReceivedActions()
    #expect(operations.value == [.copy])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func movingAnInternalFileRefreshesBothDestinationAndOldParent() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let root = Self.listing([("src", isDirectory: true), ("docs", isDirectory: true)])
    let src = Self.listing([("a.txt", isDirectory: false)])
    let docs = Self.listing([])
    let relisted = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { url, _ in
        relisted.withValue { $0.append(url.lastPathComponent) }
        switch url.lastPathComponent {
        case "src": return src
        case "docs": return docs
        default: return root
        }
      }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in [] }
      $0.fileExplorerClient.transfer = { _, _, _, _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()
    await store.send(.directoryToggled("src"))
    await store.skipReceivedActions()
    await store.send(.directoryToggled("docs"))
    await store.skipReceivedActions()
    relisted.setValue([])

    // Moving an internal file empties its origin and fills the destination, so
    // both directories must re-list.
    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/wt-a/src/a.txt")], destinationDirectory: "docs", operation: .move
      )
    )
    await store.skipReceivedActions()
    #expect(Set(relisted.value) == ["src", "docs"])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func aFailedFileTransferSurfacesTheFailureAlert() async {
    struct TransferError: Error {}
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in [] }
      $0.fileExplorerClient.transfer = { _, _, _, _, _ in throw TransferError() }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/new.txt")], destinationDirectory: "", operation: .move))
    await store.skipReceivedActions()
    #expect(store.state.alert?.title == TextState("The operation couldn't be completed"))

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func aFailedRenameSurfacesTheFailureAlert() async {
    struct RenameError: Error {}
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.rename = { _, _ in throw RenameError() }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.renameRequested(path: "a.txt", newName: "b.txt"))
    await store.skipReceivedActions()
    #expect(store.state.alert?.title == TextState("The operation couldn't be completed"))

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func directoryCollisionOffersMergeAndThreadsItThrough() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("src", isDirectory: true)])
    let policies = LockIsolated<[FileConflictPolicy]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in ["src"] }
      $0.fileExplorerClient.mergeableNames = { _, _ in ["src"] }
      $0.fileExplorerClient.transfer = { _, _, _, _, policy in policies.withValue { $0.append(policy) } }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/src")], destinationDirectory: "", operation: .copy))
    await store.skipReceivedActions()
    // A directory-onto-directory collision offers Merge.
    #expect(store.state.alert?.buttons.contains { $0.label == TextState("Merge") } == true)

    let plan = FileExplorerFeature.FileTransferPlan(
      worktreeID: worktree.id, sources: [URL(filePath: "/tmp/drop/src")], destinationDirectory: "", operation: .copy
    )
    await store.send(.alert(.presented(.resolveTransfer(plan, policy: .merge))))
    await store.skipReceivedActions()
    #expect(policies.value == [.merge])

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func fileCollisionDoesNotOfferMerge() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in ["a.txt"] }
      $0.fileExplorerClient.mergeableNames = { _, _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/a.txt")], destinationDirectory: "", operation: .copy))
    await store.skipReceivedActions()
    #expect(store.state.alert?.buttons.contains { $0.label == TextState("Merge") } == false)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func mixedDirectoryAndFileCollisionDoesNotOfferMerge() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("src", isDirectory: true), ("a.txt", isDirectory: false)])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.existingNames = { _, _ in ["src", "a.txt"] }
      // Only the directory is mergeable; the file is not.
      $0.fileExplorerClient.mergeableNames = { _, _ in ["src"] }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/drop/src"), URL(filePath: "/tmp/drop/a.txt")],
        destinationDirectory: "", operation: .copy
      )
    )
    await store.skipReceivedActions()
    // Merge would silently replace the file collision, so it is not offered.
    #expect(store.state.alert?.buttons.contains { $0.label == TextState("Merge") } == false)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func pastingADirectoryIntoItsOwnSubtreeIsRejected() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let root = Self.listing([("src", isDirectory: true)])
    let transferRan = LockIsolated(false)
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in root }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.transfer = { _, _, _, _, _ in transferRan.setValue(true) }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    // Pasting /tmp/wt-a/src into src itself would copy a folder inside itself,
    // so it is dropped with no effect (nothing to skip).
    await store.send(
      .filesTransferRequested(
        sources: [URL(filePath: "/tmp/wt-a/src", directoryHint: .isDirectory)],
        destinationDirectory: "src", operation: .copy
      )
    )
    #expect(transferRan.value == false)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func mergeFoldsDirectoriesKeepingExistingOnlyEntries() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(
      path: "supacode-merge-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? manager.removeItem(at: root) }
    let source = root.appending(path: "src", directoryHint: .isDirectory)
    let destination = root.appending(path: "dst", directoryHint: .isDirectory)
    let merged = destination.appending(path: "src", directoryHint: .isDirectory)

    try manager.createDirectory(at: source.appending(path: "sub"), withIntermediateDirectories: true)
    try "new".write(to: source.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
    try "n".write(to: source.appending(path: "only-new.txt"), atomically: true, encoding: .utf8)
    try "d".write(to: source.appending(path: "sub/deep.txt"), atomically: true, encoding: .utf8)

    try manager.createDirectory(at: merged.appending(path: "sub"), withIntermediateDirectories: true)
    try "old".write(to: merged.appending(path: "shared.txt"), atomically: true, encoding: .utf8)
    try "o".write(to: merged.appending(path: "only-old.txt"), atomically: true, encoding: .utf8)
    try "k".write(to: merged.appending(path: "sub/kept.txt"), atomically: true, encoding: .utf8)

    try FileExplorerClient.performTransfer(
      source: source, directory: destination, name: "src", operation: .copy, policy: .merge
    )

    // Same-named files take the new content; existing-only entries survive; subfolders recurse.
    #expect(try String(contentsOf: merged.appending(path: "shared.txt"), encoding: .utf8) == "new")
    #expect(manager.fileExists(atPath: merged.appending(path: "only-new.txt").path(percentEncoded: false)))
    #expect(manager.fileExists(atPath: merged.appending(path: "only-old.txt").path(percentEncoded: false)))
    #expect(manager.fileExists(atPath: merged.appending(path: "sub/kept.txt").path(percentEncoded: false)))
    #expect(manager.fileExists(atPath: merged.appending(path: "sub/deep.txt").path(percentEncoded: false)))
  }

  @Test func performTransferRefusesCopyingADirectoryIntoItsOwnSubtree() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(
      path: "supacode-subtree-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? manager.removeItem(at: root) }
    let source = root.appending(path: "src", directoryHint: .isDirectory)
    let inner = source.appending(path: "inner", directoryHint: .isDirectory)
    try manager.createDirectory(at: inner, withIntermediateDirectories: true)

    // Copying src into its own descendant src/inner is refused, not recursed.
    try FileExplorerClient.performTransfer(
      source: source, directory: inner, name: "src", operation: .copy, policy: .abort
    )
    #expect(!manager.fileExists(atPath: inner.appending(path: "src").path(percentEncoded: false)))
  }

  @Test func trashingAFileConfirmsThenMovesItToTrash() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let trashed = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.moveToTrash = { url in trashed.withValue { $0.append(url.lastPathComponent) } }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.trashRequested(path: "a.txt"))
    #expect(store.state.alert?.title == TextState("Move \"a.txt\" to the Trash?"))

    await store.send(.alert(.presented(.confirmTrash(worktreeID: worktree.id, path: "a.txt"))))
    await store.skipReceivedActions()
    #expect(trashed.value == ["a.txt"])
    #expect(store.state.alert == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func creatingAFolderRefreshesAndMarksItForRename() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let created = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      // The relist after creation sees the new folder, mirroring the real disk.
      $0.fileExplorerClient.list = { _, _ in
        created.value.isEmpty ? Self.listing([]) : Self.listing([("Untitled Folder", isDirectory: true)])
      }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.createItem = { _, name, isDirectory in
        created.withValue { $0.append("\(name):\(isDirectory)") }
        return name
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.createItemRequested(directory: "", isDirectory: true))
    await store.skipReceivedActions()
    #expect(created.value == ["Untitled Folder:true"])
    // The new entry is selected and flagged for an inline rename.
    #expect(store.state.trees[worktree.id]?.selectedPath == "Untitled Folder")
    #expect(store.state.trees[worktree.id]?.pendingRename == "Untitled Folder")

    await store.send(.pendingRenameConsumed)
    #expect(store.state.trees[worktree.id]?.pendingRename == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func createItemMakesUniqueDefaultNames() async throws {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory.appending(
      path: "supacode-create-\(UUID().uuidString)", directoryHint: .isDirectory)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    let client = FileExplorerClient.liveValue

    let first = try await client.createItem(directory, "Untitled", false)
    let second = try await client.createItem(directory, "Untitled", false)
    #expect(first == "Untitled")
    #expect(second == "Untitled copy")
    #expect(manager.fileExists(atPath: directory.appending(path: "Untitled").path(percentEncoded: false)))
    #expect(manager.fileExists(atPath: directory.appending(path: "Untitled copy").path(percentEncoded: false)))
  }

  @Test func creatingAFileNamesItUntitledAndMarksItForRename() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let created = LockIsolated<[String]>([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in
        created.value.isEmpty ? Self.listing([]) : Self.listing([("Untitled", isDirectory: false)])
      }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.createItem = { _, name, isDirectory in
        created.withValue { $0.append("\(name):\(isDirectory)") }
        return name
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.createItemRequested(directory: "", isDirectory: false))
    await store.skipReceivedActions()
    #expect(created.value == ["Untitled:false"])
    #expect(store.state.trees[worktree.id]?.pendingRename == "Untitled")

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func creatingInsideACollapsedFolderLoadsItSoTheNewRowAppears() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let created = LockIsolated(false)
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { url, _ in
        switch url.lastPathComponent {
        case "src": return created.value ? Self.listing([("Untitled Folder", isDirectory: true)]) : Self.listing([])
        default: return Self.listing([("src", isDirectory: true)])
        }
      }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.createItem = { _, name, _ in
        created.setValue(true)
        return name
      }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()
    // "src" is never expanded, so it has no directory node yet.
    #expect(store.state.trees[worktree.id]?.directories["src"] == nil)

    await store.send(.createItemRequested(directory: "src", isDirectory: true))
    await store.skipReceivedActions()
    // The create forces a load of the collapsed folder, so the new row lands.
    #expect(store.state.trees[worktree.id]?.expanded.contains("src") == true)
    #expect(store.state.trees[worktree.id]?.directories["src"]?.listing != nil)
    #expect(store.state.trees[worktree.id]?.pendingRename == "src/Untitled Folder")

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func pendingRenameClearsWhenTheCreatedRowIsMissingFromTheListing() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      // The relist never contains the created item (as if it fell beyond a cap).
      $0.fileExplorerClient.list = { _, _ in Self.listing([("other.txt", isDirectory: false)]) }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.createItem = { _, name, _ in name }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.createItemRequested(directory: "", isDirectory: true))
    await store.skipReceivedActions()
    // The new row never appears, so its pending rename must not linger.
    #expect(store.state.trees[worktree.id]?.pendingRename == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func creatingAnItemFailureAlertsAndLeavesNoPendingRename() async {
    struct CreateError: Error {}
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.createItem = { _, _, _ in throw CreateError() }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()

    await store.send(.createItemRequested(directory: "", isDirectory: true))
    await store.skipReceivedActions()
    #expect(store.state.alert?.title == TextState("The operation couldn't be completed"))
    #expect(store.state.trees[worktree.id]?.pendingRename == nil)
    #expect(store.state.trees[worktree.id]?.selectedPath == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func itemCreatedForInactiveWorktreeIsIgnored() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let other = Self.worktree(path: "/tmp/wt-b")
    let listing = Self.listing([])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()
    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: other), isVisible: true))
    await store.skipReceivedActions()

    // A create result for the now-inactive wt-a must not touch either tree.
    await store.send(.itemCreated(worktreeID: worktree.id, directory: "", .success("Untitled Folder")))
    #expect(store.state.trees[worktree.id]?.pendingRename == nil)
    #expect(store.state.trees[other.id]?.pendingRename == nil)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func switchingWorktreeAbortsAPendingTrash() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let other = Self.worktree(path: "/tmp/wt-b")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let trashRan = LockIsolated(false)
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in Self.gitSnapshot([]) }
      $0.fileExplorerClient.moveToTrash = { _ in trashRan.setValue(true) }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()
    await store.send(.trashRequested(path: "a.txt"))
    #expect(store.state.alert != nil)
    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: other), isVisible: true))
    await store.skipReceivedActions()

    // The stale confirmation bound to wt-a must not trash into wt-b.
    await store.send(.alert(.presented(.confirmTrash(worktreeID: worktree.id, path: "a.txt"))))
    #expect(trashRan.value == false)

    await store.send(.contextChanged(nil, isVisible: false))
  }

  @Test func performTransferRefusesACopyThroughASymlinkedPrefix() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(
      path: "supacode-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? manager.removeItem(at: root) }
    let source = root.appending(path: "src", directoryHint: .isDirectory)
    let inner = source.appending(path: "inner", directoryHint: .isDirectory)
    try manager.createDirectory(at: inner, withIntermediateDirectories: true)
    // A symlink to src: pasting src into link/inner resolves to src's own subtree.
    let link = root.appending(path: "link")
    try manager.createSymbolicLink(at: link, withDestinationURL: source)

    try FileExplorerClient.performTransfer(
      source: source, directory: link.appending(path: "inner", directoryHint: .isDirectory),
      name: "src", operation: .copy, policy: .abort
    )
    #expect(!manager.fileExists(atPath: inner.appending(path: "src").path(percentEncoded: false)))
  }

  @Test func listDirectoryFollowsASymlinkedDirectory() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(
      path: "supacode-linklist-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? manager.removeItem(at: root) }
    let target = root.appending(path: "target", directoryHint: .isDirectory)
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    try Data().write(to: target.appending(path: "a.txt"))
    // `contentsOfDirectory(at:)` throws ENOTDIR on the link itself, so a linked
    // folder must resolve to its target to list rather than fail as unreadable.
    let link = root.appending(path: "link", directoryHint: .isDirectory)
    try manager.createSymbolicLink(at: link, withDestinationURL: target)

    let listing = try FileExplorerClient.listDirectory(at: link, limit: 100)
    #expect(listing.entries.map(\.name) == ["a.txt"])
  }

  @Test func listDirectoryFlagsSymlinkEntries() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appending(
      path: "supacode-linkflag-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? manager.removeItem(at: root) }
    let target = root.appending(path: "target", directoryHint: .isDirectory)
    try manager.createDirectory(at: target, withIntermediateDirectories: true)
    try Data().write(to: root.appending(path: "plain.txt"))
    // A link to a directory reads as an expandable, alias-flagged row.
    try manager.createSymbolicLink(
      at: root.appending(path: "dirlink"), withDestinationURL: target)

    let entries = try FileExplorerClient.listDirectory(at: root, limit: 100).entries
    let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    #expect(byName["dirlink"]?.isSymbolicLink == true)
    #expect(byName["dirlink"]?.isDirectory == true)
    #expect(byName["plain.txt"]?.isSymbolicLink == false)
  }

  @Test func gitStatusLoadedWithStaleRootIsDropped() async {
    let worktree = Self.worktree(path: "/tmp/wt-a")
    let listing = Self.listing([("a.txt", isDirectory: false)])
    let fresh = Self.gitSnapshot([Self.modified("a.txt")])
    let store = TestStore(initialState: FileExplorerFeature.State()) {
      FileExplorerFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.fileExplorerClient.list = { _, _ in listing }
      $0.gitClient.fileStatus = { _ in fresh }
    }
    store.exhaustivity = .off

    await store.send(.contextChanged(FileExplorerFeature.Context(worktree: worktree), isVisible: true))
    await store.skipReceivedActions()
    #expect(store.state.trees[worktree.id]?.gitStatus == fresh)

    // A probe that lands for a different root (a re-rooted or switched tree) is
    // dropped rather than overwriting the current snapshot.
    let stale = Self.gitSnapshot([Self.modified("z.txt")])
    await store.send(
      .gitStatusLoaded(worktreeID: worktree.id, root: URL(filePath: "/tmp/other"), stale)
    )
    #expect(store.state.trees[worktree.id]?.gitStatus == fresh)

    await store.send(.contextChanged(nil, isVisible: false))
  }
}

/// The file explorer draws with AppKit, so it reimplements the chrome scale for
/// `NSFont`. These pin it to the SwiftUI `AppFontMetrics` math it must match.
struct FileExplorerCellFontTests {
  @Test(arguments: [ChromeTextSize.large, .extraLarge])
  func labelSizeMatchesTheSwiftUIChromeScale(_ size: ChromeTextSize) {
    #expect(
      FileExplorerCellFont.label(size).pointSize
        == AppFontMetrics.scaledPointSize(for: .body, size: size)
    )
  }

  @Test func standardKeepsTheExactPreferredFonts() {
    #expect(FileExplorerCellFont.label(.standard) == NSFont.preferredFont(forTextStyle: .body))
    #expect(FileExplorerCellFont.scaled(.callout, .standard) == NSFont.preferredFont(forTextStyle: .callout))
    #expect(
      FileExplorerCellFont.badge(.standard, weight: .regular)
        == .monospacedSystemFont(
          ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    )
  }
}
