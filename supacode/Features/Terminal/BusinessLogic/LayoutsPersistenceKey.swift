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
    @Dependency(\.settingsFileStorage) var storage
    let data: Data
    do {
      data = try storage.load(SupacodePaths.layoutsURL)
    } catch {
      // File does not exist yet — expected on first run.
      continuation.resumeReturningInitialValue()
      return
    }
    if let file = try? JSONDecoder().decode(LayoutsFile.self, from: data) {
      continuation.resume(returning: file)
      return
    }
    if let raw = try? JSONDecoder().decode(
      [String: FailableDecodable<TerminalLayoutSnapshot>].self, from: data
    ) {
      continuation.resume(returning: LayoutsMigrator.migrate(raw.compactMapValues(\.value)))
      return
    }
    Self.logger.warning(
      "Failed to decode layouts from \(SupacodePaths.layoutsURL.path(percentEncoded: false))"
    )
    continuation.resumeReturningInitialValue()
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
