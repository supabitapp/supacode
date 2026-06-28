import ComposableArchitecture
import Foundation
import Observation
import Sharing
import SupacodeSettingsShared

private let notesLogger = SupaLogger("Notes")

/// Owns per-(worktree, tab) note content outside TCA, mirroring
/// `WorktreeTerminalManager`'s layout-persistence machinery: the in-memory
/// `@Shared(.notes)` dict is the source of truth on main, a debounced per-worktree
/// flush merges changes into `notes.json` through `NotesIncrementalWriter` (the
/// sole disk writer), and a synchronous flush handles the on-quit terminal write.
///
/// Keyed exactly like layouts: `worktreeID.rawValue` -> `tabID.uuidString`.
@MainActor
@Observable
final class WorktreeNotesManager {
  @ObservationIgnored
  @Shared(.notes) private var notes: [String: [String: NoteDocument]]

  @ObservationIgnored private let notesWriter: NotesIncrementalWriter
  /// Per-worktree debounce timers for incremental notes saves.
  @ObservationIgnored private var dirtyTasks: [Worktree.ID: Task<Void, Never>] = [:]
  /// Per-worktree in-flight positive flush Tasks. A delete awaits the live one
  /// for its key so `.delete` always lands after the `.snapshot`, preventing a
  /// stale positive flush from resurrecting a pruned worktree's notes.
  @ObservationIgnored private var flushTasks: [Worktree.ID: Task<Void, Never>] = [:]
  /// Sleeps the debounce window; injected so tests drive it with a `TestClock`.
  @ObservationIgnored private let debounceSleep: @Sendable (Duration) async throws -> Void
  private static let debounceDuration: Duration = .seconds(1)

  init<C: Clock<Duration>>(clock: C = ContinuousClock()) {
    self.debounceSleep = { duration in try await clock.sleep(for: duration) }
    @Dependency(\.settingsFileStorage) var settingsFileStorage
    self.notesWriter = NotesIncrementalWriter(storage: settingsFileStorage)
  }

  isolated deinit {
    for task in dirtyTasks.values { task.cancel() }
    for task in flushTasks.values { task.cancel() }
  }

  /// Current note for a tab, or `nil` when none is stored.
  func document(worktreeID: Worktree.ID, tabID: TerminalTabID) -> NoteDocument? {
    notes[worktreeID.rawValue]?[tabID.rawValue.uuidString]
  }

  /// Records an edit: updates the in-memory dict synchronously (so an on-quit
  /// flush sees the latest keystroke) and schedules a debounced disk merge. A
  /// `nil` document clears the tab key (empty-note no-trace semantics).
  func updateNote(worktreeID: Worktree.ID, tabID: TerminalTabID, document: NoteDocument?) {
    let wKey = worktreeID.rawValue
    let tKey = tabID.rawValue.uuidString
    $notes.withLock { dict in
      var sub = dict[wKey] ?? [:]
      if let document {
        sub[tKey] = document
      } else {
        sub.removeValue(forKey: tKey)
      }
      if sub.isEmpty {
        dict.removeValue(forKey: wKey)
      } else {
        dict[wKey] = sub
      }
    }
    markDirty(worktreeID: worktreeID)
  }

  /// Drops a single tab's note (tab closed). The tab UUID is never reused, so
  /// the deletion is permanent and correct.
  func deleteNote(worktreeID: Worktree.ID, tabID: TerminalTabID) {
    updateNote(worktreeID: worktreeID, tabID: tabID, document: nil)
  }

  /// Drops every note for a worktree (prune/teardown). Mirrors
  /// `deleteLayoutSnapshot`: cancels the debounce, clears the in-memory key, and
  /// awaits any in-flight positive flush before issuing the `.delete` so a
  /// debounced save can't resurrect the pruned worktree's notes.
  func deleteWorktreeNotes(worktreeID: Worktree.ID) {
    let wKey = worktreeID.rawValue
    dirtyTasks[worktreeID]?.cancel()
    dirtyTasks[worktreeID] = nil
    $notes.withLock { $0.removeValue(forKey: wKey) }
    let inflight = flushTasks[worktreeID]
    let writer = notesWriter
    let task = Task { [weak self] in
      await inflight?.value
      await writer.flush([wKey: .delete])
      self?.flushTasks[worktreeID] = nil
    }
    flushTasks[worktreeID] = task
  }

  /// Cancels every queued incremental save before the on-quit synchronous flush.
  func cancelPendingNotesSaves() {
    for task in dirtyTasks.values { task.cancel() }
    dirtyTasks.removeAll()
    for task in flushTasks.values { task.cancel() }
    flushTasks.removeAll()
  }

  /// Synchronous on-quit terminal write of the whole in-memory dict. The actor
  /// is the sole disk writer, so this persists the current `@Shared` snapshot
  /// without awaiting; the writer's equality gate skips unchanged keys.
  func flushAllSync() {
    var changes: [String: NotesIncrementalWriter.Change] = [:]
    for (wKey, sub) in notes {
      changes[wKey] = .snapshot(sub)
    }
    guard !changes.isEmpty else { return }
    notesWriter.flushSync(changes)
  }

  /// Schedules a debounced incremental save for `worktreeID`, coalescing a burst
  /// of edits into one write. Mirrors `markLayoutDirty`.
  private func markDirty(worktreeID: Worktree.ID) {
    dirtyTasks[worktreeID]?.cancel()
    dirtyTasks[worktreeID] = Task { [weak self, debounceSleep] in
      try? await debounceSleep(Self.debounceDuration)
      guard !Task.isCancelled else { return }
      self?.flush(worktreeID: worktreeID)
    }
  }

  /// Fires after the debounce window: merges the worktree's current sub-dict into
  /// `notes.json` off main. Its only caller is `markDirty`.
  private func flush(worktreeID: Worktree.ID) {
    dirtyTasks[worktreeID] = nil
    let wKey = worktreeID.rawValue
    let change: NotesIncrementalWriter.Change = notes[wKey].map { .snapshot($0) } ?? .delete
    let writer = notesWriter
    let task = Task { [weak self] in
      await writer.flush([wKey: change])
      self?.flushTasks[worktreeID] = nil
    }
    flushTasks[worktreeID] = task
  }
}
