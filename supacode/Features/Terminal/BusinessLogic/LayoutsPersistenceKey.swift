import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

nonisolated struct LayoutsKeyID: Hashable, Sendable {}

nonisolated struct LayoutsKey: SharedKey {
  private static let logger = SupaLogger("Layouts")

  var id: LayoutsKeyID { LayoutsKeyID() }

  func load(
    context _: LoadContext<[String: TerminalLayoutSnapshot]>,
    continuation: LoadContinuation<[String: TerminalLayoutSnapshot]>
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
    do {
      let layouts = try JSONDecoder().decode([String: TerminalLayoutSnapshot].self, from: data)
      continuation.resume(returning: layouts)
    } catch {
      Self.logger.warning(
        "Failed to decode layouts from \(SupacodePaths.layoutsURL.path(percentEncoded: false)): \(error)"
      )
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<[String: TerminalLayoutSnapshot]>,
    subscriber _: SharedSubscriber<[String: TerminalLayoutSnapshot]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [String: TerminalLayoutSnapshot],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value)
      try storage.save(data, SupacodePaths.layoutsURL)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == LayoutsKey.Default {
  static var layouts: Self {
    Self[LayoutsKey(), default: [:]]
  }
}
