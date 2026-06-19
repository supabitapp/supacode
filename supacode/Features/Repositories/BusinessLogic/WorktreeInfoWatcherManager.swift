import Darwin
import Dispatch
import Foundation
import SupacodeSettingsShared

private let watcherLogger = SupaLogger("WorktreeInfoWatcher")

@MainActor
final class WorktreeInfoWatcherManager {
  /// Hard cap on the live event buffer. These events are refresh signals (not
  /// coalescable state), so the stream is capped rather than deduped: a wedged
  /// consumer drops the oldest signals instead of letting the buffer grow
  /// without bound.
  static let eventBufferCap = 2048

  private struct HeadWatcher {
    let headURL: URL
    let source: DispatchSourceFileSystemObject
  }

  private struct RefreshTask {
    let interval: Duration
    let task: Task<Void, Never>
  }

  private struct PullRequestSelectionCooldownTask {
    let id: UUID
    let task: Task<Void, Never>
  }

  private struct RepeatingTaskRequest {
    let worktreeID: Worktree.ID
    let interval: Duration
    let immediate: Bool
    let forceReschedule: Bool
    let makeEvent: (Worktree.ID) -> WorktreeInfoWatcherClient.Event
  }

  private struct RefreshTiming: Equatable {
    let focused: Duration
    let unfocused: Duration
  }

  private let filesChangedDebounceInterval: Duration
  private let pullRequestSelectionRefreshCooldown: Duration
  private let refreshTiming: RefreshTiming
  private let sleep: @Sendable (Duration) async throws -> Void
  /// Resolves a remote worktree's current branch over SSH. Injected so tests
  /// can drive the poll loop without a real connection (real-host SSH is
  /// verified separately). Returns `nil` for a local worktree or on error.
  private let pollRemoteBranch: @Sendable (Worktree) async -> String?
  private var worktrees: [Worktree.ID: Worktree] = [:]
  private var headWatchers: [Worktree.ID: HeadWatcher] = [:]
  /// Remote worktrees can't kqueue their `.git/HEAD` (it lives on another
  /// host), so they poll `git rev-parse` over SSH on the same focused /
  /// unfocused cadence as line-changes / PR refresh.
  private var remoteHeadPollTasks: [Worktree.ID: RefreshTask] = [:]
  private var lastKnownRemoteBranch: [Worktree.ID: String] = [:]
  private var branchDebounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var filesDebounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var restartTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var pullRequestTasks: [URL: RefreshTask] = [:]
  private var lineChangeTasks: [Worktree.ID: RefreshTask] = [:]
  private var deferredLineChangeIDs: Set<Worktree.ID> = []
  private var hasCompletedInitialWorktreeLoad = false
  private var selectedWorktreeID: Worktree.ID?
  private var pullRequestTrackingEnabled = true
  private var pullRequestSelectionCooldownTasksByRepo: [URL: PullRequestSelectionCooldownTask] = [:]
  private var eventContinuation: AsyncStream<WorktreeInfoWatcherClient.Event>.Continuation?

  init<C: Clock<Duration>>(
    focusedInterval: Duration = .seconds(30),
    unfocusedInterval: Duration = .seconds(60),
    filesChangedDebounceInterval: Duration = .seconds(5),
    pullRequestSelectionRefreshCooldown: Duration = .seconds(5),
    clock: C = ContinuousClock(),
    pollRemoteBranch: @escaping @Sendable (Worktree) async -> String? = { worktree in
      guard let host = worktree.host else { return nil }
      return await GitClient(shell: .ssh(host: host)).symbolicHeadBranch(at: worktree.workingDirectory)
    }
  ) {
    refreshTiming = RefreshTiming(focused: focusedInterval, unfocused: unfocusedInterval)
    self.filesChangedDebounceInterval = filesChangedDebounceInterval
    self.pullRequestSelectionRefreshCooldown = pullRequestSelectionRefreshCooldown
    self.sleep = { duration in
      try await clock.sleep(for: duration)
    }
    self.pollRemoteBranch = pollRemoteBranch
  }

  func handleCommand(_ command: WorktreeInfoWatcherClient.Command) {
    switch command {
    case .setWorktrees(let worktrees):
      setWorktrees(worktrees)
    case .setSelectedWorktreeID(let worktreeID):
      setSelectedWorktreeID(worktreeID)
    case .setPullRequestTrackingEnabled(let isEnabled):
      setPullRequestTrackingEnabled(isEnabled)
    case .stop:
      stopAll()
    }
  }

  func eventStream() -> AsyncStream<WorktreeInfoWatcherClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(
      of: WorktreeInfoWatcherClient.Event.self,
      bufferingPolicy: .bufferingNewest(Self.eventBufferCap)
    )
    eventContinuation = continuation
    return stream
  }

  private func setWorktrees(_ worktrees: [Worktree]) {
    let isInitialWorktreeLoad = !hasCompletedInitialWorktreeLoad && self.worktrees.isEmpty && !worktrees.isEmpty
    let worktreesByID = Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0) })
    let desiredIDs = Set(worktreesByID.keys)
    let currentIDs = Set(self.worktrees.keys)
    let removedIDs = currentIDs.subtracting(desiredIDs)
    for id in removedIDs {
      stopWatcher(for: id)
    }
    if !removedIDs.isEmpty {
      deferredLineChangeIDs.subtract(removedIDs)
    }
    let newIDs = desiredIDs.subtracting(currentIDs)
    if !newIDs.isEmpty && !isInitialWorktreeLoad {
      deferredLineChangeIDs.formUnion(newIDs)
    }
    self.worktrees = worktreesByID
    for worktree in worktrees {
      configureWatcher(for: worktree)
      updateLineChangeSchedule(
        worktreeID: worktree.id,
        immediate: isInitialWorktreeLoad || !deferredLineChangeIDs.contains(worktree.id)
      )
    }
    if isInitialWorktreeLoad {
      hasCompletedInitialWorktreeLoad = true
    }
    let repositoryRoots = Set(worktrees.map(\.repositoryRootURL))
    for repositoryRootURL in repositoryRoots {
      updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
    }
    let obsoleteRepositories = pullRequestTasks.keys.filter { !repositoryRoots.contains($0) }
    for repositoryRootURL in obsoleteRepositories {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
    }
    let obsoleteCooldownRepositories = pullRequestSelectionCooldownTasksByRepo.keys.filter {
      !repositoryRoots.contains($0)
    }
    for repositoryRootURL in obsoleteCooldownRepositories {
      cancelPullRequestSelectionCooldown(for: repositoryRootURL)
    }
  }

  private func setSelectedWorktreeID(_ worktreeID: Worktree.ID?) {
    guard selectedWorktreeID != worktreeID else {
      return
    }
    let previousWorktreeID = selectedWorktreeID
    let previousRepository = previousWorktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    selectedWorktreeID = worktreeID
    let nextRepository = worktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    if let previousWorktreeID {
      updateLineChangeSchedule(worktreeID: previousWorktreeID, immediate: false)
      if let worktree = worktrees[previousWorktreeID] {
        configureRemoteHeadPoll(for: worktree)
      }
    }
    if let worktreeID {
      updateLineChangeSchedule(worktreeID: worktreeID, immediate: true)
      if let worktree = worktrees[worktreeID] {
        configureRemoteHeadPoll(for: worktree)
      }
    }
    if let previousRepository, previousRepository == nextRepository {
      updatePullRequestSchedule(
        repositoryRootURL: previousRepository,
        immediate: shouldImmediatelyRefreshPullRequests(repositoryRootURL: previousRepository)
      )
      return
    }
    if let previousRepository {
      updatePullRequestSchedule(repositoryRootURL: previousRepository, immediate: false)
    }
    if let nextRepository {
      updatePullRequestSchedule(
        repositoryRootURL: nextRepository,
        immediate: shouldImmediatelyRefreshPullRequests(repositoryRootURL: nextRepository)
      )
    }
  }

  private func configureWatcher(for worktree: Worktree) {
    // Remote worktrees live on another host; their HEAD can't be kqueue'd, so
    // route them to the SSH poll loop and skip the local head-file resolver
    // (which would return nil for a non-local path and silently drop the row).
    if worktree.host != nil {
      configureRemoteHeadPoll(for: worktree)
      return
    }
    guard
      let headURL = GitWorktreeHeadResolver.headURL(
        for: worktree.workingDirectory,
        fileManager: .default
      )
    else {
      stopWatcher(for: worktree.id)
      return
    }
    if let existing = headWatchers[worktree.id], existing.headURL == headURL {
      return
    }
    stopWatcher(for: worktree.id)
    startWatcher(worktreeID: worktree.id, headURL: headURL)
  }

  private func startWatcher(worktreeID: Worktree.ID, headURL: URL) {
    let path = headURL.path(percentEncoded: false)
    let fileDescriptor = open(path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      return
    }
    let queue = DispatchQueue(label: "worktree-info-watcher.\(worktreeID)")
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .rename, .delete, .attrib],
      queue: queue
    )
    source.setEventHandler { @Sendable [weak self, weak source] in
      guard let source else { return }
      let event = source.data
      Task { @MainActor in
        self?.handleEvent(worktreeID: worktreeID, event: event)
      }
    }
    source.setCancelHandler { @Sendable in
      close(fileDescriptor)
    }
    source.resume()
    headWatchers[worktreeID] = HeadWatcher(headURL: headURL, source: source)
  }

  private func handleEvent(
    worktreeID: Worktree.ID,
    event: DispatchSource.FileSystemEvent
  ) {
    if event.contains(.delete) || event.contains(.rename) {
      stopHeadWatcher(for: worktreeID)
      scheduleRestart(worktreeID: worktreeID)
      scheduleBranchChanged(worktreeID: worktreeID)
      return
    }
    scheduleBranchChanged(worktreeID: worktreeID)
    scheduleFilesChanged(worktreeID: worktreeID)
  }

  private func scheduleBranchChanged(worktreeID: Worktree.ID) {
    branchDebounceTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(.milliseconds(200))
      await MainActor.run {
        self?.emit(.branchChanged(worktreeID: worktreeID))
      }
    }
    branchDebounceTasks[worktreeID] = task
  }

  private func scheduleFilesChanged(worktreeID: Worktree.ID) {
    filesDebounceTasks[worktreeID]?.cancel()
    let debounceInterval = filesChangedDebounceInterval
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(debounceInterval)
      await MainActor.run {
        guard let self else { return }
        self.emit(.filesChanged(worktreeID: worktreeID))
        if !self.deferredLineChangeIDs.contains(worktreeID) {
          self.updateLineChangeSchedule(
            worktreeID: worktreeID,
            immediate: false,
            forceReschedule: true
          )
        }
      }
    }
    filesDebounceTasks[worktreeID] = task
  }

  private func scheduleRestart(worktreeID: Worktree.ID) {
    restartTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(.seconds(5))
      await MainActor.run {
        self?.restartWatcher(worktreeID: worktreeID)
      }
    }
    restartTasks[worktreeID] = task
  }

  private func restartWatcher(worktreeID: Worktree.ID) {
    guard headWatchers[worktreeID] == nil else {
      return
    }
    guard let worktree = worktrees[worktreeID] else {
      return
    }
    configureWatcher(for: worktree)
    scheduleBranchChanged(worktreeID: worktreeID)
  }

  /// (Re)start the SSH HEAD poll for a remote worktree at the focused /
  /// unfocused cadence. No-op for a local worktree, and idempotent when the
  /// interval is unchanged so a selection change that doesn't flip focus won't
  /// restart the loop. The loop polls immediately, then on the interval.
  private func configureRemoteHeadPoll(for worktree: Worktree) {
    guard worktree.host != nil else {
      return
    }
    let worktreeID = worktree.id
    let interval = worktreeID == selectedWorktreeID ? refreshTiming.focused : refreshTiming.unfocused
    if let existing = remoteHeadPollTasks[worktreeID], existing.interval == interval {
      return
    }
    remoteHeadPollTasks[worktreeID]?.task.cancel()
    let sleep = self.sleep
    let pollRemoteBranch = self.pollRemoteBranch
    let task = Task { [weak self, sleep, pollRemoteBranch] in
      while !Task.isCancelled {
        guard let worktree = await MainActor.run(body: { self?.worktrees[worktreeID] }) else {
          break
        }
        let branch = await pollRemoteBranch(worktree)
        await MainActor.run {
          self?.handleRemoteBranch(worktreeID: worktreeID, branch: branch)
        }
        do {
          try await sleep(interval)
        } catch {
          break
        }
      }
    }
    remoteHeadPollTasks[worktreeID] = RefreshTask(interval: interval, task: task)
  }

  private func handleRemoteBranch(worktreeID: Worktree.ID, branch: String?) {
    guard let branch, lastKnownRemoteBranch[worktreeID] != branch else {
      return
    }
    lastKnownRemoteBranch[worktreeID] = branch
    // Reuse the kqueue debounce + `.branchChanged` emit so downstream behavior
    // is identical. The first non-nil observation also emits, populating the
    // row's branch from the live remote HEAD.
    scheduleBranchChanged(worktreeID: worktreeID)
  }

  private func stopRemoteHeadPoll(for worktreeID: Worktree.ID) {
    remoteHeadPollTasks.removeValue(forKey: worktreeID)?.task.cancel()
    lastKnownRemoteBranch.removeValue(forKey: worktreeID)
  }

  private func stopHeadWatcher(for worktreeID: Worktree.ID) {
    if let watcher = headWatchers.removeValue(forKey: worktreeID) {
      watcher.source.cancel()
    }
  }

  private func stopWatcher(for worktreeID: Worktree.ID) {
    stopHeadWatcher(for: worktreeID)
    stopRemoteHeadPoll(for: worktreeID)
    branchDebounceTasks.removeValue(forKey: worktreeID)?.cancel()
    filesDebounceTasks.removeValue(forKey: worktreeID)?.cancel()
    restartTasks.removeValue(forKey: worktreeID)?.cancel()
    lineChangeTasks.removeValue(forKey: worktreeID)?.task.cancel()
  }

  private func stopAll() {
    for watcher in headWatchers.values {
      watcher.source.cancel()
    }
    for task in branchDebounceTasks.values {
      task.cancel()
    }
    for task in filesDebounceTasks.values {
      task.cancel()
    }
    for task in restartTasks.values {
      task.cancel()
    }
    for task in pullRequestTasks.values {
      task.task.cancel()
    }
    for task in lineChangeTasks.values {
      task.task.cancel()
    }
    for task in remoteHeadPollTasks.values {
      task.task.cancel()
    }
    headWatchers.removeAll()
    branchDebounceTasks.removeAll()
    filesDebounceTasks.removeAll()
    restartTasks.removeAll()
    pullRequestTasks.removeAll()
    lineChangeTasks.removeAll()
    remoteHeadPollTasks.removeAll()
    lastKnownRemoteBranch.removeAll()
    deferredLineChangeIDs.removeAll()
    hasCompletedInitialWorktreeLoad = false
    cancelAllPullRequestSelectionCooldownTasks()
    worktrees.removeAll()
    selectedWorktreeID = nil
    pullRequestTrackingEnabled = true
    eventContinuation?.finish()
  }

  private func setPullRequestTrackingEnabled(_ enabled: Bool) {
    guard pullRequestTrackingEnabled != enabled else {
      return
    }
    pullRequestTrackingEnabled = enabled
    if enabled {
      let repositoryRoots = Set(worktrees.values.map(\.repositoryRootURL))
      for repositoryRootURL in repositoryRoots {
        updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
      }
      return
    }
    for task in pullRequestTasks.values {
      task.task.cancel()
    }
    pullRequestTasks.removeAll()
    cancelAllPullRequestSelectionCooldownTasks()
  }

  private func updatePullRequestSchedule(repositoryRootURL: URL, immediate: Bool) {
    guard pullRequestTrackingEnabled else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    let isFocused = selectedWorktreeID.map { worktreeIDs.contains($0) } ?? false
    let interval = isFocused ? refreshTiming.focused : refreshTiming.unfocused
    if let existing = pullRequestTasks[repositoryRootURL], existing.interval == interval, !immediate {
      return
    }
    pullRequestTasks[repositoryRootURL]?.task.cancel()
    if immediate {
      emitPullRequestRefresh(repositoryRootURL: repositoryRootURL)
    }
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      while !Task.isCancelled {
        do {
          try await sleep(interval)
        } catch {
          break
        }
        guard !Task.isCancelled else {
          break
        }
        await MainActor.run {
          self?.emitPullRequestRefresh(repositoryRootURL: repositoryRootURL)
        }
      }
    }
    pullRequestTasks[repositoryRootURL] = RefreshTask(interval: interval, task: task)
  }

  private func repositoryWorktreeIDs(for repositoryRootURL: URL) -> [Worktree.ID] {
    worktrees
      .values
      .filter { $0.repositoryRootURL == repositoryRootURL }
      .map(\.id)
      .sorted { $0.rawValue < $1.rawValue }
  }

  private func emitPullRequestRefresh(repositoryRootURL: URL) {
    guard pullRequestTrackingEnabled else {
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      return
    }
    emit(.repositoryPullRequestRefresh(repositoryRootURL: repositoryRootURL, worktreeIDs: worktreeIDs))
  }

  private func updateLineChangeSchedule(
    worktreeID: Worktree.ID,
    immediate: Bool,
    forceReschedule: Bool = false
  ) {
    guard worktrees[worktreeID] != nil else {
      return
    }
    let interval = worktreeID == selectedWorktreeID ? refreshTiming.focused : refreshTiming.unfocused
    let shouldEmit = immediate && !deferredLineChangeIDs.contains(worktreeID)
    let request = RepeatingTaskRequest(
      worktreeID: worktreeID,
      interval: interval,
      immediate: shouldEmit,
      forceReschedule: forceReschedule,
      makeEvent: { [weak self] worktreeID in
        self?.deferredLineChangeIDs.remove(worktreeID)
        return .filesChanged(worktreeID: worktreeID)
      }
    )
    updateRepeatingTask(request, tasks: &lineChangeTasks)
  }

  private func updateRepeatingTask(
    _ request: RepeatingTaskRequest,
    tasks: inout [Worktree.ID: RefreshTask]
  ) {
    let worktreeID = request.worktreeID
    if let existing = tasks[worktreeID], existing.interval == request.interval, !request.forceReschedule {
      if request.immediate {
        emit(request.makeEvent(worktreeID))
      }
      return
    }
    tasks[worktreeID]?.task.cancel()
    if request.immediate {
      emit(request.makeEvent(worktreeID))
    }
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      while !Task.isCancelled {
        do {
          try await sleep(request.interval)
        } catch {
          if !(error is CancellationError) {
            watcherLogger.error("Worktree refresh loop for \(worktreeID) ended: \(error).")
          }
          break
        }
        guard !Task.isCancelled else {
          break
        }
        await MainActor.run {
          self?.emit(request.makeEvent(worktreeID))
        }
      }
    }
    tasks[worktreeID] = RefreshTask(interval: request.interval, task: task)
  }

  private func emit(_ event: WorktreeInfoWatcherClient.Event) {
    if case .filesChanged(let worktreeID) = event,
      deferredLineChangeIDs.contains(worktreeID)
    {
      return
    }
    let result = eventContinuation?.yield(event)
    if case .dropped(let shed)? = result {
      let cap = Self.eventBufferCap
      watcherLogger.error(
        "Worktree info event buffer full (cap \(cap)); shed oldest refresh signal: \(Self.label(for: shed)).")
    }
  }

  /// Compact identity for a backpressure-drop log. Strips the pull-request
  /// refresh's worktree-id list to a count so a drop storm can't flood the log;
  /// the single-id signals carry small payloads and describe themselves.
  private static func label(for event: WorktreeInfoWatcherClient.Event) -> String {
    switch event {
    case .repositoryPullRequestRefresh(let rootURL, let worktreeIDs):
      "repositoryPullRequestRefresh(\(rootURL.lastPathComponent), \(worktreeIDs.count) worktrees)"
    default: String(describing: event)
    }
  }

  private func cancelPullRequestSelectionCooldown(for repositoryRootURL: URL) {
    pullRequestSelectionCooldownTasksByRepo.removeValue(forKey: repositoryRootURL)?.task.cancel()
  }

  private func cancelAllPullRequestSelectionCooldownTasks() {
    for task in pullRequestSelectionCooldownTasksByRepo.values {
      task.task.cancel()
    }
    pullRequestSelectionCooldownTasksByRepo.removeAll()
  }

  private func shouldImmediatelyRefreshPullRequests(repositoryRootURL: URL) -> Bool {
    guard pullRequestSelectionCooldownTasksByRepo[repositoryRootURL] == nil else {
      return false
    }
    let cooldown = pullRequestSelectionRefreshCooldown
    let sleep = self.sleep
    let taskID = UUID()
    let task = Task { [weak self, sleep, taskID] in
      do {
        try await sleep(cooldown)
      } catch {
        return
      }
      await MainActor.run {
        guard
          let self,
          self.pullRequestSelectionCooldownTasksByRepo[repositoryRootURL]?.id == taskID
        else {
          return
        }
        self.pullRequestSelectionCooldownTasksByRepo.removeValue(forKey: repositoryRootURL)
      }
    }
    pullRequestSelectionCooldownTasksByRepo[repositoryRootURL] = PullRequestSelectionCooldownTask(
      id: taskID,
      task: task
    )
    return true
  }
}
