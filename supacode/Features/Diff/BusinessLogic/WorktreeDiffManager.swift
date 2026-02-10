import Darwin
import Dispatch
import Foundation

@MainActor
@Observable
final class WorktreeDiffManager {
  private struct HeadWatcher {
    let headURL: URL
    let source: DispatchSourceFileSystemObject
  }

  private var worktrees: [Worktree.ID: Worktree] = [:]
  private var states: [Worktree.ID: WorktreeDiffState] = [:]
  private var headWatchers: [Worktree.ID: HeadWatcher] = [:]
  private var debounceTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var restartTasks: [Worktree.ID: Task<Void, Never>] = [:]
  private var selectedWorktreeID: Worktree.ID?
  private var panelVisible = false
  private var eventContinuation: AsyncStream<DiffClient.Event>.Continuation?

  func handleCommand(_ command: DiffClient.Command) {
    switch command {
    case .setWorktrees(let worktrees):
      setWorktrees(worktrees)
    case .setSelectedWorktreeID(let id):
      setSelectedWorktreeID(id)
    case .setPanelVisible(let visible):
      setPanelVisible(visible)
    case .prune(let ids):
      prune(ids)
    }
  }

  func eventStream() -> AsyncStream<DiffClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: DiffClient.Event.self)
    eventContinuation = continuation
    return stream
  }

  func diffState(for worktreeID: Worktree.ID) -> WorktreeDiffState? {
    states[worktreeID]
  }

  private func setWorktrees(_ worktreeList: [Worktree]) {
    let worktreesByID = Dictionary(uniqueKeysWithValues: worktreeList.map { ($0.id, $0) })
    let desiredIDs = Set(worktreesByID.keys)
    let currentIDs = Set(worktrees.keys)
    let removedIDs = currentIDs.subtracting(desiredIDs)
    for id in removedIDs {
      stopWatcher(for: id)
      states.removeValue(forKey: id)
    }
    worktrees = worktreesByID
    guard panelVisible else { return }
    for worktree in worktreeList {
      configureWatcher(for: worktree)
    }
  }

  private func setSelectedWorktreeID(_ id: Worktree.ID?) {
    guard selectedWorktreeID != id else { return }
    selectedWorktreeID = id
    guard panelVisible, let id, let worktree = worktrees[id] else { return }
    let state = getOrCreateState(for: worktree)
    state.refresh()
  }

  private func setPanelVisible(_ visible: Bool) {
    guard panelVisible != visible else { return }
    panelVisible = visible
    if visible {
      for worktree in worktrees.values {
        configureWatcher(for: worktree)
      }
      if let id = selectedWorktreeID, let worktree = worktrees[id] {
        let state = getOrCreateState(for: worktree)
        state.refresh()
      }
    } else {
      for id in headWatchers.keys {
        stopWatcher(for: id)
      }
    }
  }

  private func prune(_ validIDs: Set<Worktree.ID>) {
    let currentIDs = Set(worktrees.keys)
    let removedIDs = currentIDs.subtracting(validIDs)
    for id in removedIDs {
      stopWatcher(for: id)
      states.removeValue(forKey: id)
      worktrees.removeValue(forKey: id)
    }
  }

  private func getOrCreateState(for worktree: Worktree) -> WorktreeDiffState {
    if let existing = states[worktree.id] { return existing }
    let state = WorktreeDiffState(worktree: worktree)
    let worktreeID = worktree.id
    state.onEntriesChanged = { [weak self] entries in
      self?.emit(.entriesChanged(worktreeID: worktreeID, entries: entries))
    }
    state.onLoadingChanged = { [weak self] isLoading in
      self?.emit(.loadingChanged(worktreeID: worktreeID, isLoading: isLoading))
    }
    states[worktree.id] = state
    return state
  }

  private func configureWatcher(for worktree: Worktree) {
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
    guard fileDescriptor >= 0 else { return }
    let queue = DispatchQueue(label: "diff-watcher.\(worktreeID)")
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .rename, .delete, .attrib],
      queue: queue
    )
    source.setEventHandler { [weak self, weak source] in
      guard let source else { return }
      let event = source.data
      Task { @MainActor in
        self?.handleFileEvent(worktreeID: worktreeID, event: event)
      }
    }
    source.setCancelHandler {
      close(fileDescriptor)
    }
    source.resume()
    headWatchers[worktreeID] = HeadWatcher(headURL: headURL, source: source)
  }

  private func handleFileEvent(
    worktreeID: Worktree.ID,
    event: DispatchSource.FileSystemEvent
  ) {
    if event.contains(.delete) || event.contains(.rename) {
      stopHeadWatcher(for: worktreeID)
      scheduleRestart(worktreeID: worktreeID)
    }
    scheduleRefresh(worktreeID: worktreeID)
  }

  private func scheduleRefresh(worktreeID: Worktree.ID) {
    debounceTasks[worktreeID]?.cancel()
    let task = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      await MainActor.run {
        guard let self, let state = self.states[worktreeID] else { return }
        state.refresh()
      }
    }
    debounceTasks[worktreeID] = task
  }

  private func scheduleRestart(worktreeID: Worktree.ID) {
    restartTasks[worktreeID]?.cancel()
    let task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      await MainActor.run {
        guard let self, let worktree = self.worktrees[worktreeID] else { return }
        self.configureWatcher(for: worktree)
      }
    }
    restartTasks[worktreeID] = task
  }

  private func stopHeadWatcher(for worktreeID: Worktree.ID) {
    if let watcher = headWatchers.removeValue(forKey: worktreeID) {
      watcher.source.cancel()
    }
  }

  private func stopWatcher(for worktreeID: Worktree.ID) {
    stopHeadWatcher(for: worktreeID)
    debounceTasks.removeValue(forKey: worktreeID)?.cancel()
    restartTasks.removeValue(forKey: worktreeID)?.cancel()
  }

  private func emit(_ event: DiffClient.Event) {
    eventContinuation?.yield(event)
  }
}
