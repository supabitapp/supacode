import Dependencies
import Foundation
import Sharing

public nonisolated struct RepositorySettingsKeyID: Hashable, Sendable {
  public let repositoryID: String

  public init(repositoryID: String) {
    self.repositoryID = repositoryID
  }
}

public nonisolated struct RepositorySettingsKey: SharedKey {
  public let repositoryID: String
  public let rootURL: URL
  public let host: RemoteHost?

  public init(rootURL: URL, host: RemoteHost? = nil) {
    self.rootURL = rootURL.standardizedFileURL
    self.host = host
    if let host {
      // Brand remote keys with the host (matching `RepositoryLocation.id`) so
      // two hosts at the same path can't share settings, and so a local repo
      // at that path keeps its own bare-path key.
      repositoryID = "remote://" + host.authority + self.rootURL.path(percentEncoded: false)
    } else {
      repositoryID = self.rootURL.path(percentEncoded: false)
    }
  }

  public var id: RepositorySettingsKeyID {
    RepositorySettingsKeyID(repositoryID: repositoryID)
  }

  public func load(
    context: LoadContext<RepositorySettings>,
    continuation: LoadContinuation<RepositorySettings>
  ) {
    // Remote repos never own a local `supacode.json`; the synthetic `rootURL`
    // points at the remote path, which must not be read off the local disk.
    if host == nil {
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
          "Unable to decode repository settings at \(path); falling back to global settings."
        )
      }
    }

    @Shared(.settingsFile) var settingsFile: SettingsFile
    let settings = $settingsFile.withLock { settings in
      if let existing = settings.repositories[repositoryID] {
        return existing
      }
      let defaults = context.initialValue ?? .default
      settings.repositories[repositoryID] = defaults
      return defaults
    }
    continuation.resume(returning: settings)
  }

  public func subscribe(
    context _: LoadContext<RepositorySettings>,
    subscriber _: SharedSubscriber<RepositorySettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  public func save(
    _ value: RepositorySettings,
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    // Mirror `load`: only a local repo may persist to an on-disk `supacode.json`.
    if host == nil {
      @Dependency(\.repositoryLocalSettingsStorage) var repositoryLocalSettingsStorage
      let repositorySettingsURL = SupacodePaths.repositorySettingsURL(for: rootURL)
      if (try? repositoryLocalSettingsStorage.load(repositorySettingsURL)) != nil {
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(value)
          try repositoryLocalSettingsStorage.save(data, repositorySettingsURL)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
        return
      }
    }

    @Shared(.settingsFile) var settingsFile: SettingsFile
    $settingsFile.withLock {
      $0.repositories[repositoryID] = value
    }
    continuation.resume()
  }
}
nonisolated extension SharedReaderKey where Self == RepositorySettingsKey.Default {
  public static func repositorySettings(_ rootURL: URL, host: RemoteHost? = nil) -> Self {
    Self[RepositorySettingsKey(rootURL: rootURL, host: host), default: .default]
  }
}
