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
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))

    #expect(
      await waitForFilesChangedCount(
        collector,
        worktreeID: tempWorktree.worktree.id,
        atLeast: 1
      ) >= 1
    )

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
    #expect(
      await waitForFilesChangedCount(
        collector,
        worktreeID: firstWorktree.id,
        atLeast: 1
      ) == 1
    )

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    #expect(
      await waitForFilesChangedCount(
        collector,
        worktreeID: secondWorktree.id,
        atLeast: 1
      ) == 1
    )

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func lineChangesDoNotRefreshWhileIdle() async throws {
    let clock = TestClock()
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))
    #expect(
      await waitForFilesChangedCount(
        collector,
        worktreeID: tempWorktree.worktree.id,
        atLeast: 1
      ) == 1
    )

    await clock.advance(by: .seconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func unchangedWorktreesDoNotRefreshLineChanges() async throws {
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager(
      filesChangedDebounceInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))
    #expect(
      await waitForFilesChangedCount(
        collector,
        worktreeID: tempWorktree.worktree.id,
        atLeast: 1
      ) == 1
    )

    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
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
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree, duplicate]))

    // The manager initialized and the single de-duplicated worktree is watched.
    #expect(
      await waitForFilesChangedCount(
        collector,
        worktreeID: tempWorktree.worktree.id,
        atLeast: 1
      ) == 1
    )

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

  @Test func branchChangesDoNotRefreshPullRequestsBeforeBranchNameLoads() async throws {
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

    manager.handleCommand(.setWorktrees([remote]))
    await drainAsyncEvents(200)
    let baselineCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: remote.repositoryRootURL
    )
    #expect(baselineCount == 1)

    // Branch changes only emit branchChanged here. The reducer refreshes PR
    // state after loading the new branch name into repository state.
    await clock.advance(by: .milliseconds(200))
    await drainAsyncEvents(200)
    let afterInitialBranchObservationCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: remote.repositoryRootURL
    )
    #expect(afterInitialBranchObservationCount == baselineCount)
    #expect(await collector.branchChangedCount(worktreeID: remote.id) == 1)

    await clock.advance(by: .milliseconds(300))
    await drainAsyncEvents(200)
    await clock.advance(by: .milliseconds(200))
    await drainAsyncEvents(200)
    let afterBranchChangeCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: remote.repositoryRootURL
    )
    #expect(afterBranchChangeCount == baselineCount)
    #expect(await collector.branchChangedCount(worktreeID: remote.id) == 2)

    // Stable remote branch polls must not keep refreshing PR state.
    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents(200)
    await clock.advance(by: .milliseconds(200))
    await drainAsyncEvents(200)
    let afterStableBranchPollCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: remote.repositoryRootURL
    )
    #expect(afterStableBranchPollCount == afterBranchChangeCount)

    manager.handleCommand(.stop)
    await task.value
  }

  @Test func refreshCommandRefreshesLineChangesAndPullRequests() async throws {
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      filesChangedDebounceInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    let firstBaselineCount = await waitForFilesChangedCount(
      collector,
      worktreeID: firstWorktree.id,
      atLeast: 1
    )
    let secondBaselineCount = await waitForFilesChangedCount(
      collector,
      worktreeID: secondWorktree.id,
      atLeast: 1
    )
    #expect(firstBaselineCount == 1)
    #expect(secondBaselineCount == 1)
    let baselinePullRequestCount = await waitForPullRequestRefreshCount(
      collector,
      repositoryRootURL: tempRepository.tempRoot,
      atLeast: 1
    )
    #expect(baselinePullRequestCount == 1)

    manager.handleCommand(.refresh)
    #expect(
      await waitForFilesChangedCount(
        collector,
        worktreeID: firstWorktree.id,
        atLeast: firstBaselineCount + 1
      ) == firstBaselineCount + 1
    )
    #expect(
      await waitForFilesChangedCount(
        collector,
        worktreeID: secondWorktree.id,
        atLeast: secondBaselineCount + 1
      ) == secondBaselineCount + 1
    )
    #expect(
      await waitForPullRequestRefreshCount(
        collector,
        repositoryRootURL: tempRepository.tempRoot,
        atLeast: baselinePullRequestCount + 1
      )
        == baselinePullRequestCount + 1
    )

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
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

  @Test func pullRequestsDoNotRefreshWhileIdle() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents(120)
    let baselineCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(baselineCount == 1)

    await clock.advance(by: .seconds(1))
    await drainAsyncEvents(120)
    let afterIdleCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterIdleCount == baselineCount)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func unchangedWorktreesDoNotRefreshPullRequests() async throws {
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager()
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents(120)
    let baselineCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(baselineCount == 1)

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents(120)
    let afterUnchangedWorktreesCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterUnchangedWorktreesCount == baselineCount)

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

    // Metadata changes still emit refresh signals; with nothing draining, the
    // stream must cap rather than grow unbounded.
    let overflow = WorktreeInfoWatcherManager.eventBufferCap + 50
    for index in 0..<overflow {
      let worktree = Worktree(
        id: tempWorktree.worktree.id,
        kind: tempWorktree.worktree.kind,
        name: tempWorktree.worktree.name,
        detail: "detail-\(index)",
        workingDirectory: tempWorktree.worktree.workingDirectory,
        repositoryRootURL: tempWorktree.worktree.repositoryRootURL
      )
      manager.handleCommand(.setWorktrees([worktree]))
    }
    manager.handleCommand(.stop)

    var count = 0
    for await event in stream where event == .filesChanged(worktreeID: tempWorktree.worktree.id) {
      count += 1
    }

    #expect(count == WorktreeInfoWatcherManager.eventBufferCap)
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func reconcileBackstopRefreshesRemoteLineChangesAndPullRequests() async throws {
    let clock = TestClock()
    let stub = RemoteBranchPollStub(responses: ["main"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .seconds(3_600),
      reconcileInterval: .seconds(1),
      reconcileStep: .milliseconds(10),
      clock: clock,
      pollRemoteBranch: { _ in await stub.next() }
    )
    let (collector, task) = startCollecting(manager.eventStream())
    let remote = makeRemoteWorktree(name: "remote-eagle")

    manager.handleCommand(.setWorktrees([remote]))
    #expect(await waitForFilesChangedCount(collector, worktreeID: remote.id, atLeast: 1) == 1)
    #expect(
      await waitForPullRequestRefreshCount(
        collector, repositoryRootURL: remote.repositoryRootURL, atLeast: 1
      ) == 1
    )

    // One reconcile sweep re-emits the remote worktree's line changes (no local
    // FS events) and re-refreshes its pull requests.
    await clock.advance(by: .seconds(1))
    #expect(await waitForFilesChangedCount(collector, worktreeID: remote.id, atLeast: 2) == 2)
    await clock.advance(by: .milliseconds(10))
    #expect(
      await waitForPullRequestRefreshCount(
        collector, repositoryRootURL: remote.repositoryRootURL, atLeast: 2
      ) == 2
    )

    manager.handleCommand(.stop)
    await task.value
  }

  @Test func reconcileBackstopLeavesLocalLineChangesToFileEvents() async throws {
    let clock = TestClock()
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager(
      filesChangedDebounceInterval: .seconds(3_600),
      reconcileInterval: .seconds(1),
      reconcileStep: .milliseconds(10),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))
    #expect(
      await waitForFilesChangedCount(collector, worktreeID: tempWorktree.worktree.id, atLeast: 1) == 1
    )
    #expect(
      await waitForPullRequestRefreshCount(
        collector, repositoryRootURL: tempWorktree.tempRoot, atLeast: 1
      ) == 1
    )

    // The sweep re-refreshes pull requests but must not diff a local worktree on
    // a timer; local line counts stay event-driven.
    await clock.advance(by: .seconds(1))
    await clock.advance(by: .milliseconds(10))
    #expect(
      await waitForPullRequestRefreshCount(
        collector, repositoryRootURL: tempWorktree.tempRoot, atLeast: 2
      ) == 2
    )
    await drainAsyncEvents(200)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func backgroundPollingPausesWhileInactiveAndResumesWhenActive() async throws {
    let clock = TestClock()
    let stub = RemoteBranchPollStub(responses: ["main"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .seconds(3_600),
      reconcileInterval: .seconds(1),
      reconcileStep: .milliseconds(10),
      clock: clock,
      pollRemoteBranch: { _ in await stub.next() }
    )
    let (collector, task) = startCollecting(manager.eventStream())
    let remote = makeRemoteWorktree(name: "remote-eagle")

    manager.handleCommand(.setWorktrees([remote]))
    #expect(await waitForFilesChangedCount(collector, worktreeID: remote.id, atLeast: 1) == 1)

    // Going inactive stops the reconcile sweep and the remote SSH head poll.
    manager.handleCommand(.setActive(false))
    await drainAsyncEvents(200)
    let callsWhileInactive = await stub.callCount
    await clock.advance(by: .seconds(5))
    await drainAsyncEvents(200)
    #expect(await collector.filesChangedCount(worktreeID: remote.id) == 1)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: remote.repositoryRootURL) == 1)
    #expect(await stub.callCount == callsWhileInactive)

    // Reactivating resumes both.
    manager.handleCommand(.setActive(true))
    await drainAsyncEvents(200)
    #expect(await stub.callCount > callsWhileInactive)
    await clock.advance(by: .seconds(1))
    #expect(await waitForFilesChangedCount(collector, worktreeID: remote.id, atLeast: 2) == 2)

    manager.handleCommand(.stop)
    await task.value
  }

  @Test func disablingPollingStopsBackgroundWorkAndReenablingResumesIt() async throws {
    let clock = TestClock()
    let stub = RemoteBranchPollStub(responses: ["main"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .seconds(3_600),
      reconcileInterval: .seconds(1),
      reconcileStep: .milliseconds(10),
      clock: clock,
      pollRemoteBranch: { _ in await stub.next() }
    )
    let (collector, task) = startCollecting(manager.eventStream())
    let remote = makeRemoteWorktree(name: "remote-eagle")

    manager.handleCommand(.setWorktrees([remote]))
    #expect(await waitForFilesChangedCount(collector, worktreeID: remote.id, atLeast: 1) == 1)

    manager.handleCommand(.setAutomaticRefreshEnabled(false))
    await drainAsyncEvents(200)
    let callsWhileDisabled = await stub.callCount
    await clock.advance(by: .seconds(5))
    await drainAsyncEvents(200)
    #expect(await collector.filesChangedCount(worktreeID: remote.id) == 1)
    #expect(await stub.callCount == callsWhileDisabled)

    manager.handleCommand(.setAutomaticRefreshEnabled(true))
    await drainAsyncEvents(200)
    #expect(await stub.callCount > callsWhileDisabled)
    await clock.advance(by: .seconds(1))
    #expect(await waitForFilesChangedCount(collector, worktreeID: remote.id, atLeast: 2) == 2)

    manager.handleCommand(.stop)
    await task.value
  }

  @Test func pollingDisabledAtConstructionSkipsRemoteStatusWorkButKeepsLocalDiscovery() async throws {
    let clock = TestClock()
    let stub = RemoteBranchPollStub(responses: ["main"])
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .seconds(3_600),
      reconcileInterval: .seconds(1),
      reconcileStep: .milliseconds(10),
      automaticRefreshEnabled: false,
      clock: clock,
      pollRemoteBranch: { _ in await stub.next() }
    )
    let (collector, task) = startCollecting(manager.eventStream())
    let remote = makeRemoteWorktree(name: "remote-eagle")

    manager.handleCommand(.setWorktrees([remote, tempWorktree.worktree]))
    await drainAsyncEvents(200)
    await clock.advance(by: .seconds(5))
    await drainAsyncEvents(200)

    // No recurring SSH head poll and no reconcile sweep while disabled, and the
    // remote worktree's SSH line count is not read on discovery either. A local
    // worktree still shows its counts, since that diff is cheap and never SSH.
    #expect(await stub.callCount == 0)
    #expect(await collector.filesChangedCount(worktreeID: remote.id) == 0)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func fileEventRootsIncludesLinkedWorktreeAdminDir() throws {
    let linked = try makeLinkedWorktree()
    let manager = WorktreeInfoWatcherManager()

    let roots = manager.fileEventRoots(for: linked.worktree)

    // The working tree plus the admin dir outside it, so a commit that only
    // rewrites the admin dir still produces a file event.
    #expect(roots.contains(linked.worktree.workingDirectory))
    #expect(roots.contains(linked.adminDirectory))
    #expect(roots.count == 2)

    try FileManager.default.removeItem(at: linked.tempRoot)
  }

  @Test func fileEventRootsIsJustTheWorkingTreeForAnEmbeddedGitDir() throws {
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager()

    let roots = manager.fileEventRoots(for: tempWorktree.worktree)

    #expect(roots == [tempWorktree.worktree.workingDirectory])

    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func reconcileCatchesUpALocalWorktreeWhoseWatcherIsDead() async throws {
    let clock = TestClock()
    // A worktree with no resolvable HEAD never arms a head watcher, so the
    // reconcile backstop must emit a catch-up instead of leaving it stale.
    let worktree = makeLocalWorktreeWithoutGitMetadata()
    let manager = WorktreeInfoWatcherManager(
      filesChangedDebounceInterval: .seconds(3_600),
      reconcileInterval: .seconds(1),
      reconcileStep: .milliseconds(10),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([worktree]))
    #expect(await waitForFilesChangedCount(collector, worktreeID: worktree.id, atLeast: 1) == 1)
    #expect(await collector.branchChangedCount(worktreeID: worktree.id) == 0)

    await clock.advance(by: .seconds(1))
    #expect(await waitForFilesChangedCount(collector, worktreeID: worktree.id, atLeast: 2) == 2)
    #expect(await collector.branchChangedCount(worktreeID: worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
  }

  @Test func reconcileSweepStaggersWorktreesOneStepApartInOrder() async throws {
    let clock = TestClock()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      filesChangedDebounceInterval: .seconds(3_600),
      reconcileInterval: .seconds(1),
      reconcileStep: .seconds(1),
      clock: clock,
      pollRemoteBranch: { _ in "main" }
    )
    let (collector, task) = startCollecting(manager.eventStream())
    let first = makeRemoteWorktree(name: "alpha")
    let second = makeRemoteWorktree(name: "beta")
    #expect(first.id.rawValue < second.id.rawValue)

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([first, second]))
    _ = await waitForFilesChangedCount(collector, worktreeID: first.id, atLeast: 1)
    _ = await waitForFilesChangedCount(collector, worktreeID: second.id, atLeast: 1)

    // The sweep reconciles one worktree per step, in id order: alpha, then beta.
    await clock.advance(by: .seconds(1))
    #expect(await waitForFilesChangedCount(collector, worktreeID: first.id, atLeast: 2) == 2)
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: second.id) == 1)

    await clock.advance(by: .seconds(1))
    #expect(await waitForFilesChangedCount(collector, worktreeID: second.id, atLeast: 2) == 2)

    manager.handleCommand(.stop)
    await task.value
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
      if case .repositoryPullRequestRefresh(let rootURL, _, _) = event, rootURL == repositoryRootURL {
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

private struct LinkedWorktree {
  let worktree: Worktree
  let adminDirectory: URL
  let tempRoot: URL
}

/// A linked worktree whose `.git` is a file pointing at an admin dir outside
/// the working tree, mirroring `git worktree add`.
private func makeLinkedWorktree() throws -> LinkedWorktree {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  let repositoryRoot = tempRoot.appending(path: "repo")
  let adminDirectory = repositoryRoot.appending(path: ".git/worktrees/feature")
  try fileManager.createDirectory(at: adminDirectory, withIntermediateDirectories: true)
  try "ref: refs/heads/feature\n".write(
    to: adminDirectory.appending(path: "HEAD"), atomically: true, encoding: .utf8)
  let worktreeDirectory = tempRoot.appending(path: "wt-feature")
  try fileManager.createDirectory(at: worktreeDirectory, withIntermediateDirectories: true)
  try "gitdir: \(adminDirectory.path(percentEncoded: false))\n".write(
    to: worktreeDirectory.appending(path: ".git"), atomically: true, encoding: .utf8)
  let worktree = Worktree(
    id: WorktreeID(worktreeDirectory.path(percentEncoded: false)),
    name: "feature",
    detail: "detail",
    workingDirectory: worktreeDirectory,
    repositoryRootURL: repositoryRoot
  )
  return LinkedWorktree(
    worktree: worktree,
    adminDirectory: adminDirectory.standardizedFileURL,
    tempRoot: tempRoot
  )
}

/// A worktree pointing at a directory with no `.git`, so no head watcher can
/// ever arm for it.
private func makeLocalWorktreeWithoutGitMetadata() -> Worktree {
  Worktree(
    id: WorktreeID("/private/tmp/\(UUID().uuidString)/wt"),
    name: "orphan",
    detail: "detail",
    workingDirectory: URL(fileURLWithPath: "/private/tmp/\(UUID().uuidString)/wt"),
    repositoryRootURL: URL(fileURLWithPath: "/private/tmp/\(UUID().uuidString)")
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

private func waitForFilesChangedCount(
  _ collector: EventCollector,
  worktreeID: Worktree.ID,
  atLeast expectedCount: Int,
  iterations: Int = 200
) async -> Int {
  for _ in 0..<iterations {
    let count = await collector.filesChangedCount(worktreeID: worktreeID)
    if count >= expectedCount {
      return count
    }
    await Task.yield()
  }
  return await collector.filesChangedCount(worktreeID: worktreeID)
}

private func waitForPullRequestRefreshCount(
  _ collector: EventCollector,
  repositoryRootURL: URL,
  atLeast expectedCount: Int,
  iterations: Int = 200
) async -> Int {
  for _ in 0..<iterations {
    let count = await collector.pullRequestRefreshCount(
      repositoryRootURL: repositoryRootURL
    )
    if count >= expectedCount {
      return count
    }
    await Task.yield()
  }
  return await collector.pullRequestRefreshCount(repositoryRootURL: repositoryRootURL)
}
