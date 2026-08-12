import Dependencies
import Foundation
import SupacodeSettingsShared

/// Thread-safe UserDefaults handle for the layouts blob. `UserDefaults` is
/// documented thread-safe, so `@unchecked Sendable` is honest, and `nonisolated`
/// lets the off-main writer own the read-modify-write without hopping to the main
/// actor (the module defaults to main-actor isolation).
nonisolated struct LayoutsUserDefaultsStore: @unchecked Sendable {
  let defaults: UserDefaults

  func read() -> Data? { defaults.data(forKey: LayoutsFile.userDefaultsKey) }
  func write(_ data: Data) { defaults.set(data, forKey: LayoutsFile.userDefaultsKey) }

  /// Stashes an undecodable blob under a sibling key so a wholly-unreadable value
  /// (genuine corruption, or a newer schema after a downgrade) survives for
  /// diagnosis while the live store recovers to a fresh value.
  func stashCorrupt(_ data: Data) { defaults.set(data, forKey: LayoutsFile.userDefaultsKey + ".corrupt") }

  /// Forces a synchronous flush for the on-quit write, where the run loop is
  /// tearing down before UserDefaults' own periodic flush would run.
  func synchronize() { defaults.synchronize() }
}

/// Serialized off-main writer for incremental layout persistence. Every flush
/// re-reads the layouts blob from UserDefaults, splices in only the per-worktree
/// keys it carries, then writes the whole value back. Being an actor makes the
/// read-modify-write a FIFO critical section: a positive record and a delete
/// tombstone for the same key can't interleave, and concurrent keys from
/// separate flushes both survive (last-writer-wins per key, not whole-file).
actor LayoutsIncrementalWriter {
  /// One per-worktree change to splice into the value. `.delete` is an explicit
  /// tombstone: absence from a flush means "leave the key alone", so a pruned
  /// worktree must be carried as `.delete`, never as omission.
  enum RecordChange: Sendable {
    case record(LayoutRecord)
    case delete
  }

  private static let logger = SupaLogger("Layouts")
  /// Dedicated executor so the encode never runs on the cooperative pool, and
  /// never on main when the test main serial executor is active.
  private nonisolated let executorQueue = DispatchSerialQueue(label: "app.supabit.supacode.layouts-writer")
  nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }
  private let store: LayoutsUserDefaultsStore
  /// Redundant now that `flushSync` also runs on `executorQueue`, so the queue
  /// serializes every write and owns their ordering; kept as belt-and-suspenders
  /// mutual exclusion around the read-modify-write.
  private let writeLock = NSLock()

  init(store: LayoutsUserDefaultsStore) {
    self.store = store
  }

  /// Re-reads the persisted value, applies `changes`, and writes the result.
  /// Keys not present in `changes` are preserved untouched.
  func flush(records changes: [String: RecordChange]) {
    applyAndWriteRecords(changes, synchronize: false)
  }

  /// Synchronous variant for the on-quit terminal write, where the run loop is
  /// tearing down and there's no chance to await the actor. Runs on the writer's
  /// serial executor so this terminal write is FIFO-ordered strictly after any
  /// flush already enqueued at quit, never overtaken and regressed by a late one.
  /// Forces a UserDefaults flush so the last write survives termination.
  nonisolated func flushSync(records changes: [String: RecordChange]) {
    executorQueue.sync { applyAndWriteRecords(changes, synchronize: true) }
  }

  private nonisolated func applyAndWriteRecords(_ changes: [String: RecordChange], synchronize: Bool) {
    guard !changes.isEmpty else { return }
    writeLock.lock()
    defer { writeLock.unlock() }
    guard var file = readPersisted() else { return }
    // A newer schema is read-only for this build; never write into it.
    guard file.schemaVersion <= LayoutsFile.currentSchemaVersion else {
      Self.logger.warning("Skipping layout flush into newer schema v\(file.schemaVersion).")
      return
    }
    let original = file
    for (key, change) in changes {
      switch change {
      case .record(let record):
        // The migration origin is write-once; preserve it when the caller
        // carries none.
        file.worktrees[key] = LayoutRecord(
          layout: record.layout,
          origin: record.origin ?? file.worktrees[key]?.origin
        )
      case .delete:
        file.worktrees.removeValue(forKey: key)
      }
    }
    guard file != original else { return }
    write(file, synchronize: synchronize)
  }

  /// The persisted layouts; an empty stamped value when absent or after a
  /// wholly-undecodable blob is stashed aside; `nil` (abort the flush) only on a
  /// lossy-but-decodable value, so the caller never makes partial loss permanent.
  /// A wholly-undecodable blob (genuine corruption, or a newer schema after a
  /// downgrade) is stashed under a sibling key before starting fresh, so it is
  /// preserved for recovery without wedging persistence forever.
  private nonisolated func readPersisted() -> LayoutsFile? {
    guard let data = store.read() else { return LayoutsFile(worktrees: [:]) }
    let decoder = JSONDecoder()
    decoder.userInfo[.layoutDecodeLoss] = LayoutDecodeLoss()
    guard let file = try? decoder.decode(LayoutsFile.self, from: data) else {
      Self.logger.error("Persisted layouts blob undecodable; stashing it aside and starting fresh.")
      store.stashCorrupt(data)
      return LayoutsFile(worktrees: [:])
    }
    guard file.undecodedEntryCount == 0 else {
      Self.logger.error("Aborting layout flush: persisted blob has unreadable entries.")
      return nil
    }
    return file
  }

  private nonisolated func write(_ file: LayoutsFile, synchronize: Bool) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      store.write(try encoder.encode(file))
      if synchronize { store.synchronize() }
    } catch {
      Self.logger.warning("Failed to write incremental layouts: \(error)")
    }
  }

  /// True only when a file read failed because the file does not exist. Retained
  /// for the legacy `layouts.json` readers in the migration path.
  static func isFileAbsent(_ error: Error) -> Bool {
    if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
    if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
    return false
  }
}
