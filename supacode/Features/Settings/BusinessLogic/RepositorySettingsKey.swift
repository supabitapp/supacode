import Dependencies
import Foundation
import Sharing

nonisolated struct RepositorySettingsKeyID: Hashable, Sendable {
  let repositoryID: String
}

nonisolated struct RepositorySettingsKey: SharedKey {
  let repositoryID: String
  let rootURL: URL

  init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
    repositoryID = self.rootURL.path(percentEncoded: false)
  }

  var id: RepositorySettingsKeyID {
    RepositorySettingsKeyID(repositoryID: repositoryID)
  }

  func load(
    context: LoadContext<RepositorySettings>,
    continuation: LoadContinuation<RepositorySettings>
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    if let localData = try? repositoryLocalSettingsStorage.load(repositorySettingsURL) {
      let decoder = JSONDecoder()
      if let settings = try? decoder.decode(RepositorySettings.self, from: localData) {
        continuation.resume(returning: settings)
        return
      }
      let path = repositorySettingsURL.path(percentEncoded: false)
      SupaLogger("Settings").warning(
        "Unable to decode repository settings at \(path); migrating from global settings."
      )
    }

    @Shared(.settingsFile) var settingsFile: SettingsFile
    let migratedSettings = $settingsFile.withLock { settings in
      settings.repositories[repositoryID] ?? (context.initialValue ?? .default)
    }
    if migratedSettings != .default {
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(migratedSettings)
        try repositoryLocalSettingsStorage.save(data, repositorySettingsURL)
      } catch {
        let path = repositorySettingsURL.path(percentEncoded: false)
        SupaLogger("Settings").warning(
          "Unable to write migrated repository settings to \(path): \(error.localizedDescription)"
        )
      }
    }
    continuation.resume(returning: migratedSettings)
  }

  func subscribe(
    context _: LoadContext<RepositorySettings>,
    subscriber _: SharedSubscriber<RepositorySettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: RepositorySettings,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
    let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value)
      try repositoryLocalSettingsStorage.save(data, repositorySettingsURL)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == RepositorySettingsKey.Default {
  static func repositorySettings(_ rootURL: URL) -> Self {
    Self[RepositorySettingsKey(rootURL: rootURL), default: .default]
  }
}
