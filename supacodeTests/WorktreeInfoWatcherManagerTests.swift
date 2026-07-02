import Clocks
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct WorktreeInfoWatcherManagerTests {
  @Test func emitsLineChangesImmediatelyOnInitialWorktreeLoad() async throws {
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))

    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func defersLineChangesForWorktreesAddedAfterInitialLoad() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: firstWorktree.id) == 1)

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func buildsWorktreeLookupWithoutTrappingOnDuplicateID() async throws {
    // Two entries sharing one WorktreeID must not trap; the first entry wins.
    let tempWorktree = try makeTempWorktree()
    let duplicate = Worktree(
      id: tempWorktree.worktree.id,
      name: "eagle-duplicate",
      detail: "duplicate",
      workingDirectory: tempWorktree.worktree.workingDirectory,
      repositoryRootURL: tempWorktree.worktree.repositoryRootURL
    )
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree, duplicate]))

    await drainAsyncEvents(120)
    // The manager initialized and the single de-duplicated worktree is watched.
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func emitsBranchChangedForRemoteWorktreeWhenHeadChanges() async throws {
    let clock = TestClock()
    let stub = RemoteBranchPollStub(responses: ["main", "feature"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(500),
      unfocusedInterval: .milliseconds(500),
      clock: clock,
      pollRemoteBranch: { _ in await stub.next() }
    )
    let (collector, task) = startCollecting(manager.eventStream())
    let remote = makeRemoteWorktree(name: "remote-eagle")

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([remote]))
    // The immediate first poll observes "main"; the 200ms branch debounce emits.
    await drainAsyncEvents(200)
    await clock.advance(by: .milliseconds(200))
    await drainAsyncEvents(200)
    #expect(await collector.branchChangedCount(worktreeID: remote.id) == 1)

    // The next interval tick polls "feature" -> change -> debounce -> emit.
    await clock.advance(by: .milliseconds(300))
    await drainAsyncEvents(200)
    await clock.advance(by: .milliseconds(200))
    await drainAsyncEvents(200)
    #expect(await collector.branchChangedCount(worktreeID: remote.id) == 2)

    // Subsequent polls keep returning "feature", so no further branch changes.
    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents(200)
    await clock.advance(by: .milliseconds(200))
    await drainAsyncEvents(200)
    #expect(await collector.branchChangedCount(worktreeID: remote.id) == 2)

    manager.handleCommand(.stop)
    await task.value
  }

  @Test func remoteHeadPollStopsAfterWorktreeRemoval() async throws {
    let clock = TestClock()
    let stub = RemoteBranchPollStub(responses: ["main"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(500),
      unfocusedInterval: .milliseconds(500),
      clock: clock,
      pollRemoteBranch: { _ in await stub.next() }
    )
    let (collector, task) = startCollecting(manager.eventStream())
    let remote = makeRemoteWorktree(name: "remote-eagle")

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([remote]))
    await drainAsyncEvents(200)
    #expect(await stub.callCount >= 1)

    // Removing the worktree must cancel the poll loop.
    manager.handleCommand(.setWorktrees([]))
    await drainAsyncEvents(200)
    let callsAfterRemoval = await stub.callCount

    await clock.advance(by: .seconds(2))
    await drainAsyncEvents(200)
    #expect(await stub.callCount == callsAfterRemoval)
    _ = collector

    manager.handleCommand(.stop)
    await task.value
  }

  @Test func selectionRefreshUsesCooldownWithinRepository() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func canceledSelectionCooldownDoesNotClearReplacementCooldown() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)

    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    let afterFirstSelectionCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterFirstSelectionCount == baselineCount + 1)

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setPullRequestTrackingEnabled(true))
    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    let afterReplacementCooldownCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterReplacementCooldownCount == afterFirstSelectionCount + 2)

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(
      await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
        == afterReplacementCooldownCount
    )

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func capsTheEventBufferUnderBackpressure() async throws {
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager()
    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    let stream = manager.eventStream()

    // Each setWorktrees re-emits an immediate filesChanged for the worktree;
    // with nothing draining, the buffer must cap rather than grow unbounded.
    let overflow = WorktreeInfoWatcherManager.eventBufferCap + 50
    for _ in 0..<overflow {
      manager.handleCommand(.setWorktrees([tempWorktree.worktree]))
    }
    manager.handleCommand(.stop)

    var count = 0
    for await event in stream where event == .filesChanged(worktreeID: tempWorktree.worktree.id) {
      count += 1
    }

    #expect(count == WorktreeInfoWatcherManager.eventBufferCap)
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }
}

actor EventCollector {
  private var events: [WorktreeInfoWatcherClient.Event] = []

  func append(_ event: WorktreeInfoWatcherClient.Event) {
    events.append(event)
  }

  func filesChangedCount(worktreeID: Worktree.ID) -> Int {
    events.reduce(into: 0) { result, event in
      if case .filesChanged(let id) = event, id == worktreeID {
        result += 1
      }
    }
  }

  func branchChangedCount(worktreeID: Worktree.ID) -> Int {
    events.reduce(into: 0) { result, event in
      if case .branchChanged(let id) = event, id == worktreeID {
        result += 1
      }
    }
  }

  func pullRequestRefreshCount(repositoryRootURL: URL) -> Int {
    events.reduce(into: 0) { result, event in
      if case .repositoryPullRequestRefresh(let rootURL, _) = event, rootURL == repositoryRootURL {
        result += 1
      }
    }
  }
}

/// Stubs the remote-branch SSH poll: returns each queued value once, then
/// repeats the last value for every subsequent poll. Tracks call count so a
/// test can assert the poll loop stopped.
actor RemoteBranchPollStub {
  private var responses: [String?]
  private(set) var callCount = 0

  init(responses: [String?]) {
    self.responses = responses
  }

  func next() -> String? {
    callCount += 1
    if responses.count > 1 {
      return responses.removeFirst()
    }
    return responses.first ?? nil
  }
}

private func makeRemoteWorktree(name: String) -> Worktree {
  Worktree(
    id: WorktreeID("devbox:/home/me/\(name)"),
    name: name,
    detail: "devbox",
    workingDirectory: URL(fileURLWithPath: "/home/me/\(name)"),
    repositoryRootURL: URL(fileURLWithPath: "/home/me/repo"),
    host: RemoteHost(alias: "devbox")
  )
}

private struct TempWorktree {
  let worktree: Worktree
  let tempRoot: URL
  let headURL: URL
}

private struct TempRepository {
  let worktrees: [Worktree]
  let tempRoot: URL
}

private func makeTempWorktree() throws -> TempWorktree {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  let worktreeDirectory = tempRoot.appending(path: "wt")
  let gitDirectory = worktreeDirectory.appending(path: ".git")
  try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
  let headURL = gitDirectory.appending(path: "HEAD")
  try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)
  let worktree = Worktree(
    id: WorktreeID(worktreeDirectory.path(percentEncoded: false)),
    name: "eagle",
    detail: "detail",
    workingDirectory: worktreeDirectory,
    repositoryRootURL: tempRoot
  )
  return TempWorktree(worktree: worktree, tempRoot: tempRoot, headURL: headURL)
}

private func makeTempRepository(worktreeNames: [String]) throws -> TempRepository {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  var worktrees: [Worktree] = []
  for name in worktreeNames {
    let worktreeDirectory = tempRoot.appending(path: name)
    let gitDirectory = worktreeDirectory.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/\(name)\n".write(to: headURL, atomically: true, encoding: .utf8)
    let worktree = Worktree(
      id: WorktreeID(worktreeDirectory.path(percentEncoded: false)),
      name: name,
      detail: "detail",
      workingDirectory: worktreeDirectory,
      repositoryRootURL: tempRoot
    )
    worktrees.append(worktree)
  }
  return TempRepository(worktrees: worktrees, tempRoot: tempRoot)
}

private func startCollecting(
  _ stream: AsyncStream<WorktreeInfoWatcherClient.Event>
) -> (EventCollector, Task<Void, Never>) {
  let collector = EventCollector()
  let task = Task {
    for await event in stream {
      if Task.isCancelled {
        break
      }
      await collector.append(event)
    }
  }
  return (collector, task)
}

private func drainAsyncEvents(_ iterations: Int = 20) async {
  for _ in 0..<iterations {
    await Task.yield()
  }
}
