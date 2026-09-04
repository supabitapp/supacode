import CoreServices
import Darwin
import Dispatch
import Foundation
import SupacodeSettingsShared

private let watcherLogger = SupaLogger("WorktreeInfoWatcher")

private final class WorktreeFileEventMonitor {
  let rootURLs: [URL]
  private let onEvent: @MainActor @Sendable () -> Void
  private nonisolated(unsafe) var stream: FSEventStreamRef?

  init?(
    rootURLs: [URL],
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) {
    self.rootURLs = rootURLs
    self.onEvent = onEvent
    guard !rootURLs.isEmpty else {
      return nil
    }
    let paths = rootURLs.map { $0.path(percentEncoded: false) }
    var context = FSEventStreamContext(
      version: 0,
      info: nil,
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    context.info = Unmanaged.passUnretained(self).toOpaque()
    let callback: FSEventStreamCallback = { _, callbackInfo, _, _, _, _ in
      guard let callbackInfo else { return }
      let monitor = Unmanaged<WorktreeFileEventMonitor>
        .fromOpaque(callbackInfo)
        .takeUnretainedValue()
      Task { @MainActor in
        monitor.onEvent()
      }
    }
    stream = FSEventStreamCreate(
      nil,
      callback,
      &context,
      paths as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      1.0,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagNoDefer
          | kFSEventStreamCreateFlagWatchRoot
      )
    )
    guard let stream else {
      return nil
    }
    FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      return nil
    }
  }

  deinit {
    Self.release(&stream)
  }

  func cancel() {
    Self.release(&stream)
  }

  private nonisolated static func release(_ stream: inout FSEventStreamRef?) {
    guard let streamRef = stream else {
      return
    }
    FSEventStreamStop(streamRef)
    FSEventStreamInvalidate(streamRef)
    FSEventStreamRelease(streamRef)
    stream = nil
  }
}

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

  private struct RefreshTiming: Equatable {
    let focused: Duration
    let unfocused: Duration
  }

  private let filesChangedDebounceInterval: Duration
  private let pullRequestSelectionRefreshCooldown: Duration
  private let refreshTiming: RefreshTiming
  /// Gap between self-healing reconcile sweeps. Rare on purpose: the fast path
  /// is event-driven, and this only backstops signals with no local event
  /// (remote line counts, GitHub merges, a dead watcher).
  private var reconcileInterval: Duration
  /// Delay between reconciling successive worktrees / repos so a sweep rolls
  /// through them one at a time instead of fanning a diff storm.
  private let reconcileStep: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  /// Resolves a remote worktree's current branch over SSH. Injected so tests
  /// can drive the poll loop without a real connection (real-host SSH is
  /// verified separately). Returns `nil` for a local worktree or on error.
  private let pollRemoteBranch: @Sendable (Worktree) async -> String?
  private var worktrees: [Worktree.ID: Worktree] = [:]
  private var headWatchers: [Worktree.ID: HeadWatcher] = [:]
  private var fileEventMonitors: [Worktree.ID: WorktreeFileEventMonitor] = [:]
  /// Remote worktrees can't kqueue their `.git/HEAD` (it lives on another
  /// host), so they poll `git rev-parse` over SSH on the same focused /
  /// unfocused cadence.
  private var remoteHeadPollTasks: [Worktree.ID: RefreshTask] = [:]
  private var lastKnownRemoteBranch: [Worktree.ID: String] = [:]
  private var branchDebounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var filesDebounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var restartTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var lineChangeRefreshTasks: [Worktree.ID: Task<Void, Never>] = [:]
  /// Worktrees whose file-event monitor / HEAD kqueue failed to start. Tracked
  /// so the reconcile retry logs once per failure, not once per attempt. Cleared
  /// on success or on worktree removal, never on the re-arm teardown.
  private var fileEventMonitorFailedIDs: Set<Worktree.ID> = []
  private var headWatcherFailedIDs: Set<Worktree.ID> = []
  private var deferredLineChangeIDs: Set<Worktree.ID> = []
  private var hasCompletedInitialWorktreeLoad = false
  private var selectedWorktreeID: Worktree.ID?
  private var pullRequestTrackingEnabled = true
  /// User setting: when false, all background repository polling is off.
  private var automaticRefreshEnabled: Bool
  /// Whether the app is foreground-active. Background polling (remote SSH HEAD
  /// poll + reconcile sweep) only runs while active, so an idle / backgrounded
  /// app is quiet.
  private var isActive = true
  private var reconcileTask: Task<Void, Never>?
  private var pullRequestSelectionCooldownTasksByRepo: [URL: PullRequestSelectionCooldownTask] = [:]
  private var eventContinuation: AsyncStream<WorktreeInfoWatcherClient.Event>.Continuation?

  init<C: Clock<Duration>>(
    focusedInterval: Duration = .seconds(30),
    unfocusedInterval: Duration = .seconds(60),
    filesChangedDebounceInterval: Duration = .seconds(5),
    pullRequestSelectionRefreshCooldown: Duration = .seconds(5),
    reconcileInterval: Duration = .seconds(300),
    reconcileStep: Duration = .seconds(2),
    automaticRefreshEnabled: Bool = true,
    clock: C = ContinuousClock(),
    pollRemoteBranch: @escaping @Sendable (Worktree) async -> String? = { worktree in
      guard let host = worktree.host else { return nil }
      return await GitClient(shell: .ssh(host: host)).symbolicHeadBranch(at: worktree.workingDirectory)
    }
  ) {
    refreshTiming = RefreshTiming(focused: focusedInterval, unfocused: unfocusedInterval)
    self.filesChangedDebounceInterval = filesChangedDebounceInterval
    self.pullRequestSelectionRefreshCooldown = pullRequestSelectionRefreshCooldown
    self.reconcileInterval = reconcileInterval
    self.reconcileStep = reconcileStep
    self.automaticRefreshEnabled = automaticRefreshEnabled
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
    case .setAutomaticRefreshEnabled(let isEnabled):
      setAutomaticRefreshEnabled(isEnabled)
    case .setAutomaticRefreshInterval(let interval):
      setAutomaticRefreshInterval(interval)
    case .setActive(let active):
      setActive(active)
    case .refresh:
      refreshAll()
    case .stop:
      stopAll()
    }
  }

  /// Gates only the timer-driven loops (reconcile sweep + remote SSH HEAD
  /// poll), not the local file-event monitors, which stay live and cheap.
  private var backgroundPollingAllowed: Bool {
    isActive && automaticRefreshEnabled
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
    let previousWorktrees = self.worktrees
    // Keep the first entry on a duplicate WorktreeID instead of trapping; a repo registered
    // under both its working dir and `.bare/` enumerates the same worktree twice.
    let worktreesByID = Dictionary(worktrees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let desiredIDs = Set(worktreesByID.keys)
    let currentIDs = Set(self.worktrees.keys)
    let removedIDs = currentIDs.subtracting(desiredIDs)
    for id in removedIDs {
      stopWatcher(for: id)
    }
    if !removedIDs.isEmpty {
      deferredLineChangeIDs.subtract(removedIDs)
      fileEventMonitorFailedIDs.subtract(removedIDs)
      headWatcherFailedIDs.subtract(removedIDs)
    }
    let newIDs = desiredIDs.subtracting(currentIDs)
    if !newIDs.isEmpty && !isInitialWorktreeLoad {
      deferredLineChangeIDs.formUnion(newIDs)
    }
    self.worktrees = worktreesByID
    // Iterate the de-duplicated values so a duplicate WorktreeID doesn't configure
    // the same watcher or emit its immediate refresh twice.
    var repositoryRoots: Set<URL> = []
    var repositoryRootsToRefresh = Set(removedIDs.compactMap { previousWorktrees[$0]?.repositoryRootURL })
    for worktree in worktreesByID.values {
      configureWatcher(for: worktree)
      let didWorktreeChange = previousWorktrees[worktree.id] != worktree
      if isInitialWorktreeLoad || newIDs.contains(worktree.id) || didWorktreeChange {
        repositoryRootsToRefresh.insert(worktree.repositoryRootURL)
        // A remote worktree's line count is read over SSH, so this roster-driven
        // refresh honors the background-polling gate; local diffs are cheap,
        // never SSH, and stay so a discovered worktree shows its counts.
        if worktree.host == nil || backgroundPollingAllowed {
          let isDeferred = deferredLineChangeIDs.contains(worktree.id)
          if isDeferred {
            scheduleLineChangeRefresh(worktreeID: worktree.id, delay: refreshInterval(for: worktree.id))
          } else {
            emitLineChangesChanged(worktreeID: worktree.id)
          }
        }
      }
      repositoryRoots.insert(worktree.repositoryRootURL)
    }
    if isInitialWorktreeLoad {
      hasCompletedInitialWorktreeLoad = true
    }
    for repositoryRootURL in repositoryRootsToRefresh {
      refreshPullRequests(repositoryRootURL: repositoryRootURL)
    }
    let obsoleteCooldownRepositories = pullRequestSelectionCooldownTasksByRepo.keys.filter {
      !repositoryRoots.contains($0)
    }
    for repositoryRootURL in obsoleteCooldownRepositories {
      cancelPullRequestSelectionCooldown(for: repositoryRootURL)
    }
    startReconcileLoop()
  }

  private func setSelectedWorktreeID(_ worktreeID: Worktree.ID?) {
    guard selectedWorktreeID != worktreeID else {
      return
    }
    let previousWorktreeID = selectedWorktreeID
    let previousRepository = previousWorktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    selectedWorktreeID = worktreeID
    let nextRepository = worktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    if let previousWorktreeID, let worktree = worktrees[previousWorktreeID] {
      configureRemoteHeadPoll(for: worktree)
    }
    if let worktreeID {
      emitLineChangesChanged(worktreeID: worktreeID)
      if let worktree = worktrees[worktreeID] {
        configureRemoteHeadPoll(for: worktree)
      }
    }
    if let previousRepository, previousRepository == nextRepository {
      if shouldImmediatelyRefreshPullRequests(repositoryRootURL: previousRepository) {
        refreshPullRequests(repositoryRootURL: previousRepository)
      }
      return
    }
    if let nextRepository, shouldImmediatelyRefreshPullRequests(repositoryRootURL: nextRepository) {
      refreshPullRequests(repositoryRootURL: nextRepository)
    }
  }

  private func configureWatcher(for worktree: Worktree) {
    // Remote worktrees live on another host; their HEAD can't be kqueue'd, so
    // route them to the SSH poll loop and skip the local head-file resolver
    // (which would return nil for a non-local path and silently drop the row).
    if worktree.host != nil {
      stopHeadWatcher(for: worktree.id)
      stopFileEventMonitor(for: worktree.id)
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
      configureFileEventMonitor(for: worktree)
      return
    }
    stopWatcher(for: worktree.id)
    configureFileEventMonitor(for: worktree)
    startWatcher(worktreeID: worktree.id, headURL: headURL)
  }

  private func startWatcher(worktreeID: Worktree.ID, headURL: URL) {
    let path = headURL.path(percentEncoded: false)
    let fileDescriptor = open(path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      // A dead HEAD kqueue misses branch changes; the reconcile backstop's
      // catch-up re-emits once it re-arms. Log once so a persistent failure
      // doesn't spam a line every sweep.
      if headWatcherFailedIDs.insert(worktreeID).inserted {
        watcherLogger.error("Failed to open \(path) for HEAD watching (errno \(errno)).")
      }
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
    headWatcherFailedIDs.remove(worktreeID)
  }

  /// File-event roots for a local worktree: its working tree, plus the
  /// linked-worktree admin dir when that lives outside the tree. A commit on a
  /// branch rewrites the admin dir's index / reflog without touching a watched
  /// working-tree file, so watching it heals the line count at event speed.
  func fileEventRoots(for worktree: Worktree) -> [URL] {
    var roots = [worktree.workingDirectory]
    guard
      let headURL = GitWorktreeHeadResolver.headURL(
        for: worktree.workingDirectory,
        fileManager: .default
      )
    else {
      return roots
    }
    let adminDir = headURL.deletingLastPathComponent().standardizedFileURL
    let embeddedGitDir = worktree.workingDirectory.appending(path: ".git").standardizedFileURL
    if adminDir != embeddedGitDir {
      roots.append(adminDir)
    }
    return roots
  }

  private func configureFileEventMonitor(for worktree: Worktree) {
    let roots = fileEventRoots(for: worktree)
    if let existing = fileEventMonitors[worktree.id], existing.rootURLs == roots {
      return
    }
    // Tear down only the monitor value; keep the failed-set so retries log once.
    fileEventMonitors.removeValue(forKey: worktree.id)?.cancel()
    let monitor = WorktreeFileEventMonitor(
      rootURLs: roots
    ) { [weak self] in
      self?.scheduleFilesChanged(worktreeID: worktree.id)
    }
    guard let monitor else {
      if fileEventMonitorFailedIDs.insert(worktree.id).inserted {
        let path = worktree.workingDirectory.path(percentEncoded: false)
        watcherLogger.error(
          "Failed to start filesystem monitor for \(path); relying on the reconcile backstop until it recovers."
        )
      }
      return
    }
    fileEventMonitorFailedIDs.remove(worktree.id)
    fileEventMonitors[worktree.id] = monitor
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
      guard !Task.isCancelled else {
        return
      }
      await MainActor.run {
        self?.emitBranchChanged(worktreeID: worktreeID)
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
      guard !Task.isCancelled else {
        return
      }
      await MainActor.run {
        guard let self else { return }
        self.emitLineChangesChanged(worktreeID: worktreeID)
      }
    }
    filesDebounceTasks[worktreeID] = task
  }

  private func scheduleRestart(worktreeID: Worktree.ID) {
    restartTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(.seconds(5))
      guard !Task.isCancelled else {
        return
      }
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
    guard backgroundPollingAllowed else {
      return
    }
    let worktreeID = worktree.id
    let interval = refreshInterval(for: worktreeID)
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

  private func stopFileEventMonitor(for worktreeID: Worktree.ID) {
    // Runs on the re-arm teardown too, so it must not clear the failed-set.
    fileEventMonitors.removeValue(forKey: worktreeID)?.cancel()
  }

  private func stopWatcher(for worktreeID: Worktree.ID) {
    stopHeadWatcher(for: worktreeID)
    stopFileEventMonitor(for: worktreeID)
    stopRemoteHeadPoll(for: worktreeID)
    branchDebounceTasks.removeValue(forKey: worktreeID)?.cancel()
    filesDebounceTasks.removeValue(forKey: worktreeID)?.cancel()
    restartTasks.removeValue(forKey: worktreeID)?.cancel()
    lineChangeRefreshTasks.removeValue(forKey: worktreeID)?.cancel()
  }

  private func stopAll() {
    stopBackgroundRefreshTasks()
    deferredLineChangeIDs.removeAll()
    hasCompletedInitialWorktreeLoad = false
    worktrees.removeAll()
    selectedWorktreeID = nil
    pullRequestTrackingEnabled = true
    // `automaticRefreshEnabled` and `isActive` are user / session state, not
    // task state, so a teardown must not silently re-enable polling the user
    // turned off.
    eventContinuation?.finish()
  }

  private func stopBackgroundRefreshTasks() {
    stopReconcileLoop()
    for watcher in headWatchers.values {
      watcher.source.cancel()
    }
    for monitor in fileEventMonitors.values {
      monitor.cancel()
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
    for task in lineChangeRefreshTasks.values {
      task.cancel()
    }
    for task in remoteHeadPollTasks.values {
      task.task.cancel()
    }
    headWatchers.removeAll()
    fileEventMonitors.removeAll()
    fileEventMonitorFailedIDs.removeAll()
    headWatcherFailedIDs.removeAll()
    branchDebounceTasks.removeAll()
    filesDebounceTasks.removeAll()
    restartTasks.removeAll()
    lineChangeRefreshTasks.removeAll()
    remoteHeadPollTasks.removeAll()
    lastKnownRemoteBranch.removeAll()
    cancelAllPullRequestSelectionCooldownTasks()
  }

  private func setPullRequestTrackingEnabled(_ enabled: Bool) {
    guard pullRequestTrackingEnabled != enabled else {
      return
    }
    pullRequestTrackingEnabled = enabled
    if enabled {
      let repositoryRoots = Set(worktrees.values.map(\.repositoryRootURL))
      for repositoryRootURL in repositoryRoots {
        refreshPullRequests(repositoryRootURL: repositoryRootURL)
      }
      return
    }
    cancelAllPullRequestSelectionCooldownTasks()
  }

  private func refreshPullRequests(
    repositoryRootURL: URL,
    trigger: WorktreeInfoWatcherClient.RefreshTrigger = .automatic
  ) {
    guard pullRequestTrackingEnabled else {
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      return
    }
    emit(
      .repositoryPullRequestRefresh(
        repositoryRootURL: repositoryRootURL,
        worktreeIDs: worktreeIDs,
        trigger: trigger
      )
    )
  }

  private func refreshAll() {
    for worktree in sortedWorktrees() {
      // Re-arm the watcher so a manual refresh repairs a dead kqueue / file
      // event stream, not just re-emits from a still-broken one.
      configureWatcher(for: worktree)
      emitLineChangesChanged(worktreeID: worktree.id)
    }
    for repositoryRootURL in sortedRepositoryRoots() {
      refreshPullRequests(repositoryRootURL: repositoryRootURL, trigger: .manual)
    }
  }

  private func setAutomaticRefreshInterval(_ interval: Int) {
    let duration: Duration = .seconds(interval)
    guard reconcileInterval != duration else {
      return
    }
    reconcileInterval = duration
    reconfigureBackgroundPolling()
  }

  private func setAutomaticRefreshEnabled(_ enabled: Bool) {
    guard automaticRefreshEnabled != enabled else {
      return
    }
    automaticRefreshEnabled = enabled
    reconfigureBackgroundPolling()
  }

  private func setActive(_ active: Bool) {
    guard isActive != active else {
      return
    }
    isActive = active
    reconfigureBackgroundPolling()
  }

  private func reconfigureBackgroundPolling() {
    guard backgroundPollingAllowed else {
      stopReconcileLoop()
      for worktreeID in Array(remoteHeadPollTasks.keys) {
        stopRemoteHeadPoll(for: worktreeID)
      }
      return
    }
    for worktree in worktrees.values where worktree.host != nil {
      configureRemoteHeadPoll(for: worktree)
    }
    startReconcileLoop()
  }

  /// Self-healing backstop for signals no local event catches (remote line
  /// counts, external merges, a dead watcher). Rolls through worktrees one at a
  /// time so a sweep never fans a diff storm.
  private func startReconcileLoop() {
    guard backgroundPollingAllowed, !worktrees.isEmpty, reconcileTask == nil else {
      return
    }
    let sleep = self.sleep
    let interval = reconcileInterval
    let step = reconcileStep
    reconcileTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await sleep(interval)
        } catch {
          return
        }
        let worktrees = await MainActor.run { self?.sortedWorktrees() } ?? []
        for worktree in worktrees {
          guard !Task.isCancelled else {
            return
          }
          await MainActor.run { self?.reconcileWorktree(worktree) }
          do {
            try await sleep(step)
          } catch {
            return
          }
        }
        let repositoryRoots = await MainActor.run { self?.sortedRepositoryRoots() } ?? []
        for repositoryRootURL in repositoryRoots {
          guard !Task.isCancelled else {
            return
          }
          await MainActor.run { self?.refreshPullRequests(repositoryRootURL: repositoryRootURL) }
          do {
            try await sleep(step)
          } catch {
            return
          }
        }
      }
    }
  }

  private func stopReconcileLoop() {
    reconcileTask?.cancel()
    reconcileTask = nil
  }

  private func sortedWorktrees() -> [Worktree] {
    worktrees.values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  private func sortedRepositoryRoots() -> [URL] {
    Set(worktrees.values.map(\.repositoryRootURL)).sorted {
      $0.path(percentEncoded: false) < $1.path(percentEncoded: false)
    }
  }

  private func reconcileWorktree(_ worktree: Worktree) {
    guard let current = worktrees[worktree.id] else {
      return
    }
    // A dead local watcher misses events a since-now stream never replays, so
    // catch up once when re-arming; a live local watcher stays event-driven and
    // is never diffed on a timer.
    let localWatcherWasDead =
      current.host == nil
      && (headWatchers[current.id] == nil || fileEventMonitorFailedIDs.contains(current.id))
    configureWatcher(for: current)
    if current.host != nil {
      emitLineChangesChanged(worktreeID: current.id)
    } else if localWatcherWasDead {
      emitBranchChanged(worktreeID: current.id)
      emitLineChangesChanged(worktreeID: current.id)
    }
  }

  private func repositoryWorktreeIDs(for repositoryRootURL: URL) -> [Worktree.ID] {
    worktrees
      .values
      .filter { $0.repositoryRootURL == repositoryRootURL }
      .map(\.id)
      .sorted { $0.rawValue < $1.rawValue }
  }

  private func refreshInterval(for worktreeID: Worktree.ID) -> Duration {
    worktreeID == selectedWorktreeID ? refreshTiming.focused : refreshTiming.unfocused
  }

  private func scheduleLineChangeRefresh(worktreeID: Worktree.ID, delay: Duration) {
    guard worktrees[worktreeID] != nil else {
      return
    }
    lineChangeRefreshTasks[worktreeID]?.cancel()
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      try? await sleep(delay)
      guard !Task.isCancelled else {
        return
      }
      await MainActor.run {
        self?.lineChangeRefreshTasks.removeValue(forKey: worktreeID)
        self?.emitLineChangesChanged(worktreeID: worktreeID)
      }
    }
    lineChangeRefreshTasks[worktreeID] = task
  }

  private func emitLineChangesChanged(worktreeID: Worktree.ID) {
    guard worktrees[worktreeID] != nil else {
      return
    }
    deferredLineChangeIDs.remove(worktreeID)
    emit(.filesChanged(worktreeID: worktreeID))
  }

  private func emitBranchChanged(worktreeID: Worktree.ID) {
    guard worktrees[worktreeID] != nil else {
      return
    }
    emit(.branchChanged(worktreeID: worktreeID))
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
    case .repositoryPullRequestRefresh(let rootURL, let worktreeIDs, _):
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
      try? await sleep(cooldown)
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
