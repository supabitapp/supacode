import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

nonisolated struct ConversationsKeyID: Hashable, Sendable {}

public nonisolated enum ConversationsFileURLKey: DependencyKey {
  public static var liveValue: URL { SupacodePaths.conversationsURL }
  public static var previewValue: URL { SupacodePaths.conversationsURL }
  public static var testValue: URL {
    FileManager.default.temporaryDirectory
      .appending(
        path: "supacode-conversations-test-\(UUID().uuidString).json",
        directoryHint: .notDirectory
      )
  }
}

extension DependencyValues {
  public nonisolated var conversationsFileURL: URL {
    get { self[ConversationsFileURLKey.self] }
    set { self[ConversationsFileURLKey.self] = newValue }
  }
}

nonisolated struct ConversationsKey: SharedKey {
  private static let logger = SupaLogger("Conversations")

  var id: ConversationsKeyID { ConversationsKeyID() }

  func load(
    context _: LoadContext<ConversationStore>,
    continuation: LoadContinuation<ConversationStore>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.conversationsFileURL) var url
    let data: Data
    do {
      data = try storage.load(url)
    } catch {
      continuation.resumeReturningInitialValue()
      return
    }
    do {
      let conversations = try JSONDecoder().decode(ConversationStore.self, from: data)
      continuation.resume(returning: conversations)
    } catch {
      Self.logger.warning(
        "Failed to decode conversations from \(url.path(percentEncoded: false)): \(error)"
      )
      Self.renameCorruptFile(at: url)
      continuation.resumeReturningInitialValue()
    }
  }

  func subscribe(
    context _: LoadContext<ConversationStore>,
    subscriber _: SharedSubscriber<ConversationStore>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: ConversationStore,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.conversationsFileURL) var url
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value)
      try storage.save(data, url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }

  private static func renameCorruptFile(at url: URL) {
    let fileManager = FileManager.default
    let sourcePath = url.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: sourcePath) else {
      return
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp = formatter.string(from: Date()).replacing(":", with: "-")
    let destination = url.deletingLastPathComponent()
      .appending(
        path: "\(url.lastPathComponent).corrupt-\(timestamp)",
        directoryHint: .notDirectory
      )
    do {
      try fileManager.moveItem(at: url, to: destination)
    } catch {
      Self.logger.warning(
        """
        Failed to rename corrupt conversations file to \(destination.lastPathComponent): \(error). \
        Next save WILL overwrite the corrupt bytes.
        """
      )
    }
  }
}

nonisolated extension SharedReaderKey where Self == ConversationsKey.Default {
  static var conversations: Self {
    Self[ConversationsKey(), default: ConversationStore()]
  }
}
