import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

nonisolated struct LayoutsKeyID: Hashable, Sendable {}

/// Load-only reader for the persisted v2 layouts file. A still-v1 file (a
/// deferred migration) migrates in memory so readers never see an empty file
/// while real records exist on disk.
nonisolated struct LayoutsKey: SharedKey {
  private static let logger = SupaLogger("Layouts")

  var id: LayoutsKeyID { LayoutsKeyID() }

  func load(
    context _: LoadContext<LayoutsFile>,
    continuation: LoadContinuation<LayoutsFile>
  ) {
    // Absent and unreadable both serve the empty initial value here: this
    // reader only seeds sidebar badges. Destructive consumers (the orphan
    // reaper) read `LayoutsFile.readFromDisk()` directly and skip on
    // `.unreadable`.
    switch LayoutsFile.readFromDisk() {
    case .file(let file):
      continuation.resume(returning: file)
    case .absent, .unreadable:
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<LayoutsFile>,
    subscriber _: SharedSubscriber<LayoutsFile>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _: LayoutsFile,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    // No-op: `LayoutsIncrementalWriter` is the sole disk writer for `layouts.json`.
    continuation.resume()
  }
}

nonisolated extension SharedReaderKey where Self == LayoutsKey.Default {
  static var layouts: Self {
    Self[LayoutsKey(), default: LayoutsFile(worktrees: [:])]
  }
}
