import Dependencies
import Foundation
import SupacodeSettingsShared

/// Serialized off-main writer for incremental layout persistence. Every flush
/// re-reads `layouts.json` from disk, splices in only the per-worktree keys it
/// carries, then writes the whole dict back through the atomic temp+rename
/// `settingsFileStorage.save`. Being an actor makes the read-modify-write a
/// FIFO critical section: a positive snapshot and a delete tombstone for the
/// same key can't interleave, and concurrent keys from separate flushes both
/// survive (last-writer-wins per key, not whole-dict).
///
/// There is no flock / NSFileCoordinator: a second Supacode instance writing
/// the same file concurrently is a dev-only scenario and accepted as
/// last-writer-wins. The in-memory `@Shared(.layouts)` dict stays the source of
/// truth on main; this actor only owns the encode + disk merge.
actor LayoutsIncrementalWriter {
  /// One per-worktree change to splice into the on-disk dict. `.delete` is an
  /// explicit tombstone: absence from a flush means "leave the disk key alone",
  /// so a pruned worktree must be carried as `.delete`, never as omission.
  enum Change: Sendable {
    case snapshot(TerminalLayoutSnapshot)
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

  /// Re-reads the on-disk dict, applies `changes`, and writes the result.
  /// Keys not present in `changes` are preserved from disk untouched.
  func flush(_ changes: [String: Change]) {
    applyAndWrite(changes)
  }

  /// Synchronous variant for the on-quit terminal write, where the run loop is
  /// tearing down and there's no chance to await the actor. The atomic temp+rename
  /// `storage.save` makes the off-actor write safe as the process's final flush.
  nonisolated func flushSync(_ changes: [String: Change]) {
    applyAndWrite(changes)
  }

  private nonisolated func applyAndWrite(_ changes: [String: Change]) {
    guard !changes.isEmpty else { return }
    writeLock.lock()
    defer { writeLock.unlock() }
    guard var dict = readFromDisk() else {
      // Abort rather than splice our keys into an empty dict and clobber every other worktree's layout.
      Self.logger.error(
        "Aborting incremental layout flush: on-disk layouts failed to decode; preserving file for recovery.")
      return
    }
    let original = dict
    for (key, change) in changes {
      switch change {
      case .snapshot(let snapshot):
        dict[key] = snapshot
      case .delete:
        dict.removeValue(forKey: key)
      }
    }
    // Skip the write when the splice is a no-op. onTabProjectionChanged fires on
    // notification / focus / zoom deltas that aren't part of the snapshot, so an
    // agent tool-call storm would otherwise churn the file with identical bytes.
    guard dict != original else { return }
    write(dict)
  }

  /// Returns the on-disk dict, `[:]` when the file is absent (fresh start) or
  /// when corrupt bytes were rotated aside, or `nil` on a present-but-unreadable
  /// file (transient/permission error) so the caller aborts rather than clobbers it.
  private nonisolated func readFromDisk() -> [String: TerminalLayoutSnapshot]? {
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      // Only an absent file is a fresh start; a present-but-unreadable file must abort so we don't clobber siblings.
      guard Self.isFileAbsent(error) else {
        Self.logger.error("Failed to read layouts during incremental merge: \(error)")
        return nil
      }
      return [:]
    }
    do {
      return try JSONDecoder().decode([String: TerminalLayoutSnapshot].self, from: data)
    } catch {
      // Corrupt bytes: rotate aside and start fresh rather than refuse to save
      // forever. Mirrors SidebarPersistenceKey; the bytes are kept for recovery.
      Self.logger.error("Failed to decode layouts during incremental merge: \(error)")
      Self.renameCorruptFile(at: url)
      return [:]
    }
  }

  /// True only when the read failed because the file does not exist.
  private static func isFileAbsent(_ error: Error) -> Bool {
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

  private nonisolated func write(_ dict: [String: TerminalLayoutSnapshot]) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(dict)
      try storage.save(data, url)
    } catch {
      Self.logger.warning("Failed to write incremental layouts: \(error)")
    }
  }
}
