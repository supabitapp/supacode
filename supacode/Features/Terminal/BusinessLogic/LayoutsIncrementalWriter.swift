import Dependencies
import Foundation
import SupacodeSettingsShared

/// Serialized off-main writer for incremental layout persistence. Every flush
/// re-reads `layouts.json` from disk, splices in only the per-worktree keys it
/// carries, then writes the whole file back through the atomic temp+rename
/// `settingsFileStorage.save`. Being an actor makes the read-modify-write a
/// FIFO critical section: a positive record and a delete tombstone for the
/// same key can't interleave, and concurrent keys from separate flushes both
/// survive (last-writer-wins per key, not whole-file).
///
/// There is no flock / NSFileCoordinator: a second Supacode instance writing
/// the same file concurrently is a dev-only scenario and accepted as
/// last-writer-wins. The store's layout state is the source of truth on main;
/// this actor only owns the encode + disk merge.
actor LayoutsIncrementalWriter {
  /// One per-worktree change to splice into the v2 file. `.delete` is an
  /// explicit tombstone: absence from a flush means "leave the disk key alone",
  /// so a pruned worktree must be carried as `.delete`, never as omission.
  enum RecordChange: Sendable {
    case record(LayoutRecord)
    case delete
  }

  private static let logger = SupaLogger("Layouts")
  /// Dedicated executor so the sync disk I/O never runs on the cooperative
  /// pool, and never on main when the test main serial executor is active.
  private nonisolated let executorQueue = DispatchSerialQueue(label: "app.supabit.supacode.layouts-writer")
  nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }
  private let storage: SettingsFileStorage
  private let url: URL
  /// Guards the read-modify-write so the off-actor `flushSync` (on-quit) and the
  /// actor-routed flush/delete paths mutually exclude. The actor still owns FIFO
  /// ordering of the live path; this only prevents a lost update against the
  /// single off-actor entrant.
  private let writeLock = NSLock()

  init(
    storage: SettingsFileStorage,
    url: URL = SupacodePaths.layoutsURL
  ) {
    self.storage = storage
    self.url = url
  }

  /// Re-reads the on-disk file, applies `changes`, and writes the result.
  /// Keys not present in `changes` are preserved from disk untouched.
  func flush(records changes: [String: RecordChange]) {
    applyAndWriteRecords(changes)
  }

  /// Synchronous variant for the on-quit terminal write, where the run loop is
  /// tearing down and there's no chance to await the actor. The atomic temp+rename
  /// `storage.save` makes the off-actor write safe as the process's final flush.
  nonisolated func flushSync(records changes: [String: RecordChange]) {
    applyAndWriteRecords(changes)
  }

  private nonisolated func applyAndWriteRecords(_ changes: [String: RecordChange]) {
    guard !changes.isEmpty else { return }
    writeLock.lock()
    defer { writeLock.unlock() }
    guard var file = readFileFromDisk() else { return }
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
    write(file)
  }

  /// Returns the on-disk v2 file; an empty stamped file when absent or after
  /// corrupt bytes were rotated aside; `nil` on a present-but-unreadable file
  /// or a still-v1 file, so the caller aborts rather than clobbers it.
  private nonisolated func readFileFromDisk() -> LayoutsFile? {
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      guard Self.isFileAbsent(error) else {
        Self.logger.error("Failed to read layouts during v2 merge: \(error)")
        return nil
      }
      return LayoutsFile(worktrees: [:])
    }
    if let file = try? JSONDecoder().decode(LayoutsFile.self, from: data) {
      return file
    }
    if (try? JSONDecoder().decode([String: FailableDecodable<TerminalLayoutSnapshot>].self, from: data)) != nil {
      // A deferred migration left v1 bytes in place; they must survive for the
      // next launch's migrator, so this flush is dropped.
      Self.logger.error("Aborting v2 layout flush: layouts.json is still v1.")
      return nil
    }
    Self.logger.error("Failed to decode layouts during v2 merge; rotating aside.")
    Self.renameCorruptFile(at: url)
    return LayoutsFile(worktrees: [:])
  }

  private nonisolated func write(_ file: LayoutsFile) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(file)
      try storage.save(data, url)
    } catch {
      Self.logger.warning("Failed to write incremental layouts: \(error)")
    }
  }

  /// True only when the read failed because the file does not exist.
  static func isFileAbsent(_ error: Error) -> Bool {
    if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile { return true }
    if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
    return false
  }

  /// Moves a corrupt `layouts.json` aside to `layouts.json.corrupt-<ISO8601>` so
  /// the next save starts fresh instead of aborting forever. The storage dep only
  /// exposes load/save, so the rename goes through FileManager; a missing or
  /// already-renamed file returns quietly and the caller proceeds to the fresh dict.
  private nonisolated static func renameCorruptFile(at url: URL) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: Date()).replacing(":", with: "-")
    let destination = url.deletingLastPathComponent()
      .appending(path: "\(url.lastPathComponent).corrupt-\(timestamp)", directoryHint: .notDirectory)
    do {
      try SymlinkPreservingFileWriter.moveAside(at: url, to: destination)
    } catch {
      Self.logger.warning(
        "Failed to rename corrupt layouts file to \(destination.lastPathComponent): \(error).")
    }
  }

}
